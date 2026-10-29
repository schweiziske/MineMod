import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
IMPORTER = ROOT / "mc_import_world.py"


def test_streaming_writer_exports_v10_manifest(tmp_path):
    out = tmp_path / "large" / "manifest.json"
    script = (
        "import importlib.util, pathlib;"
        f"spec=importlib.util.spec_from_file_location('imp', r'{IMPORTER}');"
        "m=importlib.util.module_from_spec(spec);"
        "spec.loader.exec_module(m);"
        f"out=pathlib.Path(r'{out}');"
        "fields={'slotName':'large','map':'gm_flatgrass','savedAt':1,'bs':36.5,'h':32};"
        "chunks=[[0,0,0,'0:0;1:0'],[1,0,0,'0:0'],[0,1,0,'0:0']];"
        "stats={'blocks':4,'chunks':3,'scannedMcChunks':1,'missingMcChunks':0,'uniqueBlocks':1,'clippedByMaxBlocks':False};"
        "m.write_gmod_save_streaming(out, fields, chunks, ['minecraft:stone'], stats, 128);"
        "print(out)"
    )
    result = subprocess.run([sys.executable, "-X", "utf8", "-c", script], capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    manifest_path = pathlib.Path(result.stdout.strip())
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    assert manifest["v"] == 10
    assert manifest["p"] == ["minecraft:stone"]
    assert "parts" in manifest and manifest["parts"]
    assert "chunkIndex" in manifest
    assert "0:0:0" in manifest["chunkIndex"]

    assert manifest["parts"][0]["fastFormat"] == "MCB4"
    assert "path" not in manifest["parts"][0]
    assert manifest["chunkIndex"]["0:0:0"]["fastOffset"] == 0
    fast_path = pathlib.PurePosixPath(manifest["parts"][0]["fastPath"])
    assert fast_path.parts[0].startswith("mc_import_")
    assert fast_path.parts[1:] == ("regions", "r.0.0.json")
    assert (manifest_path.parent / fast_path).is_file()
    assert (manifest_path.parent / "meta.json").is_file()


def run_writer(tmp_path, chunks, palette, name="regions"):
    out = tmp_path / name / "manifest.json"
    script = (
        "import importlib.util, pathlib, json;"
        f"spec=importlib.util.spec_from_file_location('imp', r'{IMPORTER}');"
        "m=importlib.util.module_from_spec(spec);"
        "spec.loader.exec_module(m);"
        f"out=pathlib.Path(r'{out}');"
        f"fields={{'slotName':'{name}','map':'gm_flatgrass','savedAt':1,'bs':36.5,'h':32}};"
        f"chunks=json.loads(r'''{json.dumps(chunks)}''');"
        f"palette=json.loads(r'''{json.dumps(palette)}''');"
        "stats={'blocks':1,'chunks':len(chunks),'scannedMcChunks':1,'missingMcChunks':0,'uniqueBlocks':1,'clippedByMaxBlocks':False};"
        "m.write_gmod_save_streaming(out, fields, chunks, palette, stats);"
        "print(out)"
    )
    result = subprocess.run([sys.executable, "-X", "utf8", "-c", script], capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    manifest_path = pathlib.Path(result.stdout.strip())
    return manifest_path, json.loads(manifest_path.read_text(encoding="utf-8"))


def test_parts_are_sharded_by_region_like_minecraft(tmp_path):
    # cx/cy are horizontal and cz vertical, so a column's vertical layers must
    # all land in the same region file. 32 chunks per region, as in r.X.Z.mca.
    chunks = [
        [0, 0, 0, "0:0"],
        [31, 31, 7, "0:0"],
        [32, 0, 0, "0:0"],
        [-1, 0, 0, "0:0"],
    ]
    manifest_path, manifest = run_writer(tmp_path, chunks, ["minecraft:stone"])
    part_dir = (manifest_path.parent / manifest["parts"][0]["fastPath"]).parent

    assert manifest["regionChunks"] == 32
    assert manifest["fastFormat"] == "MCB4"
    # sorted by (rx, ry): (-1,0), (0,0), (1,0)
    assert [entry["region"] for entry in manifest["parts"]] == [[-1, 0], [0, 0], [1, 0]]
    assert [path.name for path in sorted(part_dir.iterdir())] == [
        "r.-1.0.json",
        "r.0.0.json",
        "r.1.0.json",
    ]

    # Both chunks of region (0,0) share one file at distinct offsets.
    assert manifest["chunkIndex"]["0:0:0"]["part"] == 2
    assert manifest["chunkIndex"]["31:31:7"]["part"] == 2
    assert manifest["chunkIndex"]["0:0:0"]["fastOffset"] == 0
    assert manifest["chunkIndex"]["31:31:7"]["fastOffset"] > 0
    assert manifest["chunkIndex"]["-1:0:0"]["part"] == 1
    assert manifest["chunkIndex"]["32:0:0"]["part"] == 3

    for entry in manifest["parts"]:
        fast = manifest_path.parent / entry["fastPath"]
        assert fast.stat().st_size == entry["fastBytes"]


def test_side_data_chunks_use_the_qualified_json_name(tmp_path):
    chunks = [
        [0, 0, 0, "0:0"],
        [1, 0, 0, "0:0", [], [{"localIndex": 0, "sourceType": "minecraft:sign"}]],
    ]
    manifest_path, manifest = run_writer(tmp_path, chunks, ["minecraft:stone"], "sides")
    part_dir = (manifest_path.parent / manifest["parts"][0]["fastPath"]).parent

    assert len(manifest["parts"]) == 1
    entry = manifest["parts"][0]
    assert entry["fastPath"].endswith("r.0.0.json")
    assert entry["path"].endswith("r.0.0.side.json")
    assert entry["chunks"] == 1
    assert sorted(path.name for path in part_dir.iterdir()) == ["r.0.0.json", "r.0.0.side.json"]

    # The side lane keeps the 1-based index into its own chunks array.
    assert manifest["chunkIndex"]["1:0:0"] == {"part": 1, "index": 1}
    assert manifest["chunkIndex"]["0:0:0"]["fastOffset"] == 0
    assert manifest["stats"]["fallbackChunks"] == 1
    assert manifest["stats"]["fastChunks"] == 1
    assert json.loads((part_dir / "r.0.0.side.json").read_text(encoding="utf-8"))["chunks"][0][0] == 1


def test_evicted_region_files_are_appended_not_truncated(tmp_path):
    # More regions than MAX_OPEN_REGION_FILES, with region 0 written again after
    # every other region has forced it out of the open-handle set. If the reopen
    # truncated, its first fragment would be lost and offsets would not line up.
    chunks = [[0, 0, 0, "0:0"]]
    chunks += [[32 * i, 0, 0, "0:0"] for i in range(1, 40)]
    chunks += [[1, 0, 1, "0:0"]]
    manifest_path, manifest = run_writer(tmp_path, chunks, ["minecraft:stone"], "evict")
    part_dir = (manifest_path.parent / manifest["parts"][0]["fastPath"]).parent

    assert len(manifest["parts"]) == 40
    first = manifest["chunkIndex"]["0:0:0"]
    second = manifest["chunkIndex"]["1:0:1"]
    assert first["part"] == second["part"]
    assert first["fastOffset"] == 0
    assert second["fastOffset"] == first["fastBytes"]

    entry = manifest["parts"][first["part"] - 1]
    assert entry["region"] == [0, 0]
    assert entry["fastBytes"] == first["fastBytes"] + second["fastBytes"]
    fast = part_dir / pathlib.Path(entry["fastPath"]).name
    assert fast.stat().st_size == entry["fastBytes"]

    for part in manifest["parts"]:
        path = manifest_path.parent / part["fastPath"]
        assert path.stat().st_size == part["fastBytes"]


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as tmp:
        test_streaming_writer_exports_v10_manifest(pathlib.Path(tmp))
        test_parts_are_sharded_by_region_like_minecraft(pathlib.Path(tmp))
        test_side_data_chunks_use_the_qualified_json_name(pathlib.Path(tmp))
        test_evicted_region_files_are_appended_not_truncated(pathlib.Path(tmp))
    print("mc import streaming save tests passed")
