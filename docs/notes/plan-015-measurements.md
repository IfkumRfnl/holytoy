# Plan 015 Stages A+B measurements (bilerp upsample + SMP=8/oversubscription)

Measured 2026-07-18 on branch `advisor/015-ab-bilerp-smp`. Host:
i5-13450HX (10c/16t; WSL2 shows 8 logical CPUs), KVM, solo runs. The perf
workload is the local heavyweight raymarcher (gitignored
`local/perf-workloads/`; licensed educational-use-only — referenced
generically, never committed). ms/frame values are the per-frame pane
readout OCR'd from the run's rolling frames (`tools/scrtext.py`); the
shader animates, so per-frame cost varies — medians quoted, ranges in
parentheses.

## Stage A: bilerp exactness (proof 16 post-merge; ran as proof 15 pre-rebase)

Static gradient (linear in fragCoord), viewport crop `0,8,640x288`:

| config | viewport hash |
|---|---|
| pinned 1:1 (reference) | `467019008aeb600eb34e1780064c8701` |
| pinned 1:16, bilerp ON | `467019008aeb600eb34e1780064c8701` (byte-identical) |
| pinned 1:16, bilerp OFF | `8d6b8c06052f7dd16360ee0473b49f83` (differs — negative check) |

Byte-exactness required center-aligned weights `(2j+1)/(2*scale)` (not the
plan text's `j/scale`, which reconstructs pixel top-left corners while the
1:1 path samples centers), 8.16 corner storage, and a `+4*scale^2`
rounding bias — host-simulated exact for scales 2/4/8/16 under F32-rounded
corner samples, then VM-verified (spot runs `run-20260718-005816-lvzYkE`
1:16-ON, `run-20260718-005856-AKyTtc` 1:16-OFF, `run-20260718-005911-wpBK0q`
1:1; proof runs `test-20260718-010545-*-bilerp-*`).

## Stage B: heavyweight-workload ms/frame

Pinned 1:16 (viewport 640x288, KVM):

| config | median ms/frame | run |
|---|---|---|
| SMP=4, bilerp OFF, one band/worker (plan-014 default) | 146 | baseline `run-20260718-003543-Q95oNi` |
| SMP=8, bilerp OFF, one band/worker | 98 | baseline `run-20260718-003557-NBdDeW` |
| SMP=8, bilerp OFF, 4x oversub | **75** (68-83) | `temple-smp8-ov-off16` |
| SMP=8, bilerp ON, 4x oversub (rejected) | 146 (139-148) | `temple-smp8-ov-s16` |
| SMP=8, bilerp ON, one band/worker (**shipped default**) | **127** (109-150) | `temple-smp8-tuned-s16` |
| SMP=4, bilerp OFF, oversub (all-gates-OFF STOP check) | 122 (116-153) | `temple-smp4-off-s16` |

Pinned 1:8:

| config | median ms/frame | run |
|---|---|---|
| SMP=8, bilerp OFF, 4x oversub | 365 (341-387) | `temple-smp8-ov-off8` |
| SMP=8, bilerp ON, 4x oversub (rejected) | 577 (556-595) | `temple-smp8-ov-s8` |
| SMP=8, bilerp ON, one band/worker (**shipped default**) | 394 (378-423) | `temple-smp8-tuned-s8` |

Takeaways:

- **Oversubscription is a clear win for flood-fill frames**: 98 -> 75 ms
  at 1:16 (1.31x) — the workload's bands are heterogeneous and round-robin
  balancing recovers the slowest-band wait, as the plan predicted.
- **Oversubscription LOSES with bilerp ON**: every band recomputes one
  shared corner row (the Stage A determinism contract), i.e. each extra
  band adds a full block-row of shader samples. At 1:16 that doubled the
  sample count (18 one-row bands) and erased the SMP=8 gain (146 ms).
  Shipped rule: bilerp frames use one band per worker; flood-fill frames
  keep `M=min(nby, 4*(cores-1))`.
- **Default-vs-default**: plan-014 defaults (SMP=4, flood fill) 146 ms ->
  plan-015 defaults (SMP=8, bilerp, tuned bands) 127 ms at 1:16 — 1.15x
  faster AND the frame reads as a smooth scene instead of a 16x16 mosaic
  (`temple-smp8-tuned-s16/latest.png` vs `temple-smp8-ov-off16/latest.png`;
  1:8 capture `temple-smp8-tuned-s8/latest.png`). A 1:8 flood-fill frame
  of comparable smoothness costs ~365 ms.
- **STOP-condition check passed**: SMP=4 with bilerp OFF (all gates off)
  medians 122 ms vs the 146 ms baseline (the lone 153 ms tail frame is
  within the animated shader's per-frame variance; the run is a net win
  because the OFF path now oversubscribes).
- WSL2 `processors` is capped at 8 of 16 host threads; raising it is a
  user machine decision (flagged per the plan, not implemented).

## Proofs and corpus (final tuned code)

- `make test`: **15 passed, 0 failed** (14 pre-existing + new bilerp
  proof), bilerp default-ON, SMP=8. Proof 9 dither hash and proof 14
  C1==C4 hash both `467019008aeb600eb34e1780064c8701`.
- Corpus v2 (`tools/corpus_run.sh`): stratum A compile/install/exec
  **39/39**, visual **32/39** within tolerance — same 7 chaotic FAILs and
  identical per-shader scores as plan-014 (e.g. XdsGWH 39.83/25.5%).
  Branch run `run-20260718-014237-NkNzn6` (final code) and
  `run-20260718-012927-mjLyvO` (pre-tuning) vs main baseline
  `run-20260718-013022-LxCrO6`: **all 78 guest V-DAT md5s byte-identical**
  — the oracle path is untouched by construction and in fact.
