#!/usr/bin/env bash
# e2e test of the Omarchy FIRST-BOOT user setup against the built CORE image (container; no boot).
#
# Covers the boot-time half of first boot: omarchy-firstboot-user creating the primary user, and the
# baked /etc/skel giving that user the Omarchy ~/.config (the thing that was missing before the
# userland bake). Also runs the per-user finalize (omarchy-provision-user) best-effort, validates the
# shipped units with systemd-analyze, and runs the hermetic provisioning unit tests (mounted repo,
# since the image strips test/).
#
# NOT covered here — needs a real booted session (that's hack/boottest/ on a Mac): the
# ConditionFirstBoot sequencing, the tty1 interactive prompt, the SDDM handoff, and the Hyprland
# first-login autostart → omarchy-provision-first-run trigger + install/user/all.sh network steps.
#
#   ./images/core/hack/first-boot.sh [IMAGE]
#   ENGINE=podman ./images/core/hack/first-boot.sh omarchy-atomic-core:44
set -euo pipefail
IMAGE="${1:-omarchy-atomic-core:44}"
ENGINE="${ENGINE:-docker}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # hack -> core -> images -> repo root

echo "== first-boot e2e: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i -v "$REPO_ROOT:/src:ro" --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }
note(){ printf '  \033[2m·\033[0m %s\n' "$1"; }

U=tester

echo "== A) omarchy-firstboot-user (preseed) creates the primary user =="
install -d /etc/omarchy
cat >/etc/omarchy/firstboot-user.conf <<EOF
OMARCHY_USER=$U
OMARCHY_USER_FULLNAME="Test User"
OMARCHY_USER_GROUPS="wheel"
OMARCHY_USER_PASSWORD=correcthorsebattery
EOF
/usr/libexec/omarchy-firstboot-user
getent passwd "$U" >/dev/null && ok "user '$U' created" || no "user '$U' not created"
id -nG "$U" 2>/dev/null | tr ' ' '\n' | grep -qx wheel && ok "in 'wheel' (sudo)" || no "not in wheel"
passwd -S "$U" 2>/dev/null | awk '{exit $2=="P"?0:1}' && ok "password set" || no "password not set (locked/none)"
home="$(getent passwd "$U" | cut -d: -f6)"; note "home = $home"
[ -d "$home" ] && ok "home dir exists" || no "home dir missing"

echo "== B) /etc/skel seeded the Omarchy desktop into the new home =="
[ -d "$home/.config/hypr" ]                                   && ok "~/.config/hypr (desktop config from skel)" || no "~/.config/hypr missing — skel not seeded"
[ -f "$home/.bashrc" ]                                        && ok "~/.bashrc (from skel)"                     || no "~/.bashrc missing"
[ -f "$home/.config/omarchy/branding/screensaver.txt" ]       && ok "~/.config branding seeded"                 || no "branding missing"
[ -f /etc/omarchy.conf ]                                      && ok "/etc/omarchy.conf (session env)"           || no "/etc/omarchy.conf missing"

echo "== C) preseed shredded + idempotent re-run =="
[ ! -e /etc/omarchy/firstboot-user.conf ] && ok "preseed conf shredded after use" || no "preseed conf left behind (holds a secret)"
/usr/libexec/omarchy-firstboot-user 2>&1 | grep -qi 'already exists' && ok "re-run is a no-op (a user already exists)" || no "re-run did not self-skip"

echo "== D) omarchy-provision-user finalize (best-effort; session/network steps skip in a container) =="
if runuser -u "$U" -- env HOME="$home" bash -lc 'omarchy-provision-user --first-install' >/tmp/pu.log 2>&1; then
  ok "omarchy-provision-user completed"
else
  note "omarchy-provision-user exited non-zero (mise/keyring/gsettings unavailable here — expected): $(tail -1 /tmp/pu.log 2>/dev/null)"
fi
[ -f "$home/.config/user-dirs.dirs" ]                     && ok "xdg-user-dirs written"       || note "xdg-user-dirs not written (best-effort)"
[ -f "$home/.local/state/omarchy/done/finalize-user" ]   && ok "finalize-user stamped"        || note "finalize-user not stamped (partial finalize)"

echo "== E) systemd-analyze verify on shipped units (report) =="
if command -v systemd-analyze >/dev/null 2>&1; then
  for u in /usr/lib/systemd/system/omarchy-*.service; do
    if systemd-analyze verify "$u" >/tmp/sv.log 2>&1; then ok "verify $(basename "$u")"; else note "verify $(basename "$u"): $(grep -m1 . /tmp/sv.log 2>/dev/null) (non-fatal)"; fi
  done
else
  note "systemd-analyze absent"
fi

echo "== F) provisioning logic unit tests (mounted repo; image strips test/) =="
# first-run-test is hermetic (mocked) → gate on it. The rest need the full Fedora + omarchy runtime;
# run + report so we see their behavior in the real image without failing on session/env gaps.
if bash /src/test/shell.d/first-run-test.sh >/tmp/fr.log 2>&1; then ok "shell.d/first-run-test"; else no "shell.d/first-run-test FAILED"; sed 's/^/      /' /tmp/fr.log; fi
for t in provision-user-test provisioning-groups-test user-theme-test; do
  if bash "/src/test/shell.d/$t.sh" >"/tmp/$t.log" 2>&1; then ok "shell.d/$t"; else note "shell.d/$t reported: $(tail -1 "/tmp/$t.log" 2>/dev/null)"; fi
done

echo
if [ "$fail" = 0 ]; then echo "FIRST-BOOT E2E: PASS"; else echo "FIRST-BOOT E2E: FAIL"; fi
exit "$fail"
CHECKS
