#!/usr/bin/env bash
# Container smoke test for the omarchy-atomic PREINSTALLS image. Asserts the bakeable parts
# (app-like first-party tools, shipped app lists, enabled first-boot services) — the actual
# brew/flatpak installs happen at first boot and are covered on-hardware, not here.
#   ./images/preinstalls/hack/smoke.sh [IMAGE]     # default omarchy-atomic:44
set -euo pipefail
IMAGE="${1:-omarchy-atomic:44}"
ENGINE="${ENGINE:-docker}"

echo "== smoke-testing preinstalls image: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }

echo "== app-like first-party tools baked into /usr/bin =="
for b in aether cliamp omacut omawrite; do
  [ -e "/usr/bin/$b" ] && ok "/usr/bin/$b" || no "/usr/bin/$b missing"
done

echo "== app lists shipped in the image =="
[ -s /usr/share/omarchy-atomic/Brewfile ] && ok "Brewfile shipped" || no "Brewfile missing"
[ -s /usr/share/omarchy-atomic/flatpaks ] && ok "flatpaks list shipped" || no "flatpaks list missing"

echo "== first-boot provisioning enabled =="
command -v flatpak >/dev/null 2>&1 && ok "flatpak present (from core)" || no "flatpak missing"
for svc in omarchy-flatpak-setup omarchy-brew-setup; do
  [ -x "/usr/libexec/$svc" ] && ok "/usr/libexec/$svc" || no "/usr/libexec/$svc missing"
  [ -L "/etc/systemd/system/multi-user.target.wants/$svc.service" ] \
    && ok "$svc.service enabled" || no "$svc.service not enabled"
done

echo
if [ "$fail" = 0 ]; then echo "PREINSTALLS SMOKE: PASS"; else echo "PREINSTALLS SMOKE: FAIL"; fi
exit "$fail"
CHECKS
