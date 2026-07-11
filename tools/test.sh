#!/usr/bin/env bash
# holytoy proof suite. Nine round-trips through the real VM:
#   1. smoke        guest marker round-trip
#   2. gradient     screenshot dimensions and colors
#   3. error        guest compiler failure surfaces as exit 1
#   4. animate      plasma produces distinct frames and a GIF
#   5. parallel     simultaneous VMs keep disks/artifacts isolated
#   6. holytoy      app skeleton: live recompile self-test + animating viewport
#   7. glsl-static  transpiled GLSL runs standalone (--runner static)
#   8. glsl-app     .glsl source animates inside the app (--runner none)
#   9. mouse        QMP mouse injection lands on a pixel and clicks
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
cd "$ROOT"

tools/test-run-locks.sh || exit 2

python3 tools/test_glsl2hc.py >/dev/null 2>&1 || {
    echo "test.sh: glsl2hc unit tests failed - run python3 tools/test_glsl2hc.py" >&2
    exit 2
}

[[ "$MAX_RUNS" =~ ^[0-9]+$ ]] && (( MAX_RUNS >= 2 )) || {
    echo "test.sh: MAX_RUNS must be at least 2 for the parallel proof" >&2
    exit 2
}

PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }
new_run_path() {
    printf '%s/test-%s-%s-%s\n' \
        "$RUNS" "$(date -u +%Y%m%d-%H%M%S)" "$$" "$1"
}

TMP_SMOKE=""
TMP_PARALLEL_A=""
TMP_PARALLEL_B=""
TMP_GLSL_STATIC=""
cleanup_sources() {
    rm -f -- "$TMP_SMOKE" "$TMP_PARALLEL_A" "$TMP_PARALLEL_B" "$TMP_GLSL_STATIC"
}
trap cleanup_sources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

MARKER="HOLYTOY_MARKER_$$_$(date +%s)"
TMP_SMOKE="$(mktemp -p "${TMPDIR:-/tmp}" smoke-XXXX.HC)"
cat >"$TMP_SMOKE" <<EOF
U8 *st="$MARKER";
FileWrite("E:/MARKER.TXT",st,StrLen(st));
EOF

# 1. smoke: marker round-trip
RD="$(new_run_path smoke)"
if RUN_DIR="$RD" tools/run.sh "$TMP_SMOKE"; then
    GOT="$(MTOOLSRC="$RD/mtools.conf" mtype x:/MARKER.TXT 2>/dev/null | tr -d '\r\0')"
    if [ "$GOT" = "$MARKER" ]; then
        ok "smoke: marker round-tripped host->guest->host"
    else
        bad "smoke: marker mismatch (got '$GOT'; run $RD)"
    fi
else
    RC=$?
    bad "smoke: run.sh exited $RC (run $RD)"
fi

# 2. gradient: screenshot shows a gradient
RD="$(new_run_path gradient)"
if RUN_DIR="$RD" tools/run.sh src/gradient.HC; then
    INFO="$(python3 tools/imginfo.py "$RD/latest.png" 2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    if [ "$W" = 640 ] && [ "$H" = 480 ] && [ "$NCOLORS" -ge 8 ]; then
        ok "gradient: $RD/latest.png is ${W}x${H} with $NCOLORS colors"
    else
        bad "gradient: screenshot looks wrong (${W}x${H}, $NCOLORS colors; run $RD)"
    fi
else
    RC=$?
    bad "gradient: run.sh exited $RC (run $RD)"
fi

# 3. error: syntax error surfaces on host with exit 1
RD="$(new_run_path error)"
RUN_DIR="$RD" tools/run.sh tests/syntax-error.HC
RC=$?
if [ "$RC" = 1 ]; then
    if grep -qi "err\|compile\|except" "$RD/guest.log" 2>/dev/null; then
        ok "error: exit 1 and compiler message in $RD/guest.log"
    else
        bad "error: exit 1 but no error text in $RD/guest.log"
    fi
else
    bad "error: expected exit 1, got $RC (run $RD)"
fi

# 4. animate: plasma yields distinct trailing frames and GIF
RD="$(new_run_path animate)"
if RUN_DIR="$RD" tools/run.sh src/plasma.HC; then
    frame_files=("$RD"/frames/frame-*.png)
    if [ -e "${frame_files[0]}" ]; then
        DISTINCT="$(printf '%s\0' "${frame_files[@]}" | tail -z -n 6 |
            xargs -0 -r md5sum | awk '{print $1}' | sort -u | wc -l)"
    else
        DISTINCT=0
    fi
    if [ "$DISTINCT" -ge 3 ] && [ -f "$RD/anim.gif" ]; then
        ok "animate: $DISTINCT distinct trailing frames and $RD/anim.gif"
    else
        bad "animate: need >=3 distinct frames and anim.gif (got $DISTINCT; run $RD)"
    fi
else
    RC=$?
    bad "animate: run.sh exited $RC (run $RD)"
fi

# 5. parallel isolation: two live VMs use different slots and transfer disks
PARALLEL_A="PARALLEL_A_$$_$(date +%s)"
PARALLEL_B="PARALLEL_B_$$_$(date +%s)"
TMP_PARALLEL_A="$(mktemp -p "${TMPDIR:-/tmp}" parallel-a-XXXX.HC)"
TMP_PARALLEL_B="$(mktemp -p "${TMPDIR:-/tmp}" parallel-b-XXXX.HC)"
cat >"$TMP_PARALLEL_A" <<EOF
U8 *st="$PARALLEL_A";
FileWrite("E:/MARKER.TXT",st,StrLen(st));
EOF
cat >"$TMP_PARALLEL_B" <<EOF
U8 *st="$PARALLEL_B";
FileWrite("E:/MARKER.TXT",st,StrLen(st));
EOF

RD_A="$(new_run_path parallel-a)"
RD_B="$(new_run_path parallel-b)"
RUN_DIR="$RD_A" tools/run.sh "$TMP_PARALLEL_A" &
PID_A=$!
RUN_DIR="$RD_B" tools/run.sh "$TMP_PARALLEL_B" &
PID_B=$!
wait "$PID_A"
RC_A=$?
wait "$PID_B"
RC_B=$?

GOT_A="$(MTOOLSRC="$RD_A/mtools.conf" mtype x:/MARKER.TXT 2>/dev/null | tr -d '\r\0')"
GOT_B="$(MTOOLSRC="$RD_B/mtools.conf" mtype x:/MARKER.TXT 2>/dev/null | tr -d '\r\0')"
SLOT_A="$(tr -d '[:space:]' 2>/dev/null <"$RD_A/slot" || true)"
SLOT_B="$(tr -d '[:space:]' 2>/dev/null <"$RD_B/slot" || true)"
if [ "$RC_A" = 0 ] && [ "$RC_B" = 0 ] &&
   [ "$GOT_A" = "$PARALLEL_A" ] && [ "$GOT_B" = "$PARALLEL_B" ] &&
   [ -n "$SLOT_A" ] && [ -n "$SLOT_B" ] && [ "$SLOT_A" != "$SLOT_B" ]; then
    ok "parallel: isolated markers on simultaneous slots $SLOT_A and $SLOT_B"
else
    bad "parallel: rc=$RC_A/$RC_B marker='$GOT_A'/'$GOT_B' slot=$SLOT_A/$SLOT_B (runs $RD_A $RD_B)"
fi

# 6. holytoy: app skeleton recompiles shaders live and keeps animating
RD="$(new_run_path holytoy)"
if RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC; then
    frame_files=("$RD"/frames/frame-*.png)
    if [ -e "${frame_files[0]}" ]; then
        DISTINCT="$(printf '%s\0' "${frame_files[@]}" | tail -z -n 6 |
            xargs -0 -r md5sum | awk '{print $1}' | sort -u | wc -l)"
    else
        DISTINCT=0
    fi
    if grep -q "HT SWAP OK" "$RD/guest.log" &&
       grep -q "HT ERRSURVIVE OK" "$RD/guest.log" &&
       grep -q "HT MATH OK" "$RD/guest.log" &&
       grep -qE "HolyToy +[0-9]+ms" "$RD/screen.txt" &&
       [ "$DISTINCT" -ge 3 ]; then
        ok "holytoy: recompile + math markers, ms readout, $DISTINCT distinct frames"
    else
        bad "holytoy: missing HT markers/ms readout or <3 distinct frames (got $DISTINCT; run $RD)"
    fi
else
    RC=$?
    bad "holytoy: run.sh exited $RC (run $RD)"
fi

# 7. glsl-static: transpiled GLSL renders standalone under the static runner
TMP_GLSL_STATIC="$(mktemp -p "${TMPDIR:-/tmp}" glsl-static-XXXX.HC)"
RD="$(new_run_path glsl-static)"
if python3 tools/glsl2hc.py tests/glsl/gradient.glsl --runner static \
        -o "$TMP_GLSL_STATIC" &&
   RUN_DIR="$RD" tools/run.sh "$TMP_GLSL_STATIC"; then
    INFO="$(python3 tools/imginfo.py "$RD/latest.png" 2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    if [ "$W" = 640 ] && [ "$H" = 480 ] && [ "$NCOLORS" -ge 8 ]; then
        ok "glsl-static: transpiled gradient is ${W}x${H} with $NCOLORS colors"
    else
        bad "glsl-static: screenshot looks wrong (${W}x${H}, $NCOLORS colors; run $RD)"
    fi
else
    RC=$?
    bad "glsl-static: transpile or run failed with $RC (run $RD)"
fi

# 8. glsl-app: a .glsl source transpiles, injects, and animates in the app
RD="$(new_run_path glsl-app)"
if RUN_DIR="$RD" tools/run.sh tests/glsl/plasma.glsl; then
    frame_files=("$RD"/frames/frame-*.png)
    if [ -e "${frame_files[0]}" ]; then
        DISTINCT="$(printf '%s\0' "${frame_files[@]}" | tail -z -n 6 |
            xargs -0 -r md5sum | awk '{print $1}' | sort -u | wc -l)"
    else
        DISTINCT=0
    fi
    if grep -q "HT GLSL OK" "$RD/guest.log" && [ "$DISTINCT" -ge 3 ]; then
        ok "glsl-app: HT GLSL OK and $DISTINCT distinct frames"
    else
        bad "glsl-app: missing HT GLSL OK or <3 distinct frames (got $DISTINCT; run $RD)"
    fi
else
    RC=$?
    bad "glsl-app: run.sh exited $RC (run $RD)"
fi

# 9. mouse: QMP mouse injection lands within tolerance and the click is seen
RD="$(new_run_path mouse)"
RUN_DIR="$RD" tools/run.sh tests/mouse-probe.HC &
MOUSE_PID=$!
READY=0
for _ in $(seq 1 60); do
    if python3 tools/scrtext.py "$RD/frames/last-good.png" \
            --grep "MOUSE READY" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done
if [ "$READY" = 1 ]; then
    # The QMP socket is shared with run.sh's screendump loop; each call is a
    # short-lived connection, so retry once on a collision.
    python3 tools/qmp.py "$RD/qmp.sock" mouse-to 400 300 2>/dev/null ||
        python3 tools/qmp.py "$RD/qmp.sock" mouse-to 400 300
    sleep 0.5
    python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left down 2>/dev/null ||
        python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left down
    sleep 0.7
    python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left up 2>/dev/null ||
        python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left up
fi
wait "$MOUSE_PID"
RC=$?
if [ "$READY" != 1 ]; then
    bad "mouse: MOUSE READY never appeared on screen (run $RD)"
elif [ "$RC" != 0 ]; then
    bad "mouse: run.sh exited $RC (run $RD)"
else
    read -r MX MY MLB <<<"$(sed -n 's/.*MOUSE FINAL \([0-9-]*\) \([0-9-]*\) \([0-9]*\).*/\1 \2 \3/p' \
        "$RD/guest.log" | head -1)"
    if [ -n "${MLB:-}" ] && [ "$MLB" = 1 ] &&
       [ "$MX" -ge 384 ] && [ "$MX" -le 416 ] &&
       [ "$MY" -ge 284 ] && [ "$MY" -le 316 ]; then
        ok "mouse: landed at $MX,$MY (target 400,300 +-16) with click seen"
    else
        bad "mouse: MOUSE FINAL '${MX:-?} ${MY:-?} ${MLB:-?}' out of tolerance (run $RD)"
    fi
fi

echo "-- $PASS passed, $FAIL failed --"
[ "$FAIL" = 0 ]
