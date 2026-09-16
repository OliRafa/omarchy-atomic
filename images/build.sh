#!/usr/bin/env bash
# Build an omarchy-atomic bootc image. Run on a native aarch64 (Apple Silicon) host.
#
#   ./images/build.sh core                # -> omarchy-atomic-core:$FEDORA
#   ./images/build.sh preinstalls         # -> omarchy-atomic:$FEDORA (FROM the core image)
#   ./images/build.sh fairydust-core      # -> omarchy-atomic-fairydust-core:$FEDORA (FROM core; kernel swap)
#   ./images/build.sh fairydust-core-usb4 # -> omarchy-atomic-fairydust-core-usb4:$FEDORA (test image; 7.2 USB4+DP-alt kernel)
#
#   WITH_FIRST_PARTY=0 ./images/build.sh core   # faster: validate the core package set only
#   ENGINE=podman FEDORA=43 ./images/build.sh core
#   FDK_IMAGE=ghcr.io/olirafa/omarchy-fairydust-kernel:44 ./images/build.sh fairydust-core
set -euo pipefail

TARGET="${1:-core}"
FEDORA="${FEDORA:-44}"
WITH_FIRST_PARTY="${WITH_FIRST_PARTY:-1}"
ENGINE="${ENGINE:-docker}"
FDK_IMAGE="${FDK_IMAGE:-}"   # defaulted per fairydust target below
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$TARGET" in
  core)
    TAG="${TAG:-omarchy-atomic-core:$FEDORA}"
    echo "==> $ENGINE build $TAG (core, Fedora $FEDORA, first-party=$WITH_FIRST_PARTY)"
    exec "$ENGINE" build \
      -f "$REPO_ROOT/images/core/Containerfile" \
      --build-arg FEDORA="$FEDORA" \
      --build-arg WITH_FIRST_PARTY="$WITH_FIRST_PARTY" \
      -t "$TAG" "$REPO_ROOT" ;;
  preinstalls)
    TAG="${TAG:-omarchy-atomic:$FEDORA}"
    echo "==> $ENGINE build $TAG (preinstalls, FROM omarchy-atomic-core:$FEDORA)"
    exec "$ENGINE" build \
      -f "$REPO_ROOT/images/preinstalls/Containerfile" \
      --build-arg TAG="$FEDORA" \
      -t "$TAG" "$REPO_ROOT" ;;
  fairydust-core)
    FDK_IMAGE="${FDK_IMAGE:-ghcr.io/olirafa/omarchy-fairydust-kernel:latest}"
    TAG="${TAG:-omarchy-atomic-fairydust-core:$FEDORA}"
    echo "==> $ENGINE build $TAG (fairydust-core, FROM omarchy-atomic-core:$FEDORA, kernel=$FDK_IMAGE)"
    exec "$ENGINE" build \
      -f "$REPO_ROOT/images/fairydust-core/Containerfile" \
      --build-arg TAG="$FEDORA" \
      --build-arg FDK_IMAGE="$FDK_IMAGE" \
      -t "$TAG" "$REPO_ROOT" ;;
  fairydust-core-usb4)
    # Side/test variant: identical kernel-swap to fairydust-core, but consumes the 7.2 USB4 + DP-alt
    # kernel and tags the bootc image distinctly so it never overwrites the production fairydust-core.
    # Build that kernel first, in the kernel repo:
    #   USB4=1 ./build.sh        # -> omarchy-fairydust-kernel:$FEDORA-usb4
    FDK_IMAGE="${FDK_IMAGE:-omarchy-fairydust-kernel:$FEDORA-usb4}"
    TAG="${TAG:-omarchy-atomic-fairydust-core-usb4:$FEDORA}"
    echo "==> $ENGINE build $TAG (fairydust-core-usb4 TEST image, FROM omarchy-atomic-core:$FEDORA, kernel=$FDK_IMAGE)"
    exec "$ENGINE" build \
      -f "$REPO_ROOT/images/fairydust-core/Containerfile" \
      --build-arg TAG="$FEDORA" \
      --build-arg FDK_IMAGE="$FDK_IMAGE" \
      -t "$TAG" "$REPO_ROOT" ;;
  *)
    echo "usage: $0 [core|preinstalls|fairydust-core|fairydust-core-usb4]" >&2; exit 2 ;;
esac
