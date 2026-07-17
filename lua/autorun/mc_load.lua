--[[----------------------------------------------------------------------------
	MC - Minecraft-style voxel blocks for Garry's Mod
	Loader. Runs shared on server, is sent to and runs on clients.

	Design goal: NO per-block entities. Blocks live in a chunked voxel store and
	are drawn with IMesh (1 draw call per 16x16x32 chunk). One physics entity per
	non-empty chunk provides collision. So ~8192 blocks == 1 entity.
------------------------------------------------------------------------------]]

MC = MC or {}

local loadPerfStart = SysTime and SysTime() or 0
local loadPerfStartKB = collectgarbage and collectgarbage( "count" ) or 0

local SHARED = {
	"mc/state/sh_network_protocol.lua",
	"mc/sh_config.lua",
	"mc/sh_config_ui.lua",
	"mc/sh_daycycle.lua",
	"mc/sh_i18n.lua",
	"mc/generated/sh_generated_tiles.lua",
	"mc/generated/sh_generated_blocks.lua",
	"mc/generated/sh_generated_block_state_schemas.lua",
	"mc/generated/sh_generated_state_visual_catalog.lua",
	"mc/generated/sh_generated_block_connections.lua",
	"mc/generated/sh_generated_block_properties.lua",
	"mc/generated/sh_generated_block_light.lua",
	"mc/generated/sh_generated_block_collision.lua",
	"mc/generated/sh_generated_state_collision_families.lua",
	"mc/generated/sh_generated_sound_types.lua",
	"mc/generated/sh_generated_lang.lua",
	"mc/functional/sh_furnace.lua",
	"mc/functional/sh_doors.lua",
	"mc/functional/sh_trapdoors.lua",
	"mc/functional/sh_ladders.lua",
	"mc/functional/sh_liquids.lua",
	"mc/custom/sh_custom_blocks.lua",
	"mc/sh_blocks.lua",
	"mc/generated/sh_generated_mcswep_blocks.lua",
	"mc/sh_block_states.lua",
	"mc/state/sh_project_block_state_schemas.lua",
	"mc/state/sh_state_collision.lua",
	"mc/state/sh_state_visuals.lua",
	"mc/state/sh_state_tints.lua",
	"mc/import/sh_format.lua",
	"mc/block_entity/sh_registry.lua",
	"mc/block/sh_stairs.lua",
	"mc/sh_presets.lua",
	"mc/sh_player.lua",
	"mc/state/sh_section.lua",
	"mc/sh_voxel.lua",
	"mc/sh_multiblock.lua",
}
local SERVER_FILES = {
	"mc/sv_world.lua",
	"mc/creative/sv_state_selection.lua",
	"mc/state/sv_save_codec.lua",
	"mc/state/sv_network_transport.lua",
	"mc/state/sv_block_transaction.lua",
	"mc/import/sv_reader.lua",
	"mc/import/sv_decoder.lua",
	"mc/import/sv_world_sink.lua",
	"mc/import/sv_service.lua",
	"mc/import/sv_commands.lua",
	"mc/sv_config_ui.lua",
	"mc/sv_commands.lua",
	"mc/sv_collision_carriers.lua",
	"mc/sv_chunk_store.lua",
	"mc/sv_saves.lua",
	"mc/sv_presets.lua",
	"mc/sv_damage.lua",
	"mc/sv_player.lua",
}
local CLIENT_FILES = {
	"mc/state/cl_state_visual_catalog.lua",
	"mc/cl_lighting.lua",
	"mc/render/cl_mesh_cache.lua",
	"mc/render/cl_mesh_constants.lua",
	"mc/render/cl_mesh_config.lua",
	"mc/render/cl_sky_column.lua",
	"mc/render/cl_sky_flood.lua",
	"mc/render/cl_mesh_gpu_light_texture.lua",
	"mc/render/cl_mesh_shadow_map.lua",
	"mc/render/cl_mesh_heightfield.lua",
	"mc/render/cl_sun_shadow_sample.lua",
	"mc/render/cl_mesh_materials.lua",
	"mc/render/cl_mesh_global_lightmap.lua",
	"mc/render/cl_mesh_light_samples.lua",
	"mc/render/cl_mesh_upload.lua",
	"mc/render/cl_mesh_source_lighting.lua",
	"mc/render/cl_mesh_color.lua",
	"mc/render/cl_mesh_geometry.lua",
	"mc/render/cl_mesh_build_context.lua",
	"mc/render/cl_mesh_emitters.lua",
	"mc/render/cl_mesh_builder.lua",
	"mc/render/cl_mesh_core.lua",
	"mc/render/cl_collision.lua",
	"mc/render/cl_draw.lua",
	"mc/render/cl_mesh_bloom.lua",
	"mc/render/cl_dirty.lua",
	"mc/cl_render.lua",
	"mc/cl_config_ui.lua",
	"mc/cl_ui.lua",
	"mc/cl_save_ui.lua",
	"mc/cl_presets.lua",
	"mc/cl_effects.lua",
	"mc/cl_net.lua",
	"mc/state/cl_network_transport.lua",
	"mc/cl_commands.lua",
	"mc/cl_debug.lua",
	"mc/cl_light_bench.lua",
	"mc/cl_player.lua",
}

local LOAD_PERF_FILES = {
	["mc/generated/sh_generated_blocks.lua"] = true,
	["mc/generated/sh_generated_block_state_schemas.lua"] = true,
	["mc/generated/sh_generated_state_visual_catalog.lua"] = true,
	["mc/generated/sh_generated_state_collision_families.lua"] = true,
	["mc/sh_blocks.lua"] = true,
	["mc/sh_block_states.lua"] = true,
	["mc/state/cl_state_visual_catalog.lua"] = true,
}

MC.LoadPerfStats = {
	realm = SERVER and "server" or "client",
	files = {},
}

local function includeTracked( fileName )
	if not LOAD_PERF_FILES[fileName] then
		include( fileName )
		return
	end
	local start = SysTime and SysTime() or 0
	local beforeKB = collectgarbage and collectgarbage( "count" ) or 0
	include( fileName )
	local afterKB = collectgarbage and collectgarbage( "count" ) or beforeKB
	MC.LoadPerfStats.files[fileName] = {
		ms = math.Round( ( ( SysTime and SysTime() or start ) - start ) * 1000, 3 ),
		memoryKB = math.Round( afterKB - beforeKB, 3 ),
	}
end

if SERVER then
	AddCSLuaFile()
	for _, f in ipairs( SHARED ) do AddCSLuaFile( f ) end
	for _, f in ipairs( CLIENT_FILES ) do AddCSLuaFile( f ) end
end

for _, f in ipairs( SHARED ) do includeTracked( f ) end

if SERVER then
	for _, f in ipairs( SERVER_FILES ) do includeTracked( f ) end
else
	for _, f in ipairs( CLIENT_FILES ) do includeTracked( f ) end
end

local loadPerfEndKB = collectgarbage and collectgarbage( "count" ) or loadPerfStartKB
MC.LoadPerfStats.totalMS = math.Round( ( ( SysTime and SysTime() or loadPerfStart ) - loadPerfStart ) * 1000, 3 )
MC.LoadPerfStats.totalMemoryKB = math.Round( loadPerfEndKB - loadPerfStartKB, 3 )

function MC.GeneratedRuntimeDiagnostics()
	return {
		realm = SERVER and "server" or "client",
		luaHeapKB = collectgarbage and math.Round( collectgarbage( "count" ), 3 ) or 0,
		load = MC.LoadPerfStats,
		blocks = MC.GeneratedBlockCatalogStats,
		blockCount = MC.GeneratedBlockDefinitionCount or 0,
		stateCount = MC.BlockStateCount or 0,
		stateMetadata = MC.BlockStateRegistryMetadata or MC.GeneratedStateMetadata,
		propertyDomains = MC.BlockStatePropertyDomainStats,
		stateVisuals = MC.StateVisualCatalogStats,
		blockStagingReleased = MC.GeneratedBlockRegistrationTablesReleased == true,
		schemaStagingReleased = MC.GeneratedBlockStateSchemasReleased == true,
		pendingSchemasReleased = MC.PendingBlockStateSchemasReleased == true,
	}
end

MsgN( "[MC] Voxel block addon loaded (" .. ( SERVER and "server" or "client" ) .. ")" )
