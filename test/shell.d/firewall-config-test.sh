#!/bin/bash

set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/base-test.sh"

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

# The fork uses firewalld (Fedora), not ufw. firewall-cmd must exist so setup
# proceeds; systemctl reports firewalld neither enabled nor active, so setup
# enables it for next boot and stages the permanent rules through
# firewall-offline-cmd rather than touching a live daemon.
cat >"$stub_dir/firewall-cmd" <<'STUB'
#!/bin/bash
printf 'firewall-cmd %s\n' "$*" >>"$TEST_LOG"
STUB

cat >"$stub_dir/firewall-offline-cmd" <<'STUB'
#!/bin/bash
printf 'firewall-offline-cmd %s\n' "$*" >>"$TEST_LOG"
STUB

cat >"$stub_dir/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$TEST_LOG"
# is-enabled / is-active both fail: firewalld is off in the test environment.
exit 1
STUB

chmod +x "$stub_dir"/*

export TEST_LOG="$stub_dir/firewall.log"
PATH="$stub_dir:$PATH" bash -eE -c 'source "$1"' bash "$ROOT/install/config/firewall.sh"

grep -q '^systemctl enable firewalld$' "$TEST_LOG" ||
  fail "firewalld is enabled for next boot" "$(cat "$TEST_LOG")"
grep -q '^firewall-offline-cmd --add-port=53317/udp$' "$TEST_LOG" ||
  fail "the LocalSend UDP port is opened"
grep -q '^firewall-offline-cmd --add-port=53317/tcp$' "$TEST_LOG" ||
  fail "the LocalSend TCP port is opened"
grep -q 'firewall-offline-cmd --add-rich-rule=.*172.17.0.1' "$TEST_LOG" ||
  fail "the Docker DNS rich rule is staged"
# firewalld is inactive here, so nothing should reload a live daemon.
! grep -q '^firewall-cmd --reload$' "$TEST_LOG" ||
  fail "firewall config does not reload an inactive firewalld"

pass "firewall config stages firewalld rules offline without activating a live daemon"
