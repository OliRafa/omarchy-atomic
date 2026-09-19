#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

# The shipped Chromium is the Flatpak org.chromium.Chromium. It reads external extensions from its
# Flatpak extension point under /var/lib/flatpak/extension, NOT /usr/share/<browser>/extensions and
# never a runtime /usr write. The Claude extension manifest is baked read-only under etc/ and exposed
# to the sandbox by a tmpfiles.d directory symlink (image) or omarchy-install-chromium-claude
# (git-clone / the omarchy-default-agent Claude flow). This pins that whole chain.
ext_id="fcoeoabgfenejglbffodgkkbkcdhcgfn"
payload="$ROOT/etc/omarchy/chromium-extensions/aarch64/1/extensions/$ext_id.json"
etc_files="$ROOT/install/config/etc-files.sh"
tmpfiles="$ROOT/images/core/files/usr/lib/tmpfiles.d/omarchy-chromium-extensions.conf"
script="$ROOT/bin/omarchy-install-chromium-claude"

# The baked manifest is a valid external-update offer for the Claude extension id.
[[ -f $payload ]] || fail "the Claude extension manifest is baked under etc/"
jq -e '.external_update_url == "https://clients2.google.com/service/update2/crx"' "$payload" >/dev/null ||
  fail "the manifest is an external_update_url offer to the Chrome Web Store update service"
pass "the Claude extension manifest is a valid external-update offer"

# etc-files.sh installs the manifest into /etc at build (Containerfile step 4b).
grep -qF "install_etc omarchy/chromium-extensions/aarch64/1/extensions/$ext_id.json" "$etc_files" ||
  fail "etc-files.sh installs the baked Claude extension manifest"
pass "etc-files.sh installs the baked Claude extension manifest"

# tmpfiles.d links the Flatpak extension-point DIRECTORY to the baked /etc payload at boot. The link
# target must be the directory (Flatpak cannot resolve a symlinked file) and use the omarchy label.
[[ -f $tmpfiles ]] || fail "a tmpfiles.d drop-in exposes the extension to the Flatpak browser"
grep -qE '^L\+?[[:space:]]+/var/lib/flatpak/extension/org\.chromium\.Chromium\.Extension\.omarchy[[:space:]].*[[:space:]]/etc/omarchy/chromium-extensions$' "$tmpfiles" ||
  fail "tmpfiles.d symlinks the extension-point directory to /etc/omarchy/chromium-extensions"
pass "tmpfiles.d exposes the baked extension point to the Flatpak browser"

# The installer must target the Flatpak extension point, not the dead /usr/share paths, and must not
# write into read-only /usr. It re-asserts the same directory symlink the tmpfiles.d drop-in creates.
grep -qF '/var/lib/flatpak/extension/org.chromium.Chromium.Extension.omarchy' "$script" ||
  fail "the installer targets the Flatpak extension point"
grep -qF '/etc/omarchy/chromium-extensions' "$script" ||
  fail "the installer links to the baked /etc payload"
grep -qF 'ln -sfn' "$script" ||
  fail "the installer creates the extension-point directory symlink idempotently"
! grep -qF '/usr/share/chromium/extensions' "$script" ||
  fail "the installer no longer writes the dead /usr/share external-extensions path"
grep -qE 'EUID == 0' "$script" || fail "the installer keeps its privilege guard"
grep -qE 'exec (sudo|pkexec)' "$script" || fail "the installer re-execs with sudo/pkexec for the /var write"
pass "the installer exposes the extension through the Flatpak extension point"
