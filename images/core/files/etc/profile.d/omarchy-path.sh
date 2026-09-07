# omarchy-atomic core: keep OMARCHY_PATH pointed at the in-image tree so scripts that
# resolve assets relative to it work. The omarchy-* commands themselves are symlinked
# into /usr/bin at image build time, so PATH already carries them.
export OMARCHY_PATH="/usr/share/omarchy"
