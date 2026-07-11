# holytoy vision: a Shadertoy clone *inside* TempleOS

Status: **design target, not implemented.** What exists today is the dev
harness (README.md): host-driven edit→inject→boot→screenshot cycles.
This document is the shape the project is heading toward.

## Target UX

The user boots TempleOS (or `make gui`) and opens **HolyToy**, a single
program with the classic Shadertoy layout:

```
┌──────────────────────────────────────────────┐
│                viewport                      │
│        (fragment shader output,              │
│         animating live)                      │
├──────────────────────────────────────────────┤
│ code input box                               │
│   void mainImage(out vec4 fragColor,         │
│                  in vec2 fragCoord) { ... }  │
│                                              │
│ [compile-on-change; errors shown inline]     │
└──────────────────────────────────────────────┘
```

- Edit code in the input box → output updates directly in the viewport.
- **Fragment shaders only** (per-pixel function of coordinates + time),
  Shadertoy conventions: `mainImage(fragColor, fragCoord)` plus the
  standard uniforms (`iTime`, `iResolution`, `iMouse`, `iFrame`).
- Compile errors don't crash the app — they render in the code pane
  (the harness already proved catchable compiler errors via `ExeFile2`
  after `RLf_ADAM_SERVER`).

## The pieces

### 1. GLSL → HolyC transpiler

Users write GLSL; a transpiler emits HolyC that TempleOS's JIT compiles
on the spot. TempleOS is uniquely suited to this: `ExePutS2()` compiles a
string in-task in milliseconds, and redefining a function rebinds it for
the next frame — live reload is *native*.

Scope (deliberately small — Shadertoy-subset GLSL, not the spec):
- types `float/vec2/vec3/vec4/int/bool` + swizzles (`p.xy`, `c.rgb`)
- arithmetic incl. componentwise vector ops, `mat2` at most
- builtins: `sin cos tan atan sqrt pow exp log floor fract mod min max
  clamp mix step smoothstep length normalize dot cross abs sign`
- control flow: `if/for/while`, function definitions
- no textures/buffers initially (Stage E adds a channel0 sampler maybe)

Where it runs — two phases:
1. **Host-side first** (Python, `tools/glsl2hc.py`): `src/*.glsl` becomes
   `.HC` during `make run`/`make watch`. Cheap to build, testable with the
   existing harness, no guest constraints.
2. **In-guest later**: port the emitter to HolyC so the input box takes
   GLSL directly. (Fallback if that's unreasonable: the in-guest input box
   speaks HolyC-with-shader-ABI, and GLSL stays a host-side convenience.)

### 2. Shader ABI in HolyC

The transpiler targets a stable per-pixel contract, roughly:

```holyc
class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
U0 MainImage(CHtUniforms *u, I64 x, I64 y, U8 *out_color);  // one pixel
```

The runner owns the render loop: iterate the viewport, call `MainImage`,
write pixels, present. User code never touches windows/DCs — that's what
makes the input box safe.

### 3. Fast math (the hard constraint)

Measured reality: 640×480 = 307k pixels; QEMU TCG on WSL2 (no KVM), and
per-pixel F64 transcendentals won't hit interactive rates. The plan:

- **Lookup tables**: `sin/cos/atan2/sqrt` as I64 fixed-point LUTs
  (e.g. 1024–4096 entries, 16.16 or 10.22 fixed point), generated once at
  startup. GLSL floats transpile to fixed-point ops where profiling says
  it matters; F64 stays the fallback for correctness.
- **Resolution scaling**: shade at 160×120 (19k calls/frame) and
  block-copy 4×4, Shadertoy-style "render scale". Full-res available for
  stills/screenshots.
- **Palette tricks as a first-class citizen**: the screen is 16 colors,
  but the 16 palette registers are 48-bit RGB and settable per frame
  (`GrPaletteColorSet(I64 color_num, CBGR48)`, `GrPaletteSet` —
  Adam/Gr/GrPalette.HC). Palette cycling animates the whole screen for
  the cost of 16 writes — many classic demoscene effects (plasma, fire,
  tunnels) want exactly this. Add ordered dithering (or the built-in
  `ROPF_PROBABILITY_DITHER`) to fake gradients beyond 16 colors.
- Frame budget telemetry in the viewport (ms/frame), so slow shaders are
  visible, not mysterious.

### 4. Staging

| stage | deliverable | builds on |
|-------|-------------|-----------|
| A ✅ | host harness: inject/run/screenshot/errors | done (README) |
| B | shader ABI + render loop + LUT math lib in `guest/`, toys written as `MainImage` in HolyC | A |
| C | host-side `glsl2hc.py`; `make run SRC=src/foo.glsl` just works; golden-image tests for the builtin library | B |
| D | in-guest HolyToy app: editor pane (DolDoc edit control) + viewport task, recompile-on-save via `ExePutS2`, inline errors | B |
| E | GLSL input directly in-guest (transpiler ported to HolyC), uniforms `iMouse` from real mouse, maybe channel0 texture | C+D |

The harness stays the outer loop through all stages: every stage lands
with `make test` proofs (e.g. "transpiled plasma renders ≥N distinct
colors", "LUT sin max error < ε", "editor survives a syntax error").

## Open questions (decide when we get there)

- Fixed-point format: 16.16 vs 10.22 vs per-op choice; needs profiling
  under both TCG and KVM before committing.
- Viewport presentation: `draw_it` callback redrawing a cached bitmap vs
  blitting into a `CDC` sprite; whichever survives window drag cheaper.
- Whether Stage E (in-guest GLSL) is worth it vs polishing the HolyC
  shader dialect — revisit after Stage D exists.
