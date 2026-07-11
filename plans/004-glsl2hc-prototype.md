# Plan 004: Prototype the GLSL→HolyC transpiler host-side (`tools/glsl2hc.py`, VISION step 3)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a27d114..HEAD -- tools/ docs/VISION.md tests/`
> If any in-scope file changed since this plan's verification refresh, compare
> the "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. (Planned at `74e018b`; verification
> commands refreshed at `a27d114`, after plan 005 replaced global `out/`
> artifacts with per-run `RUN_DIR` directories and grew `make test` to five
> proofs — `tools/` also gained `run-common.sh`, `prune-runs.sh`,
> `test-run-locks.sh` since the original baseline.)

## Status

- **Priority**: P2
- **Effort**: L (coarse — this is a compiler; the scope below is the honest v0 cut)
- **Risk**: LOW (all-new files; nothing existing changes)
- **Depends on**: none to build (pure host-side + existing harness); plan 002 consumes its output later
- **Category**: direction
- **Planned at**: commit `74e018b`, 2026-07-11

## Why this matters

The headline of the project is "GLSL fragment shaders transpiled to HolyC"
(README.md:30-33), and the v1 spec names the exact artifact this plan
builds: "A host-side Python prototype (`tools/glsl2hc.py`) comes first
purely as a development vehicle (fast iteration on the emitter, testable
against the harness before the app exists), then the emitter is ported to
HolyC and embedded in the app" (docs/VISION.md:54-58). That file does not
exist. This plan delivers it: a stdlib-only Python transpiler for the
deliberately small GLSL subset, unit-tested without a VM, plus one
end-to-end proof where a real GLSL shader renders on real TempleOS through
the existing harness.

**Decided tradeoff to honor** (do not re-litigate): the host pipeline is a
development vehicle, NOT a product surface — "the v1 input box takes GLSL
directly" in the guest (VISION.md:53), and "Nothing ships as 'host pipeline
now, app later'" (VISION.md:100-103). So: no watch-mode integration, no
README feature marketing; the deliverable is the emitter and its tests. The
subset is small *precisely so the in-guest HolyC port is realistic*
(VISION.md:57-58) — resist adding GLSL features beyond the spec list.

## Current state

- `tools/` contains no transpiler: `gui.sh imginfo.py install_os.sh
  mkxfer.sh prune-runs.sh qmp.py run-common.sh run.sh scrtext.py test.sh
  test-run-locks.sh watch.sh`.
- The GLSL subset is specified at docs/VISION.md:45-51:
  - types `float/vec2/vec3/vec4/int/bool` + swizzles (`p.xy`, `c.rgb`)
  - arithmetic incl. componentwise vector ops, `mat2` at most
  - builtins: `sin cos tan atan sqrt pow exp log floor fract mod min max
    clamp mix step smoothstep length normalize dot cross abs sign`
  - control flow: `if/for/while`, function definitions
  - no textures/buffers
- Shadertoy conventions (VISION.md:29-31): entry point
  `mainImage(out vec4 fragColor, in vec2 fragCoord)`; uniforms `iTime`,
  `iResolution`, `iMouse`, `iFrame`.
- The HolyC target ABI (docs/VISION.md:64-67):

  ```holyc
  class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
  U0 MainImage(CHtUniforms *u, I64 x, I64 y, U8 *out_color);  // one pixel
  ```

- HolyC facts that constrain the emitter (all VM-validated in this repo —
  see `skills/holyc/SKILL.md` for the full list): no `float`, use `F64`;
  no operator overloading, so vec ops become emitted helper functions or
  per-component expressions; `U0` is the void-like return; sources must be
  **pure ASCII**. Working HolyC style to imitate: `src/plasma.HC`.
- Harness facts for the e2e proof (post plan 005 — there are NO global
  `out/` artifact paths): `make run SRC=file.HC` injects the file as
  `E:/MAIN.HC` and runs it fullscreen under try/catch, printing its result
  directory as the first stdout line (`RUN_DIR=/abs/path/out/runs/run-...`);
  exit 0 = compiled and ran; exit 1 = HolyC compile/runtime error with the
  message in that run's `guest.log`;
  `python3 tools/imginfo.py "$RD/latest.png"` prints `WIDTH HEIGHT NCOLORS`.
  For scripted verification, reserve the directory yourself:
  `RD="$(mktemp -d "$PWD/out/runs/verify-004-XXXXXX")";
  RUN_DIR="$RD" tools/run.sh out/g.HC` (must be a new or empty direct child
  of `out/runs/`; directories are single-use — take a fresh `$RD` per run).
- Python conventions in this repo: stdlib-only, `#!/usr/bin/env python3`,
  module docstring with usage and exit codes — see `tools/qmp.py:1-13` and
  `tools/scrtext.py`. There is no pip/venv/pytest anywhere; keep it that
  way.
- 16-color screen: the emitted standalone runner must quantize
  `fragColor` to 16 palette entries (see Step 3 for the decided v0 scheme).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Unit tests (no VM) | `python3 tools/test_glsl2hc.py` | `OK (N tests)`-style summary, exit 0 |
| Transpile | `python3 tools/glsl2hc.py tests/glsl/circle.glsl -o out/circle.HC` | exit 0, ASCII HolyC emitted |
| E2E on TempleOS | fresh `$RD`; `RUN_DIR="$RD" tools/run.sh out/circle.HC` | exit 0, artifacts in `$RD` |
| Screenshot facts | `python3 tools/imginfo.py "$RD/latest.png"` | `640 480 N`, N ≥ 8 |
| Regression | `make test` | `5 passed, 0 failed` |

## Suggested executor toolkit

- Read `skills/holyc/SKILL.md` before writing the emitter's HolyC templates;
  every emitted construct must be legal HolyC per that skill / vendor
  source, not per C intuition.
- GLSL semantics questions (e.g. `mod` sign behavior, `smoothstep` clamping):
  use the Shadertoy-observable behavior; note any deliberate deviation in
  the module docstring.

## Scope

**In scope** (create only):
- `tools/glsl2hc.py` — the transpiler (single file, stdlib only)
- `tools/test_glsl2hc.py` — unit tests (stdlib `unittest`)
- `tests/glsl/` — fixture shaders: `gradient.glsl`, `circle.glsl`,
  `plasma.glsl` (+ their expected-output goldens if you choose golden
  files; embedded expectations in the test file are also fine)
- `docs/notes/glsl2hc.md` — v0 coverage table: each spec-subset feature →
  supported / deferred, plus known semantic deviations

**Out of scope** (do NOT touch):
- `tools/run.sh`, `tools/watch.sh`, `Makefile` — no pipeline integration;
  the transpiler is invoked manually (decided tradeoff above).
- `src/holytoy/` — wiring transpiled shaders into the app is plan 002/003
  follow-up, after both exist.
- `skills/`, `vendor/` — maintained by a parallel agent session.
- GLSL features beyond the VISION.md:45-51 list (textures, structs,
  arrays, `#define`, mat3/mat4) — out, even if easy.

## Git workflow

- Branch: `advisor/004-glsl2hc`
- Commit style: short imperative sentence, matching `git log`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Skeleton — CLI, lexer, parser for the subset

`tools/glsl2hc.py` with the repo's script conventions (docstring, usage,
exit codes: 0 ok, 1 transpile error with a `file:line: message` diagnostic
on stderr, 2 usage/IO error). CLI:
`glsl2hc.py IN.glsl [-o OUT.HC] [--runner static|none] [--scale N]`.
Hand-written lexer + recursive-descent parser producing a small AST for:
declarations with the subset types, functions, `mainImage`, expressions
(arithmetic, comparison, logical, swizzle access/assignment, constructor
calls like `vec3(1.0, p)`, builtin calls), `if/for/while/return`. Reject
everything outside the subset with a clear diagnostic — a wrong-answer
transpile is worse than an error.

**Verify**: `python3 tools/test_glsl2hc.py` → parser-level tests pass
(write tests alongside each stage; `unittest` discovery not needed — a
plain `unittest.main()` file).

### Step 2: Emitter — AST → HolyC against the ABI

Emit, in order: a fixed preamble of vec helper types/functions (HolyC has
no operator overloading — emit `CV2/CV3/CV4` classes and `V3Add`,
`V3Scale`, `V3Dot`, … helpers, or fully scalarize expressions; **pick
scalarization only if swizzle assignment stays correct**, otherwise
helpers), the builtins mapped to HolyC (`Sin`, `Cos`, `Sqrt`, `Pow`,
`Floor`… — verify each name against `skills/holyc`; implement the ones
HolyC lacks, e.g. `fract`, `clamp`, `mix`, `step`, `smoothstep`,
`normalize`, `length`, as emitted F64 helper functions), user functions,
and `MainImage(CHtUniforms *u, I64 x, I64 y, U8 *out_color)` which builds
`fragCoord`/`iResolution`/`iTime`/`iFrame`/`iMouse` locals from `u` and
inlines the translated `mainImage` body. All F64 math in v0 — fixed-point
belongs to plan 003's library and the later in-guest integration. Output
must be pure ASCII; make the emitter assert that.

**Verify**: `python3 tools/test_glsl2hc.py` → emitter tests pass: for each
fixture, transpile and assert (a) output is ASCII, (b) contains
`U0 MainImage(CHtUniforms *u`, (c) golden-match or targeted substring
checks on the translated expressions (e.g. `circle.glsl`'s
`length(uv - 0.5)` becomes the emitted length-helper call).

### Step 3: `--runner static` — standalone one-frame proof harness

With `--runner static`, append a self-contained runner so the output runs
under `make run` *today*, with no app: set the palette to a 16-step
grayscale ramp via `GrPaletteColorSet` (pattern: `src/plasma.HC:5-17`),
loop the viewport calling `MainImage` once per pixel at `--scale N`
(default 4 → 160×120 evaluations, 4×4 blocks — keeps TCG runtime well
inside the 90 s timeout), map `fragColor` to the palette by luminance
(`0.299r+0.587g+0.114b` → 0..15). Grayscale-by-luminance is the decided v0
quantization: deterministic, provable via `imginfo` color count, no
palette-fitting cleverness. `iTime`=0.0, `iFrame`=0, `iMouse`=(0,0) for the
static frame.

Fixtures to include in `tests/glsl/`:
- `gradient.glsl` — `fragColor = vec4(fragCoord.y / iResolution.y);`
- `circle.glsl` — centered disc via `length`/`step`
- `plasma.glsl` — a sines-plasma using `sin`, `length`, swizzles, a `for`
  loop, and a user-defined function (exercises the widest subset slice)

**Verify**:
`python3 tools/glsl2hc.py tests/glsl/gradient.glsl --runner static -o out/g.HC`
then fresh `$RD`; `RUN_DIR="$RD" tools/run.sh out/g.HC` → exit 0 and
`python3 tools/imginfo.py "$RD/latest.png"` → `640 480 N` with N ≥ 8.
Repeat for `circle.glsl` with its own fresh `$RD` (its screenshot has ≥2
colors and the proof is exit 0 + no `ERR` in `$RD/status`).

### Step 4: E2E for the widest fixture + coverage notes

Run `plasma.glsl` end-to-end the same way — this is the real test that
emitted user functions, loops, and swizzles all compile under the actual
TempleOS compiler. Any exit 1 here: read the HolyC compiler message in
that run's `guest.log`, fix the *emitter* (never hand-edit the emitted file), add
a unit test pinning the fix. Then write `docs/notes/glsl2hc.md`: the
feature-coverage table (each VISION.md:45-51 item → supported/deferred),
semantic deviations, and the shortlist of what the in-guest HolyC port of
this emitter will need (informs the plan-002 follow-up).

**Verify**: the plasma e2e exits 0; `python3 tools/test_glsl2hc.py` all
pass; `make test` all pass (no regressions — this plan touched nothing the
proofs use, so any failure is environmental; investigate before blaming
your change).

## Test plan

- Unit (`tools/test_glsl2hc.py`, no VM): lexer tokens incl. swizzle vs
  float-literal dot ambiguity (`p.xy` vs `1.x` is invalid vs `1.0`);
  parser acceptance of each subset construct; parser *rejection* with
  diagnostics for out-of-subset input (texture2D, arrays); emitter goldens
  for the three fixtures; ASCII assertion; `--runner none` output contains
  no runner code.
- E2E (VM, manual in this plan, not added to `make test`): the three
  fixtures via `--runner static` as in Steps 3–4, each in its own reserved
  `RUN_DIR`. Not in `make test` because each costs a ~20 s VM cycle and the
  transpiler has no in-repo consumers yet; revisit when plan 002 integrates
  it (note this in docs/notes/glsl2hc.md). Parallel agents may be running
  VMs concurrently — this is safe (bounded slots), but expect occasional
  slot waits.
- Pattern to model tests on: there is no existing Python test file; use
  stdlib `unittest`, mirror the CLI conventions of `tools/qmp.py`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `python3 tools/test_glsl2hc.py` exits 0, ≥15 tests
- [ ] All three fixtures transpile with exit 0; out-of-subset input exits 1 with a `file:line` diagnostic
- [ ] `gradient.glsl` and `plasma.glsl` e2e runs exit 0; gradient run's `latest.png` has ≥8 colors per `tools/imginfo.py`
- [ ] Emitted output is pure ASCII (`LC_ALL=C grep -P '[^\x00-\x7F]' out/g.HC` → no output)
- [ ] `docs/notes/glsl2hc.md` has the coverage table
- [ ] `make test` exits 0 (`5 passed, 0 failed`)
- [ ] `git status` shows nothing modified outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- An emitted construct that `skills/holyc` says is legal fails to compile
  on the real TempleOS compiler twice (skill/reality divergence) — report
  the construct, the emitted HolyC, and the compiler message from the
  run's `guest.log`; the skill maintainers (parallel agent session) need to
  know.
- The static-frame run at `--scale 4` exceeds `RUN_TIMEOUT` — report the
  timing; do not silently drop to `--scale 8`.
- Correct swizzle-assignment semantics (`p.xy = q.yx;`) can't be achieved
  with your chosen representation after a genuine attempt — report the
  options you tried; this is a design fork the maintainer should pick.
- You find yourself adding a GLSL feature not on the VISION.md:45-51 list
  to make a fixture nicer — trim the fixture instead; if impossible, stop.

## Maintenance notes

- The emitter's HolyC preamble (vec helpers, builtin shims) is exactly what
  the in-guest port (VISION step 3 second half) must reproduce in HolyC —
  keep it small and listed in `docs/notes/glsl2hc.md`; every helper added
  is future port surface.
- Real `iTime`/`iMouse` come from plan 002's app runner, not the static
  runner; when integrating, only `MainImage` + preamble should be injected
  (that is what `--runner none` is for).
- Reviewer should scrutinize: diagnostics carry line numbers; the emitter
  refuses instead of guessing; no non-stdlib imports.
- Deferred explicitly: `mat2`, `iMouse`-driven fixtures (needs harness
  mouse injection — see plans/README.md "considered and deferred"),
  fixed-point emission (plan 003 integration), palette-fitting color
  quantization beyond grayscale.
