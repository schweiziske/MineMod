# ConVar 完整版

[English](../../../docs-user/09-convar-complete.md) | 简体中文

常用选项见 [ConVar 简洁版](08-convar-reference.md)。本页收录当前源码注册的变量，包括动态生成的姿态参数、内部迁移标记及旧入口保留项。

## 阅读方式

- 默认值指源码注册值；已有配置、服务器同步及版本迁移可能改变实际值。
- 客户端变量在自己的控制台修改；服务器变量在服务器控制台修改。单人游戏也区分这两个作用域。
- 在控制台输入完整变量名查看当前值；名称后加值修改。含空格的值要加引号，空字符串用 `""`。
- `mc_item` 的变量需要安装并加载对应 addon；按需创建的变量可能在首次渲染相关实体后才出现。
- 光影包内的 `shadow_resolution` 等参数不是 ConVar，见 [光影包](06-shader-packs.md)。

当前加载入口及内置按需注册共 **963 个唯一名称**，另列 **6 个旧入口专有变量**。下面逐个写出完整名称，不省略动态后缀。

数值单位按用途列标注。一个方块当前默认 36.5 Source 单位；源码中依赖方块尺寸的默认值已展开为数值，不表示运行时应写死该尺寸。

可用 `find mc_`、`find mcitem_`、`find bmb_item_test_fp_` 查询当前进程已注册项；控制台命令与其他 addon / 引擎自带变量不计入本表。

## 目录

- [界面与包选择](#convars-1)
- [服务器权限、建造与存档](#convars-2)
- [昼夜、方块更新与生存](#convars-3)
- [方块伤害与爆炸](#convars-4)
- [结构实体](#convars-5)
- [网络与区块流送](#convars-6)
- [碰撞与预测](#convars-7)
- [网格构建与绘制](#convars-8)
- [光照与兼容渲染参数](#convars-9)
- [创造模式手持方块](#convars-10)
- [MC Item：玩法与显示](#convars-11)
- [MC Item：共享第一人称锚点](#convars-12)
- [MC Item：逐物品第一人称锚点](#convars-13)
- [MC Item：使用姿态增量与拉伸](#convars-14)
- [MC Item：已上弦姿态增量](#convars-15)
- [MC Item：挥动分量倍率](#convars-16)
- [MC Item：第三人称动画类型](#convars-17)
- [MC Item：第三人称状态模型](#convars-18)
- [MC Item：第三人称姿态](#convars-19)
- [MC Item：弹丸模型朝向](#convars-20)
- [调试与性能诊断](#convars-21)
- [内部迁移标记](#convars-22)
- [旧 Native 入口保留项](#convars-23)

<a id="convars-1"></a>

## 界面与包选择

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_gamemode` | `creative` | 客户端 | 请求切换自己的模式：creative / 1、survival / 0；由服务器确认 |
| `mc_inventory_hud_offset_x` | `0` | 客户端 | 生存 HUD 水平偏移，像素 |
| `mc_inventory_hud_offset_y` | `0` | 客户端 | 生存 HUD 垂直偏移，像素 |
| `mc_inventory_hud_scale` | `0` | 客户端 | 生存 HUD 缩放上限；0 自动，正值仍受分辨率限制 |
| `mc_inventory_return_button` | `1` | 客户端 | 物品栏下方显示返回 GMod 按钮 |
| `mc_inventory_ui_offset_x` | `0` | 客户端 | 物品栏界面水平偏移，像素 |
| `mc_inventory_ui_offset_y` | `0` | 客户端 | 物品栏界面垂直偏移，像素 |
| `mc_inventory_ui_scale` | `0` | 客户端 | 物品栏与容器界面缩放上限；0 自动，正值仍受分辨率限制 |
| `mc_item_drop_draw_distance` | `96` | 客户端 | 掉落物绘制距离，方块；0 不按距离剔除 |
| `mc_join_notice` | `1` | 客户端 | 进服时显示设置入口提示 |
| `mc_language` | `auto` | 客户端 | 默认跟随 GMod，无法识别或不支持时使用英文；zh_cn 中文，en_us 英文 |
| `mc_render_pack_saved` | `mc:vanilla` | 客户端 | 进服时选用的光影包 ID；由 mc_render_pack select / off 保存 |
| `mc_texture_pack` | `mc_default_raw` | 客户端 | 当前材质包 ID |

源码：[mc_load.lua](../../../addons/mc_engine/lua/autorun/mc_load.lua)、[cl_mesh_config.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_config.lua)、[cl_render_pack_runtime.lua](../../../addons/mc_engine/lua/mc/render/cl_render_pack_runtime.lua)、[sh_game_mode.lua](../../../addons/mc_engine/lua/mc/sh_game_mode.lua)、[sh_i18n.lua](../../../addons/mc_engine/lua/mc/sh_i18n.lua)、[cl_init.lua](../../../addons/mc_game/lua/entities/mc_item_drop/cl_init.lua)、[cl_theme.lua](../../../addons/mc_game/lua/mcgame/inventory/ui/cl_theme.lua)。

<a id="convars-2"></a>

## 服务器权限、建造与存档

服务器决定权限和实际游戏规则；名称中出现 client 也不表示可由客户端修改。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_admin_only` | `0` | 服务器 | 仅管理员可放置、破坏方块 |
| `mc_allow_gamemode_switch` | `1` | 服务器 | 允许玩家切换自己的创造 / 生存模式 |
| `mc_autosave` | `0` | 服务器 | 自动保存间隔，秒；0 关闭，写入当前地图默认档 |
| `mc_cluster_public` | `0` | 服务器 | 普通玩家可使用结构搬运器 |
| `mc_default_gamemode` | `creative` | 服务器 | 新玩家默认模式：creative 或 survival；不覆盖已保存的玩家模式 |
| `mc_fill_batch_cells` | `4096` | 服务器 | 每个 /fill 服务器批次最多处理的格数 |
| `mc_fill_batch_chunks` | `16` | 服务器 | 每个 /fill 服务器批次最多触及的区块数 |
| `mc_fill_batch_interval` | `0.05` | 服务器 | /fill 服务器批次间隔，秒 |
| `mc_fill_max` | `100000` | 服务器 | 单次 /fill 体积上限；0 不限 |
| `mc_import_max` | `0` | 服务器 | 单次世界导入方块数上限；0 不限 |
| `mc_inventory_action_rate` | `80` | 服务器 | 每位玩家每秒允许的服务器物品栏操作数 |
| `mc_inventory_persist` | `1` | 服务器 | 按 SteamID64 保存玩家 MC 物品栏 |
| `mc_keep_inventory` | `0` | 服务器 | 死亡保留 MC 物品栏与装备 |
| `mc_max_blocks` | `0` | 服务器 | 世界方块总数上限；0 不限 |
| `mc_preset_max_blocks` | `100000` | 服务器 | 单个预设保存 / 放置的非空气方块数上限；0 不限 |
| `mc_preset_public` | `0` | 服务器 | 普通玩家可列出、保存、读取和放置预设 |
| `mc_reach` | `182.5` | 服务器 | 放置、破坏距离，Source 单位；默认按 5 个方块尺寸计算，0 关闭检查 |
| `mc_save_public` | `0` | 服务器 | 普通玩家可列出、保存和读取存档；删除仍限管理员 |
| `mc_use_interact` | `1` | 服务器 | 右键与瞄准的可用 MC 方块交互；E 不用于方块交互 |
| `mc_workshop_manage` | `0` | 服务器 | 工坊世界发布 / 导入权限：0 超级管理员、1 管理员、2 所有人 |
| `mc_world_limit` | `1024` | 服务器 | 每个轴允许的最大绝对方块坐标 |

源码：[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)、[sh_game_mode.lua](../../../addons/mc_engine/lua/mc/sh_game_mode.lua)、[sv_presets.lua](../../../addons/mc_engine/lua/mc/sv_presets.lua)、[sv_saves.lua](../../../addons/mc_engine/lua/mc/sv_saves.lua)、[sv_workshop.lua](../../../addons/mc_engine/lua/mc/workshop/sv_workshop.lua)。

<a id="convars-3"></a>

## 昼夜、方块更新与生存

本节由服务器控制。mc_gameplay_parity_* 在共享端也有注册，服务器注册带复制标记；实际物理与交互由服务器执行。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_atmos_fixed_time` | `7` | 服务器 | Atmos 锁定时间，十进制小时，0–24 |
| `mc_atmos_time_locked` | `0` | 服务器 | 安装 Atmos 时将其时间锁定为 mc_atmos_fixed_time |
| `mc_block_update_max_cells_per_tick` | `16384` | 服务器 | 每逻辑刻由方块更新产生的事务格数软上限 |
| `mc_block_update_max_depth` | `64` | 服务器 | 异步邻居更新链深度上限 |
| `mc_block_update_max_per_tick` | `4096` | 服务器 | 每个 20 TPS 逻辑刻最多执行的方块更新回调数 |
| `mc_block_update_max_queue` | `262144` | 服务器 | 就绪和计划方块更新的队列总上限 |
| `mc_block_updates_enabled` | `1` | 服务器 | 启用邻居更新队列与计划方块刻 |
| `mc_daycycle` | `0` | 服务器 | MC 昼夜循环；关闭时使用地图太阳方向 |
| `mc_daycycle_follow_atmos` | `0` | 服务器 | 安装 Atmos 时跟随其昼夜时钟 |
| `mc_daycycle_length` | `1200` | 服务器 | 完整 MC 一天的现实秒数 |
| `mc_daycycle_paused` | `0` | 服务器 | 暂停 MC 昼夜时钟 |
| `mc_farming_mob_griefing` | `1` | 服务器 | 允许非玩家活体踩坏耕地 |
| `mc_fire_tick` | `1` | 服务器 | 火自行老化并熄灭；缺少支撑的火仍会移除 |
| `mc_gameplay_parity_block_physics` | `0` | 服务器 | 启用冰、蜂蜜、蛛网、灵魂类及黏液块的 MC 物理规则 |
| `mc_gameplay_parity_decorations` | `0` | 服务器 | 启用画、盔甲架和物品展示框的 MC 规则 |
| `mc_gameplay_parity_item_entity` | `0` | 服务器 | 启用掉落物实体的 MC 物理和生命周期规则 |
| `mc_gameplay_parity_logistics` | `0` | 服务器 | 启用漏斗、发射器和投掷器的 MC 物流规则 |
| `mc_random_tick_max_callbacks_per_tick` | `1024` | 服务器 | 每逻辑刻最多分发的随机刻回调数；也计入总更新回调预算 |
| `mc_random_tick_max_samples_per_tick` | `4096` | 服务器 | 随机刻生产器每逻辑刻最多采样的方块位置数 |
| `mc_random_tick_max_sections_per_tick` | `1024` | 服务器 | 随机刻生产器每逻辑刻最多检查的已加载 16³ 区段数 |
| `mc_random_tick_speed` | `3` | 服务器 | 每个符合条件的 16³ 区段每逻辑刻的随机采样次数 |
| `mc_redstone_input_scan_budget` | `256` | 服务器 | 每 0.1 秒最多检查的活动压力板 / 日光输入数 |
| `mc_water_clear_flowing` | `0` | 服务器 | 清除独立流动水，保留水源和含水方块 |
| `mc_water_source_conversion` | `1` | 服务器 | 允许符合支撑条件的相邻水源生成新水源 |

源码：[sv_scheduler.lua](../../../addons/mc_engine/lua/mc/block_update/sv_scheduler.lua)、[sh_core.lua](../../../addons/mc_engine/lua/mc/daycycle/sh_core.lua)、[sv_atmos.lua](../../../addons/mc_engine/lua/mc/daycycle/sv_atmos.lua)、[sv_trampling.lua](../../../addons/mc_engine/lua/mc/farming/sv_trampling.lua)、[sv_water_cleanup.lua](../../../addons/mc_engine/lua/mc/liquid/sv_water_cleanup.lua)、[sv_water_state.lua](../../../addons/mc_engine/lua/mc/liquid/sv_water_state.lua)、[sv_inputs.lua](../../../addons/mc_engine/lua/mc/redstone/sv_inputs.lua)、[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)、[sh_rules.lua](../../../addons/mc_game/lua/mcgame/block_physics/sh_rules.lua)、[sh_rules.lua](../../../addons/mc_game/lua/mcgame/decoration/sh_rules.lua)、[sh_rules.lua](../../../addons/mc_game/lua/mcgame/item_entity/sh_rules.lua)、[sh_rules.lua](../../../addons/mc_game/lua/mcgame/logistics/sh_rules.lua)。

<a id="convars-4"></a>

## 方块伤害与爆炸

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_block_damage` | `1` | 服务器 | 允许 GMod 伤害破坏 MC 方块 |
| `mc_block_damage_decay` | `5` | 服务器 | 未完成破坏的伤害保留时间，秒 |
| `mc_block_explosion_fx_limit` | `16` | 服务器 | 一次爆炸最多广播的破坏粒子 / 音效组数；0 不广播 |
| `mc_block_explosion_max_blocks` | `4096` | 服务器 | 一次 GMod 爆炸最多破坏的 MC 方块数；0 不限 |
| `mc_block_explosion_max_radius` | `8` | 服务器 | MC 爆炸半径上限，方块 |
| `mc_block_explosion_scale` | `0.04` | 服务器 | GMod 爆炸伤害转换为 MC 爆炸半径的倍率 |
| `mc_block_health_scale` | `20` | 服务器 | 方块硬度转换为生命值的倍率 |

源码：[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)。

<a id="convars-5"></a>

## 结构实体

这些限制由服务器统一决定。精确碰撞参数不宜随意增大，源码标明存在 Source 物理引擎崩溃风险。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_cluster_collision_inset` | `0.5` | 服务器 | 结构实体每个碰撞面的内缩量，Source 单位；0 不内缩 |
| `mc_cluster_health_per_block` | `4` | 服务器 | 结构实体每方块生命值；0 不可破坏 |
| `mc_cluster_mass_per_block` | `10` | 服务器 | 结构实体每方块质量，kg |
| `mc_cluster_max_blocks` | `8191` | 服务器 | 单个结构实体方块数上限；协议硬上限 8191 |
| `mc_cluster_max_convexes` | `64` | 服务器 | 精确碰撞模式的凸体上限，箱体模式不受此项限制；增大有崩服风险 |
| `mc_cluster_max_extent` | `96` | 服务器 | 结构选择框最大边长，方块 |
| `mc_cluster_max_per_player` | `8` | 服务器 | 每位玩家结构实体数量上限；0 不限 |
| `mc_cluster_merge_cells` | `8` | 服务器 | 合并碰撞盒最大边长，格；超过 8 有物理引擎崩溃风险 |

源码：[sh_block_cluster.lua](../../../addons/mc_engine/lua/mc/sh_block_cluster.lua)。

<a id="convars-6"></a>

## 网络与区块流送

服务器控制数据流送；客户端的 unload 两项只控制本机清理预算。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_binary_chunk_patch` | `1` | 服务器 | 使用调色板 / 压缩字二进制区段补丁，替代地形 JSON |
| `mc_chunk_http_base_url` | `""` | 服务器 | 提供 garrysmod/data 下延迟存档清单及分片的 HTTP 根地址 |
| `mc_chunk_http_enabled` | `0` | 服务器 | 允许通过 HTTP 获取延迟存档的基础区块，替代 GMod net 传输 |
| `mc_chunk_store_frame_ms` | `3` | 服务器 | 每个存储刻的近似区块还原预算，毫秒 |
| `mc_chunk_store_loads_per_tick` | `8` | 服务器 | 每个存储刻最多还原的延迟区块数 |
| `mc_chunk_store_part_cache` | `8` | 服务器 | 内存中缓存的 v8 延迟存档分片文件数上限 |
| `mc_chunk_streaming` | `0` | 服务器 | 启用服务器控制的水平区块列流送 |
| `mc_large_world_chunk_threshold` | `2048` | 服务器 | 导入存档建议采用延迟流送的区块数门槛 |
| `mc_large_world_lazy_load` | `0` | 服务器 | 旧 v8 延迟加载开关；默认采用直接服务器加载 |
| `mc_stream_chunk_span_xy` | `8` | 服务器 | 水平订阅列半径；发送完整垂直列 |
| `mc_stream_chunk_span_z` | `0` | 服务器 | 预留字段；当前流送发送整列，不使用独立 Z 半径 |
| `mc_stream_columns_per_batch` | `1` | 服务器 | 每次流送间隔最多加入的新订阅列数 |
| `mc_stream_interval` | `0.3` | 服务器 | 服务器更新区块列兴趣范围的间隔，秒 |
| `mc_stream_max_patch_cells` | `32768` | 服务器 | 单个流送补丁最多包含的非空气格数 |
| `mc_stream_max_patch_chunks` | `16` | 服务器 | 单个流送补丁最多包含的非空区块数 |
| `mc_stream_unload_chunks_per_frame` | `1` | 客户端 | 每客户端帧清理的已脱离流送区块数 |
| `mc_stream_unload_frame_ms` | `3` | 客户端 | 每客户端帧清理已脱离流送区块的预算，毫秒 |
| `mc_stream_unload_margin` | `2` | 服务器 | 卸载前额外保留的列半径 |
| `mc_sync_frame_ms` | `4` | 服务器 | 每服务器刻用于全量同步的近似 CPU 预算，毫秒 |
| `mc_sync_inflight_limit` | `32768` | 服务器 | 每位玩家等待确认的可靠状态字节上限 |
| `mc_sync_messages_per_tick` | `4` | 服务器 | 每位玩家每 0.05 秒最多发送的排队可靠状态消息数 |
| `mc_sync_reliable_budget` | `3400` | 服务器 | 每位玩家每 0.05 秒的排队可靠状态字节硬预算 |

源码：[cl_net.lua](../../../addons/mc_engine/lua/mc/cl_net.lua)、[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)。

<a id="convars-7"></a>

## 碰撞与预测

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_bulk_collision_chunks_per_interval` | `1` | 服务器 | 爆炸 / 预设批量编辑每间隔重建的服务器碰撞区块数 |
| `mc_bulk_collision_interval` | `0.12` | 服务器 | 批量编辑的服务器碰撞重建间隔，秒 |
| `mc_client_collision` | `1` | 客户端 | 构建本地移动预测碰撞；0 仅使用服务器碰撞 |
| `mc_client_collision_aim_radius` | `1` | 服务器 | 服务器规定的客户端瞄准预测碰撞半径，方块 |
| `mc_client_collision_chunk_span` | `1` | 客户端 | 启用玩家附近的小型预测碰撞 AABB；0 关闭，不是通用区块半径 |
| `mc_client_collision_cross_chunk` | `0` | 客户端 | 允许客户端预测碰撞兴趣扩展到相邻区块 |
| `mc_collision_aim_distance` | `18688` | 服务器 | 瞄准碰撞兴趣追踪距离，Source 单位；独立于建造距离 |
| `mc_server_collision` | `1` | 服务器 | 构建服务器权威方块碰撞 |
| `mc_server_collision_aabb_padding` | `36.5` | 服务器 | 玩家 / 实体碰撞兴趣 AABB 的扩边量，Source 单位；默认一个方块尺寸 |
| `mc_server_collision_aim_radius` | `1` | 服务器 | 玩家瞄准方块周围保持服务器碰撞的半径，方块 |
| `mc_server_collision_chunk_span` | `0` | 服务器 | 服务器碰撞 AABB 外额外扩展的区块半径 |
| `mc_server_collision_hot_span` | `2` | 服务器 | 速度前瞻碰撞兴趣的区块跨度 |
| `mc_server_collision_lookahead_max` | `4` | 服务器 | 速度前瞻可扩展到的最大区块半径 |
| `mc_server_collision_lookahead_time` | `0.5` | 服务器 | 实体速度前瞻时间，秒 |

源码：[cl_collision.lua](../../../addons/mc_engine/lua/mc/render/cl_collision.lua)、[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)。

<a id="convars-8"></a>

## 网格构建与绘制

全部为客户端选项。Native 绘制需 L2 后端实际激活；把开关设为 1 不代表模块已加载。

调度预设按「构建毫秒 / 批量几何毫秒 / 每帧区段数」设置：smooth = 3 / 3 / 16，fast = 8 / 8 / 64，loading = 20 / 20 / 128。单次区段上传不可拆分，仍可能超过帧预算。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_build_unlimited` | `0` | 客户端 | 取消客户端构建 / 清理预算及延迟网格推迟，连续处理收到的任务 |
| `mc_explosion_mesh_frame_ms` | `8` | 客户端 | 爆炸、换包等限速几何任务的每帧 Lua 预算，毫秒 |
| `mc_explosion_mesh_sections_per_frame` | `64` | 客户端 | 限速几何任务每帧处理的渲染区段数 |
| `mc_gc_smoothing` | `0` | 客户端 | 全客户端 Lua GC 步进平滑：0 恢复原设置，1–16 越大请求越小步进；仍可能有原子暂停 |
| `mc_mesh_begin_upload` | `1` | 客户端 | 用 mesh.Begin 上传 IMesh 顶点，替代 BuildFromTriangles |
| `mc_mesh_block_emit_cache_sections` | `1536` | 客户端 | 保留逐方块顶点 / 光照缓存的区段上限；调低增加完整重建工作 |
| `mc_mesh_build_frame_ms` | `8` | 客户端 | 每帧 Lua 几何 / 光照重建的近似预算，毫秒；Native 路径仅管延迟构建，0 不限 |
| `mc_mesh_build_preset` | `fast` | 客户端 | 调度预设：smooth、fast、loading、custom；手改预算会切到 custom |
| `mc_mesh_connection_visible_template` | `1` | 客户端 | 实验性栅栏、玻璃板、墙、管道连接形状的可见几何模板缓存 |
| `mc_mesh_cull_mode` | `ccw` | 客户端 | 网格面剔除方向：cw 或 ccw |
| `mc_mesh_directional_cull` | `0` | 客户端 | 实验性不透明方块六方向网格；可能增加 DX9 绘制调用，切换会重建 |
| `mc_mesh_directional_min_blocks` | `64` | 客户端 | 仅对至少含此数量方块的渲染区段拆分面方向 |
| `mc_mesh_draw_distance` | `0` | 客户端 | 绘制距离，Source 单位；0 在延迟构建开启时使用其距离，否则不限 |
| `mc_mesh_frustum_cull` | `1` | 客户端 | 剔除视锥外的 8³ 渲染区段 |
| `mc_mesh_geometry_cache_sections` | `384` | 客户端 | 保留 Lua 顶点 / 光照数据供仅重着色的区段上限；调低省内存 |
| `mc_mesh_lazy_build` | `0` | 客户端 | 保留客户端全量世界数据，仅在视距内构建网格 |
| `mc_mesh_lazy_distance` | `10000` | 客户端 | 延迟构建距离，Source 单位；显式绘制距离为 0 时也用于绘制 |
| `mc_mesh_occlusion_cull` | `1` | 客户端 | 基于区段连通性的保守遮挡剔除；未知 / 透明空间保持开放 |
| `mc_mesh_render` | `1` | 客户端 | 绘制世界网格；关闭不影响碰撞 |
| `mc_native_draw` | `1` | 客户端 | 启用 Native L2 批量绘制；0 使用 Lua 绘制循环供对比 |
| `mc_native_draw_directions` | `1` | 客户端 | L2 绘制跳过背向摄像机的索引范围，不拆分网格 |
| `mc_native_draw_worker` | `1` | 客户端 | 在后台线程计算 L2 保守可见性 |
| `mc_native_mesh` | `0` | 客户端 | L2 网格后端：0 Lua，1 Native 四边形光照及索引网格上传；需 Native 模块 |

源码：[cl_gc.lua](../../../addons/mc_engine/lua/mc/cl_gc.lua)、[cl_collision.lua](../../../addons/mc_engine/lua/mc/render/cl_collision.lua)、[cl_dirty.lua](../../../addons/mc_engine/lua/mc/render/cl_dirty.lua)、[cl_draw.lua](../../../addons/mc_engine/lua/mc/render/cl_draw.lua)、[cl_mesh_cache.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_cache.lua)、[cl_mesh_config.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_config.lua)、[cl_mesh_presets.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_presets.lua)、[cl_native_mesh_config.lua](../../../addons/mc_engine/lua/mc/render/cl_native_mesh_config.lua)、[cl_render_section_cull.lua](../../../addons/mc_engine/lua/mc/render/cl_render_section_cull.lua)。

<a id="convars-9"></a>

## 光照与兼容渲染参数

全部为客户端注册项。其中旧区块着色器、Fancy、自管阴影图 / 高度场选项仍保留注册，不代表当前光影包使用它们。PBR 的阴影、泛光等包内参数请用 mc_render_pack_settings 查询；不要把旧 mc_shadow_size 当作 PBR 的 shadow_resolution。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_daycycle_moon_light` | `3` | 客户端 | 深夜天空光等级，0–15 |
| `mc_daycycle_moon_shadow` | `0.3` | 客户端 | 旧阴影路径的夜间月影相对日影强度；0 无月影 |
| `mc_daycycle_night_tint` | `0.35` | 客户端 | 夜间天空光表面蓝色染色强度；0 中性 |
| `mc_daycycle_sun_tilt` | `0.2` | 客户端 | 昼夜太阳轨迹侧向倾斜，避免轴对齐阴影 |
| `mc_dynamic_flashlight` | `1` | 客户端 | MC 表面接收 MC 与 Source 手电光束 |
| `mc_dynamic_lights` | `1` | 客户端 | Vanilla 和光影包中的移动光源 |
| `mc_dynamic_lights_max` | `8` | 客户端 | 最多可见移动光源数 |
| `mc_light_ambient_min` | `0` | 客户端 | 顶点光照最低亮度倍率 |
| `mc_light_bloom` | `1` | 客户端 | 旧 Fancy GPU 外观的屏幕泛光开关 |
| `mc_light_bloom_radius` | `6` | 客户端 | 旧 Fancy 泛光模糊半径，屏幕像素 |
| `mc_light_bloom_strength` | `0.3` | 客户端 | 旧 Fancy 泛光强度 |
| `mc_light_bloom_threshold` | `0.7` | 客户端 | 旧 Fancy 泛光亮度阈值 |
| `mc_light_brightness` | `1.5` | 客户端 | 方块光 / 天空光亮度倍率；1 不变 |
| `mc_light_enabled` | `1` | 客户端 | 对方块网格应用 MC 顶点光照 |
| `mc_light_entity` | `0` | 客户端 | 玩家与常见模型实体使用插值 MC 光照的总开关 |
| `mc_light_entity_cluster` | `1` | 客户端 | 对结构实体 mc_block_cluster 应用 MC 实体光照 |
| `mc_light_entity_cluster_gain` | `1` | 客户端 | MC 光照结构实体的曝光倍率；1 匹配区块顶点光照 |
| `mc_light_entity_gain` | `0.48` | 客户端 | MC 光照 Source 实体的曝光倍率 |
| `mc_light_entity_interval` | `0.10` | 客户端 | 每实体两次体素采光的最短间隔，秒，移动也受限；每帧最多更新 4 个实体，0 表示每帧申请更新，超额排队 |
| `mc_light_entity_npcs` | `1` | 客户端 | 对 NPC 和 NextBot 模型应用 MC 实体光照 |
| `mc_light_entity_player_gamma` | `2.2` | 客户端 | 玩家环境立方体光照从显示空间转线性空间的指数 |
| `mc_light_entity_players` | `1` | 客户端 | 对玩家模型应用 MC 实体光照；已有配置保留原值 |
| `mc_light_entity_props` | `1` | 客户端 | 对常见道具模型应用 MC 实体光照 |
| `mc_light_entity_reflections` | `0.35` | 客户端 | 实体反射强度；还受采样亮度影响 |
| `mc_light_entity_vehicles` | `1` | 客户端 | 对标准 Source 载具应用 MC 实体光照 |
| `mc_light_gamma` | `1` | 客户端 | 光照衰减曲线；大于 1 提亮中间亮度，小于 1 压暗 |
| `mc_light_shader` | `1` | 客户端 | 旧区块 GPU 着色器开关；需已编译 VCS |
| `mc_light_sky_flood` | `1` | 客户端 | MC 天空光传播：露天下为 15，向室内逐格衰减；0 使用均匀明亮天空 |
| `mc_light_sky_flood_frame_ms` | `2` | 客户端 | 每帧天空光重算软预算，毫秒；0 不限 |
| `mc_light_sky_flood_per_frame` | `4` | 客户端 | 每帧最多执行的区块天空光重算数 |
| `mc_light_style` | `vanilla` | 客户端 | 已弃用的外观选择器；不能用它选择当前光影包 |
| `mc_light_sun_brightness` | `1` | 客户端 | 太阳 / 天空光亮度倍率 |
| `mc_light_texture` | `1` | 客户端 | 旧 GPU 路径使用区块光照纹理，替代顶点烘焙颜色 |
| `mc_lightmap` | `1` | 客户端 | 16×16 全局光照贴图：暖色方块光与昼夜天空色；0 灰度回退 |
| `mc_lightmap_ambient` | `0.18` | 客户端 | 全局光照贴图中完全黑暗区域的最低可见亮度 |
| `mc_lightmap_eye_dark` | `1` | 客户端 | 摄像机格没有天空光时的环境光倍率；1 不压暗 |
| `mc_lightmap_night_gamma` | `0.6` | 客户端 | 昼夜天空亮度曲线；1 线性，更低使夜间更亮更蓝 |
| `mc_lightmap_sky_curve` | `3` | 客户端 | 天空环境光衰减曲线指数；越高使遮蔽但开放区域更亮 |
| `mc_lightmap_sky_min` | `0.18` | 客户端 | 天空光等级 0 时的最低天空环境光比例；不控制直射太阳 |
| `mc_lightmap_sunset` | `0.5` | 客户端 | 全局光照贴图中的日出 / 日落橙色强度；0 关闭 |
| `mc_lightmap_torch_warmth` | `0.7` | 客户端 | 全局光照贴图中的方块光暖色强度；0 白光 |
| `mc_lightmap_vanilla_flicker` | `1` | 客户端 | Vanilla 火把逐刻闪烁；0 稳定方块光 |
| `mc_lightmap_vanilla_gamma` | `0.5` | 客户端 | Vanilla 亮度滑块：0 Moody、0.5 默认、1 Bright |
| `mc_pbr_shadow_entities` | `1` | 客户端 | Source 道具、玩家、NPC 和载具模型向 MC 表面投影 |
| `mc_shadow` | `1` | 客户端 | 旧区块着色器接收 MC 自管太阳阴影图 |
| `mc_shadow_bias` | `0` | 客户端 | 旧阴影图深度 / 边缘采样偏移 |
| `mc_shadow_cascade_ratio` | `3` | 客户端 | 旧级联阴影半径比；近层为 distance / ratio²，中层为 distance / ratio |
| `mc_shadow_caster_distance` | `10000` | 客户端 | 旧自管阴影图中区块投影的相机距离上限，Source 单位 |
| `mc_shadow_distance` | `10000` | 客户端 | 旧自管阴影图覆盖半径，Source 单位 |
| `mc_shadow_edge_fade` | `0.1` | 客户端 | 旧 Fancy 外观阴影覆盖边缘淡出宽度，UV 单位；0 硬切 |
| `mc_shadow_face_shade` | `0.65` | 客户端 | 旧 Fancy 外观背光面阴影强度 |
| `mc_shadow_facefix` | `0` | 客户端 | 旧阴影 A/B 测试：0 旧合成，1 分离投影阴影与背光面修正 |
| `mc_shadow_hf_max_dist` | `2400` | 客户端 | 旧高度场投影最远射线步进距离，Source 单位 |
| `mc_shadow_hf_range` | `4096` | 客户端 | 旧高度场以玩家为中心的覆盖半径，Source 单位 |
| `mc_shadow_hf_size` | `1024` | 客户端 | 旧 height 高度场阴影分辨率 |
| `mc_shadow_hf_softness` | `0.05` | 客户端 | 旧高度场半影随遮挡距离扩大的斜率 |
| `mc_shadow_hf_update_interval` | `0` | 客户端 | 旧高度场网格变化 / 窗口重定位后的最短重绘间隔，秒 |
| `mc_shadow_mode` | `map` | 客户端 | 旧阴影模式：linear、map、csm、height |
| `mc_shadow_size` | `4096` | 客户端 | 旧 MC 自管阴影图单层分辨率，512–4096；非 PBR 包阴影分辨率 |
| `mc_shadow_softness` | `0.5` | 客户端 | 旧阴影 PCF 半径，阴影图纹素；法线偏移固定一个纹素 |
| `mc_shadow_strength` | `0.75` | 客户端 | 旧区块着色器阴影强度倍率 |
| `mc_shadow_sun_step` | `0` | 客户端 | 旧阴影太阳角量化步长，度；0 连续 |
| `mc_shadow_tint` | `0.6` | 客户端 | 旧 Fancy 外观阴影冷色天空染色强度；0 只变暗 |
| `mc_shadow_update_interval` | `0` | 客户端 | 旧自管阴影重绘最短间隔，秒；0 每帧 |
| `mc_shadow_warmth` | `0.35` | 客户端 | 旧 Fancy 外观日照与火把区域暖色强度；0 中性 |

源码：[cl_lighting.lua](../../../addons/mc_engine/lua/mc/cl_lighting.lua)、[cl_entity_lighting.lua](../../../addons/mc_engine/lua/mc/render/cl_entity_lighting.lua)、[cl_mesh_config.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_config.lua)、[cl_render_dynamic_lights.lua](../../../addons/mc_engine/lua/mc/render/cl_render_dynamic_lights.lua)、[cl_render_pbr_shadows.lua](../../../addons/mc_engine/lua/mc/render/cl_render_pbr_shadows.lua)、[cl_sky_flood.lua](../../../addons/mc_engine/lua/mc/render/cl_sky_flood.lua)。

<a id="convars-10"></a>

## 创造模式手持方块

全部为客户端选项，调节创造放置器的手持方块；与下面的 MC Item 锚点分开。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_creative_held_anim` | `1` | 客户端 | 播放创造模式手持方块挥动动画 |
| `mc_creative_held_fp_forward` | `11.5` | 客户端 | 创造模式手持方块第一人称前后偏移，Source 单位 |
| `mc_creative_held_fp_pitch` | `0` | 客户端 | 创造模式手持方块第一人称俯仰角，度 |
| `mc_creative_held_fp_right` | `12` | 客户端 | 创造模式手持方块第一人称左右偏移，Source 单位 |
| `mc_creative_held_fp_roll` | `0` | 客户端 | 创造模式手持方块第一人称翻滚角，度 |
| `mc_creative_held_fp_scale` | `6.4` | 客户端 | 创造模式手持方块第一人称缩放倍率 |
| `mc_creative_held_fp_up` | `-8.3` | 客户端 | 创造模式手持方块第一人称上下偏移，Source 单位 |
| `mc_creative_held_fp_yaw` | `45` | 客户端 | 创造模式手持方块第一人称偏航角，度 |
| `mc_creative_held_model` | `1` | 客户端 | 显示创造模式手持方块模型 |
| `mc_creative_held_tp_forward` | `2.5` | 客户端 | 创造模式手持方块第三人称前后偏移，Source 单位 |
| `mc_creative_held_tp_pitch` | `75` | 客户端 | 创造模式手持方块第三人称俯仰角，度 |
| `mc_creative_held_tp_right` | `2.2` | 客户端 | 创造模式手持方块第三人称左右偏移，Source 单位 |
| `mc_creative_held_tp_roll` | `0` | 客户端 | 创造模式手持方块第三人称翻滚角，度 |
| `mc_creative_held_tp_scale` | `6` | 客户端 | 创造模式手持方块第三人称缩放倍率 |
| `mc_creative_held_tp_up` | `-1.8` | 客户端 | 创造模式手持方块第三人称上下偏移，Source 单位 |
| `mc_creative_held_tp_yaw` | `45` | 客户端 | 创造模式手持方块第三人称偏航角，度 |

源码：[shared.lua](../../../addons/mc_engine/lua/weapons/mc_creative_placer/shared.lua)。

<a id="convars-11"></a>

## MC Item：玩法与显示

需加载 mc_item。服务器参数决定玩法，客户端参数决定本机显示。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_attack_indicator` | `1` | 客户端 | 攻击进度指示：0 关闭、1 显示在准星处 |
| `mcitem_attack_range` | `4.5` | 服务器 | 普通近战攻击距离，方块；长矛使用自己的范围 |
| `mcitem_block_outline` | `1` | 客户端 | 持有 MC Item 武器 / 物品并瞄准方块时绘制选中轮廓 |
| `mcitem_channeling_thunderstorm` | `0` | 服务器 | 将当前 GMod 世界视为雷雨天，供引雷三叉戟判定 |
| `mcitem_crosshair` | `1` | 客户端 | 持有 MC Item 武器时显示 MC 准星 |
| `mcitem_crosshair_invert` | `1` | 客户端 | 使用 MC 准星反色混合，不是反转攻击进度 |
| `mcitem_damage_scale` | `5` | 服务器 | 武器直伤倍率，含近战、横扫、长矛、重锤、箭及投掷物；不缩放药水状态伤害 |
| `mcitem_draw_shake` | `1` | 客户端 | 弓、弩和三叉戟蓄力细微抖动的幅度倍率；0 关闭 |
| `mcitem_draw_stretch` | `1` | 客户端 | 弓、弩和三叉戟蓄力时的深度拉伸开关 |
| `mcitem_fov_effect_scale` | `1` | 服务器 | MC FOV 效果强度；0 无拉弓缩放，1 原版强度 |
| `mcitem_hand_aspect_lock` | `1` | 客户端 | 按宽高比补偿手持物水平位置，保持 4:3 校准位置 |
| `mcitem_hand_fov_lock` | `1` | 客户端 | 世界 FOV 因拉弓缩小时保持手持物屏幕大小 |
| `mcitem_hand_lower` | `1` | 客户端 | 按冷却升降手部；0 始终抬起 |
| `mcitem_hud_scale` | `2` | 客户端 | 每 MC GUI 像素对应的屏幕像素数；0 自动 |
| `mcitem_knockback_scale` | `0.3` | 服务器 | MC 击退速度映射至 Source 的倍率 |
| `mcitem_mcswep_lighting` | `1` | 客户端 | 手持、掉落和投掷物模型使用 MineMod 体素光照 |
| `mcitem_name_tag_scale` | `2.5` | 客户端 | 命名牌世界文字大小倍率，范围 0.5–3 |
| `mcitem_particle_limit` | `1200` | 客户端 | 同时存活的 MC Item 粒子上限；0 不限 |
| `mcitem_potion_max_entity_cramming` | `24` | 服务器 | 渗浆效果使用的 maxEntityCramming 上限；0 关闭该上限 |
| `mcitem_projectile_billboard` | `1` | 客户端 | 雪球、鸡蛋、珍珠、药水、末影之眼等投掷物使用朝向相机的精灵图；0 原始模型 |
| `mcitem_projectile_light_offset` | `0.5` | 客户端 | 插住的箭 / 三叉戟沿命中面法线向外取光的距离，方块；0 几何中心 |
| `mcitem_projectile_stick_depth` | `0.05` | 服务器 | 箭 / 三叉戟尖端越过命中面的深度，方块 |
| `mcitem_use_preview` | `-1` | 客户端 | 将使用 / 蓄力动画冻结在指定 MC tick；-1 正常播放 |
| `mcitem_view_bob` | `1` | 客户端 | 走路时手持物晃动倍率；0 关闭 |
| `mcitem_view_sway` | `1` | 客户端 | 转头时手持物滞后倍率；0 关闭 |

源码：[cl_init.lua](../../../addons/mc_item/lua/entities/mcitem_arrow/cl_init.lua)、[shared.lua](../../../addons/mc_item/lua/entities/mcitem_arrow/shared.lua)、[cl_billboard.lua](../../../addons/mc_item/lua/mcitem/cl_billboard.lua)、[cl_block_outline.lua](../../../addons/mc_item/lua/mcitem/cl_block_outline.lua)、[cl_crosshair.lua](../../../addons/mc_item/lua/mcitem/cl_crosshair.lua)、[cl_model_lighting.lua](../../../addons/mc_item/lua/mcitem/cl_model_lighting.lua)、[sh_runtime.lua](../../../addons/mc_item/lua/mcitem/enchantments/sh_runtime.lua)、[cl_render.lua](../../../addons/mc_item/lua/mcitem/name_tags/cl_render.lua)、[sv_special.lua](../../../addons/mc_item/lua/mcitem/potions/status/sv_special.lua)、[sh_tuning.lua](../../../addons/mc_item/lua/mcitem/sh_tuning.lua)、[sh_use_effects.lua](../../../addons/mc_item/lua/mcitem/sh_use_effects.lua)、[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-12"></a>

## MC Item：共享第一人称锚点

名称沿用 bmb_item_test_fp_*，但公共 MC Item 武器继承此渲染基类，并非仅供测试武器使用。全部为客户端变量。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `bmb_item_test_fp_fov` | `80` | 客户端 | 非 MC 动画模式的手持物 FOV，度 |
| `bmb_item_test_fp_mc_fov` | `70` | 客户端 | MC 动画模式的手持物 FOV，度 |
| `bmb_item_test_fp_mc_pivot` | `1` | 客户端 | MC 手部旋转轴心偏移倍率 |
| `bmb_item_test_fp_mc_pos_x` | `1` | 客户端 | MC 挥动位置变换 X 分量倍率 |
| `bmb_item_test_fp_mc_pos_y` | `1` | 客户端 | MC 挥动位置变换 Y 分量倍率 |
| `bmb_item_test_fp_mc_pos_z` | `1` | 客户端 | MC 挥动位置变换 Z 分量倍率 |
| `bmb_item_test_fp_mc_preview` | `-1` | 客户端 | 冻结挥动动画相位；-1 正常播放 |
| `bmb_item_test_fp_mc_rot_pitch` | `1` | 客户端 | MC 挥动俯仰变换倍率 |
| `bmb_item_test_fp_mc_rot_roll` | `1` | 客户端 | MC 挥动翻滚变换倍率 |
| `bmb_item_test_fp_mc_rot_yaw` | `1` | 客户端 | MC 挥动偏航变换倍率 |
| `bmb_item_test_fp_mc_scale` | `0.68` | 客户端 | MC 动画模式在基础缩放上再乘的倍率 |
| `bmb_item_test_fp_minecraft` | `1` | 客户端 | 启用 MC 第一人称动作变换 |
| `bmb_item_test_fp_pitch` | `-3` | 客户端 | 共享第一人称俯仰角，度 |
| `bmb_item_test_fp_roll` | `20` | 客户端 | 共享第一人称翻滚角，度 |
| `bmb_item_test_fp_scale` | `0.5` | 客户端 | 共享第一人称模型基础缩放 |
| `bmb_item_test_fp_x` | `19.5` | 客户端 | 共享第一人称前后偏移，Source 单位 |
| `bmb_item_test_fp_y` | `10.3` | 客户端 | 共享第一人称左右偏移，Source 单位 |
| `bmb_item_test_fp_yaw` | `110` | 客户端 | 共享第一人称偏航角，度 |
| `bmb_item_test_fp_z` | `-7` | 客户端 | 共享第一人称上下偏移，Source 单位 |

源码：[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-13"></a>

## MC Item：逐物品第一人称锚点

全部为客户端变量。位置 / 旋转增量叠加在共享锚点上，scale 为倍率。bow、crossbow、trident、spear、shield、fishing_rod、food、potion 在加载时注册；item、bucket 在首次渲染相关物品时按需创建。盾牌的精确 MC 变换路径会绕过通用锚点，因此已注册不代表每条渲染路径都读取它。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_fp_bow_pitch` | `5` | 客户端 | 弓第一人称手持增量：俯仰角，度 |
| `mcitem_fp_bow_roll` | `0` | 客户端 | 弓第一人称手持增量：翻滚角，度 |
| `mcitem_fp_bow_scale` | `1` | 客户端 | 弓第一人称手持增量：缩放倍率 |
| `mcitem_fp_bow_x` | `-1` | 客户端 | 弓第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_bow_y` | `0` | 客户端 | 弓第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_bow_yaw` | `-5` | 客户端 | 弓第一人称手持增量：偏航角，度 |
| `mcitem_fp_bow_z` | `0` | 客户端 | 弓第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_bucket_pitch` | `0` | 客户端 | 桶第一人称手持增量：俯仰角，度 |
| `mcitem_fp_bucket_roll` | `0` | 客户端 | 桶第一人称手持增量：翻滚角，度 |
| `mcitem_fp_bucket_scale` | `1` | 客户端 | 桶第一人称手持增量：缩放倍率 |
| `mcitem_fp_bucket_x` | `0` | 客户端 | 桶第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_bucket_y` | `0` | 客户端 | 桶第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_bucket_yaw` | `0` | 客户端 | 桶第一人称手持增量：偏航角，度 |
| `mcitem_fp_bucket_z` | `0` | 客户端 | 桶第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_crossbow_pitch` | `5` | 客户端 | 弩第一人称手持增量：俯仰角，度 |
| `mcitem_fp_crossbow_roll` | `-244` | 客户端 | 弩第一人称手持增量：翻滚角，度 |
| `mcitem_fp_crossbow_scale` | `1` | 客户端 | 弩第一人称手持增量：缩放倍率 |
| `mcitem_fp_crossbow_x` | `-1` | 客户端 | 弩第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_crossbow_y` | `0.6` | 客户端 | 弩第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_crossbow_yaw` | `-100` | 客户端 | 弩第一人称手持增量：偏航角，度 |
| `mcitem_fp_crossbow_z` | `0` | 客户端 | 弩第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_fishing_rod_pitch` | `0` | 客户端 | 钓鱼竿第一人称手持增量：俯仰角，度 |
| `mcitem_fp_fishing_rod_roll` | `5` | 客户端 | 钓鱼竿第一人称手持增量：翻滚角，度 |
| `mcitem_fp_fishing_rod_scale` | `1` | 客户端 | 钓鱼竿第一人称手持增量：缩放倍率 |
| `mcitem_fp_fishing_rod_x` | `0` | 客户端 | 钓鱼竿第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_fishing_rod_y` | `1` | 客户端 | 钓鱼竿第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_fishing_rod_yaw` | `-10` | 客户端 | 钓鱼竿第一人称手持增量：偏航角，度 |
| `mcitem_fp_fishing_rod_z` | `1` | 客户端 | 钓鱼竿第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_food_pitch` | `0` | 客户端 | 食物第一人称手持增量：俯仰角，度 |
| `mcitem_fp_food_roll` | `0` | 客户端 | 食物第一人称手持增量：翻滚角，度 |
| `mcitem_fp_food_scale` | `1` | 客户端 | 食物第一人称手持增量：缩放倍率 |
| `mcitem_fp_food_x` | `0` | 客户端 | 食物第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_food_y` | `0` | 客户端 | 食物第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_food_yaw` | `0` | 客户端 | 食物第一人称手持增量：偏航角，度 |
| `mcitem_fp_food_z` | `0` | 客户端 | 食物第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_item_pitch` | `0` | 客户端 | 普通物品第一人称手持增量：俯仰角，度 |
| `mcitem_fp_item_roll` | `0` | 客户端 | 普通物品第一人称手持增量：翻滚角，度 |
| `mcitem_fp_item_scale` | `1` | 客户端 | 普通物品第一人称手持增量：缩放倍率 |
| `mcitem_fp_item_x` | `0` | 客户端 | 普通物品第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_item_y` | `0` | 客户端 | 普通物品第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_item_yaw` | `0` | 客户端 | 普通物品第一人称手持增量：偏航角，度 |
| `mcitem_fp_item_z` | `0` | 客户端 | 普通物品第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_potion_pitch` | `0` | 客户端 | 药水第一人称手持增量：俯仰角，度 |
| `mcitem_fp_potion_roll` | `0` | 客户端 | 药水第一人称手持增量：翻滚角，度 |
| `mcitem_fp_potion_scale` | `1` | 客户端 | 药水第一人称手持增量：缩放倍率 |
| `mcitem_fp_potion_x` | `0` | 客户端 | 药水第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_potion_y` | `0` | 客户端 | 药水第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_potion_yaw` | `0` | 客户端 | 药水第一人称手持增量：偏航角，度 |
| `mcitem_fp_potion_z` | `0` | 客户端 | 药水第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_shield_pitch` | `190` | 客户端 | 盾牌第一人称手持增量：俯仰角，度 |
| `mcitem_fp_shield_roll` | `-185` | 客户端 | 盾牌第一人称手持增量：翻滚角，度 |
| `mcitem_fp_shield_scale` | `1.5` | 客户端 | 盾牌第一人称手持增量：缩放倍率 |
| `mcitem_fp_shield_x` | `-10` | 客户端 | 盾牌第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_shield_y` | `16` | 客户端 | 盾牌第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_shield_yaw` | `-15` | 客户端 | 盾牌第一人称手持增量：偏航角，度 |
| `mcitem_fp_shield_z` | `-20` | 客户端 | 盾牌第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_spear_pitch` | `17` | 客户端 | 长矛第一人称手持增量：俯仰角，度 |
| `mcitem_fp_spear_roll` | `-20` | 客户端 | 长矛第一人称手持增量：翻滚角，度 |
| `mcitem_fp_spear_scale` | `1.3` | 客户端 | 长矛第一人称手持增量：缩放倍率 |
| `mcitem_fp_spear_x` | `2` | 客户端 | 长矛第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_spear_y` | `0` | 客户端 | 长矛第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_spear_yaw` | `-4` | 客户端 | 长矛第一人称手持增量：偏航角，度 |
| `mcitem_fp_spear_z` | `-0.7` | 客户端 | 长矛第一人称手持增量：上下位移，Source 单位 |
| `mcitem_fp_trident_pitch` | `0` | 客户端 | 三叉戟第一人称手持增量：俯仰角，度 |
| `mcitem_fp_trident_roll` | `0` | 客户端 | 三叉戟第一人称手持增量：翻滚角，度 |
| `mcitem_fp_trident_scale` | `1.5` | 客户端 | 三叉戟第一人称手持增量：缩放倍率 |
| `mcitem_fp_trident_x` | `-2` | 客户端 | 三叉戟第一人称手持增量：前后位移，Source 单位 |
| `mcitem_fp_trident_y` | `19.3` | 客户端 | 三叉戟第一人称手持增量：左右位移，Source 单位 |
| `mcitem_fp_trident_yaw` | `0` | 客户端 | 三叉戟第一人称手持增量：偏航角，度 |
| `mcitem_fp_trident_z` | `-57` | 客户端 | 三叉戟第一人称手持增量：上下位移，Source 单位 |

源码：[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-14"></a>

## MC Item：使用姿态增量与拉伸

全部为客户端变量，加载时按物品名注册。x/y/z 与角度只在使用状态叠加；draw 调后拉幅度，stretch 调深度形变，二者不同。部分物品 / 使用状态不会进入对应分支，不能仅凭变量存在判断当前动作会读取它。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_use_bow_draw` | `1` | 客户端 | 弓使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_bow_pitch` | `-5` | 客户端 | 弓第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_bow_roll` | `0` | 客户端 | 弓第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_bow_stretch` | `1` | 客户端 | 弓蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_bow_x` | `-3` | 客户端 | 弓第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_bow_y` | `1` | 客户端 | 弓第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_bow_yaw` | `0` | 客户端 | 弓第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_bow_z` | `0` | 客户端 | 弓第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_crossbow_draw` | `1` | 客户端 | 弩使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_crossbow_pitch` | `-5` | 客户端 | 弩第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_crossbow_roll` | `0` | 客户端 | 弩第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_crossbow_stretch` | `1` | 客户端 | 弩蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_crossbow_x` | `-2` | 客户端 | 弩第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_crossbow_y` | `-2` | 客户端 | 弩第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_crossbow_yaw` | `0` | 客户端 | 弩第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_crossbow_z` | `0` | 客户端 | 弩第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_fishing_rod_draw` | `1` | 客户端 | 钓鱼竿使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_fishing_rod_pitch` | `0` | 客户端 | 钓鱼竿第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_fishing_rod_roll` | `5` | 客户端 | 钓鱼竿第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_fishing_rod_stretch` | `1` | 客户端 | 钓鱼竿蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_fishing_rod_x` | `0` | 客户端 | 钓鱼竿第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_fishing_rod_y` | `1` | 客户端 | 钓鱼竿第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_fishing_rod_yaw` | `-10` | 客户端 | 钓鱼竿第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_fishing_rod_z` | `1` | 客户端 | 钓鱼竿第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_food_draw` | `1` | 客户端 | 食物使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_food_pitch` | `10` | 客户端 | 食物第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_food_roll` | `3` | 客户端 | 食物第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_food_stretch` | `1` | 客户端 | 食物蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_food_x` | `-9` | 客户端 | 食物第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_food_y` | `3` | 客户端 | 食物第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_food_yaw` | `-5` | 客户端 | 食物第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_food_z` | `0` | 客户端 | 食物第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_potion_draw` | `1` | 客户端 | 药水使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_potion_pitch` | `10` | 客户端 | 药水第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_potion_roll` | `3` | 客户端 | 药水第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_potion_stretch` | `1` | 客户端 | 药水蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_potion_x` | `-9` | 客户端 | 药水第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_potion_y` | `3` | 客户端 | 药水第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_potion_yaw` | `-10` | 客户端 | 药水第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_potion_z` | `0` | 客户端 | 药水第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_shield_draw` | `1` | 客户端 | 盾牌使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_shield_pitch` | `-8` | 客户端 | 盾牌第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_shield_roll` | `20` | 客户端 | 盾牌第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_shield_stretch` | `1` | 客户端 | 盾牌蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_shield_x` | `-2` | 客户端 | 盾牌第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_shield_y` | `7` | 客户端 | 盾牌第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_shield_yaw` | `0` | 客户端 | 盾牌第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_shield_z` | `2` | 客户端 | 盾牌第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_spear_draw` | `1` | 客户端 | 长矛使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_spear_pitch` | `0` | 客户端 | 长矛第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_spear_roll` | `0` | 客户端 | 长矛第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_spear_stretch` | `1` | 客户端 | 长矛蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_spear_x` | `0` | 客户端 | 长矛第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_spear_y` | `0` | 客户端 | 长矛第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_spear_yaw` | `0` | 客户端 | 长矛第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_spear_z` | `0` | 客户端 | 长矛第一人称使用时额外增量：上下位移，Source 单位 |
| `mcitem_use_trident_draw` | `3` | 客户端 | 三叉戟使用姿态蓄力后拉的幅度倍率；不拉长模型 |
| `mcitem_use_trident_pitch` | `-12` | 客户端 | 三叉戟第一人称使用时额外增量：俯仰角，度 |
| `mcitem_use_trident_roll` | `1` | 客户端 | 三叉戟第一人称使用时额外增量：翻滚角，度 |
| `mcitem_use_trident_stretch` | `1` | 客户端 | 三叉戟蓄力深度拉伸倍率；0 不变形 |
| `mcitem_use_trident_x` | `-15` | 客户端 | 三叉戟第一人称使用时额外增量：前后位移，Source 单位 |
| `mcitem_use_trident_y` | `3` | 客户端 | 三叉戟第一人称使用时额外增量：左右位移，Source 单位 |
| `mcitem_use_trident_yaw` | `-12` | 客户端 | 三叉戟第一人称使用时额外增量：偏航角，度 |
| `mcitem_use_trident_z` | `58` | 客户端 | 三叉戟第一人称使用时额外增量：上下位移，Source 单位 |

源码：[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-15"></a>

## MC Item：已上弦姿态增量

全部为客户端变量，加载时注册。当前主要由弩的 charged 状态读取；其他物品名也预注册，但没有相应状态时不生效。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_charged_bow_pitch` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_bow_roll` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_bow_x` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_bow_y` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_bow_yaw` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_bow_z` | `0` | 客户端 | 弓第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_crossbow_pitch` | `-2` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_crossbow_roll` | `9` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_crossbow_x` | `-2` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_crossbow_y` | `1` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_crossbow_yaw` | `0` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_crossbow_z` | `0` | 客户端 | 弩第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_fishing_rod_pitch` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_fishing_rod_roll` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_fishing_rod_x` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_fishing_rod_y` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_fishing_rod_yaw` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_fishing_rod_z` | `0` | 客户端 | 钓鱼竿第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_food_pitch` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_food_roll` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_food_x` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_food_y` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_food_yaw` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_food_z` | `0` | 客户端 | 食物第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_potion_pitch` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_potion_roll` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_potion_x` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_potion_y` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_potion_yaw` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_potion_z` | `0` | 客户端 | 药水第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_shield_pitch` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_shield_roll` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_shield_x` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_shield_y` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_shield_yaw` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_shield_z` | `0` | 客户端 | 盾牌第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_spear_pitch` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_spear_roll` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_spear_x` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_spear_y` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_spear_yaw` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_spear_z` | `0` | 客户端 | 长矛第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |
| `mcitem_charged_trident_pitch` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：俯仰角，度 |
| `mcitem_charged_trident_roll` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：翻滚角，度 |
| `mcitem_charged_trident_x` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：前后位移，Source 单位 |
| `mcitem_charged_trident_y` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：左右位移，Source 单位 |
| `mcitem_charged_trident_yaw` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：偏航角，度 |
| `mcitem_charged_trident_z` | `0` | 客户端 | 三叉戟第一人称已装填 / 上弦静止时额外增量：上下位移，Source 单位 |

源码：[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-16"></a>

## MC Item：挥动分量倍率

全部为客户端变量。位置与旋转各分量独立相乘；1 原幅度，0 关闭该分量。item、bucket 按需创建，其余下列物品在加载时注册。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_swing_bow_pos_x` | `1` | 客户端 | 弓第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_bow_pos_y` | `1` | 客户端 | 弓第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_bow_pos_z` | `1` | 客户端 | 弓第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_bow_rot_pitch` | `1` | 客户端 | 弓第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_bow_rot_roll` | `1` | 客户端 | 弓第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_bow_rot_yaw` | `1` | 客户端 | 弓第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_bucket_pos_x` | `1` | 客户端 | 桶第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_bucket_pos_y` | `1` | 客户端 | 桶第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_bucket_pos_z` | `1` | 客户端 | 桶第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_bucket_rot_pitch` | `1` | 客户端 | 桶第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_bucket_rot_roll` | `1` | 客户端 | 桶第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_bucket_rot_yaw` | `1` | 客户端 | 桶第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_crossbow_pos_x` | `1` | 客户端 | 弩第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_crossbow_pos_y` | `1` | 客户端 | 弩第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_crossbow_pos_z` | `1` | 客户端 | 弩第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_crossbow_rot_pitch` | `1` | 客户端 | 弩第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_crossbow_rot_roll` | `1` | 客户端 | 弩第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_crossbow_rot_yaw` | `1` | 客户端 | 弩第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_fishing_rod_pos_x` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_fishing_rod_pos_y` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_fishing_rod_pos_z` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_fishing_rod_rot_pitch` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_fishing_rod_rot_roll` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_fishing_rod_rot_yaw` | `1` | 客户端 | 钓鱼竿第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_food_pos_x` | `1` | 客户端 | 食物第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_food_pos_y` | `1` | 客户端 | 食物第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_food_pos_z` | `1` | 客户端 | 食物第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_food_rot_pitch` | `1` | 客户端 | 食物第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_food_rot_roll` | `1` | 客户端 | 食物第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_food_rot_yaw` | `1` | 客户端 | 食物第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_item_pos_x` | `1` | 客户端 | 普通物品第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_item_pos_y` | `1` | 客户端 | 普通物品第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_item_pos_z` | `1` | 客户端 | 普通物品第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_item_rot_pitch` | `1` | 客户端 | 普通物品第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_item_rot_roll` | `1` | 客户端 | 普通物品第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_item_rot_yaw` | `1` | 客户端 | 普通物品第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_potion_pos_x` | `1` | 客户端 | 药水第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_potion_pos_y` | `1` | 客户端 | 药水第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_potion_pos_z` | `1` | 客户端 | 药水第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_potion_rot_pitch` | `1` | 客户端 | 药水第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_potion_rot_roll` | `1` | 客户端 | 药水第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_potion_rot_yaw` | `1` | 客户端 | 药水第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_shield_pos_x` | `1` | 客户端 | 盾牌第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_shield_pos_y` | `1` | 客户端 | 盾牌第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_shield_pos_z` | `1` | 客户端 | 盾牌第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_shield_rot_pitch` | `1` | 客户端 | 盾牌第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_shield_rot_roll` | `1` | 客户端 | 盾牌第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_shield_rot_yaw` | `1` | 客户端 | 盾牌第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_spear_pos_x` | `1` | 客户端 | 长矛第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_spear_pos_y` | `1` | 客户端 | 长矛第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_spear_pos_z` | `1` | 客户端 | 长矛第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_spear_rot_pitch` | `1` | 客户端 | 长矛第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_spear_rot_roll` | `1` | 客户端 | 长矛第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_spear_rot_yaw` | `1` | 客户端 | 长矛第一人称左键挥动的偏航旋转幅度倍率 |
| `mcitem_swing_trident_pos_x` | `1` | 客户端 | 三叉戟第一人称左键挥动的X 位移幅度倍率 |
| `mcitem_swing_trident_pos_y` | `1` | 客户端 | 三叉戟第一人称左键挥动的Y 位移幅度倍率 |
| `mcitem_swing_trident_pos_z` | `1` | 客户端 | 三叉戟第一人称左键挥动的Z 位移幅度倍率 |
| `mcitem_swing_trident_rot_pitch` | `1` | 客户端 | 三叉戟第一人称左键挥动的俯仰旋转幅度倍率 |
| `mcitem_swing_trident_rot_roll` | `1` | 客户端 | 三叉戟第一人称左键挥动的翻滚旋转幅度倍率 |
| `mcitem_swing_trident_rot_yaw` | `1` | 客户端 | 三叉戟第一人称左键挥动的偏航旋转幅度倍率 |

源码：[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-17"></a>

## MC Item：第三人称动画类型

服务器选择 GMod HoldType。可选值：normal、fist、melee、melee2、knife、smg、ar2、pistol、revolver、shotgun、rpg、physgun、grenade、slam、passive、magic、crossbow、camera、duel。无效名称退回该状态默认值。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_holdtype_bow` | `normal` | 服务器 | 弓静止的 GMod HoldType |
| `mcitem_holdtype_bow_attack` | `melee` | 服务器 | 弓左键攻击的 GMod HoldType |
| `mcitem_holdtype_bow_draw` | `revolver` | 服务器 | 拉弓的 GMod HoldType |
| `mcitem_holdtype_bucket_use` | `melee` | 服务器 | 桶取液 / 放液的 GMod HoldType |
| `mcitem_holdtype_crossbow` | `normal` | 服务器 | 弩静止的 GMod HoldType |
| `mcitem_holdtype_crossbow_attack` | `melee` | 服务器 | 弩左键攻击的 GMod HoldType |
| `mcitem_holdtype_crossbow_charged` | `revolver` | 服务器 | 弩已上弦的 GMod HoldType |
| `mcitem_holdtype_crossbow_load` | `shotgun` | 服务器 | 弩装填的 GMod HoldType |
| `mcitem_holdtype_eat` | `camera` | 服务器 | 进食 / 喝药的 GMod HoldType |
| `mcitem_holdtype_fishing_rod_use` | `melee` | 服务器 | 钓鱼竿使用的 GMod HoldType |
| `mcitem_holdtype_flint_and_steel_use` | `melee` | 服务器 | 打火石使用的 GMod HoldType |
| `mcitem_holdtype_item` | `normal` | 服务器 | 普通物品静止的 GMod HoldType |
| `mcitem_holdtype_item_attack` | `melee` | 服务器 | 普通物品左键攻击 / 挖掘的 GMod HoldType |
| `mcitem_holdtype_mace` | `melee` | 服务器 | 重锤的 GMod HoldType |
| `mcitem_holdtype_shears_use` | `melee` | 服务器 | 剪刀使用的 GMod HoldType |
| `mcitem_holdtype_shield` | `normal` | 服务器 | 盾牌静止的 GMod HoldType |
| `mcitem_holdtype_shield_block` | `slam` | 服务器 | 盾牌格挡的 GMod HoldType |
| `mcitem_holdtype_spear` | `normal` | 服务器 | 长矛静止的 GMod HoldType |
| `mcitem_holdtype_spear_attack` | `crossbow` | 服务器 | 长矛左键突刺的 GMod HoldType |
| `mcitem_holdtype_spear_use` | `crossbow` | 服务器 | 长矛右键冲刺的 GMod HoldType |
| `mcitem_holdtype_throw` | `grenade` | 服务器 | 投掷的 GMod HoldType |
| `mcitem_holdtype_trident` | `melee` | 服务器 | 三叉戟静止的 GMod HoldType |
| `mcitem_holdtype_trident_charge` | `melee` | 服务器 | 三叉戟蓄力的 GMod HoldType |
| `mcitem_holdtype_trident_melee` | `melee` | 服务器 | 三叉戟近战的 GMod HoldType |

源码：[sh_holdtypes.lua](../../../addons/mc_item/lua/mcitem/sh_holdtypes.lua)。

<a id="convars-18"></a>

## MC Item：第三人称状态模型

服务器控制阶段开关与阈值；客户端创建同名镜像供渲染读取。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_tp_bow_pull_1_threshold` | `0.65` | 服务器 | 弓切换阶段 1 的拉弦进度阈值 |
| `mcitem_tp_bow_pull_2_threshold` | `0.9` | 服务器 | 弓切换阶段 2 的拉弦进度阈值 |
| `mcitem_tp_bow_state_models` | `1` | 服务器 | 弓第三人称分阶段模型开关 |
| `mcitem_tp_crossbow_pull_1_threshold` | `0.58` | 服务器 | 弩切换阶段 1 的拉弦进度阈值 |
| `mcitem_tp_crossbow_pull_2_threshold` | `1` | 服务器 | 弩切换阶段 2 的拉弦进度阈值 |
| `mcitem_tp_crossbow_state_models` | `1` | 服务器 | 弩第三人称分阶段模型开关 |

源码：[sh_holdtypes.lua](../../../addons/mc_item/lua/mcitem/sh_holdtypes.lua)。

<a id="convars-19"></a>

## MC Item：第三人称姿态

全部为客户端变量，按物品 / 状态独立注册。x/y/z 沿玩家右手骨骼 Forward/Right/Up 偏移；pitch/yaw/roll 绕 Right/Up/Forward 旋转，单位为度；scale 为世界模型倍率。已登记但没有专用默认姿态的状态注册为位置 / 角度 0、scale 1；未登记的状态回退到 idle。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_tp_axe_attack_pitch` | `-10` | 客户端 | 斧 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_axe_attack_roll` | `50` | 客户端 | 斧 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_axe_attack_scale` | `1.3` | 客户端 | 斧 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_axe_attack_x` | `1.5` | 客户端 | 斧 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_axe_attack_y` | `5` | 客户端 | 斧 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_axe_attack_yaw` | `-200` | 客户端 | 斧 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_axe_attack_z` | `-1` | 客户端 | 斧 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_axe_idle_pitch` | `-10` | 客户端 | 斧 / 静止：俯仰角，度 |
| `mcitem_tp_axe_idle_roll` | `50` | 客户端 | 斧 / 静止：翻滚角，度 |
| `mcitem_tp_axe_idle_scale` | `1.3` | 客户端 | 斧 / 静止：缩放倍率 |
| `mcitem_tp_axe_idle_x` | `1.5` | 客户端 | 斧 / 静止：前后位移，Source 单位 |
| `mcitem_tp_axe_idle_y` | `5` | 客户端 | 斧 / 静止：左右位移，Source 单位 |
| `mcitem_tp_axe_idle_yaw` | `-200` | 客户端 | 斧 / 静止：偏航角，度 |
| `mcitem_tp_axe_idle_z` | `-1` | 客户端 | 斧 / 静止：上下位移，Source 单位 |
| `mcitem_tp_bow_attack_pitch` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_bow_attack_roll` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_bow_attack_scale` | `1` | 客户端 | 弓 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_bow_attack_x` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_bow_attack_y` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_bow_attack_yaw` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_bow_attack_z` | `0` | 客户端 | 弓 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_bow_draw_0_pitch` | `6` | 客户端 | 弓 / 拉弓阶段 0：俯仰角，度 |
| `mcitem_tp_bow_draw_0_roll` | `220` | 客户端 | 弓 / 拉弓阶段 0：翻滚角，度 |
| `mcitem_tp_bow_draw_0_scale` | `1.3` | 客户端 | 弓 / 拉弓阶段 0：缩放倍率 |
| `mcitem_tp_bow_draw_0_x` | `0` | 客户端 | 弓 / 拉弓阶段 0：前后位移，Source 单位 |
| `mcitem_tp_bow_draw_0_y` | `8` | 客户端 | 弓 / 拉弓阶段 0：左右位移，Source 单位 |
| `mcitem_tp_bow_draw_0_yaw` | `-25` | 客户端 | 弓 / 拉弓阶段 0：偏航角，度 |
| `mcitem_tp_bow_draw_0_z` | `-5` | 客户端 | 弓 / 拉弓阶段 0：上下位移，Source 单位 |
| `mcitem_tp_bow_draw_1_pitch` | `6` | 客户端 | 弓 / 拉弓阶段 1：俯仰角，度 |
| `mcitem_tp_bow_draw_1_roll` | `220` | 客户端 | 弓 / 拉弓阶段 1：翻滚角，度 |
| `mcitem_tp_bow_draw_1_scale` | `1.3` | 客户端 | 弓 / 拉弓阶段 1：缩放倍率 |
| `mcitem_tp_bow_draw_1_x` | `0` | 客户端 | 弓 / 拉弓阶段 1：前后位移，Source 单位 |
| `mcitem_tp_bow_draw_1_y` | `8` | 客户端 | 弓 / 拉弓阶段 1：左右位移，Source 单位 |
| `mcitem_tp_bow_draw_1_yaw` | `-25` | 客户端 | 弓 / 拉弓阶段 1：偏航角，度 |
| `mcitem_tp_bow_draw_1_z` | `-5` | 客户端 | 弓 / 拉弓阶段 1：上下位移，Source 单位 |
| `mcitem_tp_bow_draw_2_pitch` | `6` | 客户端 | 弓 / 拉弓阶段 2：俯仰角，度 |
| `mcitem_tp_bow_draw_2_roll` | `220` | 客户端 | 弓 / 拉弓阶段 2：翻滚角，度 |
| `mcitem_tp_bow_draw_2_scale` | `1.3` | 客户端 | 弓 / 拉弓阶段 2：缩放倍率 |
| `mcitem_tp_bow_draw_2_x` | `0` | 客户端 | 弓 / 拉弓阶段 2：前后位移，Source 单位 |
| `mcitem_tp_bow_draw_2_y` | `8` | 客户端 | 弓 / 拉弓阶段 2：左右位移，Source 单位 |
| `mcitem_tp_bow_draw_2_yaw` | `-25` | 客户端 | 弓 / 拉弓阶段 2：偏航角，度 |
| `mcitem_tp_bow_draw_2_z` | `-5` | 客户端 | 弓 / 拉弓阶段 2：上下位移，Source 单位 |
| `mcitem_tp_bow_idle_pitch` | `0` | 客户端 | 弓 / 静止：俯仰角，度 |
| `mcitem_tp_bow_idle_roll` | `180` | 客户端 | 弓 / 静止：翻滚角，度 |
| `mcitem_tp_bow_idle_scale` | `1.3` | 客户端 | 弓 / 静止：缩放倍率 |
| `mcitem_tp_bow_idle_x` | `0` | 客户端 | 弓 / 静止：前后位移，Source 单位 |
| `mcitem_tp_bow_idle_y` | `6` | 客户端 | 弓 / 静止：左右位移，Source 单位 |
| `mcitem_tp_bow_idle_yaw` | `0` | 客户端 | 弓 / 静止：偏航角，度 |
| `mcitem_tp_bow_idle_z` | `-9` | 客户端 | 弓 / 静止：上下位移，Source 单位 |
| `mcitem_tp_crossbow_attack_pitch` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_crossbow_attack_roll` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_crossbow_attack_scale` | `1` | 客户端 | 弩 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_crossbow_attack_x` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_crossbow_attack_y` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_crossbow_attack_yaw` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_crossbow_attack_z` | `0` | 客户端 | 弩 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_crossbow_charged_arrow_pitch` | `90` | 客户端 | 弩 / 已装箭：俯仰角，度 |
| `mcitem_tp_crossbow_charged_arrow_roll` | `195` | 客户端 | 弩 / 已装箭：翻滚角，度 |
| `mcitem_tp_crossbow_charged_arrow_scale` | `1.3` | 客户端 | 弩 / 已装箭：缩放倍率 |
| `mcitem_tp_crossbow_charged_arrow_x` | `0` | 客户端 | 弩 / 已装箭：前后位移，Source 单位 |
| `mcitem_tp_crossbow_charged_arrow_y` | `9` | 客户端 | 弩 / 已装箭：左右位移，Source 单位 |
| `mcitem_tp_crossbow_charged_arrow_yaw` | `10` | 客户端 | 弩 / 已装箭：偏航角，度 |
| `mcitem_tp_crossbow_charged_arrow_z` | `-6.5` | 客户端 | 弩 / 已装箭：上下位移，Source 单位 |
| `mcitem_tp_crossbow_charged_firework_pitch` | `90` | 客户端 | 弩 / 已装烟花：俯仰角，度 |
| `mcitem_tp_crossbow_charged_firework_roll` | `195` | 客户端 | 弩 / 已装烟花：翻滚角，度 |
| `mcitem_tp_crossbow_charged_firework_scale` | `1.3` | 客户端 | 弩 / 已装烟花：缩放倍率 |
| `mcitem_tp_crossbow_charged_firework_x` | `0` | 客户端 | 弩 / 已装烟花：前后位移，Source 单位 |
| `mcitem_tp_crossbow_charged_firework_y` | `9` | 客户端 | 弩 / 已装烟花：左右位移，Source 单位 |
| `mcitem_tp_crossbow_charged_firework_yaw` | `10` | 客户端 | 弩 / 已装烟花：偏航角，度 |
| `mcitem_tp_crossbow_charged_firework_z` | `-6.5` | 客户端 | 弩 / 已装烟花：上下位移，Source 单位 |
| `mcitem_tp_crossbow_idle_pitch` | `10` | 客户端 | 弩 / 静止：俯仰角，度 |
| `mcitem_tp_crossbow_idle_roll` | `190` | 客户端 | 弩 / 静止：翻滚角，度 |
| `mcitem_tp_crossbow_idle_scale` | `1.3` | 客户端 | 弩 / 静止：缩放倍率 |
| `mcitem_tp_crossbow_idle_x` | `0` | 客户端 | 弩 / 静止：前后位移，Source 单位 |
| `mcitem_tp_crossbow_idle_y` | `5` | 客户端 | 弩 / 静止：左右位移，Source 单位 |
| `mcitem_tp_crossbow_idle_yaw` | `-25` | 客户端 | 弩 / 静止：偏航角，度 |
| `mcitem_tp_crossbow_idle_z` | `-9` | 客户端 | 弩 / 静止：上下位移，Source 单位 |
| `mcitem_tp_crossbow_load_0_pitch` | `-270` | 客户端 | 弩 / 装填阶段 0：俯仰角，度 |
| `mcitem_tp_crossbow_load_0_roll` | `200` | 客户端 | 弩 / 装填阶段 0：翻滚角，度 |
| `mcitem_tp_crossbow_load_0_scale` | `1.3` | 客户端 | 弩 / 装填阶段 0：缩放倍率 |
| `mcitem_tp_crossbow_load_0_x` | `0` | 客户端 | 弩 / 装填阶段 0：前后位移，Source 单位 |
| `mcitem_tp_crossbow_load_0_y` | `0` | 客户端 | 弩 / 装填阶段 0：左右位移，Source 单位 |
| `mcitem_tp_crossbow_load_0_yaw` | `0` | 客户端 | 弩 / 装填阶段 0：偏航角，度 |
| `mcitem_tp_crossbow_load_0_z` | `-5` | 客户端 | 弩 / 装填阶段 0：上下位移，Source 单位 |
| `mcitem_tp_crossbow_load_1_pitch` | `-270` | 客户端 | 弩 / 装填阶段 1：俯仰角，度 |
| `mcitem_tp_crossbow_load_1_roll` | `200` | 客户端 | 弩 / 装填阶段 1：翻滚角，度 |
| `mcitem_tp_crossbow_load_1_scale` | `1.3` | 客户端 | 弩 / 装填阶段 1：缩放倍率 |
| `mcitem_tp_crossbow_load_1_x` | `0` | 客户端 | 弩 / 装填阶段 1：前后位移，Source 单位 |
| `mcitem_tp_crossbow_load_1_y` | `0` | 客户端 | 弩 / 装填阶段 1：左右位移，Source 单位 |
| `mcitem_tp_crossbow_load_1_yaw` | `0` | 客户端 | 弩 / 装填阶段 1：偏航角，度 |
| `mcitem_tp_crossbow_load_1_z` | `-5` | 客户端 | 弩 / 装填阶段 1：上下位移，Source 单位 |
| `mcitem_tp_crossbow_load_2_pitch` | `-270` | 客户端 | 弩 / 装填阶段 2：俯仰角，度 |
| `mcitem_tp_crossbow_load_2_roll` | `200` | 客户端 | 弩 / 装填阶段 2：翻滚角，度 |
| `mcitem_tp_crossbow_load_2_scale` | `1.3` | 客户端 | 弩 / 装填阶段 2：缩放倍率 |
| `mcitem_tp_crossbow_load_2_x` | `0` | 客户端 | 弩 / 装填阶段 2：前后位移，Source 单位 |
| `mcitem_tp_crossbow_load_2_y` | `0` | 客户端 | 弩 / 装填阶段 2：左右位移，Source 单位 |
| `mcitem_tp_crossbow_load_2_yaw` | `0` | 客户端 | 弩 / 装填阶段 2：偏航角，度 |
| `mcitem_tp_crossbow_load_2_z` | `-5` | 客户端 | 弩 / 装填阶段 2：上下位移，Source 单位 |
| `mcitem_tp_fishing_rod_attack_pitch` | `0` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_fishing_rod_attack_roll` | `0` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_fishing_rod_attack_scale` | `0.6` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_fishing_rod_attack_x` | `1` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_fishing_rod_attack_y` | `5` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_fishing_rod_attack_yaw` | `-20` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_fishing_rod_attack_z` | `-5` | 客户端 | 钓鱼竿 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_fishing_rod_idle_pitch` | `0` | 客户端 | 钓鱼竿 / 静止：俯仰角，度 |
| `mcitem_tp_fishing_rod_idle_roll` | `0` | 客户端 | 钓鱼竿 / 静止：翻滚角，度 |
| `mcitem_tp_fishing_rod_idle_scale` | `0.6` | 客户端 | 钓鱼竿 / 静止：缩放倍率 |
| `mcitem_tp_fishing_rod_idle_x` | `1` | 客户端 | 钓鱼竿 / 静止：前后位移，Source 单位 |
| `mcitem_tp_fishing_rod_idle_y` | `5` | 客户端 | 钓鱼竿 / 静止：左右位移，Source 单位 |
| `mcitem_tp_fishing_rod_idle_yaw` | `-20` | 客户端 | 钓鱼竿 / 静止：偏航角，度 |
| `mcitem_tp_fishing_rod_idle_z` | `-5` | 客户端 | 钓鱼竿 / 静止：上下位移，Source 单位 |
| `mcitem_tp_fishing_rod_use_pitch` | `0` | 客户端 | 钓鱼竿 / 使用：俯仰角，度 |
| `mcitem_tp_fishing_rod_use_roll` | `0` | 客户端 | 钓鱼竿 / 使用：翻滚角，度 |
| `mcitem_tp_fishing_rod_use_scale` | `0.6` | 客户端 | 钓鱼竿 / 使用：缩放倍率 |
| `mcitem_tp_fishing_rod_use_x` | `1` | 客户端 | 钓鱼竿 / 使用：前后位移，Source 单位 |
| `mcitem_tp_fishing_rod_use_y` | `5` | 客户端 | 钓鱼竿 / 使用：左右位移，Source 单位 |
| `mcitem_tp_fishing_rod_use_yaw` | `-20` | 客户端 | 钓鱼竿 / 使用：偏航角，度 |
| `mcitem_tp_fishing_rod_use_z` | `-5` | 客户端 | 钓鱼竿 / 使用：上下位移，Source 单位 |
| `mcitem_tp_flint_and_steel_attack_pitch` | `0` | 客户端 | 打火石 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_flint_and_steel_attack_roll` | `-45` | 客户端 | 打火石 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_flint_and_steel_attack_scale` | `0.6` | 客户端 | 打火石 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_flint_and_steel_attack_x` | `1` | 客户端 | 打火石 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_flint_and_steel_attack_y` | `5` | 客户端 | 打火石 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_flint_and_steel_attack_yaw` | `-20` | 客户端 | 打火石 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_flint_and_steel_attack_z` | `-4` | 客户端 | 打火石 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_flint_and_steel_idle_pitch` | `0` | 客户端 | 打火石 / 静止：俯仰角，度 |
| `mcitem_tp_flint_and_steel_idle_roll` | `-45` | 客户端 | 打火石 / 静止：翻滚角，度 |
| `mcitem_tp_flint_and_steel_idle_scale` | `0.6` | 客户端 | 打火石 / 静止：缩放倍率 |
| `mcitem_tp_flint_and_steel_idle_x` | `1` | 客户端 | 打火石 / 静止：前后位移，Source 单位 |
| `mcitem_tp_flint_and_steel_idle_y` | `5` | 客户端 | 打火石 / 静止：左右位移，Source 单位 |
| `mcitem_tp_flint_and_steel_idle_yaw` | `-20` | 客户端 | 打火石 / 静止：偏航角，度 |
| `mcitem_tp_flint_and_steel_idle_z` | `-4` | 客户端 | 打火石 / 静止：上下位移，Source 单位 |
| `mcitem_tp_flint_and_steel_use_pitch` | `0` | 客户端 | 打火石 / 使用：俯仰角，度 |
| `mcitem_tp_flint_and_steel_use_roll` | `-45` | 客户端 | 打火石 / 使用：翻滚角，度 |
| `mcitem_tp_flint_and_steel_use_scale` | `0.6` | 客户端 | 打火石 / 使用：缩放倍率 |
| `mcitem_tp_flint_and_steel_use_x` | `1` | 客户端 | 打火石 / 使用：前后位移，Source 单位 |
| `mcitem_tp_flint_and_steel_use_y` | `5` | 客户端 | 打火石 / 使用：左右位移，Source 单位 |
| `mcitem_tp_flint_and_steel_use_yaw` | `-20` | 客户端 | 打火石 / 使用：偏航角，度 |
| `mcitem_tp_flint_and_steel_use_z` | `-4` | 客户端 | 打火石 / 使用：上下位移，Source 单位 |
| `mcitem_tp_food_attack_pitch` | `0` | 客户端 | 食物 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_food_attack_roll` | `0` | 客户端 | 食物 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_food_attack_scale` | `0.6` | 客户端 | 食物 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_food_attack_x` | `1` | 客户端 | 食物 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_food_attack_y` | `5` | 客户端 | 食物 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_food_attack_yaw` | `-20` | 客户端 | 食物 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_food_attack_z` | `-5` | 客户端 | 食物 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_food_idle_pitch` | `0` | 客户端 | 食物 / 静止：俯仰角，度 |
| `mcitem_tp_food_idle_roll` | `0` | 客户端 | 食物 / 静止：翻滚角，度 |
| `mcitem_tp_food_idle_scale` | `0.6` | 客户端 | 食物 / 静止：缩放倍率 |
| `mcitem_tp_food_idle_x` | `1` | 客户端 | 食物 / 静止：前后位移，Source 单位 |
| `mcitem_tp_food_idle_y` | `5` | 客户端 | 食物 / 静止：左右位移，Source 单位 |
| `mcitem_tp_food_idle_yaw` | `-20` | 客户端 | 食物 / 静止：偏航角，度 |
| `mcitem_tp_food_idle_z` | `-5` | 客户端 | 食物 / 静止：上下位移，Source 单位 |
| `mcitem_tp_food_use_pitch` | `30` | 客户端 | 食物 / 使用：俯仰角，度 |
| `mcitem_tp_food_use_roll` | `20` | 客户端 | 食物 / 使用：翻滚角，度 |
| `mcitem_tp_food_use_scale` | `0.6` | 客户端 | 食物 / 使用：缩放倍率 |
| `mcitem_tp_food_use_x` | `-3` | 客户端 | 食物 / 使用：前后位移，Source 单位 |
| `mcitem_tp_food_use_y` | `5` | 客户端 | 食物 / 使用：左右位移，Source 单位 |
| `mcitem_tp_food_use_yaw` | `60` | 客户端 | 食物 / 使用：偏航角，度 |
| `mcitem_tp_food_use_z` | `-9` | 客户端 | 食物 / 使用：上下位移，Source 单位 |
| `mcitem_tp_hoe_attack_pitch` | `-10` | 客户端 | 锄 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_hoe_attack_roll` | `50` | 客户端 | 锄 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_hoe_attack_scale` | `1.3` | 客户端 | 锄 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_hoe_attack_x` | `1.5` | 客户端 | 锄 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_hoe_attack_y` | `5` | 客户端 | 锄 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_hoe_attack_yaw` | `-200` | 客户端 | 锄 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_hoe_attack_z` | `-1` | 客户端 | 锄 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_hoe_idle_pitch` | `-10` | 客户端 | 锄 / 静止：俯仰角，度 |
| `mcitem_tp_hoe_idle_roll` | `50` | 客户端 | 锄 / 静止：翻滚角，度 |
| `mcitem_tp_hoe_idle_scale` | `1.3` | 客户端 | 锄 / 静止：缩放倍率 |
| `mcitem_tp_hoe_idle_x` | `1.5` | 客户端 | 锄 / 静止：前后位移，Source 单位 |
| `mcitem_tp_hoe_idle_y` | `5` | 客户端 | 锄 / 静止：左右位移，Source 单位 |
| `mcitem_tp_hoe_idle_yaw` | `-200` | 客户端 | 锄 / 静止：偏航角，度 |
| `mcitem_tp_hoe_idle_z` | `-1` | 客户端 | 锄 / 静止：上下位移，Source 单位 |
| `mcitem_tp_mace_attack_pitch` | `5` | 客户端 | 重锤 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_mace_attack_roll` | `0` | 客户端 | 重锤 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_mace_attack_scale` | `1.4` | 客户端 | 重锤 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_mace_attack_x` | `-0.8` | 客户端 | 重锤 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_mace_attack_y` | `2` | 客户端 | 重锤 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_mace_attack_yaw` | `2` | 客户端 | 重锤 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_mace_attack_z` | `-2` | 客户端 | 重锤 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_mace_idle_pitch` | `5` | 客户端 | 重锤 / 静止：俯仰角，度 |
| `mcitem_tp_mace_idle_roll` | `0` | 客户端 | 重锤 / 静止：翻滚角，度 |
| `mcitem_tp_mace_idle_scale` | `1.4` | 客户端 | 重锤 / 静止：缩放倍率 |
| `mcitem_tp_mace_idle_x` | `-0.8` | 客户端 | 重锤 / 静止：前后位移，Source 单位 |
| `mcitem_tp_mace_idle_y` | `2` | 客户端 | 重锤 / 静止：左右位移，Source 单位 |
| `mcitem_tp_mace_idle_yaw` | `2` | 客户端 | 重锤 / 静止：偏航角，度 |
| `mcitem_tp_mace_idle_z` | `-2` | 客户端 | 重锤 / 静止：上下位移，Source 单位 |
| `mcitem_tp_name_tag_attack_pitch` | `0` | 客户端 | 命名牌 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_name_tag_attack_roll` | `0` | 客户端 | 命名牌 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_name_tag_attack_scale` | `0.6` | 客户端 | 命名牌 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_name_tag_attack_x` | `1` | 客户端 | 命名牌 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_name_tag_attack_y` | `5` | 客户端 | 命名牌 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_name_tag_attack_yaw` | `-20` | 客户端 | 命名牌 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_name_tag_attack_z` | `-5` | 客户端 | 命名牌 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_name_tag_idle_pitch` | `0` | 客户端 | 命名牌 / 静止：俯仰角，度 |
| `mcitem_tp_name_tag_idle_roll` | `0` | 客户端 | 命名牌 / 静止：翻滚角，度 |
| `mcitem_tp_name_tag_idle_scale` | `0.6` | 客户端 | 命名牌 / 静止：缩放倍率 |
| `mcitem_tp_name_tag_idle_x` | `1` | 客户端 | 命名牌 / 静止：前后位移，Source 单位 |
| `mcitem_tp_name_tag_idle_y` | `5` | 客户端 | 命名牌 / 静止：左右位移，Source 单位 |
| `mcitem_tp_name_tag_idle_yaw` | `-20` | 客户端 | 命名牌 / 静止：偏航角，度 |
| `mcitem_tp_name_tag_idle_z` | `-5` | 客户端 | 命名牌 / 静止：上下位移，Source 单位 |
| `mcitem_tp_pickaxe_attack_pitch` | `-10` | 客户端 | 镐 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_pickaxe_attack_roll` | `50` | 客户端 | 镐 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_pickaxe_attack_scale` | `1.3` | 客户端 | 镐 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_pickaxe_attack_x` | `1.5` | 客户端 | 镐 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_pickaxe_attack_y` | `5` | 客户端 | 镐 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_pickaxe_attack_yaw` | `-200` | 客户端 | 镐 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_pickaxe_attack_z` | `-1` | 客户端 | 镐 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_pickaxe_idle_pitch` | `-10` | 客户端 | 镐 / 静止：俯仰角，度 |
| `mcitem_tp_pickaxe_idle_roll` | `50` | 客户端 | 镐 / 静止：翻滚角，度 |
| `mcitem_tp_pickaxe_idle_scale` | `1.3` | 客户端 | 镐 / 静止：缩放倍率 |
| `mcitem_tp_pickaxe_idle_x` | `1.5` | 客户端 | 镐 / 静止：前后位移，Source 单位 |
| `mcitem_tp_pickaxe_idle_y` | `5` | 客户端 | 镐 / 静止：左右位移，Source 单位 |
| `mcitem_tp_pickaxe_idle_yaw` | `-200` | 客户端 | 镐 / 静止：偏航角，度 |
| `mcitem_tp_pickaxe_idle_z` | `-1` | 客户端 | 镐 / 静止：上下位移，Source 单位 |
| `mcitem_tp_potion_attack_pitch` | `0` | 客户端 | 药水 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_potion_attack_roll` | `0` | 客户端 | 药水 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_potion_attack_scale` | `0.6` | 客户端 | 药水 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_potion_attack_x` | `1` | 客户端 | 药水 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_potion_attack_y` | `5` | 客户端 | 药水 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_potion_attack_yaw` | `-20` | 客户端 | 药水 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_potion_attack_z` | `-5` | 客户端 | 药水 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_potion_idle_pitch` | `0` | 客户端 | 药水 / 静止：俯仰角，度 |
| `mcitem_tp_potion_idle_roll` | `0` | 客户端 | 药水 / 静止：翻滚角，度 |
| `mcitem_tp_potion_idle_scale` | `0.6` | 客户端 | 药水 / 静止：缩放倍率 |
| `mcitem_tp_potion_idle_x` | `1` | 客户端 | 药水 / 静止：前后位移，Source 单位 |
| `mcitem_tp_potion_idle_y` | `5` | 客户端 | 药水 / 静止：左右位移，Source 单位 |
| `mcitem_tp_potion_idle_yaw` | `-20` | 客户端 | 药水 / 静止：偏航角，度 |
| `mcitem_tp_potion_idle_z` | `-5` | 客户端 | 药水 / 静止：上下位移，Source 单位 |
| `mcitem_tp_potion_throw_pitch` | `0` | 客户端 | 药水 / 投掷：俯仰角，度 |
| `mcitem_tp_potion_throw_roll` | `0` | 客户端 | 药水 / 投掷：翻滚角，度 |
| `mcitem_tp_potion_throw_scale` | `1` | 客户端 | 药水 / 投掷：缩放倍率 |
| `mcitem_tp_potion_throw_x` | `0` | 客户端 | 药水 / 投掷：前后位移，Source 单位 |
| `mcitem_tp_potion_throw_y` | `0` | 客户端 | 药水 / 投掷：左右位移，Source 单位 |
| `mcitem_tp_potion_throw_yaw` | `0` | 客户端 | 药水 / 投掷：偏航角，度 |
| `mcitem_tp_potion_throw_z` | `0` | 客户端 | 药水 / 投掷：上下位移，Source 单位 |
| `mcitem_tp_potion_use_pitch` | `30` | 客户端 | 药水 / 使用：俯仰角，度 |
| `mcitem_tp_potion_use_roll` | `20` | 客户端 | 药水 / 使用：翻滚角，度 |
| `mcitem_tp_potion_use_scale` | `0.6` | 客户端 | 药水 / 使用：缩放倍率 |
| `mcitem_tp_potion_use_x` | `-3` | 客户端 | 药水 / 使用：前后位移，Source 单位 |
| `mcitem_tp_potion_use_y` | `5` | 客户端 | 药水 / 使用：左右位移，Source 单位 |
| `mcitem_tp_potion_use_yaw` | `60` | 客户端 | 药水 / 使用：偏航角，度 |
| `mcitem_tp_potion_use_z` | `-9` | 客户端 | 药水 / 使用：上下位移，Source 单位 |
| `mcitem_tp_shears_attack_pitch` | `0` | 客户端 | 剪刀 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_shears_attack_roll` | `0` | 客户端 | 剪刀 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_shears_attack_scale` | `0.6` | 客户端 | 剪刀 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_shears_attack_x` | `1` | 客户端 | 剪刀 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_shears_attack_y` | `5` | 客户端 | 剪刀 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_shears_attack_yaw` | `-20` | 客户端 | 剪刀 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_shears_attack_z` | `-5` | 客户端 | 剪刀 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_shears_idle_pitch` | `0` | 客户端 | 剪刀 / 静止：俯仰角，度 |
| `mcitem_tp_shears_idle_roll` | `0` | 客户端 | 剪刀 / 静止：翻滚角，度 |
| `mcitem_tp_shears_idle_scale` | `0.6` | 客户端 | 剪刀 / 静止：缩放倍率 |
| `mcitem_tp_shears_idle_x` | `1` | 客户端 | 剪刀 / 静止：前后位移，Source 单位 |
| `mcitem_tp_shears_idle_y` | `5` | 客户端 | 剪刀 / 静止：左右位移，Source 单位 |
| `mcitem_tp_shears_idle_yaw` | `-20` | 客户端 | 剪刀 / 静止：偏航角，度 |
| `mcitem_tp_shears_idle_z` | `-5` | 客户端 | 剪刀 / 静止：上下位移，Source 单位 |
| `mcitem_tp_shears_use_pitch` | `0` | 客户端 | 剪刀 / 使用：俯仰角，度 |
| `mcitem_tp_shears_use_roll` | `0` | 客户端 | 剪刀 / 使用：翻滚角，度 |
| `mcitem_tp_shears_use_scale` | `0.6` | 客户端 | 剪刀 / 使用：缩放倍率 |
| `mcitem_tp_shears_use_x` | `1` | 客户端 | 剪刀 / 使用：前后位移，Source 单位 |
| `mcitem_tp_shears_use_y` | `5` | 客户端 | 剪刀 / 使用：左右位移，Source 单位 |
| `mcitem_tp_shears_use_yaw` | `-20` | 客户端 | 剪刀 / 使用：偏航角，度 |
| `mcitem_tp_shears_use_z` | `-5` | 客户端 | 剪刀 / 使用：上下位移，Source 单位 |
| `mcitem_tp_shield_attack_pitch` | `180` | 客户端 | 盾牌 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_shield_attack_roll` | `5` | 客户端 | 盾牌 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_shield_attack_scale` | `1.3` | 客户端 | 盾牌 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_shield_attack_x` | `2` | 客户端 | 盾牌 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_shield_attack_y` | `12` | 客户端 | 盾牌 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_shield_attack_yaw` | `30` | 客户端 | 盾牌 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_shield_attack_z` | `-4` | 客户端 | 盾牌 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_shield_block_pitch` | `165` | 客户端 | 盾牌 / 格挡：俯仰角，度 |
| `mcitem_tp_shield_block_roll` | `170` | 客户端 | 盾牌 / 格挡：翻滚角，度 |
| `mcitem_tp_shield_block_scale` | `1.3` | 客户端 | 盾牌 / 格挡：缩放倍率 |
| `mcitem_tp_shield_block_x` | `0` | 客户端 | 盾牌 / 格挡：前后位移，Source 单位 |
| `mcitem_tp_shield_block_y` | `0` | 客户端 | 盾牌 / 格挡：左右位移，Source 单位 |
| `mcitem_tp_shield_block_yaw` | `-90` | 客户端 | 盾牌 / 格挡：偏航角，度 |
| `mcitem_tp_shield_block_z` | `-6` | 客户端 | 盾牌 / 格挡：上下位移，Source 单位 |
| `mcitem_tp_shield_idle_pitch` | `180` | 客户端 | 盾牌 / 静止：俯仰角，度 |
| `mcitem_tp_shield_idle_roll` | `5` | 客户端 | 盾牌 / 静止：翻滚角，度 |
| `mcitem_tp_shield_idle_scale` | `1.3` | 客户端 | 盾牌 / 静止：缩放倍率 |
| `mcitem_tp_shield_idle_x` | `2` | 客户端 | 盾牌 / 静止：前后位移，Source 单位 |
| `mcitem_tp_shield_idle_y` | `12` | 客户端 | 盾牌 / 静止：左右位移，Source 单位 |
| `mcitem_tp_shield_idle_yaw` | `30` | 客户端 | 盾牌 / 静止：偏航角，度 |
| `mcitem_tp_shield_idle_z` | `-4` | 客户端 | 盾牌 / 静止：上下位移，Source 单位 |
| `mcitem_tp_shovel_attack_pitch` | `-10` | 客户端 | 铲 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_shovel_attack_roll` | `50` | 客户端 | 铲 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_shovel_attack_scale` | `1.3` | 客户端 | 铲 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_shovel_attack_x` | `1.5` | 客户端 | 铲 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_shovel_attack_y` | `5` | 客户端 | 铲 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_shovel_attack_yaw` | `-200` | 客户端 | 铲 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_shovel_attack_z` | `-1` | 客户端 | 铲 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_shovel_idle_pitch` | `-10` | 客户端 | 铲 / 静止：俯仰角，度 |
| `mcitem_tp_shovel_idle_roll` | `50` | 客户端 | 铲 / 静止：翻滚角，度 |
| `mcitem_tp_shovel_idle_scale` | `1.3` | 客户端 | 铲 / 静止：缩放倍率 |
| `mcitem_tp_shovel_idle_x` | `1.5` | 客户端 | 铲 / 静止：前后位移，Source 单位 |
| `mcitem_tp_shovel_idle_y` | `5` | 客户端 | 铲 / 静止：左右位移，Source 单位 |
| `mcitem_tp_shovel_idle_yaw` | `-200` | 客户端 | 铲 / 静止：偏航角，度 |
| `mcitem_tp_shovel_idle_z` | `-1` | 客户端 | 铲 / 静止：上下位移，Source 单位 |
| `mcitem_tp_spear_attack_pitch` | `15` | 客户端 | 长矛 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_spear_attack_roll` | `205` | 客户端 | 长矛 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_spear_attack_scale` | `2` | 客户端 | 长矛 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_spear_attack_x` | `7` | 客户端 | 长矛 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_spear_attack_y` | `-3` | 客户端 | 长矛 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_spear_attack_yaw` | `-35` | 客户端 | 长矛 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_spear_attack_z` | `-10` | 客户端 | 长矛 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_spear_idle_pitch` | `-5` | 客户端 | 长矛 / 静止：俯仰角，度 |
| `mcitem_tp_spear_idle_roll` | `50` | 客户端 | 长矛 / 静止：翻滚角，度 |
| `mcitem_tp_spear_idle_scale` | `2` | 客户端 | 长矛 / 静止：缩放倍率 |
| `mcitem_tp_spear_idle_x` | `0` | 客户端 | 长矛 / 静止：前后位移，Source 单位 |
| `mcitem_tp_spear_idle_y` | `7` | 客户端 | 长矛 / 静止：左右位移，Source 单位 |
| `mcitem_tp_spear_idle_yaw` | `150` | 客户端 | 长矛 / 静止：偏航角，度 |
| `mcitem_tp_spear_idle_z` | `-1` | 客户端 | 长矛 / 静止：上下位移，Source 单位 |
| `mcitem_tp_spear_use_pitch` | `15` | 客户端 | 长矛 / 使用：俯仰角，度 |
| `mcitem_tp_spear_use_roll` | `205` | 客户端 | 长矛 / 使用：翻滚角，度 |
| `mcitem_tp_spear_use_scale` | `2` | 客户端 | 长矛 / 使用：缩放倍率 |
| `mcitem_tp_spear_use_x` | `7` | 客户端 | 长矛 / 使用：前后位移，Source 单位 |
| `mcitem_tp_spear_use_y` | `-3` | 客户端 | 长矛 / 使用：左右位移，Source 单位 |
| `mcitem_tp_spear_use_yaw` | `-35` | 客户端 | 长矛 / 使用：偏航角，度 |
| `mcitem_tp_spear_use_z` | `-10` | 客户端 | 长矛 / 使用：上下位移，Source 单位 |
| `mcitem_tp_sword_attack_pitch` | `-15` | 客户端 | 剑 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_sword_attack_roll` | `48` | 客户端 | 剑 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_sword_attack_scale` | `1.3` | 客户端 | 剑 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_sword_attack_x` | `2` | 客户端 | 剑 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_sword_attack_y` | `7` | 客户端 | 剑 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_sword_attack_yaw` | `-35` | 客户端 | 剑 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_sword_attack_z` | `3` | 客户端 | 剑 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_sword_idle_pitch` | `-15` | 客户端 | 剑 / 静止：俯仰角，度 |
| `mcitem_tp_sword_idle_roll` | `48` | 客户端 | 剑 / 静止：翻滚角，度 |
| `mcitem_tp_sword_idle_scale` | `1.3` | 客户端 | 剑 / 静止：缩放倍率 |
| `mcitem_tp_sword_idle_x` | `2` | 客户端 | 剑 / 静止：前后位移，Source 单位 |
| `mcitem_tp_sword_idle_y` | `7` | 客户端 | 剑 / 静止：左右位移，Source 单位 |
| `mcitem_tp_sword_idle_yaw` | `-35` | 客户端 | 剑 / 静止：偏航角，度 |
| `mcitem_tp_sword_idle_z` | `3` | 客户端 | 剑 / 静止：上下位移，Source 单位 |
| `mcitem_tp_throwable_attack_pitch` | `0` | 客户端 | 投掷物 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_throwable_attack_roll` | `0` | 客户端 | 投掷物 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_throwable_attack_scale` | `0.6` | 客户端 | 投掷物 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_throwable_attack_x` | `1` | 客户端 | 投掷物 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_throwable_attack_y` | `5` | 客户端 | 投掷物 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_throwable_attack_yaw` | `-20` | 客户端 | 投掷物 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_throwable_attack_z` | `-5` | 客户端 | 投掷物 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_throwable_idle_pitch` | `0` | 客户端 | 投掷物 / 静止：俯仰角，度 |
| `mcitem_tp_throwable_idle_roll` | `0` | 客户端 | 投掷物 / 静止：翻滚角，度 |
| `mcitem_tp_throwable_idle_scale` | `0.6` | 客户端 | 投掷物 / 静止：缩放倍率 |
| `mcitem_tp_throwable_idle_x` | `1` | 客户端 | 投掷物 / 静止：前后位移，Source 单位 |
| `mcitem_tp_throwable_idle_y` | `5` | 客户端 | 投掷物 / 静止：左右位移，Source 单位 |
| `mcitem_tp_throwable_idle_yaw` | `-20` | 客户端 | 投掷物 / 静止：偏航角，度 |
| `mcitem_tp_throwable_idle_z` | `-5` | 客户端 | 投掷物 / 静止：上下位移，Source 单位 |
| `mcitem_tp_throwable_throw_pitch` | `0` | 客户端 | 投掷物 / 投掷：俯仰角，度 |
| `mcitem_tp_throwable_throw_roll` | `0` | 客户端 | 投掷物 / 投掷：翻滚角，度 |
| `mcitem_tp_throwable_throw_scale` | `0.6` | 客户端 | 投掷物 / 投掷：缩放倍率 |
| `mcitem_tp_throwable_throw_x` | `1` | 客户端 | 投掷物 / 投掷：前后位移，Source 单位 |
| `mcitem_tp_throwable_throw_y` | `5` | 客户端 | 投掷物 / 投掷：左右位移，Source 单位 |
| `mcitem_tp_throwable_throw_yaw` | `-20` | 客户端 | 投掷物 / 投掷：偏航角，度 |
| `mcitem_tp_throwable_throw_z` | `-5` | 客户端 | 投掷物 / 投掷：上下位移，Source 单位 |
| `mcitem_tp_totem_of_undying_attack_pitch` | `0` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：俯仰角，度 |
| `mcitem_tp_totem_of_undying_attack_roll` | `0` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：翻滚角，度 |
| `mcitem_tp_totem_of_undying_attack_scale` | `0.6` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：缩放倍率 |
| `mcitem_tp_totem_of_undying_attack_x` | `1` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：前后位移，Source 单位 |
| `mcitem_tp_totem_of_undying_attack_y` | `5` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：左右位移，Source 单位 |
| `mcitem_tp_totem_of_undying_attack_yaw` | `-20` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：偏航角，度 |
| `mcitem_tp_totem_of_undying_attack_z` | `-5` | 客户端 | 不死图腾 / 左键攻击 / 挖掘：上下位移，Source 单位 |
| `mcitem_tp_totem_of_undying_idle_pitch` | `0` | 客户端 | 不死图腾 / 静止：俯仰角，度 |
| `mcitem_tp_totem_of_undying_idle_roll` | `0` | 客户端 | 不死图腾 / 静止：翻滚角，度 |
| `mcitem_tp_totem_of_undying_idle_scale` | `0.6` | 客户端 | 不死图腾 / 静止：缩放倍率 |
| `mcitem_tp_totem_of_undying_idle_x` | `1` | 客户端 | 不死图腾 / 静止：前后位移，Source 单位 |
| `mcitem_tp_totem_of_undying_idle_y` | `5` | 客户端 | 不死图腾 / 静止：左右位移，Source 单位 |
| `mcitem_tp_totem_of_undying_idle_yaw` | `-20` | 客户端 | 不死图腾 / 静止：偏航角，度 |
| `mcitem_tp_totem_of_undying_idle_z` | `-5` | 客户端 | 不死图腾 / 静止：上下位移，Source 单位 |
| `mcitem_tp_trident_charge_pitch` | `90` | 客户端 | 三叉戟 / 蓄力：俯仰角，度 |
| `mcitem_tp_trident_charge_roll` | `0` | 客户端 | 三叉戟 / 蓄力：翻滚角，度 |
| `mcitem_tp_trident_charge_scale` | `1.3` | 客户端 | 三叉戟 / 蓄力：缩放倍率 |
| `mcitem_tp_trident_charge_x` | `20` | 客户端 | 三叉戟 / 蓄力：前后位移，Source 单位 |
| `mcitem_tp_trident_charge_y` | `7` | 客户端 | 三叉戟 / 蓄力：左右位移，Source 单位 |
| `mcitem_tp_trident_charge_yaw` | `-15` | 客户端 | 三叉戟 / 蓄力：偏航角，度 |
| `mcitem_tp_trident_charge_z` | `-7` | 客户端 | 三叉戟 / 蓄力：上下位移，Source 单位 |
| `mcitem_tp_trident_idle_pitch` | `0` | 客户端 | 三叉戟 / 静止：俯仰角，度 |
| `mcitem_tp_trident_idle_roll` | `-30` | 客户端 | 三叉戟 / 静止：翻滚角，度 |
| `mcitem_tp_trident_idle_scale` | `1.3` | 客户端 | 三叉戟 / 静止：缩放倍率 |
| `mcitem_tp_trident_idle_x` | `0` | 客户端 | 三叉戟 / 静止：前后位移，Source 单位 |
| `mcitem_tp_trident_idle_y` | `15` | 客户端 | 三叉戟 / 静止：左右位移，Source 单位 |
| `mcitem_tp_trident_idle_yaw` | `0` | 客户端 | 三叉戟 / 静止：偏航角，度 |
| `mcitem_tp_trident_idle_z` | `-20` | 客户端 | 三叉戟 / 静止：上下位移，Source 单位 |
| `mcitem_tp_trident_melee_pitch` | `0` | 客户端 | 三叉戟 / 近战：俯仰角，度 |
| `mcitem_tp_trident_melee_roll` | `-30` | 客户端 | 三叉戟 / 近战：翻滚角，度 |
| `mcitem_tp_trident_melee_scale` | `1.3` | 客户端 | 三叉戟 / 近战：缩放倍率 |
| `mcitem_tp_trident_melee_x` | `0` | 客户端 | 三叉戟 / 近战：前后位移，Source 单位 |
| `mcitem_tp_trident_melee_y` | `15` | 客户端 | 三叉戟 / 近战：左右位移，Source 单位 |
| `mcitem_tp_trident_melee_yaw` | `0` | 客户端 | 三叉戟 / 近战：偏航角，度 |
| `mcitem_tp_trident_melee_z` | `-20` | 客户端 | 三叉戟 / 近战：上下位移，Source 单位 |
| `mcitem_tp_trident_throw_pitch` | `0` | 客户端 | 三叉戟 / 投掷：俯仰角，度 |
| `mcitem_tp_trident_throw_roll` | `0` | 客户端 | 三叉戟 / 投掷：翻滚角，度 |
| `mcitem_tp_trident_throw_scale` | `1` | 客户端 | 三叉戟 / 投掷：缩放倍率 |
| `mcitem_tp_trident_throw_x` | `0` | 客户端 | 三叉戟 / 投掷：前后位移，Source 单位 |
| `mcitem_tp_trident_throw_y` | `0` | 客户端 | 三叉戟 / 投掷：左右位移，Source 单位 |
| `mcitem_tp_trident_throw_yaw` | `0` | 客户端 | 三叉戟 / 投掷：偏航角，度 |
| `mcitem_tp_trident_throw_z` | `0` | 客户端 | 三叉戟 / 投掷：上下位移，Source 单位 |

源码：[sh_holdtypes.lua](../../../addons/mc_item/lua/mcitem/sh_holdtypes.lua)。

<a id="convars-20"></a>

## MC Item：弹丸模型朝向

按首次计算箭 / 三叉戟模型朝向时创建；带服务器复制标记。旋转叠加在飞行方向上，不是第一人称手持姿态。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mcitem_arrow_model_pitch` | `0` | 服务器 | 箭弹丸模型相对飞行方向的俯仰角，度；按需创建 |
| `mcitem_arrow_model_roll` | `0` | 服务器 | 箭弹丸模型相对飞行方向的翻滚角，度；按需创建 |
| `mcitem_arrow_model_yaw` | `0` | 服务器 | 箭弹丸模型相对飞行方向的偏航角，度；按需创建 |
| `mcitem_trident_model_pitch` | `0` | 服务器 | 三叉戟弹丸模型相对飞行方向的俯仰角，度；按需创建 |
| `mcitem_trident_model_roll` | `90` | 服务器 | 三叉戟弹丸模型相对飞行方向的翻滚角，度；按需创建 |
| `mcitem_trident_model_yaw` | `90` | 服务器 | 三叉戟弹丸模型相对飞行方向的偏航角，度；按需创建 |

源码：[shared.lua](../../../addons/mc_item/lua/entities/mcitem_arrow/shared.lua)。

<a id="convars-21"></a>

## 调试与性能诊断

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_binary_net_profile` | `0` | 服务器 | 收集服务器二进制编码、压缩、排队与 net.Send 耗时 |
| `mc_client_collision_aabb_debug` | `0` | 客户端 | 客户端绘制预测碰撞 AABB |
| `mc_client_collision_aabb_debug_limit` | `2048` | 客户端 | 客户端最多绘制的预测碰撞 AABB 数 |
| `mc_client_collision_area_debug` | `0` | 客户端 | 客户端绘制预测碰撞兴趣区域 |
| `mc_client_collision_debug` | `0` | 客户端 | 打印客户端预测碰撞重建信息 |
| `mc_debug_block_interact` | `0` | 服务器 | 在服务器控制台打印右键方块交互触发 / 未触发原因 |
| `mc_debug_gallery_aim_distance` | `4096` | 客户端 | 调试画廊检查器的最大追踪距离，Source 单位 |
| `mc_debug_gallery_hud` | `1` | 客户端 | 瞄准调试画廊条目时显示方块 / 状态身份 |
| `mc_light_perf_debug` | `0` | 客户端 | 显示并收集详细光照性能信息 |
| `mc_light_perf_print_break` | `0` | 客户端 | 破坏方块后打印光照性能信息 |
| `mc_light_perf_print_each` | `0` | 客户端 | 每次光照计算打印一行耗时 |
| `mc_mesh_debug_full_cube_only` | `0` | 客户端 | 调试：只发射完整立方体方块的网格 |
| `mc_mesh_emit_probe` | `0` | 客户端 | 打印完整网格几何重建的详细耗时 |
| `mc_pbr_bloom_debug` | `0` | 客户端 | 调试：显示提取并模糊的高光 |
| `mc_pbr_ssao_debug` | `0` | 客户端 | 调试：显示 SSAO 可见性缓冲 |
| `mc_pbr_volumetric_debug` | `0` | 客户端 | 调试：只显示太阳散射 |
| `mc_pbr_water_ssr_debug` | `0` | 客户端 | 调试：显示水面 SSR 中间渲染目标 |
| `mc_server_collision_debug` | `0` | 客户端 | 客户端绘制服务器权威碰撞兴趣边界 |
| `mc_stream_profile_debug` | `0` | 客户端 | 打印流送补丁与卸载的帧耗时 |
| `mc_strict` | `0` | 两端独立 | 本作用域错误处理：0 记录后继续，1 在故障点抛出 Lua 错误 |
| `mcitem_debug` | `0` | 客户端 | 显示实际 MC 刻率 / 挥动计时及参考值；不归档保存 |
| `mcitem_entity_interact_debug` | `0` | 服务器 | 服务器打印 MC Item 右键实体交互的分发结果 |

源码：[cl_debug.lua](../../../addons/mc_engine/lua/mc/cl_debug.lua)、[cl_lighting.lua](../../../addons/mc_engine/lua/mc/cl_lighting.lua)、[cl_net.lua](../../../addons/mc_engine/lua/mc/cl_net.lua)、[cl_collision.lua](../../../addons/mc_engine/lua/mc/render/cl_collision.lua)、[cl_mesh_config.lua](../../../addons/mc_engine/lua/mc/render/cl_mesh_config.lua)、[cl_render_pbr_post.lua](../../../addons/mc_engine/lua/mc/render/cl_render_pbr_post.lua)、[cl_render_pbr_ssr.lua](../../../addons/mc_engine/lua/mc/render/cl_render_pbr_ssr.lua)、[sh_config.lua](../../../addons/mc_engine/lua/mc/sh_config.lua)、[sh_fault.lua](../../../addons/mc_engine/lua/mc/sh_fault.lua)、[sv_world.lua](../../../addons/mc_engine/lua/mc/sv_world.lua)、[sh_block_interact.lua](../../../addons/mc_item/lua/mcitem/sh_block_interact.lua)、[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-22"></a>

## 内部迁移标记

供版本迁移使用，不是用户调节项。表中仍列注册默认值；完成迁移后的值写在用途列。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_client_collision_default_version` | `0` | 客户端 | 内部碰撞默认值迁移标记；注册为 0，迁移后为 2 |
| `mcitem_holdtype_item_idle_migration` | `0` | 服务器 | 内部普通物品静止 HoldType 迁移标记；注册为 0，迁移后为 1 |
| `mcitem_holdtype_ranged_attack_migration` | `0` | 服务器 | 内部弓 / 弩左键攻击 HoldType 迁移标记；注册为 0，迁移后为 1 |
| `mcitem_name_tag_scale_revision` | `0` | 客户端 | 内部命名牌大小迁移标记；注册为 0，迁移后为 1 |
| `mcitem_tp_tuned_defaults_migration` | `0` | 客户端 | 内部第三人称姿态默认值迁移标记；注册为 0，迁移后为 2 |
| `mcitem_trident_pose_revision` | `0` | 客户端 | 内部三叉戟使用姿态迁移标记；注册为 0，迁移后为 2 |

源码：[cl_collision.lua](../../../addons/mc_engine/lua/mc/render/cl_collision.lua)、[cl_render.lua](../../../addons/mc_item/lua/mcitem/name_tags/cl_render.lua)、[sh_holdtypes.lua](../../../addons/mc_item/lua/mcitem/sh_holdtypes.lua)、[cl_view.lua](../../../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua)。

<a id="convars-23"></a>

## 旧 Native 入口保留项

仅在保留的 cl_native_mesh_backend.lua 中注册；当前主加载器没有加载该旧 L1 后端。默认安装不保证能在控制台找到这些名称。当前 L2 的 mc_native_mesh 默认是 0，已在「网格构建与绘制」中列出；旧文件同名声明的默认 1 不作为当前默认值。

| 变量 | 默认 | 修改位置 | 用途 |
|---|---|---|---|
| `mc_native_directional_draw` | `1` | 客户端 | 旧 L1 后端按相机朝向绘制不透明面方向范围 |
| `mc_native_greedy` | `0` | 客户端 | 旧 L1 后端对不透明完整方块做简单贪心合并 |
| `mc_native_lod` | `0` | 客户端 | 旧 L1 后端远距离 2×2×2 不透明方块 LOD |
| `mc_native_lod_start` | `24` | 客户端 | 旧 L1 后端 LOD 起始距离，区块 |
| `mc_native_occlusion_cull` | `1` | 客户端 | 旧 L1 后端的区段门户保守遮挡剔除 |
| `mc_native_think_ms` | `3` | 客户端 | 旧 L1 后端每帧收尾预算，毫秒 |

源码：[cl_native_mesh_backend.lua](../../../addons/mc_engine/lua/mc/render/cl_native_mesh_backend.lua)。

## 动态名称的扩展边界

以上动态表按仓库内置物品、状态与弹丸类型展开。第三方代码若新增 MCAnchorName、ThirdPerson.Profiles 或 MCAngleConVarName，还能按相同规则注册额外变量；未加载第三方代码的名称不属于本版本内置列表。

第一人称使用 `<物品名>` 生成 `mcitem_fp_*`、`mcitem_use_*`、`mcitem_charged_*`、`mcitem_swing_*`；第三人称使用 `mcitem_tp_<物品名>_<状态>_<字段>`；弹丸使用 `mcitem_<类型>_model_<角度轴>`。各字段、内置名称和默认值已在对应表逐项列全。
