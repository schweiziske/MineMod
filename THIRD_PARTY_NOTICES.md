# Third-party notices

English | [简体中文](docs/zh/THIRD_PARTY_NOTICES.md)

MineMod's own code is licensed under [MIT](LICENSE). The components below are outside that license and retain their authors' copyrights and licenses.

## Minecraft assets

Minecraft textures, sounds, block/item models, block states, language text, and related assets belong to Mojang Studios. They are primarily located in:

- `addons/mc_texturepack_default/` and `addons/mc_texturepack_programmer_art/`
- `addons/mc_game/materials/` and `addons/mc_game/sound/`
- `addons/mc_engine/sound/`
- Block catalogs, item catalogs, and translations generated from Minecraft assets

Block behavior, properties, and values follow Minecraft Java Edition. This unofficial project is unaffiliated with, and is not endorsed or authorized by, Mojang Studios or Microsoft. Use and redistribution of these assets must comply with the [Minecraft Usage Guidelines](https://www.minecraft.net/usage-guidelines) and [Minecraft EULA](https://www.minecraft.net/eula).

## Included third-party code and assets

| Component | Location | Purpose | License |
| --- | --- | --- | --- |
| Source SDK headers and `tier0` import libraries, based on [sourcesdk-minimal](https://github.com/danielga/sourcesdk-minimal) | `native/sdk/` | Engine interface calls from the Native module | Source 1 SDK License; versions and adaptations: [SDK sources](native/sdk/README.md). Retain LICENSE and thirdpartylegalnotices.txt from that directory |
| Garry's Mod Lua module headers | `native/include/GarrysMod/` | Native Lua interface | Facepunch [gmod-module-base](https://github.com/Facepunch/gmod-module-base) |
| [miniz](https://github.com/richgel999/miniz) | `native/include/miniz/` | ZIP/deflate | MIT; directory `LICENSE` |
| [RapidJSON](https://github.com/Tencent/rapidjson) | `native/include/rapidjson-master/` | JSON parsing | MIT; directory `license.txt` |
| LZMA SDK decoder (Igor Pavlov) | `native/include/lzma/` | LZMA decoding | Public domain |
| [LibDeflate](https://github.com/safeteeWow/LibDeflate) | `addons/mc_engine/lua/mc/resources/vendor/libdeflate.lua` | Lua deflate | zlib License |
| [GNU Unifont](https://unifoundry.com/unifont/) | `addons/mc_engine/materials/mc/font/` | CJK bitmap font | SIL OFL 1.1 and GPL with the font embedding exception; see `addons/mc_engine/data_static/mc/licenses/unifont.txt` |
| [Poly Haven](https://polyhaven.com/a/kloofendal_48d_partly_cloudy) HDRI “Kloofendal 48d Partly Cloudy” (Greg Zaal) | `tools/shader_compiler/shadersrc/l2/pbr_assets/` | PBR environment lighting source | CC0 1.0 |

## Ported or referenced algorithms

| Project | Location | Use | Upstream license |
| --- | --- | --- | --- |
| [Google Filament](https://github.com/google/filament) | PBR BRDF and IBL | GGX, Smith visibility, Fresnel, split-sum IBL, multiscattering compensation, and specular occlusion rewritten in HLSL SM3 | Apache-2.0; `third_party/filament/` |
| [three.js](https://github.com/mrdoob/three.js) | PBR water | Adapted Water2 Fresnel blending and SSRShader screen-space ray marching | MIT; `third_party/threejs/` |
| [Complementary Reimagined](https://github.com/ComplementaryDevelopment/ComplementaryReimagined) | PBR material classification | Block classifications, material-response values, and texture-region masks used as references for our own generators and textures; no upstream GLSL or assets included | Complementary License Agreement 1.7; `third_party/complementary/` |
| [Iris](https://github.com/IrisShaders/Iris) | `addons/mc_engine/lua/mc/render/cl_render_shadow_math.lua`, `cl_render_pbr_shadows.lua` | Reference for world-space grid alignment of shadow frusta | LGPL-3.0 |
| [Photon](https://github.com/sixthsurge/photon) | `addons/mc_engine/lua/mc/render/cl_mesh_shadow_map.lua` and shadow-depth shaders | Reference for shadow-map distortion formulas | Photon Shaders License Agreement |
| [Valve Source SDK 2013](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/gamemovement.cpp) | `addons/mc_engine/lua/mc/liquid/sh_movement.lua` | Algorithm reference for an independent Lua implementation of swimming wish speed, friction, acceleration, and jump speed | Source 1 SDK License; see `native/sdk/LICENSE` |
