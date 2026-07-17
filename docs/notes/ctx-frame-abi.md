# Per-invocation ctx ABI and the ht_frame split (plan 011)

HolyToy shader state is split into two disjoint parts so `ht_fp` can be
called concurrently from several cores without a lock.

## `ht_fp` signature and reentrancy contract

```
U0 ht_fp(F64 frag_x, F64 frag_y, CHtFragColor *out_color);
```

`ht_fp` reads only: (a) its scalar `frag_x`/`frag_y` args (per-call,
private); (b) the shared read-only `ht_frame` (this frame's derived
uniforms); and (c) shared read-only const globals and LUTs (`htl_sin`,
palette/Bayer tables, built once at init). It writes only through
`out_color` (caller-owned) and its own stack (`CHtCtx`, temps).

Concurrent calls from multiple cores are therefore safe **without any
lock**, provided the caller guarantees:

1. `ht_frame` has been filled by `HtFrameSetup` on the control core
   **before** the first worker starts, and is **not mutated** until **all**
   workers for that frame have joined;
2. each concurrent call is given a **distinct** `CHtFragColor` output;
3. no shader install / `ht_fp` rebind (`HtInstallHoly`) runs during
   fan-out — installs happen on the control core between frames.

Per-frame the driver does: `HtFrameSetup(&u)` -> spawn workers (each with a
private `CHtFragColor`) -> join all -> composite -> (optionally
install/rebind) -> next frame.

## Per-frame, shared read-only: `CHtFrame ht_frame`

`class CHtFrame { F64 itime,itdelta,ifrate; CHtV3 ires; CHtV4
imouse,idate; I64 iframe; };`, one runtime-owned global `CHtFrame
ht_frame`. `HtFrameSetup(CHtUniforms *u)` (the old per-frame stamp block,
lifted verbatim to the runtime) fills it once per frame. Generated units
read these as `ht_frame.<field>` (resident-symbol bind, probe-verified).
The old `htu_*` process globals and the `MainImage` stamp-rebind block are
gone.

## Per-invocation, private: generated `CHtCtx`

Mutable ("non-`const`") user globals — and any `const` global whose
initializer is not static-safe — move into a generated `class CHtCtx`,
stack-allocated inside the `MainImage` glue, zero-initialized then
re-initialized in declaration order at the top of every invocation
(`HtCtxInit`). This gives GLSL per-invocation global semantics: each
fragment starts with globals freshly re-initialized and mutations never
leak to other pixels.

`const` globals with static-safe initializers (constants, const lookup
tables) **stay process globals**, initialized once at install by
`HtShaderInit` — correct (immutable) and fast (no per-pixel copy).

### Function plumbing

Only functions that (transitively) reference a per-invocation global carry
a `CHtCtx *ctx` parameter (only-if-touches, computed by a call-graph
fixpoint; `mainImage` is forced on when the per-invocation set is
non-empty). Canonical parameter/argument order is **`ctx` (if needed), then
the composite-return pointer, then declared params**. When a shader has
zero per-invocation globals, no `CHtCtx`, no init, and no ctx plumbing is
emitted — overhead is exactly zero and output is bit-identical to the
pre-011 no-global path (minus the removed stamp block).

## Two legitimate output-change classes

Removing the shared mutable `ug*` process globals fixes two previously
undefined/leaky behaviors (never makes a correct shader wrong):

1. a global **read before being written** within an invocation now sees
   its initializer/zero instead of the previous pixel's leftover;
2. a global whose (illegal-GLSL) initializer reads a uniform now sees the
   current frame's value instead of the install-time zero.

Attribute any corpus visual-oracle movement to these classes when
re-measuring; movement outside them is a regression, not a fix.
