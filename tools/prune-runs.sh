#!/usr/bin/env bash
# Keep the newest completed run directories; active directories are locked.
# Usage: prune-runs.sh [COUNT]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/config.sh"
. "$ROOT/tools/run-common.sh"

COUNT="${1:-$KEEP_RUNS}"
[[ "$COUNT" =~ ^[0-9]+$ ]] || {
    echo "prune-runs.sh: COUNT must be a nonnegative integer" >&2
    exit 2
}

holy_open_run_registry prune-runs.sh || exit 2
flock -x 6 || {
    echo "prune-runs.sh: could not lock run registry" >&2
    exit 2
}
kept=0
while IFS= read -r -d '' entry; do
    dir="${entry#* }"
    [ -d "$dir" ] || continue
    [ ! -L "$dir/.lock" ] || continue

    # Reopening fd 7 releases the previous iteration's probe lock.
    if ! exec 7>"$dir/.lock"; then
        continue
    fi
    if ! flock -n 7; then
        continue
    fi

    if (( kept < COUNT )); then
        kept=$((kept + 1))
    elif ! rm -rf -- "$dir"; then
        echo "prune-runs.sh: warning: could not remove $dir; skipping" >&2
    fi
done < <(find "$RUNS_CANON" -mindepth 1 -maxdepth 1 -type d \
    -printf '%T@ %p\0' 2>/dev/null | sort -z -nr)
