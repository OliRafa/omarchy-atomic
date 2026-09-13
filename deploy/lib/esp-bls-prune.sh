#!/usr/bin/env bash
# Prune half-written BLS boot entries from the ESP.
#
# bootc's composefs backend stages a deployment as
#   <ESP>/EFI/Linux/bootc_composefs-<verity>/{vmlinuz,initrd}
# writing vmlinuz first and initrd second. If it dies between the two — the ESP filling up is the
# way we hit it, but a power cut or a ^C does the same — the directory survives with vmlinuz and no
# initrd.
#
# That debris is not inert. On the NEXT upgrade bootc calls find_vmlinuz_initrd_duplicate(), which
# walks every `bootc_composefs-*` directory under <ESP>/EFI/Linux and hashes vmlinuz + initrd in
# each one (compute_boot_digest_type1, crates/lib/src/bootc_composefs/boot.rs). One directory
# missing its initrd fails the whole operation, before anything is written:
#
#   error: Upgrading composefs: … Setting up BLS boot: Checking boot entry duplicates:
#          Computing boot digest for Type1 entries: Opening initrd: No such file or directory
#
# So a single interrupted upgrade permanently blocks every later one, and freeing space does not
# help — the machine is wedged until the corpse is removed. Worse, the ESP backup/restore in
# omarchy-atomic-grow-esp faithfully preserves it, so growing the ESP alone leaves you stuck at the
# same place with a different error.
#
# A directory missing either half is unbootable by definition: systemd-boot cannot load an entry
# whose initrd does not exist, so nothing is lost by deleting it. A COMPLETE directory is never
# touched here — that is bootc's own garbage collection to do, and one of them is what you booted.
#
# Pure filesystem: unit-tested off-hardware in deploy/tests/esp-bls-prune.test.sh.

ESP_BLS_DIR="${ESP_BLS_DIR:-EFI/Linux}"
ESP_BLS_PREFIX="${ESP_BLS_PREFIX:-bootc_composefs-}"

# esp_partial_bls_dirs ESP_MNT — name every bootc_composefs-* directory that is missing vmlinuz or
# initrd, one per line (bare directory name, not a path).
esp_partial_bls_dirs() {
  local mnt="$1" dir name
  [[ -d $mnt/$ESP_BLS_DIR ]] || return 0
  for dir in "$mnt/$ESP_BLS_DIR/$ESP_BLS_PREFIX"*; do
    [[ -d $dir ]] || continue
    if [[ -f $dir/vmlinuz && -f $dir/initrd ]]; then
      continue
    fi
    name="$(basename "$dir")"
    printf '%s\n' "$name"
  done
}

# esp_prune_partial_bls ESP_MNT — delete each partial directory and any loader entry that points at
# it. Prints one line per removal. Returns 0 if it removed something, 1 if there was nothing to do.
esp_prune_partial_bls() {
  local mnt="$1" name entry removed=0 missing
  while read -r name; do
    [[ -n $name ]] || continue
    missing=""
    [[ -f $mnt/$ESP_BLS_DIR/$name/vmlinuz ]] || missing+=" vmlinuz"
    [[ -f $mnt/$ESP_BLS_DIR/$name/initrd ]] || missing+=" initrd"
    echo "==> pruning half-written boot entry $name (missing:$missing)"
    rm -rf "${mnt:?}/$ESP_BLS_DIR/$name"
    for entry in "$mnt"/loader/entries/*.conf; do
      [[ -e $entry ]] || continue
      grep -q "$name" "$entry" || continue
      echo "==> removing its loader entry $(basename "$entry")"
      rm -f "$entry"
    done
    removed=1
  done < <(esp_partial_bls_dirs "$mnt")
  return $(( ! removed ))
}
