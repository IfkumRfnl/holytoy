#!/usr/bin/env bash
# Interactive mode: visible QEMU window (WSLg), same disks as run.sh.
# Usage: gui.sh [SRC.HC]
# If SRC is given it is injected and auto-executed on boot, but the guest
# stays up afterwards (no auto-reboot) so you can poke at it. Close the
# window or run Reboot; in the guest to leave.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"

SRC="${1:-}"
[ -f "$GOLDEN" ] || { echo "gui.sh: golden image missing — run 'make golden' first" >&2; exit 2; }

HOLYTOY_GUI=1 "$ROOT/tools/mkxfer.sh" $SRC

rm -f "$OVERLAY"
qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY"

exec "$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$OVERLAY",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display gtk \
    -qmp unix:"$ROOT/images/qmp-gui.sock",server,nowait
