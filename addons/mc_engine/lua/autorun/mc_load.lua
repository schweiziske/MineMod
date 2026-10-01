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
	-- First, and deliberately: every file after this one may report through
	-- MC.Fault / MC.Check / MC.Need, so the reporter has to exist before any of
	-- them run. It has no dependencies of its own.
	"mc/sh_fault.lua",
	"mc/state/sh_network_protocol.lua",
	"mc/sh_config.lua",
	"mc/sh_game_mode.lua",
	"mc/workshop/sh_workshop_bundle.lua",
	"mc/sh_world_adapter.lua",
	"mc/sh_config_ui.lua",
	"mc/sh_daycycle.lua",
	"mc/sh_i18n.lua",
	"mc/generated/sh_generated_tiles.lua",
	"mc/generated/sh_generated_block_animations_default.lua",
	"mc/generated/sh_generated_block_animations_programmer_art.lua",
	"mc/generated/sh_generated_blocks.lua",
	"mc/generated/sh_generated_block_state_schemas.lua",
	"mc/generated/sh_generated_state_visual_catalog.lua",
	"mc/generated/sh_generated_model_lighting.lua",
	"mc/generated/sh_generated_block_connections.lua",
	"mc/generated/sh_generated_block_properties.lua",
	"mc/generated/sh_generated_block_light.lua",
	"mc/generated/sh_generated_block_collision.lua",
	"mc/generated/sh_generated_state_collision_families.lua",
	"mc/generated/sh_generated_sound_types.lua",
	"mc/generated/sh_generated_event_sounds.lua",
	"mc/generated/sh_generated_fire_flammables.lua",
	"mc/sh_event_sounds.lua",
	"mc/generated/sh_generated_lang.lua",
	"mc/functional/sh_doors.lua",
	"mc/functional/sh_trapdoors.lua",
	"mc/functional/sh_fence_gates.lua",
	"mc/functional/sh_ladders.lua",
	"mc/liquid/sh_registry.lua",
	"mc/liquid/sh_shapes.lua",
	"mc/liquid/sh_flow.lua",
	"mc/liquid/sh_contact.lua",
	"mc/liquid/sh_movement.lua",
	"mc/custom/sh_custom_blocks.lua",
	"mc/sh_blocks.lua",
	"mc/generated/sh_generated_mcswep_blocks.lua",
	"mc/sh_block_states.lua",
	"mc/block_entity/sh_registry.lua",
	"mc/block_update/sh_registry.lua",
	"mc/farming/sh_rules.lua",
	"mc/state/sh_project_block_state_schemas.lua",
	"mc/state/sh_state_collision.lua",
	"mc/state/sh_state_visuals.lua",
	"mc/registry/sh_mod_registry.lua",
	"mc/block/sh_barrier.lua",
	"mc/state/sh_state_tints.lua",
	"mc/import/sh_format.lua",
	"mc/functional/sh_signs.lua",
	"mc/functional/sh_banners.lua",
	"mc/block/sh_stairs.lua",
	"mc/block/sh_torch_placement.lua",
	"mc/block/sh_face_attached_placement.lua",
	"mc/block/sh_redstone_wire.lua",
	"mc/block/sh_connections.lua",
	"mc/block/sh_rails.lua",
	"mc/block/sh_neighbor_states.lua",
	"mc/sh_presets.lua",
	"mc/sh_block_cluster.lua",
	"mc/sh_player.lua",
	"mc/state/sh_section.lua",
	"mc/state/sh_binary_section_patch.lua",
	"mc/state/cl_state_visual_catalog.lua",
	"mc/state/cl_state_selection_boxes.lua",
	"mc/sh_voxel.lua",
	"mc/debug/sh_gallery.lua",
	"mc/redstone/sh_redstone.lua",
	"mc/redstone/sh_logic.lua",
	"mc/redstone/sh_devices.lua",
	"mc/redstone/sh_piston.lua",
	"mc/sh_multiblock.lua",
	"mc/api/sh_api.lua",
	"mc/api/sh_manifest.lua",
	"mc/registry/sh_builtin_api_migration.lua",
	"mc/integration/sh_hand_weapon_bridge.lua",
}
local SERVER_FILES = {
	"mc/sv_world.lua",
	"mc/sv_game_mode.lua",
	"mc/creative/sv_state_selection.lua",
	"mc/state/sv_save_codec.lua",
	"mc/state/sv_region_save.lua",
	"mc/state/sv_region_persistence.lua",
	"mc/state/sv_network_transport.lua",
	"mc/state/sv_block_transaction.lua",
	"mc/state/sv_column_streaming.lua",
	"mc/block_update/sv_scheduler.lua",
	"mc/functional/sv_fire_block.lua",
	"mc/farming/sv_growth.lua",
	"mc/farming/sv_trampling.lua",
	"mc/redstone/sv_inputs.lua",
	"mc/liquid/sv_world_collision.lua",
	"mc/liquid/sv_water_state.lua",
	"mc/liquid/sv_water_spread.lua",
	"mc/liquid/sv_lava_state.lua",
	"mc/liquid/sv_lava_spread.lua",
	"mc/liquid/sv_water_cleanup.lua",
	"mc/import/sv_reader.lua",
	"mc/import/sv_decoder.lua",
	"mc/import/sv_world_sink.lua",
	"mc/import/sv_service.lua",
	"mc/import/sv_commands.lua",
	"mc/sv_config_ui.lua",
	"mc/sv_commands.lua",
	"mc/debug/sv_gallery.lua",
	"mc/sv_collision_carriers.lua",
	"mc/sv_chunk_store.lua",
	"mc/sv_saves.lua",
	"mc/workshop/sv_workshop.lua",
	"mc/sv_presets.lua",
	"mc/sv_block_cluster.lua",
	"mc/sv_damage.lua",
	"mc/explosion/sv_java_rays.lua",
	"mc/explosion/sv_trigger_handlers.lua",
	"mc/explosion/sv_trigger_explosion.lua",
	"mc/explosion/sv_block_explosion.lua",
	"mc/sv_lighting.lua",
	"mc/sv_player.lua",
	"mc/api/sv_api.lua",
	"mc/integration/sv_hand_weapon_bridge.lua",
}
local CLIENT_FILES = {
	"mc/cl_lighting.lua",
	"mc/render/cl_mesh_constants.lua",
	"mc/render/cl_render_pipeline.lua",
	"mc/render/cl_render_snapshot.lua",
	"mc/render/cl_render_vertex_buffer.lua",
	"mc/render/cl_render_light_buffer.lua",
	"mc/render/cl_render_geometry_store.lua",
	"mc/render/cl_render_material_abi.lua",
	"mc/render/cl_render_shader_registry.lua",
	"mc/render/cl_render_pack_schema.lua",
	"mc/render/cl_render_pack_registry.lua",
	"mc/render/cl_render_pack_discovery.lua",
	"mc/render/cl_render_pack_settings.lua",
	"mc/render/cl_render_block_bindings.lua",
	"mc/render/cl_mesh_cache.lua",
	"mc/render/cl_native_mesh_config.lua",
	"mc/render/cl_mesh_config.lua",
	"mc/render/cl_sky_column.lua",
	"mc/render/cl_sky_flood.lua",
	"mc/render/cl_mesh_gpu_light_texture.lua",
	"mc/render/cl_sun_shadow_sample.lua",
	"mc/render/cl_entity_lighting.lua",
	"mc/render/cl_atlas_profiles.lua",
	"mc/render/cl_mesh_materials.lua",
	"mc/render/cl_mesh_global_lightmap.lua",
	"mc/render/cl_mesh_light_samples.lua",
	"mc/render/cl_mesh_upload.lua",
	"mc/render/cl_mesh_color.lua",
	"mc/render/cl_mesh_geometry.lua",
	"mc/render/cl_fluid_geometry.lua",
	"mc/render/cl_render_visibility.lua",
	"mc/render/cl_render_section_cull.lua",
	"mc/render/cl_render_occlusion.lua",
	"mc/render/cl_mesh_build_context.lua",
	"mc/render/cl_mesh_emitters.lua",
	"mc/render/cl_mesh_builder.lua",
	"mc/render/cl_mesh_core.lua",
	"mc/render/cl_collision.lua",
	"mc/generated/sh_generated_state_lighting.lua",
	"mc/state/sh_state_lighting.lua",
	"mc/render/cl_render_l2_models.lua",
	"mc/render/cl_render_l2_snapshot.lua",
	"mc/render/cl_render_l2_lighting.lua",
	"mc/render/cl_render_l2_quad.lua",
	"mc/render/cl_render_l2_resources.lua",
	"mc/render/cl_render_sky.lua",
	"mc/render/cl_native_l2_backend.lua",
	"mc/render/cl_native_world_session.lua",
	"mc/render/cl_render_dynamic_lights.lua",
	"mc/render/cl_render_shadow_math.lua",
	"mc/render/cl_render_pbr.lua",
	"mc/render/cl_render_pbr_water.lua",
	"mc/render/cl_render_pack_processing.lua",
	"mc/render/cl_render_scene.lua",
	"mc/render/cl_render_pbr_ssr.lua",
	"mc/render/cl_render_pbr_post.lua",
	"mc/render/cl_render_pack_screen.lua",
	"mc/render/cl_render_pack_resources.lua",
	"mc/render/cl_render_pack_geometry.lua",
	"mc/render/cl_render_pack_runtime.lua",
	"mc/render/cl_render_atlas_audit.lua",
	"mc/render/cl_draw.lua",
	"mc/render/cl_render_pbr_shadows.lua",
	"mc/render/cl_dirty.lua",
	"mc/render/cl_mesh_presets.lua",
	"mc/cl_render.lua",
	"mc/render/cl_block_animations.lua",
	"mc/functional/cl_fire_campfires.lua",
	"mc/generated/cl_generated_bitmap_font.lua",
	"mc/generated/cl_generated_unifont_atlases.lua",
	"mc/render/cl_bitmap_font.lua",
	"mc/functional/cl_signs.lua",
	"mc/functional/cl_banners.lua",
	"mc/cl_texture_pack_manager.lua",
	"mc/render/cl_atlas_bake_plan.lua",
	"mc/render/cl_atlas_baker.lua",
	"mc/cl_texture_pack_ui.lua",
	"mc/cl_config_ui.lua",
	"mc/cl_ui.lua",
	"mc/cl_save_ui.lua",
	"mc/workshop/cl_workshop.lua",
	"mc/cl_presets.lua",
	"mc/cl_block_cluster.lua",
	"mc/cl_effects.lua",
	"mc/explosion/cl_explosion.lua",
	"mc/liquid/cl_effects.lua",
	"mc/cl_net.lua",
	"mc/state/cl_network_transport.lua",
	"mc/cl_commands.lua",
	"mc/cl_debug.lua",
	"mc/debug/cl_gallery.lua",
	"mc/cl_player.lua",
	"mc/integration/cl_hand_weapon_bridge.lua",
	-- The legacy L1 world backend remains unloaded; L2 uses cl_native_l2_backend.
	"mc/api/cl_api.lua",
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
	if resource and resource.AddFile then
		-- Engine assets only: anything the world still needs when no game layer
		-- is installed. Item icons, container GUI, HUD, mining cracks and their
		-- sounds ship with mcgame_load.lua instead. sound/mc/random stays here
		-- because it mixes block-break and engine-UI clips; the game layer may
		-- reference engine assets, never the other way round.
		for _, fileName in ipairs( {
			"materials/mc/atlas_365.png",
			"materials/mc/atlas_365.vmt",
			"materials/mc/atlas_365_translucent.png",
			"materials/mc/atlas_365_translucent.vmt",
			"materials/mc/atlas_365_programmer_art.png",
			"materials/mc/atlas_365_programmer_art.vmt",
			"materials/mc/atlas_365_programmer_art_translucent.png",
			"materials/mc/atlas_365_programmer_art_translucent.vmt",
		} ) do
			resource.AddFile( fileName )
		end
		for _, fileName in ipairs( file.Find( "materials/mc/font/*.png", "GAME" ) or {} ) do
			resource.AddFile( "materials/mc/font/" .. fileName )
		end
		for _, resourceRoot in ipairs( {
			"materials/mc/entity/chest",
			"materials/mc/entity/banner",
			"materials/mc/entity/boat",
			"materials/mc/entity/minecart",
			"materials/mc/particle",
			"materials/mc/animated/default",
			"materials/mc/animated/programmer_art",
		} ) do
			for _, fileName in ipairs( file.Find( resourceRoot .. "/*.png", "GAME" ) or {} ) do
				resource.AddFile( resourceRoot .. "/" .. fileName )
			end
		end
		for _, resourceRoot in ipairs( {
			"sound/mc/random",
			"sound/mc/fire",
			"sound/mc/block/campfire",
			"sound/mc/entity/boat",
			"sound/mc/entity/bobber",
			"sound/mc/minecart",
			"sound/mc/item/shield",
			"sound/mc/item/totem",
			"sound/mc/mob/sheep",
		} ) do
			for _, fileName in ipairs( file.Find( resourceRoot .. "/*.ogg", "GAME" ) or {} ) do
				resource.AddFile( resourceRoot .. "/" .. fileName )
			end
		end
	end
end

for _, f in ipairs( SHARED ) do includeTracked( f ) end

-- Pick the Lua L2 section layout before client modules cache its dimensions.
-- The native module supplies L2 construction and optional non-rendering APIs.
if CLIENT then
	MC.JoinNoticeEnabled = MC.JoinNoticeEnabled or CreateClientConVar(
		"mc_join_notice", "1", true, false,
		"Show the MCSWEP configuration hint after joining a server"
	)
	if not MC.JoinNoticeScheduled then
		MC.JoinNoticeScheduled = true
		timer.Simple( 4, function()
			if MC.JoinNoticeShown or not MC.JoinNoticeEnabled:GetBool() then return end
			MC.JoinNoticeShown = true
			if chat and chat.AddText then
				chat.AddText(
					Color( 80, 190, 255 ), "[MCSWEP] ",
					Color( 235, 235, 235 ), MC.T( "join.config_hint",
						"控制台输入 mc_config 打开配置界面，输入 mc_save_manager 打开存档管理器。" ),
					Color( 160, 255, 160 ), "  " .. MC.T( "join.config_hide_hint",
						"输入 mc_join_notice 0 关闭进服提示。" )
				)
			end
		end )
	end

	local NATIVE_MODULE_EXPORTS = {
		"Handshake", "SetAtlasPageMaterial", "SetBlockDefs", "SetLightDefs", "CreateChunk", "ApplyChunk", "SetCellsBatch",
		"SetCell", "GetCell", "GetChunkCells", "Think", "DrawChunk", "UnloadChunk",
		"ClearWorld", "Shutdown", "GetStats", "StartBlockLightRebuild",
		"PollBlockLightRebuild", "CancelBlockLightRebuild", "RebuildBlockLight", "GetBlockLightChunk", "GetSkyLightChunk",
		"BindLightAtlasMaterial", "GetLightAtlasStats", "GetLightAtlasSlot",
		"DrawVisible", "SetChunkVisible", "SetSimpleGreedy", "SetDirectionalDraw", "SetOcclusionCull", "SetLod",
	}
	MC.NativeMeshABI = 8
	local NATIVE_MODULE_URL = "https://github.com/ABSD546316187/mcswep_native_mesh/releases"

	local function expectedNativeModulePath()
		if not ( system and system.IsWindows and system.IsWindows() ) then return nil end
		local arch = jit and jit.arch or nil
		if arch == "x64" then return "lua/bin/gmcl_mcswep_native_mesh_win64.dll" end
		if arch == "x86" then return "lua/bin/gmcl_mcswep_native_mesh_win32.dll" end
		return nil
	end

	function MC.ProbeNativeMeshModule()
		if MC.NativeMeshModuleProbeDone == true then
			return MC.NativeMeshModuleAvailable == true
		end

		local modulePath = expectedNativeModulePath()
		MC.NativeMeshModulePath = modulePath
		local modulePresent = istable( mcmesh ) and isfunction( mcmesh.AbiVersion )
		local loaded, loadError = modulePresent, nil
		if not modulePresent then
			if not modulePath then
				MC.NativeMeshModuleProbeDone = true
				MC.NativeMeshModuleAvailable = false
				MC.NativeMeshModuleMissing = false
				MC.NativeMeshModuleABI = nil
				MC.NativeMeshModuleExpectedABI = MC.NativeMeshABI
				MC.NativeMeshModuleOutdated = false
				MC.NativeMeshModuleFailureReason = "unsupported native module platform or architecture"
				return false
			end
			modulePresent = file and file.Exists and file.Exists( modulePath, "GAME" ) == true
			if not modulePresent then
				MC.NativeMeshModuleProbeDone = true
				MC.NativeMeshModuleAvailable = false
				MC.NativeMeshModuleMissing = true
				MC.NativeMeshModuleABI = nil
				MC.NativeMeshModuleExpectedABI = MC.NativeMeshABI
				MC.NativeMeshModuleOutdated = false
				MC.NativeMeshModuleFailureReason = "module not installed: " .. modulePath
				return false
			end
			loaded, loadError = pcall( require, "mcswep_native_mesh" )
		end

		local usable = loaded and istable( mcmesh ) and isfunction( mcmesh.AbiVersion )
		local failureReason
		local moduleABI
		if usable then failureReason = nil
		elseif loadError ~= nil then failureReason = tostring( loadError )
		elseif mcmesh ~= nil then failureReason = "invalid module table (type=" .. tostring( type( mcmesh ) ) .. ")"
		else failureReason = "module did not publish mcmesh"
		end
		if usable then
			local abiOK, abi = pcall( mcmesh.AbiVersion )
			moduleABI = abiOK and tonumber( abi ) or nil
			usable = moduleABI == MC.NativeMeshABI
			if not usable then
				failureReason = "ABI mismatch (module " .. tostring( moduleABI or abi )
					.. ", required " .. MC.NativeMeshABI .. ")"
			end
		end
		if usable then
			for _, name in ipairs( NATIVE_MODULE_EXPORTS ) do
				if not isfunction( mcmesh[name] ) then
					usable = false
					failureReason = "missing export " .. name
					break
				end
			end
		end

		MC.NativeMeshModuleProbeDone = true
		MC.NativeMeshModuleAvailable = usable
		MC.NativeMeshModuleMissing = false
		MC.NativeMeshModuleABI = moduleABI
		MC.NativeMeshModuleExpectedABI = MC.NativeMeshABI
		MC.NativeMeshModuleOutdated = moduleABI ~= nil and moduleABI < MC.NativeMeshABI
		MC.NativeMeshModuleFailureReason = usable and nil or failureReason
		return usable
	end

	MC.ProbeNativeMeshModule()
	local nativeMissing = MC.NativeMeshModuleMissing == true
	local nativeOutdated = MC.NativeMeshModuleOutdated == true
	MC.RENDER_SECTION_SIZE = 8
	MsgN( "[MC] render section size = " .. MC.RENDER_SECTION_SIZE
		.. " (Lua L2)" )

	if ( nativeMissing or nativeOutdated ) and not MC.NativeMeshInstallNoticeScheduled then
		MC.NativeMeshInstallNoticeScheduled = true
		local nativeURL = NATIVE_MODULE_URL
		timer.Simple( 1, function()
			if MC.NativeMeshInstallNoticeShown then return end
			MC.NativeMeshInstallNoticeShown = true
			if chat and chat.AddText then
				if nativeOutdated then
					chat.AddText(
						Color( 80, 190, 255 ), "[MCSWEP] ",
						Color( 255, 120, 90 ), MC.T( "native.dll_outdated",
							"Native DLL 版本过期（当前 ABI {actual}，需要 ABI {required}），当前使用 Lua 后端。下载地址：", {
								actual = tostring( MC.NativeMeshModuleABI or "?" ),
								required = tostring( MC.NativeMeshABI ),
							} ),
						Color( 130, 210, 255 ), nativeURL
					)
				else
					chat.AddText(
						Color( 80, 190, 255 ), "[MCSWEP] ",
						Color( 255, 210, 90 ), MC.T( "native.dll_missing",
							"未检测到优化DLL，当前使用 Lua 后端。 下载地址：" ),
						Color( 130, 210, 255 ), nativeURL,
						Color( 160, 255, 160 ), MC.T( "native.dll_open_hint",
							"(推荐下载)" )
					)
				end
			end
			local consoleKey = nativeOutdated and "native.dll_outdated_console" or "native.dll_console"
			local consoleFallback = nativeOutdated
				and "Native DLL 版本过期（当前 ABI {actual}，需要 ABI {required}）。下载地址: {url}"
				or "Native DLL 下载地址: {url}"
			MsgN( "[MCSWEP] " .. MC.T( consoleKey, consoleFallback, {
				actual = tostring( MC.NativeMeshModuleABI or "?" ),
				required = tostring( MC.NativeMeshABI ),
				url = nativeURL,
			} ) )
		end )
		concommand.Add( "mc_native_download", function()
			if gui and gui.OpenURL then gui.OpenURL( nativeURL ) end
		end, nil, MC.T( "native.dll_command_help", "打开 MCSWEP Native DLL 的 GitHub 页面" ) )
	end
end

if SERVER then
	for _, f in ipairs( SERVER_FILES ) do includeTracked( f ) end
else
	for _, f in ipairs( CLIENT_FILES ) do includeTracked( f ) end

	-- Both builders publish L2 records. Native retains the section scheduler and
	-- Lua state store while accelerating corner lighting and indexed Source uploads.
	MC.MeshBackends = MC.MeshBackends or {}
	MC.MeshBackends.lua = {
		name = "lua",
		native = false,
		layout = "mc:quad_corners_v1",
		IsActive = function() return true end,
		BuildChunkMesh = MC.BuildChunkMesh,
		RebuildChunkMeshLighting = MC.RebuildChunkMeshLighting,
		FreeChunkMesh = MC.FreeChunkMesh,
	}
	MC.MeshBackends.native_l2 = {
		name = "native_l2", native = true, async = false, layout = "mc:quad_corners_v1",
		IsActive = MC.NativeL2.IsActive,
		BuildChunkMesh = MC.BuildChunkMesh,
		RebuildChunkMeshLighting = MC.RebuildChunkMeshLighting,
		FreeChunkMesh = MC.FreeChunkMesh,
	}
	function MC.RegisterMeshBackend( name, backend )
		if not isstring( name ) or name == "" or not istable( backend ) then return false end
		backend.name = name
		MC.MeshBackends[name] = backend
		return true
	end
	function MC.GetMeshBackend()
		if MC.NativeL2.IsActive() then return MC.MeshBackends.native_l2 end
		return MC.MeshBackends.lua
	end
	function MC.BuildChunkMesh( ... )
		local backend = MC.GetMeshBackend()
		return backend.BuildChunkMesh( ... )
	end
	function MC.RebuildChunkMeshLighting( ... )
		local backend = MC.GetMeshBackend()
		local fn = backend.RebuildChunkMeshLighting or backend.BuildChunkMesh
		return fn( ... )
	end
	function MC.FreeChunkMesh( ... )
		local backend = MC.GetMeshBackend()
		return backend.FreeChunkMesh( ... )
	end
end

local loadPerfEndKB = collectgarbage and collectgarbage( "count" ) or loadPerfStartKB
MC.LoadPerfStats.totalMS = math.Round( ( ( SysTime and SysTime() or loadPerfStart ) - loadPerfStart ) * 1000, 3 )
MC.LoadPerfStats.totalMemoryKB = math.Round( loadPerfEndKB - loadPerfStartKB, 3 )

function MC.GeneratedRuntimeDiagnostics()
	local chunkBackend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	local meshBackend = CLIENT and MC.GetMeshBackend and MC.GetMeshBackend() or nil
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
		renderSectionSize = MC.RENDER_SECTION_SIZE or 8,
		nativeModuleAvailable = MC.NativeMeshModuleAvailable == true,
		chunkBackend = chunkBackend and chunkBackend.name or "lua",
		meshBackend = meshBackend and meshBackend.name or "lua",
	}
end

-- Public API lifecycle. The register phase fires synchronously while the block/
-- state registries are still open (external addons register custom content
-- here). The freeze happens on the zero-delay timers scheduled during include
-- (sh_block_states.lua), so queuing the ready signal now runs it after them.
-- Both phases replay for late subscribers via API.OnRegister / API.OnReady,
-- which is what makes a separately shipped addon immune to autorun order.
if MC.API and MC.API._FireAvailable then MC.API._FireAvailable() end
-- Creative metadata and optional consumer registries freeze at one shared
-- boundary.  The extra zero-delay hop is intentional: a separately mounted
-- addon may load after this file and still register its finalizer during the
-- same bootstrap tick, before MC.APIReady is announced.
if MC.API and MC.API._RunFreezeCallbacks then timer.Simple( 0, function()
	local manifestOK, manifestError = true, nil
	if MC.API._FireManifestEntrypoints then
		manifestOK, manifestError = MC.API._FireManifestEntrypoints()
	end
	if not manifestOK then
		local message = "[MC] manifest bootstrap failed: " .. tostring( manifestError or "unknown" ) .. "\n"
		if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		return
	end
	local freezeOK, freezeError = MC.API._RunFreezeCallbacks()
	if not freezeOK then
		local message = "[MC] registry bootstrap freeze failed: " .. tostring( freezeError or "unknown" ) .. "\n"
		if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		return
	end
	if MC.FinalizeModCreativeRegistry and not MC.ModCreativeRegistryFrozen then
		MC.FinalizeModCreativeRegistry()
		MC.ModBlockRegistryFrozen = true
		if MC.RunEvent then MC.RunEvent( "MC.ModCreativeRegistryReady", MC.API and MC.API.ModRegistryVersion or "1.0" ) end
	end
	if MC.API and MC.API._FireReady then timer.Simple( 0, MC.API._FireReady ) end
end )
elseif MC.FinalizeModCreativeRegistry then timer.Simple( 0, function()
	if not MC.ModCreativeRegistryFrozen then
		MC.FinalizeModCreativeRegistry()
		MC.ModBlockRegistryFrozen = true
		if MC.RunEvent then MC.RunEvent( "MC.ModCreativeRegistryReady", MC.API and MC.API.ModRegistryVersion or "1.0" ) end
	end
	if MC.API and MC.API._FireReady then timer.Simple( 0, MC.API._FireReady ) end
end )
elseif MC.API and MC.API._FireReady then
	timer.Simple( 0, MC.API._FireReady )
end

MsgN( "[MC] Voxel block addon loaded (" .. ( SERVER and "server" or "client" ) .. ")" )
