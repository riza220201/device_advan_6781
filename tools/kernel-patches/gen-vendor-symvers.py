#!/usr/bin/env python3
"""gen-vendor-symvers.py -- build the module-only symvers for the kbase build.

For every stock .ko, reads __ksymtab_* (proof of EXPORT_SYMBOL) and the
matching __crc_* ABS value (the export CRC), and emits KBUILD_EXTRA_SYMBOLS
rows. EXPORT-driven, deliberately: the kbase under construction needs symbols
NO stock module needs (e.g. mtk_notify_gpu_power_change -- stock's r32p1
kbase never calls it, r54p1 does), so a need-driven set derived from stock
__versions can never cover a new driver's requirements. Export CRCs equal
import CRCs by genksyms construction (same signature -> same CRC; verified:
0x06a043ba for mtk_notify_gpu_power_change, byte-identical to the RS4 file).

Two traps this already caught (2026-09-19):
  __crc_* ABS symbols are EXPORT CRCs -- a need-driven reader inverts them.
  --dyn-syms UND is empty on .ko; vmlinux symbols must be EXCLUDED here
  (modpost reads vmlinux itself; duplicates fail "exported twice").

vmlinux-provided symbols are excluded via the kernel's Module.symvers NAMES
(their CRCs come from the kernel build, never this file).

Usage: gen-vendor-symvers.py <kernel-Module.symvers> <modules-root> <out>
"""
import subprocess, glob, collections, sys

def symtab(f):
    out = subprocess.run(['readelf','-sW',f],capture_output=True,text=True).stdout.splitlines()
    crc, ksym = {}, set()
    for l in out:
        p = l.split()
        if len(p) < 8: continue
        if p[6] == 'ABS' and p[7].startswith('__crc_'):
            crc[p[7][6:]] = int(p[1], 16) & 0xFFFFFFFF
        elif p[7].startswith('__ksymtab_') and '.' not in p[7]:
            ksym.add(p[7][10:])
    return crc, ksym

ksymvers, modroot, outpath = sys.argv[1], sys.argv[2], sys.argv[3]
mods = sorted(glob.glob(modroot + '/vendor_dlkm/*.ko') + glob.glob(modroot + '/vendor_boot/*.ko'))
ksym = set()
with open(ksymvers) as f:
    for ln in f:
        p = ln.split('\t')
        if len(p) >= 2: ksym.add(p[1].strip())
rows = {}
for m in mods:
    base = m.split('/')[-1]
    crc, ksyms = symtab(m)
    for s in ksyms:
        if s in ksym or s == 'module_layout': continue
        if s in crc:
            rows[s] = (crc[s], base)
n = 0
with open(outpath, 'w') as f:
    for s in sorted(rows):
        crc, e = rows[s]
        f.write('0x%08x\t%s\t%s\tEXPORT_SYMBOL\t\n' % (crc, s, e)); n += 1
print('modules: %d exported-with-crc: %d wrote: %d' % (len(mods), len(rows), n))
