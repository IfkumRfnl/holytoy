# Plan 008: In-guest GLSL compiler skeleton, gradient vertical slice, corpus compatibility baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and record actual evidence. Do not count host fallback
> success as guest compiler compatibility. Update `plans/README.md` only after
> the proof state is known.
>
> **Drift check (run first)**: `git diff --stat 300a342..HEAD -- src/holytoy/ tools/ tests/ guest/ docs/ README.md AGENTS.md`
> Plan 007 is merged and its RGBA ABI is frozen. Stop on an ABI mismatch.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH (first product compiler code in TempleOS; VM verification required)
- **Depends on**: plans/007-rgba-abi-renderer-dither.md (DONE, merged at `300a342`)
- **Category**: direction
- **Planned at**: commit `8c7e820`, 2026-07-12
- **Execution status**: DONE; implementation and host checks completed in the
  Codex runner (which denies QEMU Unix-socket creation, so VM criteria were
  left unchecked there), then all 11 VM proofs verified green on the
  maintainer's host on 2026-07-12 (evidence under Done criteria).

## Why this matters

The shipping product must accept GLSL and compile it inside HolyToy. The Python
prototype proves feasibility but is not product progress. This plan establishes
native module boundaries and one narrow, rendered path before language breadth:

`SHADER.GLS -> lexer -> parser/AST -> semantic lowering -> HolyC emitter -> HtRecompile -> HTRENDER`

The compatibility number begins honestly against versioned repository fixtures.
It is not yet the large public Shadertoy corpus needed for a ~99% claim.

## Current state

Plan 007 supplies `CHtUniforms`, `CHtFragColor`, failure-safe `HtRecompile`, and
renderer-owned quantization. `.glsl` currently reaches the app through the host
Python prototype. The versioned GLSL smoke corpus has gradient, circle, and
plasma fixtures; there is no compatibility reporting tool.

## Scope

**In scope**: separate guest lexer, parser/AST, semantic lowering, emitter and
orchestrator modules; raw GLSL transfer; scalar `mainImage` gradient slice;
transitional fallback for wider old fixtures; a deterministic corpus report and
unit tests; an end-to-end VM proof; documentation/index updates.

**Out of scope**: claiming the public-corpus target, structs, arrays, functions,
overloads, matrices, general vectors, preprocessor, textures, multipass,
adaptive scale, and expansion of `tools/glsl2hc.py`.

## Steps

### Step 1: Add explicit guest compiler modules

Create `HTLEX.HC`, `HTPARSE.HC`, `HTLOWER.HC`, `HTEMIT.HC`, and `HTCOMP.HC`.
The lexer produces located tokens; the parser builds an AST; lowering validates
names/types in the supported scalar slice; the emitter targets the frozen RGBA
ABI; orchestration returns a structured result and diagnostic. Ship and include
each file independently. All guest source is ASCII.

### Step 2: Wire raw GLSL into HolyToy

Ship `.glsl` unchanged as `SHADER.GLS`. `HtLoadGlsl` compiles it in-task and
passes only generated HolyC to `HtRecompile`. Preserve the old shader on error.
Keep host-generated `SHADER.HC` solely as a temporary fallback when this first
slice rejects a wider fixture; emit distinct `HT GUEST GLSL OK/FAIL` markers so
proofs cannot confuse the paths.

### Step 3: Prove the vertical slice

Add proof 11: run `tests/glsl/gradient.glsl`, require `HT GUEST GLSL OK`, reject
the host `HT GLSL OK` marker, and validate a multi-color 640x288 viewport. The
slice parses `void mainImage(out vec4 fragColor, in vec2 fragCoord)` and scalar
arithmetic over numbers, `fragCoord.y`, and `iResolution.y`.

### Step 4: Add compatibility measurement

`tools/corpus_compat.py` scans the versioned GLSL fixtures, prints pass/fail and
unsupported-feature reasons, and inventories HolyC shader ABI declarations.
`tools/test_corpus_compat.py` prevents accidental overclaiming. Report the public
~99% goal separately from this smoke-corpus baseline.

### Step 5: Verify and document

Run Python/shell/ASCII checks, measurement, focused VM proof, and `make test`.
Update this section with literal evidence and leave unmet boxes unchecked.

## Test plan

- `python3 tools/test_corpus_compat.py`
- `python3 tools/corpus_compat.py`
- `python3 tools/test_glsl2hc.py`
- `bash -n tools/{mkxfer,run-common,test}.sh`
- ASCII scan of all new `.HC` files
- focused gradient VM run with guest-only marker
- `make test` ending `-- 11 passed, 0 failed --`

## Done criteria and proof evidence

- [x] Five explicit guest compiler modules exist and target `CHtFragColor`.
- [x] Raw `.glsl` is shipped as `SHADER.GLS`; generated HolyC remains internal
      to the successful guest path.
- [x] Measurement output on 2026-07-12:
      `GLSL guest-compiler compatibility: 1/3 (33.33%)`; gradient PASS;
      circle and plasma FAIL with unsupported-feature reasons. HolyC inventory:
      `2/13 files declare MainImage` (includes app and emitter source).
- [x] Measurement unit tests: 3 tests, `OK`.
- [x] Focused VM proof: in the Codex runner, attempted runs `verify-008-SeGODu`,
      `verify-008b-WCGIjB`, and `/tmp`-socket retry `verify-008c-PHMazH` all
      stopped before boot with QEMU `Failed to bind socket ... Operation not
      permitted` (environment failure). On the maintainer's host on 2026-07-12,
      run `test-20260712-184909-5383-guest-glsl` booted, compiled raw GLSL in
      the guest, and proof 11 printed
      `PASS: guest-glsl: raw GLSL compiled in guest and rendered (4 colors)`.
- [x] `make test` prints `-- 11 passed, 0 failed --`: the Codex runner could
      not execute VMs (host lock preflight passed, every VM exited 2 before
      boot, `-- 0 passed, 11 failed --`), but the maintainer-host run on
      2026-07-12 (runs `test-20260712-184656-5383-error` through
      `test-20260712-184909-5383-guest-glsl`) passed all proofs and ended
      `-- 11 passed, 0 failed --`.
- [x] Plan status changes to DONE only after both unchecked VM criteria pass —
      satisfied by the maintainer-host run above.

## STOP conditions

- Generated code changes the plan-007 ABI or performs palette quantization.
- A proof accepts the host fallback marker as guest compiler success.
- Unsupported fixtures are counted as compatible without guest compile/render.
- The guest compiler errors or faults and two source-backed fixes do not resolve it.
- QEMU cannot start in the execution environment: record the exact failure and
  leave VM criteria/status incomplete rather than manufacturing evidence.

## Maintenance notes

The 33.33% number is only a seed baseline. Next work must add a pinned public
corpus and foundational GLSL semantics, then distinguish compile, run, visual,
and missing-input results. The temporary host fallback must shrink as guest
coverage grows and cannot contribute to the guest compatibility numerator.
