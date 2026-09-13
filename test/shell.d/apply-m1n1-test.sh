#!/bin/bash

# omarchy-apply-m1n1 refreshes m1n1 stage 2 + the devicetree for the running kernel. On an atomic
# install it failed every time, and this file pins the reason.
#
# update-m1n1 is a distro script running `set -e`, and line 70 is:
#     gzip -c "$U_BOOT" >>"${TARGET}.new"
# Every file in an ostree/composefs deployment has mtime 0 (timestamps are normalised at commit).
# GNU gzip calls that "file timestamp out of range for gzip format", warns, and exits 2 — so `set -e`
# kills update-m1n1 before boot.bin is written. Observed on hardware; the machine kept a stale
# devicetree, which breaks hardware the moment a kernel ships a changed one.

source "$(dirname "$0")/base-test.sh"

helper="$ROOT/images/core/files/usr/libexec/omarchy-apply-m1n1"
[[ -f $helper ]] || fail "the apply-m1n1 helper ships"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

blob="$test_tmp/u-boot-nodtb.bin"
head -c 2048 /dev/urandom >"$blob"
touch -d @0 "$blob" || fail "can set an mtime of 0 for the test fixture"

# The premise. If a future gzip stops exiting non-zero here the workaround becomes redundant rather
# than wrong, so report instead of failing — but the assertions below must still hold.
if gzip -c "$blob" >/dev/null 2>&1; then
  pass "gzip no longer rejects a zero mtime on this host (workaround now redundant, still correct)"
else
  pass "gzip rejects a zero mtime — the failure mode this helper works around"
fi

OMARCHY_APPLY_M1N1_LIB=1 source "$helper"

staged=$(stage_gzip_safe_uboot "$blob") || fail "stage_gzip_safe_uboot succeeds"
[[ -f $staged ]] || fail "stage_gzip_safe_uboot produces a file" "got: ${staged:-<empty>}"
pass "stage_gzip_safe_uboot produces a file"

cmp -s "$blob" "$staged" || fail "the staged copy is byte-identical to the blob"
pass "the staged copy is byte-identical to the blob"

# The point of the whole exercise: gzip must accept the copy.
if gzip -c "$staged" >/dev/null 2>&1; then
  pass "gzip accepts the staged copy (exit 0, no warning)"
else
  fail "gzip accepts the staged copy" "gzip still exits $? — mtime: $(stat -c %Y "$staged" 2>/dev/null)"
fi

(( $(stat -c %Y "$staged" 2>/dev/null || echo 0) > 0 )) || fail "the staged copy has a real mtime"
pass "the staged copy has a real mtime"

rm -rf "$(dirname "$staged")"

# And the copy has to actually reach update-m1n1: it reads a fixed path, so the helper bind-mounts
# the staged file over the original. Without this the staging above would be dead code.
grep -q 'mount --bind' "$helper" || fail "the helper bind-mounts the staged copy over the blob"
grep -q 'unshare --mount' "$helper" || fail "the bind mount is confined to a private namespace"
grep -q 'run_update_m1n1' "$helper" || fail "the refresh path calls update-m1n1 through the wrapper"
pass "the staged copy is bind-mounted over the blob for update-m1n1"
