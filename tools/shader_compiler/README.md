# Shader compiler tools

English | [简体中文](../../docs/zh/tools/shader_compiler/README.md)

This directory contains build entry points, bytecode validators, and sources for Vanilla, PBR, Skybox, and diagnostic shaders. Requires Node.js 18+, Python 3, and a local compiler.

## Preparing the compiler

Run from the repository root:

```powershell
powershell -NoProfile -File tools/shader_compiler/setup_toolchain.ps1
```

By default, the script copies compilers and supporting files from `D:\\steam\\steamapps\\common\\GarrysMod\\bin` and `D:\\code\\source-engine` into `toolchain/`. On other computers, specify `-CompilerDir` and `-SourceEngineDir`. These third-party files are neither downloaded nor committed; prepare them again after cloning.

## Building

Run the required entry point from the repository root:

```powershell
node tools/shader_compiler/build_l2_vanilla.cjs
node tools/shader_compiler/build_l2_pbr.cjs
node tools/shader_compiler/build_skybox_block.cjs
```

All three accept `--game <GMod-garrysmod-directory>`, `--toolchain <compiler-directory>`, and `--python <Python-executable>`. The default game directory is `D:/steam/steamapps/common/GarrysMod/garrysmod`; Python defaults to `python` on PATH. Vanilla and PBR also accept `--compiler <ShaderCompile-executable>` for a compatible modern compiler.

Vanilla/PBR builds validate SM3 bytecode and update the corresponding `addons/mc_shaderpack_*` `.vcs` files, descriptors, and build records. Both remove unreferenced build-named `.vcs` files only after publishing the new descriptor. Skybox updates `addons/mc_skybox_block`. These commands modify the workspace without launching the game or creating commits.

For Vanilla/PBR, `--stage-only` prepares compiler inputs without compiling or publishing. It still creates a temporary directory and checks required resources.

To clean earlier builds without recompiling:

```powershell
node tools/shader_compiler/build_l2_vanilla.cjs --prune-only
node tools/shader_compiler/build_l2_pbr.cjs --prune-only
```

Cleanup uses the published descriptor's vertex and pixel references, not its build
hash. It stops if the descriptor is invalid or any referenced shader is missing or
empty. Only regular build-named `.vcs` files owned by that pack are removed;
other files, build records, and compiler intermediates are left unchanged.

## Corner atlas binding

Vanilla and PBR publish `cornerAtlasVersion: 1` in their pack definitions. This
declares support for square 16K, 8K, and 4K corner/AO atlases. The engine rejects
older definitions on 8K/4K layouts. `COLOR0` remains bank-local; each bank holds
1,048,576 quads. The material parameter is `bank + 64 * (16384 / atlasSize - 1)`,
in `c0.z` for base/PBR passes and `c0.y` for Vanilla dynamic lights. Shaders decode
both the bank and physical dimensions before sampling. No vertex ABI change is needed.

## Display text and settings

User-visible descriptor fields contain translation keys only (`nameKey`, `labelKey`, `helpKey`, etc.). Maintain translations under each addon's `data_static/mc/i18n/`; see [localization](../../docs/localization.md). Translations are not build inputs, so editing them does not require recompilation or descriptor publication.

- `descriptor_display.json` registers `nameKey` and optional `descriptionKey` by descriptor ID. All three publishers read it; it is not part of the GPU build fingerprint.
- `shadersrc/l2/pbr_assets/settings.json` contains PBR settings, groups, and built-in presets. Display fields use `shaderpack.mc_pbr.settings.<key>.label|.help`, `shaderpack.mc_pbr.groups.<id>.label`, and `shaderpack.mc_pbr.presets.<id>.label`. Unlabeled enum options display their values.

After changing only display keys or PBR settings, publish without compiling:

```powershell
node tools/shader_compiler/build_l2_pbr.cjs --settings-only
node tools/shader_compiler/build_l2_vanilla.cjs --display-only
node tools/shader_compiler/build_skybox_block.cjs --display-only
```

`--settings-only` writes PBR settings and display keys and recalculates the descriptor's `build`. The other two commands replace display keys while retaining programs and `build`.

Vanilla bytecode comparison accepts `--reference-sources <baseline-source-directory>`. The compatibility option `--reference <reference-repository-root>` reads `tools/shader_compiler/shadersrc/mc_gpu_test/` in that external repository. The two options are mutually exclusive.

Comparison requires `mc_vanilla_quad_vs30.fxc` and `mc_vanilla_quad.fxh` in the baseline directory and supports only the legacy compiler. Normal builds do not need reference sources.

## File locations

- `shadersrc/`: shader sources, PBR settings, and environment assets. Skybox sources live in `addons/mc_skybox_block/shadersrc/`.
- `.build/`: ignored compiler intermediates and logs.
- `toolchain/`: ignored local compiler dependencies, recreated by the setup script.
- `check_l2_vcs.py`, `vcs_scan.py`: bytecode validation and reading tools used during builds.
- `descriptor_display.cjs`, `descriptor_display.json`: display-key source and writer shared by all three publishers.
- `build_engine_render_textures.cjs`: rebuilds neutral engine material textures; PBR builds read the existing output.
- `build_l2_probes.cjs`: diagnostic probe builder that generates probe autorun code; not required for normal builds.
