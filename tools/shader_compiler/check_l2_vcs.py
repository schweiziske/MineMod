"""Strict single-combo VCS validation for offline builds, not GPU validation.

Uses Python's standard LZMA decoder and the existing register scanner. Extraction
and COMMENT stripping follow the reference branch's vcs_scan.py test helpers.
"""
import argparse
import hashlib
import json
import lzma
from pathlib import Path
import re
import struct

from vcs_scan import parse_bytecode


def extract(data):
    if len(data) < 48:
        raise ValueError("Truncated VCS header")
    version, total, dynamic, _, _, entries, _ = struct.unpack_from("<7I", data)
    if (version, total, dynamic, entries) != (6, 1, 1, 2):
        raise ValueError("Expected VCS v6 with exactly one combo")
    combo, offset, sentinel, end = struct.unpack_from("<4I", data, 28)
    if combo != 0 or sentinel != 0xFFFFFFFF or not 48 <= offset < end == len(data):
        raise ValueError("Invalid single-combo VCS table")
    size_word = struct.unpack_from("<I", data, offset)[0]
    size = size_word & 0x3FFFFFFF
    if size <= 8 or offset + 4 + size + 4 != end:
        raise ValueError("Expected one complete VCS data block")
    if data[end - 4:end] != b"\xff\xff\xff\xff":
        raise ValueError("Missing VCS end-of-block marker")
    blob = data[offset + 4:offset + 4 + size]
    if size_word & 0x40000000:
        if len(blob) < 17 or blob[:4] != b"LZMA":
            raise ValueError("Unsupported VCS compression")
        actual, compressed = struct.unpack_from("<II", blob, 4)
        if not 8 < actual <= 4 * 1024 * 1024 or compressed + 17 != len(blob):
            raise ValueError("Invalid VCS LZMA sizes")
        pb, remainder = divmod(blob[12], 45)
        lp, lc = divmod(remainder, 9)
        dictionary = struct.unpack_from("<I", blob, 13)[0]
        if dictionary > 64 * 1024 * 1024:
            raise ValueError("VCS LZMA dictionary exceeds limit")
        decoder = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=[{
            "id": lzma.FILTER_LZMA1, "dict_size": dictionary,
            "lc": lc, "lp": lp, "pb": pb}])
        # Valve writes raw LZMA without an EOS marker. The declared length is
        # its termination condition: decoding one extra byte can interpret
        # range-coder padding as another symbol. The combo byte_count and the
        # shader END token below independently reject a false declared size.
        blob = decoder.decompress(blob[17:], max_length=actual)
        if len(blob) != actual:
            raise ValueError("VCS decompressed size mismatch")
    elif not size_word & 0x80000000:
        raise ValueError("Unsupported VCS data block")
    dynamic_id, byte_count = struct.unpack_from("<2I", blob)
    if dynamic_id != 0 or byte_count + 8 != len(blob):
        raise ValueError("Invalid VCS dynamic combo")
    return blob[8:]


def executable(data):
    if len(data) < 8 or len(data) % 4:
        raise ValueError("Unaligned/truncated D3D9 bytecode")
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if words[0] not in (0xFFFF0300, 0xFFFE0300):
        raise ValueError("Expected shader model 3 bytecode")
    tokens, i = [words[0]], 1
    while i < len(words):
        token = words[i]
        if token == 0xFFFF:
            if i + 1 != len(words):
                raise ValueError("Unexpected tokens after END")
            return struct.pack("<%dI" % (len(tokens) + 1), *tokens, token)
        comment = token & 0xFFFF == 0xFFFE
        length = (token >> 16) & 0x7FFF if comment else (token >> 24) & 15
        if i + 1 + length > len(words):
            raise ValueError("Truncated shader instruction")
        if not comment:
            tokens.extend(words[i:i + 1 + length])
        i += 1 + length
    raise ValueError("Missing shader END")


def disassemble(data):
    """Use the Windows compiler DLL on the CPU; never create a D3D device."""
    import ctypes as ct

    # The pack compiler is Windows-only. Search System32, not the working tree.
    compiler = ct.WinDLL("d3dcompiler_47.dll", winmode=0x00000800)
    function = compiler.D3DDisassemble
    function.argtypes = [ct.c_void_p, ct.c_size_t, ct.c_uint, ct.c_char_p, ct.POINTER(ct.c_void_p)]
    function.restype = ct.c_long
    buffer, blob = ct.create_string_buffer(data), ct.c_void_p()
    result = function(buffer, len(data), 0, None, ct.byref(blob))
    if result < 0:
        raise ValueError(f"D3DDisassemble failed: 0x{result & 0xffffffff:08x}")
    table = ct.cast(blob, ct.POINTER(ct.POINTER(ct.c_void_p))).contents
    release = ct.WINFUNCTYPE(ct.c_uint, ct.c_void_p)(table[2])
    pointer = ct.WINFUNCTYPE(ct.c_void_p, ct.c_void_p)(table[3])
    size = ct.WINFUNCTYPE(ct.c_size_t, ct.c_void_p)(table[4])
    try:
        return ct.string_at(pointer(blob), size(blob)).rstrip(b"\0").decode("utf-8")
    finally:
        release(blob)


def instruction_slots(assembly):
    match = re.search(r"approximately (\d+) instruction slots? used", assembly)
    if not match:
        raise ValueError("Disassembler did not report shader instruction slots")
    return int(match[1])


def report(path, sm3_budget=False):
    data = extract(Path(path).read_bytes())
    code = executable(data)
    result = dict(parse_bytecode(code), instructionHash=hashlib.sha256(code).hexdigest())
    if sm3_budget:
        assembly = disassemble(data)
        result["instructionSlots"] = instruction_slots(assembly)
        result["centroidTexcoords"] = sorted(int(index or 0) for index in
            re.findall(r"dcl_texcoord(\d*)_centroid\s", assembly))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sm3-budget", action="store_true", help="Include CPU-disassembled instruction slots (Windows only)")
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    print(json.dumps({Path(p).stem: report(p, args.sm3_budget) for p in args.paths}))
