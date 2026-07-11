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
# Prompt detection: QMP screendumps are read as text via tools/scrtext.py
# (exact 8x8 kernel-font glyph match) and each installer prompt is awaited
# by literal substring. Checkpoints land in out/install/ for post-mortem.
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

# Wait until STRING appears on the guest screen (case-insensitive).
# wait_text TAG STRING MAX_SECS
wait_text() {
    local tag="$1" needle="$2" max="$3" t=0
    while (( t < max )); do
        if QMP screendump "$CHK/$tag.png" 2>/dev/null &&
           python3 "$ROOT/tools/scrtext.py" "$CHK/$tag.png" --grep "$needle"; then
            return 0
        fi
        sleep 3; t=$((t+3))
    done
    echo "install_os.sh: timed out waiting for '$needle' ($tag) — see $CHK/$tag.png" >&2
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
    wait_text boot "Install onto hard drive" 90
    QMP keys y; sleep 2
    wait_text vmq "similar virtual" 60
    QMP keys y; sleep 2
    wait_text presskey "press a key" 60
    QMP keys spc
    wait_text rebootq "Reboot Now" 600      # install copy takes minutes (TCG)
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

# The MBR loader's drive menu runs in BIOS text mode (720x400 screendumps,
# not TempleOS's 640x480) — keep answering "1" (Drive C) until the guest
# switches to graphics mode, then await the first-boot tour prompt.
T=0
while (( T < 60 )); do
    sleep 3; T=$((T+3))
    QMP screendump "$CHK/bootmenu.png" 2>/dev/null || continue
    SZ="$(python3 "$ROOT/tools/imginfo.py" "$CHK/bootmenu.png" 2>/dev/null | cut -d' ' -f1)"
    [ "$SZ" = "640" ] && break
    QMP keys 1
done
wait_text tour "Take Tour" 120     # first HD boot: TipOfDay + "Take Tour"
QMP keys n; sleep 2                # decline tour → shell
QMP screendump "$CHK/p2-shell.png" || true
QMP typefile "$ROOT/guest/INJECT.HC"   # mounts xfer, installs hook, reboots
wait_exit 90 || { echo "install_os.sh: guest did not reboot after hook install" >&2; exit 2; }

chmod -w "$GOLDEN"
echo "=== Golden image ready (read-only): $GOLDEN ==="
echo "Verify with: make run SRC=src/gradient.HC"
