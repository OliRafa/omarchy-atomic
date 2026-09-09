#!/usr/bin/env bash
# Bake the Omarchy USERLAND into the bootc image at build time.
#
# The base is a DE-less Fedora Asahi atomic image, and the Containerfile only lays down packages +
# the omarchy tree + first-boot provisioning. It does NOT run install.sh's system/user config, so a
# built image has: no display manager enabled, no /etc/skel, and no /etc/omarchy.conf — meaning a
# freshly-provisioned user boots to a bare (or bounced) session. This reproduces, at build time,
# what install.sh's config steps produce on a normal install:
#
#   1. system-files.sh  — SDDM theme, /etc/omarchy.conf (session-critical), uwsm/env.d, systemd user
#                         units, fontconfig, plymouth, /etc/skel {nautilus-python, branding}.
#   2. enable-services  — sddm + NetworkManager + resolved + oomd + power-profiles + docker.socket
#                         (+ mask NetworkManager-wait-online); best-effort per unit.
#   3. /etc/skel/.config — the shipped ~/.config tree (config/*), .bashrc, and login-shell env, so
#                          `useradd -m` seeds the desktop AND the first-login trigger
#                          (~/.config/hypr → default/hypr/autostart.lua → omarchy-provision-first-run).
#
# Reuses the upstream install/config/* scripts as the single source of truth. In the image
# OMARCHY_PATH=/usr/share/omarchy, so their `/usr/share/omarchy/`→$OMARCHY_PATH path-rewrites are
# no-ops. OMARCHY_INSTALL_USER is deliberately UNSET (no user exists at build) so the per-user home
# seeding self-skips and only /usr + /etc + /etc/skel are written.
set -uo pipefail

export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
OMARCHY_INSTALL="$OMARCHY_PATH/install"
unset OMARCHY_INSTALL_USER || true

say(){ printf '[image-userland] %s\n' "$1"; }

# 1) System files (default/ → /usr + /etc + /etc/skel). Its tail `systemctl daemon-reload` is a
#    no-op in the build (no live systemd) and is tolerated; nothing here needs a running manager.
say "system-files.sh (SDDM theme, /etc/omarchy.conf, uwsm/env.d, units, fontconfig, plymouth)"
bash "$OMARCHY_INSTALL/config/system-files.sh" || say "system-files.sh returned non-zero (tolerated)"

# 2) Service enablement + default target. `systemctl enable/set-default` work offline (symlinks);
#    units not installed (e.g. cups/avahi) fail individually inside the script and are skipped.
say "enable-services.sh + set-default graphical.target"
bash "$OMARCHY_INSTALL/config/enable-services.sh" || say "enable-services.sh returned non-zero (tolerated)"
# Belt-and-suspenders for the units the session can't boot without, independent of the upstream
# script's ordering/error handling (a missing optional unit like cups must not skip sddm).
systemctl enable sddm.service NetworkManager.service || say "critical enable had a miss (checked below)"
systemctl set-default graphical.target || say "set-default graphical.target failed (tolerated)"
# sddm is the greeter — its enablement is not optional; fail the build if it didn't take.
if [ ! -L /etc/systemd/system/display-manager.service ] \
   && ! systemctl is-enabled sddm.service >/dev/null 2>&1; then
  echo "[image-userland] FATAL: sddm.service is not enabled — no greeter would start" >&2
  exit 1
fi

# 3) /etc/skel: the shipped ~/.config tree + shell env (config.sh's user-seed, retargeted to skel).
say "/etc/skel: .config tree + .bashrc + login-shell env"
install -d /etc/skel/.config
cp -R "$OMARCHY_PATH"/config/* /etc/skel/.config/
cp -f "$OMARCHY_PATH/default/bashrc" /etc/skel/.bashrc
# Login shells (the SDDM Wayland session uses one) must export OMARCHY_PATH + ~/.local/bin.
cat >/etc/skel/.profile <<'PROFILE'
export OMARCHY_PATH="/usr/share/omarchy"
export PATH="$OMARCHY_PATH/bin:$HOME/.local/bin:$PATH"
PROFILE
cat >/etc/skel/.bash_profile <<'BP'
[ -f ~/.profile ] && . ~/.profile
[ -f ~/.bashrc ] && . ~/.bashrc
BP

# Sanity: the first-login provisioning trigger must be reachable from the seeded home.
[ -f /etc/skel/.config/hypr/hyprland.lua ] || { echo "[image-userland] FATAL: skel missing hypr config" >&2; exit 1; }
[ -f /etc/omarchy.conf ] || { echo "[image-userland] FATAL: /etc/omarchy.conf not written (session would bounce)" >&2; exit 1; }

say "done"
