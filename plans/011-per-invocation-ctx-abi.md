# Plan 011: Per-invocation context ABI (`ht_fp` reentrancy + GLSL global semantics)

Status: DONE (branch `plan-011-ctx-abi`, 2026-07-17). ABI landed as
specified; `make test` 13/13 + `HT CTX OK`; corpus v2 stratum A 39/39
compile/install/exec, visual 28/39 (unchanged vs the plan-010 baseline).
NOT merged to main (implementer instruction). See "## Completion evidence".
Designed 2026-07-17 by an Opus 4.8 design agent (probe
`run-20260717-151439-mMR74p` verified the resident-bind mechanism and the
~6 ns/call ctx cost). Prerequisite for plan 012 (multicore shading) and
scheduled before plan 013 (F32) because both rewrite HTEMIT.HC emission.

STOP conditions: if the `needs_ctx` transitive analysis misbehaves, fall
back to always-pass (documented in Risks) rather than debugging blind; if
corpus visual moves outside the two documented legitimate-change classes,
stop and report before "fixing" anything.

## Done criteria

1. New ABI `U0 ht_fp(F64 frag_x, F64 frag_y, CHtFragColor *out_color)`
   landed exactly as specified below (CHtFrame/HtFrameSetup, CHtCtx,
   HtCtxInit, needs_ctx plumbing, shared-const classification).
2. A new in-app self-test shader mutates a user global from a nested
   helper and reads it back per-invocation (guards the needs_ctx
   analysis); prints `HT CTX OK`.
3. `make test` 13/13 (plus the new marker greped by proof 6's block).
4. Corpus v2: stratum A still 39/39 compile/install/exec; visual still
   >=28/39 with any per-shader movement attributed to the two legitimate
   classes in "Compatibility" below.
5. Merged to main once green; make test re-run post-merge.

---

## Summary

Today the emitted GLSL user globals become **process globals** (`ug<s>_<name>`) whose initializers run once at install (`HtShaderInit`), and the standard Shadertoy uniforms become process globals (`htu_*`) that a per-frame **stamp-rebind block inside `MainImage`** writes lazily. Both are wrong for the program's direction:

1. **Semantics.** GLSL globals are *per-invocation*: each fragment invocation starts with globals re-initialized (initializers re-run in declaration order), and mutations do not persist to other invocations. Process globals persist mutation across pixels, so any shader that reads a mutable global before writing it, or relies on fresh per-pixel initializer values (e.g. a global initialized from `iResolution`), can render incorrectly.
2. **Reentrancy.** The `htu_*` writes (stamp block) and the mutable `ug*` globals are shared mutable state. The multicore renderer being designed in parallel calls `ht_fp` from several cores concurrently; shared mutable state is a data race and blocks it.

This design splits shader state into two disjoint parts:

- **Per-frame, shared read-only** — the derived Shadertoy uniforms. Lifted out of generated code into a runtime-owned struct `CHtFrame ht_frame`, filled **once per frame** by a new runtime function `HtFrameSetup` before any worker runs. The per-frame stamp-rebind block is deleted. Generated uniform reads become `ht_frame.<field>`.
- **Per-invocation, private** — mutable ("non-`const`") user globals. Moved into a generated `class CHtCtx`, stack-allocated inside the `MainImage` glue, zero-initialized then re-initialized in declaration order at the top of every invocation, and threaded by pointer into the (transitively) touching user functions.
- **Shared read-only const globals** (const-qualified with static-safe constant initializers — including big const lookup arrays) **stay** process globals, initialized once at install. This is both correct (immutable, identical every invocation) and fast (no per-pixel copy).

The new `ht_fp` ABI drops both `u` and any ctx parameter: `U0 ht_fp(F64 frag_x, F64 frag_y, CHtFragColor *out_color)`. All inputs are per-call stack args plus shared read-only state; the only output is the caller-owned `out_color`. `ht_fp` becomes fully reentrant with no internal locking. When a shader has zero mutable globals, no `CHtCtx`, no ctx local, no init, and no ctx plumbing is emitted — overhead is exactly zero.

The probe (`run-20260717-151439-mMR74p`) verified the load-bearing mechanism and that per-invocation ctx cost is in the noise.

## Design

### 1. Classification of emitted globals

Walk the top-level `HT_AST_DECL` nodes in declaration order and classify each global symbol into exactly one bucket:

- **Shared read-only (stays a process global):** the global is `const` (`HTF_CONST` set) **and** its initializer is *static-safe*. Emitted and initialized exactly as today (unit-scope declaration; initializer run once in `HtShaderInit` at install). This is the fast, correct home for constants and const lookup arrays/tables.
- **Per-invocation (moves into `CHtCtx`):** everything else — i.e. any non-`const` global, and any `const` global whose initializer is *not* static-safe.

*static-safe* initializer predicate `HtInitStaticSafe(p, node)` (recursive over the initializer AST):
- `HT_AST_NUMBER` → true; `NAME` bound `true`/`false` → true.
- `HT_AST_NAME` bound to a symbol → true **iff** that symbol is a global already classified *shared read-only* (references to uniforms, per-invocation globals, params, or locals → false).
- `HT_AST_UNARY`, `HT_AST_BINARY`, `HT_AST_INDEX`, `HT_AST_MEMBER`, `HT_AST_TERNARY`, `HT_AST_SEQ` → true iff all operand subtrees are static-safe.
- `HT_AST_CALL` → true iff `bind` is `HT_CALL_CTOR`/`HT_CALL_BI`/`HT_CALL_STRUCT` and all argument subtrees are static-safe (`HT_CALL_USER` → false).
- `HT_AST_ARRCTOR` → true iff all element subtrees are static-safe.
- anything else → false.

Because GLSL requires an earlier-global to be declared before it is referenced, and this pass runs in declaration order recording each global's bucket, the `NAME`-references-shared-const case is always resolvable. Demote-on-doubt is always *safe*: a demoted const simply gets re-evaluated per invocation (correct), only losing the shared fast path.

Rationale for using const-ness (not initializer-constness) as the primary axis: a mutable global with a constant initializer is still per-invocation — sharing it across concurrent invocations both races and leaks writes between pixels. `const` is exactly the "immutable, safe to share" set, and sema already enforces const-non-assignability (`HtSemaIsLval`: `if (s->flags&HTF_CONST) return FALSE;`).

Store the classification as a per-symbol bool (e.g. `Bool per_inv` on `CHtSym`, or a side array in the emitter keyed by symbol index).

*Simpler acceptable fallback:* `const ⇒ shared`, `non-const ⇒ per-invocation`, skipping the static-safe guard. The guard only matters for a const global whose initializer reads a uniform/per-invocation global — which is illegal GLSL and absent from the corpus. Implement the guard anyway: it is cheap and closes a latent wrong-output path (today such a const reads uniforms that are zero at install time).

### 2. The per-invocation context struct

- **Type.** Emit `class CHtCtx { … };` with one member per per-invocation global, member name = the existing `HtSymText` spelling (`ug<s>_<name>`), member type/array-arity emitted exactly like the current user-global declarations. Emit the class **after** the user struct classes and **before** any function (functions reference `CHtCtx*`). **Emit nothing** (no class, no local, no init, no plumbing) when the per-invocation set is empty.
- **Allocation.** In the `MainImage` glue, on the stack:
  ```
  CHtCtx ctx_store;
  CHtCtx *ctx=&ctx_store;
  ```
  A single pointer name `ctx` is used everywhere (glue, init, user functions), so all per-invocation references are uniformly `ctx->ug<s>_<name>` and all forwarding is the bare token `ctx`. The glue is the only place that materializes storage and takes its address.
- **Initialization order & timing.** Emit `U0 HtCtxInit(CHtCtx *ctx)` that:
  1. `MemSet(ctx,0,sizeof(CHtCtx));` — deterministic zero for globals lacking initializers (GLSL leaves these undefined; zeroing removes nondeterminism that a live stack would otherwise introduce).
  2. runs each per-invocation global's initializer in **declaration order** via `HtEmDeclInit` (which now targets `ctx->…`). Initializers may read `ht_frame.*` (current-frame uniforms — strictly more correct than the old install-time init), shared consts, and earlier per-invocation globals; they may call user functions (ctx is in scope and forwarded).
  The glue calls `HtCtxInit(ctx);` at the top of every invocation. This is the per-invocation re-initialization GLSL semantics require.
- **Cost.** Probe: 1M invocations with ctx init + two threaded calls = 6 ms under KVM (~6 ns/call). Against ~140 ns/pixel F64 shading this is negligible. Zero per-invocation globals ⇒ none of this is emitted ⇒ literally zero cost.

### 3. Function plumbing (which functions get `CHtCtx *ctx`)

Use **transitive "only-if-touches"**: only functions that (transitively) reference a per-invocation global carry the ctx parameter. Pure math helpers — the common case — keep their current signatures and call cost. (Perf is not the deciding factor per the probe; this is chosen for lean, legible generated code and to stay out of the way of the later one-liner-builtin inlining plan, which concerns runtime builtins, not user functions.)

Compute a `Bool needs_ctx[func_node]` before emission:
1. `direct[F]` = does `F`'s body reference (value/lvalue/addr) a per-invocation global symbol? (single AST walk of the body).
2. Reuse `HtEmCollectCalls` to get each `F`'s direct user-callee set.
3. Propagate: `needs_ctx[F] = direct[F] || any(needs_ctx[callee])`. GLSL forbids recursion, so a post-order fixpoint over the existing topo order terminates.
4. **Force** `needs_ctx[main_node]=TRUE` whenever the per-invocation set is non-empty, so the entry always threads ctx and the init/entry path is coherent even for a (degenerate) shader whose `mainImage` never itself touches a global.

Canonical parameter/argument order (must match between `HtEmFuncDef` and `HtEmUserCall`): **`ctx` (if `needs_ctx`), then the composite-return pointer `ht_ret` (if composite return), then declared params.**

Both `HtEmFuncDef` (parameter list) and `HtEmUserCall` (argument list) consult `needs_ctx[callee]`. In `HtEmUserCall`, prepend the literal token `ctx` as the first argument when the callee needs it (before the composite-return pointer and before real args). Because every enclosing scope that can emit such a call holds a `CHtCtx *ctx` (user functions and `HtCtxInit` by parameter; the glue by its `ctx` pointer local), forwarding is always the bare `ctx`.

### 4. `ht_fp` ABI and caller changes

New signature (drop `u`; ctx is glue-local, not an ABI parameter):
```
U0 (*ht_fp)(F64 frag_x, F64 frag_y, CHtFragColor *out_color);
```
`ht_default_fp`, `ht_new_fp`, the built-in `MainImage`, and the generated `MainImage` all take this exact signature.

**Reentrancy contract (state explicitly in code comments and the plan):**
`ht_fp` reads only (a) its scalar `frag_x/frag_y` args (per-call, private), (b) the shared read-only `ht_frame` (derived uniforms for the current frame), and (c) shared read-only const globals and LUTs (`htl_sin`, palette/Bayer tables, built once at init). It writes only through `out_color` (caller-owned) and its own stack (`CHtCtx`, temps). Therefore concurrent calls from multiple cores are safe **without any lock**, provided the caller guarantees:
1. `ht_frame` has been filled by `HtFrameSetup` on the control core **before** the first worker starts, and is **not mutated** until **all** workers for that frame have joined;
2. each concurrent call is given a **distinct** `CHtFragColor` output;
3. no shader install / `ht_fp` rebind (`HtInstallHoly`) runs during fan-out — installs happen on the control core between frames.

The multicore renderer (separate design) therefore does per frame: `HtFrameSetup(&ht_u)` → spawn workers (each with a private `CHtFragColor`) → join all → composite → (optionally install/rebind) → next frame.

New runtime pieces in HT.HC:
```
class CHtFrame
{
  F64 itime,itdelta,ifrate;
  CHtV3 ires;
  CHtV4 imouse,idate;
  I64 iframe;
};
CHtFrame ht_frame;                 // filled once/frame; read-only during shading

U0 HtFrameSetup(CHtUniforms *u)    // the OLD generated stamp block, verbatim, lifted to runtime
{
  ht_frame.itime=u->i_time;
  ht_frame.itdelta=1.0/30.0;
  ht_frame.ifrate=30.0;
  ht_frame.iframe=u->i_frame;
  ht_frame.ires.x=u->res_x; ht_frame.ires.y=u->res_y; ht_frame.ires.z=1.0;
  ht_frame.imouse.x=u->mouse_x;
  ht_frame.imouse.y=u->res_y-u->mouse_y;
  if (u->click_x<0) { ht_frame.imouse.z=0.0; ht_frame.imouse.w=0.0; }
  else {
    ht_frame.imouse.z=u->click_x;
    ht_frame.imouse.w=u->res_y-u->click_y;
    if (!u->mouse_lb) { ht_frame.imouse.z=-ht_frame.imouse.z;
                        ht_frame.imouse.w=-ht_frame.imouse.w; }
  }
  ht_frame.idate.x=u->date_year; ht_frame.idate.y=u->date_mon;
  ht_frame.idate.z=u->date_day;  ht_frame.idate.w=u->date_secs;
}
```
`CHtFrame`/`ht_frame` must be declared **before** the built-in `MainImage` (which now reads `ht_frame.itime`). `CHtV3/CHtV4` are already available (HTLIB.HC is included first). Generated units bind `ht_frame` as a resident symbol — **probe-verified**.

Caller edits (all four are simple, and remove the stamp/sentinel dance):
- **`HtDrawIt`**: after populating `ht_u.*` (date/time/res/mouse) and before the `by/bx` loops, call `HtFrameSetup(&ht_u);`. Change the shade call from `ht_fp(&ht_u, bx*…, vh-…, &fc)` to `ht_fp(bx*…, vh-…, &fc)`.
- **`HtVisualDump`**: delete the `u.i_frame=-1` sentinel prime + throwaway call (its only purpose was to force exactly one stamp rebind). Set `u.*`, then `u.i_frame=frame; HtFrameSetup(&u);` once, then loop `ht_fp(px,py,&fc)`. Now deterministic regardless of sample order.
- **`HtCorpusRun`**: set `ht_u.i_time/res_*`, call `HtFrameSetup(&ht_u);` before the sample loop; change `ht_fp(&ht_u,px,py,&fc)` → `ht_fp(px,py,&fc)`.
- **built-in `MainImage`**: new signature; read `F64 t=ht_frame.itime;` instead of `u->i_time`.
- **`HtSelfTest`** exercises `ht_fp` only via `HtDrawIt`, so it needs no direct call changes; its frame-advance checks (`ht_u.i_frame`) remain valid. `HtLoadGlsl`'s single-shader dump path must **keep** its `Fs->draw_it=NULL; Sleep(250)` park — now for a new reason: it prevents `HtDrawIt` on the control path from rewriting the shared `ht_frame` while `HtVisualDump` uses it.

### 5. Compatibility

- **No-global and const-only shaders (the bulk of stratum A):** generated code is identical except the stamp block is gone and uniform reads are renamed `htu_*` → `ht_frame.*`. `HtFrameSetup` computes the same values the stamp block did. Output is bit-identical. 39/39 compile and 28/39 visual are preserved. The proof suite (pins `HOLYTOY_SCALE=4`, deterministic frame hashes) should stay green.
- **Shaders with mutable globals — output may *legitimately* change toward correctness in two narrow cases only:**
  1. a global that is **read before being written** within an invocation now sees its initializer/zero instead of the previous pixel's leftover (previously order-dependent and nondeterministic);
  2. a global whose (illegal-GLSL) initializer reads a uniform now sees the current frame's value instead of the install-time zero.
  Normal shaders write-before-read their scratch globals, so their per-pixel output is unchanged. This change never makes a *correct* shader wrong; it only fixes previously undefined/leaky behavior. Flag any visual-oracle movement to these two classes when re-measuring.
- **Determinism improves:** removing the stamp cache and the `-1` sentinel eliminates the frame-rebind race the current dump path works around, making the oracle more robust.

## ABI / interfaces

- `U0 ht_fp(F64 frag_x, F64 frag_y, CHtFragColor *out_color)` — reentrant; contract in §4.
- `CHtFrame` (runtime) + global `CHtFrame ht_frame` — per-frame derived uniforms, shared read-only during shading.
- `U0 HtFrameSetup(CHtUniforms *u)` (runtime) — control-core, once/frame, before fan-out.
- Generated `class CHtCtx { … }` — per-invocation mutable-global storage (emitted only when non-empty).
- Generated `U0 HtCtxInit(CHtCtx *ctx)` — `MemSet` + declaration-order initializers (emitted only when non-empty).
- Generated `U0 MainImage(F64 frag_x, F64 frag_y, CHtFragColor *out_color)` — glue; owns `CHtCtx ctx_store; CHtCtx *ctx=&ctx_store;` when non-empty.
- Generated user functions: parameter order `(CHtCtx *ctx?, <ret ptr>?, <params>)`; only ctx-touching functions get `ctx`.
- `HtShaderInit()` (generated) — now initializes shared-const globals only; `htu_stamp=-1` removed. May be empty.
- `ht_new_fp`/`ht_default_fp` retyped to the new signature. `HtInstallHoly` still appends `ht_new_fp=&MainImage;` (unchanged text).

## File-level change list

- **`src/holytoy/HTLOWER.HC`** — add the per-symbol per-invocation classification: extend `CHtSym` with a `Bool per_inv` (or expose enough for the emitter to classify), add `HtInitStaticSafe(p,node)`, and set each global symbol's bucket in declaration order during `HtLower`'s top-level pass (§1). (Alternatively the classification can live entirely in the emitter keyed by symbol index; put it wherever symbol flags are most naturally read.)
- **`src/holytoy/HTEMIT.HC`** —
  - Add `HtSymRef(e,s,buf)`: emits `ctx->ug<s>_<name>` for per-invocation globals, else falls through to `HtSymText`. Add `HtGlobalPerInvocation(p,s)` predicate.
  - Redirect **reference sites** to `HtSymRef`: NAME value in `HtEmExpr` (the symbol else-branch, ~L1271-1285), NAME lvalue in `HtEmLval` (~L350-364), NAME address in `HtEmLvalAddr` (~L486-495), and the init-target name in `HtEmDeclInit` (L1561). `HtSymText` remains for storage declarations (struct members, shared-const globals, locals, ctx members) and param names.
  - Change uniform bind strings in `HtEmExpr` (L1242-1268): `htu_itime`→`ht_frame.itime`, `htu_ires`→`ht_frame.ires`, `htu_imouse`→`ht_frame.imouse`, `htu_idate`→`ht_frame.idate`, `htu_iframe`→`ht_frame.iframe`, `htu_itdelta`→`ht_frame.itdelta`, `htu_ifrate`→`ht_frame.ifrate`.
  - `HtEmFuncDef` (L1725): prepend `CHtCtx *ctx` param when `needs_ctx[f]`, in the canonical order (ctx, then `ht_ret`, then params).
  - `HtEmUserCall` (L1122): prepend `ctx` argument when `needs_ctx[callee]`, canonical order; keep existing composite-return / void handling after it.
  - Add the `needs_ctx` analysis (direct-touch AST walk + transitive propagation reusing `HtEmCollectCalls`), computed in `HtEmit` before function emission; force `needs_ctx[main_node]=TRUE` when per-invocation set non-empty.
  - `HtEmit` (L1849-1966): (a) delete the `htu_*` uniform-global declaration block (L1879-1881); (b) split the user-globals loop (L1882-1895) into shared-const process-global declarations vs collection of per-invocation globals; (c) emit `class CHtCtx {…}` (after struct classes, before functions) when non-empty; (d) new `MainImage` glue without the stamp block (delete L1915-1940), with the `ctx_store`/`ctx`/`HtCtxInit(ctx)` prologue and ctx-aware `mainImage` call when non-empty; (e) emit `HtCtxInit` (`MemSet` + per-invocation initializers in decl order) when non-empty; (f) `HtShaderInit` now runs only shared-const initializers, drop `htu_stamp=-1`.
- **`src/holytoy/HT.HC`** — add `class CHtFrame` + `CHtFrame ht_frame;` before `MainImage` (~L38); add `U0 HtFrameSetup(CHtUniforms *u)` before `HtDrawIt`; retype `ht_fp`/`ht_default_fp`/`ht_new_fp` to the new signature (L40-41, L154); rewrite built-in `MainImage` to new signature reading `ht_frame.itime` (L87-98); in `HtDrawIt` call `HtFrameSetup(&ht_u)` before the shade loops and drop `&ht_u` from the `ht_fp` call (L255); in `HtVisualDump` remove the `-1` sentinel prime and throwaway call, call `HtFrameSetup(&u)` once, drop `&u` from `ht_fp` (L355-364); in `HtCorpusRun` call `HtFrameSetup(&ht_u)` before the sample loop and drop `&ht_u` (L559); leave the `HtLoadGlsl` draw_it park/`Sleep` in place (now guards `ht_frame`).
- **`src/holytoy/HTLIB.HC`, `HTMATH.HC`, `HTRENDER.HC`, `HTPP.HC`, `HTLEX.HC`, `HTPARSE.HC`, `HTCOMP.HC`** — no changes required (builtins/LUTs are already stateless pure functions over shared read-only tables; `HtCompileGlsl` is unchanged).
- **Docs** — record the new reentrancy contract and the ctx/`ht_frame` split (e.g. a note under `docs/notes/`), and the two output-change classes for corpus re-measurement. (Not part of code; per repo conventions, do not touch README.)

## Risks & mitigations

- **`ctx`-forwarding token mismatch (value vs pointer).** Mitigated by making the glue hold ctx via a pointer local (`CHtCtx *ctx=&ctx_store;`) so every scope forwards the bare `ctx` and every reference is `ctx->…`. No `&ctx`/`ctx` branching in the emitter.
- **Parameter/argument order drift between `HtEmFuncDef` and `HtEmUserCall`.** Mitigated by fixing one canonical order (ctx, ret-ptr, params) and consulting the same `needs_ctx[]` array in both.
- **Large mutable global (big array) now per-invocation.** Each concurrent worker gets its own copy (required for correctness) and `HtCtxInit` `MemSet`s it every pixel — a 4096-float mutable global is a 32 KB memset/pixel and multiplies stack use per worker. Rare (mutable global arrays are uncommon; lookup tables are `const` → shared). Mitigation if it appears: initialize per-member instead of blanket `MemSet`, or skip the zero for globals proven write-before-read; and size worker stacks accordingly. Flag but defer.
- **`needs_ctx` transitive analysis bug** (missing a touch → a function reads `ctx->…` without a `ctx` param, or passes `ctx` it doesn't have). Mitigation: the always-pass variant (thread ctx into *every* user function whenever the per-invocation set is non-empty) is a drop-in fallback with the same ABI shape and only a dead-pointer-arg cost (~6 ns/call territory, negligible). Land only-if-touches with a self-test shader that mutates a global from a nested helper; fall back to always-pass if it misbehaves.
- **Resident-global read from a JITed unit failing to bind.** De-risked by probe (`PROBE BIND OK`).
- **Output changes flagged as regressions.** The two legitimate-change classes (read-before-write globals; const-from-uniform) are documented; re-run the corpus visual oracle and attribute any movement before treating it as a regression.

## VM-verified findings

- **Probe run `run-20260717-151439-mMR74p`** (`make run SRC=…/scratchpad/ctxabi/PROBE.HC`), `guest.log`:
  - `PROBE R100=2500`, `PROBE BIND OK` — an `ExePutS2`-compiled unit read a member of a resident runtime global struct (`pf_frame.itime`), called an earlier-compiled resident function (`PfHelper`), defined and threaded an in-unit `CHtCtx*` through its own functions (`pf_uf`), and bound a resident function pointer to its `MainImage`. This is exactly the `ht_frame`/`CHtCtx`/`ht_fp` pattern the design uses. Confirms the whole architecture binds under the real install path.
  - `PROBE TIME ctx1M 6 ms` — 1,000,000 ctx-threaded invocations (stack ctx + two threaded helper calls + one resident call + one resident-global read) in 6 ms under KVM (~6 ns/call). Per-invocation ctx init and pointer plumbing are negligible versus the ~140 ns/pixel F64 shading budget (docs/notes/perf-floor.md), so the only-if-touches-vs-always-pass choice is about code cleanliness, not performance, and "zero cost when no globals" is well within reach.
- Environment facts relied on (already verified today per task brief): KVM on; `-smp 4`; `Spawn(&fn,NULL,name,1)` runs on core 1 — these underpin the multicore reentrancy contract but were not re-measured here.

## Open questions

1. **`iTimeDelta`/`iFrameRate` fidelity.** `HtFrameSetup` still hardcodes 1/30 and 30 (as the old stamp block did). `HtFrameSetup` is now the natural place to compute real per-frame deltas from `tS`; out of scope here but worth wiring when the SMP renderer lands.
2. **Zero-init policy for initializer-less per-invocation globals.** This design `MemSet`s them (deterministic); GLSL technically leaves them undefined. If any corpus shader depends on that being genuinely uninitialized (none should), revisit.
3. **Should `HtShaderInit`/`HtCtxInit` be inlined into the glue** rather than emitted as separate functions? Separate functions are clearer and the call cost is negligible (probe); left as an implementer preference.
4. **SMP worker API.** This doc fixes only the `ht_fp` reentrancy contract and the `ht_frame`/`HtFrameSetup` seam. The worker partition scheme, `Spawn`/join, and per-worker output buffers belong to the parallel multicore-renderer design; they must honor the §4 contract (fill `ht_frame` before fan-out; private `CHtFragColor`; install only between joined frames).
5. **Interaction with the fast-F32 track (plan 011).** F32 semantics change the arithmetic inside generated code and `HtSinF`, orthogonal to this state split; no ordering dependency, but both touch generated `MainImage` output, so land and re-measure the visual oracle once rather than twice if scheduled together.

---

## Completion evidence

Implemented on branch `plan-011-ctx-abi` (2026-07-17), not merged to main
(implementer instruction). Commits:

- `4d04be8` compiler: HTLOWER classification (`CHtSym.per_inv`,
  `HtGlobalPerInvocation`, `HtInitStaticSafe`, decl-order bucketing) +
  HTEMIT ctx ABI (`HtSymRef`, `class CHtCtx`, `HtCtxInit`, reentrant
  `MainImage` glue, `ht_frame.*` uniform reads, `needs_ctx` fixpoint,
  ctx-first parameter/argument threading).
- `f41a0ac` runtime: `CHtFrame ht_frame` + `HtFrameSetup`, retyped
  `ht_fp`/`ht_default_fp`/`ht_new_fp`/built-in `MainImage`, updated
  `HtDrawIt`/`HtVisualDump` (sentinel prime removed)/`HtCorpusRun` callers,
  `HT CTX OK` self-test + test.sh proof-6 gate.
- `c29150b` docs note `docs/notes/ctx-frame-abi.md`.

### As landed (for plan-012/013 implementers)

- **ABI:** `U0 ht_fp(F64 frag_x, F64 frag_y, CHtFragColor *out_color)`.
  Exactly as specified; `u` dropped, ctx is glue-local (never an ABI param).
- **`CHtFrame`** (HT.HC, declared before the built-in `MainImage`):
  `F64 itime,itdelta,ifrate; CHtV3 ires; CHtV4 imouse,idate; I64 iframe;`.
  Global `CHtFrame ht_frame;`.
- **`U0 HtFrameSetup(CHtUniforms *u)`** fills `ht_frame` from the raw
  `CHtUniforms` once per frame on the control core (the old stamp block
  verbatim; still hardcodes `itdelta=1/30`, `ifrate=30`). Callers:
  `HtDrawIt` (before the shade loops), `HtVisualDump` (once, after setting
  the pinned state), `HtCorpusRun` (per shader, before the exec samples).
- **Generated layout:** struct classes -> shared-const process globals ->
  `class CHtCtx {...}` (only if non-empty) -> user functions (topo) ->
  `HtCtxInit` (only if non-empty; `MemSet` + decl-order per-invocation
  initializers) -> `MainImage` glue -> `HtShaderInit` (shared-const inits
  only; may be empty; the `htu_stamp=-1` line is gone) -> `HtShaderInit;`.
  `HtCtxInit` is emitted **before** `MainImage` (no HolyC prototypes).
- **ctx threading:** `needs_ctx[F] = F directly touches a per-invocation
  global OR any transitive callee does`; `mainImage` forced true when the
  per-invocation set is non-empty. Canonical order everywhere:
  **`ctx`, then composite-return pointer, then declared params**. Glue owns
  `CHtCtx ctx_store; CHtCtx *ctx=&ctx_store;` so forwarding is the bare
  token `ctx` and every reference is `ctx->ug<s>_<name>`. Landed the
  only-if-touches variant (the always-pass fallback was not needed).
- Zero per-invocation globals => no `CHtCtx`/init/plumbing emitted; the
  no-global path is bit-identical to pre-011 minus the stamp block.

### Verification

- **`make test` 13/13** (`-- 13 passed, 0 failed --`). The `holytoy` proof
  now also greps `HT CTX OK`. Self-test markers observed in
  `run-20260717-154034-lbWq1Q`: SWAP/IDENT/ERRSURVIVE/RECOVER/MATH/LIB/
  DITHER/**CTX**/SCALE all OK.
- **`HT CTX OK` fixture** (`ht_glsl_ctx`): a mutable global `g_acc=2`
  bumped +2 through a nested helper chain (`mainImage`->`addTwo`->`addOne`)
  reads back as 4 (=> r=1.0) on three consecutive `ht_fp` calls at one
  point with no accumulation — guards the transitive `needs_ctx` analysis
  and per-invocation re-init.
- **VM spot checks:** `tests/glsl/gradient.glsl` (no globals,
  `run-20260717-153942-VYqFaa`) and a mutable-global-via-nested-helper
  shader (`run-20260717-154010-rl9jEh`) both `HT GUEST GLSL OK`.
- **Corpus v2** (`run-20260717-154447-Ycxs8E`, `HOLYTOY_SCALE` default):

  | metric | before (plan 010) | after (plan 011) |
  |--------|-------------------|------------------|
  | compile stratum A | 39/39 | 39/39 |
  | install/exec stratum A | 39/39 | 39/39 |
  | stratum B (texture) | 0/12 | 0/12 |
  | visual stratum A | 28/39 | 28/39 |

  17 of the 39 stratum-A shaders declare mutable globals and thus exercise
  the per-invocation ctx path; all render within tolerance (write-before-
  read, output unchanged). The 11 visual FAILs are the identical
  documented white-noise-hash precision cluster (9 use `fract(sin(x)*<big>)`
  directly; `Xlt3Dn`/`tlSSDV` use Dave-Hoskins `fract`-multiply hashes) —
  the plan-010 LUT-sin/F64 deviation, not state handling. No shader crossed
  the tolerance boundary; no movement outside the two legitimate change
  classes (none were triggered — every corpus mutable global is
  write-before-read). No STOP condition hit.