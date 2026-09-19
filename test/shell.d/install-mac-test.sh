#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# install.sh is the fork's git-clone installer for Fedora Asahi Remix (aarch64).
# It is not the old Arch/ALARM installer: packages come from dnf/COPR, gum from
# the Fedora bootstrap, and there is no pacman keyring or limine stack here.
install_script="$ROOT/install.sh"

[[ -x $install_script ]] || fail "the Apple Silicon installer ships and is executable"
pass "the Apple Silicon installer ships and is executable"

# set -e turns a call to a command that no longer ships into a half-finished
# install. Anchored to command position so paths and filenames the script merely
# names (omarchy-base.packages, cache dirs) stay out.
while read -r command_name; do
  [[ -n $command_name ]] || continue
  [[ -x "$ROOT/bin/$command_name" ]] ||
    fail "the installer only calls commands that ship in bin/" "missing: $command_name"
done < <(grep -oE '^[[:space:]]*(sudo[[:space:]]+)?omarchy-[a-z0-9-]+' "$install_script" |
  grep -oE 'omarchy-[a-z0-9-]+' | sort -u)
pass "the installer only calls commands that ship in bin/"

# First install: hardware setup runs as root, then the user is provisioned.
grep -F 'exec omarchy-apply-hardware --install-user "$3"' "$install_script" >/dev/null ||
  fail "the installer applies hardware setup as root for a first install"
grep -F 'omarchy-provision-user --first-install' "$install_script" >/dev/null ||
  fail "the installer finalizes the user for a first install"
pass "the installer runs first-install system and user setup"

# The git-clone fork has no /etc/skel-populating package, so the shipped ~/.config
# tree is seeded from the clone by install/config/config.sh (run as the user).
grep -qF 'config/config.sh' "$install_script" ||
  fail "the installer seeds shipped defaults into the user's home"
pass "the installer seeds shipped defaults into the user's home"

# gum arrives up front via the Fedora gum bootstrap, so the install speaks with
# Omarchy's styling from the start rather than only after the long package pass.
grep -qF 'helpers/fedora-gum.sh' "$install_script" ||
  fail "the installer bootstraps gum up front"
grep -qF 'gum style' "$install_script" ||
  fail "the installer styles its output with gum"
gum_line=$(grep -n 'helpers/fedora-gum.sh' "$install_script" | head -1 | cut -d: -f1)
packages_line=$(grep -n 'packaging/base.sh' "$install_script" | head -1 | cut -d: -f1)
[[ -n $gum_line && -n $packages_line ]] ||
  fail "the installer bootstraps gum and installs the base package set"
(( gum_line < packages_line )) || fail "gum is bootstrapped before the long package phase"
pass "the installer styles its output with gum from the start"
