#!/bin/bash

# omarchy-screensaver hides the mouse cursor while it runs (hyprctl cursor:invisible true) and shows
# it again on exit. The bug this guards: it hid the cursor FIRST and only then checked for tte
# (terminaltexteffects), the PyPI-only engine it renders with. On any machine without tte — every
# Fedora image, since tte is neither a Fedora package nor a brew formula — it hid the pointer, printed
# "tte is not installed", and exit 1'd WITHOUT restoring the cursor (the restore only ran from the
# signal trap, never on that exit). The mouse vanished until the next `hyprctl cursor:invisible false`.
#
# Invariants: (1) an EXIT trap restores the cursor however the script leaves; (2) tte is checked
# BEFORE the cursor is hidden, so a missing tte never hides it in the first place.

source "$(dirname "$0")/base-test.sh"

script="$ROOT/bin/omarchy-screensaver"
[[ -f $script ]] || fail "omarchy-screensaver ships"
pass "omarchy-screensaver ships"

# An EXIT trap must restore the cursor — the belt-and-suspenders against any exit path leaving it
# hidden. `restore_cursor` must set cursor invisible=false.
grep -qE '^trap restore_cursor EXIT' "$script" ||
  fail "an EXIT trap restores the cursor on any exit" "$(grep -n 'trap' "$script")"
pass "an EXIT trap restores the cursor on any exit"

grep -qE 'restore_cursor\(\)' "$script" &&
  grep -A3 'restore_cursor\(\)' "$script" | grep -q 'invisible = false' ||
  fail "restore_cursor sets the cursor visible again" "$(grep -nA3 'restore_cursor()' "$script")"
pass "restore_cursor makes the cursor visible again"

# Ordering: the tte availability check must come before the line that hides the cursor.
tte_check_line=$(grep -nE 'command -v tte' "$script" | head -1 | cut -d: -f1)
hide_line=$(grep -nE 'invisible = true' "$script" | head -1 | cut -d: -f1)
[[ -n $tte_check_line && -n $hide_line ]] ||
  fail "both the tte check and the cursor-hide are present" "tte=$tte_check_line hide=$hide_line"
(( tte_check_line < hide_line )) ||
  fail "the tte check must run BEFORE the cursor is hidden (tte@$tte_check_line, hide@$hide_line)" \
    "$(grep -nE 'command -v tte|invisible = true' "$script")"
pass "tte is checked before the cursor is hidden ($tte_check_line < $hide_line)"

# And the missing-tte exit must itself come before the hide, so it can never strand the cursor.
missing_exit_line=$(grep -nE 'tte\) is not installed' "$script" | head -1 | cut -d: -f1)
[[ -n $missing_exit_line ]] || fail "the missing-tte branch is present"
(( missing_exit_line < hide_line )) ||
  fail "the missing-tte exit must be before the cursor is hidden" \
    "missing@$missing_exit_line hide@$hide_line"
pass "a missing tte bails out before hiding the cursor"
