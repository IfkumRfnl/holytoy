# Gotchas — things models get wrong about HolyC/TempleOS

Each entry: the hallucination, the truth, the source. When in doubt, grep
`vendor/TempleOS` — if a symbol has zero hits there, IT DOES NOT EXIST.

## Language traps (writing C by accident)

| You'll want to write | Reality | Source |
|---|---|---|
| `int main() {...}` | No main. Top-level statements run at #include time; end file with `MyDemo;` | Doc/HolyC.DD |
| `printf(...)` | `Print(...)`, or just `"fmt",args;` as a statement | Doc/HolyC.DD |
| `(F64)x`, `(CDC*)p` | Postfix only: `x(F64)`, `p(CDC*)` — prefix cast is a compile ERROR | Compiler/PrsExp.HC:729 |
| `cond ? a : b` | No ternary. Use if/else (no continue either — use goto) | Doc/HolyC.DD |
| `continue;` | Doesn't exist. `goto` to a label at loop end | Doc/HolyC.DD |
| `a << (b-1)` habits | `<<`/`>>`/`` ` `` bind ABOVE `*`; `& ^ |` above `+ -`; `+ -` above comparisons. Re-parenthesize all bit math | Doc/HolyC.DD precedence table |
| `x ^ 8 == y` | In C this is `x^(8==y)`; in HolyC `^` binds above `==`, so it's `(x^8)==y`. Bitwise-vs-comparison precedence is inverted from C | Compiler/CInit.HC:287-330 |
| `struct`, `enum`, `typedef`, `const`, `unsigned` | None exist. `class` only; #define for constants | Compiler/OpCodes.DD:140-188 |
| `float`, `F32` | No 32-bit float at all. F64 only | Doc/HolyC.DD |
| `#include <file.h>` | `#include "file"` only; default ext .HC.Z; resolves vs CURRENT DIR | Doc/PreProcessor.DD |
| `#define MAX(a,b) ...` | No function-like macros | Doc/HolyC.DD |
| `va_list/va_arg` | Implicit `argc`/`argv[]` in `...` functions | Doc/HolyC.DD |
| `callback = DrawIt;` | Bare name is a CALL (paren-less). Must write `&DrawIt` | Doc/HolyC.DD |
| `catch (Exception e)` | `catch` takes nothing; code is in `Fs->except_ch`; set `Fs->catch_except=TRUE` or it auto-rethrows | Kernel/KExcept.HC |
| `throw SomeObject;` | `throw('Char8')` — a function taking a ≤8-char char const | Kernel/KExcept.HC:86 |
| `0755`, `1UL`, `1.0f` | No octal, no literal suffixes. `0b1010` binary exists | Compiler/Lex.HC:517-562 |
| `"\a\b\f\v"` | Not escapes (backslash kept literally). Only `\0 \' \` \" \\ \d \n \r \t \x??` | Compiler/Lex.HC:377-424 |
| `$` in a string | `$` is the DolDoc escape — write `$$` or `\d` for a literal dollar | Doc/HolyC.DD |
| big local arrays | Stack does NOT grow. MAlloc anything large | Doc/HolyC.DD |
| `%ld %lld %o %i` | `%d` is 64-bit already; no octal/`%i`. HolyC adds `%b %n %z %p %D %T %,d` | Kernel/StrPrint.HC |
| include guards | Unnecessary; re-inclusion shadows symbols by design | Doc/ScopingLinkage.DD |
| `#include "KernelA.HH"` | Never include OS headers — the whole Kernel/Adam API is already in every task's symbol chain; demo files include nothing | Doc/Hash.DD |
| `switch` with sparse cases | Always a jump table — huge sparse ranges explode. Also: `case 4...7:`, auto-number `case:`, `switch []` nobounds, `start:`/`end:` porches | Doc/HolyC.DD |

## API near-misses (plausible names that DON'T exist)

Verified absent by grep; the real name follows.

- `gr_palette` global → per-DC `dc->palette[16]`; std palettes are only
  `gr_palette_std` / `gr_palette_gray` (`Adam/Gr/GrPalette.HC:64,70`).
- `LFBFlush` / framebuffer flush → none. Winmgr converts gr.dc2's 8-bit body to VGA
  planes each frame. (`VGAFlush()` exists but is a mode reset, not a blit.)
- `PutPixel` / `GrPixel` / `SetPixel` → `GrPlot(dc,x,y)` (clipped) / `GrPlot0` (raw).
- `GrBitMap()` → not a function; GrBitMap.HC is a filename.
- `KeyGet` / `CharScan` → `GetKey`, `GetChar`, `ScanKey`, `ScanChar`.
- `FBlink` → `Blink(F64 Hz=2.5)`.
- `DCSymbol` → sprites are `$IB$` binary items + `Sprite3()`.
- `COLOR_RED` etc. → bare `RED`, `LTGRAY`, ... (`KernelA.HH:2913`).
- `Man()` → no man pages; `Help;`, AutoComplete F1, `Uf("Name")`.
- `Cat()` → `Type("file")`.
- `MemMax()` → `MemRep()` reports memory.
- `body_size` CDC field → compute `width_internal*height`.
- `main()`, `exit()` → no process model; `return` from top level / fall off the end.
  To kill your own task: `Exit;` exists as menu-speak, real calls are user leaves via
  the terminal; `Kill(task)` kills a task.
- `GetTicks()`/`clock()` → `tS` (F64 seconds), `cnts.jiffies` (mS).
- `srand/rand` → `Seed()`, `Rand` (F64 [0,1)), `RandU16`...

(Also verified the reverse: `ExeDoc` DOES exist — `Adam/DolDoc/DocTree.HC:192` — even
though it sounds made-up.)

## Graphics model traps

- **The draw_it dc is already double-buffered.** Winmgr composites gr.dc2 fresh each
  frame and calls your `draw_it(task,dc)` with an alias. Don't build a manual
  page-flip for normal animation; don't draw once and expect it to persist (it vanishes
  next frame); don't `DCDel(dc)` or cache the dc pointer across frames.
- **Persistent drawing is the other mode**: `CDC *dc=DCAlias;` targets gr.dc; pixels
  stay until `DCFill;`. Mixing the two models is the classic bug (drawing to gr.dc from
  inside draw_it, or expecting gr.dc2 drawing to persist).
- Pixels are PALETTE INDICES 0-15, not RGB. Color math = palette tricks, dithering
  (ROPF_DITHER / ROPF_PROBABILITY_DITHER), or `c^8` bright-flip. 0xFF = transparent.
- Palette writes hit the VGA DAC immediately (6 bits/channel — low 10 bits of each
  CBGR48 U16 are dropped). Palette is GLOBAL hardware state, not per-window: your
  palette animation recolors the whole screen, and SettingsPop is what restores it.
- Row stride is `width_internal` (width rounded up to 8), not `width` — off-by-stride
  shears the image when poking body directly.
- `GrRect(dc,x,y,w,h)` takes WIDTH/HEIGHT and is FILLED; `GrRectB` takes corners;
  the outline rect is `GrBorder`. `GrCircle`/`GrEllipse` are OUTLINES — no filled-circle
  primitive exists; fill via `GrFloodFill` at an interior point (SunMoon.HC idiom).
- `i(F64)` does NOT convert an int to float — postfix casts reinterpret bits. Use
  `ToF64(i)` or mixed arithmetic (`i*1.0` works but ToF64 is the sanctioned form).
- `GrPrint` has no font size — the 8x8 font is all there is. Scale by drawing.
- Window coords: clipped primitives on screen DCs translate by
  `dc->win_task->pix_left/pix_top` (+scroll) automatically and skip pixels covered by
  other windows; `GrPlot0`/raw body pokes do NEITHER (buffer-absolute, unclipped).
  The CDC `x0/y0` fields are NOT a window origin. `ms.pos` is in SCREEN coords —
  subtract `task->pix_left/pix_top` (and scroll_x/y) for window-relative.
- Bounds: your canvas is `Fs->pix_width` x `Fs->pix_height` (window), not
  GR_WIDTH x GR_HEIGHT (screen), unless you `WinMax;` first.

## Runtime traps

- **Reload doesn't retro-patch**: re-#include shadows symbols; existing function
  POINTERS (e.g. an installed draw_it) still run the OLD code until reassigned; global
  variable state is lost (new shadowing instance). Old code leaks until task death —
  fine at demo scale, by design.
- try/catch: forgetting `Fs->catch_except=TRUE` (or `PutExcept`) silently rethrows.
  Don't goto out of try, don't return out of catch.
- `Sleep()` takes mS. `Busy()` takes µS. `tS` is F64 seconds.
- Filenames are case-sensitive (RedSea). `.Z` handled transparently — write
  `#include "Foo"` and let ExtDft find Foo.HC.Z.
- A demo that doesn't `SettingsPush`/`SettingsPop` leaves the palette/draw_it/border
  trashed for the terminal. Always bracket.
- `WinMax;` + `WinBorder;` + `DocClear;` or your animation shares the window with
  command-line text.
- CTRL-ALT-c is an exception, not a signal — an unguarded main loop dies without
  running your cleanup; wrap in `try{...} catch PutExcept;`.
- No `argc/argv` program args: parameterize by editing the trailing call in the file or
  via `#if __CMD_LINE__` footers.
- The compiler runs statements DURING compilation — an infinite top-level loop means
  the #include never "returns". That's normal for demos (loop until key).
