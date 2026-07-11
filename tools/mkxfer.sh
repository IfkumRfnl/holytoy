#!/usr/bin/env bash
# Build the FAT32 transfer disk from scratch (host->guest direction).
# Usage: mkxfer.sh [SRC.HC]
#   Creates $XFER with an MBR + one FAT32 partition containing:
#     RUN.HC   - guest autorun payload (from guest/RUN.HC, params substituted)
#     MAIN.HC  - the user's HolyC source (if SRC given)
#   Guest writes LOG.TXT / STAT.TXT back to the same disk.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"

SRC="${1:-}"

rm -f "$XFER"
truncate -s "${XFER_SIZE}M" "$XFER"

# mtools config: drive X = our image, partition 1
export MTOOLSRC="$ROOT/images/mtools.conf"
printf 'drive x: file="%s" partition=1\nmtools_skip_check=1\n' "$XFER" >"$MTOOLSRC"

mpartition -I x:                 # wipe/init MBR
mpartition -c -a x:              # create + activate partition spanning the disk
mformat -F x:                    # FAT32

# mpartition picks type 0x06 (FAT16) for small disks; TempleOS BlkDevAdd only
# mounts MBR types 0x0B/0x0C/... as FAT32 (Kernel/BlkDev/DskAddDev.HC). Patch
# the partition type byte (MBR offset 446+4) to 0x0C (FAT32 LBA).
printf '\x0c' | dd of="$XFER" bs=1 seek=450 conv=notrunc status=none

mcopy -o "$ROOT/guest/ONCE.HC" x:/ONCE.HC
mcopy -o "$ROOT/guest/RUN.HC" x:/RUN.HC
if [ -n "$SRC" ]; then
    mcopy -o "$SRC" x:/MAIN.HC
fi
# GUI marker: tells RUN.HC to leave the guest running instead of rebooting.
if [ -n "${HOLYTOY_GUI:-}" ]; then
    echo gui | mcopy -o - x:/GUI.TXT
fi
