# MC ConVar 说明

这个文件汇总本 addon 当前创建的 `mc_*` ConVar。默认值来自源码里的 `CreateConVar` / `CreateClientConVar`；带 `约` 的默认值是 Lua 常量计算后的数值。

## 先看这几个

| 需求 | 主要 ConVar | 说明 |
| --- | --- | --- |
| 开启 GPU 光照路径 | `mc_mesh_gpu_shader 1`, `mc_mesh_gpu_light_texture 1`, `mc_mesh_gpu_lightmap 1` | 使用自定义 chunk shader、GPU chunk light texture 和全局 16x16 lightmap。 |
| 让夜晚更暗蓝 | `mc_daycycle 1`, `mc_daycycle_moon_light`, `mc_daycycle_night_tint`, `mc_mesh_gpu_lightmap_ambient` | `moon_light` 控夜晚天光等级，`night_tint` 控蓝色夜色，`ambient` 控 GPU lightmap 最低亮度。 |
| 让阴影处更黑 | `mc_mesh_shadow_map 1`, `mc_mesh_shadow_map_strength`, `mc_mesh_shadow_map_face_shade`, `mc_mesh_gpu_lightmap_ambient` | 阴影暗度走 shadow map 和 fancy shader；不要靠 `mc_mesh_gpu_sky_light` 做。 |
| 避免光柱 | `mc_mesh_gpu_sky_light 0` | 当前源码硬关闭 column sky exposure；昼夜天光是统一的，遮挡应交给 shadow map。 |
| 区分两个最低亮度 | `mc_light_ambient_min`, `mc_mesh_gpu_lightmap_ambient` | 前者是 CPU/vertex-color 路径最低亮度；后者是 GPU global lightmap 最低亮度。 |

## 服务器：权限、世界和批量操作

这些大多是服务器端、归档、通知并复制到客户端的配置。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_admin_only` | `0` | 只允许管理员放置、破坏方块；也影响部分预设操作权限。 |
| `mc_world_limit` | `1024` | 限制每个方块坐标轴距离原点的最大绝对值。 |
| `mc_max_blocks` | `0` | 全局方块数量上限；`0` 表示不限。 |
| `mc_reach` | 约 `182.5` | 玩家放置/破坏 MC 方块的最大距离；`0` 表示关闭距离限制。 |
| `mc_fill_max` | `100000` | 单次 `/fill` 最多修改的方块数；`0` 表示不限。 |
| `mc_fill_batch_cells` | `4096` | `/fill` 每个服务器批次最多应用多少格。 |
| `mc_fill_batch_chunks` | `16` | `/fill` 每个服务器批次最多触碰多少 chunk。 |
| `mc_fill_batch_interval` | `0.05` | `/fill` 批次之间的间隔秒数，用来分摊卡顿。 |
| `mc_import_max` | `0` | 单次 `mc_import` 最多导入多少方块；`0` 表示不限。 |
| `mc_autosave` | `0` | 自动保存间隔秒数；`0` 表示关闭。 |
| `mc_save_public` | `0` | 是否允许非管理员列出、读取、保存 MC 存档；删除仍然只限管理员。 |
| `mc_preset_max_blocks` | `100000` | 单个建筑预设最多保存/放置的非空气方块数；`0` 表示不限。 |

## 服务器：同步、存储和大世界

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_sync_cells_per_part` | `2048` | 流式同步时每个 net part 包含的方块格数。 |
| `mc_sync_messages_per_tick` | `4` | 每个 0.05 秒 tick 发送多少条流式同步消息。 |
| `mc_sync_reliable_budget` | `32768` | 每个 0.05 秒 tick 允许的可靠同步字节预算。 |
| `mc_sync_fast` | `1` | 使用带 ack 窗口的快速全图同步。 |
| `mc_sync_frame_ms` | `4` | 每 tick 大约花多少毫秒服务器 CPU 时间做完整同步。 |
| `mc_sync_inflight_limit` | `65536` | 单个同步客户端允许未 ack 的最大同步字节数。 |
| `mc_sync_snapshot` | `1` | 用压缩存档快照同步客户端，再发送增量编辑。 |
| `mc_sync_snapshot_part_bytes` | `32768` | 快照同步每个 net part 的字节数。 |
| `mc_sync_snapshot_max_chunks` | `0` | 旧设置；当前完整快照突发同步基本忽略这个限制。 |
| `mc_chunk_http_enabled` | `0` | 允许客户端通过 HTTP 拉取 lazy-save 基础 chunk，而不是走 GMod net。 |
| `mc_chunk_http_base_url` | 空 | HTTP 根地址，指向服务端 `garrysmod/data` 下的 lazy save manifest/part。 |
| `mc_stream_chunk_span_xy` | `0` | 旧的客户端 chunk 范围同步水平半径；直接全量同步会忽略。 |
| `mc_stream_chunk_span_z` | `0` | 旧的客户端 chunk 范围同步垂直半径；直接全量同步会忽略。 |
| `mc_large_world_lazy_load` | `0` | 旧的 v8 lazy chunk loading 开关；默认是服务端直接加载。 |
| `mc_large_world_chunk_threshold` | `2048` | 导入存档达到多少 chunk 后按大世界/lazy streaming 语义处理。 |
| `mc_chunk_store_part_cache` | `8` | 内存里最多缓存多少个 v8 lazy-save part 文件。 |
| `mc_chunk_store_loads_per_tick` | `8` | store tick 每次最多 hydrate 多少个 lazy chunk。 |
| `mc_chunk_store_frame_ms` | `3` | lazy chunk hydrate 每 tick 的大约毫秒预算。 |

## 服务器和客户端碰撞

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_server_collision_chunk_span` | `0` | 服务器碰撞 AABB 周围额外保活的 chunk 半径。 |
| `mc_server_collision_aabb_padding` | 约 `36.5` | 玩家/实体 AABB 外扩多少 Source 单位，用于保持 MC chunk 碰撞激活。 |
| `mc_collision_aim_distance` | 约 `18688` | 以准星方块为中心维护碰撞兴趣的 trace 距离，和建造距离无关。 |
| `mc_server_collision_aim_radius` | `1` | 每个玩家准星命中的 MC 方块周围多少格保活服务器碰撞。 |
| `mc_client_collision_aim_radius` | `1` | 客户端预测碰撞使用的准星方块半径。 |
| `mc_server_collision_hot_span` | `2` | 按实体速度预判时额外保活的服务器碰撞 chunk 半径。 |
| `mc_server_collision_lookahead_time` | `0.5` | 服务器碰撞兴趣按实体速度向前看的秒数。 |
| `mc_server_collision_lookahead_max` | `4` | 速度预判最多扩到多少 chunk 半径。 |
| `mc_client_collision` | `1` | 是否构建客户端预测用方块碰撞；`0` 表示只用服务器碰撞。 |
| `mc_client_collision_chunk_span` | `1` | 本地玩家周围客户端预测碰撞 AABB 的 chunk 半径；`0` 关闭。 |
| `mc_client_collision_debug` | `0` | 打印客户端预测碰撞重建诊断。 |
| `mc_client_collision_cross_chunk` | `0` | 允许客户端预测碰撞兴趣溢出到相邻 chunk。 |
| `mc_client_collision_default_version` | `0` | 内部迁移标记，用于客户端碰撞默认值升级。 |

## 爆炸、伤害和批量重建

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_explosion_mesh_sections_per_frame` | `4` | 爆炸修改方块后，客户端每个间隔重建多少 render section。 |
| `mc_explosion_mesh_interval` | `0.12` | 爆炸后客户端 mesh 重建批次之间的秒数。 |
| `mc_bulk_collision_chunks_per_interval` | `1` | 爆炸/预设编辑后，服务器每个间隔重建多少碰撞 chunk。 |
| `mc_bulk_collision_interval` | `0.12` | 服务器批量碰撞重建间隔秒数。 |
| `mc_block_damage` | `1` | 是否允许 GMod 伤害破坏 MC 方块。 |
| `mc_block_health_scale` | `20` | Minecraft hardness 转成方块血量时的倍率。 |
| `mc_block_damage_decay` | `5` | 部分方块伤害多少秒后遗忘。 |
| `mc_block_explosion_scale` | `0.04` | GMod 爆炸伤害转 Minecraft 风格爆炸半径的倍率。 |
| `mc_block_explosion_max_radius` | `8` | Minecraft 风格方块爆炸最大半径。 |
| `mc_block_explosion_max_blocks` | `4096` | 单次 GMod 爆炸最多破坏多少 MC 方块；`0` 表示不限。 |

## 客户端基础光照

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_light_enabled` | `1` | 是否把 Minecraft 风格顶点光照应用到 MC chunk mesh。 |
| `mc_light_ambient_min` | `0` | CPU/vertex-color 路径的最低亮度，不控制 GPU global lightmap。 |
| `mc_light_style` | `shader` | MC chunk 光照风格：`fast`、`vanilla`、`best`、`shader`、`lightmap`。 |
| `mc_light_perf_debug` | `0` | 显示并收集详细光照性能诊断。 |
| `mc_light_perf_print_break` | `0` | 破坏方块后打印光照性能诊断。 |
| `mc_light_perf_print_each` | `0` | 每次光照计算打印一行 timing 诊断。 |

## 客户端渲染和 mesh

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_render` | `1` | 是否绘制 MC chunk IMesh；关闭只隐藏 mesh，不影响碰撞。 |
| `mc_mesh_cull_mode` | `ccw` | MC chunk mesh 的剔除方向：`ccw` 或 `cw`。 |
| `mc_mesh_emit_probe` | `0` | 打印详细 mesh emit timings，用于诊断完整几何重建。 |
| `mc_mesh_begin_upload` | `1` | 用 `mesh.Begin` 上传 IMesh 顶点，而不是 `IMesh:BuildFromTriangles`。 |
| `mc_mesh_debug_full_cube_only` | `0` | 调试 mesh emission 时只渲染完整立方体方块。 |
| `mc_mesh_geometry_cache_sections` | `384` | 保留 Lua 顶点/光照数据的 render section 数量；调低省内存。 |
| `mc_mesh_block_emit_cache_sections` | `1536` | 保留按方块 emit 顶点/光照缓存的 section 数；调低省内存但增加重建工作。 |
| `mc_mesh_connection_visible_template` | `1` | 对 fence/pane/wall/pipe 等连接形状使用可见几何模板缓存。 |

## GPU shader、GPU light texture 和 global lightmap

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_gpu_shader` | `0` | 使用自定义 GPU chunk shader；需要已编译 VCS 文件。 |
| `mc_mesh_gpu_light_texture` | `0` | GPU shader 从 chunk light texture 采样光照，而不是把光照烘进顶点色。 |
| `mc_mesh_gpu_shader_fancy` | `0` | 使用 fancy GPU shader 变体：冷阴影、暖太阳、背光面 shading、边缘 fade。 |
| `mc_mesh_gpu_light_brightness` | `1` | GPU light texture 的 block/sky light 亮度倍率。 |
| `mc_mesh_gpu_light_gamma` | `1` | GPU light texture 的衰减曲线；`>1` 提亮中间亮度，`<1` 压暗。 |
| `mc_mesh_gpu_sky_light` | `0` | 旧的柱状 sky exposure 开关名；当前源码硬关闭，昼夜走统一天光，避免光柱。 |
| `mc_mesh_gpu_sun_brightness` | `1` | GPU 路径 sun/sky light 亮度倍率。 |
| `mc_mesh_gpu_light_refresh_per_frame` | `2` | 昼夜 sky level 跳变时，每帧刷新多少个 chunk light texture。 |
| `mc_mesh_gpu_lightmap` | `1` | 启用程序生成的 16x16 global lightmap；提供暖火把和彩色昼夜天光。 |
| `mc_mesh_gpu_lightmap_torch_warmth` | `0.7` | global lightmap 里 block light/火把的暖色程度。 |
| `mc_mesh_gpu_lightmap_ambient` | `0.04` | GPU global lightmap 的最低可见亮度；设 `0` 可接近全黑。 |
| `mc_mesh_gpu_lightmap_sunset` | `0.5` | sunrise/sunset 天光轴橙色渐变强度；`0` 关闭。 |

## 昼夜循环

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_daycycle` | `0` | 服务器端 MC 昼夜循环开关。 |
| `mc_daycycle_length` | `1200` | 一个完整 MC 日的现实秒数；`1200` 等于原版 20 分钟。 |
| `mc_daycycle_sun_tilt` | `0.2` | shadow map 使用的太阳轨迹侧向倾斜，避免纯轴向阴影。 |
| `mc_daycycle_moon_shadow` | `0.3` | 夜晚月光阴影强度相对太阳阴影的倍率。 |
| `mc_daycycle_moon_light` | `2` | 深夜 moonlight sky level，范围 `0..15`；越低夜晚越暗。 |
| `mc_daycycle_night_tint` | `0.85` | 夜晚天光向蓝色月光偏移的强度；`0` 表示中性不染蓝。 |

## GPU shadow map

阴影处的黑暗主要靠这一组。建议组合：`mc_mesh_gpu_shader 1`、`mc_mesh_gpu_light_texture 1`、`mc_mesh_gpu_shader_fancy 1`、`mc_mesh_shadow_map 1`，再调 `mc_mesh_shadow_map_strength` 和 `mc_mesh_gpu_lightmap_ambient`。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_shadow_map` | `0` | 让 GPU light texture chunk shader 接收 MC shadow map。 |
| `mc_mesh_shadow_map_strength` | `0.75` | shadow map 对最终亮度的压暗强度。 |
| `mc_mesh_shadow_map_bias` | `0.0005` | shadow map 深度/边缘采样 bias，用于减轻 acne 和漏光。 |
| `mc_mesh_shadow_map_softness` | `1` | 阴影边缘柔化半径，单位是 shadow-map texel，最低钳到 1。 |
| `mc_mesh_shadow_map_size` | `2048` | MC-owned shadow map 分辨率。 |
| `mc_mesh_shadow_map_distance` | `4096` | MC-owned shadow map 的世界覆盖半径。 |
| `mc_mesh_shadow_map_caster_distance` | `4608` | 距相机多远以内的 MC chunk 会绘入 shadow map。 |
| `mc_mesh_shadow_map_update_interval` | `0` | shadow map 最小重绘间隔秒数；`0` 表示启用时每帧重绘。 |
| `mc_mesh_shadow_map_tint` | `0.6` | fancy shader 中阴影向冷色天空 tint 偏移的强度。 |
| `mc_mesh_shadow_map_edge_fade` | `0.1` | fancy shader 中阴影覆盖边缘的 fade 宽度。 |
| `mc_mesh_shadow_map_face_shade` | `0.65` | fancy shader 中背离太阳的面按阴影压暗的强度。 |
| `mc_mesh_shadow_map_warmth` | `0.35` | fancy shader 中日照面和火把区域的暖色强度。 |

## 高度场光影模式（height shadow mode）

与 shadow map 二选一的另一套太阳阴影：`mc_mesh_shadow_mode height` 切换（`map` 切回，需要 `mc_mesh_shadow_map 1`）。
维护一张俯视高度图，只在方块变化或玩家走远时重画；chunk shader 沿太阳方向对它 raymarch，
得到近硬远软的距离衰减软阴影。太阳/相机移动零重绘成本，昼夜循环下远比 `map` 模式便宜。
强度与调色复用 `mc_mesh_shadow_map_strength` 和 fancy 的 tint/face_shade/warmth/edge_fade；
`bias/softness/size/distance/caster_distance/update_interval` 等 shadow map 专属项在此模式下无效。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_shadow_mode` | `map` | 太阳阴影技术：`map` = 每帧太阳视角 shadow map（PCF），`height` = 缓存俯视高度场 raymarch。 |
| `mc_mesh_hf_shadow_size` | `1024` | 高度图分辨率。 |
| `mc_mesh_hf_shadow_range` | `4096` | 高度图覆盖的世界半径（以玩家为中心）。 |
| `mc_mesh_hf_shadow_max_dist` | `2400` | 阴影投射的最大世界距离（raymarch 射程）。 |
| `mc_mesh_hf_shadow_softness` | `0.05` | 半影正切：阴影随遮挡距离变软的速度（0.02 锐利，0.12 很软）。 |
| `mc_mesh_hf_shadow_update_interval` | `0.1` | 几何变化/窗口重定位后高度图的最小重绘间隔秒数。 |

## Source engine 光照桥

这一组把 Source 静态光照采样混入 MC mesh 顶点色，属于可选桥接，不是 GPU global lightmap。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_source_lighting` | `0` | 将 Source engine 静态光照混入 MC mesh 顶点色：`0` 关，`1` ambient，`2` normal，`3` max。 |
| `mc_mesh_source_lighting_strength` | `0.55` | Source 光照调制 MC 顶点色的强度。 |
| `mc_mesh_source_lighting_min` | `0.35` | Source 光照调制时的最低倍率。 |
| `mc_mesh_source_lighting_scale` | `1.0` | Source 光照采样值在混入前的倍率。 |

## Experimental UV1 hardware lightmap

这条路当前不是生产主线。源码里明确写了 UV1 `LightmappedGeneric` 路径还没准备好，`lightmap` style 会 fallback 到 vanilla。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_lightmap_experimental` | `0` | 打开隔离的实验 UV1 lightmap 后端入口；当前仍未接回主线。 |
| `mc_mesh_lightmap_uv` | `0` | 实验 UV1 hardware lightmap 开关；当前与主 mesh backend 隔离。 |
| `mc_mesh_lightmap_source` | `generated` | 实验 hardware lightmap 贴图来源：`generated` 或 `image`。 |
| `mc_mesh_lightmap_image` | `mc/lightmap.png` | 当 source 为 `image` 时使用的材质路径。 |
| `mc_mesh_lightmap_allow_external` | `0` | 允许外部 image 覆盖游戏内生成的 MC lightmap。 |
| `mc_mesh_lightmap_exposure` | `1` | 生成的 MC hardware lightmap 亮度倍率。 |
| `mc_mesh_lightmap_base_scale` | `0.6` | 用户 hardware lightmap 的基础亮度补偿，会乘以 exposure。 |
| `mc_mesh_lightmap_ambient_scale` | `1` | Minecraft `AmbientColor` uniform 的倍率。 |
| `mc_mesh_lightmap_sky_factor` | `1` | Minecraft lightmap `SkyFactor` uniform。 |
| `mc_mesh_lightmap_brightness_factor` | `0` | Minecraft lightmap `BrightnessFactor` / gamma uniform。 |
| `mc_mesh_lightmap_block_flicker` | `0` | 对生成的 UV1 lightmap 应用 Minecraft 风格 block light flicker。 |
| `mc_mesh_lightmap_night_vision_factor` | `0` | Minecraft lightmap `NightVisionFactor` uniform。 |
| `mc_mesh_lightmap_darkness_scale` | `0` | Minecraft lightmap `DarknessScale` uniform。 |
| `mc_mesh_lightmap_boss_darkening` | `0` | Minecraft lightmap `BossOverlayWorldDarkeningFactor` uniform。 |
| `mc_mesh_lightmap_block_tint` | `255 255 255` | UV1 lightmap 的 `BlockLightTint` RGB。 |
| `mc_mesh_lightmap_sky_color` | `255 255 255` | UV1 lightmap 的 `SkyLightColor` RGB。 |
| `mc_mesh_lightmap_ambient_color` | `0 0 0` | UV1 lightmap 的 `AmbientColor` RGB。 |
| `mc_mesh_lightmap_night_vision_color` | `153 153 153` | UV1 lightmap 的 `NightVisionColor` RGB。 |

## 调试

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_server_collision_debug` | `0` | 绘制服务器权威 MC 碰撞兴趣 bounds。 |
| `mc_client_collision_area_debug` | `0` | 绘制客户端预测碰撞兴趣区域。 |
| `mc_client_collision_aabb_debug` | `0` | 绘制客户端预测碰撞 AABB boxes。 |
| `mc_client_collision_aabb_debug_limit` | `2048` | 最多绘制多少个客户端预测碰撞 AABB box。 |

## 创造模式手持方块显示

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_creative_held_model` | `1` | 是否绘制创造模式手持方块模型。 |
| `mc_creative_held_anim` | `1` | 是否播放创造模式手持方块挥动动画。 |
| `mc_creative_held_fp_forward` | `11.5` | 第一人称手持方块前后偏移。 |
| `mc_creative_held_fp_right` | `12` | 第一人称手持方块左右偏移。 |
| `mc_creative_held_fp_up` | `-8.3` | 第一人称手持方块上下偏移。 |
| `mc_creative_held_fp_scale` | `6.4` | 第一人称手持方块缩放。 |
| `mc_creative_held_fp_yaw` | `45` | 第一人称手持方块 yaw。 |
| `mc_creative_held_fp_pitch` | `0` | 第一人称手持方块 pitch。 |
| `mc_creative_held_fp_roll` | `0` | 第一人称手持方块 roll。 |
| `mc_creative_held_tp_forward` | `2.5` | 第三人称手持方块前后偏移。 |
| `mc_creative_held_tp_right` | `2.2` | 第三人称手持方块左右偏移。 |
| `mc_creative_held_tp_up` | `-1.8` | 第三人称手持方块上下偏移。 |
| `mc_creative_held_tp_scale` | `6` | 第三人称手持方块缩放。 |
| `mc_creative_held_tp_yaw` | `45` | 第三人称手持方块 yaw。 |
| `mc_creative_held_tp_pitch` | `75` | 第三人称手持方块 pitch。 |
| `mc_creative_held_tp_roll` | `0` | 第三人称手持方块 roll。 |

## UI

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_language` | `auto` | MC UI 语言：`auto`、`zh_cn` 或 `en_us`；`auto` 跟随 `gmod_language`。 |

## Fast 低采样 GPU 光照（旧版观感）

`mc_mesh_gpu_light_fast 1` 切换回最初的低采样 GPU 光照着色器观感：每像素 4 次光照采样 + 1 次图集采样，
解析式暖/冷调色 + 面向着色，**无阴影采样、无 lightmap 查表**。优先级高于 fancy/height 材质选择。
昼夜亮度/夜色/暖色由每帧一次的常量传入（复用 daycycle 与 lightmap 的 cvar），无每 chunk 成本。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_gpu_light_fast` | `0` | 低采样快速 GPU 光照着色器（旧版观感），开启后覆盖 fancy/height 选择。 |
| `mc_mesh_gpu_light_flush_per_frame` | `8` | PreRender 中每帧最多重烘的 chunk 光照纹理数（绘制路径不再重烘；0 = 不限）。 |
