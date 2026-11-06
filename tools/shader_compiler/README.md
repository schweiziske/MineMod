# Shader 编译工具

此目录保存 Vanilla、PBR、Skybox 和调试 shader 的构建入口、字节码校验器及 shader 源码。运行需要 Node.js 18+、Python 3 和本地编译器。

## 准备编译器

在仓库根目录运行：

```powershell
powershell -NoProfile -File tools/shader_compiler/setup_toolchain.ps1
```

默认从 `D:\steam\steamapps\common\GarrysMod\bin` 和 `D:\code\source-engine` 复制编译器与配套文件到 `toolchain/`。其他电脑可指定 `-CompilerDir` 和 `-SourceEngineDir`。这些第三方文件不会下载或提交到 Git；重新克隆后需要再次准备。

## 编译

在仓库根目录运行所需入口：

```powershell
node tools/shader_compiler/build_l2_vanilla.cjs
node tools/shader_compiler/build_l2_pbr.cjs
node tools/shader_compiler/build_skybox_block.cjs
```

三个入口均接受 `--game <GMod的garrysmod目录>`、`--toolchain <编译器目录>` 和 `--python <Python程序>`。默认游戏目录为 `D:/steam/steamapps/common/GarrysMod/garrysmod`，Python 使用 PATH 中的 `python`。Vanilla 和 PBR 还支持 `--compiler <ShaderCompile程序>` 使用兼容的现代编译器。

Vanilla/PBR 编译后会校验 SM3 字节码，并更新对应 `addons/mc_shaderpack_*` 下的 `.vcs`、描述文件及构建记录。PBR 入口还会清理该包不再引用的旧 `.vcs`。Skybox 更新 `addons/mc_skybox_block`。这些操作会修改工作区，但不会启动游戏或创建提交。

Vanilla/PBR 的 `--stage-only` 只准备编译输入，不运行编译器、不发布 shader。它仍会创建临时目录并检查所需资源。

## 显示文字与设置

描述文件中用户可见的字段只保存翻译 key（`nameKey`、`labelKey`、`helpKey` 等），译文在各 addon 的 `data_static/mc/i18n/` 下维护，见 `docs/localization.md`。译文不是构建输入，修改译文不需要重新编译或发布描述文件。

- `descriptor_display.json`：按描述文件 id 登记 `nameKey`（及可选的 `descriptionKey`）。三个入口发布描述文件时都从这里取值；它不参与 GPU 构建指纹。
- `shadersrc/l2/pbr_assets/settings.json`：PBR 的设置、分组和内置预设，显示字段同样只写 key（`shaderpack.mc_pbr.settings.<key>.label|.help`、`shaderpack.mc_pbr.groups.<id>.label`、`shaderpack.mc_pbr.presets.<id>.label`）。没有标签的枚举选项显示其数值。

只改了显示 key 或 PBR 设置时，不编译即可重新发布：

```powershell
node tools/shader_compiler/build_l2_pbr.cjs --settings-only
node tools/shader_compiler/build_l2_vanilla.cjs --display-only
node tools/shader_compiler/build_skybox_block.cjs --display-only
```

`--settings-only` 同时写入 PBR 的设置与显示 key 并重新计算描述文件的 `build`；另外两个入口只替换显示 key，程序与 `build` 不变。

Vanilla 字节码对照使用 `--reference-sources <基准源码目录>`；兼容选项 `--reference <参考仓库根目录>` 则从该外部仓库的 `tools/shader_compiler/shadersrc/mc_gpu_test/` 读取基准。这两种参数不能同时使用。

字节码对照需要基准目录中存在 `mc_vanilla_quad_vs30.fxc` 和 `mc_vanilla_quad.fxh`，且只支持旧式编译器。正常编译不需要参考源码。

## 文件位置

- `shadersrc/`：shader 源码及 PBR 设置、环境资源；Skybox 源码位于 `addons/mc_skybox_block/shadersrc/`。
- `.build/`：编译中间文件和日志，已忽略。
- `toolchain/`：本机编译器依赖，已忽略，可用准备脚本重新生成。
- `check_l2_vcs.py`、`vcs_scan.py`：构建过程使用的字节码校验与读取工具。
- `descriptor_display.cjs`、`descriptor_display.json`：描述文件显示 key 的来源与写入工具，三个发布入口共用。
- `build_engine_render_textures.cjs`：重建 engine 的中性默认材质贴图，PBR 编译会读取其现有产物。
- `build_l2_probes.cjs`：调试探针构建入口，会生成探针 autorun；正常 shader 编译无需运行。
