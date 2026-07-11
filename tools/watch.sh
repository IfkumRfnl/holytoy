#!/usr/bin/env bash
# Watch mode: re-run SRC through the VM whenever it changes on disk.
# Usage: watch.sh SRC.HC
# Polls mtime (no inotify dependency). Ctrl-C to stop.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:?usage: watch.sh SRC.HC}"
[ -f "$SRC" ] || { echo "watch.sh: no such file: $SRC" >&2; exit 2; }

echo "watch.sh: watching $SRC (Ctrl-C to stop)"
LAST=""
while true; do
    M="$(stat -c %Y "$SRC" 2>/dev/null || echo gone)"
    if [ "$M" != "$LAST" ]; then
        LAST="$M"
        echo "── $(date +%H:%M:%S) change detected — running ──"
        "$ROOT/tools/run.sh" "$SRC"
        echo "── exit $? — waiting for changes ──"
    fi
    sleep 0.5
done
