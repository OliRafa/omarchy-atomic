#!/bin/bash

# omarchy-brew-setup.service installs Homebrew for the primary user on first boot. Homebrew is a
# core dependency here, not an extra: omarchy-default-editor runs nvim, and tmux/gh resolve the
# same way, all from the Brewfile. When this helper picks the wrong account there is no brew, and
# those commands are dangling references on a machine that otherwise looks healthy.
#
# The failure this file was written for: the awk printed `$3, $2` from `getent passwd`. passwd
# fields are name:passwd:uid:gid:gecos:home:shell, so $2 is the password placeholder, not the name.
# Every machine resolved its primary user to the literal string "x":
#
#   id: 'x': no such user
#   brew-setup: installing Homebrew for x
#   install: invalid user 'x'
#   su: user x does not exist or the user entry does not contain all the required fields
#   brew-setup: Homebrew install failed
#
# brew had therefore never installed on any boot of any machine. Nothing caught it because the
# sibling check in omarchy-firstboot-user only tests whether a row EXISTS — it never extracts a
# field — so the bug lived only on the path no test exercised.

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

# Drift guard: the stamp the unit's description promises is "first boot" only if the helper writes
# the path the helper itself reads. Both come from the same default here.
helper_stamp=$(sed -n 's/^STAMP="\${OMARCHY_BREW_STAMP:-\(.*\)}"$/\1/p' "$helper")
[[ -n $helper_stamp ]] || fail "helper has a parseable stamp default"
pass "helper stamps completion at $helper_stamp"

# --- primary-user detection -------------------------------------------------------------------

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

# Everything the helper shells out to, recording its arguments instead of doing the work. `su` is
# the one that matters: whatever name reaches it is the name brew gets installed for.
cat >"$mock_bin/id" <<'SH'
#!/bin/bash
[[ $1 == -gn ]] && { printf '%s\n' "$2"; exit 0; }
exit 0
SH

for cmd in install su; do
  cat >"$mock_bin/$cmd" <<SH
#!/bin/bash
printf '$cmd %s\n' "\$*" >>"\$MOCK_LOG"
exit 0
SH
done

chmod +x "$mock_bin"/*

brewfile="$test_tmp/Brewfile"
printf 'brew "neovim"\n' >"$brewfile"
stamp="$test_tmp/state/brew-setup-done"
login_defs="$test_tmp/login.defs"
printf 'UID_MIN 1000\nUID_MAX 60000\n' >"$login_defs"
mock_log="$test_tmp/mock.log"

run_helper() {
  env PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" \
    OMARCHY_BREW_FILE="$brewfile" OMARCHY_BREW_STAMP="$stamp" \
    OMARCHY_BREW_PREFIX="$test_tmp/linuxbrew" OMARCHY_LOGIN_DEFS="$login_defs" \
    "$@" bash "$helper" >"$test_tmp/out.log" 2>&1
}

# 1) The regression itself. The helper must resolve the account NAME, never the passwd placeholder.
: >"$mock_log"; rm -f "$stamp"
HUMAN_USER=1 run_helper || fail "run with a human user succeeds" "$(cat "$test_tmp/out.log")"
grep -q "installing Homebrew for rafael" "$test_tmp/out.log" ||
  fail "helper resolves the primary user by name" "$(cat "$test_tmp/out.log")"
pass "helper resolves the primary user by name"

grep -qE '^su .*\brafael\b' "$mock_log" ||
  fail "the account name is what reaches su" "$(cat "$mock_log")"
pass "the account name is what reaches su"

# The exact shape of the bug: "x" is every passwd row's second field, so it can never be a user.
if grep -qE "(^| )x( |$)" "$mock_log" || grep -q "Homebrew for x" "$test_tmp/out.log"; then
  fail "the passwd placeholder never reaches a command" "$(cat "$mock_log")"
fi
pass "the passwd placeholder never reaches a command"

[[ -f $stamp ]] || fail "a successful run stamps done" "$(cat "$test_tmp/out.log")"
pass "a successful run stamps done"

# 2) The lowest uid in range wins, so a second account added later cannot hijack the prefix.
: >"$mock_log"; rm -f "$stamp"
HUMAN_USER=1 SECOND_USER=1 run_helper || fail "run with two users succeeds" "$(cat "$test_tmp/out.log")"
grep -q "installing Homebrew for rafael" "$test_tmp/out.log" ||
  fail "the lowest uid in range is chosen" "$(cat "$test_tmp/out.log")"
pass "the lowest uid in range is chosen"

# 3) A DynamicUser= account is not a human. speakersafetyd (Asahi speaker protection) lands at uid
#    62454, which systemd allocates from 61184-65519 and nss-systemd surfaces in getent. It must
#    neither be chosen nor make the helper think provisioning is done.
: >"$mock_log"; rm -f "$stamp"
DYNAMIC_USER=1 run_helper || fail "run alongside a DynamicUser account succeeds" "$(cat "$test_tmp/out.log")"
grep -q "no primary user yet" "$test_tmp/out.log" ||
  fail "a DynamicUser account is not treated as the primary user" "$(cat "$test_tmp/out.log")"
pass "a DynamicUser account is not treated as the primary user"
[[ ! -f $stamp ]] || fail "a run with no human user leaves no stamp, so it retries next boot"
pass "a run with no human user leaves no stamp"

# 4) No human user at all: same retry behaviour, and nothing is invoked against a bogus name.
: >"$mock_log"; rm -f "$stamp"
run_helper || fail "run with no users succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "no commands run without a primary user" "$(cat "$mock_log")"
pass "no commands run without a primary user"

# 5) Already stamped: a no-op, so a later boot does not reinstall over a working prefix.
: >"$mock_log"; mkdir -p "$(dirname "$stamp")"; : >"$stamp"
HUMAN_USER=1 run_helper || fail "a stamped run succeeds" "$(cat "$test_tmp/out.log")"
[[ ! -s $mock_log ]] || fail "a stamped run does nothing" "$(cat "$mock_log")"
pass "a stamped run does nothing"
