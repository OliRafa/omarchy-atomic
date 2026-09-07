# Core OS vs user applications

First step toward the bootc / immutable vision: split the omadora package set into
an **immutable base** and a **writable user-app layer**.

## Principle

A package is **CORE** (baked into the bootc base image) if the shipped desktop or an
**always-loaded** Omarchy config/menu depends on it. Everything discretionary — or
invoked only **on demand** — moves to the writable layer:

| Layer | Delivery | File |
|-------|----------|------|
| Core OS | dnf / COPR / first-party source builds (base image) | `install/omarchy-base.packages.core` |
| GUI user apps | Flatpak (Flathub) | `install/flatpaks` |
| CLI / dev tools | Homebrew (Linuxbrew) | `Brewfile` |

Distinction that decides the CLI cases: **wired into always-loaded shell config**
(eza/bat/zoxide aliases, starship prompt, fastfetch about) → **core**, because the
base shell must work with no brew present. **Invoked on demand** (nvim, tmux, gh,
yt-dlp) → **brew**, resolved via PATH.

## Decisions (2026-09-05)

- **chromium → out** (Flatpak browser; user default = Brave).
- **lightweight default apps → out**: evince (→ `org.gnome.Evince`), imv (→ `org.gnome.Loupe`),
  gnome-calculator. `nautilus`, `mpv`/`mpv-mpris`, `gnome-disk-utility` kept native in core
  after verification — see Open items.
- **docker/moby → stays core** (system daemon; not a Flatpak/brew fit).
- Dev language toolchains + on-demand dev CLIs → brew.
- Heavy apps (obs-studio, kdenlive, pinta, xournalpp, libreoffice, obsidian) → Flatpak.

**Side benefit:** obs-studio, pinta, obsidian and dotnet are in
`install/omarchy-aarch64-unavailable.packages` (they don't build on Arch/aarch64).
Moving them to Flatpak/brew *removes those failures* as well.

## Required callsite repoints BEFORE removing from the base

Some "moved" binaries are invoked by Omarchy scripts/config (ref counts from a grep of
`bin/` + `default/`). Removing them from core without these repoints breaks tooling:

| Binary | Where it's used | Resolution |
|--------|-----------------|-----------|
| chromium/brave (20/8) | `bin/omarchy-launch-webapp`, `mimeapps.list` http(s) | **DONE** — launch-webapp made flatpak-aware (flatpak export dirs + `com.brave.Browser.desktop`/`org.chromium.Chromium.desktop` + `flatpak run <appid> --app`); http(s) default → `com.brave.Browser.desktop` |
| imv (3) | `mimeapps.list`, `hypr/apps/system.lua`, `omarchy-plymouth-preview` | **DONE** — image mimes → `org.gnome.Loupe.desktop`; window rules add `org.gnome.Loupe`; preview uses `xdg-open` |
| mpv (7) | capture / screenrecord / ytdlp-host, `mimeapps.list` video | **KEPT CORE** — v4l2 webcam overlay breaks under Flatpak sandbox; no repoint |
| nautilus (10) | launch-nautilus(-cwd), theme-bg-install, retroarch, `mimeapps.list` dir | **KEPT CORE** — not on Flathub (404) + native-binary launched |

`evince`, `gnome-calculator`, `htop`, `tldr`, `whois` have **0**
tooling refs — clean to move.

## Open items

- **Kept native in core after verification** (not user apps in practice): `gnome-disk-utility`
  (fronts udisks2; not in Flatpak/brew), `nautilus` (not on Flathub; native-binary launched),
  `mpv`/`mpv-mpris` (v4l2 webcam overlay + shell MPRIS bridge).
- **Homebrew bootstrap is a core concern**: the base image must install brew and export
  its shellenv (a `/etc/profile.d` drop-in) so on-demand tooling resolves `nvim`/`tmux`/`gh`.
- **IDs verified 2026-09-05** against Flathub / homebrew-core: every Flatpak id and brew
  formula returns 200 except `org.gnome.Nautilus` (404), which is why nautilus stays core.
