# HolyC Language Reference

Every claim here is traceable to `vendor/TempleOS` (paths relative to that root).
Read `.DD` docs with `python3 skills/holyc/scripts/strip_doldoc.py <file>`.
Primary sources: `Doc/HolyC.DD`, `Doc/CutCorners.DD`, `Doc/ScopingLinkage.DD`,
`Doc/PreProcessor.DD`, `Doc/GuideLines.DD`, `Compiler/` sources.

## The keyword table (authoritative)

The complete HolyC keyword list (`Compiler/OpCodes.DD:140-188`, mirrored as `KW_*` in
`Compiler/CompilerA.HH:239-286`):

```
include define union catch class try if else for while extern _extern return
sizeof _intern do asm goto exe break switch start end case default public
offset import _import ifdef ifndef ifaot ifjit endif assert reg noreg
lastclass no_warn help_index help_file static lock defined interrupt
haserrcode argpop noargpop
```

**These C keywords DO NOT EXIST**: `continue`, `typedef`, `struct`, `enum`, `const`,
`volatile`, `register`, `auto`, `inline`, `signed`, `unsigned`, `short`, `long`, `int`,
`char`, `float`, `double`, `void`, `restrict`, `_Bool`.
- "There is no continue stmt. Use goto." — `Doc/HolyC.DD`
- "No typedef, use class." — `Doc/HolyC.DD`

Note `throw` is NOT a keyword — it's an ordinary kernel function (see Exceptions).

## Execution model

- **No `main()`.** "Any code outside of functions gets executed upon start-up, in order."
  (`Doc/HolyC.DD`). A file IS a program; the last line of a demo is typically a bare
  paren-less call: `MyDemo;  //Execute when #included`.
- Everything is compiled (JIT or AOT) — never interpreted (`Doc/GuideLines.DD`).
- Global initializers are arbitrary expressions, evaluated at compile time by compiling
  and `Call()`ing machine code (`Compiler/PrsVar.HC`, `PrsVarInit`).
- "No type-checking" (`Doc/HolyC.DD`). Return-type mismatches are warnings, not errors
  (`Compiler/PrsStmt.HC:1111-1117`).

## Types

| HolyC | C equivalent |
|-------|-------------|
| `U0`  | void — but ZERO size (avoid `U0 *`; ptr arithmetic step is 0) |
| `I8`/`U8` | char / unsigned char (strings are `U8 *`) |
| `I16`/`U16`, `I32`/`U32`, `I64`/`U64` | 16/32/64-bit ints |
| `F64` | double — **there is no F32** |
| `Bool` | intrinsic 1-byte signed int (`Compiler/CInit.HC:1-15`); nothing forces 0/1 |

- `TRUE`=1, `FALSE`=0, `NULL`=0, `ON`=1, `OFF`=0 are `#define`s (`Kernel/KernelA.HH:19-23`).
- Integer literals are `I64`; float literals are `F64` (`Compiler/Lex.HC`). **All values are
  extended to 64-bit when accessed; intermediate math is 64-bit** (`Doc/HolyC.DD`):
  `I32 i5=-0x80000000; i5>>1 == 0xFFFFFFFFC0000000`.
- The public int types are type-prefixed **unions** over intrinsics, giving sub-int access
  (`Kernel/KernelA.HH:66+`, `Demo/SubIntAccess.HC`):
  ```holyc
  I64 i=0x123456780000DEF0;
  i.u16[1]=0x9ABC;      // poke bytes/words of any int
  arg2.u8[0]            // idiomatic: low byte = scan code
  x.i32[1]              // idiomatic: integer part of 32.32 fixed point
  ```
  Sub-int access (or `&i`) on a local forces it off registers (`Doc/ScopingLinkage.DD`).
- No bit fields; use `Bt/Bts/Btr/Btc` and `LBts/LBtr/LBtc` intrinsics (`Kernel/KernelB.HH:13-25`).
- Style (Doc/GuideLines.DD): default to `I64` for everything; don't use unsigned unless it
  actually breaks; `F64` for floats.
- Class forward declaration: `extern class CTask;` (pointers only until defined).

## Literals & escapes

- Hex `0x...`, binary `0b...`. **No octal** (leading 0 is plain decimal). **No suffixes**
  (`U`,`L`,`f` are errors — lexer ends the token). (`Compiler/Lex.HC:517-562`)
- **Char constants hold up to 8 chars**, packed little-endian: `'ABC'==0x434241`
  (`Doc/HolyC.DD`, `Compiler/Lex.HC:637-685`). Used for exception codes: `throw('OutMem')`.
- String escapes are ONLY `\0 \' \` \" \\ \d \n \r \t \x??` (max 2 hex digits).
  **No `\a \b \f \v \e`, no octal escapes.** `\d` = literal `$` (because `$` is the DolDoc
  escape char in source files — write `$$` in strings for a literal `$` too).
  (`Compiler/Lex.HC:377-424`)
- Adjacent string literals concatenate, as in C (`Compiler/LexLib.HC:248-275`).
- `$` in code = current instruction address / current offset in a class definition
  (`Doc/Asm.DD`; `#assert $-SYS_GDT==sizeof(CGDT)` in `Kernel/KStart16.HC:50`).
- Identifiers may contain chars 128-255: `π`, `θ` appear in real code
  (`#define π` isn't needed — see `Kernel/KernelA.HH:50-52`, demos use `2*π/70`).

## Print shortcuts (the #1 idiom)

There is no `printf`. The function is `Print`, and statement-position literals invoke it
implicitly (`Doc/HolyC.DD`, parser `Compiler/PrsStmt.HC:1203-1205`, `Compiler/PrsExp.HC:394-410`):

```holyc
"Hello World!\n";          // Print("Hello World!\n")
"%s age %d\n",name,age;    // Print with args
"" fmt,name,age;           // empty "" = variable format string follows
'*';                       // char const alone -> PutChars('*') — up to 8 chars
'' drv;                    // empty '' = PutChars(variable)
```

No auto-newline — include `\n` yourself.

**Format spec** (`Doc/Print.DD`, implementation `Kernel/StrPrint.HC:250-870`):
`%[-][0][width][.decimals][t][,][$][/][h<n>]<code>`

Codes: `%%  %b %B` (binary) `%c %C` (char/uppercased; multi-char, `%h25c` repeats)
`%d` (signed dec) `%u` (unsigned) `%x %X` (hex) `%e %f %g` (float) `%n` (engineering
notation, `%h-3n` = milli) `%s` (string) `%S` (Define() entry) `%z %Q %q` (indexed
NUL-list entry / quote / unquote) `%p %P` (symbolic pointer: renders the address as
`FunName+offset` via the function-segment cache, hex if unresolved — works on JIT
functions; `%P` wraps it in a clickable DolDoc link — `Kernel/StrPrint.HC:414-426`,
`Kernel/FunSeg.HC:134`) `%D %T` (date/time) `%F` (file contents).
**No `%o`, no `%i`, no `%ld`/`%lld`** (`%l` is accepted as a harmless no-op).
`,` flag groups digits: `%,d`.

Family: `StrPrint` (sprintf), `MStrPrint` (returns MAlloc'ed string), `CatPrint`,
`DocPrint`, `ExePrint` (compile & run a string), `GrPrint` (pixels).

## Functions

- **Paren-less calls**: a function with no args (or only default args) can be called bare:
  `Dir;` `DCFill;` `Refresh;` `SettingsPop;` (`Doc/HolyC.DD`). Consequence: a bare function
  name IS a call — **taking an address requires `&`**: `Fs->draw_it=&DrawIt;`.
- **Default args need not be trailing**; skip middle args with bare commas:
  ```holyc
  U0 Test(I64 i=4,I64 j,I64 k=5) {...}
  Test(,3);                              // i=4, j=3, k=5
  Spawn(&AnimateTask,NULL,"Animate",,Fs); // skip target_cpu
  GetMsg(,,1<<MSG_KEY_UP);               // skip both out-params
  ```
- **Varargs**: `...` gives implicit locals `I64 argc` and `I64 argv[]` — no va_list:
  ```holyc
  U0 GrPrint(CDC *dc,I64 x,I64 y,U8 *fmt,...)
  { U8 *buf=StrPrintJoin(NULL,fmt,argc,argv); ... }   // forwarding idiom
  ```
- Calling convention: ALL args on the stack, 8 bytes each, none in registers; return in
  RAX; callee pops (`Doc/GuideLines.DD`). Unnamed params legal: `U0 Fun(I64)`.
- Function flags before return type: `public`, `interrupt`, `haserrcode`, `argpop`,
  `noargpop` (`Doc/HolyC.DD`). `public` = export to other tasks / help system — it's
  linkage, not C++ access control.
- `reg`/`noreg` on locals, optionally naming a register: `I64 reg R15 i=5, noreg j=4;`.
- `static` locals exist (not on data heap). Declarations are statements — allowed anywhere.
- `lastclass` as a default-arg value = class name string of the previous arg
  (`Demo/LastClass.HC`, used by `ClassRep(&x)`).

## Operators — the precedence trap

Official table (`Doc/HolyC.DD`, `Compiler/CInit.HC:287-330`), tightest first:

```
`  >>  <<                          power and SHIFTS — above multiplication!
*  /  %
&
^
|
+  -                               & ^ | bind TIGHTER than + -
<  >  <=  >=
==  !=
&&
^^                                 logical XOR (not in C)
||
=  <<= >>= *= /= %= &= |= ^= += -=
```

This is the opposite of C for shifts. Real code exploits it constantly:
`1<<mp_cnt-1` == `(1<<mp_cnt)-1` (in C it would be `1<<(mp_cnt-1)`);
`RED<<16+YELLOW` == `(RED<<16)+YELLOW`; `BLUE<<4+WHITE` == `(BLUE<<4)+WHITE` (text attr);
`1<<MSG_KEY_DOWN+1<<MSG_MS_L_DOWN` == `(1<<MSG_KEY_DOWN)+(1<<MSG_MS_L_DOWN)`.
When translating C code, re-parenthesize every expression involving `<< >> & ^ |`.

- `` ` `` is power: ``2`10`` == 1024 (also `Pow(base,power)` for F64).
- **No ternary `?:`**. No comma operator in expressions (but `,` separates statements
  inside `{}` — `Compiler/PrsStmt.HC:1180-1186`).
- **Chained comparisons are real**: `if (13<=age<20)` compiles as `13<=age && age<20`
  (`Doc/HolyC.DD`; demos: `if (!(0<=x[i]<Fs->pix_width<<32))`).
- **Typecasting is postfix**: `x(F64)`, `p(CHashGeneric *)->user_data0`. A C-style prefix
  cast is a hard error: "Use TempleOS postfix typecasting" (`Compiler/PrsExp.HC:729-731`).
  **A postfix cast RETYPES the bits — it never converts the value**, on variables as on
  constants: `0x400921FB54442D18(F64)` is pi (`Kernel/KernelA.HH:52`); `PopUpFloat`
  round-trips an F64's raw bits through an I64 with `return i(F64);`
  (`Adam/DolDoc/DocPopUp.HC:230-232`); postfix casts work as lvalues for the same trick
  (`tmpde->user_data(F64)=100.0*a/b;`). So `i(F64)` on an integer-valued I64 is float
  garbage — for VALUE conversion use `ToF64()`, `ToI64()`, `ToBool()`, or rely on
  implicit conversion: normal C-like int<->float conversion happens automatically in
  mixed arithmetic, assignment, and argument passing (`Doc/HolyC.DD`). Postfix casts
  are for pointer retyping and bit reinterpretation.
- `sizeof(x)` and `offset(Class.member)` are keywords; both accept only ONE level of
  member. Bare `Class.member` in an expression also yields the offset.
- `defined(SYM)` works in any expression, not just `#if`.

## Statements

- `if/else`, `for(;;)`, `while()`, `do{}while();` are C-like. Assignment-in-condition is
  idiomatic: `while (!(ch=ScanChar) || ch!=CH_ESC)`.
- **No `continue`** — use `goto`. `break` works in loops/switches only.
- Labels only inside functions; must not collide with global names. "Don't do a goto out
  of a try{}" (`Doc/Quirks.DD`) — demos exit via a label placed AFTER the loop but inside
  the try: `goto vr_done; ... vr_done:; } catch PutExcept;`.
- **switch** (`Compiler/PrsStmt.HC:578-780`):
  - Always a jump table (range must fit 0xFFFF entries — no sparse cases).
  - `switch [expr]` (brackets) skips the bounds check ("nobound").
  - Case ranges: `case 4...7:`, `case 'A'...'Z':`.
  - Empty `case:` auto-numbers = previous+1 (first is 0) (`Demo/NullCase.HC`).
  - `start:`/`end:` "sub_switch" porch blocks: code shared by a group of cases, run on
    entry/exit of the group (`Demo/SubSwitch.HC`). Don't goto/throw/return out of the
    `start:` front porch.
  - `default:` and C-style fall-through work.
- `lock {...}` applies x86 LOCK prefixes (braces optional; "a little shoddy" — prefer
  `LBts/LBtr/LBtc` for multicore flags).
- `no_warn i;` suppresses unused-var warning.
- `asm {...}` blocks anywhere; bare mnemonics are also valid statements inside functions.
  Locals as `&i[RBP]`, globals as `[&glbl]`. `Call(ASM_LABEL);` calls in.

## Classes (no struct/enum)

```holyc
class CCritter
{
  CCritter *next,*last;
  I64 x,y,type;
  F64 t_offset;
};
```

- Single inheritance: `class CDerived:CBase` — one base only.
- **No methods** — data members and function-pointer members only:
  `Bool (*user_put_key)(CDoc *doc,U8 *data,I64 ch,I64 sc);`
- No `private`/`protected`; `public` before a class exports the symbol.
- `union` is a standalone type (no tag after definition). A type before the union name
  sets its as-a-whole type: `public I64i union I64 {...};` — this is how I64 itself is
  defined (`Doc/HolyC.DD`, `Kernel/KernelA.HH`).
- Member metadata: `I64 age print_str "%2d" dft_val 38;` — arbitrary `ident value` pairs
  after a member, readable at runtime (`Demo/ClassMeta.HC`, `MemberMetaData()`).
- Multiple members named `pad` or `reserved` don't warn.
- `$=expr;` inside a class sets the current offset (`Doc/Asm.DD`).

## Preprocessor (built into the lexer — no separate pass)

- Because the parser reads one token ahead, a directive can be consumed early; the idiom
  is a doubled semicolon after statements followed by directives: `Cd(__DIR__);;`
  (`Doc/PreProcessor.DD`, `Doc/Quirks.DD`).
- Directives: `#include ""`, `#define`, `#exe {}`, `#assert`, `#if`, `#else`, `#endif`,
  `#ifdef`, `#ifndef`, `#ifaot`, `#ifjit`, `#help_index`, `#help_file`.
  **No `#undef`, `#elif`, `#pragma`, `#error`, `#warning`, `#line`.**
- **`#include "file"` only — `<>` is an error.** Default extension appended: `.HC.Z`.
  Paths resolve against the task's CURRENT DIRECTORY (not the including file!); see
  runtime.md. No include guards exist or are needed — re-inclusion shadows symbols.
- **`#define` is object-like only — no function-like macros** ("No #define functions
  exist (I'm not a fan)"). Body runs to end of line; `\` continuation works.
- **`#exe {...}` runs HolyC at compile time**; `StreamPrint(fmt,...)` inside it injects
  text into the compile stream. This is how `__DATE__ __TIME__ __LINE__ __FILE__ __DIR__
  __CMD_LINE__` are implemented (`Doc/Directives.DD`) — they are #defines wrapping #exe,
  not magic. `__CMD_LINE__` is 1 when compiled from the prompt; the standard "run me"
  footer for parameterized tools is:
  ```holyc
  #if __CMD_LINE__
  Cd(__DIR__);;
  MyMain("args");
  #endif
  ```
- `#assert expr` — compile-time check, failure is only a WARNING.
- `Option(OPTf_...,ON)` toggles compiler behavior (`Doc/Options.DD`).

## Exceptions

```holyc
try {
  ...
  throw('MyErr');       // throw is a FUNCTION: U0 throw(I64 ch=0,Bool no_log=FALSE)
} catch {               // catch takes NO argument — no catch(...) form
  if (Fs->except_ch=='MyErr') {
    ...
    Fs->catch_except=TRUE;   // consume; otherwise auto-rethrows to next handler
  }
}
```

- Source: `Kernel/KExcept.HC:86-114`, `Demo/Exceptions.HC`, `Doc/HolyC.DD`.
- The throw code is a multi-char char const (≤8 chars), read via `Fs->except_ch`.
- **If a catch block doesn't set `Fs->catch_except=TRUE`, the exception continues to the
  next enclosing handler.** `PutExcept` prints it and sets the flag — the canonical
  whole-catch-body: `} catch PutExcept;`
- Unhandled → `Panic("Unhandled Exception")` → debugger.
- try/catch forces all locals off registers. Don't `goto` out of a `try{}`; don't
  `return` out of a `catch{}` (`Demo/Exceptions.HC` header warning).
- Every real use of try/catch in the tree is INSIDE a function; file-scope `try` is
  unattested — put your guarded main loop in a function (the standard skeleton does).
- CTRL-ALT-c injects an exception into a task — wrapping the main loop in
  `try {...} catch PutExcept;` is how demos survive it.

## Linkage keywords (Doc/ScopingLinkage.DD)

- `extern` — bind to existing same-named symbol (once only per symbol).
- `import` — like extern but resolved at `Load()` time (AOT).
- `_extern NAME decl` — bind declaration to an asm symbol of a DIFFERENT name.
- `_intern IC_XXX decl` — bind to a compiler intrinsic opcode (how Sin/Cos/Fs are done).
- `public` — export (visible to other tasks; listed in Help indexes).

## Runtime facts affecting codegen

- The stack does NOT grow (no virtual memory). Allocate big buffers with `MAlloc`, not
  as locals (`Doc/HolyC.DD`).
- `Free(NULL)` is legal. `MSize(ptr)` gives the real (rounded-up) allocation size.
- `MemCpy` only copies forward (`Doc/Quirks.DD`).
- In-order short-circuit is guaranteed for `&&`/`||`.
