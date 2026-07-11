# Plan 005: Isolated run directories and bounded parallel VMs

> **Executor instructions**: Read this plan completely before editing. Follow
> the steps in order and run each verification before continuing. Preserve
> the `run.sh` exit-code contract: 0 = guest success, 1 = guest compile/runtime
> error, 2 = harness failure. If a STOP condition occurs, report it instead of
> improvising. When complete, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: this plan was written at commit `b3b6e5b`,
> after plan 001 was committed. Run:
>
> ```sh
> git diff --stat b3b6e5b..HEAD -- \
>   config.sh Makefile tools/run.sh tools/mkxfer.sh tools/gui.sh \
>   tools/watch.sh tools/test.sh AGENTS.md README.md
> git status --short
> ```
>
> Plan-only changes are expected. If harness files changed, compare them with
> the Current state section and stop if the design no longer applies.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MEDIUM (rewires all host-side run paths and VM coordination)
- **Depends on**: 001 (DONE)
- **Category**: DX / reliability
- **Planned at**: `b3b6e5b`, 2026-07-11

## Outcome

Two or more agents can run TempleOS VMs concurrently without sharing an
overlay, transfer disk, QMP socket, screenshot, log, status, or frame set.
Every invocation prints one authoritative directory containing its results.
Old completed directories are pruned automatically, while active runs are
protected by locks. A configurable slot limit bounds RAM and CPU use.

There is deliberately no `out/latest` path or symlink. In a parallel system,
"latest" means "whichever unrelated run finished most recently" and is not a
safe result locator. Callers must use the `RUN_DIR=...` line printed by the
invocation they started, or provide a unique `RUN_DIR` themselves.

## Current state

- `config.sh` defines shared `OVERLAY`, `XFER`, `LATEST_PNG`, and `GUEST_LOG`
  paths.
- `tools/run.sh` serializes on `images/run.lock` and overwrites shared files
  in `images/` and `out/`.
- `tools/mkxfer.sh` always creates `images/xfer.img` and writes the global
  `images/mtools.conf`.
- `tools/gui.sh` uses the same overlay and transfer disk as batch runs but
  does not take `images/run.lock`.
- `tools/watch.sh` invokes `run.sh` once per change; no watch-specific state
  needs to persist.
- `tools/test.sh` reads the shared artifact paths after each of four VM
  proofs.
- `make clean` removes the shared paths directly.
- `AGENTS.md` documents fixed, overwritten artifact paths and global
  serialization. `README.md` still describes three tests.

Guest code needs no changes. `guest/RUN.HC` already communicates only through
the transfer disk attached to that VM (`E:/MAIN.HC`, `E:/LOG.TXT`, and
`E:/STAT.TXT`).

## Target contract

### One directory per VM invocation

A batch run creates a collision-safe directory with `mktemp`, for example:

```text
out/runs/run-20260711-142233-a8K3Qp/
  .lock             liveness lock, held for the whole invocation
  slot              slot number held while QEMU ran
  overlay.qcow2     transient; removed when the invocation exits
  xfer.img          retained for inspection and guest-written files
  mtools.conf       points mtools drive x: at this xfer.img
  qmp.sock          transient; removed when the invocation exits
  qemu.log
  latest.png
  screen.txt
  guest.log
  status
  frames/
  anim.gif
```

GUI sessions use the same layout with a `gui-...` prefix. Every watch
iteration is a separate batch invocation and therefore gets a separate
directory. Do not reuse one mutable directory for an entire watch session;
that would discard earlier results and recreate the stale-artifact problem
inside a narrower scope.

Only coordination and immutable inputs remain shared:

- `images/golden.qcow2` is a read-only input; `images/TempleOS.ISO` is an
  input and is not mutated by normal runs.
- `images/slot.N` are persistent zero-byte semaphore files.
- `out/runs/` is the parent directory, not a result directory.

### Locating results

After validating its source argument, `run.sh` creates and locks the result
directory and prints this as its first stdout line:

```text
RUN_DIR=/absolute/path/to/out/runs/run-20260711-142233-a8K3Qp
```

It prints the line before transfer-disk creation, slot waiting, or QEMU
startup, so a later harness failure is still diagnosable. Preflight failures
that occur before a directory can be useful (missing source or golden image)
may exit 2 without a `RUN_DIR` line.

`RUN_DIR=/path tools/run.sh SRC.HC` is supported for tests and orchestration,
with these rules:

1. The resolved path must be a direct child of `out/runs/`; nested paths are
   rejected so each override is exactly one retention unit.
2. It may be newly created or already exist empty.
3. `run.sh` takes its `.lock` itself; callers never hold that lock.
4. Any content other than an unlocked `.lock` makes reuse fail with exit 2.

The override is an exclusive destination, not a way to overwrite a previous
run. This makes accidental reuse fail safely and lets test code know the path
without parsing terminal output.

### Bounded concurrency

`MAX_RUNS=3` limits concurrent QEMUs. Batch and GUI invocations both count:
they consume the same `$MEM` MB and approximately one TCG-saturated core.
Callers poll `images/slot.1` through `images/slot.$MAX_RUNS` for an available
`flock`, up to `RUN_QUEUE_TIMEOUT=300` seconds.

Do not wait only on slot 1 after an initial scan: slot 2 or 3 might become
free while a long-lived GUI still owns slot 1. Polling all slots avoids that
head-of-line stall. The acquired descriptor must remain open through QEMU's
lifetime. Write the selected number to `<run-dir>/slot`; proof 5 uses two
different retained slot numbers to prove the VMs actually overlapped.

### Retention and cleanup

`KEEP_RUNS=20` means "keep the 20 newest unlocked run directories." Active
directories do not count toward the limit and are never removed. At the start
of each batch or GUI invocation, prune older unlocked directories. The total
may temporarily be `KEEP_RUNS + active runs + 1` until the next prune pass.

`tools/prune-runs.sh [COUNT]` owns this policy. `make clean` calls it with 0,
so clean removes completed runs but skips active ones. It must not remove
`images/slot.*`: unlinking a locked semaphore file would let a new process
lock a different inode with the same name and exceed `MAX_RUNS`.

Allocation and pruning coordinate through persistent
`out/runs/.registry.lock`. An allocator holds the registry lock from before
creating its directory until after acquiring that directory's `.lock`;
pruning holds it while enumerating and deleting. This closes the otherwise
unlocked creation window. Failure to remove one directory emits a warning and
does not fail pruning or prevent other directories from being processed.

The per-run EXIT trap kills/waits for QEMU and removes `overlay.qcow2` and
`qmp.sock` on success, failure, timeout, or interruption. It retains all
diagnostic artifacts, including `xfer.img`. If the whole process is killed
with SIGKILL, its directory becomes unlocked and a later prune removes the
leaked transients with the directory.

## Scope

Files to modify:

- `config.sh`
- `tools/mkxfer.sh`
- `tools/run.sh`
- `tools/gui.sh`
- `tools/watch.sh`
- `tools/test.sh`
- `tools/install_os.sh` (required scope correction described below)
- `Makefile`
- `AGENTS.md`
- `README.md`
- `plans/README.md` (status only when implementation is done)

File to add:

- `tools/prune-runs.sh`
- `tools/run-common.sh`
- `tools/test-run-locks.sh`

Scope correction: `mkxfer.sh` no longer has a global transfer-image default,
so golden-image hook injection in `tools/install_os.sh` must pass its private
transfer path. The original scope missed this forced dependency; reverting
the edit would break `make golden`.

Out of scope:

- `guest/**`, `tools/qmp.py`, `tools/scrtext.py`
- `vendor/**`, `skills/holyc/**`, `docs/VISION.md`, and HolyC toys
- changing the meanings of run.sh exit codes 0, 1, and 2
- an `out/latest` symlink or any other process-global result pointer
- running more than `MAX_RUNS` VMs by bypassing the semaphore

Do not push or open a PR unless explicitly asked.

## Steps

### Step 1: Replace shared-path config with concurrency and retention knobs

In `config.sh`:

1. Remove `OVERLAY`, `XFER`, `LATEST_PNG`, and `GUEST_LOG`.
2. Keep `GOLDEN`, `HDD_SIZE`, `XFER_SIZE`, `OUT`, and all timing knobs.
3. Add:

   ```sh
   # QEMU
   MAX_RUNS=3             # concurrent VMs; each uses MEM MiB and ~1 TCG core
   RUN_QUEUE_TIMEOUT=300  # wait this long for any VM slot

   # Output
   RUNS="$OUT/runs"
   KEEP_RUNS=20           # newest completed run dirs to retain
   ```

Validate both numeric concurrency values before using them in scripts:
`MAX_RUNS` must be at least 1, and the queue timeout must be nonnegative.

Verification:

```sh
bash -n config.sh
grep -En '^(OVERLAY|XFER|LATEST_PNG|GUEST_LOG)=' config.sh
```

Expected: syntax succeeds and grep has no output.

### Step 2: Make transfer-disk creation explicit and per-run

Change `tools/mkxfer.sh` to:

```text
Usage: mkxfer.sh XFER_IMG [SRC.HC]
```

Parse arguments as:

```sh
XFER="${1:?usage: mkxfer.sh XFER_IMG [SRC.HC]}"
SRC="${2:-}"
mkdir -p "$(dirname "$XFER")"
```

Write `mtools.conf` beside `XFER_IMG`:

```sh
export MTOOLSRC="$(dirname "$XFER")/mtools.conf"
printf 'drive x: file="%s" partition=1\nmtools_skip_check=1\n' \
    "$XFER" >"$MTOOLSRC"
```

Keep the existing MBR/FAT32 creation, partition type patch, guest-file
copies, optional source copy, and `HOLYTOY_GUI` marker unchanged.

Verification:

```sh
bash -n tools/mkxfer.sh
D="$(mktemp -d)"
tools/mkxfer.sh "$D/xfer.img" src/gradient.HC
MTOOLSRC="$D/mtools.conf" mdir x:/
rm -rf "$D"
```

Expected: `mdir` lists `ONCE.HC`, `RUN.HC`, and `MAIN.HC`.

### Step 3: Add lock-aware retention

Add executable `tools/prune-runs.sh` with `set -euo pipefail`. It sources
`config.sh`, accepts an optional nonnegative integer count (default
`KEEP_RUNS`), and:

1. Creates `$RUNS` and opens its persistent registry lock if needed.
2. Takes the registry lock and collects immediate child directories
   newest-mtime first.
3. For each directory, opens `<dir>/.lock` on fd 7 and attempts
   `flock -n 7`.
4. Skips the directory without counting it if the lock is busy.
5. Keeps the first COUNT unlocked directories and `rm -rf --` the rest,
   warning and continuing if an individual removal fails.

Open fd 7 again for every iteration so the previous probe lock is released.
Handle a directory disappearing between enumeration and lock-open without
failing the entire prune; concurrent pruners are expected. Do not inspect or
delete anything outside `$RUNS`.

Host-only verification (no VM required):

```sh
mkdir -p out/runs/prune-live out/runs/prune-dead
(
  exec 8>out/runs/prune-live/.lock
  flock 8
  : >out/runs/prune-live/ready
  sleep 30
) & LPID=$!
while [ ! -e out/runs/prune-live/ready ]; do sleep 0.05; done
tools/prune-runs.sh 0
test -d out/runs/prune-live && test ! -e out/runs/prune-dead
kill "$LPID"; wait "$LPID" 2>/dev/null || true
tools/prune-runs.sh 0
test ! -e out/runs/prune-live
```

Expected: the live directory survives the first prune and disappears after
its owner exits.

### Step 4: Rework run.sh around one exclusive run directory

Keep the current VM lifecycle, frame capture, GIF generation, log stripping,
status parsing, result wording, and exit codes. Change path ownership and
cleanup as follows. Rewrite the script header to document the printed
`RUN_DIR`, the per-run artifact names, and the unchanged exit-code meanings.

#### 4.1 Preflight, allocate, lock, and announce

After checking the source and golden image, open and exclusively lock the
persistent registry lock, then either:

- generate `RUN_DIR` with
  `mktemp -d "$RUNS/run-$(date -u +%Y%m%d-%H%M%S)-XXXXXX"`; or
- validate and create the caller's direct-child `RUN_DIR` override.

Canonicalize both `$RUNS` and `$RUN_DIR` before the containment check so a
symlink cannot escape the parent. Open `$RUN_DIR/.lock` on fd 8, require
`flock -n 8`, reject pre-existing content other than `.lock`, then print:

```sh
echo "RUN_DIR=$RUN_DIR"
```

Nothing earlier in a valid invocation may write to stdout. Errors still go
to stderr.

Release the registry lock only after fd 8 owns the liveness lock. Put this
allocation sequence and shared slot acquisition in `tools/run-common.sh` and
use it from both batch and GUI wrappers.

Call `tools/prune-runs.sh "$KEEP_RUNS"` after acquiring the liveness lock;
the new directory is therefore skipped as active.

Define every path locally:

```sh
OVERLAY="$RUN_DIR/overlay.qcow2"
XFER="$RUN_DIR/xfer.img"
SOCK="$RUN_DIR/qmp.sock"
FRAMES="$RUN_DIR/frames"
LATEST_PNG="$RUN_DIR/latest.png"
GUEST_LOG="$RUN_DIR/guest.log"
STATUS_FILE="$RUN_DIR/status"
```

Create `frames/`. Do not clear a previous result set: the exclusivity check
must reject reuse instead.

#### 4.2 Create this run's disks

Call:

```sh
"$ROOT/tools/mkxfer.sh" "$XFER" "$SRC"
qemu-img create -q -f qcow2 -b "$GOLDEN" -F qcow2 "$OVERLAY"
```

Treat failure of either command as harness exit 2 after reporting the run
directory. Do not proceed to QEMU with a half-created disk.

#### 4.3 Acquire any available VM slot

Before launching QEMU, poll all slot files until one locks or
`RUN_QUEUE_TIMEOUT` elapses. Use one fd (for example 9), reopening it for
each attempted slot; opening a new file on fd 9 releases the prior failed
attempt. On success:

```sh
printf '%s\n' "$SLOT" >"$RUN_DIR/slot"
```

Keep fd 9 open until the script exits. If no slot becomes available, report
the run directory and exit 2. Do not fall back to a global lock.

#### 4.4 Point QEMU and artifacts at the run directory

Use the local overlay, transfer disk, and QMP socket. Redirect QEMU output to
`$RUN_DIR/qemu.log`. Write OCR to `$RUN_DIR/screen.txt`, the GIF to
`$RUN_DIR/anim.gif`, and guest extraction to `$GUEST_LOG` and `$STATUS_FILE`.

Set mtools internally:

```sh
export MTOOLSRC="$RUN_DIR/mtools.conf"
```

There must be no `$OUT/...`, `images/work.qcow2`, `images/xfer.img`, global
`images/mtools.conf`, or global QMP socket reference left in `run.sh`.

#### 4.5 Make cleanup unconditional

Install an EXIT trap after local paths exist. It must:

- kill and wait for QEMU if `QPID` is set and still alive;
- remove only `$OVERLAY` and `$SOCK`;
- preserve the script's intended exit status.

The normal path may stop/wait for QEMU explicitly, but leave the EXIT trap
installed until all extraction and result reporting is complete. Initialize
`QPID=""` so failures before QEMU startup are safe.

Verification:

```sh
bash -n tools/run.sh
grep -En '\$OUT/|images/(work\.qcow2|xfer\.img|mtools\.conf|qmp-run\.sock|run\.lock)' tools/run.sh
tools/run.sh src/gradient.HC; RC=$?; echo "exit=$RC"
```

Expected: grep has no output; the run's first stdout line is `RUN_DIR=...`;
exit is 0. Inspect that directory and require:

```sh
test -f "$RUN_DIR/latest.png"
test -f "$RUN_DIR/screen.txt"
test -f "$RUN_DIR/guest.log"
test -f "$RUN_DIR/status"
test -f "$RUN_DIR/xfer.img"
test -f "$RUN_DIR/mtools.conf"
test -f "$RUN_DIR/slot"
test ! -e "$RUN_DIR/overlay.qcow2"
test ! -e "$RUN_DIR/qmp.sock"
```

When verifying interactively, assign `RUN_DIR` from the printed line; do not
guess it by sorting `out/runs` while other agents may be active.

### Step 5: Give GUI sessions isolated state and a real slot

In `tools/gui.sh`:

1. Validate the optional source if one was supplied.
2. Generate and canonicalize a `gui-...` directory under `$RUNS`.
3. Lock `<run-dir>/.lock` on fd 8 and print `RUN_DIR=<absolute path>`.
4. Prune via `tools/prune-runs.sh`.
5. Define local overlay, transfer disk, and QMP socket paths.
6. Call `HOLYTOY_GUI=1 tools/mkxfer.sh "$XFER" "$SRC"`.
7. Acquire a slot with the same all-slots polling algorithm as `run.sh` and
   write its number to `<run-dir>/slot`.
8. Start the boot-key helper against the local socket.
9. Run QEMU in the foreground without `exec`, then remove the overlay and
   socket in an EXIT trap. The non-`exec` wrapper is necessary for cleanup.

The slot and liveness descriptors remain open for the whole GUI lifetime.
A long-lived GUI therefore reduces available batch capacity by one, which is
the intended resource limit.

Verification:

```sh
bash -n tools/gui.sh
grep -En 'images/(work\.qcow2|xfer\.img|mtools\.conf|qmp-gui\.sock)' tools/gui.sh
```

Expected: syntax succeeds and grep has no output. Do not launch WSLg during
automated verification.

### Step 6: Keep watch iterations independent

`tools/watch.sh` should call `tools/run.sh` through `env -u RUN_DIR` on each
change. Update its comments/output so users know that every iteration prints
and retains a new `RUN_DIR`. Do not set a session-wide `RUN_DIR`, do not hold
a liveness lock in the watcher, and do not overwrite prior iterations.

Verification:

```sh
bash -n tools/watch.sh
grep -n 'RUN_DIR=' tools/watch.sh
```

Expected: an inherited or make-exported `RUN_DIR` is removed before each
iteration (a help message mentioning the printed `RUN_DIR` is fine).

### Step 7: Move the proof suite to explicit directories

Update `tools/test.sh` to five proofs. Add a small helper that creates an
empty unique test directory under `$RUNS`, then pass it as `RUN_DIR` for each
invocation. Proofs 1-4 retain their existing assertions but read only their
own directories:

1. smoke: marker from `$RD/xfer.img` using `$RD/mtools.conf`;
2. gradient: `$RD/latest.png`;
3. error: `$RD/guest.log`, still requiring run.sh exit 1;
4. animate: `$RD/frames/frame-*.png` and `$RD/anim.gif`.

Add proof 5, parallel isolation:

1. Create two ASCII HolyC sources that write different marker strings to
   `E:/MARKER.TXT`.
2. Create two distinct empty run directories.
3. Start both `run.sh` commands in the background before waiting for either.
4. Capture both exit codes without letting `set -u` abort the suite.
5. Read each marker through its own `mtools.conf`.
6. Read each retained `slot` file.
7. Pass only if both runs exited 0, both markers match their own source, and
   the nonempty slot numbers differ.

Different slots are the proof of overlap: a merely serialized
implementation would normally reuse the same first slot and must fail this
test. Require `MAX_RUNS >= 2` at test startup with a clear failure message.

Always remove temporary source files with a trap, including when a proof is
interrupted. Retain run directories for diagnosis; retention handles them.

Verification:

```sh
bash -n tools/test.sh
make test
```

Expected: `5 passed, 0 failed`. Under TCG, the parallel pair may run slower
than one VM but should complete within the existing per-run timeout.

### Step 8: Make clean safe around active runs

Change `make clean` to:

- call `tools/prune-runs.sh 0`;
- remove legacy pre-plan artifacts (`out/latest.png`, `out/screen.txt`,
  `out/guest.log`, `out/status`, `out/qemu.log`, `out/frames`, `out/anim.gif`,
  `images/work.qcow2`, `images/xfer.img`, `images/qmp-run.sock`,
  `images/qmp-gui.sock`, and `images/mtools.conf`);
- never remove `out/runs` wholesale;
- never remove `images/slot.*`;
- never touch `images/golden.qcow2`.

Prefix the `run` recipe with `@` so `make run` does not echo the shell command
before `run.sh` prints `RUN_DIR=...`.

Verification while one fake directory is locked:

```sh
mkdir -p out/runs/clean-live
(
  exec 8>out/runs/clean-live/.lock
  flock 8
  : >out/runs/clean-live/ready
  sleep 30
) & LPID=$!
while [ ! -e out/runs/clean-live/ready ]; do sleep 0.05; done
make clean
test -d out/runs/clean-live
kill "$LPID"; wait "$LPID" 2>/dev/null || true
make clean
test ! -e out/runs/clean-live
```

### Step 9: Rewrite the operator contract

Update `AGENTS.md`:

- Commands: `make test` runs five proofs.
- Replace the fixed-path artifact table with the per-run layout and explain
  the `RUN_DIR=` line and exclusive `RUN_DIR` override.
- State explicitly that there is no `out/latest` pointer; use the directory
  printed by the invocation you started.
- Update the run-flow diagram to show per-run `xfer.img`, overlay, and QMP
  socket.
- Replace global serialization with `MAX_RUNS` slots shared by batch and GUI
  VMs; excess callers wait up to `RUN_QUEUE_TIMEOUT`.
- Document automatic `KEEP_RUNS` retention and lock-aware `make clean`.
- Replace the global `MTOOLSRC` instruction with:
  `MTOOLSRC=<run-dir>/mtools.conf mdir x:/`.
- Point troubleshooting at `<run-dir>/screen.txt`, `guest.log`, and
  `qemu.log`.
- Add `plans/` and the per-run layout to the repository layout section.

Update `README.md`:

- Quickstart says five proofs and no longer promises `out/latest.png`.
- Describe the printed `<run-dir>/latest.png` as the result of a cycle.
- Change `out/screen.txt` to "the run's `screen.txt`."
- List animation and parallel isolation as proofs 4 and 5.

Do not expand README into an operations manual; AGENTS.md remains the source
of truth.

Verification:

```sh
rg -n 'run\.lock|out/latest|out/screen\.txt|out/guest\.log|MTOOLSRC=images/mtools\.conf|\(3 tests\)|four proofs' \
  AGENTS.md README.md Makefile tools config.sh
```

Expected: no stale-contract matches. Contextual historical references in
plans are allowed.

### Step 10: Final verification and status

Run:

```sh
bash -n tools/{mkxfer,prune-runs,run,gui,watch,test}.sh
make clean
make run SRC=src/gradient.HC
make test
git diff --check
git status --short
```

Then update plan 005 from TODO to DONE in `plans/README.md`, including the
parallel proof's two observed slot numbers. Do not mark it done if any
criterion below is unmet.

## Done criteria

- [x] `make run SRC=src/gradient.HC` prints `RUN_DIR=` as its first stdout
      line and exits 0.
- [x] Its directory contains its own screenshot, OCR, guest log, status,
      frames, transfer disk, mtools config, QEMU log, and slot number.
- [x] Its overlay and QMP socket are absent after exit.
- [x] A syntax-error run still exits 1; harness failures still exit 2.
- [x] `make test` exits 0 with `5 passed, 0 failed`.
- [x] Parallel proof markers stay isolated and its retained slot numbers are
      different.
- [x] `make clean` and automatic pruning skip locked directories.
- [x] Batch and GUI code both acquire the same bounded slot pool.
- [x] No global result path or `out/latest` symlink exists.
- [x] No script requires global `images/mtools.conf` or `MTOOLSRC` setup.
- [x] `git diff --check` passes and only ratified in-scope files changed.
- [x] `plans/README.md` marks plan 005 DONE.

## STOP conditions

Stop and report if:

- Current harness code has drifted enough that the paths or lifecycle above
  no longer match.
- Two QEMUs cannot open independent overlays backed by the read-only golden
  image; include both `qemu.log` files in the report.
- Proofs 1-4 pass but the parallel proof times out twice. Report elapsed
  times and both run directories; do not raise `RUN_TIMEOUT` above 180 or set
  `MAX_RUNS=1` to hide the failure.
- Two simultaneously launched runs receive the same slot while both QEMUs
  are demonstrably alive.
- `flock` cannot distinguish live and unlocked run directories, or pruning
  removes a locked directory.
- Correctness appears to require changing guest code, the golden image, or
  QEMU drive-sharing semantics.
- The host lacks enough RAM/CPU for two 512 MiB TCG VMs. Capacity policy then
  needs an explicit maintainer decision.

## Review notes

Review these invariants especially carefully:

- A run directory is never reused or cleared; an override is unique and
  exclusive.
- The liveness lock is owned by the VM wrapper, not by its caller.
- All VM types use the same capacity limit.
- Waiting callers poll every slot, not only slot 1.
- Slot files are persistent and never unlinked by clean.
- `xfer.img` survives successful cleanup because tests and humans inspect
  guest-written files after QEMU exits.
- The EXIT trap removes only transient per-run state and does not erase
  failure evidence.
- Watch mode produces one immutable result directory per iteration.
- No "latest" convenience pointer is added later without redesigning result
  ownership.

Deferred deliberately: a richer machine-readable result protocol (JSON),
mouse/keyboard scripting for live guests, age-based retention, and placing
QMP sockets in `$XDG_RUNTIME_DIR` if repository paths approach Unix socket
length limits.
