# omarchy-atomic bootc images

Two-image design for the bootc PoC:

| Image | Contents | Status |
|-------|----------|--------|
| **core** — `images/core/Containerfile` | Fedora Asahi base-atomic + Omarchy Hyprland core (`install/omarchy-base.packages.core`) + core first-party tools (tensaku, voxtype, tobi-try, hyprland-preview-share-picker) + PATH/brew shell hooks | **building now** |
| **preinstalls** — *later* | `FROM core` + removable app-like tools (aether, cliamp, omacut, omawrite) + default Flatpaks (`install/flatpaks`) + Homebrew bootstrap (`Brewfile`) | TODO |

## Base image

`quay.io/fedora-asahi-remix-atomic-desktops/base-atomic:44` — the unofficial Fedora
Asahi Remix bootc base with **no desktop environment**, already carrying the Asahi
kernel (`kernel-16k`), Apple firmware, u-boot/m1n1 glue and dracut. That's why we don't
hand-assemble a kernel: the hard Apple-Silicon boot bits come from the base, and we
only layer the Omarchy desktop on top. Tags `43` and `44` are published.

## Build (native aarch64 / Apple Silicon)

```sh
./images/build.sh                     # docker, Fedora 44, first-party tools on
WITH_FIRST_PARTY=0 ./images/build.sh  # faster: validate the package set only
ENGINE=podman FEDORA=43 ./images/build.sh
```

## e2e tests

Modeled on `home-servers-setup/ultron-os` (build-from-source, then assert). Split in two
because our image is aarch64 Fedora Asahi — its `kernel-16k` only boots on real Apple
Silicon, so the ultron-os-style qemu boot test isn't possible in generic CI.

- **Container smoke test — `images/core/hack/smoke.sh`** (runs now, anywhere aarch64):
  runs the built image as a container and asserts the userspace — Asahi base, core desktop
  packages, docker/nautilus/mpv/gnome-disk-utility kept in core, the omarchy tree + commands
  on PATH, the four core first-party tools in `/usr/bin` (not the `/usr/local` symlink), the
  preinstall "bloat" absent, the profile.d hooks, and the mimeapps repoints.

  ```sh
  ./images/build.sh && ./images/core/hack/smoke.sh
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

- **CI — `.github/workflows/core-image-e2e.yml`**: on an `ubuntu-24.04-arm` runner, builds
  the image (first-party on, `bootc container lint` in-build), runs the container smoke test,
  and builds the boot-test overlay.

## Known bootc follow-ups (tracked; not blockers for the core build)

- **`/usr/local` vs `/usr`** — `install/helpers/fedora-first-party.sh` installs into
  `/usr/local/bin`, which is `/var`-backed on bootc (won't update on image upgrades).
  Retarget the core tools to `/usr`.
- **Homebrew on first boot** — the image ships only the `/etc/profile.d` shellenv hook;
  installing brew (into `/home/linuxbrew`) and applying the `Brewfile` belongs to a
  first-boot service in the preinstalls / user layer.
- **Full config + systemd integration** — this core image installs packages + tree +
  PATH, not the whole of `install.sh` (login/session/system-file steps). Layer next.
- **`bootc container lint` is a hard gate and passes** (12 checks). One residual
  `var-tmpfiles` warning remains for package-owned dirs (`/var/lib/plocate`,
  `/var/lib/power-profiles-daemon`, `/var/spool/cups-pdf`): ship a
  `/usr/lib/tmpfiles.d` entry for them (they must not simply be deleted — bootc treats
  `/var` as machine-state and only seeds it on first boot).

## Deploy / test

On an Apple-Silicon host already on Fedora Asahi bootc:

```sh
sudo bootc switch --transport registry <registry>/omarchy-atomic-core:44
```

or turn the image into an installable disk with
[`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder).
