#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := $(call my-dir)

ifeq ($(TARGET_DEVICE),6781)
include $(call all-makefiles-under,$(LOCAL_PATH))

# /vendor/lib*/foo.so -> mt6789/foo.so (409 of stock's links, plus 11
# same-dir aliases and 5 bin/ platform links; see symlinks.mk)
include $(LOCAL_PATH)/symlinks.mk

# ---------------------------------------------------------------------------
# KMI gate
#
# Only meaningful when the kernel is built from source. Every prebuilt
# vendor module on this device is version-checked at load time, and the set
# includes storage, display and the GPU -- so a kernel whose symbol CRCs
# disagree does not boot. Critically it also does not fail to BUILD, so
# without this the first symptom is a bootloop on a tester's device --
# the most expensive failure shape on a project with no live device.
#
# The CRCs come from the kernel CONFIG, not the source (see kmi-check.py).
# ---------------------------------------------------------------------------
ifneq ($(TARGET_KERNEL_SOURCE),)
ifneq ($(wildcard $(KMI_VENDOR_MODULES_DIR)),)

6781_KMI_STAMP := $(PRODUCT_OUT)/kmi_verified.stamp

# Capture the script path NOW, with ':='. LOCAL_PATH is recursively
# expanded and every later makefile reassigns it, so a bare $(LOCAL_PATH)
# inside the recipe below expands at RULE-EXECUTION time to whatever was
# included last and the gate dies with
#   python3: can't open file '.../build/make/core/kmi-check.py'
6781_KMI_SCRIPT := $(LOCAL_PATH)/kmi-check.py

# Which symvers to verify against. KMI_SYMVERS is set by BoardConfig.mk
# only when a custom kernel has been imported; otherwise the file comes
# from the in-tree source build. $(KERNEL_OUT) is not defined this early,
# so the fallback stays recursively expanded ('=').
ifneq ($(KMI_SYMVERS),)
6781_KMI_SYMVERS := $(KMI_SYMVERS)
6781_KMI_KERNEL_DEP := $(TARGET_PREBUILT_KERNEL)
else
6781_KMI_SYMVERS = $(KERNEL_OUT)/Module.symvers
6781_KMI_KERNEL_DEP = $(TARGET_PREBUILT_INT_KERNEL)
endif

# BOTH module sets are checked. vendor_dlkm is 180 modules and vendor_boot
# is 178, and a kernel that satisfies one is not automatically right for
# the other -- they are separate .ko sets that happen to share a KMI.
$(6781_KMI_STAMP): $(6781_KMI_KERNEL_DEP) $(6781_KMI_SCRIPT)
	@echo "----- Verifying KMI against stock vendor modules -----"
	$(hide) python3 $(6781_KMI_SCRIPT) \
	    $(6781_KMI_SYMVERS) \
	    $(KMI_VENDOR_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT)
	$(hide) $(if $(wildcard $(KMI_RAMDISK_MODULES_DIR)),python3 $(6781_KMI_SCRIPT) \
	    $(6781_KMI_SYMVERS) \
	    $(KMI_RAMDISK_MODULES_DIR) \
	    $(BOARD_KMI_MODULE_LAYOUT))
	$(hide) mkdir -p $(dir $@) && touch $@

# Hook: vendor_dlkm.img is NOT it (bacon never builds image targets; it
# goes bacon -> OTA -> target-files -> staged files). What bacon DOES reach
# is every staged file, so the gate hangs off our staged vendor files as an
# ORDER-ONLY prerequisite (runs BEFORE they install; its timestamp must not
# make them perpetually dirty). Proven with `ninja -t query` before
# believing -- the RS4 tree hooked two wrong targets first, both of which
# "worked" in the sense that the build succeeded and the gate never ran.
#
# The $(error) is the point of the whole block: a detached gate looks
# exactly like a passing one. If this filter ever comes up empty the build
# stops instead of quietly shipping unverified.
6781_KMI_HOOK := $(filter $(TARGET_OUT_VENDOR)/%,$(ALL_DEFAULT_INSTALLED_MODULES))
ifeq ($(6781_KMI_HOOK),)
$(error 6781: KMI gate has nothing to attach to. It would not run, and the \
        build would ship a kernel that was never checked against the vendor \
        modules. Fix the hook rather than removing this check.)
endif
$(6781_KMI_HOOK): | $(6781_KMI_STAMP)

# Kept for `m`/`make` and for image-only builds, which do reach these.
droidcore: $(6781_KMI_STAMP)
$(PRODUCT_OUT)/vendor_dlkm.img: $(6781_KMI_STAMP)

else
$(warning 6781: KMI_VENDOR_MODULES_DIR unset or missing - KMI gate DISABLED.)
$(warning         A config drift will produce a kernel that builds and does not boot.)
endif
endif

# ---------------------------------------------------------------------------
# Vendor dependency gate -- the userspace counterpart of the KMI gate above
#
# The KMI gate catches a kernel that builds and cannot boot. This catches a
# VENDOR PARTITION that builds and cannot link. It verifies the OUTPUT (the
# complete staged /vendor tree), so unlike the KMI gate it must run AFTER
# staging -- hooking it to the KMI hook would read a half-populated
# directory. What bacon reaches is the target-files zip, and everything
# staged is a prerequisite of it, so depending on that zip buys "after
# staging". The release path (target-files-package) is hooked too: the RS4
# tree shipped two releases with this gate never running because only the
# eng path was named.
#
# Both ways this can break are LOUD: a wrong zip path fails with "No rule
# to make target", and `bacon` always exists so the hook cannot quietly
# attach to nothing.
# ---------------------------------------------------------------------------
6781_VDEPS_SCRIPT := $(LOCAL_PATH)/tools/vendor-deps-check.sh

ifeq ($(wildcard $(6781_VDEPS_SCRIPT)),)
$(error 6781: tools/vendor-deps-check.sh is missing. Restore it rather than \
        dropping this gate: without it a vendor partition whose HALs cannot \
        link builds, signs and flashes without complaint.)
endif
ifeq ($(FILE_NAME_TAG),)
$(error 6781: FILE_NAME_TAG is empty, so the target-files path below cannot \
        be constructed and the vendor dependency gate would not run.)
endif

6781_VDEPS_NAME := $(TARGET_PRODUCT)
ifeq ($(TARGET_BUILD_TYPE),debug)
6781_VDEPS_NAME := $(6781_VDEPS_NAME)_debug
endif
6781_VDEPS_NAME := $(6781_VDEPS_NAME)-target_files-$(FILE_NAME_TAG)

6781_VDEPS_TF    := $(PRODUCT_OUT)/obj/PACKAGING/target_files_intermediates/$(6781_VDEPS_NAME).zip
6781_VDEPS_STAMP := $(PRODUCT_OUT)/vendor_deps_verified.stamp

# 6781_VDEPS_SCRIPT is assigned with ':=' for the same reason as the KMI
# script path above: a bare $(LOCAL_PATH) inside a recipe resolves at
# RULE-EXECUTION time to whatever makefile was included last.
$(6781_VDEPS_STAMP): $(6781_VDEPS_TF) $(6781_VDEPS_SCRIPT)
	@echo "----- Verifying vendor DT_NEEDED resolution, per ABI -----"
	$(hide) $(6781_VDEPS_SCRIPT) $(TARGET_OUT_VENDOR) $(TARGET_OUT)
	$(hide) mkdir -p $(dir $@) && touch $@

bacon: $(6781_VDEPS_STAMP)

# ...and the RELEASE path, which is a DIFFERENT target (what the release
# script builds). Naming every packaging path is only correct while the
# list stays complete; a phony that does not exist would fail the build
# with "No rule to make target", not pass quietly.
target-files-package: $(6781_VDEPS_STAMP)

# droidcore is deliberately NOT hooked here, unlike the KMI gate. droidcore
# builds images without building target-files, so hooking it would drag the
# whole target-files zip into image-only builds to satisfy this stamp.

endif
