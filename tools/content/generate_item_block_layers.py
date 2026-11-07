"""Restore block-backed item sprites from the matching Minecraft model assets.

Supply --minecraft-root with an extracted client, or --asset-url with an
assets/minecraft URL for the version in sh_generated_item_models.lua.
Requires Pillow. Existing item-only layers and display transforms are preserved.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
from urllib.request import urlopen

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
PART = re.compile(rb"\[=\[(.*?)\]=\]", re.S)


def generate(repo, read_model):
    generated = repo / "addons/mc_game/lua/mcgame/generated"
    raw = repo / "addons/mc_texturepack_default/data_static/mc/raw_default"
    materials = repo / "addons/mc_texturepack_default/materials/mc/resourcepacks/default"
    manifest = json.loads((raw / "manifest.json").read_bytes())
    tiles = {}
    for tile in manifest["tiles"]:
        tiles.setdefault(tile["resource"], tile["name"])
    parts = []
    candidates = []
    for path in sorted(generated.glob("sh_generated_item_models_part*.lua")):
        content = path.read_bytes()
        match = PART.search(content)
        entries = json.loads(match[1])
        parts.append((path, content, match, entries))
        for entry in entries:
            data = entry["d"]
            if (entry.get("m") and data.get("kind") == "flat"
                    and len(data["layers"]) == 1
                    and (data["layers"][0] is None
                         or data["layers"][0].startswith("mc/block/"))):
                candidates.append(entry)

    def resolve(entry):
        model_id = entry["m"]
        if not model_id.startswith("minecraft:item/"):
            raise ValueError(f"Unsupported model namespace: {model_id}")
        model = read_model(model_id.split(":", 1)[1])
        resource = model.get("textures", {}).get("layer0")
        if not resource or not resource.startswith("minecraft:block/"):
            raise ValueError(f"Expected a block layer0 in {model_id}: {resource}")
        texture_path = "assets/minecraft/textures/" + resource.split(":", 1)[1] + ".png"
        tile = tiles[resource.replace(":block/", ":textures/block/") + ".png"]
        image_path = materials / texture_path
        if not image_path.exists():
            image_path = raw / texture_path
        with Image.open(image_path) as image:
            width, height = image.size
            metadata_path = raw / (texture_path + ".mcmeta")
            if not metadata_path.exists():
                metadata_path = raw / (texture_path + ".mcmeta.json")
            animation = json.loads(metadata_path.read_bytes()).get("animation", {}) if metadata_path.exists() else {}
            if "width" in animation:
                width, height = animation["width"], animation.get("height", height)
            elif "height" in animation:
                height = animation["height"]
            else:
                width = height = min(width, height)
            if not (1 <= width <= 32 and 1 <= height <= 32):
                raise ValueError(f"Unsupported sprite frame: {model_id}: {width}x{height}")
            alpha = image.convert("RGBA").getchannel("A")
            rows = [sum(1 << x for x in range(width) if alpha.getpixel((x, y)) >= 128)
                    for y in range(height)]
        return {"layers": ["mc/block/" + tile],
                "blockSpriteMask": {"width": width, "height": height, "rows": rows}}

    # Resolve and validate every source before touching generated output.
    with ThreadPoolExecutor(max_workers=8) as pool:
        repaired = list(pool.map(resolve, candidates))
    for entry, data in zip(candidates, repaired):
        entry["d"].update(data)
    payloads = []
    for path, content, match, entries in parts:
        payload = json.dumps(entries, ensure_ascii=False, separators=(",", ":")).encode()
        if len(payload) > 96 * 1024:
            raise ValueError(f"Item model part exceeds the runtime limit: {path}")
        payloads.append(payload)
    for (path, content, match, _), payload in zip(parts, payloads):
        updated = content[:match.start(1)] + payload + content[match.end(1):]
        if updated != content:
            path.write_bytes(updated)
    loader = generated / "sh_generated_item_models.lua"
    content = loader.read_bytes()
    digest = hashlib.sha256(b"".join(payloads)).hexdigest().encode()
    updated = re.sub(rb'(MC.ItemModelRegistryHash = ")[a-f0-9]+(")',
                     lambda m: m[1] + digest + m[2], content)
    if updated != content:
        loader.write_bytes(updated)
    print(f"Generated {len(candidates)} block-backed item sprites and silhouette masks.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--minecraft-root", type=Path)
    source.add_argument("--asset-url", help="Versioned assets/minecraft base URL")
    parser.add_argument("--repository-root", type=Path, default=ROOT)
    args = parser.parse_args()

    def read_model(model):
        if args.minecraft_root:
            return json.loads((args.minecraft_root / "assets/minecraft/models" / (model + ".json")).read_bytes())
        with urlopen(args.asset_url.rstrip("/") + "/models/" + model + ".json", timeout=30) as response:
            return json.load(response)

    generate(args.repository_root, read_model)
