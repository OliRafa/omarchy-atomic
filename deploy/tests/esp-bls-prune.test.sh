#!/usr/bin/env bash
# Unit test for deploy/lib/esp-bls-prune.sh — removing the half-written boot entry an interrupted
# `bootc upgrade` leaves on the ESP. Pure filesystem: no root, no block device, no hardware.
#
# Hit on hardware, twice over. The first ENOSPC upgrade wrote
# <ESP>/EFI/Linux/bootc_composefs-<verity>/vmlinuz (17 MiB) and then ran out of room writing initrd.
# After the ESP was grown to 1.5 GiB the upgrade still failed, now with
#
#   error: Upgrading composefs: … Checking boot entry duplicates: Computing boot digest for Type1
#          entries: Opening initrd: No such file or directory (os error 2)
#
# because bootc's find_vmlinuz_initrd_duplicate() hashes vmlinuz + initrd in EVERY
# bootc_composefs-* directory before writing anything. One corpse wedges the machine permanently,
# and freeing space does not help.
#
# Run: bash deploy/tests/esp-bls-prune.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/esp-bls-prune.sh
. "$here/../lib/esp-bls-prune.sh"

pass=0 fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }
is(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$2', got '$3')"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

GOOD="bootc_composefs-aaaa1111"   # the booted deployment — complete, must survive
PART="bootc_composefs-bbbb2222"   # the ENOSPC corpse — vmlinuz only

mkesp() {
  local esp="$tmp/esp"
  rm -rf "$esp"
  mkdir -p "$esp/EFI/Linux/$GOOD" "$esp/loader/entries" "$esp/m1n1"
  printf 'VMLINUZ\n' > "$esp/EFI/Linux/$GOOD/vmlinuz"
  printf 'INITRD\n'  > "$esp/EFI/Linux/$GOOD/initrd"
  printf 'M1N1\n'    > "$esp/m1n1/boot.bin"
  printf 'title Fedora Linux 44\nlinux /EFI/Linux/%s/vmlinuz\ninitrd /EFI/Linux/%s/initrd\n' \
    "$GOOD" "$GOOD" > "$esp/loader/entries/bootc_fedora_asahi_remix-44-1.conf"
}

echo "== the hardware case: vmlinuz written, initrd never was"

mkesp
mkdir -p "$tmp/esp/EFI/Linux/$PART"
printf 'VMLINUZ\n' > "$tmp/esp/EFI/Linux/$PART/vmlinuz"
printf 'title Fedora Linux 44\nlinux /EFI/Linux/%s/vmlinuz\ninitrd /EFI/Linux/%s/initrd\n' \
  "$PART" "$PART" > "$tmp/esp/loader/entries/bootc_fedora_asahi_remix-44-2.conf"

is "the partial directory is identified" "$PART" "$(esp_partial_bls_dirs "$tmp/esp")"
if esp_prune_partial_bls "$tmp/esp" >/dev/null; then
  ok "reports that it pruned something"
else
  no "must report a removal"
fi
[ ! -e "$tmp/esp/EFI/Linux/$PART" ] && ok "the partial directory is gone" \
  || no "the partial directory must be deleted"
[ ! -e "$tmp/esp/loader/entries/bootc_fedora_asahi_remix-44-2.conf" ] \
  && ok "its loader entry is gone" || no "its loader entry must be deleted"

# The whole point of being conservative: the booted deployment must survive untouched.
[ -f "$tmp/esp/EFI/Linux/$GOOD/vmlinuz" ] && [ -f "$tmp/esp/EFI/Linux/$GOOD/initrd" ] \
  && ok "the complete deployment survives" || no "a complete deployment must never be pruned"
[ -f "$tmp/esp/loader/entries/bootc_fedora_asahi_remix-44-1.conf" ] \
  && ok "the booted loader entry survives" || no "the booted loader entry must survive"
[ -f "$tmp/esp/m1n1/boot.bin" ] && ok "the preboot layer is not touched" \
  || no "m1n1 must never be touched"

echo
echo "== the mirror case: initrd without vmlinuz"

mkesp
mkdir -p "$tmp/esp/EFI/Linux/$PART"
printf 'INITRD\n' > "$tmp/esp/EFI/Linux/$PART/initrd"
is "a directory missing vmlinuz is partial too" "$PART" "$(esp_partial_bls_dirs "$tmp/esp")"
esp_prune_partial_bls "$tmp/esp" >/dev/null || true
[ ! -e "$tmp/esp/EFI/Linux/$PART" ] && ok "it is pruned as well" || no "it must be pruned"

echo
echo "== an empty directory (died before writing anything)"

mkesp
mkdir -p "$tmp/esp/EFI/Linux/$PART"
is "an empty directory is partial" "$PART" "$(esp_partial_bls_dirs "$tmp/esp")"
esp_prune_partial_bls "$tmp/esp" >/dev/null || true
[ ! -e "$tmp/esp/EFI/Linux/$PART" ] && ok "it is pruned" || no "it must be pruned"

echo
echo "== a healthy ESP is left completely alone"

mkesp
is "nothing is identified as partial" "" "$(esp_partial_bls_dirs "$tmp/esp")"
before="$(find "$tmp/esp" | sort)"
if esp_prune_partial_bls "$tmp/esp" >/dev/null; then
  no "a healthy ESP must report nothing to do"
else
  ok "a healthy ESP reports nothing to do"
fi
is "and is byte-for-byte unchanged" "$before" "$(find "$tmp/esp" | sort)"

echo
echo "== things that are not ours"

mkesp
# A UKI or a hand-placed directory that does not carry the prefix is not bootc's Type1 layout and
# is not scanned by find_vmlinuz_initrd_duplicate — so it must not be scanned or deleted here.
mkdir -p "$tmp/esp/EFI/Linux/some-other-loader"
printf 'STUFF\n' > "$tmp/esp/EFI/Linux/some-other-loader/vmlinuz"
is "an unprefixed directory is ignored" "" "$(esp_partial_bls_dirs "$tmp/esp")"
esp_prune_partial_bls "$tmp/esp" >/dev/null || true
[ -d "$tmp/esp/EFI/Linux/some-other-loader" ] && ok "and survives the prune" \
  || no "an unprefixed directory must not be deleted"

# A file (not a directory) sitting where a UKI would live must not trip the glob.
printf 'UKI\n' > "$tmp/esp/EFI/Linux/${ESP_BLS_PREFIX}cccc3333.efi"
is "a UKI file is not a partial directory" "" "$(esp_partial_bls_dirs "$tmp/esp")"
[ -f "$tmp/esp/EFI/Linux/${ESP_BLS_PREFIX}cccc3333.efi" ] && ok "and is left in place" \
  || no "a UKI file must not be deleted"

echo
echo "== degenerate inputs"

rm -rf "$tmp/esp"; mkdir -p "$tmp/esp"
is "an ESP with no EFI/Linux yields nothing" "" "$(esp_partial_bls_dirs "$tmp/esp")"
if esp_prune_partial_bls "$tmp/esp" >/dev/null; then
  no "must report nothing to do"
else
  ok "an ESP with no EFI/Linux reports nothing to do"
fi

mkdir -p "$tmp/esp/EFI/Linux"
is "an empty EFI/Linux yields nothing (unmatched glob)" "" "$(esp_partial_bls_dirs "$tmp/esp")"

echo
printf 'esp-bls-prune: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
