# SPDX-License-Identifier: GPL-2.0
# Out-of-tree build of the patched camera drivers (and the new imx241 driver).
#
# HPCAM_SRC is the patched source tree, relative to this directory ($(M)):
#   build/<tag>/src  in a development checkout (created by scripts/prepare.sh)
#   vendor           in a DKMS / 'make dist' tree
# Each module is a composite object so the resulting .ko files land next to this
# file and keep exactly the in-tree module names (KBUILD_MODNAME is the composite
# name), letting them replace the in-tree modules. imx241 has no in-tree
# counterpart; its source is created by patches/0006 (no pristine upstream file).

ifeq ($(HPCAM_SRC),)
$(error HPCAM_SRC is not set; build through the top-level Makefile)
endif

int3472 := $(HPCAM_SRC)/drivers/platform/x86/intel/int3472

obj-m += intel_skl_int3472_tps68470.o
intel_skl_int3472_tps68470-y := $(int3472)/tps68470.o $(int3472)/tps68470_board_data.o

obj-m += ipu-bridge.o
ipu-bridge-y := $(HPCAM_SRC)/drivers/media/pci/intel/ipu-bridge.o

obj-m += ov8858.o
ov8858-y := $(HPCAM_SRC)/drivers/media/i2c/ov8858.o

obj-m += imx241.o
imx241-y := $(HPCAM_SRC)/drivers/media/i2c/imx241.o

# tps68470.c includes its private "tps68470.h" relative to itself, so no extra
# include path is needed; everything else comes from the kernel headers.
