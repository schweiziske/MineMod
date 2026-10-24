#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import json
import struct
import zlib
import sys
import tempfile
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import mc_import_world as importer  # noqa: E402


def expect_error(code: str, callback) -> None:
    try:
        callback()
    except importer.ImportValidationError as exc:
        assert exc.code == code, (exc.code, code)
        return
    raise AssertionError(f"expected ImportValidationError({code})")


def registry() -> importer.BlockStateRegistry:
    report = {
        "test:block": {
            "properties": {
                "facing": ["north", "south", "west", "east"],
                "powered": ["true", "false"],
            },
            "states": [
                {"properties": {"facing": "north", "powered": "false"}},
                {"properties": {"facing": "south", "powered": "false"}},
                {"properties": {"facing": "west", "powered": "false"}},
                {"properties": {"facing": "east", "powered": "false"}},
                {"properties": {"facing": "south", "powered": "true"}},
            ],
        },
        "minecraft:air": {"states": [{}]},
        "minecraft:cave_air": {"states": [{}]},
        "minecraft:void_air": {"states": [{}]},
    }
    metadata = {
        "minecraftId": "test-version",
        "worldVersion": 4897,
        "seriesId": "main",
        "schemaHash": "schema-test",
        "reportSha256": "report-test",
    }
    return importer.BlockStateRegistry(report, metadata)


def test_canonical_properties_and_validation() -> None:
    reg = registry()
    entry = {"Name": "test:block", "Properties": {"powered": "false", "facing": "north"}}
    assert reg.canonical_spec(entry) == "test:block[facing=north,powered=false]"
    expect_error(
        "missing_property",
        lambda: reg.canonical_spec({"Name": "test:block", "Properties": {"facing": "north"}}),
    )
    expect_error(
        "unknown_property",
        lambda: reg.canonical_spec({
            "Name": "test:block",
            "Properties": {"facing": "north", "powered": "false", "future": "x"},
        }),
    )
    expect_error(
        "invalid_property_value",
        lambda: reg.canonical_spec({
            "Name": "test:block", "Properties": {"facing": "up", "powered": "false"},
        }),
    )
    expect_error(
        "illegal_state_combination",
        lambda: reg.canonical_spec({
            "Name": "test:block", "Properties": {"facing": "north", "powered": "true"},
        }),
    )
    expect_error("unknown_block", lambda: reg.canonical_spec({"Name": "mod:missing"}))


def test_generated_report_property_order() -> None:
    reg = importer.load_block_state_registry(ROOT / "data")
    spec = reg.canonical_spec({
        "Name": "minecraft:oak_stairs",
        "Properties": {
            "waterlogged": "false",
            "shape": "straight",
            "half": "bottom",
            "facing": "north",
        },
    })
    assert spec == "minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]"
    assert importer.AIR == {"minecraft:air"}


def test_import_coordinate_mapping() -> None:
    lo = (10, 20, 30)
    hi = (12, 22, 32)
    origin = (100, 200, 300)
    base = importer.dest_pos(10, 20, 30, lo, hi, origin, False)
    assert base == (100, 202, 300)
    assert importer.dest_pos(11, 20, 30, lo, hi, origin, False) == (101, 202, 300)
    assert importer.dest_pos(10, 21, 30, lo, hi, origin, False) == (100, 202, 301)
    assert importer.dest_pos(10, 20, 31, lo, hi, origin, False) == (100, 201, 300)
    assert importer.dest_pos(12, 22, 32, lo, hi, origin, False) == (102, 200, 302)
    assert importer.dest_pos(10, 20, 30, lo, hi, origin, True) == (110, 170, 320)


def test_import_block_states() -> None:
    reg = importer.load_block_state_registry(ROOT / "data")

    def assert_transform(name: str, source: dict[str, str], expected: dict[str, str]) -> None:
        entry = {"Name": name, "Properties": source}
        expected_entry = {"Name": name, "Properties": expected}
        assert reg.import_spec(entry) == reg.canonical_spec(expected_entry)
        transformed_entry = importer.transform_import_block_state_entry(entry)
        assert importer.transform_import_block_state_entry(transformed_entry) == entry

    assert_transform(
        "minecraft:oak_stairs",
        {"facing": "north", "half": "bottom", "shape": "inner_left", "waterlogged": "false"},
        {"facing": "south", "half": "bottom", "shape": "inner_right", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:oak_door",
        {"facing": "north", "half": "lower", "hinge": "left", "open": "true", "powered": "false"},
        {"facing": "south", "half": "lower", "hinge": "right", "open": "true", "powered": "false"},
    )
    assert_transform(
        "minecraft:rail",
        {"shape": "ascending_north", "waterlogged": "false"},
        {"shape": "ascending_south", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:rail",
        {"shape": "south_east", "waterlogged": "false"},
        {"shape": "north_east", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:rail",
        {"shape": "north_south", "waterlogged": "false"},
        {"shape": "north_south", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:oak_sign",
        {"rotation": "1", "waterlogged": "false"},
        {"rotation": "7", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:oak_fence",
        {"east": "false", "north": "true", "south": "false", "waterlogged": "false", "west": "true"},
        {"east": "false", "north": "false", "south": "true", "waterlogged": "false", "west": "true"},
    )
    assert_transform(
        "minecraft:chest",
        {"type": "left", "facing": "north", "waterlogged": "false"},
        {"type": "right", "facing": "south", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:acacia_shelf",
        {"facing": "east", "powered": "false", "side_chain": "left", "waterlogged": "false"},
        {"facing": "east", "powered": "false", "side_chain": "right", "waterlogged": "false"},
    )
    assert_transform(
        "minecraft:crafter",
        {"crafting": "false", "orientation": "down_north", "triggered": "false"},
        {"crafting": "false", "orientation": "down_south", "triggered": "false"},
    )
    assert_transform(
        "minecraft:oak_log",
        {"axis": "x"},
        {"axis": "x"},
    )
    entry = {"Name": "minecraft:grass", "Properties": {}}
    assert reg.import_spec(entry) == reg.canonical_spec({"Name": "minecraft:short_grass"})


def test_generated_registry_is_closed_under_import_transform() -> None:
    reg = importer.load_block_state_registry(ROOT / "data")
    checked = 0
    for name, definition in reg.report.items():
        for state in definition.get("states") or []:
            entry = {"Name": name}
            if definition.get("properties"):
                entry["Properties"] = dict(state.get("properties") or {})
            transformed_entry = importer.transform_import_block_state_entry(entry)
            assert reg.import_spec(entry) == reg.canonical_spec(transformed_entry)
            assert importer.transform_import_block_state_entry(transformed_entry) == entry
            checked += 1
    assert checked > 30000


def test_strict_packed_palette_validation() -> None:
    words = [0] * 256
    words[0] = 1
    values = importer.unpack_palette_indices(words, 2)
    assert values[0] == 1 and values[1] == 0 and len(values) == 4096
    expect_error("invalid_packed_block_state_length", lambda: importer.unpack_palette_indices([0], 2))
    bad = [0] * 256
    bad[0] = 15
    expect_error("palette_index_out_of_range", lambda: importer.unpack_palette_indices(bad, 3))
    expect_error("missing_packed_block_states", lambda: importer.unpack_palette_indices(None, 2))
    assert importer.unpack_palette_indices(None, 1) == [0] * 4096


def make_typed_block_entity() -> importer.NBTCompound:
    entity = importer.NBTCompound()
    entity["id"] = "minecraft:sign"
    entity.tag_types["id"] = importer.TAG_STRING
    for key, value in (("x", 0), ("y", 0), ("z", 0)):
        entity[key] = value
        entity.tag_types[key] = importer.TAG_INT
    entity["future_long"] = 9_223_372_036_854_775_000
    entity.tag_types["future_long"] = importer.TAG_LONG
    return entity


def test_block_entities_modern_and_legacy_rejection() -> None:
    entity = make_typed_block_entity()
    assert importer.chunk_block_entities({"block_entities": [entity]}) == [entity]
    expect_error(
        "unsupported_legacy_chunk_storage",
        lambda: importer.chunk_block_entities({"Level": {"TileEntities": [entity]}}),
    )
    entity["x"] = 1
    entity["z"] = 2
    out_key, record, event = importer.opaque_block_entity_record(
        entity, 4897, (0, 0, 0), (4, 4, 4), (0, 0, 0), False,
    )
    assert out_key == (0, 0, 0)
    assert record["localIndex"] == 33
    assert record["encoding"] == "typed-nbt-json-v1"
    compound_entries = record["data"]["value"]
    future = next(item for item in compound_entries if item["name"] == "future_long")
    assert future["value"] == {"tag": "long", "value": "9223372036854775000"}
    assert event["action"] == "preserve_opaque"
    assert event["targetPos"] == [1, 2, 0]


def test_nbt_reader_keeps_numeric_tag_types() -> None:
    raw = bytearray()
    raw.extend(bytes([importer.TAG_COMPOUND, 0, 0]))
    raw.extend(bytes([importer.TAG_LONG, 0, 5]))
    raw.extend(b"value")
    raw.extend(struct.pack(">q", 9_223_372_036_854_775_000))
    raw.extend(bytes([importer.TAG_END]))
    root = importer.read_nbt(bytes(raw))
    assert isinstance(root, importer.NBTCompound)
    assert root.tag_types["value"] == importer.TAG_LONG
    typed = importer.typed_nbt_value(root, importer.TAG_COMPOUND)
    assert typed["value"][0]["value"] == {"tag": "long", "value": "9223372036854775000"}


def test_nbt_and_region_safety_limits() -> None:
    raw = bytearray([importer.TAG_COMPOUND, 0, 0])
    for _ in range(importer.MAX_NBT_DEPTH + 2):
        raw.extend(bytes([importer.TAG_COMPOUND, 0, 1]))
        raw.extend(b"x")
    raw.extend(bytes([importer.TAG_END]) * (importer.MAX_NBT_DEPTH + 3))
    expect_error("nbt_depth_limit", lambda: importer.read_nbt(bytes(raw)))

    oversized_list = bytearray([importer.TAG_COMPOUND, 0, 0, importer.TAG_LIST, 0, 1])
    oversized_list.extend(b"l")
    oversized_list.append(importer.TAG_BYTE)
    oversized_list.extend(struct.pack(">i", importer.MAX_NBT_COLLECTION_ITEMS + 1))
    oversized_list.append(importer.TAG_END)
    expect_error("nbt_collection_limit", lambda: importer.read_nbt(bytes(oversized_list)))

    old_limit = importer.MAX_DECOMPRESSED_CHUNK_BYTES
    importer.MAX_DECOMPRESSED_CHUNK_BYTES = 16
    try:
        expect_error(
            "chunk_decompressed_too_large",
            lambda: importer.decompress_zlib_limited(zlib.compress(b"x" * 17), zlib.MAX_WBITS),
        )
    finally:
        importer.MAX_DECOMPRESSED_CHUNK_BYTES = old_limit

    with tempfile.TemporaryDirectory() as tmp:
        region = pathlib.Path(tmp) / "r.0.0.mca"
        header = bytearray(8192)
        header[0:4] = bytes([0, 0, 2, 1])
        region.write_bytes(header)
        expect_error("region_sector_out_of_bounds", lambda: importer.read_region_chunk(region, 0, 0))

        payload = bytearray(4096)
        payload[0:4] = struct.pack(">I", 4093)
        region.write_bytes(header + payload)
        expect_error("invalid_region_chunk_length", lambda: importer.read_region_chunk(region, 0, 0))


def test_chunk_storage_adapter_registry() -> None:
    source = importer.chunk_storage_adapter_for_data_version(4671)
    target = importer.chunk_storage_adapter_for_data_version(4897)
    assert source is target
    assert source.adapter_id == "java_anvil_root_sections_block_states_v1"
    expect_error(
        "unsupported_chunk_storage_data_version",
        lambda: importer.chunk_storage_adapter_for_data_version(2859),
    )
    expect_error(
        "unsupported_chunk_storage_data_version",
        lambda: importer.chunk_storage_adapter_for_data_version(4898),
    )

    legacy_root = {
        "DataVersion": 4671,
        "Level": {"Sections": [{"Y": 0, "Palette": [{"Name": "minecraft:air"}]}]},
    }
    expect_error(
        "unsupported_legacy_chunk_storage",
        lambda: importer.resolve_chunk_storage_adapter(legacy_root, 4671, 3, 4),
    )
    expect_error(
        "unsupported_legacy_chunk_storage",
        lambda: source.section_palette({"Y": 0, "Palette": []}, 3, 4, 0),
    )
    expect_error(
        "invalid_modern_block_state_data",
        lambda: source.section_palette(
            {"block_states": {"palette": [{"Name": "minecraft:air"}], "data": "bad"}},
            3, 4, 0,
        ),
    )


def test_import_bundle_v10_and_strict_data_version() -> None:
    reg = registry()
    root = importer.NBTCompound()
    root["DataVersion"] = 4897
    root.tag_types["DataVersion"] = importer.TAG_INT
    root["sections"] = [{
        "Y": 0,
        "block_states": {
            "palette": [{
                "Name": "test:block",
                "Properties": {"powered": "false", "facing": "north"},
            }],
        },
    }]
    root["block_entities"] = [make_typed_block_entity()]

    with tempfile.TemporaryDirectory() as tmp:
        world = pathlib.Path(tmp)
        region = world / "region"
        region.mkdir()
        (region / "r.0.0.mca").write_bytes(b"fixture")
        args = SimpleNamespace(
            world=str(world), dimension="overworld",
            from_pos=(0, 0, 0), to_pos=(0, 0, 0), origin=(0, 0, 0),
            keep_coords=False, max_blocks=0, allow_data_version=[],
        )
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: root
        try:
            bundle = importer.import_world(args, reg)
        finally:
            importer.read_region_chunk = original

    assert bundle["format"] == "mc_world_import"
    assert bundle["formatVersion"] == 1 and bundle["v"] == 10
    assert bundle["p"] == ["test:block[facing=south,powered=false]"]
    assert bundle["source"]["dataVersion"] == 4897
    assert bundle["source"]["storageAdapter"] == "java_anvil_root_sections_block_states_v1"
    assert bundle["source"]["axisMapping"] == "minecraft x/-z/y -> gmod bx/by/bz"
    assert bundle["target"]["schemaHash"] == "schema-test"
    assert bundle["target"]["blockReportSha256"] == "report-test"
    assert bundle["lossReport"]["eventCount"] == 1
    assert bundle["lossReport"]["opaqueBlockEntities"] == 1
    assert bundle["lossReport"]["runtimeComplete"] is False
    assert len(bundle["chunks"][0]) == 5
    assert bundle["chunks"][0][4][0]["sourceType"] == "minecraft:sign"

    mismatch = dict(root)
    mismatch["DataVersion"] = 4898
    expect_error("data_version_mismatch", lambda: importer.validate_chunk_data_version(mismatch, 4897, 0, 0))
    expect_error("missing_data_version", lambda: importer.validate_chunk_data_version({}, 4897, 0, 0))

    compatible = importer.NBTCompound()
    compatible.update(root)
    compatible.tag_types.update(root.tag_types)
    compatible["DataVersion"] = 4671
    with tempfile.TemporaryDirectory() as tmp:
        compatible_region = pathlib.Path(tmp) / "region"
        compatible_region.mkdir()
        (compatible_region / "r.0.0.mca").write_bytes(b"fixture")
        allowed_args = SimpleNamespace(
            world=tmp, dimension=args.dimension,
            from_pos=args.from_pos, to_pos=args.to_pos, origin=args.origin,
            keep_coords=False, max_blocks=0, allow_data_version=[4671],
        )
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: compatible
        try:
            compatible_bundle = importer.import_world(allowed_args, reg)
        finally:
            importer.read_region_chunk = original

        denied_args = SimpleNamespace(**vars(allowed_args))
        denied_args.allow_data_version = []
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: compatible
        try:
            expect_error("data_version_mismatch", lambda: importer.import_world(denied_args, reg))
        finally:
            importer.read_region_chunk = original
    assert compatible_bundle["source"]["dataVersion"] == 4671
    assert compatible_bundle["source"]["targetDataVersion"] == 4897
    assert compatible_bundle["source"]["storageAdapter"] == "java_anvil_root_sections_block_states_v1"
    assert compatible_bundle["source"]["compatibility"] == "schema-validated-state-only"


def test_streaming_path_transforms_palette() -> None:
    reg = registry()
    root = importer.NBTCompound()
    root["DataVersion"] = 4897
    root.tag_types["DataVersion"] = importer.TAG_INT
    root["sections"] = [{
        "Y": 0,
        "block_states": {
            "palette": [{
                "Name": "test:block",
                "Properties": {"powered": "false", "facing": "north"},
            }],
        },
    }]
    root["block_entities"] = []

    with tempfile.TemporaryDirectory() as tmp:
        world = pathlib.Path(tmp)
        region = world / "region"
        region.mkdir()
        (region / "r.0.0.mca").write_bytes(b"fixture")
        args = SimpleNamespace(
            world=str(world), dimension="overworld",
            from_pos=(0, 0, 0), to_pos=(0, 0, 0), origin=(0, 0, 0),
            keep_coords=False, max_blocks=0, allow_data_version=[],
        )
        stats = {
            "blocks": 0, "chunks": 0, "scannedMcChunks": 0, "missingMcChunks": 0,
            "uniqueBlocks": 0, "clippedByMaxBlocks": False, "opaqueBlockEntities": 0,
        }
        palette: list[str] = []
        palette_index: dict[str, int] = {}
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: root
        try:
            chunks = list(importer.iter_gmod_save_chunks_from_world(
                args, stats, palette, palette_index, reg,
            ))
        finally:
            importer.read_region_chunk = original

    assert palette == ["test:block[facing=south,powered=false]"]
    assert chunks == [[0, 0, 0, "0:0"]]


def test_loss_report_is_deterministic() -> None:
    events = [
        {"code": "b", "sourcePos": [2, 0, 0], "sourceType": "z"},
        {"code": "a", "sourcePos": [1, 0, 0], "sourceType": "x"},
    ]
    first = importer.make_loss_report(events)
    second = importer.make_loss_report(list(reversed(events)))
    assert first == second
    assert list(first["counts"]) == ["a", "b"]


def test_split_import_parts_have_hashes() -> None:
    data = {
        "format": "mc_world_import", "formatVersion": 1, "v": 10,
        "source": {}, "target": {}, "lossReport": importer.make_loss_report([]),
        "h": 32, "p": ["minecraft:stone"], "stats": {"blocks": 1},
        "chunks": [[0, 0, 0, "0:0"]],
    }
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "bundle.json"
        written = importer.write_output(out, data, True)
        manifest = json.loads(out.read_text(encoding="utf-8"))
        part_entry = manifest["parts"][0]
        part_bytes = written[1].read_bytes()
    assert isinstance(part_entry, dict) and part_entry["path"]
    assert part_entry["sha256"] == __import__("hashlib").sha256(part_bytes).hexdigest()


def test_phase5_streaming_manifest_keeps_bundle_metadata() -> None:
    root = importer.NBTCompound()
    root["DataVersion"] = 4671
    root.tag_types["DataVersion"] = importer.TAG_INT
    root["sections"] = [
        {
            "Y": 0,
            "block_states": {"palette": [{"Name": "minecraft:stone"}]},
        },
        {
            "Y": 2,
            "block_states": {"palette": [{"Name": "minecraft:stone"}]},
        },
    ]
    root["block_entities"] = [make_typed_block_entity()]

    with tempfile.TemporaryDirectory() as tmp:
        base = pathlib.Path(tmp)
        world = base / "world"
        region = world / "region"
        region.mkdir(parents=True)
        (region / "r.0.0.mca").write_bytes(b"fixture")
        args = SimpleNamespace(
            world=str(world), dimension="overworld",
            from_pos=(0, 0, 0), to_pos=(0, 32, 0), origin=(0, 0, 0),
            keep_coords=False, max_blocks=0, allow_data_version=[4671],
        )
        save_path = base / "phase5.dat"
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: root
        try:
            stats, written = importer.stream_world_to_gmod_save(
                args, save_path, "phase5", "gm_flatgrass", 1, 36.5, 1024, "chunked",
            )
        finally:
            importer.read_region_chunk = original
        manifest = json.loads(save_path.read_text(encoding="utf-8"))
        part = json.loads(written[2].read_text(encoding="utf-8"))

    assert manifest["v"] == 10 and manifest["format"] == "mc_world_import"
    assert manifest["source"]["dataVersion"] == 4671
    assert manifest["source"]["storageAdapter"] == "java_anvil_root_sections_block_states_v1"
    assert manifest["source"]["compatibility"] == "schema-validated-state-only"
    assert manifest["target"]["blockReportSha256"]
    assert manifest["lossReport"]["opaqueBlockEntities"] == 1
    assert stats["opaqueBlockEntities"] == 1
    assert len(part["chunks"]) == 2
    assert len(part["chunks"][0]) == 6
    assert part["chunks"][0][4] == []
    assert part["chunks"][0][5][0]["sourceType"] == "minecraft:sign"


def test_skip_block_entity_nbt_keeps_blocks_in_every_export_path() -> None:
    root = importer.NBTCompound()
    root["DataVersion"] = 3465
    root["sections"] = [
        {"Y": y, "block_states": {"palette": [{"Name": "minecraft:stone"}]}}
        for y in (0, 2)
    ]
    inside = make_typed_block_entity()
    outside = make_typed_block_entity()
    outside["x"] = 1
    root["block_entities"] = [inside, outside]
    with tempfile.TemporaryDirectory() as tmp:
        world = pathlib.Path(tmp) / "world"
        (world / "region").mkdir(parents=True)
        (world / "region" / "r.0.0.mca").write_bytes(b"fixture")
        argv = ["--world", str(world), "--from", "0", "0", "0", "--to", "0", "32", "0",
                "--allow-data-version", "3465"]
        args = importer.parse_args(argv)
        assert args.skip_block_entity_nbt is True
        preserve_args = importer.parse_args(argv + ["--preserve-block-entity-nbt"])
        assert preserve_args.skip_block_entity_nbt is False
        skip_args = importer.parse_args(argv + ["--skip-nbt"])
        assert skip_args.skip_block_entity_nbt is True
        assert importer.parse_args(argv + ["--skip-block-entity-nbt"]).skip_block_entity_nbt is True
        original = importer.read_region_chunk
        importer.read_region_chunk = lambda *_args: root
        try:
            preserved = importer.import_world(preserve_args)
            skipped = importer.import_world(skip_args)
            assert skipped["stats"]["blocks"] == preserved["stats"]["blocks"] == 17
            assert skipped["p"] == preserved["p"]
            assert [record[:4] for record in skipped["chunks"]] == [record[:4] for record in preserved["chunks"]]
            assert preserved["stats"]["opaqueBlockEntities"] == 1
            assert skipped["stats"]["opaqueBlockEntities"] == 0
            assert skipped["stats"]["skippedBlockEntityNBT"] == 1
            assert all(len(record) == 4 for record in skipped["chunks"])
            classic = importer.make_gmod_save_data(skipped, "skip", "gm_flatgrass")
            for save_format in ("chunked", "streaming"):
                path = pathlib.Path(tmp) / save_format / "manifest.json"
                stats, written = importer.stream_world_to_gmod_save(
                    skip_args, path, "skip", "gm_flatgrass", 1, 36.5, 1024, save_format,
                )
                manifest = json.loads(path.read_text(encoding="utf-8"))
                assert stats["blocks"] == 17 and stats["opaqueBlockEntities"] == 0
                assert stats["skippedBlockEntityNBT"] == 1
                assert manifest["source"]["blockEntityNBT"] == "skip"
                assert manifest["lossReport"] == skipped["lossReport"]
                if save_format == "streaming":
                    assert manifest["stats"]["fallbackChunks"] == 0
                    assert all("path" not in part for part in manifest["parts"])
                else:
                    part = json.loads(written[2].read_text(encoding="utf-8"))
                    assert all(len(record) == 4 for record in part["chunks"])
        finally:
            importer.read_region_chunk = original
    assert classic["source"]["blockEntityNBT"] == "skip"
    assert classic["lossReport"]["archiveRoundTripLossless"] is False
    assert classic["lossReport"]["lossCount"] == 1
    assert classic["lossReport"]["skippedBlockEntityNBT"] == 1
    assert "data" not in classic["lossReport"]["events"][0]


def main() -> int:
    test_canonical_properties_and_validation()
    test_generated_report_property_order()
    test_import_coordinate_mapping()
    test_import_block_states()
    test_generated_registry_is_closed_under_import_transform()
    test_strict_packed_palette_validation()
    test_block_entities_modern_and_legacy_rejection()
    test_nbt_reader_keeps_numeric_tag_types()
    test_nbt_and_region_safety_limits()
    test_chunk_storage_adapter_registry()
    test_import_bundle_v10_and_strict_data_version()
    test_streaming_path_transforms_palette()
    test_loss_report_is_deterministic()
    test_split_import_parts_have_hashes()
    test_phase5_streaming_manifest_keeps_bundle_metadata()
    test_skip_block_entity_nbt_keeps_blocks_in_every_export_path()
    print("mc_import_world Phase 5 tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
