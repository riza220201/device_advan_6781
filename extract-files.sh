#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#
# Extracts the proprietary blobs this device needs from a stock dump.
# The blobs themselves are Advan/MediaTek's; this script only lists and copies
# them. Pin the source to ADVAN_6781_S34NF2_V4.0_20250304 (build 1741067669)
# -- a newer dump would ship blobs that no longer match the fingerprint the
# ROM presents.

set -e

DEVICE=6781
VENDOR=advan

MY_DIR="${BASH_SOURCE%/*}"
[[ ! -d "${MY_DIR}" ]] && MY_DIR="${PWD}"

ANDROID_ROOT="${MY_DIR}/../../.."

HELPER="${ANDROID_ROOT}/tools/extract-utils/extract_utils.sh"
if [ ! -f "${HELPER}" ]; then
    echo "Unable to find helper script at ${HELPER}" >&2
    exit 1
fi
source "${HELPER}"

# Default to sanitizing the vendor folder before extraction
CLEAN_VENDOR=true

KANG=
SECTION=

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        -n | --no-cleanup) CLEAN_VENDOR=false ;;
        -k | --kang)       KANG="--kang" ;;
        -s | --section)    SECTION="${2}"; shift; CLEAN_VENDOR=false ;;
        *)                 SRC="${1}" ;;
    esac
    shift
done

if [ -z "${SRC}" ]; then
    SRC="adb"
fi

# Fix up blobs that name Android-12 sonames.
#
# AOSP dropped the `_platform` suffix from AIDL NDK backend libraries in
# Android 13. A blob built against the A12 vendor still records the old
# soname, which no longer exists on the target, so it fails at load time --
# a runtime dlopen error, not a build failure, which is why it is easy to
# miss.
#
# Derived from our own ADVAN_6781_S34NF2 dump (2026-09-19: swept every stock
# vendor ELF for _platform.so DT_NEEDED; each entry below names its measured
# consumer). To re-derive after a firmware bump:
#
#   for f in $(find <vendor> -name '*.so' -o -path '*/bin/*' -type f); do
#       readelf -d "$f" | grep -o '[^[]*_platform\.so'
#   done
#
# and confirm each replacement exists as a soong module on lineage-20.0
# BEFORE adding the rename (the arm.graphics lesson: renaming onto a soname
# nothing provides leaves the HAL unable to link).
#
# Deliberately NOT renamed (measured):
#   arm.graphics-V1-ndk_platform.so (8 consumers incl. both mapper impls):
#       soong on this branch builds arm.graphics-V1-ndk_platform WITH the
#       suffix -- stock resolves it from /vendor natively.
#   keymint/secureclock/sharedsecret-V1-ndk_platform.so
#   (keymint-service.trustonic): the v31 set carries exactly those, so
#   leaving the binary alone IS the fix under a v31 vendor namespace.
#   memtrack-V1-ndk_platform.so (memtrack-service.mediatek, 29,176 B):
#   same -- native _platform request, no rename.
#
# Owed at Phase 2 boot (each needs crash/link evidence on THIS device,
# never analogy):
#   libeffectsconfig.so (does stock's libeffects.so crash against the
#       platform parser? -- the A12/A13 EffectLoadXmlEffectConfig layout
#       question; vendor-deps gate + HAL restart count decide)
#   the A12 codec2 set (which generation the C2 stack pins to -- device.mk
#       deliberately requests neither generation yet)
#   (RESOLVED 2026-09-29: biometrics face jdm-service's common-V2 /
#   keymaster-V3 _platform refs -> hardware/lineage/compat forwarding
#   libraries requested in device.mk, after the vendor-deps gate flagged
#   the -vndk31 copies as unreachable from the default namespace.)
# Stock's Android-12 codec2 set, shipped alongside the platform's Android-13
# one. Under a v31 vendor namespace the MTK C2 HAL needs A12 partners (the
# platform's copies crash-loop it on v33-only symbols), but these are AOSP
# libraries and soong builds VENDOR VARIANTS of them whether or not the
# product asks -- so a prebuilt installing to the same /vendor path is a
# duplicate make rule. Hence the -stock renames (proprietary-files.txt
# src:dst): a unique soong `name` with a `stem` does NOT fix it (stem avoids
# the module-NAME clash; the install PATH stays identical). Distinct
# filenames are the only route.
#
# The eleven move as one generation: holding back part of the set splits one
# process across VNDK generations (the two-libutils condition relocated
# into codec2).
C2_STOCK_LIBS="android.hardware.media.c2@1.0 android.hardware.media.c2@1.1 \
android.hardware.media.c2@1.2 libcodec2_hidl@1.0 libcodec2_hidl@1.1 \
libcodec2_hidl@1.2 libcodec2_hidl_plugin libcodec2_vndk libcodec2_soft_common \
libsfplugin_ccodec_utils libstagefright_bufferpool@2.0.1"

# Repoint every reference to the renamed set, then prove none survived.
#
# `local` is MANDATORY on loop variables: blob_fixup() is called from inside
# extract()'s own loop and shares its scope. patchelf --replace-needed is a
# silent no-op (exit 0) when the dependency is absent, so this needs no error
# suppression and real failures stay visible.
function c2_stock_repoint() {
    local target="${1}" lib
    for lib in ${C2_STOCK_LIBS}; do
        "${PATCHELF}" --replace-needed "${lib}.so" "${lib}-stock.so" "${target}"
    done
    for lib in ${C2_STOCK_LIBS}; do
        if "${PATCHELF}" --print-needed "${target}" | grep -qx "${lib}.so"; then
            echo "!! blob_fixup: ${target} still needs ${lib}.so after repointing" >&2
            exit 1
        fi
    done
}

function blob_fixup() {
    case "${1}" in
        vendor/bin/hw/android.hardware.audio.service.mediatek | \
        vendor/lib/hw/android.hardware.audio@6.0-impl-mediatek.so | \
        vendor/lib64/hw/android.hardware.audio@6.0-impl-mediatek.so | \
        vendor/lib/hw/android.hardware.audio@7.0-impl-mediatek.so | \
        vendor/lib64/hw/android.hardware.audio@7.0-impl-mediatek.so)
            # Drop ONE vestigial dependency (measured: all five reference
            # libaudiofoundation.so, whose symbols none of them -- nor
            # anything else on /vendor -- takes). Renaming that string to
            # liblog.so prunes the A13 interface cascade (incl. the
            # libaudioclient_aidl_conversion that kills processes against
            # v31 libutils) out of the audio HAL's runtime set. The RS4
            # tree proved this live; here the reference pattern is
            # identical (same five files, same single reference each).
            # No verneed repair needed (checked pattern: no .gnu.version_r
            # entry -- re-verify on the built image if this ever misbehaves).
            "${PATCHELF}" --replace-needed "libaudiofoundation.so" "liblog.so" "${2}"
            ;;
        vendor/lib64/android.hardware.power-service-mediatek-stock.so | \
        vendor/bin/hw/vendor.mediatek.hardware.mtkpower@1.0-service)
            # Consumer side of the power impl rename above: the service host
            # links the impl by its stock soname, repointed here. (The impl
            # lib itself needs no repoint -- it links power-V2-ndk_platform,
            # handled in its own case.)
            "${PATCHELF}" --replace-needed "android.hardware.power-service-mediatek.so" \
                "android.hardware.power-service-mediatek-stock.so" "${2}"
            # The AIDL power provider links power-V2-ndk_platform.so, which
            # exists nowhere in stock's vendor OR system (stock resolves it
            # from the v31 apex, which this ROM does not ship). The
            # replacement genuinely exists here: device.mk requests
            # android.hardware.power-V2-ndk.vendor. If that request is ever
            # dropped, this rename dangles and the boot loop returns -- the
            # two belong together.
            "${PATCHELF}" --replace-needed "android.hardware.power-V2-ndk_platform.so" \
                "android.hardware.power-V2-ndk.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.lights-service.mediatek)
            # Boot-blocking otherwise (LightsService.waitForDeclaredService
            # stalls system_server into a Watchdog kill -- RS4 mechanism;
            # the Advan binary carries the same _platform reference).
            "${PATCHELF}" --replace-needed "android.hardware.light-V1-ndk_platform.so" \
                "android.hardware.light-V1-ndk.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.gnss-service.mediatek | \
        vendor/lib64/hw/android.hardware.gnss-impl-mediatek.so)
            "${PATCHELF}" --replace-needed "android.hardware.gnss-V1-ndk_platform.so" \
                "android.hardware.gnss-V1-ndk.so" "${2}"
            ;;
        vendor/bin/hw/android.hardware.wifi@1.0-service-stock)
            # Stock's Wi-Fi HAL, and it has to be stock's: only stock's
            # libwifi-hal.so powers the chip (measured: wmtWifi ×1 in the
            # 64-bit stock library, ×0 in the platform build -- and the
            # platform's hardware/mediatek/wlan carries zero wmtWifi
            # references at all). Both halves renamed because libwifi-hal
            # and the lazy service are BOTH unconditional kati modules:
            # leaving either defined collides at parse time.
            "${PATCHELF}" --replace-needed "libwifi-hal.so" \
                "libwifi-hal-stock.so" "${2}"
            ;;
        vendor/etc/init/android.hardware.wifi@1.0-service-stock.rc)
            # Follow the binary rename into its init script. Only the exec
            # PATH changes; the service name (vendor.wifi_hal_legacy) and
            # the `interface` lines stay exactly as stock wrote them --
            # those are what hwservicemanager matches to lazy-start the HAL.
            sed -i 's|\(/vendor/bin/hw/android\.hardware\.wifi@1\.0-service\)-lazy$|\1-stock|' "${2}"
            # Loud: a sed matching nothing leaves the defect it was added
            # to fix and the build would not notice.
            grep -q '/vendor/bin/hw/android\.hardware\.wifi@1\.0-service-stock$' "${2}" || {
                echo "!! blob_fixup: wifi rc was not repointed to -stock -- pattern stale" >&2
                exit 1
            }
            ;;
        vendor/etc/init/vibrator-mtk-default.rc)
            # Same shape: init service pointed at a binary this tree
            # installs under a different name. The vibrator ships -stock
            # because hardware/mediatek/aidl/vibrator defines its module
            # name in kati (defined on every build, no prefer: rescue).
            sed -i 's|\(/vendor/bin/hw/android\.hardware\.vibrator-service\.mediatek\)$|\1-stock|' "${2}"
            grep -q 'vibrator-service\.mediatek-stock$' "${2}" || {
                echo "!! blob_fixup: vibrator rc was not repointed to -stock -- pattern stale" >&2
                exit 1
            }
            ;;
        vendor/lib/libeffects.so | vendor/lib64/libeffects.so)
            # Point stock's effects factory at stock's config parser shipped
            # under a distinct filename (proprietary-files.txt maps
            # libeffectsconfig.so -> libeffectsconfig-stock.so). The plain
            # name collides: frameworks/av/media/libeffects/config defines
            # it, and a prebuilt of the same name is a duplicate definition
            # (base_rules.mk). Only libeffects.so links libeffectsconfig,
            # both ABIs, so this rename reaches every consumer. Whether the
            # stock parser is also RUNTIME-needed (the A12/A13 struct-layout
            # crash question) is owed to Phase-2 boot evidence -- the rename
            # here is build-necessary regardless.
            "${PATCHELF}" --replace-needed "libeffectsconfig.so" \
                "libeffectsconfig-stock.so" "${2}"
            ;;
        vendor/lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so)
            # blob_fixup keys on the DESTINATION path, and this impl is itself
            # renamed -stock. The case used to name the pre-rename file, so it
            # never matched and the impl shipped still needing libmtk_bsg.so
            # (vendor-deps gate, build ad; the only dead pattern of 38 -- audited).
            # libmtk_bsg ships -stock for the usual reason: hardware/mediatek
            # defines that module name in its own soong namespace, so nothing
            # is displaced and a same-named blob collides. The boot impl is
            # the only consumer shipped here (both ABIs audited; the tree
            # carries the 64-bit impl only).
            "${PATCHELF}" --replace-needed "libmtk_bsg.so" \
                "libmtk_bsg-stock.so" "${2}"
            ;;
        # ---- the renamed A12 codec2 set ------------------------------------
        # SONAME is patched as well as DT_NEEDED, and it is not optional: the
        # platform's A13 copy keeps the canonical name and stays installed, so
        # if both ever land in one process the first loaded wins the name for
        # all of it. The soname comes from the destination filename, so it
        # cannot drift from proprietary-files.txt's rename.
        vendor/lib64/android.hardware.media.c2@1.0-stock.so | \
        vendor/lib64/android.hardware.media.c2@1.1-stock.so | \
        vendor/lib64/android.hardware.media.c2@1.2-stock.so | \
        vendor/lib64/libcodec2_hidl@1.0-stock.so | \
        vendor/lib64/libcodec2_hidl@1.1-stock.so | \
        vendor/lib64/libcodec2_hidl@1.2-stock.so | \
        vendor/lib64/libcodec2_hidl_plugin-stock.so | \
        vendor/lib64/libcodec2_vndk-stock.so | \
        vendor/lib64/libcodec2_soft_common-stock.so | \
        vendor/lib64/libsfplugin_ccodec_utils-stock.so | \
        vendor/lib64/libstagefright_bufferpool@2.0.1-stock.so)
            "${PATCHELF}" --set-soname "$(basename "${2}")" "${2}"
            c2_stock_repoint "${2}"
            ;;
        # ---- the MTK blobs that consume them --------------------------------
        # Every /vendor consumer of libcodec2_vndk.so: the C2 service binary
        # first, then the MTK component libraries it dlopens. Verified present
        # in Advan stock (c2store, vdec, venc, soft_mtk_*, vpp_*).
        vendor/bin/hw/android.hardware.media.c2@1.2-mediatek-64b | \
        vendor/lib64/libcodec2_mtk_c2store.so | \
        vendor/lib64/libcodec2_mtk_vdec.so | \
        vendor/lib64/libcodec2_mtk_venc.so | \
        vendor/lib64/libcodec2_soft_mtk_alacdec.so | \
        vendor/lib64/libcodec2_soft_mtk_apedec.so | \
        vendor/lib64/libcodec2_soft_mtk_imaadpcmdec.so | \
        vendor/lib64/libcodec2_soft_mtk_mp3dec.so | \
        vendor/lib64/libcodec2_soft_mtk_msadpcmdec.so | \
        vendor/lib64/libcodec2_vpp_qt_plugin.so | \
        vendor/lib64/libcodec2_vpp_rs_plugin.so)
            c2_stock_repoint "${2}"
            ;;
        vendor/etc/init/android.hardware.media.c2@1.2-mediatek.rc)
            # Stock ships TWO c2 binaries (8,204 B 32-bit + 15,616 B 64-bit
            # -- byte-identical sizes to the RS4 stock pair) and exactly ONE
            # rc, naming the 32-bit one. This tree is 64-bit-only for codec2,
            # so the rc is repointed at -64b; stock has no rc for -64b
            # either, and as extracted the installed binary would have no rc
            # at all (declared-but-unimplemented VINTF shape).
            sed -i 's|\(/vendor/bin/hw/android\.hardware\.media\.c2@1\.2-mediatek\)$|\1-64b|' "${2}"
            grep -q 'mediatek-64b$' "${2}" || {
                echo "!! blob_fixup: c2 rc was not repointed to -64b -- pattern stale" >&2
                exit 1
            }
            ;;
    esac
}

setup_vendor "${DEVICE}" "${VENDOR}" "${ANDROID_ROOT}" false "${CLEAN_VENDOR}"
extract "${MY_DIR}/proprietary-files.txt" "${SRC}" "${KANG}" --section "${SECTION}"

"${MY_DIR}/setup-makefiles.sh"

# CLEAN_VENDOR defaults to true, so the run above WIPED the vendor directory
# and re-extracted everything from stock -- including the GPU driver.
#
# The vendor repository carries the r54p1 driver (donor SM-A175F
# r54p1-12eac0; vendor/advan/6781/MANIFEST.md). A clean extraction undoes it
# in two ways, with no error and no warning:
#   - the UMD and libgpud (both ABIs) are overwritten with stock r32p1, which
#     shows up as modified files in `git status`;
#   - the donor-only libraries (proprietary-files-r54p1.txt) are DELETED,
#     because stock has none of them -- and a UMD restored without them
#     cannot load (DT_NEEDED), so restore all of them together.
# Then wipe the shader caches on first boot:
#     rm -f /data/user_de/0/*/code_cache/com.android.*.shaders_cache
R54_PATHS="proprietary/vendor/lib64/egl/mt6789/libGLES_mali.so
proprietary/vendor/lib/egl/mt6789/libGLES_mali.so
proprietary/vendor/lib64/libgpud.so
proprietary/vendor/lib/libgpud.so
$(sed -n 's|^-vendor/|proprietary/vendor/|p' "${MY_DIR}/proprietary-files-r54p1.txt")"
if git -C "${ANDROID_ROOT}/vendor/${VENDOR}/${DEVICE}" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "${ANDROID_ROOT}/vendor/${VENDOR}/${DEVICE}" diff --quiet -- \
            ${R54_PATHS} 2>/dev/null; then
        echo
        echo "NOTE: extraction replaced or removed the r54p1 GPU userspace"
        echo "      (the driver is now stock r32p1, Vulkan 1.1). To restore it:"
        echo "          git -C vendor/${VENDOR}/${DEVICE} checkout -- \\"
        echo "${R54_PATHS}" | sed 's/^/              /; $!s/$/ \\/'
        echo "      Then wipe the shader caches on first boot (see above)."
    fi
fi
