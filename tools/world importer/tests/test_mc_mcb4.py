import importlib.util
import pathlib
import struct


ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mc_import_world", ROOT / "mc_import_world.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def decode_fragment(fragment: bytes):
    cx, cy, cz, total, section_count = struct.unpack_from("<iiiHH", fragment, 0)
    offset = 16
    cells = []
    for _ in range(section_count):
        section_y, count, palette_count, bits = struct.unpack_from("<HHHB", fragment, offset)
        offset += 7
        palette = list(struct.unpack_from("<" + "H" * palette_count, fragment, offset))
        offset += palette_count * 2
        occupancy = fragment[offset : offset + 512]
        offset += 512
        stream = fragment[offset : offset + (count * bits + 7) // 8]
        offset += len(stream)
        stream_bit = 0
        for local_index in range(4096):
            if occupancy[local_index // 8] & (1 << (local_index % 8)):
                value = 0
                for bit_index in range(bits):
                    value |= ((stream[(stream_bit + bit_index) // 8] >> ((stream_bit + bit_index) % 8)) & 1) << bit_index
                stream_bit += bits
                cells.append((section_y * 4096 + local_index, palette[value]))
    assert len(cells) == total
    assert offset == len(fragment)
    return [cx, cy, cz, sorted(cells)]


def test_mcb4_round_trip_and_side_data_guard():
    palette = ["minecraft:stone", "minecraft:dirt", "minecraft:glass"]
    record = [0, -2, 1, "0:0;15:1;4095:2;4096:1;8191:0"]
    fragment = module.encode_mcb4_fragment(record, palette, 32)
    assert fragment is not None
    assert decode_fragment(fragment) == [0, -2, 1, [(0, 0), (15, 1), (4095, 2), (4096, 1), (8191, 0)]]
    assert module.encode_mcb4_fragment(record + [[], [{"sourceType": "sign"}]], palette, 32) is None


def test_mcb4_palette_width_boundaries():
    assert module._mcb4_palette_bits(0) == 1
    assert module._mcb4_palette_bits(1) == 1
    assert module._mcb4_palette_bits(2) == 1
    assert module._mcb4_palette_bits(3) == 2
    assert module._mcb4_palette_bits(5) == 3


if __name__ == "__main__":
    test_mcb4_round_trip_and_side_data_guard()
    test_mcb4_palette_width_boundaries()
    print("mc MCB4 tests passed")
