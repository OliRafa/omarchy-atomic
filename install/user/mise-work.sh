# Setup default work directory (and tries)
mkdir -p "$HOME/Work"
mkdir -p "$HOME/Work/tries"

# omarchy-provision-user --first-install sets OMARCHY_SETUP_CONTEXT=iso-chroot, which upstream only
# ever reaches from the ISO. The fork installs by git clone, so that context is entered on a live
# system with no /opt/packages at all - and the bundled tarball is linux-x64, which this aarch64
# fork could not use anyway. Treat it as an optimisation and fall through to a normal mise install
# whenever it is not there.
NODE_TARBALL=""
if [[ ${OMARCHY_SETUP_CONTEXT:-runtime} == "iso-chroot" ]]; then
  case "$(uname -m)" in
    x86_64) NODE_TARBALL_ARCH=x64 ;;
    aarch64) NODE_TARBALL_ARCH=arm64 ;;
    *) NODE_TARBALL_ARCH=$(uname -m) ;;
  esac
  NODE_TARBALL=$(find /opt/packages -name "node-v*-linux-${NODE_TARBALL_ARCH}.tar.gz" -type f 2>/dev/null | head -n1)
fi

if [[ -n $NODE_TARBALL ]]; then
  NODE_VERSION=$(basename "$NODE_TARBALL" | sed 's/node-v\(.*\)-linux-.*\.tar\.gz/\1/')
  NODE_INSTALL_DIR="$HOME/.local/share/mise/installs/node/$NODE_VERSION"

  mkdir -p "$NODE_INSTALL_DIR"
  tar -xzf "$NODE_TARBALL" --strip-components=1 -C "$NODE_INSTALL_DIR"
  mise use -g node@"$NODE_VERSION"
else
  mise use -g node@latest
fi
