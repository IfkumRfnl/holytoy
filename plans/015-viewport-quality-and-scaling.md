# Plan 015: Viewport quality and scaling — bilinear upsample, 8-vCPU SMP, adaptive palette, SSE stage-0

Goal: the viewport gets BOTH faster and visibly better, compounding. A 1:16
frame that interpolates smoothly between samples reads like today's 1:8; more
worker cores push heavy shaders' ms/frame down; a scene-adaptive palette
spends the 16 DAC entries on the colors the scene actually uses. All three are
display-path changes that are **oracle-invariant by construction** (verified:
the visual oracle taps `ht_fp` via `HtVisualDump`, `HT.HC:595-641`, on its own
fixed 80x36 block-CENTER pre-quantization grid — it never reads the
framebuffer, dither, palette, or `HtShadeBand`).

Motivating workload: iq's Greek Temple (gitignored `local/perf-workloads/
greek-temple/`, plan 014's fixture). At 1:16 the adaptive controller floor,
the temple is unrecognizable — one flat dithered color per 16x16 block.

## Why (measured, 2026-07-18)

- `HtShadeBand` (`HT.HC:333-376`) already pays a per-pixel cost (Bayer offset
  + `htr_lut` hit per pixel) yet floods each scale-block with ONE sample taken
  at the block center. All spatial information between samples is discarded.
- Temple at pinned 1:16: **SMP=4 146 ms/frame, SMP=8 98 ms/frame (1.49x)**
  (runs run-20260718-003543-Q95oNi / run-20260718-003557-NBdDeW). Host is 4
  physical cores x 2 HT visible in WSL2 (i5-13450HX; WSL capped at 8 logical
  of 16) — HT explains the gap vs the naive 7/3-workers ratio. Static
  one-band-per-worker partitioning (`HT.HC:501-515`) additionally wastes time
  on heterogeneous scenes: sky bands are cheap, temple bands expensive; the
  frame waits on the slowest band.
- The fixed EGA-ish palette (`HTRENDER.HC:33-48`) wastes most of its 16
  entries on colors absent from any given scene (temple = warm stone + sky).
- SSE research verdict (2026-07-18, vendor-verified): kernel enablement is
  one CR4 bit per core — `SYS_ENTER_LONG_MODE` sets only 0xB0
  (`KStart64.HC:45-47`), OSFXSR(9)/OSXMMEXCPT(10) clear on all cores; the
  task-switch machinery is ALREADY XMM-ready (`Sched.HC:86-119` FXSAVE/FXRSTOR
  into 512-byte 16-aligned `CFPU`, `KTask.HC:211`). But the HolyC compiler
  backend is x87-only (`BackFB.HC:501-570`) and the assembler has ZERO SSE
  arithmetic opcodes (`ARGT_XMM*` "Not implemented", `KernelA.HH:1951-1956`) —
  HolyToy emits HolyC source text, so scalar SSE is unreachable from source
  and per-op helper calls would re-add the overhead plan 014 removed. Scalar
  SSE is NOT a PC24 replacement; the payoff is a future raw-machine-code
  packed-PS backend (plan 016 candidate, XL). This plan lands only the cheap
  stage-0 enablement + probe that de-risks it.

## Design

### Stage A — bilinear corner-sample upsample (display only)

Shade block CORNERS instead of centers: an (nbx+1) x (nby+1) sample grid per
frame (+~6% samples at 1:16), then per-pixel bilinear interpolation of the
8.8 fixed-point RGB between the 4 surrounding corners, then the existing
Bayer offset + `htr_lut` quantization per pixel. Integer math only in the
per-pixel loop (the lerp weights at scale 16 are j/16, i/16 — shifts).

- Sample storage: per-frame corner grid (F64->8.8 ints) sized
  (HT_FB_MAXW/1+1) rows worst case; allocate once like `ht_fb`.
- Band decomposition invariance (proof 14 `C1==C4`, `test.sh:408-438`): a
  band shading block rows [y0,y1) computes corner rows [y0,y1]; the shared
  boundary row is recomputed by both neighbors. `ht_fp` is deterministic
  (plan 011 contract), so duplicated corners are bit-identical. Never share
  corner rows across bands via memory — recompute.
- Edge semantics: rightmost/bottom corner column/row sits at x=nbx*scale,
  y=nby*scale (may equal vw/vh). Leftover pixels beyond nbx*scale keep
  today's behavior.
- At scale=1 the corner grid degenerates: keep the EXACT current center-
  sampling path for scale==1 (bilinear is identity there only if sample
  positions are unchanged; do not perturb 1:1 output).
- Gate: `E:/BILERP.TXT` via `HOLYTOY_BILERP=0|1` (mkxfer.sh), default ON.
  OFF must reproduce today's flood-fill path byte-for-byte.
- **Do NOT touch** `HtVisualDump`, `HtDump8`, `HtFrameSetup`, or feed the
  dump from the corner grid — the oracle stays on its own center grid
  (constraint from oracle research; the tempting reuse is the failure mode).

### Stage B — SMP=8 + band oversubscription

- `config.sh`: `SMP="${HOLYTOY_SMP:-8}"` (env-overridable; 8 = this host's
  WSL logical CPU count; document `HOLYTOY_SMP=4` fallback and that MAX_RUNS=3
  concurrent 8-vCPU VMs oversubscribe — solo measurement runs unaffected).
- Load balance: replace one-band-per-worker with M small bands round-robin
  across workers, M = min(nby, OVERSUB*(cores-1)), OVERSUB=4 initial. JobQue
  already queues multiple jobs per core (`HT.HC:517-518` loop generalizes;
  `ht_desc[]` grows from MP_PROCESSORS_NUM to a small static max, e.g. 64).
  Expect recovery of part of the slowest-band wait on heterogeneous scenes;
  measure temple delta.
- Controller (`HtScaleController`, `HT.HC:394-417`) budgets unchanged.
- Flag (do not implement): raising WSL2 `processors` beyond 8 (host has
  10c/16t) is a user machine decision — record in the measurement note.

### Stage C — scene-adaptive palette (after A merges)

Design per research (2026-07-18, vendor-verified):
- Reserve indices {0,7,10,12,14,15} (BLACK, LTGRAY, LTGREEN, LTRED, YELLOW,
  WHITE — every color `HtDrawPane` uses, `HT.HC:184-228`); adapt
  {1,2,3,4,5,6,8,9,11,13}. Mouse pointer is XOR-drawn (`Adam/Win.HC:186-192`)
  — legibility risk only, no reservation needed. scrtext OCR is color-
  agnostic (2-distinct-RGB cells) — pane text stays readable via 0/7/15.
- Weighted k-means k=10, warm-started from previous frame, 2-3 Lloyd
  iterations, over per-band RGB histograms piggybacked on Stage A's corner
  samples (workers already hold the RGB; merge on core 0 at the publish
  point, `HT.HC:524-529`). ~0.5-1 ms/frame.
- Quantizer targets 6 fixed anchors + 10 centroids. `htr_lut` rebuild only
  on material centroid motion, capped to every >=8 frames (2-4 ms amortized
  <0.5 ms/frame). DAC program via `GrPaletteColorSet` (5 port writes/entry,
  no vblank wait, global instant, `GrPalette.HC:30-44`) only for entries
  moved > epsilon; re-assert the 10 adaptive entries every publish (guards
  against any nested SettingsPop restoring the standard palette,
  `TaskSettings.HC:15,85`).
- Flicker: luminance-order centroids (stable index identity), exponential
  smoothing (alpha ~0.15), hysteresis on DAC/LUT updates.
- Gate: `E:/PAL.TXT` via `HOLYTOY_PAL=fixed|adaptive`, **default fixed**
  initially; flip default to adaptive only after visual spot-checks on
  temple + 3 corpus shaders. Never engages in `HtSelfTest`/`HtCorpusRun`.
- Determinism (proof 9 `HASH1==HASH2`, proof 14 `C1==C4`): the palette must
  be a pure function of frame content (histogram merge order fixed by band
  index, not completion order; no wall-clock inputs).
- Exit path: `SettingsPop` at `HT.HC:1032` already restores the standard
  palette on ESC.

### Stage D — SSE stage-0 enablement probe (parallel-safe, probe only)

- New `src/probe-sse.HC` (PROBECW4 style, raw `DU8` bytes for
  MOVSS/ADDSS/MULSS/SUBSS/DIVSS/SQRTSS since the assembler lacks mnemonics):
  1. read CR4 (expect OSFXSR=0), set CR4|=0x600 + `LDMXCSR` 0x1F80 per core
     (dispatch to every core 0..mp_cnt-1 via JobQue);
  2. prove MOVSS/MULSS execute (no #UD) on core 0 and an AP;
  3. prove an XMM sentinel survives `Yield` + `Sleep(50)` on an AP (FXSAVE
     with OSFXSR=1 carries XMM through task switches);
  4. bit-exactness sweep: ADDSS/MULSS/DIVSS/SQRTSS vs `HtF32` reference for
     normal operands (reuse BENCHPC.HC:126-163 operand generator pattern —
     but the probe lives in src/, so REIMPLEMENT the generator, do not copy
     from the licensed local/ dir); divergences ONLY at the F32 exponent
     boundary (denormal/overflow) are classified SSE-CORRECT (the plan-014
     documented PC24 edge), anything else FAILs.
- Zero changes to the production render/emit path. PC24 stays the shipped
  F32 math. The probe's findings unblock a future plan-016 packed-PS
  raw-machine-code backend.
- Proof line `HT SSE OK` appended to test.sh.

## Done criteria

1. All existing proofs stay green: `make test` 14/14 pre-existing, plus new
   proofs (bilerp, SSE; palette proof lands with Stage C).
2. **Bilerp proof**: a shader linear in fragCoord (gradient) rendered at
   pinned 1:16 with bilerp ON matches its pinned 1:1 rendering byte-for-byte
   in the viewport (bilinear reconstruction of a linear function is exact
   modulo identical quantization). Negative check: bilerp OFF at 1:16 does
   NOT match (proves the proof can fail).
3. Proof 14 (C1==C4) green WITH bilerp ON — band-boundary corner recompute
   is bit-identical across core counts.
4. Corpus: stratum A 39/39 compile/exec, visual 32/39, all V-DAT md5s
   byte-stable (display changes cannot move them; this catches accidental
   oracle-path edits).
5. Temple evidence (local, uncommitted note is fine): ms/frame at SMP=8 +
   oversubscription at 1:16 and 1:8, plus latest.png at 1:8 and 1:16-bilerp
   for the before/after.
6. `HT SSE OK` proof green: enable + execute + XMM-survival + bit-sweep.
7. Stage C (when it lands): `HT PAL OK` self-test — adaptive run on a
   synthetic two-color scene converges DAC entries near the scene colors,
   reserved indices' DAC values untouched, two identical runs hash-identical.
8. README purity: no plan/progress text in README.md.

STOP conditions: any pre-existing proof regresses and the fix is not
obvious within one debug cycle; corpus visual drops below 32/39; any
committed V-DAT md5 changes; temple ms/frame at SMP=4 with all gates OFF
regresses >5% vs 146 ms (the machinery must be free when disabled); the
SSE probe #UDs or corrupts XMM on any core (record and stop Stage D only —
it must not block A/B/C).

## File-level change list

- `src/holytoy/HT.HC` — HtShadeBand corner grid + bilinear fill + gate;
  band descriptor corner-row fields; HtRenderTask band oversubscription;
  (C) per-band histogram + publish-point palette update; BILERP/PAL TXT
  parsing next to SCALE/CORES (`HT.HC:1039-1101` pattern).
- `src/holytoy/HTRENDER.HC` — (C) adaptive palette module: k-means, DAC
  program, gated LUT rebuild; HTRInit/fixed path unchanged.
- `config.sh` — SMP default 8 + HOLYTOY_SMP override; comment MAX_RUNS
  interaction.
- `tools/mkxfer.sh` — BILERP.TXT, PAL.TXT plumbing (PAD.TXT 16-entry
  boundary rule: keep the entry count off the boundary when adding files,
  plan-010 gotcha).
- `src/probe-sse.HC` — stage-0 probe (new).
- `tools/test.sh` — proofs: bilerp exact-linear (+negative), HT SSE OK,
  (C) HT PAL OK.
- `plans/README.md` — row 015.
- `docs/notes/plan-015-measurements.md` — SMP/oversub/bilerp numbers
  (temple numbers referenced generically: "the local heavyweight workload";
  do not name or include licensed shader content).

## Verification plan

Executor worktrees with `images/ out/ vendor/` symlinked to the main repo
(VM slots stay globally bounded). Per stage: targeted `make run` spot checks
(gradient bilerp A/B, temple perf), then full `make test`, then corpus
(`RUN_TIMEOUT` per plan-010 batch convention) for stages touching the
render path. Merge ff-only to main when all green; re-run `make test`
post-merge (house rule).

Dispatch: Executor 1 = Stages A+B (same files, sequential within one
branch). Executor 2 = Stage D (disjoint files, parallel). Stage C starts
after A+B merge (its histogram piggybacks the corner grid).
