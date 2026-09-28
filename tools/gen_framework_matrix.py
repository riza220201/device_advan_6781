#!/usr/bin/env python3
"""Generate configs/vintf/framework_compatibility_matrix.xml from the device
manifest, instead of from a failed build.

With PRODUCT_ENFORCE_VINTF_MANIFEST=true, check_vintf rejects every instance
in the device manifest that no framework matrix mentions -- at "Package OTA",
99% into a full build. The S666LN tree built its matrix from that failure
list. The same question can be answered before the build: which device
instances does no platform framework matrix at the device's target-level (or
later) cover? Every one of them gets an optional="true" entry here. The real
check_vintf at the end of the build remains the verifier.

Coverage rule (mirrors libvintf's unused-HAL check, which also accepts an
instance when a CHILD interface is in the matrix): an instance is covered if
a platform matrix lists the same package, interface and instance at the same
or a NEWER version of that package. For AOSP packages a newer same-named
interface extends the older one (radio 1.6 IRadio <- 1.2, thermal 2.0 <- 1.0,
gnss 2.x <- 1.1, boot 1.2 <- 1.0). Cross-checked on 2026-09-29 against the
S666LN matrix, which came from a real check_vintf list on the same MediaTek
BSP: identical treatment of every package both devices declare.

usage: gen_framework_matrix.py <tree> <android-root>
"""
import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

TREE, TOP = sys.argv[1], sys.argv[2]
VINTF = os.path.join(TREE, "configs/vintf")
OUT = os.path.join(VINTF, "framework_compatibility_matrix.xml")
MATRICES = os.path.join(TOP, "hardware/interfaces/compatibility_matrices")


def ver_key(v):
    return tuple(int(x) for x in v.split("."))


def device_instances():
    files = [os.path.join(VINTF, "manifest.xml")] + sorted(
        glob.glob(os.path.join(VINTF, "manifest/*.xml")))
    level = None
    out = set()
    for f in files:
        root = ET.parse(f).getroot()
        level = level or root.get("target-level")
        for h in root.iter("hal"):
            fmt = h.get("format", "hidl")
            name = h.findtext("name").strip()
            vers = [v.text.strip() for v in h.findall("version")]
            if fmt == "aidl" and not vers:
                vers = ["1"]
            for itf in h.findall("interface"):
                iname = itf.findtext("name").strip()
                for inst in itf.findall("instance"):
                    for v in vers:
                        out.add((fmt, name, v, iname, inst.text.strip()))
            for fq in h.findall("fqname"):
                t = fq.text.strip()
                if "::" in t:
                    v, rest = t.lstrip("@").split("::", 1)
                    iname, inst = rest.split("/", 1)
                    out.add((fmt, name, v, iname, inst))
                else:
                    iname, inst = t.split("/", 1)
                    for v in vers:
                        out.add((fmt, name, v, iname, inst))
    return int(level), out


def platform_matrices(level):
    mats = []
    for p in sorted(glob.glob(os.path.join(MATRICES, "compatibility_matrix.*.xml"))):
        tag = p.rsplit(".", 2)[-2]
        if tag == "current" or (tag.isdigit() and int(tag) >= level):
            mats.append(ET.parse(p).getroot())
    return mats


def covered(inst, mats):
    fmt, name, ver, iname, instname = inst
    for m in mats:
        for h in m.iter("hal"):
            if h.findtext("name", "").strip() != name or h.get("format", "hidl") != fmt:
                continue
            ok = fmt == "aidl" and not h.findall("version")
            for vr in h.findall("version"):
                t = vr.text.strip()
                if fmt == "aidl":
                    lo, hi = (t.split("-") + [t])[:2]
                    ok |= int(lo) <= int(ver) <= int(hi)
                else:
                    maj, rng = t.split(".")
                    hi = rng.split("-")[-1]
                    # same-or-newer: the matrix names this interface at a
                    # version that extends (or equals) the device's
                    ok |= ver_key(ver) <= ver_key("%s.%s" % (maj, hi))
            if not ok:
                continue
            for itf in h.findall("interface"):
                if itf.findtext("name", "").strip() != iname:
                    continue
                if instname in [i.text.strip() for i in itf.findall("instance")]:
                    return True
                if any(re.fullmatch(p.text.strip(), instname)
                       for p in itf.findall("regex-instance")):
                    return True
    return False


level, dev = device_instances()
mats = platform_matrices(level)
gap = sorted(i for i in dev if not covered(i, mats))

# group: (fmt, name, version) -> interface -> [instances]
groups = {}
for fmt, name, ver, iname, inst in gap:
    groups.setdefault((fmt, name, ver), {}).setdefault(iname, []).append(inst)

lines = [
    '<?xml version="1.0" encoding="utf-8"?>',
    "<!--",
    "    Device FRAMEWORK compatibility matrix: which additional HAL instances",
    "    this device is ALLOWED to advertise (not what it requires; that is",
    "    compatibility_matrix.xml). GENERATED by tools/gen_framework_matrix.py",
    "    from configs/vintf/manifest{.xml,/*.xml} against the platform matrices",
    "    at target-level %d and later; rerun it after any manifest change." % level,
    "    Everything is optional=\"true\": vendor HALs whose absence must never",
    "    make the device non-compliant. check_vintf at the end of the build is",
    "    the verifier.",
    "-->",
    '<compatibility-matrix version="2.0" type="framework">',
]
for (fmt, name, ver), itfs in sorted(groups.items()):
    lines.append('    <hal format="%s" optional="true">' % fmt)
    lines.append("        <name>%s</name>" % name)
    lines.append("        <version>%s</version>" % ver)
    for iname in sorted(itfs):
        lines.append("        <interface>")
        lines.append("            <name>%s</name>" % iname)
        for inst in sorted(itfs[iname]):
            lines.append("            <instance>%s</instance>" % inst)
        lines.append("        </interface>")
    lines.append("    </hal>")
lines.append("</compatibility-matrix>")

with open(OUT, "w") as fh:
    fh.write("\n".join(lines) + "\n")
print("wrote %s: %d device instances, %d uncovered -> %d hal entries"
      % (OUT, len(dev), len(gap), len(groups)))
