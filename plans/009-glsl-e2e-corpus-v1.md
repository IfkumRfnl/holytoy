# Plan 009: End-to-end in-guest GLSL compiler measured against Shadertoy corpus v1

> **Executor instructions**: Follow this plan stage by stage. Run every
> verification command and record actual evidence. Corpus numbers come only
> from the in-guest compiler through the batch harness; never count host-side
> preprocessing or hand-edited shaders as compatibility. Record the honest
> Stage 1 baseline even though it is expected to be ~0/20. Update
> `plans/README.md` only after the proof state is known.
>
> **Drift check (run first)**: `git diff --stat 8478f37..HEAD -- src/holytoy/ tools/ tests/ guest/ corpus/ AGENTS.md`
> Plan 008 is merged; the RGBA `CHtFragColor` ABI and the failure-safe
> `HtCompileAndSwapGlsl` path are frozen. Corpus v1 is committed byte-for-byte
> at `c23a59f`. Stop on an ABI mismatch or any modified corpus original.

## Status

- **Priority**: P1
- **Effort**: XL
- **Risk**: HIGH (full compiler rewrite in HolyC; every semantic bug shows up
  only inside the VM)
- **Depends on**: plans/008-in-guest-glsl-compiler-skeleton.md (DONE);
  corpus v1 at `c23a59f`
- **Category**: direction
- **Planned at**: commit `c23a59f`, 2026-07-14
- **Execution status**: IN PROGRESS

## Milestone and measurement

`corpus/shadertoy/v1` is exactly 20 real single-pass, no-channel Shadertoy
shaders (10 2D, 10 3D), committed byte-for-byte. **Success for this plan is
strong language compatibility across these 20 shaders.** No textures,
channels, or multipass — those are out of scope by corpus construction.

Per AGENTS.md, report independently and never blend:

1. corpus compile/run percentage, staged (compile / install / exec);
2. visual correctness on spot-checked shaders and known semantic deviations;
3. performance (shade ms at HT_SCALE under TCG/KVM);
4. harness/test health (the twelve `make test` proofs).

## Current state

Plan 008's guest compiler (`HTLEX/HTPARSE/HTLOWER/HTEMIT/HTCOMP.HC`) handles
one scalar `mainImage` slice. `HT.HC` owns the editor loop, `HtInstallHoly`
(ExePutS2, previous-shader-on-error), and the frozen uniforms/RGBA ABI.
`HT_GLSL_MAX` is 32768; the largest corpus shader (`4sfGWX`, 19892 bytes)
fits. Early Stage 1 work exists on this branch: `tools/glsl_prep.py`, the
`HOLYTOY_CORPUS_DIR` hook in `mkxfer.sh`, and an overridable `RUN_TIMEOUT`.
Against corpus v1 the skeleton compiles ~0/20 — every shader uses functions,
vectors beyond the slice, and most use `#define`.

## Scope

**In scope**: corpus guest batch harness with staged reporting; a full
compiler rewrite (preprocessor, lexer, parser, typed sema, three-address
emitter, runtime library) — all in HolyC, in-guest, modular, host doing zero
compiler semantics; iteration until the largest failure clusters are fixed;
honest staged corpus table.

**Out of scope**: textures/channels/multipass/sound/VR, adaptive resolution,
a corpus beyond the committed 20, editor UX changes, and any host-side
transpilation or shader rewriting beyond byte-level ASCII preparation.

## Steps

### Stage 1: corpus guest harness and honest baseline

**Step 1 — deterministic guest-safe prep.** `tools/glsl_prep.py` writes
prepped copies of the 20 passes: strip a UTF-8 BOM, replace every non-ASCII
byte with `?` (TempleOS is an 8-bit charset; mojibake breaks compilation).
Originals stay byte-for-byte untouched. Output is deterministic:
`S01.GLS..S20.GLS` in manifest order plus `CORPUS.TXT`, one `Sxx <shader_id>`
line each.

**Step 2 — ship and batch-run in the guest.** `mkxfer.sh` gains
`HOLYTOY_CORPUS_DIR`: ships the prepped shaders as `E:/S01.GLS..S20.GLS` and
the `E:/CORPUS.TXT` manifest. `HT.HC` corpus mode: when `E:/CORPUS.TXT` is
present, for each shader run the in-guest compiler stage by stage and print
one marker per stage:

```
HT CORPUS <id> <stage> OK|ERR <msg>
```

with stages `compile` (GLSL -> HolyC), `install` (ExePutS2 + bind), `exec`
(call the shader at 4 sample pixels and check all outputs finite). No
rendering in batch mode; the previous-shader guarantee is irrelevant here but
faults must not take down the batch loop.

**Step 3 — one-boot report and baseline.** `tools/corpus_run.sh`: prep, one
VM boot (larger exported `RUN_TIMEOUT`), then `tools/corpus_report.py` parses
the run's `guest.log` into a staged compatibility table (per-shader rows,
per-stage OK/ERR with first error message) and per-stage percentages. Run it
against the current skeleton and record the number honestly — expected ~0/20.

### Stage 2: compiler rewrite (all HolyC, in-guest, modular)

**Step 4 — `HTPP.HC` (new): text-level GLSL preprocessor.** Object-like AND
function-like `#define`, `#undef`, `#if/#ifdef/#ifndef/#elif/#else/#endif`,
`defined()`, an integer const-expr evaluator for conditions;
line-count-preserving output so diagnostics keep source line numbers;
recursion-guarded macro expansion.

**Step 5 — `HTLEX.HC`/`HTPARSE.HC`: full GLSL grammar.** Lexer: ternary
`?`/`:`, all GLSL operators, uint/float literal suffixes, bool/keyword
idents. Parser: ternary, all assignment ops, `++`/`--`, indexing, swizzles,
struct declarations, fixed-size arrays, `const` qualifier, global variables
with initializers, function definitions with `in`/`out`/`inout` params, full
control flow (`if`/`else`/`for`/`while`/`do`/`break`/`continue`/`return`);
precision qualifiers parsed and skipped.

**Step 6 — `HTLOWER.HC` becomes typed sema.** Type system: `bool`, `int`,
`uint`, `float`, `vec2-4`, `ivec/uvec/bvec2-4`, `mat2/3/4`, user structs,
fixed arrays. Scoped symbol tables; user-function overloads; a GLSL builtin
catalog with genType componentwise rules; implicit int->float conversions;
const-expr folding for array sizes.

**Step 7 — `HTEMIT.HC`: three-address statement lowering to HolyC**, plus
`HTLIB.HC` (new) runtime. Normative HolyC emission rules (from skills/holyc):

- **No ternary**: lower `?:` to if/else assigning a pre-declared temp.
- **No `continue`**: `goto` a per-loop continue label. Loops lower to the
  normal form `while(1){cond-stmts; if(!c) break; body; cont:; step-stmts;}`.
- **No `const`**: drop the qualifier after sema has used it.
- **Non-C precedence**: fully parenthesize every emitted expression.
- **Postfix casts only**: never emit casts; use `ToF64`/`ToI64` (`ToI64`
  truncates, matching GLSL `int()`).
- Declarations are statements — temps may be declared inline; `&&`/`||`
  short-circuit is guaranteed and may be relied on.
- **Types**: GLSL `float`->`F64`, `int`->`I64`, `bool`->`I64`; `uint`->`I64`
  masked with `0xFFFFFFFF` after arithmetic/shifts (32-bit wrap semantics so
  hash functions work). Vectors: `CHtV2/V3/V4` (F64 fields), ivec->
  `CHtI2/3/4` (I64), `mat2/3/4`->`CHtM2/M3/M4` (`F64 m[N]`). Structs become
  emitted HolyC classes; struct copy via `MemCpy`.
- **Componentwise ops emitted INLINE per component**, each non-trivial
  subexpression materialized in a temp exactly once. Cross-component ops
  (`dot`, `cross`, `length`, `normalize`, `distance`, `reflect`, `refract`,
  matrix*vector, matrix*matrix, `any`/`all`/`equal`) call `HTLIB.HC` helpers.
- **Functions**: composite params/returns by pointer; `out`/`inout` scalars
  by pointer; GLSL in-params are caller-copied; overload name mangling
  `uf_<name>_<sig>`.
- **Globals/uniforms**: global initializers run in a generated
  `HtShaderInit()` called by `HtInstallHoly` after install. Unit-level
  globals `htu_iTime`, `htu_iResolution` (vec3), `htu_iMouse` (vec4, mapped
  per AGENTS.md), `htu_iDate` (vec4), `htu_iFrame`, rebound when
  `u->i_frame` changes; `CHtUniforms` gains date fields filled by `HtDrawIt`
  (`Date2Struct`/`Now`).
- **`HTLIB.HC` runtime**: vector/matrix classes, cross-component helpers,
  scalar builtins (`HtFract`, `HtMod` = `x-y*Floor(x/y)`, `HtClamp`, `HtMix`,
  `HtStep`, `HtSmoothstep`, `HtSign`, `HtAtan2` via `Arg(x,y)`), and F64 LUT
  sin/cos (4096-entry, linear interpolation, accuracy gate like `HTMATH.HC`)
  for per-pixel speed. Kernel `Sqrt/Exp/Ln/Log2/Pow/Floor/Ceil/Round/Trunc`
  are used directly.

**Step 8 — integration.** `HT.HC`/`mkxfer.sh` ship and include the new module
list (`HTPP`, `HTLEX`, `HTPARSE`, `HTLOWER`, `HTEMIT`, `HTLIB`, `HTCOMP` plus
existing `HTMATH`, `HTRENDER`). All guest source stays ASCII. Existing
`.glsl` fixtures and all twelve proofs stay green throughout.

### Stage 3: cluster-driven iteration

**Step 9 — measure, cluster, fix, re-measure.** Run `tools/corpus_run.sh`,
cluster failures by first error, fix the largest clusters first. Expected
clusters: uint bit-op masking, matrix ops, struct arrays, `floatBitsToUint`
F32-bit semantics (needs a software F64->F32 bit conversion), and one shader
(`3dfGR2`). Re-measure after each fix batch; commit table snapshots. Visual
spot-checks: run individual corpus shaders through `make run SRC=...glsl`
and read the screenshots. The previous-shader-on-error guarantee and all
twelve proofs must stay green after every landing.

## Test plan

- `python3 tools/glsl_prep.py` twice — byte-identical output (determinism)
- `git status corpus/` clean — originals never modified
- `bash -n tools/{mkxfer,run-common,test,corpus_run}.sh`
- ASCII scan of all new/changed `.HC` files
- `tools/corpus_run.sh` at baseline (Stage 1) and after each Stage 3 batch
- focused VM runs of individual corpus shaders with screenshots
- `make test` ending `-- 12 passed, 0 failed --` after every stage

## Done criteria and proof evidence

- [ ] Stage 1 harness lands; honest baseline table with the skeleton compiler
      recorded in this section (expected ~0/20 — record the real number).
- [ ] Compiler rewrite complete: `HTPP.HC` and `HTLIB.HC` exist; all compiler
      semantics execute in-guest in HolyC; host does zero compiler semantics.
- [ ] Final honest staged corpus table committed, with per-stage percentages
      (compile / install / exec) reported separately from visual correctness,
      performance, and harness health.
- [ ] Visual spot-check screenshots for at least 3 corpus shaders referenced
      by run directory, with observed deviations noted.
- [ ] Known semantic deviations recorded and justified (e.g. `float` is F64
      not F32; `int` is I64 unmasked; LUT sin/cos accuracy bound).
- [ ] `make test` prints `-- 12 passed, 0 failed --` on the final tree;
      previous-shader-on-error preserved.

## STOP conditions

- Any file under `corpus/shadertoy/v1/shaders/` is modified.
- Corpus percentage is computed from anything but `HT CORPUS` markers in a
  real guest run's log.
- Host-side code starts making compiler decisions (anything beyond byte-level
  ASCII prep is compiler semantics).
- Generated code changes the frozen RGBA ABI or performs palette
  quantization.
- A guest fault in one corpus shader aborts the batch loop and two
  source-backed fixes do not resolve it.
- QEMU cannot start in the execution environment: record the exact failure
  and leave VM criteria unchecked rather than manufacturing evidence.

## Maintenance notes

The 20-shader corpus is v1 of the large public corpus the ~99% target
requires; growing it (and adding channels/multipass strata) is later work.
The staged table format (`compile`/`install`/`exec`) is the contract for
future corpus versions — extend it with `visual` once a reference-image
pipeline exists. `HTMATH.HC`'s 16.16 LUT remains for the built-in shader;
generated code uses `HTLIB.HC`'s F64 LUT. If exec-stage timing becomes the
bottleneck, raise the corpus run's exported `RUN_TIMEOUT` rather than
skipping shaders.
