# holytoy

> The product is a full Shadertoy clone running *inside* TempleOS — code
> input box + live viewport, GLSL fragment shaders transpiled to HolyC,
> LUT-based fast math. All of that is the scope of **v1**, the first real
> version — see **[docs/VISION.md](docs/VISION.md)**. What exists today is
> the dev harness described below: the proof loop we build the app with.

A Shadertoy-style live-coding playground for **HolyC on real TempleOS**,
running headless in QEMU. Edit a `.HC` file, run one command, and seconds
later you have a screenshot of what TempleOS drew, plus guest-side logs and
compiler errors — with exit codes an agent (or a Makefile) can trust.

```
make golden                      # one-time: ISO -> installed golden image (~1-2 min)
make run SRC=src/gradient.HC     # edit/run cycle (~20 s)  -> out/latest.png
make watch SRC=src/gradient.HC   # re-run on every save
make gui SRC=src/gradient.HC     # visible QEMU window (WSLg), stays up
make test                        # the three proofs (see below)
```

## How a run works

```
src/foo.HC ──mtools──> images/xfer.img (FAT32, MBR type 0x0C)  as MAIN.HC
                       + guest/RUN.HC (runner, refreshed every run)
                │
                ▼
QEMU boots images/work.qcow2 — a throwaway overlay on the read-only
images/golden.qcow2 (corruption is a non-event; every run is pristine)
                │
                ▼  in the guest
C:/Home/Once.HC (hook baked into the golden image)
  └─ ATAMount('E',...) the transfer disk, ExeFile("E:/RUN.HC")
       └─ RUN.HC: wait for RLf_ADAM_SERVER, go fullscreen,
          try { ExeFile2("E:/MAIN.HC"); } catch { log it }
          write E:/STAT.TXT + E:/LOG.TXT, hold picture 4 s, Reboot
                │
                ▼  on the host (tools/run.sh)
-no-reboot turns the guest's Reboot into a clean QEMU exit; rolling QMP
screendumps kept the last frame; mtools pulls STAT/LOG off xfer.img
```

Outputs (fixed paths, overwritten every run):

| path             | contents                                             |
|------------------|------------------------------------------------------|
| `out/latest.png` | last stable frame of the guest screen (640x480)      |
| `out/screen.txt` | the same frame as text (exact 8x8 glyph OCR)         |
| `out/guest.log`  | guest task doc dump — compiler/runtime errors appear here |
| `out/status`     | raw guest status line (`OK` / `ERR` / `OK NOSRC`)    |

Exit codes of `tools/run.sh` (and therefore `make run`):

* **0** — guest compiled and ran the source
* **1** — guest reported a compile/runtime error (read `out/guest.log`)
* **2** — harness failure: timeout, no guest status, missing golden image

## The three proofs (`make test`)

1. **smoke** — a generated program writes a unique marker string to
   `E:/MARKER.TXT`; the host reads it back off the transfer disk.
2. **gradient** — `src/gradient.HC` runs; the screenshot must be 640x480
   with ≥8 distinct colors (it draws 16 bands via a `draw_it` callback).
3. **error** — `tests/syntax-error.HC` must produce exit 1 with the
   TempleOS compiler message (`ERROR: ... E:/MAIN.HC,NNNN`) in `out/guest.log`.

## Writing toys

Sources are plain HolyC executed top-to-bottom by the JIT (no `main`).
The runner has already made the window fullscreen/borderless. The idiomatic
"shader" shape (see `src/gradient.HC`, `vendor/TempleOS/Demo/Graphics/Box.HC`):

```holyc
U0 DrawIt(CTask *,CDC *dc)
{ // called every frame (~30 fps); 640x480, 16-color palette
  dc->color=RED;
  GrLine(dc,0,0,Fs->pix_width-1,Fs->pix_height-1);
}
Fs->draw_it=&DrawIt;
```

Gotchas the harness already encodes, worth knowing when you write guest code:

* **ASCII only** in sources — TempleOS uses its own 8-bit charset; UTF-8
  (e.g. `π`) reaches the compiler as mojibake and fails.
* Transfer-disk filenames: single-dot UPPERCASE 8.3 (`LOG.TXT`). A second
  dot (`FOO.HC.Z`) triggers TempleOS auto-compression.
* Drive letters: boot disk is C/D, transfer disk mounts as **E:**.
  ATA letters are hard-ranged C–L (`Kernel/BlkDev/DskDrv.HC`).
* Compile errors only *throw* (catchably) after boot reaches
  `RLf_ADAM_SERVER`; earlier they open the interactive debugger.
  `ExeFile` swallows `'Compiler'`; `ExeFile2` propagates it.
* A hard runtime fault (bad pointer etc.) drops the guest into the
  debugger — the host's 90 s `RUN_TIMEOUT` (config.sh) then kills the VM
  and you get exit 2 with `out/screen.txt` showing the register dump.

## One-time setup

```
make fetch-iso    # if images/TempleOS.ISO is missing (templeos.org is flaky;
                  # retry, or fetch any TempleOS 5.03 ISO mirror)
make golden       # fully unattended: installs, injects the boot hook,
                  # locks images/golden.qcow2 read-only  (~1-2 min TCG)
make test
```

`make golden` drives the ISO's own VM-install wizard over QMP `send-key`,
gating each step on *screen text* (`tools/scrtext.py` glyph-matches
screendumps against the kernel font — TempleOS text is pixel-exact, no
fuzzy OCR). Checkpoint PNGs land in `out/install/` for post-mortem.

Manual fallback (~60 s, if the script ever misbehaves): run
`qemu-system-x86_64 -m 512 -drive file=images/golden.qcow2,format=qcow2 -cdrom images/TempleOS.ISO -boot d -display gtk`
and answer: `y` (install) · `y` (VM?) · any key · wait · `y` (reboot now).
Then `tools/install_os.sh --hook-only` injects the boot hook.

## Environment notes

* Built for WSL2 Ubuntu; QEMU/mtools installed via nix profile. KVM is used
  automatically when `/dev/kvm` exists (plain WSL2 lacks it — TCG is fine,
  TempleOS is tiny; the whole run cycle is ~20 s).
* `make gui` uses WSLg (`DISPLAY` must be set). The guest stays up; the
  injected source auto-runs but doesn't reboot (`E:/GUI.TXT` marker).
* Concurrency-safe: runs serialize on `images/run.lock` (flock), so two
  agents/watchers can share the repo without corrupting artifacts.

## Troubleshooting

* **exit 2, `status='none'`** — the hook never ran. Look at
  `out/screen.txt` / `out/latest.png`: stuck at the MBR "Selection:" menu
  means the boot-menu keypress misfired (rerun); a register dump means the
  guest crashed pre-hook. Rebuild state: `make clean && make run ...`
  (fresh overlay + xfer are made every run anyway).
* **exit 2 after 90 s** — your code hung or faulted into the debugger;
  `out/screen.txt` shows the debugger text. Increase `RUN_TIMEOUT` in
  `config.sh` for long-running toys.
* **Golden image suspect / corrupted** — impossible for runs to corrupt it
  (read-only + overlays), but if you must: `chmod +w images/golden.qcow2;
  make golden` rebuilds from the ISO in ~2 min.
* **`Drive 'X:' not supported` from mtools** — you ran mtools without the
  repo config: `export MTOOLSRC=images/mtools.conf`.
* **ISO download fails** — templeos.org drops connections sometimes;
  `make fetch-iso` retries with wget. Any TempleOS 5.03 ISO works.
* **Reading TempleOS source in `vendor/`** — many files carry DolDoc
  binary codes; `python3 skills/holyc/scripts/strip_doldoc.py FILE` cleans
  them.

## Layout

```
config.sh        all knobs (sizes, timeouts, paths)
tools/           host side: run.sh watch.sh gui.sh install_os.sh
                 qmp.py (QMP client) scrtext.py (screen->text)
                 mkxfer.sh (FAT32 transfer disk) imginfo.py test.sh
guest/           guest side, source of truth:
                 ONCE.HC (boot hook, baked into golden)
                 RUN.HC (runner, refreshed every run)
                 INJECT.HC (typed once by install_os.sh)
src/             your toys (gradient.HC = hello world)
tests/           fixtures for make test
images/          gitignored: ISO, golden.qcow2 (read-only), overlays, xfer
out/             gitignored: latest.png screen.txt guest.log status
vendor/TempleOS  reference source (github.com/cia-foundation/TempleOS)
```
