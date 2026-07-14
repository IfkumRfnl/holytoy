#!/usr/bin/env bash
# One-boot corpus compatibility measurement: prep guest-safe shader copies,
# boot HT.HC in corpus batch mode, and print the staged report.
# Usage: corpus_run.sh            (whole corpus)
#        CORPUS_TIMEOUT=600 corpus_run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RUN_TIMEOUT="${CORPUS_TIMEOUT:-420}"
. "$ROOT/config.sh"
cd "$ROOT"

PREP_DIR="$OUT/corpus-guest"
python3 tools/glsl_prep.py --dest "$PREP_DIR" || exit 2

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
