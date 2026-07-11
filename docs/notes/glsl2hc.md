# glsl2hc v0 — coverage notes (plan 004)

`tools/glsl2hc.py` transpiles the Shadertoy-subset GLSL of
docs/VISION.md:45-51 to HolyC against the plan-004 shader ABI
(`CHtUniforms` + `U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)`).
Unit tests: `python3 tools/test_glsl2hc.py` (50 tests, no VM). All three
fixtures in `tests/glsl/` were proven end-to-end on real TempleOS via
`--runner static` (2026-07-11: gradient 640x480x16 colors, circle disc,
plasma 11 colors; all exit 0).

## Feature coverage vs the VISION.md subset

| Subset item (VISION.md:45-51) | v0 status |
|---|---|
| `float` / `int` / `bool` | supported (`F64` / `I64` / `Bool`) |
| `vec2/vec3/vec4` | supported — fully scalarized to per-component `F64` locals |
| swizzles (`p.xy`, `c.rgb`, also `stpq`) | supported, read and write; writes are aliasing-safe (`p.xy = p.yx` copies through temps); repeated components on the left rejected (GLSL rule) |
| arithmetic incl. componentwise vector ops | supported: `+ - * /` scalar/vec-vec/vec-scalar broadcast; `%` int-only; every emitted expression is fully parenthesized so HolyC's non-C precedence (and comparison chaining) can never bite |
| `mat2` | **deferred** (plan 004 "deferred explicitly"); recognized and rejected with a diagnostic |
| `sin cos tan sqrt exp floor` | supported -> `Sin Cos Tan Sqrt Exp Floor`, componentwise on vecs |
| `atan` | supported: 1-arg -> `ATan(x)`; 2-arg `atan(y,x)` -> `Arg(x,y)` (FPATAN, quadrant-aware; note the argument swap) |
| `log` | supported -> `Ln` (natural log, as GLSL) |
| `pow` | supported -> `Pow` |
| `fract mod mix step smoothstep` | supported via emitted F64 helpers `HtFract HtMod HtMix HtStep HtSmooth` (emitted only when used) |
| `min max clamp abs sign` | supported -> `Min Max Clamp Abs Sign`; all-int calls use `MinI64 MaxI64 ClampI64 AbsI64 SignI64` |
| `length normalize dot cross` | supported, scalarized inline (`Sqrt` of component sums etc.); `cross` is vec3-only |
| `if / for / while` | supported (+ `break`); `for` with non-trivial condition/increment lowers to a `while (TRUE)` form |
| function definitions | supported; `in` (value) parameters only; vec-returning functions use an out-pointer protocol (`U0 f(F64 *ht_ret_x,...,args)`) invisible to GLSL code |
| no textures/buffers | enforced — `texture2D`/samplers/arrays rejected with diagnostics |

## Rejected with diagnostics (out of subset or deferred)

`continue` (HolyC has no continue), `discard`, ternary `?:`, logical `^^`,
bitwise `& | ^ ~`, arrays and indexing, `struct`, preprocessor directives,
global variables (incl. `const` globals), `uniform` declarations, precision
qualifiers, `out`/`inout` parameters on user functions (only `mainImage`'s
`out vec4` is special-cased), `mat2/mat3/mat4`, int/uint vector types.
Diagnostics carry `file:line:`; the emitter refuses instead of guessing.

## Semantic deviations from GLSL/Shadertoy

- All math is F64 (fixed-point is plan 003's turf).
- `fragCoord` matches `gl_FragCoord`: origin bottom-left (the emitter flips
  TempleOS's top-down y), pixel centers at `+0.5`.
- Implicit `int -> float` promotion is allowed in arithmetic, calls,
  assignment and initialization (strict GLSL ES forbids it).
- Uniforms are exactly `iTime` (float), `iResolution` (vec3, z=1.0),
  `iMouse` (vec4, zw=0.0), `iFrame` (int). They are emitted as `ht_*`
  globals refreshed at `MainImage` entry, so user functions can read them.
  The static runner supplies iTime=0, iFrame=0, iMouse=0 (`iMouse`-driven
  shaders run live in the app, where the harness can move the real mouse:
  `tools/qmp.py ... mouse-to X Y`).
- `mod()` uses GLSL floor semantics (`a-b*Floor(a/b)`), not C `fmod`.
- The static runner quantizes `fragColor` to a 16-step grayscale palette by
  luminance (`0.299r+0.587g+0.114b -> 0..15`); palette-fitting color
  quantization is deferred.
- Pure expression statements ("`p.x;`") are rejected as having no effect.
- User identifiers that collide with HolyC keywords/kernel symbols
  (e.g. `pi`, or `x`/`u` inside mainImage) are deterministically renamed.

## Emitted preamble = the in-guest port surface

The in-guest HolyC port (VISION step 3, second half) must reproduce, in
HolyC, exactly:

1. the `CHtUniforms` class and the four `ht_i*` uniform globals;
2. the five scalar helpers `HtFract HtMod HtMix HtStep HtSmooth`
   (everything else maps to kernel intrinsics/externs: `Sin Cos Tan ATan
   Arg Sqrt Pow Exp Ln Floor Abs Sign Min Max Clamp ToI64 ToF64` + the
   `*I64` int variants);
3. the transpiler itself: lexer, recursive-descent parser, and the
   scalarizing emitter (vec values -> per-component F64 locals + temps,
   vec returns -> out-pointers). It is a single pass, string-based, no
   optimization — realistic to port with `CatPrint`/`StrPrint` into a
   buffer handed to `ExePutS2`.

Every helper added to the preamble is future port surface — keep it small.

## Harness integration status (plan 006)

- `make test` now covers the transpiler end to end: a host-only preflight
  runs the 50 unit tests (exit 2 on failure, no VM cost), proof 7 renders
  `tests/glsl/gradient.glsl` standalone via `--runner static`
  (640x480, >=8 colors), and proof 8 drives `tests/glsl/plasma.glsl`
  through the `.glsl` app path (`HT GLSL OK` + >=3 distinct trailing
  frames). `circle.glsl` stays manual-only — redundant coverage, one VM
  cycle saved.
- `--runner none` output has an in-repo consumer: `tools/run.sh` and
  `tools/gui.sh` accept a `.glsl` SRC, transpile it to `RUN_DIR/shader.HC`
  (`holy_prepare_glsl`, tools/run-common.sh), and ship it as
  `E:/SHADER.HC`; `src/holytoy/HT.HC` reads and compiles it at startup
  through the same `HtRecompile` path used for live edits (verbatim
  injection, no transpiler changes — VM-probed JIT redefinition).
- `--runner static` output still runs standalone under `make run` (one
  static frame, draw_it blit, `--scale 4` default -> 160x120 MainImage
  evaluations).
- The host `.glsl` pipeline is dev tooling and the proof mechanism, not
  the shipped product surface — the v1 input box takes GLSL directly in
  the guest (docs/VISION.md); the in-guest transpiler port is plan 007.
