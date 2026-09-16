#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
apps="$test_home/.local/share/applications"
mkdir -p "$mock_bin" "$apps"

launch_log="$test_tmp/launch"

# The fork's launcher resolves the default browser and hands it to
# `setsid uwsm-app -- <argv>`. Stub setsid to run its argument directly and
# uwsm-app to record the launch argv, so the test observes the final command.
cat >"$mock_bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat >"$mock_bin/uwsm-app" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >"$OMARCHY_TEST_BROWSER_LAUNCH"
SH
# xdg-settings reports the configured default-browser desktop id.
cat >"$mock_bin/xdg-settings" <<'SH'
#!/bin/bash
if [[ "$*" == "get default-web-browser" ]]; then
  printf '%s\n' "${OMARCHY_TEST_DEFAULT_BROWSER:-chromium.desktop}"
fi
SH
# Browser binaries used for the private-mode capability probe: Chromium prints no
# MOZ_LOG (Chromium family -> --incognito); Firefox advertises MOZ_LOG in --help
# (Firefox family -> --private-window).
cat >"$mock_bin/chromium" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$mock_bin/firefox" <<'SH'
#!/bin/bash
[[ "$*" == "--help" ]] && printf 'set MOZ_LOG to enable logging\n'
exit 0
SH
chmod +x "$mock_bin"/*

cat >"$apps/chromium.desktop" <<'EOF'
[Desktop Entry]
Exec=chromium %U
EOF
cat >"$apps/firefox.desktop" <<'EOF'
[Desktop Entry]
Exec=firefox %U
EOF
# A Flatpak browser resolves its Exec to `flatpak run <app-id> ...`.
cat >"$apps/com.brave.Browser.desktop" <<'EOF'
[Desktop Entry]
Exec=flatpak run --branch=stable com.brave.Browser @@u %U @@
EOF

launch_browser() {
  # usage: launch_browser <default-desktop-id> [args...]
  local default="$1"
  shift
  : >"$launch_log"
  HOME="$test_home" PATH="$mock_bin:$PATH" \
    OMARCHY_TEST_DEFAULT_BROWSER="$default" \
    OMARCHY_TEST_BROWSER_LAUNCH="$launch_log" \
    bash "$ROOT/bin/omarchy-launch-browser" "$@"
}

# The resolved default browser receives the URL through uwsm-app.
launch_browser chromium.desktop "https://example.test/authorize"
launched=$(<"$launch_log")
[[ $launched == "-- chromium https://example.test/authorize" ]] ||
  fail "browser launcher hands the URL to the default browser via uwsm-app" "$launched"
pass "browser launcher launches the default browser with the requested URL"

# Private mode injects the Chromium incognito flag ahead of the URL.
launch_browser chromium.desktop --private "https://example.test/authorize"
launched=$(<"$launch_log")
[[ $launched == "-- chromium --incognito https://example.test/authorize" ]] ||
  fail "private launch adds the Chromium incognito flag" "$launched"
pass "private browsing opens a Chromium browser incognito"

# A Firefox-family browser gets --private-window instead.
launch_browser firefox.desktop --private "https://example.test/authorize"
launched=$(<"$launch_log")
[[ $launched == "-- firefox --private-window https://example.test/authorize" ]] ||
  fail "private launch adds the Firefox private-window flag" "$launched"
pass "private browsing opens a Firefox browser in a private window"

# A Flatpak browser launches through `flatpak run <app-id>` so our flags reach
# the application rather than flatpak itself.
launch_browser com.brave.Browser.desktop "https://example.test/authorize"
launched=$(<"$launch_log")
[[ $launched == "-- flatpak run com.brave.Browser https://example.test/authorize" ]] ||
  fail "a Flatpak browser launches through flatpak run with the URL" "$launched"
pass "Flatpak browsers launch through flatpak run"
