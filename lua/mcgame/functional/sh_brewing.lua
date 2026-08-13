MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.brewing = MC.BlockHandlers.brewing or {
	OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.OpenBrewingStand then return false end
		return MC.SV.OpenBrewingStand( ply, bx, by, bz ) == true
	end,
	OnRemoved = function( context )
		if SERVER and MC.SV and MC.SV.DropBrewingContents then
			MC.SV.DropBrewingContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
	OnReplaced = function( context )
		if SERVER and MC.SV and MC.SV.DropBrewingContents then
			MC.SV.DropBrewingContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
		end
	end,
}
