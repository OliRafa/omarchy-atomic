# Chromium is the shipped default browser, delivered as a Flatpak preinstall rather than through
# omarchy-install-browser, and fresh installs mark every migration as already applied. Without this,
# the bundled extensions load but have no native messaging host to talk to. The host helpers write
# into the Flatpak per-app config tree (~/.var/app/org.chromium.Chromium/...) as well as the native
# profile roots.
omarchy-install-chromium-copy-url
omarchy-install-chromium-ytdlp
