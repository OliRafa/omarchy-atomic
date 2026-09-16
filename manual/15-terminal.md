# Terminal

[Foot](https://codeberg.org/dnkl/foot) is the default terminal for Omarchy. It's fast, lightweight, and compatible with even old computers. It does not, however, support native tabs or splits.

If you use Tmux, you may not mind, but if not, you can install _Kitty_ under _Install > Terminal_ in the Omarchy menu — it's delivered through [Homebrew](https://brew.sh/), the same as Omarchy's other CLI tools.

_Alacritty_ and _Ghostty_ are still perfectly good terminals, but they aren't published on Flathub or as Homebrew Linux builds, so Omarchy no longer installs them for you — that part is on you. Install either one however you prefer (for example `sudo dnf install alacritty`), then make it your default by putting its desktop entry (`Alacritty.desktop` or `com.mitchellh.ghostty.desktop`) on the first line of `~/.config/xdg-terminals.list`. Everything else — `Super + Return`, theming — follows along once that entry is in place.

You start a new terminal using `Super + Return`. (This binding will automatically point to whichever Terminal you've set up, and you can switch between Foot and Kitty under _Setup > Defaults > Terminal_.)

## Tmux

Tmux provides a consistent, programmable interface for panes, windows (aka tabs), and resumable sessions regardless of your terminal. It even works on remote hosts, so when you're SSH'ing into a server, you can use the same approach.

You start a new Tmux session in a fresh terminal using `Super + Alt + Return`, and because Tmux is a persistent process, you can resume your session even if you close that terminal. Just hit `Ctrl + Space` (called the prefix key) then `s` to see all your active sessions.

Omarchy ships with an ergonomically-optimized Tmux configuration, which has a lot of keybindings to learn, so keep [the cheatsheet handy](07-hotkeys.md#tmux).

## Tmux layout functions

Because Tmux is programmable, we can use functions to create layouts. Omarchy ships with four different functions for common developer layouts.

`tdl [agent]` starts a three-way split IDE-like interface with the `$EDITOR` on the left, your chosen AI agent on the right (like `c` for opencode or `cx` for Claude or `codex` for OpenAI), and then a terminal at the bottom.

So `tdl c` would start this (or just `ic`):

 ![tmux-tdl](images/tmux-tdl.webp)

You can also start a second agent with `tdl c cx` (opencode + claude) (or just `icx`):

 ![tmux-tdl2](images/tmux-tdl2.webp)

There's also `tds`, which starts a four-way square with the editor top left, a live diff watcher top right, a terminal bottom left, and opencode bottom right.

You can also start this layout configuration for every subdirectory in the current directory using `tdlm [agent]`, then navigate using `alt + 1/2/3/4/5/...`:

 ![tmux-tdlm](images/tmux-tdlm.webp)

Finally, you can start a swarm of agents using `tsl [panes] [command]`. So `tsl 4 c` will give you a four-way grid of opencode agents:

 ![tmux-tsl](images/tmux-tsl.webp)
