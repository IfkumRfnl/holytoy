---
name: holyc
description: Write correct, idiomatic HolyC for TempleOS — language semantics, graphics/DC/palette APIs, demo idioms, JIT live-reload. Use whenever reading or writing .HC files, TempleOS graphics code, or anything for the holytoy project. HolyC is NOT C; do not write HolyC from C intuition without this skill.
---

# HolyC / TempleOS

Ground truth is the TempleOS source in `vendor/TempleOS/` (clone of
cia-foundation/TempleOS). **Every signature and semantic claim must be verifiable
there** — if a symbol has zero grep hits in that tree, it does not exist; do not invent
it. `.DD` docs contain DolDoc `$...$` codes; read them with:

```
python3 skills/holyc/scripts/strip_doldoc.py vendor/TempleOS/Doc/HolyC.DD
```

## The ten mistakes that break everything

1. **No `main()`** — top-level statements run at `#include`/JIT time. A program file
   ends with a bare call: `MyDemo;`
2. **Paren-less calls**: `Dir;` calls Dir. So function *addresses* need `&`:
   `Fs->draw_it=&DrawIt;`
3. **Postfix casts only**: `x(F64)`, `p(CDC*)->body`. Prefix `(F64)x` is a compile
   error — and postfix casts REINTERPRET bits, never convert values: use `ToF64/ToI64`
   or mixed arithmetic to convert.
4. **Precedence is not C's**: `` ` `` `>>` `<<` bind ABOVE `*`; `& ^ |` above `+ -`;
   `+ -` above `< ==`. `1<<n-1` == `(1<<n)-1`. `` ` `` is the power operator.
   Re-parenthesize all bit math when translating from C.
5. **Print shortcuts**: `"Score:%d\n",score;` is a statement (calls Print). No printf.
   `'*';` sends up to 8 packed chars to PutChars. No `%o`/`%i`; `%d` is 64-bit.
6. **Types**: `U0 I8 U8 I16 U16 I32 U32 I64 U64 F64` only. No F32, no `struct/enum/
   typedef/const/unsigned` keywords, no `?:`, **no `continue`** (use goto). `class`
   replaces struct; `Bool` is a 1-byte int. Literals default to I64/F64; all math is
   64-bit. Sub-int access: `x.u8[0]`, `x.i32[1]`.
7. **Default args anywhere, skippable**: `Test(,3);`, `Spawn(&Fun,NULL,"Name",,Fs);`,
   `GetMsg(,,1<<MSG_KEY_UP);`
8. **`#include ""` only** (no `<>`), default ext `.HC.Z`, resolved against the task's
   CURRENT DIRECTORY (hence `Cd(__DIR__);;` — note the `;;`). No function-like
   `#define`. `#exe {...}` runs code at compile time. **Never include OS headers** —
   the entire Kernel/Adam API is already in scope in every task; demos include nothing.
9. **Exceptions**: `throw('Char8')` is a function; `catch` takes no arg; read
   `Fs->except_ch`; set `Fs->catch_except=TRUE` (or call `PutExcept`) or it rethrows.
10. **Chained comparisons are legal and idiomatic**: `if (0<=x<640)`.

## The graphics model in one paragraph

640x480, 16 colors, 8x8 font, ring 0, no GPU. A pixel is ONE BYTE holding a palette
index 0-15 (0xFF=transparent); row stride is `dc->width_internal` (width rounded up
to 8). Two targets: `gr.dc` (persistent — `CDC *dc=DCAlias;`, pixels stay until
`DCFill;`) and `gr.dc2` (rebuilt every frame — your `Fs->draw_it=&DrawIt;` callback
`U0 DrawIt(CTask *task,CDC *dc)` receives an alias at ~30fps, already offscreen, redraw
everything, never DCDel it). Set `dc->color` (a CColorROPU32: plain `RED`, or
`ROPF_DITHER+c1<<16+c0`, or `ROP_XOR+...`) then call `GrPlot/GrLine/GrRect/GrCircle/
GrPrint/GrBlot/GrFloodFill`. Palette: `GrPaletteColorSet(i,bgr48)` hits the VGA DAC
immediately (6 bits/channel, global to the screen) — palette cycling is 16 writes per
frame. `SettingsPush;` ... `SettingsPop;` brackets every demo (restores palette,
draw_it, and kills `Fs->animate_task`).

## Minimal demo skeleton (the real idiom)

```holyc
F64 θ;                              // state in globals; greek is idiomatic

U0 DrawIt(CTask *task,CDC *dc)
{
  dc->color=YELLOW;
  GrCircle(dc,task->pix_width/2+100*Cos(θ),task->pix_height/2+100*Sin(θ),20);
}

U0 MyDemo()
{
  SettingsPush;
  WinBorder;  WinMax;  DocClear;
  Fs->draw_it=&DrawIt;
  try {
    while (!ScanChar) {
      Sleep(20);
      θ+=2*π/70;
    }
  } catch
    PutExcept;
  SettingsPop;
}

MyDemo;
```

## Live reload (JIT redefinition — holytoy's mechanism)

JIT executes ONE top-level statement at a time — each is compiled and run before the
next is lexed (`ExeCmdLine`, `Kernel/KTask.HC:302`), so `Cd(x);;` affects the next
`#include`, and redefinitions take effect mid-file. Re-`#include`/`ExeFile` the same
file freely: new symbols **shadow** old ones in the task's hash table (by design, for
exactly this workflow). But: old code is never freed (reclaimed at task death); `&Fun`
binds at the compile time of the code containing it, so previously captured function
pointers — including an installed `draw_it` — keep hitting the OLD code until
reassigned; a reloaded file must re-run its `Fs->draw_it=&DrawIt;` line (the skeleton
above does, since setup re-executes); shadowed globals lose their values.
Details: references/runtime.md.

## Reference files (read before writing code in that area)

| File | Contents |
|---|---|
| `references/language.md` | Full language: types, literals, operators/precedence, switch extensions, classes/unions/metadata, preprocessor, exceptions, linkage |
| `references/graphics.md` | Verbatim signatures with source locations: CDC, DC lifecycle, primitives, direct body access, palette, draw_it/window, timing, input, sound, math, Exe* |
| `references/idioms.md` | Annotated real patterns from Demo/: skeletons, render modes, exit loops, animate tasks, palette cycling, ROP tricks, fixed point, style rules |
| `references/runtime.md` | JIT model, redefinition/live-reload semantics, ring 0, memory, paths/RedSea/.Z, startup chain, debugging (`Uf`, `ClassRep`, `Find`) |
| `references/gotchas.md` | Hallucination table: C-isms that fail, plausible-but-nonexistent APIs, graphics-model traps. **Check here first when something "should work"** |

Key vendor files worth opening directly: `Doc/HolyC.DD` (language), `Kernel/KernelA.HH`
(all structs/defines), `Kernel/KernelC.HH` (kernel API decls), `Adam/Gr/GrDC.HC` +
`GrPrimatives.HC` + `GrPalette.HC` (graphics impl), `Demo/Graphics/*.HC` (idioms —
`Palette.HC`, `Bounce.HC`, `Doodle.HC`, `Life.HC` are the best short reads).
