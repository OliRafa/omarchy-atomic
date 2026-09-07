#!/usr/bin/env bash
# Build an omarchy-atomic bootc image. Run on a native aarch64 (Apple Silicon) host.
#
#   ./images/build.sh core          # -> omarchy-atomic-core:$FEDORA
#   ./images/build.sh preinstalls   # -> omarchy-atomic:$FEDORA (FROM the core image)
#
#   WITH_FIRST_PARTY=0 ./images/build.sh core   # faster: validate the core package set only
#   ENGINE=podman FEDORA=43 ./images/build.sh core
set -euo pipefail

TARGET="${1:-core}"
FEDORA="${FEDORA:-44}"
WITH_FIRST_PARTY="${WITH_FIRST_PARTY:-1}"
ENGINE="${ENGINE:-docker}"
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
  *)
    echo "usage: $0 [core|preinstalls]" >&2; exit 2 ;;
esac
