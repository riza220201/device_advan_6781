#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# REQUIRED: import the kernel this device ships. There is no from-source
# kernel build in this tree (BoardConfig.mk errors out without an import).
#
# WHERE THE KERNEL COMES FROM
#   itel-rs4-kernel     the custom kernel project, VANILLA variant (BORE,
#                        NTSYNC, reflex and the rs4 set, no root). Those
#                        patches belong ONLY there. This device ships the same
#                        vanilla kernel as the S666LN (operator, 2026-09-29):
#                        both stock configs are the same GKI android12-5.10
#                        config (15-line diff, all GKI-drop drift) and share
#                        module_layout 0x7c24b32d. /mnt/external_nvme/Advan-Kernel
#                        was a stale local fork of it and is retired.
#   kernel/advan/6781   NOT a kernel this tree builds (an earlier revision of
#                        this header claimed "plain GKI + 6781_defconfig"; no
#                        such defconfig has ever existed). It is only the
#                        source lineage's generated_kernel_includes reads for
#                        UAPI headers: a symlink to ~/itel-rs4-kernel/common,
#                        the source of the imported Image.
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
# There is no in-tree source build to go back to: without prebuilt/ the
# BoardConfig refuses to build.

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
echo "  The ROM ships exactly this kernel; there is no source-build fallback."
