#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

# The edge channel installs omarchy-dev instead of plain omarchy, so a query for
# omarchy finds nothing there. Stub rpm (the Fedora fork queries rpm, not pacman):
# `rpm -q <pkg>` tests presence, `rpm -q --qf <fmt> <pkg>` prints the version.
cat >"$stub_bin/rpm" <<'STUB'
#!/bin/bash
[[ $1 == "-q" ]] || exit 1
shift
qf=""
[[ ${1:-} == "--qf" ]] && { qf="$2"; shift 2; }
for package in "$@"; do
  case ",${OMARCHY_TEST_PACKAGES:-}," in
    *",$package,"*)
      [[ -n $qf ]] && echo "${OMARCHY_TEST_VERSION:-4.0.0-1}"
      exit 0
      ;;
  esac
done
echo "package '${*: -1}' is not installed" >&2
exit 1
STUB
chmod +x "$stub_bin/rpm"

version() {
  OMARCHY_TEST_PACKAGES="$1" \
    OMARCHY_PATH="${2:-/usr/share/omarchy}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-version"
}

[[ $(version omarchy) == "4.0.0-1" ]] || fail "version reports the stable package"
pass "version reports the stable package"

[[ $(version omarchy-dev) == "4.0.0-1" ]] || fail "version reports the edge package"
pass "version reports the edge package"

# A checkout reports its hash instead, so packages are irrelevant there.
[[ $(version "" "$test_tmp/checkout") == "dev" ]] || fail "version reports a dev checkout"
pass "version reports a dev checkout"

if version "" >/dev/null 2>&1; then
  fail "version fails when no Omarchy package is installed"
fi
pass "version fails when no Omarchy package is installed"

# The snapshot description is only a label, so a failed lookup must not abort
# the update under set -e.
snapshot_desc=$(
  set -e
  PATH="$stub_bin:$PATH" OMARCHY_TEST_PACKAGES="" OMARCHY_PATH=/usr/share/omarchy \
    bash -c 'DESC="$(omarchy-version 2>/dev/null || echo unknown)"; echo "$DESC"' 2>/dev/null
) || fail "snapshot survives an unknown version"

[[ $snapshot_desc == "unknown" ]] || fail "snapshot labels an unknown version" "actual: $snapshot_desc"
pass "snapshot survives an unknown version"
