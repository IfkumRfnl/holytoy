#!/usr/bin/env bash
# One holytoy cycle: inject SRC into the transfer disk, boot a fresh overlay
# of the golden image headless, collect a screenshot + guest logs, shut down.
#
# Usage: run.sh SRC.HC
#
# Outputs (predictable paths, overwritten every run):
#   out/latest.png   last stable frame of the guest screen
#   out/guest.log    guest-side log (includes compiler/runtime errors)
#   out/status       raw guest status line
#
# Exit codes:
#   0  guest compiled and ran SRC successfully
#   1  guest reported a compile/runtime error (see out/guest.log)
#   2  harness failure: timeout, guest never reported status, missing deps
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"

SRC="${1:?usage: run.sh SRC.HC}"
[ -f "$SRC" ] || { echo "run.sh: no such file: $SRC" >&2; exit 2; }
[ -f "$GOLDEN" ] || { echo "run.sh: golden image missing — run 'make golden' first" >&2; exit 2; }

# One VM cycle at a time: overlay, transfer disk and out/ are shared state.
# Concurrent callers (e.g. two agents) queue here instead of corrupting runs.
exec 9>"$ROOT/images/run.lock"
if ! flock -w 300 9; then
    echo "run.sh: another run held the lock >300s — giving up" >&2
    exit 2
fi

SOCK="$ROOT/images/qmp-run.sock"
FRAMES="$OUT/frames"
mkdir -p "$OUT" "$FRAMES"
rm -f "$LATEST_PNG" "$GUEST_LOG" "$OUT/status" "$FRAMES"/*.png "$SOCK"

"$ROOT/tools/mkxfer.sh" "$SRC"

# Fresh overlay every run: guest disk corruption is a non-event.
rm -f "$OVERLAY"
qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY"

"$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$OVERLAY",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display none -no-reboot \
    -qmp unix:"$SOCK",server,nowait \
    >"$OUT/qemu.log" 2>&1 &
QPID=$!

cleanup() { kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; }
trap cleanup EXIT

# TempleOS's MBR loader stops at a drive menu; "1" = boot C. Sent twice for
# timing slack — early presses wait in the BIOS keyboard buffer, and a
# duplicate is swallowed harmlessly by the guest's input queue.
sleep 3
python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true
sleep 2
python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true

# Rolling screendumps start right away — the whole cycle can be ~12s and the
# guest only holds the final picture for HT_SHOW_MS, so early boot frames are
# fine (the newest good frame wins).
sleep 1
START=$SECONDS
TIMED_OUT=0
N=0
while kill -0 "$QPID" 2>/dev/null; do
    if (( SECONDS - START > RUN_TIMEOUT )); then
        TIMED_OUT=1
        echo "run.sh: hard timeout after ${RUN_TIMEOUT}s — killing VM" >&2
        break
    fi
    if python3 "$ROOT/tools/qmp.py" "$SOCK" screendump "$FRAMES/cur.png" 2>/dev/null; then
        cp -f "$FRAMES/cur.png" "$FRAMES/last-good.png"
        N=$((N+1))
    fi
    sleep "$FRAME_INTERVAL"
done
cleanup
trap - EXIT

if [ -f "$FRAMES/last-good.png" ]; then
    cp -f "$FRAMES/last-good.png" "$LATEST_PNG"
    # Machine-readable view of the final screen (exact glyph OCR).
    python3 "$ROOT/tools/scrtext.py" "$LATEST_PNG" >"$OUT/screen.txt" 2>/dev/null || true
fi

# Pull guest-written files off the transfer disk.
export MTOOLSRC="$ROOT/images/mtools.conf"
mcopy -o x:/LOG.TXT  "$GUEST_LOG"    2>/dev/null || true
mcopy -o x:/STAT.TXT "$OUT/status"   2>/dev/null || true

# The guest log is a DolDoc dump ($...$ control codes) — strip to plain text.
STRIP="$ROOT/skills/holyc/scripts/strip_doldoc.py"
if [ -f "$GUEST_LOG" ] && [ -f "$STRIP" ]; then
    python3 "$STRIP" <"$GUEST_LOG" 2>/dev/null |
        tr -d '\000-\010\013\014\016-\037' >"$GUEST_LOG.tmp" &&
        mv -f "$GUEST_LOG.tmp" "$GUEST_LOG"
fi

STATUS=""
[ -f "$OUT/status" ] && STATUS="$(tr -d '\r\0' <"$OUT/status" | head -1)"

if (( TIMED_OUT )); then
    echo "run.sh: FAIL(timeout) status='${STATUS:-none}' log=$GUEST_LOG png=$LATEST_PNG" >&2
    exit 2
fi
case "$STATUS" in
    OK*)
        echo "run.sh: OK  png=$LATEST_PNG log=$GUEST_LOG (${N} frames)"
        exit 0 ;;
    ERR*)
        echo "run.sh: GUEST ERROR — $(cat "$GUEST_LOG" 2>/dev/null | tail -5)" >&2
        exit 1 ;;
    *)
        echo "run.sh: FAIL(no guest status) — hook never ran? log=$GUEST_LOG" >&2
        exit 2 ;;
esac
