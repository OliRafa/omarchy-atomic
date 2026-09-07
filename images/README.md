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

## Known bootc follow-ups (tracked; not blockers for the core build)

- **`/usr/local` vs `/usr`** — `install/helpers/fedora-first-party.sh` installs into
  `/usr/local/bin`, which is `/var`-backed on bootc (won't update on image upgrades).
  Retarget the core tools to `/usr`.
- **Homebrew on first boot** — the image ships only the `/etc/profile.d` shellenv hook;
  installing brew (into `/home/linuxbrew`) and applying the `Brewfile` belongs to a
  first-boot service in the preinstalls / user layer.
- **Full config + systemd integration** — this core image installs packages + tree +
  PATH, not the whole of `install.sh` (login/session/system-file steps). Layer next.
- **`bootc container lint`** runs advisory here; make it a hard gate once the above land.

## Deploy / test

On an Apple-Silicon host already on Fedora Asahi bootc:

```sh
sudo bootc switch --transport registry <registry>/omarchy-atomic-core:44
```

or turn the image into an installable disk with
[`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder).
