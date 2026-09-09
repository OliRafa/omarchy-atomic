#!/usr/bin/env bash
# REAL-bootc integration test for the Asahi install wrapper's ESP copy/replace. CI/root only:
# needs loop devices, mounts, and a built image. Complements the pure-bash esp-backup.test.sh by
# running esp_backup/esp_restore around an ACTUAL `bootc install`.
#
# Confirmed from bootc source (crates/lib/src/install.rs): `to-existing-root` defaults
# --replace=alongside (:523), and Alongside runs clean_boot_directories() which empties /boot AND
# the ESP (:2374, "TODO: we should also support not wiping the ESP"). So a real install WIPES the
# whole ESP — the preboot layer (m1n1/vendorfw/asahi/ubootefi.var) is gone unless we restore it.
#
# Why to-filesystem (not to-existing-root): to-existing-root reimages the host it runs on, and the
# CI runner isn't Asahi (no ESP/m1n1/device-tree) — so it can't run here. `to-filesystem` with
# --replace=alongside takes the SAME clean_boot_directories() path, so it faithfully reproduces the
# ESP wipe on a throwaway loopback disk, sparing the runner. We pre-populate the ESP to mimic a real
# Asahi ESP (m1n1/vendorfw/asahi/ubootefi.var + an OLD bootloader), then prove esp_backup/esp_restore
# bring the preboot layer back and never let the old bootloader clobber bootc's systemd-boot.
#
# Usage (root):  sudo env ENGINE=podman bash deploy/tests/esp-bootc-integration.sh <image-ref> [workdir]
set -euo pipefail

IMAGE="${1:?usage: esp-bootc-integration.sh <image-ref> [workdir]}"
WORK="${2:-${RUNNER_TEMP:-/var/tmp}/esp-int}"
ENGINE="${ENGINE:-podman}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/esp-backup.sh
. "$here/../lib/esp-backup.sh"

[ "$(id -u)" = 0 ] || { echo "run as root (loop devices + mounts)"; exit 1; }

disk="$WORK/disk.raw"; target="$WORK/target"; bk="$WORK/bk"; esp="$target/boot/efi"; loop=""
cleanup() {
  set +e
  umount -R "$target" 2>/dev/null
  [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null
  rm -f "$disk"
}
trap cleanup EXIT
rm -rf "$WORK"; mkdir -p "$WORK" "$target"

echo "== 1) create + partition a throwaway 20G disk (p1=ESP vfat, p2=root btrfs) =="
# Partition the FILE first, then attach with -P so ${loop}p1/p2 appear without a re-read dance.
truncate -s 20G "$disk"
sgdisk -Z "$disk" >/dev/null
sgdisk -n1:0:+512M -t1:EF00 -c1:EFI  "$disk" >/dev/null
sgdisk -n2:0:0     -t2:8300 -c2:root "$disk" >/dev/null
loop="$(losetup -Pf --show "$disk")"; echo "   loop: $loop"
udevadm settle 2>/dev/null || true
mkfs.vfat -F32 "${loop}p1" >/dev/null
mkfs.btrfs -f  "${loop}p2" >/dev/null

echo "== 2) mount target root + ESP; pre-populate a fake Asahi ESP =="
mount "${loop}p2" "$target"
mount --make-rshared "$target"          # so the ESP submount propagates into the install container
mkdir -p "$esp"
mount "${loop}p1" "$esp"
mkdir -p "$esp/m1n1" "$esp/vendorfw" "$esp/asahi/extras" "$esp/EFI/BOOT"
printf 'M1N1-STAGE2-ORIG'     > "$esp/m1n1/boot.bin"
printf 'VENDOR-FW-ORIG'       > "$esp/vendorfw/firmware.cpio"
printf 'FW-SOURCE-TARBALL'    > "$esp/asahi/all_firmware.tar.gz"
printf '{"vgid":"TEST-VGID"}' > "$esp/asahi/stub_info.json"
printf 'UBOOT-VARS'           > "$esp/ubootefi.var"
printf 'OLD-GRUB-BOOTAA64'    > "$esp/EFI/BOOT/BOOTAA64.EFI"   # the OLD bootloader
sync

echo "== 3) esp_backup the pre-populated ESP =="
esp_backup "$esp" "$bk"
echo "   backup entries:"; ls -A "$bk" | sed 's/^/     /'

echo "== 4) REAL bootc install to-filesystem (composefs + systemd-boot) =="
# --replace=alongside is what `to-existing-root` defaults to (bootc install.rs:523), and it's the
# mode that triggers clean_boot_directories() — which empties /boot AND the ESP (install.rs:2374,
# "TODO: we should also support not wiping the ESP"). So this faithfully reproduces the ESP wipe our
# wrapper's `to-existing-root` performs. Without it (the None branch just requires an empty root),
# bootc would NOT wipe the ESP and the test wouldn't exercise the reformat path.
$ENGINE run --rm --privileged --pid=host --security-opt label=type:unconfined_t \
  -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
  -v "$target:$target:rshared" \
  "$IMAGE" \
  bootc install to-filesystem \
    --composefs-backend --bootloader systemd \
    --generic-image --skip-fetch-check \
    --replace=alongside --acknowledge-destructive \
    "$target"

echo "== 5) observe: did bootc REFORMAT the ESP, or WRITE INTO it? =="
if [ -e "$esp/m1n1/boot.bin" ]; then
  echo "   >>> RESULT: bootc WROTE INTO the ESP (preboot layer survived install)"
else
  echo "   >>> RESULT: bootc REFORMATTED the ESP (preboot wiped — restore is REQUIRED for boot)"
fi
echo "   --- ESP after install (pre-restore) ---"; find "$esp" -maxdepth 2 2>/dev/null | sort | sed 's/^/     /'

echo "== 6) esp_restore, then assert preboot preserved + systemd-boot intact =="
esp_restore "$esp" "$bk"

fail=0
pass_(){ printf '   \033[32mOK\033[0m   %s\n' "$1"; }
fail_(){ printf '   \033[31mFAIL %s\033[0m\n' "$1"; fail=1; }
cmp_(){ [ "$(cat "$2" 2>/dev/null)" = "$3" ] && pass_ "$1" || fail_ "$1"; }

cmp_ "m1n1/boot.bin preserved"        "$esp/m1n1/boot.bin"             'M1N1-STAGE2-ORIG'
cmp_ "vendorfw preserved"             "$esp/vendorfw/firmware.cpio"    'VENDOR-FW-ORIG'
cmp_ "asahi/ firmware source kept"    "$esp/asahi/all_firmware.tar.gz" 'FW-SOURCE-TARBALL'
cmp_ "asahi/ VGID identity kept"      "$esp/asahi/stub_info.json"      '{"vgid":"TEST-VGID"}'
cmp_ "ubootefi.var kept"              "$esp/ubootefi.var"              'UBOOT-VARS'
[ -e "$esp/EFI/BOOT/BOOTAA64.EFI" ]           && pass_ "systemd-boot at EFI/BOOT/BOOTAA64.EFI" || fail_ "EFI/BOOT/BOOTAA64.EFI missing"
[ -e "$esp/EFI/systemd/systemd-bootaa64.efi" ] && pass_ "systemd-boot at EFI/systemd"          || fail_ "EFI/systemd/systemd-bootaa64.efi missing"
grep -rq OLD-GRUB "$esp/EFI" 2>/dev/null      && fail_ "old GRUB leaked into EFI/"             || pass_ "no old-GRUB remnant under EFI/"
# Informational: kernel staging is bootc's job, strictly asserted by the to-disk test elsewhere.
if find "$esp/EFI/Linux" -name 'vmlinuz*' 2>/dev/null | grep -q .; then
  pass_ "kernel staged under EFI/Linux"
else
  printf '   \033[2m··\033[0m   kernel not under EFI/Linux (informational)\n'
fi

echo
[ "$fail" = 0 ] && echo "BOOTC ESP INTEGRATION: PASS" || echo "BOOTC ESP INTEGRATION: FAIL"
exit "$fail"
