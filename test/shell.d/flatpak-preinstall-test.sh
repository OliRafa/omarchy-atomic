#!/bin/bash

# The omarchy-atomic Flatpak app set (Brave, Loupe, Evince, Obsidian, …) is installed on first boot
# via Fedora/flatpak's UPSTREAM `flatpak preinstall`: a manifest in /usr/share/flatpak/preinstall.d
# plus the CLI, which owns the install logic, idempotency and user opt-out. Fedora packages the CLI
# but no boot unit, so omarchy-flatpak-preinstall.service is the thin wrapper that runs it — the only
# Flatpak-provisioning code we own. This is the same mechanism Bluefin/Aurora use.
#
# Those apps are core dependencies: mimeapps.list maps http(s) to com.brave.Browser and images to
# org.gnome.Loupe, and hypr/apps/system.lua launches Loupe. When provisioning never completes, a
# machine boots with mime handlers pointing at software that was never installed.
#
# It used to be a bespoke script that failed on every boot: the unit ordered itself
# After=network-online.target, but the image masks NetworkManager-wait-online
# (install/config/enable-services.sh), so that target is reached before DHCP/DNS. Every install
# failed with "Could not resolve hostname", the unit went to failed, and "retry next boot" lost the
# same race again. The fix mirrors ublue: the remote is registered from a LOCAL baked file (no
# network), and the wrapper retries with Restart=on-failure out of the boot path until connectivity
# exists.

source "$(dirname "$0")/base-test.sh"

unit="$ROOT/images/core/files/usr/lib/systemd/system/omarchy-flatpak-preinstall.service"
manifest="$ROOT/images/core/files/usr/share/flatpak/preinstall.d/omarchy-atomic.preinstall"

[[ -f $unit ]] || fail "the flatpak preinstall unit ships"
[[ -f $manifest ]] || fail "the flatpak preinstall manifest ships"
pass "the flatpak preinstall unit and manifest ship"

# The old bespoke script and its unit must be gone, not merely superseded — a stray enable of the old
# unit would race the new one.
[[ ! -e $ROOT/images/core/files/usr/libexec/omarchy-flatpak-setup ]] ||
  fail "the old bespoke omarchy-flatpak-setup script is removed"
[[ ! -e $ROOT/install/flatpaks ]] ||
  fail "the old install/flatpaks list is removed (the manifest is the source of truth now)"
pass "the old bespoke flatpak-setup script and list are gone"

# --- the manifest -------------------------------------------------------------------------------

# The upstream .preinstall format groups each app as [Flatpak Preinstall <id>]. Assert the app set,
# and that every group pins Branch=stable — the flatpak default is "master", which does not exist on
# Flathub, so an unpinned group silently installs nothing.
for app in com.brave.Browser org.gnome.Evince org.gnome.Calculator org.gnome.Loupe \
           com.obsproject.Studio org.kde.kdenlive com.github.PintaProject.Pinta \
           com.github.xournalpp.xournalpp org.libreoffice.LibreOffice md.obsidian.Obsidian; do
  grep -qF "[Flatpak Preinstall $app]" "$manifest" || fail "manifest declares $app"
done
pass "manifest declares the full omarchy-atomic app set"

groups=$(grep -cE '^\[Flatpak Preinstall ' "$manifest")
branches=$(grep -cE '^Branch=stable$' "$manifest")
(( groups == branches )) ||
  fail "every group pins Branch=stable ($groups groups, $branches Branch=stable)" "$(grep -nE '^\[Flatpak Preinstall |^Branch=' "$manifest")"
pass "every group pins Branch=stable"

# --- unit wiring --------------------------------------------------------------------------------

grep -q '^WantedBy=multi-user\.target' "$unit" || fail "unit is wired into multi-user.target"
pass "unit is wired into multi-user.target"

# The install pulls need a network that is actually up. network-online.target is not that here — it
# is reached before the network answers because wait-online is masked — so the unit must retry, out
# of the boot path, until connectivity exists.
grep -q '^Restart=on-failure' "$unit" || fail "unit retries on failure"
grep -q '^RestartSec=' "$unit" || fail "unit spaces its retries out (RestartSec)"
pass "unit retries a failed pull rather than giving up until reboot"

# The start-rate limiter must be disabled, in [Unit] (systemd ignores StartLimitIntervalSec in
# [Service]), or repeated RestartSec attempts eventually trip it and the unit gives up.
awk '/^\[/{sec=$0} /^StartLimitIntervalSec=0/{print sec}' "$unit" | grep -q '^\[Unit\]' ||
  fail "StartLimitIntervalSec=0 must be in [Unit] so the retry limiter is actually disabled" \
    "$(grep -n 'StartLimitIntervalSec' "$unit")"
pass "the retry limiter is disabled in [Unit]"

# The remote must be registered from the baked LOCAL file, not a URL — that is what makes remote-add
# survive the masked wait-online. It runs as ExecStartPre so preinstall has a source to resolve from.
grep -qE '^ExecStartPre=.*flatpak remote-add .*--system .*/etc/flatpak/remotes.d/flathub\.flatpakrepo' "$unit" ||
  fail "the remote is added from the baked local file before preinstall runs" "$(grep -n Exec "$unit")"
grep -qE '^ExecStartPre=.*remote-add .*http' "$unit" &&
  fail "the remote must not be fetched over the network at boot" "$(grep -n Exec "$unit")"
pass "the remote is registered from the baked local file before preinstall runs"

# The install itself is delegated to the upstream CLI, not a hand-rolled loop — and it MUST run under
# a D-Bus session bus. `flatpak preinstall` activates the OCI authenticator over the session bus; a
# system service has none, so without dbus-run-session it dies instantly with "Cannot autolaunch
# D-Bus without X11 $DISPLAY" and installs nothing. This is the exact failure seen on real hardware
# after the first release, invisible to CI (the e2e job does not run first-boot services).
grep -qE '^ExecStart=/usr/bin/dbus-run-session -- /usr/bin/flatpak preinstall .*-y' "$unit" ||
  fail "preinstall runs under dbus-run-session (needs a D-Bus session bus)" "$(grep -n Exec "$unit")"
pass "the install is delegated to upstream 'flatpak preinstall', under a D-Bus session bus"

# remote-add does NOT need the session bus (proven on hardware: its ExecStartPre succeeds), so it
# must stay unwrapped — wrapping it would only add a spurious dependency.
grep -qE '^ExecStartPre=/usr/bin/flatpak remote-add' "$unit" ||
  fail "remote-add runs directly (no session bus needed)" "$(grep -n Exec "$unit")"
pass "remote-add runs directly, without dbus-run-session"

# No stamp of our own: preinstall must run every boot so later additions apply and user removals
# stick (both are the CLI's job). A stamp would freeze the set at first boot. Comments are excluded —
# the unit explains that it carries no stamp, and saying so is not doing it.
if grep -vE '^[[:space:]]*#' "$unit" | grep -qiE 'stamp|ConditionPathExists.*-done|-done'; then
  fail "the wrapper must not gate on a stamp — upstream preinstall handles idempotency" \
    "$(grep -vE '^[[:space:]]*#' "$unit" | grep -niE 'stamp|-done')"
fi
pass "the wrapper carries no stamp; idempotency is upstream's job"

# --- build wiring (Containerfile step 5c) -------------------------------------------------------

containerfile="$ROOT/images/core/Containerfile"

# The remote is only DNS-free at boot if the .flatpakrepo is actually baked into /etc at build.
grep -qE 'remotes\.d/flathub\.flatpakrepo' "$containerfile" ||
  fail "the Containerfile bakes flathub.flatpakrepo into /etc/flatpak/remotes.d"
pass "the Containerfile bakes the Flathub remote file"

# Flathub must be the only enabled remote, or `flatpak preinstall` can resolve an app from Fedora's
# OCI remote instead. bluefin masks (and deletes) flatpak-add-fedora-repos for the same reason.
grep -qE 'systemctl mask flatpak-add-fedora-repos\.service' "$containerfile" ||
  fail "the Containerfile masks flatpak-add-fedora-repos.service so Flathub is authoritative"
pass "the Containerfile masks Fedora's flatpak remote"

# The wrapper unit must actually be enabled.
grep -qE 'systemctl enable .*omarchy-flatpak-preinstall\.service' "$containerfile" ||
  fail "the Containerfile enables omarchy-flatpak-preinstall.service"
pass "the Containerfile enables the wrapper unit"

# --- the update timer ---------------------------------------------------------------------------

# preinstall installs the set once; nothing else updates the system Flatpaks (omarchy-update-manual-pkgs
# is --user only). A timer must keep them current, the way ublue's flatpak-system-update.timer does.
update_service="$ROOT/images/core/files/usr/lib/systemd/system/omarchy-flatpak-update.service"
update_timer="$ROOT/images/core/files/usr/lib/systemd/system/omarchy-flatpak-update.timer"

[[ -f $update_service ]] || fail "the flatpak update service ships"
[[ -f $update_timer ]] || fail "the flatpak update timer ships"
pass "the flatpak update service and timer ship"

grep -qE '^ExecStart=/usr/bin/dbus-run-session -- /usr/bin/flatpak update --system' "$update_service" ||
  fail "the update service updates the SYSTEM installation under dbus-run-session" "$(grep -n Exec "$update_service")"
pass "the update service updates the system installation, under a D-Bus session bus"

# Metered connections must be spared, or a hotspot gets drained — the guard ublue/bluefin both use.
grep -qE '^ExecCondition=.*Metered' "$update_service" ||
  fail "the update service skips metered connections" "$(grep -n Exec "$update_service")"
pass "the update service skips metered connections"

grep -qE '^OnCalendar=' "$update_timer" || fail "the timer has a schedule"
grep -qE '^Persistent=true' "$update_timer" || fail "the timer catches up after downtime (Persistent)"
grep -qE '^WantedBy=timers\.target' "$update_timer" || fail "the timer is wired into timers.target"
pass "the timer is scheduled, persistent, and wired into timers.target"

grep -qE 'systemctl enable .*omarchy-flatpak-update\.timer' "$containerfile" ||
  fail "the Containerfile enables omarchy-flatpak-update.timer"
pass "the Containerfile enables the update timer"
