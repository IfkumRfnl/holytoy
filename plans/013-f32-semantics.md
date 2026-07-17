# Plan 013: F32 semantics — bit-reproducing llvmpipe to converge the hash shaders

Status: TODO. Depends on plan 011 (HTEMIT rewrite ordering); can run in
parallel with plan 012 (disjoint files except small HT.HC knob edits —
rebase after 012 merges). Designed 2026-07-17 by an Opus 4.8 design
agent; probes `run-20260717-152012-ZP15Ou` (F32 rounding primitives:
x87 round-trip RNE-correct incl. subnormals; integer bit-twiddle correct
on 1.15M normal-range values, denormal branch has a KNOWN BUG to fix)
plus a host replica of gallivm's Cephes-F32 sine proving that only
bit-reproduction — not accuracy — converges the hash idiom.

Core insight (why the exact-sin spike failed): llvmpipe's F32 sine is
deliberately lossy (error grows to 1.63e-6 at x~78) and the hash gain
(~5e4) turns that into >tolerance divergence from ANY accurate sine.
docs/notes/exact-sin-spike.md records the failed alternative.

STOP conditions: never regenerate tests/corpus-visual refs to match the
guest (the oracle is the contract); if the 6 spatial-hash shaders do
not converge after sin bit-reproduction, investigate the dot/normalize
FMA open question (design Risks) before widening scope; the 5
Monte-Carlo tracers are allowed to stay FAIL (document, propose the
distribution-metric follow-up, do not tune tolerances).

## Done criteria

1. `HtF32` (RNE, correct subnormal/overflow/NaN — fix the probe's
   denormal-shift bug), `HtSinF32`/`HtCosF32` (Cephes replica, cos
   branch separately validated vs glsl_ref.py), `HtFractF32`, `HtModF32`
   in HTLIB.HC; `HT F32 OK` self-test gate covering the recorded bit
   patterns incl. subnormals.
2. Emitter `f32` mode (default ON): literals folded to F32, float ops
   rounded (inline bit-twiddle in the temp store), builtins routed per
   the design table; `HOLYTOY_F32=0` escape hatch knob.
3. Corpus v2 stratum A visual: the 6 spatial-hash FAILs (XdsGWH MdlGz4
   lds3D8 lsX3DH lsX3WH Xlt3Dn) flip to OK; zero regressions among the
   28 currently passing; result >=34/39. Per-shader before/after table
   recorded in this file on completion.
4. The 5 Monte-Carlo FAILs (4lfGWr 4sfGWX 4tl3z4 MtfGR4 tlSSDV)
   re-measured and their status + the statistical-oracle recommendation
   recorded.
5. Perf: bench or corpus timing evidence that F32 mode keeps the
   adaptive controller interactive (scale semantics unchanged).
6. 13/13 proofs (14/14 if plan 012 merged first) green; merged to main.

---

## Summary

Eleven stratum-A corpus shaders fail the visual oracle because HolyToy evaluates generated shader code in F64 while the llvmpipe reference evaluates in F32, and every one of them routes a value through the `fract(sin(x)*C)` (or `fract(dot·mul)`) white-noise hash idiom, whose ~5e4 gain turns any representation difference into fully decorrelated noise. The exact-sin spike already proved that LUT-sine error is *not* the cause. This design establishes the actual cause and the fix.

The decisive new finding (VM- and host-verified below): **a *more accurate* sine makes the hash shaders worse, not better.** llvmpipe computes `sin` with the Cephes single-precision polynomial and a *deliberately lossy F32 argument reduction*; at argument x=78.233 its result differs from the true sine by 1.63e-6 (~50 ULP), and 1.63e-6 × 43758 ≈ 0.071 already exceeds the 16/255 ≈ 0.063 tolerance. A correctly-rounded F64 sine (the exact-sin spike) or an x87 `FSIN` rounded to F32 would be ~2e-8 accurate and therefore *disagree* with llvmpipe by exactly that 1.6e-6 at large arguments. Convergence therefore requires **bit-reproducing llvmpipe's F32 semantics**, not merely computing "in F32":

1. round every float arithmetic op and every float literal to F32 (round-to-nearest-even), and
2. replace the sine/cosine builtins with a HolyC replica of gallivm's Cephes-F32 `sin_or_cos` (coefficients, FOPI/DP1/DP2/DP3 reduction, quadrant logic, all reproduced), computing each `fmuladd` as an exact F64 product rounded once to F32.

For `+`, `-`, `*` (and FMA), computing in F64 then rounding to F32 is provably identical to native F32 (no double-rounding — the F32×F32 product fits in F64's 52-bit mantissa exactly; verified in-guest: `f32(0.1)^2` = `0x3C23D70B` via both paths). Only `/` and `sqrt` double-round, in ~1/2^29 of cases by 1 ULP — negligible at oracle tolerance.

I recommend the **integer bit-twiddle** rounding primitive emitted **inline** into the emitter's existing per-op temp (portable, no asm/RBP coupling, measured cheaper than the asm round-trip), with the validated x87 `FSTP U32`/`FLD U32` round-trip as a correct fallback (it handles subnormals/overflow/NaN in hardware for free).

Predicted outcome: the 6 short-chain *spatial-hash* FAILs (XdsGWH, MdlGz4, lds3D8, lsX3DH, lsX3WH, Xlt3Dn) should converge to within tolerance. The 5 *Monte-Carlo path tracers / long-RNG* FAILs (4lfGWr, 4tl3z4, MtfGR4, 4sfGWX, tlSSDV) mutate a seed across hundreds of iterations and drive discrete branch decisions from hash values; these will converge only if the *entire* dataflow (including `dot`/`normalize` FMA contraction) is bit-reproduced, and are the honest candidates for a distribution-level metric if per-sample bit-exactness proves unreachable.

## Design

### What llvmpipe actually computes (source: mesa gallivm `lp_bld_arit.c`)

| GLSL op | gallivm implementation | Must we replicate the algorithm? |
|---|---|---|
| `+ - * /` | plain LLVM `fadd/fmul/fdiv`, **no `contract` fast-math flag set** → ordinary `a*b+c` is *not* fused | No — F64-compute-then-round-to-F32 is bit-identical for `+ - *`; `/` double-rounds ~1/2^29 (1 ULP), ignore |
| `sqrt` | LLVM `sqrt` intrinsic (hardware F32 sqrt) | No — round F64 `Sqrt` to F32 (double-round ~1/2^29, ignore) |
| `inversesqrt` | `lp_build_rcp(lp_build_sqrt(a))`, and `rcp` = **exact `1.0/x` fdiv** (comment explicitly rejects `RCPPS`) | No — `HtF32(1.0/HtF32(Sqrt(x)))` matches (two roundings vs their two) |
| `floor` | `FPToSI` + rounding correction (exact integer result) | No — `Floor()` of an F32 value is exact |
| `fract` | `x - floor(x)`, result rounded to F32 | Round the subtraction to F32 |
| `mod` | `x - y*floor(x/y)` | Round each sub-op to F32 |
| **`sin`/`cos`** | **Cephes single-precision polynomial**, F32 reduction, internal `lp_build_fmuladd` (FMA) | **YES — bit-replicate** |
| `exp2`/`log2`/`pow` | polynomial approximations (F32, FMA) | YES for bit-exactness, **but not needed for the 11 FAILs** (all use `sin` or `fract·mul`); defer |
| `dot`/`normalize`/`mix`/`length` | mul/add sequences; may or may not emit `lp_build_fmuladd` | **Open** — see Risks; default to per-op rounding, provide FMA variant |

Verbatim constants for the sine replica (from `lp_build_sin_or_cos`):
- `FOPI = 1.27323954473516` (= 4/π)
- `DP1 = -0.78515625`, `DP2 = -2.4187564849853515625e-4`, `DP3 = -3.77489497744594108e-8`
- sin poly `sincof = {-1.9515295891E-4, 8.3321608736E-3, -1.6666654611E-1}`
- cos poly `coscof = {2.443315711809948E-5, -1.388731625493765E-3, 4.166664568298827E-2}`

`sin_or_cos` algorithm (want_sin branch, exactly as in gallivm; I reproduced it on the host and it matches true sine to F32 ULP — see VM-verified findings):

```
xa       = |x|                              // all F32
emm2_i   = (int) (xa * FOPI)                // FPToSI: truncate toward zero
emm2_add = emm2_i + 1
emm2_and = emm2_add & ~1
sign_bit = signbit(x) XOR bit31(emm2_add << 29)   // i.e. flip on (emm2_add & 4)
poly_sin = (emm2_and & 2) == 0              // true => use sin poly, else cos poly
y  = (float) emm2_and
xr = fma(y,DP1,xa); xr = fma(y,DP2,xr); xr = fma(y,DP3,xr)   // extended-precision reduction
z  = xr*xr
yc = coscof0; yc = fma(yc,z,coscof1); yc = fma(yc,z,coscof2)
yc = ((yc*z)*z) - 0.5*z + 1.0
ys = sincof0; ys = fma(ys,z,sincof1); ys = fma(ys,z,sincof2)
ys = fma(ys*z, xr, xr)
r  = poly_sin ? ys : yc
r  = sign_bit ? -r : r
```
`cos` is the same with `emm2_2 = emm2_and - 2` and `sign_bit = ((~emm2_2) & 4) << 29`. **Every arithmetic step above is done in F64 and rounded to F32; each `fma(a,b,c)` is `HtF32(a*b + c)` where `a*b+c` is exact in F64** (F32 operands), which reproduces the hardware FMA that gallivm emits.

### The rounding primitive

`HtF32(F64) -> F64` returns the round-to-nearest-even F32 value of its argument, stored back as F64. Because generated code stores every float value in an F64 temp already, and F32×F32 / F32±F32 are exact in F64, wrapping the result of each op in `HtF32(...)` yields bit-identical F32 semantics for `+ - *`.

Two implementations were probed (below). **Recommended: integer bit-twiddle, emitted inline** into the three-address temp the op already writes:
- reinterpret the F64 temp's bits (`*(&t)(I64*)`), RNE-round the 52-bit fraction to 23 bits (guard = bit 28, round-or-sticky = low 29 bits, tie-to-even on kept LSB), handle mantissa carry into exponent, `E>127`→±inf, `E<-126`→denormal/zero, `e==0x7FF`→pass through. Emitting it inline avoids a call; TempleOS does not inline functions, so a called `HtF32()` costs a `CALL` per op.
- Keep a self-tested library `HtF32()` (same logic) as the correctness reference and for constant-folding literals.

The x87 `FSTP U32`/`FLD U32` round-trip is a validated alternative and is the *simplest correct* option for subnormals/overflow/NaN (hardware does RNE), but the global-scratch form I measured is ~14× more expensive per call than the integer path, and a stack-local asm form couples the emitter to RBP-relative temp layout. Use it only if profiling of the inline integer path disappoints.

### Scope of rounding

Apply F32 rounding to the **entire float domain**, gated by a compile-time mode flag `e->f32` (default ON for corpus/oracle runs):
- **float literals** → constant-folded to their F32 value at emit time (zero runtime cost; e.g. `43758.5453` is emitted as `43758.546875`);
- **every float-typed arithmetic op** (`HtEmBinary` scalar float case, `HtEmBinComp` float components) → wrap result;
- **int→float conversions** → round to F32; float→int stays `ToI64` truncation (matches GLSL `int()` = `FPToSI`);
- **`sin`/`cos`** → `HtSinF32`/`HtCosF32` (replica above);
- **`fract`/`mod`/`sqrt`/`inversesqrt`** → round results;
- integer/uint ops are untouched (I64 is already exact; uint masking unchanged).

Static hash-taint analysis to round *only* amplified chains is intentionally rejected: it is fragile, and rounding a non-amplified op is harmless because F64→F32 error stays far under 16/255 when not amplified (the 28 already-passing shaders confirm F64 is fine unamplified). Full-domain rounding + adaptive scale is simpler and correct. Per-op cost budget: with rounding inlined (no call), the added cost is a handful of integer ops per float op; combined with the Cephes sine replacing the LUT (~2× the LUT's cost, still far cheaper than x87 `FSIN`), a hash shader in F32 mode is non-interactive at full 640×480 (as all shaders already are — perf-floor.md) but interactive at the adaptive controller's chosen scale. Semantics are scale-independent by construction.

## ABI / interfaces

New/changed guest interfaces (all in `HTLIB.HC` unless noted):

```holyc
F64 HtF32(F64 x);                 // RNE round to F32, full range; self-tested
F64 HtSinF32(F64 x);              // gallivm Cephes-F32 sin replica (bit-exact target)
F64 HtCosF32(F64 x);              // cos = same routine, cos branch (NOT HtSinF32(x+pi/2))
F64 HtFractF32(F64 x);            // HtF32(x - Floor(x))
F64 HtModF32(F64 x,F64 y);        // HtF32(x - HtF32(y*Floor(HtF32(x/y))))
// optional, pending the dot-FMA open question:
F64 HtV2DotF32(CHtV2*,CHtV2*);    // per-op-rounded; +HtV2DotFmaF32 if gallivm fuses
```

Emitter contract (`HTEMIT.HC`): a boolean `f32` field on `CHtEmitter`, plumbed from `HTCOMP.HC`/`HT.HC`. When set:
- `HtEmNumText` emits float literals pre-rounded to F32 decimal;
- scalar/componentwise float ops emit `<temp>=HtF32(<expr>);` (or the inline bit-twiddle sequence);
- `HtEmBuiltin` dispatches `sin/cos→HtSinF32/HtCosF32`, `fract→HtFractF32`, `mod→HtModF32`, and wraps `sqrt/inversesqrt` results in `HtF32`.

Uniform ABI: `iTime`, `iResolution`, `fragCoord` etc. must be fed as F32-exact values (the oracle's states — `iTime∈{0.5,8.0}`, `iResolution=(640,288,1)`, `fragCoord=8·block+4` — already are; no change required, but the renderer should `HtF32`-round any uniform it derives by division to stay safe).

`HtLibSelfTest` gains gates (grepped by the proof): the 11 host-verified F32 bit patterns (`0.1→0x3DCCCCCD`, `1/3→0x3EAAAAAB`, `43758.5453→0x472AEE8C`, subnormal `1e-40→0x000116C2`, `1.4e-45→0x00000001`, overflow→`0x7F800000`, …) and a set of `HtSinF32`/hash values validated against `tools/glsl_ref.py` output. Prints `HT F32 OK`/`FAIL`.

## File-level change list

| File | Change |
|---|---|
| `src/holytoy/HTLIB.HC` | Add `HtF32` (RNE bit-twiddle, full subnormal/overflow/NaN), `HtSinF32`/`HtCosF32` (Cephes-F32 replica with FMA-as-exact-F64-product), `HtFractF32`, `HtModF32`; optional `HtV2/3/4DotF32`. Extend `HtLibSelfTest` with the F32 bit-pattern and sin/hash gates (`HT F32 OK`). Keep existing LUT `HtSinF`/`HtCosF` for non-F32 mode. |
| `src/holytoy/HTEMIT.HC` | Add `f32` flag to `CHtEmitter`. `HtEmNumText`: constant-fold float literals to F32 decimal when `f32`. `HtEmBinary` (scalar float) + `HtEmBinComp`: wrap float results in `HtF32`/inline twiddle. `HtEmBuiltin`: route `SIN/COS/FRACT/MOD` to F32 helpers, wrap `SQRT/INVSQRT`. Int→float conversion sites (`HtEmSplat`, `HtEmCtorConv`): round float results. |
| `src/holytoy/HTCOMP.HC` | Set/propagate the emitter `f32` mode (default ON). |
| `src/holytoy/HT.HC` | Wire the F32-mode default; ensure derived uniforms are F32-rounded before the shader ABI. Add `HT F32 OK` to the startup self-test dump. Optionally expose `HOLYTOY_F32=0` escape via a `.TXT` knob mirroring `SCALE.TXT`. |
| `src/holytoy/HTLOWER.HC` | No semantic change (types/storage unchanged: float stays F64). At most pass the mode flag through. |
| `src/holytoy/HTMATH.HC` | Unchanged (fixed-point LUT serves its own fast path). |
| `tools/test.sh` | Add/extend a proof to grep `HT F32 OK`; keep the existing oracle proof. |
| `src/bench-math.HC` | (Optional) add an F32-mode plasma variant so the accuracy/perf gate tracks the new path. |
| `plans/011-*.md` | New plan file recording this design, the corpus re-measurement, and per-shader before/after. |
| `tools/glsl_ref.py`, `tools/visual_compare.py`, `tests/corpus-visual/refs-v2` | **Unchanged** — they are the oracle; do not regenerate references to match the guest. |

## Risks & mitigations

- **FMA contraction in `dot`/`normalize`/`mix`/`length`.** gallivm sets no global `contract` flag (verified), so ordinary user `a*b+c` is *not* fused — good, per-op rounding matches it. But the GLSL builtins may internally call `lp_build_fmuladd`. If so, our per-op-rounded `HtV*Dot` diverges by ≤0.5 ULP, which the hash amplifies past tolerance for large arguments. *Mitigation:* implement dot/length with a single F64 accumulate rounded once (= fused) AND a per-op-rounded variant; pick per builtin by A/B against `glsl_ref.py`. Xlt3Dn (uses `dot(p3, p3.yzx+19.19)` inside its hash) is the direct test case. **Confirm the gallivm builtin lowering (`lp_bld_nir`/`lp_bld_tgsi`) before implementing.**
- **Monte-Carlo path tracers won't per-sample converge.** 4lfGWr/4tl3z4/MtfGR4/4sfGWX/tlSSDV mutate `seed += 0.1` across hundreds of iterations and branch on hash values; a single non-reproduced op anywhere flips a discrete path and decorrelates. *Mitigation:* accept that these may remain FAIL under a per-sample metric; recommend a distribution/statistical oracle (mean/variance or histogram distance) for shaders flagged chaotic, rather than tuning tolerance. Do not block the plan on them.
- **`exp2`/`log2`/`pow` not replicated.** They are polynomial in gallivm; leaving them as `Pow`/`Log2` + F32-round keeps a small residual divergence. *Mitigation:* none of the 11 FAILs use them in a hash; defer replication to a follow-up, note as a known deviation.
- **Integer bit-twiddle subnormal path.** My probe's first cut returned 0 for `1e-40`/`1.4e-45` (buggy denormal shift); normals were perfect (0/1.15M). *Mitigation:* port the correct denormal shift from `F32BitsExact`/`HtF32FromBits` (which the existing self-test already covers), or use the x87 `FSTP U32` primitive for the funnel (hardware handles subnormals). Subnormals essentially never arise in shader hashes, so this is low-severity but must pass the self-test.
- **Performance at full res.** F32 mode adds per-op rounding and a costlier sine. *Mitigation:* the adaptive-scale controller already targets interactive ms/frame; full-res is a stills mode. Inline the rounding (no call) to minimize the tax.
- **x87 intermediate precision.** If HolyC evaluates `a*b` in 80-bit before we round, the result is still exact for F32 operands (48-bit product ⊂ 64-bit mantissa), so `HtF32(a*b)` is correct regardless of the FPU precision-control setting — confirmed by the `f32(0.1)^2` probe matching the native F32 product bit-for-bit.

## VM-verified findings

**Probe run `run-20260717-152012-ZP15Ou`** (`make run` on the F32 primitive probe; earlier `run-20260717-151948-uPdumh` was a HolyC parse error — ternary inside a printf arg list — fixed by precomputing the status string). Guest.log `F32` lines:

- The x87 `FSTP U32` / `FLD U32` round-trip is **correctly rounded (RNE) on every case**, including subnormals (`1e-40→0x000116C2`, `1.4e-45→0x00000001`) and overflow (`1e39→0x7F800000`) — hardware does IEEE F32 rounding for free.
- The **integer bit-twiddle matches the asm path on all normal-range values**: `0.1→0x3DCCCCCD`, `1/3→0x3EAAAAAB`, `2/3→0x3F2AAAAB`, `43758.5453→0x472AEE8C`, `12.9898→0x414FD639`, `78.233→0x429C774C`, `-2.5→0xC0200000`, all correct; **sweep over ~1.15M values in [-100,100]: 0 mismatches asm-vs-int.** (Only the integer subnormal branch was wrong — returned 0 for `1e-40`/`1.4e-45`; a fixable denormal-shift bug, see Risks.)
- **No double-rounding for `*`:** `f32(0.1)^2` computed as F64 product then rounded = `0x3C23D70B` via *both* paths, equal to the host's native F32 product — confirming F64-compute-then-round-to-F32 == native F32 for `+ - *`.
- **Timing (called funnel, n=2M, under KVM):** integer `+8 ns/op` over the no-rounding baseline; global-scratch asm `+113 ns/op`. Integer wins as a call; inlining removes the call entirely. (Absolute numbers are call/loop-dominated and not the deliverable; the ~14× marginal ratio is.)

**Host verification (no VM, `struct`-based F32 emulation, `scratchpad/f32/host_ref.py`):** my HolyC-targeted Cephes-F32 `sin` replica (coefficients + reduction + quadrant logic above) reproduces true sine to F32 ULP and, critically, its error *grows with argument magnitude* — `x=0.1: 4.8e-9`, `x=1.0: 2.8e-8`, `x=78.233: 1.63e-6`, `x=133.7: 5.4e-7`. At x=78.233, `1.63e-6 × 43758 ≈ 0.071 > 0.063` tolerance: **proof that a more-accurate (F64 or correctly-rounded-F32) sine cannot converge the hash shaders — only bit-reproducing llvmpipe's lossy F32 reduction can.** This is exactly why the exact-sin spike moved nothing.

## Open questions

1. **Do gallivm's GLSL `dot`, `normalize`, `mix`, `length`, `reflect` builtins emit `lp_build_fmuladd`?** Determine from `src/gallium/auxiliary/gallivm/lp_bld_nir.c` / `lp_bld_tgsi_soa.c` (the GLSL→gallivm lowering, not `lp_bld_arit.c`). This decides whether `HtV*Dot` must fuse. Xlt3Dn is the corpus canary.
2. **Which of the 5 Monte-Carlo FAILs (if any) converge under full bit-reproduction**, and where to draw the line for adopting a distribution-level oracle metric versus per-sample tolerance for chaotic hash-driven shaders.
3. **Exact `exp2`/`log2`/`pow` polynomials** (deferred; needed only if a future corpus batch surfaces a transcendental-driven hash).
4. **Should F32 mode be always-on or per-shader?** Recommendation: default on with a `HOLYTOY_F32=0` escape hatch mirroring `SCALE.TXT`, so the 28 currently-passing shaders can be A/B-checked for any regression (expected: none, since F32 is strictly closer to the reference).
5. **Confirm the cosine branch** (`emm2_and - 2`, `sign_bit = ((~emm2_2)&4)<<29`) reproduces llvmpipe as exactly as the sin branch did — validate `HtCosF32` against a `cos`-only probe shader rendered through `glsl_ref.py` before trusting it (do not derive cos as `HtSinF32(x+π/2)`; the reduction differs).