#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from __future__ import annotations

import json
import lzma
import pathlib
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import mc_import_world as importer  # noqa: E402


def read_dat_json(path: pathlib.Path) -> dict:
    raw = path.read_bytes()
    if raw[:1] in (b"{", b"["):
        return json.loads(raw.decode("utf-8"))
    return json.loads(lzma.decompress(raw, format=lzma.FORMAT_ALONE).decode("utf-8"))


def assert_eq(actual, expected, message: str) -> None:
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def test_chunk_box_from_chunk_coords() -> None:
    lo, hi = importer.chunk_box((-64, -33), (32, 64), (-64, 319))
    assert_eq(lo, (-1024, -64, -528), "chunk box low corner")
    assert_eq(hi, (527, 319, 1039), "chunk box high corner")


def test_save_slot_name_matches_gmod_rules() -> None:
    slot = importer.gmod_save_slot_name('..Equestria/BroHoof? Reimagined:"')
    assert_eq(slot, "_Equestria_BroHoof_ Reimagined__", "sanitized slot")
    assert_eq(importer.gmod_save_slot_name("   "), None, "empty slot")


def test_write_gmod_save_files_round_trips() -> None:
    import_data = {
        "v": 5,
        "h": importer.CH,
        "p": ["minecraft:stone"],
        "stats": {"blocks": 2, "chunks": 1},
        "chunks": [[0, 0, 0, "0:0;1:0"]],
    }
    save_data = importer.make_gmod_save_data(
        import_data,
        slot_name="Equestria_BroHoof",
        map_name="gm_flatgrass",
        saved_at=1_700_000_000,
        block_size=36.5,
    )

    with tempfile.TemporaryDirectory() as tmp:
        save_path = pathlib.Path(tmp) / "mc" / "saves" / "Equestria_BroHoof.dat"
        written = importer.write_gmod_save_files(save_path, save_data)

        assert_eq(written, [save_path, save_path.with_suffix(".json")], "written paths")
        raw = save_path.read_bytes()
        assert raw[:1] == b"{", "python-generated gmod .dat should be raw JSON"
        loaded = json.loads(raw.decode("utf-8"))
        assert_eq(loaded["slotName"], "Equestria_BroHoof", "dat slot name")
        assert_eq(loaded["chunks"], import_data["chunks"], "dat chunks")

        meta = json.loads(save_path.with_suffix(".json").read_text(encoding="utf-8"))
        assert_eq(meta["name"], "Equestria_BroHoof", "meta name")
        assert_eq(meta["path"], "mc/saves/Equestria_BroHoof.dat", "meta data path")
        assert_eq(meta["blocks"], 2, "meta block count")
    assert_eq(meta["chunks"], 1, "meta chunk count")
    expected_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(1_700_000_000))
    assert_eq(meta["savedAtText"], expected_time, "meta timestamp text")


def test_import_opaque_block_entities_move_to_save_slot_six() -> None:
    opaque = [{"localIndex": 3, "sourceType": "minecraft:sign"}]
    import_data = {
        "format": "mc_world_import",
        "formatVersion": 1,
        "v": importer.PHASE5_FORMAT_VERSION,
        "h": importer.CH,
        "p": ["minecraft:oak_sign"],
        "chunks": [[0, 0, 0, "3:0", opaque]],
    }
    save_data = importer.make_gmod_save_data(
        import_data,
        slot_name="Equestria_Opaque",
        map_name="gm_flatgrass",
        saved_at=1_700_000_000,
        block_size=36.5,
    )
    chunk = save_data["chunks"][0]
    assert_eq(chunk[4], [], "save slot five should contain active Block Entities")
    assert_eq(chunk[5], opaque, "opaque Block Entities should move to save slot six")


def test_write_gmod_save_stream_round_trips() -> None:
    save_fields = {
        "slotName": "Equestria_Stream",
        "map": "gm_flatgrass",
        "savedAt": 1_700_000_001,
        "bs": 36.5,
        "h": importer.CH,
    }
    chunks = [[0, 0, 0, "0:0"], [1, 0, 0, "1:1;2:1"]]
    stats = {"chunks": 2, "blocks": 3}

    with tempfile.TemporaryDirectory() as tmp:
        save_path = pathlib.Path(tmp) / "mc" / "saves" / "Equestria_Stream.dat"
        written = importer.write_gmod_save_stream(
            save_path,
            save_fields,
            chunks,
            ["minecraft:stone", "minecraft:dirt"],
            stats,
        )

        assert_eq(written, [save_path, save_path.with_suffix(".json")], "stream written paths")
        loaded = read_dat_json(save_path)
        assert_eq(loaded["slotName"], "Equestria_Stream", "stream slot name")
        assert_eq(loaded["chunks"], chunks, "stream chunks")
        assert_eq(loaded["p"], ["minecraft:stone", "minecraft:dirt"], "stream palette")

        meta = json.loads(save_path.with_suffix(".json").read_text(encoding="utf-8"))
        assert_eq(meta["blocks"], 3, "stream meta block count")
        assert_eq(meta["chunks"], 2, "stream meta chunk count")


def test_write_gmod_save_chunked_uses_manifest_parts() -> None:
    save_fields = {
        "slotName": "Equestria_Chunked",
        "map": "gm_flatgrass",
        "savedAt": 1_700_000_002,
        "bs": 36.5,
        "h": importer.CH,
    }
    chunks = [
        [0, 0, 0, "0:0"],
        [1, 0, 0, "1:1;2:1"],
        [2, 0, 0, "3:1"],
    ]
    stats = {"chunks": 3, "blocks": 4}

    with tempfile.TemporaryDirectory() as tmp:
        save_path = pathlib.Path(tmp) / "mc" / "saves" / "Equestria_Chunked.dat"
        written = importer.write_gmod_save_chunked(
            save_path,
            save_fields,
            chunks,
            ["minecraft:stone", "minecraft:dirt"],
            stats,
            max_part_json_bytes=72,
        )

        assert save_path.read_bytes()[:1] == b"{", "chunked manifest .dat should be raw JSON"
        manifest = read_dat_json(save_path)
        assert_eq(manifest["v"], 7, "chunked manifest version")
        assert_eq(manifest["chunks"], [], "chunked manifest should not inline chunks")
        assert_eq(manifest["stats"]["chunks"], 3, "chunked manifest chunk count")
        assert_eq(manifest["stats"]["blocks"], 4, "chunked manifest block count")
        assert manifest["parts"], "chunked manifest should list part files"

        part_paths = [save_path.parent / part for part in manifest["parts"]]
        assert_eq(written, [save_path, save_path.with_suffix(".json"), *part_paths], "chunked written paths")
        loaded_chunks = []
        for part_path in part_paths:
            assert part_path.read_bytes()[:1] == b"{", "chunked part .dat should be raw JSON"
            part = read_dat_json(part_path)
            assert_eq(part["v"], 5, "chunked part version")
            loaded_chunks.extend(part["chunks"])
        assert_eq(loaded_chunks, chunks, "chunked parts preserve chunks")

        meta = json.loads(save_path.with_suffix(".json").read_text(encoding="utf-8"))
        assert_eq(meta["blocks"], 4, "chunked meta block count")
        assert_eq(meta["chunks"], 3, "chunked meta chunk count")


def main() -> int:
    test_chunk_box_from_chunk_coords()
    test_save_slot_name_matches_gmod_rules()
    test_write_gmod_save_files_round_trips()
    test_import_opaque_block_entities_move_to_save_slot_six()
    test_write_gmod_save_stream_round_trips()
    test_write_gmod_save_chunked_uses_manifest_parts()
    print("mc_import_world gmod save tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
