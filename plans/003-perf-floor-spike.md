# Plan 003: Perf-floor spike — measure F64 vs LUT fixed-point per-pixel math, pick the format (VISION step 2)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 091deb4..HEAD -- src/ docs/VISION.md config.sh`
> If any in-scope file changed since this plan's verification refresh, compare
> the "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Planned at `74e018b`; verification
> commands refreshed after plan 005 replaced global `out/` artifacts with
> per-run `RUN_DIR` directories and plan 002 landed `src/holytoy/HT.HC` —
> the app that will adopt this plan's HTMATH library.)

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW (pure measurement + a new library file; nothing existing changes)
- **Depends on**: none (parallel-safe with 001/002; plan 002 consumes the result)
- **Category**: direction
- **Planned at**: commit `74e018b`, 2026-07-11

## Why this matters

The v1 spec calls per-pixel math "the hard constraint": 640×480 = 307k
pixels under QEMU TCG (no KVM on this host), and "per-pixel F64
transcendentals won't hit interactive rates" (docs/VISION.md:75-77). The
planned mitigations are fixed-point LUTs for `sin/cos/atan2/sqrt` and
render-scale (VISION.md:78-85). But the fixed-point format is an explicitly
open question: "16.16 vs 10.22 vs per-op choice; needs profiling under both
TCG and KVM before committing" (VISION.md:121-123). Today the repo has zero
measurements and zero telemetry — nobody knows the actual ms/frame of the
existing plasma. This spike produces the numbers, a first `HTMATH` LUT
library with a proven accuracy bound, and a recorded format decision that
plan 002's app builds on.

## Current state

- `src/plasma.HC:23-40` is the reference workload — per-pixel F64 with four
  `Sin` and one `Sqrt` per pixel, poking `dc->body[sy*stride+sx]`:

  ```holyc
  v=Sin(fx*0.043+t)+
    Sin(fy*0.031-t*0.7)+
    Sin((fx+fy)*0.021+t*0.5)+
    Sin(Sqrt(fx*fx+fy*fy)*0.024-t*1.3);
  c=ToI64(v*4.0)&15;
  ```

  It runs as a `draw_it` callback, which the window manager calls (~30 fps
  cap) — so **draw_it cannot measure raw throughput**; the benchmark must
  drive its own render loop and time it.

- Timing source: `tS` is an `F64` wall-clock seconds value, already used by
  `src/plasma.HC:24` and `src/reload.HC:25`. It is sufficient for
  ms/frame-level measurement over dozens of frames. If you want finer
  resolution, look up the timestamp-counter idioms in `vendor/TempleOS`
  (e.g. `GetTSC` — verify in vendor source, never from memory).

- Palette targets: 16 palette registers, 48-bit RGB, settable per frame —
  `GrPaletteColorSet(I64 color_num, CBGR48)` (see `src/plasma.HC:5-17` for
  a working sine-ramp palette, and VISION.md:86-91).

- How results get to the host: anything the guest prints lands in the task
  Doc, which `guest/RUN.HC` dumps to `E:/LOG.TXT` → the run's `guest.log`
  (DolDoc codes stripped). So the benchmark just prints lines like
  `"BENCH f64 %d ms/frame\n",ms;` and the host greps them. Post plan 005
  there are NO global `out/` artifact paths: each run prints its result
  directory as the first stdout line (`RUN_DIR=...`). For scripted
  verification, reserve the directory yourself:
  `RD="$(mktemp -d "$PWD/out/runs/verify-003-XXXXXX")";
  RUN_DIR="$RD" tools/run.sh src/bench-math.HC` (new/empty direct child of
  `out/runs/`; directories are single-use — fresh `$RD` per run).

- Guest-code rules (AGENTS.md): ASCII only; the host filename doesn't need
  8.3 (mkxfer renames the source to `MAIN.HC`); a hard fault = debugger =
  host exit 2 with a register dump in the run's `screen.txt`.

- `RUN_TIMEOUT=90` seconds (`config.sh`) bounds the whole VM cycle; a
  benchmark comfortably fits if each variant renders ~30 frames.

- KVM: `config.sh` auto-enables KVM when `/dev/kvm` exists; on this host it
  does not (WSL2, TCG only). The spec wants numbers under both — record TCG
  now, leave a marked TODO row for KVM in the notes.

## Commands you will need

All run commands below assume a fresh reserved run directory:
`RD="$(mktemp -d "$PWD/out/runs/verify-003-XXXXXX")"` (new `$RD` per run).

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Run benchmark | `RUN_DIR="$RD" tools/run.sh src/bench-math.HC` | exit 0, artifacts in `$RD` |
| Read results | `grep '^BENCH' "$RD/guest.log"` | one line per variant |
| Accuracy gate | `grep 'BENCH maxerr OK' "$RD/guest.log"` | match |
| Regression | `make test` | `6 passed, 0 failed` |

## Suggested executor toolkit

- Read `skills/holyc/SKILL.md` before writing HolyC; imitate `src/plasma.HC`
  for rendering and palette code.
- Verify any TempleOS API you are not copying from `src/` against
  `vendor/TempleOS` source (strip DolDoc codes with
  `python3 skills/holyc/scripts/strip_doldoc.py FILE`). Never from memory.

## Scope

**In scope** (create only; nothing existing changes):
- `src/holytoy/HTMATH.HC` (create — the LUT/fixed-point math library:
  table-driven `sin`/`cos` at minimum; `sqrt`/`atan2` if time allows)
- `src/bench-math.HC` (create — self-contained benchmark; `#include`s or
  inlines HTMATH so it runs as a single injected `MAIN.HC` — **check
  first** whether `#include` of a second file works under the transfer-disk
  runner; only `MAIN.HC` is injected, so likely you must paste HTMATH's
  contents into the benchmark file or extend nothing — pasting is fine for
  the spike, with `HTMATH.HC` as the canonical copy)
- `docs/notes/perf-floor.md` (create — the numbers and the decision)

**Out of scope** (do NOT touch):
- `src/plasma.HC` and the other existing toys — they are test fixtures.
- `tools/`, `guest/`, `config.sh` — no harness changes needed.
- `skills/`, `vendor/` — maintained by a parallel agent session.
- Optimizing plan 002's app — that lands after this spike reports.

## Git workflow

- Branch: `advisor/003-perf-floor`
- Commit style: short imperative sentence, matching `git log`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Benchmark harness with the F64 baseline

Create `src/bench-math.HC`: set the plasma palette, get a drawable `dc`
(the `DCAlias` idiom from `src/palcycle.HC`, or body pokes per
`src/plasma.HC` — your own loop, NOT `draw_it`), then render N=30 frames of
the exact plasma formula above (F64, real `Sin`/`Sqrt`) at 640×480, timing
with `tS` around the whole batch. Print
`"BENCH f64_640 %d ms/frame\n"` with the integer average. Then the same at
160×120 with 4×4 block fill (VISION.md:83-85), printed as `f64_160`.

**Verify**: fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/bench-math.HC` →
exit 0; `grep -c '^BENCH f64' "$RD/guest.log"` → 2.

### Step 2: LUT sin/cos in fixed point, both candidate formats

In `src/holytoy/HTMATH.HC`, implement table-driven sine: a 4096-entry
I64 table generated once at startup from real `Sin`, plus lookup functions
for **both** candidate formats — 16.16 and 10.22 (VISION.md:121-122) — over
a full-turn angle input (pick the angle convention, document it in the file
header; a power-of-two turn subdivision makes the wrap a mask). Cosine =
phase-shifted lookup. Include a self-check routine: max |LUT sin − Sin|
over ≥10k sample angles, computed in the guest; print
`"BENCH maxerr %d/65536 OK\n"` if the max error ≤ 2/4096 of full scale
(a generous bound for a 4096-entry table with no interpolation — if you add
linear interpolation, tighten and note it), else print `... FAIL`.

**Verify** (after pasting into the benchmark per Scope note): fresh `$RD`;
`RUN_DIR="$RD" tools/run.sh src/bench-math.HC` → exit 0;
`grep 'BENCH maxerr' "$RD/guest.log"` shows `OK`.

### Step 3: Fixed-point plasma variants, measured

Add to the benchmark: the same plasma formula rewritten against the LUT in
16.16 and in 10.22 (angles and accumulators in the fixed format; the
`Sqrt`-distance term may stay F64 for now if a fixed `sqrt` is out of reach
— but then measure a variant with the distance term dropped too, so the
LUT-vs-F64 delta is not masked). Print one `BENCH` line per variant at
640×480 and at 160×120. Also print a visual-parity marker: render one F64
frame and one LUT frame into two halves of the screen at the same `t` so
the final screenshot shows them side by side.

**Verify**: fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/bench-math.HC` →
exit 0; `grep -c '^BENCH' "$RD/guest.log"` ≥ 7 (2 f64 + maxerr + ≥4 fixed
variants); `$RD/latest.png` shows the split-screen parity frame (eyeball
it; they should look alike).

### Step 4: Record the decision

Write `docs/notes/perf-floor.md`: a table of every `BENCH` line (variant,
resolution, ms/frame, fps), the accuracy result, the environment (TCG,
WSL2, host CPU from `lscpu | head -5`), a **KVM: not measured — TODO** row,
and a short "Decision" section: which format wins on these numbers, whether
render-scale alone already hits interactive rates, and what the app (plan
002) should adopt for its ms/frame readout. If the numbers are inconclusive
(<20% spread between formats), say so — "per-op choice deferred, 16.16
default" is a valid decision; record the reasoning.

**Verify**: `grep -c '^| ' docs/notes/perf-floor.md` ≥ 6 (the table exists);
`make test` → all proofs still pass.

## Test plan

- The benchmark is the test: its `maxerr ... OK` line is a machine-checked
  accuracy gate that should keep running in the future whenever HTMATH
  changes (note this in the file header). Do not add it to `make test` yet
  — it costs a VM cycle and HTMATH has no consumers until plan 002 adopts
  it; plan 002's proof will cover it indirectly.
- Sanity case: LUT sin at angle 0, quarter-turn, half-turn printed
  explicitly (expect 0, +max, 0 in fixed scale) — cheap and catches
  off-by-one table indexing.
- Verification: `make run SRC=src/bench-math.HC` exit 0 twice; numbers
  within ~2× across runs (TCG jitter is real; wild swings mean the timing
  is wrong).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] fresh `$RD`: `RUN_DIR="$RD" tools/run.sh src/bench-math.HC` exits 0
- [ ] `grep '^BENCH' "$RD/guest.log"` shows ≥7 lines incl. `maxerr ... OK`
- [ ] `docs/notes/perf-floor.md` exists with the numbers table and a Decision section
- [ ] `src/holytoy/HTMATH.HC` exists, ASCII-only (`LC_ALL=C grep -P '[^\x00-\x7F]' src/holytoy/HTMATH.HC` → no output)
- [ ] `make test` exits 0 (`6 passed, 0 failed`, no regressions)
- [ ] `git status` shows nothing modified outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The benchmark exceeds `RUN_TIMEOUT` (host exit 2) even after cutting N to
  10 frames — report the partial `BENCH` lines from the run's `guest.log`.
- A hard fault (register dump in the run's `screen.txt`) persists after checking
  table-index bounds — fixed-point indexing bugs fault easily in ring 0;
  report the dump.
- The accuracy self-check FAILs after two fix attempts.
- LUT variants come out *slower* than F64 at the same resolution — that
  invalidates the VISION.md:78-82 premise; report the numbers, don't
  massage the benchmark until it agrees.

## Maintenance notes

- Plan 002's app adopts HTMATH and the ms/frame readout; when KVM becomes
  available (`/dev/kvm` on a non-WSL host), rerun `src/bench-math.HC` and
  fill the TODO row — the format decision should be revisited only if KVM
  flips the ordering.
- Reviewer should scrutinize: the timing loop actually excludes palette
  setup and table generation; the fixed-point plasma is numerically the
  same formula (same constants, scaled), not a simplified one.
- Deferred explicitly: `atan2`/`sqrt` LUTs if not reached, dithering
  (`ROPF_PROBABILITY_DITHER`, VISION.md:90-91), and integrating the
  ms/frame readout into the app (plan 002's follow-up).
