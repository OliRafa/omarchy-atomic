#!/usr/bin/env bash
# ESP backup/restore for the plain-bootc Asahi install (deploy/omarchy-atomic-install).
#
# `bootc install` manages ONLY <ESP>/EFI (systemd-boot). Everything else on the Asahi ESP is the
# preboot + install-identity layer bootc knows nothing about: m1n1/ (stage 2 + U-Boot + DTB),
# vendorfw/ (per-machine firmware), asahi/ (firmware source + VGID identity), ubootefi.var (U-Boot
# NVRAM). We can't know up front whether `bootc install` reformats the ESP or writes into it, so:
#   esp_backup  — snapshot the WHOLE ESP before install.
#   esp_restore — after install, put back every entry bootc removed, EXCEPT EFI/ (bootc's, freshly
#                 written systemd-boot; restoring the OLD EFI/ over it would clobber the new
#                 bootloader — the exact bug this guards against).
#
# Both are pure filesystem ops (no root / podman / hardware) so the copy-and-replace logic can be
# e2e-tested off-hardware; see deploy/tests/esp-backup.test.sh.

# esp_backup ESP BK  — mirror the entire ESP (dotfiles included) into a fresh BK dir.
esp_backup() {
  local esp="$1" bk="$2"
  rm -rf "$bk"; mkdir -p "$bk"
  cp -a "$esp/." "$bk/"
}

# esp_restore ESP BK  — restore each top-level BK entry that no longer exists on ESP, except EFI/.
# If bootc reformatted the ESP, this brings the preboot layer back; if bootc wrote in place, every
# entry still exists and this is a no-op. Prints per-entry progress + a summary line to stdout.
esp_restore() {
  local esp="$1" bk="$2" restored="" entry name
  for entry in "$bk"/* "$bk"/.[!.]*; do
    [ -e "$entry" ] || continue                 # unmatched glob stays literal — skip
    name="$(basename "$entry")"
    [ "$name" = EFI ] && continue               # bootc owns EFI/ now — keep its systemd-boot
    [ -e "$esp/$name" ] && continue             # bootc left it in place — nothing to do
    echo "==> ESP was reinitialized — restoring $name from backup"
    cp -a "$entry" "$esp/$name"; restored="$restored $name"
  done
  [ -n "$restored" ] && echo "==> restored:$restored" || echo "==> ESP left intact by bootc (nothing to restore)"
}
