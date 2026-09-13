#!/usr/bin/env bash
# Unit test for deploy/lib/esp-capacity.sh — the "will `bootc upgrade` ever fit on this ESP?"
# arithmetic the install wrapper gates on. Pure filesystem + numbers: no root, no podman, no
# hardware, runs anywhere (incl. CI x86).
#
# The case that motivated this is a real machine: a 500 MiB Asahi ESP with ~126 MiB of preboot
# (m1n1/ + vendorfw/ + asahi/) and a ~212 MiB kernel payload per deployment. The install fits one
# deployment and every later upgrade dies with ENOSPC, because bootc writes the new deployment's
# vmlinuz + initrd before collecting the booted one. The regression this file guards: anything
# that makes the check pass in that configuration.
#
# Run: bash deploy/tests/esp-capacity.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/esp-capacity.sh
. "$here/../lib/esp-capacity.sh"

pass=0 fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }
is(){ # is DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi
}

MIB=$((1024 * 1024))
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

echo "== esp_payload_bytes: largest kernel + initramfs pair under /usr/lib/modules"

mkdir -p "$tmp/root/usr/lib/modules/6.16.0-asahi"
head -c $((17 * MIB)) /dev/zero > "$tmp/root/usr/lib/modules/6.16.0-asahi/vmlinuz"
head -c $((195 * MIB)) /dev/zero > "$tmp/root/usr/lib/modules/6.16.0-asahi/initramfs.img"
is "one kernel: vmlinuz + initramfs.img" "$((212 * MIB))" "$(esp_payload_bytes "$tmp/root")"

# Two kernels installed (a pending kernel update in the image): the ESP has to fit the biggest.
mkdir -p "$tmp/root/usr/lib/modules/6.17.0-asahi"
head -c $((17 * MIB)) /dev/zero > "$tmp/root/usr/lib/modules/6.17.0-asahi/vmlinuz"
head -c $((200 * MIB)) /dev/zero > "$tmp/root/usr/lib/modules/6.17.0-asahi/initramfs.img"
is "two kernels: the larger pair wins" "$((217 * MIB))" "$(esp_payload_bytes "$tmp/root")"

# A modules directory with no vmlinuz is not a bootable kernel; it must not be counted or crash.
mkdir -p "$tmp/root/usr/lib/modules/6.18.0-nokernel"
head -c $((500 * MIB)) /dev/zero > "$tmp/root/usr/lib/modules/6.18.0-nokernel/initramfs.img"
is "modules dir without vmlinuz is ignored" "$((217 * MIB))" "$(esp_payload_bytes "$tmp/root")"

mkdir -p "$tmp/empty"
is "no kernels at all is 0, not an error" "0" "$(esp_payload_bytes "$tmp/empty")"

echo
echo "== esp_required_bytes: two deployments have to coexist during an upgrade"

is "default is 2 deployments + slack" \
  "$((212 * MIB * 2 + ESP_SLACK_BYTES))" "$(esp_required_bytes $((212 * MIB)))"
is "deployment count is overridable" \
  "$((212 * MIB * 3 + ESP_SLACK_BYTES))" "$(esp_required_bytes $((212 * MIB)) 3)"
is "slack is overridable" "$((212 * MIB * 2))" "$(esp_required_bytes $((212 * MIB)) 2 0)"

echo
echo "== esp_capacity_report: the verdict"

# The machine this was written for. 373 MiB usable, 212 MiB per deployment -> must FAIL.
if esp_capacity_report $((373 * MIB)) "$(esp_required_bytes $((212 * MIB)))" $((212 * MIB)) >/dev/null; then
  no "500 MiB Asahi ESP with a 212 MiB payload must be rejected"
else
  ok "500 MiB Asahi ESP with a 212 MiB payload is rejected (the ENOSPC case)"
fi

# The same machine after omarchy-atomic-grow-esp folds the 1 GiB /boot in: 1397 MiB usable.
if esp_capacity_report $((1397 * MIB)) "$(esp_required_bytes $((212 * MIB)))" $((212 * MIB)) >/dev/null; then
  ok "grown 1.5 GiB ESP accepts the same payload"
else
  no "grown 1.5 GiB ESP should accept a 212 MiB payload"
fi

# Exactly enough must pass — an off-by-one here turns into a spurious refusal on a fine machine.
need="$(esp_required_bytes $((212 * MIB)))"
if esp_capacity_report "$need" "$need" $((212 * MIB)) >/dev/null; then
  ok "usable == required is accepted"
else
  no "usable == required must be accepted"
fi
if esp_capacity_report $((need - 1)) "$need" $((212 * MIB)) >/dev/null; then
  no "one byte short must be rejected"
else
  ok "one byte short is rejected"
fi

echo
echo "== esp_usable_bytes: free space plus EFI/, which bootc rewrites anyway"

mkdir -p "$tmp/esp/EFI/Linux/bootc_composefs-abc" "$tmp/esp/m1n1"
head -c $((4 * MIB)) /dev/zero > "$tmp/esp/EFI/Linux/bootc_composefs-abc/initrd"
head -c $((1 * MIB)) /dev/zero > "$tmp/esp/m1n1/boot.bin"
free_only="$(df -B1 --output=avail "$tmp/esp" | tail -1 | tr -dc '0-9')"
usable="$(esp_usable_bytes "$tmp/esp")"
if [ "$usable" -gt "$free_only" ]; then
  ok "EFI/ counts as reclaimable (usable > raw free)"
else
  no "EFI/ must count as reclaimable (usable=$usable, free=$free_only)"
fi
# m1n1/ is the preboot layer: bootc never touches it, so it must stay counted as used.
efi_alloc="$(du -s --block-size=1 "$tmp/esp/EFI" | cut -f1)"
is "usable is exactly free + EFI/ (m1n1 stays used)" "$((free_only + efi_alloc))" "$usable"

if esp_usable_bytes "$tmp/definitely-not-here" >/dev/null 2>&1; then
  no "a missing ESP path must fail, not report a number"
else
  ok "a missing ESP path fails loudly"
fi

echo
printf 'esp-capacity: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
