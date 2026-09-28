#!/bin/bash
#
# Copyright (C) 2026 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

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

setup_vendor "${DEVICE}" "${VENDOR}" "${ANDROID_ROOT}" false true

write_headers
write_makefiles "${MY_DIR}/proprietary-files.txt" true
# The r54p1 donor-only libraries: placed, never extracted from stock (see the
# file's header). Same module generation as the stock list.
write_makefiles "${MY_DIR}/proprietary-files-r54p1.txt" true
write_footers
