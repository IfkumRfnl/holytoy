#!/usr/bin/env bash
# Host-only proofs for run allocation/pruning coordination and prune failures.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$(mktemp -d "${TMPDIR:-/tmp}/holytoy-lock-proof-XXXXXX")"
TEST_RUNS="$CONTROL/runs"
LIVE="$TEST_RUNS/allocation-window"
ALLOC_PID=""
PRUNE_PID=""

cleanup() {
    touch "$CONTROL/continue" "$CONTROL/release" 2>/dev/null || true
    [ -z "$PRUNE_PID" ] || kill "$PRUNE_PID" 2>/dev/null || true
    [ -z "$ALLOC_PID" ] || kill "$ALLOC_PID" 2>/dev/null || true
    [ -z "$PRUNE_PID" ] || wait "$PRUNE_PID" 2>/dev/null || true
    [ -z "$ALLOC_PID" ] || wait "$ALLOC_PID" 2>/dev/null || true
    /bin/rm -rf -- "$CONTROL"
}
trap cleanup EXIT

# Hold the registry across a deliberately widened mkdir-to-flock window.
# prune-runs.sh must block, then observe the liveness lock and skip the run.
(
    export HOLYTOY_RUNS="$TEST_RUNS"
    . "$ROOT/config.sh"
    . "$ROOT/tools/run-common.sh"
    holy_open_run_registry lock-proof
    flock -x 6
    mkdir -p "$LIVE"
    touch "$CONTROL/ready"
    while [ ! -e "$CONTROL/continue" ]; do sleep 0.01; done
    exec 8>"$LIVE/.lock"
    flock 8
    flock -u 6
    touch "$CONTROL/locked"
    while [ ! -e "$CONTROL/release" ]; do sleep 0.01; done
) &
ALLOC_PID=$!

while [ ! -e "$CONTROL/ready" ]; do sleep 0.01; done
HOLYTOY_RUNS="$TEST_RUNS" "$ROOT/tools/prune-runs.sh" 0 &
PRUNE_PID=$!
sleep 0.1
kill -0 "$PRUNE_PID" 2>/dev/null || {
    echo "test-run-locks.sh: prune did not wait for allocation registry lock" >&2
    exit 1
}
touch "$CONTROL/continue"
while [ ! -e "$CONTROL/locked" ]; do sleep 0.01; done
wait "$PRUNE_PID"
PRUNE_PID=""
[ -d "$LIVE" ] || {
    echo "test-run-locks.sh: prune removed a newly locked run" >&2
    exit 1
}
touch "$CONTROL/release"
wait "$ALLOC_PID"
ALLOC_PID=""
HOLYTOY_RUNS="$TEST_RUNS" "$ROOT/tools/prune-runs.sh" 0
[ ! -e "$LIVE" ] || {
    echo "test-run-locks.sh: unlocked proof run survived pruning" >&2
    exit 1
}

# One failed deletion must warn without preventing deletion of other entries.
mkdir -p "$TEST_RUNS/prune-fail" "$TEST_RUNS/prune-dead" "$CONTROL/bin"
cat >"$CONTROL/bin/rm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *prune-fail*) exit 1 ;;
    *) exec /bin/rm "$@" ;;
esac
EOF
chmod +x "$CONTROL/bin/rm"
PATH="$CONTROL/bin:$PATH" HOLYTOY_RUNS="$TEST_RUNS" \
    "$ROOT/tools/prune-runs.sh" 0 2>"$CONTROL/prune.err"
grep -q 'warning: could not remove .*prune-fail' "$CONTROL/prune.err"
[ -d "$TEST_RUNS/prune-fail" ] && [ ! -e "$TEST_RUNS/prune-dead" ] || {
    echo "test-run-locks.sh: prune failure was not isolated" >&2
    exit 1
}

echo "PASS: host locks: allocation is atomic with pruning; delete failures are isolated"
