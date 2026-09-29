#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/advan/6781

# NOTE: this tree deliberately does NOT force ADB on. A forced-adb block
# (ro.secure=0 / persist.sys.usb.config=adb) enables USB debugging by
# default on user builds. Let the build variant decide.

# A/B
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=ext4 \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    otapreopt_script \
    update_engine \
    update_engine_sideload \
    update_verifier

# Dynamic partitions / Virtual A/B.
# These are PRODUCT_* variables so they must be set from a product makefile --
# board_config.mk makes PRODUCT_* readonly before BoardConfig.mk is included.
PRODUCT_USE_DYNAMIC_PARTITIONS := true
PRODUCT_VIRTUAL_AB_OTA := true

PRODUCT_PACKAGES += \
    fastbootd

# vndservicemanager. AOSP only installs this via
# PRODUCT_PACKAGES_SHIPPING_API_LEVEL_29 (base_vendor.mk), i.e. only for
# devices shipping at API <= 29 -- and this device sets shipping API 31.
# Advan stock ships bin/vndservicemanager + bin/vndservice, and the A12
# vendor blobs still open /dev/vndbinder, which needs a context manager.
# Stock's daemon links plain libbinder/libutils (measured, no _platform
# sonames at DT_NEEDED level); the v33-only-symbol question (RS4's
# ConnectionInfo vtable) is owed at Phase 2 via the v31-delta method.
# `vndservice` (the CLI) stays a source build regardless.
PRODUCT_PACKAGES += \
    vndservice

# Launch API level. Stock declares ro.product.first_api_level=31 [V],
# i.e. the device shipped originally on Android 12. This is what
# Treble/VSR requirements gate on, and it is NOT the same as the vendor's
# build SDK.                                                   [V]
PRODUCT_SHIPPING_API_LEVEL := 31

# VNDK 31. THIS IS LOAD-BEARING; it is not a version-bump preference.
#
# Stock's vendor partition, measured from the ADVAN_6781_S34NF2 dump:
#
#   ro.product.first_api_level      = 31    device launched on Android 12
#   ro.vendor.build.version.sdk     = 31    vendor was BUILT at Android 12
#   ro.vndk.version                 = 31
#
# (34 is the SYSTEM side -- ro.build.version.sdk. An A14 system on an A12
# vendor. Three numbers that are easy to conflate.)
#
# Around twenty vendor ELFs need A12-era AIDL `_platform` sonames
# (measured 2026-09-19 by sweeping stock's vendor for _platform.so
# DT_NEEDED): power-V2, light-V1, gnss-V1, the three Trustonic keymint
# ones, memtrack-V1, vibrator-V2, keystore2-V1, plus Advan-specific
# biometrics.common/face/common-V2/keymaster-V3 (face jdm-service),
# arm.graphics (deliberately NOT renamed -- soong builds
# arm.graphics-V1-ndk_platform WITH the suffix on lineage-20.0; renaming
# by analogy with the light HAL was the RS4 arm.graphics mistake), and
# libneuron_platform (self-reference). NONE of those libraries exists in
# stock's vendor or system partitions: they live inside
# com.android.vndk.v31.apex, which stock ships in /system_ext/apex/.
#
# The mechanism that works on lineage-20.0 (RS4-proven, branch facts, not
# device facts): the v31 snapshot CANNOT be shipped as an apex here (the
# vendor namespace only searches the apex named by ro.vndk.version, which
# the build always emits as 33; pinning BOARD_VNDK_VERSION changes what
# every vendor module COMPILES against and fails). Instead the snapshot
# ships as 136 cc_prebuilt_library_shared modules into
# /vendor/lib{,64}/vndk (NOT vndk-sp: that path has a soong-owned test rule
# and would mix generations inside system processes; vndk/ is searched by
# the vendor namespace first and never by system processes).
#
# ⚠ ASSERT IT, DO NOT TRUST IT. After any build that touches this, confirm
# BOTH on the tester-run gate:
#
#     getprop ro.vndk.version           -> 33 (the build emits 33; the pin
#                                            works through the vndk/ path,
#                                            not through this property)
#     camerahalserver maps libraries out of /vendor/lib64/vndk/
#
# The v31 libraries go into /vendor/lib*/vndk, which has no file_contexts
# rule, so they take vendor_file from the directory -- correct, because
# only vendor processes ever search that path.
#
# Provenance: AOSP's prebuilts/vndk/v31 snapshot (prebuilts/vndk31-snapshot/,
# staged in Phase 2 -- same snapshot the RS4 tree ships; it is
# device-independent).
#
# libfmq IS DELIBERATELY NOT IN THIS SET. It is the one snapshot library
# that breaks A13-built vendor components (it lacks
# android::hardware::details::check(bool, char const*), which every A13
# FMQ-template instantiation emits): with v31 pinned, AOSP's Bluetooth
# audio HAL cannot dlopen (see audio.bluetooth.default below). v33's libfmq
# is a superset of what the blobs reference, so dropping the module lets it
# fall through to the apex. These two changes only work together.
PRODUCT_PACKAGES += \
    android.hardware.audio.common@2.0-vndk31 \
    android.hardware.authsecret-V1-ndk_platform-vndk31 \
    android.hardware.automotive.occupant_awareness-V1-ndk_platform-vndk31 \
    android.hardware.common-V2-ndk_platform-vndk31 \
    android.hardware.common.fmq-V1-ndk_platform-vndk31 \
    android.hardware.configstore-utils-vndk31 \
    android.hardware.configstore@1.0-vndk31 \
    android.hardware.configstore@1.1-vndk31 \
    android.hardware.confirmationui-support-lib-vndk31 \
    android.hardware.gnss-V1-ndk_platform-vndk31 \
    android.hardware.graphics.allocator@2.0-vndk31 \
    android.hardware.graphics.allocator@3.0-vndk31 \
    android.hardware.graphics.allocator@4.0-vndk31 \
    android.hardware.graphics.bufferqueue@1.0-vndk31 \
    android.hardware.graphics.bufferqueue@2.0-vndk31 \
    android.hardware.graphics.common-V2-ndk_platform-vndk31 \
    android.hardware.graphics.common@1.0-vndk31 \
    android.hardware.graphics.common@1.1-vndk31 \
    android.hardware.graphics.common@1.2-vndk31 \
    android.hardware.graphics.mapper@2.0-vndk31 \
    android.hardware.graphics.mapper@2.1-vndk31 \
    android.hardware.graphics.mapper@3.0-vndk31 \
    android.hardware.graphics.mapper@4.0-vndk31 \
    android.hardware.health.storage-V1-ndk_platform-vndk31 \
    android.hardware.identity-V3-ndk_platform-vndk31 \
    android.hardware.keymaster-V3-ndk_platform-vndk31 \
    android.hardware.light-V1-ndk_platform-vndk31 \
    android.hardware.media.bufferpool@2.0-vndk31 \
    android.hardware.media.omx@1.0-vndk31 \
    android.hardware.media@1.0-vndk31 \
    android.hardware.memtrack-V1-ndk_platform-vndk31 \
    android.hardware.memtrack@1.0-vndk31 \
    android.hardware.oemlock-V1-ndk_platform-vndk31 \
    android.hardware.power-V2-ndk_platform-vndk31 \
    android.hardware.power.stats-V1-ndk_platform-vndk31 \
    android.hardware.rebootescrow-V1-ndk_platform-vndk31 \
    android.hardware.renderscript@1.0-vndk31 \
    android.hardware.security.keymint-V1-ndk_platform-vndk31 \
    android.hardware.security.secureclock-V1-ndk_platform-vndk31 \
    android.hardware.security.sharedsecret-V1-ndk_platform-vndk31 \
    android.hardware.soundtrigger@2.0-core-vndk31 \
    android.hardware.soundtrigger@2.0-vndk31 \
    android.hardware.vibrator-V2-ndk_platform-vndk31 \
    android.hardware.weaver-V1-ndk_platform-vndk31 \
    android.hidl.memory.token@1.0-vndk31 \
    android.hidl.memory@1.0-impl-vndk31 \
    android.hidl.memory@1.0-vndk31 \
    android.hidl.safe_union@1.0-vndk31 \
    android.hidl.token@1.0-utils-vndk31 \
    android.hidl.token@1.0-vndk31 \
    android.system.keystore2-V1-ndk_platform-vndk31 \
    android.system.suspend@1.0-vndk31 \
    libRSCpuRef-vndk31 \
    libRSDriver-vndk31 \
    libRS_internal-vndk31 \
    libaudioroute-vndk31 \
    libaudioutils-vndk31 \
    libbacktrace-vndk31 \
    libbase-vndk31 \
    libbcinfo-vndk31 \
    libbinder-vndk31 \
    libblas-vndk31 \
    libbufferqueueconverter-vndk31 \
    libc++-vndk31 \
    libcamera_metadata-vndk31 \
    libcap-vndk31 \
    libcn-cbor-vndk31 \
    libcodec2-vndk31 \
    libcompiler_rt-vndk31 \
    libcrypto-vndk31 \
    libcrypto_utils-vndk31 \
    libcurl-vndk31 \
    libcutils-vndk31 \
    libdiskconfig-vndk31 \
    libdmabufheap-vndk31 \
    libdumpstateutil-vndk31 \
    libevent-vndk31 \
    libexif-vndk31 \
    libexpat-vndk31 \
    libgatekeeper-vndk31 \
    libgralloctypes-vndk31 \
    libgui-vndk31 \
    libhardware-vndk31 \
    libhardware_legacy-vndk31 \
    libhidlallocatorutils-vndk31 \
    libhidlbase-vndk31 \
    libhidlmemory-vndk31 \
    libion-vndk31 \
    libjpeg-vndk31 \
    libjsoncpp-vndk31 \
    libldacBT_abr-vndk31 \
    libldacBT_enc-vndk31 \
    liblz4-vndk31 \
    liblzma-vndk31 \
    libmedia_helper-vndk31 \
    libmedia_omx-vndk31 \
    libmemtrack-vndk31 \
    libminijail-vndk31 \
    libmkbootimg_abi_check-vndk31 \
    libnetutils-vndk31 \
    libnl-vndk31 \
    libpcre2-vndk31 \
    libpiex-vndk31 \
    libpng-vndk31 \
    libpower-vndk31 \
    libprocessgroup-vndk31 \
    libprocinfo-vndk31 \
    libradio_metadata-vndk31 \
    libspeexresampler-vndk31 \
    libsqlite-vndk31 \
    libssl-vndk31 \
    libstagefright_bufferpool@2.0-vndk31 \
    libstagefright_bufferqueue_helper-vndk31 \
    libstagefright_foundation-vndk31 \
    libstagefright_omx-vndk31 \
    libstagefright_omx_utils-vndk31 \
    libstagefright_xmlparser-vndk31 \
    libsysutils-vndk31 \
    libtinyalsa-vndk31 \
    libtinyxml2-vndk31 \
    libui-vndk31 \
    libunwindstack-vndk31 \
    libusbhost-vndk31 \
    libutils-vndk31 \
    libutilscallstack-vndk31 \
    libwifi-system-iface-vndk31 \
    libxml2-vndk31 \
    libyuv-vndk31 \
    libz-vndk31 \
    libziparchive-vndk31 \
    libclang_rt.scudo-aarch64-android-vndk31 \
    libclang_rt.scudo_minimal-aarch64-android-vndk31 \
    libclang_rt.ubsan_standalone-aarch64-android-vndk31 \
    libclang_rt.scudo-arm-android-vndk31 \
    libclang_rt.scudo_minimal-arm-android-vndk31 \
    libclang_rt.ubsan_standalone-arm-android-vndk31

# --- A12 AIDL soname aliases, into /vendor/lib{,64} ------------------------
# The vndk31 snapshot above CANNOT supply these: vendor/lib*/vndk is not a
# search path of the vendor namespace (only /odm/${LIB}, /vendor/${LIB},
# /vendor/${LIB}/hw, /vendor/${LIB}/egl), and it is reached only over the
# v33 allowlist, which contains no `_platform` soname. hardware/lineage/compat
# solves it with empty forwarding libraries, so the A12 soname exists on the
# default search path and resolves transitively. Source-built, and each pulls
# in the -V1-ndk .vendor variants. Only entries with a measured Advan
# consumer are requested (measured 2026-09-19):
#
#   keymint/secureclock/sharedsecret  <- keymint-service.trustonic (3 _platform refs)
#   memtrack                          <- memtrack-service.mediatek
#   vibrator                          <- vibrator-service.mediatek (V2)
#   keystore2                         <- libkeystore-engine-wifi-hidl.so
PRODUCT_PACKAGES += \
    android.hardware.memtrack-V1-ndk_platform.vendor \
    android.hardware.security.keymint-V1-ndk_platform.vendor \
    android.hardware.security.secureclock-V1-ndk_platform.vendor \
    android.hardware.security.sharedsecret-V1-ndk_platform.vendor \
    android.hardware.vibrator-V2-ndk_platform.vendor \
    android.system.keystore2-V1-ndk_platform.vendor

# Vendor variants of platform-built libraries.
#
# NOT optional. Without these the vendor partition contains HALs that cannot
# link (RS4: 501 unresolved DT_NEEDED across 144 libraries, boot stalled
# waiting for IBootControl). Nothing requests the .vendor variant on its own
# -- every consumer here is a cc_prebuilt_* whose dependencies soong cannot
# see -- so /vendor goes without while the build still succeeds.
#
# Re-derive after ANY blob change with tools/vendor-deps-check.sh. It must
# report zero. NFC/ST and camera-specific entries are owed at Phase 2/3
# (Advan ships the ST NFC stack, not NXP: no nxpese/nxpnfc/ese here).
PRODUCT_PACKAGES += \
    android.frameworks.cameraservice.common@2.0.vendor \
    android.frameworks.cameraservice.device@2.0.vendor \
    android.frameworks.cameraservice.device@2.1.vendor \
    android.frameworks.cameraservice.service@2.0.vendor \
    android.frameworks.cameraservice.service@2.1.vendor \
    android.frameworks.cameraservice.service@2.2.vendor \
    android.frameworks.sensorservice@1.0.vendor \
    android.hardware.audio.common-util.vendor \
    android.hardware.audio.common@5.0.vendor \
    android.hardware.audio.common@6.0-util.vendor \
    android.hardware.audio.common@6.0.vendor \
    android.hardware.audio.common@7.0-enums.vendor \
    android.hardware.audio.common@7.0-util.vendor \
    android.hardware.audio.common@7.0.vendor \
    android.hardware.audio.effect@6.0.vendor \
    android.hardware.audio.effect@6.0-util.vendor \
    android.hardware.audio.effect@7.0-util.vendor \
    android.hardware.audio.effect@7.0.vendor \
    android.hardware.audio@6.0.vendor \
    android.hardware.audio@7.0-util.vendor \
    android.hardware.audio@7.0.vendor \
    android.hardware.biometrics.fingerprint@2.1.vendor \
    android.hardware.bluetooth.audio@2.0.vendor \
    android.hardware.bluetooth.audio@2.1.vendor \
    android.hardware.bluetooth@1.0.vendor \
    android.hardware.bluetooth@1.1.vendor \
    android.hardware.boot@1.0.vendor \
    android.hardware.boot@1.1.vendor \
    android.hardware.boot@1.2.vendor \
    android.hardware.camera.common@1.0.vendor \
    android.hardware.camera.device@1.0.vendor \
    android.hardware.camera.device@3.2.vendor \
    android.hardware.camera.device@3.3.vendor \
    android.hardware.camera.device@3.4.vendor \
    android.hardware.camera.device@3.5.vendor \
    android.hardware.camera.device@3.6.vendor \
    android.hardware.camera.provider@2.4.vendor \
    android.hardware.camera.provider@2.5.vendor \
    android.hardware.camera.provider@2.6.vendor \
    android.hardware.drm@1.0.vendor \
    android.hardware.drm@1.1.vendor \
    android.hardware.drm@1.2.vendor \
    android.hardware.drm@1.3.vendor \
    android.hardware.drm@1.4.vendor \
    android.hardware.gatekeeper@1.0.vendor \
    android.hardware.gnss-V1-ndk.vendor \
    android.hardware.health@1.0.vendor \
    android.hardware.health@2.0.vendor \
    android.hardware.health@2.1.vendor \
    android.hardware.gnss.measurement_corrections@1.0.vendor \
    android.hardware.gnss.measurement_corrections@1.1.vendor \
    android.hardware.gnss.visibility_control@1.0.vendor \
    android.hardware.gnss@1.0.vendor \
    android.hardware.gnss@1.1.vendor \
    android.hardware.gnss@2.0.vendor \
    android.hardware.gnss@2.1.vendor \
    android.hardware.graphics.composer@2.1-resources.vendor \
    android.hardware.graphics.composer@2.1.vendor \
    android.hardware.graphics.composer@2.2-resources.vendor \
    android.hardware.graphics.composer@2.2.vendor \
    android.hardware.graphics.composer@2.3.vendor \
    android.hardware.graphics.composer@2.4.vendor \
    android.hardware.light-V1-ndk.vendor \
    android.hardware.light@2.0.vendor \
    android.hardware.media.c2@1.0.vendor \
    android.hardware.media.c2@1.1.vendor \
    android.hardware.media.c2@1.2.vendor \
    android.hardware.nfc@1.0.vendor \
    android.hardware.nfc@1.1.vendor \
    android.hardware.nfc@1.2.vendor \
    android.hardware.power@1.0.vendor \
    android.hardware.power@1.1.vendor \
    android.hardware.power@1.2.vendor \
    android.hardware.power@1.3.vendor \
    android.hardware.radio.config@1.0.vendor \
    android.hardware.radio.config@1.1.vendor \
    android.hardware.radio.config@1.2.vendor \
    android.hardware.radio.config@1.3.vendor \
    android.hardware.radio@1.0.vendor \
    android.hardware.radio@1.1.vendor \
    android.hardware.radio@1.2.vendor \
    android.hardware.radio@1.3.vendor \
    android.hardware.radio@1.4.vendor \
    android.hardware.radio@1.5.vendor \
    android.hardware.radio@1.6.vendor \
    android.hardware.secure_element@1.0.vendor \
    android.hardware.secure_element@1.1.vendor \
    android.hardware.secure_element@1.2.vendor \
    android.hardware.security.keymint-V1-ndk.vendor \
    android.hardware.sensors@1.0.vendor \
    android.hardware.sensors@2.0-ScopedWakelock.vendor \
    android.hardware.sensors@2.0.vendor \
    android.hardware.sensors@2.1.vendor \
    android.hardware.soundtrigger@2.1.vendor \
    android.hardware.soundtrigger@2.2.vendor \
    android.hardware.soundtrigger@2.3.vendor \
    android.hardware.tetheroffload.config@1.0.vendor \
    android.hardware.tetheroffload.control@1.0.vendor \
    android.hardware.tetheroffload.control@1.1.vendor \
    android.hardware.thermal@1.0.vendor \
    android.hardware.thermal@2.0.vendor \
    android.hardware.usb.gadget@1.0.vendor \
    android.hardware.usb.gadget@1.1.vendor \
    android.hardware.usb@1.0.vendor \
    android.hardware.usb@1.1.vendor \
    android.hardware.usb@1.2.vendor \
    android.hardware.usb@1.3.vendor \
    android.hidl.allocator@1.0.vendor \
    libaudiofoundation.vendor \
    libavservices_minijail.vendor \
    libchrome.vendor \
    libcppbor_external.vendor \
    libdrm.vendor \
    libflatbuffers-cpp.vendor \
    libhidltransport.vendor \
    libhwbinder.vendor \
    libmediautils_vendor.vendor \
    libmemunreachable.vendor \
    libpcap.vendor \
    libruy.vendor \
    libtextclassifier_hash.vendor \
    libvibratorutils.vendor \
    vendor.lineage.touch@1.0.vendor \
    vendor.mediatek.hardware.mtkpower@1.0.vendor \
    vendor.mediatek.hardware.mtkpower@1.1.vendor \
    vendor.mediatek.hardware.mtkpower@1.2.vendor

# NOTE: codec2 .vendor modules (libcodec2_hidl@1.x, libcodec2_vndk,
# libcodec2_soft_common, libsfplugin_ccodec_utils) are deliberately ABSENT.
# Advan follows the RS4 option-B shape decision at Phase 2 (stock A12 C2
# set vs platform A13 set); which generation the C2 stack pins to is
# decided with the blob_fixup derivation, not here. A wrong guess here
# either collides (duplicate install rules) or splits the C2 process
# across VNDK generations. Owed, explicitly.

# Vendor-only libraries that soong already builds (mostly hardware/mediatek,
# which only compiles because BoardConfig sets BOARD_HAS_MTK_HARDWARE).
# These have no .vendor suffix because the module IS the vendor variant.
# PRODUCT_PACKAGES entries that do not exist fail the build loudly
# ("includes non-existent modules"), which is the check.
PRODUCT_PACKAGES += \
    libprotobuf-cpp-full.vendor \
    libprotobuf-cpp-lite.vendor \
    libhwc2on1adapter \
    libhwc2onfbadapter \
    libmtkperf_client_vendor

# Passthrough HAL implementations.
#
# These are dlopen'd by their service, never linked, so they appear in NO
# ELF's DT_NEEDED and tools/vendor-deps-check.sh is structurally blind to
# them. A name-keyed service diff is a lead generator, not a verdict
# (renamed services read as missing while running under another name).
PRODUCT_PACKAGES += \
    android.hardware.renderscript@1.0-impl

# ...and the boot-control implementation again, for recovery. Without it
# `adb sideload` fails having transferred nothing (Error getting bootctrl
# HIDL module). There is no hwservicemanager in recovery, so getService()
# falls to the passthrough manager; update_engine_sideload is a recovery
# binary, so HAL_LIBRARY_PATH_SYSTEM stays in its search path -- which is
# why the recovery copy belongs at system/lib64/hw.
PRODUCT_PACKAGES += \
    android.hardware.boot@1.2-mtkimpl.recovery

# Wi-Fi. Stock daemons (option B) + stock HAL (wmtWifi), same shape as the
# RS4 end state, all measured on Advan stock 2026-09-19:
#   bin/hw/wpa_supplicant + hostapd present; VINTF fragments
#   android.hardware.wifi{,.hostapd,.supplicant} present;
#   64-bit libwifi-hal.so carries wmtWifi (1 ref; 32-bit 0) -- only stock's
#   library powers the chip. HIDL fallback is all-or-nothing (framework
#   tries AIDL first): stock's HIDL declarations must ship with the daemons.
# The dependency closure (wifi@1.0-1.5, supplicant/hostapd HIDL, nl,
# wifi-system-iface, keystore) is requested explicitly because soong will
# not build .vendor variants for cc_prebuilt* consumers.
PRODUCT_PACKAGES += \
    libwifi-system-iface.vendor \
    libnl.vendor \
    android.hardware.wifi@1.0.vendor \
    android.hardware.wifi@1.1.vendor \
    android.hardware.wifi@1.2.vendor \
    android.hardware.wifi@1.3.vendor \
    android.hardware.wifi@1.4.vendor \
    android.hardware.wifi@1.5.vendor

PRODUCT_PACKAGES += \
    android.hardware.wifi.supplicant@1.0.vendor \
    android.hardware.wifi.supplicant@1.1.vendor \
    android.hardware.wifi.supplicant@1.2.vendor \
    android.hardware.wifi.supplicant@1.3.vendor \
    android.hardware.wifi.supplicant@1.4.vendor \
    android.hardware.wifi.hostapd@1.0.vendor \
    android.hardware.wifi.hostapd@1.1.vendor \
    android.hardware.wifi.hostapd@1.2.vendor \
    android.hardware.wifi.hostapd@1.3.vendor

PRODUCT_PACKAGES += \
    android.system.wifi.keystore@1.0.vendor

# --- Mali r54p1 shim (see mali/libr54shim.c; without it the driver will not
# load and SurfaceFlinger crash-loops) --------------------------------------
# The six stubbed symbols were re-measured on Advan stock 2026-09-19 (0
# ged_fr_swd exports in libged, no GpuAuxBlitAHardwareBuffer in libgpu_aux,
# no bad_function_call in the vendor libc++; donor libgpud carries 69
# C++-mangled UNDs needing the private A16 libc++): same shape, same shim.
PRODUCT_PACKAGES += \
    libr54shim

# The r54p1 UMD DT_NEEDs android.hardware.graphics.allocator-V2-ndk. It is
# not shipped as a blob: on this branch AIDL's unfrozen `current` is V2 and
# soong generates the module itself (4 definitions in
# out/soong/Android-lineage_6781.mk), so a prebuilt would be a duplicate.
# Nothing else pulls its vendor variant in -- build v's vendor.img inputs
# had it 0 times (control: libgpud 1) -- so request it. A SOFT dependency
# for the driver (it falls back to HIDL mapper@4.0 with no AIDL allocator
# registered), but the linker still needs the file. The other four
# donor-only libraries: proprietary-files-r54p1.txt.
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-V2-ndk.vendor

# --- MediaTek GPU KPI reporting (see prebuilts/gedkpi/Android.bp) -----------
# ged's DVFS policy loop only runs when ged is told a frame happened. The
# matching hook is a recipe-side libgui change (see
# tools/recipe-libvulkan-r54p1.sh step 41); these two blobs are what it
# dlopens. [C] provenance: Advan stock ships neither (measured across
# system+vendor) -- they come from itel A12 stock (same MTK generation as
# Advan's ged.ko). Tester gate (OPP walk) decides; without them the hook is
# a no-op and DVFS simply never runs.
PRODUCT_PACKAGES += \
    libged_kpi \
    libged_sys

# Bluetooth audio HAL -- AOSP's, NOT stock's. [C: Advan-measured shape,
# RS4-proven fix; tester gate plays audio through a headset.]
# Stock's lib64/hw/audio.bluetooth.default.so is MediaTek's build (DT_NEEDED:
# vendor.mediatek.hardware.bluetooth.audio@2.1/@2.2 +
# libbluetooth_audio_session_mediatek.so -- measured 2026-09-19), so it
# polls the MTK session registry while our AOSP Bluetooth stack writes the
# AOSP one: connected headset, audio stays on the speaker. AOSP's HAL links
# the registry our stack writes. The two -impl providers stay stock blobs
# (ABI-matched to the session libraries). libbluetooth_audio_session_aidl
# arrives as a shared_libs dependency automatically. Prerequisite: libfmq
# dropped from the v31 pin above (A13 check() symbol), or this HAL cannot
# dlopen -- the two changes only work together.
PRODUCT_PACKAGES += \
    audio.bluetooth.default

# Overlays (staged Phase 3)
DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

# Init. rootdir/ carries the boot plumbing this tree owns and edits
# (staged Phase 2 from stock, with our own edits re-applied, never
# imported); every other .rc on the vendor partition ships as a blob
# through the vendor tree instead, unmodified.
PRODUCT_PACKAGES += \
    init.insmod.sh

PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*.rc,$(LOCAL_PATH)/rootdir/etc/init/hw,$(TARGET_COPY_OUT_VENDOR)/etc/init/hw) \
    $(LOCAL_PATH)/rootdir/etc/init.insmod.mt6789.cfg:$(TARGET_COPY_OUT_VENDOR)/etc/init.insmod.mt6789.cfg

# ueventd reads /vendor/etc/ueventd.rc.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/ueventd.mt6789.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# fstab. Needed twice: first-stage mount reads it out of the vendor_boot
# ramdisk, later consumers read the copy on /vendor. (Stock-shape; the
# Advan fstab content is staged Phase 2.)
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6789:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.mt6789 \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6789:$(TARGET_COPY_OUT_VENDOR_RAMDISK)/first_stage_ramdisk/fstab.mt6789

# Recovery. This is what makes `adb sideload` enumerate.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/rootdir/etc/init.recovery.mt6789.rc:$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.mt6789.rc

# Recovery firmware (touch/haptic). Owed Phase 2: survey Advan's
# /vendor/firmware names from the zip-chained vendor (RS4 needed
# ft8057s/td4160/haptic + Conf_MultipleTest.ini; Advan panel/touch differ)
# and the kernel-module gate for recovery-bootmode. No filenames are
# invented here.

# VINTF. Stock's manifest declares thermal @1.0+@2.0 natively (measured),
# so taking the stock manifest whole via DEVICE_MANIFEST_FILE is the fix at
# zero authoring cost. Fragments must NEVER go through extract-utils (it
# force-creates colliding modules); they merge here and assemble_vintf
# validates the union at BUILD time. (Fragments staged Phase 2.)
DEVICE_MANIFEST_FILE := \
    $(LOCAL_PATH)/configs/vintf/manifest.xml \
    $(sort $(wildcard $(LOCAL_PATH)/configs/vintf/manifest/*.xml))
DEVICE_MATRIX_FILE := $(LOCAL_PATH)/configs/vintf/compatibility_matrix.xml

# DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE is required with
# PRODUCT_ENFORCE_VINTF_MANIFEST=true: check_vintf rejects every device
# manifest instance that no framework matrix mentions (all non-AOSP HALs).
DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE := \
    $(LOCAL_PATH)/configs/vintf/framework_compatibility_matrix.xml

# Health
PRODUCT_PACKAGES += \
    android.hardware.health@2.1-impl \
    android.hardware.health@2.1-service

# Memtrack. Stock's android.hardware.memtrack-service.mediatek (29,176 B --
# byte-identical size to the RS4 stock build), which wants the
# memtrack-V1-ndk_platform soname natively: no rename, and the source
# module's rule is simply left orphaned (different names, no collision).
# Its vintf fragment must move with it (declaration and implementation
# travel together).

# Power and vibrator. Stock's service binaries
# (vendor.mediatek.hardware.mtkpower@1.0-service 24,256 B,
# android.hardware.vibrator-service.mediatek 47,096 B -- both want their
# _platform sonames natively, measured). The AIDL power implementation
# library comes from the firmware (proprietary-files.txt, -stock dash form;
# needs the recipe-side module exclusion like the RS4 step-36 pattern --
# owed, loudly build-breaking if missed). The vibrator ships -stock: its
# kati module name is defined on every build whether requested or not, so
# the blob would collide; blob_fixup repoints the rc (Phase 2).
# Stock's power AIDL impl links power-V2-ndk_platform.so, renamed by
# blob_fixup to the Android 13 soname -- request it explicitly, since soong
# builds no .vendor variant for a cc_prebuilt's benefit.
PRODUCT_PACKAGES += \
    android.hardware.power-V2-ndk.vendor

# VNDK 31 interface libs for the A12 blobs that cannot run against platform
# VNDK 33 (same-process caveat as the RS4 tree: rename PER PROCESS, never
# per file). Sourced from AOSP's prebuilts/vndk/v31 snapshot. Which Advan
# consumers are renamed onto them is blob_fixup's job (Phase 2, measured
# per binary -- the Advan _platform map is in notes/JOURNAL.md).
PRODUCT_PACKAGES += \
    libutils-v31 \
    libhidlbase-v31 \
    libcutils-v31 \
    libbinder-v31

# AIDL NDK libraries that stock's blobs need under their Android 13 names.
# A rename only works if the target is actually installed to /vendor; the
# light/gnss/keymint .vendor variants are already pulled in above.
# (secureclock/sharedsecret are deliberately NOT separately requested: they
# were measured absent from /vendor on the RS4 -- the Trustonic binary
# resolves two of its three sonames from the v33 apex pre-pin, and post-pin
# all three come from the v31 set. Re-verify on the Advan built image
# before adding requests: a citation is a claim about the past.)

# Audio (staged Phase 2)
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/audio,$(TARGET_COPY_OUT_VENDOR)/etc)

# NFC is the ST variant on this board (android.hardware.nfc@1.2-service-st
# + nfc_nci.st21nfc.st.so; NO NXP ese stack anywhere -- measured). No NXP
# RF.conf-at-root, no ese renames. ST config derivation is Phase 3; nothing
# NXP-shaped is reproduced here.

# android.hardware.hardware_keystore -- stock's own declaration, version
# 100 (measured in vendor/etc/permissions). KeyMint V1 via Trustonic is
# what banking apps query. IT GOES ON PRODUCT, NOT VENDOR: the AIDL
# default keymint module claims /vendor/etc/permissions for that path and
# a duplicate is a kati parse-time FATAL. The platform's own copy declares
# 200 (KeyMint 2.0) -- a capability this device does not have.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/permissions/android.hardware.hardware_keystore.xml:$(TARGET_COPY_OUT_PRODUCT)/etc/permissions/android.hardware.hardware_keystore.xml

# Media
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/media,$(TARGET_COPY_OUT_VENDOR)/etc)

# Seccomp policies for the media stack
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/seccomp,$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy)

# Sensors. hals.conf names the sub-HALs the multi-HAL should load; an
# unresolvable name is not an error (multihal loads nothing). The entry is
# checked against vendor/lib64/hw in the Phase-2 extraction, not sooner.
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/sensors/hals.conf:$(TARGET_COPY_OUT_VENDOR)/etc/sensors/hals.conf

# Wi-Fi supplicant configuration
PRODUCT_COPY_FILES += \
    $(call find-copy-subdir-files,*,$(LOCAL_PATH)/configs/wifi,$(TARGET_COPY_OUT_VENDOR)/etc/wifi)

# Loose vendor configs (both measured present in stock vendor/etc)
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/public.libraries.txt:$(TARGET_COPY_OUT_VENDOR)/etc/public.libraries.txt \
    $(LOCAL_PATH)/configs/task_profiles.json:$(TARGET_COPY_OUT_VENDOR)/etc/task_profiles.json

# Screen density. Keep TARGET_SCREEN_DENSITY (BoardConfig),
# ro.sf.lcd_density (vendor.prop) and this block consistent. Panel class
# FHD+; density value itself is [C] (see BoardConfig).
PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xxhdpi

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    hardware/mediatek \
    vendor/advan/6781

# Inherit the proprietary blobs
$(call inherit-product, vendor/advan/6781/6781-vendor.mk)

# ---------------------------------------------------------------------------
# ro.rs4.build.stamp (from ADVAN_BUILD_STAMP) -- what PackageManager compares to
# decide "is this an update?"
#
# This ROM pins ro.build.version.incremental to the stock identity
# (1741067669) on purpose, so banking/integrity checks see an honest
# device. AOSP's upgrade test is exactly that string, so mIsUpgrade is
# permanently false and everything gated on it is dead. The fix patches
# what PackageManager COMPARES, never what the device REPORTS (RS4
# mechanism): a release flow exports ADVAN_BUILD_STAMP once per release so
# every artifact carries the same stamp; guarded so plain `m` builds emit
# nothing and behave exactly as stock. (No Advan release flow exists yet --
# the S666LN's is crdroid-build-rc.sh + sign-release.sh; while BUILD_NUMBER
# is not pinned the incremental changes per build and this is moot.)
#
# The PROPERTY NAME is not ours to choose: the shared crDroid tree's
# PackageManagerService (the S666LN recipe's frameworks patch, :1453) reads
# SystemProperties.get("ro.rs4.build.stamp", Build.VERSION.INCREMENTAL) --
# hard-coded. An earlier revision emitted ro.6781.build.stamp, which nothing
# reads, so the fix would have been silently dead the moment a release pinned
# BUILD_NUMBER (found 2026-09-29 reading the recipe). The "rs4" in the name is
# that patch's contract, not a claim about this device.
ifneq ($(ADVAN_BUILD_STAMP),)
PRODUCT_SYSTEM_PROPERTIES += ro.rs4.build.stamp=$(ADVAN_BUILD_STAMP)
endif
