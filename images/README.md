# omarchy-atomic bootc images

Two-image design for the bootc PoC:

| Image | Contents | Status |
|-------|----------|--------|
| **core** — `images/core/Containerfile` → `omarchy-atomic-core` | Fedora Asahi base-atomic + Omarchy Hyprland core (`install/omarchy-base.packages.core`) + core first-party tools + m1n1/devicetree fix + **systemd-boot** + PATH/brew hooks | builds + lints; install-to-disk validated in CI |
| **preinstalls** — `images/preinstalls/Containerfile` → `omarchy-atomic` | `FROM core` + app-like first-party tools baked in (aether, cliamp, omacut, omawrite) + **first-boot** Flatpak (`install/flatpaks`) & Homebrew (`Brewfile`) provisioning | built |

## Base image

`quay.io/fedora-asahi-remix-atomic-desktops/base-atomic:44` — the unofficial Fedora
Asahi Remix bootc base with **no desktop environment**, already carrying the Asahi
kernel (`kernel-16k`), Apple firmware, u-boot/m1n1 glue and dracut. That's why we don't
hand-assemble a kernel: the hard Apple-Silicon boot bits come from the base, and we
only layer the Omarchy desktop on top. Tags `43` and `44` are published.

## Build (native aarch64 / Apple Silicon)

```sh
./images/build.sh core                    # -> omarchy-atomic-core:44
./images/build.sh preinstalls             # -> omarchy-atomic:44 (FROM the core image)
WITH_FIRST_PARTY=0 ./images/build.sh core # faster: validate the core package set only
ENGINE=podman FEDORA=43 ./images/build.sh core
```

## Bootloader: systemd-boot

The core image ships **systemd-boot**, not GRUB — it adds `systemd-boot-unsigned` and selects
it at install via `--bootloader systemd`. (grub2/bootupd can't be fully removed — they're held
by `asahi-platform-metapackage` — but stay unused; the ESP ends up systemd-boot-only.) On Asahi
the chain is `m1n1 → U-Boot(UEFI) → /EFI/BOOT/BOOTAA64.EFI
→ kernel`: U-Boot loads whatever EFI binary sits at that removable path (here, systemd-boot),
and the devicetree comes from m1n1 via UEFI, so the bootloader never manages it. Upstream
fedora-asahi-atomic and bazzite both stay on GRUB — this is the one place we diverge. It needs
the **composefs-native backend** at install time (see Deploy). CI validates it end-to-end:
`bootc install --composefs-backend --bootloader systemd` succeeds and lands
`/EFI/systemd/systemd-bootaa64.efi` + the removable `/EFI/BOOT/BOOTAA64.EFI` with no grub. The
only unconfirmed part is the physical boot (devicetree handoff) — needs a real Mac.

## Preinstalls image

`FROM omarchy-atomic-core`, this adds the removable, app-like layer on top of the lean core:

- **App-like first-party tools baked in** — aether, cliamp, omacut, omawrite install to
  `/usr/bin` at build time (they're just binaries), via `fedora-first-party.sh preinstalls`.
- **Homebrew + Flatpak = first-boot provisioning, not baked.** Both live in `/var`
  (machine-state), which a bootc image only *seeds* on first boot and does not track on
  upgrades — so they can't live in immutable `/usr` (and baking Flatpaks would add GBs and go
  stale). Instead the image ships the lists at `/usr/share/omarchy-atomic/{Brewfile,flatpaks}`
  and two stamped, idempotent oneshot units (the uBlue/Bluefin/Bazzite pattern):
  - `omarchy-flatpak-setup.service` → adds Flathub, installs `install/flatpaks` system-wide.
  - `omarchy-brew-setup.service` → installs Homebrew for the primary user, runs `brew bundle`
    against the `Brewfile`. Retries until a primary user exists; `brew bundle` can be slow on
    first boot (some aarch64 formulae build from source). **Needs on-hardware validation.**

## e2e tests

Modeled on `home-servers-setup/ultron-os` (build-from-source, then assert). CI validates
everything short of a physical boot — build, container contents, and a **real `bootc install
to-disk`** (composefs + systemd-boot) inspected by loopback mount. The Asahi `kernel-16k` only
boots on real hardware, so the actual boot is the on-hardware boottest harness.

- **Container smoke test — `images/core/hack/smoke.sh`** (runs now, anywhere aarch64):
  runs the built image as a container and asserts the userspace — Asahi base, core desktop
  packages, docker/nautilus/mpv/gnome-disk-utility kept in core, the omarchy tree + commands
  on PATH, the four core first-party tools in `/usr/bin` (not the `/usr/local` symlink), the
  preinstall "bloat" absent, the profile.d hooks, and the mimeapps repoints.

  ```sh
  ./images/build.sh core && ./images/core/hack/smoke.sh
  ```

- **Boot smoke harness — `images/core/hack/boottest/`** (on real Apple Silicon / Asahi VM):
  the ultron-os pattern — a gated `omarchy-boottest.service` runs `boot-smoke.sh` at boot
  and reports `BOOT SMOKE: PASS` over the serial console (running Asahi kernel, sddm,
  NetworkManager, desktop stack, first-party tools, immutability invariants). Build the
  overlay and deploy it, then read `journalctl -u omarchy-boottest`:

  ```sh
  docker build -t omarchy-atomic-core:44-boottest \
    --build-arg BASE=omarchy-atomic-core:44 \
    -f images/core/hack/boottest/Containerfile .
  ```

- **Install-to-disk deploy test — in `core-image-e2e.yml`**: runs a real `bootc install
  to-disk --composefs-backend --bootloader systemd` and loopback-mounts the result to assert
  systemd-boot on the ESP (no grub), a staged kernel, and the composefs-native deployment
  root layout (`/composefs`, `/ostree`, `/state`).

- **CI — `.github/workflows/core-image-e2e.yml`** (`ubuntu-24.04-arm`): free disk → build core
  → container smoke → install-to-disk deploy assertions → build preinstalls → preinstalls smoke
  → boot-test overlay.

## Asahi: m1n1 & devicetree on atomic

The Asahi bootloader (m1n1) and the machine devicetree are updated by `update-m1n1`, which
on a *mutable* install runs automatically on kernel updates. On bootc/atomic it does **not**,
and — worse — by default it reads the **static** devicetree in `/boot` rather than the one
shipped in the image. A kernel devicetree change (e.g. the 6.19 USB DT change) then boots
stale and breaks hardware. This is the unsolved half of
[images#2](https://github.com/fedora-asahi-remix-atomic-desktops/images/issues/2); neither
the base project nor bazzite handle it.

The core image fixes both:
- **Build time:** `DTBS` in `/etc/sysconfig/update-m1n1` is repointed to
  `/usr/lib/modules/$(uname -r)/dtb` (the image's DT, not `/boot`).
- **Run time:** `omarchy-apply-m1n1.service` runs `update-m1n1` **once per kernel** so the
  boot partition's m1n1 + DT track the running image.

Update flow (two reboots are inherent to Asahi — reboot #1 lands you on the new kernel so
`/usr/lib` has the new DT; reboot #2 boots with it):

```sh
sudo bootc upgrade && reboot     # onto the new image
# omarchy-apply-m1n1.service applies the new m1n1/DT on that boot...
reboot                           # ...and this boot uses it
```

Set `OMARCHY_M1N1_AUTOREBOOT=1` in `/etc/default/omarchy-m1n1` to make the service do reboot
#2 automatically when the DT changed.

## Known bootc follow-ups (tracked; not blockers for the core build)

- **Full config + systemd integration** — *done*: `install/helpers/fedora-image-userland.sh` bakes
  `install.sh`'s system-files + service enablement + `/etc/skel` at build time (SDDM theme,
  `/etc/omarchy.conf`, uwsm/env.d, systemd user units, graphical.target, the shipped `~/.config`).
- **`var-tmpfiles` lint warning** — one residual warning for package-owned dirs
  (`/var/lib/plocate`, `/var/lib/power-profiles-daemon`, `/var/spool/cups-pdf`): ship a
  `/usr/lib/tmpfiles.d` entry (don't delete them — bootc only seeds `/var` on first boot).
- **SELinux** — every shipped file lives in a standard-labeled path (`/usr/libexec`,
  `/usr/lib/systemd/system`, `/etc/profile.d`, `/etc/skel`, `/usr/share/*`), so `bootc install`
  relabels them correctly from the base policy; no custom file_contexts are needed. Runtime service
  denials under enforcing SELinux can only be found on real hardware — a boottest item.
- **omarchy-migrate** — bootc-safe as-is: migration *state* is per-user (`~/.local/state/omarchy/`),
  migrations are read from immutable `/usr/share/omarchy/migrations`, and a Fedora-44 gate skips the
  pacman/Arch/system migrations. Nothing writes the immutable tree.
- **First-boot provisioning idempotence** — `omarchy-{brew,flatpak}-setup` are stamp-gated
  (`/var/lib/omarchy/*-setup-done`) and retry-until-success, so they don't re-run once complete.
- **On-hardware boot** — confirm `U-Boot → systemd-boot → Asahi kernel` + the first-boot
  services (m1n1 apply, user provisioning, brew/flatpak) on a real Mac via the boottest harness.

## Deploy / test

Fresh install onto a disk — systemd-boot requires the composefs-native backend:

```sh
sudo bootc install to-disk --composefs-backend --bootloader systemd \
  --filesystem btrfs --wipe /dev/DISK
```

Or take over an existing Fedora Asahi bootc system (this keeps whatever bootloader is already
installed — the bootloader is chosen at install time, not by `switch`):

```sh
sudo bootc switch <registry>/omarchy-atomic-core:44
```
