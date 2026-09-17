#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The atomic image bakes the Omarchy userland through fedora-image-userland.sh, not install.sh.
# It runs system-files.sh + enable-services.sh + skel seeding, and MUST also run etc-files.sh:
# without it the repo etc/ tree (sudoers.d/omarchy-tzupdate, /etc/xdg/kitty defaults, sysctl, …)
# never lands, which is what broke the timezone menu (sudo timedatectl with no TTY, no rule). This
# pins that wiring statically; the built image itself is asserted by images/core/hack/smoke.sh.
userland="$ROOT/install/helpers/fedora-image-userland.sh"
etc_files="$ROOT/install/config/etc-files.sh"
core="$ROOT/install/omarchy-base.packages.core"

[[ -f $userland ]] || fail "the image userland helper ships"

grep -qF 'config/etc-files.sh' "$userland" ||
  fail "the image build runs etc-files.sh (else the repo etc/ tree never lands)"
pass "the image build runs etc-files.sh"

# The two files whose absence would silently regress a build are guarded FATAL so a broken build
# fails loudly rather than shipping a desktop with no timezone rule or no kitty defaults.
grep -qF '/etc/sudoers.d/omarchy-tzupdate' "$userland" ||
  fail "the build fails if the timezone sudoers rule did not land"
grep -qF '/etc/xdg/kitty/kitty.conf' "$userland" ||
  fail "the build fails if the system kitty defaults did not land"
pass "the build guards the timezone rule and the kitty defaults"

# etc-files.sh must install the timezone sudoers rule and the system kitty defaults.
grep -qF 'sudoers.d/$name' "$etc_files" ||
  fail "etc-files.sh installs the sudoers drop-ins"
grep -qE 'omarchy-passwd-tries omarchy-tzupdate' "$etc_files" ||
  fail "etc-files.sh installs the omarchy-tzupdate sudoers rule"
grep -qF 'install_etc xdg/kitty/kitty.conf' "$etc_files" ||
  fail "etc-files.sh installs the system kitty defaults at /etc/xdg/kitty/kitty.conf"
pass "etc-files.sh installs the timezone rule and the system kitty defaults"

# The sudoers validation must delete a drop-in only when visudo reports it invalid — never merely
# because visudo is absent (it is not installed yet at image-build time), which would silently drop
# the vetted omarchy-tzupdate rule and reintroduce the original bug.
grep -qF 'command -v visudo' "$etc_files" ||
  fail "etc-files.sh only validates sudoers when visudo is available"
pass "etc-files.sh keeps vetted sudoers rules when visudo is unavailable"

# The system kitty defaults the minimal user template relies on must ship socket-only remote
# control (the secure form), never unrestricted yes.
grep -qxF 'allow_remote_control socket-only' "$ROOT/etc/xdg/kitty/kitty.conf" ||
  fail "the system kitty defaults use socket-only remote control"
! grep -qxF 'allow_remote_control yes' "$ROOT/etc/xdg/kitty/kitty.conf" ||
  fail "the system kitty defaults never enable unrestricted remote control"
pass "the system kitty defaults use socket-only remote control"

# Native-feature system packages the desktop needs must be in the CORE set the image installs.
for pkg in qt6-qtmultimedia ffmpegthumbnailer vim-minimal cups-pk-helper; do
  grep -qxE "$pkg([[:space:]].*)?" "$core" ||
    fail "the core package set includes $pkg" "missing: $pkg"
done
pass "the core package set includes the native-feature system packages"

# cups-pdf runs a print backend as root; the CUPS hardening (migration 1787815267) removes it, and
# cups-hardening-test already forbids it in omarchy-base.packages. It must be gone from the image
# sets too, or fresh installs would ship the backend the hardening exists to drop.
for manifest in "$core" "$ROOT/install/omarchy-base.packages.fedora"; do
  ! grep -qxE 'cups-pdf([[:space:]].*)?' "$manifest" ||
    fail "cups-pdf is removed from the image package sets" "still in: ${manifest#"$ROOT/"}"
done
pass "cups-pdf is out of the image package sets (matches the CUPS hardening)"
