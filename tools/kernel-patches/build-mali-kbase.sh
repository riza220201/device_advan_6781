#!/bin/bash
# Build Mali r54p1 kbase for MT6789 against the Advan GKI 5.10 kernel.
#
# Parameterized copy of the RS4 tree's tools/kernel-patches/build-mali-kbase.sh
# (same donor r54p1-12eac0, same MT6789, same A12 ged). Advan deltas vs RS4,
# all measured 2026-09-19 (see the device-tree JOURNAL):
#   - stock kbase dep closure is 8 modules
#     (irq-dbg,ged,mtk_gpufreq_wrapper,sspm_v3,mtk_gpu_qos,mtk_gpu_hal,mrdump,
#     tinysys-scmi), not RS4's 5 -- re-verify the built module's imports and
#     `depends=` against THIS list, not RS4's, before shipping.
#   - Advan vermagic is 5.10.209-... (KMI layout identical: 0x7c24b32d).
#   - BM_2 MUST reach the preprocessor (-DCONFIG_MALI_MTK_GPU_BM_2=1 in
#     KCFLAGS below, NOT just CONFIG_MALI_MTK_GPU_BM_2=y on the make line):
#     it is a UAPI ABI switch (frame_nr field, 64 vs 72-byte atoms), and a
#     make-only setting silently builds a kbase that rejects userspace.
#   - 0003 (A12 ged wants BOOL 1, A16 headers say GED_POWER_ON==2) applies
#     unchanged: Advan's ged.ko is A12, same one-bit DVFS killer.
#
# Prerequisites (owed before first run, not present in this repo):
#   GPU source (Samsung open source, a16w_jm) + MTK device-module headers
#   (Samsung Kernel.tar.gz) + the Advan kernel tree built once (for symvers).
# After `make`: llvm-strip --strip-debug, then VERIFY by reconstruction
# (strip must reproduce a known module byte-for-byte before trusting it).
set -uo pipefail
# The shipped kernel is itel-rs4-kernel's vanilla variant (operator,
# 2026-09-29). The current kbase was built against the retired Advan-Kernel
# fork (5.10.268) and passes the KMI gate against the 5.10.269 vanilla
# symvers unchanged; a rebuild here would target the shipped kernel.
KPROJECT="${KERNEL_PROJECT:-$HOME/itel-rs4-kernel}"
MALIBUILD="${MALIBUILD:-$HOME/advan-malibuild}"
K="${KPROJECT}/common"
B="${KPROJECT}/.build/out-vanilla"
# KBUILD_EXTRA_SYMBOLS is the MODULE-ONLY symvers (tools/gen-vendor-symvers.py):
# vmlinux symbols must NOT be listed -- modpost reads vmlinux itself, and a
# duplicate entry fails with "exported twice". (Measured 2026-09-19: passing
# the kernel's own Module.symvers broke the build exactly that way.)
SYMVERS="${KBUILD_SYMVERS:-$MALIBUILD/vendor.symvers}"
DM="$MALIBUILD/dm"             # MTK device-modules headers (DEVICE_MODULES_PATH)
MID="$MALIBUILD/gpu/gpu_mali/mali_avalon/a16w_jm/drivers/gpu/arm/midgard"
export PATH="$KPROJECT/toolchain/clang-r416183b/bin:$PATH"
log(){ echo "[$(date +%H:%M:%S)] $*"; }

if [ ! -d "$DM" ]; then
  log "extract MTK device-module headers from Samsung Kernel.tar.gz into $DM first"
  log "  (see the RS4 recipe for the tar layout); refusing to guess."
  exit 1
fi

log "building mali_kbase (r54p1, MTK_PLATFORM=mt6789)"
make -C "$K" O="$B" M="$MID" \
  ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu- \
  DEVICE_MODULES_PATH="$DM" MTK_PLATFORM=mt6789 \
  CONFIG_MALI_MIDGARD=m CONFIG_MALI_PLATFORM_NAME=mt6789 \
  CONFIG_GPU_MT6789=y CONFIG_MALI_MTK_COMMON=y CONFIG_MALI_REAL_HW=y \
  CONFIG_MALI_MIDGARD_DVFS=y CONFIG_MALI_DEVFREQ=y CONFIG_MALI_CSF_SUPPORT=n \
  CONFIG_MALI_MTK_MEMTRACK=y CONFIG_MALI_MTK_DEVFREQ_GOVERNOR=y \
  CONFIG_MALI_MTK_DEVFREQ_THERMAL=y CONFIG_MALI_MTK_PROC_FS=y \
  CONFIG_MALI_MTK_PREVENT_PRINTK_TOO_MUCH=y CONFIG_MALI_MTK_GPU_BM_2=y \
  CONFIG_MTK_GPU_COMMON_DVFS_SUPPORT=y \
  CONFIG_MALI_GATOR_SUPPORT=y CONFIG_MALI_BASE_MODULES=y \
  KCFLAGS="-Wno-macro-redefined -Wno-declaration-after-statement -DCONFIG_MTK_GPUFREQ_V2 -DCONFIG_MTK_GPU_LEGACY -DCONFIG_MALI_MTK_GPU_BM_2=1 -DCONFIG_MTK_TINYSYS_SSPM_SUPPORT=1 -DCONFIG_MTK_GPU_COMMON_DVFS_SUPPORT=1 -DCONFIG_MALI_MIDGARD_DVFS=1 -I$DM/drivers/misc/mediatek/sspm/v3 -I$DM/drivers/gpu/mediatek/gpu_bm" \
  KBUILD_EXTRA_SYMBOLS="$SYMVERS" -j"$(nproc)" modules
log "make rc=$?  (read this code, not the shell's exit status)"
