# TempleOS Runtime Environment

What a HolyC program lives inside. Citations relative to `vendor/TempleOS`.

## Execution = compilation (the JIT model)

- "Running a program" is `#include`-ing its source into your task's compiler. Top-level
  statements execute as they're compiled. `ExeFile("name")` literally synthesizes
  `#include "name";` (`Compiler/CMain.HC:614-663`); `ExePrint("...")` compiles and runs a
  string. There is no exec, no processes, no argv — "run with args" means calling a
  function: `RunFile()` = ExeFile + call the last-defined function with your args.
- The command line IS a HolyC REPL inside an editable DolDoc document: each line feeds
  the compiler; statements execute immediately (`Doc/CmdLineOverview.DD`). F5 in the
  editor = #include the file you're editing. There is no $PATH — typing a bare filename
  does nothing; you `#include` it or click it in a `Dir;` listing.
- JIT code goes into the task's heap "all over ... in the first 2Gig of memory"
  (`Doc/Glossary.DD` "JIT"). AOT mode (`Cmp()` → .BIN → `Load()`) exists but is only used
  for the Kernel and Compiler themselves — "Do not use AOT, use JIT" (`Doc/Glossary.DD`).

## Live reload / redefinition semantics (holytoy's core mechanism)

- Each task has a **hash symbol table chained to its parent's**, all the way up to the
  immortal Adam task. Lookups walk the chain; new symbols go in the current task's table.
  "Conceptually, syms are at the scope of environment vars." (`Doc/ScopingLinkage.DD`)
- **Re-#include-ing a file adds new symbols that OVERSHADOW the old ones.** This is by
  design: "so that you can repeatedly #include the same file from the cmd line while
  developing it. Or, so you can repeatedly declare a function with a standard name, like
  DrawIt()." (`Doc/ScopingLinkage.DD`)
- Consequences:
  - Old machine code is never freed — "There is no way to unload except by killing the
    task" (`Doc/Glossary.DD`). Leaks are reclaimed at task death (each task has code +
    data heaps freed together).
  - **Pointers captured before redefinition still point at the OLD code.** If
    `Fs->draw_it=&DrawIt;` ran before you reloaded, the winmgr keeps calling old DrawIt
    until you re-run the assignment. A reload script must re-install callbacks.
  - Calls compiled earlier also bound to the old address — only newly compiled calls see
    the new definition. For hot-swappable indirection, call through a function-pointer
    global you reassign on reload.
  - Global variables: a re-included `I64 x=0;` creates a NEW x (shadowing), losing state.
    To preserve state across reloads, guard: `#ifndef MY_STATE  #define MY_STATE ...`
    won't survive either (defines shadow too) — the working pattern is keeping state in
    a task that ISN'T reloaded, or re-entering it from the registry (`RegExe`).
- `Adam("...")` / SHIFT-F5 compiles into the Adam task = system-wide and immortal —
  required for code hooked into globals that outlive your terminal (wallpaper, etc.).
- `HashTablePurge(task->hash_table)` exists (used in `StartOS.HC:18`).

## Ring 0, one address space

- Everything — including "user" programs — runs in kernel mode, identity-mapped, one
  page table for all tasks, no swap, no protection (`Doc/Charter.DD`,
  `Doc/MemOverview.DD`). You can poke hardware ports (`OutU8`) and any memory from any
  program. Dereferencing NULL does NOT fault (`Doc/MemOverview.DD` history).
- A CPU fault drops the offending TASK into the resident debugger; the system keeps
  running. `G()` / `G2()` to continue (`Kernel/KDbg.HC:596`, `Doc/DbgOverview.DD`).
- Tasks: no process/thread distinction. `Fs` = current CTask (via the FS segment reg);
  `Gs` = current CCPU. One window per task. Children die with their parent.
  Multicore is master-slave: only Core0 tasks get windows; farm work to other cores with
  `Spawn(...,target_cpu)` or `JobQue()` (`Doc/MultiCore.DD`).

## Memory

```holyc
public extern U8 *MAlloc(I64 size,CTask *mem_task=NULL);  // NULL = current task's data heap
public extern U8 *CAlloc(I64 size,CTask *mem_task=NULL);  // zeroed
public extern U0 Free(U8 *addr);                          // Free(NULL) is legal
public extern U8 *MStrPrint(U8 *fmt,...);                 // sprintf into MAlloc'ed string
public extern U8 *StrNew(U8 *buf,CTask *mem_task=NULL);
// ACAlloc/AMAlloc/AStrNew — allocate on the immortal Adam heap (survives task death)
```
(`Kernel/Mem/MAllocFree.HC`, `Kernel/KernelC.HH:558-576`.) Out of memory throws
`'OutMem'`. The STACK DOES NOT GROW — heap-allocate anything big.

## Files & paths

- Paths use `/`. `::/` = boot drive root; `~/` = home dir; drive letters `A-Z`
  (`:` = boot drive, A-B RAM drives, C-L ATA, T-Z CD/DVD) (`Doc/Glossary.DD` "Drive").
  There is a current directory per task (`Fs->cur_dir`, `Fs->cur_dv`) but no path env.
- **RedSea is case-SENSITIVE** (`StrCmp` match, `Kernel/BlkDev/FileSysRedSea.HC:190`);
  files are contiguous and cannot grow.
- `.Z` suffix = transparently compressed on read/write. Default HolyC source type is
  `.HC.Z`. Lookups auto-toggle `.Z` and then **search parent directories** if not found
  (`Doc/CmdLineOverview.DD`, `Kernel/BlkDev/DskFind.HC`).
- **`#include` resolves against the task's current directory, not the including file's
  location** (`Compiler/Lex.HC:305-311` — FileNameAbs on the raw name). Hence the
  `Cd(__DIR__);;` prologue in multi-file apps. `__DIR__`/`__FILE__` are #exe-based
  defines usable in code (`Doc/Directives.DD`) — but they expand at compile time only.
- Core API: `FileRead(name,&size)` (returns MAlloc'ed whole file), `FileWrite(name,buf,
  size)`, `Cd`, `Dir("*")`, `Del`, `Copy`, `Move`, `FileFind`, `DirMk`. The "cat"
  command is `Type(name)` (renders DolDoc). There is no `Cat()`.
- Source files ARE DolDoc documents: the lexer whitelists text, tabs, and embedded
  binary (sprites) in compilable source (`Compiler/Lex.HC:322-323`). Plain ASCII is a
  strict subset and always safe to generate. `Linux/TOSZ.CPP` in the vendor tree builds
  a host-side tool for `.Z` files.

## Startup chain & autorun

`Kernel (AOT) → ::/StartOS.HC → ~/MakeHome.HC → ~/HomeSys.HC (StartUpTasks: two User
terminals) → ~/Once.HC → OnceExe()` (`Doc/Once.DD`). Queue code for next boot:
`Once("Beep;");` (user terminal) / `AOnce()` (Adam). The registry (`~/Registry.HC`) is
executable HolyC text — `RegDft`/`RegExe`/`RegWrite` for persistent settings/scores.
Warm reboot without hardware reset: `BootRAM()` (kernel dev); reinstall boot: `BootHDIns()`.

## Debugging & introspection (use these when iterating inside TempleOS)

- `Dbg()` or CTRL-ALT-d → debugger; faults land there automatically; `G()` continues.
- **`Uf("FunName")`** — unassemble a function by name WITH interleaved source lines
  (`Adam/ADbg.HC:254`). The fastest way to check what the JIT actually compiled.
- `ClassRep(ptr)` — dump any struct by type (uses `lastclass`). `D(addr)`, `Dm`, `Da`
  hex dumps; `Dr` registers.
- `Find("needle","mask")` = grep over files (`Adam/Opt/Utils/Find.HC:145`).
  `Help;` for the help index; `#help_index` tags symbols into it. **There is no `Man()`.**
- `Trace()`/`PassTrace()`/`Echo()` — compiler introspection. `HeapLog()` for leaks,
  `Prof()`/`ProfRep()` for profiling. `RawPrint()`/`Raw(TRUE)` bypass the window system.
- CTRL-ALT-c throws an exception in the focused task; CTRL-ALT-x kills it.

## Emulation notes (repo facts only)

`ReadMe.TXT`: boot the ISO in a VM ("aim your virtual machine's CD/DVD at the ISO");
64-bit only; ≥512MB RAM; may need manual ATA port config. No emulator is named and no
build/run scripts ship in the vendor tree (the `Linux/` dir has only the TOSZ tool and
some bash scripts). BIOS boot only, no UEFI (`Doc/Boot.DD`).
