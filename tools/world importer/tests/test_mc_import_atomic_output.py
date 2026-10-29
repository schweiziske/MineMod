"""Overwrite/cancellation regressions for both distributed importer copies."""
from __future__ import annotations

import functools
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPOSITORY = pathlib.Path(__file__).resolve().parents[3]
IMPORTERS = (
    REPOSITORY / "tools" / "world importer" / "mc_import_world.py",
    REPOSITORY / "_tools" / "mc_import_world.py",
)
FORMATS = ("classic", "stream", "chunked", "streaming", "json", "json_split")


def load_importer(path):
    spec = importlib.util.spec_from_file_location("atomic_importer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def output_path(root, kind):
    if kind == "streaming":
        return root / "mc" / "saves" / "slot" / "manifest.json"
    if kind.startswith("json"):
        return root / "mc_import" / "slot.json"
    return root / "mc" / "saves" / "slot.dat"


def export(module, path, kind, marker=1, chunks=None):
    chunks = [[0, 0, 0, "0:0"], [1, 0, 0, "1:0"]] if chunks is None else chunks
    fields = {"slotName": "slot", "map": "gm_flatgrass", "savedAt": marker, "bs": 36.5, "h": 32}
    stats = {"chunks": 2, "blocks": 2}
    palette = ["minecraft:stone"]
    if kind == "classic":
        return module.write_gmod_save_files(path, {**fields, "chunks": chunks, "p": palette})
    if kind.startswith("json"):
        return module.write_output(path, {**fields, "v": 5, "chunks": chunks, "p": palette, "stats": stats},
                                   kind == "json_split")
    writer = getattr(module, "write_gmod_save_" + kind)
    return writer(path, fields, chunks, palette, stats)


def part_paths(path, manifest=None):
    manifest = json.loads(path.read_text(encoding="utf-8")) if manifest is None else manifest
    result = []
    for part in manifest.get("parts", []):
        references = [part] if isinstance(part, str) else [part[key] for key in ("path", "fastPath") if key in part]
        result.extend(path.parent / reference for reference in references)
    return result


def snapshot(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


def every_format(test):
    @functools.wraps(test)
    def run(self):
        for source in IMPORTERS:
            module = load_importer(source)
            for kind in FORMATS:
                with self.subTest(importer=source.parent.name, format=kind):
                    with tempfile.TemporaryDirectory(prefix="mc_atomic_test_") as temporary:
                        root = pathlib.Path(temporary)
                        path = output_path(root, kind)
                        export(module, path, kind)
                        test(self, module, root, path, kind)
    return run


class AtomicOutputTests(unittest.TestCase):
    def assert_preserved(self, root, before):
        for relative, data in before.items():
            self.assertEqual((root / relative).read_bytes(), data, str(relative))

    @every_format
    def test_success_keeps_previous_generation_readable(self, module, root, path, kind):
        before = snapshot(root)
        old_manifest = json.loads(path.read_text(encoding="utf-8"))
        written = export(module, path, kind, marker=2)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["savedAt"], 2)
        self.assertTrue(all(item.is_file() for item in written))
        self.assertEqual(set(part_paths(path)), set(written[1 if kind.startswith("json") else 2:]))
        for part in part_paths(path, old_manifest):
            self.assertEqual(part.read_bytes(), before[part.relative_to(root)])
        if not kind.startswith("json"):
            meta = path.parent / "meta.json" if path.name == "manifest.json" else path.with_suffix(".json")
            self.assertEqual(json.loads(meta.read_text(encoding="utf-8"))["path"],
                             module.gmod_data_relative_path(path))

    @every_format
    def test_writer_exception_and_keyboard_interrupt_preserve_old_save(self, module, root, path, kind):
        before = snapshot(root)
        for error in (OSError("disk full"), KeyboardInterrupt()):
            def broken_chunks():
                yield [0, 0, 0, "0:0"]
                raise error

            if kind in ("stream", "chunked", "streaming"):
                with self.assertRaises(type(error)):
                    export(module, path, kind, marker=2, chunks=broken_chunks())
            else:
                with mock.patch.object(module.json, "dumps", side_effect=error):
                    with self.assertRaises(type(error)):
                        export(module, path, kind, marker=2)
            self.assertEqual(snapshot(root), before, "failed generation not cleaned up")

    @every_format
    def test_manifest_replace_failure_rolls_back_metadata(self, module, root, path, kind):
        before = snapshot(root)
        replace = os.replace

        def fail_manifest(source, target):
            if pathlib.Path(target) == path:
                raise PermissionError("manifest locked")
            return replace(source, target)

        with mock.patch.object(module.os, "replace", side_effect=fail_manifest):
            with self.assertRaises(PermissionError):
                export(module, path, kind, marker=2)
        self.assertEqual(snapshot(root), before)

    @every_format
    def test_metadata_replace_failure_preserves_old_save(self, module, root, path, kind):
        if kind.startswith("json"):
            return
        before = snapshot(root)
        replace = os.replace

        def fail_metadata(source, target):
            if pathlib.Path(target) != path:
                raise PermissionError("metadata locked")
            return replace(source, target)

        with mock.patch.object(module.os, "replace", side_effect=fail_metadata):
            with self.assertRaises(PermissionError):
                export(module, path, kind, marker=2)
        self.assertEqual(snapshot(root), before)

    @every_format
    def test_interrupt_after_manifest_replace_rolls_back_safely(self, module, root, path, kind):
        before = snapshot(root)
        replace = os.replace

        def interrupt_after_replace(source, target):
            replace(source, target)
            if pathlib.Path(target) == path and pathlib.Path(source).parent.name != "_rollback":
                raise KeyboardInterrupt()

        with mock.patch.object(module.os, "replace", side_effect=interrupt_after_replace):
            with self.assertRaises(KeyboardInterrupt):
                export(module, path, kind, marker=2)
        self.assertEqual(snapshot(root), before)

    @every_format
    def test_failed_rollback_retains_readable_data_and_recovery_backup(self, module, root, path, kind):
        if kind.startswith("json"):
            return
        before = path.read_bytes()
        replace = os.replace

        def fail_metadata_and_rollback(source, target):
            if pathlib.Path(target) != path or pathlib.Path(source).parent.name == "_rollback":
                raise PermissionError("commit and recovery locked")
            return replace(source, target)

        with mock.patch.object(module.os, "replace", side_effect=fail_metadata_and_rollback):
            with self.assertRaisesRegex(PermissionError, "recovery locked"):
                export(module, path, kind, marker=2)
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["savedAt"], 2)
        self.assertTrue(all(part.is_file() for part in part_paths(path)), "recovery deleted new shards")
        backups = list(path.parent.glob("mc_import_*/_rollback/output.json"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), before)

    @every_format
    def test_interrupt_after_metadata_replace_rolls_back_both_files(self, module, root, path, kind):
        if kind.startswith("json"):
            return
        before = snapshot(root)
        replace = os.replace

        def interrupt_after_metadata(source, target):
            replace(source, target)
            if pathlib.Path(target) != path and pathlib.Path(source).parent.name != "_rollback":
                raise KeyboardInterrupt()

        with mock.patch.object(module.os, "replace", side_effect=interrupt_after_metadata):
            with self.assertRaises(KeyboardInterrupt):
                export(module, path, kind, marker=2)
        self.assertEqual(snapshot(root), before)

    def test_first_export_commit_failure_does_not_publish_metadata(self):
        for source in IMPORTERS:
            module = load_importer(source)
            for kind in FORMATS:
                with self.subTest(importer=source.parent.name, format=kind):
                    with tempfile.TemporaryDirectory(prefix="mc_atomic_test_") as temporary:
                        root = pathlib.Path(temporary)
                        path = output_path(root, kind)
                        replace = os.replace

                        def fail_manifest(source, target):
                            if pathlib.Path(target) == path:
                                raise PermissionError("manifest locked")
                            return replace(source, target)

                        with mock.patch.object(module.os, "replace", side_effect=fail_manifest):
                            with self.assertRaises(PermissionError):
                                export(module, path, kind)
                        self.assertEqual(snapshot(root), {})

    def test_hard_cancel_before_commit_preserves_old_save(self):
        for source in IMPORTERS:
            module = load_importer(source)
            for kind in ("stream", "chunked", "streaming", "json_split"):
                for phase in ("generation", "commit"):
                    with self.subTest(importer=source.parent.name, format=kind, phase=phase):
                        with tempfile.TemporaryDirectory(prefix="mc_atomic_test_") as temporary:
                            root = pathlib.Path(temporary)
                            path = output_path(root, kind)
                            export(module, path, kind)
                            before = snapshot(root)
                            ready = root / "ready"
                            child = subprocess.Popen(
                                [sys.executable, "-X", "utf8", str(pathlib.Path(__file__).resolve()),
                                 "--cancel-child", str(source), str(path), kind, phase, str(ready)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            )
                            try:
                                deadline = time.monotonic() + 15
                                while not ready.exists():
                                    if child.poll() is not None or time.monotonic() > deadline:
                                        self.fail("child did not reach cancellation barrier")
                                    time.sleep(0.01)
                                child.terminate()  # Matches the GUI's Popen.terminate cancellation.
                                child.communicate(timeout=10)
                            finally:
                                if child.poll() is None:
                                    child.kill()
                                    child.communicate(timeout=10)
                            self.assert_preserved(root, before)
                            self.assertTrue(all(part.is_file() for part in part_paths(path)))

    def test_hard_cancel_after_data_commit_keeps_complete_new_save(self):
        for source in IMPORTERS:
            with self.subTest(importer=source.parent.name):
                module = load_importer(source)
                with tempfile.TemporaryDirectory(prefix="mc_atomic_test_") as temporary:
                    root = pathlib.Path(temporary)
                    path = output_path(root, "streaming")
                    export(module, path, "streaming")
                    old_manifest = json.loads(path.read_text(encoding="utf-8"))
                    old_parts = {part: part.read_bytes() for part in part_paths(path, old_manifest)}
                    ready = root / "ready"
                    child = subprocess.Popen(
                        [sys.executable, "-X", "utf8", str(pathlib.Path(__file__).resolve()),
                         "--cancel-child", str(source), str(path), "streaming", "published", str(ready)],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    try:
                        deadline = time.monotonic() + 15
                        while not ready.exists():
                            if child.poll() is not None or time.monotonic() > deadline:
                                self.fail("child did not reach published data barrier")
                            time.sleep(0.01)
                        child.terminate()
                        child.communicate(timeout=10)
                    finally:
                        if child.poll() is None:
                            child.kill()
                            child.communicate(timeout=10)
                    self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["savedAt"], 2)
                    self.assertTrue(all(part.is_file() for part in part_paths(path)))
                    for part, data in old_parts.items():
                        self.assertEqual(part.read_bytes(), data)


def cancel_child(source, destination, kind, phase, ready):
    module = load_importer(pathlib.Path(source))

    def barrier():
        pathlib.Path(ready).write_text("ready", encoding="ascii")
        while True:
            time.sleep(1)

    if phase in ("commit", "published"):
        replace = os.replace

        def pause_commit(source, target):
            is_manifest = pathlib.Path(target) == pathlib.Path(destination)
            if phase == "commit" and is_manifest or phase == "published" and not is_manifest:
                barrier()
            return replace(source, target)

        module.os.replace = pause_commit
    else:
        dumps = json.dumps
        calls = 0

        def pause_generation(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                barrier()
            return dumps(*args, **kwargs)

        module.json.dumps = pause_generation
        if kind == "streaming":
            encode = module.encode_mcb4_fragment
            fragments = 0

            def pause_fragment(*args, **kwargs):
                nonlocal fragments
                fragments += 1
                if fragments == 2:
                    barrier()
                return encode(*args, **kwargs)

            module.encode_mcb4_fragment = pause_fragment
    export(module, pathlib.Path(destination), kind, marker=2)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--cancel-child":
        cancel_child(*sys.argv[2:])
    else:
        unittest.main()
