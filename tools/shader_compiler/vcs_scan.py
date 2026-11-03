#!/usr/bin/env python3
"""Scan GMod/Source VCS v6 shader files: decompress LZMA combos and report
D3D9 bytecode register usage (const reads, color outputs, samplers, defs)."""
import lzma
import struct
import sys

REG_TYPES = {
    0: "temp", 1: "input", 2: "const", 3: "texture/addr", 4: "rastout",
    5: "attrout", 6: "texcrdout/output", 7: "constint", 8: "colorout",
    9: "depthout", 10: "sampler", 11: "const2", 12: "const3", 13: "const4",
    14: "constbool", 15: "loop", 16: "tempfloat16", 17: "misctype",
    18: "label", 19: "predicate",
}

OPCODE_NAMES = {
    1: "mov", 2: "add", 4: "mad", 5: "mul", 6: "rcp", 7: "rsq", 8: "dp3",
    9: "dp4", 10: "min", 11: "max", 12: "slt", 13: "sge", 14: "exp",
    15: "log", 16: "lit", 17: "dst", 18: "lrp", 19: "frc", 20: "m4x4",
    21: "m4x3", 22: "m3x4", 23: "m3x3", 24: "m3x2", 25: "call", 26: "callnz",
    27: "loop", 28: "ret", 29: "endloop", 30: "label", 31: "dcl",
    32: "pow", 33: "crs", 34: "sgn", 35: "abs", 36: "nrm", 37: "sincos",
    38: "rep", 39: "endrep", 40: "if", 41: "ifc", 42: "else", 43: "endif",
    44: "break", 45: "breakc", 46: "mova", 47: "defb", 48: "defi",
    64: "texcoord", 65: "texkill", 66: "texld", 67: "texbem",
    81: "def", 82: "phase", 88: "cmp", 90: "dp2add", 93: "texldd",
    94: "setp", 95: "texldl", 96: "breakp",
}

def parse_bytecode(data, detail=False):
    # find version token
    words = struct.unpack("<%dI" % (len(data) // 4), data[: (len(data) // 4) * 4])
    start = None
    for i, w in enumerate(words):
        if w in (0xFFFF0300, 0xFFFE0300, 0xFFFF0200, 0xFFFE0200):
            start = i
            break
    if start is None:
        return None
    kind = "ps" if (words[start] >> 16) == 0xFFFF else "vs"
    ver = "%d_%d" % ((words[start] >> 8) & 0xFF, words[start] & 0xFF)
    const_reads = set()
    defs = set()
    color_writes = set()
    depth_write = False
    samplers = {}
    dcl_inputs = []
    i = start + 1
    n = len(words)
    while i < n:
        tok = words[i]
        if tok == 0x0000FFFF:  # END
            break
        op = tok & 0xFFFF
        if op == 0xFFFE:  # comment
            length = (tok >> 16) & 0x7FFF
            i += 1 + length
            continue
        length = (tok >> 24) & 0x0F
        params = words[i + 1 : i + 1 + length]
        opname = OPCODE_NAMES.get(op, "op%d" % op)
        def reg_of(p):
            rtype = ((p >> 28) & 0x7) | ((p >> 8) & 0x18)
            regnum = p & 0x7FF
            return rtype, regnum
        if op == 81:  # def c#, x, y, z, w
            rtype, regnum = reg_of(params[0])
            if rtype == 2:
                defs.add(regnum)
        elif op in (47, 48):  # defb / defi
            pass
        elif op == 31:  # dcl
            usage = params[0]
            rtype, regnum = reg_of(params[1])
            if rtype == 10:
                ttype = (usage >> 27) & 0xF
                samplers[regnum] = {2: "2d", 3: "cube", 4: "volume"}.get(ttype, "t%d" % ttype)
            else:
                dcl_inputs.append("%s%d" % (REG_TYPES.get(rtype, "r?"), regnum))
        else:
            if detail:
                pretty = []
                for j, p in enumerate(params):
                    if p & 0x80000000:
                        rtype, regnum = reg_of(p)
                        pretty.append("%s%d" % (REG_TYPES.get(rtype, "t%d?" % rtype), regnum))
                    else:
                        pretty.append("imm")
                print("       %s %s" % (opname, ", ".join(pretty)))
            for j, p in enumerate(params):
                if not (p & 0x80000000):
                    continue
                rtype, regnum = reg_of(p)
                if rtype == 2 and j > 0:
                    const_reads.add(regnum)
                elif rtype == 2 and j == 0 and opname not in ("def",):
                    # const as first param can still be a source for some ops
                    # (dest can never be const) — count reads for non-dest ops
                    if opname in ("if", "ifc", "breakc", "rep", "loop", "call", "callnz"):
                        const_reads.add(regnum)
                if rtype == 10 and j > 0:
                    samplers.setdefault(regnum, "used")
                if rtype == 8 and j == 0:
                    color_writes.add(regnum)
                if rtype == 9 and j == 0:
                    depth_write = True
        i += 1 + length
    return {
        "kind": kind, "ver": ver,
        "const_reads": sorted(const_reads),
        "defs": sorted(defs),
        "external_consts": sorted(const_reads - defs),
        "color_writes": sorted(color_writes),
        "depth_write": depth_write,
        "samplers": samplers,
        "dcl": dcl_inputs,
    }

def scan_vcs(path):
    with open(path, "rb") as f:
        data = f.read()
    ver, total, dyn, flags, centroid, nstatic, crc = struct.unpack_from("<iiiIIII", data, 0)
    print("== %s" % path)
    print("   vcs v%d totalCombos=%d dynamicCombos=%d staticEntries=%d" % (ver, total, dyn, nstatic))
    table = []
    off = 28
    for _ in range(nstatic):
        cid, foff = struct.unpack_from("<II", data, off)
        table.append((cid, foff))
        off += 8
    results = []
    for idx in range(len(table) - 1):
        cid, foff = table[idx]
        if cid == 0xFFFFFFFF:
            continue
        pos = foff
        combo_i = 0
        while pos + 4 <= len(data):
            (blocksize,) = struct.unpack_from("<I", data, pos)
            if blocksize == 0xFFFFFFFF:
                break
            pos += 4
            compressed = bool(blocksize & 0x40000000)
            size = blocksize & 0x3FFFFFFF
            blob = data[pos : pos + size]
            pos += size
            if compressed and blob[:4] == b"LZMA":
                actual, lz = struct.unpack_from("<II", blob, 4)
                props = blob[12:17]
                pb, rem = divmod(props[0], 45)
                lp, lc = divmod(rem, 9)
                dict_size = struct.unpack_from("<I", props, 1)[0]
                dec = lzma.LZMADecompressor(
                    format=lzma.FORMAT_RAW,
                    filters=[{"id": lzma.FILTER_LZMA1, "dict_size": dict_size,
                              "lc": lc, "lp": lp, "pb": pb}],
                )
                payload = dec.decompress(blob[17 : 17 + lz], max_length=actual)
            else:
                payload = blob
            r = parse_bytecode(payload, detail=DETAIL)
            if r:
                print("   combo static=%d dyn=%d: %s_%s" % (cid, combo_i, r["kind"], r["ver"]))
                print("     external const reads: %s" % (["c%d" % c for c in r["external_consts"]] or "none"))
                print("     def'd (inline) consts: %s" % (["c%d" % c for c in r["defs"]] or "none"))
                print("     color outputs written: %s" % (["oC%d" % c for c in r["color_writes"]] or "none"))
                if r["depth_write"]:
                    print("     writes oDepth")
                print("     samplers: %s" % (r["samplers"] or "none"))
            else:
                print("   combo static=%d dyn=%d: no d3d9 bytecode found (%d bytes)" % (cid, combo_i, len(payload)))
            results.append(r)
            combo_i += 1
    return results

DETAIL = False
if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--detail"]
    DETAIL = "--detail" in sys.argv
    for p in args:
        scan_vcs(p)
        print()
