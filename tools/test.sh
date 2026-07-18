#!/usr/bin/env bash
# holytoy proof suite. Fifteen round-trips through the real VM:
#   1. smoke        guest marker round-trip
#   2. gradient     screenshot dimensions and colors
#   3. error        guest compiler failure surfaces as exit 1
#   4. animate      plasma produces distinct frames and a GIF
#   5. parallel     simultaneous VMs keep disks/artifacts isolated
#   6. holytoy      app skeleton: live recompile self-test + animating viewport
#   7. glsl-app     raw GLSL compiles in-guest and animates inside the app
#   8. mouse        QMP mouse injection lands on a pixel and clicks
#   9. dither       static GLSL gradient is deterministic and spatially dithered
#  10. guest-glsl   raw GLSL is compiled in-guest and rendered through HTRENDER
#  11. circle       declarations/vectors/builtins compile and render geometry
#  12. editor       native in-guest edit auto-compiles and changes the viewport
#  13. oracle       guest visual sample dump matches the committed reference
#  14. smp          single-core vs multicore render is byte-identical
#  15. sse          stage-0 SSE probe: enable + execute + XMM survival + sweep
#  16. bilerp       1:16 bilinear upsample of a linear shader equals 1:1
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
cd "$ROOT"

# Existing screenshot proofs require the historical 4x4 block size. Proof 6
# temporarily forces auto mode in-guest to exercise the adaptive controller.
export HOLYTOY_SCALE=4

tools/test-run-locks.sh || exit 2

python3 tools/test_corpus_compat.py >/dev/null 2>&1 || {
    echo "test.sh: corpus compatibility tests failed - run python3 tools/test_corpus_compat.py" >&2
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
cleanup_sources() {
    rm -f -- "$TMP_SMOKE" "$TMP_PARALLEL_A" "$TMP_PARALLEL_B"
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
       grep -q "HT F32 OK" "$RD/guest.log" &&
       grep -q "HT PC24 OK" "$RD/guest.log" &&
       grep -q "HT DITHER OK" "$RD/guest.log" &&
       grep -q "HT CTX OK" "$RD/guest.log" &&
       grep -q "HT SCALE OK" "$RD/guest.log" &&
       grep -qE "HolyToy +[^ ]+ms" "$RD/screen.txt" &&
       [ "$DISTINCT" -ge 3 ]; then
        ok "holytoy: recompile + math markers, ms readout, $DISTINCT distinct frames"
    else
        bad "holytoy: missing HT markers/ms readout or <3 distinct frames (got $DISTINCT; run $RD)"
    fi
else
    RC=$?
    bad "holytoy: run.sh exited $RC (run $RD)"
fi

# 7. glsl-app: raw GLSL compiles in-guest and animates in the app
RD="$(new_run_path glsl-app)"
if RUN_DIR="$RD" tools/run.sh tests/glsl/live-gradient.glsl; then
    frame_files=("$RD"/frames/frame-*.png)
    if [ -e "${frame_files[0]}" ]; then
        DISTINCT="$(printf '%s\0' "${frame_files[@]}" | tail -z -n 6 |
            xargs -0 -r md5sum | awk '{print $1}' | sort -u | wc -l)"
    else
        DISTINCT=0
    fi
    if grep -q "HT GUEST GLSL OK" "$RD/guest.log" && [ "$DISTINCT" -ge 3 ]; then
        ok "glsl-app: guest GLSL compiled and produced $DISTINCT distinct frames"
    else
        bad "glsl-app: missing HT GUEST GLSL OK or <3 distinct frames (got $DISTINCT; run $RD)"
    fi
else
    RC=$?
    bad "glsl-app: run.sh exited $RC (run $RD)"
fi

# 8. mouse: QMP mouse injection lands within tolerance and the click is seen
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

# 9. dither: a static app shader is deterministic and varies across space
RD="$(new_run_path dither)"
if RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl; then
    frame_files=("$RD"/frames/frame-*.png)
    HASH1=""
    HASH2=""
    if [ "${#frame_files[@]}" -ge 2 ] && [ -e "${frame_files[0]}" ]; then
        LAST1="${frame_files[${#frame_files[@]}-2]}"
        LAST2="${frame_files[${#frame_files[@]}-1]}"
        # Screen rows 0-7 are TempleOS's live system status bar; the app
        # viewport starts at row 8, so exclude the bar from stable hashes.
        HASH1="$(python3 tools/imginfo.py "$LAST1" --crop 0,8,640x288 --hash |
            awk '{print $4}')"
        HASH2="$(python3 tools/imginfo.py "$LAST2" --crop 0,8,640x288 --hash |
            awk '{print $4}')"
    fi
    INFO="$(python3 tools/imginfo.py "$RD/latest.png" --crop 0,8,640x288 \
        2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    BAND_ALIVE=0
    for ROW in 56 152 248; do
        BAND_COLORS="$(python3 tools/imginfo.py "$RD/latest.png" \
            --crop "0,$ROW,640x8" 2>/dev/null | awk '{print $3}')"
        if [ "${BAND_COLORS:-0}" -ge 2 ]; then
            BAND_ALIVE=$((BAND_ALIVE + 1))
        fi
    done
    if grep -q "HT GUEST GLSL OK" "$RD/guest.log" &&
       [ -n "$HASH1" ] && [ "$HASH1" = "$HASH2" ] &&
       [ "$BAND_ALIVE" -ge 2 ] &&
       [ "$W" = 640 ] && [ "$H" = 288 ] &&
       [ "$NCOLORS" -ge 4 ] && [ "$NCOLORS" -le 16 ]; then
        ok "dither: deterministic viewport $HASH1, $NCOLORS colors, spatial variation"
    else
        bad "dither: GLSL/hash/band/gamut check failed (hash '$HASH1'/'$HASH2', colors $NCOLORS, band $BAND_ALIVE; run $RD)"
    fi
else
    RC=$?
    bad "dither: run.sh exited $RC (run $RD)"
fi

# 10. guest-glsl: raw source succeeds in the in-guest compiler.
RD="$(new_run_path guest-glsl)"
if RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl; then
    INFO="$(python3 tools/imginfo.py "$RD/latest.png" --crop 0,8,640x288 \
        2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    if grep -q "HT GUEST GLSL OK" "$RD/guest.log" &&
       [ "$W" = 640 ] && [ "$H" = 288 ] && [ "$NCOLORS" -ge 4 ]; then
        ok "guest-glsl: raw GLSL compiled in guest and rendered ($NCOLORS colors)"
    else
        bad "guest-glsl: missing guest marker or invalid viewport (run $RD)"
    fi
else
    RC=$?
    bad "guest-glsl: run.sh exited $RC (run $RD)"
fi

# 11. circle: the broader guest compiler slice renders white center/black edge.
RD="$(new_run_path circle)"
if RUN_DIR="$RD" tools/run.sh tests/glsl/circle.glsl; then
    INFO="$(python3 tools/imginfo.py "$RD/latest.png" --crop 0,8,640x288 \
        2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    CENTER="$(python3 tools/imginfo.py "$RD/latest.png" \
        --crop 320,152,1x1 --hash 2>/dev/null | awk '{print $4}')"
    EDGE="$(python3 tools/imginfo.py "$RD/latest.png" \
        --crop 32,40,1x1 --hash 2>/dev/null | awk '{print $4}')"
    if grep -q "HT GUEST GLSL OK" "$RD/guest.log" &&
       [ "$W" = 640 ] && [ "$H" = 288 ] && [ "$NCOLORS" -ge 2 ] &&
       [ -n "$CENTER" ] && [ -n "$EDGE" ] && [ "$CENTER" != "$EDGE" ]; then
        ok "circle: guest declarations/vectors/builtins rendered center/edge geometry"
    else
        bad "circle: compile or geometry proof failed (colors $NCOLORS, center '$CENTER', edge '$EDGE'; run $RD)"
    fi
else
    RC=$?
    bad "circle: run.sh exited $RC (run $RD)"
fi

# 12. editor: drive the native TempleOS editor, wait for debounce compilation,
# and prove both the visible GLSL and viewport changed before exiting with ESC.
RD="$(new_run_path editor)"
HOLYTOY_EDIT_TEST=1 RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl &
EDITOR_PID=$!
EDITOR_READY=0
for _ in $(seq 1 75); do
    if python3 tools/scrtext.py "$RD/frames/last-good.png" \
            --grep "full-screen vertical gradient" >/dev/null 2>&1; then
        EDITOR_READY=1
        break
    fi
    sleep 1
done
BEFORE_HASH=""
AFTER_HASH=""
EDITOR_CHANGED=0
if [ "$EDITOR_READY" = 1 ]; then
    python3 tools/qmp.py "$RD/qmp.sock" screendump "$RD/editor-before.png" &&
        BEFORE_HASH="$(python3 tools/imginfo.py "$RD/editor-before.png" \
            --crop 0,8,640x288 --hash | awk '{print $4}')"
    # HolyToy maps Ctrl-A to select-all; Shift-Delete uses native DocPutKey
    # cut semantics before the replacement text is typed.
    python3 tools/qmp.py "$RD/qmp.sock" keys ctrl+a shift+delete
    python3 tools/qmp.py "$RD/qmp.sock" typefile tests/glsl/invert-gradient.glsl
    for _ in $(seq 1 30); do
        if python3 tools/scrtext.py "$RD/frames/last-good.png" \
                --grep "1.0 - fragCoord.y" >/dev/null 2>&1 &&
           python3 tools/scrtext.py "$RD/frames/last-good.png" \
                --grep "OK  GLSL" >/dev/null 2>&1; then
            EDITOR_CHANGED=1
            break
        fi
        sleep 1
    done
    if [ "$EDITOR_CHANGED" = 1 ]; then
        python3 tools/qmp.py "$RD/qmp.sock" screendump "$RD/editor-after.png" &&
            AFTER_HASH="$(python3 tools/imginfo.py "$RD/editor-after.png" \
                --crop 0,8,640x288 --hash | awk '{print $4}')"
    fi
    python3 tools/qmp.py "$RD/qmp.sock" keys esc 2>/dev/null || true
fi
wait "$EDITOR_PID"
RC=$?
if [ "$EDITOR_READY" = 1 ] && [ "$EDITOR_CHANGED" = 1 ] && [ "$RC" = 0 ] &&
   [ -n "$BEFORE_HASH" ] && [ -n "$AFTER_HASH" ] &&
   [ "$BEFORE_HASH" != "$AFTER_HASH" ]; then
    ok "editor: native edit auto-compiled and changed viewport $BEFORE_HASH -> $AFTER_HASH"
else
    bad "editor: ready=$EDITOR_READY changed=$EDITOR_CHANGED rc=$RC hash='$BEFORE_HASH'/'$AFTER_HASH' (run $RD)"
fi

# 13. oracle: the guest's visual sample dump matches the committed reference
# DATs within the plan-010 tolerance (tools/visual_compare.py exit 0).
RD="$(new_run_path oracle)"
if HOLYTOY_VISDUMP=1 RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl; then
    ORACLE_DIR="$RD/visual"
    mkdir -p "$ORACLE_DIR"
    MTOOLSRC="$RD/mtools.conf" mcopy -n x:/V00A.DAT "$ORACLE_DIR/gradient-A.DAT" 2>/dev/null
    MTOOLSRC="$RD/mtools.conf" mcopy -n x:/V00B.DAT "$ORACLE_DIR/gradient-B.DAT" 2>/dev/null
    if grep -q "HT VISUAL DUMP OK" "$RD/guest.log" &&
       python3 tools/visual_compare.py --dumps "$ORACLE_DIR" \
           --refs tests/corpus-visual/refs-fixtures; then
        ok "oracle: guest visual dump within tolerance of committed reference"
    else
        bad "oracle: dump missing or out of tolerance (run $RD)"
    fi
else
    RC=$?
    bad "oracle: run.sh exited $RC (run $RD)"
fi

# 14. smp: the multicore render fan-out is byte-identical to single-core.
# Run the static gradient at the pinned scale once on one shading core and
# once on four; the published viewport (crop 0,8,640x288, excludes the pane's
# per-config %3dms readout) must hash identically. Deterministic by
# construction: identical integer/F64 math, disjoint bands, snapshotted
# uniforms (proof 9 already establishes intra-run determinism).
smp_viewport_hash() {
    # newest complete rolling frame's viewport hash for a finished run dir
    local rd="$1" files last
    files=("$rd"/frames/frame-*.png)
    [ -e "${files[0]}" ] || return 1
    last="${files[${#files[@]}-1]}"
    python3 tools/imginfo.py "$last" --crop 0,8,640x288 --hash 2>/dev/null |
        awk '{print $4}'
}
RD_C1="$(new_run_path smp-c1)"
RD_C4="$(new_run_path smp-c4)"
HASH_C1=""
HASH_C4=""
if HOLYTOY_CORES=1 RUN_DIR="$RD_C1" tools/run.sh tests/glsl/gradient.glsl &&
   grep -q "HT GUEST GLSL OK" "$RD_C1/guest.log"; then
    HASH_C1="$(smp_viewport_hash "$RD_C1")"
fi
if HOLYTOY_CORES=4 RUN_DIR="$RD_C4" tools/run.sh tests/glsl/gradient.glsl &&
   grep -q "HT GUEST GLSL OK" "$RD_C4/guest.log"; then
    HASH_C4="$(smp_viewport_hash "$RD_C4")"
fi
if [ -n "$HASH_C1" ] && [ -n "$HASH_C4" ] && [ "$HASH_C1" = "$HASH_C4" ]; then
    ok "smp: CORES=1 and CORES=4 produced identical viewport $HASH_C1"
else
    bad "smp: viewport hash mismatch (cores1 '$HASH_C1' vs cores4 '$HASH_C4'; runs $RD_C1 $RD_C4)"
fi

# 15. sse: plan-015 stage-0 SSE enablement probe. CR4.OSFXSR|OSXMMEXCPT set
# per core + MXCSR pinned to 0x1F80, raw-encoded scalar SSE executes on core
# 0 and an AP, an XMM sentinel survives task switches against an active
# clobber task, and the ADDSS/MULSS/SUBSS/DIVSS/SQRTSS bit sweep matches the
# HtF32 reference (MISMATCH==0). The probe prints HT SSE OK only then.
RD="$(new_run_path sse)"
if RUN_DIR="$RD" tools/run.sh src/probe-sse.HC; then
    if grep -q "HT SSE OK" "$RD/guest.log"; then
        ok "sse: enable + execute + XMM survival + bit sweep (HT SSE OK)"
    else
        bad "sse: no HT SSE OK marker (run $RD)"
    fi
else
    RC=$?
    bad "sse: run.sh exited $RC (run $RD)"
fi

# 16. bilerp: bilinear reconstruction of a fragCoord-LINEAR shader (the
# static gradient) at pinned 1:16 with bilerp ON matches the pinned 1:1
# center-sampled rendering byte-for-byte in the viewport (bilinear
# reconstruction of a linear function is exact under identical quantization;
# plan 015 Stage A). Negative check: bilerp OFF at 1:16 must NOT match 1:1
# (the per-block flood fill), proving the comparison can fail.
RD_B1="$(new_run_path bilerp-1to1)"
RD_B16="$(new_run_path bilerp-16-on)"
RD_B16OFF="$(new_run_path bilerp-16-off)"
HASH_B1=""
HASH_B16=""
HASH_B16OFF=""
if HOLYTOY_SCALE=1 RUN_DIR="$RD_B1" tools/run.sh tests/glsl/gradient.glsl &&
   grep -q "HT GUEST GLSL OK" "$RD_B1/guest.log"; then
    HASH_B1="$(smp_viewport_hash "$RD_B1")"
fi
if HOLYTOY_SCALE=16 RUN_DIR="$RD_B16" tools/run.sh tests/glsl/gradient.glsl &&
   grep -q "HT GUEST GLSL OK" "$RD_B16/guest.log"; then
    HASH_B16="$(smp_viewport_hash "$RD_B16")"
fi
if HOLYTOY_BILERP=0 HOLYTOY_SCALE=16 RUN_DIR="$RD_B16OFF" \
       tools/run.sh tests/glsl/gradient.glsl &&
   grep -q "HT GUEST GLSL OK" "$RD_B16OFF/guest.log" &&
   grep -q "HT BILERP OFF" "$RD_B16OFF/guest.log"; then
    HASH_B16OFF="$(smp_viewport_hash "$RD_B16OFF")"
fi
if [ -n "$HASH_B1" ] && [ -n "$HASH_B16" ] && [ -n "$HASH_B16OFF" ] &&
   [ "$HASH_B16" = "$HASH_B1" ] && [ "$HASH_B16OFF" != "$HASH_B1" ]; then
    ok "bilerp: 1:16 bilerp viewport $HASH_B16 == 1:1, and OFF differs"
else
    bad "bilerp: 1:1 '$HASH_B1' vs 16-on '$HASH_B16' vs 16-off '$HASH_B16OFF' (runs $RD_B1 $RD_B16 $RD_B16OFF)"
fi

echo "-- $PASS passed, $FAIL failed --"
[ "$FAIL" = 0 ]
