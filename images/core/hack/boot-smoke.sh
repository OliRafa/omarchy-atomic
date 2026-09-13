#!/usr/bin/env bash
# Boot smoke test for the omarchy-atomic CORE image. Baked into the CI/on-device overlay
# (hack/boottest/) and run at boot by omarchy-boottest.service, which reports over the
# serial console. Asserts the things a container inspection cannot: that the image
# actually booted on the Fedora Asahi kernel and brought its core services up.
#
# NOTE: unlike the amd64 ultron-os boot test, this cannot run in generic qemu — the
# Fedora Asahi kernel-16k is Apple-Silicon-specific. Run it on real Apple Silicon (after
# `bootc switch`) or an Asahi-capable VM. Exits non-zero on any failure.
set -uo pipefail

fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }

echo "== running kernel is the Fedora Asahi kernel =="
kver="$(uname -r)"
echo "  kernel: $kver"
echo "$kver" | grep -qiE '16k|asahi' && ok "Asahi kernel-16k is running" || no "not the Asahi kernel: $kver"

echo "== bootloader: systemd-boot (not GRUB) =="
# bootctl only searches /efi, /boot and /boot/efi for the ESP. On the Asahi layout where /boot is a
# separate ext4 partition the OS ESP is mounted nowhere, and two checks here went wrong because of
# it: `bootctl list` failed outright ("Couldn't find EFI system partition") on a machine that had
# booted perfectly, and the grub check passed VACUOUSLY — it tested paths under an ESP that was not
# mounted, so it would also have passed with grub all over it. Locate the ESP the way m1n1 and
# deploy/omarchy-atomic-install do (the device tree names the OS ESP) and mount it read-only if it
# is not mounted already.
esp="" esp_tmp=""
esp="$(bootctl --print-esp-path 2>/dev/null || true)"
if [ -z "$esp" ]; then
  esp_uuid="$(tr -d '\0' </proc/device-tree/chosen/asahi,efi-system-partition 2>/dev/null || true)"
  esp_dev="$(blkid -t "PARTUUID=$esp_uuid" -o device 2>/dev/null || true)"
  if [ -n "$esp_dev" ]; then
    esp="$(findmnt -no TARGET "$esp_dev" 2>/dev/null | head -1 || true)"
    if [ -z "$esp" ]; then
      esp_tmp="$(mktemp -d)"
      if mount -o ro "$esp_dev" "$esp_tmp" 2>/dev/null; then esp="$esp_tmp"; else rmdir "$esp_tmp"; esp_tmp=""; fi
    fi
  fi
fi
[ -n "$esp" ] && ok "OS ESP located at $esp" || no "OS ESP not found (bootctl, then asahi,efi-system-partition)"

# Capture before matching: this file runs under `set -o pipefail`, where `cmd | grep -q` reports
# failure when grep's early exit SIGPIPEs cmd — the trap that made hack/smoke.sh reject a good image.
if command -v bootctl >/dev/null 2>&1; then
  bootctl_status="$(bootctl status 2>/dev/null || true)"
  case $bootctl_status in
    *systemd-boot*) ok "systemd-boot is the active bootloader" ;;
    *)              no "systemd-boot not active (GRUB?)" ;;
  esac
else
  no "bootctl missing"
fi

# Assert on the entry files rather than bootctl's prose: a composefs install writes a Type #1 entry
# under loader/entries with its kernel under EFI/Linux, and bootctl cannot read either when the ESP
# is unmounted.
if [ -n "$esp" ] && { ls "$esp"/loader/entries/*.conf >/dev/null 2>&1 || ls "$esp"/EFI/Linux/*/vmlinuz >/dev/null 2>&1; }; then
  ok "a boot entry is present on the ESP"
else
  no "no boot entry on ${esp:-<no ESP>}"
fi

if [ -n "$esp" ]; then
  grub_found="$(find "$esp" -iname 'grub*.efi' -print -quit 2>/dev/null || true)"
  [ -z "$grub_found" ] && ok "no grub on ESP" || no "grub present on ESP: $grub_found"
else
  no "cannot check for grub — ESP not located"
fi

[ -n "$esp_tmp" ] && { umount "$esp_tmp" 2>/dev/null || true; rmdir "$esp_tmp" 2>/dev/null || true; }

echo "== core services =="
systemctl is-active --quiet sddm.service && ok "sddm (display manager) active" || no "sddm not active"
systemctl is-active --quiet NetworkManager.service && ok "NetworkManager active" || no "NetworkManager not active"
systemctl is-active --quiet bluetooth.service 2>/dev/null && ok "bluetooth active" || echo "  (bluetooth inactive — ok if no adapter)"

echo "== desktop stack present =="
for b in Hyprland hyprland quickshell uwsm; do
  command -v "$b" >/dev/null 2>&1 && { ok "$b present"; break; }
done
command -v quickshell >/dev/null 2>&1 && ok "quickshell present" || no "quickshell missing"

echo "== omarchy tree + commands =="
[ -d /usr/share/omarchy ] && ok "/usr/share/omarchy present" || no "omarchy tree missing"
command -v omarchy >/dev/null 2>&1 && ok "omarchy on PATH" || no "omarchy not on PATH"

echo "== core first-party tools =="
for b in tensaku voxtype try hyprland-preview-share-picker; do
  command -v "$b" >/dev/null 2>&1 && ok "$b" || no "$b missing"
done

echo "== m1n1 / devicetree applied for the running kernel =="
grep -Eq 'DTBS=.*/usr/lib/modules/.*dtb' /etc/sysconfig/update-m1n1 2>/dev/null \
  && ok "update-m1n1 DTBS -> image devicetree" || no "update-m1n1 DTBS not pointed at the image DT"
[ "$(cat /var/lib/omarchy/m1n1-applied 2>/dev/null)" = "$(uname -r)" ] \
  && ok "m1n1/devicetree applied for $(uname -r)" \
  || no "m1n1 not yet applied for the running kernel — reboot once (omarchy-apply-m1n1)"

echo "== immutability invariants =="
[ -L /usr/local ] && ok "/usr/local is a symlink (nothing baked there)" || no "/usr/local not a symlink"
enforce="$(getenforce 2>/dev/null || echo unknown)"
[ "$enforce" != Disabled ] && ok "SELinux: $enforce" || no "SELinux disabled"

echo
if [ "$fail" = 0 ]; then echo "BOOT SMOKE: PASS"; else echo "BOOT SMOKE: FAIL"; fi
exit "$fail"
