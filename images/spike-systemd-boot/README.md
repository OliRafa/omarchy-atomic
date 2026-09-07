# Spike: systemd-boot instead of GRUB (Apple Silicon)

**Question:** can the omarchy-atomic core boot via **systemd-boot** rather than GRUB on Asahi,
like `home-servers-setup/ultron-os` does on amd64?

**Context:** upstream `fedora-asahi-remix-atomic-desktops` ([images#2](https://github.com/fedora-asahi-remix-atomic-desktops/images/issues/2)) and bazzite
([ublue-os/bazzite#2155](https://github.com/ublue-os/bazzite/pull/2155)) **both stay on GRUB+bootupd** — nobody ships systemd-boot on
Asahi, so this is unproven.

## Why it's architecturally possible

The Asahi chain is `m1n1 → U-Boot(UEFI) → /EFI/BOOT/BOOTAA64.EFI → kernel`. U-Boot loads
*whatever* EFI binary is at the removable path `/EFI/BOOT/BOOTAA64.EFI` — that can be
systemd-boot (`systemd-bootaa64.efi`) instead of GRUB. And the devicetree comes from **m1n1
via UEFI**, so systemd-boot doesn't have to provide it. (There's no UEFI NVRAM boot-entry
model here, so the bootloader must live at the *removable* path.)

## The change-set

- **Image** (`Containerfile`, `FROM omarchy-atomic-core`): add `systemd-boot-unsigned`, drop
  `grub2-efi-aa64` + `bootupd`.
- **Install** (deploy-time): systemd-boot needs the composefs-native backend (the ostree
  backend errors *"bootupd is required for ostree-based installs"*):
  ```sh
  sudo bootc install to-disk --composefs-backend --bootloader systemd \
    --filesystem btrfs --generic-image --via-loopback --wipe /dev/DISK
  ```
- **Lost:** bootupd's GRUB self-update; systemd-boot self-updates via `bootctl update` instead.
  (m1n1/U-Boot firmware updates remain `update-m1n1`'s job either way — unchanged.)

## What's validated where

| Check | How | Where |
|---|---|---|
| Image builds; `bootc container lint` passes | Containerfile | ✅ CI (`spike-systemd-boot.yml`) |
| `bootc install --bootloader systemd` succeeds on the Asahi base | `bootc install to-disk` | ✅ CI |
| systemd-boot lands on the ESP, **no GRUB** | guestfish pre-boot inspection | ✅ CI |
| **U-Boot → systemd-boot → Asahi kernel actually boots (DT handoff)** | reboot | ⚠️ **real Apple Silicon only** |

The last row is the genuine unknown and can't be tested in CI (the Asahi kernel-16k doesn't
boot in generic qemu). On hardware, confirm with:

```sh
bootctl status | grep -qi systemd-boot     # systemd-boot is the active bootloader
bootctl list   | grep -qi 'Type #1'        # BLS Type-1 entry present (no UKI)
test ! -e /boot/efi/EFI/fedora/grubaa64.efi  # GRUB gone
```

## Verdict (fill in after CI + a hardware boot)

- [ ] CI: builds + lints + systemd-boot on ESP
- [ ] Hardware: boots to a working desktop with USB/GPU (DT intact)
