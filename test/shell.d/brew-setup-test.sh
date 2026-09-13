#!/bin/bash

# omarchy-brew-setup.service hands Homebrew to the primary user and applies the Brewfile on first
# boot. Homebrew is a core dependency here, not an extra: omarchy-default-editor runs nvim, and
# tmux/gh resolve the same way, all from the Brewfile. When this helper picks the wrong account
# there is no brew, and those commands are dangling references on a machine that looks healthy.
#
# Homebrew itself now ships PREBUILT in the image (ublue's brew image) and ublue's own
# brew-setup.service unpacks it. This helper no longer touches the network. That change is the
# fix for two hardware failures, both silent, both found only by reading the journal:
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
# (2) is now structurally impossible: there is no download. What remains is that the helper must
# still resolve the right account, must re-own the prefix away from ublue's hardcoded uid 1000, and
# must fail loudly rather than silently when the unpack has not happened.

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

# Ordering, not Requires=: if either has not happened the helper must say so and retry next boot,
# never be silently skipped.
grep -q '^After=brew-setup\.service' "$unit" ||
  fail "unit is ordered after ublue's brew-setup.service (the unpack)"
grep -q '^After=omarchy-firstboot-user\.service' "$unit" ||
  fail "unit is ordered after the primary account is created"
pass "unit is ordered after the unpack and the account"
if grep -qE '^(Requires|BindsTo)=brew-setup\.service' "$unit"; then
  fail "a hard dependency would skip the retry path" "$(grep -nE '^(Requires|BindsTo)=' "$unit")"
fi
pass "the dependency on the unpack is ordering only"

# The network path is what kept failing. It must be gone, not merely guarded. Comments are
# excluded: the helper documents the bug it used to have, and naming it is not doing it.
if grep -vE '^[[:space:]]*#' "$helper" | grep -qE 'install\.sh|curl|wget'; then
  fail "the helper no longer downloads anything" \
    "$(grep -vE '^[[:space:]]*#' "$helper" | grep -nE 'install\.sh|curl|wget')"
fi
pass "the helper no longer downloads anything"

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

# stat reports whoever OWNS_PREFIX says, so the re-own path can be driven without root.
cat >"$mock_bin/stat" <<'SH'
#!/bin/bash
[[ $1 == -c && $2 == %u ]] && { printf '%s
' "${OWNS_PREFIX:-1000}"; exit 0; }
exit 1
SH

cat >"$mock_bin/chown" <<'SH'
#!/bin/bash
printf 'chown %s
' "$*" >>"$MOCK_LOG"
exit "${CHOWN_RC:-0}"
SH

# su RUNS the command it is handed rather than discarding it, so the command string the helper
# builds — the shellenv eval and the bundle call — is genuinely executed. A mock that only recorded
# its arguments is how the old `bash -c "$(curl …)"` bug survived a passing test suite.
cat >"$mock_bin/su" <<'SH'
#!/bin/bash
printf 'su %s
' "$*" >>"$MOCK_LOG"
cmd=""
while [[ $# -gt 0 ]]; do
  [[ $1 == -c ]] && { cmd="$2"; shift 2; continue; }
  shift
done
[[ -n $cmd ]] || exit 0
bash -c "$cmd"
SH

chmod +x "$mock_bin"/*

brewfile="$test_tmp/Brewfile"
printf 'brew "neovim"\n' >"$brewfile"
stamp="$test_tmp/state/brew-setup-done"
login_defs="$test_tmp/login.defs"
printf 'UID_MIN 1000\nUID_MAX 60000\n' >"$login_defs"
mock_log="$test_tmp/mock.log"
prefix="$test_tmp/linuxbrew"

# unpack fakes what ublue's brew-setup.service leaves behind: a working brew under the prefix.
unpack() {
  mkdir -p "$prefix/bin"
  printf '#!/bin/bash\n[ "$1" = bundle ] && echo "bundle ran"\nexit 0\n' >"$prefix/bin/brew"
  chmod +x "$prefix/bin/brew"
}
reset() { : >"$mock_log"; rm -f "$stamp"; rm -rf "$prefix"; }

run_helper() {
  env PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" \
    OMARCHY_BREW_FILE="$brewfile" OMARCHY_BREW_STAMP="$stamp" \
    OMARCHY_BREW_PREFIX="$prefix" OMARCHY_LOGIN_DEFS="$login_defs" \
    "$@" bash "$helper" >"$test_tmp/out.log" 2>&1
}

# --- 1) the account name ------------------------------------------------------------------------

reset; unpack
HUMAN_USER=1 run_helper || fail "a normal run succeeds" "$(cat "$test_tmp/out.log")"
grep -q "applying .* as rafael" "$test_tmp/out.log" ||
  fail "helper resolves the primary user by name" "$(cat "$test_tmp/out.log")"
pass "helper resolves the primary user by name"

grep -qE '^su .*\brafael\b' "$mock_log" ||
  fail "the account name is what reaches su" "$(cat "$mock_log")"
pass "the account name is what reaches su"

# "x" is every passwd row's second field, so it can never be a real account.
if grep -qE "(^| )x( |$)" "$mock_log" || grep -q " as x" "$test_tmp/out.log"; then
  fail "the passwd placeholder never reaches a command" "$(cat "$mock_log")"
fi
pass "the passwd placeholder never reaches a command"

grep -q "bundle ran" "$test_tmp/out.log" ||
  fail "the Brewfile is actually applied" "$(cat "$test_tmp/out.log")"
pass "the Brewfile is actually applied"
[[ -f $stamp ]] || fail "a successful run stamps done" "$(cat "$test_tmp/out.log")"
pass "a successful run stamps done"

# --- 2) which account wins ----------------------------------------------------------------------

reset; unpack
HUMAN_USER=1 SECOND_USER=1 run_helper || fail "run with two users succeeds" "$(cat "$test_tmp/out.log")"
grep -q "applying .* as rafael" "$test_tmp/out.log" ||
  fail "the lowest uid in range is chosen" "$(cat "$test_tmp/out.log")"
pass "the lowest uid in range is chosen"

# A DynamicUser= account is not a human. speakersafetyd (Asahi speaker protection) lands at uid
# 62454, which systemd allocates from 61184-65519 and nss-systemd surfaces in getent.
reset; unpack
DYNAMIC_USER=1 run_helper || fail "run alongside a DynamicUser account succeeds" "$(cat "$test_tmp/out.log")"
grep -q "no primary user yet" "$test_tmp/out.log" ||
  fail "a DynamicUser account is not treated as the primary user" "$(cat "$test_tmp/out.log")"
pass "a DynamicUser account is not treated as the primary user"
[[ ! -f $stamp ]] || fail "a run with no human user leaves no stamp, so it retries next boot"
pass "a run with no human user leaves no stamp"

reset; unpack
run_helper || fail "run with no users succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "no commands run without a primary user" "$(cat "$mock_log")"
pass "no commands run without a primary user"

# --- 3) ownership -------------------------------------------------------------------------------

# ublue's brew-setup.service chowns the unpacked tree to a hardcoded 1000:1000. That is right on
# nearly every machine but it is an assumption, and a prefix owned by the wrong uid is a brew that
# cannot install anything. Re-own to the account actually detected.
reset; unpack
HUMAN_USER=1 OWNS_PREFIX=1000 run_helper || fail "run with matching ownership succeeds" "$(cat "$test_tmp/out.log")"
grep -q '^chown' "$mock_log" &&
  fail "ownership already correct means no chown" "$(cat "$mock_log")"
pass "ownership already correct means no chown"

reset; unpack
HUMAN_USER=1 OWNS_PREFIX=4242 run_helper || fail "run with wrong ownership succeeds" "$(cat "$test_tmp/out.log")"
grep -qE '^chown .*rafael' "$mock_log" ||
  fail "a mismatched owner is re-owned to the detected user" "$(cat "$mock_log")"
pass "a mismatched owner is re-owned to the detected user"
grep -q "was uid 4242" "$test_tmp/out.log" ||
  fail "the re-own says what it found" "$(cat "$test_tmp/out.log")"
pass "the re-own says what it found"

reset; unpack
HUMAN_USER=1 OWNS_PREFIX=4242 CHOWN_RC=1 run_helper &&
  fail "a failed chown fails the run" "$(cat "$test_tmp/out.log")"
pass "a failed chown fails the run"
[[ ! -f $stamp ]] || fail "a failed chown leaves no stamp"
pass "a failed chown leaves no stamp"

# --- 4) the unpack must have happened -------------------------------------------------------------

# Homebrew ships in the image now, so a missing prefix means ublue's brew-setup.service has not run
# or has failed. That must be named, not rediscovered as "brew: command not found" from a login
# shell two commands later — which is exactly how the old download failure presented.
reset
HUMAN_USER=1 run_helper &&
  fail "a missing brew fails the run" "$(cat "$test_tmp/out.log")"
pass "a missing brew fails the run"
grep -q "has brew-setup.service unpacked" "$test_tmp/out.log" ||
  fail "the failure names the unpack" "$(cat "$test_tmp/out.log")"
pass "the failure names the unpack"
grep -q "brew bundle failed" "$test_tmp/out.log" &&
  fail "a missing brew never reaches brew bundle" "$(cat "$test_tmp/out.log")"
pass "a missing brew never reaches brew bundle"
[[ ! -f $stamp ]] || fail "a missing brew leaves no stamp, so it retries next boot"
pass "a missing brew leaves no stamp"

# --- 5) idempotence -----------------------------------------------------------------------------

reset; unpack; mkdir -p "$(dirname "$stamp")"; : >"$stamp"
HUMAN_USER=1 run_helper || fail "a stamped run succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "a stamped run does nothing" "$(cat "$mock_log")"
pass "a stamped run does nothing"
