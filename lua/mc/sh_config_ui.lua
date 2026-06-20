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
		} },
		{ scope = "client", id = "lighting", label = "Lighting", items = {
			item( "lighting", "mc_light_enabled", "Lighting enabled", "bool", "Apply Minecraft-style block lighting" ),
			item( "lighting", "mc_light_sky_level", "Sky light level", "number", "Base sky light level" ),
			item( "lighting", "mc_light_ambient_min", "Ambient minimum", "number", "Minimum rendered brightness" ),
			item( "lighting", "mc_light_style", "Lighting style", "string", "best or fast" ),
			item( "lighting", "mc_light_perf_debug", "Lighting perf debug", "bool", "Track lighting perf diagnostics" ),
			item( "lighting", "mc_light_perf_print_break", "Print break lighting perf", "bool", "Print lighting cost when breaking blocks" ),
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

function MC.FindConfigConVar( scope, name )
	for _, category in ipairs( ( MC.ConfigConVars and MC.ConfigConVars[scope] ) or {} ) do
		for _, entry in ipairs( category.items or {} ) do
			if entry.name == name then return entry, category end
		end
	end
end
