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

# Rolling screendumps; the guest reboots itself when done (-no-reboot => exit).
sleep "$BOOT_GRACE"
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

[ -f "$FRAMES/last-good.png" ] && cp -f "$FRAMES/last-good.png" "$LATEST_PNG"

# Pull guest-written files off the transfer disk.
export MTOOLSRC="$ROOT/images/mtools.conf"
mcopy -o x:/LOG.TXT  "$GUEST_LOG"    2>/dev/null || true
mcopy -o x:/STAT.TXT "$OUT/status"   2>/dev/null || true

STATUS="$(tr -d '\r\0' <"$OUT/status" 2>/dev/null | head -1 || true)"

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
