# Perf floor: F64 vs LUT fixed-point per-pixel math (plan 003 spike)

Measured 2026-07-11 with `src/bench-math.HC` (the plasma formula from
`src/plasma.HC` as the reference workload: four `Sin` + one `Sqrt` per
pixel). The benchmark drives its own render loop on the persistent layer
(`gr.dc` body pokes) — NOT `draw_it`, which the winmgr caps at ~30 fps —
and times up to 30 frames (early-out after 3 s) per variant with `tS`
(HPET-backed). Table generation and palette setup are outside the timed
region. A CPU-bound TempleOS task is never preempted (IRQ_TIMER restores
the interrupted task), so nothing else runs inside the timed loops.

## Environment

- QEMU 11.0.1, **TCG** (no `/dev/kvm`), single vCPU, `-m 512`
- WSL2 (kernel 6.6.87.2-microsoft-standard-WSL2), Ubuntu
- Host CPU: 13th Gen Intel Core i5-13450HX
- **KVM: measured 2026-07-17** on the same host after `/dev/kvm` appeared
  (config.sh auto-enables `-enable-kvm`); see the KVM section below. The
  ordering did **not** flip, so the plan 003 format decision stands.

## Numbers (run `verify-003-Uh068Z`; rerun `verify-003-NLlQYN` agreed
within 1% on every variant — and flipped the fx16/fx22 ordering, i.e. a tie)

Variants: `f64` = original F64 formula; `fx16`/`fx22` = same formula with
angles/accumulators in 16.16 / 10.22 fixed-point turns through the HTMATH
LUT, distance term still F64 `Sqrt`; `*nd` = distance term dropped
(3 sines), isolating pure sin cost.

| variant | resolution | ms/frame | fps |
|---------|------------|----------|------|
| f64     | 640x480    | 272      | 3.7  |
| fx16    | 640x480    | 108      | 9.3  |
| fx22    | 640x480    | 110      | 9.1  |
| f64nd   | 640x480    | 163      | 6.1  |
| fx16nd  | 640x480    | 24       | 41.7 |
| fx22nd  | 640x480    | 24       | 41.7 |
| f64     | 160x120+4x4| 18       | 55.6 |
| fx16    | 160x120+4x4| 8        | 125  |
| fx22    | 160x120+4x4| 8        | 125  |

## KVM numbers (runs `verify-kvm-4R2wVC` and `run-20260717-113005-muyiIG`,
measured 2026-07-17; the two runs agree exactly on every variant)

Same host, same benchmark, QEMU 11.0.1 with `-enable-kvm`, single vCPU.
`BENCH maxerr 8/65536 OK` unchanged.

| variant | resolution | ms/frame | fps  | vs TCG |
|---------|------------|----------|------|--------|
| f64     | 640x480    | 43       | 23.3 | 6.3x   |
| fx16    | 640x480    | 5        | 200  | 21.6x  |
| fx22    | 640x480    | 4        | 250  | 27.5x  |
| f64nd   | 640x480    | 30       | 33.3 | 5.4x   |
| fx16nd  | 640x480    | 3        | 333  | 8.0x   |
| fx22nd  | 640x480    | 3        | 333  | 8.0x   |
| f64     | 160x120+4x4| 3        | 333  | 6.0x   |
| fx16    | 160x120+4x4| <1       | n/a  | >8x    |
| fx22    | 160x120+4x4| <1       | n/a  | >8x    |

KVM takeaways:

1. **Ordering unchanged — the LUT still wins, by more** (43 vs 5 ms at
   640x480, 8.6x; TCG was 2.5x). x87 `FSIN` under KVM is real hardware
   but still microcoded and slow relative to table lookups. The 16.16
   format decision stands.
2. **Native F64 `Sin` is now affordable where correctness wants it**:
   43 ms/frame for the full plasma formula at 640x480 (~23 fps) means
   exact-sin semantics (plan 011 candidate, targeting the 11 visual-oracle
   hash-decorrelation FAILs) costs interactivity, not feasibility.
3. **The adaptive-scale controller budget changed regimes**: at TCG-era
   thresholds (coarsen >250 ms, refine when projected <150 ms) a shader
   could settle at ~5 fps without coarsening. Retuned 2026-07-17 in
   `HT.HC` to coarsen >70 ms / refine when `ht_shade_ms*4 < 60` — about
   two winmgr ~33 ms periods, and refine only when the projected
   next-finer cost stays comfortably interactive.
4. **The remaining ceiling is single-core**: QEMU passes no `-smp`, so one
   vCPU shades everything. Multicore fan-out (TempleOS `Spawn` with
   `target_cpu`) is the next multiplier, ~4x+.

## Accuracy

`BENCH maxerr 8/65536 OK` — max |LUT sin − F64 Sin| over 10k angles,
both formats, including the caller's angle quantization. The 4096-entry
table interpolates linearly, so the gate was tightened from the plan's
no-interpolation bound (2/4096 = 32/65536) to 10/65536; the observed
8/65536 is dominated by 16.16 angle quantization (2*pi/65536 ~ 6.3/65536).
Sanity probes (0 / quarter / half turn) are exact in both formats.
The parity screenshot (left half F64, right half 16.16 LUT, same t) is
seam-continuous at x=320 — visually indistinguishable.

## Decision

1. **LUT fixed point wins, clearly.** Full formula at 640x480: 2.5x faster
   than F64 (272 -> 108 ms). With the F64 `Sqrt` distance term dropped, the
   pure sin path is **6.8x** faster (163 -> 24 ms). The VISION.md:78-82
   premise holds under TCG.
2. **Format: 16.16 default, per-op choice deferred.** 16.16 and 10.22 are
   identical within noise (<2% spread, far under the 20% threshold): TCG
   costs the same for either shift width. Accuracy at 16.16 (8/65536) is
   ample for 16-color output. Adopt **16.16** (matches the existing
   `WallPaperFish.HC` idiom, roomier integer part for coordinate*constant
   angle math); revisit only if KVM changes the picture.
3. **Render-scale alone already hits interactive rates**: even pure F64 at
   160x120+4x4 runs ~56 fps; LUT pushes it to ~125 fps, and the winmgr's
   ~30 fps composite becomes the ceiling. Full 640x480 stays
   non-interactive in any variant (9 fps best) — 160x120 is the right
   default viewport mode, with full-res for stills.
4. **Next per-pixel win is a fixed-point sqrt** (deferred from this spike):
   the F64 `Sqrt`+conversions cost ~84 ms/frame at 640x480 (108 vs 24 nd),
   ~78% of the remaining fixed-variant budget. `atan2` LUT also deferred.
5. **What plan 002's app should adopt**: `src/holytoy/HTMATH.HC` (16.16
   entry points `HTMSin16`/`HTMCos16`/`HTMRad16` after `HTMInit`), a
   160x120 render-scale viewport, and an ms/frame readout timed around the
   app's own render loop with `tS` — not inside `draw_it`. Rerun
   `src/bench-math.HC` whenever HTMATH changes: its `BENCH maxerr ... OK`
   line is the machine-checked accuracy gate.
