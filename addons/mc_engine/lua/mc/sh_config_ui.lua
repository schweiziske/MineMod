--[[----------------------------------------------------------------------------
	MC : shared ConVar metadata for the in-game config menu.

	Entries carry ids only. Their display text is translated from keys that
	derive from those ids (MC.ConfigText); an entry names its own key only to
	reuse a text. The owning addon ships the text as JSON fragments below
	data_static/mc/i18n/config/ (docs/localization.md).
------------------------------------------------------------------------------]]

MC = MC or {}

------------------------------------------------------------------ text keys

MC.ConfigText = MC.ConfigText or {}
local Text = MC.ConfigText

--   group           config.group.<id>
--   category        config.category.<id>.label / .description
--   setting         config.setting.<name>.label / .help
--   choice          config.setting.<name>.choice.<value>
--   unit            config.unit.<unit>
-- labelKey, descriptionKey and helpKey replace a derived key; helpKey or
-- descriptionKey false means the entry has no such text. labelVars,
-- descriptionVars and helpVars fill placeholders and may hold nested
-- { key = ..., vars = ... } specs. A choice with text shows that literal
-- (a locale id, a user's preset name) instead of a translation.
function Text.GroupKey( group )
	return group.labelKey or ( "config.group." .. tostring( group.id ) )
end

function Text.CategoryKey( category )
	return category.labelKey or ( "config.category." .. tostring( category.id ) .. ".label" )
end

function Text.CategoryDescriptionKey( category )
	if category.descriptionKey == false then return nil end
	return category.descriptionKey or ( "config.category." .. tostring( category.id ) .. ".description" )
end

function Text.ItemKey( item )
	return item.labelKey or ( "config.setting." .. tostring( item.name ) .. ".label" )
end

function Text.ItemHelpKey( item )
	if item.helpKey == false then return nil end
	return item.helpKey or ( "config.setting." .. tostring( item.name ) .. ".help" )
end

function Text.ChoiceKey( item, entry )
	if entry.text ~= nil then return nil end
	return entry.labelKey or ( "config.setting." .. tostring( item.name ) .. ".choice." .. tostring( entry.value ) )
end

function Text.UnitKey( unit )
	return "config.unit." .. tostring( unit )
end

-- Every key an entry will look up ("group", "category" or "item"), for
-- validation at registration time and for the coverage tests.
function Text.Keys( kind, entry )
	local keys = {}
	local function add( key )
		if key ~= nil then keys[#keys + 1] = key end
	end
	if kind == "group" then
		add( Text.GroupKey( entry ) )
	elseif kind == "category" then
		add( Text.CategoryKey( entry ) )
		add( Text.CategoryDescriptionKey( entry ) )
	else
		add( Text.ItemKey( entry ) )
		add( Text.ItemHelpKey( entry ) )
		if entry.unit ~= nil then add( Text.UnitKey( entry.unit ) ) end
		if istable( entry.choices ) then
			for _, choiceEntry in ipairs( entry.choices ) do add( Text.ChoiceKey( entry, choiceEntry ) ) end
		end
	end
	return keys
end

------------------------------------------------------------------ metadata

local function choice( value, options )
	local entry = { value = tostring( value ) }
	for key, option in pairs( options or {} ) do entry[key] = option end
	return entry
end

local function item( name, kind, options )
	local entry = {
		name = name,
		kind = kind or "number",
	}

	for key, value in pairs( options or {} ) do
		entry[key] = value
	end

	return entry
end

local function category( id, group, items, options )
	for _, entry in ipairs( items or {} ) do
		entry.category = id
	end

	local entry = {
		id = id,
		group = group,
		items = items or {},
	}

	for key, value in pairs( options or {} ) do
		entry[key] = value
	end

	return entry
end

-- Language choice values stay stable while labels use each locale's autonym.
local function languageChoices()
	local choices = {}
	for index, option in ipairs( MC.I18n.LanguageOptions() ) do
		choices[index] = { value = option.value, text = option.label }
	end
	return choices
end

MC.ConfigGroups = {
	client = {
		{ id = "interface" },
		{ id = "lighting" },
		{ id = "creative" },
		{ id = "rendering" },
		{ id = "diagnostics" },
	},
	server = {
		{ id = "access" },
		{ id = "editing" },
		{ id = "gameplay" },
		{ id = "network" },
		{ id = "physics" },
		{ id = "interface" },
	},
}

MC.ConfigConVars = {
	client = {
		category( "home", "interface", {
				item( "mc_save_manager", "action", { action = "save_manager" } ),
				item( "mc_texture_packs", "action", { action = "texture_pack_manager" } ),
				item( "mc_gamemode", "choice", { choices = {
						choice( "creative" ),
						choice( "survival" ),
					},
					get = function() return MC.ConfirmedPlayerGameMode() end,
					set = function( value ) return MC.RequestPlayerGameMode( value ) end,
				} ),
		} ),

		category( "texture_pack", "interface", {
				item( "mc_texture_packs", "action", { action = "texture_pack_manager" } ),
		} ),

		category( "shader_pack", "interface", {}, { dynamic = "render_pack" } ),

		category( "language", "interface", {
			item( "mc_language", "choice", { choices = languageChoices } ),
		} ),

		category( "display", "rendering", {
			item( "mc_mesh_render", "bool" ),
			item( "mc_mesh_cull_mode", "choice", { choices = {
					choice( "ccw" ),
					choice( "cw" ),
				} } ),
			item( "mc_mesh_frustum_cull", "bool" ),
			item( "mc_mesh_draw_distance", "number", { unit = "u" } ),
			item( "mc_mesh_depth_prepass", "bool" ),
		} ),

		category( "mesh_cache", "rendering", {
			item( "mc_gc_smoothing", "number" ),
			item( "mc_build_unlimited", "bool" ),
			item( "mc_mesh_geometry_cache_sections", "number" ),
			item( "mc_mesh_block_emit_cache_sections", "number" ),
			item( "mc_mesh_begin_upload", "bool" ),
			item( "mc_mesh_connection_visible_template", "bool" ),
		} ),

		category( "native_mesh", "rendering", {
			item( "mc_native_mesh", "bool" ),
			item( "mc_native_think_ms", "number", { unit = "ms" } ),
		}, { requiresNativeMesh = true } ),

		category( "client_collision", "rendering", {
			item( "mc_client_collision", "bool" ),
			item( "mc_client_collision_chunk_span", "number", { unit = "chunks" } ),
			item( "mc_client_collision_cross_chunk", "bool" ),
			item( "mc_client_collision_default_version", "number", { advanced = true } ),
		} ),

		category( "light_pipeline", "lighting", {
			item( "mc_light_enabled", "bool" ),
			item( "mc_light_shader", "bool" ),
			item( "mc_light_texture", "bool" ),
		} ),

		category( "light_balance", "lighting", {
			item( "mc_light_ambient_min", "number" ),
			item( "mc_light_brightness", "number" ),
			item( "mc_light_gamma", "number" ),
			item( "mc_light_sun_brightness", "number" ),
		} ),

		category( "bloom", "lighting", {
			item( "mc_light_bloom", "bool" ),
			item( "mc_light_bloom_strength", "number" ),
			item( "mc_light_bloom_threshold", "number" ),
			item( "mc_light_bloom_radius", "number", { unit = "px" } ),
		} ),

		category( "lightmap", "lighting", {
			item( "mc_lightmap", "bool" ),
			item( "mc_lightmap_torch_warmth", "number" ),
			item( "mc_lightmap_ambient", "number" ),
			item( "mc_lightmap_sunset", "number" ),
			item( "mc_lightmap_night_gamma", "number" ),
			item( "mc_lightmap_sky_curve", "number" ),
			item( "mc_lightmap_sky_min", "number" ),
			item( "mc_lightmap_eye_dark", "number" ),
			item( "mc_lightmap_vanilla_gamma", "number" ),
			item( "mc_lightmap_vanilla_flicker", "bool" ),
		} ),

		category( "sky_light", "lighting", {
			item( "mc_light_sky_flood", "bool" ),
			item( "mc_light_sky_flood_per_frame", "number", { unit = "chunks_per_frame" } ),
		} ),

		category( "shadow_look", "lighting", {
			item( "mc_shadow", "bool" ),
			item( "mc_shadow_strength", "number" ),
			item( "mc_shadow_tint", "number" ),
			item( "mc_shadow_face_shade", "number" ),
			item( "mc_shadow_warmth", "number" ),
			item( "mc_shadow_edge_fade", "number" ),
		} ),

		category( "shadow_map", "lighting", {
			item( "mc_shadow_bias", "number" ),
			item( "mc_shadow_softness", "number", { unit = "texels" } ),
			item( "mc_shadow_size", "number", { unit = "px" } ),
			item( "mc_shadow_distance", "number", { unit = "u" } ),
			item( "mc_shadow_cascade_ratio", "number" ),
			item( "mc_shadow_caster_distance", "number", { unit = "u" } ),
			item( "mc_shadow_update_interval", "number", { unit = "s" } ),
			item( "mc_shadow_sun_step", "number", { unit = "deg" } ),
		} ),

		-- category( "height_shadow", "lighting", {
		-- 	item( "mc_shadow_hf_size", "number", { unit = "px" } ),
		-- 	item( "mc_shadow_hf_range", "number", { unit = "u" } ),
		-- 	item( "mc_shadow_hf_max_dist", "number", { unit = "u" } ),
		-- 	item( "mc_shadow_hf_softness", "number" ),
		-- 	item( "mc_shadow_hf_update_interval", "number", { unit = "s" } ),
		-- } ),

		category( "day_night_look", "lighting", {
			item( "mc_daycycle_sun_tilt", "number" ),
			item( "mc_daycycle_moon_shadow", "number" ),
			item( "mc_daycycle_moon_light", "number" ),
			item( "mc_daycycle_night_tint", "number" ),
		} ),

		category( "entity_lighting", "lighting", {
			item( "mc_light_entity", "bool" ),
			item( "mc_light_entity_players", "bool" ),
			item( "mc_light_entity_npcs", "bool" ),
			item( "mc_light_entity_props", "bool" ),
			item( "mc_light_entity_vehicles", "bool" ),
			item( "mc_light_entity_cluster", "bool" ),
			item( "mc_light_entity_gain", "number" ),
			item( "mc_light_entity_cluster_gain", "number" ),
			item( "mc_light_entity_reflections", "number" ),
			item( "mc_light_entity_interval", "number", { unit = "s" } ),
		} ),

		category( "creative_general", "creative", {
			item( "mc_creative_held_model", "bool" ),
			item( "mc_creative_held_anim", "bool" ),
		} ),

		category( "creative_first_person", "creative", {
			item( "mc_creative_held_fp_forward", "number" ),
			item( "mc_creative_held_fp_right", "number" ),
			item( "mc_creative_held_fp_up", "number" ),
			item( "mc_creative_held_fp_scale", "number" ),
			item( "mc_creative_held_fp_yaw", "number", { unit = "deg" } ),
			item( "mc_creative_held_fp_pitch", "number", { unit = "deg" } ),
			item( "mc_creative_held_fp_roll", "number", { unit = "deg" } ),
		} ),

		category( "creative_third_person", "creative", {
			item( "mc_creative_held_tp_forward", "number" ),
			item( "mc_creative_held_tp_right", "number" ),
			item( "mc_creative_held_tp_up", "number" ),
			item( "mc_creative_held_tp_scale", "number" ),
			item( "mc_creative_held_tp_yaw", "number", { unit = "deg" } ),
			item( "mc_creative_held_tp_pitch", "number", { unit = "deg" } ),
			item( "mc_creative_held_tp_roll", "number", { unit = "deg" } ),
		} ),

		category( "render_diagnostics", "diagnostics", {
			item( "mc_mesh_debug_full_cube_only", "bool" ),
			item( "mc_mesh_emit_probe", "bool" ),
			item( "mc_light_perf_debug", "bool" ),
			item( "mc_light_perf_print_break", "bool" ),
			item( "mc_light_perf_print_each", "bool" ),
		} ),

		category( "collision_diagnostics", "diagnostics", {
			item( "mc_server_collision_debug", "bool" ),
			item( "mc_client_collision_debug", "bool" ),
			item( "mc_client_collision_area_debug", "bool" ),
			item( "mc_client_collision_aabb_debug", "bool" ),
			item( "mc_client_collision_aabb_debug_limit", "number" ),
		} ),
	},

	server = {
		category( "permissions", "access", {
			item( "mc_admin_only", "bool" ),
			item( "mc_save_public", "bool" ),
			item( "mc_workshop_manage", "choice", { choices = {
					choice( "0" ),
					choice( "1" ),
					choice( "2" ),
				} } ),
			item( "mc_preset_public", "bool" ),
			item( "mc_cluster_public", "bool" ),
		} ),

		-- Choices are the locales the server loaded; the client receives them
		-- with the server values (sv_config_ui.lua).
		category( "server_console", "interface", {
			item( "mc_console_language", "choice", { serverChoices = languageChoices } ),
		} ),

		category( "world_limits", "access", {
			item( "mc_world_limit", "number", { unit = "blocks" } ),
			item( "mc_max_blocks", "number", { unit = "blocks" } ),
			item( "mc_reach", "number", { unit = "u" } ),
		} ),

		category( "server_time", "access", {
			item( "mc_daycycle", "bool" ),
			item( "mc_daycycle_paused", "bool" ),
			item( "mc_daycycle_follow_atmos", "bool" ),
			item( "mc_daycycle_length", "number", { unit = "s" } ),
		} ),

		category( "autosave", "editing", {
			item( "mc_autosave", "number", { unit = "s" } ),
		} ),

		category( "fill", "editing", {
			item( "mc_fill_max", "number", { unit = "blocks" } ),
			item( "mc_fill_batch_cells", "number" ),
			item( "mc_fill_batch_chunks", "number" ),
			item( "mc_fill_batch_interval", "number", { unit = "s" } ),
		} ),

		category( "imports_presets", "editing", {
			item( "mc_import_max", "number", { unit = "blocks" } ),
			item( "mc_preset_max_blocks", "number", { unit = "blocks" } ),
		} ),

		category( "full_sync", "network", {
			item( "mc_binary_chunk_patch", "bool", { advanced = true } ),
			item( "mc_binary_net_profile", "bool", { advanced = true } ),
			item( "mc_sync_messages_per_tick", "number" ),
			item( "mc_sync_reliable_budget", "number", { unit = "bytes" } ),
			item( "mc_sync_frame_ms", "number", { unit = "ms" } ),
			item( "mc_sync_inflight_limit", "number", { unit = "bytes" } ),
		} ),

		-- category( "http_delivery", "network", {
		-- 	item( "mc_chunk_http_enabled", "bool" ),
		-- 	item( "mc_chunk_http_base_url", "string" ),
		-- } ),

		-- category( "chunk_storage", "network", {
		-- 	item( "mc_large_world_chunk_threshold", "number", { unit = "chunks" } ),
		-- 	item( "mc_chunk_store_part_cache", "number" ),
		-- 	item( "mc_chunk_store_loads_per_tick", "number" ),
		-- 	item( "mc_chunk_store_frame_ms", "number", { unit = "ms" } ),
		-- } ),

		-- category( "legacy_streaming", "network", {
		-- 	item( "mc_stream_chunk_span_xy", "number", { advanced = true } ),
		-- 	item( "mc_stream_chunk_span_z", "number", { advanced = true } ),
		-- 	item( "mc_large_world_lazy_load", "bool", { advanced = true } ),
		-- } ),

		category( "collision_interest", "physics", {
			item( "mc_server_collision", "bool" ),
			item( "mc_server_collision_chunk_span", "number", { unit = "chunks" } ),
			item( "mc_server_collision_aabb_padding", "number", { unit = "u" } ),
			item( "mc_collision_aim_distance", "number", { unit = "u" } ),
			item( "mc_server_collision_aim_radius", "number", { unit = "blocks" } ),
			item( "mc_client_collision_aim_radius", "number", { unit = "blocks" } ),
			item( "mc_server_collision_hot_span", "number", { unit = "chunks" } ),
			item( "mc_server_collision_lookahead_time", "number", { unit = "s" } ),
			item( "mc_server_collision_lookahead_max", "number", { unit = "chunks" } ),
		} ),

		category( "collision_rebuild", "physics", {
			item( "mc_bulk_collision_chunks_per_interval", "number" ),
			item( "mc_bulk_collision_interval", "number", { unit = "s" } ),
		} ),

		category( "interaction", "gameplay", {
			item( "mc_use_interact", "bool" ),
		} ),

		category( "block_updates", "gameplay", {
			item( "mc_block_updates_enabled", "bool" ),
		} ),

		category( "block_damage", "gameplay", {
			item( "mc_block_damage", "bool" ),
			item( "mc_block_health_scale", "number" ),
			item( "mc_block_damage_decay", "number", { unit = "s" } ),
		} ),

		category( "block_cluster", "gameplay", {
			item( "mc_cluster_max_blocks", "number", { unit = "blocks" } ),
			item( "mc_cluster_max_extent", "number", { unit = "blocks" } ),
			item( "mc_cluster_max_per_player", "number" ),
			item( "mc_cluster_health_per_block", "number" ),
			item( "mc_cluster_mass_per_block", "number", { unit = "kg" } ),
			item( "mc_cluster_max_convexes", "number" ),
			item( "mc_cluster_merge_cells", "number", { unit = "cells" } ),
			item( "mc_cluster_collision_inset", "number", { unit = "u" } ),
		} ),

		category( "explosions", "gameplay", {
			item( "mc_block_explosion_scale", "number" ),
			item( "mc_block_explosion_max_radius", "number", { unit = "blocks" } ),
			item( "mc_block_explosion_max_blocks", "number", { unit = "blocks" } ),
			item( "mc_block_explosion_fx_limit", "number" ),
		} ),

		category( "inventory_death", "gameplay", {
			item( "mc_keep_inventory", "bool" ),
		} ),
		category( "player_game_mode", "gameplay", {
			item( "mc_default_gamemode", "choice", { choices = {
					choice( "creative" ),
					choice( "survival" ),
				} } ),
			item( "mc_allow_gamemode_switch", "bool" ),
		} ),
	},
}

for scope, categories in pairs( MC.ConfigConVars ) do
	for _, entryCategory in ipairs( categories or {} ) do
		entryCategory.scope = scope
		for _, entry in ipairs( entryCategory.items or {} ) do
			entry.scope = scope
		end
	end
end

function MC.FindConfigConVar( scope, name )
	for _, entryCategory in ipairs( ( MC.ConfigConVars and MC.ConfigConVars[scope] ) or {} ) do
		for _, entry in ipairs( entryCategory.items or {} ) do
			if entry.name == name then return entry, entryCategory end
		end
	end
end
