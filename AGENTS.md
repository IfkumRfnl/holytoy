# AGENTS.md — working on holytoy

Operational reference for agents (and humans who want the details).
The pitch is [README.md](README.md), and [docs/VISION.md](docs/VISION.md)
contains the longer design narrative. The product direction below is
authoritative when an older plan or document describes a narrower target.

## Product direction (authoritative)

HolyToy is a Shadertoy-compatible application that runs **inside TempleOS**.
Its product loop is: open HolyToy, edit GLSL, compile it in the guest, and see
the live result in the adjacent viewport. Host injection, Python, and the QEMU
harness are development and verification tools; they are not runtime parts of
the product.

### Compatibility target

The goal is approximately **99% compatibility with real Shadertoy shaders**,
measured against a large, versioned corpus of public shaders rather than a few
hand-written fixtures. Compatibility means that a shader compiles, runs, and
produces materially correct output when its required inputs are available.
Performance is measured separately: expensive shaders may render at an
adaptive lower resolution, but lowering resolution must not change their
language semantics.

The old "small Shadertoy subset" was a feasibility-spike boundary, not an
acceptable product boundary. In particular, the product compiler must be
designed to support the GLSL used in practice, including:

* structs and nested user-defined types;
* arrays and indexing;
* global and local constants, scopes, and initializers;
* overloaded functions and GLSL constructors;
* vectors, matrices, swizzles, and the usual implicit conversions;
* control flow and common preprocessor usage;
* the standard Shadertoy uniforms and builtins;
* texture/channel sampling and buffer inputs needed by real shaders; and
* multipass and other Shadertoy facilities wherever corpus results show they
  are required to reach the compatibility target.

Features may land incrementally, but do not simplify the final product target
to make an implementation plan easier. Any deliberate incompatibility must be
recorded, corpus-measured, and justified; a missing foundational GLSL feature
such as `struct` is unfinished work, not an acceptable permanent deviation.

### Compiler ownership and architecture

The shipping GLSL-to-HolyC compiler is implemented in **HolyC** and executes
inside the HolyToy process. It must not require Python or host-side
pretranspilation. Keep the guest compiler modular: lexer, parser, typed semantic
model/IR, lowering, and HolyC emitter should have explicit interfaces and
separate source files. Prefer data structures and ownership rules natural to
HolyC instead of transliterating Python objects.

`tools/glsl2hc.py` is a disposable feasibility prototype and little further
use of it is expected. It is not the product compiler, not the architecture to
port mechanically, not the oracle the guest compiler is judged against (GLSL
correctness is judged against rendered output and GLSL semantics, not Python
parity), and not evidence that a GLSL feature is complete until the in-guest
path supports that feature. Avoid expanding the Python implementation except
where a focused change is necessary to keep the transitional host-injection
pipeline (plans 006-007) working until the guest compiler replaces it.

The temporary HolyC `MainImage` editing dialect is scaffolding only. The
shipping editor accepts GLSL. Generated HolyC stays internal, is compiled with
TempleOS's compiler, and on failure HolyToy reports the GLSL-facing diagnostic
while keeping the previous shader alive.

### How progress is judged

Infrastructure and spikes are enabling work, not proportional product
completion. Report these independently:

1. corpus compile/run compatibility percentage and important unsupported
   language/runtime features;
2. in-guest compiler and editor-loop status;
3. visual correctness and known semantic deviations;
4. performance by render scale under TCG and KVM; and
5. harness/test health.

A host-only transpiler passing unit tests or rendering fixture shaders is a
useful proof, but it does not count as completion of the corresponding product
compiler feature.

## Commands

```
make golden                      # one-time: ISO -> installed golden image (~1-2 min, unattended)
make run SRC=src/gradient.HC     # one cycle (~20 s): inject, boot, screenshot, extract logs
make run SRC=tests/glsl/foo.glsl # .glsl: transpiled host-side, runs inside the HolyToy app
make watch SRC=...               # re-run on every save
make gui [SRC=...]               # visible QEMU window (WSLg); guest stays up, no auto-reboot
make test                        # the ten proofs (must stay green)
make fetch-iso                   # (re)download images/TempleOS.ISO
make clean                       # remove run artifacts; never touches the golden image
```

## Run artifacts

Every invocation prints its authoritative result directory as the first
stdout line, before disk creation or slot waiting:

```text
RUN_DIR=/absolute/path/to/out/runs/run-20260711-142233-a8K3Qp
```

There is no process-global "latest" file or symlink: use the directory
printed by the invocation you started. Each batch run has this layout:

| path within `RUN_DIR`       | contents                                                  |
|-----------------------------|-----------------------------------------------------------|
| `.lock`                     | liveness lock, held for the invocation                    |
| `slot`                      | bounded-concurrency slot number                           |
| `xfer.img`, `mtools.conf`   | retained guest transfer disk and its mtools config        |
| `qemu.log`                  | QEMU diagnostics                                          |
| `latest.png`                | last stable guest frame (640x480)                         |
| `screen.txt`                | exact 8x8 glyph OCR of that frame; grep this first        |
| `guest.log`, `status`       | guest task-doc dump and raw `OK` / `ERR` status           |
| `frames/frame-NNNN.png`     | rolling screendumps (~0.7 s apart)                        |
| `anim.gif`                  | trailing frames as a best-effort GIF                      |

`RUN_DIR=/path tools/run.sh SRC.HC` reserves a specific new or empty direct
child of `out/runs/`; nested overrides are rejected. Reuse of a completed or
active directory fails safely. The wrapper itself owns the liveness lock.

Exit codes of `tools/run.sh` / `make run` remain:

* **0** — guest compiled and ran the source
* **1** — guest reported a compile/runtime error (read the run's `guest.log`)
* **2** — harness failure: timeout, no guest status, missing golden image

Read screenshots yourself: the run's `latest.png` is a normal PNG and its
`screen.txt` is faster to grep. Any screendump can be OCR'd with
`python3 tools/scrtext.py FILE.png [--grep STRING]`.

## How a run works

```
src/foo.HC ──mtools──> RUN_DIR/xfer.img (FAT32, MBR type 0x0C) as MAIN.HC
                       + guest/RUN.HC (runner, refreshed every run)
                │
                ▼
QEMU boots RUN_DIR/overlay.qcow2 — throwaway overlay on golden.qcow2
and exposes RUN_DIR/qmp.sock for isolated screen capture
                │
                ▼  in the guest
C:/Home/Once.HC (hook baked into golden)
  └─ ATAMount('E',...) the transfer disk, ExeFile("E:/RUN.HC")
       └─ RUN.HC: wait for RLf_ADAM_SERVER, go fullscreen,
          try { ExeFile2("E:/MAIN.HC"); } catch { log it }
          write E:/STAT.TXT + E:/LOG.TXT, hold picture 4 s, Reboot
                │
                ▼  on the host (tools/run.sh, all output in RUN_DIR)
-no-reboot turns the guest's Reboot into a clean QEMU exit; rolling QMP
screendumps kept the last frame; mtools pulls STAT/LOG off xfer.img
```

Boot detail: the TempleOS MBR loader blocks on a drive menu each boot;
run.sh/gui.sh/install_os.sh answer it with blind `1` keypresses (the BIOS
keyboard buffer holds early presses, duplicates are harmless).

GLSL sources: when SRC ends in `.glsl`, run.sh/gui.sh transpile it with
`tools/glsl2hc.py --runner none` to `RUN_DIR/shader.HC` (retained as a
debugging artifact), export `HOLYTOY_SHADER`, and retarget the run at
`src/holytoy/HT.HC` (`holy_prepare_glsl`, tools/run-common.sh). A
transpile failure exits 1 before any VM boots, diagnostic on stderr.
mkxfer.sh ships `HOLYTOY_SHADER` (any `--runner none` .HC works) as
`E:/SHADER.HC`; the app compiles it at startup and prints `HT GLSL OK`
or `HT GLSL FAIL` to guest.log. mkxfer.sh also always ships
`src/holytoy/HTMATH.HC` as `E:/HTMATH.HC` and
`src/holytoy/HTRENDER.HC` as `E:/HTRENDER.HC`; HT.HC `#include`s both.
The app shader ABI returns unclamped RGBA through `CHtFragColor`. The
renderer owns clamping, bottom-left pixel-center coordinates, palette
quantization, and deterministic 4x4 Bayer dithering.

The ABI carries mouse positions in raw viewport pixels with Y down. Emitted
GLSL maps these to Shadertoy `iMouse`: xy is the current Y-up position; zw is
the latched click position while held, its negation after release, or zero
before the first click.

Driving a live VM: `python3 tools/qmp.py RUN_DIR/qmp.sock VERB ...` —
keyboard (`keys`/`type`/`typefile`), `screendump`, and mouse injection:
`mouse-rel DX DY` (raw PS/2 counts, chunked/paced), `mouse-btn
left|right down|up`, `mouse-to X Y` (slam to the top-left edge anchor,
then `QMP_MOUSE_COUNTS_PER_PX` counts per pixel — default 2 because the
golden image boots `ms_hard.scale=0.5`; landings are accurate to about
+-16 px, so callers must assert with tolerance).

## Guest-code rules (violating these cost real debugging time)

* **ASCII only** in anything sent to the guest — TempleOS has its own
  8-bit charset; UTF-8 (`π`, em-dashes) arrives as mojibake and breaks
  compilation.
* Transfer-disk filenames: single-dot UPPERCASE 8.3 (`LOG.TXT`). A second
  dot (`FOO.HC.Z`) triggers TempleOS .Z auto-compression
  (`IsDotZ`, Kernel/BlkDev/DskStrA.HC).
* Drive letters: boot disk is C/D, transfer disk mounts as **E:**.
  ATA letters are hard-ranged C–L (`Let2BlkDevType`,
  Kernel/BlkDev/DskDrv.HC) — 'B' is impossible for an ATA disk.
* `ExeFile` swallows `'Compiler'` exceptions (Compiler/CMain.HC:589);
  use **`ExeFile2`** when you need to catch compile errors.
* Compile errors only *throw* after boot reaches `RLf_ADAM_SERVER`;
  before that, `LexExcept` opens the interactive debugger
  (Compiler/CExcept.HC). guest/RUN.HC waits for the run-level bit —
  keep that if you touch it.
* A hard runtime fault (bad pointer) drops the guest into the debugger.
  The host's `RUN_TIMEOUT` (config.sh, 90 s) kills the VM → exit 2, and
  the run's `screen.txt` contains the register dump.
* The "shader" idiom: install `Fs->draw_it=&DrawIt;` (called ~30 fps,
  see src/gradient.HC and vendor Demo/Graphics/Box.HC). One-shot DCAlias
  drawing also persists, but draw_it survives window redraws.

## Harness invariants

* `images/golden.qcow2` is **read-only**; runs use fresh qcow2 overlays.
  Guest disk corruption is by construction a non-event.
* Batch and GUI VMs share `MAX_RUNS` persistent slot locks. Excess callers
  poll all slots for up to `RUN_QUEUE_TIMEOUT`; never bypass this semaphore.
* Each VM owns its overlay, transfer disk, QMP socket, and artifacts. Batch
  runs, GUI sessions, agents, and watch iterations may therefore overlap.
* Completed directories are pruned to the newest `KEEP_RUNS`. Active locks
  are skipped and do not count toward the limit. `make clean` removes all
  unlocked runs but never active runs or persistent `images/slot.*` files.
  Allocation and pruning share persistent `out/runs/.registry.lock`, so a
  new directory cannot be observed between creation and liveness locking.
  A failed deletion is warned about and skipped rather than blocking runs.
* `guest/` is the source of truth for guest-side code. `RUN.HC` is
  refreshed onto the transfer disk every run; `ONCE.HC` is baked into the
  golden image (changing it requires `tools/install_os.sh --hook-only`).
* Inspect a retained transfer disk with
  `MTOOLSRC=<run-dir>/mtools.conf mdir x:/`.
* All knobs live in `config.sh` (including `ANIM_FRAMES` for GIF/proof
  trailing-frame count).

## Rebuilding the golden image

`make golden` is fully unattended (~72 s measured): it drives the ISO's
VM-install wizard over QMP send-key, gating each step on screen text via
scrtext.py, then injects guest/ONCE.HC by typing guest/INJECT.HC at the
shell. Checkpoints land in `out/install/`. `--force` rebuilds from
scratch; `--hook-only` re-injects the hook into an existing image.

Manual fallback (~60 s): boot
`qemu-system-x86_64 -m 512 -drive file=images/golden.qcow2,format=qcow2 -cdrom images/TempleOS.ISO -boot d -display gtk`,
answer `y` (install), `y` (VM?), any key, wait, `y` (reboot now), then run
`tools/install_os.sh --hook-only`.

## Troubleshooting

* **exit 2, `status='none'`** — the hook never ran. Check the run's
  `screen.txt`: MBR "Selection:" menu = boot keypress misfired
  (rerun); register dump = pre-hook crash.
* **exit 2 after 90 s** — guest hung or sits in the debugger; see that run's
  `screen.txt`, `guest.log`, and `qemu.log`. Long-running toys may need a
  larger `RUN_TIMEOUT` in `config.sh`.
* **`Drive 'X:' not supported`** — you forgot `MTOOLSRC` (above).
* **ISO download fails** — templeos.org drops connections; retry
  `make fetch-iso`. Any TempleOS 5.03 ISO works (17,350,656 bytes, 2017).
* **Reading vendor/ sources** — many files carry DolDoc binary codes:
  `python3 skills/holyc/scripts/strip_doldoc.py FILE`. Open questions
  about HolyC/TempleOS behavior: answer from `vendor/TempleOS` source,
  never from memory.

## Environment

WSL2 Ubuntu; qemu/mtools installed via `nix profile add` (no sudo here).
`/dev/kvm` absent → TCG (config.sh auto-enables KVM when present).
`make gui` needs WSLg (`DISPLAY` set). A parallel agent session maintains
`skills/holyc/` and `vendor/TempleOS` — coordinate through git, don't
rewrite those trees.

## Layout

```
config.sh        all knobs (sizes, timeouts, paths)
tools/           run.sh run-common.sh watch.sh gui.sh install_os.sh test.sh
                 qmp.py (QMP client) scrtext.py (screen->text OCR)
                 mkxfer.sh (FAT32 transfer disk) imginfo.py test-run-locks.sh
guest/           ONCE.HC (boot hook) RUN.HC (runner) INJECT.HC (installer)
src/             toys (gradient.HC = hello world)
tests/           fixtures for make test
images/          gitignored: ISO, golden.qcow2, persistent slot locks
out/runs/        gitignored: per-VM dirs and persistent .registry.lock
out/install/     gitignored: golden-image installation checkpoints
plans/           ordered implementation plans and status index
vendor/TempleOS  reference source (cia-foundation/TempleOS)
skills/holyc     HolyC knowledge base (maintained by a parallel agent)
docs/            VISION.md (v1 spec), img/
```
