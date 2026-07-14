# holytoy — live-coded per-pixel HolyC playground for TempleOS
#
#   make golden              one-time: install TempleOS -> images/golden.qcow2
#   make run SRC=src/foo.HC  inject, boot, print isolated result directory
#   make watch SRC=...       re-run on every save
#   make gui [SRC=...]       visible QEMU window (WSLg), guest stays up
#   make test                end-to-end host and VM proofs
#   make fetch-iso           (re)download the TempleOS ISO
#   make clean               remove run artifacts (never the golden image)

SRC ?= src/gradient.HC

.PHONY: run watch gui test golden fetch-iso clean

run:
	@tools/run.sh $(SRC)

watch:
	tools/watch.sh $(SRC)

gui:
	tools/gui.sh $(SRC)

test:
	tools/test.sh

golden:
	tools/install_os.sh

fetch-iso:
	wget --tries=3 --timeout=60 -O images/TempleOS.ISO \
		https://templeos.org/Downloads/TempleOS.ISO

clean:
	tools/prune-runs.sh 0
	rm -rf $(addprefix out/,latest.png screen.txt guest.log status qemu.log frames anim.gif) \
		images/work.qcow2 images/xfer.img \
		images/qmp-run.sock images/qmp-gui.sock images/mtools.conf
