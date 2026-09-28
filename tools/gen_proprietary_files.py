#!/usr/bin/env python3
"""Generate proprietary-files.txt mechanically from the stock vendor dump.

Only stock content -- see BLUEPRINT section 2. No curated list from any
third-party tree is read or consulted.

Two things make this more than `find`:

1. Anything device.mk or PRODUCT_PACKAGES already installs must be EXCLUDED,
   or the build hits duplicate install rules for the same destination.
2. /vendor/lib*/foo.so -> mt6789/foo.so symlinks are NOT listed here at all:
   symlinks.mk owns all 427 of them (make rules), because extract-utils on
   lineage-20.0 has no working ';SYMLINK=' support. Listing a link path
   would make extract-utils copy the resolved content, duplicating the
   payload; listing it with ';SYMLINK=' breaks 32/64-bit module pairing.

extract-utils conventions (verified against tools/extract-utils/extract_utils.sh):
  no prefix  -> PRODUCT_COPY_FILES
  '-' prefix -> Android.bp prebuilt module + PRODUCT_PACKAGES
  'src:dst'  -> renamed install (used for the -stock renames below)
"""
import os
import sys

# The source dump is a REQUIRED argument, and it must be the stock
# ADVAN_6781_S34NF2 extraction (.build/stock/vendor). Never give this a
# default: the RS4 tree's generator once defaulted to a shipped ROM's vendor
# partition while its docstring claimed stock, putting 44 non-stock paths
# into the blob list and boot-looping the device on a missing power HAL.
# This project already caught its own unpack dir carrying a staged r54p1 UMD
# -- the zip CRC is the provenance check, and this script additionally
# refuses any path containing "shipped".
if len(sys.argv) < 2:
    sys.exit("usage: gen_proprietary_files.py <stock-vendor-dump> [tree]\n"
             "       e.g. .build/stock/vendor   (NEVER a shipped ROM dump)")
V = sys.argv[1]
TREE = sys.argv[2] if len(sys.argv) > 2 else "device/advan/6781"
if "shipped" in os.path.realpath(V):
    sys.exit(f"refusing: {V} looks like a shipped ROM dump, not stock firmware")
OUT = os.path.join(TREE, "proprietary-files.txt")


def names(d):
    p = os.path.join(TREE, d)
    return set(os.listdir(p)) if os.path.isdir(p) else set()


# --- destinations device.mk already owns -------------------------------------
excl = set()
excl |= {"etc/init/hw/" + f for f in names("rootdir/etc/init/hw") if f.endswith(".rc")}
excl |= {"etc/" + f for f in names("configs/audio")}
excl |= {"etc/" + f for f in names("configs/media")}
excl |= {"etc/seccomp_policy/" + f for f in names("configs/seccomp")}
excl |= {"etc/wifi/" + f for f in names("configs/wifi")}
excl |= {
    "etc/init.insmod.mt6789.cfg", "etc/ueventd.rc", "etc/fstab.mt6789",
    "etc/fstab.emmc", "etc/sensors/hals.conf",
    "etc/public.libraries.txt", "etc/task_profiles.json",
    "etc/vintf/manifest.xml", "etc/vintf/compatibility_matrix.xml",
    "bin/init.insmod.sh",
    # device.mk declares this feature ONCE, on product (configs/permissions,
    # version 100 = stock's value). AOSP's keymint default module defines the
    # vendor path (v200) whether or not it is requested, so stock's vendor
    # copy was a second rule for that path (parse r, 2026-09-29).
    "etc/permissions/android.hardware.hardware_keystore.xml",
}
# built from source (device.mk PRODUCT_PACKAGES). Substring match on the
# basename. The health 2.1 impl INSTALLS under its stem,
# android.hardware.health@2.0-impl-2.1.so, which the module name's substring
# does not match -- so stock's impl (both ABIs) slipped through and collided
# with hardware/interfaces' install rule (parse r, 2026-09-29). Stock's impl
# is plain AOSP: AOSP-only DT_NEEDED, 0 mtk strings (control: 92 "health").
FROM_SOURCE = (
    "android.hardware.health@2.1", "android.hardware.health@2.0-impl-2.1",
    "vndservicemanager", "vndservice",
)
# Platform base_vendor.mk components that stock also ships as its own copies.
# Soong writes an install rule for every module whether requested or not, so
# each blob here was a second rule for the same path -- "overriding commands
# for target" (parse r, 2026-09-29; all five found in one scan of
# installs-lineage_6781.mk + PRODUCT_COPY_FILES instead of five parses).
# Every one measured AOSP, none MediaTek:
#   bin/boringssl_self_test32/64  boringssl_self_test_vendor (base_vendor.mk)
#     + etc/init/boringssl_self_test.rc   (stock's is byte-identical to
#                                 external/boringssl/selftest's)
#   bin/hw/...omx@1.0-service     32-bit AOSP build: AOSP-only DT_NEEDED, 0 mtk
#     + its etc/init rc           strings (control: 12 "omx"). The platform
#                                 module ships its OWN rc (mediacodec
#                                 Android.bp init_rc) -- installed by a MAKE
#                                 rule (base_rules.mk:611), which is why the
#                                 soong-installs scan missed it; found by the
#                                 BUILD_BROKEN_DUP_RULES diagnostic parse t.
#                                 Binary and rc go together, platform's pair
#                                 (the RS4's arrangement). Lost from stock's
#                                 rc: service name `mediacodec`, extra groups
#                                 (media_rw sdcard_rw media system inet net_bt
#                                 net_bt_admin net_bw_acct sdcard_r) -- tester
#                                 gate on the OMX path; C2 is primary.
#   etc/passwd, etc/group         0 bytes in stock; passwd_vendor/group_vendor
#                                 generate them from fs_config.
#   etc/mkshrc                    byte-identical to external/mksh mkshrc_vendor.
# RS4 ships none of these either.
#
# Also here: etc/init/...composer@2.2-service.rc -- a 0-BYTE file in stock
# (so are 2.1 and 2.4; stock's live composer is 2.3, matching its VINTF
# fragment). MediaTek ships empty rcs to shadow AOSP defaults; the 2.2 one
# collides with hardware/interfaces' make module rule. Nothing requests that
# module, so dropping the empty file leaves the path empty either way.
DROP_BASE_VENDOR = {
    "bin/boringssl_self_test32", "bin/boringssl_self_test64",
    "etc/init/boringssl_self_test.rc",
    "bin/hw/android.hardware.media.omx@1.0-service",
    "etc/init/android.hardware.media.omx@1.0-service.rc",
    "etc/passwd", "etc/group", "etc/mkshrc",
    "etc/init/android.hardware.graphics.composer@2.2-service.rc",
}
# Interface libraries the tree requests as .vendor variants (device.mk).
# The platform module is then reachable, so a same-named blob is a duplicate
# install rule (base_rules.mk:338 -- third build failure class, 2026-09-20:
# cameraservice.common@2.0). The .vendor build satisfies the consumers;
# impls (hw/ passthrough, MTK-specific names) never match a stem and stay
# blobs. Derived from device.mk itself so the two cannot drift: if a .vendor
# request is removed, its blob silently returns (and collides again -- the
# build failure is the reminder).
def _vendor_stems():
    import re as _re
    try:
        mk = open(os.path.join(TREE, "device.mk")).read()
    except OSError:
        return set()
    return set(_re.findall(r"^\s+([\w@.+-]+)\.vendor\s*(?:\\)?$", mk, _re.M))
VENDOR_STEMS = _vendor_stems()
# generated by the build, or owned by another package
GENERATED_EXACT = {
    "build.prop", "default.prop", "etc/build.prop",
    "etc/fs_config_dirs", "etc/fs_config_files", "etc/NOTICE.xml.gz",
    "odm/etc/build.prop",
}
GENERATED_PREFIX = ("etc/selinux/", "lib/modules", "lost+found",
                    "odm/etc/vintf/", "etc/vintf/manifest/")
# Dropped blobs: the platform builds these at the same install path, so
# shipping the blob is a duplicate install rule (base_rules.mk). Measured
# on Advan stock 2026-09-19/20 -- zero in-partition consumers for each:
#   libvibrator (AOSP vibrator client; only self-SONAME refs)
#   libhapticgenerator (0 consumers in lib64{,/hw})
#   libaudiofoundation (consumers are the 5 audio files, ALL pruned by
#       blob_fixup's libaudiofoundation->liblog rename; device.mk requests
#       libaudiofoundation.vendor instead)
#   lib/libmtk_bsg.so (32-bit; the tree ships the 64-bit impl only)
#   lib/hw/boot impl (32-bit ditto)
DROP_BLOBS = {
    "lib/libvibrator.so", "lib64/libvibrator.so",
    "lib/soundfx/libhapticgenerator.so", "lib64/soundfx/libhapticgenerator.so",
    "lib/libaudiofoundation.so", "lib64/libaudiofoundation.so",
    "lib/libmtk_bsg.so",
    "lib/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so",
}
# Shell toolbox binaries. Stock ships real binaries; the platform defines
# modules of the same names (base_rules.mk:338 -- sixth build: awk already
# defined by external/one-true-awk; seventh: dmabuf_dump by
# system/memory/libmeminfo). /system provides them on our ROM; no stock init
# rc references any (measured), so dropping is behavior-preserving. Same
# exclusion class as the 180 toybox/toolbox symlinks. Preemptively audited
# 2026-09-20 by matching all 94 vendor/bin regular files against platform
# Android.bp module names (9 hits; vndservice/vndservicemanager are already
# covered by FROM_SOURCE).
DROP_SHELL = {
    "bin/awk", "bin/sh", "bin/toolbox",
    "bin/dmabuf_dump", "bin/dumpsys", "bin/logwrapper", "bin/toybox_vendor",
}
# 32-bit-only legacy CAS stack (daemon + rc + 4 interface libs). The platform
# defines these module names (base_rules.mk:338, fourth build:
# cas.native@1.0_32 already defined by hardware/interfaces), and renaming a
# 5-file self-contained 32-bit stack is surgery without a symptom: nothing
# outside it consumes it (measured consumer audit), RS4 ships none of it,
# and DRM (clearkey/widevine plugins, both ABIs -- KEPT) does not go through
# it. Widevine L1 is MTK-native on this SoC. Tester gate (DRM Info + video)
# adjudicates; the fragment moves to manifest-UNUSED/ alongside.
DROP_CAS32 = {
    "bin/hw/android.hardware.cas@1.2-service-lazy",
    "etc/init/android.hardware.cas@1.2-service-lazy.rc",
    "lib/android.hardware.cas.native@1.0.so",
    "lib/android.hardware.cas@1.0.so",
    "lib/android.hardware.cas@1.1.so",
    "lib/android.hardware.cas@1.2.so",
}
# AOSP libraries the platform also defines (32-bit stagefright-soft stack,
# opus/vpx/vorbis, libz_stable). Bulk-derived 2026-09-20: blob basenames that
# (a) collide with a platform Android.bp module name, AND (b) are absent from
# RS4's blob list (which builds fine without them = proof nobody needs the
# vendor copy). Impls, plugins, services and soundfx are EXCLUDED from this
# rule -- those get individual treatment (consumer analysis), because a
# same-named platform module is not always the same component.
# List frozen in-code (not computed) so regeneration is deterministic and the
# audit trail names every file.
DROP_AOSP = {
    "libopus.so", "libstagefright_amrnb_common.so",
    "libstagefright_enc_common.so", "libstagefright_flacdec.so",
    "libstagefright_soft_aacdec.so", "libstagefright_soft_aacenc.so",
    "libstagefright_soft_amrdec.so", "libstagefright_soft_amrnbenc.so",
    "libstagefright_soft_amrwbenc.so", "libstagefright_soft_avcdec.so",
    "libstagefright_soft_avcenc.so", "libstagefright_soft_flacdec.so",
    "libstagefright_soft_flacenc.so", "libstagefright_soft_g711dec.so",
    "libstagefright_soft_gsmdec.so", "libstagefright_soft_hevcdec.so",
    "libstagefright_soft_mp3dec.so", "libstagefright_soft_mpeg2dec.so",
    "libstagefright_soft_mpeg4dec.so", "libstagefright_soft_mpeg4enc.so",
    "libstagefright_soft_opusdec.so", "libstagefright_soft_rawdec.so",
    "libstagefright_soft_vorbisdec.so", "libstagefright_soft_vpxdec.so",
    "libstagefright_soft_vpxenc.so", "libstagefright_softomx.so",
    "libstagefright_softomx_plugin.so", "libvorbisidec.so", "libvpx.so",
    "libz_stable.so",
}
# AOSP RIL libs (libril, librilutils, libreference-ril, both ABIs). The
# platform defines libril unconditionally (base_rules.mk:338, thirteenth
# build) for the stub-rild path this tree deliberately crash-loops (see
# system.prop vendor.rild.libpath). The REAL modem (mtkfusionrild) links
# librilfusion + MTK libs only -- measured -- so nothing here needs the
# AOSP set. Kept: libmtk-ril, librilfusion, libmtkrillog, libmtkrilutils
# (MTK-specific, no platform collision). RS4-identical (keeps librilfusion
# only).
DROP_RIL = {
    "libril.so", "librilutils.so", "libreference-ril.so",
}
# Sourced-or-platform libs with zero vendor-side need for the blob:
#   libbinderdebug (0 consumers anywhere; base_rules.mk:338, eighth build)
#   libbluetooth_audio_session (consumers are the -impl providers, which stay
#       blobs; the lib itself builds from source -- audio.bluetooth.default
#       needs its headers, and a cc_prebuilt exports none. RS4-identical.)
#   gralloc.default.so (both ABIs, hw/ root -- NOT the mt6789/gralloc.common.so
#       the mapper actually uses, which stays. Platform defines it
#       unconditionally, eleventh build; nothing on Treble loads the legacy
#       path; RS4 ships none either.)
DROP_SOURCED = {
    "libbinderdebug.so",
    "libbluetooth_audio_session.so",
    "gralloc.default.so",
}
# Soong-built vendor modules (device.mk requests them; the blob would be a
# duplicate definition -- base_rules.mk:338, second build:
# libmtkperf_client_vendor already defined by hardware/mediatek). Basenames.
DROP_SONGBUILT = {
    "libmtkperf_client_vendor.so",
    "libprotobuf-cpp-full-3.9.1.so", "libprotobuf-cpp-lite-3.9.1.so",
    "libhwc2on1adapter.so", "libhwc2onfbadapter.so",
}
# The libaudiofoundation cascade (measured CLOSED 2026-09-20: nothing outside
# it consumes anything inside it, and blob_fixup prunes its single entry
# point). First hit: audioclient-types-aidl-cpp, base_rules.mk:338, first
# build. Basenames (both ABIs).
DROP_CASCADE = {
    "libaudioclient_aidl_conversion.so", "audioclient-types-aidl-cpp.so",
    "audio_common-aidl-cpp.so", "framework-permission-aidl-cpp.so",
    "shared-file-region-aidl-cpp.so", "libshmemcompat.so", "libshmemutil.so",
}
# Renamed blobs (src:dst): same install path as a platform module the tree
# cannot displace, so the blob ships under a distinct filename and the
# consumer is repointed in blob_fixup. All renames are build-necessary on
# lineage-20.0 (proven by RS4 builds 42/49/64 in the same branch), not
# guesses:
#   libeffectsconfig -> -stock (consumers: libeffects.so both ABIs;
#       platform defines libeffectsconfig in frameworks/av)
#   lib64/libmtk_bsg -> -stock (consumers: boot@1.0-impl-1.2-mtkimpl 64-bit;
#       hardware/mediatek defines libmtk_bsg in its own namespace)
#   lib64 boot impl -> -stock (hardware/mediatek/bootctrl emits the same
#       install path in its own namespace. Safe for a passthrough impl:
#       openLibs() matches on the `<package>@<ver>-impl` PREFIX.)
RENAME_BLOBS = {
    "lib/libeffectsconfig.so": "lib/libeffectsconfig-stock.so",
    "lib64/libeffectsconfig.so": "lib64/libeffectsconfig-stock.so",
    "lib64/libmtk_bsg.so": "lib64/libmtk_bsg-stock.so",
    "lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl.so":
        "lib64/hw/android.hardware.boot@1.0-impl-1.2-mtkimpl-stock.so",
}
# Stock Wi-Fi HAL pair (64-bit only in stock -- no 32-bit libwifi-hal exists).
# Both names collide unconditionally (frameworks/opt/net/wifi defines
# libwifi-hal; hardware/interfaces/wifi/1.6 defines the lazy service), so
# both move to -stock and blob_fixup repoints the binary's DT_NEEDED and the
# rc's exec path (service NAME and interface lines stay stock's -- those are
# what hwservicemanager lazy-matches). Tenth build failure class, 2026-09-20.
RENAME_BLOBS.update({
    "bin/hw/android.hardware.wifi@1.0-service-lazy":
        "bin/hw/android.hardware.wifi@1.0-service-stock",
    "lib64/libwifi-hal.so": "lib64/libwifi-hal-stock.so",
    "etc/init/android.hardware.wifi@1.0-service-lazy.rc":
        "etc/init/android.hardware.wifi@1.0-service-stock.rc",
    # Vibrator service binary: hardware/mediatek/aidl/vibrator defines this
    # kati module name unconditionally (twelfth build). The rc moves with it
    # (blob_fixup); service NAME + interfaces stay stock's for hwservicemanager.
    "bin/hw/android.hardware.vibrator-service.mediatek":
        "bin/hw/android.hardware.vibrator-service.mediatek-stock",
    # Power AIDL impl library: same kati collision
    # (hardware/mediatek/aidl/power-mediatek). The mtkpower service binary
    # hosts the AIDL interface and links this impl, so both move together
    # (blob_fixup repoints the DT_NEEDED). RS4-identical shape.
    "lib64/android.hardware.power-service-mediatek.so":
        "lib64/android.hardware.power-service-mediatek-stock.so",
})
# The A12 codec2 set, 64-bit (see extract-files.sh blob_fixup for the full
# reasoning -- v31 namespace, platform A13 copies crash-loop the MTK C2 HAL).
# Forced early by base_rules.mk:338 (ninth build: libcodec2_hidl@1.0 already
# defined by frameworks/av). The platform defines all 11 unconditionally, so
# renaming one at a time would cost 11 builds; the whole generation moves as
# one. 32-bit halves are dropped (64-bit-only C2, same ABI decision as the
# boot impl -- generated_kernel_includes breaks armv7a compiles the same way).
C2_STOCK_LIBS = (
    "android.hardware.media.c2@1.0", "android.hardware.media.c2@1.1",
    "android.hardware.media.c2@1.2", "libcodec2_hidl@1.0",
    "libcodec2_hidl@1.1", "libcodec2_hidl@1.2", "libcodec2_hidl_plugin",
    "libcodec2_vndk", "libcodec2_soft_common", "libsfplugin_ccodec_utils",
    "libstagefright_bufferpool@2.0.1",
)
for _lib in C2_STOCK_LIBS:
    RENAME_BLOBS["lib64/%s.so" % _lib] = "lib64/%s-stock.so" % _lib
DROP_C2_32 = {"lib/%s.so" % _lib for _lib in C2_STOCK_LIBS}


def skip(rel):
    if rel in excl or rel in GENERATED_EXACT:
        return "owned"
    if rel.startswith(GENERATED_PREFIX) or rel.endswith(".ko"):
        return "generated"
    base = os.path.basename(rel)
    if any(s in base for s in FROM_SOURCE):
        return "from-source"
    return None


# --- walk the partition -------------------------------------------------------
files = []
stats = {"owned": 0, "from-source": 0, "generated": 0, "toybox": 0,
         "dropped": 0, "dropped-cascade": 0, "dropped-songbuilt": 0, "dropped-sourced": 0, "dropped-ril": 0, "dropped-aosp": 0, "dropped-cas32": 0, "dropped-basevendor": 0, "dropped-c2-32": 0, "dropped-shell": 0, "dropped-vendorset": 0, "renamed": 0,
         "dangling": 0, "links-skipped": 0}
for root, dirs, fnames in os.walk(V):
    dirs[:] = [d for d in dirs if d != "lost+found"]
    for f in fnames:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, V)
        if os.path.islink(full):
            # symlinks.mk owns every link; toolbox/toybox applets and
            # extraction artifacts are not stock structure either way.
            stats["links-skipped"] += 1
            if not os.path.exists(full):
                stats["dangling"] += 1
            continue
        if os.path.isfile(full):
            files.append(rel)

lines, n_pkg, n_copy = [], 0, 0
for rel in sorted(files):
    why = skip(rel)
    if why:
        stats[why] += 1
        continue
    if rel in DROP_BLOBS:
        stats["dropped"] += 1
        continue
    if os.path.basename(rel) in DROP_CASCADE:
        stats["dropped-cascade"] += 1
        continue
    if os.path.basename(rel) in DROP_SONGBUILT:
        stats["dropped-songbuilt"] += 1
        continue
    if os.path.basename(rel) in DROP_SOURCED:
        stats["dropped-sourced"] += 1
        continue
    if os.path.basename(rel) in DROP_RIL:
        stats["dropped-ril"] += 1
        continue
    if os.path.basename(rel) in DROP_AOSP:
        stats["dropped-aosp"] += 1
        continue
    if rel in DROP_CAS32:
        stats["dropped-cas32"] += 1
        continue
    if rel in DROP_BASE_VENDOR:
        stats["dropped-basevendor"] += 1
        continue
    if rel in DROP_C2_32:
        stats["dropped-c2-32"] += 1
        continue
    # Renames bypass everything below: a -stock blob is a DIFFERENT module
    # name by construction, so neither the vendorset rule nor anything else
    # applies to it. (Order bug caught 2026-09-20: c2@1.x vanished here
    # because device.mk requests their .vendor variants -- which is exactly
    # why they must be renamed rather than dropped.)
    if rel in RENAME_BLOBS:
        dst = RENAME_BLOBS[rel]
        lines.append("-vendor/" + rel + ":vendor/" + dst)
        stats["renamed"] += 1
        n_pkg += 1
        continue
    if rel in DROP_SHELL:
        stats["dropped-shell"] += 1
        continue
    _mod = os.path.basename(rel)
    _mod = _mod[:-3] if _mod.endswith(".so") else _mod
    if _mod in VENDOR_STEMS:
        stats["dropped-vendorset"] += 1
        continue
    # ELF -> prebuilt module (dash); everything else -> plain copy.
    # (Renames are all handled above; nothing reaching here is renamed.)
    elf = rel.endswith(".so") or rel.startswith(("bin/", "lib/hw/", "lib64/hw/"))
    entry = ("-" if elf else "") + "vendor/" + rel
    if elf:
        n_pkg += 1
    else:
        n_copy += 1
    lines.append(entry)

# group by top-level directory for readability
groups = {}
for l in lines:
    p = l.lstrip("-").split(";")[0].split(":")[0][len("vendor/"):]
    groups.setdefault(p.split("/")[0] if "/" in p else ".", []).append(l)

with open(OUT, "w") as fh:
    fh.write("# Proprietary blobs for Advan X1 (6781), MT6789 family.\n")
    fh.write("# Generated by tools/gen_proprietary_files.py from the stock\n")
    fh.write("# ADVAN_6781_S34NF2_V4.0_20250304 vendor partition. Stock content\n")
    fh.write("# only -- see BLUEPRINT section 2.\n#\n")
    fh.write("# '-' prefix = Android.bp prebuilt module; no prefix = PRODUCT_COPY_FILES.\n")
    fh.write("# Symlinks are NOT listed here (symlinks.mk owns all 427+2).\n")
    fh.write("# 'src:dst' = renamed install (-stock collision avoidance).\n#\n")
    fh.write("## ADVAN/6781 package version: ADVAN_X1-14-1741067669\n")
    for g in sorted(groups):
        fh.write("\n# %s\n" % g)
        fh.write("\n".join(groups[g]) + "\n")

print(f"wrote {OUT}")
print(f"  entries            {len(lines)}")
print(f"    PRODUCT_PACKAGES {n_pkg}   (ELF, dash-prefixed)")
print(f"    COPY_FILES       {n_copy}")
print("  excluded:")
for k, v in stats.items():
    print(f"    {k:12s} {v}")
