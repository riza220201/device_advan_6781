#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

# Dalvik heap. NOT optional, and its absence is not a tuning question --
# without any heap makefile the device inherits AOSP's 16 MiB fallback and
# system_server OOMs before completing boot (RS4 lesson, build 51: identical
# failure shape, `target footprint 16777216`).
#
# Stock ADVAN_6781_S34NF2_V4.0_20250304 vendor/build.prop declares five of
# the six values (measured 2026-09-19 from the unpack; heapstartsize absent):
#   heapgrowthlimit=256m  heapsize=512m  heaptargetutilization=0.75
#   heapminfree=512k      heapmaxfree=8m
# phone-xhdpi-6144-dalvik-heap.mk matches the two capacity values
# (growthlimit 256m, heapsize 512m); the other three (0.75 vs 0.5,
# 512k vs 8m, 8m vs 32m) differ and heapstartsize falls back to the
# preset's 16m. [C] -- tester gate compares `getprop | grep dalvik.vm.heap`
# against the stock five before release; capacity match is what prevents
# the OOM, the rest is tuning.
$(call inherit-product, frameworks/native/build/phone-xhdpi-6144-dalvik-heap.mk)

# Inherit from those products. Most specific first.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)

# Inherit from 6781 device
$(call inherit-product, $(LOCAL_PATH)/device.mk)

# Inherit some common Lineage stuff
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_6781
PRODUCT_DEVICE := 6781
PRODUCT_MANUFACTURER := ADVAN
PRODUCT_BRAND := ADVAN
# Stock ro.product.system.model is 6781 (measured). The retail name
# "Advan X1" goes to ro.product.marketname in configs/properties/system.prop
# -- a value containing a space cannot go through PRODUCT_*_PROPERTIES
# (entries there are whitespace-separated).
PRODUCT_MODEL := 6781

# Identity presented to the platform. These are the values Advan ships;
# the stock fingerprint is ADVAN/ADVAN_X1/ADVAN_X1:14/UP1A.231005.007/...
# (measured 2026-09-19), where the second field is the PRODUCT name.
PRODUCT_SYSTEM_NAME := ADVAN_X1
PRODUCT_SYSTEM_DEVICE := ADVAN_X1

# No PRODUCT_GMS_CLIENTID_BASE: that value is Transsion-specific
# (android-transsion) and this is not a Transsion device. The ROM default
# applies.

# Build fingerprint / description are deliberately NOT set here. They are a
# ROM-level decision (they must match the signing posture), so they belong in
# the build recipe, not in a device tree other ROMs are expected to reuse.
