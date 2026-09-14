#!/bin/bash
# Container smoke test for the omarchy-atomic FAIRYDUST-CORE image.
#
# Asserts what the kernel swap must produce, WITHOUT booting (the Asahi kernel only boots on real
# Apple Silicon — DP-alt-mode itself is a hardware check, see the kernel repo's README). The core
# userspace is already covered by images/core/hack/smoke.sh against the core image this is built
# FROM; here we only check the fairydust delta plus the boot-critical invariants the swap touches.
#
# Runnable on any aarch64 host with docker/podman:
#   ./images/fairydust-core/hack/smoke.sh [IMAGE]     # default omarchy-atomic-fairydust-core:44
#   ENGINE=podman ./images/fairydust-core/hack/smoke.sh
set -euo pipefail
IMAGE="${1:-omarchy-atomic-fairydust-core:44}"
ENGINE="${ENGINE:-docker}"

echo "== smoke-testing image: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }

echo "== kernel swapped to fairydust =="
[ "$(uname -m)" = aarch64 ] && ok "aarch64" || no "not aarch64: $(uname -m)"
# The stock kernel-16k RPM must be GONE — the swap removes it (this is the inverse of core's smoke).
if rpm -q kernel-16k >/dev/null 2>&1; then
  no "kernel-16k RPM still present — the stock kernel was not removed"
else
  ok "stock kernel-16k RPM removed"
fi
# Exactly one kernel tree must remain, and it is NOT an fcNN Fedora build (fairydust builds as a
# plain `<ver>+` localversion, e.g. 7.1.13+).
n=$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | wc -l)
[ "$n" = 1 ] && ok "exactly one kernel in /usr/lib/modules" || no "expected 1 kernel, found $n"
kver="$(basename "$(dirname "$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | head -1)")")"
case $kver in
  *.fc*) no "kernel $kver looks like a Fedora build, not the fairydust swap" ;;
  "")    no "no kernel version resolved" ;;
  *)     ok "fairydust kernel present: $kver" ;;
esac

echo "== fairydust payload (DisplayPort alt-mode) =="
# appledrm = DRM_APPLE, phy-apple-dptx = the USB-C DisplayPort-TX PHY that is fairydust's whole point.
for m in appledrm phy-apple-dptx; do
  if find "/usr/lib/modules/$kver" -name "$m.ko*" 2>/dev/null | grep -q .; then
    ok "module $m present"
  else
    no "module $m missing — not a fairydust kernel"
  fi
done
# vmlinuz must be the EFI-stub image systemd-boot needs on this UEFI/m1n1 chain.
if command -v file >/dev/null 2>&1; then
  case "$(file -b "/usr/lib/modules/$kver/vmlinuz" 2>/dev/null)" in
    *EFI*) ok "vmlinuz is an EFI application (systemd-boot loadable)" ;;
    *)     no "vmlinuz is not an EFI application — systemd-boot may not load it" ;;
  esac
fi

echo "== Apple devicetrees shipped with the kernel =="
# Apple Silicon DTB filenames are SoC-coded (t8103-*.dtb, t6000-*.dtb, ...), not "apple*"; the dtb
# dir holds only the Apple DTBs we install (arch/arm64/boot/dts/apple/*.dtb), so count all *.dtb.
dtbn=$(find "/usr/lib/modules/$kver/dtb" -name '*.dtb' 2>/dev/null | wc -l)
[ "$dtbn" -gt 0 ] && ok "$dtbn Apple DTBs under modules/$kver/dtb" || no "no Apple DTBs — update-m1n1 would boot stale devicetree"

echo "== composefs initramfs rebuilt against the fairydust kernel =="
# Same assertion as core: the boot entry's initrd must carry bootc's composefs root pivot, or a
# composefs install boots the host's /usr. No `| grep -q` under pipefail (SIGPIPE trap) — capture.
initramfs_listing="$(lsinitrd "/usr/lib/modules/$kver/initramfs.img" 2>/dev/null || true)"
case $initramfs_listing in
  *bootc-root-setup.service*) ok "initramfs carries bootc-root-setup.service" ;;
  *)                          no "initramfs has no bootc composefs root setup" ;;
esac

echo "== inherited core invariants (sanity) =="
rpm -q systemd-boot-unsigned >/dev/null 2>&1 && ok "systemd-boot-unsigned present" || no "systemd-boot-unsigned missing"
rpm -q asahi-platform-metapackage >/dev/null 2>&1 && ok "asahi-platform-metapackage present" || no "asahi platform packages missing"
[ -L /usr/bin/omarchy ] && ok "omarchy symlinked into /usr/bin" || no "omarchy not symlinked into /usr/bin"

if [ "$fail" = 0 ]; then
  echo "== ALL FAIRYDUST-CORE SMOKE CHECKS PASSED =="
else
  echo "== FAIRYDUST-CORE SMOKE CHECKS FAILED =="
fi
exit "$fail"
CHECKS
