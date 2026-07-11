# TempleOS Graphics & System API Reference

All signatures are copied verbatim from `vendor/TempleOS` (paths relative to that root).
**Never guess a signature — grep these files.** The graphics library is `Adam/Gr/`
(note: `GrPrimatives.HC` is the real spelling). Kernel declarations: `Kernel/KernelA.HH`
(types/defines), `Kernel/KernelB.HH` (intrinsics), `Kernel/KernelC.HH` (extern decls).
Non-ASCII in signatures: `ã` below is how TempleOS's pi glyph (single byte 0xE3)
mis-renders on the host. In host-authored code always write the ASCII `pi` define —
a UTF-8 `π` will not compile (see the Math section).

## Screen model — the facts everything else hangs on

- Fixed **640x480, 16 colors, 8x8 font**:
  `GR_WIDTH 640` / `GR_HEIGHT 480` (`Kernel/KernelA.HH:3555-3556`),
  `COLORS_NUM 16` (`:2931`), `FONT_WIDTH 8` / `FONT_HEIGHT 8` (`:3551-3552`).
- **Pixel = 1 byte = palette index 0-15**; `0xFF` = `TRANSPARENT`.
- Row stride is `dc->width_internal` = width rounded UP to a multiple of 8
  (`(width+7)&~7`, `Adam/Gr/GrDC.HC:195`). Body size = `width_internal*height` bytes.
  There is NO `body_size` field.
- No linear framebuffer, no flush call: `GrUpdateVGAGraphics` (`Adam/Gr/GrScrn.HC:366`)
  converts the 8-bit body to 4 planar VGA bitplanes every winmgr frame
  (`WINMGR_FPS (30000.0/1001)` ≈ 29.97, `KernelA.HH:1478`).
- Two screen DCs (`Adam/Gr/GrGlbls.HC:3-43`, global `gr`):
  - `gr.dc` — the **persistent** layer. Draw once, it stays until `DCFill;`. Access via
    `CDC *dc=DCAlias;` (no-arg DCAlias aliases gr.dc).
  - `gr.dc2` — recomposited from scratch every frame. **`draw_it` callbacks receive an
    alias of gr.dc2** clipped to the task — already offscreen, inherently flicker-free,
    must redraw everything each call.
  - Every frame, `GrUpdateScrn` unconditionally blots gr.dc over the composited gr.dc2
    (`DCBlotColor8(gr.dc2,gr.dc)`, `GrScrn.HC:407`) — the persistent layer reaches the
    screen every frame **even with no draw_it installed**. So a draw-once image +
    palette-only animation needs nothing but `Sleep()` pacing in the main loop.
  - `draw_it` runs INSIDE the winmgr task, which updates every window: heavy per-pixel
    math there slows the entire UI, and an exception in it is caught by the winmgr
    ("Exception in WinMgr", your window gets hidden — `GrScrn.HC:18-56`). For expensive
    effects, render into an offscreen `DCNew` DC from your own loop/animate task and
    have draw_it just `GrBlot` it (the `Life.HC` pattern).

## CDC — the device context (`Kernel/KernelA.HH:3599-3659`)

Key fields (full class in source):

```holyc
public class CDC
{
  ...
  I32 x0,y0,                 // NOT a window origin — re-blot hint used by ScrnCast/GrMV
      width,width_internal,  // width = visible extent; width_internal = row stride
      height, flags;
  CBGR48 palette[COLORS_NUM];
  CColorROPU32 color,        // <- SET THIS before drawing
      bkcolor, color2;
  U64 dither_probability_u16; // 0x0000=100% c0 .. 0x8000=50/50 .. 0x10000=100% c1
  CDC *brush;
  I64 *r, r_norm;            // 3D rotation matrix (DCMat4x4Set)
  I32 x,y,z, thick;          // 3D origin; pen thickness
  U0 (*transform)(CDC *dc,I64 *x,I64 *y,I64 *z);
  CGrSym sym;                // symmetry (DCSymmetrySet)
  ...
  CTask *mem_task,*win_task;
  CDC *alias;
  U8  *body;                 // the pixels: body[y*width_internal+x]
  I32 *depth_buf;            // set by DCDepthBufAlloc()
};
```

Flags (`KernelA.HH:3565-3584`): `DCF_TRANSFORMATION` (enable dc->r/transform for `*3`
calls), `DCF_SYMMETRY`, `DCF_JUST_MIRROR`, `DCF_NO_TRANSPARENTS` (treat color 0 as opaque
in GrBlot), `DCF_DONT_DRAW`, `DCF_RECORD_EXTENTS`, `DCF_ALIAS`, ...

### Color & ROPs (`KernelA.HH:2889-2942`)

`dc->color` is a `CColorROPU32`: two `(U8 color,U8 rop)` pairs (c0 low, c1 high).
Low byte = color 0-15. Combine with `+` (precedence makes `X<<16+Y` work):

```holyc
dc->color=RED;                                  // plain color
dc->color=ROP_XOR+color^TRANSPARENT;            // XOR draw (draw twice = erase)
dc->color=ROP_EQU;                              // overwrite incl. TRANSPARENT
dc->color=ROPF_DITHER+RED<<16+YELLOW;           // 50/50 checker dither of two colors
dc->color=ROPF_PROBABILITY_DITHER+BLACK<<16+c;  // weighted random dither...
dc->dither_probability_u16=i;                   // ...weight 0-0xFFFF toward c1
```

`ROP_EQU ROP_XOR ROP_COLLISION ROP_MONO` (values `ROPB_*<<8`);
`ROPF_DITHER=0x40000000`, `ROPF_PROBABILITY_DITHER=0x80000000`.

### Colors (`KernelA.HH:2913-2933`) — bare names, no prefix

`BLACK 0, BLUE 1, GREEN 2, CYAN 3, RED 4, PURPLE 5, BROWN 6, LTGRAY 7, DKGRAY 8,
LTBLUE 9, LTGREEN 10, LTCYAN 11, LTRED 12, LTPURPLE 13, YELLOW 14, WHITE 15,
TRANSPARENT 0xFF`. Color `c^8` flips dark↔bright variant (used by Shading.HC).

## DC lifecycle (`Adam/Gr/GrDC.HC`)

```holyc
public CDC *DCAlias(CDC *dc=NULL,CTask *task=NULL)  // :168  NULL = gr.dc
public CDC *DCNew(I64 width,I64 height,CTask *task=NULL,Bool null_bitmap=FALSE) // :186
public U0  DCDel(CDC *dc)                           // :208
public U0  DCFill(CDC *dc=NULL,CColorROPU32 val=TRANSPARENT) // :122  MemSet of body
public U0  DCClear(CDC *dc=NULL)                    // :128  fill with 0 (BLACK)
public CDC *DCCopy(CDC *dc,CTask *task=NULL)        // :243
public I32 *DCDepthBufAlloc(CDC *dc)                // :236  z-buffer for *3 calls
public I64 DCColorChg(CDC *dc,I64 src_color,I64 dst_color=TRANSPARENT) // :271
public U8  *DCSave(CDC *dc,I64 *_size=NULL,I64 dcsf_flags=DCSF_COMPRESSED) // :286
public CDC *DCLoad(U8 *src,I64 *_size=NULL,CTask *task=NULL)  // :338
public I64 GRWrite(U8 *filename,CDC *dc,I64 dcsf_flags=DCSF_COMPRESSED) // :383
public CDC *GRRead(U8 *filename,CTask *task=NULL)   // :394
public CDC *DCScrnCapture(Bool include_zoom=TRUE,CTask *task=NULL) // :417
```

`DCFill;` bare = clear the persistent screen layer. **Never DCDel the dc passed to your
draw_it** — the winmgr aliases and deletes it (`GrScrn.HC:36-38`).

## Drawing primitives — dc first, defaults to gr.dc, coords I64

`Adam/Gr/GrPrimatives.HC`:
```holyc
public Bool GrPlot(CDC *dc=gr.dc,I64 x,I64 y)                                  // :51  clips
public I64  GrPeek(CDC *dc=gr.dc,I64 x,I64 y)                                  // :111 read pixel
public I64  GrFloodFill(CDC *dc=gr.dc,I64 x,I64 y,Bool not_color=FALSE,I64 z=0,I32 *db=NULL) // :239
public Bool GrLine(CDC *dc=gr.dc,I64 x1,I64 y1,I64 x2,I64 y2,I64 step=1,I64 start=0) // :568
public Bool GrCircle(CDC *dc=gr.dc,I64 cx,I64 cy,I64 radius,
  I64 step=1,F64 start_radians=0,F64 len_radians=2*ã)                          // :583
public Bool GrEllipse(CDC *dc=gr.dc,I64 cx,I64 cy,I64 x_radius,I64 y_radius,
  F64 rot_angle=0,I64 step=1,F64 start_radians=0,F64 len_radians=2*ã)          // :594
// 3D variants (need DCF_TRANSFORMATION for dc->r transform): GrPlot3, GrLine3,
// GrCircle3, GrEllipse3, GrFloodFill3, GrBlot3, GrPutChar3, GrPrint3            :412-1000
```

`Adam/Gr/GrBitMap.HC`:
```holyc
public Bool GrPlot0(CDC *dc=gr.dc,I64 x,I64 y)     // :4   NO clipping/transform (fast)
public I64  GrPeek0(CDC *dc=gr.dc,I64 x,I64 y)     // :64  = dc->body[dc->width_internal*y+x]
public I64  GrBlot(CDC *dc=gr.dc,I64 x,I64 y,CDC *img)     // :71  copy img onto dc
public I64  GrPutChar(CDC *dc=gr.dc,I64 x,I64 y,U8 ch)     // :693 8x8 font, no scaling
public I64  GrPrint(CDC *dc=gr.dc,I64 x,I64 y,U8 *fmt,...) // :989 full Print fmt codes
public I64  GrRect(CDC *dc=gr.dc,I64 x,I64 y,I64 w,I64 h)  // :1008 x,y,WIDTH,HEIGHT (filled)
```

`Adam/Gr/GrComposites.HC`:
```holyc
public I64 GrRectB(CDC *dc=gr.dc,I64 x1,I64 y1,I64 x2,I64 y2) // :68 corner-to-corner (filled)
public U0  GrBorder(CDC *dc=gr.dc,I64 x1,I64 y1,I64 x2,I64 y2,I64 step=1,I64 start=0) // :93 outline
```

There is no `PutPixel`/`GrPixel`/`GrBitMap()` function. Plot = `GrPlot`/`GrPlot0`.
**Outline vs filled**: `GrCircle`, `GrEllipse`, `GrBorder` draw OUTLINES; `GrRect`/
`GrRectB` are filled; the filled circle is
```holyc
public I64 GrFillCircle(CDC *dc=gr.dc,I64 cx,I64 cy,I64 z=0,I64 diameter) // GrPrimatives.HC:390
```
— note the non-trailing default (`GrFillCircle(dc,x,y,,30)`) and that it takes
DIAMETER, not radius. Alternative fill idiom: outline + `GrFloodFill` at an interior
point (`Demo/Graphics/SunMoon.HC`). Don't build rings from step-1 GrCircle outlines at
consecutive radii — integer rasterization can leave gaps; use nested GrFillCircle
large-to-small, or FloodFill between two outlines.

### Direct body access (fastest per-pixel path)

```holyc
dc->body[y*dc->width_internal+x]=color;   // color 0-15; y,x in DC coordinates
MemSet(dc->body,color,dc->width_internal*dc->height);  // whole-buffer fill (=DCFill)
```

This is exactly what GrPeek0/DCFill do internally.

**How window-relative coordinates actually work** (`GrPlot`, `GrPrimatives.HC:51-79`):
on a DC with `DCF_SCRN_BITMAP` set (gr.dc, gr.dc2, and their aliases — NOT DCNew DCs),
clipped primitives translate your (x,y) by `dc->win_task->pix_left+scroll_x` /
`pix_top+scroll_y`, clip to the window rectangle, and **skip pixels covered by other
windows** (`IsPixCovered0`) unless the task's window is topmost or `DCF_ON_TOP` is set.
The `x0/y0` fields play no part. On a plain `DCNew` DC, primitives just clip to
`0<=x<width`, `0<=y<height` with no translation.

**Raw body pokes and `GrPlot0` get NONE of that** — no translation, no clipping, no
coverage test: coordinates are buffer-absolute (= screen coords on gr.dc/gr.dc2
aliases). For a full-window effect inside draw_it: offset by `task->pix_left/pix_top`
yourself, bounds-check `0<=x<dc->width` and `0<=y<dc->height` (use `width_internal`
ONLY as the row stride — poking the padding columns is harmless but wasted), and accept
that you'll scribble over any overlapping window — which is why per-pixel demos run
`WinBorder; WinMax;` borderless-fullscreen first. No demo in the tree pokes body
directly (they use GrPlot); the fast path is legitimate, just unclipped.

## Palette (`Adam/Gr/GrPalette.HC`)

```holyc
public U0 GrPaletteColorSet(I64 color_num,CBGR48 bgr48)  // :30  writes VGA DAC immediately
public CBGR48 GrPaletteColorGet(I64 color_num)           // :46
public U0 GrPaletteGet(CBGR48 *bgr48)                    // :76  all 16
public U0 GrPaletteSet(CBGR48 *bgr48)                    // :83  all 16
public U0 PaletteSetStd()                                // :90
public CBGR48 gr_palette_std[COLORS_NUM]                 // :64  the boot palette
public CBGR48 gr_palette_gray[COLORS_NUM]                // :70  gray ramp
public U8 gr_rainbow_10[10]                              // :2   color-cycle-friendly ramp
```

- `CBGR48` = `I64 class { U16 b,g,r,pad; }` (`KernelA.HH:2951`). Full brightness per
  channel is `0xFFFF` (`Palette.HC` ramps `j=0xFFFF*i/(COLORS_NUM-1);` into b/g/r —
  assigning F64 expressions into the U16 fields converts implicitly). Because it's an
  I64-typed class you can pass a literal: `GrPaletteColorSet(WHITE,0xFFFFFFFF0000)` =
  r=0xFFFF, g=0xFFFF, b=0 (layout from low word: b,g,r,pad → literal reads
  `0x pad rrrr gggg bbbb`).
- VGA DAC is 6 bits/channel — only the top 6 bits of each U16 survive (`bgr48.r>>10`).
- Takes effect immediately via port I/O (0x3C8/0x3C9) — **no flush**; palette cycling is
  just calling GrPaletteColorSet in a loop each frame.
- `SettingsPush`/`SettingsPop` save/restore the palette — that IS the cleanup idiom
  (`Demo/Graphics/Palette.HC`). There is no global named `gr_palette`.

## Window / draw_it / task fields

```holyc
U0 (*draw_it)(CTask *task,CDC *dc);   // CTask field, Kernel/KernelA.HH:3308
```

Install: `Fs->draw_it=&DrawIt;`. Winmgr calls it ~30fps with an alias of gr.dc2
(`Adam/Gr/GrScrn.HC:36-38`). Window geometry on CTask (`KernelA.HH:3283-3298`):
`pix_left,pix_top,pix_width,pix_height` (pixels), `win_left/right/top/bottom` (character
cells), `scroll_x,scroll_y,scroll_z`. Demos bound to `Fs->pix_width`/`Fs->pix_height`.
Mouse→window coords: `ms.pos.x-task->pix_left-task->scroll_x`.

```holyc
public CTaskSettings *SettingsPush(CTask *task=NULL,I64 flags=0) // Adam/TaskSettings.HC:3
public U0 SettingsPop(CTask *task=NULL,I64 flags=0)              // Adam/TaskSettings.HC:89
public U0 DocClear(CDoc *doc=NULL,Bool clear_holds=FALSE)  // Adam/DolDoc/DocRecalcLib.HC:120
public U0 Refresh(I64 cnt=1,Bool force=FALSE)              // Adam/WinMgr.HC:3  blocks till winmgr redraw
public Bool WinBorder(Bool val=OFF,CTask *task=NULL)       // Adam/Win.HC:517
public U0 WinMax(CTask *task=NULL)                         // Adam/Win.HC:503
public Bool WinHorz(I64 left,I64 right,CTask *task=NULL)   // Adam/Win.HC:357  (char cells)
public Bool WinVert(I64 top,I64 bottom,CTask *task=NULL)   // Adam/Win.HC:391
```

SettingsPush snapshots draw_it, palette, animate_task, border, win_inhibit, text_attr,
autocomplete, cur_dir...; SettingsPop restores all of it AND kills `Fs->animate_task`.

## Timing

```holyc
public extern F64 tS();          // seconds since boot, float — Kernel/KMisc.HC:122
U0   Sleep(I64 mS)               // Kernel/KMisc.HC:155 (JIFFY_FREQ=1000 Hz)
U0   SleepUntil(I64 wake_jiffy)  // KMisc.HC:147; jiffies counter = cnts.jiffies
Bool Blink(F64 Hz=2.5)           // KMisc.HC:130  square wave — flashing UI
U0   Busy(I64 µS)                // KMisc.HC:136  spin-wait
Yield;                           // give up timeslice (use in tight loops)
```

Idioms: `Sleep(20)` paces a ~50Hz sim loop; `Refresh;` is the frame-sync when drawing
to the persistent layer; inside draw_it use `tS`-based phase math (`Sin(2*π*tS/10)`).

## Input

```holyc
// Kernel/KernelC.HH:519-536
public extern I64  GetChar(I64 *_scan_code=NULL,Bool echo=TRUE,Bool raw_cursor=FALSE);
public extern I64  GetKey(I64 *_scan_code=NULL,Bool echo=FALSE,Bool raw_cursor=FALSE); // blocks
public extern I64  ScanChar();   // nonblocking; 0 if no key
public extern Bool ScanKey(I64 *_ch=NULL,I64 *_scan_code=NULL,Bool echo=FALSE);
public extern I64  PressAKey();
public extern CKbdStateGlbls kbd;  // kbd.down_bitmap[8]: test with Bt(kbd.down_bitmap,sc)
```

Key-state polling (continuous movement): `sc=Char2ScanCode('a'); if (Bt(kbd.down_bitmap,sc))...`
Scan codes `SC_ESC, SC_CURSOR_LEFT/RIGHT/UP/DOWN, SC_F1..` (`KernelA.HH:~3480`);
char codes `CH_ESC 0x1B, CH_SHIFT_ESC 0x1C, CH_BACKSPACE 0x08, CH_SPACE 0x20` (`:3453`).
With `GetKey(&sc)`: return 0 means non-ASCII key, scan code in `sc.u8[0]`.

```holyc
// mouse — poll the global: Kernel/KernelA.HH:2998-3018, KernelC.HH:616
public extern CMsStateGlbls ms;   // ms.pos.x, ms.pos.y, ms.lb, ms.rb, ms.speed
```

```holyc
// message queue — KernelC.HH:591-595; codes KernelA.HH:3174-3193
public extern I64 GetMsg(I64 *_arg1=NULL,I64 *_arg2=NULL,I64 mask=~1,CTask *task=NULL);
public extern I64 ScanMsg(I64 *_arg1=NULL,I64 *_arg2=NULL,I64 mask=~1,CTask *task=NULL);
// mask = bit set: 1<<MSG_KEY_DOWN+1<<MSG_MS_L_DOWN
// MSG_CMD 1, MSG_KEY_DOWN 2 (arg1=ch,arg2=sc), MSG_KEY_UP 3, MSG_MS_MOVE 4 (x,y),
// MSG_MS_L_DOWN 5, MSG_MS_L_UP 6, MSG_MS_R_DOWN 9, MSG_MS_R_UP 10
```

Keep the winmgr from stealing clicks: `Fs->win_inhibit=WIG_TASK_DFT-WIF_SELF_FOCUS-WIF_SELF_BORDER;`
(WIF_*/WIG_* at `KernelA.HH:1418-1447`).

## Sprites (embedded art)

Sprites are DolDoc binary items embedded in the source file, created with the in-OS
sprite editor (<CTRL-r>). `$SP,"<1>",BI=1$` defines blob #1; `$IB,"<1>",BI=1$` is a
`U8*` expression pointing at it (`Demo/Graphics/SpritePlot.HC`).

```holyc
public U0 Sprite3(CDC *dc=gr.dc,I64 x,I64 y,I64 z,U8 *elems,Bool just_one_elem=FALSE)
                                            // Adam/Gr/GrSpritePlot.HC:18
// Also Sprite3B, Sprite3ZB (rotated/z-buffered), Sprite3Mat4x4B
// SpriteExtents(img,&min_x,&max_x,&min_y,&max_y) for sizing
```

You can't author `$SP$` blobs from plain text; generate art at runtime into a `DCNew`
DC and `GrBlot` it instead.

## Sound (PC speaker)

```holyc
public extern U0 Snd(I8 ona=0);         // KernelC.HH:679 — ona = piano key #, 0=silence
public extern U0 Beep(I8 ona=62,Bool busy=FALSE);
F64 Ona2Freq(I8 ona)                    // ona 60 = 440Hz; 12 onas/octave — KMisc.HC:163
```

## Math & random

```holyc
// intrinsics — Kernel/KernelB.HH:95-124
F64 Sin(F64 d); Cos(F64 d); Tan(F64 d); ATan(F64 d); Sqrt(F64 d); Abs(F64 d);
I64 AbsI64(I64); MinI64(I64,I64); MaxI64(I64,I64); SqrI64(I64);
I64 ToI64(F64 d); // truncates    F64 ToF64(I64 i);
F64 Arg(F64 x,F64 y);             // atan2-style polar angle
I64 ClampI64(I64 num,I64 lo,I64 hi);
F64 Pow(F64 base,F64 power); Floor(F64); Ceil(F64); Round(F64);
// Kernel/KernelC.HH:539-555
public extern F64 Rand();         // [0,1)
public extern U16 RandU16();      // also RandI16/I32/I64/U32/U64
public extern I64 Seed(I64 seed=0,CTask *task=NULL);
public extern F64 Clamp(F64 d,F64 lo,F64 hi); Min(F64,F64); Max(F64,F64);
```

Pi is `#define`d twice (`Kernel/KernelA.HH:50-51`): as ASCII `pi` and as the pi GLYPH —
a single byte 0xE3 in TempleOS's codepage. Vendor sources that display `2*π/70` store
byte 0xE3. **A UTF-8 `π` from a host editor is two different bytes and fails to compile
(`Invalid lval at "π"` — verified in VM). Host-authored files must write `pi`.**
Angles are radians.

## Program-level / JIT

```holyc
public extern I64 ExeFile(U8 *name,I64 ccf_flags=0);   // Compiler/CompilerB.HH:3 — same as #include
public extern I64 ExePrint(U8 *fmt,...);               // CompilerB.HH:5 — compile & run a string
public extern I64 ExePutS(U8 *buf,U8 *filename=NULL,I64 ccf_flags=0,...); // CompilerB.HH:7
public I64 ExeDoc(CDoc *doc,I64 ccf_flags=0);          // Adam/DolDoc/DocTree.HC:192
public extern I64 RunFile(U8 *name,I64 ccf_flags=0,...); // ExeFile + call last-defined fn with args
public extern Bool Cd(U8 *dirname=NULL,Bool make_dirs=FALSE);
public extern CTask *Spawn(U0 (*fp_addr)(U8 *data),U8 *data=NULL,U8 *task_name=NULL,
  I64 target_cpu=-1,CTask *parent=NULL,I64 stk_size=0,I64 flags=1<<JOBf_ADD_TO_QUE);
                                                        // Kernel/KernelC.HH:725
public extern Bool Kill(CTask *task,Bool wait=TRUE,Bool just_break=FALSE);
public CMenu *MenuPush(U8 *st);  public U0 MenuPop();   // Adam/Menu.HC:150,166
I64 Adam(U8 *fmt,...);   // compile into the immortal Adam task — Kernel/Job.HC:406
```
