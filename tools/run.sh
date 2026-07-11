#!/usr/bin/env bash
# Run one HolyC source in an isolated headless TempleOS VM.
# Usage: run.sh SRC.HC
#
# The first stdout line is RUN_DIR=/absolute/path. That directory owns this
# invocation's latest.png, screen.txt, guest.log, status, frames, and disks.
# Set RUN_DIR to reserve a new/empty direct child of out/runs.
#
# Exit codes: 0 = guest success, 1 = guest compile/runtime error,
#             2 = harness failure.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
. "$ROOT/tools/run-common.sh"

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: run.sh SRC.HC" >&2; exit 2; }
[ -f "$SRC" ] || { echo "run.sh: no such file: $SRC" >&2; exit 2; }
[ -f "$GOLDEN" ] || { echo "run.sh: golden image missing - run 'make golden' first" >&2; exit 2; }
REQUESTED_RUN_DIR="${RUN_DIR:-}"
holy_validate_run_settings run.sh || exit 2
holy_allocate_run_dir run.sh run "$REQUESTED_RUN_DIR" || exit 2

OVERLAY="$RUN_DIR/overlay.qcow2"
XFER="$RUN_DIR/xfer.img"
SOCK="$RUN_DIR/qmp.sock"
FRAMES="$RUN_DIR/frames"
LATEST_PNG="$RUN_DIR/latest.png"
GUEST_LOG="$RUN_DIR/guest.log"
STATUS_FILE="$RUN_DIR/status"
QPID=""

cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$QPID" ]; then
        kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -f -- "$OVERLAY" "$SOCK"
    exit "$rc"
}
trap cleanup EXIT

echo "RUN_DIR=$RUN_DIR"
"$ROOT/tools/prune-runs.sh" "$KEEP_RUNS" || {
    echo "run.sh: could not prune old runs" >&2
    exit 2
}
mkdir -p "$FRAMES" || exit 2

if ! "$ROOT/tools/mkxfer.sh" "$XFER" "$SRC"; then
    echo "run.sh: could not create transfer disk" >&2
    exit 2
fi
if ! qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY"; then
    echo "run.sh: could not create VM overlay" >&2
    exit 2
fi

holy_acquire_vm_slot run.sh || exit 2
printf '%s\n' "$SLOT" >"$RUN_DIR/slot"

"$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$OVERLAY",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display none -no-reboot \
    -qmp unix:"$SOCK",server,nowait \
    >"$RUN_DIR/qemu.log" 2>&1 &
QPID=$!

# TempleOS's MBR loader stops at a drive menu; "1" = boot C. Duplicate early
# keypresses are harmless and cover timing variation under TCG.
sleep 3
python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true
sleep 2
python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true

sleep 1
START=$SECONDS
TIMED_OUT=0
N=0
while kill -0 "$QPID" 2>/dev/null; do
    if (( SECONDS - START > RUN_TIMEOUT )); then
        TIMED_OUT=1
        echo "run.sh: hard timeout after ${RUN_TIMEOUT}s - killing VM" >&2
        break
    fi
    if python3 "$ROOT/tools/qmp.py" "$SOCK" screendump "$FRAMES/cur.png" 2>/dev/null; then
        cp -f "$FRAMES/cur.png" "$FRAMES/last-good.png"
        cp -f "$FRAMES/cur.png" "$(printf '%s/frame-%04d.png' "$FRAMES" "$N")"
        N=$((N + 1))
    fi
    sleep "$FRAME_INTERVAL"
done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

if [ -f "$FRAMES/last-good.png" ]; then
    cp -f "$FRAMES/last-good.png" "$LATEST_PNG"
    python3 "$ROOT/tools/scrtext.py" "$LATEST_PNG" >"$RUN_DIR/screen.txt" 2>/dev/null || true
fi

# Best-effort animated GIF from the trailing frames; it never affects status.
frame_files=("$FRAMES"/frame-*.png)
if [ -e "${frame_files[0]}" ]; then
    ANIM_DIR="$FRAMES/anim"
    rm -rf "$ANIM_DIR"
    mkdir -p "$ANIM_DIR"
    start=0
    (( ${#frame_files[@]} > ANIM_FRAMES )) && start=$((${#frame_files[@]} - ANIM_FRAMES))
    i=0
    for ((index=start; index<${#frame_files[@]}; index++)); do
        cp -f "${frame_files[$index]}" "$(printf '%s/%03d.png' "$ANIM_DIR" "$i")"
        i=$((i + 1))
    done
    ffmpeg -v quiet -y -framerate 2 -i "$ANIM_DIR/%03d.png" "$RUN_DIR/anim.gif" || true
fi

export MTOOLSRC="$RUN_DIR/mtools.conf"
mcopy -o x:/LOG.TXT "$GUEST_LOG" 2>/dev/null || true
mcopy -o x:/STAT.TXT "$STATUS_FILE" 2>/dev/null || true

STRIP="$ROOT/skills/holyc/scripts/strip_doldoc.py"
if [ -f "$GUEST_LOG" ] && [ -f "$STRIP" ]; then
    python3 "$STRIP" <"$GUEST_LOG" 2>/dev/null |
        tr -d '\000-\010\013\014\016-\037' >"$GUEST_LOG.tmp" &&
        mv -f "$GUEST_LOG.tmp" "$GUEST_LOG"
fi

STATUS=""
[ -f "$STATUS_FILE" ] && STATUS="$(tr -d '\r\0' <"$STATUS_FILE" | head -1)"

if (( TIMED_OUT )); then
    echo "run.sh: FAIL(timeout) status='${STATUS:-none}' log=$GUEST_LOG png=$LATEST_PNG" >&2
    exit 2
fi
case "$STATUS" in
    OK*)
        echo "run.sh: OK  png=$LATEST_PNG log=$GUEST_LOG (${N} frames)"
        exit 0 ;;
    ERR*)
        echo "run.sh: GUEST ERROR - $(tail -5 "$GUEST_LOG" 2>/dev/null)" >&2
        exit 1 ;;
    *)
        echo "run.sh: FAIL(no guest status) - hook never ran? log=$GUEST_LOG" >&2
        exit 2 ;;
esac
