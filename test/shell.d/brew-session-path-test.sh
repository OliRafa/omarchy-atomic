#!/bin/bash

# Homebrew provides the editor. EDITOR is `omarchy-launch-editor --inline`, that resolves to nvim,
# and nvim comes from the Brewfile — so if brew is not on the SESSION path, a keybind that opens an
# editor fails on a machine where `brew` works perfectly in a terminal.
#
# Two things conspire. ublue's /etc/profile.d/brew.sh is guarded on `$- == *i*`, so it only extends
# PATH for interactive shells; and uwsm does not source /etc/profile.d at all (the env.d file says
# so itself). Meanwhile omarchy-launch-tui execs its target with no shell in between:
#     exec setsid uwsm-app -- xdg-terminal-exec --app-id=$APP_ID -e "$1" "${@:2}"
# so nothing along that path would ever have added brew's bin.

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

envd="$ROOT/default/uwsm/env.d/10-omarchy"
[[ -f $envd ]] || fail "the session env drop-in ships"

# Sourcing the whole file drags in the rest of the session bootstrap, so exercise just the brew
# block: it is self-contained and guarded on the prefix existing.
brew_block=$(sed -n '/^if \[ -d \/home\/linuxbrew\/\.linuxbrew\/bin \]/,/^fi$/p' "$envd")
[[ -n $brew_block ]] || fail "the session env adds brew to PATH"
pass "the session env has a brew PATH block"

run_block() { # run_block PREFIX_EXISTS
  local root="$1"
  env -i PATH=/usr/bin:/bin bash -c "
    $(printf '%s' "${brew_block//\/home\/linuxbrew/$root\/home\/linuxbrew}")
    printf '%s' \"\$PATH\"
  "
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# No brew installed: PATH must be untouched, so a machine without brew is not left with dangling
# entries pointing at a prefix that does not exist.
out=$(run_block "$tmp")
[[ $out == "/usr/bin:/bin" ]] || fail "PATH is untouched when brew is absent" "actual: $out"
pass "PATH is untouched when brew is absent"

mkdir -p "$tmp/home/linuxbrew/.linuxbrew/bin" "$tmp/home/linuxbrew/.linuxbrew/sbin"
out=$(run_block "$tmp")
[[ $out == *"/home/linuxbrew/.linuxbrew/bin"* ]] || fail "brew's bin joins PATH when installed" "actual: $out"
pass "brew's bin joins PATH when installed"
[[ $out == *"/home/linuxbrew/.linuxbrew/sbin"* ]] || fail "brew's sbin joins PATH when installed" "actual: $out"
pass "brew's sbin joins PATH when installed"

# APPENDED, never prepended. ublue hit real breakage (dbus) letting brew shadow system binaries,
# which is why their own profile.d drop-in strips brew's PATH= line and appends instead.
[[ $out == "/usr/bin:/bin:"* ]] || fail "brew is appended, never prepended" "actual: $out"
pass "brew is appended to PATH, never prepended"

# The launcher this exists for must still be exec'ing directly — if it ever grows a login shell,
# this block is redundant rather than load-bearing, and that is worth noticing.
grep -q 'xdg-terminal-exec .* -e' "$ROOT/bin/omarchy-launch-tui" ||
  fail "omarchy-launch-tui still execs its target directly (this test's reason to exist)"
pass "omarchy-launch-tui still execs its target directly"
