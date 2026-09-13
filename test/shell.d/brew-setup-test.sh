#!/bin/bash

# omarchy-brew-setup.service installs Homebrew for the primary user on first boot. Homebrew is a
# core dependency here, not an extra: omarchy-default-editor runs nvim, and tmux/gh resolve the
# same way, all from the Brewfile. When this helper picks the wrong account, or thinks it
# installed something it did not, there is no brew — and those commands are dangling references on
# a machine that otherwise looks healthy.
#
# Two failures on hardware, both silent, both found only by reading the journal:
#
#  1. The awk printed `$3, $2` from `getent passwd`. Fields are name:passwd:uid:gid:gecos:home:shell,
#     so $2 is the password placeholder. Every machine resolved its primary user to "x":
#       id: 'x': no such user / install: invalid user 'x' / su: user x does not exist
#     The sibling check in omarchy-firstboot-user only asks whether a row EXISTS, never extracting
#     a field, so the bug lived on the one path nothing exercised.
#
#  2. The installer ran as `/bin/bash -c "$(curl -fsSL ...)"`. When curl fails that substitution is
#     the EMPTY STRING, bash runs nothing and exits 0, and the `|| exit 1` never fires — so the run
#     walked on to `brew bundle` against an empty prefix and blamed the bundle. At boot,
#     network-online.target is routinely reached before DNS answers, and the whole service failed
#     inside a single second without ever naming the real cause.
#
# The mocks below run the command strings the helper builds rather than swallowing them, so both
# the account name and the installer invocation are exercised for real.

source "$(dirname "$0")/base-test.sh"

unit="$ROOT/images/core/files/usr/lib/systemd/system/omarchy-brew-setup.service"
helper="$ROOT/images/core/files/usr/libexec/omarchy-brew-setup"

[[ -f $unit ]] || fail "the brew setup unit ships"
[[ -f $helper ]] || fail "the brew setup helper ships"
pass "the brew setup unit and helper ship"

# --- unit wiring ------------------------------------------------------------------------------

grep -q '^WantedBy=multi-user\.target' "$unit" || fail "unit is wired into multi-user.target"
pass "unit is wired into multi-user.target"

# Fetching the installer and the bottles needs a network that is actually up, not merely
# configured — network.target is reached long before that.
grep -q '^After=network-online\.target' "$unit" || fail "unit waits for network-online.target"
grep -q '^Wants=network-online\.target' "$unit" || fail "unit pulls in network-online.target"
pass "unit waits for the network to be online"

# Drift guard: the unit promises "first boot", which holds only if the helper writes the stamp path
# it also reads. Both come from the same default here.
helper_stamp=$(sed -n 's/^STAMP="\${OMARCHY_BREW_STAMP:-\(.*\)}"$/\1/p' "$helper")
[[ -n $helper_stamp ]] || fail "helper has a parseable stamp default"
pass "helper stamps completion at $helper_stamp"

# --- harness ------------------------------------------------------------------------------------

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

# getent as nss-systemd presents it: real accounts from /etc/passwd, plus DynamicUser= accounts
# that exist only in the name-service layer.
cat >"$mock_bin/getent" <<'SH'
#!/bin/bash
case $1 in
  passwd)
    echo 'root:x:0:0:root:/root:/bin/bash'
    echo 'bin:x:1:1:bin:/bin:/sbin/nologin'
    [[ ${DYNAMIC_USER:-0} == 1 ]] && echo 'speakersafetyd:x:62454:62454:Dynamic User:/:/usr/sbin/nologin'
    [[ ${HUMAN_USER:-0} == 1 ]] && echo 'rafael:x:1000:1000:Rafael:/var/home/rafael:/bin/bash'
    [[ ${SECOND_USER:-0} == 1 ]] && echo 'later:x:1001:1001::/var/home/later:/bin/bash'
    ;;
esac
exit 0
SH

cat >"$mock_bin/id" <<'SH'
#!/bin/bash
[[ $1 == -gn ]] && { printf '%s\n' "$2"; exit 0; }
exit 0
SH

cat >"$mock_bin/install" <<'SH'
#!/bin/bash
printf 'install %s\n' "$*" >>"$MOCK_LOG"
exit 0
SH

# su RUNS the command it is handed rather than discarding it, so the command string the helper
# builds — the installer invocation, the shellenv eval, the bundle call — is genuinely executed.
# A mock that only recorded its arguments would have passed happily against `bash -c "$(curl …)"`.
cat >"$mock_bin/su" <<'SH'
#!/bin/bash
printf 'su %s\n' "$*" >>"$MOCK_LOG"
cmd=""
while [[ $# -gt 0 ]]; do
  [[ $1 == -c ]] && { cmd="$2"; shift 2; continue; }
  shift
done
[[ -n $cmd ]] || exit 0
bash -c "$cmd"
SH

# curl writes a fake Homebrew installer to -o, or fails the way it does at boot when
# network-online.target has been reached but DNS is not answering yet.
cat >"$mock_bin/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >>"$MOCK_LOG"
out=""
while [[ $# -gt 0 ]]; do
  [[ $1 == -o ]] && { out="$2"; shift 2; continue; }
  shift
done
[[ ${CURL_FAILS:-0} == 1 ]] && exit 6          # 6 = could not resolve host
[[ -n $out ]] || exit 0
if [[ ${INSTALLER_PRODUCES_BREW:-1} == 1 ]]; then
  cat >"$out" <<'INNER'
#!/bin/bash
mkdir -p "$FAKE_PREFIX/bin"
printf '#!/bin/bash\n[ "$1" = bundle ] && echo "bundle ran"\nexit 0\n' >"$FAKE_PREFIX/bin/brew"
chmod +x "$FAKE_PREFIX/bin/brew"
INNER
else
  # An installer that exits 0 having produced nothing — Homebrew's own does this on some paths.
  printf '#!/bin/bash\nexit 0\n' >"$out"
fi
exit 0
SH

chmod +x "$mock_bin"/*

brewfile="$test_tmp/Brewfile"
printf 'brew "neovim"\n' >"$brewfile"
stamp="$test_tmp/state/brew-setup-done"
login_defs="$test_tmp/login.defs"
printf 'UID_MIN 1000\nUID_MAX 60000\n' >"$login_defs"
mock_log="$test_tmp/mock.log"
prefix="$test_tmp/linuxbrew"

reset() { : >"$mock_log"; rm -f "$stamp"; rm -rf "$prefix"; }

run_helper() {
  env PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" FAKE_PREFIX="$prefix" \
    OMARCHY_BREW_FILE="$brewfile" OMARCHY_BREW_STAMP="$stamp" \
    OMARCHY_BREW_PREFIX="$prefix" OMARCHY_LOGIN_DEFS="$login_defs" \
    OMARCHY_BREW_INSTALLER_URL="https://example.invalid/install.sh" \
    "$@" bash "$helper" >"$test_tmp/out.log" 2>&1
}

# --- 1) the account name ------------------------------------------------------------------------

reset
HUMAN_USER=1 run_helper || fail "a full install run succeeds" "$(cat "$test_tmp/out.log")"
grep -q "installing Homebrew for rafael" "$test_tmp/out.log" ||
  fail "helper resolves the primary user by name" "$(cat "$test_tmp/out.log")"
pass "helper resolves the primary user by name"

grep -qE '^su .*\brafael\b' "$mock_log" ||
  fail "the account name is what reaches su" "$(cat "$mock_log")"
pass "the account name is what reaches su"

# "x" is every passwd row's second field, so it can never be a real account.
if grep -qE "(^| )x( |$)" "$mock_log" || grep -q "Homebrew for x" "$test_tmp/out.log"; then
  fail "the passwd placeholder never reaches a command" "$(cat "$mock_log")"
fi
pass "the passwd placeholder never reaches a command"

[[ -x $prefix/bin/brew ]] || fail "the install actually produced brew" "$(cat "$test_tmp/out.log")"
pass "the install actually produced brew"
[[ -f $stamp ]] || fail "a successful run stamps done" "$(cat "$test_tmp/out.log")"
pass "a successful run stamps done"

# --- 2) which account wins ----------------------------------------------------------------------

reset
HUMAN_USER=1 SECOND_USER=1 run_helper || fail "run with two users succeeds" "$(cat "$test_tmp/out.log")"
grep -q "installing Homebrew for rafael" "$test_tmp/out.log" ||
  fail "the lowest uid in range is chosen" "$(cat "$test_tmp/out.log")"
pass "the lowest uid in range is chosen"

# A DynamicUser= account is not a human. speakersafetyd (Asahi speaker protection) lands at uid
# 62454, which systemd allocates from 61184-65519 and nss-systemd surfaces in getent.
reset
DYNAMIC_USER=1 run_helper || fail "run alongside a DynamicUser account succeeds" "$(cat "$test_tmp/out.log")"
grep -q "no primary user yet" "$test_tmp/out.log" ||
  fail "a DynamicUser account is not treated as the primary user" "$(cat "$test_tmp/out.log")"
pass "a DynamicUser account is not treated as the primary user"
[[ ! -f $stamp ]] || fail "a run with no human user leaves no stamp, so it retries next boot"
pass "a run with no human user leaves no stamp"

reset
run_helper || fail "run with no users succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "no commands run without a primary user" "$(cat "$mock_log")"
pass "no commands run without a primary user"

# --- 3) the download must not fail silently -----------------------------------------------------

reset
HUMAN_USER=1 CURL_FAILS=1 run_helper &&
  fail "a failed installer download fails the run" "$(cat "$test_tmp/out.log")"
pass "a failed installer download fails the run"
grep -q "could not download the Homebrew installer" "$test_tmp/out.log" ||
  fail "the failure names the download, not brew bundle" "$(cat "$test_tmp/out.log")"
pass "the failure names the download, not brew bundle"
grep -q "brew bundle failed" "$test_tmp/out.log" &&
  fail "a failed download never reaches brew bundle" "$(cat "$test_tmp/out.log")"
pass "a failed download never reaches brew bundle"
[[ ! -f $stamp ]] || fail "a failed download leaves no stamp, so it retries next boot"
pass "a failed download leaves no stamp"

# An installer that exits 0 having produced nothing must be caught at the prefix, not two commands
# later as "brew: command not found" from inside a login shell.
reset
HUMAN_USER=1 INSTALLER_PRODUCES_BREW=0 run_helper &&
  fail "an installer that produces no brew fails the run" "$(cat "$test_tmp/out.log")"
pass "an installer that produces no brew fails the run"
grep -q "installer finished but .* is missing" "$test_tmp/out.log" ||
  fail "the failure names the missing brew binary" "$(cat "$test_tmp/out.log")"
pass "the failure names the missing brew binary"
[[ ! -f $stamp ]] || fail "a run that produced no brew leaves no stamp"
pass "a run that produced no brew leaves no stamp"

# --- 4) idempotence -----------------------------------------------------------------------------

# Already stamped: a no-op, so a later boot does not reinstall over a working prefix.
reset; mkdir -p "$prefix/bin"; : >"$prefix/bin/brew"; chmod +x "$prefix/bin/brew"
mkdir -p "$(dirname "$stamp")"; : >"$stamp"
HUMAN_USER=1 run_helper || fail "a stamped run succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "a stamped run does nothing" "$(cat "$mock_log")"
pass "a stamped run does nothing"

# brew already present but no stamp (a previous bundle failed): reuse it, never reinstall.
reset; mkdir -p "$prefix/bin"
printf '#!/bin/bash\n[ "$1" = bundle ] && echo "bundle ran"\nexit 0\n' >"$prefix/bin/brew"
chmod +x "$prefix/bin/brew"
HUMAN_USER=1 run_helper || fail "a re-run over an existing brew succeeds" "$(cat "$test_tmp/out.log")"
grep -q "installing Homebrew" "$test_tmp/out.log" &&
  fail "an existing brew is not reinstalled" "$(cat "$test_tmp/out.log")"
pass "an existing brew is not reinstalled"
grep -q '^curl' "$mock_log" && fail "an existing brew means no download" "$(cat "$mock_log")"
pass "an existing brew means no download"
[[ -f $stamp ]] || fail "the re-run stamps done"
pass "the re-run stamps done"
