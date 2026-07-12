# holytoy: a Shadertoy clone *inside* TempleOS

Status: **spec for the first version.** This is not a someday/stretch
document — everything below is what v1, the first real release, contains.
What exists today is the dev harness (README.md): host-driven
edit→inject→boot→screenshot cycles, which is the proof loop we build the
app with, not the product.

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

**Amendment (2026-07-12, per the user):** the input box takes **ONLY
GLSL** — the temporary HolyC `MainImage` dialect (step 1) is development
scaffolding, never a product mode. The compatibility target grows beyond
the minimal subset above: **most Shadertoy fragment shaders should run**
(no textures/buffers, and simplifications where the 16-color output
demands them). The 16-color gamut is bridged with **Bayer ordered
dithering** (a deterministic threshold matrix, testable via screendump —
preferred over the random `ROPF_PROBABILITY_DITHER`).

Where it runs: **in the guest — the v1 input box takes GLSL directly.**
A host-side Python prototype (`tools/glsl2hc.py`) comes first purely as a
development vehicle (fast iteration on the emitter, testable against the
harness before the app exists), then the emitter is ported to HolyC and
embedded in the app. The GLSL subset above is chosen small precisely so
the in-guest port is realistic.

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

### 4. Build order (all of it is v1 — this is not a multi-release roadmap)

**Ground rules (per the user):**
- The first thing we iterate on already has the final form: the
  in-TempleOS app — input box + live viewport, edit → recompile → pixels
  change. Nothing ships as "host pipeline now, app later".
- GLSL input, the transpiler and the fast-math floor are **in scope for
  the first version**, not follow-ups. The steps below are engineering
  order within v1 (days-to-weeks of iteration), each step demo-able.

| step | deliverable |
|------|-------------|
| 1 | **HolyToy app skeleton in the guest**: split window — editable code box (DolDoc edit control) + animating viewport task. Recompile-on-change via `ExePutS2`; compile errors render inline in the code pane, never crash the app. Temporary shader dialect: HolyC `MainImage` ABI (§2), so the app is exercisable before the transpiler lands. |
| 2 | perf floor: LUT/fixed-point math lib, render-scale viewport, ms/frame readout |
| 3 | GLSL in the input box: transpiler prototyped host-side (`glsl2hc.py`) for fast iteration, then embedded so the guest compiles GLSL without host help; Shadertoy uniforms incl. real `iMouse` |
| 4 | polish to call it v1: palette-cycling/dithering modes, a few bundled example shaders, shader load/save on the transfer disk |

The existing harness (README) stays the outer proof loop for every step:
each lands with `make test` proofs driven by screendumps + `scrtext.py`
(e.g. "editor shows typed source", "viewport animates ≥N distinct frames",
"syntax error appears in the code pane and app survives", "LUT sin max
error < ε").

## Open questions (decide when we get there)

- Fixed-point format: 16.16 vs 10.22 vs per-op choice; needs profiling
  under both TCG and KVM before committing.
- Viewport presentation: `draw_it` callback redrawing a cached bitmap vs
  blitting into a `CDC` sprite; whichever survives window drag cheaper.
- ~~Whether Stage E (in-guest GLSL) is worth it vs polishing the HolyC
  shader dialect~~ — **resolved 2026-07-12: GLSL only.** The input box
  takes GLSL exclusively; the HolyC dialect never ships (see the
  amendment in §1).
