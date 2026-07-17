# Exact-sin spike: native Sin does NOT fix the hash-idiom visual FAILs

Measured 2026-07-17 under KVM. Question: the 11 stratum-A visual-oracle
FAILs (plans/010) all contain the `fract(sin(x)*43758.5453)` white-noise
hash idiom. Plan 009 recorded two candidate causes: LUT sine error
(<= 2e-4) and F64-instead-of-F32 float semantics. Which one dominates?

## Method

Temporarily replaced `HtSinF`/`HtCosF` (HTLIB.HC) with native x87
`Sin`/`Cos` — the single funnel for all generated GLSL `sin`/`cos` — and
re-ran three of the 11 failing shaders through the visual oracle
(`HOLYTOY_VISDUMP=1`, V00 dumps vs `tests/corpus-visual/refs-v2`,
runs `run-20260717-113951-YTekWp`, `-114006-lstlcY`, `-114021-vYbLQz`).

## Result: no movement

| shader | LUT pctA/pctB (plan 010) | exact-sin pctA/pctB |
|--------|--------------------------|---------------------|
| lsX3DH | 50.5 / 39.4              | 51.2 / 35.8         |
| XdsGWH | 25.5 / 25.5              | 25.5 / 25.5         |
| lds3D8 | 52.5 / 48.8              | 52.5 / 48.8         |

Shifts are noise-level; XdsGWH and lds3D8 are unchanged to the decimal.

## Conclusions

1. **F64-vs-F32 semantics dominate the hash decorrelation, not LUT
   error.** `fract(sin(x)*43758.5453)` amplifies any representation
   difference by ~5e4; feeding it a sine that is exact *in F64* still
   diverges from the reference, which computes the whole chain in F32.
2. **Keep the LUT.** It is 8.6x faster than native `Sin` under KVM
   (docs/notes/perf-floor.md) and this spike removes the standing
   correctness argument against it: exact sin buys nothing visually.
3. **Plan 011 scope note:** converging the hash shaders means F32
   semantics in the generated code path (at minimum F32 rounding through
   the hash chain). Caveat for that plan: the llvmpipe reference's F32
   `sin` is gallivm's own polynomial, not correctly-rounded — bit-exact
   convergence may additionally require replicating that polynomial, or
   the oracle may need a distribution-level metric for chaotic
   hash-driven shaders instead of per-sample tolerance.
