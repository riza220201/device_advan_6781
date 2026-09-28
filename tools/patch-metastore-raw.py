#!/usr/bin/env python3
"""patch-metastore-raw.py -- add RAW to android.request.availableCapabilities,
by editing OUR OWN stock libmtkcam_metastore.so, for one sensor constructor.

Method reference: PORTROM.md sections 5.4w (the 3rdparty-customer red herring
and the isolation matrix proving the metastore is the single gate) and 5.4y
(the 172-byte two-half patch on the RS4's hi5022q constructor), plus the
RS4 tool tools/portrom/patch-metastore-raw.py. This tool generalizes that
tool's PART 1 (capability flag) across same-compiler constructors: the FUNC
name is an argument, the replay block is READ from the target function
rather than hardcoded, and every instruction is asserted before a byte is
written. A wrong four bytes in a camera HAL is a crash loop, not a bug.

Advan status (measured 2026-09-19 against stock
ADVAN_6781_S34NF2_V4.0_20250304 weight -- tag 0x000c000c pushes per
PLATFORM_PROJECT constructor):

  IMX782_MIPI_RAW         0,1,2,5,3,6,9   RAW PRESENT -- do NOT run this tool
  GC32E1SUB_MIPI_RAW      0,1,2,5,6       needs the patch
  BF2257CSMACRO_MIPI_RAW  0,1,2,5,6       needs the patch
  GC08A3SUB2LANE_MIPI_RAW 0,1,2,5,6       needs the patch

THE EDIT (part 1 only -- the capability flag)
=============================================
The function builds tag 0x000c000c one push_back at a time, calls
IMetadata::update(), then `cbz w0, <exit>` where w0==0 means success and the
exit is preceded by a dead error-reporting region (reached only when update
fails). The tool:

  1. nop's the cbz (always fall through into the cave),
  2. replays the push-6/tag/update block inside the cave with the pushed
     value changed 6 -> 3 (RAW), then branches to the original exit.

IMetadata::update() replaces the entry, so the second call overwrites the
5/6-value entry with the RAW-inclusive one. Register safety holds BY
CONSTRUCTION for this shape: the replayed block re-sets w8/x0/x1/x2 itself,
x19 (the IMetadata*) is live at the update call and the cbz does not touch
it, and sp is unchanged. The bl rel32s are retargeted for the new pc.

COST, STATED PLAINLY: the error-reporting path for this one entry is gone.
If update() ever fails for availableCapabilities it now fails silently.

This adds the RAW *capability flag* ONLY. Whether RAW_SENSOR stream configs
exist (tag 0x000d0012, the scaler half -- PORTROM 5.4y part 2) is a SEPARATE
question, answered on hardware via dumpsys, never assumed: an app would
otherwise see CAPABILITY_RAW, try a RAW stream, and fail -- worse than not
offering it. Tester gate (runs on STOCK, no flash needed):

  adb shell dumpsys media.camera   # per camera: availableCapabilities bytes
                                   # + RAW_SENSOR (0x20) stream configurations

Usage:
  patch-metastore-raw.py <libmtkcam_metastore.so> <FUNC> [--verify] [-o OUT]
"""
import struct
import subprocess
import sys

TAG_AVAILABLE_CAPABILITIES = 0x000C000C
CAP_RAW = 3
CAP_BURST = 6

NOP = 0xD503201F


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def bl_imm(src, dst):
    off = dst - src
    assert off % 4 == 0, "misaligned branch"
    assert -(1 << 27) <= off < (1 << 27), "bl out of range"
    return 0x94000000 | ((off >> 2) & 0x03FFFFFF)


def b_imm(src, dst):
    off = dst - src
    assert off % 4 == 0, "misaligned branch"
    assert -(1 << 27) <= off < (1 << 27), "b out of range"
    return 0x14000000 | ((off >> 2) & 0x03FFFFFF)


def decode_cbz_target(word, pc):
    assert (word & 0xFF000000) == 0x34000000, "not a cbz"
    imm19 = (word >> 5) & 0x7FFFF
    if imm19 & (1 << 18):
        imm19 -= (1 << 19)
    return pc + imm19 * 4


def resolve(path, name):
    out = subprocess.run(["readelf", "-sW", path],
                         capture_output=True, text=True).stdout
    for ln in out.splitlines():
        f = ln.split()
        if len(f) >= 8 and f[7] == name:
            return int(f[1], 16), int(f[2])
    raise SystemExit("!! symbol not found: %s" % name)


def movz_imm(word):
    """If word is `mov w8, #N` (movz, 32-bit, no shift), return N, else None.
    movz: sf=0(31) opc=00(30:29) hw(22:21) imm16(20:5) Rd(4:0).
    """
    if (word & 0xFFE0001F) == 0x52800008 and ((word >> 21) & 3) == 0:
        return (word >> 5) & 0xFFFF
    return None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if len(args) < 2:
        raise SystemExit(__doc__)
    path, func = args[0], args[1]
    verify_only = "--verify" in sys.argv
    out_path = path
    if "-o" in sys.argv:
        out_path = sys.argv[sys.argv.index("-o") + 1]

    d = bytearray(open(path, "rb").read())
    base, size = resolve(path, func)
    print("%s\n  %s\n  @ 0x%x size %d" % (path, func, base, size))

    # --- the tag must be availableCapabilities, exactly once before the pushes.
    dis = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn",
         "--start-address=0x%x" % base,
         "--stop-address=0x%x" % (base + size), path],
        capture_output=True, text=True).stdout
    import re
    tag_lines = [l.strip() for l in dis.splitlines()
                 if re.search(r"\bmov\s+w1, #0x%x\b" % TAG_AVAILABLE_CAPABILITIES, l)]
    if len(tag_lines) != 1:
        raise SystemExit("!! expected exactly one tag setup, got %d -- refusing"
                         % len(tag_lines))

    # --- find the push-6 (BURST_CAPTURE) replay block STRUCTURALLY:
    # mov w8,#6 ; strb ; sub x0 ; add x1 ; bl push_back ; sub ; bl tag ;
    # mov w1,w0 ; sub x2 ; mov x0,x19 ; bl update ; cbz w0, <exit>
    # NOTE: the replayed push must be the LAST one before tag()/update().
    # IMX782-shaped functions end in push-9 and never match here.
    def find_site():
        found = None
        for off in range(base, base + size - 48, 4):
            w = [u32(d, off + i * 4) for i in range(12)]
            if (movz_imm(w[0]) == CAP_BURST
                    and w[1] == 0x390043E8      # strb w8, [sp, #0x10]
                    and w[2] == 0xD10143A0      # sub x0, x29, #0x50
                    and w[3] == 0x910043E1      # add x1, sp, #0x10
                    and (w[4] & 0xFC000000) == 0x94000000   # bl push_back
                    and w[5] == 0xD10143A0
                    and (w[6] & 0xFC000000) == 0x94000000   # bl tag
                    and w[7] == 0x2A0003E1      # mov w1, w0
                    and w[8] == 0xD10143A2      # sub x2, x29, #0x50
                    and w[9] == 0xAA1303E0      # mov x0, x19
                    and (w[10] & 0xFC000000) == 0x94000000  # bl update
                    and ((w[11] & 0xFF000000) == 0x34000000  # cbz, or
                         or w[11] == NOP)):                 # already patched
                if found is not None:
                    raise SystemExit("!! replay block matches more than once -- refusing")
                found = off
        return found

    site = find_site()
    if site is None:
        # No patchable shape. If RAW is already pushed this is the IMX782
        # stock shape (report, don't patch); otherwise the shape is unknown.
        raw_here = any(
            movz_imm(u32(d, off)) == CAP_RAW and u32(d, off + 4) == 0x390043E8
            for off in range(base, base + size - 8, 4))
        if raw_here:
            print("  RAW (3) is already pushed in this function -- nothing to do.")
            print("  (the scaler/stream half is the remaining question, answered "
                   "on hardware via dumpsys, never assumed)")
            return
        raise SystemExit("!! could not find the push-6/tag/update/cbz block -- refusing")
    cbz_at = site + 0x2C
    block = [u32(d, site + i * 4) for i in range(11)]

    _w = u32(d, cbz_at)
    if (_w & 0xFF000000) == 0x34000000:
        exit_at = decode_cbz_target(_w, cbz_at)
    else:
        # Already-patched file reads nop here; a verifier must not raise.
        if _w == NOP:
            print("  already patched (nop at cbz site) -- verifying cave...")
            exit_at = None
        else:
            raise SystemExit("!! cbz site reads %08x -- refusing" % _w)

    cave = site + 0x30
    if exit_at is None:
        # Already-patched file: verify the 11 replay words match what this
        # tool would emit, and the 12th word branches back inside the
        # function (the exact exit is not recoverable from a nop, but a
        # branch leaving the function would be a wrong patch).
        exp = []
        for i, w in enumerate(block):
            src = site + i * 4
            dst_addr = cave + i * 4
            if (w & 0xFC000000) == 0x94000000:
                tgt = src + (((w & 0x03FFFFFF) ^ 0x02000000) - 0x02000000) * 4
                exp.append(bl_imm(dst_addr, tgt))
            elif i == 0:
                exp.append((w & ~(0xFFFF << 5)) | (CAP_RAW << 5))
            else:
                exp.append(w)
        got = [u32(d, cave + i * 4) for i in range(11)]
        bw = u32(d, cave + 11 * 4)
        b_ok = ((bw & 0xFC000000) == 0x14000000
                and base < cave + 44 + ((((bw & 0x03FFFFFF) ^ 0x02000000)
                                         - 0x02000000) * 4) <= base + size)
        if got == exp and b_ok:
            print("  part 1 (RAW capability): YES (cbz->nop + cave verified)")
        else:
            print("  part 1 (RAW capability): NO -- cbz is nop but the cave "
                  "does not match this tool's output (foreign patch?)")
        return
    else:
        cave_bytes = exit_at - cave
        need = 12 * 4
        print("  push(BURST_CAPTURE)+update block @ 0x%x" % site)
        print("  cbz @0x%x -> exit 0x%x   cave = %d bytes, need %d"
              % (cbz_at, exit_at, cave_bytes, need))
        if cave_bytes < need:
            raise SystemExit("!! cave is %d bytes, need %d -- refusing"
                             % (cave_bytes, need))
        if not (base < cave < base + size and exit_at <= base + size):
            raise SystemExit("!! cave/exit fall outside the function -- refusing")

    # --- build the replacement: replay block with 6 -> 3, bl retargeted.
    new = []
    for i, w in enumerate(block):
        src = site + i * 4
        dst_addr = cave + i * 4
        if (w & 0xFC000000) == 0x94000000:
            tgt = src + (((w & 0x03FFFFFF) ^ 0x02000000) - 0x02000000) * 4
            new.append(bl_imm(dst_addr, tgt))
        elif i == 0:
            new.append((w & ~(0xFFFF << 5)) | (CAP_RAW << 5))
        else:
            new.append(w)
    # new[11] appended after exit is known; for the applied-check compute lazily
    if verify_only:
        p1 = u32(d, cbz_at) == NOP
        print("  part 1 (RAW capability): %s" % ("YES" if p1 else "no"))
        return

    new.append(b_imm(cave + 11 * 4, exit_at))
    patched = bytearray(d)
    struct.pack_into("<I", patched, cbz_at, NOP)
    for i, x in enumerate(new):
        struct.pack_into("<I", patched, cave + i * 4, x)
    open(out_path, "wb").write(patched)
    print("  patched: cbz->nop @0x%x, %d cave words @0x%x" % (cbz_at, len(new), cave))


if __name__ == "__main__":
    main()
