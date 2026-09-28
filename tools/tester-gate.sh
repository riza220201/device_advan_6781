#!/bin/bash
# tester-gate.sh -- run on a FLASHED Advan X1 (6781) build BEFORE it is published.
#
# WHY THIS EXISTS (and why a denial sweep is not enough): a domain missing a
# service grant fails as a NULL service handle and a Java NPE, emitting NO avc
# record at all. A zero-denial logcat sweep passed on builds that force-closed
# apps in public releases. This file is the functional test.
#
# WHO RUNS IT: community testers (this project has no live device). adb only;
# root-dependent lines degrade to SKIP with the reason printed -- a SKIP is
# information, not a pass. Report the FULL output, not a summary.
#
# Usage:  bash tester-gate.sh            # automated half, then the manual half
set -u
P() { printf '  %-26s %s\n' "$1" "$2"; }
HAVE_SU=0
adb shell 'su -c true' >/dev/null 2>&1 && HAVE_SU=1
S() { if [ "$HAVE_SU" = 1 ]; then adb shell su -c "$1" 2>/dev/null | tr -d '\r'; else echo "SKIP (needs root)"; fi; }
G() { adb shell getprop "$1" 2>/dev/null | tr -d '\r'; }

echo "=================================================================="
echo " AUTOMATED CHECKS  (root available: $HAVE_SU)"
echo "=================================================================="

echo "--- identity / build ---"
P "fingerprint"      "$(G ro.build.fingerprint)"
P "  want"           "ADVAN/ADVAN_X1/ADVAN_X1:14/UP1A.231005.007/1741067669:user/release-keys"
P "incremental"      "$(G ro.build.version.incremental)  (want 1741067669)"
P "security_patch"   "$(G ro.build.version.security_patch)"
P "vendor patch"     "$(G ro.vendor.build.security_patch)  (want 2025-02-05)"
P "marketname"       "$(G ro.product.marketname)  (want Advan X1)"
P "selinux"          "$(adb shell getenforce 2>/dev/null | tr -d '\r')  (want Enforcing)"
P "slot"             "$(G ro.boot.slot_suffix)  (record which slot this ran on)"
P "dalvik heap"      "$(adb shell 'getprop | grep dalvik.vm.heap' 2>/dev/null | tr -d '\r' | tr '\n' ' ')"

echo "--- health ---"
P "tombstones"       "$(S 'ls /data/tombstones 2>/dev/null | wc -l')  (want 0)"
P "restarting svcs"  "$(adb shell 'getprop | grep -c "init.svc.*restarting"' 2>/dev/null | tr -d '\r')  (want 0)"
P "keybox status"    "$(G vendor.tee.googlekey.status)  (want ok)"
P "goodix service"   "$(adb shell 'service list' 2>/dev/null | grep -ci goodix | tr -d '\r')  (want >=1: com.goodix.FingerprintService)"
P "remosaic"         "$(S 'vndservice list 2>/dev/null | grep -ci remosaic')  (want >=1 if the daemon runs; 0 with no daemon is INERT, not a fail)"

echo "--- kernel / features ---"
P "kernel"           "$(adb shell uname -r 2>/dev/null | tr -d '\r')  (want 5.10.x-Riza-*)"
P "policy0 gov"      "$(S 'cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor')  (want reflex)"
P "policy6 gov"      "$(S 'cat /sys/devices/system/cpu/cpufreq/policy6/scaling_governor')  (want reflex)"
P "ntsync"           "$(S 'ls -lZ /dev/ntsync' | awk '{print $1, $5}')  (want crw-rw-rw- + ntsync_device)"
P "vndk"             "$(G ro.vndk.version)  (want 33; the v31 pin works through /vendor/lib*/vndk, not this prop)"
P "modules"          "$(S 'lsmod | wc -l')  (want ~= 180+ second stage)"

echo "--- gpu ---"
P "driver"           "$(adb shell 'dumpsys SurfaceFlinger 2>/dev/null | grep GLES' 2>/dev/null | tr -d '\r' | head -n 1)"
P "vulkan ext"       "run tools/egl-config-check.sh (floor gate; needs the Advan stock baseline)"
P "egl floor"        "RECORDABLE/WINDOW_BIT counts must be >= Advan stock r32p1 -- never eyeball it"

echo "--- camera raw ---"
P "capabilities"     "$(adb shell 'dumpsys media.camera 2>/dev/null | grep -m2 -i "availableCapabilities"' 2>/dev/null | tr -d '\r')"
P "  want"           "main camera byte list includes 3 (RAW); RAW_SENSOR streams listed per camera"

echo "--- power / panel ---"
P "plug (wall)"      "$(adb shell 'dumpsys battery 2>/dev/null | grep -iE "powered|current|voltage"' 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
P "  want"           "AC powered: true on a wall charger (status:charging alone is NOT the test)"
P "density"          "$(adb shell wm density 2>/dev/null | tr -d '\r')  (want: physical measurement; 440 is a placeholder)"
P "brightness node"  "$(S 'cat /sys/class/leds/lcd-backlight/brightness')  (set brightness 255 first; panel is 12-bit class)"

echo "--- denials (logcat, NOT dmesg: auditd consumes the netlink records) ---"
n=$(adb logcat -b all -d 2>/dev/null | grep -c "avc: denied")
P "avc denials"      "$n  (0 is necessary, never sufficient)"
[ "${n:-0}" -gt 0 ] && adb logcat -b all -d 2>/dev/null | grep "avc: denied" \
  | sed -E 's/.*avc: +denied +//; s/ pid=[0-9]+//' | sort | uniq -c | sort -rn | head -10

cat <<'MANUAL'

==================================================================
 MANUAL CHECKS -- THE PART THAT ACTUALLY CATCHES REGRESSIONS
==================================================================
  Tap through ALL of these before calling a build good. A green
  indicator is not the feature: test the LAST link of each chain.

  Identity / system
    [ ] Settings > About phone shows "Advan X1"
    [ ] Play Store opens, Play Services updates
    [ ] e-KYC app of choice  (the result users actually need)

  Camera (photo AND video AND flash, each lens; a file existing is not a camera --
    open the file and check it decodes fully)
    [ ] rear photo, front photo, flash photo, video
    [ ] fingerprint enroll + unlock

  Radios (EXERCISE each; an icon is not a test)
    [ ] dual-SIM + VoLTE call + SMS
    [ ] WiFi connect + 5 GHz + 2.4 GHz hotspot (with a client joined)
    [ ] Bluetooth: pair + connect + AUDIO ACTUALLY OUT OF THE HEADSET
      (connecting then playing through the speaker is the known failure shape)
    [ ] GPS lock (real fix, not just icon)

  Power
    [ ] online charging report (see plug line above)
    [ ] offline charging: charges while powered off. A static battery image
        with no animation/percentage is EXPECTED -- that screen is drawn by
        the bootloader, not Android. Not a regression.

  GPU (20-minute sustained session, not a smoke test; check tombstones before
    and after)
    [ ] a Vulkan title renders and holds (ZZZ-class if available)
    [ ] a 32-bit title (they have never met anything but r32p1)
    [ ] camera viewfinder + capture under the shipped driver
MANUAL
