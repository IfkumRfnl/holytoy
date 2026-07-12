# Plan 007: RGBA shader ABI, renderer-owned quantization (`HTRENDER.HC`), Bayer ordered dithering

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 27720e9..HEAD -- src/holytoy/ tools/ tests/ guest/ docs/ README.md AGENTS.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M/L (one guest-side workstream + a small emitter retarget)
- **Risk**: MED (per-pixel quantization cost under TCG; mitigation in step 3)
- **Depends on**: plans/006-glsl-app-integration.md (DONE, merged at `345aef8`)
- **Category**: direction
- **Planned at**: commit `27720e9`, 2026-07-12

## Why this matters

AGENTS.md "Product direction (authoritative)" makes HolyToy a
Shadertoy-compatible app whose compiler must know nothing about the
16-color display. The current ABI bakes palette quantization into every
shader (`src/holytoy/HT.HC:22`):

```holyc
U0 (*ht_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);   // out = palette index
```

That is wrong for GLSL semantics: `mainImage` writes a float RGBA
`fragColor`, period. Every emitted shader currently ends with a
luminance-to-16 hack, and the promised Bayer ordered dithering
(docs/VISION.md §1 amendment) has nowhere to live because no single
component owns color. This plan flips ownership:

- **shader**: fragment coordinates + uniforms → RGBA (`CHtFragColor`)
- **renderer** (`HTRENDER.HC`, new): RGBA + screen position → TempleOS
  palette index, via a nearest-color LUT plus a deterministic 4x4 Bayer
  threshold matrix

This is the ABI the in-guest GLSL compiler (plan 008+) will emit against.
Landing it before any compiler work means the ABI breaks exactly once.
Since `CHtUniforms` is unfrozen here anyway, the iMouse button fields
deferred by plan 006 ride along (one break, not two).

**Decided tradeoffs to honor** (do not re-litigate):

- Dithering is **Bayer ordered** — a deterministic threshold matrix,
  testable via screendump. NOT `ROPF_PROBABILITY_DITHER`, NOT
  error-diffusion (stateful, order-dependent, untestable per-pixel).
- The renderer owns clamping, the Y-flip, pixel-center coordinates,
  palette choice, and dithering. Emitted shader code contains **none** of
  these (delete them from the emitter; do not keep both paths).
- `tools/glsl2hc.py` gets the **minimum focused diff** to keep the
  transitional host-injection pipeline green (AGENTS.md: little further
  use of it is expected). Only the `--runner none` ABI surface changes.
  `--runner static` (standalone runner, own display path) is untouched.
- Alpha is carried in the ABI but ignored by the renderer (Shadertoy
  ignores it too).
- Expect full-resolution F64 shading to stay slow (docs/notes/perf-floor.md:
  272 ms/frame pure-F64 at 640x480). Correct semantics first; adaptive
  render scale is the perf tool. Do NOT "fix" perf by re-baking
  quantization into shaders.

## Current state

Files and roles (all line numbers at `27720e9`):

- `src/holytoy/HT.HC` (325 lines) — the app. Key excerpts:

```holyc
// HT.HC:19-22 — the ABI to replace
class CHtUniforms { F64 i_time; I64 i_frame; I64 res_x,res_y; I64 mouse_x,mouse_y; };
CHtUniforms ht_u;
U0 (*ht_fp)(CHtUniforms *u,I64 x,I64 y,U8 *out_color);

// HT.HC:30-64 — ht_src1/ht_src2/ht_src3/ht_bad sample sources (strings),
// each a MainImage with the old signature ending in a 0-15 palette store.
// HT.HC:66-74 — the compiled built-in MainImage (same text as ht_src1).

// HT.HC:123 — U0 (*ht_new_fp)(...old signature...);
// HT.HC:125-163 — HtRecompile(src): appends "\nht_new_fp=&MainImage;\n",
// ExePutS2 under try/catch, rebinds ht_fp only on success.

// HT.HC:181-200 — HtDrawIt shading loop: one ht_fp call per 4x4 block,
// c&=15, then 16 raw dc->body pokes of the same index:
  if (ht_fp) {
    for (by=0;by<nby;by++) {
      for (bx=0;bx<nbx;bx++) {
        c=0;
        ht_fp(&ht_u,bx*HT_SCALE,by*HT_SCALE,&c);
        c&=15;
        ...
              p=&dc->body[sy*stride+sx0];
              for (j=0;j<HT_SCALE;j++)
                p[j]=c;

// HT.HC:225-262 — HtSelfTest: markers HT SWAP OK / HT IDENT OK /
// HT ERRSURVIVE OK / HT RECOVER OK / HT MATH OK, then parks on ht_bad.
// HT.HC:310-325 — startup: HTMInit; draw_it; HtLoadShader(); GUI/headless split.
```

- `src/holytoy/HTMATH.HC` (65 lines) — LUT sin/cos, consumed via
  `#include "E:/HTMATH.HC"` (HT.HC:10). `HTRENDER.HC` follows the same
  ship-always + include pattern.
- `tools/glsl2hc.py` — the `--runner none` emitter currently emits (tail
  of every shader; measured at `27720e9` on tests/glsl/gradient.glsl):

```holyc
class CHtUniforms { ... same fields as HT.HC ... };
F64 ht_iTime; I64 ht_iFrame;
F64 ht_iRes_x,ht_iRes_y,ht_iRes_z;
F64 ht_iMouse_x,ht_iMouse_y,ht_iMouse_z,ht_iMouse_w;

U0 MainImage(CHtUniforms *u,I64 x,I64 y,U8 *out_color)
{
  ...
  ht_iMouse_z=0.0;              // zw hardcoded 0 (006's documented deviation)
  ht_iMouse_w=0.0;
  fragCoord_x=x+0.5;            // pixel-center + Y-flip done IN the shader
  fragCoord_y=u->res_y-y-0.5;
  ...user shader body...
  ht_lum=Clamp(0.299*fragColor_x+0.587*fragColor_y+0.114*fragColor_z,0.0,1.0);
  *out_color=ClampI64(ToI64(ht_lum*16.0),0,15);   // the hack this plan deletes
}
```

- `tools/test_glsl2hc.py` — 50 unit tests, exit 0, prints `OK`. Some
  assert the emitted tail/signature above; those assertions move with the
  ABI.
- `tools/mkxfer.sh` — copies `HTMATH.HC` always; the block to extend:

```bash
mcopy -o "$ROOT/src/holytoy/HTMATH.HC" x:/HTMATH.HC
```

- `tools/test.sh` — 9 proofs (`smoke gradient error animate parallel
  holytoy glsl-static glsl-app mouse`), unit-test preflight, ends
  `-- N passed, M failed --`. Proof 6 greps HT.HC self-test markers;
  proof 8 runs `tests/glsl/plasma.glsl` through the app path.
- `tools/imginfo.py` — prints `WIDTH HEIGHT DISTINCT_COLORS` for a PNG.
- `tests/glsl/gradient.glsl` — time-independent vertical luminance ramp
  (`fragColor` = uv.y gray). Perfect dither/determinism fixture.
- Palette ground truth: `vendor/TempleOS/Adam/Gr/GrPalette.HC:64-68`
  `gr_palette_std[16]` (CBGR48, U16 per channel — 0x0000/0x5555/0xAAAA/0xFFFF
  component values; `GrPaletteColorSet` feeds the top 6 bits to the VGA
  DAC). The four pure grays are indices 0 (BLACK, 0x000000), 8 (DKGRAY,
  0x555555), 7 (LTGRAY, 0xAAAAAA), 15 (WHITE, 0xFFFFFF).
- Shadertoy semantics for reference: `fragCoord` is pixel-centered,
  origin **bottom-left** (range 0.5 .. res-0.5); `iMouse.xy` = current
  drag position, `iMouse.zw` = click position, negated while the button
  is up.

Harness facts (same as plan 006 — abbreviated):

- Reserve a run dir: `RD="$(mktemp -d "$PWD/out/runs/verify-007-XXXXXX")"; RUN_DIR="$RD" tools/run.sh FILE`
  (fresh `$RD` per run). Exit 0 guest OK / 1 guest error / 2 harness.
- `$RD/screen.txt` = OCR of final frame; `$RD/frames/frame-*.png` =
  rolling dumps; `python3 tools/scrtext.py PNG --grep STR` exits 0 iff
  STR on screen.
- ASCII only in guest sources; transfer-disk names are UPPERCASE 8.3
  (`HTRENDER.HC` is valid).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Transpiler unit tests (no VM) | `python3 tools/test_glsl2hc.py` | `OK`, exit 0 |
| Transpile for the app | `python3 tools/glsl2hc.py tests/glsl/gradient.glsl --runner none -o "$RD/shader.HC"` | exit 0 |
| One VM cycle (~20-30 s) | fresh `$RD`; `RUN_DIR="$RD" tools/run.sh SRC` | exit 0 |
| GLSL through the app | fresh `$RD`; `RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl` | exit 0, `HT GLSL OK` in `$RD/guest.log` |
| Screenshot facts | `python3 tools/imginfo.py "$RD/latest.png"` | `640 480 N` |
| Full proof suite | `make test` | `-- 10 passed, 0 failed --` (after step 6) |
| Shell/Python syntax | `bash -n tools/test.sh`; `python3 -c "import ast; ast.parse(open('tools/imginfo.py').read())"` | silent |

## Suggested executor toolkit

- Read `skills/holyc/SKILL.md` before writing any HolyC: no `float` (use
  `F64`), print-statement idiom `"%d\n",x;`, no `%f` in guest code, pure
  ASCII sources.
- Answer HolyC/TempleOS questions from `vendor/TempleOS` source (strip
  DolDoc first: `python3 skills/holyc/scripts/strip_doldoc.py FILE`),
  never from memory. Palette: `vendor/TempleOS/Adam/Gr/GrPalette.HC:64`.
- `src/holytoy/HTMATH.HC` is the model for a small include library with
  an `*Init` entry point and a header comment stating its contract.

## Scope

**In scope** (the only files you may create or modify):

- `src/holytoy/HTRENDER.HC` — NEW: palette table, nearest-color LUT,
  Bayer matrix, `HtQuantize`, `HTRInit`
- `src/holytoy/HT.HC` — new ABI, sample shaders rewritten, quantizing
  draw loop, click tracking, self-test additions
- `tools/glsl2hc.py` — `--runner none` ABI retarget ONLY (signature,
  uniforms class text, fragCoord passthrough, RGBA store, iMouse zw)
- `tools/test_glsl2hc.py` — update assertions the retarget touches
- `tools/mkxfer.sh` — ship `HTRENDER.HC` always
- `tools/imginfo.py` — add `--crop X,Y,WxH` and `--hash`
- `tools/test.sh` — extend proof 6; add proof 10 (dither)
- Docs: `README.md`, `AGENTS.md`, `docs/notes/step1-skeleton.md`,
  `plans/README.md`

**Out of scope** (do NOT touch):

- The in-guest GLSL compiler, GLSL-only editor switch, corpus tooling —
  plans 008+.
- `--runner static` emitter path and proof 7 — standalone demo path,
  unaffected.
- `src/holytoy/HTMATH.HC`, `src/bench-math.HC`, `guest/RUN.HC`,
  `guest/ONCE.HC`, `tests/glsl/*.glsl`, `tools/qmp.py`.
- `skills/`, `vendor/` — maintained elsewhere.
- Perf work beyond the integer inner loop specified in step 3 (no LUT
  sin/cos emission, no `Sqrt` LUT — later plans).

## Git workflow

- Branch: `advisor/007-rgba-renderer-dither`
- Commit per step, short imperative sentence (match `git log`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 0: record the perf baseline

Fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC` → exit 0.
Record the readout from `grep -oE "HolyToy +[0-9]+ms" "$RD/screen.txt"`
(the built-in plasma at HT_SCALE=4). Save the number in your notes — the
step 3 verification compares against it.

### Step 1: HTRENDER.HC — the quantizer library

Create `src/holytoy/HTRENDER.HC` (ASCII; model the header-comment style
and `*Init` pattern on HTMATH.HC):

1. Palette table: sixteen `F64 r,g,b` triples transcribed from
   `gr_palette_std` (vendor/TempleOS/Adam/Gr/GrPalette.HC:64-68; each
   U16 component / 65535.0 — cite the vendor location in a comment).
2. Bayer 4x4 threshold matrix (the classic index matrix):

```
 0  8  2 10
12  4 14  6
 3 11  1  9
15  7 13  5
```

   Per cell the signed threshold is `((m+0.5)/16.0-0.5)*HTR_SPREAD`, with
   `#define HTR_SPREAD 0.18` (see verification for the allowed tuning
   range).
3. Nearest-color LUT: `U8 htr_lut[32768]` (5 bits per channel), built
   once by `HTRInit` — for each (r5,g5,b5) find the palette index with
   minimum squared RGB distance (channel value = `c5/31.0`). ~32768*16
   F64 evaluations, one-time at startup; fine under TCG.
4. The hot entry point — integer inner-loop friendly:

```holyc
I64 htr_bofs[16];  //premultiplied Bayer offsets in 8.8 fixed point, HTRInit fills

U8 HtQuantize(I64 r88,I64 g88,I64 b88,I64 sx,I64 sy)
{//RGBA (8.8 fixed, 0..0x100 = 0..1.0) + SCREEN position -> palette index.
 //Deterministic: same inputs, same output. Screen coords pick the Bayer cell.
  I64 o=htr_bofs[(sy&3)*4+(sx&3)],r5,g5,b5;
  r5=ClampI64((r88+o)*31>>8,0,31);
  g5=ClampI64((g88+o)*31>>8,0,31);
  b5=ClampI64((b88+o)*31>>8,0,31);
  return htr_lut[r5<<10+g5<<5+b5];
}
```

   (Adjust operator precedence/shift idioms to what HolyC actually
   accepts — verify against skills/holyc/SKILL.md; the semantics above
   are the contract. The F64→8.8 conversion happens once per block in
   HT.HC, not here.)
5. `HTRInit` builds `htr_lut` and `htr_bofs`.

**Verify**: `LC_ALL=C grep -P '[^\x00-\x7F]' src/holytoy/HTRENDER.HC` →
no output. Full behavior is verified in guest via step 4's self-test.

### Step 2: mkxfer.sh — ship HTRENDER.HC always

Next to the existing `HTMATH.HC` copy:

```bash
mcopy -o "$ROOT/src/holytoy/HTRENDER.HC" x:/HTRENDER.HC
```

**Verify**: `bash -n tools/mkxfer.sh` → silent;
`tools/mkxfer.sh /tmp/x7.img src/gradient.HC && MTOOLSRC=/tmp/mtools.conf mdir x:/`
→ listing shows `HTRENDER.HC`. Remove `/tmp/x7.img /tmp/mtools.conf`.

### Step 3: HT.HC — the new ABI and the quantizing draw loop

All in `src/holytoy/HT.HC` (pure ASCII):

1. `#include "E:/HTRENDER.HC"` after the HTMATH include; `HTRInit;` in
   the startup block before `Fs->draw_it=&HtDrawIt;`.
2. Replace the ABI:

```holyc
class CHtFragColor { F64 r,g,b,a; };
class CHtUniforms
{
  F64 i_time;
  I64 i_frame;
  I64 res_x,res_y;
  I64 mouse_x,mouse_y;   //current position, viewport px, Y-DOWN (raw)
  I64 mouse_lb;          //1 while left button held
  I64 click_x,click_y;   //viewport px of last lb press, Y-DOWN; -1 = never
};
U0 (*ht_fp)(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color);
```

   Update `ht_new_fp` (HT.HC:123) to the same type. Initialize
   `click_x=click_y=-1` at startup. In `HtDrawIt`'s uniform refresh, set
   `ht_u.mouse_lb=ms.lb;` and on a rising edge (lb now, not before)
   latch `click_x/click_y` from the current position. Y-flips for GLSL
   happen in the EMITTER's uniform mapping (step 5), not here — the ABI
   carries raw Y-down viewport coords, documented in the class comment.
3. Rewrite the draw loop. Per block: one `ht_fp` call at the block
   center in GLSL coordinates, then convert to 8.8 once and dither each
   screen pixel:

```holyc
CHtFragColor fc;
...
        fc.r=0;fc.g=0;fc.b=0;fc.a=0;
        ht_fp(&ht_u,bx*HT_SCALE+HT_SCALE*0.5,
              vh-(by*HT_SCALE+HT_SCALE*0.5),&fc);   //pixel-center, Y-UP
        r88=ClampI64(ToI64(fc.r*256.0),0,256);       //F64->8.8, once per block
        g88=...; b88=...;
        for each pixel (sx,sy) of the block:
          p[j]=HtQuantize(r88,g88,b88,sx0+j,sy);
```

   At HT_SCALE=1 the fragCoord formula degenerates to the exact
   Shadertoy pixel center — state that in a comment. The `ht_shade_ms`
   brackets stay around the whole loop (shader + quantize are both
   "shading work").
4. Rewrite `ht_src1`, `ht_src2`, `ht_src3`, `ht_bad`, and the compiled
   built-in `MainImage` to the new signature, producing RGBA. Model
   (sample 1 — keep the plasma character, colors welcome):

```holyc
U8 *ht_src1=
"U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)\n"
"{//sample 1: plasma bands\n"
"  F64 t=u->i_time,v;\n"
"  v=Sin(frag_x*0.021+t)+\n"
"    Sin(frag_y*0.032-t*0.7)+\n"
"    Sin((frag_x+frag_y)*0.014+t*0.5)+\n"
"    Sin(Sqrt(frag_x*frag_x+frag_y*frag_y)*0.019-t*1.3);\n"
"  out_color->r=0.5+v*0.125;\n"
"  out_color->g=0.5-v*0.125;\n"
"  out_color->b=0.75+v*0.0625;\n"
"  out_color->a=1.0;\n"
"}\n";
```

   `ht_src3` keeps its HTMATH LUT-sine body but maps the ±0x40000 sum to
   F64 rgb (e.g. `out_color->r=(v+0x40000)/0x80000.0;` — mind HolyC
   literal syntax). `ht_bad` keeps a deliberate syntax error under the
   new signature. Update the pane header string only if you change the
   key hints (you shouldn't).
5. Self-test addition in `HtSelfTest`, after `HT MATH OK` and before the
   final park — exact, deterministic assertions on the quantizer:

```holyc
//HT DITHER OK iff: pure black and pure white are position-independent
//and exact; a mid-gray varies across the Bayer tile (dither is alive).
I64 dx,dy,n=0,first=-1;
Bool mono=TRUE,vary=FALSE;
for (dy=0;dy<4;dy++)
  for (dx=0;dx<4;dx++) {
    if (HtQuantize(0,0,0,dx,dy)!=BLACK || HtQuantize(256,256,256,dx,dy)!=WHITE)
      mono=FALSE;
    n=HtQuantize(128,128,128,dx,dy);
    if (first<0) first=n;
    else if (n!=first) vary=TRUE;
  }
if (mono && vary)
  "HT DITHER OK\n";
else
  "HT DITHER FAIL\n";
```

**Verify**: fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC` →
exit 0; all of `HT SWAP OK`, `HT IDENT OK`, `HT ERRSURVIVE OK`,
`HT RECOVER OK`, `HT MATH OK`, `HT DITHER OK` in `$RD/guest.log`;
`grep -E "HolyToy +[0-9]+ms" "$RD/screen.txt"` → present, and the ms
value is ≤ 2x the step 0 baseline. Trailing frames still animate:
`md5sum "$RD"/frames/frame-*.png | awk '{print $1}' | tail -6 | sort -u | wc -l` ≥ 3.

### Step 4: glsl2hc.py — retarget `--runner none` to the new ABI

The minimum focused diff (touch nothing `--runner static` uses
exclusively):

1. Emitted `class CHtUniforms` text: byte-for-byte the same fields as
   HT.HC step 3.2 (the app passes a pointer; field offsets must match).
   Also emit `class CHtFragColor { F64 r,g,b,a; };`.
2. Signature:
   `U0 MainImage(CHtUniforms *u,F64 frag_x,F64 frag_y,CHtFragColor *out_color)`.
3. fragCoord: `fragCoord_x=frag_x; fragCoord_y=frag_y;` — delete the
   pixel-center/Y-flip arithmetic (renderer owns it now).
4. iMouse mapping (Shadertoy convention, Y-flip here because the ABI is
   Y-down):

```holyc
ht_iMouse_x=u->mouse_x;
ht_iMouse_y=u->res_y-u->mouse_y;
if (u->click_x<0) {
  ht_iMouse_z=0.0; ht_iMouse_w=0.0;        //never clicked
} else if (u->mouse_lb) {
  ht_iMouse_z=u->click_x; ht_iMouse_w=u->res_y-u->click_y;
} else {
  ht_iMouse_z=-u->click_x; ht_iMouse_w=-(u->res_y-u->click_y);
}
```

5. Tail: delete `ht_lum`/`ClampI64` quantization; emit

```holyc
out_color->r=fragColor_x;
out_color->g=fragColor_y;
out_color->b=fragColor_z;
out_color->a=fragColor_w;
```

   No clamping — the renderer clamps.
6. Update `tools/test_glsl2hc.py`: fix the assertions the above breaks;
   add one asserting the emitted tail contains `out_color->r=` and does
   NOT contain `ht_lum` or `ClampI64`. Keep the suite green.

**Verify**: `python3 tools/test_glsl2hc.py` → `OK`, exit 0.
`python3 tools/glsl2hc.py tests/glsl/gradient.glsl --runner none -o /tmp/g7.HC`
→ exit 0, `grep -c "ht_lum" /tmp/g7.HC` → 0,
`grep -c "CHtFragColor" /tmp/g7.HC` → ≥2. Then the round trip: fresh
`$RD`; `RUN_DIR="$RD" tools/run.sh tests/glsl/plasma.glsl` → exit 0,
`HT GLSL OK` in `$RD/guest.log`, ≥3 distinct trailing frames (md5 idiom).

### Step 5: imginfo.py — crop and hash

Add two optional flags to `tools/imginfo.py` (keep the default output
`WIDTH HEIGHT DISTINCT` byte-identical when neither is given):

- `--crop X,Y,WxH` — operate on the cropped region (report its W H and
  its distinct color count).
- `--hash` — append the md5 hex digest of the (cropped) raw RGB bytes as
  a fourth field.

**Verify**:
`python3 tools/imginfo.py "$RD/latest.png"` (any prior run) → same
3-field format as before;
`python3 tools/imginfo.py "$RD/latest.png" --crop 0,0,640x288 --hash` →
`640 288 N <32 hex chars>`. Running it twice → identical output
(determinism of the tool itself).

### Step 6: test.sh — extend proof 6, add proof 10 (dither)

- Header comment: nine proofs → ten.
- **Proof 6 (holytoy)**: extend the marker grep chain with
  `grep -q "HT DITHER OK" "$RD/guest.log"`.
- **Proof 10 (dither)**: run `tests/glsl/gradient.glsl` through the app
  path (same invocation pattern as proof 8). The shader is
  time-independent, so the viewport must be pixel-identical across
  frames while the dither pattern varies across space. Pass iff ALL of:
  1. run exits 0 with `HT GLSL OK` in `guest.log`;
  2. determinism: the viewport crop hash
     (`imginfo.py PNG --crop 0,0,640x288 --hash`, 4th field) is
     IDENTICAL for the last two `frames/frame-*.png` (crop excludes the
     pane, whose ms readout may differ);
  3. dithering alive: some 640x8 horizontal band inside the ramp has ≥2
     distinct colors (`imginfo.py latest.png --crop 0,ROW,640x8`,
     scanning ROW over e.g. 96/144/192 and requiring at least one hit) —
     a solid-banded (undithered) ramp fails this;
  4. gamut sane: the full viewport crop has ≥4 distinct colors (the four
     grays at minimum) and ≤16.

**Verify**: `bash -n tools/test.sh` → silent; `make test` →
`-- 10 passed, 0 failed --`, twice in a row (guards timing flakes).

### Step 7: documentation sync

- `README.md` — **maintainer rule: pure product description; never
  mention plans, plan numbers, VISION steps, progress, or process.**
  Only: keep the "Proven by `make test`" list factually true (add the
  dither proof in the same plain style).
- `AGENTS.md` — proof count ("ten proofs"); document the RGBA
  ABI (`CHtFragColor`, renderer-owned quantization, `HTRENDER.HC`
  ships always) and the iMouse zw semantics in the appropriate
  operational sections. Do not touch the "Product direction" section.
- `docs/notes/step1-skeleton.md` — mark the palette-quantization item
  as moved to the renderer (RGBA ABI landed, plan 007).
- `plans/README.md` — status row for 007; note the ABI is now the one
  plan 008's guest compiler emits against (re-frozen until a plan
  explicitly unfreezes it).

**Verify**: `grep -rn "nine proofs" README.md AGENTS.md` → no stale
count; `git status` shows only in-scope files modified.

## Test plan

- Host-only: `python3 tools/test_glsl2hc.py` green; `bash -n` on touched
  scripts; `ast.parse` on touched Python; imginfo.py default output
  unchanged.
- VM proofs (all via `make test`): extended proof 6 (`HT DITHER OK` +
  existing markers + readout), proof 8 unchanged-but-must-stay-green
  (plasma animates through the new ABI end to end), new proof 10
  (deterministic dither on a static gradient).
- Manual, once: GUI sanity is NOT required (headless proofs suffice);
  corrupt-shader path already covered by proof 6's `ht_bad` park.
- `make test` → `-- 10 passed, 0 failed --`, twice consecutively.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `make test` exits 0 printing `-- 10 passed, 0 failed --`, twice
      consecutively
- [ ] `python3 tools/test_glsl2hc.py` exits 0
- [ ] fresh `$RD`; `RUN_DIR="$RD" tools/run.sh src/holytoy/HT.HC` → exit 0,
      all six `HT * OK` markers (SWAP, IDENT, ERRSURVIVE, RECOVER, MATH,
      DITHER) in `$RD/guest.log`
- [ ] fresh `$RD`; `RUN_DIR="$RD" tools/run.sh tests/glsl/gradient.glsl` →
      exit 0, `HT GLSL OK`, last two frame viewport-crop hashes identical
- [ ] `grep -rn "ht_lum\|out_color=ClampI64" tools/glsl2hc.py` → no
      luminance quantization left in the `--runner none` path
- [ ] `git diff 27720e9..HEAD --stat -- src/holytoy/HTMATH.HC src/bench-math.HC guest/ tests/glsl/ tools/qmp.py` → empty
- [ ] `LC_ALL=C grep -P '[^\x00-\x7F]' src/holytoy/HT.HC src/holytoy/HTRENDER.HC` → no output
- [ ] Shading readout (built-in sample, HT_SCALE=4) ≤ 2x the step 0
      baseline, evidenced by `screen.txt` from the done-criteria HT.HC run
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- A retargeted `--runner none` fixture fails to compile in the app
  (`HT GLSL FAIL`) and one focused fix attempt does not resolve it —
  report the emitted line and the guest compiler message.
- The shading readout exceeds 2x baseline after the integer inner loop of
  step 1.4 is in place — do NOT start optimizing further (no LUT rewrites,
  no scale changes); report the numbers.
- `HT DITHER FAIL` persists with `HTR_SPREAD` anywhere in [0.10, 0.30] —
  the palette-distance or Bayer assumptions are wrong; report the 16
  mid-gray indices the guest printed. Do not widen the assertion.
- Any pre-existing marker (`HT SWAP OK` … `HT MATH OK`) disappears after
  your edits — bisect your change; if two fix attempts fail, stop.
- Proof 10's determinism check fails intermittently (same source, two
  runs, different viewport hashes) — that suggests nondeterminism in the
  pipeline (timing-dependent uniforms leaking in, or a mid-write frame);
  report rather than loosening the check to "mostly equal".
- HolyC rejects a construct this plan's snippets assume (shift/precedence
  idioms, F64 member access through pointers in emitted strings) and the
  fix is not obvious from vendor source — report with the compiler error.

## Maintenance notes

- **Plan 008 (in-guest compiler skeleton + vertical slice) builds on
  this**: the guest compiler's emitter targets exactly this ABI; the
  renderer contract (`HtQuantize` inputs are unclamped RGBA + screen
  position) is what makes the compiler display-agnostic. Re-freeze the
  ABI after this plan lands.
- `HTR_SPREAD` is a taste constant; 0.18 is a starting point. Tuning it
  later only changes which palette pairs interleave — proof 10's checks
  are written to survive any value in the STOP-condition range.
- The 5-bit LUT quantizes the *post-dither* color; the Bayer offset
  (±0.09 ≈ ±2.8 LUT steps at spread 0.18) comfortably exceeds one LUT
  step (1/31), so dithering is not swallowed by LUT granularity.
- Deliberately deferred: adaptive render scale keybinding (HT_SCALE is
  still a compile-time constant), fixed-point `Sqrt` LUT, gamma-aware
  palette distance (linear-RGB distance is fine at 16 colors), GLSL-only
  editor switch, everything compiler.
