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
	"mc/workshop/sh_workshop_bundle.lua",
	"mc/sh_world_adapter.lua",
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
	"mc/functional/sh_fence_gates.lua",
	"mc/functional/sh_ladders.lua",
	"mc/liquid/sh_registry.lua",
	"mc/liquid/sh_shapes.lua",
	"mc/liquid/sh_flow.lua",
	"mc/liquid/sh_contact.lua",
	"mc/liquid/sh_movement.lua",
	"mc/custom/sh_custom_blocks.lua",
	"mc/sh_blocks.lua",
	"mc/item/sh_registry.lua",
	"mc/generated/sh_generated_items.lua",
	"mc/item/sh_model_registry.lua",
	"mc/generated/sh_generated_item_models.lua",
	"mc/generated/sh_generated_creative_tabs.lua",
	"mc/item/sh_stack.lua",
	"mc/item/sh_definition.lua",
	"mc/item/sh_behavior.lua",
	"mc/item/sh_equipment.lua",
	"mc/item/sh_projectile_defs.lua",
	"mc/item/sh_codec.lua",
	"mc/recipe/sh_registry.lua",
	"mc/generated/sh_generated_recipes.lua",
	"mc/recipe/sh_book.lua",
	"mc/inventory/sh_slot.lua",
	"mc/inventory/sh_container.lua",
	"mc/inventory/sh_click.lua",
	"mc/inventory/sh_crafting.lua",
	"mc/generated/sh_generated_mcswep_blocks.lua",
	"mc/sh_block_states.lua",
	"mc/block_entity/sh_registry.lua",
	"mc/functional/sh_chest_data.lua",
	"mc/functional/sh_chests.lua",
	"mc/functional/sh_crafting.lua",
	"mc/block_update/sh_registry.lua",
	"mc/state/sh_project_block_state_schemas.lua",
	"mc/state/sh_state_collision.lua",
	"mc/state/sh_state_visuals.lua",
	"mc/state/sh_state_tints.lua",
	"mc/import/sh_format.lua",
	"mc/functional/sh_signs.lua",
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
}
local SERVER_FILES = {
	"mc/sv_world.lua",
	"mc/creative/sv_state_selection.lua",
	"mc/state/sv_save_codec.lua",
	"mc/state/sv_region_save.lua",
	"mc/state/sv_region_persistence.lua",
	"mc/state/sv_network_transport.lua",
	"mc/state/sv_block_transaction.lua",
	"mc/state/sv_column_streaming.lua",
	"mc/block_update/sv_scheduler.lua",
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
	"mc/sv_lighting.lua",
	"mc/sv_player.lua",
	"mc/inventory/sv_player_inventory.lua",
	"mc/inventory/sv_equipment.lua",
	"mc/inventory/sv_item_durability.lua",
	"mc/inventory/sv_item_use.lua",
	"mc/inventory/sv_item_drops.lua",
	"mc/inventory/sv_projectiles.lua",
	"mc/inventory/sv_combat.lua",
	"mc/inventory/sv_chests.lua",
	"mc/inventory/sv_crafting.lua",
	"mc/inventory/sv_network.lua",
	"mc/api/sv_api.lua",
}
local CLIENT_FILES = {
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
	"mc/render/cl_entity_lighting.lua",
	"mc/render/cl_mesh_materials.lua",
	"mc/render/cl_mesh_global_lightmap.lua",
	"mc/render/cl_mesh_light_samples.lua",
	"mc/render/cl_mesh_upload.lua",
	"mc/render/cl_mesh_source_lighting.lua",
	"mc/render/cl_mesh_color.lua",
	"mc/render/cl_mesh_geometry.lua",
	"mc/render/cl_fluid_geometry.lua",
	"mc/render/cl_mesh_build_context.lua",
	"mc/render/cl_mesh_emitters.lua",
	"mc/render/cl_mesh_builder.lua",
	"mc/render/cl_mesh_core.lua",
	"mc/render/cl_collision.lua",
	"mc/render/cl_draw.lua",
	"mc/render/cl_mesh_bloom.lua",
	"mc/render/cl_dirty.lua",
	"mc/cl_render.lua",
	"mc/functional/cl_signs.lua",
	"mc/cl_config_ui.lua",
	"mc/cl_ui.lua",
	"mc/cl_save_ui.lua",
	"mc/workshop/cl_workshop.lua",
	"mc/cl_presets.lua",
	"mc/cl_block_cluster.lua",
	"mc/cl_effects.lua",
	"mc/liquid/cl_effects.lua",
	"mc/cl_net.lua",
	"mc/state/cl_network_transport.lua",
	"mc/cl_commands.lua",
	"mc/cl_debug.lua",
	"mc/debug/cl_gallery.lua",
	"mc/cl_light_bench.lua",
	"mc/cl_player.lua",
	"mc/inventory/cl_state.lua",
	"mc/inventory/cl_network.lua",
	"mc/inventory/ui/cl_theme.lua",
	"mc/item/cl_model_resolver.lua",
	"mc/inventory/ui/cl_entry.lua",
	"mc/inventory/ui/cl_item_renderer.lua",
	"mc/inventory/ui/cl_tooltip.lua",
	"mc/inventory/ui/cl_slot.lua",
	"mc/inventory/ui/cl_drag.lua",
	"mc/inventory/ui/cl_recipe_book.lua",
	"mc/inventory/ui/cl_inventory_screen.lua",
	"mc/inventory/ui/cl_hotbar.lua",
	"mc/render/cl_native_mesh_backend.lua",
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
		for _, fileName in ipairs( {
			"materials/mc/atlas_365.png",
			"materials/mc/atlas_365.vmt",
			"materials/mc/atlas_365_translucent.png",
			"materials/mc/atlas_365_translucent.vmt",
			"materials/mc/atlas_365_programmer_art.png",
			"materials/mc/atlas_365_programmer_art.vmt",
			"materials/mc/atlas_365_programmer_art_translucent.png",
			"materials/mc/atlas_365_programmer_art_translucent.vmt",
			"materials/mc/gui/recipe_book.png",
		} ) do
			resource.AddFile( fileName )
		end
		for _, fileName in ipairs( file.Find( "materials/mc/item/*.png", "GAME" ) or {} ) do
			resource.AddFile( "materials/mc/item/" .. fileName )
		end
		for _, fileName in ipairs( file.Find( "materials/mc/font/*.png", "GAME" ) or {} ) do
			resource.AddFile( "materials/mc/font/" .. fileName )
		end
		for _, resourceRoot in ipairs( {
			"materials/mc/gui/container",
			"materials/mc/gui/container/creative_inventory",
			"materials/mc/gui/hud",
			"materials/mc/gui/sprites/container",
			"materials/mc/gui/sprites/container/creative_inventory",
			"materials/mc/gui/sprites/recipe_book",
		} ) do
			for _, fileName in ipairs( file.Find( resourceRoot .. "/*.png", "GAME" ) or {} ) do
				resource.AddFile( resourceRoot .. "/" .. fileName )
			end
		end
	end
end

for _, f in ipairs( SHARED ) do includeTracked( f ) end

-- Pick one render-section layout before any client render module caches its
-- derived section counts.  A native module that cannot actually be loaded is
-- treated the same as a missing DLL so the pure-Lua backend keeps its smaller
-- 8^3 update granularity.
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
		"Handshake", "SetBlockDefs", "SetLightDefs", "CreateChunk", "ApplyChunk", "SetCellsBatch",
		"SetCell", "GetCell", "GetChunkCells", "Think", "DrawChunk", "UnloadChunk",
		"ClearWorld", "Shutdown", "GetStats", "StartBlockLightRebuild",
		"PollBlockLightRebuild", "CancelBlockLightRebuild", "RebuildBlockLight", "GetBlockLightChunk", "GetSkyLightChunk",
		"BindLightAtlasMaterial", "GetLightAtlasStats", "GetLightAtlasSlot",
		"DrawVisible", "SetChunkVisible", "SetSimpleGreedy", "SetDirectionalDraw", "SetOcclusionCull", "SetLod",
	}
	MC.NativeMeshABI = 7
	local NATIVE_MODULE_URL = "https://github.com/schweiziske/mc_swep"

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

	local nativeUsable = MC.ProbeNativeMeshModule()
	local nativeMissing = MC.NativeMeshModuleMissing == true
	local nativeOutdated = MC.NativeMeshModuleOutdated == true
	MC.RENDER_SECTION_SIZE = nativeUsable and 16 or 8
	MsgN( "[MC] render section size = " .. MC.RENDER_SECTION_SIZE
		.. ( nativeUsable and " (native module)" or " (Lua fallback)" ) )

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

	-- Formal mesh backend dispatch.  Public MC mesh functions remain stable;
	-- optional backends register implementations instead of monkey-patching the
	-- mother addon at runtime.  The Lua implementation is always the fallback.
	MC.MeshBackends = MC.MeshBackends or {}
	MC.MeshBackends.lua = {
		name = "lua",
		native = false,
		IsActive = function() return true end,
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
		local native = MC.MeshBackends and MC.MeshBackends.native
		if native and native.IsActive and native.IsActive() then return native end
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

-- Public API lifecycle. MC.APIAvailable fires synchronously while the block/
-- state registries are still open (external addons register custom content
-- here). The freeze happens on the zero-delay timers scheduled during include
-- (sh_block_states.lua), so queuing the ready signal now runs it after them.
if MC.RunEvent then MC.RunEvent( "MC.APIAvailable", MC.API and MC.API.VERSION or 0 ) end
if MC.API and MC.API._FireReady then timer.Simple( 0, MC.API._FireReady ) end

MsgN( "[MC] Voxel block addon loaded (" .. ( SERVER and "server" or "client" ) .. ")" )
