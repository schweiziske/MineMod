from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest


TOOL_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_ROOT))

from i18n import Localization  # noqa: E402
from ui_model import FormError, FormState, build_plan  # noqa: E402


class UiModelTests(unittest.TestCase):
    def make_world(self, root: pathlib.Path) -> pathlib.Path:
        world = root / "Example World"
        (world / "region").mkdir(parents=True)
        (world / "level.dat").write_bytes(b"test")
        (world / "region" / "r.0.0.mca").write_bytes(b"test")
        return world

    def make_state(self, world: pathlib.Path, output: pathlib.Path) -> FormState:
        return FormState(
            {
                "world": str(world),
                "data_dir": str(output),
                "save_name": "Example",
                "save_format": "streaming",
            }
        )

    def test_chunk_save_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            world = self.make_world(root)
            plan = build_plan(self.make_state(world, root / "data"), sys.executable)

            self.assertEqual(plan.world_name, "Example World")
            self.assertEqual(plan.region_count, 1)
            self.assertIn("--from-chunk", plan.command)
            self.assertIn("--auto-data-version", plan.command)
            self.assertIn("--skip-block-entity-nbt", plan.command)
            self.assertIn("--save-out", plan.command)
            self.assertEqual(plan.output_path.name, "Example.dat")

    def test_block_json_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            world = self.make_world(root)
            state = self.make_state(world, root / "data")
            state.set("range_mode", "block")
            state.set("output_mode", "json")
            state.set("output_name", "Example Export")
            state.set("split_chunks", False)

            plan = build_plan(state, sys.executable)

            self.assertIn("--from", plan.command)
            self.assertIn("--no-split-chunks", plan.command)
            self.assertEqual(plan.output_path.name, "Example Export.json")

    def test_invalid_height_range_has_translation_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            world = self.make_world(root)
            state = self.make_state(world, root / "data")
            state.set("y_min", "100")
            state.set("y_max", "-100")

            with self.assertRaises(FormError) as raised:
                build_plan(state, sys.executable)
            self.assertEqual(raised.exception.code, "y_order")

    def test_catalogs_have_matching_keys(self) -> None:
        catalogs = {}
        for path in (TOOL_ROOT / "locales").glob("*.json"):
            catalogs[path.stem] = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(set(catalogs["zh_CN"]), set(catalogs["en_US"]))

    def test_localization_formats_values(self) -> None:
        i18n = Localization(TOOL_ROOT / "locales", "zh_CN")
        self.assertIn(
            "Example",
            i18n.text(
                "status.world_valid",
                name="Example",
                count=3,
                data_version=3465,
            ),
        )
        i18n.set_language("en_US")
        self.assertEqual(i18n.text("buttons.import"), "Start import")


if __name__ == "__main__":
    unittest.main()
