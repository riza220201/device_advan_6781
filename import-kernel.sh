#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# OPTIONAL: ship a kernel built by the separate custom-kernel project instead of
# the GKI source this tree compiles by default.
#
# WHY TWO KERNELS EXIST, AND WHY THEY MUST STAY SEPARATE
#   kernel/advan/6781   plain GKI android12-5.10-lts 5.10.260 + 6781_defconfig.
#                        What this tree builds by default, and what anyone who
#                        clones it reproduces byte for byte.
#   itel-rs4-kernel     the custom kernel project, VANILLA variant (BORE,
#                        NTSYNC, reflex and the rs4 set, no root). Those
#                        patches belong ONLY there. This device ships the same
#                        vanilla kernel as the S666LN (operator, 2026-09-29):
#                        both stock configs are the same GKI android12-5.10
#                        config (15-line diff, all GKI-drop drift) and share
#                        module_layout 0x7c24b32d. /mnt/external_nvme/Advan-Kernel
#                        was a stale local fork of it and is retired.
#
#   Do not "fix" the GKI fork by committing those patches into it. The defconfig
#   in the fork does list CONFIG_SCHED_BORE and CONFIG_NTSYNC; Kconfig discards
#   both silently when the source lacks them, so a from-source build here is a
#   kernel without those features, not a broken one.
#
# WHAT THIS IMPORTS
#   Image.gz          the kernel itself
#   vmlinux.symvers   the symbol CRCs, so the KMI gate can verify an imported
#                     kernel against all 358 prebuilt vendor modules exactly as
#                     it verifies a source-built one. Without it the gate cannot
#                     run at all in prebuilt mode, because FULL_KERNEL_BUILD is
#                     false and $(KERNEL_OUT)/Module.symvers is never produced.
#   kernel.config     kept purely as provenance for what was built.
#
# The import is verified before it is accepted: a kernel whose module_layout is
# not 0x7c24b32d, or which disagrees on any symbol CRC, is rejected here rather
# than at flash time.
#
# To go back to the in-tree source build, delete the prebuilt directory.

set -e

MY_DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL_PROJECT="${KERNEL_PROJECT:-$HOME/itel-rs4-kernel}"
VARIANT="${1:-vanilla}"
# build.sh publishes Image.gz, vmlinux.symvers and kernel.config to
# out/<variant>/, but a release run leaves only the boot.img and AnyKernel3
# zip there. The build's own output dir still holds the same bytes, under the
# kernel's own names: arch/arm64/boot/Image.gz and .config.
SRC="${KERNEL_SRC:-$KERNEL_PROJECT/out/${VARIANT}}"
IMG="${SRC}/Image.gz"
CFG="${SRC}/kernel.config"
if [ ! -f "${IMG}" ] && [ -z "${KERNEL_SRC}" ]; then
    SRC="${KERNEL_PROJECT}/.build/out-${VARIANT}"
    IMG="${SRC}/arch/arm64/boot/Image.gz"
    CFG="${SRC}/.config"
fi
DEST="${MY_DIR}/../6781-kernel/prebuilt"
KMI_LAYOUT="0x7c24b32d"

if [ ! -d "${SRC}" ]; then
    echo "!! no such build: ${SRC}" >&2
    echo "!! build it first:  (cd ${KERNEL_PROJECT} && ./build.sh ${VARIANT})" >&2
    echo "!! or set KERNEL_PROJECT=/path/to/itel-rs4-kernel" >&2
    exit 1
fi

for f in "${IMG}" "${SRC}/vmlinux.symvers"; do
    if [ ! -f "${f}" ]; then
        echo "!! ${f} is missing -- incomplete kernel build?" >&2
        exit 1
    fi
done

echo "Importing ${VARIANT} kernel from ${SRC}"

# Verify BEFORE installing, against both module sets. A kernel that fails here
# would build a ROM that flashes cleanly and bootloops.
for set in vendor_dlkm vendor_boot; do
    dir="${MY_DIR}/../6781-kernel/modules/${set}"
    [ -d "${dir}" ] || continue
    echo "  checking KMI against ${set}..."
    if ! python3 "${MY_DIR}/kmi-check.py" "${SRC}/vmlinux.symvers" "${dir}" "${KMI_LAYOUT}"; then
        echo "!! KMI check FAILED for ${set} -- refusing to import." >&2
        echo "!! This kernel cannot load the stock vendor modules and would not boot." >&2
        exit 1
    fi
done

mkdir -p "${DEST}"
cp -f "${IMG}"                 "${DEST}/Image.gz"
cp -f "${SRC}/vmlinux.symvers" "${DEST}/vmlinux.symvers"
[ -f "${CFG}" ] && cp -f "${CFG}" "${DEST}/kernel.config"

{
    echo "variant:  ${VARIANT}"
    echo "source:   ${SRC}"
    [ -f "${SRC}/include/config/kernel.release" ] && \
        echo "release:  $(cat "${SRC}/include/config/kernel.release")"
    echo "imported: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "sha256:"
    (cd "${DEST}" && sha256sum Image.gz vmlinux.symvers | sed 's/^/  /')
} > "${DEST}/IMPORTED"

echo
echo "Imported to ${DEST}"
echo "  BoardConfig.mk picks this up automatically (TARGET_FORCE_PREBUILT_KERNEL)."
echo "  The ROM will now ship this kernel instead of building kernel/advan/6781."
echo "  Delete ${DEST} to go back to the source build."
