#!/usr/bin/env bash
# Build the golden TempleOS image from the ISO, unattended.
#
# Usage: install_os.sh            (refuses to clobber an existing golden image)
#        install_os.sh --force
#
# Phase 1  boot ISO, drive the VM install wizard:  y, y, <key>, ... , y(reboot)
# Phase 2  boot installed system + transfer disk, decline tour, inject the
#          guest/ONCE.HC boot hook onto C:, reboot.
# The result images/golden.qcow2 is made read-only; run.sh only ever touches
# throwaway overlays on top of it.
#
# Prompt detection: the guest screen is polled via QMP screendumps and two
# consecutive frames are compared with ffmpeg PSNR. During file copy the
# screen churns (low PSNR); sitting at a prompt only the clock/cursor blink
# (high PSNR). Checkpoints land in out/install/ for post-mortem.
#
# Manual fallback (if this script misbehaves, ~60s by hand):
#   tools/gui.sh will not work yet (no golden image), so run:
#     qemu-system-x86_64 -m 512 -drive file=images/golden.qcow2,format=qcow2 \
#       -cdrom images/TempleOS.ISO -boot d -display gtk
#   then answer:  y (install)  y (VM?)  any key  ...wait...  y (reboot now)
#   then rerun this script with --hook-only to inject the boot hook.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"

SOCK="$ROOT/images/qmp-install.sock"
CHK="$OUT/install"
QMP() { python3 "$ROOT/tools/qmp.py" "$SOCK" "$@"; }
export QMP_KEY_DELAY=0.06   # a little slack so typed HolyC never outruns the shell

HOOK_ONLY=0
FORCE=0
for a in "$@"; do
    case "$a" in
        --hook-only) HOOK_ONLY=1 ;;
        --force) FORCE=1 ;;
        *) echo "install_os.sh: unknown arg $a" >&2; exit 2 ;;
    esac
done

mkdir -p "$CHK" "$ROOT/images"
QPID=""
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; }
trap cleanup EXIT

# PSNR between two PNGs; prints "inf" for identical frames.
psnr() {
    ffmpeg -hide_banner -i "$1" -i "$2" -filter_complex psnr -f null - 2>&1 |
        sed -n 's/.*average:\([0-9.inf]*\).*/\1/p' | head -1
}

# Wait until N consecutive frame pairs are near-identical (prompt reached).
# wait_quiet TAG NEED MAX_SECS
wait_quiet() {
    local tag="$1" need="$2" max="$3" quiet=0 t=0 p
    QMP screendump "$CHK/$tag-a.png" 2>/dev/null || true
    while (( t < max )); do
        sleep 5; t=$((t+5))
        if ! QMP screendump "$CHK/$tag-b.png" 2>/dev/null; then continue; fi
        p="$(psnr "$CHK/$tag-a.png" "$CHK/$tag-b.png" || echo 0)"
        mv -f "$CHK/$tag-b.png" "$CHK/$tag-a.png"
        case "$p" in
            inf*) quiet=$((quiet+1)) ;;
            *) if awk "BEGIN{exit !($p > 34)}" 2>/dev/null; then
                   quiet=$((quiet+1))
               else
                   quiet=0
               fi ;;
        esac
        if (( quiet >= need )); then return 0; fi
    done
    echo "install_os.sh: timed out waiting for quiet screen ($tag) — see $CHK/$tag-a.png" >&2
    return 1
}

wait_exit() { # wait for QEMU to exit, max $1 secs
    local t=0
    while kill -0 "$QPID" 2>/dev/null; do
        sleep 2; t=$((t+2))
        (( t > $1 )) && return 1
    done
    QPID=""
    return 0
}

if (( ! HOOK_ONLY )); then
    if [ -f "$GOLDEN" ] && (( ! FORCE )); then
        echo "install_os.sh: $GOLDEN exists; use --force to rebuild from scratch" >&2
        exit 2
    fi
    [ -f "$ISO" ] || { echo "install_os.sh: ISO missing — run 'make fetch-iso'" >&2; exit 2; }

    echo "=== Phase 1: OS install (takes ~4-8 min under TCG) ==="
    rm -f "$GOLDEN"
    chmod +w "$GOLDEN" 2>/dev/null || true
    qemu-img create -q -f qcow2 "$GOLDEN" "$HDD_SIZE"

    "$QEMU" $ACCEL_ARGS -m "$MEM" \
        -drive file="$GOLDEN",format=qcow2,index=0,media=disk \
        -cdrom "$ISO" -boot d \
        -rtc base=localtime -display none -no-reboot \
        -qmp unix:"$SOCK",server,nowait >"$CHK/qemu-p1.log" 2>&1 &
    QPID=$!

    sleep 8
    wait_quiet boot 2 60           # "Install onto hard drive (y or n)?"
    QMP keys y; sleep 4
    wait_quiet vmq 2 60            # "…inside VMware, QEMU… (y or n)?"
    QMP keys y; sleep 3
    wait_quiet presskey 2 60       # "PRESS A KEY"
    QMP keys spc
    sleep 60                       # let the copy phase get going
    wait_quiet rebootq 3 600       # "Reboot Now (y or n)?" after copy churn
    QMP screendump "$CHK/p1-final.png" || true
    QMP keys y                     # reboot → -no-reboot makes QEMU exit
    wait_exit 60 || { echo "install_os.sh: QEMU did not exit after reboot" >&2; exit 2; }
    echo "=== Phase 1 done ==="
fi

echo "=== Phase 2: inject guest/ONCE.HC boot hook ==="
[ -f "$GOLDEN" ] || { echo "install_os.sh: no golden image for --hook-only" >&2; exit 2; }
chmod +w "$GOLDEN"
"$ROOT/tools/mkxfer.sh"            # transfer disk carrying ONCE.HC

"$QEMU" $ACCEL_ARGS -m "$MEM" \
    -drive file="$GOLDEN",format=qcow2,index=0,media=disk \
    -drive file="$XFER",format=raw,index=1,media=disk \
    -cdrom "$ISO" \
    -rtc base=localtime -display none -no-reboot \
    -qmp unix:"$SOCK",server,nowait >"$CHK/qemu-p2.log" 2>&1 &
QPID=$!

sleep 3
QMP keys 1                         # TempleOS MBR loader menu: "1. Drive C"
sleep 5
wait_quiet hdboot 2 90             # first HD boot: TipOfDay + "Take Tour"
QMP keys n; sleep 2                # decline tour → shell
QMP screendump "$CHK/p2-shell.png" || true
QMP typefile "$ROOT/guest/INJECT.HC"   # mounts xfer, installs hook, reboots
wait_exit 90 || { echo "install_os.sh: guest did not reboot after hook install" >&2; exit 2; }

chmod -w "$GOLDEN"
echo "=== Golden image ready (read-only): $GOLDEN ==="
echo "Verify with: make run SRC=src/gradient.HC"
