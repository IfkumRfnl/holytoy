# Step 1 skeleton spike — findings (plan 002)

App: `src/holytoy/HT.HC`, run as a plain `MAIN.HC` under `guest/RUN.HC`
(batch self-test) or `make gui SRC=src/holytoy/HT.HC` (interactive).
Everything below was observed in the VM on 2026-07-11 (TCG, no KVM).

## Decision (a): code-pane mechanism — GrPrint from the app's own draw_it

Tried, in the plan's order:

1. **Task's own DolDoc doc** — VM-probed (36 blank lines printed, then fake
   source, viewport draw_it over the top region). It *displays*: doc text
   renders before `draw_it` in the same window (`GrUpdateTaskWin`,
   Adam/Gr/GrScrn.HC — TextRect, then `DocUpdateTaskDocs`, then `draw_it`),
   so the pushed-down lines show in the bottom region under an animating
   viewport, OCR-clean. Rejected anyway: the task doc is also the harness
   log (`guest/RUN.HC` dumps it to `E:/LOG.TXT` at exit), so maintaining a
   pane there (DocClear + reprint per recompile) would erase the `HT * OK`
   self-test markers, while append-only maintenance mixes markers and
   LexExcept compiler output into the visible pane and scrolls the layout
   away after ~59 total lines. Structural conflict, not a rendering one.
2. **Second task owning the bottom region** — not attempted in the VM.
   Viable per source (WinVert/WinHorz set char-cell bounds), but adds a
   task lifecycle, cross-task doc writes, DolDoc `$` escapes garbling
   shader source, and focus questions — all for no gain over (3).
3. **GrPrint of the source buffer from the same draw_it** — chosen. The
   pane is repainted every frame: black band (`MemSet` rows 296..479),
   header, up to 20 source lines, status/error line. Drawn on the 8x8 font
   grid (window y is a multiple of 8; borderless-max window starts at
   screen y=8), so `tools/scrtext.py` OCRs it exactly — the whole pane
   greps from `screen.txt`. One task, one callback, deterministic layout,
   error line is just a colored GrPrint.

## Decision (b): viewport presentation — draw_it recomputes into dc->body

Used: per-frame recompute in the `draw_it` callback, poking `dc->body`
directly (the proven `src/plasma.HC` idiom; absolute screen coords, stride
`width_internal`), shading once per 4x4 block (`HT_SCALE=4`, VISION.md
render-scale) = 160x72 = 11,520 `MainImage` calls/frame through a function
pointer, F64 sin/sqrt math.

Rejected for the spike: rendering into a cached `DCNew` CDC from a spawned
task with draw_it just `GrBlot`ing it (the Life.HC pattern). Observed cost
of the direct path: winmgr status line holds **FPS:29-30** (full winmgr
rate) with both sample shaders, under TCG — no perf pressure at 4x scale,
so the extra task + blit + double-buffer bookkeeping buys nothing yet.
This answers VISION.md:124-126 for now; revisit in plan 003 if full-res or
heavier shaders drop the winmgr rate (the offscreen-CDC path decouples
shading rate from winmgr rate and remains the escape hatch).

Note: an exception thrown inside `draw_it` is caught by the winmgr, which
*hides the window* and sleeps 3 s (`GrScrn.HC` "Exception in WinMgr").
A hard pointer fault still lands in the debugger — acceptable while shader
source is trusted; the GLSL transpiler (plan 004) is what makes user code
pointer-free.

## Decision (c): recompile trigger — F5 (plus F1/F2 sample loaders)

- `HtRecompile(src)` compiles `src + "\nht_new_fp=&MainImage;"` as ONE
  `ExePutS2` unit inside try/catch (`Fs->catch_except=TRUE`). Taking
  `&MainImage` *inside* the compiled unit binds the freshly JITed code
  (src/reload.HC pattern); `ht_fp` is swapped only on success — a single
  atomic pointer store, safe against the concurrently running winmgr.
- `ExePutS2` (Compiler/CMain.HC:631, "throws exceptions") is the right
  call: `ExePutS`/`ExePrint` swallow `'Compiler'` exceptions internally.
  Caveat found in source: on an exception `ExePutS2` skips its
  `QueRem(cc)`/`CmpCtrlDel(cc)` — each failed compile leaks one CCmpCtrl
  on the task queue (reclaimed at task death). Harmless at spike scale;
  the self-test proves the compiler keeps working after a failure
  (`HT RECOVER OK`).
- Interactive mode (`E:/GUI.TXT` present): a blocking `GetKey` loop in the
  app task — the winmgr keeps animating the viewport meanwhile, and the
  headless path never enters it. Keys reach the task fine (it has focus).
  F5 = recompile buffer, F1/F2 = load samples, ESC = uninstall draw_it and
  return to the shell. Verified live over QMP `send-key`/`type` in a
  `make gui` session: F2 swapped plasma→rings with "OK compiled 204
  bytes"; typing `zz=;` + F5 gave the red "COMPILE ERR [Compiler]
  previous shader kept" line with the rings still animating (successive
  screendumps differ); 4x backspace + F5 back to OK; ESC returned to a
  live shell.
- A genuinely editable DolDoc region was NOT attempted — the spike's
  "editing" is append-at-end/backspace of a global buffer with a drawn
  cursor. Accepted spike outcome per the plan; the real edit control is
  follow-up work.

## What step 1 still lacks (deliberate)

- Real editing: cursor movement, mid-buffer insertion/deletion, mouse-driven
  editing — still open. (The host-side prerequisite landed in plan 006:
  `tools/qmp.py mouse-rel/mouse-btn/mouse-to` inject real PS/2 mouse input,
  proven by the `mouse` proof in `make test`; the pane just doesn't use the
  mouse yet.)
- Inline error text: the status line shows `COMPILE ERR [Compiler]`; the
  full LexExcept message (with line number) goes to the task doc /
  `guest.log`, not the pane. Capturing it needs a doc-tail grab or a
  LexExcept-side hook — follow-up.
- Render-scale toggle — still open. The ms/frame readout landed in plan
  006 (pane header times the shading loop only, whole ms).
- LUT/fixed-point math — landed: plan 003 built `HTMATH.HC`, plan 006
  wired it into the app (`#include "E:/HTMATH.HC"`, F3 fixed-point plasma
  sample, `HT MATH OK` self-test marker).
- Palette control per shader (samples use the std palette so UI colors
  stay stable; plasma.HC-style palette ramps are a step-4 polish item).
- Shader load/save on the transfer disk — VISION step 4.
