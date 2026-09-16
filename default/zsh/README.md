Omarchy shell configuration for the Zsh shell.

## Install

```bash
# Install zsh from Homebrew (Omarchy delivers CLI tools via brew)
brew install zsh

# Set zsh up for Omarchy (writes ~/.zshrc and, optionally, auto-launches zsh from bash)
omarchy-setup-zsh
```

`omarchy-setup-zsh` installs zsh with Homebrew automatically if it is missing,
so running it on its own is enough on a normal Omarchy system. If you already
have a `~/.zshrc`, it asks whether to keep your current config or replace it
with the Omarchy defaults (backing your file up first) before continuing.

Omarchy does not change your login shell. It keeps bash as the login shell
(safer for scripts) and, when you opt in, has interactive bash `exec` into zsh.

## fzf Keybindings
- **Ctrl+Alt+F** - Search files/directories
- **Ctrl+Alt+L** - Search Git Log
- **Ctrl+R** - Search command history
- **Ctrl+T** - Search files in current directory
- **Ctrl+V** - Search Variables
- **Alt+C** - cd into selected directory

## Customization

To add your own configuration or override defaults:

```bash
# Edit your .zshrc
nvim ~/.zshrc

# Add customizations at the bottom, after the omarchy zsh config is sourced
```

The default `~/.zshrc` sources `~/.local/share/omarchy/default/zsh/rc`, which
loads every file under `~/.local/share/omarchy/default/zsh/conf.d/` and
`~/.local/share/omarchy/default/zsh/functions/`. Your own customizations in
`~/.zshrc` take precedence over the defaults.

## Uninstall

```bash
brew uninstall zsh
```

To restore bash, copy a backup over `~/.bashrc` (backups are saved as
`~/.bashrc.backup-*`), or remove the "Auto-launch zsh shell" block that
`omarchy-setup-zsh` added near the top of `~/.bashrc`.
