from __future__ import annotations

import pathlib
import sys
import unittest
from types import SimpleNamespace


TOOL_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_ROOT))

import mc_import_world as importer  # noqa: E402


def chunk(data_version: int | None) -> dict:
    root = importer.NBTCompound()
    if data_version is not None:
        root["DataVersion"] = data_version
        root.tag_types["DataVersion"] = importer.TAG_INT
    return root


class AutoDataVersionTests(unittest.TestCase):
    def test_mismatched_version_is_rejected_without_auto_mode(self) -> None:
        with self.assertRaises(importer.ImportValidationError) as raised:
            importer.validate_chunk_data_version(chunk(3465), 4897, 0, 0)
        self.assertEqual(raised.exception.code, "data_version_mismatch")

    def test_audited_version_is_accepted_in_auto_mode(self) -> None:
        actual = importer.validate_chunk_data_version(
            chunk(3465), 4897, 0, 0, auto_compatible=True
        )
        self.assertEqual(actual, 3465)

    def test_unknown_version_is_not_accepted_in_auto_mode(self) -> None:
        with self.assertRaises(importer.ImportValidationError) as raised:
            importer.validate_chunk_data_version(
                chunk(1), 4897, 0, 0, auto_compatible=True
            )
        self.assertEqual(
            raised.exception.code, "unsupported_chunk_storage_data_version"
        )

    def test_missing_version_is_rejected(self) -> None:
        with self.assertRaises(importer.ImportValidationError) as raised:
            importer.validate_chunk_data_version(
                chunk(None), 4897, 0, 0, auto_compatible=True
            )
        self.assertEqual(raised.exception.code, "missing_data_version")

    def test_auto_mode_records_mixed_audited_versions(self) -> None:
        registry = importer.BlockStateRegistry(
            {"minecraft:air": {"states": [{}]}},
            {
                "minecraftId": "test",
                "worldVersion": 4897,
                "seriesId": "main",
                "schemaHash": "schema",
                "reportSha256": "report",
            },
        )
        args = SimpleNamespace(
            dimension="overworld",
            world="World",
            from_pos=(0, 0, 0),
            to_pos=(15, 15, 15),
            origin=(0, 0, 0),
            keep_coords=False,
            max_blocks=0,
            auto_data_version=True,
            allow_mixed_data_versions=False,
            skip_block_entity_nbt=False,
        )
        result = importer.make_output(
            args,
            {},
            [],
            {},
            1,
            0,
            0,
            False,
            registry,
            {3465, 4897},
        )
        self.assertEqual(result["source"]["storageAdapter"], "mixed")
        self.assertEqual(
            set(result["source"]["storageAdapters"]),
            {"3465", "4897"},
        )


if __name__ == "__main__":
    unittest.main()
