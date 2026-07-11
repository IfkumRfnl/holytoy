# Plan 002: Spike the HolyToy in-guest app skeleton — editor pane + live viewport (VISION step 1)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 74e018b..HEAD -- src/ guest/ docs/VISION.md tools/test.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L (spike scoped to days; this plan is the smallest demo-able slice)
- **Risk**: MED (guest-side HolyC; unfamiliar OS APIs; mitigated by escape hatches)
- **Depends on**: plans/001-animation-capture.md (its distinct-frames proof pattern)
- **Category**: direction
- **Planned at**: commit `74e018b`, 2026-07-11

## Why this matters

Everything in this repo so far is *harness* — the product is HolyToy, an
in-TempleOS app with a code pane and a live viewport (docs/VISION.md, "Target
UX"). Step 1 of the v1 build order is the app skeleton: "split window —
editable code box (DolDoc edit control) + animating viewport task.
Recompile-on-change via `ExePutS2`; compile errors render inline in the code
pane, never crash the app. Temporary shader dialect: HolyC `MainImage` ABI"
(docs/VISION.md:107-109). This spike builds that smallest slice and resolves
the two design unknowns recorded in VISION.md's "Open questions": how to embed
an editable code region, and how the viewport presents (draw_it redrawing a
cached bitmap vs blitting a CDC sprite — VISION.md:124-126).

## Current state

- No app code exists. `src/` holds standalone toys (`gradient.HC`,
  `plasma.HC`, `palcycle.HC`, `reload.HC`); `guest/` holds only the harness
  hook (`ONCE.HC`), runner (`RUN.HC`), installer typing script (`INJECT.HC`).

- **The mechanics are already proven** — build on them, don't re-derive:
  - `src/reload.HC` proves in-task JIT hot-swap: redefining a function via a
    compiled string rebinds a *freshly taken* `&Effect` while old pointers
    keep the old code, and re-running `Fs->draw_it=&Effect;` hot-swaps the
    live callback (see its header, lines 8–13). It deliberately uses
    `ExePrint`; VISION.md:42-44 names `ExePutS2()` for compiling a string
    in-task. Verify the exact symbol and signature in `vendor/TempleOS`
    before use (see toolkit below).
  - `guest/RUN.HC:54-63` proves compile errors are catchable:
    ```holyc
    try {
      ExeFile2("E:/MAIN.HC");
      ok=TRUE;
    } catch {
      Fs->catch_except=TRUE;
      ec=Fs->except_ch;
      ...
    }
    ```
    `ExeFile2`, not `ExeFile` — `ExeFile` swallows `'Compiler'` exceptions
    (Compiler/CMain.HC:589). Same applies to whichever `ExePutS*` variant
    you use: confirm from vendor source that compiler exceptions reach your
    `catch`, and wrap every recompile in `try/catch` with
    `Fs->catch_except=TRUE`.
  - Compile errors only *throw* after boot reaches `RLf_ADAM_SERVER`
    (`guest/RUN.HC:44-48`); the harness already waits for it before running
    user code, so app code run via `make run` is safe.

- The target ABI (docs/VISION.md:64-67) — the spike's temporary shader
  dialect is HolyC directly against it:

  ```holyc
  class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
  U0 MainImage(CHtUniforms *u, I64 x, I64 y, U8 *out_color);  // one pixel
  ```

  "The runner owns the render loop: iterate the viewport, call `MainImage`,
  write pixels, present. User code never touches windows/DCs."

- Rendering idioms available in-repo: `src/plasma.HC` pokes
  `dc->body[sy*stride+sx]` with absolute screen coordinates
  (`stride=dc->width_internal`); `src/gradient.HC` uses `GrLine` per row in
  a `draw_it`. `src/palcycle.HC` shows `Spawn` of a background task with
  `Fs->animate_task` so `SettingsPop` reaps it.

- Guest-code rules (AGENTS.md "Guest-code rules" — violating these costs
  real debugging time): ASCII only; transfer-disk filenames single-dot
  UPPERCASE 8.3; a hard pointer fault drops into the debugger and the host
  times out with exit 2 and a register dump in `out/screen.txt`.

- Harness facts for proofs: `make run SRC=file.HC` injects the file as
  `E:/MAIN.HC` and executes it fullscreen; `out/screen.txt` is an exact OCR
  of the final screen (grep it); `out/guest.log` carries everything the task
  printed; `out/frames/frame-*.png` (after plan 001) are rolling per-run
  frames ~0.7 s apart. Long runs: raise `RUN_TIMEOUT` in `config.sh`
  temporarily rather than fighting the 90 s default.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Run the app headless | `make run SRC=src/holytoy/HT.HC` | exit 0, artifacts in `out/` |
| Read the screen | `grep STRING out/screen.txt` | match |
| Read app prints | `grep STRING out/guest.log` | match |
| Distinct frames | `ls out/frames/frame-*.png \| tail -n 6 \| xargs -r md5sum \| awk '{print $1}' \| sort -u \| wc -l` | ≥3 for an animating viewport |
| Interactive session | `make gui SRC=src/holytoy/HT.HC` | QEMU window, app running (needs WSLg) |
| Regression | `make test` | all proofs pass |

## Suggested executor toolkit

- Read `skills/holyc/SKILL.md` before writing any HolyC — it is the
  VM-validated knowledge base for this repo (its `src/*.HC` examples are
  known-good patterns).
- Answer every TempleOS API question from `vendor/TempleOS` source, never
  from memory (AGENTS.md, Troubleshooting). Many vendor files carry DolDoc
  binary codes: `python3 skills/holyc/scripts/strip_doldoc.py FILE`.
  Starting points: `vendor/TempleOS/Adam/DolDoc/` (document/edit machinery),
  `vendor/TempleOS/Demo/Graphics/` (window + draw_it patterns),
  `vendor/TempleOS/Compiler/` (ExePutS/ExeFile2 semantics),
  `vendor/TempleOS/Adam/Gr/GrPalette.HC` (palette calls).

## Scope

**In scope**:
- `src/holytoy/HT.HC` (create — the app; single file for the spike)
- `src/holytoy/SHADER1.HC`, `src/holytoy/SHADER2.HC` (create if you choose
  to keep sample dialect sources as separate files; inline strings are fine
  too)
- `tools/test.sh` (add the app proof as a new numbered proof)
- `docs/notes/step1-skeleton.md` (create — spike findings: the two design
  decisions with measured/observed rationale)
- `config.sh` — only if the app run needs a longer `RUN_TIMEOUT`; if so,
  prefer documenting per-run override `RUN_TIMEOUT=... tools/run.sh ...`
  over changing the default. (Check first whether run.sh honors an
  environment override; config.sh currently assigns unconditionally, so
  a per-run override may require a small `: "${RUN_TIMEOUT:=90}"`-style
  change in config.sh — that is in scope.)

**Out of scope** (do NOT touch):
- `guest/ONCE.HC`, `guest/RUN.HC` — the boot protocol. The app runs *under*
  the existing runner as an ordinary `MAIN.HC`. Changing `ONCE.HC` requires
  re-baking the golden image; do not.
- `tools/run.sh`, `tools/qmp.py`, `tools/install_os.sh` — harness internals.
- `skills/`, `vendor/` — maintained by a parallel agent session.
- The GLSL transpiler — that is plan 004; this spike's input dialect is
  HolyC against the `MainImage` ABI only.

## Git workflow

- Branch: `advisor/002-holytoy-skeleton`
- Commit style: short imperative sentence, matching `git log`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Viewport-only skeleton — the render loop owns the pixels

Create `src/holytoy/HT.HC` with: the `CHtUniforms` class exactly as in the
ABI excerpt above; a built-in sample shader `U0 MainImage(CHtUniforms *u,
I64 x, I64 y, U8 *out_color)` (e.g. plasma-like, time-varying — adapt the
math from `src/plasma.HC`); and a renderer that fills the *top* region of
the screen (viewport = full width × ~60% height for the spike) by iterating
pixels, calling `MainImage`, and writing bytes. Start with the
`draw_it` + `dc->body` poking idiom from `src/plasma.HC` — it is proven in
this repo. Render at reduced scale if a full-res loop is visibly slow
(VISION.md:83-85 blesses 4× block scaling); note whatever you observe, the
real perf work is plan 003. Update `u->i_time` from `tS` and `u->i_frame`
per call.

**Verify**: `make run SRC=src/holytoy/HT.HC` → exit 0; distinct-frames
pipeline (table above) ≥3; `python3 tools/imginfo.py out/latest.png` →
`640 480 N` with N ≥ 8.

### Step 2: Code pane — render the shader source in the bottom region

Display the current shader source text in the bottom region of the screen
(the code pane). For the spike, investigate in this order and take the
first that works: (a) the task's own DolDoc document (the task Doc is
already a scrolling text surface — `DocClear`/prints — but it occupies the
whole window; check vendor `Adam/DolDoc/` for how windows scroll/clip), (b)
a second task owning the bottom window region with its Doc showing the
source, (c) manual `GrPrint`/text drawing of the source buffer into the
bottom region from the same `draw_it`. **This choice is a spike finding** —
record in `docs/notes/step1-skeleton.md` what you tried and why the winner
won. The pane must show at least the first ~10 lines of the current shader
source and have room for an error line.

**Verify**: `make run SRC=src/holytoy/HT.HC` → exit 0, and
`grep -i "MainImage" out/screen.txt` matches (the source text is on screen
together with the animating viewport).

### Step 3: Recompile path — swap the shader from a string at runtime

Add `Bool HtRecompile(U8 *src)`: compiles `src` in-task (the `ExePutS2`-
family call you verified in vendor source), inside `try/catch` with
`Fs->catch_except=TRUE` in the catch; on success rebind the renderer's
function pointer to a fresh `&MainImage` (the `src/reload.HC` pattern:
fresh address-of after redefinition picks up the new code); on failure
leave the old shader running and render the error text into the code pane's
error line. The app must survive a failed compile (VISION.md:33-34).

Wire a self-test into the app for headless proof: when the app starts under
the harness, it (1) renders shader v1 for ~2 s, (2) calls
`HtRecompile(v2_source)` where v2 draws a visibly different pattern,
(3) prints `HT SWAP OK` if the rebound pointer changed, (4) calls
`HtRecompile(bad_source)` (syntax error), prints `HT ERRSURVIVE OK` if it
caught the exception and the viewport is still animating, then keeps
rendering v2 until the harness screenshots.

**Verify**: `make run SRC=src/holytoy/HT.HC` → exit 0;
`grep "HT SWAP OK" out/guest.log` and `grep "HT ERRSURVIVE OK"
out/guest.log` both match; distinct-frames ≥3.

### Step 4: Interactive editing — the smallest live loop

Make the code pane *editable* enough to demo: at minimum, a recompile
trigger key (F5 or Ctrl-Enter — check vendor `Adam/` message loop /
`ScanChar`/`GetKey` idioms for reading keys without blocking the renderer)
that recompiles the current source buffer. If a genuinely editable DolDoc
region proves workable within the spike, use it; if not, key-triggered
recompile of a source buffer is the accepted spike outcome — the full
editor is follow-up work, record it as such in the notes. Test it live with
`make gui SRC=src/holytoy/HT.HC` and describe the session in the notes.

**Verify**: `make gui` session (if WSLg available): pressing the trigger
key recompiles — describe observed behavior in
`docs/notes/step1-skeleton.md`. Headless regression: `make run
SRC=src/holytoy/HT.HC` still exits 0 with both `HT * OK` markers.

### Step 5: Add the app proof to `tools/test.sh` and write the notes

New proof following the existing `ok`/`bad` pattern: run
`tools/run.sh src/holytoy/HT.HC`; assert exit 0, both `HT SWAP OK` and
`HT ERRSURVIVE OK` in `$GUEST_LOG`, and ≥3 distinct trailing frames.
Finish `docs/notes/step1-skeleton.md`: decisions on (a) code-pane
mechanism, (b) viewport presentation (what you used, what you rejected,
observed cost — this answers VISION.md:124-126), (c) recompile trigger,
(d) explicit list of what step 1 still lacks (real mouse-driven editing,
render-scale toggle, ms/frame readout — the latter two are plan 003).

**Verify**: `make test` → all proofs pass (the pre-existing ones plus this
one), exit 0.

## Test plan

- The self-test markers (`HT SWAP OK`, `HT ERRSURVIVE OK`) + screen OCR +
  distinct-frames are the machine checks; the new `test.sh` proof bundles
  them. Model the proof on the existing gradient proof (`tools/test.sh`
  proof 2).
- Edge cases the self-test must cover: failed compile leaves previous
  shader running (viewport still animates after step 3's bad source);
  recompile of *identical* source is harmless.
- Verification: `make test` twice in a row, all pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `make run SRC=src/holytoy/HT.HC` exits 0
- [ ] `grep "HT SWAP OK" out/guest.log` and `grep "HT ERRSURVIVE OK" out/guest.log` both match
- [ ] `grep -i "MainImage" out/screen.txt` matches (code pane visible)
- [ ] Distinct trailing frames ≥3 (animating viewport at screenshot time)
- [ ] `make test` exits 0 (all proofs including the new one, twice in a row)
- [ ] `docs/notes/step1-skeleton.md` records the three design decisions
- [ ] `git status` shows nothing modified outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `ExePutS*` symbol you find in vendor source cannot compile a string
  in-task with catchable compiler exceptions (i.e. the VISION.md:42-44
  premise fails in practice). Report exactly what you ran and what the
  guest showed (`out/screen.txt`).
- A hard fault drops the guest into the debugger (exit 2 + register dump in
  `out/screen.txt`) more than three times on the same step — capture the
  dump and report rather than shotgun-debugging.
- Step 2: none of the three code-pane approaches shows text alongside an
  animating viewport after a genuine attempt at each — report what each did.
- You are tempted to modify `guest/RUN.HC` or `guest/ONCE.HC` to make the
  app work — that changes the boot protocol for every toy; stop and report
  why the app can't run as a plain `MAIN.HC`.
- `make test` regressions you cannot attribute to your change.

## Maintenance notes

- This skeleton is the spine of v1; plans 003 (perf floor) and 004 (GLSL)
  plug into it — 003 replaces the shader math and adds the ms/frame
  readout; 004's transpiler output must compile via `HtRecompile` unchanged.
- Reviewer should scrutinize: every recompile wrapped in try/catch with
  `Fs->catch_except=TRUE` (an uncaught exception in `draw_it`-adjacent code
  can wedge the winmgr); no UTF-8 anywhere in `src/holytoy/`; spawned tasks
  registered so they die with the app (the `Fs->animate_task` pattern in
  `src/palcycle.HC`).
- Deferred explicitly: real mouse/cursor editing in the code pane, shader
  load/save on the transfer disk, palette/dither modes (VISION step 4), and
  everything measured-but-unfixed about performance (plan 003).
