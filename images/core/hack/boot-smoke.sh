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
if command -v bootctl >/dev/null 2>&1; then
  bootctl status 2>/dev/null | grep -qi 'systemd-boot' && ok "systemd-boot is the active bootloader" || no "systemd-boot not active (GRUB?)"
  bootctl list 2>/dev/null | grep -qiE 'type #1|type #2' && ok "a boot entry is present" || no "no boot entry"
else
  no "bootctl missing"
fi
{ [ ! -e /boot/efi/EFI/fedora/grubaa64.efi ] && [ ! -e /boot/EFI/fedora/grubaa64.efi ]; } \
  && ok "no grub on ESP" || no "grub present on ESP"

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
