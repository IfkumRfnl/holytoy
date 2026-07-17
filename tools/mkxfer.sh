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
mcopy -o "$ROOT/src/holytoy/HTLIB.HC" x:/HTLIB.HC
mcopy -o "$ROOT/src/holytoy/HTPP.HC" x:/HTPP.HC
mcopy -o "$ROOT/src/holytoy/HTLEX.HC" x:/HTLEX.HC
mcopy -o "$ROOT/src/holytoy/HTPARSE.HC" x:/HTPARSE.HC
mcopy -o "$ROOT/src/holytoy/HTLOWER.HC" x:/HTLOWER.HC
mcopy -o "$ROOT/src/holytoy/HTEMIT.HC" x:/HTEMIT.HC
mcopy -o "$ROOT/src/holytoy/HTCOMP.HC" x:/HTCOMP.HC
if [ -n "${HOLYTOY_GLSL:-}" ]; then
    mcopy -o "$HOLYTOY_GLSL" x:/SHADER.GLS
fi
# Corpus batch mode: ship every prepped shader plus the CORPUS.TXT manifest;
# HT.HC compiles them all in one boot and prints HT CORPUS markers.
if [ -n "${HOLYTOY_CORPUS_DIR:-}" ]; then
    [ -f "$HOLYTOY_CORPUS_DIR/CORPUS.TXT" ] || {
        echo "mkxfer.sh: HOLYTOY_CORPUS_DIR has no CORPUS.TXT (run tools/glsl_prep.py)" >&2
        exit 2
    }
    mcopy -o "$HOLYTOY_CORPUS_DIR"/S*.GLS x:/
    mcopy -o "$HOLYTOY_CORPUS_DIR/CORPUS.TXT" x:/CORPUS.TXT
fi
# GUI marker: tells RUN.HC to leave the guest running instead of rebooting.
if [ -n "${HOLYTOY_GUI:-}" ]; then
    echo gui | mcopy -o - x:/GUI.TXT
fi
# Optional deterministic/adaptive render-scale selection for tests and runs.
if [ -n "${HOLYTOY_SCALE:-}" ]; then
    echo "$HOLYTOY_SCALE" | mcopy -o - x:/SCALE.TXT
fi
# Optional shading-core pin (plan 012): 1..mp_cnt shades in the background
# render task, or "auto" for mp_cnt. HT.HC reads E:/CORES.TXT.
if [ -n "${HOLYTOY_CORES:-}" ]; then
    echo "$HOLYTOY_CORES" | mcopy -o - x:/CORES.TXT
fi
# plan 013: HOLYTOY_F32=0 turns the emitter's F32-semantics mode off (F64
# path); any other value leaves the default-on mode alone.
if [ "${HOLYTOY_F32:-}" = "0" ]; then
    echo 0 | mcopy -o - x:/F32.TXT
fi
# plan 014: HOLYTOY_HWF32=0 keeps F32 semantics but reverts to the plan-013
# software rounding path (A/B escape hatch for the PC24 hardware mode).
if [ "${HOLYTOY_HWF32:-}" = "0" ]; then
    echo 0 | mcopy -o - x:/HWF32.TXT
fi
# Visual-oracle dump request: HT.HC writes V00A/V00B sample DATs after a
# successful single-shader GLSL compile (plan 010).
if [ -n "${HOLYTOY_VISDUMP:-}" ]; then
    echo visdump | mcopy -o - x:/VISDUMP.TXT
fi
# Headless editor proof: HT.HC enters its interactive loop, while RUN.HC still
# owns status extraction and reboot after the test sends ESC.
if [ -n "${HOLYTOY_EDIT_TEST:-}" ]; then
    echo edit | mcopy -o - x:/EDIT.TXT
fi

# TempleOS FAT32 gotcha (found in plan 010, 64-entry corpus disk): the
# guest's FAT32DirNew cannot extend a root directory whose mtools-written
# chain ends in an EXACTLY-full cluster with no zeroed terminator entry --
# the first in-guest FileWrite throws 'Drv' and wedges the drive. The
# guest's own writes always pre-allocate a zeroed terminator cluster, so
# only the host-written count matters. mformat creates no volume label and
# all names here are 8.3 (one entry each): keep the entry count off the
# 16-per-512-byte-cluster boundary with a one-entry pad file.
ENTRIES="$(mdir -b x:/ 2>/dev/null | wc -l)"
if [ $((ENTRIES % 16)) -eq 0 ]; then
    echo pad | mcopy -o - x:/PAD.TXT
fi
