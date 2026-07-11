# How this skill was validated (2026-07-11)

Method: research agents produced citation-grounded notes from `vendor/TempleOS`
(every claim traced to file:line); the skill was authored from those; then it was
adversarially validated in three stages:

1. **Skill-only authoring**: agents with access ONLY to this skill (vendor/ forbidden)
   wrote three programs — `src/plasma.HC` (per-pixel dc->body + custom palette),
   `src/palcycle.HC` (draw-once rings + palette rotation from a spawned task),
   `src/reload.HC` (JIT redefinition proof + language-corner exercises) — and logged
   every assumption the skill failed to settle.
2. **Cross-verification**: independent agents verified every construct in those
   programs against vendor sources, classifying defects as skill-gaps vs writer-errors.
3. **Real-VM runs** via the repo harness (`make run SRC=...`): all three programs
   compile and behave correctly in TempleOS under QEMU; screenshots and guest logs
   in the session records.

Errors found and fixed in the skill during validation:
- CDC `x0/y0` misdocumented as window origin (real mechanism: `DCF_SCRN_BITMAP` +
  `win_task->pix_left/pix_top` translation, plus covered-pixel skipping).
- "No `ExeDoc`", "no `Man()`", "no filled-circle primitive" — all three EXIST
  (`Adam/DolDoc/DocTree.HC:192`, `Kernel/FunSeg.HC:346`, `GrPrimatives.HC:390`).
- UTF-8 `π` compiles only as TempleOS codepage byte 0xE3 — host files must use `pi`
  (VM-verified compile error).
- `` ` `` power operator always yields F64 (`%d` prints raw bits).
- Postfix cast on a function-pointer variable parses as a CALL (VM-verified).
- Missing facts added: gr.dc blotted to screen every frame with no draw_it; draw_it
  runs inside the winmgr task; JIT executes one top-level statement at a time
  (`ExeCmdLine`); no #includes needed for the OS API; `.Z` needs two dots; ExeFile2
  vs ExeFile exception surfacing.

VM-verified behaviors (positive evidence, not just desk-checked): same-file function
redefinition via ExePrint; stale-pointer-runs-old-code; `Fs->draw_it` hot-swap;
default-arg skipping; case ranges + auto-numbered `case:`; chained comparisons;
sub-int access; try/catch with `Fs->except_ch`; lvalue postfix bit-reinterpret;
`GrFillCircle` diameter arg; palette writes hitting the DAC immediately and
persisting; per-pixel body pokes with `width_internal` stride.
