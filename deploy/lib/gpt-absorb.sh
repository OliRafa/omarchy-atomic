#!/usr/bin/env bash
# GPT table surgery for deploy/omarchy-atomic-grow-esp: grow the ESP by absorbing the partition
# that follows it.
#
# Everything here operates on an `sfdisk -d` dump — text in, text out — so the dangerous part (what
# the new partition table will actually say) is unit-testable off-hardware without a block device;
# see deploy/tests/gpt-absorb.test.sh.
#
# Why a dump-edit-reapply round trip rather than `sfdisk --delete` + a resize: the dump names every
# partition's `uuid=` explicitly, so re-applying it preserves each PARTUUID verbatim. That is not a
# nicety on Asahi — /proc/device-tree/chosen/asahi,efi-system-partition holds the ESP's PARTUUID,
# and m1n1 stage 1 uses it to find <ESP>/m1n1/boot.bin. Change it and the machine stops booting
# before Linux is ever reached.
#
# An `sfdisk -d` dump looks like:
#   label: gpt
#   label-id: 8A4F…
#   device: /dev/nvme0n1
#   unit: sectors
#   first-lba: 34
#   last-lba: 1953525134
#
#   /dev/nvme0n1p4 : start=  1234567, size=  1024000, type=C12A7328-…, uuid=6F3E…, name="EFI"
#   /dev/nvme0n1p5 : start=  2258567, size=  2097152, type=BC13C2FF-…, uuid=A1B2…, name="XBOOTLDR"

# gpt_field NODE KEY [DUMP_FILE] — print partition NODE's KEY (start, size, type, uuid, name).
# Empty output (status 1) when the node or key is absent.
gpt_field() {
  local node="$1" key="$2" file="${3:--}"
  awk -v node="$node" -v key="$key" '
    $1 != node || $2 != ":" { next }
    {
      line = $0
      sub(/^[^:]*:[[:space:]]*/, "", line)
      n = split(line, parts, /,[[:space:]]*/)
      for (i = 1; i <= n; i++) {
        eq = index(parts[i], "=")
        if (eq == 0) continue
        k = substr(parts[i], 1, eq - 1)
        v = substr(parts[i], eq + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        gsub(/^"|"$/, "", v)
        if (k == key) { print v; found = 1 }
      }
    }
    END { exit !found }
  ' "$file"
}

# gpt_absorb_size ESP_NODE ABSORB_NODE [DUMP_FILE] — the ESP's new size in sectors: everything from
# the ESP's start through the end of ABSORB_NODE, so any gap between the two is reclaimed too.
# Fails (message on stderr) unless ABSORB_NODE really lies after the ESP and nothing else is
# parked in the range being swallowed.
gpt_absorb_size() {
  local esp="$1" absorb="$2" file="${3:--}" dump
  dump="$(cat "$file")"

  local esp_start esp_size ab_start ab_size
  esp_start="$(gpt_field "$esp" start <<<"$dump")" || { echo "gpt_absorb_size: $esp not in table" >&2; return 1; }
  esp_size="$(gpt_field "$esp" size <<<"$dump")"   || { echo "gpt_absorb_size: $esp has no size" >&2; return 1; }
  ab_start="$(gpt_field "$absorb" start <<<"$dump")" || { echo "gpt_absorb_size: $absorb not in table" >&2; return 1; }
  ab_size="$(gpt_field "$absorb" size <<<"$dump")"   || { echo "gpt_absorb_size: $absorb has no size" >&2; return 1; }

  if (( ab_start <= esp_start )); then
    echo "gpt_absorb_size: $absorb starts at $ab_start, before $esp at $esp_start — the ESP can only grow forwards" >&2
    return 1
  fi

  local ab_end=$((ab_start + ab_size))

  # Anything else living inside [esp_start, ab_end) would be overwritten by the grown ESP.
  local other other_start other_size
  while read -r other; do
    [[ -z $other || $other == "$esp" || $other == "$absorb" ]] && continue
    other_start="$(gpt_field "$other" start <<<"$dump")" || continue
    other_size="$(gpt_field "$other" size <<<"$dump")" || continue
    if (( other_start < ab_end && other_start + other_size > esp_start )); then
      echo "gpt_absorb_size: $other (start=$other_start size=$other_size) sits between $esp and $absorb — refusing" >&2
      return 1
    fi
  done < <(gpt_nodes <<<"$dump")

  printf '%s\n' "$((ab_end - esp_start))"
}

# gpt_nodes [DUMP_FILE] — every partition node in the dump, in table order.
gpt_nodes() {
  local file="${1:--}"
  awk '$2 == ":" && $3 ~ /^start=/ { print $1 }' "$file"
}

# gpt_absorb_table ESP_NODE ABSORB_NODE NEW_SIZE [DUMP_FILE] — the dump with ABSORB_NODE dropped
# and ESP_NODE's size set to NEW_SIZE sectors. Every other field of every other partition —
# uuid, type, name, start — is passed through untouched.
gpt_absorb_table() {
  local esp="$1" absorb="$2" newsize="$3" file="${4:--}"
  awk -v esp="$esp" -v absorb="$absorb" -v newsize="$newsize" '
    $1 == absorb && $2 == ":" { next }
    $1 == esp && $2 == ":" { sub(/size=[[:space:]]*[0-9]+/, "size= " newsize) }
    { print }
  ' "$file"
}
