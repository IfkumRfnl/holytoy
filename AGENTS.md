# AGENTS.md — working on holytoy

Operational reference for agents (and humans who want the details).
The product spec is [docs/VISION.md](docs/VISION.md); the pitch is
[README.md](README.md). This file is how to actually drive the machinery.

## Commands

```
make golden                      # one-time: ISO -> installed golden image (~1-2 min, unattended)
make run SRC=src/gradient.HC     # one cycle (~20 s): inject, boot, screenshot, extract logs
make watch SRC=...               # re-run on every save
make gui [SRC=...]               # visible QEMU window (WSLg); guest stays up, no auto-reboot
make test                        # the four proofs (must stay green)
make fetch-iso                   # (re)download images/TempleOS.ISO
make clean                       # remove run artifacts; never touches the golden image
```

## Run artifacts (fixed paths, overwritten every run)

| path                        | contents                                                  |
|-----------------------------|-----------------------------------------------------------|
| `out/latest.png`            | last stable frame of the guest screen (640x480)           |
| `out/screen.txt`            | same frame as text — exact 8x8 glyph OCR, grep this first |
| `out/guest.log`             | guest task-doc dump; compiler/runtime errors appear here  |
| `out/status`                | raw guest status line (`OK` / `ERR` / `OK NOSRC`)         |
| `out/frames/frame-NNNN.png` | rolling per-run screendumps (~0.7 s apart)                |
| `out/anim.gif`              | trailing frames as GIF (best-effort; see `ANIM_FRAMES`)   |

Exit codes of `tools/run.sh` / `make run`:

* **0** — guest compiled and ran the source
* **1** — guest reported a compile/runtime error (read `out/guest.log`)
* **2** — harness failure: timeout, no guest status, missing golden image

Read screenshots yourself: `out/latest.png` is a normal PNG; `out/screen.txt`
is faster to grep. Any screendump can be OCR'd with
`python3 tools/scrtext.py FILE.png [--grep STRING]`.

## How a run works

```
src/foo.HC ──mtools──> images/xfer.img (FAT32, MBR type 0x0C)  as MAIN.HC
                       + guest/RUN.HC (runner, refreshed every run)
                │
                ▼
QEMU boots images/work.qcow2 — throwaway overlay on read-only golden.qcow2
                │
                ▼  in the guest
C:/Home/Once.HC (hook baked into golden)
  └─ ATAMount('E',...) the transfer disk, ExeFile("E:/RUN.HC")
       └─ RUN.HC: wait for RLf_ADAM_SERVER, go fullscreen,
          try { ExeFile2("E:/MAIN.HC"); } catch { log it }
          write E:/STAT.TXT + E:/LOG.TXT, hold picture 4 s, Reboot
                │
                ▼  on the host (tools/run.sh)
-no-reboot turns the guest's Reboot into a clean QEMU exit; rolling QMP
screendumps kept the last frame; mtools pulls STAT/LOG off xfer.img
```

Boot detail: the TempleOS MBR loader blocks on a drive menu each boot;
run.sh/gui.sh/install_os.sh answer it with blind `1` keypresses (the BIOS
keyboard buffer holds early presses, duplicates are harmless).

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
  `out/screen.txt` contains the register dump.
* The "shader" idiom: install `Fs->draw_it=&DrawIt;` (called ~30 fps,
  see src/gradient.HC and vendor Demo/Graphics/Box.HC). One-shot DCAlias
  drawing also persists, but draw_it survives window redraws.

## Harness invariants

* `images/golden.qcow2` is **read-only**; runs use fresh qcow2 overlays.
  Guest disk corruption is by construction a non-event.
* Runs serialize on `images/run.lock` (flock, 300 s wait) — multiple
  agents/watchers share the repo safely. Don't bypass run.sh with your
  own QEMU invocation against the shared overlay/xfer paths.
* `guest/` is the source of truth for guest-side code. `RUN.HC` is
  refreshed onto the transfer disk every run; `ONCE.HC` is baked into the
  golden image (changing it requires `tools/install_os.sh --hook-only`).
* mtools needs the repo config: `export MTOOLSRC=images/mtools.conf`
  (drive `x:` = the transfer disk).
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

* **exit 2, `status='none'`** — the hook never ran. Check
  `out/screen.txt`: MBR "Selection:" menu = boot keypress misfired
  (rerun); register dump = pre-hook crash.
* **exit 2 after 90 s** — guest hung or sits in the debugger; see
  `out/screen.txt`. Long-running toys: raise `RUN_TIMEOUT` in config.sh.
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
tools/           run.sh watch.sh gui.sh install_os.sh test.sh
                 qmp.py (QMP client) scrtext.py (screen->text OCR)
                 mkxfer.sh (FAT32 transfer disk) imginfo.py
guest/           ONCE.HC (boot hook) RUN.HC (runner) INJECT.HC (installer)
src/             toys (gradient.HC = hello world)
tests/           fixtures for make test
images/          gitignored: ISO, golden.qcow2, overlays, xfer, locks
out/             gitignored: run artifacts + install checkpoints
vendor/TempleOS  reference source (cia-foundation/TempleOS)
skills/holyc     HolyC knowledge base (maintained by a parallel agent)
docs/            VISION.md (v1 spec), img/
```
