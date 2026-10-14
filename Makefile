# SPDX-License-Identifier: GPL-2.0
# hp-x2-612-g2-camera: out-of-tree build of patched int3472-tps68470, ipu-bridge
# and ov8858 modules, plus the new imx241 driver, for the HP Pro x2 612 G2.
#
#   make                       fetch+patch (scripts/prepare.sh) and build for `uname -r`
#   make KVER=7.2.9-arch1-1    same, for another installed kernel
#   make modules               build only (tree must already be prepared/vendored)
#   make clean                 remove build artifacts (keeps the fetched-source cache)
#   make distclean             also remove build/ (source cache, dist trees)
#   make dist                  vendor the patched tree into a DKMS source tree + tarball
#                              under build/dist/ (needs network on first fetch only)
#
# In a vendored DKMS tree ('make dist' output) the sources live in ./vendor and
# no fetching/patching happens: 'make' only compiles.

PACKAGE_NAME := hp-x2-612-g2-camera

KVER  ?= $(shell uname -r)
KDIR  ?= /lib/modules/$(KVER)/build
ifeq ($(strip $(KDIR)),)
override KDIR := /lib/modules/$(KVER)/build
endif
MAKEFLAGS += --no-print-directory

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

ifneq ($(wildcard $(ROOT)/vendor/VENDORED),)
# ---- vendored (DKMS) tree -------------------------------------------------
VENDORED   := 1
HPCAM_SRC  ?= vendor
TAG        := $(shell sed -n 's/^tag=//p' $(ROOT)/vendor/VENDORED)
else
# ---- development checkout -------------------------------------------------
VENDORED   :=
TAG        := $(shell $(ROOT)/scripts/prepare.sh --tag $(KVER))
HPCAM_SRC  ?= build/$(TAG)/src
endif

TAGNUM  := $(patsubst v%,%,$(TAG))
TAGBASE := $(firstword $(subst -, ,$(TAGNUM)))
GITREV  := $(shell git -C $(ROOT) rev-list --count HEAD 2>/dev/null)
GITSHA  := $(shell git -C $(ROOT) rev-parse --short HEAD 2>/dev/null)
VERSION ?= $(TAGNUM)$(if $(GITREV),.r$(GITREV).g$(GITSHA))

DISTDIR ?= $(ROOT)/build/dist
DISTTREE = $(DISTDIR)/$(PACKAGE_NAME)-$(VERSION)

KBUILD_ARGS = -C $(KDIR) M=$(ROOT) HPCAM_SRC=$(HPCAM_SRC)

.PHONY: all prepare modules clean distclean dist dist-tree version

ifeq ($(VENDORED),1)
all: modules
prepare:
	@echo "vendored tree ($(TAG)): nothing to prepare"
else
all: prepare
	@$(MAKE) -f $(ROOT)/Makefile modules KVER=$(KVER) KDIR=$(KDIR)
prepare:
	$(ROOT)/scripts/prepare.sh $(KVER)
endif

modules:
	@test -d $(KDIR) || { echo "error: no kernel build dir $(KDIR) (install headers for $(KVER))" >&2; exit 1; }
	@test -f $(ROOT)/$(HPCAM_SRC)/VENDORED -a -f $(ROOT)/$(HPCAM_SRC)/drivers/media/i2c/ov8858.c \
	      -a -f $(ROOT)/$(HPCAM_SRC)/drivers/media/i2c/imx241.c || { echo "error: $(HPCAM_SRC) is not prepared (or the last prepare failed); run 'make prepare KVER=$(KVER)'" >&2; exit 1; }
	@echo "building $(TAG) sources from $(HPCAM_SRC) against $(KVER)"
	$(MAKE) $(KBUILD_ARGS) modules

clean:
	-@test -d $(KDIR) && $(MAKE) $(KBUILD_ARGS) clean >/dev/null 2>&1 || true
	rm -f $(ROOT)/*.ko $(ROOT)/*.mod $(ROOT)/*.mod.c $(ROOT)/*.o $(ROOT)/.*.cmd \
	      $(ROOT)/Module.symvers $(ROOT)/modules.order
	-@test -d $(ROOT)/$(HPCAM_SRC) && find $(ROOT)/$(HPCAM_SRC) \
	      \( -name '*.o' -o -name '.*.cmd' -o -name '*.mod' -o -name '*.mod.c' \) -delete || true

distclean: clean
	rm -rf $(ROOT)/build

version:
	@echo $(VERSION)

# ---- vendoring ---------------------------------------------------------------
# A DKMS source tree must build offline at boot/upgrade time, so instead of
# fetching in PRE_BUILD we vendor the already fetched+patched sources here.
# The generated dkms.conf restricts building to the vendored x.y series (see the
# comment in dkms.conf for the reasoning).
ifeq ($(VENDORED),1)
dist dist-tree:
	@echo "error: already a vendored tree" >&2; exit 1
else
dist: dist-tree
	tar -C $(DISTDIR) -czf $(DISTTREE).tar.gz $(PACKAGE_NAME)-$(VERSION)
	@echo "DKMS tree:  $(DISTTREE)"
	@echo "tarball:    $(DISTTREE).tar.gz"

dist-tree: prepare
	rm -rf $(DISTTREE)
	mkdir -p $(DISTTREE)/vendor
	cp -R $(ROOT)/build/$(TAG)/src/. $(DISTTREE)/vendor/
	find $(DISTTREE)/vendor \( -name '*.o' -o -name '.*.cmd' -o -name '*.mod' \
	      -o -name '*.mod.c' -o -name '*.orig' -o -name '*.rej' \) -delete
	mkdir -p $(DISTTREE)/patches
	-cp $(ROOT)/patches/*.patch $(DISTTREE)/patches/ 2>/dev/null
	cp $(ROOT)/Makefile $(ROOT)/Kbuild $(DISTTREE)/
	sed -e 's/^PACKAGE_VERSION=.*/PACKAGE_VERSION="$(VERSION)"/' \
	    -e 's/^BUILD_EXCLUSIVE_KERNEL=.*/BUILD_EXCLUSIVE_KERNEL="^$(subst .,\\.,$(word 1,$(subst ., ,$(TAGBASE))).$(word 2,$(subst ., ,$(TAGBASE))))\\."/' \
	    $(ROOT)/dkms.conf > $(DISTTREE)/dkms.conf
	echo "version=$(VERSION)" >> $(DISTTREE)/vendor/VENDORED
	echo $(VERSION) > $(DISTTREE)/VERSION
	@echo "vendored $(TAG) as $(PACKAGE_NAME) $(VERSION) into $(DISTTREE)"
endif
