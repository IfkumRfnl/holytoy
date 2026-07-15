# Plan 010: Adaptive render scale, visual-correctness oracle, Shadertoy corpus v2

> **Executor instructions**: Follow this plan stage by stage. Run every
> verification command and record actual evidence (run directory names,
> table output, marker lines). Corpus numbers come only from the in-guest
> compiler through the batch harness; visual-correctness numbers come only
> from comparing in-guest sample dumps against the reference files this plan
> creates. Never hand-edit a corpus shader and never count a host-side
> result as guest compatibility. If anything in "STOP conditions" occurs,
> stop and report — do not improvise. When done, update the 010 row in
> `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat a214703..HEAD -- src/holytoy/ tools/ tests/ guest/ corpus/ config.sh Makefile AGENTS.md`
> If any in-scope file changed since `a214703`, compare the "Current state"
> excerpts below against the live code before proceeding; on a mismatch,
> treat it as a STOP condition. `corpus/shadertoy/v1/` must show zero diff.

## Status

- **Priority**: P1
- **Effort**: XL (three stages: M + L + L)
- **Risk**: MED (Stage A touches the hot render loop and proof determinism;
  Stage B depends on obtaining a host GL context; Stage C is curation-heavy)
- **Depends on**: plans/009-glsl-e2e-corpus-v1.md (DONE at `3e75c6a`)
- **Category**: direction
- **Planned at**: commit `a214703`, 2026-07-15
- **Execution status**: TODO

## Why this matters

Plan 009 got corpus v1 to 20/20 compile/install/exec, but three honesty gaps
remain, and they are exactly the next three reporting lines AGENTS.md
demands ("How progress is judged", AGENTS.md:64-78):

1. **Performance**: heavy 3D shaders shade one 4x4-block frame in 2.6–23 s
   under TCG (plan 009 evidence, e.g. Wtj3Wc at 22.8 s/frame), which
   overruns the 90 s run cycle — visual spot-checks of exactly the shaders
   that most need checking are impractical. AGENTS.md:22-24 already licenses
   the fix: "expensive shaders may render at an adaptive lower resolution,
   but lowering resolution must not change their language semantics."
2. **Visual correctness** is currently three eyeballed screenshots. The
   staged corpus table's contract says "extend it with `visual` once a
   reference-image pipeline exists" (plans/009, Maintenance notes). Without
   a numeric oracle, a semantically wrong-but-finite shader counts as 100%.
3. **Corpus size**: 20 shaders cannot support the ~99% target
   (AGENTS.md:18-21, "a large, versioned corpus"). v2 must grow the
   measured denominator, including an honestly-failing texture-channel
   stratum so missing features are corpus-measured instead of invisible.

After this plan: any corpus shader renders live at an automatically chosen
scale within the normal run cycle; `tools/corpus_run.sh` reports a per-shader
visual-error table against committed reference samples; and the corpus is
versioned v2 at ~50 shaders across two strata with staged + visual numbers
recorded for all of them.

## Current state

Read these files fully before editing them. Roles:

- `src/holytoy/HT.HC` (610 lines) — app: uniforms ABI, editor loop,
  `HtDrawIt` render loop, `HtSelfTest`, `HtCorpusRun` batch mode.
- `src/holytoy/HTRENDER.HC` (73 lines) — palette LUT + 4x4 Bayer
  (`HtQuantize`, `HTRInit`). Frozen ABI; do not change its semantics.
- `src/holytoy/HTCOMP.HC` — `CHtCompileResult`/`HtCompileGlsl` compiler
  entry; `HtInstallHoly`/`HtCompileAndSwapGlsl` in HT.HC install shaders.
- `tools/run.sh`, `tools/run-common.sh`, `tools/mkxfer.sh` — one-VM run
  cycle; env hooks ship extra files onto the FAT32 transfer disk.
- `tools/corpus_run.sh` — prep + one-boot batch + report;
  `tools/glsl_prep.py` — guest-safe ASCII copies (has `--corpus`/`--dest`);
  `tools/corpus_report.py` — parses `HT CORPUS` markers into the staged
  table (stages `compile|install|exec`, plus `read`).
- `tools/test.sh` — the twelve proofs; `tools/imginfo.py` (PNG size/colors/
  hash via ffmpeg), `tools/scrtext.py` (exact 8x8 glyph OCR).
- `corpus/shadertoy/v1/` — 20 shaders, byte-for-byte, frozen; `manifest.jsonl`
  schema documented in its README; `validate.py` checks layout/hashes/licenses.
- `config.sh` — all knobs (`RUN_TIMEOUT=90` default; corpus runs export more).
- `plans/009-glsl-e2e-corpus-v1.md` — prior art for staged corpus reporting
  and the recorded semantic deviations (F64 floats, masked uint, LUT trig).

### The render loop (HT.HC:20-25, 198-275)

`HT_SCALE` is a compile-time constant; the viewport shades once per
`HT_SCALE x HT_SCALE` block and pokes `dc->body` directly:

```holyc
#define HT_VIEW_H	288	//viewport: full width x 288 window pixels (~60%)
#define HT_SCALE	4	//shade once per 4x4 block (VISION.md render scale)
...
U0 HtDrawIt(CTask *task,CDC *dc)
{
  I64 bx,by,i,j,sx0,sy,stride=dc->width_internal,r88,g88,b88;
  ...
  I64 nbx=vw/HT_SCALE,nby=vh/HT_SCALE;
  U8 *p,q[16];
  ...
        ht_fp(&ht_u,bx*HT_SCALE+HT_SCALE*0.5,
              vh-(by*HT_SCALE+HT_SCALE*0.5),&fc);
  ...
  ht_shade_ms=ToI64((tS-ht_t0)*1000.0);
```

Uniform fields set per frame in `HtDrawIt`: `i_time=tS`, `i_frame++`,
`res_x=vw` (the FULL 640, independent of block size), `res_y=vh`, mouse and
date fields. The inline quantize path computes a Bayer offset per pixel from
absolute screen coords (`htr_bofs[((sy&3)*4)+((sx0+j)&3)]`), so it is already
correct for any block size; only the loop bounds and the `q[16]` buffer
assume 4.

The pane header (HT.HC:98-99) is OCR'd by proof 6 with
`grep -qE "HolyToy +[^ ]+ms" "$RD/screen.txt"`:

```holyc
  GrPrint(dc,0,HT_PANE_ROW*FONT_HEIGHT,
          " HolyToy %3dms  F5 compile  F1-F2 samples  ESC exit",ht_shade_ms);
```

### Corpus batch mode (HT.HC:359-440, 590-608)

`HtCorpusRun` runs with **no draw_it installed** (HT.HC:591-595), sets
`ht_u.i_time=0.5; ht_u.res_x=640; ht_u.res_y=288;`, and per shader prints
`HT CORPUS <id> <stage> OK|ERR <msg>` for stages compile/install/exec, where
exec calls `ht_fp` at 4 sample pixels and checks finiteness via `HtFinite`.
The manifest parser (HT.HC:379-388) reads `name` up to a space, then reads
**everything to end-of-line into `id`** — it must learn to stop `id` at a
space before CORPUS.TXT lines gain a third field:

```holyc
    while (*p==' ') p++;
    i=0;
    while (*p && *p!='\n' && *p!='\r' && i<15) id[i++]=*p++;
    id[i]=0;
```

### Transfer-disk hooks (tools/mkxfer.sh:49-67)

```sh
if [ -n "${HOLYTOY_CORPUS_DIR:-}" ]; then
    ...
    mcopy -o "$HOLYTOY_CORPUS_DIR"/S*.GLS x:/
    mcopy -o "$HOLYTOY_CORPUS_DIR/CORPUS.TXT" x:/CORPUS.TXT
fi
if [ -n "${HOLYTOY_GUI:-}" ]; then
    echo gui | mcopy -o - x:/GUI.TXT
fi
```

`tools/run.sh` retains `xfer.img` + `mtools.conf` in every RUN_DIR; host-side
extraction after a run is `MTOOLSRC="$RD/mtools.conf" mcopy -n x:/FILE dest`.

### Proof determinism facts (tools/test.sh)

- Proof 6 (holytoy) greps guest markers `HT SWAP/ERRSURVIVE/MATH/DITHER OK`
  and the `HolyToy +[^ ]+ms` header; needs >=3 distinct trailing frames.
- Proof 9 (dither) requires the **same hash for the last two frames** of a
  static gradient (crop `0,8,640x288`) — any mid-run scale change breaks it.
- Proof 12 (editor) hashes the viewport before/after an edit.
- Proof 13 does not exist yet; the suite ends with
  `echo "-- $PASS passed, $FAIL failed --"` and the header comment says
  "Twelve round-trips".

### Host environment facts (verified 2026-07-15)

- WSL2, no `/dev/kvm` (TCG). `DISPLAY=:0` (WSLg works; `make gui` uses it).
- Image decoding everywhere is **ffmpeg** (`tools/scrtext.py:68-70` decodes
  PNG to raw rgb24). There is **no** PIL/numpy/moderngl/glslViewer/glslang
  installed, and no system libGL/libEGL; `/usr/lib/wsl/lib` has the WSLg GPU
  driver libs. `nix` 2.34.7 is at `~/.nix-profile/bin/nix` (qemu and mtools
  came from `nix profile add`). Python is 3.13.5.
- `ffmpeg` is at `/usr/bin/ffmpeg`.

### Guest-code rules that will bite (AGENTS.md:189-212 + skills/holyc)

ASCII only in anything shipped to the guest; transfer filenames single-dot
UPPERCASE 8.3; use `ExeFile2` to catch compile errors; HolyC has **no
`continue`** (use `goto`, see `corpus_next:` in `HtCorpusRun`), function
scope for locals, non-C precedence (parenthesize), postfix casts
(`ToI64(x)`), and large programs need extern forward declarations between
modules. Read `skills/holyc/` if unsure; answer HolyC questions from
`vendor/TempleOS` source, never memory.

### Corpus v1 provenance rules (corpus/shadertoy/v1/README.md)

Sources are pinned author-maintained snapshots — Reinder Nijhoff backup at
`reindernijhoff/shadertoy` commit `2def3ce132b4f5d9590e9eee0c17bd37a011835c`
(per-shader README license sections, CC BY-NC-SA 4.0) and `bean-mhm/shaders`
commit `6baf7720d28d4440e8ebdabf9b971c34a7356545` (repo-level AGPL-3.0).
"Public visibility alone was not treated as permission." Files are preserved
byte-for-byte; `manifest.jsonl` has one object per shader with license
evidence, provenance, coverage labels, and pass metadata (see the first line
of `corpus/shadertoy/v1/manifest.jsonl` for the exact schema); inspected
non-accepted candidates go to `rejected.jsonl`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full proof suite | `make test` | ends `-- 13 passed, 0 failed --` (12 today; this plan adds one) |
| One run cycle | `make run SRC=tests/glsl/gradient.glsl` | exit 0; first stdout line `RUN_DIR=...` |
| Corpus batch | `tools/corpus_run.sh` | staged table, `guest DONE` line |
| Corpus prep only | `python3 tools/glsl_prep.py --corpus <dir> --dest <dir>` | `glsl_prep: wrote N ...`; run twice → byte-identical |
| Corpus static validate | `python3 corpus/shadertoy/v2/validate.py` | exit 0, no FAIL lines |
| Shell syntax | `bash -n tools/run.sh tools/run-common.sh tools/mkxfer.sh tools/test.sh tools/corpus_run.sh` | silence, exit 0 |
| ASCII scan of guest code | `LC_ALL=C grep -rnP '[\x80-\xff]' src/holytoy guest tests/glsl && echo NONASCII || echo CLEAN` | `CLEAN` |
| OCR a screenshot | `python3 tools/scrtext.py RUN_DIR/latest.png --grep STRING` | exit 0 when present |
| Extract from a run's transfer disk | `MTOOLSRC=RUN_DIR/mtools.conf mcopy -n x:/V01A.DAT out/` | file appears |

Timing: a normal run is ~20 s; `make test` makes 13+ VM round-trips (~6-10
min); a corpus batch is minutes (export `CORPUS_TIMEOUT`, see Step B5).

## Scope

**In scope** (the only files you should create/modify):

- `src/holytoy/HT.HC` (adaptive scale, SCALE.TXT, visual dump, manifest
  parser third field)
- `tools/run.sh`, `tools/run-common.sh`, `tools/mkxfer.sh` (ship
  `SCALE.TXT`/`VISDUMP.TXT`; corpus DAT extraction stays in corpus_run.sh)
- `tools/corpus_run.sh`, `tools/corpus_report.py`, `tools/glsl_prep.py`
- `tools/glsl_ref.py` (new), `tools/visual_compare.py` (new)
- `tools/test.sh`, `tests/corpus-visual/**` (new: committed reference DATs),
  `tests/glsl/slow-loop.glsl` (new fixture)
- `corpus/shadertoy/v2/**` (new), `config.sh`, `Makefile` (only if a new
  convenience target is warranted), `AGENTS.md` (corpus/scale doc deltas),
  `docs/VISION.md` only if it contradicts landed behavior, `plans/README.md`
- `tools/test_corpus_compat.py` only if it hardcodes v1 paths that break

**Out of scope** (do NOT touch):

- `corpus/shadertoy/v1/**` — frozen forever; v2 is a sibling, not an edit.
- `src/holytoy/HTPP.HC HTLEX.HC HTPARSE.HC HTLOWER.HC HTEMIT.HC HTCOMP.HC
  HTLIB.HC HTMATH.HC` — the compiler itself, EXCEPT the bounded Stage C
  cluster fixes (Step C4), which must each be justified by a named corpus
  failure cluster. No speculative compiler work.
- `HTRENDER.HC` quantization semantics and the `CHtUniforms`/`CHtFragColor`
  ABI — frozen (plans/007). Adding *fields* is also out of scope here.
- Texture/channel **runtime support** — stratum B lands as measured-failing
  corpus entries only; implementing `texture()` is a later plan.
- `guest/ONCE.HC` and the golden image; `skills/holyc/`, `vendor/TempleOS`
  (parallel agent owns those trees).
- README.md — pure product pitch, no progress notes (repo rule).

## Git workflow

- Branch off `main`: `plan-010-scale-oracle-corpus2` (matches
  `plan-009-glsl-e2e`).
- Commit per stage or per coherent step; imperative summaries like the log
  (`Adopt RGBA shader ABI; add HTRENDER quantizer with Bayer dithering`).
- Do NOT push or merge; the maintainer merges when green (repo rule:
  merge-when-green is the maintainer's call after reviewing proofs).

## Steps

### Stage A — adaptive render scale (guest)

**Design (all of Stage A implements exactly this):** `HT_SCALE` becomes a
runtime variable `ht_scale` with legal values 1, 2, 4, 8, 16 (all divide
640 and 288 exactly). A controller in `HtDrawIt` adjusts it from measured
`ht_shade_ms` when in auto mode. `iResolution`, `fragCoord` math, and the
generated-shader ABI are untouched — a block still samples its center with
`res_x=640` — so language semantics never change (AGENTS.md:22-24). Corpus
batch exec sampling and the Stage B visual dumps evaluate `ht_fp` directly
on fixed grids and are **independent of `ht_scale` by construction**.

Controller (auto mode):
- Start every newly installed shader (and startup) at `ht_scale=16`; the
  first frame of an unknown shader must be cheap (a 23 s/frame-at-4 shader
  is ~1.4 s at 16).
- After each frame: if `ht_shade_ms > 250` for 2 consecutive frames and
  `ht_scale < 16`, coarsen one step (scale *= 2). If
  `ht_shade_ms * 4 < 150` for 4 consecutive frames and `ht_scale > 1`,
  refine one step (scale /= 2). The `*4` is the projected cost of the finer
  scale; 150 < 250 is the hysteresis gap that prevents oscillation.
- Reset the consecutive-frame counters on any scale change or shader swap.

Pinning: if `E:/SCALE.TXT` exists and contains `1|2|4|8|16`, lock that
scale (no controller); if it contains `auto` or is absent, auto mode.

#### Step A1: runtime scale in HtDrawIt

In `src/holytoy/HT.HC`: replace uses of `HT_SCALE` inside `HtDrawIt` with a
new global `I64 ht_scale=16;` plus `I64 ht_scale_lock=0;` (0 = auto, else
the locked value) and controller counters. Keep the `#define HT_SCALE 4`
only if something else still references it; otherwise delete it. Concretely:

- `q[16]` becomes `U8 q[256];` (16x16 worst case); loop bounds use
  `ht_scale`; the sample position becomes
  `ht_fp(&ht_u,bx*ht_scale+ht_scale*0.5,vh-(by*ht_scale+ht_scale*0.5),&fc);`.
- The comment "HT_SCALE=4 aligns with the Bayer tile" is no longer true for
  1/2; the per-pixel offset lookup already handles that — update the comment,
  not the math. The dither proof (proof 9, pinned at 4 — Step A4) plus
  `HT DITHER OK` remain the quantizer's regression net.
- Append the controller at the end of `HtDrawIt` right after
  `ht_shade_ms=...`, exactly per the design block above, gated on
  `!ht_scale_lock`.
- In `HtCompileAndSwapGlsl`, after a successful install in auto mode, reset
  `ht_scale=16` and the counters.
- Pane header: change to `" HolyToy %3dms 1:%-2d F5 compile  F1-F2 samples  ESC exit",ht_shade_ms,ht_scale`
  — it must still match `grep -qE "HolyToy +[^ ]+ms"` (proof 6) and fit 80
  columns.

**Verify**: `LC_ALL=C grep -rnP '[\x80-\xff]' src/holytoy && echo NONASCII || echo CLEAN` → `CLEAN`;
`make run SRC=src/holytoy/HT.HC` → exit 0 and the run's `screen.txt`
contains `HolyToy` and `1:` (`grep -E "HolyToy +[^ ]+ms 1:" RUN_DIR/screen.txt`).

#### Step A2: SCALE.TXT pinning + harness plumbing

- `src/holytoy/HT.HC` startup (near the `ht_gui=FileFind(...)` block): read
  optional `E:/SCALE.TXT`; parse `auto` → `ht_scale_lock=0, ht_scale=16`;
  digits 1/2/4/8/16 → `ht_scale_lock=N, ht_scale=N`; anything else →
  treat as auto (and print `HT SCALE BADPIN` once for debuggability).
- `tools/mkxfer.sh`: next to the `HOLYTOY_GUI` block, add: if
  `HOLYTOY_SCALE` is set, `echo "$HOLYTOY_SCALE" | mcopy -o - x:/SCALE.TXT`.
- `tools/test.sh`: export `HOLYTOY_SCALE=4` once near the top (after
  sourcing config.sh) so every existing proof renders exactly as today —
  proofs 9 and 12 hash frames and must not see scale changes; pinning the
  whole suite is the deterministic choice. The new scale check runs
  in-guest (Step A3), so the suite still exercises the controller.

**Verify**: `bash -n tools/mkxfer.sh tools/test.sh` → exit 0.
`HOLYTOY_SCALE=4 make run SRC=src/holytoy/HT.HC` → `screen.txt` shows `1:4`
and `guest.log` has no `HT SCALE BADPIN`.

#### Step A3: self-test coverage (`HT SCALE OK`) + slow fixture

- New fixture `tests/glsl/slow-loop.glsl` (ASCII, comment it as a
  deliberately expensive fixture): a `mainImage` that loops ~40000 iterations
  of `v = fract(sin(v*12.9898+float(i))*43758.5453);` and writes `vec4(v)`.
  Target: clearly >250 ms/frame at 1:16 under TCG so coarsening is forced;
  verify the number empirically and adjust the loop count if needed.
- In `HtSelfTest` (HT.HC), after the `HT DITHER` block: save
  `ht_scale_lock`, force auto (`ht_scale_lock=0`), compile the slow source
  via `HtCompileAndSwapGlsl` (embed it as a string literal `ht_glsl_slow`
  next to `ht_glsl1/2/bad` — keep it byte-identical to the fixture's body so
  the numbers agree), `Sleep` long enough for several frames (start with
  8000 ms), and require `ht_scale==16`. Then swap `ht_glsl1` (trivial),
  sleep again, and require `ht_scale<=4`. Print `HT SCALE OK` /
  `HT SCALE FAIL up=<n> down=<n>`. Restore the saved lock state and the
  default shader. Note draw_it only runs while the task is not blocked in
  compute — `Sleep` yields, so frames do accumulate.
- `tools/test.sh` proof 6: add `grep -q "HT SCALE OK" "$RD/guest.log"` to
  the existing conjunction (the run itself is unchanged — self-test drives
  auto mode internally regardless of the suite's `HOLYTOY_SCALE=4` pin,
  because the self-test overrides the lock and restores it).

**Verify**: `make run SRC=src/holytoy/HT.HC` → `grep "HT SCALE OK" RUN_DIR/guest.log`
prints the marker. If it flakes (TCG timing), widen the sleeps or the loop
count — two attempts, then STOP.

#### Step A4: the payoff run + suite green

- Confirm the motivating case: `make run SRC=<prepped 4tsGD7>.glsl` at
  default (auto) completes within the stock 90 s `RUN_TIMEOUT` with an
  animating viewport. Produce the prepped file with
  `python3 tools/glsl_prep.py --corpus corpus/shadertoy/v1/shaders --dest out/corpus-guest`
  and use the `Sxx.GLS` that CORPUS.TXT maps to `4tsGD7` (rename the copy to
  `heavy.glsl` under `out/` for the run; do not touch `corpus/`).
- Run the full suite.

**Verify**: heavy run exits 0 with >=3 distinct trailing frames (count as
proof 4 does: `md5sum RUN_DIR/frames/frame-*.png | awk '{print $1}' | sort -u | wc -l`);
`make test` → `-- 12 passed, 0 failed --` (still 12 at this point; the count
grows in Stage B). Record the heavy shader's settled `1:N` from `screen.txt`.

### Stage B — visual-correctness oracle

**Design:** the guest dumps **pre-quantization clamped RGB** samples on a
fixed 80x36 grid (8x8 blocks of the 640x288 viewport, block centers — the
exact `fragCoord` set `(bx*8+4, 288-(by*8+4))`) at two fixed uniform states:

- state A: `iTime=0.5, iFrame=15`; state B: `iTime=8.0, iFrame=240`;
- both: mouse 0/never-clicked (`mouse_x=mouse_y=0, mouse_lb=0, click_x=click_y=-1`),
  date fixed `year=2026, mon=1, day=1, date_secs=0.0`, `res=(640,288)`.

DAT format (headerless, exactly 8640 bytes): rows top-down `by=0..35`, then
`bx=0..79`, 3 bytes R,G,B each = `ToI64(clamp(v,0,1)*255.0+0.5)`. Names:
`V<nn>A.DAT`/`V<nn>B.DAT` where `<nn>` is the CORPUS.TXT ordinal, `V00?.DAT`
for single-shader mode. This sidesteps the 16-color palette entirely and
compares shader semantics, not dithering.

The reference side renders the **same prepped bytes** the guest compiled,
wrapped for desktop OpenGL, at 80x36 with `fragCoord = gl_FragCoord.xy*8.0`
(GL pixel centers are `x+0.5`, so that yields exactly `8x+4`; GL rows are
bottom-up — flip when writing the DAT). References are **committed** under
`tests/corpus-visual/`, so `make test` and future corpus runs never need GL;
GL is only needed when regenerating references.

Comparison metric (in `tools/visual_compare.py`): a sample passes when
`max(|dR|,|dG|,|dB|) <= 16` (of 255); a shader's state passes when >=90% of
its 2880 samples pass; a shader is `visual OK` when both states pass.
Always print per-shader `meanerr / maxerr / pct` — the numbers are the
deliverable, the threshold is just the summary line. Known F64-vs-F32
deviants (`floatBitsTo*` users, plans/009 deviations list) may legitimately
fail: record them as deviations, do not tune the threshold to hide them.

#### Step B1: guest dump routine + hooks

In `src/holytoy/HT.HC`:

- `U0 HtVisualDump(U8 *path,F64 time,I64 frame)` — fills a local
  `CHtUniforms` per the design block, then evaluates `ht_fp` over the 80x36
  grid into an `MAlloc(8640)` buffer and `FileWrite(path,buf,8640)`. Wrap
  the sample loop in `try/catch` (like exec) so a faulting shader yields a
  marker, not a dead batch. IMPORTANT: pass the local uniforms pointer to
  `ht_fp`; generated code rebinds its globals when `u->i_frame` changes, so
  a fixed distinct `i_frame` per state gives deterministic rebinding.
- `HtCorpusRun`: after `exec OK`, call it twice
  (`E:/V%02dA.DAT`, `E:/V%02dB.DAT`, using the shader ordinal) and print
  `HT CORPUS <id> visual OK <ms>` or `... visual ERR <msg>`. On exec ERR,
  skip visual (the report shows `-`).
- Single-shader mode: in the `HtLoadGlsl` success path, when
  `FileFind("E:/VISDUMP.TXT")`: set `Fs->draw_it=NULL` is not yet needed —
  at that point draw_it IS already installed (HT.HC:597) — so temporarily
  `Fs->draw_it=NULL;`, dump `E:/V00A.DAT`/`E:/V00B.DAT`, restore
  `Fs->draw_it=&HtDrawIt;`, print `HT VISUAL DUMP OK`. (Concurrent HtDrawIt
  frames would race the generated globals' frame-rebind cache.)
- `tools/mkxfer.sh`: ship `x:/VISDUMP.TXT` when `HOLYTOY_VISDUMP` is set
  (same pattern as `GUI.TXT`).

**Verify**: `HOLYTOY_VISDUMP=1 make run SRC=tests/glsl/gradient.glsl` →
exit 0, `guest.log` has `HT VISUAL DUMP OK`, and
`MTOOLSRC=RUN_DIR/mtools.conf mcopy -n x:/V00A.DAT /tmp/claude-scratch/` (use
the session scratchpad or `out/`) yields a file of exactly 8640 bytes. Sanity:
for the gradient (`fragColor=vec4(fragCoord.y/iResolution.y)`), row 0
(top) samples `y=284` → value `round(284/288*255)=251` in all three
channels; check with
`python3 -c "d=open('V00A.DAT','rb').read(); print(d[0],d[1],d[2])"` → `251 251 251`.

#### Step B2: comparer + gradient reference + proof 13

- `tools/visual_compare.py` (new): inputs `--dumps DIR --refs DIR
  [--manifest CORPUS.TXT]`; pairs `V<nn>[AB].DAT` with
  `<shader_id>-[AB].dat` reference names; prints the per-shader table and a
  summary line `visual K/N within tolerance`; exits 0 if all *present*
  pairs pass, 1 otherwise (missing references report as `no-ref`, don't
  fail the exit). Pure stdlib (bytes + math), no numpy.
- Commit the gradient references `tests/corpus-visual/refs-fixtures/gradient-A.dat`
  and `gradient-B.dat`. Generate them with the Step B3 GL pipeline if it is
  already up; otherwise compute them analytically (the fixture is
  `vec4(fragCoord.y/iResolution.y)`, i.e. value `round((288-(by*8+4))/288*255)`
  per row) with a throwaway script — the fixture's math is exact either way,
  and B equals A (time-independent).
- `tools/test.sh` proof 13 "oracle": run
  `HOLYTOY_VISDUMP=1 RUN_DIR=... tools/run.sh tests/glsl/gradient.glsl`,
  extract `V00A.DAT`/`V00B.DAT` via mcopy, rename to `gradient-[AB].DAT`
  pairing, run `tools/visual_compare.py` against
  `tests/corpus-visual/refs-fixtures/`, require exit 0. Update the suite
  header comment (12 → 13) and the plan-009-era `Twelve round-trips` text.

**Verify**: `make test` → `-- 13 passed, 0 failed --`.

#### Step B3: host reference renderer (GL bootstrap — bounded)

Goal: `tools/glsl_ref.py` renders every prepped corpus shader to reference
DATs. Wrapper construction (in the script): prologue

```glsl
#version 330 core
out vec4 ht_out_color;
const vec3 iResolution = vec3(640.0, 288.0, 1.0);
uniform float iTime; uniform int iFrame; uniform vec4 iMouse; uniform vec4 iDate;
// (uniform values are set per state: A/B per the plan's fixed-state table;
//  iMouse = vec4(0), iDate = vec4(2026.0, 1.0, 1.0, 0.0) — the GUEST's
//  values, so the recorded 1-based-month deviation cancels out.)
```

then the prepped shader source verbatim, then
`void main(){ vec4 c=vec4(0); mainImage(c, gl_FragCoord.xy*8.0); ht_out_color=c; }`.
Render a fullscreen triangle at 80x36 into an RGBA8 FBO, read pixels, flip
rows, write `<shader_id>-[AB].dat`. Use `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe)
for machine-independent output where the stack allows it.

Environment routes, in order — spend at most ~30 minutes per route, then
move on:

1. **moderngl via nix**:
   `nix shell --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.moderngl ])' --command python3 tools/glsl_ref.py ...`
   with `moderngl.create_standalone_context()` (add `backend='egl'` and
   mesa's libEGL on `LD_LIBRARY_PATH` via `nix build nixpkgs#mesa` if
   window-system creation fails; `DISPLAY=:0` WSLg is also available).
2. **glslViewer via nix**: `nix profile add nixpkgs#glslviewer`, have
   `glsl_ref.py` shell out:
   `glslViewer wrapped.frag -w 80 -h 36 --headless -E screenshot,out.png`,
   decode the PNG with ffmpeg (`-f rawvideo -pix_fmt rgb24`) exactly like
   `tools/scrtext.py` does. Uniform values then ride in as `const` in the
   prologue instead of uniforms (the script supports both modes; consts are
   simpler and equally valid since all values are fixed per state).
3. Neither works → **escape hatch**: skip reference generation, mark the
   plan's visual-vs-reference criteria BLOCKED with the exact errors from
   both routes, keep proof 13 (its fixture references are analytic), and
   continue with Stage C. Do not write a CPU GLSL evaluator.

Gate before trusting the pipeline: render `tests/glsl/gradient.glsl` through
it and diff against the analytic `gradient-A.dat` — must match within 1/255
on every sample.

**Verify**: gate comparison passes; `python3 tools/glsl_ref.py --corpus corpus/shadertoy/v1/shaders --out tests/corpus-visual/refs-v1` writes 40 files
(20 shaders x A/B), each 8640 bytes. Commit them. Record which route worked
in the plan file under Done criteria.

#### Step B4: corpus harness integration

- `tools/corpus_run.sh`: after the report, extract dumps
  (`MTOOLSRC="$RD/mtools.conf" mcopy -n 'x:/V*.DAT' "$DUMP_DIR/"`, where
  `DUMP_DIR="$RD/visual"`), then run `tools/visual_compare.py --dumps
  "$DUMP_DIR" --refs tests/corpus-visual/refs-v1 --manifest
  "$PREP_DIR/CORPUS.TXT"` and print its table after the staged table (visual
  is reported separately from exec%, per AGENTS.md:69-73). Raise the default
  `RUN_TIMEOUT` export from 420 to 900 (dumping 2x2880 samples of heavy 3D
  shaders adds minutes under TCG).
- `tools/corpus_report.py`: extend `MARKER` to also accept `visual` so the
  guest-side OK/ERR shows up as an extra column, but keep `STAGES`
  (`compile install exec`) as the headline percentages.

**Verify**: `tools/corpus_run.sh` → staged table still 20/20/20; visual
table lists all 20 with numbers; nonzero `visual K/20` recorded honestly.
Expected: the three plan-009 spot-check shaders (4dSBz3, 4tsGD7, Wtj3Wc)
pass; `floatBitsTo*`/hash-heavy shaders may fail — list each failure with
its meanerr/pct and, for each, one sentence on whether it traces to a
recorded deviation (plans/009 list) or a real compiler bug. A real bug found
here is Stage C work only if it clusters; otherwise record it.

### Stage C — Shadertoy corpus v2

#### Step C1: build `corpus/shadertoy/v2/`

Mirror v1's layout (`README.md`, `manifest.jsonl`, `rejected.jsonl`,
`shaders/<id>/{image.glsl,metadata.json}`, `validate.py`) as a
**self-contained sibling** — v1 stays frozen and unreferenced. Sources: the
SAME two pinned snapshots (commits inlined above in "Current state") — clone
each at its pinned commit into the scratchpad, never vendored into the repo.
Same license-evidence rules as v1 (Reinder: per-shader README license
section required; bean-mhm: repo-level AGPL-3.0). Anything ambiguous →
`rejected.jsonl`, not accepted.

Composition targets:

- **Stratum `single_no_channels`**: the 20 v1 projects copied byte-for-byte
  (same ids, metadata refreshed only in provenance notes) plus **>=20 new**
  projects passing exactly v1's gates (one Image pass, no iChannel/texture/
  Buffer/Common/Sound/Cubemap/webcam/video/mainVR). Keep a rough 2D/3D
  balance; record each `visual_domain` as v1 does.
- **Stratum `single_texture_channels`**: **8-12** projects with exactly one
  Image pass whose only inputs are static texture channels
  (`iChannel*` + `texture`/`texelFetch` on stills). No keyboard, video,
  music, webcam, buffer, or cubemap inputs. Do NOT ship the media files;
  record each channel in `passes[].inputs` (channel index, input kind,
  Shadertoy media path if known). These are *expected to fail compile*
  today — that is the point: the missing feature becomes corpus-measured
  (AGENTS.md:41-44).
- Multipass/buffer stratum: explicitly deferred (record in v2 README and
  plans/README.md) — the manifest schema has no pass-graph yet and no
  runtime could consume it.

Adapt `validate.py` for v2: same checks, plus per-stratum input gates
(stratum A: inputs empty; stratum B: inputs all static textures, nonempty).
If the pinned snapshots yield fewer qualifying candidates than the targets,
take what exists and record the shortfall in v2's README — do not relax the
gates or add a third source repo without stopping to report first.

**Verify**: `python3 corpus/shadertoy/v2/validate.py` → exit 0;
`git status --porcelain corpus/shadertoy/v1` → empty;
`ls corpus/shadertoy/v2/shaders | wc -l` → >= 48 (40 A + 8 B).

#### Step C2: version-aware harness

- `tools/glsl_prep.py`: already takes `--corpus`; add `--manifest-strata`:
  when the corpus root has a `manifest.jsonl`, emit CORPUS.TXT lines as
  `Sxx <shader_id> <stratum>` (fallback: two fields as today).
- `src/holytoy/HT.HC` manifest parser: stop `id` at space (excerpt above)
  and skip the rest of the line — the guest ignores the stratum.
- `tools/corpus_run.sh`: accept `CORPUS_DIR` env (default
  `corpus/shadertoy/v2` once v2 exists) and pass it to glsl_prep; pass the
  manifest through to report/compare.
- `tools/corpus_report.py` + `tools/visual_compare.py`: when the manifest
  carries strata, group percentages per stratum AND overall — never let
  stratum B's expected failures blur stratum A's number, and never hide the
  overall number either.
- Check `tools/test_corpus_compat.py` (invoked by `make test`) for v1-path
  assumptions; keep it green (pointing it at v1 permanently is fine — it is
  a static smoke check).

**Verify**: `CORPUS_DIR=corpus/shadertoy/v1 tools/corpus_run.sh` still
produces 20/20/20 (backward compatible); `bash -n` on touched scripts.

#### Step C3: v2 references + full measurement

- Generate references for **stratum A** shaders:
  `python3 tools/glsl_ref.py --corpus corpus/shadertoy/v2/shaders --only-stratum single_no_channels --out tests/corpus-visual/refs-v2` (skip stratum B — no channel
  runtime on either side). Commit them (~40 shaders x 2 x 8640 bytes ≈ 700 KB).
- Run the full v2 batch: `tools/corpus_run.sh` (default v2). Record the
  staged table and visual table verbatim in this plan file.

**Verify**: report shows all v2 shaders; stratum B rows show `compile ERR`
with a texture-related diagnostic (e.g. the plans/009-recorded "texture
functions are rejected with diagnostics" message) — a stratum B shader that
*compiles* means the gate misclassified it: move it or STOP.

#### Step C4: bounded cluster fixes (stratum A only)

New stratum A shaders will expose compiler gaps. Apply plan 009's method:
cluster failures by first error, fix the largest clusters first — **at most
3 fix batches**, each batch justified in the commit message by its named
cluster and re-measured with `tools/corpus_run.sh`. Compiler modules may be
touched ONLY here. All 13 proofs must stay green after every batch. If
stratum A exec is still below 90% after 3 batches, STOP and report the
remaining clusters (they become plan 011 input).

**Verify** (after final batch): `make test` → `-- 13 passed, 0 failed --`;
v1 run still 20/20/20; final v2 tables recorded.

#### Step C5: docs + index

- `AGENTS.md`: update the corpus paragraph (v2 default, strata, visual
  table, refs location) and the run-artifact/scale knobs
  (`HOLYTOY_SCALE`, `HOLYTOY_VISDUMP`, `CORPUS_DIR`); keep it operational,
  no progress prose.
- `plans/README.md`: add the 010 row + dependency notes (multipass stratum
  deferred; texture runtime = next direction plan), update status when done.
- `docs/VISION.md`: only if a landed behavior contradicts it (render scale
  is already spec'd there as a feature).

**Verify**: `git diff --stat` touches only in-scope files;
`grep -n "HOLYTOY_SCALE" AGENTS.md` finds the doc.

## Test plan

- New proof 13 "oracle" (Step B2) and the `HT SCALE OK` marker in proof 6
  (Step A3) — both wired into `tools/test.sh`, final count 13.
- New fixture `tests/glsl/slow-loop.glsl`; committed reference DATs under
  `tests/corpus-visual/` (fixtures, refs-v1, refs-v2).
- Determinism: run `HOLYTOY_VISDUMP=1 make run SRC=tests/glsl/gradient.glsl`
  twice → both `V00A.DAT` extractions byte-identical (`md5sum`).
- `python3 tools/glsl_prep.py` twice → byte-identical outputs (existing
  guarantee, must survive the strata change).
- Full suite `make test` after every stage; corpus runs per stage as above.

## Done criteria

Machine-checkable; ALL must hold, with evidence (run dirs, tables) recorded
in this file:

- [ ] `make test` ends `-- 13 passed, 0 failed --` on the final tree.
- [ ] Adaptive scale: prepped `4tsGD7` completes `make run` (default auto,
      stock `RUN_TIMEOUT=90`) with exit 0 and >=3 distinct trailing frames;
      settled `1:N` recorded. `HT SCALE OK` present in the proof-6 run log.
- [ ] `git diff a214703..HEAD -- corpus/shadertoy/v1/` is empty.
- [ ] Visual oracle: `tools/corpus_run.sh` on v1 prints the per-shader
      visual table vs `tests/corpus-visual/refs-v1`; K/20 recorded with
      per-shader meanerr/pct; every failing shader has a one-line diagnosis
      (recorded deviation vs bug). 4dSBz3, 4tsGD7, Wtj3Wc pass. (If Step B3
      hit its escape hatch: this criterion is BLOCKED with both routes'
      errors recorded instead — not silently dropped.)
- [ ] Corpus v2 exists, `validate.py` exits 0, >=40 stratum-A and >=8
      stratum-B shaders; staged + visual tables for all of v2 recorded;
      stratum A exec >= 90% (or the STOP report from C4); stratum B compile
      failures all carry texture diagnostics.
- [ ] v1 backward-compat run (`CORPUS_DIR=corpus/shadertoy/v1`) still
      20/20 compile / 20/20 install / 20/20 exec.
- [ ] AGENTS.md documents `HOLYTOY_SCALE`, `HOLYTOY_VISDUMP`, `CORPUS_DIR`;
      `plans/README.md` row updated; README.md untouched.

## STOP conditions

Stop and report (do not improvise) if:

- Any file under `corpus/shadertoy/v1/` would need to change, or a corpus
  shader (v1 or v2) would need hand-editing to pass any stage.
- The HT.HC excerpts above don't match the live code (drift).
- Proof 9 (dither) or proof 12 (editor) fails twice after Stage A with the
  suite's `HOLYTOY_SCALE=4` pin in place — the runtime-scale refactor has a
  determinism leak; do not paper over it by re-hashing.
- The `HT SCALE OK` self-test flakes twice after one loop-count/sleep
  adjustment (TCG timing margins too thin — report measured ms values).
- Both GL routes in Step B3 fail (escape hatch: record errors, mark visual
  criteria BLOCKED, continue) — but STOP fully if the *gate* passes yet
  corpus references disagree wildly on shaders the guest renders correctly
  on screen (pipeline bug, not shader bug).
- The pinned snapshot repos are unreachable or their pinned commits are
  gone, or stratum targets can't be met under the license-evidence rules.
- Host-side code starts making compiler decisions (anything beyond
  byte-level ASCII prep and *verification* rendering is compiler semantics).
- A guest fault in one corpus shader kills the batch loop and two
  source-backed fixes don't isolate it.
- QEMU cannot start in your environment: record the failure, leave VM
  criteria unchecked — never manufacture evidence.

## Maintenance notes

- The visual tolerance (16/255, 90% of samples, both states) is a starting
  contract — tighten it as F32 semantics land; never loosen it to make a
  shader pass. Reference DATs regenerate only via `tools/glsl_ref.py`
  (needs the GL route recorded in Done criteria); regeneration is required
  whenever a corpus version is added, and the diff of committed refs is the
  review surface for oracle drift.
- The controller constants (250 ms coarsen / 150 ms projected refine /
  2-and-4-frame settle) live in HT.HC; a future KVM host will settle at
  finer scales automatically — no code change needed. If a plan later adds
  render-scale UI (VISION step 4 polish), keep `E:/SCALE.TXT` as the
  harness pin.
- Stratum B is a measured IOU: the texture/channel runtime plan (next
  direction plan, likely 011) flips those rows from `compile ERR` to real
  numbers and must then extend `glsl_ref.py` and the guest with actual
  channel media plumbing. Multipass needs a manifest pass-graph schema
  first — deferred deliberately.
- Review scrutiny points: the `q[256]` bounds and per-pixel Bayer offsets at
  scales 1/2/8/16 (screenshot-diff a static shader at each pinned scale);
  the visual dump's uniform snapshot (any accidental dependence on live
  `ms`/`tS` state breaks determinism); v2 license evidence links.
