# Upstream sync: quattro catch-up

Branch: `merge/upstream-quattro-2026-09` (off `quattro`). Merge base `0ae16948` (2026-08-25); ~311 upstream commits, 416 files, 48 trial-merge conflicts.

## Goal and policy

Bring the fork close to upstream `basecamp/omarchy` quattro. **Follow upstream on everything**, deviating only where the Fedora / bootc / Apple-Silicon platform forces it:

- No pacman/AUR/keyring → dnf at image build, rpm-ostree/bootc for the OS, Flatpak for GUI apps, Homebrew for CLIs (`omarchy-pkg-add`/`-drop` abstract it).
- Bootloader is systemd-boot, not limine/GRUB.
- `/usr` is read-only at runtime — no runtime `/usr` writes; system files land at image build.
- Kernel is dracut + Asahi `kernel-16k`, not mkinitcpio; no `linux-*`/limine kernel plumbing.
- Target is aarch64 Apple Silicon; x86-only features (windows-vm, hybrid-gpu, Intel kernel, broadcom-wl) stay stubbed/inert.

**New software** → Homebrew or Flatpak, unless it must be a system component, in which case install at image build time.

**Final commit** purges everything pacman-related (the machine has no pacman).

**Testing runs on CI/CD only** — not locally. The CLI/shell suites (`./test/all`) run via `.github/workflows/tests.yml`, which currently lives on the `ci-test-suites` branch, not on `quattro`/this branch; `main.yml` on this branch only lints (shellcheck/shfmt) + smoke-runs. So getting suite results for this work needs `tests.yml` present on the branch plus a push/PR to `quattro`. Local `./test/*` runs are noisy anyway: a quattro baseline showed **40 pre-existing failures**, most environment-dependent (no `mise`, no sibling `omarchy-pkgs` checkout, no display for QML). Subtracting the baseline, the merge attributably added ~15 failures (several are new Arch tests → Phase 5; the rest are Fedora adaptations), plus one real regression: `runtime-smoke` widget IPC registration went 3→4. The duplicate-keybinding failure is pre-existing, not merge-caused.

## Conflict-resolution rule

- Take upstream ("theirs") for features/hardening with no platform coupling.
- Keep the fork ("ours") where it made a forced platform deviation (de-pacman'd package helpers, dracut plymouth branch, aarch64 stubs, deleted limine/Intel/pacman artifacts).
- Manual merge where both changed non-trivially (kitty defaults relocation, SKILL.md, capture-screenrecording, a few tests) — take upstream's substance, keep the fork's platform bits.
- `omarchy-upgrade-to-quattro` stays deleted (AGENTS.md: the 3.8→4.0 transition runs through the migration runner).

## Phases (each: SWE → QA `./test/all` + syntax → Review)

1. **Merge & resolve** — `git merge upstream/quattro`, resolve all 48 conflicts to a building tree per the rule above. One merge commit.
2. **Platform adaptations** — harvest upstream's portable hardening into the fork's de-pacman'd commands (`%q` quoting, exit-code, ERR-trap); map package names to Fedora; neutralize the two runtime `/usr`-write migrations (`1787691200` chromium, `1788662350` system-sleep); port the input-group keylogging fix (`1787865477`) pacman-free; keep the dracut branch in `plymouth-set`.
3. **Build wiring** — wire `install/config/etc-files.sh` into `install/helpers/fedora-image-userland.sh` (fixes the timezone bug + lets `/etc` land); add system packages at build in `omarchy-base.packages.core`/`.fedora` with Fedora names: `qt6-qtmultimedia`(+ffmpeg, native video wallpaper), `ffmpegthumbnailer`, `vi`/`vim-minimal`, `cups-pk-helper`; bake `/etc/xdg/kitty/kitty.conf` and the Claude Chromium extension at build.
4. **New software (brew/flatpak)** — AI apps as Flatpak/brew-cask: Claude desktop, Hermes desktop, T3 Code, Perplexity, OpenClaw; CLIs via mise (already user-scope): Cursor `cursor-agent`, Muse, basecamp, cf, Hermes CLI. Port `omarchy-install-ai-*`/`-remove-ai-*`/`theme-set-*` to the Fedora install path; bring the menu/theme/glyph wiring.
5. **Pacman purge** — final atomic commit removing all pacman-related code (helpers' pacman branches, `install/post-install/pacman.sh`, Arch package manifests, pacman references in docs/tests).

## New-software packaging decisions

| Software | Kind | Path |
|----------|------|------|
| Claude desktop | GUI | Flatpak if on Flathub, else brew-cask/skip; **research** |
| Claude Chromium extension | browser ext | bake at image build (was runtime `/usr` write) |
| Hermes desktop | GUI | Flatpak/brew; **research** |
| Hermes CLI | CLI | mise (user-scope) — bring as-is |
| T3 Code | GUI | Flatpak/brew; `theme-set-t3code` writes `~/.t3` (safe) |
| Perplexity | GUI | Flatpak if available, else skip; **research** |
| OpenClaw | web app on local gateway | brew/npm-global; keep launch/onboard (user-scope) |
| Cursor CLI, Muse, basecamp, cf | CLI | mise (user-scope) — bring as-is (Muse ⚠ curls api.meta.ai) |
| qt6-qtmultimedia(+ffmpeg), ffmpegthumbnailer, vi, cups-pk-helper | system pkgs | image build (`.core`/`.fedora`) |

## Status

- [x] Phase 1 — merge & resolve (`67616aa7`); merged origin/quattro too (`20a2dd5b`, stale base)
- [x] CI wired — draft PR #18 to quattro; `tests.yml` added; lint green; suite deps (lua/magick/mise/updatedb) added
- [x] Removed 11 pure Arch/pacman/limine/x86 test files (`88f25a0d`)
- [x] Fixed the 15 crashing test files from CI run 35103314994 (firewall-config by parent `7979b595`; the other 14 in `8945dc8e`..`9afac927`). 10 adapted to the fork, 4 retired:
  - Adapted: `config` (drop pacman ALPM hooks), `video-background` (drop removed `omarchy-upgrade-to-quattro` read), `snapper` (`omarchy-apply-system` rename + drop Arch-ISO/archinstall block), `locate` (tolerate non-UTF-8 `bin/__pycache__` bytecode), `kitty-config` (stub `gum`), `mise-work-path` (keep `mise` on the isolated PATH), `nopasswd-sudo-expiry` (drop `systemd-tmpfiles --inline`, use a conf file), `launch-browser` (rewrite for the `uwsm-app` launcher), `sddm-login` (rewrite → static analysis of Fedora autologin `sddm.sh`), `pkg-drop` (rewrite for `rpm -q`/`dnf remove`).
  - Retired (flagged): `omarchy-kernel-migration` (Arch/limine `linux-omarchy` pacman migration), `update-pkg-prune` (paccache), `update-lock` (upstream update-lock/stay-awake orchestration not ported), `windows-vm-compose` (upstream hardened compose writer not ported; fork ships the un-hardened x86-only original).
  - **Phase 5 must also purge:** `bin/omarchy-update-pkg-prune` (paccache) and `migrations/1789325478.sh` (x86 `linux-omarchy` + Limine boot order). Both self-inert on aarch64 but Arch-only.
  - **Deferred re-adds (not Arch):** re-add `update-lock-test.sh` when the update-lock/stay-awake orchestration is ported into `omarchy-update`; re-add `windows-vm-compose-test.sh` if upstream's hardened `omarchy-windows-vm` writer is adopted.
  - Residual risk resolved: on CI run 35150454888 the count dropped 15→3, leaving `kitty-config` (no-op `gum` stub swallowed the "Close and reopen" guidance → echo its args), `locate` (looped over the AUR-only `omarchy-pkg-aur-install`, absent here → drop it), and `snapper` (discovery ignored `OMARCHY_PKGS_PATH` → honor it). The snapper PKGBUILD content assertions — including `limine-snapper-sync` in `depends_x86_64` — all verified against the real `omarchy-dev`/`omarchy-settings-dev` trees, so none was dropped. Fixes in `a52ce1c4`/`cccef380`/`ec3546bc`; expected 0 files failed next run.
- [ ] Phase 2 — platform adaptations (in progress). Post-Batch-1 CI: 43 suite failures.
- [ ] Phase 3 — build wiring (etc-files.sh + system packages)
- [ ] Phase 4 — new software (brew/flatpak)
- [ ] Phase 5 — pacman purge (also removes channel/menu-guards/nm-transition pacman assertions if not adapted)

### Batch 2 (next): env-deps ffmpeg+xkbcli; mise-work PATH-injection removal; reconstruct install/config/all.sh; theme-staging classify hermes/t3code; investigate provision-user + install-mac.
