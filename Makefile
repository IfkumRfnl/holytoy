# holytoy — live-coded per-pixel HolyC playground for TempleOS
#
#   make golden              one-time: install TempleOS -> images/golden.qcow2
#   make run SRC=src/foo.HC  inject, boot, screenshot -> out/latest.png
#   make watch SRC=...       re-run on every save
#   make gui [SRC=...]       visible QEMU window (WSLg), guest stays up
#   make test                smoke + gradient + error-surfacing proofs
#   make fetch-iso           (re)download the TempleOS ISO
#   make clean               remove run artifacts (never the golden image)

SRC ?= src/gradient.HC

.PHONY: run watch gui test golden fetch-iso clean

run:
	tools/run.sh $(SRC)

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
	rm -rf out images/work.qcow2 images/xfer.img images/*.sock images/mtools.conf
