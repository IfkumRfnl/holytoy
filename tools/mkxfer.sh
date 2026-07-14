#!/usr/bin/env bash
# Build the FAT32 transfer disk from scratch (host->guest direction).
# Usage: mkxfer.sh XFER_IMG [SRC.HC]
#   Creates XFER_IMG with an MBR + one FAT32 partition containing:
#     RUN.HC   - guest autorun payload (from guest/RUN.HC, params substituted)
#     MAIN.HC  - the user's HolyC source (if SRC given)
#   Guest writes LOG.TXT / STAT.TXT back to the same disk.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"

XFER="${1:?usage: mkxfer.sh XFER_IMG [SRC.HC]}"
SRC="${2:-}"
mkdir -p "$(dirname "$XFER")"

rm -f "$XFER"
truncate -s "${XFER_SIZE}M" "$XFER"

# mtools config: drive X = our image, partition 1
export MTOOLSRC="$(dirname "$XFER")/mtools.conf"
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
mcopy -o "$ROOT/src/holytoy/HTMATH.HC" x:/HTMATH.HC
mcopy -o "$ROOT/src/holytoy/HTRENDER.HC" x:/HTRENDER.HC
mcopy -o "$ROOT/src/holytoy/HTLEX.HC" x:/HTLEX.HC
mcopy -o "$ROOT/src/holytoy/HTPARSE.HC" x:/HTPARSE.HC
mcopy -o "$ROOT/src/holytoy/HTLOWER.HC" x:/HTLOWER.HC
mcopy -o "$ROOT/src/holytoy/HTEMIT.HC" x:/HTEMIT.HC
mcopy -o "$ROOT/src/holytoy/HTCOMP.HC" x:/HTCOMP.HC
if [ -n "${HOLYTOY_GLSL:-}" ]; then
    mcopy -o "$HOLYTOY_GLSL" x:/SHADER.GLS
fi
# GUI marker: tells RUN.HC to leave the guest running instead of rebooting.
if [ -n "${HOLYTOY_GUI:-}" ]; then
    echo gui | mcopy -o - x:/GUI.TXT
fi
# Headless editor proof: HT.HC enters its interactive loop, while RUN.HC still
# owns status extraction and reboot after the test sends ESC.
if [ -n "${HOLYTOY_EDIT_TEST:-}" ]; then
    echo edit | mcopy -o - x:/EDIT.TXT
fi
