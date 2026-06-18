--[[----------------------------------------------------------------------------
	MC - Minecraft-style voxel blocks for Garry's Mod
	Loader. Runs shared on server, is sent to and runs on clients.

	Design goal: NO per-block entities. Blocks live in a chunked voxel store and
	are drawn with IMesh (1 draw call per 16x16x32 chunk). One physics entity per
	non-empty chunk provides collision. So ~8192 blocks == 1 entity.
------------------------------------------------------------------------------]]

MC = MC or {}

local SHARED = {
	"mc/sh_config.lua",
	"mc/sh_i18n.lua",
	"mc/generated/sh_generated_tiles.lua",
	"mc/generated/sh_generated_blocks.lua",
	"mc/generated/sh_generated_block_connections.lua",
	"mc/generated/sh_generated_block_properties.lua",
	"mc/generated/sh_generated_block_light.lua",
	"mc/generated/sh_generated_block_collision.lua",
	"mc/generated/sh_generated_sound_types.lua",
	"mc/generated/sh_generated_lang.lua",
	"mc/generated/sh_generated_mcswep_blocks.lua",
	"mc/functional/sh_furnace.lua",
	"mc/functional/sh_doors.lua",
	"mc/functional/sh_trapdoors.lua",
	"mc/functional/sh_ladders.lua",
	"mc/functional/sh_liquids.lua",
	"mc/custom/sh_custom_blocks.lua",
	"mc/sh_blocks.lua",
	"mc/sh_presets.lua",
	"mc/sh_player.lua",
	"mc/sh_voxel.lua",
	"mc/sh_multiblock.lua",
}
local SERVER_FILES = {
	"mc/sv_world.lua",
	"mc/sv_commands.lua",
	"mc/sv_chunk_store.lua",
	"mc/sv_saves.lua",
	"mc/sv_presets.lua",
	"mc/sv_damage.lua",
	"mc/sv_player.lua",
}
local CLIENT_FILES = {
	"mc/cl_lighting.lua",
	"mc/cl_render.lua",
	"mc/cl_ui.lua",
	"mc/cl_save_ui.lua",
	"mc/cl_presets.lua",
	"mc/cl_effects.lua",
	"mc/cl_net.lua",
	"mc/cl_commands.lua",
	"mc/cl_debug.lua",
	"mc/cl_player.lua",
}

if SERVER then
	AddCSLuaFile()
	for _, f in ipairs( SHARED ) do AddCSLuaFile( f ) end
	for _, f in ipairs( CLIENT_FILES ) do AddCSLuaFile( f ) end
end

for _, f in ipairs( SHARED ) do include( f ) end

if SERVER then
	for _, f in ipairs( SERVER_FILES ) do include( f ) end
else
	for _, f in ipairs( CLIENT_FILES ) do include( f ) end
end

MsgN( "[MC] Voxel block addon loaded (" .. ( SERVER and "server" or "client" ) .. ")" )
