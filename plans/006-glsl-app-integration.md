# Plan 006: Wire GLSL into the HolyToy app host-side — HTMATH, ms/frame readout, `SHADER.HC` injection, testable `iMouse` (VISION step 3, first half)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat e91b74a..HEAD -- src/holytoy/ tools/ tests/ guest/ docs/ README.md AGENTS.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L (three cooperating workstreams; each is S/M alone)
- **Risk**: MED (two proofs depend on guest timing under TCG; mitigations below)
- **Depends on**: plans/002-holytoy-skeleton-spike.md, plans/003-perf-floor-spike.md, plans/004-glsl2hc-prototype.md (all DONE)
- **Category**: direction
- **Planned at**: commit `e91b74a`, 2026-07-12

## Why this matters

VISION step 3 is "GLSL in the input box: transpiler prototyped host-side
(`glsl2hc.py`) for fast iteration, then embedded so the guest compiles GLSL
without host help; Shadertoy uniforms incl. real `iMouse`"
(docs/VISION.md:111). Plans 002–004 built the pieces but nothing connects
them: the app (`src/holytoy/HT.HC`) still renders F64 sample shaders with no
perf readout, the transpiler has **no in-repo consumer** (its e2e fixtures
were deliberately left out of `make test` for that reason —
docs/notes/glsl2hc.md "Harness integration status"), and `tools/qmp.py` is
keyboard-only, so `iMouse` is untestable (deferred finding,
plans/README.md:47-50). This plan closes all three gaps host-side: a GLSL
file typed on Linux renders animated in the app's viewport through the same
`HtRecompile` path the future in-guest transpiler (plan 007) will use, the
app adopts the perf-floor results (docs/notes/perf-floor.md item 5), and the
harness can move the guest's mouse to a coordinate and prove it landed.

**Decided tradeoffs to honor** (do not re-litigate):
- The host `.glsl` pipeline is dev tooling and the proof mechanism, NOT the
  shipped product surface — "the v1 input box takes GLSL directly" in the
  guest (docs/VISION.md:53, 100-103). Frame it that way in docs.
- Fixed-point format is **16.16** (docs/notes/perf-floor.md Decision 2).
- The `CHtUniforms` ABI is **frozen** in this plan. No button fields, no
  F64 mouse — `iMouse.zw=0` stays a documented deviation. Changing the ABI
  ripples into `tools/glsl2hc.py`'s emitter, which is out of scope.

## Current state

Files and their roles:

- `src/holytoy/HT.HC` (273 lines) — the app: viewport + code pane +
  `HtRecompile` + headless self-test + GUI key loop.
- `src/holytoy/HTMATH.HC` (65 lines) — LUT sin/cos library from plan 003.
  Angles are *turns* in 16.16 (one turn = 0x10000). Entry points: `HTMInit`
  (build table once at startup), `HTMSin16`, `HTMCos16`, `HTMRad16`.
  Currently consumed by nothing but `src/bench-math.HC` (which embeds its
  own copy — do not modify either).
- `tools/glsl2hc.py` — GLSL→HolyC transpiler (plan 004). Do not modify.
  `--runner none` emits preamble + user functions + `MainImage` only.
  Fixture sizes with `--runner none`: gradient 1120 B, circle 1425 B,
  plasma 1959 B (measured at `e91b74a`).
- `tools/mkxfer.sh` — builds the FAT32 transfer disk; copies `ONCE.HC`,
  `RUN.HC`, optionally `SRC` as `MAIN.HC`, and `GUI.TXT` when
  `HOLYTOY_GUI` is set (that env-gated pattern is the one to imitate).
- `tools/run.sh` — batch run; `tools/gui.sh` — GUI session (both call
  `mkxfer.sh`, so env vars exported by them reach it); `tools/watch.sh`
  just re-invokes `run.sh`, so it inherits any `run.sh` change.
- `tools/run-common.sh` — shared helpers `holy_validate_run_settings`,
  `holy_open_run_registry`, `holy_allocate_run_dir`, `holy_acquire_vm_slot`.
- `tools/qmp.py` — QMP client, verbs: `screendump keys type typefile quit
  reset`. `send_keys`/`type_text` with `KEY_DELAY` (env `QMP_KEY_DELAY`,
  default 0.04 s) is the pacing pattern to imitate for mouse events.
- `tools/test.sh` — proof suite, currently **6 proofs** (`smoke gradient
  error animate parallel holytoy`), ends `-- N passed, M failed --`.
- `tests/glsl/{gradient,circle,plasma}.glsl` — fixtures. `plasma.glsl`
  uses `iTime`, so it animates under the app runner (needed for the
  distinct-frames proof).
- `guest/RUN.HC` — guest runner; runs `E:/MAIN.HC` under try/catch,
  writes `E:/STAT.TXT`/`E:/LOG.TXT`, holds the picture 4 s, reboots.
  **Not modified by this plan** — `SHADER.HC` is read by the app
  (MAIN.HC), not by the runner.

Key excerpts of `src/holytoy/HT.HC` as of `e91b74a`:

```holyc
// HT.HC:10-15 — layout constants
#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_SCALE	4	//shade once per 4x4 block (VISION.md render scale)
#define HT_PANE_ROW	36	//first code-pane text row (window row, 8px cells)
#define HT_SRC_ROWS	20	//source lines shown in the pane
#define HT_STATUS_ROW	58	//status/error line (last window row)
#define HT_SRC_MAX	4096

// HT.HC:17-20 — the frozen ABI and the shader function pointer
class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);

// HT.HC:76-77 — the pane header line (HtDrawPane)
  dc->color=LTGRAY;
  GrPrint(dc,0,HT_PANE_ROW*8," HolyToy  F5 recompile  F1/F2 samples  ESC exit");

// HT.HC:109-147 — HtRecompile(src): copies src into ht_src (pane shows what
// was attempted), appends "\nht_new_fp=&MainImage;\n", ExePutS2 under
// try/catch, rebinds ht_fp only on success. Returns Bool.

// HT.HC:149-163 — HtDrawIt head: uniform refresh then the block loop
U0 HtDrawIt(CTask *task,CDC *dc)
{//dc aliases gr.dc2; raw body pokes are ABSOLUTE screen coords.
  I64 bx,by,i,j,sx0,sy,stride=dc->width_internal;
  I64 vw=task->pix_width,vh=HT_VIEW_H;
  I64 nbx=vw/HT_SCALE,nby=vh/HT_SCALE;
  U8 c,*p;
  if (vh>task->pix_height)
    vh=task->pix_height;
  ht_u.i_time=tS;
  ht_u.i_frame++;
  ...
  if (ht_fp) {
    for (by=0;by<nby;by++) {   // <-- the shading loop to time (step 2)
  ...
  HtDrawPane(task,dc);

// HT.HC:186-218 — HtSelfTest: prints "HT SWAP OK", "HT IDENT OK",
// "HT ERRSURVIVE OK", "HT RECOVER OK" markers, then parks on ht_bad
// (error-state demo). tools/test.sh proof 6 greps two of these markers.

// HT.HC:220+ HtInteract: GUI GetKey loop; SC_F1/SC_F2/SC_F5 in a switch —
// the place to add SC_F3.

// HT.HC:265-273 — startup (top-level statements at end of file)
Bool ht_gui=FileFind("E:/GUI.TXT");
StrCpy(ht_src,ht_src1);
HtStatus(FALSE,"READY  sample 1 (built-in)");
ht_fp=&MainImage;
Fs->draw_it=&HtDrawIt;
if (ht_gui)
  HtInteract;
else
  HtSelfTest;
```

`tools/mkxfer.sh` tail (the copy block to extend):

```bash
mcopy -o "$ROOT/guest/ONCE.HC" x:/ONCE.HC
mcopy -o "$ROOT/guest/RUN.HC" x:/RUN.HC
if [ -n "$SRC" ]; then
    mcopy -o "$SRC" x:/MAIN.HC
fi
# GUI marker: tells RUN.HC to leave the guest running instead of rebooting.
if [ -n "${HOLYTOY_GUI:-}" ]; then
    echo gui | mcopy -o - x:/GUI.TXT
fi
```

**VM-verified facts this plan builds on** (probe run `verify-006-Z25s4L`,
2026-07-12, commit `e91b74a` — a probe source defined
`class CHtUniforms` + a global + a helper function, then `ExePutS2`'d a
buffer redefining all three, twice, then `FileWrite` + `ExePutS2` of an
`#include "E:/..."` source):

1. `PROBE REDEF OK` / `PROBE REDEF2 OK` — HolyC re-JITs a class, global,
   and function redefinition through `ExePutS2` without error, repeatedly
   (hash-table symbol layering). **Therefore `--runner none` output is
   injectable verbatim through `HtRecompile` — no transpiler changes.**
2. `PROBE INC OK` — JIT-compiling source containing
   `#include "E:/FILE.HC"` works when the file exists on the mounted
   transfer disk at lex time. `E:/MAIN.HC` is itself lexed after `E:` is
   mounted (guest/RUN.HC runs `ExeFile2("E:/MAIN.HC")`), so a top-level
   `#include "E:/HTMATH.HC"` in HT.HC uses the identical mechanism.
3. `FileRead` NUL-terminates its buffer:
   vendor/TempleOS/Kernel/BlkDev/FileSysFAT.HC `FAT32FileRead` does
   `buf[de.size]=0; //Terminate` — safe to hand straight to `HtRecompile`.

**Mouse facts** (from vendor source — cite these in code comments):

- vendor/TempleOS/Kernel/SerialDev/Mouse.HC `MsHardHndlr`: raw PS/2 deltas
  accumulate 1:1 into `ms_hard.prescale`; `MsHardSetPost` computes
  `pos = prescale * ms_hard.scale * ms_grid.speed` and, whenever the
  position would leave the screen, adjusts `ms.offset` to pin it at the
  edge (with `ms_grid`=8 granularity). So slamming the cursor far into a
  corner re-anchors it there, and subsequent relative counts map to pixels
  deterministically.
- vendor/TempleOS/HomeLocalize.HC:11-12 sets `ms_hard.scale.x/y = 0.5` and
  runs at every boot (via MakeHome) — **the stock golden image moves 1
  pixel per 2 raw counts**. `ms.scale=1.0`, `ms_grid.x_speed=1`,
  grid snap off (defaults).
- Consequence: `mouse-to X Y` = slam ≥2000 counts up-left (covers 640 px ×
  2 counts from anywhere), then move `2*X, 2*Y` counts. Landing error is
  bounded by the grid-8 re-anchor + rounding: assert with **±16 px
  tolerance**.
- QEMU 11.0.1 QMP `input-send-event` takes
  `{"type":"rel","data":{"axis":"x","value":N}}` and
  `{"type":"btn","data":{"down":true,"button":"left"}}`. The emulated PS/2
  mouse clamps per-packet deltas and has a bounded queue — send rel moves
  in **chunks of ≤120 counts per axis with `KEY_DELAY` sleeps between**,
  never one giant event.

Harness facts for verification commands:

- Each run prints `RUN_DIR=/abs/path` first. Reserve your own:
  `RD="$(mktemp -d "$PWD/out/runs/verify-006-XXXXXX")"; RUN_DIR="$RD" tools/run.sh FILE`
  (must be a new/empty direct child of `out/runs/`; one run per directory —
  take a fresh `$RD` each time).
- Exit codes: 0 guest OK, 1 guest compile/runtime error (message in that
  run's `guest.log`), 2 harness failure.
- `$RD/screen.txt` is exact OCR of the final screenshot;
  `python3 tools/scrtext.py PNG [--grep STR]` OCRs any frame (exit 0 iff
  the string is on screen — use it to gate mid-run injection on
  `$RD/frames/last-good.png`, which is always a complete PNG; `cur.png`
  can be mid-write).
- ASCII only in anything sent to the guest; transfer-disk filenames are
  single-dot UPPERCASE 8.3 (`SHADER.HC`, `HTMATH.HC` are valid).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Transpiler unit tests (no VM) | `python3 tools/test_glsl2hc.py` | `OK`, 50 tests, exit 0 |
| Transpile for the app | `python3 tools/glsl2hc.py tests/glsl/plasma.glsl --runner none -o "$RD/shader.HC"` | exit 0 |
| One VM cycle (~20-30 s) | fresh `$RD`; `RUN_DIR="$RD" tools/run.sh SRC` | exit 0, artifacts in `$RD` |
| Screen OCR | `python3 tools/scrtext.py "$RD/latest.png" --grep 'STR'` | exit 0 iff STR on screen |
| Screenshot facts | `python3 tools/imginfo.py "$RD/latest.png"` | `640 480 N` |
| Inspect transfer disk | `MTOOLSRC="$RD/mtools.conf" mdir x:/` | file listing |
| Full proof suite | `make test` | `-- 9 passed, 0 failed --` (after step 7) |
| Shell syntax check | `bash -n tools/test.sh` (etc.) | exit 0, silent |

## Suggested executor toolkit

- Read `skills/holyc/SKILL.md` before writing any HolyC: no `float` (use
  `F64`), `"%d ms\n",x;` print-statement idiom (no `%f` anywhere in this
  repo's guest code — format ms as integer), pure ASCII sources.
- Answer HolyC/TempleOS behavior questions from `vendor/TempleOS` source
  (strip DolDoc codes first: `python3 skills/holyc/scripts/strip_doldoc.py FILE`),
  never from memory.
- `src/bench-math.HC:150-196` (`BmFx16Frame*`) is the working fixed-point
  plasma idiom to adapt for the new F3 sample shader.

## Scope

**In scope** (the only files you may create or modify):

- `src/holytoy/HT.HC` — HTMATH include/init, ms/frame readout, F3 sample,
  `E:/SHADER.HC` load path, new self-test markers, `HT_SRC_MAX` bump
- `tools/mkxfer.sh` — copy `HTMATH.HC` always; `SHADER.HC` when
  `HOLYTOY_SHADER` is set
- `tools/run-common.sh` — new `holy_prepare_glsl` helper
- `tools/run.sh`, `tools/gui.sh` — `.glsl` source branch (calls the helper)
- `tools/qmp.py` — `mouse-rel`, `mouse-btn`, `mouse-to` verbs
- `tests/mouse-probe.HC` — new guest-side mouse probe
- `tools/test.sh` — extend proof 6; add proofs 7 (glsl-static), 8
  (glsl-app), 9 (mouse); unit-test preflight
- Docs: `README.md`, `AGENTS.md`, `docs/notes/glsl2hc.md`,
  `docs/notes/step1-skeleton.md`, `plans/README.md`

**Out of scope** (do NOT touch, even though they look related):

- `tools/glsl2hc.py`, `tools/test_glsl2hc.py` — the probe proved verbatim
  injection works; if emitted code fails in the app, that's a STOP, not a
  license to patch the emitter.
- `src/holytoy/HTMATH.HC`, `src/bench-math.HC` — consumed, not modified
  (modifying HTMATH triggers the accuracy-gate rerun; avoid).
- `guest/RUN.HC`, `guest/ONCE.HC` — no protocol change (ONCE.HC changes
  would require golden-image surgery).
- The `CHtUniforms` ABI — frozen (see tradeoffs).
- `tests/glsl/*.glsl` fixtures — used as-is.
- `skills/`, `vendor/` — maintained by a parallel agent session.
- The in-guest transpiler port — that is plan 007.

## Git workflow

- Branch: `advisor/006-glsl-app-integration`
- Commit per step, short imperative sentence (match `git log`, e.g.
  "Add glsl2hc coverage notes; mark plan 004 done").
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: mkxfer.sh — ship HTMATH.HC always, SHADER.HC on request

After the `MAIN.HC` copy block in `tools/mkxfer.sh`, add (imitating the
`HOLYTOY_GUI` pattern already there):

```bash
mcopy -o "$ROOT/src/holytoy/HTMATH.HC" x:/HTMATH.HC
# Transpiled shader for the app: HT.HC compiles it at startup when present.
if [ -n "${HOLYTOY_SHADER:-}" ]; then
    mcopy -o "$HOLYTOY_SHADER" x:/SHADER.HC
fi
```

The unconditional `HTMATH.HC` copy keeps every source runnable — HT.HC's
new `#include` (step 2) must find it regardless of how the disk was built.
`run.sh` and `gui.sh` export nothing new; `HOLYTOY_SHADER` flows through
the environment like `HOLYTOY_GUI` does from `gui.sh`.

**Verify**:
`bash -n tools/mkxfer.sh` → silent. Then
`tools/mkxfer.sh /tmp/x.img src/gradient.HC && MTOOLSRC=/tmp/mtools.conf mdir x:/`
→ listing shows `HTMATH.HC` and no `SHADER.HC`; repeat with
`HOLYTOY_SHADER=src/gradient.HC tools/mkxfer.sh /tmp/x.img src/gradient.HC`
→ listing shows `SHADER.HC`. (`mkxfer.sh` writes `mtools.conf` next to the
image.) Remove `/tmp/x.img /tmp/mtools.conf` afterwards.

### Step 2: HT.HC — adopt HTMATH, add the ms/frame readout and the F3 fixed-point sample

All in `src/holytoy/HT.HC` (pure ASCII throughout):

1. Top of file, after the header comment:
   `#include "E:/HTMATH.HC"` — and call `HTMInit;` in the startup block
   (before `Fs->draw_it=&HtDrawIt;`). Table build is once-at-startup per
   HTMATH.HC's own doc.
2. Readout: add globals `F64 ht_t0; I64 ht_shade_ms;`. In `HtDrawIt`,
   bracket ONLY the shading block loop (`if (ht_fp) { for (by=... } }`):
   `ht_t0=tS;` before, `ht_shade_ms=ToI64((tS-ht_t0)*1000.0);` after.
   This times the shader work itself, not the winmgr's ~30 fps frame
   cadence — the distinction docs/notes/perf-floor.md draws (its bench
   avoided `draw_it` because *whole-frame* timing there measures the
   winmgr; timing the inner loop does not have that problem).
   Display it in the pane header by changing the `GrPrint` at HT.HC:77 to:
   `GrPrint(dc,0,HT_PANE_ROW*8," HolyToy %3dms  F5 recompile  F1-F3 samples  ESC exit",ht_shade_ms);`
   (integer ms; the OCR regex in step 7 keys on `ms  F5`).
3. F3 sample: add `ht_src3` — a fixed-point plasma `MainImage` (as a
   string, like `ht_src1`/`ht_src2`) that calls `HTMSin16`/`HTMCos16`
   with 16.16 turn angles; adapt the formula from
   `src/bench-math.HC:150-168` (`BmFx16Frame`), deriving the time angle
   from `u->i_time` (e.g. `I64 t16=ToI64(u->i_time*0x3000);` — any
   constant giving visible motion is fine) and mapping the sum of four
   sines (each in ±0x10000) to a 0-15 color. It compiles via
   `HtRecompile`, so it may reference `HTMSin16` — the enclosing task
   already JIT-ed it (probe fact 1/2). Wire `SC_F3` into `HtInteract`'s
   switch: `case SC_F3: HtRecompile(ht_src3); break;`.
4. Self-test additions in `HtSelfTest`, after the existing four checks and
   BEFORE the final `HtRecompile(ht_bad)` park: print `HT MATH OK` if
   `HTMSin16(0x4000)==0x10000 && HTMCos16(0)==0x10000 &&
   HTMSin16(0x8000)==0` and `HtRecompile(ht_src3)` returns TRUE — else
   `HT MATH FAIL`. (Quarter-turn sin, zero cos, half-turn sin: exact table
   entries, deterministic.)

**Verify**: fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC` →
exit 0; `grep -c "OK" "$RD/guest.log"` covers: `HT SWAP OK`, `HT IDENT OK`,
`HT ERRSURVIVE OK`, `HT RECOVER OK`, `HT MATH OK` all present
(`grep "HT MATH OK" "$RD/guest.log"`); and
`grep -E "HolyToy +[0-9]+ms" "$RD/screen.txt"` → one line (the readout
renders and OCRs).

### Step 3: HT.HC — compile `E:/SHADER.HC` at startup; raise HT_SRC_MAX

1. `#define HT_SRC_MAX 8192` (transpiled shaders start at ~2 KB; 4096
   leaves too little headroom; `ht_src` is a static global — 8 KB is
   free at 512 MB RAM).
2. Add, near `HtSelfTest`:

```holyc
Bool HtLoadShader()
{//Compile a host-transpiled shader off the transfer disk, if present.
 //FileRead NUL-terminates (Kernel/BlkDev/FileSysFAT.HC FAT32FileRead).
  U8 *buf;
  I64 sz;
  Bool ok=FALSE;
  if (!FileFind("E:/SHADER.HC"))
    return FALSE;
  buf=FileRead("E:/SHADER.HC",&sz);
  if (buf) {
    ok=HtRecompile(buf);
    Free(buf);
  }
  if (ok)
    "HT GLSL OK\n";
  else
    "HT GLSL FAIL\n";
  return TRUE;
}
```

   Note `HtRecompile` already handles the too-long case with a status
   message and FALSE — that surfaces as `HT GLSL FAIL`.
3. Rework the startup block: after installing `draw_it`, call
   `Bool ht_had_shader=HtLoadShader();` then:
   - GUI (`ht_gui`): proceed to `HtInteract` as today (the shader, if any,
     is already live in the viewport and pane).
   - Headless with a shader: **skip `HtSelfTest`** and instead
     `Sleep(3000);` so the rolling screendumps capture ≥4 frames of the
     animating GLSL shader, then return (RUN.HC holds and reboots). The
     recompile-robustness markers stay the no-shader run's job — the two
     headless modes must not contaminate each other's markers.
   - Headless without a shader: `HtSelfTest` exactly as today.

**Verify** (round-trip): fresh `$RD`;
`python3 tools/glsl2hc.py tests/glsl/plasma.glsl --runner none -o /tmp/shader006.HC`
→ exit 0; then
`HOLYTOY_SHADER=/tmp/shader006.HC RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC`
→ exit 0, `grep "HT GLSL OK" "$RD/guest.log"` matches, no `HT SWAP`
markers in the log, and the trailing frames differ:
`md5sum "$RD"/frames/frame-*.png | awk '{print $1}' | tail -6 | sort -u | wc -l` ≥ 3.
Also confirm the failure path: transpile `tests/glsl/gradient.glsl` the
same way but corrupt it first
(`printf 'U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color) {*out_color=;}\n' > /tmp/bad006.HC`),
run with `HOLYTOY_SHADER=/tmp/bad006.HC` → run exits 0 (the app survives),
`HT GLSL FAIL` in `guest.log`, and `screen.txt` contains `COMPILE ERR`.

### Step 4: `.glsl` sources for run.sh and gui.sh

Add to `tools/run-common.sh`:

```bash
# If SRC is a .glsl file, transpile it into RUN_DIR and retarget the run at
# the HolyToy app with the result as its shader. Requires RUN_DIR allocated.
# On transpile failure prints the diagnostic and returns 1 (user source
# error, mirroring guest compile errors).
holy_prepare_glsl() {
    case "$SRC" in
        *.glsl) ;;
        *) return 0 ;;
    esac
    if ! python3 "$ROOT/tools/glsl2hc.py" "$SRC" --runner none \
            -o "$RUN_DIR/shader.HC"; then
        echo "run: GLSL transpile failed for $SRC" >&2
        return 1
    fi
    export HOLYTOY_SHADER="$RUN_DIR/shader.HC"
    SRC="$ROOT/src/holytoy/HT.HC"
}
```

In `tools/run.sh`, after `holy_allocate_run_dir` and the `RUN_DIR=` echo
(i.e. just before the `mkxfer.sh` call), insert:

```bash
holy_prepare_glsl || exit 1
```

Same insertion point in `tools/gui.sh` (after its `RUN_DIR=` echo, before
its `mkxfer.sh` call). `watch.sh` needs nothing — it re-invokes `run.sh`.
The retained `$RUN_DIR/shader.HC` doubles as a debugging artifact.

**Verify**:
- fresh `$RD`; `RUN_DIR="$RD" tools/run.sh tests/glsl/plasma.glsl` →
  exit 0, `HT GLSL OK` in `$RD/guest.log`, `$RD/shader.HC` exists.
- `printf 'void mainImage(out vec4 f, in vec2 c) { f = texture2D(x); }\n' > /tmp/bad006.glsl`;
  fresh `$RD`; `RUN_DIR="$RD" tools/run.sh /tmp/bad006.glsl` → exit 1 with
  a `file:line:` diagnostic on stderr and **no VM boot** (fails before
  QEMU; the run takes <5 s).
- `make run SRC=tests/glsl/circle.glsl` → exit 0 (Makefile passes SRC
  through unchanged — no Makefile edit needed).

### Step 5: qmp.py — mouse verbs

Extend `tools/qmp.py` (docstring usage block too):

```
  qmp.py SOCKET mouse-rel DX DY             # relative move, raw PS/2 counts
  qmp.py SOCKET mouse-btn left|right down|up
  qmp.py SOCKET mouse-to X Y                # slam to top-left, land on pixel
```

Implementation notes:
- `mouse_rel(dx, dy)` method on `QMP`: loop chunks of ≤120 counts per
  axis per `input-send-event` call (both axes in one event list), with
  `time.sleep(KEY_DELAY)` between calls — bounded PS/2 queue (Current
  state, mouse facts).
- `mouse_btn(button, down)`:
  `self.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": button}}])`.
- `mouse-to X Y`: `mouse_rel(-2000, -2000)` (pins the cursor at the
  top-left; TempleOS re-anchors `ms.offset` at screen edges —
  Kernel/SerialDev/Mouse.HC `MsHardSetPost`), `time.sleep(0.3)`, then
  `mouse_rel(round(CPP*X), round(CPP*Y))` where
  `CPP = float(os.environ.get("QMP_MOUSE_COUNTS_PER_PX", "2"))` — 2
  because the stock golden image boots `ms_hard.scale=0.5`
  (vendor HomeLocalize.HC:11-12). Put that rationale in a comment.
- Landing accuracy is ±16 px (grid-8 edge re-anchor + rounding); callers
  assert with tolerance, `mouse-to` itself makes no claims.

**Verify**: `python3 -c "import ast; ast.parse(open('tools/qmp.py').read())"`
→ silent; `python3 tools/qmp.py 2>&1 | grep mouse-to` → usage line.
(Live verification is step 6.)

### Step 6: tests/mouse-probe.HC — guest probe, plus a live injection check

Create `tests/mouse-probe.HC` (ASCII; model the marker style on
`HtSelfTest`):

- Print `"MOUSE READY\n";` (renders on the fullscreen task doc → visible
  to `scrtext.py` in the rolling frames).
- Sample for ~15 s: 50 iterations of `Sleep(300)`, each reading
  `ms.pos.x`, `ms.pos.y`, `ms.lb`; latch `Bool lb_seen|=ms.lb;`.
- Finish with `"MOUSE FINAL %d %d %d\n",ms.pos.x,ms.pos.y,lb_seen;`.

Then verify the whole mouse path manually (this is the pattern proof 9
automates):

```bash
RD="$(mktemp -d "$PWD/out/runs/verify-006-XXXXXX")"
RUN_DIR="$RD" tools/run.sh tests/mouse-probe.HC &
RUNPID=$!
for i in $(seq 1 60); do
    python3 tools/scrtext.py "$RD/frames/last-good.png" --grep "MOUSE READY" 2>/dev/null && break
    sleep 1
done
python3 tools/qmp.py "$RD/qmp.sock" mouse-to 400 300
sleep 0.5
python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left down
sleep 0.7
python3 tools/qmp.py "$RD/qmp.sock" mouse-btn left up
wait "$RUNPID"   # expect exit 0
grep "MOUSE FINAL" "$RD/guest.log"
```

**Verify**: `MOUSE FINAL X Y 1` with `|X-400| <= 16` and `|Y-300| <= 16`.
The QMP socket is shared with run.sh's screendump loop — each qmp.py call
is a short-lived connection, so collisions just delay; if a qmp.py call
fails, retry it once before investigating.

### Step 7: test.sh — extend proof 6, add proofs 7-9, unit-test preflight

In `tools/test.sh` (update the header comment to list nine proofs):

- **Preflight** (next to the existing `tools/test-run-locks.sh` gate, no
  VM cost): `python3 tools/test_glsl2hc.py >/dev/null 2>&1 || exit 2` —
  with a stderr message on failure, matching the MAX_RUNS gate style.
- **Proof 6 (holytoy)** — extend the existing grep chain with
  `grep -q "HT MATH OK" "$RD/guest.log"` and
  `grep -qE "HolyToy +[0-9]+ms" "$RD/screen.txt"`.
- **Proof 7 (glsl-static)**: transpile `tests/glsl/gradient.glsl` with
  `--runner static` to a mktemp .HC (clean it up via the existing
  `cleanup_sources` trap), run it; pass iff exit 0 and
  `tools/imginfo.py` on that run's `latest.png` reports `640 480 N` with
  N ≥ 8 (16-step grayscale ramp). This covers the standalone runner mode;
  circle.glsl stays manual-only (redundant coverage, one VM cycle saved).
- **Proof 8 (glsl-app)**: `tools/run.sh tests/glsl/plasma.glsl` (the step-4
  path end to end); pass iff exit 0, `HT GLSL OK` in `guest.log`, and ≥3
  distinct trailing frames (copy the md5 idiom from proof 4/6).
- **Proof 9 (mouse)**: automate step 6's sequence verbatim (background
  run + READY poll with 60 s bound + inject + wait); pass iff run exit 0,
  `MOUSE FINAL X Y 1` parsed from `guest.log`, `|X-400|<=16`,
  `|Y-300|<=16`. If the READY poll times out, fail the proof with the
  run dir in the message (don't hang: `wait` the pid regardless).

**Verify**: `bash -n tools/test.sh` → silent; `make test` →
`-- 9 passed, 0 failed --`. Run `make test` twice; both green (guards
against timing flakes in proofs 8-9).

### Step 8: documentation sync

- `README.md` — **maintainer rule: the README is a pure product
  description. It must never mention plans, plan numbers, VISION steps,
  progress, or any internal process.** Only two edits are allowed here:
  (a) keep the "Proven by `make test`" list factually true (describe the
  new proofs in the same plain style as the existing five — what is
  proven, not when or why it was added), and (b) one Quickstart line:
  `make run SRC=tests/glsl/plasma.glsl   # a Shadertoy-style GLSL shader, live in the app`.
  Nothing else. If you feel the urge to explain, put it in AGENTS.md or
  docs/notes/ instead.
- `AGENTS.md`: `make test` line ("the five proofs" → "the nine proofs");
  document `HOLYTOY_SHADER`, the `.glsl` SRC support, and the three new
  qmp.py verbs (with the counts-per-pixel caveat) in the appropriate
  sections.
- `docs/notes/glsl2hc.md`: rewrite the "Harness integration status"
  section — fixtures now covered by `make test` (which ones, which
  runner), `--runner none` consumed by HT.HC via `E:/SHADER.HC`.
- `docs/notes/step1-skeleton.md`: in "What step 1 still lacks", mark the
  HTMATH/ms-readout and mouse-injection items as landed by plan 006
  (leave real editing and inline error text as open follow-ups).
- `plans/README.md`: set plan 006's status row; move the mouse-injection
  entry out of "Findings considered and deferred/rejected" (it landed
  here); note plan 007 (in-guest transpiler port) as the successor.

**Verify**: `grep -rn "five" README.md AGENTS.md` → no stale proof-count
references; `git status` shows only in-scope files modified.

## Test plan

- Host-only: transpiler unit suite unchanged and green
  (`python3 tools/test_glsl2hc.py`, 50 tests) — now enforced by the
  test.sh preflight. `bash -n` on every touched script.
- VM proofs (all via `make test`): extended proof 6 (HTMATH + readout),
  proof 7 (static-runner gradient), proof 8 (GLSL app round-trip,
  animating), proof 9 (mouse landing + button). Model marker greps on the
  existing proof-6 block; model background-run handling on proof 5
  (parallel) which already backgrounds run.sh and `wait`s pids.
- Manual (not in make test, do once): step 3's corrupt-shader run
  (app survives, `HT GLSL FAIL`), step 4's transpile-error `.glsl`
  (exit 1, no VM boot), `make run SRC=tests/glsl/circle.glsl`.
- Verification: `make test` → `-- 9 passed, 0 failed --`, twice in a row.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `make test` exits 0 printing `-- 9 passed, 0 failed --`, on two
      consecutive runs
- [ ] `python3 tools/test_glsl2hc.py` exits 0 (50 tests, unchanged)
- [ ] fresh `$RD`; `RUN_DIR="$RD" tools/run.sh tests/glsl/plasma.glsl`
      exits 0 with `HT GLSL OK` in `$RD/guest.log` and ≥3 distinct
      trailing frames
- [ ] fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC` exits 0
      with `HT MATH OK` in `$RD/guest.log` and `HolyToy +[0-9]+ms`
      (regex) in `$RD/screen.txt`
- [ ] `git diff e91b74a..HEAD --stat -- tools/glsl2hc.py tools/test_glsl2hc.py src/holytoy/HTMATH.HC guest/ src/bench-math.HC tests/glsl/` → empty
- [ ] `LC_ALL=C grep -P '[^\x00-\x7F]' src/holytoy/HT.HC tests/mouse-probe.HC` → no output
- [ ] `git status` shows nothing modified outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The top-level `#include "E:/HTMATH.HC"` fails to compile in the app run
  even though the probe's runtime-`ExePutS2` include worked — report the
  compiler message from `guest.log`; the lex-time/run-time include
  distinction would then matter and the fallback (host-side concatenation
  in mkxfer.sh) is a design change the maintainer should approve.
- `HT GLSL FAIL` with a compiler message when injecting an unmodified
  `--runner none` fixture — the emitter produces something the app's task
  context rejects. `tools/glsl2hc.py` is out of scope: report the emitted
  line and the compiler message; do not patch either side.
- Mouse landings are repeatedly (>2 of 5 attempts) off by more than 16 px
  or `lb_seen` stays 0 — the `ms_hard.scale=0.5` or PS/2-queue assumptions
  are wrong on this host; report the observed `MOUSE FINAL` values. Do not
  tune tolerances upward to pass.
- Proof 6's pre-existing markers (`HT SWAP OK`, `HT ERRSURVIVE OK`)
  disappear after your HT.HC edits — you broke the recompile path;
  bisect your change, and if two fix attempts fail, stop.
- Any proof needs `RUN_TIMEOUT` or slot-semaphore changes to pass —
  config/harness invariants are out of scope; report instead.

## Maintenance notes

- **Plan 007 (in-guest transpiler port) builds directly on this**: the
  port surface listed in docs/notes/glsl2hc.md ("Emitted preamble = the
  in-guest port surface") plus this plan's `HtLoadShader`/`HtRecompile`
  path is exactly where the ported transpiler slots in (GLSL text in
  `ht_src` → transpile in-guest → `ExePutS2`). Keep `HtLoadShader` small
  and single-purpose so 007 can retarget it.
- The pane shows the injected **HolyC**, not the GLSL source — deliberate
  for v0 (the pane shows what was compiled). Plan 007 flips the pane to
  GLSL; don't "fix" it here.
- `QMP_MOUSE_COUNTS_PER_PX=2` encodes the golden image's
  `ms_hard.scale=0.5`. If `make golden` ever changes HomeLocalize (or KVM
  timing changes packet batching), proof 9's tolerance is the canary.
- Reviewer should scrutinize: no `tools/glsl2hc.py` diff; HT.HC additions
  are ASCII; proof 9 cannot hang (`wait` always reached, READY poll
  bounded); `HOLYTOY_SHADER` documented in AGENTS.md.
- Explicitly deferred: iMouse buttons/click state in the ABI (needs the
  frozen-ABI change → plan 007), fixed-point `Sqrt` LUT (perf-floor
  Decision 4 — pairs naturally with 007's fixed-point emission), GLSL
  shown in the pane, palette-fitting color quantization (VISION step 4).
- **Maintainer direction (2026-07-12), for whoever plans 007**: the v1
  input box takes ONLY GLSL — the HolyC `MainImage` dialect (F1-F3
  samples) is dev scaffolding, not a product mode. Compatibility target:
  most Shadertoy fragment shaders (no textures; simplifications where the
  16-color output demands). Color quantization should move to **Bayer
  ordered dithering** (deterministic threshold matrix — not the random
  `ROPF_PROBABILITY_DITHER`); nothing in the repo implements it yet.
