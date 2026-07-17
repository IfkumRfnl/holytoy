# Plan 012: SMP background render task (multicore shading fan-out)

Status: DONE (2026-07-17, branch plan-012-smp-render). Depends on plan 011
(reentrant ht_fp). Designed 2026-07-17
by an Opus 4.8 design agent; probe `run-20260717-151606-YVG02x` verified
JobQue fan-out on cores 1-3, byte-identical multicore output (checksum
match), 3.16x speedup on 3 workers, and throw isolation. `-smp 4` is
already live (commit ee802ce).

Reconciliation with plan 011 (supersedes the design text where they
differ): the render task owns the per-frame uniforms handoff — it copies
`ht_u` into a frame-local `CHtUniforms` snapshot and calls
`HtFrameSetup(&snap)` BEFORE fan-out (satisfying 011's contract that
`ht_frame` is filled before workers start and not mutated until they
join). `HtDrawIt` no longer calls `HtFrameSetup` at all; it only updates
`ht_u` for the next snapshot and blits. `HtVisualDump`/`HtCorpusRun`
pause the render task (`HtRenderPause`) and call `HtFrameSetup`
themselves, staying single-core on core 0.

STOP conditions: if proof 14 (multicore == single-core bytes) fails,
stop and diagnose the nondeterminism — do not loosen the comparison; if
any existing proof needs its assertion weakened, stop and report.

## Done criteria

1. draw_it never shades: it blits the last complete frame + pane;
   editor stays responsive while a multi-second shader renders.
2. Fan-out per the design (JobQue transient jobs, contiguous row-bands,
   double buffer, pause/resume quiesce, single-core fallback).
3. `HOLYTOY_CORES` env -> `E:/CORES.TXT` pin, mirroring HOLYTOY_SCALE.
4. New proof 14: gradient.glsl at HOLYTOY_SCALE=4 with CORES=1 vs
   CORES=4 produces identical viewport hashes. 14/14 proofs green.
5. Measured evidence in the plan-completion note: a heavy shader's
   ht_shade_ms at CORES=1 vs CORES=4 showing >=2.5x (probe predicts
   ~3.16x on 3 workers).
6. Corpus v2 visual unchanged (dumps are single-core by design).
7. Merged to main once green; make test re-run post-merge.

---

## Summary

Today HolyToy shades the whole viewport inline inside `HtDrawIt`, which the window manager calls in the **winmgr task on core 0**. A multi-second shader therefore blocks the single winmgr, freezing the editor and the whole UI. This design moves all shading out of `draw_it` into a dedicated **render task** that fans each frame's block-rows across the worker cores (cores `1..mp_cnt-1`) using TempleOS's `JobQue`/`JobResGet` job mechanism, shading into an offscreen double buffer. `HtDrawIt` shrinks to a pure blit of the last *complete* frame plus the pane/status text, so the editor stays responsive no matter how slow the shader is.

The design deliberately uses **transient per-frame jobs** (`JobQue`), not long-lived spawned worker tasks. `JobResGet` is a synchronous barrier, so the render task always knows workers are idle between frames — this gives quiesce-for-free (no `Kill`, no flag-and-spin, no use-after-free of freed shader code) and makes shader swap / scale change / exit trivially safe.

A single VM probe (RUN_DIR `run-20260717-151606-YVG02x`) confirmed the mechanism end-to-end under KVM `-smp 4`: a 3-band fan-out ran on cores 1/2/3, a shared `MAlloc`'d buffer written concurrently by three cores was **byte-identical** to the single-core reference (checksum `1295095` both ways), speedup was **3.16x** on 3 workers, and a job that `throw`s was absorbed without crashing the system.

This design assumes the **per-invocation context-struct ABI fix has already landed** (the parallel "ctx ABI" track), so `ht_fp` no longer mutates emitted module globals. That fix is the precondition for concurrent `ht_fp` calls; see *Risks* for what happens if it has not landed.

## Design

### Roles and tasks (all on core 0 except workers)

| Task | Core | Responsibility |
|------|------|----------------|
| winmgr task | 0 | calls `HtDrawIt` (~30 fps) → blit front buffer + pane |
| HT main task | 0 | startup, then `HtInteract` (GUI keyboard) *or* `HtSelfTest`/`HtCorpusRun` (headless) |
| **HT render task (new)** | 0 | frame loop: snapshot uniforms → fan out band jobs → drain → publish |
| Seth tasks (workers) | 1..mp_cnt-1 | run `JobQue`'d band jobs (`JobRunOne`), i.e. call `ht_fp` for their rows |

All four core-0 roles are round-robin time-sliced. The render task spends almost its entire frame inside `JobResGet`, which `Yield`s (`LBts(TASKf_IDLE); Yield`), so the winmgr and keyboard tasks get core 0 while workers shade on cores 1..3.

### Frame loop (render task)

```
HtRenderTask():
  loop forever:
    if ht_render_exit:            break
    if ht_render_pause:           // control handshake (swap/scale/exit)
        ht_render_busy = 0; Sleep(2); continue
    fb = &ht_fb[ht_back_idx]       // the buffer NOT currently shown
    snapshot uniforms into fb->snap     // ONE consistent CHtUniforms per frame
    nb = worker band count (see below)
    t0 = tS
    ht_render_busy = 1             // workers about to touch ht_fp / fb
    if nb == 0:                    // single-core fallback (pinned or uniprocessor)
        for each contiguous row-band k: HtShadeBand(&desc[k]); Yield  // Yield keeps UI alive
    else:
        for k in 0..nb-1: jobs[k] = JobQue(&HtShadeBandJob, &desc[k], 1+k, 0)
        for k in 0..nb-1: ok &= JobResGet(jobs[k])   // barrier: all workers done
    ht_render_busy = 0
    ht_shade_ms = (tS - t0)*1000
    if ok:                         // no band faulted
        ht_front_idx = ht_back_idx // PUBLISH: single aligned word store (atomic)
        ht_back_idx  ^= 1
    HtScaleController(ht_shade_ms) // req 5: controller consumes background frame time
```

`desc[k]` is a per-band descriptor (see ABI). Each band job shades one sample per `ht_scale x ht_scale` block for its rows, quantizes + Bayer-dithers exactly as today's inline path, and writes final **palette indices** into `fb->pix` at viewport resolution. `HtDrawIt` then only has to `MemCpy` rows.

### Offscreen buffers and publish (req 3, double buffering)

Two frame buffers `ht_fb[0]`, `ht_fb[1]`, each `{ CHtUniforms snap; U8 *pix; }`. `pix` is `fb_stride * HT_VIEW_H` palette-index bytes, `fb_stride = (max_vw + 63) & ~63` (64-byte-aligned rows → band boundaries never share a cache line; see below). Base pointer 64-byte aligned (over-allocate 64, round up).

- **Publish** is the single store `ht_front_idx = ht_back_idx`. On x86-64 an aligned 8-byte store is atomic; `HtDrawIt` reads `ht_front_idx` once into a local and blits that buffer. A screendump can only ever see a fully-completed frame → **no tearing**.
- **No torn uniforms** (req 3): the render task copies `ht_u` into `fb->snap` *once*, before fan-out. Every worker reads the same `fb->snap`. The winmgr may keep mutating `ht_u` (time/mouse/date) for the *next* frame; in-flight workers never see it.
- Because a fixed `snap.i_frame` is used for the whole frame and only the render pipeline calls `ht_fp`, the generated shader's per-invocation stamp/rebind is consistent across all bands.

`HtDrawIt` becomes:

```
HtDrawIt(task,dc):
    update ht_u (time,frame,res,mouse,date)   // for the NEXT snapshot only
    f = ht_front_idx                          // read published index once
    if ht_have_frame:
        for y in 0..vh-1:
            MemCpy(&dc->body[(pix_top+y)*stride + pix_left], &ht_fb[f].pix[y*fb_stride], vw)
    HtDrawPane(task,dc)                        // pane + "%3dms 1:%-2d" from ht_shade_ms/ht_scale
```

### Static row-bands, not interleaved (req 2, justified by cache behavior)

**Assignment: static contiguous row-bands, one band per worker core.** Worker `w` (0-based) owns block-rows `[w*nby/nb, (w+1)*nby/nb)`, i.e. a contiguous, disjoint slab of output rows.

Cache justification:
- **Output writes.** Each output row is `fb_stride` bytes (≥640, a multiple of 64). With row-aligned band boundaries and a 64-byte-aligned base, every band writes a region that begins and ends on a cache-line boundary → **zero false sharing** between workers. Writes within a band are sequential → hardware prefetch and full-line write-combining.
- **Input reads.** The only shared reads are the `htl_sin`, `htr_lut`, `htr_bofs`, `htr_palette` tables — **read-only** after init. Read-only lines replicate into every core's cache with no coherence traffic.
- **Interleaved (`rows w, w+nb, w+2nb…`) is strictly worse:** adjacent output rows would be written by different cores, so nearly every 64-byte line is touched by ≥2 cores → cache-line ping-pong / invalidation storm, and it destroys the sequential write stream. Its only theoretical benefit — load balancing when per-row cost varies — is minor for typical uniform-cost shaders, and is better addressed (if ever needed) by **over-decomposing into `K*nb` contiguous strips** handed round-robin to cores (coarse strips keep false sharing at strip boundaries only). Start with one-band-per-core; the strip count is a one-line knob.

Determinism is unaffected by the assignment: each pixel is computed by identical code regardless of which core runs it.

### Should core 0 take a shading slice? (req 2) — No.

Core 0 orchestrates and blits only; it does **not** shade a band when `nb ≥ 1`. Rationale: taking a core-0 slice would run a tight, non-yielding shade loop on core 0 for one band's duration (hundreds of ms for slow shaders), reintroducing exactly the UI freeze this design removes. The ~1/nb of core-0 time "lost" to idle-waiting is spent on winmgr compositing and editor keystrokes — which is the entire point (req 1). The throughput give-up is `nb/(nb+1)` (e.g. 3/4) and is the right trade for a UI app. **Exception:** when `nb == 0` (pinned single-core or a uniprocessor guest), the render task shades all bands itself but `Yield`s between contiguous bands so the winmgr/editor still run — strictly better than today's monolithic `draw_it`.

### Worker count and the pin escape hatch (req 6)

`ht_render_cores` = number of cores that shade. `nb` (worker job count) = `ht_render_cores - 1` when `ht_render_cores ≥ 2` (core 0 orchestrates, cores `1..nb` shade); `nb = 0` when `ht_render_cores == 1` (single-core fallback).

- Default (auto): `ht_render_cores = mp_cnt` (clamped to `MP_PROCESSORS_NUM`).
- Pinned via `E:/CORES.TXT` (mirrors the existing `SCALE.TXT` block in HT.HC): a decimal `1..mp_cnt`, or `auto`. Values `>mp_cnt` clamp to `mp_cnt` with an `HT CORES BADPIN` log line.
- Host plumbing: `HOLYTOY_CORES` env var → `mkxfer.sh` writes `x:/CORES.TXT` (one new `if` block, identical shape to the `HOLYTOY_SCALE` block).

`nb` is re-read from `ht_render_cores` at the top of each frame's fan-out; changing it just changes the next frame's job count (an aligned-word read, inherently safe, no handshake needed).

### Lifecycle / quiesce handshake (req 4)

Because workers are transient jobs drained by `JobResGet` every frame, the only long-lived shared state is `ht_fp` (+ its JITed code), `ht_scale`, and the buffers. Foreground events that must not race a worker — **shader recompile/swap, scale reset on swap, app exit, and the self-test/visual-dump** — use a two-flag request/ack handshake with the render task:

```
HtRenderPause():                 // called from HT main task (editor/selftest)
    LBts(&ht_render_pause,0)
    while (Bt(&ht_render_busy,0)) Yield   // wait out at most one in-flight frame
HtRenderResume():
    LBtr(&ht_render_pause,0)
```

- `HtInstallHoly` / `HtCompileAndSwapGlsl`: wrap the `ht_fp = ht_new_fp` rebind and `HtScaleReset` in `HtRenderPause … HtRenderResume`. The render task is guaranteed to be outside its fan-out (no worker executing `ht_fp`) before the pointer flips, so a worker can never call a half-swapped or freed shader. The old shader stays live until the barrier, satisfying "previous shader kept on error."
- **App exit** (`HtInteract` ESC / end of headless run): `HtRenderPause`, set `ht_render_exit`, `HtRenderResume`, then `DeathWait(&ht_render_task)` before `SettingsPop`. This drains any in-flight frame and reaps the render task before the buffers are freed — no use-after-free.
- **Self-test** already parks `Fs->draw_it=NULL` around `HtVisualDump`; add `HtRenderPause` so no background frame is in flight, then run `HtVisualDump` single-core on core 0 (unchanged), then `HtRenderResume`.
- Workers are **never `Kill`ed** — they are the kernel Seth tasks, which `Kill` explicitly refuses (`KTask.HC`), and jobs always complete within a frame, so there is nothing to kill.

Per-band fault handling: `HtShadeBandJob` wraps its shading in `try{…}catch{Fs->catch_except=TRUE; return FALSE;}` (the `HtCorpusRun` idiom) and returns `TRUE` on success. `JobRunOne` additionally wraps every `JOBT_CALL` in its own try/catch on the worker Seth task. The render task `&`s the `JobResGet` results; if any band faulted it **does not publish** (keeps the last-good front buffer). Probe-confirmed: a throwing job is absorbed and the system survives.

### Adaptive-scale controller (req 5)

The controller body is unchanged (same KVM thresholds: coarsen when `ht_shade_ms>70` for 2 frames, refine when `ht_shade_ms*4<60` for 4 frames, tuned in `HT.HC`). It simply moves out of `HtDrawIt` into the render task and consumes the render task's measured `ht_shade_ms` (now a real multicore frame time). `HtScaleReset` on shader swap is unchanged.

### Reentrancy audit of the `ht_fp` call path (req 7)

Assuming the ctx-struct fix has landed (user globals + the `htu_stamp`/`htu_iframe`/uniform globals emitted by `HTEMIT.HC` now live in a per-invocation context, not module globals):

| Item in call path | Reentrant? | Handling |
|---|---|---|
| Emitted user/uniform globals, `htu_stamp`, `htu_iframe` | Fixed by ctx track | Per-invocation ctx struct (assumed landed) — **the precondition** |
| `HTLIB.HC` vector/matrix/builtin fns | **Yes** | Audited: all pure, write only to caller-supplied `out` pointers; no `MAlloc`/`Free`, no static scratch |
| `htl_sin` LUT (HtSinF/Cos/Tan) | **Yes** | Read-only after `HtLibInit` |
| `HTMATH` LUT (`HTMSin16`…) | **Yes** | Read-only after `HTMInit` (generated code uses `HtSinF`; HTMATH is the app's own math) |
| `htr_lut`/`htr_bofs`/`htr_palette` (quantize/dither) | **Yes** | Read-only after `HTRInit`; workers only read |
| `CHtFragColor out_color`, band-local temps | **Yes** | Per-invocation stack locals; generated temps are stack structs (no per-pixel heap alloc — confirmed in `HTEMIT.HC`) |
| `CHtUniforms *u` | **Yes** | Points at the frozen `fb->snap`; workers read only |
| x87/SSE FPU state, rounding mode | **Yes** | Per-core register file (`FNINIT` at AP init); saved/restored per task-context. No cross-core sharing |
| Exceptions (`Fs->catch_except`, `except_ch`) | **Yes** | Per-task; `JobRunOne` + band `try/catch` isolate per worker |
| Output framebuffer `fb->pix` | **Yes (by construction)** | Workers write disjoint row-bands; publish is one atomic word |

**No additional non-reentrant state was found** beyond the emitted globals the ctx track already fixes. The one thing to keep an eye on: if a future generated shader ever calls `MAlloc`/`Free` per invocation, it would hit per-task heap locks — correct but a contention hotspot; each Seth task allocates from its own heap so it stays correct.

## ABI / interfaces

TempleOS primitives used (from `vendor/TempleOS/Kernel/MultiProc.HC`, `Job.HC`):

```
CJob *JobQue(I64 (*fp)(U8 *data), U8 *data=NULL, I64 target_cpu=1,
             I64 flags=1<<JOBf_FREE_ON_COMPLETE, ...);   // flags=0 to keep the result
I64   JobResGet(CJob *rqst=NULL);                         // blocks (Yield) until JOBf_DONE
```

Fan-out idiom (matches `Demo/MultiCore/MPAdd.HC`, `Primes.HC`): `JobQue(&fn, data, cpu, 0)` per band, then `JobResGet` each. `Gs->num` inside a job = the executing core. `mp_cnt` = live core count.

New/changed HolyToy symbols (all in `HT.HC` unless noted):

```
class CHtFrameBuf { CHtUniforms snap; U8 *pix; };        // NEW
CHtFrameBuf ht_fb[2];
I64  ht_fb_stride;                                        // (max_vw+63)&~63
I64  ht_front_idx=0, ht_back_idx=1;                       // published index / work index
Bool ht_have_frame=FALSE;
I64  ht_render_cores;                                     // shading cores; 1..mp_cnt
I64  ht_render_pause, ht_render_busy, ht_render_exit;     // handshake bits (LBts/LBtr/Bt)
CTask *ht_render_task;

class CHtBandDesc { I64 band, y0_blk, y1_blk, fb_idx, scale, pix_left, pix_top; };
CHtBandDesc ht_desc[MP_PROCESSORS_NUM];

U0  HtShadeBand(CHtBandDesc *d);                          // core shading+quantize+dither of a band
I64 HtShadeBandJob(U8 *data);                             // (CHtBandDesc*)data; try/catch; returns Bool ok
U0  HtRenderTask(U8 *ignored);                            // the frame loop (Spawn'd once)
U0  HtRenderPause(); U0 HtRenderResume();                 // quiesce handshake
```

`HtShadeBand` reproduces today's inline block loop **byte-for-byte** (same `ToI64(fc.*256.0)` clamps, `htr_bofs`/`htr_lut` math, Bayer phase from absolute screen coords `(pix_top+y)&3`, `(pix_left+x)&3`) so multicore output equals the current single-core output. It writes into `ht_fb[d->fb_idx].pix` at `d->fb_idx` row stride `ht_fb_stride`.

## File-level change list

| File | Change |
|------|--------|
| `src/holytoy/HT.HC` | Add `CHtFrameBuf`/`CHtBandDesc`, the two buffers, `ht_render_*` state and handshake bits. Extract today's `HtDrawIt` block loop into `HtShadeBand`. Add `HtShadeBandJob`, `HtRenderTask`, `HtRenderPause/Resume`. Rewrite `HtDrawIt` to *blit* `ht_fb[ht_front_idx].pix` + pane (no shading). Move the adaptive controller from `HtDrawIt` into `HtRenderTask`. Wrap `ht_fp` swap + `HtScaleReset` in `HtCompileAndSwapGlsl`/`HtInstallHoly` with pause/resume. In startup: alloc buffers (64B-aligned), read `E:/CORES.TXT` (mirror the `SCALE.TXT` block) → `ht_render_cores`, `Spawn(&HtRenderTask,…,-1,…)` before `HtInteract`/`HtSelfTest`. In `HtInteract` ESC path and end-of-headless: set `ht_render_exit`, `DeathWait(&ht_render_task)`, free buffers. In `HtSelfTest`: pin `ht_render_cores=1` for the SCALE sub-test (save/restore); `HtRenderPause` around the visual-dump park. Add `HtVisualDump`/`HtCorpusRun` note: keep them single-core on core 0 (unchanged). |
| `tools/mkxfer.sh` | Add one `if [ -n "${HOLYTOY_CORES:-}" ]; then echo "$HOLYTOY_CORES" | mcopy -o - x:/CORES.TXT; fi` block, next to the `HOLYTOY_SCALE` block. |
| `config.sh` | (Optional) document `HOLYTOY_CORES`; no functional change (`SMP=4` already set). |
| `tools/test.sh` | Add proof 14 (multicore byte-identical); see below. No change to proofs 1-13. |
| `src/holytoy/HTRENDER.HC`, `HTLIB.HC`, `HTMATH.HC` | **No change** — already reentrant / read-only after init. |
| `guest/RUN.HC` | **No change.** |

## How each affected proof stays deterministic

The published viewport is byte-identical across core counts by construction (probe-confirmed): identical deterministic integer/F64 math, disjoint bands, snapshotted uniforms. Proofs crop `0,8,640x288` (the viewport), which excludes the pane's `%3dms` readout that legitimately differs between core counts.

- **9 dither** (static `gradient.glsl`, `HASH1==HASH2`): a static shader produces identical bytes every frame; double buffering publishes whole frames only → the two rolling frames match. Green.
- **13 oracle** and **corpus**: `HtVisualDump`/`HtCorpusRun` stay **single-core on core 0** (they call `ht_fp` in a synchronous loop, not via the render task). Bytes unchanged. Green. (`HtRenderPause` ensures no background frame races the dump.)
- **6 holytoy**: `HT SWAP/ERRSURVIVE/RECOVER` rely on the pause/resume-guarded `ht_fp` swap; `HT SCALE` runs pinned to `ht_render_cores=1` during its sub-test so the KVM controller thresholds (validated single-core) still drive the slow fixture to `1:16` and the fast fixture to `≤1:4`. `%3dms` readout still comes from `ht_shade_ms` (now the render-task frame time). Distinct frames come from the render task animating. Green. *(Alternative if a fully-multicore SCALE test is wanted: raise `ht_glsl_slow`'s iteration count so `1:16` frame time still exceeds the 70 ms coarsen threshold at `mp_cnt` cores — but pinning is core-count-independent and lower-risk.)*
- **7 glsl-app, 10 guest-glsl, 11 circle, 12 editor**: animating/geometry/edit-recompile all flow through the render task; determinism and the before/after viewport change are preserved; editor recompile uses the swap handshake. Green.
- **Proofs 1-5, 8**: don't touch the render path (standalone toys / smoke / mouse). Unaffected.

**New proof 14 (multicore == single-core, byte-identical):** run the static `tests/glsl/gradient.glsl` twice with `HOLYTOY_SCALE=4`: once `HOLYTOY_CORES=1`, once `HOLYTOY_CORES=4`. `md5` of `imginfo.py … --crop 0,8,640x288 --hash` on a stable rolling frame must be **equal**. Deterministic because the viewport is byte-identical by construction (proof 9 already establishes intra-run determinism; this establishes inter-config determinism).

## VM-verified findings

Probe `smp/PROBE.HC`, RUN_DIR `run-20260717-151606-YVG02x` (KVM, `-smp 4`), guest.log:

```
PROBE mp_cnt=4
PROBE single ms=865 sum=1295095
PROBE multi  ms=273 sum=1295095 cores=1,2,3
PROBE COHERENT OK
PROBE SPEEDUP 316 pct
PROBE THROW SURVIVED OK
PROBE DONE
```

Verified claims:
1. **`JobQue` fan-out runs concurrently on distinct worker cores** — three bands executed on cores 1, 2, 3 (`Gs->num` captured per band). Confirms `target_cpu` placement via `JobQue`, not just `Spawn`.
2. **Cross-core coherence of a shared `MAlloc`'d buffer** — three cores wrote disjoint bands; the whole-buffer checksum after `JobResGet` (`1295095`) equals the single-core reference **exactly** → concurrent writes are fully visible after the barrier, and multicore output is byte-identical to single-core (the basis of proof 14).
3. **Fan-out efficiency ≈ ideal** — 865 ms → 273 ms = **3.16x** on 3 workers (essentially linear; measurement noise makes it read slightly superlinear). Extrapolating the 43 ms/frame F64 plasma floor: ~14 ms/frame across 3 workers — full-res exact-sin becomes interactive.
4. **Exception isolation** — a job that `throw`s was absorbed by `JobRunOne`'s try/catch on the worker Seth task; the system survived and `JobResGet` returned. Confirms the "faulting shader keeps last-good, no crash" safety property for thrown exceptions.

Budget used: 1 of 3 probe runs.

## Open questions

1. **Wild-pointer faults on a worker core.** A *thrown* exception is caught (verified). A genuine bad-pointer GPF from generated code on core `≠0` triggers `IntMPCrash` → `Panic` (whole-system, per `MultiProc.HC`), whereas today the same fault on core 0 drops into the debugger and is killed by `RUN_TIMEOUT` (recoverable-ish). This is a *shift*, not a new class of bug (both are fatal to the run), but moving risky code to workers changes the failure signature. Mitigation options to decide during impl: rely on the compiler's array bounds behavior, and/or keep the band `try/catch` (catches HolyC-level throws only). Not probed on purpose — it would crash the VM and burn budget.
2. **Per-frame `JobQue` allocation cost.** Each `JobQue` does an `ACAlloc(sizeof(CJob))` + queue insert + `MPInt` wake; `JobResGet`/`JobResScan` frees it. For 3 jobs/frame this is negligible vs multi-ms shading (unmeasured but bounded). If ever hot, a pre-allocated job-pool or persistent workers with a barrier could replace it — but that reintroduces the quiesce complexity this design avoids. Recommend measuring `ht_shade_ms` overhead at `1:1` on a cheap shader once implemented.
3. **Load imbalance for spatially non-uniform shaders** (e.g. a raymarcher cheap in sky rows). One-band-per-core can leave a worker idle. The strip over-decomposition knob (`K*nb` contiguous strips) is the answer; deferred until a corpus shader demonstrates measurable imbalance.
4. **`ht_render_cores` upper bound.** Pinned via `CORES.TXT` clamps to `mp_cnt` (=4 in CI). If `SMP` in `config.sh` ever changes, the SCALE proof's single-core pin keeps it robust, but proof 14's `CORES=4` literal should track `SMP`.
## Completion evidence

Implemented on branch `plan-012-smp-render` (base main @ 7fa12c2). All shading
moved out of `HtDrawIt` into `HtRenderTask` (spawned once on core 0); the fan
uses `JobQue(&HtShadeBandJob,&desc,1+k,0)` per band and `JobResGet` as the
barrier, into a 64-aligned double buffer published by one word store. Deviations
from the design body are noted below.

### Done criteria — all met

1. `HtDrawIt` no longer shades: it updates `ht_u` for the next snapshot and
   blits `ht_fb[ht_front_idx].pix` + pane. Editor responsive during slow shades.
2. Fan-out per the design: transient `JobQue` jobs, static contiguous row-bands
   (one per worker core 1..nb), double buffer with atomic publish, nesting
   pause/resume quiesce, single-core fallback with per-band `Yield`.
3. `HOLYTOY_CORES` env -> `E:/CORES.TXT` pin (`mkxfer.sh`), `1..mp_cnt`/`auto`,
   `>mp_cnt` clamps with `HT CORES BADPIN`. Mirrors the `SCALE.TXT` block.
4. `make test` = **14 passed, 0 failed** (13 existing, unchanged assertions, +
   new proof 14). Proof 14: `gradient.glsl` at `HOLYTOY_SCALE=4`, `CORES=1` vs
   `CORES=4` -> identical viewport hash `6d5c42e03ecb2f002f8ba8316c4dfb94`.
   Run dirs `out/runs/test-20260717-1616*` (incl. `-smp-c1`, `-smp-c4`).
5. Measured `ht_shade_ms` (pane readout) on the heavy `tests/glsl/slow-loop.glsl`
   (40000-iter fract(sin) loop), scale pinned so both configs do equal work:
   - `HOLYTOY_SCALE=16`: CORES=1 ~1380 ms, CORES=4 ~437 ms -> **3.16x**.
   - `HOLYTOY_SCALE=8` : CORES=1  5537 ms, CORES=4 1748 ms -> **3.17x**.
   3 workers (cores 1-3), matching the probe's 3.16x prediction; >= 2.5x met.
6. Corpus v2 visual **unchanged** from plan 010 (dumps single-core; `HtCorpusRun`
   holds `HtRenderPause` for the whole batch). One-boot `tools/corpus_run.sh`
   (RUN_DIR `out/runs/run-20260717-161906-MUHxkQ`): compile/install/exec
   39/51, stratum A 39/39; visual 28/39 within tolerance with the same 11
   fract(sin)-decorrelation FAILs (4lfGWr 4sfGWX 4tl3z4 MdlGz4 MtfGR4 XdsGWH
   Xlt3Dn lds3D8 lsX3DH lsX3WH tlSSDV). Oracle fixture proof 13: 100% match.
7. NOT merged to main (per task); merge is the coordinator's step.

### Deviations from the design body (all documented in HT.HC)

- `ht_render_pause` is a **nesting count**, not an `LBts`/`LBtr` bit, so a shader
  swap (`HtInstallHoly`) inside an already-paused `HtCorpusRun` cannot resume it
  early. `HtRenderPause`/`Resume` are defined ahead of `HtInstallHoly` (their
  first caller) because HolyC resolves calls top-down.
- The render task claims `ht_render_busy` **before** re-reading `ht_render_pause`
  (the design set it after the pause check); this closes a race where a pauser
  could slip past a just-starting frame.
- Single-core fallback measures **pure shading ms** (sum of per-band deltas,
  Yields excluded) so the adaptive controller behaves exactly like the validated
  pre-012 inline path; multicore `ht_shade_ms` is the real fan-out wall time.
  The render loop paces to ~30 fps (`Sleep(33-ms)`), which is also a guaranteed
  yield point and avoids pegging the workers on cheap shaders.
- `ht_fb_stride` is a fixed 64-aligned ceiling (`HT_FB_MAXW=1024`) rather than
  derived from `max_vw`, because the window may not be laid out when the buffers
  are allocated; `HtDrawIt`/the render task clamp `vw` to it. `CHtFrameBuf`
  carries a `pix_raw` field for the pre-alignment `Free`.
- Teardown (reap render task + free buffers) runs **only on GUI exit**. In the
  headless paths the render task and `draw_it` are deliberately left running so
  the winmgr keeps blitting the live, animating frame through RUN.HC's 4 s hold
  (the pre-012 behavior the screenshot proofs depend on); Reboot reclaims all.
