# Idioms — how demos are actually written

Patterns extracted from real sources: `Demo/Graphics/*.HC`, `Demo/Games/*.HC`,
`Adam/WallPaper.HC`. Copy these shapes; don't invent structure.

## The canonical demo skeleton

```holyc
//Optional header comment explaining the demo.
#define FRAMES_NUM	16          // ALL_CAPS, tab-aligned value

I64 frame;                          // ALL state in file-scope globals —
F64 θ;                              // draw_it gets no user pointer

U0 DrawIt(CTask *task,CDC *dc)      // CTask * often anonymous: (CTask *,CDC *dc)
{
  I64 x,y;
  dc->color=YELLOW;
  GrPrint(dc,0,0,"Frame:%d",frame);
  ...                               // redraw EVERYTHING — dc is a fresh gr.dc2 alias
}

U0 MyDemo()
{
  SettingsPush;                     // snapshots draw_it, palette, border, menu keys...
  WinBorder;                        // border off
  WinMax;                           // maximize
  DocClear;                         // clear the command-line text behind us
  Fs->draw_it=&DrawIt;
  try {                             // survive <CTRL-ALT-c>
    while (!ScanChar) {
      ...update globals...
      Sleep(20);
      θ+=2*π/70;
    }
  } catch
    PutExcept;
  SettingsPop;                      // restores draw_it & palette, kills animate_task
}

MyDemo;   //Execute when #included (F5)
```

This is `Demo/Graphics/Box.HC` / `WinZBuf.HC` distilled. Variations below.

## Two rendering modes — pick one

**Mode A: draw_it callback (gr.dc2).** Winmgr calls you ~30fps with an offscreen dc.
Flicker-free by construction; you must redraw the whole frame; never `DCDel` that dc.
Use for anything animated. (`Demo/Graphics/Box.HC`, `Life.HC`, `Shading.HC`)

**Mode B: persistent layer (gr.dc).** `CDC *dc=DCAlias;` then draw; pixels stay until
`DCFill;`. Frame-sync with `Refresh;` ("Typically 30 fps" — `SunMoon.HC`). Use for
accumulative drawing (trails, doodling). Cleanup: `DCFill; DCDel(dc);`.
```holyc
CDC *dc=DCAlias;
...
while (!ms.lb) {
  GrPlot(dc,ms.pos.x,ms.pos.y);
  Refresh;
}
DCFill; DCDel(dc);
```
(`Demo/Graphics/MouseDemo.HC`, `Bounce.HC`, `NetOfDots.HC`.) `SpritePlot.HC`: "This file
uses the persistent graphic device context CDC, gr.dc, while the other demo's use gr.dc2
which must be redrawn at 30 fps by the window mgr task." `SunMoon.HC` warns two tasks
using gr.dc without DCAlias "will screw-up color and stuff."

## Exit-condition idioms (by input complexity)

```holyc
// (a) any key exits:
while (!ScanChar) { ...; Sleep(20); }

// (b) only ESC/SHIFT-ESC exits, CTRL-ALT-c safe (Bounce.HC):
try {
  do { ...; Yield; } while (!(ch=ScanChar) || ch!=CH_SHIFT_ESC && ch!=CH_ESC);
} catch
  PutExcept;

// (c) keyboard game (Varoom.HC): GetKey blocks; 0 => scan code in sc
while (TRUE)
  switch (GetKey(&sc)) {
    case 0:
      switch (sc.u8[0]) {
        case SC_CURSOR_LEFT:  dθ-=π/60; break;
        case SC_CURSOR_RIGHT: dθ+=π/60; break;
      }
      break;
    case CH_SHIFT_ESC:
    case CH_ESC: goto done;
  }
done:   // label INSIDE the try — "Don't goto out of try"

// (d) mouse (Doodle.HC): message loop, then EAT THE KEY-UP
do {
  msg_code=GetMsg(&arg1,&arg2,1<<MSG_KEY_DOWN+1<<MSG_MS_L_DOWN+1<<MSG_MS_R_UP);
  switch (msg_code) { ... }
} while (msg_code!=MSG_KEY_DOWN || !arg1);
GetMsg(,,1<<MSG_KEY_UP);
```

`PressAKey;` / `GetChar(,FALSE);` are the one-line "wait for key" forms.

## Background physics task

Heavier sims split sim from render (`Life.HC`, `Varoom.HC`, `RainDrops.HC`):

```holyc
U0 AnimateTask(I64)                 // note unnamed I64 arg
{
  while (TRUE) {
    ...step simulation (globals)...
    Sleep(10);
  }
}
...
Fs->animate_task=Spawn(&AnimateTask,NULL,"Animate",,Fs);  // parented on us
Fs->draw_it=&DrawIt;
```

Registering it as `Fs->animate_task` means **SettingsPop kills it** — no manual Kill.
The child reaches the window size via `Fs->parent_task->pix_width`.

## Per-pixel effects

```holyc
// color-per-pixel loop (WinZBuf.HC):
for (i=0;i<h;i++)
  for (j=0;j<w;j++) {
    dc->color=ComputeColor(j,i);   // 0-15
    GrPlot(dc,j,i);
  }

// pixel reads as data (Life.HC — cellular automata on GrPeek):
if (GrPeek(dc[cur_dc],x1,y1)==GREEN) cnt++;
```

Demos use GrPlot/GrPeek, never raw `dc->body` (kernel blitters only). For a full-window
plasma, direct `dc->body[y*dc->width_internal+x]=c;` is legitimate and fastest — see
graphics.md for the caveats (no clipping, absolute screen coords in draw_it).
Put `Yield;` inside long pixel loops on the persistent layer (`Bounce.HC`, `Grid.HC`).

## Palette animation (`Palette.HC` — read it, it's short)

```holyc
SettingsPush;                       // saves current palette
for (i=0;i<COLORS_NUM;i++) {
  j=0xFFFF*i/(COLORS_NUM-1);
  bgr.b=j; bgr.g=j; bgr.r=j;        // CBGR48 has U16 b,g,r
  GrPaletteColorSet(i,bgr);
}
...
GrPaletteColorSet(WHITE,0xFFFFFFFF0000);  // literal form: 0x pad_rrrr_gggg_bbbb
...
SettingsPop;                        // restores original palette
```

Palette *cycling*: rotate what each index means once per frame — 16 palette writes beat
307200 pixel writes. Whole-palette swap: `GrPaletteSet(gr_palette_gray);` /
`PaletteSetStd;`. Do the SetColor calls in the main loop (not draw_it — palette isn't
per-frame composited, it's global hardware state). For draw-once art + palette-only
animation: draw on the persistent layer (`DCAlias` of gr.dc), then the loop needs ONLY
`GrPaletteColorSet` + `Sleep` — the winmgr re-emits the unchanged gr.dc body to VGA
every frame regardless (`GrScrn.HC:407`), so the new palette shows without Refresh or
redrawing.

## ROP tricks (SunMoon.HC, Shading.HC, Doodle.HC)

```holyc
// two-color dither fill:
gr.dc->color=ROPF_DITHER+RED<<16+YELLOW;
GrFloodFill(gr.dc,x,y);

// probability dither — poor man's brightness ramp (Shading.HC):
if (i<0) { dc->color=ROPF_PROBABILITY_DITHER+BLACK<<16+color;     dc->dither_probability_u16=-i; }
else     { dc->color=ROPF_PROBABILITY_DITHER+(color^8)<<16+color; dc->dither_probability_u16=i;  }

// XOR rubber-band — draw twice erases (Doodle.HC):
dc->color=ROP_XOR+color^TRANSPARENT;
GrLine3(dc,x1,y1,0,x2,y2,0);   // draw
...
GrLine3(dc,x1,y1,0,x2,y2,0);   // erase
```

`dc->thick=2;` pen width (`Speedline.HC` does `dc->thick=0.04*ms.speed;`).
`dc->flags|=DCF_NO_TRANSPARENTS;` before `GrBlot` makes color 0 opaque (`Life.HC`).

## Offscreen DCs / explicit double buffer (Life.HC)

```holyc
CDC *dc[2]; I64 cur_dc;
U0 DrawIt(CTask *,CDC *dc2)
{
  dc[cur_dc]->flags|=DCF_NO_TRANSPARENTS;
  GrBlot(dc2,0,0,dc[cur_dc]);
}
...
dc[0]=DCNew(GR_WIDTH,GR_HEIGHT);
dc[1]=DCNew(GR_WIDTH,GR_HEIGHT);
// AnimateTask renders generation into dc[!cur_dc], then flips cur_dc
```

Also: pre-render a background DC once, GrBlot each frame; GrPeek an offscreen DC as a
collision map (`RainDrops.HC`, `Varoom.HC` track_map).

## Time-based animation (evaluated fresh each draw_it call)

```holyc
j=(tS*4+c->t_offset)%FRAMES_PER_CRITTER;   // sprite frame — WallPaperFish.HC
F64 tt=0.5*(Sin(π*2*(tS%10.0)/10.0)+2.0);  // 10-second breathing — Shading.HC
if (Blink) GrPrint(dc,x,y,"Game Over");    // 2.5Hz flash — Varoom.HC
```

Randomness: `θ=Rand*2*π;` `c->x=(RandU16%GR_WIDTH)<<16;` `if (RandU16&1)...` —
never seeded in demos (`Seed()` exists for determinism).

## Fixed point (no F32, F64 is fine, but Terry likes integers)

```holyc
// 32.32 (Bounce.HC): position I64, integer part = .i32[1]
dx[i]=I32_MAX*Cos(θ);              // velocity
x[i]+=dx[i];
GrPlot(dc,x[i].i32[1],y[i].i32[1]);
if (!(0<=x[i]<Fs->pix_width<<32)) ...   // chained comparison + shifted bound
// 16.16 (WallPaperFish.HC): x=c->x>>16%GR_WIDTH;
```

## Text & style

- `GrPrint(dc,x,y,fmt,...)` with full Print codes; center with
  `GrPrint(dc,(w-FONT_WIDTH*9)/2,(h-FONT_HEIGHT)/2,"Game Over");` — set `dc->color` first.
- Task text attr: `Fs->text_attr=BLUE<<4+WHITE;` (BG<<4+FG).
- Bare strings print to the doc: `"Press left mouse bttn to exit.\n";`
- Style: 2-space indent; function brace on its own line, control-flow brace inline;
  `I64 i,j;` at function top; globals lowercase_with_underscores; `#define` ALL_CAPS;
  temporaries `tmpc`/`tmpt`; no blank lines inside functions; `//` comments;
  doc-comment on the line after `{`: `{//color is 0-7`.
- Greek in identifiers is normal: `θ`, `dθ`, `π`.

## Menus, scores, wallpaper (garnish)

```holyc
MenuPush("File {"
         "  Abort(,CH_SHIFT_ESC);"
         "  Exit(,CH_ESC);"
         "}");
... MenuPop;                        // menus double as key-binding docs (Varoom.HC)

RegDft("TempleOS/MyGame","F64 best=9999;\n");  // registry = executable HolyC text
RegExe("TempleOS/MyGame");
RegWrite("TempleOS/MyGame","F64 best=%5.4f;\n",best);
```

Code that must outlive the including task (wallpaper hooks, resident tools) must be
**Adam-included** (SHIFT-F5) and allocate with `ACAlloc`; guard with:
```holyc
if (Fs!=adam_task) {
  "Must be Adam Included with SHIFT-F5.\n";
  return;
}
old_wall_paper=gr.fp_wall_paper;    // chain the old hook
gr.fp_wall_paper=&WallPaperFish;
```
(`Demo/Graphics/WallPaperFish.HC`, `Adam/WallPaper.HC`.)

## Multi-file programs

```holyc
// Load.HC (Apps/Budget/Load.HC):
Cd(__DIR__);;                       // note ;; — see language.md preprocessor section
#include "BgtStrs"                  // no extension: .HC.Z default
#include "Budget"
```
