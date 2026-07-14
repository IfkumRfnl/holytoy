#!/usr/bin/env bash
# Shared host-side allocation and capacity helpers for run.sh and gui.sh.
# Callers must define ROOT, RUNS, MAX_RUNS, and RUN_QUEUE_TIMEOUT first.

holy_validate_run_settings() {
    local caller="$1"
    [[ "$MAX_RUNS" =~ ^[0-9]+$ ]] && (( MAX_RUNS >= 1 )) || {
        echo "$caller: MAX_RUNS must be an integer of at least 1" >&2
        return 2
    }
    [[ "$RUN_QUEUE_TIMEOUT" =~ ^[0-9]+$ ]] || {
        echo "$caller: RUN_QUEUE_TIMEOUT must be a nonnegative integer" >&2
        return 2
    }
}

# Open the persistent registry lock on fd 6. It coordinates the otherwise
# non-atomic mkdir -> .lock -> flock sequence with pruning.
holy_open_run_registry() {
    local caller="$1"
    mkdir -p -- "$RUNS" || {
        echo "$caller: could not create run registry: $RUNS" >&2
        return 2
    }
    RUNS_CANON="$(realpath "$RUNS")" || return 2
    exec 6>"$RUNS_CANON/.registry.lock" || {
        echo "$caller: could not open run registry lock" >&2
        return 2
    }
}

# Allocate and exclusively lock one direct child of RUNS. The optional third
# argument is a requested new or empty path; an empty value generates a path.
# Returns with the liveness lock held on fd 8 and RUN_DIR set canonically.
holy_allocate_run_dir() {
    local caller="$1"
    local prefix="$2"
    local requested="${3:-}"
    local candidate relative extra

    holy_open_run_registry "$caller" || return
    flock -x 6 || {
        echo "$caller: could not lock run registry" >&2
        return 2
    }

    if [ -n "$requested" ]; then
        candidate="$(realpath -m -- "$requested")" || return 2
        case "$candidate" in
            "$RUNS_CANON"/*) ;;
            *)
                echo "$caller: RUN_DIR must be a direct child of $RUNS_CANON" >&2
                return 2 ;;
        esac
        relative="${candidate#"$RUNS_CANON"/}"
        if [ -z "$relative" ] || [[ "$relative" == */* ]]; then
            echo "$caller: RUN_DIR must be a direct child of $RUNS_CANON" >&2
            return 2
        fi
        if [ -e "$candidate" ] && [ ! -d "$candidate" ]; then
            echo "$caller: RUN_DIR is not a directory: $candidate" >&2
            return 2
        fi
        mkdir -p -- "$candidate" || return 2
        RUN_DIR="$(realpath "$candidate")" || return 2
    else
        RUN_DIR="$(mktemp -d "$RUNS_CANON/$prefix-$(date -u +%Y%m%d-%H%M%S)-XXXXXX")" || return 2
        RUN_DIR="$(realpath "$RUN_DIR")" || return 2
    fi

    if [ -L "$RUN_DIR/.lock" ]; then
        echo "$caller: RUN_DIR lock must not be a symlink: $RUN_DIR" >&2
        return 2
    fi
    exec 8>"$RUN_DIR/.lock" || return 2
    if ! flock -n 8; then
        echo "$caller: RUN_DIR is active: $RUN_DIR" >&2
        return 2
    fi
    extra="$(find "$RUN_DIR" -mindepth 1 -maxdepth 1 ! -name .lock -print -quit)" || return 2
    if [ -n "$extra" ]; then
        echo "$caller: RUN_DIR is not empty: $RUN_DIR" >&2
        return 2
    fi

    flock -u 6 || return 2
}

# Ship GLSL unchanged for the in-guest compiler and launch the HolyToy app.
holy_prepare_glsl() {
    case "$SRC" in
        *.glsl) ;;
        *) return 0 ;;
    esac
    export HOLYTOY_GLSL="$(realpath "$SRC")"
    SRC="$ROOT/src/holytoy/HT.HC"
}

# Acquire any persistent VM slot and leave it locked on fd 9. The admission
# lock prevents a later caller from repeatedly overtaking an existing waiter;
# the admitted caller still scans every slot to avoid head-of-line blocking.
holy_acquire_vm_slot() {
    local caller="$1"
    local candidate queue_start

    mkdir -p "$ROOT/images" || return 2
    SLOT=""
    queue_start=$SECONDS
    exec 7>"$ROOT/images/slot.queue" || return 2
    if ! flock -w "$RUN_QUEUE_TIMEOUT" 7; then
        echo "$caller: no VM slot became free within ${RUN_QUEUE_TIMEOUT}s" >&2
        return 2
    fi
    while :; do
        for ((candidate=1; candidate<=MAX_RUNS; candidate++)); do
            if ! exec 9>"$ROOT/images/slot.$candidate"; then
                flock -u 7 || true
                return 2
            fi
            if flock -n 9; then
                SLOT="$candidate"
                flock -u 7 || return 2
                return 0
            fi
        done
        if (( SECONDS - queue_start >= RUN_QUEUE_TIMEOUT )); then
            echo "$caller: no VM slot became free within ${RUN_QUEUE_TIMEOUT}s" >&2
            flock -u 7 || true
            return 2
        fi
        sleep 0.1
    done
}
