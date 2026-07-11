# Plan 001: Harness captures animation — numbered frames, a GIF, and a "viewport animates" proof

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 74e018b..HEAD -- tools/run.sh tools/test.sh config.sh AGENTS.md README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `74e018b`, 2026-07-11

## Why this matters

holytoy is a live-graphics playground, but the harness can only prove *still
pictures*. The v1 spec (docs/VISION.md, "Build order") requires acceptance
proofs like "viewport animates ≥N distinct frames" for the upcoming HolyToy
app — and today `tools/run.sh` throws away every screendump except the last
one, so no test can distinguish an animating shader from a frozen one.
`ffmpeg` is already a hard dependency (README quickstart), used only to decode
single PNGs. This plan keeps the per-run frames, assembles an animated GIF,
and adds a fourth proof to `make test` that an animated toy actually animates.
It unblocks the acceptance tests for every subsequent v1 step and gives the
README an animated demo.

## Current state

- `tools/run.sh` — one VM cycle: inject source, boot overlay, rolling QMP
  screendumps, extract logs. The frame loop (lines 66–81) overwrites a single
  file and keeps only the newest good frame:

  ```bash
  # tools/run.sh:70-81
  while kill -0 "$QPID" 2>/dev/null; do
      if (( SECONDS - START > RUN_TIMEOUT )); then
          TIMED_OUT=1
          echo "run.sh: hard timeout after ${RUN_TIMEOUT}s — killing VM" >&2
          break
      fi
      if python3 "$ROOT/tools/qmp.py" "$SOCK" screendump "$FRAMES/cur.png" 2>/dev/null; then
          cp -f "$FRAMES/cur.png" "$FRAMES/last-good.png"
          N=$((N+1))
      fi
      sleep "$FRAME_INTERVAL"
  done
  ```

  `FRAMES="$OUT/frames"` (line 33); the directory is wiped at run start
  (line 35: `rm -f ... "$FRAMES"/*.png ...`).

- Timing: `FRAME_INTERVAL=0.7` seconds (config.sh). The guest holds the final
  picture for `HT_SHOW_MS` = 4000 ms before rebooting (`guest/RUN.HC:17` and
  `:74`), and an installed `draw_it` callback **keeps animating during that
  hold** — the window manager calls it every frame independently of the
  task's `Sleep`. So an animated toy yields ~5 distinct frames in the hold
  window; a static toy yields identical ones.

- `tools/test.sh` — three proofs (smoke marker round-trip, gradient
  screenshot, error surfacing), each a real VM cycle (~20 s each). Pattern:

  ```bash
  # tools/test.sh:13-15
  PASS=0; FAIL=0
  ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
  bad()  { echo "FAIL: $1" >&2; FAIL=$((FAIL+1)); }
  ```

- `src/plasma.HC` — per-pixel animated plasma driven by `tS` (wall-clock
  seconds); guaranteed to change every frame. Use it as the animation
  fixture. `src/gradient.HC` redraws identical pixels every frame — it is
  the *negative* fixture (animated callback, static output).

- Harness contract that must NOT change (AGENTS.md "Run artifacts"): exit
  codes 0/1/2 of `run.sh`, and the fixed artifact paths `out/latest.png`,
  `out/screen.txt`, `out/guest.log`, `out/status`.

- Repo conventions: bash with `set -uo pipefail`, `ROOT` resolved from
  `BASH_SOURCE`, all knobs in `config.sh` (see the header comment there:
  "sourced by every tool script"). Match `tools/run.sh` style.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| One cycle | `make run SRC=src/plasma.HC` | exit 0, `out/latest.png` written |
| Full proofs | `make test` | `── N passed, 0 failed ──`, exit 0 |
| Image facts | `python3 tools/imginfo.py FILE.png` | `WIDTH HEIGHT NCOLORS` |
| Frame diff | `md5sum out/frames/frame-*.png` | one line per kept frame |

Prerequisite: `images/golden.qcow2` must exist (`make golden` builds it,
unattended, ~1–2 min). If it is missing and `make golden` fails twice, STOP.

## Scope

**In scope** (the only files you should modify):
- `tools/run.sh`
- `tools/test.sh`
- `config.sh` (new knobs only)
- `AGENTS.md` (document the new artifacts — two lines in the artifact table)
- `README.md` (only if you regenerate the demo image; optional)

**Out of scope** (do NOT touch):
- `guest/RUN.HC`, `guest/ONCE.HC` — the guest protocol is fine as is;
  raising `HT_SHOW_MS` is a documented escape hatch, not a first move.
- `tools/gui.sh`, `tools/install_os.sh`, `tools/qmp.py` — not involved.
- `run.sh` exit codes and existing artifact paths — hard contract.
- `skills/`, `vendor/` — maintained by a parallel agent session.

## Git workflow

- Branch: `advisor/001-animation-capture`
- Commit style: short imperative sentence, matching `git log` (e.g.
  "Kill AutoComplete popup before screenshot; gradient visually clean").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Keep numbered frames in `tools/run.sh`

In the frame loop, after the existing `cp -f "$FRAMES/cur.png"
"$FRAMES/last-good.png"`, also keep a numbered copy:

```bash
cp -f "$FRAMES/cur.png" "$(printf '%s/frame-%04d.png' "$FRAMES" "$N")"
```

(Place it before `N=$((N+1))` or adjust the index — just be consistent.)
The wipe at run start (line 35) already clears `"$FRAMES"/*.png`, so frames
never leak across runs. Add `ANIM_FRAMES=8` to `config.sh` (number of
trailing frames considered for the GIF/proof) with a one-line comment.

**Verify**: `make run SRC=src/plasma.HC` → exit 0, and
`ls out/frames/frame-*.png | wc -l` ≥ 5.

### Step 2: Assemble `out/anim.gif` from the trailing frames

After the frame loop (near where `out/latest.png` is produced, run.sh:85–89),
assemble the last `$ANIM_FRAMES` numbered frames into a GIF. Must be
best-effort — never affect exit codes (follow the `|| true` pattern used for
`scrtext.py` on line 88):

```bash
if ls "$FRAMES"/frame-*.png >/dev/null 2>&1; then
    ANIM_DIR="$FRAMES/anim"; rm -rf "$ANIM_DIR"; mkdir -p "$ANIM_DIR"
    i=0
    for f in $(ls "$FRAMES"/frame-*.png | tail -n "$ANIM_FRAMES"); do
        cp -f "$f" "$(printf '%s/%03d.png' "$ANIM_DIR" "$i")"; i=$((i+1))
    done
    ffmpeg -v quiet -y -framerate 2 -i "$ANIM_DIR/%03d.png" "$OUT/anim.gif" || true
fi
```

(2 fps matches the 0.7 s capture cadence closely enough; exact rate is not
load-bearing.)

**Verify**: `make run SRC=src/plasma.HC` → exit 0, `out/anim.gif` exists,
and `ffmpeg -v quiet -i out/anim.gif -f null - && echo OK` prints `OK`.

### Step 3: Add proof 4 to `tools/test.sh` — plasma animates

After the existing third proof, add a fourth using the `ok`/`bad` helpers:
run `tools/run.sh src/plasma.HC`; on exit 0, count distinct frame contents
among the trailing frames:

```bash
DISTINCT=$(ls "$OUT"/frames/frame-*.png 2>/dev/null | tail -n 6 |
           xargs -r md5sum | awk '{print $1}' | sort -u | wc -l)
```

Pass if `DISTINCT -ge 3` (lenient on purpose: TCG timing varies and some
captures may repeat a frame). Also assert `out/anim.gif` exists. Update the
header comment of `test.sh` (currently "Three round-trips") to four.

**Verify**: `make test` → `── 4 passed, 0 failed ──`, exit 0. Run it twice;
both runs must pass (guards against timing flakiness).

### Step 4: Document the new artifacts

In `AGENTS.md`, add rows to the "Run artifacts" table for
`out/frames/frame-NNNN.png` (rolling per-run frames, ~0.7 s apart) and
`out/anim.gif` (trailing frames as GIF, best-effort). Mention `ANIM_FRAMES`
where config knobs are discussed if a natural spot exists; do not restructure
the document.

**Verify**: `grep -n "anim.gif" AGENTS.md` → at least one hit.

## Test plan

- The new proof 4 in `tools/test.sh` IS the test: plasma yields ≥3 distinct
  trailing frames and a decodable `out/anim.gif`.
- Negative sanity check (manual, not committed as a proof):
  `make run SRC=src/gradient.HC` then the same `DISTINCT` pipeline should
  yield 1–2 — confirms the metric actually discriminates. Record the number
  you observed in the plans/README.md status note.
- Verification: `make test` → 4/4 pass, twice in a row.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `make test` exits 0 with `── 4 passed, 0 failed ──` (two consecutive runs)
- [ ] `make run SRC=src/plasma.HC` exits 0 and leaves ≥5 files matching `out/frames/frame-*.png` and a decodable `out/anim.gif`
- [ ] `make run SRC=tests/syntax-error.HC` still exits 1 (exit-code contract intact)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The frame loop in `tools/run.sh` no longer matches the excerpt (drift).
- Plasma produces <3 distinct trailing frames even with `tail -n 6` — this
  means capture cadence vs the 4 s hold window doesn't yield enough animated
  frames. Report the observed frame count and md5 spread; the fix (raising
  `HT_SHOW_MS` in `guest/RUN.HC`) touches an out-of-scope file and needs a
  human decision.
- `make golden` is needed and fails twice.
- Proof 4 passes and fails intermittently across three `make test` runs
  (timing flake) — report the numbers instead of loosening the threshold
  below 3.

## Maintenance notes

- The VISION.md step-1 app proofs ("viewport animates ≥N distinct frames")
  should reuse proof 4's `md5sum | sort -u` pattern — that was the point of
  this plan.
- Reviewer should scrutinize: exit codes of `run.sh` unchanged; GIF assembly
  strictly best-effort (`|| true`); no new hard dependency (ffmpeg was
  already required).
- Deferred on purpose: capturing at higher cadence (sub-0.7 s) and MP4
  output — do it when a real shader gallery needs smoother demos.
