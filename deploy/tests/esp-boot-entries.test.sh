#!/usr/bin/env bash
# Unit test for deploy/lib/esp-boot-entries.sh — the repair that keeps omarchy-atomic-grow-esp from
# leaving a machine in emergency mode. Pure filesystem: no root, no block device, no hardware.
#
# The failure it guards against is real and was hit on hardware: the ESP was grown by absorbing
# /dev/nvme0n1p5, but the live boot entry still carried
#   systemd.mount-extra=UUID=F062-5DEE:/boot:vfat:umask=0077,shortname=winnt,iocharset=ascii
# naming the partition that had just stopped existing. On the next boot systemd waits on a mount
# that can never appear, local-fs.target fails, and the machine drops to emergency mode — with the
# partition table already rewritten.
#
# Run: bash deploy/tests/esp-boot-entries.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/esp-boot-entries.sh
. "$here/../lib/esp-boot-entries.sh"

pass=0 fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1"$'\n'"      expected: $2"$'\n'"      actual:   $3"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

ESP_VOLID="1A2B-3C4D"     # the ESP's own FAT serial
GONE_VOLID="F062-5DEE"    # the absorbed partition's — must not survive anywhere

mkentry() { mkdir -p "$tmp/esp/loader/entries"; printf '%s\n' "$2" > "$tmp/esp/loader/entries/$1"; }
entry()   { cat "$tmp/esp/loader/entries/$1"; }

echo "== the hardware case: an entry naming the partition that is about to vanish"

rm -rf "$tmp/esp"
mkentry bootc.conf "title Fedora Linux 44
linux /EFI/Linux/bootc_composefs-abc/vmlinuz
initrd /EFI/Linux/bootc_composefs-abc/initrd
options root=UUID=9d1c-root rw composefs=abc boot=UUID=$GONE_VOLID systemd.mount-extra=UUID=$GONE_VOLID:/boot:vfat:umask=0077,shortname=winnt,iocharset=ascii"

if esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null; then
  ok "reports that it changed something"
else
  no "must report a change"
fi
is "boot= now names the ESP, mount-extra is gone" \
"title Fedora Linux 44
linux /EFI/Linux/bootc_composefs-abc/vmlinuz
initrd /EFI/Linux/bootc_composefs-abc/initrd
options root=UUID=9d1c-root rw composefs=abc boot=UUID=$ESP_VOLID" \
"$(entry bootc.conf)"

# The repair is keyed on "not the ESP", not on the absorbed UUID, because by the time the table has
# been rewritten that partition is gone and its UUID can no longer be read.
if grep -q "$GONE_VOLID" "$tmp/esp/loader/entries/bootc.conf"; then
  no "the absorbed UUID must not survive anywhere in the entry"
else
  ok "the absorbed UUID is gone from the entry entirely"
fi

echo
echo "== an entry that is already correct must not be touched"

rm -rf "$tmp/esp"
clean="title Fedora Linux 44
options root=UUID=9d1c-root rw composefs=abc boot=UUID=$ESP_VOLID"
mkentry bootc.conf "$clean"
before="$(entry bootc.conf)"
if esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null; then
  no "an already-correct entry must report no change"
else
  ok "an already-correct entry reports no change"
fi
is "and is byte-identical afterwards" "$clean" "$before"
is "still byte-identical on disk" "$clean" "$(entry bootc.conf)"

# Case must not matter: blkid prints FAT serials uppercase, entries are sometimes hand-edited.
rm -rf "$tmp/esp"
mkentry bootc.conf "options rw boot=UUID=${ESP_VOLID,,}"
if esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null; then
  no "a lowercase spelling of the ESP's own volid is not foreign"
else
  ok "the ESP's own volid is recognised case-insensitively"
fi

echo
echo "== several entries, several strays"

rm -rf "$tmp/esp"
mkentry a.conf "options rw boot=UUID=$GONE_VOLID"
mkentry b.conf "options rw boot=UUID=$ESP_VOLID systemd.mount-extra=UUID=DEAD-BEEF:/boot:vfat:defaults"
mkentry c.conf "options rw root=UUID=9d1c-root"
esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null || true
is "entry with a stray boot= is fixed"          "options rw boot=UUID=$ESP_VOLID" "$(entry a.conf)"
is "entry with only a stray mount-extra is fixed" "options rw boot=UUID=$ESP_VOLID" "$(entry b.conf)"
is "entry naming neither is left alone"          "options rw root=UUID=9d1c-root"  "$(entry c.conf)"

# root=UUID= is the composefs root, on a different partition, and must never be rewritten — doing
# so would make the machine unbootable in a far worse way than the bug being fixed.
if grep -q 'root=UUID=9d1c-root' "$tmp/esp/loader/entries/c.conf"; then
  ok "root=UUID= is never touched"
else
  no "root=UUID= must never be rewritten"
fi

echo
echo "== degenerate inputs"

rm -rf "$tmp/esp"; mkdir -p "$tmp/esp"
if esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null; then
  no "an ESP with no loader/entries must report no change"
else
  ok "an ESP with no loader/entries reports no change, without erroring"
fi

rm -rf "$tmp/esp"; mkdir -p "$tmp/esp/loader/entries"
if esp_repoint_entries "$tmp/esp" "$ESP_VOLID" >/dev/null; then
  no "an empty entries directory must report no change"
else
  ok "an empty entries directory reports no change (unmatched glob is skipped)"
fi

echo
printf 'esp-boot-entries: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
