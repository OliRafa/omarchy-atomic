#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-update-requires-free-space reads `df --output=avail --block-size=1 /`
# and fails (exit 1) below a 10 GiB threshold, fails open when df is unreadable,
# and is bypassed by OMARCHY_UPDATE_FORCE.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/df" <<'SH'
#!/bin/bash
if [[ ${TEST_DF_INVALID:-0} == 1 ]]; then
  printf 'avail\nunknown\n'
else
  printf 'avail\n%s\n' "$TEST_AVAILABLE_BYTES"
fi
SH
chmod +x "$stub_bin/df"

run_check() {
  TEST_AVAILABLE_BYTES="${TEST_AVAILABLE_BYTES:-$((9 * 1024 * 1024 * 1024))}" \
    TEST_DF_INVALID="${TEST_DF_INVALID:-0}" \
    OMARCHY_UPDATE_FORCE="${OMARCHY_UPDATE_FORCE:-0}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-requires-free-space" >/dev/null
}

set +e
TEST_AVAILABLE_BYTES=$((9 * 1024 * 1024 * 1024)) run_check
status=$?
set -e
(( status == 1 )) || fail "non-interactive update exits non-zero with low disk space"
pass "the free-space check fails when disk space is low"

set +e
TEST_AVAILABLE_BYTES=$((10 * 1024 * 1024 * 1024)) run_check
status=$?
set -e
(( status == 0 )) || fail "the free-space check passes at the 10 GiB threshold"
pass "the free-space check allows the update at the threshold"

set +e
TEST_DF_INVALID=1 run_check
status=$?
set -e
(( status == 0 )) || fail "the free-space check fails open when disk space cannot be read"
pass "the free-space check fails open when disk space is unreadable"

set +e
OMARCHY_UPDATE_FORCE=1 TEST_AVAILABLE_BYTES=0 run_check
status=$?
set -e
(( status == 0 )) || fail "OMARCHY_UPDATE_FORCE bypasses the free-space check"
pass "OMARCHY_UPDATE_FORCE bypasses the free-space check"
