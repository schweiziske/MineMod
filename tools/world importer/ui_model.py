"""UI-independent form state and importer command construction."""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

import mc_import_world as importer


TOOL_ROOT = pathlib.Path(__file__).resolve().parent
IMPORTER = TOOL_ROOT / "mc_import_world.py"
DATA_ROOT = TOOL_ROOT / "data"
DEFAULT_DATA_DIR = TOOL_ROOT / "output"


class FormError(ValueError):
    def __init__(self, code: str, **values: Any) -> None:
        super().__init__(code)
        self.code = code
        self.values = values


FORM_DEFAULTS: dict[str, Any] = {
    "world": "",
    "dimension": "overworld",
    "range_mode": "chunk",
    "from_chunk_x": "-16",
    "from_chunk_z": "-16",
    "to_chunk_x": "15",
    "to_chunk_z": "15",
    "y_min": "-64",
    "y_max": "319",
    "from_x": "-256",
    "from_y": "-64",
    "from_z": "-256",
    "to_x": "255",
    "to_y": "319",
    "to_z": "255",
    "data_dir": str(DEFAULT_DATA_DIR),
    "output_mode": "save",
    "save_name": "",
    "save_format": "auto",
    "output_name": "",
    "split_chunks": True,
    "origin_x": "0",
    "origin_y": "0",
    "origin_z": "0",
    "keep_coords": False,
    "max_blocks": "0",
    "data_versions": "",
    "auto_data_version": True,
    "allow_mixed": False,
    "skip_nbt": True,
    "replace_invalid_nbt": False,
    "save_map": "",
    "block_size": "36.5",
    "part_size": "4194304",
}


class FormState:
    def __init__(self, values: dict[str, Any] | None = None) -> None:
        self.values = dict(FORM_DEFAULTS)
        for key, value in (values or {}).items():
            if key in self.values and isinstance(value, (str, bool)):
                self.values[key] = value

    def get(self, key: str) -> Any:
        return self.values.get(key, FORM_DEFAULTS.get(key))

    def set(self, key: str, value: Any) -> None:
        if key in self.values:
            self.values[key] = value

    def to_dict(self) -> dict[str, Any]:
        return dict(self.values)


@dataclass(frozen=True)
class ImportPlan:
    command: list[str]
    output_path: pathlib.Path
    data_dir: pathlib.Path
    world_name: str
    region_count: int
    source_data_version: int | None

    @property
    def display_command(self) -> str:
        return subprocess.list2cmdline(self.command)


def supported_data_version_ranges() -> str:
    return ", ".join(
        f"{adapter.min_data_version}-{adapter.max_data_version}"
        for adapter in importer.CHUNK_STORAGE_ADAPTERS
    )


def read_world_data_version(world: pathlib.Path) -> int | None:
    try:
        root = importer.read_nbt((world / "level.dat").read_bytes())
    except (OSError, EOFError, ValueError):
        return None
    data = root.get("Data")
    value = data.get("DataVersion") if isinstance(data, dict) else None
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def inspect_world(
    world_value: str, dimension: str
) -> tuple[pathlib.Path, int, int | None]:
    world_text = str(world_value or "").strip().strip('"')
    if not world_text:
        raise FormError("world_required")
    world = pathlib.Path(world_text).expanduser()
    if not world.is_absolute():
        world = TOOL_ROOT / world
    world = world.resolve()
    if not world.is_dir():
        raise FormError("world_not_dir")
    if not (world / "level.dat").is_file():
        raise FormError("level_missing")
    if dimension not in ("overworld", "the_nether", "the_end"):
        raise FormError("dimension")
    try:
        region_dir = importer.find_region_dir(world, dimension)
    except FileNotFoundError as exc:
        raise FormError("region_missing") from exc
    region_count = sum(1 for _ in region_dir.glob("*.mca"))
    if region_count == 0:
        raise FormError("region_missing")
    return world, region_count, read_world_data_version(world)


def _integer(state: FormState, key: str, label: str, default: int | None = None) -> int:
    raw = state.get(key)
    if raw is None or str(raw).strip() == "":
        if default is not None:
            return default
        raise FormError("invalid_integer", label=label)
    try:
        value = int(str(raw).strip(), 10)
    except ValueError as exc:
        raise FormError("invalid_integer", label=label) from exc
    if abs(value) > 30_000_000:
        raise FormError("integer_range", label=label)
    return value


def _positive_float(
    state: FormState, key: str, label: str, default: float | None = None
) -> float:
    raw = state.get(key)
    if raw is None or str(raw).strip() == "":
        if default is not None:
            return default
        raise FormError("positive_number", label=label)
    try:
        value = float(str(raw).strip())
    except ValueError as exc:
        raise FormError("positive_number", label=label) from exc
    if value <= 0:
        raise FormError("positive_number", label=label)
    return value


def _safe_stem(value: str, fallback: str) -> str:
    stem = re.sub(r"[\x00-\x1f/\\:*?\"<>|]", "_", value).strip().strip(".")
    if stem.lower().endswith(".json"):
        stem = stem[:-5].rstrip(" .")
    stem = re.sub(r"\.{2,}", "_", stem)[:80].strip(" .")
    return stem or fallback


def _data_versions(raw: str) -> list[str]:
    parts = [part for part in re.split(r"[\s,;]+", raw.strip()) if part]
    versions: list[str] = []
    for part in parts:
        try:
            version = int(part, 10)
        except ValueError as exc:
            raise FormError("invalid_data_version") from exc
        if version <= 0:
            raise FormError("invalid_data_version")
        if str(version) not in versions:
            versions.append(str(version))
    return versions


def build_plan(state: FormState, python_executable: str | None = None) -> ImportPlan:
    world, region_count, source_data_version = inspect_world(
        str(state.get("world")), str(state.get("dimension"))
    )
    command = [
        python_executable or sys.executable,
        str(IMPORTER),
        "--world",
        str(world),
        "--dimension",
        str(state.get("dimension")),
    ]

    range_mode = str(state.get("range_mode"))
    if range_mode == "chunk":
        from_chunk = (
            _integer(state, "from_chunk_x", "field.from_chunk"),
            _integer(state, "from_chunk_z", "field.from_chunk"),
        )
        to_chunk = (
            _integer(state, "to_chunk_x", "field.to_chunk"),
            _integer(state, "to_chunk_z", "field.to_chunk"),
        )
        y_min = _integer(state, "y_min", "unit.min_y")
        y_max = _integer(state, "y_max", "unit.max_y")
        if y_min > y_max:
            raise FormError("y_order")
        command.extend(
            [
                "--from-chunk",
                str(from_chunk[0]),
                str(from_chunk[1]),
                "--to-chunk",
                str(to_chunk[0]),
                str(to_chunk[1]),
                "--y-range",
                str(y_min),
                str(y_max),
            ]
        )
    elif range_mode == "block":
        from_block = (
            _integer(state, "from_x", "unit.x"),
            _integer(state, "from_y", "unit.y"),
            _integer(state, "from_z", "unit.z"),
        )
        to_block = (
            _integer(state, "to_x", "unit.x"),
            _integer(state, "to_y", "unit.y"),
            _integer(state, "to_z", "unit.z"),
        )
        command.extend(
            [
                "--from",
                *(str(value) for value in from_block),
                "--to",
                *(str(value) for value in to_block),
            ]
        )
    else:
        raise FormError("range_mode")

    origin = (
        _integer(state, "origin_x", "unit.x", 0),
        _integer(state, "origin_y", "unit.y", 0),
        _integer(state, "origin_z", "unit.z", 0),
    )
    command.extend(["--origin", *(str(value) for value in origin)])
    if bool(state.get("keep_coords")):
        command.append("--keep-coords")

    max_blocks = _integer(state, "max_blocks", "field.max_blocks", 0)
    if max_blocks < 0:
        raise FormError("invalid_integer", label="field.max_blocks")
    command.extend(["--max-blocks", str(max_blocks)])

    for version in _data_versions(str(state.get("data_versions"))):
        command.extend(["--allow-data-version", version])
    if bool(state.get("auto_data_version")):
        command.append("--auto-data-version")
    if bool(state.get("allow_mixed")):
        command.append("--allow-mixed-data-versions")
    if bool(state.get("skip_nbt")):
        command.append("--skip-block-entity-nbt")
    else:
        command.append("--preserve-block-entity-nbt")
    if bool(state.get("replace_invalid_nbt")):
        command.append("--replace-invalid-nbt-utf8")

    data_text = str(state.get("data_dir") or "").strip()
    if not data_text:
        raise FormError("data_dir_required")
    data_dir = pathlib.Path(data_text).expanduser()
    if not data_dir.is_absolute():
        data_dir = TOOL_ROOT / data_dir
    data_dir = data_dir.resolve()

    output_mode = str(state.get("output_mode"))
    world_name = world.name or "world"
    if output_mode == "save":
        save_name = importer.gmod_save_slot_name(
            str(state.get("save_name") or world_name)
        )
        if not save_name:
            raise FormError("save_name_invalid")
        save_format = str(state.get("save_format") or "auto")
        if save_format not in ("auto", "classic", "chunked", "streaming"):
            raise FormError("save_format")
        block_size = _positive_float(state, "block_size", "field.block_size", 36.5)
        part_size = _integer(state, "part_size", "field.part_size", 4 * 1024 * 1024)
        if part_size < 64 * 1024:
            raise FormError("part_size", minimum=64 * 1024)
        save_out = data_dir / "mc" / "saves" / f"{save_name}.dat"
        command.extend(
            [
                "--save-name",
                save_name,
                "--save-out",
                str(save_out),
                "--save-format",
                save_format,
                "--block-size",
                str(block_size),
                "--save-part-json-bytes",
                str(part_size),
            ]
        )
        save_map = str(state.get("save_map") or "").strip()
        if save_map:
            command.extend(["--save-map", save_map])
        output_path = save_out
    elif output_mode == "json":
        output_name = _safe_stem(
            str(state.get("output_name") or world_name), world_name
        )
        output_path = data_dir / "mc_import" / f"{output_name}.json"
        command.extend(["--out", str(output_path)])
        command.append(
            "--split-chunks"
            if bool(state.get("split_chunks"))
            else "--no-split-chunks"
        )
    else:
        raise FormError("output_mode")

    return ImportPlan(
        command=command,
        output_path=output_path,
        data_dir=data_dir,
        world_name=world_name,
        region_count=region_count,
        source_data_version=source_data_version,
    )
