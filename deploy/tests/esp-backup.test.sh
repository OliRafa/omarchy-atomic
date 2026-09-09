#!/usr/bin/env bash
# e2e test for deploy/lib/esp-backup.sh — the ESP "copy and replace" the Asahi install wrapper
# relies on. Pure filesystem: no root, no podman, no hardware — runs anywhere (incl. CI x86).
#
# We can't run the real `bootc install to-existing-root` here (it overwrites the host, and needs a
# real Asahi root). But bootc isn't the risky part — our backup/restore is. So we build a fake ESP
# that mirrors a real one, then STUB the two things `bootc install` can do to it and assert the
# copy/replace does the right thing in each case:
#   1. REFORMAT  — bootc wipes the ESP and writes a fresh EFI/ (systemd-boot). Restore must bring
#                  the preboot layer back WITHOUT clobbering the new EFI/.
#   2. IN-PLACE  — bootc leaves the ESP and just (re)writes EFI/. Restore must be a no-op.
# Crown jewel: the backup contains the OLD bootloader (EFI/) — restore must NEVER put it back over
# bootc's systemd-boot.
#
# Run: bash deploy/tests/esp-backup.test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/esp-backup.sh
. "$here/../lib/esp-backup.sh"

pass=0 fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=$((fail+1)); }
eq(){ [ "$(cat "$2" 2>/dev/null)" = "$1" ]; }   # eq CONTENT FILE

# A fake ESP mirroring a real Fedora/Asahi ESP layout (see the real one in deploy/README.md).
make_esp() {
  local esp="$1"; rm -rf "$esp"; mkdir -p "$esp"
  mkdir -p "$esp/m1n1";     printf 'M1N1-STAGE2-ORIG' > "$esp/m1n1/boot.bin"
  mkdir -p "$esp/vendorfw"; printf 'VENDOR-FW-ORIG'   > "$esp/vendorfw/firmware.cpio"
  mkdir -p "$esp/asahi/extras"                        # nested dir must round-trip
  printf 'FW-SOURCE-TARBALL'    > "$esp/asahi/all_firmware.tar.gz"   # vendorfw's only source
  printf '{"vgid":"TEST-VGID"}' > "$esp/asahi/stub_info.json"        # APFS volume-group identity
  printf 'UBOOT-VARS'       > "$esp/ubootefi.var"     # file at ESP root (not a dir)
  mkdir -p "$esp/.Trashes"                            # macOS dotfile — proves .[!.]* glob works
  mkdir -p "$esp/EFI/BOOT"; printf 'OLD-GRUB-BOOTAA64' > "$esp/EFI/BOOT/BOOTAA64.EFI"  # OLD loader
}

# What `bootc install --bootloader systemd` writes — same paths core-image-e2e.yml asserts on the
# real install-to-disk (EFI/BOOT/BOOTAA64.EFI + EFI/systemd/systemd-bootaa64.efi). Keep in sync.
write_systemd_boot() {
  local esp="$1"; mkdir -p "$esp/EFI/BOOT" "$esp/EFI/systemd" "$esp/EFI/Linux"
  printf 'SYSTEMD-BOOTAA64' > "$esp/EFI/BOOT/BOOTAA64.EFI"
  printf 'SYSTEMD-BOOT'     > "$esp/EFI/systemd/systemd-bootaa64.efi"
}

assert_preboot_intact() {
  local esp="$1"
  eq 'M1N1-STAGE2-ORIG'     "$esp/m1n1/boot.bin"           && ok "m1n1/boot.bin intact"          || no "m1n1/boot.bin missing/corrupt"
  eq 'VENDOR-FW-ORIG'       "$esp/vendorfw/firmware.cpio"  && ok "vendorfw intact"               || no "vendorfw missing/corrupt"
  eq 'FW-SOURCE-TARBALL'    "$esp/asahi/all_firmware.tar.gz" && ok "asahi/ firmware source kept" || no "asahi firmware source lost"
  eq '{"vgid":"TEST-VGID"}' "$esp/asahi/stub_info.json"    && ok "asahi/ VGID identity kept"     || no "asahi VGID identity lost"
  [ -d "$esp/asahi/extras" ] && ok "asahi/extras (nested dir) kept" || no "asahi/extras lost"
  eq 'UBOOT-VARS'           "$esp/ubootefi.var"            && ok "ubootefi.var kept"             || no "ubootefi.var lost"
  [ -d "$esp/.Trashes" ]     && ok ".Trashes (dotfile) round-tripped" || no ".Trashes dotfile lost"
}

assert_systemd_boot_won() {
  local esp="$1"
  eq 'SYSTEMD-BOOTAA64' "$esp/EFI/BOOT/BOOTAA64.EFI" \
    && ok "EFI/BOOT/BOOTAA64.EFI is systemd-boot (old GRUB did NOT clobber it)" \
    || no "EFI/BOOT/BOOTAA64.EFI is not systemd-boot — restore overwrote bootc's bootloader!"
  [ -f "$esp/EFI/systemd/systemd-bootaa64.efi" ] && ok "EFI/systemd present" || no "EFI/systemd missing"
  ! grep -rq 'OLD-GRUB' "$esp/EFI" 2>/dev/null && ok "no old-GRUB remnant anywhere under EFI/" || no "old GRUB leaked into EFI/"
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
esp="$tmp/esp"; bk="$tmp/bk"

echo "== scenario 1: bootc REFORMATS the ESP =="
make_esp "$esp"
esp_backup "$esp" "$bk"
rm -rf "$esp"; mkdir -p "$esp"        # bootc wipes it...
write_systemd_boot "$esp"             # ...and lays down systemd-boot
esp_restore "$esp" "$bk" >/dev/null
assert_preboot_intact "$esp"
assert_systemd_boot_won "$esp"

echo "== scenario 2: bootc WRITES INTO the ESP (no reformat) =="
make_esp "$esp"
esp_backup "$esp" "$bk"
write_systemd_boot "$esp"             # EFI/ replaced in place; preboot untouched
esp_restore "$esp" "$bk" >/dev/null
assert_preboot_intact "$esp"
assert_systemd_boot_won "$esp"

echo "== scenario 3: restore is idempotent (re-running the wrapper is safe) =="
esp_restore "$esp" "$bk" >/dev/null   # second run over the settled ESP
assert_preboot_intact "$esp"
assert_systemd_boot_won "$esp"

echo
if [ "$fail" = 0 ]; then echo "ESP BACKUP/RESTORE: PASS ($pass checks)"; else echo "ESP BACKUP/RESTORE: FAIL ($fail failed, $pass passed)"; fi
exit "$fail"
