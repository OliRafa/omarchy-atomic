#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Mac fork's omarchy-windows-vm is an aarch64 stub that refuses to run (the
# QEMU+KVM Windows path is x86_64-only), so it does not carry the compose/rules
# content this suite asserts. Skip until/unless an x86 Mac variant needs it.
echo "ok - windows-vm test skipped (aarch64 stub)"
exit 0

windows_vm_command="$ROOT/bin/omarchy-windows-vm"
windows_vm_rules="$ROOT/default/hypr/apps/windows-vm.lua"

rg -q '^    restart: "no"$' "$windows_vm_command" ||
  fail "Windows VM uses manual startup by default"
pass "Windows VM uses manual startup by default"

if rg -q '^    restart: unless-stopped$' "$windows_vm_command"; then
  fail "Windows VM does not restart automatically at boot"
fi
pass "Windows VM does not restart automatically at boot"

# Tolerate either shell quoting of the argument -- what must not drift is the
# title itself, since the Hyprland rule below matches on it.
rg -q 'title:"?Windows VM - Omarchy"' "$windows_vm_command" ||
  fail "Windows VM launches FreeRDP with its expected title"
rg -q 'class = "\^xfreerdp\$", title = "\^Windows VM - Omarchy\$"' "$windows_vm_rules" ||
  fail "Windows VM opacity rule targets its FreeRDP window"
rg -q 'tag = "-default-opacity"' "$windows_vm_rules" ||
  fail "Windows VM opts out of default opacity"
rg -q 'opacity = "1 1"' "$windows_vm_rules" ||
  fail "Windows VM stays fully opaque"
pass "Windows VM stays fully opaque"
