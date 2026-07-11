#!/usr/bin/env bash
# Interactive mode: a visible QEMU window with isolated per-session disks.
# Usage: gui.sh [SRC.HC]
# Prints RUN_DIR first; close the window or run Reboot; in TempleOS to leave.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
. "$ROOT/tools/run-common.sh"

SRC="${1:-}"
if [ -n "$SRC" ] && [ ! -f "$SRC" ]; then
    echo "gui.sh: no such file: $SRC" >&2
    exit 2
fi
[ -f "$GOLDEN" ] || { echo "gui.sh: golden image missing - run 'make golden' first" >&2; exit 2; }
holy_validate_run_settings gui.sh || exit 2
holy_allocate_run_dir gui.sh gui || exit 2

OVERLAY="$RUN_DIR/overlay.qcow2"
XFER="$RUN_DIR/xfer.img"
SOCK="$RUN_DIR/qmp.sock"
QPID=""
BOOT_PID=""
cleanup() {
    rc=$?
    trap - EXIT
    if [ -n "$BOOT_PID" ]; then
        kill "$BOOT_PID" 2>/dev/null || true
        wait "$BOOT_PID" 2>/dev/null || true
    fi
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
    echo "gui.sh: could not prune old runs" >&2
    exit 2
}
if ! HOLYTOY_GUI=1 "$ROOT/tools/mkxfer.sh" "$XFER" "$SRC"; then
    echo "gui.sh: could not create transfer disk" >&2
    exit 2
fi
if ! qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY"; then
    echo "gui.sh: could not create VM overlay" >&2
    exit 2
fi

holy_acquire_vm_slot gui.sh || exit 2
printf '%s\n' "$SLOT" >"$RUN_DIR/slot"

"$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$OVERLAY",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display gtk \
    -qmp unix:"$SOCK",server,nowait \
    >"$RUN_DIR/qemu.log" 2>&1 &
QPID=$!

# Auto-answer the MBR loader's drive menu ("1" = boot C).
(
    sleep 3
    python3 "$ROOT/tools/qmp.py" "$SOCK" keys 1 2>/dev/null || true
) &
BOOT_PID=$!

wait "$QPID"
RC=$?
QPID=""
wait "$BOOT_PID" 2>/dev/null || true
BOOT_PID=""
if (( RC != 0 )); then
    echo "gui.sh: QEMU exited with status $RC; see $RUN_DIR/qemu.log" >&2
fi
exit "$RC"
