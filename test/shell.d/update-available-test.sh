#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy-update-available is a pure git branch-divergence check on $OMARCHY_PATH
# (the fork's git-clone update model), not a pacman/checkupdates query.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

upstream="$test_tmp/upstream"
repo="$test_tmp/repo"

git init --quiet "$upstream"
git -C "$upstream" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m base
git clone --quiet "$upstream" "$repo"

set +e
output=$(OMARCHY_PATH="$repo" "$ROOT/bin/omarchy-update-available")
status=$?
set -e
(( status == 1 )) || fail "update checker exits non-zero when the checkout is current" "$output"
[[ $output == "Omarchy is up to date on"* ]] || fail "update checker reports the up-to-date branch" "$output"
pass "update checker reports up to date when the checkout matches its upstream"

git -C "$upstream" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m new
git -C "$repo" fetch --quiet origin

set +e
output=$(OMARCHY_PATH="$repo" "$ROOT/bin/omarchy-update-available")
status=$?
set -e
(( status == 0 )) || fail "update checker exits successfully when omarchy update is available" "$output"
[[ $output == "Omarchy update available (1 commit(s) behind"* ]] ||
  fail "update checker reports how far behind the checkout is" "$output"
pass "update checker reports available commits when behind the upstream branch"

detached="$test_tmp/detached"
git clone --quiet "$upstream" "$detached"
git -C "$detached" checkout --quiet --detach

set +e
output=$(OMARCHY_PATH="$detached" "$ROOT/bin/omarchy-update-available")
status=$?
set -e
(( status == 1 )) || fail "update checker exits non-zero with no upstream tracking branch" "$output"
[[ $output == *"no upstream tracking branch"* ]] ||
  fail "update checker explains there is no upstream tracking branch" "$output"
pass "update checker reports up to date when there is no upstream tracking branch"
