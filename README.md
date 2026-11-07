# MineMod

English | [简体中文](docs/zh/project.md)

MineMod brings Minecraft's block worlds and creative and survival gameplay to Garry's Mod. Build worlds, use items, crafting recipes, and containers, and save or share your builds through world saves and building presets. Resource packs, shader packs, and Java Edition world importing are also supported.

**For installation and gameplay, see the [user manual](docs-user/README.md).** This page is for developers.

## Repository layout

GMod does not mount nested directories. Each directory under `addons/` is a separate addon.

| Addon | Purpose |
| --- | --- |
| `mc_engine` | Required. Block worlds, states, networking, rendering, collision, lighting, saves, `MC.API`, and tools such as the creative and preset placers |
| `mc_texturepack_default` | Required. Default atlas and missing-texture fallback; cannot be disabled |
| `mc_shaderpack_vanilla` | Default shader pack |
| `mc_game` | Survival gameplay: items, inventory, recipes, mining, drops, and containers. Uses the engine only through `MC.API` |
| `mc_item` | MC item weapons, models, materials, and sounds |
| `mc_shaderpack_pbr` | Optional PBR shader pack |
| `mc_skybox_block` | Block skybox |
| `mc_texturepack_programmer_art` | Optional classic resource pack whose atlas is baked in game |

The engine does not depend on the gameplay layer. Each entity or weapon belongs to one addon, as recorded in [addons/ownership.json](addons/ownership.json). Two addons must not provide the same relative mount path.

Other directories:

| Directory | Contents |
| --- | --- |
| `native/` | Optional client C++ module for section mesh construction, lighting, and resource uploads |
| `tools/shader_compiler/` | Shader sources and build entry points for shader packs and the skybox |
| `tools/content/` | Generates `mc_game` item catalogs from Minecraft client assets |
| `tools/localization/` | Localization catalog generation and validation |
| `tools/world importer/` | Java Edition world importer with a graphical interface |
| `tools/tests/` | Offline Lua regression tests |
| `examples/` | Minimal third-party addon examples for registering blocks, items, and creative tabs |
| `third_party/` | Upstream licenses and notices for ported algorithms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |

## Local development

Mount the required addons into GMod using directory junctions. Edits take effect on the next launch:

```powershell
$gmod = "D:\steam\steamapps\common\GarrysMod\garrysmod"
foreach ($name in "mc_engine", "mc_texturepack_default", "mc_shaderpack_vanilla", "mc_game", "mc_item") {
    New-Item -ItemType Junction -Path "$gmod\addons\$name" -Target (Resolve-Path "addons\$name")
}
```

Fully restart the game after adding or removing mounts. Hold `C` and click **MC Config**, or enter `mc_config` in the console to open settings.

### Native module

Requires Visual Studio with the MSVC x64 tools, CMake, and Ninja components:

```powershell
powershell -File native\build.ps1                     # Release_Final, x64, automatic GMod branch detection
powershell -File native\build.ps1 -Branch public -Architecture x86
powershell -File native\build.ps1 -Tests              # Also build and run C++ tests
```

The output is `native/build/<arch>/<preset>/bin/gmcl_minemod_native_win64.dll` (`win32` for x86). Place it in the client's `garrysmod/lua/bin/` and restart. Servers do not distribute DLLs; clients without the module use Lua. See the [Native module guide](docs/native.md) for installation, troubleshooting, and source organization. Read the Native rules in [AGENTS.md](AGENTS.md) before editing C++.

### Shaders

Prepare the compiler, then run the relevant entry point. See [Shader compiler tools](tools/shader_compiler/README.md):

```powershell
powershell -NoProfile -File tools/shader_compiler/setup_toolchain.ps1
node tools/shader_compiler/build_l2_vanilla.cjs
node tools/shader_compiler/build_l2_pbr.cjs
node tools/shader_compiler/build_skybox_block.cjs
```

### Generated content

```powershell
powershell -File tools/content/generate_items.ps1 -MinecraftRoot <Minecraft-client-directory-with-decompiled-sources-and-assets>
python tools/localization/generate_minecraft_lang.py --lang-dir <Minecraft-client-assets/minecraft/lang>
```

## Tests

```powershell
python tools/localization/check_catalogs.py
python -m unittest discover -s tools/tests -p "test_*.py"      # Requires lupa
python tools/localization/tests/test_i18n_content.py --deps <directory-containing-lupa>
powershell -File native\build.ps1 -Tests
```

These tests run offline. Verify changes that depend on GMod rendering, physics, or engine resources in the game.

## Extensions

External addons should access the engine only through `MC.API`; see the [developer API](docs/api.md). [examples/mod_api_example.lua](examples/mod_api_example.lua) shows how to register blocks, items, and creative tabs without modifying this repository. Put display text in the addon's `data_static/mc/i18n/` catalogs; see the [localization contract](docs/localization.md).

## Contributing

Issues and pull requests are welcome. Read [AGENTS.md](AGENTS.md), particularly the rules for coordinate spaces, GLua multiple returns, and validation in hot paths. Report failures according to the [fault-handling contract](docs/fault-handling.md). Register new `docs/` documents in [docs/README.md](docs/README.md).

## Documentation

| Document | Contents |
| --- | --- |
| [docs/api.md](docs/api.md) | `MC.API` reference for third-party addons |
| [docs/native.md](docs/native.md) | Native module installation, troubleshooting, and source builds |
| [AGENTS.md](AGENTS.md) | Engineering rules: coordinates, GLua multiple returns, validation, performance, and documentation |
| [CONTEXT.md](CONTEXT.md) | Shared definitions for block states, sections, world packages, and overlays |
| [docs/README.md](docs/README.md) | Engineering documentation index |
| [docs-user/README.md](docs-user/README.md) | User manual: installation, gameplay, saves, presets, resource packs, shader packs, and importing |
| [convar.md](convar.md) | `mc_*` ConVars and their defaults |

## License

MineMod's code is licensed under [MIT](LICENSE).

Minecraft textures, sounds, models, and other assets belong to Mojang Studios and are outside the MIT license. This is an unofficial project, unaffiliated with Mojang Studios or Microsoft.

Parts of the PBR shader pack and other systems reference or port work from Iris, Photon, Complementary Reimagined, Google Filament, and three.js. The repository also includes Source SDK, miniz, RapidJSON, LibDeflate, and GNU Unifont components. Their sources and licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
