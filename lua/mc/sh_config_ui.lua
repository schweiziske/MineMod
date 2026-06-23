--[[----------------------------------------------------------------------------
	MC : shared ConVar metadata for the in-game config menu.
------------------------------------------------------------------------------]]

MC = MC or {}

local function item( category, name, label, kind, help )
	return {
		category = category,
		name = name,
		label = label,
		kind = kind or "number",
		help = help or "",
	}
end

MC.ConfigConVars = {
	client = {
		{ scope = "client", id = "general", label = "General", items = {
			item( "general", "mc_language", "Language", "string", "auto, zh_cn, or en_us" ),
		} },
		{ scope = "client", id = "render", label = "Render", items = {
			item( "render", "mc_mesh_render", "Chunk mesh render", "bool", "Draw MC chunks with IMesh" ),
			item( "render", "mc_client_collision", "Client collision prediction", "bool", "Predict MC chunk collision clientside" ),
			item( "render", "mc_client_collision_chunk_span", "Client collision chunk span", "number", "Extra chunk radius for prediction collision" ),
			item( "render", "mc_client_collision_cross_chunk", "Cross-chunk collision", "bool", "Include neighbouring chunk collision where needed" ),
			item( "render", "mc_client_collision_default_version", "Default collision version", "number", "Migration/version marker for collision defaults" ),
			item( "render", "mc_mesh_geometry_cache_sections", "Geometry cache sections", "number", "Render sections retaining Lua mesh/light data for light-only recolor" ),
			item( "render", "mc_mesh_block_emit_cache_sections", "Block emit cache sections", "number", "Render sections retaining per-block emitted vertex/light caches" ),
			item( "render", "mc_mesh_begin_upload", "Mesh.Begin upload", "bool", "Upload IMesh vertices with mesh.Begin instead of BuildFromTriangles" ),
			item( "render", "mc_mesh_emit_probe", "Mesh emit probe", "bool", "Print detailed mesh emit timings for geometry rebuild diagnosis" ),
		} },
		{ scope = "client", id = "lighting", label = "Lighting", items = {
			item( "lighting", "mc_light_enabled", "Lighting enabled", "bool", "Apply Minecraft-style block lighting" ),
			item( "lighting", "mc_light_sky_level", "Sky light level", "number", "Base sky light level" ),
			item( "lighting", "mc_light_ambient_min", "Ambient minimum", "number", "Minimum rendered brightness" ),
			item( "lighting", "mc_light_style", "Lighting style", "string", "fast / vanilla / best / shader" ),
			item( "lighting", "mc_light_perf_debug", "Lighting perf debug", "bool", "Track lighting perf diagnostics" ),
			item( "lighting", "mc_light_perf_print_break", "Print break lighting perf", "bool", "Print lighting cost when breaking blocks" ),
			item( "lighting", "mc_light_perf_print_each", "Print each light calc", "bool", "Print one-line timing for every lighting calculation" ),
		} },
		{ scope = "client", id = "creative", label = "Creative Placer", items = {
			item( "creative", "mc_creative_held_model", "Held block model", "bool", "Draw the held block model" ),
			item( "creative", "mc_creative_held_anim", "Held block animation", "bool", "Play placement/break swing animations" ),
			item( "creative", "mc_creative_held_fp_forward", "FP forward", "number", "First-person held block forward offset" ),
			item( "creative", "mc_creative_held_fp_right", "FP right", "number", "First-person held block right offset" ),
			item( "creative", "mc_creative_held_fp_up", "FP up", "number", "First-person held block up offset" ),
			item( "creative", "mc_creative_held_fp_scale", "FP scale", "number", "First-person held block scale" ),
			item( "creative", "mc_creative_held_fp_yaw", "FP yaw", "number", "First-person held block yaw" ),
			item( "creative", "mc_creative_held_fp_pitch", "FP pitch", "number", "First-person held block pitch" ),
			item( "creative", "mc_creative_held_fp_roll", "FP roll", "number", "First-person held block roll" ),
			item( "creative", "mc_creative_held_tp_forward", "TP forward", "number", "Third-person held block forward offset" ),
			item( "creative", "mc_creative_held_tp_right", "TP right", "number", "Third-person held block right offset" ),
			item( "creative", "mc_creative_held_tp_up", "TP up", "number", "Third-person held block up offset" ),
			item( "creative", "mc_creative_held_tp_scale", "TP scale", "number", "Third-person held block scale" ),
			item( "creative", "mc_creative_held_tp_yaw", "TP yaw", "number", "Third-person held block yaw" ),
			item( "creative", "mc_creative_held_tp_pitch", "TP pitch", "number", "Third-person held block pitch" ),
			item( "creative", "mc_creative_held_tp_roll", "TP roll", "number", "Third-person held block roll" ),
		} },
		{ scope = "client", id = "debug", label = "Debug", items = {
			item( "debug", "mc_server_collision_debug", "Server collision debug", "bool", "Draw server collision debug data" ),
			item( "debug", "mc_client_collision_debug", "Client collision debug", "bool", "Draw client collision debug data" ),
			item( "debug", "mc_client_collision_area_debug", "Collision area debug", "bool", "Draw active client collision areas" ),
			item( "debug", "mc_client_collision_aabb_debug", "Collision AABB debug", "bool", "Draw client collision AABBs" ),
			item( "debug", "mc_client_collision_aabb_debug_limit", "Collision AABB debug limit", "number", "Maximum debug AABBs to draw" ),
		} },
	},
	server = {
		{ scope = "server", id = "world", label = "World", items = {
			item( "world", "mc_admin_only", "Admin only editing", "bool", "Only admins may place/break blocks" ),
			item( "world", "mc_world_limit", "World limit", "number", "Maximum absolute block coordinate" ),
			item( "world", "mc_max_blocks", "Max blocks", "number", "Global placed-block cap; 0 = unlimited" ),
			item( "world", "mc_reach", "Build reach", "number", "Max place/break distance; 0 disables" ),
			item( "world", "mc_autosave", "Autosave interval", "number", "Seconds between autosaves; 0 disables" ),
			item( "world", "mc_save_public", "Public saves", "bool", "Allow non-admin save list/load/save" ),
		} },
		{ scope = "server", id = "edit", label = "Editing", items = {
			item( "edit", "mc_fill_max", "/fill max blocks", "number", "Max blocks one /fill may modify" ),
			item( "edit", "mc_fill_batch_cells", "/fill batch cells", "number", "Cells applied per /fill server batch" ),
			item( "edit", "mc_fill_batch_chunks", "/fill batch chunks", "number", "Chunks touched per /fill server batch" ),
			item( "edit", "mc_fill_batch_interval", "/fill batch interval", "number", "Seconds between /fill batches" ),
			item( "edit", "mc_import_max", "Import max blocks", "number", "Max blocks one import may load" ),
			item( "edit", "mc_preset_max_blocks", "Preset max blocks", "number", "Max non-air blocks one preset may save/place" ),
		} },
		{ scope = "server", id = "sync", label = "Sync / Streaming", items = {
			item( "sync", "mc_sync_cells_per_part", "Sync cells per part", "number", "Blocks per streamed sync net message" ),
			item( "sync", "mc_sync_messages_per_tick", "Sync messages per tick", "number", "Streamed sync messages per tick" ),
			item( "sync", "mc_sync_reliable_budget", "Reliable sync budget", "number", "Approx max reliable sync bytes per tick" ),
			item( "sync", "mc_sync_fast", "Fast sync", "bool", "Use ack-windowed fast full-map sync" ),
			item( "sync", "mc_sync_frame_ms", "Sync frame ms", "number", "Approx server CPU ms spent on full sync each tick" ),
			item( "sync", "mc_sync_inflight_limit", "Sync inflight limit", "number", "Max unacknowledged full-sync bytes per client" ),
			item( "sync", "mc_sync_snapshot", "Snapshot sync", "bool", "Use compressed snapshot then incremental edits" ),
			item( "sync", "mc_sync_snapshot_part_bytes", "Snapshot part bytes", "number", "Bytes per snapshot net part" ),
			item( "sync", "mc_sync_snapshot_max_chunks", "Snapshot max chunks", "number", "Legacy snapshot chunk limit" ),
			item( "sync", "mc_chunk_http_enabled", "Chunk HTTP", "bool", "Allow HTTP lazy-save chunk delivery" ),
			item( "sync", "mc_chunk_http_base_url", "Chunk HTTP base URL", "string", "HTTP root URL serving garrysmod/data" ),
			item( "sync", "mc_stream_chunk_span_xy", "Legacy stream span XY", "number", "Legacy client chunk range sync span" ),
			item( "sync", "mc_stream_chunk_span_z", "Legacy stream span Z", "number", "Legacy vertical chunk range sync span" ),
			item( "sync", "mc_large_world_lazy_load", "Legacy lazy load", "bool", "Legacy v8 lazy chunk loading toggle" ),
			item( "sync", "mc_large_world_chunk_threshold", "Lazy chunk threshold", "number", "Chunk count for lazy streaming behaviour" ),
			item( "sync", "mc_chunk_store_part_cache", "Part cache", "number", "Maximum lazy-save part files cached in memory" ),
			item( "sync", "mc_chunk_store_loads_per_tick", "Chunk loads per tick", "number", "Maximum lazy chunk hydrations per store tick" ),
			item( "sync", "mc_chunk_store_frame_ms", "Chunk store frame ms", "number", "Approx lazy chunk hydration budget per tick" ),
		} },
		{ scope = "server", id = "collision", label = "Collision", items = {
			item( "collision", "mc_server_collision_chunk_span", "Server collision chunk span", "number", "Extra chunk radius around server collision AABBs" ),
			item( "collision", "mc_server_collision_aabb_padding", "Server AABB padding", "number", "Padding around player/entity AABBs" ),
			item( "collision", "mc_collision_aim_distance", "Aim collision distance", "number", "Trace distance for aimed-block collision interest" ),
			item( "collision", "mc_server_collision_aim_radius", "Server aim radius", "number", "Aimed block radius for server collision" ),
			item( "collision", "mc_client_collision_aim_radius", "Client aim radius", "number", "Aimed block radius for client collision" ),
			item( "collision", "mc_server_collision_hot_span", "Velocity hot span", "number", "Velocity lookahead chunk span" ),
			item( "collision", "mc_server_collision_lookahead_time", "Lookahead time", "number", "Seconds of velocity lookahead" ),
			item( "collision", "mc_server_collision_lookahead_max", "Lookahead max", "number", "Maximum lookahead chunk radius" ),
			item( "collision", "mc_bulk_collision_chunks_per_interval", "Bulk collision chunks", "number", "Collision chunks rebuilt per interval" ),
			item( "collision", "mc_bulk_collision_interval", "Bulk collision interval", "number", "Seconds between collision rebuild batches" ),
		} },
		{ scope = "server", id = "damage", label = "Damage / Explosions", items = {
			item( "damage", "mc_block_damage", "Block damage", "bool", "Allow GMod damage to break MC blocks" ),
			item( "damage", "mc_block_health_scale", "Block health scale", "number", "Health multiplier applied to Minecraft hardness" ),
			item( "damage", "mc_block_damage_decay", "Damage decay", "number", "Seconds before partial damage is forgotten" ),
			item( "damage", "mc_block_explosion_scale", "Explosion scale", "number", "GMod blast damage to Minecraft explosion radius scale" ),
			item( "damage", "mc_block_explosion_max_radius", "Explosion max radius", "number", "Maximum Minecraft-style explosion radius" ),
			item( "damage", "mc_block_explosion_max_blocks", "Explosion max blocks", "number", "Maximum blocks one explosion may destroy" ),
			item( "damage", "mc_explosion_mesh_sections_per_frame", "Explosion mesh sections/frame", "number", "Client mesh rebuild sections per interval" ),
			item( "damage", "mc_explosion_mesh_interval", "Explosion mesh interval", "number", "Seconds between client mesh rebuild batches" ),
		} },
	},
}

local CATEGORY_ZH = {
	general = "通用",
	render = "渲染",
	lighting = "光照",
	creative = "创造放置器",
	debug = "调试",
	world = "世界",
	edit = "编辑",
	sync = "同步 / 流式加载",
	collision = "碰撞",
	damage = "伤害 / 爆炸",
}

local ITEM_ZH = {
	mc_language = { labelZH = "语言", helpZH = "auto、zh_cn 或 en_us" },
	mc_mesh_render = { labelZH = "区块网格渲染", helpZH = "使用 IMesh 绘制 MC 区块" },
	mc_client_collision = { labelZH = "客户端碰撞预测", helpZH = "在客户端预测 MC 区块碰撞" },
	mc_client_collision_chunk_span = { labelZH = "客户端碰撞区块范围", helpZH = "预测碰撞额外区块半径" },
	mc_client_collision_cross_chunk = { labelZH = "跨区块碰撞", helpZH = "需要时包含相邻区块碰撞" },
	mc_client_collision_default_version = { labelZH = "默认碰撞版本", helpZH = "碰撞默认值迁移/版本标记" },
	mc_light_enabled = { labelZH = "启用光照", helpZH = "应用 Minecraft 风格方块光照" },
	mc_light_sky_level = { labelZH = "天空光等级", helpZH = "基础天空光等级" },
	mc_light_ambient_min = { labelZH = "最低环境亮度", helpZH = "渲染时的最低亮度" },
	mc_light_style = { labelZH = "光照模式", helpZH = "fast / vanilla / best / shader" },
	mc_light_perf_debug = { labelZH = "光照性能调试", helpZH = "记录光照性能诊断" },
	mc_light_perf_print_break = { labelZH = "破坏时打印光照耗时", helpZH = "破坏方块时打印光照成本" },
	mc_creative_held_model = { labelZH = "手持方块模型", helpZH = "绘制手持方块模型" },
	mc_creative_held_anim = { labelZH = "手持方块动画", helpZH = "播放放置/破坏挥动动画" },
	mc_creative_held_fp_forward = { labelZH = "第一人称前后偏移", helpZH = "第一人称手持方块前后位置" },
	mc_creative_held_fp_right = { labelZH = "第一人称左右偏移", helpZH = "第一人称手持方块左右位置" },
	mc_creative_held_fp_up = { labelZH = "第一人称上下偏移", helpZH = "第一人称手持方块上下位置" },
	mc_creative_held_fp_scale = { labelZH = "第一人称缩放", helpZH = "第一人称手持方块大小" },
	mc_creative_held_fp_yaw = { labelZH = "第一人称偏航", helpZH = "第一人称手持方块 yaw 角度" },
	mc_creative_held_fp_pitch = { labelZH = "第一人称俯仰", helpZH = "第一人称手持方块 pitch 角度" },
	mc_creative_held_fp_roll = { labelZH = "第一人称翻滚", helpZH = "第一人称手持方块 roll 角度" },
	mc_creative_held_tp_forward = { labelZH = "第三人称前后偏移", helpZH = "第三人称手持方块前后位置" },
	mc_creative_held_tp_right = { labelZH = "第三人称左右偏移", helpZH = "第三人称手持方块左右位置" },
	mc_creative_held_tp_up = { labelZH = "第三人称上下偏移", helpZH = "第三人称手持方块上下位置" },
	mc_creative_held_tp_scale = { labelZH = "第三人称缩放", helpZH = "第三人称手持方块大小" },
	mc_creative_held_tp_yaw = { labelZH = "第三人称偏航", helpZH = "第三人称手持方块 yaw 角度" },
	mc_creative_held_tp_pitch = { labelZH = "第三人称俯仰", helpZH = "第三人称手持方块 pitch 角度" },
	mc_creative_held_tp_roll = { labelZH = "第三人称翻滚", helpZH = "第三人称手持方块 roll 角度" },
	mc_server_collision_debug = { labelZH = "服务端碰撞调试", helpZH = "绘制服务端碰撞调试数据" },
	mc_client_collision_debug = { labelZH = "客户端碰撞调试", helpZH = "绘制客户端碰撞调试数据" },
	mc_client_collision_area_debug = { labelZH = "碰撞区域调试", helpZH = "绘制当前客户端碰撞区域" },
	mc_client_collision_aabb_debug = { labelZH = "碰撞 AABB 调试", helpZH = "绘制客户端碰撞 AABB" },
	mc_client_collision_aabb_debug_limit = { labelZH = "碰撞 AABB 调试上限", helpZH = "最多绘制的调试 AABB 数量" },
	mc_admin_only = { labelZH = "仅管理员编辑", helpZH = "只有管理员可以放置/破坏方块" },
	mc_world_limit = { labelZH = "世界边界", helpZH = "最大绝对方块坐标" },
	mc_max_blocks = { labelZH = "方块总上限", helpZH = "全局放置方块上限；0 = 不限制" },
	mc_reach = { labelZH = "建造距离", helpZH = "最大放置/破坏距离；0 = 禁用" },
	mc_autosave = { labelZH = "自动保存间隔", helpZH = "两次自动保存之间的秒数；0 = 禁用" },
	mc_save_public = { labelZH = "公开存档", helpZH = "允许非管理员列出/读取/保存存档" },
	mc_fill_max = { labelZH = "/fill 最大方块数", helpZH = "单次 /fill 最多修改的方块数" },
	mc_fill_batch_cells = { labelZH = "/fill 每批单元", helpZH = "每批服务端 /fill 应用的单元数" },
	mc_fill_batch_chunks = { labelZH = "/fill 每批区块", helpZH = "每批 /fill 触碰的区块数" },
	mc_fill_batch_interval = { labelZH = "/fill 批次间隔", helpZH = "/fill 批次之间的秒数" },
	mc_import_max = { labelZH = "导入最大方块数", helpZH = "单次导入最多读取的方块数" },
	mc_preset_max_blocks = { labelZH = "预设最大方块数", helpZH = "单个预设最多保存/放置的非空气方块数" },
	mc_sync_cells_per_part = { labelZH = "同步每包单元", helpZH = "每条流式同步 net 消息的方块数" },
	mc_sync_messages_per_tick = { labelZH = "每 tick 同步消息数", helpZH = "每 tick 发送的流式同步消息数" },
	mc_sync_reliable_budget = { labelZH = "可靠同步预算", helpZH = "每 tick 可靠同步的大致字节上限" },
	mc_sync_fast = { labelZH = "快速同步", helpZH = "使用带 ack 窗口的快速全图同步" },
	mc_sync_frame_ms = { labelZH = "同步帧预算 ms", helpZH = "每 tick 用于全量同步的大致服务端 CPU ms" },
	mc_sync_inflight_limit = { labelZH = "同步在途上限", helpZH = "每个客户端未确认的全量同步字节上限" },
	mc_sync_snapshot = { labelZH = "快照同步", helpZH = "先发送压缩快照，再同步增量编辑" },
	mc_sync_snapshot_part_bytes = { labelZH = "快照分包字节数", helpZH = "每个快照 net 分包的字节数" },
	mc_sync_snapshot_max_chunks = { labelZH = "快照最大区块数", helpZH = "旧版快照区块上限" },
	mc_chunk_http_enabled = { labelZH = "区块 HTTP", helpZH = "允许通过 HTTP 懒加载存档区块" },
	mc_chunk_http_base_url = { labelZH = "区块 HTTP 地址", helpZH = "提供 garrysmod/data 的 HTTP 根地址" },
	mc_stream_chunk_span_xy = { labelZH = "旧版流式 XY 范围", helpZH = "旧版客户端区块同步水平范围" },
	mc_stream_chunk_span_z = { labelZH = "旧版流式 Z 范围", helpZH = "旧版客户端区块同步垂直范围" },
	mc_large_world_lazy_load = { labelZH = "旧版懒加载", helpZH = "旧版 v8 懒加载开关" },
	mc_large_world_chunk_threshold = { labelZH = "懒加载区块阈值", helpZH = "触发懒加载行为的区块数量" },
	mc_chunk_store_part_cache = { labelZH = "分包缓存", helpZH = "内存中缓存的懒保存分包文件上限" },
	mc_chunk_store_loads_per_tick = { labelZH = "每 tick 区块读取", helpZH = "每个存储 tick 最多水合的懒区块数" },
	mc_chunk_store_frame_ms = { labelZH = "区块存储帧预算 ms", helpZH = "每 tick 懒区块水合的大致预算" },
	mc_server_collision_chunk_span = { labelZH = "服务端碰撞区块范围", helpZH = "服务端碰撞 AABB 周围的额外区块半径" },
	mc_server_collision_aabb_padding = { labelZH = "服务端 AABB 边距", helpZH = "玩家/实体 AABB 周围的边距" },
	mc_collision_aim_distance = { labelZH = "准星碰撞距离", helpZH = "准星方块碰撞关注的 trace 距离" },
	mc_server_collision_aim_radius = { labelZH = "服务端准星半径", helpZH = "服务端准星方块碰撞半径" },
	mc_client_collision_aim_radius = { labelZH = "客户端准星半径", helpZH = "客户端准星方块碰撞半径" },
	mc_server_collision_hot_span = { labelZH = "速度热点范围", helpZH = "速度预测使用的区块范围" },
	mc_server_collision_lookahead_time = { labelZH = "速度预测时间", helpZH = "速度预测的秒数" },
	mc_server_collision_lookahead_max = { labelZH = "速度预测最大范围", helpZH = "速度预测最大区块半径" },
	mc_bulk_collision_chunks_per_interval = { labelZH = "批量碰撞区块数", helpZH = "每个间隔重建的碰撞区块数" },
	mc_bulk_collision_interval = { labelZH = "批量碰撞间隔", helpZH = "碰撞重建批次之间的秒数" },
	mc_block_damage = { labelZH = "方块伤害", helpZH = "允许 GMod 伤害破坏 MC 方块" },
	mc_block_health_scale = { labelZH = "方块生命倍率", helpZH = "应用到 Minecraft 硬度的生命值倍率" },
	mc_block_damage_decay = { labelZH = "伤害衰减", helpZH = "未完成破坏伤害被遗忘前的秒数" },
	mc_block_explosion_scale = { labelZH = "爆炸倍率", helpZH = "GMod 爆炸伤害到 Minecraft 爆炸半径的倍率" },
	mc_block_explosion_max_radius = { labelZH = "爆炸最大半径", helpZH = "Minecraft 风格爆炸最大半径" },
	mc_block_explosion_max_blocks = { labelZH = "爆炸最大方块数", helpZH = "单次爆炸最多破坏的方块数" },
	mc_explosion_mesh_sections_per_frame = { labelZH = "爆炸网格每帧段数", helpZH = "客户端爆炸网格每个间隔重建的段数" },
	mc_explosion_mesh_interval = { labelZH = "爆炸网格间隔", helpZH = "客户端爆炸网格重建批次之间的秒数" },
}

for _, categories in pairs( MC.ConfigConVars ) do
	for _, category in ipairs( categories or {} ) do
		category.zhLabel = CATEGORY_ZH[category.id]
		for _, entry in ipairs( category.items or {} ) do
			local zh = ITEM_ZH[entry.name]
			if zh then
				entry.labelZH = zh.labelZH
				entry.helpZH = zh.helpZH
			end
		end
	end
end

function MC.FindConfigConVar( scope, name )
	for _, category in ipairs( ( MC.ConfigConVars and MC.ConfigConVars[scope] ) or {} ) do
		for _, entry in ipairs( category.items or {} ) do
			if entry.name == name then return entry, category end
		end
	end
end
