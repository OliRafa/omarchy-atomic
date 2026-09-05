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
- **lightweight default apps → out**: nautilus, evince, imv, mpv, gnome-calculator,
  gnome-disk-utility.
- **docker/moby → stays core** (system daemon; not a Flatpak/brew fit).
- Dev language toolchains + on-demand dev CLIs → brew.
- Heavy apps (obs-studio, kdenlive, pinta, xournalpp, libreoffice, obsidian) → Flatpak.

**Side benefit:** obs-studio, pinta, obsidian and dotnet are in
`install/omarchy-aarch64-unavailable.packages` (they don't build on Arch/aarch64).
Moving them to Flatpak/brew *removes those failures* as well.

## Required callsite repoints BEFORE removing from the base

Some "moved" binaries are invoked by Omarchy scripts/config (ref counts from a grep of
`bin/` + `default/`). Removing them from core without these repoints breaks tooling:

| Binary | Where it's used | Repoint needed |
|--------|-----------------|----------------|
| chromium/brave (20/8) | `bin/omarchy-launch-webapp` `pick_chromium_desktop()` | add `com.brave.Browser.desktop` / `org.chromium.Chromium.desktop` to the desktop-id list |
| imv (3) | `default/applications/mimeapps.list`, `default/hypr/apps/system.lua` | point image mime + keybind at `org.gnome.Loupe` (or chosen viewer) |
| mpv (7) | `omarchy-capture-screenrecording`, `omarchy-cmd-screenrecord`, `omarchy-chromium-ytdlp-host` | invoke `flatpak run io.mpv.Mpv` (or keep mpv core as a media engine) |
| nautilus (10) | dropbox/retroarch service installers, skill docs | Flatpak nautilus is default FM; python-extension integrations (dropbox) degrade |

`evince`, `gnome-calculator`, `gnome-disk-utility`, `htop`, `tldr`, `whois` have **0**
tooling refs — clean to move.

## Open items

- **gnome-disk-utility**: no first-class Flatpak (needs host udisks2). Keep native as a
  core exception, or drop? Currently in neither list.
- **Homebrew bootstrap is a core concern**: the base image must install brew and export
  its shellenv (a `/etc/profile.d` drop-in) so on-demand tooling resolves `nvim`/`tmux`/`gh`.
- Verify the `# TODO verify` Flatpak ids and brew formula names against Flathub / homebrew-core.
- mpv is the one item where the "lightweight apps out" decision conflicts with tooling; flagged above.
