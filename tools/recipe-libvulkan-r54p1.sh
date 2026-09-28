#!/bin/bash
# recipe-libvulkan-r54p1.sh <TREE_PATH> -- Advan X1 staging of the RS4
# libvulkan + libgui backports (r54p1 integration, recipe side).
#
# Extracted VERBATIM 2026-09-19 from ~/itel_rs4_Crdroid/apply-overlays-v2.sh
# steps 39, 40, 41, 45, 46, 47, 48 (same ROM base: crDroid 13.0 /
# lineage-20.0). Each step is idempotent (already-patched guards) and fails
# LOUDLY on anchor mismatch -- that is what makes this portable rather than
# hopeful: run it once against the Advan recipe tree and read which guards
# fire. "Already patched" on every step with no diff means the base already
# carries the work; a FATAL means the base moved and the step needs
# re-derivation, not a looser anchor.
#
# Step 41 additionally needs GedKpiHook.h beside this script (copied from
# the RS4 recipe -- same file, branch-identical target).
#
# This file stages the WORK, not the decision: it runs when the Advan ROM
# recipe repo exists. Nothing here belongs in the device tree (a
# frameworks/native patch committed to device/ would not survive sync).
set -euo pipefail
TREE="${1:?usage: recipe-libvulkan-r54p1.sh <path-to-crdroid-tree>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$TREE"

echo "== step 39: libvulkan VkNativeBufferANDROID extended fields (r54p1) =="
SWAPCPP="$TREE/frameworks/native/vulkan/libvulkan/swapchain.cpp"
if [ ! -f "$SWAPCPP" ]; then
  echo "   *** FATAL: vulkan/libvulkan/swapchain.cpp not found"; exit 1
elif grep -q 'native_buffer.ahb' "$SWAPCPP"; then
  echo "   already patched"
else
  python3 - "$SWAPCPP" <<'PYSWAP'
import sys
p = sys.argv[1]
s = open(p).read()

inc_old = "#include <system/window.h>\n"
inc_new = ("#include <system/window.h>\n"
           "#include <vndk/window.h>\n"
           "#include <android/hardware_buffer.h>\n")

nb_old = ("    VkNativeBufferANDROID image_native_buffer = {\n"
          "#pragma clang diagnostic push\n"
          "#pragma clang diagnostic ignored \"-Wold-style-cast\"\n"
          "        .sType = VK_STRUCTURE_TYPE_NATIVE_BUFFER_ANDROID,\n"
          "#pragma clang diagnostic pop\n"
          "        .pNext = &swapchain_image_create,\n"
          "    };\n")
nb_new = ("""    // Mali r54p1 -- and any UMD built against a newer VK_ANDROID_native_buffer
    // than the SPEC_VERSION 8 struct this tree defines -- reads TWO fields past
    // the end of VkNativeBufferANDROID and dereferences the second one.
    //
    // Measured by disassembling libGLES_mali r54p1-12eac0. These are the driver's
    // ONLY reads of this struct, in both ABIs:
    //
    //   arm64   ldrsw x0,  [nb, #0x20]   usage, the spec-8 field
    //           ldr   x0,  [nb, #0x38]   +56  uint64, an extended gralloc usage
    //           ldr   x25, [nb, #0x40]   +64  AHardwareBuffer*
    //                                         -> AHardwareBuffer_getNativeHandle
    //   arm     ldr   r0,  [nb, #0x14]   usage
    //           ldrd  r0,r1,[nb, #40]    +40  the same uint64
    //           ldr   r8,  [nb, #0x30]   +48  AHardwareBuffer*
    //
    // Declaring the two extra fields as a struct produces exactly that layout in
    // both ABIs. Without them the driver picks up whatever the compiler parked
    // after the struct on our stack: the crash passed 0x3b9af111 -- the sType of
    // swapchain_image_create, the local declared immediately above -- to
    // AHardwareBuffer_getNativeHandle, which dereferenced it.
    //
    // extended_usage stays 0. We have no such value to report, and the driver only
    // tests it against registered vendor usage masks; the usage it acts on comes
    // from the usage/usage2 fields below, which we do fill.
    //
    // Harmless to r32p1/r38p1, which never read past the struct they were built
    // against.
    struct {
        VkNativeBufferANDROID nb;
        uint64_t extended_usage;
        AHardwareBuffer* ahb;
    } native_buffer = {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wold-style-cast"
    native_buffer.nb.sType = VK_STRUCTURE_TYPE_NATIVE_BUFFER_ANDROID;
#pragma clang diagnostic pop
    native_buffer.nb.pNext = &swapchain_image_create;
    VkNativeBufferANDROID& image_native_buffer = native_buffer.nb;
""")

loop_old = "        image_native_buffer.usage = int(img.buffer->usage);\n"
loop_new = (loop_old +
"""        /* +64 (arm64) / +48 (arm): the AHardwareBuffer the driver calls
         * AHardwareBuffer_getNativeHandle on. ANativeWindowBuffer_getHardwareBuffer
         * is a cast of the GraphicBuffer we already hold -- it takes no reference,
         * so there is nothing to release. */
        native_buffer.ahb = ANativeWindowBuffer_getHardwareBuffer(img.buffer.get());
        ALOGI("RS4DIAG nb_ext: ahb=%p usage3=0", (void*)native_buffer.ahb);
""")

for a, n in ((inc_old, 1), (nb_old, 1), (loop_old, 1)):
    if s.count(a) != n:
        sys.exit("anchor count %d, expected %d" % (s.count(a), n))
s = s.replace(inc_old, inc_new, 1).replace(nb_old, nb_new, 1).replace(loop_old, loop_new, 1)
open(p, "w").write(s)
PYSWAP
  [ $? -eq 0 ] || { echo "   *** FATAL: swapchain.cpp patch failed"; exit 1; }
  grep -q 'uint64_t extended_usage;' "$SWAPCPP" || { echo "   *** FATAL: extended_usage field missing"; exit 1; }
  grep -q 'AHardwareBuffer\* ahb;' "$SWAPCPP"   || { echo "   *** FATAL: ahb field missing"; exit 1; }
  grep -q 'ANativeWindowBuffer_getHardwareBuffer' "$SWAPCPP" || { echo "   *** FATAL: ahb never assigned"; exit 1; }
  grep -q '#include <vndk/window.h>' "$SWAPCPP" || { echo "   *** FATAL: include missing"; exit 1; }
  echo "   patched (extended_usage at +56/+40, AHardwareBuffer* at +64/+48)"
fi

# ---------------------------------------------------------------------------
# STEP 40 -- AHardwareBuffer_allocate: never leave *outBuffer indeterminate.
#
# AOSP's early returns write nothing to the out-param, so a caller that ignores
# the return code keeps whatever its variable happened to hold. getNativeHandle
# checks for null; it cannot check for garbage.
#
# ⚠ HONEST SCOPE: this is NOT what fixes the r54p1 crash, and the r54p1 crash is
# not evidence for it. Proven: the 2026-09-01 passing run used the SHIPPED
# libnativewindow, which does not have this patch (disassembled --
# `str xzr, [x19]` at AHardwareBuffer_allocate+0x40 is present in our build and
# absent in v2build6's). Step 39 alone carries that result.
#
# It lands anyway on its own terms: an out-param left indeterminate on a failure
# path is a defect regardless of who reads it, and this device DOES produce those
# failures -- Mali r54p1 probes HAL_PIXEL_FORMAT_R_8 (56), which this gralloc
# generation cannot allocate, on every Unity launch.
#
# NOT LANDED, deliberately: the R_8/R_16_UINT -> Y8/Y16 fallback in
# libs/ui/GraphicBufferAllocator.cpp. It was measured NOT to fire in the passing
# run (0 hits against a working positive control), so nothing needs it, and it
# would silently substitute a YUV-family format for a colour format on a path
# nobody is watching. The diagnosis is in notes/JOURNAL.md; the code is not here.
#
# DURABLE FIX: fork crdroidandroid/android_frameworks_native, or upstream it.
echo "== step 40: AHardwareBuffer_allocate clears *outBuffer on failure =="
AHB="$TREE/frameworks/native/libs/nativewindow/AHardwareBuffer.cpp"
if [ ! -f "$AHB" ]; then
  echo "   *** FATAL: libs/nativewindow/AHardwareBuffer.cpp not found"; exit 1
elif grep -q 'outBuffer indeterminate' "$AHB"; then
  echo "   already patched"
else
  python3 - "$AHB" <<'PYAHB'
import sys
p = sys.argv[1]
s = open(p).read()
old = ("    if (!outBuffer || !desc) return BAD_VALUE;\n")
new = ("""    if (!outBuffer || !desc) return BAD_VALUE;
    // Never leave *outBuffer indeterminate. AOSP's early returns below do not
    // write it, so a caller that ignores the return code keeps whatever its
    // variable happened to hold -- and AHardwareBuffer_getNativeHandle's null
    // check cannot catch garbage, only null. Mali r54p1 ignores the result of
    // the HAL_PIXEL_FORMAT_R_8 probe this gralloc generation always fails.
    *outBuffer = nullptr;
""")
if s.count(old) != 1:
    sys.exit("anchor count %d, expected 1" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PYAHB
  [ $? -eq 0 ] || { echo "   *** FATAL: AHardwareBuffer patch failed"; exit 1; }
  grep -q '\*outBuffer = nullptr;' "$AHB" || { echo "   *** FATAL: clear not present"; exit 1; }
  echo "   patched (out-param cleared before any failure path)"
fi


# ---------------------------------------------------------------------------
# STEP 41 -- libgui: report BufferQueue frames to ged, so GPU DVFS runs.
#
# 🔴 GPU DVFS HAS NEVER WORKED ON THIS ROM. Measured 2026-09-01 on v3.1 with the
# GPU powered and rendering: ged_dvfs_run 0 hits over 20 s, gpu_utilization
# "0 0 100" WHILE RENDERING, GPU pinned at OPP 0 of 38. Identical with the r38p1
# UMD, so it is not an r54p1 regression -- it is every build this project has
# shipped, and the kbase side is fine (kbase_pm_metrics_active_calc fires 56338
# times in the same window; the commit path moves the GPU 1003->756 MHz on demand).
#
# The gap is that ged's policy loop only runs when ged is told a frame happened.
# MediaTek reports that from libgui, which dlopens libged_kpi.so and calls it on
# the BufferQueue paths. AOSP's libgui does not. Stock's own libgui carries
# android::GedKpiDebug + GedKpiModuleLoader and the string "open libged_kpi.so
# failed", i.e. it is an OPTIONAL hook -- which is why this is a small patch and
# not a fork.
#
# The ABI was decoded from stock (we have no MediaTek source): the 8 wrappers in
# libged_kpi.so are 4-20 byte forwarders whose C++-mangled targets in libged_sys.so
# carry the types. Full derivation in notes/JOURNAL.md 2026-09-01.
#
# 🔴 queue's third argument is QedBuffer_length -- the QUEUE DEPTH, not the slot.
# It reaches ged_gpu_timestamp as that field (struct GED_BRIDGE_IN_GPU_TIMESTAMP).
# The slot index was the obvious guess and would have compiled, run, and steered
# the DVFS governor on a slot number with no crash and no log line.
#
# Fails soft: no libged_kpi.so -> every hook is a no-op, exactly like stock.
# The blobs ship from device/itel/S666LN/prebuilts/gedkpi (stock system, rev 28).
#
# DURABLE FIX: fork crdroidandroid/android_frameworks_native, or upstream it.
echo "== step 41: libgui reports BufferQueue frames to ged (GPU DVFS) =="
GUIDIR="$TREE/frameworks/native/libs/gui"
[ -d "$GUIDIR" ] || { echo "   *** FATAL: frameworks/native/libs/gui not found"; exit 1; }

# 🔴 The header is copied UNCONDITIONALLY, before the already-patched test.
# It used to sit inside the else-branch, so once the .cpp call sites existed the
# recipe reported "already patched" and left a STALE GedKpiHook.h in the build
# tree -- a header fix could never reach a build. That is exactly the class of
# defect RESUME 9b step 1 exists for: the tree the compiler reads is not the tree
# you edit.
cp "$HERE/gedkpi/GedKpiHook.h" "$GUIDIR/GedKpiHook.h" || { echo "   *** FATAL: GedKpiHook.h missing from the recipe"; exit 1; }

if grep -q "gedkpi::onQueue" "$GUIDIR/BufferQueueProducer.cpp"; then
  echo "   call sites already patched; GedKpiHook.h refreshed"
else
  python3 - "$GUIDIR" <<'PYGUI'
import sys, os
d = sys.argv[1]

def add_include(fn):
    p = os.path.join(d, fn); s = open(p).read()
    if '"GedKpiHook.h"' in s: return
    i = s.rindex('#include', 0, s.index('namespace android'))
    e = s.index('\n', i) + 1
    open(p, 'w').write(s[:e] + '\n#include "GedKpiHook.h"\n' + s[e:])

for f in ("BufferQueueCore.cpp", "BufferQueueProducer.cpp", "BufferQueueConsumer.cpp"):
    add_include(f)

p = os.path.join(d, "BufferQueueCore.cpp"); s = open(p).read()
a = "        mUnusedSlots.push_front(s);\n    }\n}\n\nBufferQueueCore::~BufferQueueCore() {}"
if s.count(a) != 1: sys.exit("BufferQueueCore anchor count %d" % s.count(a))
s = s.replace(a, "        mUnusedSlots.push_front(s);\n    }\n    gedkpi::onCreate(mUniqueId);\n}\n\n"
                 "BufferQueueCore::~BufferQueueCore() {\n    gedkpi::onDestroy(mUniqueId);\n}", 1)
open(p, 'w').write(s)

p = os.path.join(d, "BufferQueueProducer.cpp"); s = open(p).read()
a = "        mCore->mBufferHasBeenQueued = true;\n        mCore->mDequeueCondition.notify_all();\n        mCore->mLastQueuedSlot = slot;\n"
if s.count(a) != 1: sys.exit("queueBuffer anchor count %d" % s.count(a))
s = s.replace(a, a + "\n        // Third argument is QedBuffer_length -- the QUEUE DEPTH, not the slot.\n"
                     "        // item.mGraphicBuffer is cleared further below for non-SF consumers.\n"
                     "        gedkpi::onQueue(mCore->mUniqueId, item.mGraphicBuffer, item.mFence,\n"
                     "                        static_cast<int>(mCore->mQueue.size()));\n", 1)
a = "    if (outBufferAge) {\n        *outBufferAge = mCore->mBufferAge;\n    }\n    addAndGetFrameTimestamps(nullptr, outTimestamps);\n"
if s.count(a) != 1: sys.exit("dequeueBuffer anchor count %d" % s.count(a))
s = s.replace(a, "    if (outBufferAge) {\n        *outBufferAge = mCore->mBufferAge;\n    }\n"
                 "    gedkpi::onDequeue(mCore->mUniqueId, mSlots[*outSlot].mGraphicBuffer, *outFence);\n"
                 "    addAndGetFrameTimestamps(nullptr, outTimestamps);\n", 1)
a = "            mCore->mConnectedApi = api;\n"
if s.count(a) != 1: sys.exit("connect anchor count %d" % s.count(a))
s = s.replace(a, a + "            // getCallingPid() directly: mCore->mConnectedPid is not assigned\n"
                     "            // until further below in this function.\n"
                     "            gedkpi::onConnect(mCore->mUniqueId, api,\n"
                     "                              BufferQueueThreadState::getCallingPid());\n", 1)
a = "                    mCore->mConnectedApi = BufferQueueCore::NO_CONNECTED_API;\n"
if s.count(a) != 1: sys.exit("disconnect anchor count %d" % s.count(a))
s = s.replace(a, a + "                    gedkpi::onDisconnect(mCore->mUniqueId);\n", 1)
open(p, 'w').write(s)

p = os.path.join(d, "BufferQueueConsumer.cpp"); s = open(p).read()
i = s.index("status_t BufferQueueConsumer::acquireBuffer")
j = s.index("\n    return NO_ERROR;\n", i)
s = s[:j] + "\n    gedkpi::onAcquire(mCore->mUniqueId, outBuffer->mGraphicBuffer);\n" + s[j:]
open(p, 'w').write(s)
PYGUI
  [ $? -eq 0 ] || { echo "   *** FATAL: libgui gedkpi patch failed"; exit 1; }
  grep -q "gedkpi::onQueue"   "$GUIDIR/BufferQueueProducer.cpp" || { echo "   *** FATAL: onQueue missing";   exit 1; }
  grep -q "gedkpi::onDequeue" "$GUIDIR/BufferQueueProducer.cpp" || { echo "   *** FATAL: onDequeue missing"; exit 1; }
  grep -q "gedkpi::onAcquire" "$GUIDIR/BufferQueueConsumer.cpp" || { echo "   *** FATAL: onAcquire missing"; exit 1; }
  grep -q "gedkpi::onCreate"  "$GUIDIR/BufferQueueCore.cpp"     || { echo "   *** FATAL: onCreate missing";  exit 1; }
  echo "   patched (create/destroy, connect/disconnect, dequeue/queue, acquire)"
fi

# 🔴 Post-condition on BOTH paths: queue must hand ged fence_fd = -1.
# A real fence there panics ged_kpi_gpu_3d_fence_sync_cb from mali_kbase's
# job-done worker and bootloops the device (v3build5, 20260901091546). The
# positive control is the dequeue call beside it, which legitimately still
# passes a fence -- so a zero here is provably a real zero and not a broken grep.
grep -q 'queueTag(id, -1, queuedBufferCount' "$GUIDIR/GedKpiHook.h" \
  || { echo "   *** FATAL: GedKpiHook.h onQueue is not passing fence_fd = -1 (bootloop fix missing)"; exit 1; }
grep -q 'dequeueTag(id, fd,' "$GUIDIR/GedKpiHook.h" \
  || { echo "   *** FATAL: GedKpiHook.h control check failed -- onDequeue not found, the grep above proves nothing"; exit 1; }
echo "   onQueue fence_fd = -1 confirmed (control: onDequeue still passes a fence)"


echo "== step 45: libvulkan VK_KHR_swapchain_mutable_format =="
SWAPCPP="$TREE/frameworks/native/vulkan/libvulkan/swapchain.cpp"
DRVCPP="$TREE/frameworks/native/vulkan/libvulkan/driver.cpp"
if [ ! -f "$SWAPCPP" ] || [ ! -f "$DRVCPP" ]; then
  echo "   *** FATAL: vulkan/libvulkan sources not found"; exit 1
elif grep -q 'mutable_format_image_flags' "$SWAPCPP"; then
  echo "   already patched"
else
  python3 - "$SWAPCPP" "$DRVCPP" <<'PYMUT'
import sys
sc_path, dr_path = sys.argv[1], sys.argv[2]
s = open(sc_path).read()

a = """    bool createProtectedSwapchain = false;
    if (create_info->flags & VK_SWAPCHAIN_CREATE_PROTECTED_BIT_KHR) {
        createProtectedSwapchain = true;
        native_usage |= BufferUsage::PROTECTED;
    }
"""
a_new = a + """
    // VK_KHR_swapchain_mutable_format. Implemented entirely here: the extension
    // adds no entry points and no driver interface. The spec makes the format
    // list mandatory when the bit is set (VUID-VkSwapchainCreateInfoKHR-flags-03168),
    // so refuse rather than hand back images the app cannot legally use.
    VkImageCreateFlags mutable_format_image_flags = 0;
    const VkImageFormatListCreateInfo* swapchain_image_format_list = nullptr;
    if (create_info->flags & VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR) {
        for (const VkBaseInStructure* p =
                 reinterpret_cast<const VkBaseInStructure*>(create_info->pNext);
             p != nullptr; p = p->pNext) {
            if (p->sType == VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO) {
                swapchain_image_format_list =
                    reinterpret_cast<const VkImageFormatListCreateInfo*>(p);
                break;
            }
        }
        if (swapchain_image_format_list == nullptr ||
            swapchain_image_format_list->viewFormatCount == 0) {
            ALOGE(
                "vkCreateSwapchainKHR: MUTABLE_FORMAT_BIT set without a "
                "non-empty VkImageFormatListCreateInfo");
            return VK_ERROR_INITIALIZATION_FAILED;
        }
        mutable_format_image_flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT |
                                     VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
    }
"""

b = """    native_buffer.nb.pNext = &swapchain_image_create;
    VkNativeBufferANDROID& image_native_buffer = native_buffer.nb;"""
b_new = """    native_buffer.nb.pNext = &swapchain_image_create;
    // Appended at the TAIL so the VkNativeBufferANDROID -> swapchain_image_create
    // order the driver walks is untouched. pNext order carries no meaning.
    if (swapchain_image_format_list != nullptr)
        swapchain_image_create.pNext = swapchain_image_format_list;
    VkNativeBufferANDROID& image_native_buffer = native_buffer.nb;"""

c = "        .flags = createProtectedSwapchain ? VK_IMAGE_CREATE_PROTECTED_BIT : 0u,"
c_new = ("        .flags = (createProtectedSwapchain ? VK_IMAGE_CREATE_PROTECTED_BIT : 0u) |\n"
         "                 mutable_format_image_flags,")

for anchor in (a, b, c):
    if s.count(anchor) != 1:
        sys.exit("swapchain.cpp anchor count %d, expected 1" % s.count(anchor))
s = s.replace(a, a_new, 1).replace(b, b_new, 1).replace(c, c_new, 1)
open(sc_path, "w").write(s)

d = open(dr_path).read()
e = """    bool hdrBoardConfig = android::sysprop::has_HDR_display(false);
    if (hdrBoardConfig) {
        loader_extensions.push_back({VK_EXT_HDR_METADATA_EXTENSION_NAME,
                                     VK_EXT_HDR_METADATA_SPEC_VERSION});
    }
"""
e_new = e + """
    // VK_KHR_swapchain_mutable_format is implemented by the LOADER (swapchain.cpp),
    // not the driver -- exactly as VK_KHR_swapchain itself is, which is why
    // neither string appears in the driver's own extension table.
    //
    // Gated on the driver being >= 1.2, where both things the implementation
    // needs are CORE: VkImageFormatListCreateInfo (VK_KHR_image_format_list) and
    // VK_IMAGE_CREATE_EXTENDED_USAGE_BIT (VK_KHR_maintenance2). Advertising it
    // against a driver with neither would hand the app a swapchain whose images
    // vkCreateImage rejects. Mali r54p1 here reports 1.3.303 and exports both.
    {
        VkPhysicalDeviceProperties props;
        data.driver.GetPhysicalDeviceProperties(physicalDevice, &props);
        if (props.apiVersion >= VK_API_VERSION_1_2) {
            loader_extensions.push_back(
                {VK_KHR_SWAPCHAIN_MUTABLE_FORMAT_EXTENSION_NAME,
                 VK_KHR_SWAPCHAIN_MUTABLE_FORMAT_SPEC_VERSION});
        }
    }
"""
if d.count(e) != 1:
    sys.exit("driver.cpp anchor count %d, expected 1" % d.count(e))
open(dr_path, "w").write(d.replace(e, e_new, 1))
PYMUT
  [ $? -eq 0 ] || { echo "   *** FATAL: swapchain_mutable_format patch failed"; exit 1; }
  grep -q 'mutable_format_image_flags' "$SWAPCPP" \
    || { echo "   *** FATAL: image flags never set"; exit 1; }
  grep -q 'swapchain_image_create.pNext = swapchain_image_format_list' "$SWAPCPP" \
    || { echo "   *** FATAL: the format list never reaches vkCreateImage -- the"; \
         echo "             extension would be advertised and inert"; exit 1; }
  grep -q 'VK_KHR_SWAPCHAIN_MUTABLE_FORMAT_EXTENSION_NAME' "$DRVCPP" \
    || { echo "   *** FATAL: never advertised"; exit 1; }
  grep -q 'VK_IMAGE_CREATE_PROTECTED_BIT : 0u) |' "$SWAPCPP" \
    || { echo "   *** FATAL: control -- the protected-bit flag expression was not"; \
         echo "             rewritten, so the mutable flags are computed and dropped"; exit 1; }
  echo "   patched (advertised in driver.cpp, implemented in swapchain.cpp)"
fi

# ---------------------------------------------------------------------------
# STEP 46 -- VK_EXT_surface_maintenance1, implemented in the loader.
#
# Second of the four extensions that separate us from the donor's 148/14. This
# one is INSTANCE-level and moves 13 -> 14. Like step 41 it adds no entry points
# and needs nothing from the driver; unlike step 41 our vulkan-headers
# (VK_HEADER_VERSION 203) predate it entirely, so the types come from a local
# header rather than a repo bump -- vulkan_core.h is included by a large part of
# the platform and bumping it to gain four extensions changes every one of those
# compile units.
#
# 🔑 THE VALUES ARE NOT GUESSED. The extension makes the loader ANSWER questions
# -- what scaling a surface supports, which present modes can be swapped without
# recreating the swapchain -- and a wrong answer is worse than no extension. They
# were read out of the two shipping A16 loaders by disassembly:
#     Samsung SM-A175F  /system/lib64/libvulkan.so   (our driver's donor)
#     Infinix X6886     /system/lib64/libvulkan.so   (Transsion, independent)
# Both fill VkSurfacePresentScalingCapabilities from the SAME 8 rodata bytes,
# 04000000 00000000 -> supportedPresentScaling = STRETCH, gravityX = 0, and both
# then `str wzr` gravityY and copy min/maxScaledImageExtent straight off the base
# capabilities. Two independent vendors agreeing byte-for-byte is AOSP behaviour,
# not a vendor quirk. My own first instinct was to report scaling = 0, which
# would have been WRONG.
# For compatibility both build a list of just the queried mode, adding the other
# SHARED_*_REFRESH mode when the query is one of those two.
#
# One deliberate divergence: the donors dereference the chained
# VkSurfacePresentModeEXT unconditionally. The spec requires the app to provide
# it, but we report nothing instead of faulting on an app that gets it wrong.
#
# PROVEN ON HARDWARE 2026-09-07, with a negative control:
#   patched    instance_ext_count 14 (device 146, unchanged as predicted)
#              supportedPresentScaling 4 · gravityX 0 · gravityY 0
#              min/maxScaledImageExtent 1x1 / 4096x4096 == base caps
#              FIFO compatible with itself only, count 1
#   unpatched  instance_ext_count 13 · vkCreateInstance(+ext) -7
# Test binary: device_itel_S666LN/tools/vksurf.c
echo "== step 46: libvulkan VK_EXT_surface_maintenance1 =="
VKDIR="$TREE/frameworks/native/vulkan/libvulkan"
if [ ! -d "$VKDIR" ]; then
  echo "   *** FATAL: $VKDIR not found"; exit 1
elif grep -q 'kStructureTypeSurfacePresentScalingCapabilitiesEXT' "$VKDIR/swapchain.cpp" 2>/dev/null; then
  echo "   already patched"
else
  cat > "$VKDIR/ext_backport.h" <<'PYEOF_HDR'
/*
 * ext_backport.h -- minimal definitions for Vulkan extensions the loader
 * implements but external/vulkan-headers (VK_HEADER_VERSION 203) predates.
 *
 * WHY A LOCAL HEADER AND NOT A HEADER BUMP
 * vulkan_core.h is included by a large fraction of the platform. Bumping the
 * repo to pick up four extensions changes every one of those compile units and
 * every enum they see. These definitions are needed by exactly two files, so
 * they live next to those two files and nothing else can be affected by them.
 *
 * EVERY VALUE BELOW IS COPIED, NOT DERIVED, from Khronos
 * Vulkan-Headers-vulkan-sdk-1.4.357.0/include/vulkan/vulkan_core.h. Do not
 * "simplify" a number here; if one is wrong the struct is silently misread.
 *
 * The struct layouts must match the ABI exactly, so the field order and types
 * are reproduced verbatim from that header rather than rewritten.
 */

#ifndef VULKAN_LIBVULKAN_EXT_BACKPORT_H
#define VULKAN_LIBVULKAN_EXT_BACKPORT_H

#include <vulkan/vulkan.h>

// ---- VK_EXT_surface_maintenance1 (instance extension, no entry points)
#define RS4_VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME "VK_EXT_surface_maintenance1"
#define RS4_VK_EXT_SURFACE_MAINTENANCE_1_SPEC_VERSION 1

// VkStructureType values. Cast at the point of comparison: VkStructureType in
// this tree's headers does not contain them, and adding them as case labels
// would be a "case value not in enumerated type" warning.
constexpr uint32_t kStructureTypeSurfacePresentModeEXT = 1000274000u;
constexpr uint32_t kStructureTypeSurfacePresentScalingCapabilitiesEXT = 1000274001u;
constexpr uint32_t kStructureTypeSurfacePresentModeCompatibilityEXT = 1000274002u;

typedef VkFlags VkPresentScalingFlagsEXT;
typedef VkFlags VkPresentGravityFlagsEXT;

// VkPresentScalingFlagBitsKHR
constexpr VkPresentScalingFlagsEXT kPresentScalingOneToOneBitEXT = 0x00000001u;
constexpr VkPresentScalingFlagsEXT kPresentScalingAspectRatioStretchBitEXT = 0x00000002u;
constexpr VkPresentScalingFlagsEXT kPresentScalingStretchBitEXT = 0x00000004u;

// VkPresentGravityFlagBitsKHR
constexpr VkPresentGravityFlagsEXT kPresentGravityMinBitEXT = 0x00000001u;
constexpr VkPresentGravityFlagsEXT kPresentGravityMaxBitEXT = 0x00000002u;
constexpr VkPresentGravityFlagsEXT kPresentGravityCenteredBitEXT = 0x00000004u;

struct VkSurfacePresentModeEXT {
    VkStructureType sType;
    void* pNext;
    VkPresentModeKHR presentMode;
};

struct VkSurfacePresentScalingCapabilitiesEXT {
    VkStructureType sType;
    void* pNext;
    VkPresentScalingFlagsEXT supportedPresentScaling;
    VkPresentGravityFlagsEXT supportedPresentGravityX;
    VkPresentGravityFlagsEXT supportedPresentGravityY;
    VkExtent2D minScaledImageExtent;
    VkExtent2D maxScaledImageExtent;
};

struct VkSurfacePresentModeCompatibilityEXT {
    VkStructureType sType;
    void* pNext;
    uint32_t presentModeCount;
    VkPresentModeKHR* pPresentModes;
};

#endif  // VULKAN_LIBVULKAN_EXT_BACKPORT_H
PYEOF_HDR
  cat > "$VKDIR/.rs4_sm1_block" <<'PYEOF_BLOCK'
    // VK_EXT_surface_maintenance1: the compatibility query is answered ABOUT a
    // present mode the app chains onto the INPUT struct. Scan for it first --
    // the output walk below needs it. Behaviour copied from the two shipping
    // A16 loaders (Samsung SM-A175F and Infinix X6886), which take the LAST
    // match rather than the first and are byte-identical to each other here.
    const VkSurfacePresentModeEXT* queried_present_mode = nullptr;
    for (const VkBaseInStructure* p =
             reinterpret_cast<const VkBaseInStructure*>(pSurfaceInfo->pNext);
         p != nullptr; p = p->pNext) {
        if (static_cast<uint32_t>(p->sType) ==
            kStructureTypeSurfacePresentModeEXT) {
            queried_present_mode =
                reinterpret_cast<const VkSurfacePresentModeEXT*>(p);
        }
    }

    VkSurfaceCapabilities2KHR* caps = pSurfaceCapabilities;
    while (caps->pNext) {
        caps = reinterpret_cast<VkSurfaceCapabilities2KHR*>(caps->pNext);

        // VK_EXT_surface_maintenance1. Handled before the switch because this
        // tree's VkStructureType does not contain these values, so they cannot
        // be case labels without a "not in enumerated type" warning.
        const uint32_t stype = static_cast<uint32_t>(caps->sType);

        if (stype == kStructureTypeSurfacePresentScalingCapabilitiesEXT) {
            auto* scaling =
                reinterpret_cast<VkSurfacePresentScalingCapabilitiesEXT*>(caps);
            // An Android surface stretches to the window; it does not letterbox
            // and it has no gravity to choose. Both A16 loaders report exactly
            // this, from the same 8 rodata bytes (04000000 00000000), and the
            // extents are copied straight off the base capabilities.
            scaling->supportedPresentScaling = kPresentScalingStretchBitEXT;
            scaling->supportedPresentGravityX = 0;
            scaling->supportedPresentGravityY = 0;
            scaling->minScaledImageExtent =
                pSurfaceCapabilities->surfaceCapabilities.minImageExtent;
            scaling->maxScaledImageExtent =
                pSurfaceCapabilities->surfaceCapabilities.maxImageExtent;
            continue;
        }

        if (stype == kStructureTypeSurfacePresentModeCompatibilityEXT) {
            auto* compat =
                reinterpret_cast<VkSurfacePresentModeCompatibilityEXT*>(caps);
            // A swapchain here cannot change present mode without being
            // recreated, so a mode is compatible only with itself -- EXCEPT the
            // two shared-present modes, which are interchangeable. Again this is
            // what both A16 loaders do, not a guess.
            VkPresentModeKHR modes[2];
            uint32_t count = 0;
            if (queried_present_mode != nullptr) {
                const VkPresentModeKHR mode = queried_present_mode->presentMode;
                modes[count++] = mode;
                if (mode == VK_PRESENT_MODE_SHARED_DEMAND_REFRESH_KHR) {
                    modes[count++] =
                        VK_PRESENT_MODE_SHARED_CONTINUOUS_REFRESH_KHR;
                } else if (mode ==
                           VK_PRESENT_MODE_SHARED_CONTINUOUS_REFRESH_KHR) {
                    modes[count++] = VK_PRESENT_MODE_SHARED_DEMAND_REFRESH_KHR;
                }
            } else {
                // The spec requires a chained VkSurfacePresentModeEXT here
                // (VUID-VkSurfaceCapabilities2KHR-pNext-07776). The donors
                // dereference it unconditionally; report nothing instead of
                // faulting on an app that gets it wrong.
                ALOGE(
                    "VkSurfacePresentModeCompatibilityEXT queried without a "
                    "chained VkSurfacePresentModeEXT");
            }
            if (compat->pPresentModes == nullptr) {
                compat->presentModeCount = count;
            } else {
                if (compat->presentModeCount > count)
                    compat->presentModeCount = count;
                for (uint32_t i = 0; i < compat->presentModeCount; i++)
                    compat->pPresentModes[i] = modes[i];
            }
            continue;
        }

PYEOF_BLOCK
  python3 - "$VKDIR/swapchain.cpp" "$VKDIR/driver.cpp" "$VKDIR/.rs4_sm1_block" <<'PYSURF'
import sys
sc_path, dr_path, block_path = sys.argv[1], sys.argv[2], sys.argv[3]
block = open(block_path).read()
s = open(sc_path).read()
inc = '#include "driver.h"\n'
if s.count(inc) < 1:
    sys.exit('swapchain.cpp: no driver.h include to anchor on')
if '#include "ext_backport.h"' not in s:
    s = s.replace(inc, inc + '#include "ext_backport.h"\n', 1)
anchor = ('    VkSurfaceCapabilities2KHR* caps = pSurfaceCapabilities;\n'
          '    while (caps->pNext) {\n'
          '        caps = reinterpret_cast<VkSurfaceCapabilities2KHR*>(caps->pNext);\n'
          '\n'
          '        switch (caps->sType) {')
if s.count(anchor) != 1:
    sys.exit('swapchain.cpp caps anchor count %d, expected 1' % s.count(anchor))
s = s.replace(anchor, block + '        switch (caps->sType) {', 1)
open(sc_path, 'w').write(s)

d = open(dr_path).read()
if '#include "ext_backport.h"' not in d:
    d = d.replace(inc, inc + '#include "ext_backport.h"\n', 1)
e = '    loader_extensions.push_back({VK_GOOGLE_SURFACELESS_QUERY_EXTENSION_NAME,\n'
if d.count(e) != 1:
    sys.exit('driver.cpp anchor count %d, expected 1' % d.count(e))
e_new = ('    // VK_EXT_surface_maintenance1 -- implemented by the loader in\n'
         '    // GetPhysicalDeviceSurfaceCapabilities2KHR (swapchain.cpp). Instance-level,\n'
         '    // no entry points, no driver involvement.\n'
         '    loader_extensions.push_back({RS4_VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME,\n'
         '                                 RS4_VK_EXT_SURFACE_MAINTENANCE_1_SPEC_VERSION});\n') + e
open(dr_path, 'w').write(d.replace(e, e_new, 1))
PYSURF
  rc=$?
  rm -f "$VKDIR/.rs4_sm1_block"
  [ $rc -eq 0 ] || { echo "   *** FATAL: surface_maintenance1 patch failed"; exit 1; }
  grep -q 'kStructureTypeSurfacePresentScalingCapabilitiesEXT' "$VKDIR/swapchain.cpp" \
    || { echo "   *** FATAL: the scaling case never landed"; exit 1; }
  grep -q 'kPresentScalingStretchBitEXT' "$VKDIR/swapchain.cpp" \
    || { echo "   *** FATAL: scaling value missing -- would report 0, which is NOT"; \
         echo "             what either donor reports"; exit 1; }
  grep -q 'RS4_VK_EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME' "$VKDIR/driver.cpp" \
    || { echo "   *** FATAL: never advertised"; exit 1; }
  grep -q 'ext_backport.h' "$VKDIR/driver.cpp" \
    || { echo "   *** FATAL: driver.cpp does not include the backport header"; exit 1; }
  echo "   patched (instance extension advertised, capabilities answered)"
fi

# ---------------------------------------------------------------------------
# STEP 47 -- VK_EXT_image_compression_control_swapchain, in all three of its parts.
#
# Third of four. Device extension, 146 -> 147, no entry points. The BASE
# extension VK_EXT_image_compression_control belongs to the DRIVER (Mali r54p1
# exports and implements it); this one extends it to swapchains, which is the
# loader's job because the loader is what creates swapchain images.
#
# 🔴 IT HAS THREE PARTS AND SHIPPING TWO WOULD BE WORSE THAN SHIPPING NONE:
#   1 the FEATURE must report TRUE, because an app checks it before using this
#   2 vkGetPhysicalDeviceSurfaceFormats2KHR must ANSWER a chained
#     VkImageCompressionPropertiesEXT -- our loader previously discarded these
#     outright, with the comment "completely ignore any chained extension
#     structs". An extension that accepts a compression request and can never
#     report what it did with it is a trap.
#   3 the app's VkImageCompressionControlEXT must reach vkCreateImage
#
# The parameters in part 2 are NOT invented. Both A16 donors -- Samsung
# SM-A175F (our driver's donor) and Infinix X6886 (Transsion, independent) --
# ask the driver the identical question for each surface format:
#     VkPhysicalDeviceImageFormatInfo2 { format = the surface format,
#         type = 2D, tiling = OPTIMAL, usage = COLOR_ATTACHMENT, flags = 0 }
#     pNext -> VkImageCompressionControlEXT { flags = FIXED_RATE_DEFAULT }
#     out:  VkImageFormatProperties2 pNext -> VkImageCompressionPropertiesEXT
# and copy the two returned flag words straight back into the app's struct.
# For part 3 both copy the app's struct BY VALUE and clear its pNext before
# chaining it onto image creation.
#
# ⚠ A BELIEF THIS STEP CORRECTS. The first version of the feature code said the
# driver "has never heard of" this struct. It has: measured on the STOCK loader
# with none of this present, r54p1 already answers
# VkPhysicalDeviceImageCompressionControlSwapchainFeaturesEXT with VK_TRUE -- it
# is newer than this platform. What it does not and cannot do is ADVERTISE the
# extension (stock loader: VK_EXT_image_compression_control yes, _swapchain no),
# because the swapchain half is the loader's. We answer the feature so it is
# right on its own terms rather than by luck.
#
# PROVEN ON HARDWARE 2026-09-07, with a negative control:
#   patched    device_ext_count 147 (instance 14, unchanged)
#              imageCompressionControlSwapchain 1
#              properties ANSWERED -- 0xDEADBEEF sentinel overwritten, driver
#                reports DEFAULT compression / no fixed rate for format 37
#              vkCreateDevice(+both) 0 - vkCreateSwapchainKHR(+control) 0
#   unpatched  device_ext_count 145 - vkCreateDevice(+both) -7
#              properties NOT answered (sentinel intact)
# Test binary: device_itel_S666LN/tools/vkcomp.c
echo "== step 47: libvulkan VK_EXT_image_compression_control_swapchain =="
VKDIR="$TREE/frameworks/native/vulkan/libvulkan"
if [ ! -d "$VKDIR" ]; then
  echo "   *** FATAL: $VKDIR not found"; exit 1
elif grep -q 'kStructureTypeImageCompressionPropertiesEXT' "$VKDIR/swapchain.cpp" 2>/dev/null; then
  echo "   already patched"
else
  cat > "$VKDIR/.rs43_swap_a" <<'RS43_SWAP_A'

    // VK_EXT_image_compression_control_swapchain: the app chains a
    // VkImageCompressionControlEXT onto the SWAPCHAIN, and it has to reach
    // vkCreateImage for each swapchain image. Copied by VALUE and its pNext
    // cleared, which is what both A16 donors do -- the app's struct may sit in
    // a chain the image creation must not inherit.
    VkImageCompressionControlEXT swapchain_compression = {};
    bool have_compression_control = false;
    for (const VkBaseInStructure* p =
             reinterpret_cast<const VkBaseInStructure*>(create_info->pNext);
         p != nullptr; p = p->pNext) {
        if (static_cast<uint32_t>(p->sType) ==
            kStructureTypeImageCompressionControlEXT) {
            swapchain_compression =
                *reinterpret_cast<const VkImageCompressionControlEXT*>(p);
            swapchain_compression.pNext = nullptr;
            have_compression_control = true;
        }
    }

RS43_SWAP_A
  cat > "$VKDIR/.rs43_swap_b" <<'RS43_SWAP_B'
    if (have_compression_control) {
        // Tail again, after the format list if there is one.
        if (swapchain_image_format_list != nullptr)
            const_cast<VkImageFormatListCreateInfo*>(swapchain_image_format_list)
                ->pNext = &swapchain_compression;
        else
            swapchain_image_create.pNext = &swapchain_compression;
    }

RS43_SWAP_B
  cat > "$VKDIR/.rs43_swap_c" <<'RS43_SWAP_C'
        if (result == VK_SUCCESS || result == VK_INCOMPLETE) {
            // marshal results individually due to stride difference.
            uint32_t formats_to_marshal = *pSurfaceFormatCount;
            for (uint32_t i = 0u; i < formats_to_marshal; i++) {
                pSurfaceFormats[i].surfaceFormat = surface_formats[i];

                // VK_EXT_image_compression_control_swapchain: answer a chained
                // VkImageCompressionPropertiesEXT. This is the half of the
                // extension that is easy to skip -- the comment here used to
                // read "completely ignore any chained extension structs" --
                // and skipping it would ship an extension that accepts a
                // request and can never report what it did with it.
                //
                // The query below is not invented: both A16 donors ask the
                // driver the identical question -- 2D, OPTIMAL tiling,
                // COLOR_ATTACHMENT usage, requesting FIXED_RATE_DEFAULT -- and
                // copy the two returned flag words straight back.
                for (VkBaseOutStructure* p = reinterpret_cast<VkBaseOutStructure*>(
                         pSurfaceFormats[i].pNext);
                     p != nullptr; p = p->pNext) {
                    if (static_cast<uint32_t>(p->sType) !=
                        kStructureTypeImageCompressionPropertiesEXT)
                        continue;

                    const auto& driver = GetData(physicalDevice).driver;
                    PFN_vkGetPhysicalDeviceImageFormatProperties2 fn =
                        driver.GetPhysicalDeviceImageFormatProperties2;
                    if (!fn)
                        fn = driver.GetPhysicalDeviceImageFormatProperties2KHR;
                    if (!fn)
                        continue;

                    VkImageCompressionControlEXT request = {};
                    request.sType = static_cast<VkStructureType>(
                        kStructureTypeImageCompressionControlEXT);
                    request.flags = kImageCompressionFixedRateDefaultEXT;

                    VkPhysicalDeviceImageFormatInfo2 info = {};
                    info.sType =
                        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
                    info.pNext = &request;
                    info.format = surface_formats[i].format;
                    info.type = VK_IMAGE_TYPE_2D;
                    info.tiling = VK_IMAGE_TILING_OPTIMAL;
                    info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
                    info.flags = 0;

                    VkImageCompressionPropertiesEXT out = {};
                    out.sType = static_cast<VkStructureType>(
                        kStructureTypeImageCompressionPropertiesEXT);

                    VkImageFormatProperties2 props = {};
                    props.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
                    props.pNext = &out;

                    if (fn(physicalDevice, &info, &props) == VK_SUCCESS) {
                        auto* dst =
                            reinterpret_cast<VkImageCompressionPropertiesEXT*>(p);
                        dst->imageCompressionFlags = out.imageCompressionFlags;
                        dst->imageCompressionFixedRateFlags =
                            out.imageCompressionFixedRateFlags;
                    }
                }
            }
        }
RS43_SWAP_C
  cat > "$VKDIR/.rs43_drv_helper" <<'RS43_DRV_HELPER'
// VK_EXT_image_compression_control_swapchain is only meaningful when the DRIVER
// implements the base VK_EXT_image_compression_control -- the loader only routes
// the structs, the driver does the compressing. Both A16 donors gate the feature
// on exactly this query (Samsung SM-A175F and Infinix X6886 both build a
// VkPhysicalDeviceImageCompressionControlFeaturesEXT, chain it into
// VkPhysicalDeviceFeatures2, ask the driver, and report the swapchain feature
// TRUE only if imageCompressionControl came back TRUE), so the extension is
// gated the same way.
static bool DriverSupportsImageCompressionControl(VkPhysicalDevice physicalDevice) {
    const InstanceData& data = GetData(physicalDevice);
    PFN_vkGetPhysicalDeviceFeatures2 fn = data.driver.GetPhysicalDeviceFeatures2;
    if (!fn)
        fn = data.driver.GetPhysicalDeviceFeatures2KHR;
    if (!fn)
        return false;

    VkPhysicalDeviceImageCompressionControlFeaturesEXT icc = {};
    icc.sType = static_cast<VkStructureType>(
        kStructureTypePhysicalDeviceImageCompressionControlFeaturesEXT);
    icc.pNext = nullptr;
    icc.imageCompressionControl = VK_FALSE;

    VkPhysicalDeviceFeatures2 features = {};
    features.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features.pNext = &icc;

    fn(physicalDevice, &features);
    return icc.imageCompressionControl == VK_TRUE;
}


RS43_DRV_HELPER
  cat > "$VKDIR/.rs43_drv_adv" <<'RS43_DRV_ADV'
    // VK_EXT_image_compression_control_swapchain -- routed by the loader
    // (swapchain.cpp), backed by the driver's own compression support.
    if (DriverSupportsImageCompressionControl(physicalDevice)) {
        loader_extensions.push_back(
            {RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_EXTENSION_NAME,
             RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_SPEC_VERSION});
    }


RS43_DRV_ADV
  cat > "$VKDIR/.rs43_drv_feat" <<'RS43_DRV_FEAT'
// Fill in the features the LOADER owns, after the driver has filled in its own.
//
// ⚠ NOT because the driver is ignorant of the struct -- measured on the STOCK
// loader, with none of this code present, the Mali r54p1 driver already answers
// VkPhysicalDeviceImageCompressionControlSwapchainFeaturesEXT with VK_TRUE. It
// is a newer driver than this platform. What it does NOT do, and cannot, is
// ADVERTISE VK_EXT_image_compression_control_swapchain -- measured on the same
// stock loader, the driver advertises VK_EXT_image_compression_control and not
// the swapchain variant -- because the swapchain half is the loader's to
// implement.
//
// So this exists to make the answer correct on its own terms rather than by
// luck: the loader owns the extension, so the loader answers its feature, and
// on this device the answer happens to agree with what the driver already said.
static void AnswerLoaderFeatures(VkPhysicalDevice physicalDevice,
                                 VkPhysicalDeviceFeatures2* pFeatures) {
    bool icc_known = false;
    bool icc_supported = false;
    for (VkBaseOutStructure* p =
             reinterpret_cast<VkBaseOutStructure*>(pFeatures->pNext);
         p != nullptr; p = p->pNext) {
        if (static_cast<uint32_t>(p->sType) !=
            kStructureTypePhysicalDeviceImageCompressionControlSwapchainFeaturesEXT)
            continue;
        if (!icc_known) {
            icc_supported = DriverSupportsImageCompressionControl(physicalDevice);
            icc_known = true;
        }
        reinterpret_cast<VkPhysicalDeviceImageCompressionControlSwapchainFeaturesEXT*>(
            p)->imageCompressionControlSwapchain =
            icc_supported ? VK_TRUE : VK_FALSE;
    }
}


RS43_DRV_FEAT
  cat > "$VKDIR/.rs43_hdr" <<'RS43_HDR'

// ---- VK_EXT_image_compression_control_swapchain (device extension, no entry points)
//
// The BASE extension VK_EXT_image_compression_control is the DRIVER's (Mali
// r54p1 exports it). This one only extends it to swapchains, which is loader
// territory because the loader is what creates swapchain images.
#define RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_EXTENSION_NAME \
    "VK_EXT_image_compression_control_swapchain"
#define RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_SPEC_VERSION 1

constexpr uint32_t kStructureTypePhysicalDeviceImageCompressionControlFeaturesEXT = 1000338000u;
constexpr uint32_t kStructureTypeImageCompressionControlEXT = 1000338001u;
constexpr uint32_t kStructureTypeImageCompressionPropertiesEXT = 1000338004u;
constexpr uint32_t kStructureTypePhysicalDeviceImageCompressionControlSwapchainFeaturesEXT =
    1000437000u;

typedef VkFlags VkImageCompressionFlagsEXT;
typedef VkFlags VkImageCompressionFixedRateFlagsEXT;

constexpr VkImageCompressionFlagsEXT kImageCompressionDefaultEXT = 0x00000000u;
constexpr VkImageCompressionFlagsEXT kImageCompressionFixedRateDefaultEXT = 0x00000001u;

struct VkPhysicalDeviceImageCompressionControlFeaturesEXT {
    VkStructureType sType;
    void* pNext;
    VkBool32 imageCompressionControl;
};

struct VkPhysicalDeviceImageCompressionControlSwapchainFeaturesEXT {
    VkStructureType sType;
    void* pNext;
    VkBool32 imageCompressionControlSwapchain;
};

struct VkImageCompressionControlEXT {
    VkStructureType sType;
    const void* pNext;
    VkImageCompressionFlagsEXT flags;
    uint32_t compressionControlPlaneCount;
    VkImageCompressionFixedRateFlagsEXT* pFixedRateFlags;
};

struct VkImageCompressionPropertiesEXT {
    VkStructureType sType;
    void* pNext;
    VkImageCompressionFlagsEXT imageCompressionFlags;
    VkImageCompressionFixedRateFlagsEXT imageCompressionFixedRateFlags;
};

#endif  // VULKAN_LIBVULKAN_EXT_BACKPORT_H

RS43_HDR
  python3 - "$VKDIR" <<'PYCOMP'
import sys
V = sys.argv[1] + '/'

def part(name):
    # Each blob was written with ONE extra trailing newline so the heredoc
    # delimiter could sit on its own line. Strip exactly that one back off.
    with open(V + '.rs43_' + name) as f:
        return f.read()[:-1]

h = open(V + 'ext_backport.h').read()
if 'RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_EXTENSION_NAME' not in h:
    end = '\n#endif  // VULKAN_LIBVULKAN_EXT_BACKPORT_H\n'
    if h.count(end) != 1:
        sys.exit('ext_backport.h: no include guard end to append before')
    open(V + 'ext_backport.h', 'w').write(h.replace(end, part('hdr')))

s = open(V + 'swapchain.cpp').read()
a = ('        mutable_format_image_flags = VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT |\n'
     '                                     VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;\n'
     '    }\n')
if s.count(a) != 1:
    sys.exit('swapchain.cpp anchor A count %d (step 45 must run first)' % s.count(a))
s = s.replace(a, a + part('swap_a'), 1)

b = ('    if (swapchain_image_format_list != nullptr)\n'
     '        swapchain_image_create.pNext = swapchain_image_format_list;\n')
if s.count(b) != 1:
    sys.exit('swapchain.cpp anchor B count %d' % s.count(b))
s = s.replace(b, b + part('swap_b'), 1)

c = ('        if (result == VK_SUCCESS || result == VK_INCOMPLETE) {\n'
     '            // marshal results individually due to stride difference.\n'
     '            // completely ignore any chained extension structs.\n'
     '            uint32_t formats_to_marshal = *pSurfaceFormatCount;\n'
     '            for (uint32_t i = 0u; i < formats_to_marshal; i++) {\n'
     '                pSurfaceFormats[i].surfaceFormat = surface_formats[i];\n'
     '            }\n'
     '        }')
if s.count(c) != 1:
    sys.exit('swapchain.cpp anchor C count %d' % s.count(c))
s = s.replace(c, part('swap_c'), 1)
open(V + 'swapchain.cpp', 'w').write(s)

d = open(V + 'driver.cpp').read()
e = 'VkResult EnumerateDeviceExtensionProperties(\n'
if d.count(e) != 1:
    sys.exit('driver.cpp helper anchor count %d' % d.count(e))
d = d.replace(e, part('drv_helper') + e, 1)

f = ('    VkPhysicalDevicePresentationPropertiesANDROID presentation_properties;\n'
     '    QueryPresentationProperties(physicalDevice, &presentation_properties);')
if d.count(f) != 1:
    sys.exit('driver.cpp advertise anchor count %d' % d.count(f))
d = d.replace(f, part('drv_adv') + f, 1)

g = 'void GetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,\n'
if d.count(g) != 1:
    sys.exit('driver.cpp features anchor count %d' % d.count(g))
d = d.replace(g, part('drv_feat') + g, 1)

g2 = '        driver.GetPhysicalDeviceFeatures2(physicalDevice, pFeatures);\n        return;'
if d.count(g2) != 1:
    sys.exit('driver.cpp features2 body anchor count %d' % d.count(g2))
d = d.replace(g2,
              '        driver.GetPhysicalDeviceFeatures2(physicalDevice, pFeatures);\n'
              '        AnswerLoaderFeatures(physicalDevice, pFeatures);\n        return;', 1)

g3 = '    driver.GetPhysicalDeviceFeatures2KHR(physicalDevice, pFeatures);\n'
if d.count(g3) != 1:
    sys.exit('driver.cpp features2KHR anchor count %d' % d.count(g3))
d = d.replace(g3, g3 + '    AnswerLoaderFeatures(physicalDevice, pFeatures);\n', 1)
open(V + 'driver.cpp', 'w').write(d)
PYCOMP
  rc=$?
  rm -f "$VKDIR"/.rs43_*
  [ $rc -eq 0 ] || { echo "   *** FATAL: image_compression_control_swapchain patch failed"; exit 1; }
  grep -q 'kStructureTypeImageCompressionPropertiesEXT' "$VKDIR/swapchain.cpp" \
    || { echo "   *** FATAL: the properties answer never landed -- the extension"; \
         echo "             would accept a request and never report the result"; exit 1; }
  grep -q 'have_compression_control' "$VKDIR/swapchain.cpp" \
    || { echo "   *** FATAL: the control never reaches vkCreateImage"; exit 1; }
  grep -q 'AnswerLoaderFeatures' "$VKDIR/driver.cpp" \
    || { echo "   *** FATAL: the feature is never answered"; exit 1; }
  grep -q 'DriverSupportsImageCompressionControl' "$VKDIR/driver.cpp" \
    || { echo "   *** FATAL: never advertised"; exit 1; }
  # ⚠ Match the old CODE COMMENT exactly -- 12 spaces then the bare line. A
  # loose grep for the phrase is a false positive, because the replacement text
  # QUOTES that comment while explaining why it is gone. It fired once.
  if grep -qE '^            // completely ignore any chained extension structs\.$' \
       "$VKDIR/swapchain.cpp"; then
    echo "   *** FATAL: control -- the discard-everything path is still there, so"
    echo "             anchor C did not actually replace it"; exit 1
  fi
  echo "   patched (feature answered, properties answered, control forwarded)"
fi

# ---------------------------------------------------------------------------
# STEP 48 -- VK_EXT_swapchain_maintenance1. The last of the four, and the only
# one that adds an ENTRY POINT.
#
# 148/14 -- the donor's numbers, reached. Steps 45-47 got 145/13 to 147/14; this
# is the last device extension.
#
# WHY THIS ONE IS A PATCH FILE AND NOT ANCHORED PYTHON LIKE 45-47
# It touches SIX files, including two GENERATED ones. A diff fails loudly and
# completely on any drift; six sets of hand-written anchors fail one at a time
# and can half-apply. `patch --forward` also makes the idempotency check honest.
#
# WHAT IT DOES
#   swapchain.cpp  the present FENCE: dup the release fd out of
#                  QueueSignalReleaseImageANDROID and import it into the app's
#                  VkFence as a TEMPORARY SYNC_FD -- the mechanism all three A16
#                  donors use (VkImportFenceFdInfoKHR, flags 1, handleType 8,
#                  read out of their rodata). Plus vkReleaseSwapchainImagesEXT,
#                  which is ANativeWindow::cancelBuffer via the loader's own
#                  ReleaseSwapchainImage() -- no new mechanism, one entry point
#                  onto the existing one.
#   driver.cpp     advertise (gated on the driver advertising
#                  VK_KHR_external_fence_fd), report swapchainMaintenance1 TRUE
#                  unconditionally (what all three donors do), and the two
#                  exhaustive extension switches.
#   driver_gen.*   HAND-MAINTAINED ProcHook entry + Extension enum + checked
#                  wrapper. Our vk.xml predates the extension so the generator
#                  cannot emit them; scripts/driver_generator.py carries a note
#                  saying so, because a regeneration silently drops them and
#                  nothing references the function by name to catch it.
#
# 🔴 THE LINE THAT MAKES IT ACTUALLY WORK, and it is not obvious:
# FilterExtension() enables VK_KHR_external_fence_fd ON THE APP'S BEHALF. The
# present fence needs the DRIVER's vkImportFenceFdKHR, and a driver only exposes
# that when external_fence_fd is enabled on the device -- but the app asked for
# swapchain_maintenance1, not for external_fence_fd. Without that line the
# extension advertises, the device creates, vkQueuePresentKHR returns
# VK_SUCCESS, and the fence NEVER SIGNALS. That is not a guess; it is what the
# first build did, and the log said so:
#     E vulkan: VK_EXT_swapchain_maintenance1: no vkImportFenceFdKHR, the
#               present fence cannot be signalled
#     vkWaitForFences(present fence, 2s) = 2   (VK_TIMEOUT)
#
# ⚠ VkSwapchainPresentModeInfoEXT is parsed and deliberately IGNORED. Step 46
# reports every present mode as compatible only with itself, so there is no
# legal mode to switch to without recreating the swapchain; honouring it would
# claim a capability the compatibility query denies. All three donors parse it
# the same way.
#
# PROVEN ON HARDWARE 2026-09-08, with a negative control:
#   patched    device_ext_count 148, instance 14
#              swapchainMaintenance1 1
#              vkGetDeviceProcAddr(vkReleaseSwapchainImagesEXT) non-null
#              vkReleaseSwapchainImagesEXT(acquired image) 0
#              present fence: unsignalled -> vkQueuePresentKHR 0 ->
#                vkWaitForFences 0 (VK_SUCCESS) -> signalled
#   unpatched  145/13 - vkCreateDevice(+ext) -7 - and the feature sentinel
#              0xEE survives UNTOUCHED, so the stock loader demonstrably does
#              not answer it (unlike step 47's, which the driver answers)
# Test binary: device_itel_S666LN/tools/vksm1.c
echo "== step 48: libvulkan VK_EXT_swapchain_maintenance1 =="
VKDIR="$TREE/frameworks/native/vulkan"
if [ ! -d "$VKDIR/libvulkan" ]; then
  echo "   *** FATAL: $VKDIR/libvulkan not found"; exit 1
elif grep -q 'EXT_swapchain_maintenance1' "$VKDIR/libvulkan/driver_gen.h" 2>/dev/null; then
  echo "   already patched"
else
  cat > "$TREE/.rs48.patch" <<'RS48_PATCH'
--- a/frameworks/native/vulkan/libvulkan/ext_backport.h
+++ b/frameworks/native/vulkan/libvulkan/ext_backport.h
@@ -116,4 +116,46 @@
     VkImageCompressionFixedRateFlagsEXT imageCompressionFixedRateFlags;
 };
 
+// ---- VK_EXT_swapchain_maintenance1 (device extension, ONE entry point)
+//
+// The only one of the four that adds a function, which is why it is last: the
+// ProcHook table in driver_gen.{h,cpp} is GENERATED, and our vk.xml predates
+// this extension, so those two entries are hand-maintained. See the note in
+// scripts/driver_generator.py.
+#define RS4_VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME "VK_EXT_swapchain_maintenance1"
+#define RS4_VK_EXT_SWAPCHAIN_MAINTENANCE_1_SPEC_VERSION 1
+
+constexpr uint32_t kStructureTypePhysicalDeviceSwapchainMaintenance1FeaturesEXT = 1000275000u;
+constexpr uint32_t kStructureTypeSwapchainPresentFenceInfoEXT = 1000275001u;
+constexpr uint32_t kStructureTypeSwapchainPresentModeInfoEXT = 1000275003u;
+constexpr uint32_t kStructureTypeReleaseSwapchainImagesInfoEXT = 1000275005u;
+
+struct VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT {
+    VkStructureType sType;
+    void* pNext;
+    VkBool32 swapchainMaintenance1;
+};
+
+struct VkSwapchainPresentFenceInfoEXT {
+    VkStructureType sType;
+    const void* pNext;
+    uint32_t swapchainCount;
+    const VkFence* pFences;
+};
+
+struct VkSwapchainPresentModeInfoEXT {
+    VkStructureType sType;
+    const void* pNext;
+    uint32_t swapchainCount;
+    const VkPresentModeKHR* pPresentModes;
+};
+
+struct VkReleaseSwapchainImagesInfoEXT {
+    VkStructureType sType;
+    const void* pNext;
+    VkSwapchainKHR swapchain;
+    uint32_t imageIndexCount;
+    const uint32_t* pImageIndices;
+};
+
 #endif  // VULKAN_LIBVULKAN_EXT_BACKPORT_H
--- a/frameworks/native/vulkan/libvulkan/swapchain.h
+++ b/frameworks/native/vulkan/libvulkan/swapchain.h
@@ -18,6 +18,7 @@
 #define LIBVULKAN_SWAPCHAIN_H 1
 
 #include <vulkan/vulkan.h>
+#include "ext_backport.h"
 
 namespace vulkan {
 namespace driver {
@@ -46,6 +47,7 @@
 VKAPI_ATTR VkResult GetPhysicalDeviceSurfaceFormats2KHR(VkPhysicalDevice physicalDevice, const VkPhysicalDeviceSurfaceInfo2KHR* pSurfaceInfo, uint32_t* pSurfaceFormatCount, VkSurfaceFormat2KHR* pSurfaceFormats);
 VKAPI_ATTR VkResult BindImageMemory2(VkDevice device, uint32_t bindInfoCount, const VkBindImageMemoryInfo* pBindInfos);
 VKAPI_ATTR VkResult BindImageMemory2KHR(VkDevice device, uint32_t bindInfoCount, const VkBindImageMemoryInfo* pBindInfos);
+VKAPI_ATTR VkResult ReleaseSwapchainImagesEXT(VkDevice device, const VkReleaseSwapchainImagesInfoEXT* pReleaseInfo);
 // clang-format on
 
 }  // namespace driver
--- a/frameworks/native/vulkan/libvulkan/swapchain.cpp
+++ b/frameworks/native/vulkan/libvulkan/swapchain.cpp
@@ -1938,6 +1938,57 @@
 }
 
 VKAPI_ATTR
+// VK_EXT_swapchain_maintenance1: give acquired-but-not-presented images back
+// to the swapchain without presenting them.
+//
+// On Android that is exactly ANativeWindow::cancelBuffer, which the loader
+// already does in ReleaseSwapchainImage() -- the same call the error paths of
+// CreateSwapchainKHR and AcquireNextImage use. This adds no new mechanism, only
+// an entry point onto the existing one.
+//
+// The spec requires every listed index to be an ACQUIRED image
+// (VUID-VkReleaseSwapchainImagesInfoEXT-pImageIndices-07785). We check rather
+// than trust: releasing an image that was never dequeued would cancel a buffer
+// the compositor owns.
+VKAPI_ATTR VkResult ReleaseSwapchainImagesEXT(
+    VkDevice device,
+    const VkReleaseSwapchainImagesInfoEXT* pReleaseInfo) {
+    ATRACE_CALL();
+
+    if (pReleaseInfo == nullptr ||
+        pReleaseInfo->swapchain == VK_NULL_HANDLE)
+        return VK_ERROR_INITIALIZATION_FAILED;
+
+    Swapchain& swapchain = *SwapchainFromHandle(pReleaseInfo->swapchain);
+    ANativeWindow* window =
+        swapchain.surface.swapchain_handle == pReleaseInfo->swapchain
+            ? swapchain.surface.window.get()
+            : nullptr;
+
+    for (uint32_t i = 0; i < pReleaseInfo->imageIndexCount; i++) {
+        const uint32_t index = pReleaseInfo->pImageIndices[i];
+        if (index >= swapchain.num_images) {
+            ALOGE("vkReleaseSwapchainImagesEXT: image index %u out of range",
+                  index);
+            return VK_ERROR_INITIALIZATION_FAILED;
+        }
+        if (!swapchain.images[index].dequeued) {
+            ALOGE(
+                "vkReleaseSwapchainImagesEXT: image %u is not acquired, "
+                "refusing to cancel a buffer we do not hold",
+                index);
+            return VK_ERROR_INITIALIZATION_FAILED;
+        }
+    }
+
+    for (uint32_t i = 0; i < pReleaseInfo->imageIndexCount; i++) {
+        ReleaseSwapchainImage(device, swapchain.shared, window, -1,
+                              swapchain.images[pReleaseInfo->pImageIndices[i]],
+                              false);
+    }
+    return VK_SUCCESS;
+}
+
 VkResult QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* present_info) {
     ATRACE_CALL();
 
@@ -1952,6 +2003,8 @@
     // Look at the pNext chain for supported extension structs:
     const VkPresentRegionsKHR* present_regions = nullptr;
     const VkPresentTimesInfoGOOGLE* present_times = nullptr;
+    // VK_EXT_swapchain_maintenance1
+    const VkSwapchainPresentFenceInfoEXT* present_fences = nullptr;
     const VkPresentRegionsKHR* next =
         reinterpret_cast<const VkPresentRegionsKHR*>(present_info->pNext);
     while (next) {
@@ -1964,6 +2017,26 @@
                     reinterpret_cast<const VkPresentTimesInfoGOOGLE*>(next);
                 break;
             default:
+                // VK_EXT_swapchain_maintenance1. Handled here rather than as a
+                // case label because this tree's VkStructureType does not
+                // contain these values.
+                if (static_cast<uint32_t>(next->sType) ==
+                    kStructureTypeSwapchainPresentFenceInfoEXT) {
+                    present_fences =
+                        reinterpret_cast<const VkSwapchainPresentFenceInfoEXT*>(
+                            next);
+                    break;
+                }
+                if (static_cast<uint32_t>(next->sType) ==
+                    kStructureTypeSwapchainPresentModeInfoEXT) {
+                    // Accepted and ignored, deliberately. Step 46 reports every
+                    // present mode as compatible only with itself, so there is
+                    // never a legal mode to switch TO without recreating the
+                    // swapchain, and honouring this struct would mean claiming
+                    // a capability the compatibility query denies. All three A16
+                    // donors parse it out of the chain the same way.
+                    break;
+                }
                 ALOGV("QueuePresentKHR ignoring unrecognized pNext->sType = %x",
                       next->sType);
                 break;
@@ -2010,6 +2083,40 @@
             close(img.release_fence);
         img.release_fence = fence < 0 ? -1 : dup(fence);
 
+        // VK_EXT_swapchain_maintenance1: hand the app a fence that signals when
+        // this presented image is released. The mechanism is not invented --
+        // all three A16 donors do exactly this: dup the release fd out of
+        // QueueSignalReleaseImageANDROID and import it into the app's VkFence
+        // as a TEMPORARY SYNC_FD. On success the driver owns the fd; on failure
+        // we still own it and must close it.
+        if (present_fences != nullptr && sc < present_fences->swapchainCount &&
+            present_fences->pFences[sc] != VK_NULL_HANDLE) {
+            PFN_vkImportFenceFdKHR import_fence_fd =
+                reinterpret_cast<PFN_vkImportFenceFdKHR>(
+                    GetData(device).driver.GetDeviceProcAddr(
+                        device, "vkImportFenceFdKHR"));
+            if (import_fence_fd != nullptr) {
+                int import_fd = (fence >= 0) ? dup(fence) : -1;
+                VkImportFenceFdInfoKHR import_info = {};
+                import_info.sType = VK_STRUCTURE_TYPE_IMPORT_FENCE_FD_INFO_KHR;
+                import_info.pNext = nullptr;
+                import_info.fence = present_fences->pFences[sc];
+                import_info.flags = VK_FENCE_IMPORT_TEMPORARY_BIT;
+                import_info.handleType =
+                    VK_EXTERNAL_FENCE_HANDLE_TYPE_SYNC_FD_BIT;
+                import_info.fd = import_fd;
+                if (import_fence_fd(device, &import_info) != VK_SUCCESS) {
+                    ALOGE("vkImportFenceFdKHR for the present fence failed");
+                    if (import_fd >= 0)
+                        close(import_fd);
+                }
+            } else {
+                ALOGE(
+                    "VK_EXT_swapchain_maintenance1: no vkImportFenceFdKHR, the "
+                    "present fence cannot be signalled");
+            }
+        }
+
         if (swapchain.surface.swapchain_handle ==
             present_info->pSwapchains[sc]) {
             ANativeWindow* window = swapchain.surface.window.get();
--- a/frameworks/native/vulkan/libvulkan/driver.cpp
+++ b/frameworks/native/vulkan/libvulkan/driver.cpp
@@ -657,6 +657,7 @@
             case ProcHook::KHR_incremental_present:
             case ProcHook::KHR_shared_presentable_image:
             case ProcHook::KHR_swapchain:
+            case ProcHook::EXT_swapchain_maintenance1:
             case ProcHook::EXT_hdr_metadata:
             case ProcHook::ANDROID_external_memory_android_hardware_buffer:
             case ProcHook::ANDROID_native_buffer:
@@ -693,8 +694,32 @@
             case ProcHook::KHR_incremental_present:
             case ProcHook::GOOGLE_display_timing:
             case ProcHook::KHR_shared_presentable_image:
+            // VK_EXT_swapchain_maintenance1 is implemented entirely in the
+            // loader (the present fence and vkReleaseSwapchainImagesEXT), so
+            // like the three above it must NOT be forwarded to a driver that
+            // has never heard of it.
+            case ProcHook::EXT_swapchain_maintenance1:
+                // 🔴 It needs no HAL support of its OWN, but its present fence
+                // is delivered by importing the ANativeWindow release fd into
+                // the app's VkFence -- so the DRIVER must expose
+                // vkImportFenceFdKHR, and a driver only exposes that if
+                // VK_KHR_external_fence_fd was ENABLED on the device. The app
+                // asked for swapchain_maintenance1, not for external_fence_fd,
+                // so the loader enables it on the app's behalf.
+                //
+                // Without this the extension advertises, the device creates,
+                // vkQueuePresentKHR returns VK_SUCCESS -- and the fence is
+                // never signalled. Measured exactly that way before this line
+                // existed: "no vkImportFenceFdKHR, the present fence cannot be
+                // signalled", vkWaitForFences -> VK_TIMEOUT.
+                //
+                // The recursive call is safe: external_fence_fd maps to
+                // EXTENSION_UNKNOWN, which breaks out to the append loop below
+                // and does not re-enter this switch. The loop's own duplicate
+                // check handles an app that asked for both.
+                FilterExtension(VK_KHR_EXTERNAL_FENCE_FD_EXTENSION_NAME);
                 hook_extensions_.set(ext_bit);
-                // return now as these extensions do not require HAL support
+                // return now as this extension itself requires no HAL support
                 return;
             case ProcHook::EXT_hdr_metadata:
             case ProcHook::KHR_bind_memory2:
@@ -1074,6 +1099,35 @@
     return icc.imageCompressionControl == VK_TRUE;
 }
 
+// VK_EXT_swapchain_maintenance1's present fence is delivered by importing the
+// ANativeWindow release fd into the app's VkFence, so the whole extension rests
+// on the driver having vkImportFenceFdKHR. Gate on the driver actually
+// advertising VK_KHR_external_fence_fd rather than assuming: advertising an
+// extension whose one real mechanism is missing is the trap this whole series
+// has been avoiding. Mali r54p1 here does advertise it.
+static bool DriverSupportsExternalFenceFd(VkPhysicalDevice physicalDevice) {
+    const InstanceData& data = GetData(physicalDevice);
+    if (!data.driver.EnumerateDeviceExtensionProperties)
+        return false;
+
+    uint32_t count = 0;
+    if (data.driver.EnumerateDeviceExtensionProperties(
+            physicalDevice, nullptr, &count, nullptr) != VK_SUCCESS ||
+        count == 0)
+        return false;
+
+    std::vector<VkExtensionProperties> props(count);
+    if (data.driver.EnumerateDeviceExtensionProperties(
+            physicalDevice, nullptr, &count, props.data()) != VK_SUCCESS)
+        return false;
+
+    for (const auto& p : props) {
+        if (strcmp(p.extensionName, VK_KHR_EXTERNAL_FENCE_FD_EXTENSION_NAME) == 0)
+            return true;
+    }
+    return false;
+}
+
 VkResult EnumerateDeviceExtensionProperties(
     VkPhysicalDevice physicalDevice,
     const char* pLayerName,
@@ -1119,6 +1173,14 @@
              RS4_VK_EXT_IMAGE_COMPRESSION_CONTROL_SWAPCHAIN_SPEC_VERSION});
     }
 
+    // VK_EXT_swapchain_maintenance1 -- implemented by the loader
+    // (swapchain.cpp: the present fence and vkReleaseSwapchainImagesEXT).
+    if (DriverSupportsExternalFenceFd(physicalDevice)) {
+        loader_extensions.push_back(
+            {RS4_VK_EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME,
+             RS4_VK_EXT_SWAPCHAIN_MAINTENANCE_1_SPEC_VERSION});
+    }
+
     VkPhysicalDevicePresentationPropertiesANDROID presentation_properties;
     QueryPresentationProperties(physicalDevice, &presentation_properties);
     if (presentation_properties.sharedImage) {
@@ -1539,6 +1601,21 @@
             p)->imageCompressionControlSwapchain =
             icc_supported ? VK_TRUE : VK_FALSE;
     }
+
+    // VK_EXT_swapchain_maintenance1 -- unconditionally TRUE, which is what all
+    // three A16 donors do (a bare `str w13, [x14,#16]` with w13 = 1, no query).
+    // The loader implements the whole extension, so there is nothing to ask the
+    // driver about; whether it is USABLE is decided when the extension is
+    // advertised, above.
+    for (VkBaseOutStructure* p =
+             reinterpret_cast<VkBaseOutStructure*>(pFeatures->pNext);
+         p != nullptr; p = p->pNext) {
+        if (static_cast<uint32_t>(p->sType) ==
+            kStructureTypePhysicalDeviceSwapchainMaintenance1FeaturesEXT) {
+            reinterpret_cast<VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT*>(
+                p)->swapchainMaintenance1 = VK_TRUE;
+        }
+    }
 }
 
 void GetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
--- a/frameworks/native/vulkan/libvulkan/driver_gen.h
+++ b/frameworks/native/vulkan/libvulkan/driver_gen.h
@@ -49,6 +49,8 @@
         KHR_surface,
         KHR_surface_protected_capabilities,
         KHR_swapchain,
+        // HAND-ADDED (not generated): see scripts/driver_generator.py.
+        EXT_swapchain_maintenance1,
         ANDROID_external_memory_android_hardware_buffer,
         KHR_bind_memory2,
         KHR_get_physical_device_properties2,
--- a/frameworks/native/vulkan/libvulkan/driver_gen.cpp
+++ b/frameworks/native/vulkan/libvulkan/driver_gen.cpp
@@ -22,6 +22,7 @@
 #include <algorithm>
 
 #include "driver.h"
+#include "ext_backport.h"
 
 namespace vulkan {
 namespace driver {
@@ -65,6 +66,18 @@
     }
 }
 
+// HAND-ADDED (not generated): VK_EXT_swapchain_maintenance1. Our vk.xml
+// predates the extension, so the generator cannot emit this. See
+// scripts/driver_generator.py.
+VKAPI_ATTR VkResult checkedReleaseSwapchainImagesEXT(VkDevice device, const VkReleaseSwapchainImagesInfoEXT* pReleaseInfo) {
+    if (GetData(device).hook_extensions[ProcHook::EXT_swapchain_maintenance1]) {
+        return ReleaseSwapchainImagesEXT(device, pReleaseInfo);
+    } else {
+        Logger(device).Err(device, "VK_EXT_swapchain_maintenance1 not enabled. vkReleaseSwapchainImagesEXT not executed.");
+        return VK_SUCCESS;
+    }
+}
+
 VKAPI_ATTR VkResult checkedQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo) {
     if (GetData(queue).hook_extensions[ProcHook::KHR_swapchain]) {
         return QueuePresentKHR(queue, pPresentInfo);
@@ -538,6 +551,13 @@
         nullptr,
     },
     {
+        "vkReleaseSwapchainImagesEXT",
+        ProcHook::DEVICE,
+        ProcHook::EXT_swapchain_maintenance1,
+        reinterpret_cast<PFN_vkVoidFunction>(ReleaseSwapchainImagesEXT),
+        reinterpret_cast<PFN_vkVoidFunction>(checkedReleaseSwapchainImagesEXT),
+    },
+    {
         "vkSetHdrMetadataEXT",
         ProcHook::DEVICE,
         ProcHook::EXT_hdr_metadata,
@@ -573,6 +593,7 @@
     if (strcmp(name, "VK_KHR_surface") == 0) return ProcHook::KHR_surface;
     if (strcmp(name, "VK_KHR_surface_protected_capabilities") == 0) return ProcHook::KHR_surface_protected_capabilities;
     if (strcmp(name, "VK_KHR_swapchain") == 0) return ProcHook::KHR_swapchain;
+    if (strcmp(name, "VK_EXT_swapchain_maintenance1") == 0) return ProcHook::EXT_swapchain_maintenance1;  // HAND-ADDED
     if (strcmp(name, "VK_ANDROID_external_memory_android_hardware_buffer") == 0) return ProcHook::ANDROID_external_memory_android_hardware_buffer;
     if (strcmp(name, "VK_KHR_bind_memory2") == 0) return ProcHook::KHR_bind_memory2;
     if (strcmp(name, "VK_KHR_get_physical_device_properties2") == 0) return ProcHook::KHR_get_physical_device_properties2;
--- a/frameworks/native/vulkan/scripts/driver_generator.py
+++ b/frameworks/native/vulkan/scripts/driver_generator.py
@@ -35,6 +35,16 @@
     'VK_KHR_surface',
     'VK_KHR_surface_protected_capabilities',
     'VK_KHR_swapchain',
+    # 🔴 VK_EXT_swapchain_maintenance1 is NOT in this list and cannot be: the
+    # vk.xml this generator reads predates it, so there is no signature for
+    # vkReleaseSwapchainImagesEXT to emit. Its ProcHook entry, its Extension
+    # enum value and its checked wrapper are HAND-MAINTAINED in driver_gen.h and
+    # driver_gen.cpp, marked HAND-ADDED at each site.
+    #
+    # If you regenerate these files, those three edits are lost and
+    # vkGetDeviceProcAddr stops returning vkReleaseSwapchainImagesEXT -- with no
+    # build error, because nothing references it by name. Re-apply them, or bump
+    # the registry first and add the extension here properly.
 ]
 
 # Extensions known to vulkan::driver level.
RS48_PATCH
  ( cd "$TREE" && patch -p1 --forward --no-backup-if-mismatch < .rs48.patch > /dev/null )
  rc=$?
  rm -f "$TREE/.rs48.patch"
  [ $rc -eq 0 ] || { echo "   *** FATAL: swapchain_maintenance1 patch did not apply"; exit 1; }
  grep -q 'EXT_swapchain_maintenance1' "$VKDIR/libvulkan/driver_gen.h" \
    || { echo "   *** FATAL: the ProcHook enum value never landed"; exit 1; }
  grep -q 'vkReleaseSwapchainImagesEXT' "$VKDIR/libvulkan/driver_gen.cpp" \
    || { echo "   *** FATAL: the entry point is not in the hook table, so"; \
         echo "             vkGetDeviceProcAddr will never return it"; exit 1; }
  grep -q 'VK_KHR_EXTERNAL_FENCE_FD_EXTENSION_NAME' "$VKDIR/libvulkan/driver.cpp" \
    || { echo "   *** FATAL: external_fence_fd is not enabled for the driver --"; \
         echo "             the present fence would never signal"; exit 1; }
  # The hook table is binary-searched with std::lower_bound. An out-of-order
  # entry is not a build error and not a crash -- vkGetDeviceProcAddr just
  # returns null for a name that is right there. It happened once.
  python3 - "$VKDIR/libvulkan/driver_gen.cpp" <<'RS48_SORT'
import re, sys
c = open(sys.argv[1]).read()
i = c.index('g_proc_hooks[] = {'); j = c.index('\n};', i)
names = re.findall(r'^\s+"(vk[A-Za-z0-9]+)",$', c[i:j], re.M)
bad = [(a, b) for a, b in zip(names, names[1:]) if a >= b]
if bad:
    sys.exit('g_proc_hooks is NOT sorted: %s' % bad[:3])
if 'vkReleaseSwapchainImagesEXT' not in names:
    sys.exit('vkReleaseSwapchainImagesEXT missing from g_proc_hooks')
RS48_SORT
  [ $? -eq 0 ] || { echo "   *** FATAL: hook table order/content control failed"; exit 1; }
  echo "   patched (present fence, release entry point, hook table sorted)"
fi

echo "===================================================================="
