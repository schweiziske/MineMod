MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

local HANDLERS = {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenFurnace then return false end
		return MC.SV.OpenFurnace( ply, bx, by, bz ) == true
	end,
	OnRemoved = function( context )
		if SERVER and MC.SV and MC.SV.DropFurnaceContents then
			MC.SV.DropFurnaceContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
	OnReplaced = function( context )
		if SERVER and MC.SV and MC.SV.DropFurnaceContents then
			MC.SV.DropFurnaceContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
}

if Blocks then
	Blocks.SetHandlers( "minecraft:furnace", HANDLERS )
	Blocks.SetHandlers( "minecraft:blast_furnace", HANDLERS )
end
