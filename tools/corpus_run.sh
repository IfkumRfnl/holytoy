#!/usr/bin/env bash
# One-boot corpus compatibility measurement: prep guest-safe shader copies,
# boot HT.HC in corpus batch mode, print the staged report, then extract the
# guest's visual sample dumps and compare them against committed reference
# DATs (plan 010 oracle; reported separately from exec%, per AGENTS.md).
# Usage: corpus_run.sh                                (default corpus)
#        CORPUS_DIR=corpus/shadertoy/v1 corpus_run.sh (older version)
#        CORPUS_TIMEOUT=1200 corpus_run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Dumping 2x2880 samples of heavy 3D shaders adds minutes under TCG.
export RUN_TIMEOUT="${CORPUS_TIMEOUT:-900}"
. "$ROOT/config.sh"
cd "$ROOT"

CORPUS_DIR="${CORPUS_DIR:-corpus/shadertoy/v2}"
VERSION="$(basename "$CORPUS_DIR")"
REFS_DIR="${CORPUS_REFS:-tests/corpus-visual/refs-$VERSION}"
PREP_DIR="$OUT/corpus-guest-$VERSION"
python3 tools/glsl_prep.py --corpus "$CORPUS_DIR/shaders" \
    --dest "$PREP_DIR" --manifest-strata || exit 2

LOG="$(mktemp -p "${TMPDIR:-/tmp}" corpus-run-XXXX.log)"
trap 'rm -f -- "$LOG"' EXIT

HOLYTOY_CORPUS_DIR="$PREP_DIR" tools/run.sh src/holytoy/HT.HC | tee "$LOG"
RC=$?
RD="$(sed -n 's/^RUN_DIR=//p' "$LOG" | head -1)"
if [ -z "$RD" ] || [ ! -f "$RD/guest.log" ]; then
    echo "corpus_run: no guest.log (run.sh exit $RC, run dir '$RD')" >&2
    exit 2
fi
python3 tools/corpus_report.py "$RD/guest.log" --manifest "$PREP_DIR/CORPUS.TXT"
REPORT_RC=$?

DUMP_DIR="$RD/visual"
mkdir -p "$DUMP_DIR"
MTOOLSRC="$RD/mtools.conf" mcopy -n 'x:/V*.DAT' "$DUMP_DIR/" 2>/dev/null
echo
if [ -d "$REFS_DIR" ]; then
    python3 tools/visual_compare.py --dumps "$DUMP_DIR" --refs "$REFS_DIR" \
        --manifest "$PREP_DIR/CORPUS.TXT"
else
    echo "corpus_run: no reference DATs at $REFS_DIR - visual table skipped" >&2
fi
exit "$REPORT_RC"
