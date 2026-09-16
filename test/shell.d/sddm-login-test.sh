#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

# This fork logs in through SDDM autologin on Fedora, not upstream's seamless
# tty1 login with SDDM last-user state seeding. install/login/sddm.sh mutates the
# real system (sudo systemctl, writes under /etc) and is not parameterized for
# hermetic execution, so its behavior is pinned by static analysis instead.
sddm_setup="$ROOT/install/login/sddm.sh"
[[ -f $sddm_setup ]] || fail "the SDDM login setup ships"

# Any legacy seamless-login units are torn down and the tty1 getty restored.
grep -qF 'systemctl disable --now omarchy-seamless-login.service' "$sddm_setup" ||
  fail "setup disables the legacy seamless-login service"
grep -qF 'rm -f /etc/systemd/system/omarchy-seamless-login.service' "$sddm_setup" ||
  fail "setup removes the legacy seamless-login unit"
grep -qF 'systemctl enable getty@tty1.service' "$sddm_setup" ||
  fail "setup restores the tty1 getty the seamless login had replaced"
pass "setup removes legacy seamless-login and restores the tty1 getty"

# Autologin names the resolved human account and the Hyprland session.
grep -qF '/etc/sddm.conf.d/10-omarchy-autologin.conf' "$sddm_setup" ||
  fail "setup writes the autologin drop-in"
grep -qF '[Autologin]' "$sddm_setup" || fail "the drop-in declares an [Autologin] section"
grep -qF 'User=$AUTOLOGIN_USER' "$sddm_setup" || fail "autologin names the resolved user"
grep -qF 'Session=$SESSION_NAME' "$sddm_setup" || fail "autologin names the resolved session"
# The account resolves from the invoking user, then logname, then the first
# regular (UID >= 1000) account, and is never root.
grep -qF 'SUDO_USER' "$sddm_setup" || fail "user resolution prefers the invoking sudo user"
grep -qF 'logname' "$sddm_setup" || fail "user resolution falls back to logname"
grep -qF '$3>=1000 && $3<65534' "$sddm_setup" ||
  fail "user resolution falls back to the first regular account"
# The uwsm Hyprland session is preferred, with a plain hyprland fallback.
grep -qF 'hyprland-uwsm' "$sddm_setup" || fail "the uwsm Hyprland session is preferred"
grep -qF 'wayland-sessions/hyprland.desktop' "$sddm_setup" ||
  fail "a plain Hyprland session is the fallback"
pass "setup configures SDDM autologin for the resolved user and Hyprland session"

# SDDM uses the Omarchy theme and the machine boots into the graphical target.
grep -qF 'Current=omarchy' "$sddm_setup" || fail "SDDM uses the Omarchy theme"
grep -qF 'systemctl set-default graphical.target' "$sddm_setup" ||
  fail "the graphical target is the boot default"
grep -qF 'systemctl enable sddm.service' "$sddm_setup" || fail "sddm.service is enabled"
pass "setup selects the Omarchy SDDM theme and boots into the graphical target"

# Password logins must not create an encrypted login keyring, which would break
# the passwordless auto-unlock of the Default_keyring.
grep -qF 'pam_gnome_keyring' "$sddm_setup" || fail "setup adjusts the SDDM PAM keyring behavior"
grep -qF "sed -i '/-auth.*pam_gnome_keyring" "$sddm_setup" ||
  fail "setup strips the gnome-keyring auth line from the SDDM PAM stack"
grep -qF "sed -i '/-password.*pam_gnome_keyring" "$sddm_setup" ||
  fail "setup strips the gnome-keyring password line from the SDDM PAM stack"
pass "setup keeps password logins from creating a conflicting encrypted keyring"
