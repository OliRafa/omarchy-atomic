# omarchy-atomic core: Homebrew (Linuxbrew) shellenv, if brew has been installed on the
# writable layer. The immutable base only ships this hook; installing brew (into
# /home/linuxbrew) and applying the Brewfile is a first-boot / user-layer step. Silent
# when brew is absent.
for _omarchy_brew in /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  if [ -x "$_omarchy_brew" ]; then
    eval "$("$_omarchy_brew" shellenv)"
    break
  fi
done
unset _omarchy_brew
