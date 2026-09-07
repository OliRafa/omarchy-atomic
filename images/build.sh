#!/usr/bin/env bash
# Build the omarchy-atomic CORE bootc image (Fedora Asahi Remix, aarch64).
# Run on a native aarch64 (Apple Silicon) host.
#
#   ./images/build.sh                       # docker, Fedora 44, first-party tools on
#   WITH_FIRST_PARTY=0 ./images/build.sh    # faster: validate the package set only
#   ENGINE=podman FEDORA=43 ./images/build.sh
set -euo pipefail

FEDORA="${FEDORA:-44}"
TAG="${TAG:-omarchy-atomic-core:$FEDORA}"
WITH_FIRST_PARTY="${WITH_FIRST_PARTY:-1}"
ENGINE="${ENGINE:-docker}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> $ENGINE build $TAG (Fedora $FEDORA, first-party=$WITH_FIRST_PARTY)"
exec "$ENGINE" build \
  -f "$REPO_ROOT/images/core/Containerfile" \
  --build-arg FEDORA="$FEDORA" \
  --build-arg WITH_FIRST_PARTY="$WITH_FIRST_PARTY" \
  -t "$TAG" \
  "$REPO_ROOT"
