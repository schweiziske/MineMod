# MCSWEP

Garry's Mod 里的 Minecraft 风格方块系统。方块不按实体逐个生成，而是存进 chunk section，客户端用 `IMesh` 合批渲染，服务端和客户端各用 `mc_chunk` 实体构建碰撞。

## 当前状态

- 方块边长默认是 `36.5` Source units；运行时代码必须读取 `MC.API.Coords.BlockSize()`，不得硬编码换算值。坐标换算和 GLua 多返回值规则见根目录 `AGENTS.md`，尤其禁止用 `and` / `or` 包裹需要接收多个返回值的函数调用。
- chunk 水平尺寸固定为 `16x16`，垂直 section 高度是 `32`。
- 客户端预测碰撞默认只在本地玩家附近 `4x4x4` 方块的小 AABB 内构建；`mc_client_collision 0` 仍可完全关闭客户端预测碰撞。
- 服务端 full sync 不再对玩家发送全图 chunk；非 world / 非 `mc_chunk` 实体附近默认同步水平 `16x16`、垂直 `4` 个 chunk，由 `mc_stream_chunk_span_xy` / `mc_stream_chunk_span_z` 控制，离开范围会发送 `mc_unload_chunk` 让客户端释放数据。
- 服务端 `mc_chunk` 碰撞实体默认只保留在非 world / 非 `mc_chunk` 实体附近 `4x4x4` 个 chunk 内，由 `mc_server_collision_chunk_span` 控制；远处 chunk 仍保留在服务端 `MC.World` 和存档中。
- 支持放置、破坏、使用、`/fill`、导入、默认存档、命名多存档、分片同步。
- 提供 `MC 创造方块放置器` SWEP；Reload 打开带分类、搜索和分页的创造物品栏。
- 提供 `MC 预设放置器` SWEP；可选择区域保存建筑预设，读取后用客户端 IMesh 投影并批量放置，E 可切换覆盖模式，G 可按 90 度步进旋转投影和实际放置。
- 提供 `MC.SV.SetBlock` / `SetBlockSpec` / `RemoveBlock` 给非玩家插件、mob、状态机写入世界。
- 支持 GMod 武器/爆炸破坏方块；血量来自 Minecraft hardness 乘 `mc_block_health_scale`。
- 方块表、atlas、中文名由 `_build/build_atlas.ps1` 从 `out/assets/minecraft` 生成。
- 方块硬度/爆炸抗性由 `_build/build_block_properties.cjs` 从 `Blocks.java` 生成。
- 连接/贴附类方块由 `_build/build_block_connections.cjs` 从 `Blocks.java` 和 Minecraft blockstate 资源显式生成，不在运行时用后缀统配猜。
- 生成 Lua 已拆到 `lua/mc/generated/`，避免单文件超过 64KB。
- 不完整方块使用 Minecraft model quads 渲染，碰撞/选中使用 `MC.BlockBoxes()`。
- 梯子不生成普通 chunk 物理薄板；玩家贴近 `minecraft:ladder` 时共享 `SetupMove` 会切到 Source/GMod `MOVETYPE_LADDER`，W/S 按视角 pitch 爬行，A/D 横移，空格脱离。
- 水/岩浆保持非碰撞 voxel；玩家进入时由共享 `Move`/`FinishMove` 预测逻辑应用 GWater2 的加速度、阻力、浮力和重力补偿，同时保留 Minecraft 水流方向，客户端在眼睛进液体后绘制水下/岩浆视觉效果。
- `*_fence_gate` 渲染、碰撞和选中都使用生成模型盒，不能退回整块 `FullBlockBox`。
- `mc_autosave` 默认是 `0`，自动保存关闭；运行时修改会立即重建/移除自动保存 timer。
- `mc_save_public` 默认是 `0`，命名存档读取/保存默认仅管理员；设为 `1` 后普通玩家也能读取/保存，删除仍仅管理员。
- 栅栏、玻璃板、铁栅栏、墙、紫颂植株等动态连接方块通过 `MC.GeneratedBlockConnections` 标记，runtime 只按这个显式表处理连接/碰撞。

## 主要文件

仓库按引擎、游戏层、渲染包和材质包拆为独立 addon。`addons/mc_engine` 不依赖游戏层，但客户端需要同时挂载默认材质包 `mc_texturepack_default` 和所用 shaderpack；`addons/mc_game` 通过 `MC.API` 消费引擎。GMod 自动加载的实体和武器也只在一个 addon 中提供，归属记录在 `addons/ownership.json`。

```text
addons/mc_engine/addon.json                 独立引擎 addon 清单
addons/mc_engine/lua/autorun/mc_load.lua    引擎加载入口
addons/mc_engine/lua/mc/                    方块世界、状态、网络、渲染、碰撞、光照和生成数据
addons/mc_engine/lua/entities/              引擎实体
addons/mc_engine/lua/weapons/               引擎武器和工具
addons/mc_engine/lua/bin/                   可选 native mesh 模块
addons/mc_texturepack_default/             必需：默认 atlas、动画、实体和粒子纹理
addons/mc_texturepack_programmer_art/      可选：Programmer Art atlas 与动画
addons/mc_texturepack_vanilla/             可选：原版游戏内烘焙源包
addons/mc_texturepack_avpbr/               可选：AVPBR 三通道游戏内烘焙源包
addons/mc_game/addon.json                   生存游戏 addon 清单
addons/mc_game/lua/autorun/mcgame_load.lua  游戏层入口(register 阶段启动)
addons/mc_game/lua/mcgame/                  物品、物品栏、配方、挖掘、掉落物和容器
addons/mc_game/lua/entities/                游戏实体
addons/mc_game/lua/weapons/                 游戏武器
addons/ownership.json                       实体和武器物理归属及 mixed 清单
_build/build_atlas.ps1                      生成 atlas 和方块表
_build/build_block_properties.cjs            生成 hardness/explosionResistance 表
_build/build_block_connections.cjs           生成连接/贴附类方块表
_tools/mc_convert_8x8_save.py                老版本 Parkour Spiral 转存工具
_tools/mc_import_world.py                    通用 Minecraft 存档导出工具
docs/README.md                               全部文档索引(新增文档必须在此登记)
docs/api.md                                  对外 API(外部插件唯一受支持入口)
docs/fault-handling.md                       故障上报约定:不要写静默失败
docs/maintenance-update-guide.md             维护更新指南
```

资源也按 addon 归属：世界 atlas、方块实体材质和动画属于上述材质包；字体、中性渲染数据图、引擎声音和 native 模块留在 `mc_engine`；物品图标、容器/HUD/配方界面、破坏阶段贴图及游戏音效属于 `mc_game`。相对挂载路径不能由两个 addon 重复提供。

材质包用 `data_static/mc/resourcepacks/<id>.json` 自动登记，不需要 Lua。四个随附包采用同一协议；默认包是启动及缺失选择的回退资源，不能禁用。将各目录分别安装或链接到 GMod 的 `garrysmod/addons/`，新增挂载后完整重启游戏。源包的准备文件仍是 Git 忽略的可再生输出，新克隆需运行准备工具；发布源包 addon 时应包含生成的 PNG 和烘焙 manifest。

## 常用命令

重新生成 atlas 和方块表：

```powershell
powershell -ExecutionPolicy Bypass -File _build\build_atlas.ps1 -McOut .\out
node _build\build_block_connections.cjs
node _build\build_block_properties.cjs
```

单独烘焙 Programmer Art atlas（按 `out/version.json` 自动下载 Mojang 官方资源包，不覆盖默认 atlas）：

```powershell
powershell -ExecutionPolicy Bypass -File _build\bake_programmer_art_atlas.ps1
```

烘焙完成后可在游戏内配置菜单的“界面 → 材质包 → 打开管理器”中选择并应用。
管理器自动列出 JSON 声明的包，也兼容通过 Lua API 动态注册的包，支持搜索、详情、撤销和模式接管提示。
当前一次启用一个材质包。先按 [游戏内烘焙说明](docs/runtime-atlas-baking.md) 准备源图，之后在管理器选择原版或 AVPBR 并点「应用」，会自动烘焙并切换；同一局内复用已生成的 atlas，下次进地图自动恢复。AVPBR 同时生成颜色、法线与 LabPBR 材质 atlas。「烘焙材质」仅供手动重烘。通用多层资源覆盖后续接入。控制台入口：

```text
mc_texture_packs
mc_atlas_bake_vanilla
mc_texture_pack programmer_art
mc_texture_pack default
```

默认输出 `materials/mc/atlas_365_programmer_art.{png,vmt}` 和对应的
`_translucent` 文件。也可以通过 `-PackPath <zip或目录>` 使用本地资源包；Programmer
Art 没有提供的现代方块贴图会自动回退到当前 `out/assets/minecraft`。

导入 Parkour Spiral：

```powershell
python _tools\mc_convert_8x8_save.py --world "D:\mc\Parkour Spiral" --box -75 -64 -58 86 255 57 --out "D:\server\TEST\garrysmod\data\mc_import\parkour_spiral_8x8.json"
```

游戏内：

```text
mc_import parkour_spiral_8x8 replace
mc_clear
mc_rebuild
mc_resync
mc_save
mc_save <name>
mc_save_list
mc_saves
mc_load_save <name>
mc_delete_save <name>
mc_save_diag
mc_save_manager
mc_saves_ui
mc_preset_manager
mc_presets_ui
```

## 验证

```powershell
node _tools\test_block_properties.js
node _tools\test_atlas_padding_policy.js
node _tools\test_programmer_art_atlas_bake.js
node _tools\test_block_damage_api.js
node _tools\test_creative_inventory.js
node _tools\test_preset_placer.js
node _tools\test_save_manager.js
node _tools\test_fence_behavior.js
node _tools\test_functional_blocks.js
node _tools\test_generated_block_connections.js
node _tools\test_particle_alpha_flags.js
node _tools\test_generated_lua_size.js
node _tools\test_interest_range_policy.js
powershell -ExecutionPolicy Bypass -File _tools\check_streaming_sync.ps1
$luaFiles = @(
  "addons\mc_engine\lua\autorun\mc_load.lua",
  "addons\mc_engine\lua\mc\sh_blocks.lua",
  "addons\mc_engine\lua\mc\sh_presets.lua",
  "addons\mc_engine\lua\mc\sh_config.lua",
  "addons\mc_engine\lua\mc\functional\sh_ladders.lua",
  "addons\mc_engine\lua\mc\liquid\sh_registry.lua",
  "addons\mc_engine\lua\mc\liquid\sh_shapes.lua",
  "addons\mc_engine\lua\mc\liquid\sh_flow.lua",
  "addons\mc_engine\lua\mc\liquid\sh_contact.lua",
  "addons\mc_engine\lua\mc\liquid\sh_movement.lua",
  "addons\mc_engine\lua\mc\cl_ui.lua",
  "addons\mc_engine\lua\mc\cl_save_ui.lua",
  "addons\mc_engine\lua\mc\cl_presets.lua",
  "addons\mc_engine\lua\mc\sv_saves.lua",
  "addons\mc_engine\lua\mc\sv_presets.lua",
  "addons\mc_engine\lua\mc\sv_damage.lua",
  "addons\mc_engine\lua\entities\mc_chunk\init.lua",
  "addons\mc_engine\lua\weapons\mc_creative_placer\shared.lua",
  "addons\mc_engine\lua\weapons\mc_preset_placer\shared.lua",
  "addons\mc_engine\lua\mc\generated\sh_generated_block_connections.lua",
  "addons\mc_engine\lua\mc\generated\sh_generated_block_properties.lua",
  "addons\mc_engine\lua\mc\generated\sh_generated_sound_types.lua"
)
$luaFiles += (Get-ChildItem "addons\mc_engine\lua\mc\generated\sh_generated_block_properties_part*.lua").FullName
$luaFiles += (Get-ChildItem "addons\mc_engine\lua\mc\generated\sh_generated_sound_types_part*.lua").FullName
foreach ($f in $luaFiles) {
  npm exec --yes --package luaparse -- luaparse $f > $null
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
python -m py_compile _tools\mc_convert_8x8_save.py _tools\mc_import_world.py
git diff --check
```

`addons/mc_engine/lua/mc/sv_world.lua` 使用 GMod Lua 的 `continue`，普通 Lua parser 可能不认；不要把这个误判成新增语法错误。

## 文档入口

**全部文档的索引在 [docs/README.md](docs/README.md)。新增文档必须在那一页登记一行。**

写代码前先看这条：**[不要写静默失败](docs/fault-handling.md)** —— 凡是"这里可能失败、失败了就跳过"的地方，用 `MC.Fault` / `MC.Need` / `MC.Check` / `MC.Try` 上报，不要写 `if X then X() end` 然后什么都不说。`mc_strict 1` 让故障直接抛错，`mc_faults` 列出记录。

- [对外 API(v2)](docs/api.md) — 外部插件唯一受支持入口
- [维护更新指南](docs/maintenance-update-guide.md) — 后续维护者的第一站
- [引擎层 / 游戏层分离](docs/engine-game-layer-split-2026-08-12.md)
- [render 子系统报告](docs/render-system.md)
- [mc_import_world.py 用法](docs/mc-import-world.md)
- [Chunk 高度修改说明](docs/chunk-height.md)
