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
# We drop rpm-ostree (composefs backend uses composefs-rs, not rpm-ostree) and bootupd (GRUB-only;
# its absence is how bootc selects systemd-boot). Report status — non-fatal, since a package held
# by asahi-platform-metapackage stays but is inert (--bootloader systemd is authoritative; the
# "no grub on ESP" guarantee is the install-to-disk assertion in core-image-e2e.yml).
for p in rpm-ostree bootupd grub2-efi-aa64; do
  rpm -q "$p" >/dev/null 2>&1 && echo "  - $p present (held by a dep; inert under systemd-boot)" || ok "$p removed"
done

# The initramfs must carry bootc's dracut module. With --composefs-backend the boot entry's cmdline
# is composefs=<digest>, and /usr/lib/bootc/initramfs-setup (from 51bootc) is what consumes it. The
# base image builds an ostree-only initramfs: ostree-prepare-root.service skips on
# ConditionKernelCommandLine=ostree, nothing reads composefs=, and the kernel mounts root= directly
# — booting the image's kernel against whatever /usr is on the disk. It installs cleanly and fails
# only on real hardware, so assert it here. Containerfile step 3c rebuilds the initramfs.
# No `| grep -q` here: under `set -o pipefail` grep -q's early exit SIGPIPEs lsinitrd and the
# pipeline reports failure even on a match — the same trap as the rpm -qa note above. Capture
# the listing and match it in the shell instead.
kver="$(basename "$(dirname "$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | head -1)")")"
initramfs_listing="$(lsinitrd "/usr/lib/modules/$kver/initramfs.img" 2>/dev/null || true)"
case $initramfs_listing in
  *bootc-root-setup.service*)
    ok "initramfs carries bootc-root-setup.service (composefs root pivot)" ;;
  *)
    no "initramfs has no bootc composefs root setup — a composefs install will boot the host's /usr" ;;
esac

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

echo "== first-boot user provisioning =="
[ -x /usr/libexec/omarchy-firstboot-user ] && ok "omarchy-firstboot-user helper present" || no "omarchy-firstboot-user missing"
[ -L /etc/systemd/system/multi-user.target.wants/omarchy-firstboot-user.service ] \
  && ok "omarchy-firstboot-user.service enabled" || no "omarchy-firstboot-user.service not enabled"
# No human user (uid>=1000) may be baked into the image — the account is a first-boot job.
if getent passwd | awk -F: '$3>=1000 && $3<65534 {f=1} END{exit !f}'; then
  no "a human user is baked into the image (must be created on first boot, not baked)"
else
  ok "no human user baked in (created on first boot)"
fi

echo "== baked Omarchy userland (skel + session + services) =="
[ -f /etc/skel/.bashrc ] && ok "/etc/skel/.bashrc seeded" || no "/etc/skel/.bashrc missing"
[ -d /etc/skel/.config/hypr ] && ok "/etc/skel/.config/hypr (desktop config → new users)" || no "/etc/skel/.config/hypr missing"
[ -f /etc/skel/.config/omarchy/branding/screensaver.txt ] && ok "/etc/skel branding seeded" || no "/etc/skel branding missing"
[ -f /etc/omarchy.conf ] && ok "/etc/omarchy.conf (session OMARCHY_PATH — else SDDM bounces)" || no "/etc/omarchy.conf missing"
[ -d /usr/share/sddm/themes/omarchy ] && ok "SDDM omarchy theme installed" || no "SDDM omarchy theme missing"
if [ -L /etc/systemd/system/display-manager.service ] || systemctl is-enabled sddm.service >/dev/null 2>&1; then
  ok "sddm enabled (display-manager)"
else
  no "sddm not enabled — no greeter would start"
fi
if [ "$(systemctl get-default 2>/dev/null)" = graphical.target ]; then
  ok "default target = graphical.target"
else
  no "default target != graphical.target ($(systemctl get-default 2>/dev/null))"
fi

echo
if [ "$fail" = 0 ]; then echo "CONTAINER SMOKE: PASS"; else echo "CONTAINER SMOKE: FAIL"; fi
exit "$fail"
CHECKS
