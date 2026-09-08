#!/usr/bin/env bash
# Container smoke test for the omarchy-atomic CORE image.
#
# Runs the built image as a container and asserts the userspace a correct build must
# produce — WITHOUT booting. (The Fedora Asahi kernel-16k only boots on real Apple
# Silicon, so a generic VM boot test isn't possible; boot-time state is covered by the
# separate boot-smoke harness in hack/boottest/, run on-hardware.)
#
# Runnable on any aarch64 host with docker/podman:
#   ./images/core/hack/smoke.sh [IMAGE]        # default omarchy-atomic-core:44
#   ENGINE=podman ./images/core/hack/smoke.sh
set -euo pipefail
IMAGE="${1:-omarchy-atomic-core:44}"
ENGINE="${ENGINE:-docker}"

echo "== smoke-testing image: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }

echo "== Fedora Asahi base (Apple Silicon) =="
# Note: use `rpm -q <pkg>` (not `rpm -qa | grep -q`) — under `set -o pipefail`, grep -q's
# early exit SIGPIPEs rpm -qa and the pipeline reports failure even on a match.
[ "$(uname -m)" = aarch64 ] && ok "aarch64" || no "not aarch64: $(uname -m)"
rpm -q kernel-16k >/dev/null 2>&1 && ok "kernel-16k (Asahi kernel)" || no "kernel-16k missing — wrong base"
rpm -q asahi-platform-metapackage >/dev/null 2>&1 && ok "asahi-platform-metapackage" || no "asahi platform packages missing"

echo "== kernel + bootloader (image) =="
n=$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | wc -l)
[ "$n" = 1 ] && ok "exactly one kernel in /usr/lib/modules" || no "expected 1 kernel in /usr/lib/modules, found $n"
rpm -q systemd-boot-unsigned >/dev/null 2>&1 && ok "systemd-boot-unsigned installed" || no "systemd-boot-unsigned missing"
# grub2/bootupd may remain (held by asahi-platform-metapackage) — harmless, since the
# bootloader is selected at install time via --bootloader systemd. The authoritative "no grub"
# check is the install-to-disk ESP assertion in core-image-e2e.yml.

echo "== core desktop packages =="
for p in hyprland quickshell uwsm sddm NetworkManager pipewire wireplumber fcitx5 qt6-qtimageformats glycin-loaders; do
  rpm -q "$p" >/dev/null 2>&1 && ok "$p" || no "$p missing"
done

echo "== docker/moby kept in core (by decision) =="
rpm -q moby-engine >/dev/null 2>&1 && ok "moby-engine" || no "moby-engine missing"

echo "== native-in-core apps (not Flathub / not brew) =="
for p in nautilus mpv gnome-disk-utility; do
  rpm -q "$p" >/dev/null 2>&1 && ok "$p" || no "$p missing from core"
done

echo "== omarchy tree + commands on PATH =="
[ -d /usr/share/omarchy/bin ] && ok "/usr/share/omarchy tree present" || no "omarchy tree missing"
[ -L /usr/bin/omarchy ] && ok "omarchy symlinked into /usr/bin" || no "omarchy not symlinked into /usr/bin"
command -v omarchy-launch-webapp >/dev/null 2>&1 && ok "omarchy commands resolve on PATH" || no "omarchy commands not on PATH"

echo "== core first-party tools in /usr/bin (NOT the /usr/local symlink) =="
for b in tensaku voxtype try hyprland-preview-share-picker; do
  [ -e "/usr/bin/$b" ] && ok "/usr/bin/$b" || no "/usr/bin/$b missing"
done
[ -L /usr/local ] && ok "/usr/local is still a symlink (nothing leaked there)" || no "/usr/local is not a symlink"

echo "== preinstall 'bloat' NOT baked into core (deferred to preinstalls image) =="
for b in aether cliamp omacut omawrite; do
  [ -e "/usr/bin/$b" ] && no "$b is baked in — belongs in the preinstalls image" || ok "$b absent from core"
done

echo "== profile.d hooks =="
[ -f /etc/profile.d/omarchy-path.sh ] && ok "omarchy-path.sh" || no "omarchy-path.sh missing"
[ -f /etc/profile.d/omarchy-brew.sh ] && ok "omarchy-brew.sh (brew shellenv)" || no "omarchy-brew.sh missing"

echo "== mimeapps repoints (browser=Brave, images=Loupe) =="
mimes=/usr/share/omarchy/default/applications/mimeapps.list
grep -q 'com.brave.Browser.desktop' "$mimes" 2>/dev/null && ok "http(s) -> Brave" || no "browser mime not repointed"
grep -q 'org.gnome.Loupe.desktop'   "$mimes" 2>/dev/null && ok "images -> Loupe"  || no "image mime not repointed"

echo "== Asahi m1n1 / devicetree (atomic) =="
grep -Eq 'DTBS=.*/usr/lib/modules/.*dtb' /etc/sysconfig/update-m1n1 2>/dev/null \
  && ok "update-m1n1 DTBS -> image devicetree" || no "update-m1n1 DTBS not pointed at /usr/lib/modules"
command -v update-m1n1 >/dev/null 2>&1 && ok "update-m1n1 present (m1n1 stage-2 refresh)" || no "update-m1n1 missing"
# firmware tool name is distro-dependent (Fedora: asahi-fwupdate, Arch: asahi-fwextract); absence
# is non-fatal (vendorfw is left in place, refreshed opt-in).
if command -v asahi-fwupdate >/dev/null 2>&1 || command -v asahi-fwextract >/dev/null 2>&1; then
  ok "asahi firmware tool present (vendorfw refresh)"
else
  echo "  - asahi firmware tool absent — vendorfw left in place (ok)"
fi
[ -x /usr/libexec/omarchy-apply-m1n1 ] && ok "omarchy-apply-m1n1 helper present" || no "omarchy-apply-m1n1 missing"
[ -L /etc/systemd/system/multi-user.target.wants/omarchy-apply-m1n1.service ] \
  && ok "omarchy-apply-m1n1.service enabled" || no "omarchy-apply-m1n1.service not enabled"

echo
if [ "$fail" = 0 ]; then echo "CONTAINER SMOKE: PASS"; else echo "CONTAINER SMOKE: FAIL"; fi
exit "$fail"
CHECKS
