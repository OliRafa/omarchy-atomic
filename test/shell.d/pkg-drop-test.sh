#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_path="$test_tmp/pkg-drop-bin"
mkdir -p "$mock_path"
calls="$test_tmp/dnf-calls"

# The fork removes RPMs on Fedora: it asks `rpm -q` which names are actually
# installed and drops only those. Exact names match; a virtual/provide name that
# is not itself an installed package does not.
cat >"$mock_path/rpm" <<'EOF'
#!/bin/bash
case "${2:-}" in
  exact-package | provider-package) exit 0 ;;
  *) exit 1 ;;
esac
EOF

# Removal goes through `sudo dnf remove -y <pkg>`; record each removal target.
cat >"$mock_path/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_CALLS"
EOF

chmod +x "$mock_path/rpm" "$mock_path/sudo"

PATH="$mock_path:$PATH" TEST_CALLS="$calls" \
  "$ROOT/bin/omarchy-pkg-drop" exact-package virtual-package provider-package

[[ -f $calls ]] || fail "an installed package is removed"
grep -qx 'dnf remove -y exact-package' "$calls" ||
  fail "the installed exact package is removed" "$(cat "$calls" 2>/dev/null)"
grep -qx 'dnf remove -y provider-package' "$calls" ||
  fail "the installed provider package is removed" "$(cat "$calls" 2>/dev/null)"
! grep -q 'virtual-package' "$calls" ||
  fail "a package that is not installed is never removed" "$(cat "$calls")"
pass "package removal targets only the exact installed package names"
