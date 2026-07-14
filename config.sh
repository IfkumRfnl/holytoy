# holytoy configuration — sourced by every tool script.
# All paths relative to repo root (tools resolve ROOT themselves).

ISO="$ROOT/images/TempleOS.ISO"
ISO_URL="https://templeos.org/Downloads/TempleOS.ISO"

# Golden installed image (read-only master)
GOLDEN="$ROOT/images/golden.qcow2"
HDD_SIZE=1024M            # main TempleOS disk (VM installer splits it C:/D:)

# FAT32 transfer disk size (host<->guest file exchange, driven by mtools)
XFER_SIZE=64              # MiB

# QEMU
QEMU=qemu-system-x86_64
MEM=512
MAX_RUNS=3                # concurrent VMs; each uses MEM MiB and ~1 TCG core
RUN_QUEUE_TIMEOUT=300     # wait this long for any VM slot
ACCEL_ARGS=""
[ -e /dev/kvm ] && [ -w /dev/kvm ] && ACCEL_ARGS="-enable-kvm"

# Run-cycle timing (seconds)
RUN_TIMEOUT="${RUN_TIMEOUT:-90}"  # hard kill for a normal run cycle; corpus
                                  # batch runs export a larger value
FRAME_INTERVAL=0.7        # rolling screendump cadence
ANIM_FRAMES=8             # trailing frames kept for each run's GIF and the animates proof
# (the guest-side screenshot hold is HT_SHOW_MS in guest/RUN.HC)

# Output
OUT="$ROOT/out"
RUNS="${HOLYTOY_RUNS:-$OUT/runs}"
KEEP_RUNS=20              # newest completed run dirs to retain
