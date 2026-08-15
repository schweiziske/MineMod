--[[----------------------------------------------------------------------------
	MCSWEP game layer loader (survival: items, inventory, recipes, mining,
	containers).

	This layer is a CONSUMER of the MCSWEP voxel engine, not part of it. The
	engine owns the world - blocks, states, streaming, rendering, collision,
	lighting, liquids, redstone and block updates - and knows nothing about
	items. Everything here sits on top of that through MC.API and the engine
	registries.

	This is a separate addon that consumes the MCSWEP voxel engine:

	  * every file is included from the engine's register phase, never at file
	    scope, so "engine is loaded" is a structural guarantee instead of a
	    hand-maintained ordering in a shared list;
	  * MC.API.OnRegister replays for late subscribers, which covers "engine
	    already loaded"; the hook covers "engine loads after us". Both Garry's
	    Mod autorun orders therefore work;
	  * AddCSLuaFile and resource.AddFile run at file scope because they do not
	    need the engine, and each layer ships exactly its own files.

	Registration (items, recipes, block entity types, block handlers) must
	happen in the register phase: the engine freezes its block/state registries
	on a zero-delay timer, i.e. after every autorun file in this load tick.
------------------------------------------------------------------------------]]

MC = MC or {}

local REQUIRED_API_VERSION = 1

local SHARED = {
	"mcgame/functional/sh_furnace.lua",
	"mcgame/functional/sh_brewing.lua",
	"mcgame/functional/sh_anvil.lua",
	"mcgame/functional/sh_campfire.lua",
	"mcgame/functional/sh_tnt.lua",
	"mcgame/item/sh_registry.lua",
	"mcgame/generated/sh_generated_items.lua",
	"mcgame/vehicle/sh_vehicles.lua",
	"mcgame/item/sh_model_registry.lua",
	"mcgame/generated/sh_generated_item_models.lua",
	"mcgame/generated/sh_generated_item_sprite_masks.lua",
	"mcgame/generated/sh_generated_creative_tabs.lua",
	"mcgame/item/sh_stack.lua",
	"mcgame/item/sh_potion_contents.lua",
	"mcgame/item/sh_definition.lua",
	"mcgame/item/sh_behavior.lua",
	"mcgame/item/sh_equipment.lua",
	"mcgame/mining/sh_targeting.lua",
	"mcgame/item/sh_projectile_defs.lua",
	"mcgame/item/sh_codec.lua",
	"mcgame/inventory/sh_creative_stacks.lua",
	"mcgame/recipe/sh_registry.lua",
	"mcgame/generated/sh_generated_recipes.lua",
	"mcgame/recipe/sh_book.lua",
	"mcgame/inventory/sh_slot.lua",
	"mcgame/inventory/sh_container.lua",
	"mcgame/inventory/sh_click.lua",
	"mcgame/inventory/sh_crafting.lua",
	"mcgame/inventory/sh_anvil.lua",
	"mcgame/item/sh_public_api.lua",
	"mcgame/functional/sh_furnace_data.lua",
	"mcgame/functional/sh_brewing_data.lua",
	"mcgame/functional/sh_chest_data.lua",
	"mcgame/functional/sh_campfire_data.lua",
	"mcgame/functional/sh_chests.lua",
	"mcgame/functional/sh_crafting.lua",
}
local SERVER_FILES = {
	"mcgame/inventory/sv_player_inventory.lua",
	"mcgame/inventory/sv_hand_weapon_presentation.lua",
	"mcgame/inventory/sv_selected_mutation.lua",
	"mcgame/inventory/sv_equipment.lua",
	"mcgame/inventory/sv_item_durability.lua",
	"mcgame/inventory/sv_item_use.lua",
	"mcgame/inventory/sv_item_drops.lua",
	"mcgame/inventory/sv_fire.lua",
	"mcgame/inventory/sv_shears.lua",
	"mcgame/inventory/sv_campfires.lua",
	"mcgame/inventory/sv_tnt.lua",
	"mcgame/generated/sv_generated_block_loot.lua",
	"mcgame/mining/sv_block_loot.lua",
	"mcgame/mining/sv_block_update_drops.lua",
	"mcgame/mining/sv_mining.lua",
	"mcgame/inventory/sv_projectiles.lua",
	"mcgame/inventory/sv_combat.lua",
	"mcgame/explosion/sv_gameplay.lua",
	"mcgame/inventory/sv_furnaces.lua",
	"mcgame/inventory/sv_brewing.lua",
	"mcgame/inventory/sv_chests.lua",
	"mcgame/inventory/sv_crafting.lua",
	"mcgame/inventory/sv_anvil.lua",
	"mcgame/inventory/sv_network.lua",
}
local CLIENT_FILES = {
	"mcgame/mining/cl_mining.lua",
	"mcgame/mining/cl_hand_swing.lua",
	"mcgame/functional/cl_chests.lua",
	"mcgame/functional/cl_campfires.lua",
	"mcgame/inventory/cl_state.lua",
	"mcgame/inventory/cl_network.lua",
	"mcgame/inventory/cl_anvil.lua",
	"mcgame/inventory/cl_furnaces.lua",
	"mcgame/inventory/cl_brewing.lua",
	"mcgame/inventory/ui/cl_theme.lua",
	"mcgame/item/cl_model_resolver.lua",
	"mcgame/inventory/ui/cl_entry.lua",
	"mcgame/inventory/ui/cl_item_renderer.lua",
	"mcgame/inventory/ui/cl_tooltip.lua",
	"mcgame/inventory/ui/cl_effects.lua",
	"mcgame/inventory/ui/cl_slot.lua",
	"mcgame/inventory/ui/cl_drag.lua",
	"mcgame/inventory/ui/cl_recipe_book.lua",
	"mcgame/inventory/ui/cl_inventory_screen.lua",
	"mcgame/inventory/ui/cl_hotbar.lua",
}

-- Neither of these needs the engine, so they stay at file scope: the client
-- download list must be complete regardless of which autorun ran first.
if SERVER then
	AddCSLuaFile()
	for _, f in ipairs( SHARED ) do AddCSLuaFile( f ) end
	for _, f in ipairs( CLIENT_FILES ) do AddCSLuaFile( f ) end
	if resource and resource.AddFile then
		-- Game-layer assets only: item icons, container/HUD interface, recipe
		-- book, mining cracks and the sounds those play. The world renders
		-- without any of them.
		for _, fileName in ipairs( {
			"materials/mc/gui/recipe_book.png",
			"materials/mc/misc/enchanted_glint_item.png",
		} ) do
			resource.AddFile( fileName )
		end
		for _, fileName in ipairs( file.Find( "materials/mc/item/*.png", "GAME" ) or {} ) do
			resource.AddFile( "materials/mc/item/" .. fileName )
		end
		for _, fileName in ipairs( file.Find( "materials/mc/block/destroy_stage_*.png", "GAME" ) or {} ) do
			resource.AddFile( "materials/mc/block/" .. fileName )
		end
		for _, resourceRoot in ipairs( {
			"materials/mc/gui/container",
			"materials/mc/gui/container/creative_inventory",
			"materials/mc/gui/hud",
			"materials/mc/gui/sprites/container",
			"materials/mc/gui/sprites/container/furnace",
			"materials/mc/gui/sprites/container/creative_inventory",
			"materials/mc/gui/sprites/hud",
			"materials/mc/gui/sprites/container/inventory",
			"materials/mc/gui/mob_effect",
			"materials/mc/gui/sprites/recipe_book",
		} ) do
			for _, fileName in ipairs( file.Find( resourceRoot .. "/*.png", "GAME" ) or {} ) do
				resource.AddFile( resourceRoot .. "/" .. fileName )
			end
		end
		for _, resourceRoot in ipairs( {
			"sound/mc/block/chest",
			"sound/mc/item/book",
		} ) do
			for _, fileName in ipairs( file.Find( resourceRoot .. "/*.ogg", "GAME" ) or {} ) do
				resource.AddFile( resourceRoot .. "/" .. fileName )
			end
		end
	end
end

MC.GameLayerLoaded = MC.GameLayerLoaded == true

local function loadGameLayer()
	if MC.GameLayerLoaded then return end
	local api = MC and MC.API
	if not api then
		ErrorNoHalt( "[MCGame] MCSWEP engine is missing; the game layer will not load\n" )
		return
	end
	if api.Require and not api.Require( REQUIRED_API_VERSION, "MCSWEP game layer" ) then return end
	MC.GameLayerLoaded = true

	for _, f in ipairs( SHARED ) do include( f ) end
	if SERVER then
		for _, f in ipairs( SERVER_FILES ) do include( f ) end
	else
		for _, f in ipairs( CLIENT_FILES ) do include( f ) end
	end

	MsgN( "[MCGame] survival game layer loaded (" .. ( SERVER and "server" or "client" ) .. ")" )
end

-- OnRegister covers "the engine already loaded and fired"; the hook covers
-- "the engine loads after this file". Exactly one of them runs the load.
if MC.API and MC.API.OnRegister then
	MC.API.OnRegister( loadGameLayer )
else
	hook.Add( "MC.APIAvailable", "mcgame_bootstrap", loadGameLayer )
end

-- The engine may simply not be installed. Report that once instead of leaving
-- a server silently without items.
timer.Simple( 0, function()
	if MC.GameLayerLoaded then return end
	ErrorNoHalt( "[MCGame] MCSWEP engine never announced itself; the game layer did not load\n" )
end )
