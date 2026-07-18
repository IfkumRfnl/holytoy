#!/usr/bin/env bash
# Capture a smooth demo GIF of a shader animating inside HolyToy.
# Usage: demo_gif.sh SRC.glsl OUT.gif [NFRAMES] [INTERVAL] [SCALE]
#
# Unlike run.sh (whose rolling screendumps serve the proof loop), this boots
# a GUI-mode session headless — the app animates indefinitely in HtInteract —
# and samples the screen at a GIF-friendly cadence, then assembles a
# palette-optimized GIF. docs/img/demo.gif is:
#   tools/demo_gif.sh <prepped ldjBW1>.glsl docs/img/demo.gif 80 0.15 2
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
. "$ROOT/tools/run-common.sh"

SRC="${1:-}"; OUTGIF="${2:-}"
[ -n "$SRC" ] && [ -n "$OUTGIF" ] || { echo "usage: demo_gif.sh SRC.glsl OUT.gif [NFRAMES] [INTERVAL] [SCALE]" >&2; exit 2; }
[ -f "$SRC" ] || { echo "demo_gif.sh: no such file: $SRC" >&2; exit 2; }
[ -f "$GOLDEN" ] || { echo "demo_gif.sh: golden image missing - run 'make golden' first" >&2; exit 2; }
NFRAMES="${3:-80}"
INTERVAL="${4:-0.15}"
SCALE="${5:-2}"

holy_validate_run_settings demo_gif.sh || exit 2
holy_allocate_run_dir demo_gif.sh gif || exit 2
OVERLAY="$RUN_DIR/overlay.qcow2"
XFER="$RUN_DIR/xfer.img"
SOCK="$RUN_DIR/qmp.sock"
FRAMES="$RUN_DIR/frames"
QPID=""
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$QPID" ]; then
        python3 "$ROOT/tools/qmp.py" "$SOCK" quit 2>/dev/null || kill "$QPID" 2>/dev/null || true
        wait "$QPID" 2>/dev/null || true
    fi
    rm -f -- "$OVERLAY" "$SOCK"
    exit "$rc"
}
trap cleanup EXIT

echo "RUN_DIR=$RUN_DIR"
"$ROOT/tools/prune-runs.sh" "$KEEP_RUNS" || exit 2
mkdir -p "$FRAMES" || exit 2
holy_prepare_glsl || exit 1
export HOLYTOY_PAL="${HOLYTOY_PAL:-adaptive}"
export HOLYTOY_SCALE="$SCALE"
HOLYTOY_GUI=1 "$ROOT/tools/mkxfer.sh" "$XFER" "$SRC" || exit 2
qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY" || exit 2

holy_acquire_vm_slot demo_gif.sh || exit 2
printf '%s\n' "$SLOT" >"$RUN_DIR/slot"

"$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$OVERLAY",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display none \
    -qmp unix:"$SOCK",server,nowait \
    >"$RUN_DIR/qemu.log" 2>&1 &
QPID=$!

# Single boot-menu keypress, as gui.sh: a second one can arrive after boot
# and land inside the app's editor, corrupting the shader buffer.
sleep 3
python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true

# Wait until the HolyToy status line is on screen (the app is live).
READY=0
for _ in $(seq 1 60); do
    if python3 "$ROOT/tools/qmp.py" "$SOCK" screendump "$FRAMES/probe.png" 2>/dev/null; then
        TXT="$(python3 "$ROOT/tools/scrtext.py" "$FRAMES/probe.png" 2>/dev/null || true)"
        if printf '%s' "$TXT" | grep -q "HolyToy"; then READY=1; break; fi
    fi
    sleep 1
done
if (( !READY )); then echo "demo_gif.sh: app never appeared" >&2; exit 2; fi
sleep 5    # let the adaptive palette and scale controller settle

for ((n=0; n<NFRAMES; n++)); do
    python3 "$ROOT/tools/qmp.py" "$SOCK" screendump \
        "$(printf '%s/f-%04d.png' "$FRAMES" "$n")" 2>/dev/null || true
    sleep "$INTERVAL"
done

python3 "$ROOT/tools/qmp.py" "$SOCK" quit 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

FPS="$(python3 -c "print(round(1/$INTERVAL))")"
ffmpeg -v warning -y -framerate "$FPS" -i "$FRAMES/f-%04d.png" \
    -vf "palettegen=max_colors=64:stats_mode=diff" -update 1 "$RUN_DIR/pal.png" || exit 2
ffmpeg -v warning -y -framerate "$FPS" -i "$FRAMES/f-%04d.png" -i "$RUN_DIR/pal.png" \
    -lavfi "paletteuse=dither=none" -loop 0 "$OUTGIF" || exit 2
echo "demo_gif.sh: wrote $OUTGIF ($(du -h "$OUTGIF" | cut -f1))"
