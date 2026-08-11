MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.furnace = MC.BlockHandlers.furnace or {
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
