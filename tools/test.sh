#!/usr/bin/env bash
# holytoy proof suite. Three round-trips through the real VM:
#   1. smoke     guest writes a marker string back to the host
#   2. gradient  screenshot contains an actual multi-color gradient
#   3. error     deliberate HolyC syntax error -> nonzero exit, message on host
# Exit 0 only if all three behave.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
cd "$ROOT"

PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }

MARKER="HOLYTOY_MARKER_$$_$(date +%s)"

# ── 1. smoke: marker round-trip ─────────────────────────────────────────
TMPHC="$(mktemp -p "${TMPDIR:-/tmp}" smoke-XXXX.HC)"
cat >"$TMPHC" <<EOF
U8 *st="$MARKER";
FileWrite("B:/MARKER.TXT",st,StrLen(st));
EOF
if tools/run.sh "$TMPHC"; then
    export MTOOLSRC="$ROOT/images/mtools.conf"
    GOT="$(mtype x:/MARKER.TXT 2>/dev/null | tr -d '\r\0')"
    if [ "$GOT" = "$MARKER" ]; then
        ok "smoke: marker round-tripped host->guest->host"
    else
        bad "smoke: marker mismatch (got '$GOT')"
    fi
else
    bad "smoke: run.sh exited $? (see $GUEST_LOG)"
fi
rm -f "$TMPHC"

# ── 2. gradient: screenshot shows a gradient ────────────────────────────
if tools/run.sh src/gradient.HC; then
    INFO="$(python3 tools/imginfo.py "$LATEST_PNG" 2>/dev/null || echo "0 0 0")"
    read -r W H NCOLORS <<<"$INFO"
    if [ "$W" = 640 ] && [ "$H" = 480 ] && [ "$NCOLORS" -ge 8 ]; then
        ok "gradient: $LATEST_PNG is ${W}x${H} with $NCOLORS colors"
    else
        bad "gradient: screenshot looks wrong (${W}x${H}, $NCOLORS colors)"
    fi
else
    bad "gradient: run.sh exited $?"
fi

# ── 3. error: syntax error surfaces on host with exit 1 ────────────────
tools/run.sh tests/syntax-error.HC
RC=$?
if [ "$RC" = 1 ]; then
    if grep -qi "err\|compile\|except" "$GUEST_LOG" 2>/dev/null; then
        ok "error: exit 1 and compiler message in $GUEST_LOG"
    else
        bad "error: exit 1 but no error text in $GUEST_LOG"
    fi
else
    bad "error: expected exit 1, got $RC"
fi

echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" = 0 ]
