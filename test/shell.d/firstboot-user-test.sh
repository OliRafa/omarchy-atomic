#!/bin/bash

# The image ships no human user: omarchy-firstboot-user.service creates the primary account on the
# first boot of a deployment. When it does not run, SDDM comes up with no account to offer and the
# machine is unreachable through the GUI — so the gating on that unit is load-bearing, and this
# file locks it down.
#
# The failure it was written for: the unit gated on ConditionFirstBoot=yes, which systemd latches
# from an empty /etc/machine-id at boot start. Nothing in the image build ships one empty, and a
# composefs deployment takes /etc from the image, so the condition came out false on real hardware.
# The unit never ran, getty kept tty1, and the greeter had no user.

source "$(dirname "$0")/base-test.sh"

unit="$ROOT/images/core/files/usr/lib/systemd/system/omarchy-firstboot-user.service"
helper="$ROOT/images/core/files/usr/libexec/omarchy-firstboot-user"

[[ -f $unit ]] || fail "the first-boot user unit ships"
[[ -f $helper ]] || fail "the first-boot user helper ships"

# --- unit gating ------------------------------------------------------------------------------

if grep -q '^ConditionFirstBoot' "$unit"; then
  fail "unit does not gate on ConditionFirstBoot" "$(grep -n '^ConditionFirstBoot' "$unit")"
fi
pass "unit does not gate on ConditionFirstBoot"

unit_marker=$(sed -n 's/^ConditionPathExists=!//p' "$unit")
[[ -n $unit_marker ]] || fail "unit gates on a negative ConditionPathExists marker"
pass "unit gates on a marker path"

# Drift guard. If the two paths ever disagree the bug comes back wearing a different hat: a marker
# the helper never writes makes the unit fight getty for tty1 every boot, and one written somewhere
# the unit does not look makes it provision once and never again.
helper_marker=$(sed -n 's/^marker="\${OMARCHY_FIRSTBOOT_MARKER:-\(.*\)}"$/\1/p' "$helper")
[[ $helper_marker == "$unit_marker" ]] ||
  fail "unit marker matches the helper default" "unit=$unit_marker helper=${helper_marker:-<unparsed>}"
pass "unit marker matches the helper default ($unit_marker)"

grep -q '^Before=display-manager\.service' "$unit" ||
  fail "unit is ordered before the display manager (else SDDM greets with no account)"
pass "unit is ordered before the display manager"

grep -q '^WantedBy=multi-user\.target' "$unit" || fail "unit is wired into multi-user.target"
pass "unit is wired into multi-user.target"

grep -q '^TTYPath=/dev/tty1' "$unit" || fail "interactive prompt is bound to tty1"
grep -q '^StandardInput=tty-force' "$unit" || fail "interactive prompt can read from tty1"
pass "interactive prompt is bound to tty1"

# --- helper behaviour -------------------------------------------------------------------------

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

# HUMAN_USER=1 makes getent report an existing uid-1000 account.
cat >"$mock_bin/getent" <<'SH'
#!/bin/bash
case $1 in
  passwd)
    echo 'root:x:0:0:root:/root:/bin/bash'
    echo 'bin:x:1:1:bin:/bin:/sbin/nologin'
    [[ ${HUMAN_USER:-0} == 1 ]] && echo 'someone:x:1000:1000::/var/home/someone:/bin/bash'
    ;;
  group) [[ $2 == wheel ]] ;;
esac
exit 0
SH

cat >"$mock_bin/useradd" <<'SH'
#!/bin/bash
printf 'useradd %s\n' "$*" >>"$MOCK_LOG"
exit "${USERADD_RC:-0}"
SH

for cmd in usermod chpasswd passwd; do
  cat >"$mock_bin/$cmd" <<SH
#!/bin/bash
printf '$cmd %s\n' "\$*" >>"\$MOCK_LOG"
exit 0
SH
done

cat >"$mock_bin/shred" <<'SH'
#!/bin/bash
rm -f "${@: -1}"
SH

chmod +x "$mock_bin"/*

conf="$test_tmp/firstboot-user.conf"
marker="$test_tmp/state/firstboot-user.done"
mock_log="$test_tmp/mock.log"

write_preseed() {
  cat >"$conf" <<'PRESEED'
OMARCHY_USER=tester
OMARCHY_USER_FULLNAME="Test User"
OMARCHY_USER_GROUPS="wheel"
OMARCHY_USER_PASSWORD=correcthorsebattery
PRESEED
}

run_helper() {
  env PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" \
    OMARCHY_FIRSTBOOT_CONF="$conf" OMARCHY_FIRSTBOOT_MARKER="$marker" \
    "$@" bash "$helper" >"$test_tmp/out.log" 2>&1
}

# 1) No human user + preseed: provisions and marks done.
: >"$mock_log"; rm -f "$marker"; write_preseed
run_helper || fail "preseed run succeeds" "$(cat "$test_tmp/out.log")"
grep -q '^useradd .*tester' "$mock_log" || fail "preseed run creates the account" "$(cat "$mock_log")"
pass "preseed run creates the account"
[[ -f $marker ]] || fail "preseed run writes the done marker"
pass "preseed run writes the done marker"
[[ ! -e $conf ]] || fail "preseed holding a password is scrubbed after use"
pass "preseed is scrubbed after use"

# 2) A human user already exists: no-op, but still marks done so the unit stops taking tty1.
: >"$mock_log"; rm -f "$marker"
HUMAN_USER=1 run_helper || fail "run with an existing user succeeds" "$(cat "$test_tmp/out.log")"
grep -q '^useradd' "$mock_log" && fail "run with an existing user creates nothing" "$(cat "$mock_log")"
pass "run with an existing user creates nothing"
[[ -f $marker ]] || fail "run with an existing user still marks done"
pass "run with an existing user still marks done"

# 3) Provisioning FAILS: must NOT mark done, so the next boot retries instead of latching off with
#    no account — the shape of the original bug, reached by a different route.
: >"$mock_log"; rm -f "$marker"; write_preseed
if USERADD_RC=1 run_helper; then
  fail "a failed useradd fails the unit" "$(cat "$test_tmp/out.log")"
fi
pass "a failed useradd fails the unit"
[[ ! -e $marker ]] || fail "a failed run leaves no done marker (so the next boot retries)"
pass "a failed run leaves no done marker"
