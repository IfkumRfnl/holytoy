# holytoy configuration — sourced by every tool script.
# All paths relative to repo root (tools resolve ROOT themselves).

ISO="$ROOT/images/TempleOS.ISO"
ISO_URL="https://templeos.org/Downloads/TempleOS.ISO"

# Golden installed image (read-only master) and per-run overlay
GOLDEN="$ROOT/images/golden.qcow2"
OVERLAY="$ROOT/images/work.qcow2"
HDD_SIZE=1024M            # main TempleOS disk (VM installer splits it C:/D:)

# FAT32 transfer disk (host<->guest file exchange, driven by mtools)
XFER="$ROOT/images/xfer.img"
XFER_SIZE=64              # MiB

# QEMU
QEMU=qemu-system-x86_64
MEM=512
ACCEL_ARGS=""
[ -e /dev/kvm ] && [ -w /dev/kvm ] && ACCEL_ARGS="-enable-kvm"

# Run-cycle timing (seconds)
RUN_TIMEOUT=90            # hard kill for a normal run cycle
FRAME_INTERVAL=0.7        # rolling screendump cadence
# (the guest-side screenshot hold is HT_SHOW_MS in guest/RUN.HC)

# Output
OUT="$ROOT/out"
LATEST_PNG="$OUT/latest.png"
GUEST_LOG="$OUT/guest.log"
