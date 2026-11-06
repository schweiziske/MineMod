# MineMod

MineMod 将 Minecraft 风格的方块世界与创造、生存玩法带进 Garry's Mod。玩家可以建造方块世界，使用物品、合成配方和容器，并通过存档与建筑预设延续和分享自己的建造。项目还支持材质包、光影包和 Java 版世界导入。

**只想安装和游玩，请看 [用户手册](docs-user/README.md)。** 本页面向开发者。

## 仓库结构

GMod 不会挂载嵌套目录，`addons/` 下的每个目录都是一个独立 addon。

| addon | 作用 |
| --- | --- |
| `mc_engine` | 必需。方块世界、状态、网络同步、渲染、碰撞、光照、存档、`MC.API`，以及创造放置器、预设放置器等工具 |
| `mc_texturepack_default` | 必需。默认 atlas 与缺失贴图回退，不能禁用 |
| `mc_shaderpack_vanilla` | 默认光影包 |
| `mc_game` | 生存玩法：物品、物品栏、配方、挖掘、掉落物、容器。只通过 `MC.API` 使用引擎 |
| `mc_item` | MC 物品武器、模型、材质和声音 |
| `mc_shaderpack_pbr` | 可选 PBR 光影包 |
| `mc_shaderpack_l2_probes` | 渲染管线调试用探针 shader |
| `mc_skybox_block` | 方块天空盒 |
| `mc_texturepack_programmer_art` / `_vanilla` / `_avpbr` | 可选材质包，在游戏内烘焙 atlas |

引擎不依赖游戏层。实体和武器各只由一个 addon 提供，归属登记在 [addons/ownership.json](addons/ownership.json)；同一相对挂载路径不能由两个 addon 重复提供。

其他目录：

| 目录 | 内容 |
| --- | --- |
| `native/` | 可选的客户端 C++ 模块，负责 section 网格构建、光照与资源上传 |
| `tools/shader_compiler/` | 光影包与天空盒的 shader 源码和构建入口 |
| `tools/content/` | 从 Minecraft 客户端资源生成 `mc_game` 物品表 |
| `tools/localization/` | 本地化词典的生成与检查 |
| `tools/world importer/` | 带界面的 Java 版存档导入工具 |
| `tools/tests/` | 离线 Lua 回归测试 |
| `examples/` | 第三方 addon 注册方块、物品和创造分类的最小示例 |
| `third_party/` | 移植算法的上游许可与说明，汇总见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) |

## 本地开发

把需要的 addon 以目录联接挂到 GMod，修改即生效于下次启动：

```powershell
$gmod = "D:\steam\steamapps\common\GarrysMod\garrysmod"
foreach ($name in "mc_engine", "mc_texturepack_default", "mc_shaderpack_vanilla", "mc_game", "mc_item") {
    New-Item -ItemType Junction -Path "$gmod\addons\$name" -Target (Resolve-Path "addons\$name")
}
```

新增或移除挂载后要完整重启游戏。游戏内按住 `C` 点击 **MC Config**，或在控制台输入 `mc_config` 打开设置。

### Native 模块

需要 Visual Studio（MSVC x64 工具、CMake 和 Ninja 组件）：

```powershell
powershell -File native\build.ps1                     # 默认 Release_Final、x64、自动识别 GMod 分支
powershell -File native\build.ps1 -Branch public -Architecture x86
powershell -File native\build.ps1 -Tests              # 同时构建并运行 C++ 测试
```

产物为 `native/build/<arch>/<preset>/bin/gmcl_minemod_native_win64.dll`（x86 为 `win32`），放进客户端 `garrysmod/lua/bin/` 后重启。服务器不会下发 DLL；没有模块时客户端走 Lua 路径。安装、排错和源码结构见 [Native 模块指南](docs/native.md)；修改 C++ 前先读 [AGENTS.md](AGENTS.md) 中的 Native 规则。

### Shader

准备编译器后运行对应入口，详见 [Shader 编译工具](tools/shader_compiler/README.md)：

```powershell
powershell -NoProfile -File tools/shader_compiler/setup_toolchain.ps1
node tools/shader_compiler/build_l2_vanilla.cjs
node tools/shader_compiler/build_l2_pbr.cjs
node tools/shader_compiler/build_skybox_block.cjs
```

### 生成内容

```powershell
powershell -File tools/content/generate_items.ps1 -MinecraftRoot <含反编译源码与资源的 Minecraft 客户端目录>
python tools/localization/generate_minecraft_lang.py --lang-dir <Minecraft 客户端的 assets/minecraft/lang 目录>
```

## 测试

```powershell
python tools/localization/check_catalogs.py
python -m unittest discover -s tools/tests -p "test_*.py"      # 需要 lupa
python tools/localization/tests/test_i18n_content.py --deps <含 lupa 的目录>
powershell -File native\build.ps1 -Tests
```

这些都是离线测试，不能替代游戏内验证。游戏内验证直接用命令行参数启动 GMod，探针把结果写到 `garrysmod/data/`。

## 扩展

外部插件只应通过 `MC.API` 访问引擎，完整接口见 [开发者 API](docs/api.md)。[examples/mod_api_example.lua](examples/mod_api_example.lua) 演示如何在不修改本仓库的情况下注册方块、物品和创造分类；显示文字放在 addon 自带的 `data_static/mc/i18n/` 词典中，格式见 [本地化契约](docs/localization.md)。

## 参与开发

欢迎提交 issue 和 pull request。提交前请先阅读 [AGENTS.md](AGENTS.md) 中的工程规则，尤其是坐标空间、GLua 多返回值和热路径校验部分。可能失败的地方要按 [故障上报约定](docs/fault-handling.md) 上报，不要静默跳过。新增 `docs/` 文档要在 [docs/README.md](docs/README.md) 登记。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/api.md](docs/api.md) | 面向第三方 addon 的 `MC.API` 参考 |
| [docs/native.md](docs/native.md) | Native 模块的安装、排错和从源码构建 |
| [AGENTS.md](AGENTS.md) | 工程规则：坐标与单位、GLua 多返回值、热路径校验、性能、文档登记 |
| [CONTEXT.md](CONTEXT.md) | 方块状态、section、世界包、覆盖层等术语的统一定义 |
| [docs/README.md](docs/README.md) | 技术文档索引，新增文档必须在此登记 |
| [docs-user/README.md](docs-user/README.md) | 用户手册：安装、玩法、存档、预设、材质包、光影包、导入 |
| [convar.md](convar.md) | 全部 `mc_*` ConVar 及默认值 |

## 许可

MineMod 的代码以 [MIT](LICENSE) 发布。

仓库中的 Minecraft 贴图、声音、模型等资源版权归 Mojang Studios 所有，不在 MIT 许可范围内。本项目是非官方作品，与 Mojang Studios 和 Microsoft 无关。

PBR 光影包等部分参考或移植了 Iris、Photon、Complementary Reimagined、Google Filament、three.js、GWater2 等项目，并随附 Source SDK、miniz、RapidJSON、LibDeflate、GNU Unifont 等第三方组件。它们各自的来源和许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
