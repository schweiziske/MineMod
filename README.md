# MCSWEP

Garry's Mod 里的 Minecraft 风格方块系统。方块不按实体逐个生成，而是存进 chunk section，客户端用 `IMesh` 合批渲染，服务端和客户端各用 `mc_chunk` 实体构建碰撞。

## 当前状态

- 方块边长是 `36.5` Source units。
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
- 水/岩浆保持非碰撞 voxel；玩家进入时共享 `SetupMove` 模拟 Source/Minecraft 风格游泳阻力和上浮/下潜，客户端在眼睛进液体后绘制水下/岩浆视觉效果。
- `*_fence_gate` 渲染、碰撞和选中都使用生成模型盒，不能退回整块 `FullBlockBox`。
- `mc_autosave` 默认是 `0`，自动保存关闭。
- `mc_save_public` 默认是 `0`，命名存档读取/保存默认仅管理员；设为 `1` 后普通玩家也能读取/保存，删除仍仅管理员。
- 栅栏、玻璃板、铁栅栏、墙、紫颂植株等动态连接方块通过 `MC.GeneratedBlockConnections` 标记，runtime 只按这个显式表处理连接/碰撞。

## 主要文件

```text
lua/autorun/mc_load.lua                  加载入口
lua/mc/sh_config.lua                     尺寸、ConVar、net bit、atlas 配置
lua/mc/sh_blocks.lua                     方块注册、状态、朝向、碰撞盒
lua/mc/sh_presets.lua                    建筑预设坐标/朝向旋转和覆盖体积变换
lua/mc/sh_voxel.lua                      方块存储、坐标换算、方块射线
lua/mc/functional/sh_ladders.lua         梯子 Source ladder movetype 的共享移动预测
lua/mc/functional/sh_liquids.lua         水/岩浆游泳手感和水下视觉效果
lua/mc/sv_world.lua                      服务端世界 API、放置、破坏、导入、保存、同步
lua/mc/sv_saves.lua                      命名存档管理、元数据、存档 UI 网络接口
lua/mc/sv_presets.lua                    建筑预设保存、读取、放置和封面网络接口
lua/mc/sv_damage.lua                     GMod 伤害破坏方块、MC 风格爆炸坑
lua/mc/cl_net.lua                        客户端同步接收
lua/mc/cl_render.lua                     客户端 IMesh 渲染和预测碰撞 dirty
lua/mc/cl_ui.lua                         方块图标、选择窗口、选中框
lua/mc/cl_save_ui.lua                    命名存档管理 UI
lua/mc/cl_presets.lua                    建筑预设 UI、截图和 IMesh 投影
lua/entities/mc_chunk/                   chunk 实体和 multiconvex 碰撞
lua/weapons/mc_placer/shared.lua         方块放置器 SWEP
lua/weapons/mc_creative_placer/shared.lua 创造物品栏方块放置器 SWEP
lua/weapons/mc_preset_placer/shared.lua  建筑预设放置器 SWEP
lua/weapons/gmod_tool/stools/mc_block.lua 工具枪方块工具
lua/mc/generated/                        生成的方块、tile、中文名 Lua
_build/build_atlas.ps1                   生成 atlas 和方块表
_build/build_block_properties.cjs        生成 hardness/explosionResistance 表
_build/build_block_connections.cjs       生成连接/贴附类方块表
_tools/mc_convert_8x8_save.py            老版本 Parkour Spiral 转存工具
_tools/mc_import_world.py                通用 Minecraft 存档导出工具
docs/maintenance-update-guide.md         维护更新指南
docs/interface-usage.md                  接口使用介绍
```

## 常用命令

重新生成 atlas 和方块表：

```powershell
powershell -ExecutionPolicy Bypass -File _build\build_atlas.ps1 -McOut .\out
node _build\build_block_connections.cjs
node _build\build_block_properties.cjs
```

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
  "lua\autorun\mc_load.lua",
  "lua\mc\sh_blocks.lua",
  "lua\mc\sh_presets.lua",
  "lua\mc\sh_config.lua",
  "lua\mc\functional\sh_ladders.lua",
  "lua\mc\functional\sh_liquids.lua",
  "lua\mc\cl_ui.lua",
  "lua\mc\cl_save_ui.lua",
  "lua\mc\cl_presets.lua",
  "lua\mc\sv_saves.lua",
  "lua\mc\sv_presets.lua",
  "lua\mc\sv_damage.lua",
  "lua\entities\mc_chunk\init.lua",
  "lua\weapons\mc_creative_placer\shared.lua",
  "lua\weapons\mc_preset_placer\shared.lua",
  "lua\mc\generated\sh_generated_block_connections.lua",
  "lua\mc\generated\sh_generated_block_properties.lua",
  "lua\mc\generated\sh_generated_sound_types.lua"
)
$luaFiles += (Get-ChildItem "lua\mc\generated\sh_generated_block_properties_part*.lua").FullName
$luaFiles += (Get-ChildItem "lua\mc\generated\sh_generated_sound_types_part*.lua").FullName
foreach ($f in $luaFiles) {
  npm exec --yes --package luaparse -- luaparse $f > $null
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
python -m py_compile _tools\mc_convert_8x8_save.py _tools\mc_import_world.py
git diff --check
```

`lua/mc/sv_world.lua` 使用 GMod Lua 的 `continue`，普通 Lua parser 可能不认；不要把这个误判成新增语法错误。

## 文档入口

- [维护更新指南](docs/maintenance-update-guide.md)
- [接口使用介绍](docs/interface-usage.md)
- [mc_import_world.py 用法](docs/mc-import-world.md)
- [Chunk 高度修改说明](docs/chunk-height.md)
