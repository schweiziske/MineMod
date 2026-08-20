-- Feature-gated block use/lifecycle bindings for logistics containers.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks
local L = MC.LogisticsParity or {}
local NAMES = { "minecraft:hopper", "minecraft:dispenser", "minecraft:dropper" }

local HANDLERS = {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not L.Enabled() or not MC.SV or not MC.SV.OpenLogisticsContainer then return false end
		return MC.SV.OpenLogisticsContainer( ply, bx, by, bz ) == true
	end,
	OnRemoved = function( context )
		if SERVER and L.Enabled() and MC.SV and MC.SV.DropLogisticsContents then
			MC.SV.DropLogisticsContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
	OnReplaced = function( context )
		if SERVER and L.Enabled() and MC.SV and MC.SV.DropLogisticsContents then
			MC.SV.DropLogisticsContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
}

function L.RefreshBlockHandlers()
	if not Blocks or not Blocks.SetHandlers then return false end
	local enabled = L.Enabled()
	if not enabled and L.BlockHandlersInstalled ~= true then return true end
	for _, name in ipairs( NAMES ) do
		Blocks.SetHandlers( name, enabled and HANDLERS or {
			OnUse = false, OnRemoved = false, OnReplaced = false,
		} )
	end
	L.BlockHandlersInstalled = enabled
	return true
end

L.RefreshBlockHandlers()

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_gameplay_parity_logistics", function()
		if timer and timer.Simple then timer.Simple( 0, L.RefreshBlockHandlers ) else L.RefreshBlockHandlers() end
	end, "mcgame_logistics_block_handlers" )
end
