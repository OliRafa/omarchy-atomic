# omarchy-atomic — CLI / developer tools delivered via Homebrew (Linuxbrew)
# Installed into the user-writable brew prefix (/home/linuxbrew/.linuxbrew),
# NOT baked into the immutable base image.
#
# PREREQUISITE (core concern): the base image must bootstrap Homebrew and put
# its shellenv on PATH for Omarchy's on-demand tooling (a /etc/profile.d drop-in),
# so callsites like omarchy-default-editor (nvim), tmux, gh resolve. See
# docs/immutability/core-vs-apps.md.
#
# Formula names marked "TODO verify" need confirming against homebrew-core.

# --- Editor (default editor: omarchy-launch-editor / omarchy-default-editor call nvim) ---
brew "neovim"
brew "tree-sitter"
brew "luarocks"
brew "lua"                  # replaces compat-lua / compat-lua-libs

# --- Language toolchains (were dnf; brew is the versioned-toolchain sweet spot) ---
brew "rust"                 # cargo + rustc  # TODO verify (or use rustup-init)
brew "llvm"                 # provides clang
brew "ruby"
brew "libyaml"
brew "openjdk"              # java-latest-openjdk
brew "dotnet"              # dotnet-runtime-9.0 (also fixes aarch64)  # TODO verify
brew "poetry"              # python3-poetry-core
brew "libpq"
brew "mariadb-connector-c"

# --- Dev CLIs (on-demand; PATH-resolved) ---
brew "gh"

# --- General CLI utilities ---
brew "tmux"
brew "htop"
brew "yt-dlp"
brew "tealdeer"            # tldr client
brew "dua-cli"            # TODO verify formula name
brew "whois"
brew "inxi"               # TODO verify (may not be in homebrew-core; keep dnf if absent)
