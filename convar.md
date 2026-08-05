# MC ConVar 说明

这个文件汇总本 addon 当前创建的 `mc_*` ConVar。默认值来自源码里的 `CreateConVar` / `CreateClientConVar`；带 `约` 的默认值是 Lua 常量计算后的数值。

## 先看这几个

| 需求 | 主要 ConVar | 说明 |
| --- | --- | --- |
| 开启 GPU 光照路径 | `mc_light_shader 1`, `mc_light_texture 1`, `mc_lightmap 1` | 使用自定义 chunk shader、GPU chunk light texture 和全局 16x16 lightmap。 |
| 切换 GPU 光照观感 | `mc_light_style fancy/plain/fast/vanilla` | `fancy` 是默认阴影+冷暖调色；`plain` 是平滑无调色；`fast` 是低采样旧观感；`vanilla` 是原版 Minecraft lightmap 合成。 |
| 让夜晚更暗蓝 | `mc_daycycle 1`, `mc_daycycle_moon_light`, `mc_daycycle_night_tint`, `mc_lightmap_ambient` | `moon_light` 控夜晚天光等级，`night_tint` 控蓝色夜色，`ambient` 控 GPU lightmap 最低亮度。 |
| 让阴影处更黑 | `mc_shadow 1`, `mc_shadow_strength`, `mc_shadow_face_shade`, `mc_lightmap_ambient` | 阴影暗度走 shadow map 和 fancy shader。 |
| 封闭空间变暗 | `mc_light_sky_flood 1`, `mc_lightmap_ambient`, `mc_lightmap_sky_min` | 体素天空光泛洪(露天 15,横向每格 -1,全封闭 0)。着色器里直射阳光按体素天空光门控:全封闭格子收不到直射阳光,不再需要把 `mc_shadow_strength` 拉满;室内亮度由 `ambient`(绝对底光)和 `sky_min`(天空环境光底比例)直接控制。 |
| 区分两个最低亮度 | `mc_light_ambient_min`, `mc_lightmap_ambient` | 前者是 CPU/vertex-color 路径最低亮度；后者是 GPU global lightmap 最低亮度。 |

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
| `mc_preset_public` | `0` | 是否允许非管理员列出、读取、保存和放置建筑预设。 |
| `mc_preset_max_blocks` | `100000` | 单个建筑预设最多保存/放置的非空气方块数；`0` 表示不限。 |

## 服务器：同步、存储和大世界

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_binary_chunk_patch` | `0` | 实验性区块传输协议。启用后，以 palette + packed 32-bit words 的 Binary Section 发送区块，不再为地形生成 JSON 或 `"localIndex:paletteId"` 文本；不支持该能力的客户端自动走旧协议。 |
| `mc_binary_net_profile` | `0` | 收集 Binary Section 服务端编码、LZMA、CRC、切包入队、`net.Send` CPU 与发送队列墙钟时间。使用 `mc_binary_net_report` 查看。 |
| `mc_sync_messages_per_tick` | `4` | 每 0.05 秒最多向每个玩家发送多少条排队状态消息。 |
| `mc_sync_reliable_budget` | `3400` | 每 0.05 秒、每个玩家的排队状态字节硬上限；约 68 KB/s，204 KB 在无拥塞时约 3 秒。 |
| `mc_sync_frame_ms` | `4` | 每 tick 大约花多少毫秒服务器 CPU 时间做完整同步。 |
| `mc_sync_inflight_limit` | `32768` | 单个客户端允许等待处理确认的最大排队状态字节数。 |
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
| `mc_server_collision` | `0` | 是否建立服务器权威 MC 碰撞。关闭会立即清除现有 `mc_chunk` / `mc_chunk_phys` 碰撞实体和待重建队列；客户端预测碰撞不受影响。当前默认关闭用于定位卡顿。 |
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
| `mc_block_explosion_fx_limit` | `16` | 单次爆炸最多广播多少个方块破坏粒子/音效；`0` 表示不广播。 |

## 客户端基础光照

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_light_enabled` | `1` | 是否把 Minecraft 风格顶点光照应用到 MC chunk mesh。 |
| `mc_light_ambient_min` | `0` | CPU/vertex-color 路径的最低亮度，不控制 GPU global lightmap。 |
| `mc_light_profile` | `shader` | mesh 光照管线 profile：`fast`、`vanilla`、`best` 是 CPU/vertex-color 路径；`shader` 是 GPU chunk shader 路径（默认）。 |
| `mc_light_style` | `fancy` | GPU 像素光照观感：`fancy`、`plain`、`fast`、`vanilla`。旧归档值 `shader` / `best` / 数字会归一为 `fancy`。 |
| `mc_light_perf_debug` | `0` | 显示并收集详细光照性能诊断。 |
| `mc_light_perf_print_break` | `0` | 破坏方块后打印光照性能诊断。 |
| `mc_light_perf_print_each` | `0` | 每次光照计算打印一行 timing 诊断。 |
| `mc_light_sky_flood` | `1` | 体素天空光泛洪填充：露天 15，横向每格 -1 进入室内，全封闭 0（`0` = 天空光均匀全亮）。 |
| `mc_light_sky_flood_per_frame` | `4` | 每帧从摊销队列里重算多少个 chunk 的天空光泛洪。 |

## 客户端渲染和 mesh

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_render` | `1` | 是否绘制 MC chunk IMesh；关闭只隐藏 mesh，不影响碰撞。 |
| `mc_mesh_cull_mode` | `ccw` | MC chunk mesh 的剔除方向：`ccw` 或 `cw`。 |
| `mc_mesh_frustum_cull` | `1` | 跳过视锥外的 MC chunk mesh 绘制。 |
| `mc_mesh_draw_distance` | `0` | MC chunk mesh 最大绘制距离(Source 单位);`0` = 不限。 |
| `mc_mesh_depth_prepass` | `0` | GPU 着色前额外画一遍 CPU 材质 depth-only prepass;几何成本翻倍,通常保持关闭。 |
| `mc_mesh_emit_probe` | `0` | 打印详细 mesh emit timings，用于诊断完整几何重建。 |
| `mc_mesh_begin_upload` | `1` | 用 `mesh.Begin` 上传 IMesh 顶点，而不是 `IMesh:BuildFromTriangles`。 |
| `mc_mesh_debug_full_cube_only` | `0` | 调试 mesh emission 时只渲染完整立方体方块。 |
| `mc_mesh_geometry_cache_sections` | `384` | 保留 Lua 顶点/光照数据的 render section 数量；调低省内存。 |
| `mc_mesh_block_emit_cache_sections` | `1536` | 保留按方块 emit 顶点/光照缓存的 section 数；调低省内存但增加重建工作。 |
| `mc_mesh_connection_visible_template` | `1` | 对 fence/pane/wall/pipe 等连接形状使用可见几何模板缓存。 |

## GPU shader、GPU light texture 和 global lightmap

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_light_shader` | `1` | 使用自定义 GPU chunk shader；需要已编译 VCS 文件。 |
| `mc_light_texture` | `1` | GPU shader 从 chunk light texture 采样光照，而不是把光照烘进顶点色。 |
| `mc_light_style` | `fancy` | GPU 光照观感选择：`fancy` = PCF 阴影+冷暖调色；`plain` = 平滑光照无调色；`fast` = 低采样旧观感；`vanilla` = 原版 Minecraft lightmap 合成。 |
| `mc_light_bloom` | `1` | `fancy` GPU 光照的屏幕 bloom；shader 负责生成火把/阳光高亮种子，此项负责实际模糊扩散。 |
| `mc_light_bloom_strength` | `0.8` | bloom 强度；夜晚会自动小幅增强。 |
| `mc_light_bloom_threshold` | `0.7` | bloom 亮度阈值；越高越只保留最亮的火把核心和日光高光。 |
| `mc_light_bloom_radius` | `6` | bloom 屏幕模糊半径，范围在运行时限制为 `1..16`。 |
| `mc_light_brightness` | `1.5` | GPU light texture 的 block/sky light 亮度倍率(>1 时火把高等级饱和截顶;想不截顶地增强火把改用 gamma)。 |
| `mc_light_gamma` | `1` | GPU light texture 的衰减曲线；`>1` 提亮中间亮度，`<1` 压暗。 |
| `mc_light_sun_brightness` | `1` | GPU 路径 sun/sky light 亮度倍率。 |
| `mc_light_refresh_per_frame` | `2` | 昼夜 sky level 跳变时，每帧刷新多少个 chunk light texture。 |
| `mc_lightmap` | `1` | 启用程序生成的 16x16 global lightmap；提供暖火把和彩色昼夜天光。 |
| `mc_lightmap_torch_warmth` | `0.7` | global lightmap 里 block light/火把的暖色程度。 |
| `mc_lightmap_ambient` | `0.04` | GPU global lightmap 的最低可见亮度；设 `0` 可接近全黑。 |
| `mc_lightmap_sunset` | `0.5` | sunrise/sunset 天光轴橙色渐变强度；`0` 关闭。 |
| `mc_lightmap_night_gamma` | `0.6` | 昼夜天光亮度的感知曲线(`1` = 线性;更低 = 夜晚更亮更蓝、黄昏过渡更缓)。 |
| `mc_lightmap_sky_curve` | `3` | 天空环境光衰减形状 `1-(1-level)^curve`：越高，屋檐/树冠下等"有遮挡但开阔"的区域越亮，只有真正封闭的空间才落到环境底光（`1` = 线性）。 |
| `mc_lightmap_sky_min` | `0.1` | 天空环境光在 sky level 0 处保留的比例（室内/大建筑底下的环境底光；直射阳光独立于此，由 shadow map 决定）。 |
| `mc_lightmap_eye_dark` | `1` | 相机所在格无天空光时的环境光乘数（eyeBrightness 洞穴变暗）；`1` = 关闭——站在大建筑底下也会触发它，所以默认关。 |
| `mc_lightmap_vanilla_gamma` | `0.5` | `mc_light_style vanilla` 使用的原版亮度选项 options.gamma：`0` = 昏暗(Moody)，`0.5` = 原版默认，`1` = 明亮。 |
| `mc_lightmap_vanilla_flicker` | `1` | `mc_light_style vanilla` 使用的原版每 tick 火把闪烁；`0` = 稳定方块光。 |

## 昼夜循环

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_daycycle` | `1` | 服务器端 MC 昼夜循环开关，默认启用。 |
| `mc_daycycle_paused` | `0` | 暂停当前世界时间；解除暂停后从冻结时间继续。 |
| `mc_daycycle_length` | `1200` | 一个完整 MC 日的现实秒数；`1200` 等于原版 20 分钟。 |
| `mc_daycycle_sun_tilt` | `0.2` | shadow map 使用的太阳轨迹侧向倾斜，避免纯轴向阴影。 |
| `mc_daycycle_moon_shadow` | `0.3` | 夜晚月光阴影强度相对太阳阴影的倍率。 |
| `mc_daycycle_moon_light` | `2` | 深夜 moonlight sky level，范围 `0..15`；越低夜晚越暗。 |
| `mc_daycycle_night_tint` | `0.85` | 夜晚天光向蓝色月光偏移的强度；`0` 表示中性不染蓝。 |

## GPU shadow map

阴影处的黑暗主要靠这一组。建议组合：`mc_light_shader 1`、`mc_light_texture 1`、`mc_light_style fancy`、`mc_shadow 1`，再调 `mc_shadow_strength` 和 `mc_lightmap_ambient`。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_shadow` | `1` | 让 GPU light texture chunk shader 接收 MC shadow map。 |
| `mc_shadow_strength` | `0.75` | shadow map 对最终亮度的压暗强度。 |
| `mc_shadow_bias` | `0.0005` | shadow map 深度/边缘采样 bias，用于减轻 acne 和漏光。 |
| `mc_shadow_softness` | `0.5` | 16 点 Vogel PCF 半径，单位是 shadow-map texel；不会再联动 normal bias。 |
| `mc_shadow_size` | `2048` | MC-owned shadow map 分辨率,512-4096。map(畸变)模式 RT 为 size × size;csm 模式为 size × 3·size 的纵向级联 atlas(4096 约占 240MB 显存,老显卡可能建不出 RT 导致阴影关闭)。 |
| `mc_shadow_distance` | `4096` | 阴影总覆盖半径。map(畸变)模式下纹素密度从相机处(约 6.7 倍)随距离连续衰减,近处始终清晰;csm 模式下近/中级联半径为 distance/ratio² 和 distance/ratio。 |
| `mc_shadow_cascade_ratio` | `3` | 仅 csm 模式:级联半径比,1.5~8。 |
| `mc_shadow_caster_distance` | `4608` | 距相机多远以内的 MC chunk 会绘入 shadow map。 |
| `mc_shadow_update_interval` | `0` | shadow map 最小重绘间隔秒数。`0` = 不限速,但现在深度 pass 只在太阳方向、纹素对齐窗口、chunk 几何或覆盖半径变化时才真正重绘(静止场景零成本)。 |
| `mc_shadow_sun_step` | `1` | 昼夜循环下 shadow map 太阳角的量化步进(度)。连续移动的太阳会让光空间纹素网格每帧旋转,阴影边缘随 `mc_shadow_distance` 增大而明显爬动/抖动;量化后步进之间网格完全静止(深度 pass 也命中签名跳过)。`0` = 连续。阴影强度渐变仍是连续的。 |
| `mc_shadow_tint` | `0.6` | fancy shader 中阴影向冷色天空 tint 偏移的强度。 |
| `mc_shadow_edge_fade` | `0.1` | fancy shader 中阴影覆盖边缘的 fade 宽度。 |
| `mc_shadow_face_shade` | `0.65` | fancy shader 中背离太阳的面按阴影压暗的强度。 |
| `mc_shadow_warmth` | `0.35` | fancy shader 中日照面和火把区域的暖色强度。 |

## 高度场光影模式（height shadow mode）

与 shadow map 二选一的另一套太阳阴影：`mc_shadow_mode height` 切换（`map` 切回，需要 `mc_shadow 1`）。
维护一张俯视高度图，只在方块变化或玩家走远时重画；chunk shader 沿太阳方向对它 raymarch，
得到近硬远软的距离衰减软阴影。太阳/相机移动零重绘成本，昼夜循环下远比 `map` 模式便宜。
强度与调色复用 `mc_shadow_strength` 和 fancy 的 tint/face_shade/warmth/edge_fade；
`bias/softness/size/distance/caster_distance/update_interval` 等 shadow map 专属项在此模式下无效。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_shadow_mode` | `map` | 太阳阴影技术：`map` = Photon 式畸变 shadow map（单图,clip 空间径向拉伸,近处纹素密度约 6.7 倍且随距离连续衰减,无级联接缝跳变），`csm` = 3 级联纵向 atlas（可纹素吸附,太阳步进下完全静止,但级联边界随相机移动会有质量跳变），`height` = 缓存俯视高度场 raymarch。 |
| `mc_shadow_hf_size` | `1024` | 高度图分辨率。 |
| `mc_shadow_hf_range` | `4096` | 高度图覆盖的世界半径（以玩家为中心）。 |
| `mc_shadow_hf_max_dist` | `2400` | 阴影投射的最大世界距离（raymarch 射程）。 |
| `mc_shadow_hf_softness` | `0.05` | 半影正切：阴影随遮挡距离变软的速度（0.02 锐利，0.12 很软）。 |
| `mc_shadow_hf_update_interval` | `0.1` | 几何变化/窗口重定位后高度图的最小重绘间隔秒数。 |

## Source engine 光照桥

这一组把 Source 静态光照采样混入 MC mesh 顶点色，属于可选桥接，不是 GPU global lightmap。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_mesh_source_lighting` | `0` | 将 Source engine 静态光照混入 MC mesh 顶点色：`0` 关，`1` ambient，`2` normal，`3` max。 |
| `mc_mesh_source_lighting_strength` | `0.55` | Source 光照调制 MC 顶点色的强度。 |
| `mc_mesh_source_lighting_min` | `0.35` | Source 光照调制时的最低倍率。 |
| `mc_mesh_source_lighting_scale` | `1.0` | Source 光照采样值在混入前的倍率。 |

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

`mc_light_style fast` 切换回最初的低采样 GPU 光照着色器观感：每像素 4 次光照采样 + 1 次图集采样，
解析式暖/冷调色 + 面向着色，**无阴影采样、无 lightmap 查表**。优先级高于 fancy/height 材质选择。
昼夜亮度/夜色/暖色由每帧一次的常量传入（复用 daycycle 与 lightmap 的 cvar），无每 chunk 成本。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_light_style` | `fancy` | 设为 `fast` 使用低采样快速 GPU 光照着色器（旧版观感），并跳过 shadow map / heightfield 消费。 |
| `mc_light_flush_per_frame` | `8` | PreRender 中每帧最多重烘的 chunk 光照纹理数（绘制路径不再重烘；0 = 不限）。 |

## 原版 Minecraft 光照（vanilla 观感）

`mc_light_style vanilla` 切换到 1:1 复刻原版 Minecraft 26.2 的光照系统（公式逐行移植自
反编译源码 `out/` 的 `lightmap.fsh` + `LightmapRenderStateExtractor` + `Timelines`）：
最终色 = 图集色 x lightmap(方块光, 天光) x 面明暗(顶1.0/底0.5/X面0.6/Y面0.8) x AO，
**无阴影贴图、无冷暖调色**——昼夜亮度、火把暖色(0xFFD88C)、夜晚蓝天光(0.48,0.48,1 x 0.24)
全部按原版昼夜时间线烘在 16x16 lightmap 里，每个 MC tick 重绘（含火把闪烁随机游走）。
开启时自动跳过 shadow map / heightfield 的每帧渲染；切回默认观感用 `mc_light_style fancy`。
需要 `mc_lightmap 1`（默认开）。

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_light_style` | `fancy` | 设为 `vanilla` 使用原版 Minecraft 光照合成（一次 lightmap 查表，无阴影）。 |
| `mc_lightmap_vanilla_gamma` | `0.5` | 原版亮度选项 options.gamma：`0` = 昏暗(Moody)，`0.5` = 原版默认，`1` = 明亮。 |
| `mc_lightmap_vanilla_flicker` | `1` | 原版每 tick 火把闪烁（随机游走 x0.9 衰减）；`0` = 稳定方块光。 |
