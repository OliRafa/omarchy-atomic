#!/bin/bash
# Install the fork-vetted parts of the repo's etc/ tree. Upstream ships the
# whole tree in the Arch package, which drops it straight into /etc; the
# git-clone fork has no package, so nothing was installing any of it. Runs as
# root from install.sh (run_root), so no internal sudo.
#
# Deliberately NOT installed:
# - etc/nsswitch.conf and etc/systemd/resolved.conf.d/10-disable-multicast.conf:
#   written as a pair for Arch's avahi/nss-mdns split. Fedora's nsswitch.conf is
#   owned by authselect, and overwriting it while also silencing resolved's
#   multicast would break .local resolution. Fedora defaults stay.
# - etc/sddm.conf.d/*: install/login/sddm.sh writes the SDDM config it needs,
#   and DisplayServer=wayland would require sddm-wayland-generic, which the
#   package set does not carry.
# - etc/profile.d/omarchy.sh: config/system-files.sh installs it with the
#   clone path rewritten in.
# - etc/systemd/system/user@.service.d/: system-files.sh already installs the
#   same 5s-timeout drop-in from default/systemd.

omarchy_etc="$OMARCHY_PATH/etc"

install_etc() {
  install -Dm644 "$omarchy_etc/$1" "/etc/$1"
}

install_etc cups/cups-browsed.conf
install_etc cups/cups-files.conf
install_etc docker/daemon.json
install_etc fastfetch/config.jsonc
install_etc gnupg/dirmngr.conf
install_etc modprobe.d/omarchy-usb-autosuspend.conf
install_etc plymouth/plymouthd.conf
install_etc security/faillock.conf
install_etc sysctl.d/90-omarchy-file-watchers.conf
install_etc sysctl.d/99-omarchy-sysctl.conf
install_etc systemd/logind.conf.d/10-ignore-power-button.conf
install_etc systemd/resolved.conf.d/20-docker-dns.conf
install_etc systemd/system.conf.d/10-faster-shutdown.conf
install_etc systemd/system.conf.d/20-omarchy-nofile.conf
install_etc systemd/system/docker.service.d/no-block-boot.conf
install_etc systemd/system/plocate-updatedb.service.d/ac-only.conf
install_etc systemd/user.conf.d/20-omarchy-nofile.conf

# System kitty defaults. The shipped ~/.config/kitty/kitty.conf is upstream's
# minimal user template; the actual defaults (font, keybindings, socket-only
# remote control, tab bar) live here at /etc/xdg/kitty/kitty.conf, so this must
# land or a fresh desktop gets none of them.
install_etc xdg/kitty/kitty.conf

# Claude browser extension manifest, baked read-only. The shipped Chromium is the
# Flatpak org.chromium.Chromium, which reads external extensions from its Flatpak
# extension point (/var/lib/flatpak/extension), not /usr/share/*/extensions. This
# is the immutable payload; a tmpfiles.d symlink (image) / omarchy-install-chromium-claude
# (git-clone) exposes the directory to the sandbox. Removable external-update offer.
install_etc omarchy/chromium-extensions/aarch64/1/extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn.json

# Sudoers drop-ins get validated after the copy: one bad file under
# /etc/sudoers.d locks sudo for the whole machine. visudo may be absent at
# image-build time (the sudo package lands later), so only remove a file when
# visudo actually reports it invalid — never merely because visudo is missing,
# which would silently drop the vetted repo rules (e.g. omarchy-tzupdate).
for name in omarchy-passwd-tries omarchy-tzupdate; do
  install -Dm440 "$omarchy_etc/sudoers.d/$name" "/etc/sudoers.d/$name"
  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "/etc/sudoers.d/$name" >/dev/null; then
      rm -f "/etc/sudoers.d/$name"
      echo "[etc-files] WARNING: /etc/sudoers.d/$name failed visudo -c and was removed"
    fi
  else
    echo "[etc-files] NOTE: visudo unavailable; kept /etc/sudoers.d/$name unvalidated"
  fi
done

# The udev rules run omarchy commands from the Arch package path; rewrite them
# into the clone, the same way system-files.sh rewrites the systemd units.
# post-install/udev.sh reloads udev at the end of the install.
install -d /etc/udev/rules.d
for rule in "$omarchy_etc"/udev/rules.d/*.rules; do
  sed "s|/usr/bin/omarchy-|$OMARCHY_PATH/bin/omarchy-|g" "$rule" \
    >"/etc/udev/rules.d/$(basename "$rule")"
done
