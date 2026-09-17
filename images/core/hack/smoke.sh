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

# grub2-common's boot-success units are meaningless under systemd-boot: they write a grubenv that
# does not exist, so grub-boot-success.service fails on every login and the desktop reports a failed
# unit. Masked in Containerfile step 3b2. Only reproducible on a booted system, so assert the mask.
for u in /etc/systemd/user/grub-boot-success.service \
         /etc/systemd/user/grub-boot-success.timer \
         /etc/systemd/system/grub-boot-indeterminate.service; do
  if [ "$(readlink -f "$u" 2>/dev/null)" = /dev/null ]; then
    ok "masked $(basename "$u")"
  else
    no "$(basename "$u") not masked — it fails under systemd-boot"
  fi
done

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

echo "== screensaver engine (tte) =="
# tte is PyPI-only (no Fedora package / no brew formula); without it omarchy-screensaver has nothing
# to render. Assert both the console script on PATH and that it actually runs (venv wired correctly).
command -v tte >/dev/null 2>&1 && tte --help >/dev/null 2>&1 \
  && ok "tte present and runnable" || no "tte missing or broken (screensaver would not render)"

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

# brew + flatpak provisioning is CORE, not preinstalls: core's mimeapps repoints (asserted below)
# and omarchy-default-editor depend on apps these services install. Neither can be baked into /usr
# (brew needs a writable user-owned prefix, flatpaks live in /var), so assert the first-boot wiring.
echo "== brew + flatpak first-boot provisioning (core dependencies) =="
[ -s /usr/share/omarchy-atomic/Brewfile ] && ok "Brewfile shipped" || no "Brewfile missing"
command -v flatpak >/dev/null 2>&1 && ok "flatpak present" || no "flatpak missing"
# The app set is Fedora/flatpak's upstream `flatpak preinstall`: a manifest + the CLI, run by our
# thin wrapper unit. Assert the manifest, the CLI, the baked remote, and the retry wiring.
flatpak preinstall --help >/dev/null 2>&1 && ok "flatpak preinstall CLI present" || no "flatpak preinstall CLI missing"
[ -s /usr/share/flatpak/preinstall.d/omarchy-atomic.preinstall ] \
  && ok "flatpak preinstall manifest shipped" || no "flatpak preinstall manifest missing"
# Flathub is baked in as a LOCAL file so remote-add needs no network (we mask NetworkManager-wait-online).
[ -s /etc/flatpak/remotes.d/flathub.flatpakrepo ] \
  && ok "flathub.flatpakrepo baked in" || no "flathub.flatpakrepo missing (remote-add would need the network)"
# Fedora's flatpak remote is masked so Flathub is the only source and preinstall resolves unambiguously.
[ "$(readlink -f /etc/systemd/system/flatpak-add-fedora-repos.service 2>/dev/null)" = /dev/null ] \
  && ok "flatpak-add-fedora-repos.service masked" || no "Fedora flatpak remote not masked (ambiguous resolution)"
[ -x /usr/libexec/omarchy-brew-setup ] && ok "/usr/libexec/omarchy-brew-setup" || no "/usr/libexec/omarchy-brew-setup missing"
for svc in omarchy-flatpak-preinstall omarchy-brew-setup; do
  [ -L "/etc/systemd/system/multi-user.target.wants/$svc.service" ] \
    && ok "$svc.service enabled" || no "$svc.service not enabled"
done
# The pulls need the network, which is masked out of network-online.target here, so the unit must
# retry rather than fail once at boot and give up until the next reboot.
grep -q '^Restart=on-failure' /usr/lib/systemd/system/omarchy-flatpak-preinstall.service \
  && ok "flatpak preinstall retries on failure" || no "flatpak preinstall would not retry a network failure"
# Nothing else updates the system Flatpaks, so the update timer must be enabled.
[ -L /etc/systemd/system/timers.target.wants/omarchy-flatpak-update.timer ] \
  && ok "flatpak update timer enabled" || no "flatpak update timer not enabled"

# Homebrew is PREBUILT in the image (ublue's brew image), not installed over the network at first
# boot. That is the whole reason the tarball is here: `bash -c "$(curl ...)"` exits 0 when the curl
# fails, so a first-boot install could — and did — leave a machine with no brew and no error worth
# the name. If the tarball is missing, brew provisioning cannot work at all.
echo "== brew ships prebuilt (ublue brew image) =="
[ -s /usr/share/homebrew.tar.zst ] && ok "homebrew.tar.zst shipped" || no "homebrew.tar.zst missing"
[ -f /usr/lib/systemd/system/brew-setup.service ] && ok "brew-setup.service (unpack)" \
  || no "brew-setup.service missing"
[ -L /etc/systemd/system/multi-user.target.wants/brew-setup.service ] \
  && ok "brew-setup.service enabled" || no "brew-setup.service not enabled"
# brew maintains itself on timers, independent of image updates — without these it only ever
# updates incidentally, when someone happens to run `brew install`.
for t in brew-update brew-upgrade; do
  [ -f "/usr/lib/systemd/system/$t.timer" ] && ok "$t.timer shipped" || no "$t.timer missing"
  [ -L "/etc/systemd/system/timers.target.wants/$t.timer" ] \
    && ok "$t.timer enabled" || no "$t.timer not enabled"
done
# The helper must no longer reach the network: that path is what kept failing.
grep -vE '^[[:space:]]*#' /usr/libexec/omarchy-brew-setup | grep -qE 'install\.sh|curl|wget' \
  && no "omarchy-brew-setup still downloads an installer" \
  || ok "omarchy-brew-setup does not download an installer"

echo "== profile.d hooks =="
[ -f /etc/profile.d/omarchy-path.sh ] && ok "omarchy-path.sh" || no "omarchy-path.sh missing"
# ublue's brew.sh replaces our old omarchy-brew.sh: it APPENDS brew to PATH rather than
# prepending, so brew's binaries cannot shadow system ones (dbus is their cited breakage).
[ -f /etc/profile.d/brew.sh ] && ok "brew.sh (brew shellenv, ublue)" || no "brew.sh missing"
grep -q 'PATH}:.*HOMEBREW_PREFIX' /etc/profile.d/brew.sh 2>/dev/null \
  && ok "brew is appended to PATH, not prepended" || no "brew.sh does not append brew to PATH"
[ -e /etc/profile.d/omarchy-brew.sh ] && no "the superseded omarchy-brew.sh is still shipped" \
  || ok "the superseded omarchy-brew.sh is gone"

echo "== mimeapps repoints (browser=Chromium, images=Loupe) =="
mimes=/usr/share/omarchy/default/applications/mimeapps.list
grep -q 'org.chromium.Chromium.desktop' "$mimes" 2>/dev/null && ok "http(s) -> Chromium" || no "browser mime not repointed"
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

echo "== baked etc/ tree (etc-files.sh) + new base packages =="
# The timezone menu runs 'sudo timedatectl' with no TTY, so it needs the NOPASSWD rule from the
# repo etc/ tree. etc-files.sh (Containerfile step 4b via fedora-image-userland.sh) installs it;
# without that step the repo etc/ never landed and the menu failed. This is the original bug.
if [ -f /etc/sudoers.d/omarchy-tzupdate ] && grep -q timedatectl /etc/sudoers.d/omarchy-tzupdate; then
  ok "/etc/sudoers.d/omarchy-tzupdate present (timezone menu has its NOPASSWD rule)"
else
  no "/etc/sudoers.d/omarchy-tzupdate missing — the timezone menu would fail without a TTY"
fi
# The shipped ~/.config/kitty/kitty.conf is minimal; the real defaults live in /etc/xdg, which
# etc-files.sh installs. socket-only is the secure remote-control default (never unrestricted).
if grep -q '^allow_remote_control socket-only' /etc/xdg/kitty/kitty.conf 2>/dev/null; then
  ok "/etc/xdg/kitty/kitty.conf shipped (socket-only remote control)"
else
  no "/etc/xdg/kitty/kitty.conf missing or not socket-only — kitty would ship no defaults"
fi
# Native-feature base packages added to the core set.
for p in vim-minimal cups-pk-helper; do
  rpm -q "$p" >/dev/null 2>&1 && ok "$p installed" || no "$p missing from core"
done
command -v vi >/dev/null 2>&1 && ok "vi on PATH (from vim-minimal)" || no "vi not on PATH"
# cups-pdf runs a print backend as root; the CUPS hardening removes it, so it must not be baked in.
rpm -q cups-pdf >/dev/null 2>&1 && no "cups-pdf present — the root PDF backend should be gone (CUPS hardening)" \
  || ok "cups-pdf absent (CUPS hardening)"

echo
if [ "$fail" = 0 ]; then echo "CONTAINER SMOKE: PASS"; else echo "CONTAINER SMOKE: FAIL"; fi
exit "$fail"
CHECKS
