#!/usr/bin/env bash
# Boot-entry repair for deploy/omarchy-atomic-grow-esp.
#
# Growing the ESP destroys the partition that follows it. Any systemd-boot entry still naming that
# partition is a booby trap: `systemd.mount-extra=UUID=<gone>:/boot:vfat:…` makes systemd wait on a
# mount that can never appear, local-fs.target fails, and the machine lands in emergency mode —
# after the partition table has already been rewritten, so there is no easy way back.
#
# So the repair runs BEFORE the destructive phase, and it is keyed on "this UUID is not the ESP"
# rather than on the absorbed partition's UUID. Once the table is rewritten that partition is gone
# and its filesystem UUID can no longer be read, which would leave a half-finished run unable to
# clean up after itself.
#
# Pure filesystem: unit-tested off-hardware in deploy/tests/esp-boot-entries.test.sh.

# esp_repoint_entries ESP_MNT ESP_VOLID — in every <ESP_MNT>/loader/entries/*.conf, rewrite
# `boot=UUID=<other>` to ESP_VOLID and delete `systemd.mount-extra=UUID=<other>:…` for every
# <other> that is not ESP_VOLID. Prints one line per change.
# Returns 0 if anything changed, 1 if there was nothing to do.
esp_repoint_entries() {
  local mnt="$1" volid="$2" dir entry uuid changed=0
  dir="$mnt/loader/entries"
  [[ -d $dir ]] || return 1
  for entry in "$dir"/*.conf; do
    [[ -e $entry ]] || continue
    while read -r uuid; do
      [[ -n $uuid ]] || continue
      [[ ${uuid,,} != "${volid,,}" ]] || continue
      sed -i -e "s/boot=UUID=$uuid/boot=UUID=$volid/g" \
             -e "s/[[:space:]]*systemd\.mount-extra=UUID=$uuid:[^[:space:]]*//g" "$entry"
      echo "==> $(basename "$entry"): repointed UUID=$uuid -> the ESP ($volid)"
      changed=1
    done < <(esp_entry_foreign_uuids "$entry")
  done
  return $(( ! changed ))
}

# esp_entry_foreign_uuids ENTRY — every filesystem UUID an entry names in `boot=UUID=` or
# `systemd.mount-extra=UUID=`, deduplicated. The mount-extra value is `UUID=<uuid>:<where>:…`, so
# the UUID stops at the first colon.
esp_entry_foreign_uuids() {
  grep -oE '(boot=UUID=|systemd\.mount-extra=UUID=)[^ :]+' "$1" 2>/dev/null \
    | sed 's/.*UUID=//' | sort -u
}
