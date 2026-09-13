#!/usr/bin/env bash
# Unit test for deploy/lib/gpt-absorb.sh — the partition table omarchy-atomic-grow-esp is about to
# write. Text in, text out: no root, no block device, no hardware, runs anywhere (incl. CI x86).
#
# The stake is the whole machine. On Asahi, /proc/device-tree/chosen/asahi,efi-system-partition
# holds the ESP's PARTUUID and m1n1 stage 1 uses it to find <ESP>/m1n1/boot.bin, so a table that
# drops or changes a `uuid=` is an unbootable Mac reachable only from 1TR. Every assertion below
# is either "the ESP grew by exactly the right amount" or "nothing else moved".
#
# Run: bash deploy/tests/gpt-absorb.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/gpt-absorb.sh
. "$here/../lib/gpt-absorb.sh"

pass=0 fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

ESP_UUID="6F3E1C2A-1111-4444-8888-AAAABBBBCCCC"
# A real `sfdisk -d` dump shape from an Asahi machine: Apple's containers first (never touched),
# then the ESP, then the 1 GiB /boot that composefs makes useless, then the Linux root.
# 500 MiB ESP = 1024000 sectors; 1 GiB /boot = 2097152 sectors.
cat >"$tmp/dump" <<EOF
label: gpt
label-id: 8A4F0000-0000-0000-0000-000000000001
device: /dev/nvme0n1
unit: sectors
first-lba: 34
last-lba: 1953525134
sector-size: 512

/dev/nvme0n1p1 : start=        6, size=   259968, type=7C3457EF-0000-11AA-AA11-00306543ECAC, uuid=11111111-0000-0000-0000-000000000001, name="iBootSystemContainer"
/dev/nvme0n1p2 : start=   259974, size=194453504, type=7C3457EF-0000-11AA-AA11-00306543ECAC, uuid=22222222-0000-0000-0000-000000000002, name="Macintosh HD"
/dev/nvme0n1p3 : start=194713478, size=  1536000, type=5265636F-7665-11AA-AA11-00306543ECAC, uuid=33333333-0000-0000-0000-000000000003, name="Recovery"
/dev/nvme0n1p4 : start=196249478, size=  1024000, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=$ESP_UUID, name="EFI - FEDORA"
/dev/nvme0n1p5 : start=197273478, size=  2097152, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, uuid=55555555-0000-0000-0000-000000000005, name="boot"
/dev/nvme0n1p6 : start=199370630, size=754154496, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=66666666-0000-0000-0000-000000000006, name="root"
EOF

echo "== gpt_field: reading the dump"

is "start"        "196249478" "$(gpt_field /dev/nvme0n1p4 start "$tmp/dump")"
is "size"         "1024000"   "$(gpt_field /dev/nvme0n1p4 size  "$tmp/dump")"
is "uuid"         "$ESP_UUID" "$(gpt_field /dev/nvme0n1p4 uuid  "$tmp/dump")"
is "type"         "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" "$(gpt_field /dev/nvme0n1p4 type "$tmp/dump")"
is "quoted name with spaces" "EFI - FEDORA" "$(gpt_field /dev/nvme0n1p4 name "$tmp/dump")"
if gpt_field /dev/nvme0n1p9 start "$tmp/dump" >/dev/null 2>&1; then
  no "an absent partition must fail"
else
  ok "an absent partition fails, not silently empty"
fi
# `device: /dev/nvme0n1` in the header must not be mistaken for a partition line.
is "header lines are not partitions" "/dev/nvme0n1p1
/dev/nvme0n1p2
/dev/nvme0n1p3
/dev/nvme0n1p4
/dev/nvme0n1p5
/dev/nvme0n1p6" "$(gpt_nodes "$tmp/dump")"

echo
echo "== gpt_absorb_size: the ESP's new size in sectors"

new_size="$(gpt_absorb_size /dev/nvme0n1p4 /dev/nvme0n1p5 "$tmp/dump")"
is "500 MiB ESP + 1 GiB /boot = 1.5 GiB" "$((1024000 + 2097152))" "$new_size"
is "which is 1524 MiB" "1524" "$((new_size / 2048))"
is "and ends exactly where p6 starts" "199370630" "$((196249478 + new_size))"

# Growing backwards would silently eat the Apple recovery partition.
if gpt_absorb_size /dev/nvme0n1p4 /dev/nvme0n1p3 "$tmp/dump" >/dev/null 2>&1; then
  no "absorbing a partition BEFORE the ESP must be refused"
else
  ok "absorbing a partition before the ESP is refused"
fi
# Skipping over a partition would overwrite it.
if gpt_absorb_size /dev/nvme0n1p4 /dev/nvme0n1p6 "$tmp/dump" >/dev/null 2>&1; then
  no "absorbing past an intervening partition must be refused"
else
  ok "absorbing past an intervening partition (p5) is refused"
fi

# A gap between the ESP and the partition after it should be reclaimed, not skipped. Shift p5
# 10000 sectors later and shorten it by the same amount so it still ends where p6 begins: an
# implementation that only added the two partition sizes would come up 10000 sectors short.
sed 's|^/dev/nvme0n1p5 : start=197273478, size=  2097152|/dev/nvme0n1p5 : start=197283478, size=  2087152|' \
  "$tmp/dump" >"$tmp/gap"
is "an unallocated gap is reclaimed too" "$((199370630 - 196249478))" \
  "$(gpt_absorb_size /dev/nvme0n1p4 /dev/nvme0n1p5 "$tmp/gap")"

echo
echo "== gpt_absorb_table: the table that gets written"

gpt_absorb_table /dev/nvme0n1p4 /dev/nvme0n1p5 "$new_size" "$tmp/dump" >"$tmp/new"

is "the absorbed partition is gone" "0" "$(grep -c '^/dev/nvme0n1p5 ' "$tmp/new" || true)"
is "the ESP has the new size"       "$new_size" "$(gpt_field /dev/nvme0n1p4 size "$tmp/new")"
is "the ESP keeps its start"        "196249478" "$(gpt_field /dev/nvme0n1p4 start "$tmp/new")"
is "the ESP keeps its PARTUUID"     "$ESP_UUID" "$(gpt_field /dev/nvme0n1p4 uuid "$tmp/new")"
is "the ESP keeps its type GUID"    "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" "$(gpt_field /dev/nvme0n1p4 type "$tmp/new")"
is "the ESP keeps its name"         "EFI - FEDORA" "$(gpt_field /dev/nvme0n1p4 name "$tmp/new")"

# Apple's partitions and the Linux root must come through byte-identical.
untouched=1
for p in p1 p2 p3 p6; do
  before="$(grep "^/dev/nvme0n1$p " "$tmp/dump")"
  after="$(grep "^/dev/nvme0n1$p " "$tmp/new" || true)"
  [ "$before" = "$after" ] || { no "/dev/nvme0n1$p changed: '$before' -> '$after'"; untouched=0; }
done
[ "$untouched" = 1 ] && ok "p1/p2/p3 (Apple) and p6 (root) are byte-identical"

is "the dump header survives" "$(sed -n '1,7p' "$tmp/dump")" "$(sed -n '1,7p' "$tmp/new")"
is "exactly one partition line was removed" \
  "$(( $(grep -c '^/dev/nvme0n1p' "$tmp/dump") - 1 ))" "$(grep -c '^/dev/nvme0n1p' "$tmp/new")"

# The size substitution must not wander into another field. `start=` contains no `size=`, but a
# sloppy regex anchored on "size" would hit it — assert the total sector count moved by exactly
# the absorbed partition's size and nothing else.
before_total=0; after_total=0
while read -r node; do before_total=$((before_total + $(gpt_field "$node" size "$tmp/dump"))); done < <(gpt_nodes "$tmp/dump")
while read -r node; do after_total=$((after_total + $(gpt_field "$node" size "$tmp/new"))); done < <(gpt_nodes "$tmp/new")
is "total allocated sectors are unchanged" "$before_total" "$after_total"

echo
echo "== gpt_node_by_uuid: finding the ESP without trusting the kernel"

# This is how the tool locates the ESP after a failed BLKRRPART, when /dev/nvme0n1p4 can be missing
# from the kernel entirely while the GPT on disk is perfect. Observed on hardware.
is "finds the node by PARTUUID"        "/dev/nvme0n1p4" "$(gpt_node_by_uuid "$ESP_UUID" "$tmp/dump")"
is "case-insensitive (blkid vs sfdisk spelling)" "/dev/nvme0n1p4" \
  "$(gpt_node_by_uuid "${ESP_UUID,,}" "$tmp/dump")"
if gpt_node_by_uuid "00000000-0000-0000-0000-000000000000" "$tmp/dump" >/dev/null 2>&1; then
  no "an unknown PARTUUID must fail"
else
  ok "an unknown PARTUUID fails rather than guessing"
fi
# After the absorb the ESP must still answer to the same PARTUUID — that is the whole point.
is "still found in the rewritten table" "/dev/nvme0n1p4" "$(gpt_node_by_uuid "$ESP_UUID" "$tmp/new")"

is "gpt_partno on nvme"  "4"  "$(gpt_partno /dev/nvme0n1p4)"
is "gpt_partno past 9"   "12" "$(gpt_partno /dev/nvme0n1p12)"
is "gpt_partno on sd"    "2"  "$(gpt_partno /dev/sda2)"

echo
printf 'gpt-absorb: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
