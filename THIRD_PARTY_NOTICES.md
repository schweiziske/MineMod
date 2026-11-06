# 第三方声明

MineMod 自身的代码以 [MIT](LICENSE) 发布。下列内容不属于该许可证，各自保留原作者的版权和许可。

## Minecraft 资源

仓库中的 Minecraft 贴图、声音、方块/物品模型、blockstate、语言文本等资源版权归 Mojang Studios 所有，主要位于：

- `addons/mc_texturepack_default/`、`addons/mc_texturepack_programmer_art/`
- `addons/mc_game/materials/`、`addons/mc_game/sound/`
- `addons/mc_engine/sound/`
- 由 Minecraft 资源生成的方块表、物品表和翻译词条

方块行为、属性和数值参照 Minecraft Java 版实现。本项目是非官方作品，与 Mojang Studios 和 Microsoft 无关，也未获得其认可或授权。使用和再分发这些资源须遵守 [Minecraft 使用准则](https://www.minecraft.net/usage-guidelines) 和 [Minecraft EULA](https://www.minecraft.net/eula)。

## 随附的第三方代码和资源

| 组件 | 位置 | 用途 | 许可 |
| --- | --- | --- | --- |
| Source SDK 头文件与 `tier0` 导入库（基于 [sourcesdk-minimal](https://github.com/danielga/sourcesdk-minimal)） | `native/sdk/` | Native 模块调用引擎接口 | Source 1 SDK License；版本与本地适配见 [SDK 来源](native/sdk/README.md)，保留该目录的 LICENSE 与 thirdpartylegalnotices.txt |
| Garry's Mod Lua 模块头文件 | `native/include/GarrysMod/` | Native 模块的 Lua 接口 | Facepunch [gmod-module-base](https://github.com/Facepunch/gmod-module-base) |
| [miniz](https://github.com/richgel999/miniz) | `native/include/miniz/` | ZIP/deflate | MIT，见目录内 `LICENSE` |
| [RapidJSON](https://github.com/Tencent/rapidjson) | `native/include/rapidjson-master/` | JSON 解析 | MIT，见目录内 `license.txt` |
| LZMA SDK 解码器（Igor Pavlov） | `native/include/lzma/` | LZMA 解码 | Public domain |
| [LibDeflate](https://github.com/safeteeWow/LibDeflate) | `addons/mc_engine/lua/mc/resources/vendor/libdeflate.lua` | Lua 端 deflate | zlib License |
| [GNU Unifont](https://unifoundry.com/unifont/) | `addons/mc_engine/materials/mc/font/` | CJK 位图字体 | 字体为 SIL OFL 1.1 及带字体嵌入例外的 GPL，见 `addons/mc_engine/data_static/mc/licenses/unifont.txt` |
| [Poly Haven](https://polyhaven.com/a/kloofendal_48d_partly_cloudy) HDRI「Kloofendal 48d Partly Cloudy」（Greg Zaal） | `tools/shader_compiler/shadersrc/l2/pbr_assets/` | PBR 光影包环境光源图 | CC0 1.0 |

## 移植或参考的算法

| 项目 | 位置 | 使用方式 | 上游许可 |
| --- | --- | --- | --- |
| [Google Filament](https://github.com/google/filament) | PBR 光影包 BRDF 与 IBL | 将 GGX、Smith 可见性、Fresnel、split-sum IBL、多次散射补偿、高光遮蔽改写为 HLSL SM3 | Apache-2.0，见 `third_party/filament/` |
| [three.js](https://github.com/mrdoob/three.js) | PBR 光影包水面 | 改写 Water2 的 Fresnel 混合和 SSRShader 的屏幕空间光线步进 | MIT，见 `third_party/threejs/` |
| [Complementary Reimagined](https://github.com/ComplementaryDevelopment/ComplementaryReimagined) | PBR 材质分类 | 参考其方块分类、材质响应数值和贴图区域遮罩，用自有生成器和贴图实现；未包含上游 GLSL 或资源 | Complementary License Agreement 1.7，见 `third_party/complementary/` |
| [Iris](https://github.com/IrisShaders/Iris) | `addons/mc_engine/lua/mc/render/cl_render_shadow_math.lua`、`cl_render_pbr_shadows.lua` | 参照其阴影视锥的世界空间网格对齐方式 | LGPL-3.0 |
| [Photon](https://github.com/sixthsurge/photon) | `addons/mc_engine/lua/mc/render/cl_mesh_shadow_map.lua` 及阴影深度 shader | 参照其阴影图畸变公式 | Photon Shaders License Agreement |
| [GWater2](https://github.com/meetric1/gwater2) | `addons/mc_engine/lua/mc/liquid/sh_movement.lua` | 参照其玩家游泳的移动系数和积分方式 | GPL-3.0 |