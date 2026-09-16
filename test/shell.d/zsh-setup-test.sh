#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Files that make up the zsh setup surface. The auto-launch block and the fork
# config paths must stay consistent across all of them.
SETUP="$ROOT/bin/omarchy-setup-zsh"
INSTALL="$ROOT/install/config/zsh.sh"
TEMPLATE_BASHRC="$ROOT/default/zsh/templates/bashrc"
TEMPLATE_ZSHRC="$ROOT/default/zsh/templates/zshrc"
DEFAULT_ZSHRC="$ROOT/default/zshrc"
README="$ROOT/default/zsh/README.md"

# ---------------------------------------------------------------------------
# Paths: nothing may point at the upstream Arch package layout, and every fork
# path the setup writes must resolve to a file that actually ships.
# ---------------------------------------------------------------------------

# The Arch package installed to /usr/share/omarchy-zsh; this Fedora fork ships
# its zsh config under ~/.local/share/omarchy/default/zsh instead.
if grep -rInF '/usr/share/omarchy-zsh' \
  "$ROOT/bin/omarchy-setup-zsh" "$ROOT/install/config/zsh.sh" \
  "$ROOT/default/zsh" "$ROOT/default/zshrc" "$ROOT/default/bashrc" 2>/dev/null; then
  fail "no shipped zsh file references the upstream /usr/share/omarchy-zsh layout"
fi
pass "no shipped zsh file references the upstream /usr/share/omarchy-zsh layout"

# The loader every generated ~/.zshrc reaches, and the dirs it globs.
for path in \
  default/zsh/rc \
  default/zsh/conf.d \
  default/zsh/functions \
  default/bash/rc; do
  [[ -e "$ROOT/$path" ]] || fail "fork path exists: $path"
done
pass "the fork zsh config paths the setup writes all exist"

# default/zsh/rc must glob the fork conf.d/functions dirs, not /usr/share.
grep -qF '~/.local/share/omarchy/default/zsh/conf.d' "$ROOT/default/zsh/rc" ||
  fail "default/zsh/rc loads conf.d from the fork path"
grep -qF '~/.local/share/omarchy/default/zsh/functions' "$ROOT/default/zsh/rc" ||
  fail "default/zsh/rc loads functions from the fork path"
pass "default/zsh/rc loads config from the fork paths"

# The copyable ~/.zshrc sources (default/zshrc, template/zshrc) must reach the
# fork rc loader.
for f in "$DEFAULT_ZSHRC" "$TEMPLATE_ZSHRC"; do
  grep -qF '~/.local/share/omarchy/default/zsh/rc' "$f" ||
    fail "$(basename "$(dirname "$f")")/$(basename "$f") sources the fork zsh rc"
done
pass "the shipped zshrc files source the fork zsh rc"

# ---------------------------------------------------------------------------
# Install channel: zsh comes from Homebrew, never pacman/yay/dnf.
# ---------------------------------------------------------------------------

grep -qF 'brew install zsh' "$SETUP" ||
  fail "omarchy-setup-zsh installs zsh from Homebrew"
for bad in 'yay ' 'pacman ' 'dnf install'; do
  if grep -qF "$bad" "$SETUP"; then
    fail "omarchy-setup-zsh no longer suggests a non-brew installer" "found: $bad"
  fi
done
pass "omarchy-setup-zsh installs zsh from Homebrew only"

grep -qF 'brew install zsh' "$INSTALL" ||
  fail "install/config/zsh.sh points at Homebrew for zsh"
for bad in 'yay ' 'pacman ' 'dnf install'; do
  if grep -qF "$bad" "$INSTALL"; then
    fail "install/config/zsh.sh no longer suggests a non-brew installer" "found: $bad"
  fi
done
pass "install/config/zsh.sh points at Homebrew for zsh"

grep -qiF 'brew install zsh' "$README" || fail "README documents the brew install"
if grep -qiF 'pacman' "$README"; then
  fail "README no longer references pacman"
fi
pass "README documents the brew install channel"

# ---------------------------------------------------------------------------
# The auto-launch block: same shape everywhere it ships.
# ---------------------------------------------------------------------------

for f in "$SETUP" "$INSTALL" "$TEMPLATE_BASHRC"; do
  name="$(basename "$f")"
  grep -qF 'exec zsh $LOGIN_OPTION' "$f" || fail "$name execs zsh, preserving --login"
  grep -qF 'SHLVL} == 1' "$f" || fail "$name only auto-launches at SHLVL 1"
  grep -qF 'BASH_EXECUTION_STRING' "$f" || fail "$name skips bash -c invocations"
  grep -qF '!= "zsh"' "$f" || fail "$name skips when the parent is already zsh"
done
pass "the auto-launch block keeps its guards everywhere it ships"

# ---------------------------------------------------------------------------
# Behavior: run the real command in a throwaway HOME with stubbed helpers.
# ---------------------------------------------------------------------------

run_setup() {
  # $1 = characters piped to the prompts, in order. When a ~/.zshrc already
  #      exists the first char answers keep-vs-replace, then the next answers
  #      the auto-launch prompt; otherwise the single char answers auto-launch.
  # env: ZSH_PRESENT (1/0), PRESEED_ZSHRC (contents to pre-create ~/.zshrc with),
  #      BREW_LOG (file the brew stub appends its args to)
  local reply="$1"
  local home stub
  home="$(mktemp -d)"
  stub="$home/stubbin"
  mkdir -p "$stub"

  # Stub omarchy-cmd-present: zsh reported per ZSH_PRESENT, everything else present.
  cat >"$stub/omarchy-cmd-present" <<STUB
#!/bin/bash
for a in "\$@"; do
  [[ \$a == zsh && "\${ZSH_PRESENT:-1}" != "1" ]] && exit 1
done
exit 0
STUB

  # Stub brew so the install path is observable without touching the system.
  cat >"$stub/brew" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$BREW_LOG"
exit 0
STUB
  chmod +x "$stub/omarchy-cmd-present" "$stub/brew"

  printf 'my existing bashrc line\n' >"$home/.bashrc"
  [[ -n "${PRESEED_ZSHRC:-}" ]] && printf '%s' "$PRESEED_ZSHRC" >"$home/.zshrc"

  HOME="$home" PATH="$stub:$PATH" ZSH_PRESENT="${ZSH_PRESENT:-1}" BREW_LOG="$BREW_LOG" \
    bash "$SETUP" <<<"$reply" >/dev/null

  printf '%s' "$home"
}

# Case 1: zsh present, user opts into bash auto-launch.
BREW_LOG="$(mktemp)"; export BREW_LOG
ZSH_PRESENT=1 home="$(run_setup y)"
grep -qF '~/.local/share/omarchy/default/zsh/conf.d' "$home/.zshrc" ||
  fail "generated ~/.zshrc loads the fork conf.d"
grep -qF 'Auto-launch zsh shell' "$home/.bashrc" ||
  fail "opting in adds the auto-launch block to ~/.bashrc"
grep -qF 'my existing bashrc line' "$home/.bashrc" ||
  fail "auto-launch setup preserves the user's existing ~/.bashrc content"
[[ -s "$BREW_LOG" ]] && fail "brew is not called when zsh is already present"
pass "setup with zsh present writes a fork-path .zshrc and the auto-launch block"

# Case 2: zsh present, user declines auto-launch -> bashrc untouched.
BREW_LOG="$(mktemp)"; export BREW_LOG
ZSH_PRESENT=1 home="$(run_setup n)"
if grep -qF 'Auto-launch zsh shell' "$home/.bashrc"; then
  fail "declining the prompt leaves ~/.bashrc without the auto-launch block"
fi
pass "setup respects declining the bash auto-launch prompt"

# Case 3: zsh missing -> installed via brew before setup continues.
BREW_LOG="$(mktemp)"; export BREW_LOG
ZSH_PRESENT=0 home="$(run_setup n)"
grep -qF 'install zsh' "$BREW_LOG" ||
  fail "a missing zsh is installed with 'brew install zsh'"
pass "setup installs a missing zsh from Homebrew"

# Case 4: an existing ~/.zshrc, user chooses to keep it -> left untouched, no backup.
BREW_LOG="$(mktemp)"; export BREW_LOG
PRESEED_ZSHRC="# my custom zshrc"$'\n' ZSH_PRESENT=1 home="$(run_setup nn)"
grep -qF 'my custom zshrc' "$home/.zshrc" ||
  fail "keeping the existing ~/.zshrc leaves its contents in place"
if grep -qF '~/.local/share/omarchy/default/zsh/conf.d' "$home/.zshrc"; then
  fail "keeping the existing ~/.zshrc does not overwrite it with the defaults"
fi
if compgen -G "$home/.zshrc.backup-*" >/dev/null; then
  fail "keeping the existing ~/.zshrc makes no backup"
fi
pass "setup keeps an existing ~/.zshrc when the user declines the defaults"

# Case 5: an existing ~/.zshrc, user opts into the defaults -> replaced, backed up.
BREW_LOG="$(mktemp)"; export BREW_LOG
PRESEED_ZSHRC="# my custom zshrc"$'\n' ZSH_PRESENT=1 home="$(run_setup yn)"
grep -qF '~/.local/share/omarchy/default/zsh/conf.d' "$home/.zshrc" ||
  fail "opting into the defaults rewrites ~/.zshrc with the Omarchy config"
if grep -qF 'my custom zshrc' "$home/.zshrc"; then
  fail "opting into the defaults replaces the old ~/.zshrc contents"
fi
backup="$(compgen -G "$home/.zshrc.backup-*" || true)"
[[ -n "$backup" ]] || fail "opting into the defaults backs the old ~/.zshrc up"
grep -qF 'my custom zshrc' $backup ||
  fail "the ~/.zshrc backup holds the user's previous config"
pass "setup replaces and backs up ~/.zshrc when the user takes the defaults"
