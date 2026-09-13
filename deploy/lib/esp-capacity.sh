#!/usr/bin/env bash
# ESP capacity arithmetic for the composefs + systemd-boot install (deploy/omarchy-atomic-install).
#
# Under the composefs backend the kernel and initramfs live ON THE ESP. bootc locates the ESP by
# GPT type GUID (`find_first_colocated_esp`, crates/blockdev) and writes
# <ESP>/EFI/Linux/bootc_composefs-<digest>/{vmlinuz,initrd}. It does NOT use a separate /boot:
# crates/lib/src/bootc_composefs/boot.rs carries the explicit upstream TODO
#
#   "TODO: support XBOOTLDR. Per BLS, the ESP should be mounted at /efi when a separate XBOOTLDR
#    partition is present at /boot. bootc does not yet detect or use XBOOTLDR in the composefs
#    install path, so unconditionally mount the ESP at /boot for now."
#
# and this was confirmed on hardware: a 1 GiB partition typed BC13C2FF-… (XBOOTLDR), formatted
# VFAT and mounted at /boot via the boot entry's own systemd.mount-extra karg, was ignored —
# `bootc upgrade` still wrote to the 500 MiB ESP and died with ENOSPC.
#
# That matters because the Asahi installer sizes the ESP for m1n1 + U-Boot + GRUB, not for
# kernels: 500 MiB, of which ~126 MiB is already spent on m1n1/, vendorfw/ and asahi/. In the
# stock ostree layout kernels live on a separate 1 GiB /boot, so the ESP never sees them. Under
# composefs it holds all of them, and an UPGRADE needs room for TWO deployments at once — bootc
# writes the new entry before it collects the old one. With Fedora Asahi's ~195 MiB initramfs
# that is ~424 MiB of payload against ~373 MiB usable, so the install succeeds and every later
# `bootc upgrade` fails:
#
#   error: Upgrading composefs: … Setting up BLS boot: … Writing initrd to path:
#          No space left on device (os error 28)
#
# A machine that installs but can never update is worse than one that refuses to install, so the
# wrapper measures this up front. deploy/omarchy-atomic-grow-esp is the fix on an already-Asahi
# machine (absorb the now-useless /boot partition into the ESP).
#
# These helpers are deliberately thin over numbers the caller measures, so the decision is
# unit-testable off-hardware; see deploy/tests/esp-capacity.test.sh.

# Default retention: bootc keeps the booted deployment and the new one during an upgrade.
ESP_DEPLOYMENTS="${ESP_DEPLOYMENTS:-2}"
# systemd-boot itself (EFI/BOOT + EFI/systemd ≈ 200 KiB), loader/entries, and FAT cluster slack
# across two deployment directories. 16 MiB is generous on purpose: being wrong in this direction
# costs a warning, being wrong in the other costs an unbootable upgrade.
ESP_SLACK_BYTES="${ESP_SLACK_BYTES:-$((16 * 1024 * 1024))}"

# esp_payload_bytes [ROOT] — size of one deployment's boot payload: the largest
# vmlinuz + initramfs.img pair under ROOT/usr/lib/modules/*/. Prints bytes (0 if none found).
# Run inside the IMAGE to size what an install is about to write; run on the host to size what a
# running system already has.
esp_payload_bytes() {
  local root="${1:-}" kdir f sz total best=0
  for kdir in "$root"/usr/lib/modules/*/; do
    [ -e "$kdir/vmlinuz" ] || continue
    total=0
    for f in vmlinuz initramfs.img; do
      [ -e "$kdir$f" ] || continue
      sz="$(stat -Lc %s "$kdir$f" 2>/dev/null)" || continue
      total=$((total + sz))
    done
    [ "$total" -gt "$best" ] && best=$total
  done
  printf '%s\n' "$best"
}

# esp_required_bytes PAYLOAD [DEPLOYMENTS] [SLACK] — bytes bootc needs on the ESP.
esp_required_bytes() {
  local payload="$1" deployments="${2:-$ESP_DEPLOYMENTS}" slack="${3:-$ESP_SLACK_BYTES}"
  printf '%s\n' "$((payload * deployments + slack))"
}

# esp_usable_bytes ESP — bytes bootc may spend on the mounted ESP at ESP: the current free space
# PLUS whatever EFI/ already occupies. EFI/ is bootc's own to rewrite, so its present contents are
# not a constraint; everything else on the ESP (m1n1/, vendorfw/, asahi/, ubootefi.var) is, and
# stays counted as used. Uses allocated size, not apparent size — FAT cluster slack is real space.
esp_usable_bytes() {
  local esp="$1" free efi=0
  [ -d "$esp" ] || { echo "esp_usable_bytes: $esp is not a directory" >&2; return 1; }
  free="$(df -B1 --output=avail "$esp" 2>/dev/null | tail -1 | tr -dc '0-9')" || return 1
  [ -n "$free" ] || { echo "esp_usable_bytes: could not read free space on $esp" >&2; return 1; }
  if [ -d "$esp/EFI" ]; then
    efi="$(du -s --block-size=1 "$esp/EFI" 2>/dev/null | cut -f1)"
    [ -n "$efi" ] || efi=0
  fi
  printf '%s\n' "$((free + efi))"
}

# esp_mib BYTES — bytes as whole MiB, for messages.
esp_mib() { printf '%s\n' "$(( ${1:-0} / 1024 / 1024 ))"; }

# esp_capacity_report USABLE REQUIRED PAYLOAD [DEPLOYMENTS] — print the arithmetic.
# Returns 0 when the ESP can hold DEPLOYMENTS deployments, 1 when it cannot.
esp_capacity_report() {
  local usable="$1" required="$2" payload="$3" deployments="${4:-$ESP_DEPLOYMENTS}"
  printf '==> ESP capacity: %s MiB usable; %s deployments x %s MiB payload + %s MiB slack = %s MiB needed\n' \
    "$(esp_mib "$usable")" "$deployments" "$(esp_mib "$payload")" \
    "$(esp_mib "$ESP_SLACK_BYTES")" "$(esp_mib "$required")"
  [ "$usable" -ge "$required" ]
}
