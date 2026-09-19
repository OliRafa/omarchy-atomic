#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The fork's channel model is a single git-clone tracking the quattro branch, not
# pacman channels: stable/rc/edge all collapse onto `omarchy-branch-set quattro`
# plus the normal update, and dev links a local checkout. State lives in a file,
# not /etc/pacman.conf.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log_file="$test_tmp/channel.log"
mkdir -p "$stub_bin" "$test_tmp/home"

write_logging_stub() {
  local name="$1"
  cat >"$stub_bin/$name" <<STUB
#!/bin/bash
printf '$name' >>"\$OMARCHY_CHANNEL_TEST_LOG"
for arg in "\$@"; do printf '\t%s' "\$arg" >>"\$OMARCHY_CHANNEL_TEST_LOG"; done
printf '\n' >>"\$OMARCHY_CHANNEL_TEST_LOG"
STUB
  chmod +x "$stub_bin/$name"
}

write_logging_stub omarchy-branch-set
write_logging_stub omarchy-dev-link
write_logging_stub omarchy-update

cat >"$stub_bin/gum" <<'STUB'
#!/bin/bash
printf 'gum' >>"$OMARCHY_CHANNEL_TEST_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$OMARCHY_CHANNEL_TEST_LOG"; done
printf '\n' >>"$OMARCHY_CHANNEL_TEST_LOG"
exit "${GUM_EXIT:-0}"
STUB
chmod +x "$stub_bin/gum"

# Log every git call, and answer the few queries omarchy-channel-set makes: the
# origin URL, the tracked branch, and a clone that materializes a checkout.
cat >"$stub_bin/git" <<'STUB'
#!/bin/bash
printf 'git' >>"$OMARCHY_CHANNEL_TEST_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$OMARCHY_CHANNEL_TEST_LOG"; done
printf '\n' >>"$OMARCHY_CHANNEL_TEST_LOG"

args=("$@")
[[ ${args[0]:-} == -C ]] && args=("${args[@]:2}")
case "${args[0]:-}" in
remote) echo "https://github.com/omacom/omarchy.git" ;;
rev-parse) echo "quattro" ;;
clone)
  dest="${args[$((${#args[@]} - 1))]}"
  mkdir -p "$dest/.git" "$dest/bin" "$dest/default" "$dest/shell"
  ;;
esac
STUB
chmod +x "$stub_bin/git"

cat >"$stub_bin/omarchy-dev-status" <<'STUB'
#!/bin/bash
printf '%s\n' "${OMARCHY_TEST_DEV_STATUS:-dev-link: inactive}"
STUB
chmod +x "$stub_bin/omarchy-dev-status"

STATE_FILE="$test_tmp/home/.local/state/omarchy/channel"

run_channel_set() {
  : >"$log_file"
  OMARCHY_CHANNEL_TEST_LOG="$log_file" \
    OMARCHY_PATH="$ROOT" \
    HOME="$test_tmp/home" \
    PATH="$stub_bin:$ROOT/bin:$PATH" \
    "$ROOT/bin/omarchy-channel-set" "$@"
}

assert_log_line() {
  grep -Fx -- "$1" "$log_file" >/dev/null || fail "$2" "$(cat "$log_file")"
  pass "$2"
}

for channel in stable rc edge; do
  rm -f "$STATE_FILE"
  run_channel_set "$channel"
  assert_log_line $'omarchy-branch-set\tquattro' "$channel switches the checkout to the quattro branch"
  assert_log_line $'omarchy-update\t-y' "$channel runs the normal update pipeline"
  [[ $(<"$STATE_FILE") == stable ]] || fail "$channel records the stable channel state"
  pass "$channel records the stable channel state"
done

set +e
run_channel_set bogus >"$test_tmp/out" 2>"$test_tmp/err"
status=$?
set -e
(( status != 0 )) || fail "an unknown channel is rejected"
grep -q "Unknown channel: bogus" "$test_tmp/err" || fail "an unknown channel explains itself" "$(cat "$test_tmp/err")"
pass "an unknown channel is rejected with an explanation"

rm -f "$STATE_FILE"
set +e
GUM_EXIT=1 run_channel_set dev >"$test_tmp/out" 2>"$test_tmp/err"
set -e
grep -q "Cancelled." "$test_tmp/out" || fail "declining the dev warning cancels the switch" "$(cat "$test_tmp/out")"
[[ ! -f $STATE_FILE ]] || fail "declining the dev warning still records a channel"
if grep -q $'^git\tclone' "$log_file"; then fail "declining the dev warning still clones a checkout" "$(cat "$log_file")"; fi
pass "declining the dev warning cancels without touching the checkout"

checkout="$test_tmp/home/Work/omarchy"
rm -f "$STATE_FILE"
OMARCHY_DEV_PATH="$checkout" run_channel_set dev
assert_log_line $'git\tclone\t--branch\tquattro\thttps://github.com/omacom/omarchy.git\t'"$checkout" "dev clones a fresh checkout from origin"
assert_log_line $'omarchy-dev-link\t'"$checkout" "dev links the fresh checkout"
[[ $(<"$STATE_FILE") == dev ]] || fail "dev records the dev channel state"
pass "dev clones and links a fresh checkout"

OMARCHY_DEV_PATH="$checkout" run_channel_set dev
if grep -q $'^git\tclone' "$log_file"; then fail "dev re-clones an existing checkout" "$(cat "$log_file")"; fi
assert_log_line $'git\t-C\t'"$checkout"$'\tfetch\torigin\tquattro' "dev fetches an existing checkout"
assert_log_line $'git\t-C\t'"$checkout"$'\tpull\t--ff-only\torigin\tquattro' "dev fast-forwards an existing checkout"
pass "switching back to dev reuses the existing checkout"

current_channel() {
  local dev_status="$1" state="$2" home="$test_tmp/current-home"
  rm -rf "$home"
  mkdir -p "$home/.local/state/omarchy"
  [[ -z $state ]] || printf '%s' "$state" >"$home/.local/state/omarchy/channel"
  OMARCHY_TEST_DEV_STATUS="$dev_status" HOME="$home" PATH="$stub_bin:$ROOT/bin:$PATH" "$ROOT/bin/omarchy-channel-current"
}

[[ $(current_channel "dev-link: inactive" stable) == stable ]] || fail "current channel reads the recorded stable state"
pass "current channel reads the recorded stable state"
[[ $(current_channel "dev-link: inactive" "") == stable ]] || fail "current channel defaults to stable with no recorded state"
pass "current channel defaults to stable with no recorded state"
[[ $(current_channel $'dev-link: configured\n  path: x' stable) == dev ]] || fail "an active dev link overrides the recorded channel"
pass "an active dev link overrides the recorded channel"
