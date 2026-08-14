-- Shared campfire interaction/lifecycle binding.

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

local function dropContents( context )
	if SERVER and MC.SV and MC.SV.DropCampfireContents then
		MC.SV.DropCampfireContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
	end
end

local function isShovel( stack )
	local spec = stack and MC.ItemToolSpec and MC.ItemToolSpec( stack ) or nil
	return spec and spec.type == "shovel" or false
end

MC.BlockHandlers.campfire = MC.BlockHandlers.campfire or {
	CanUse = function( stack )
		return isShovel( stack ) or stack ~= nil and MC.FindCookingRecipe ~= nil
			and MC.FindCookingRecipe( stack, "minecraft:campfire_cooking" ) ~= nil
	end,
	OnUse = function( ply, bx, by, bz )
		if CLIENT then return true end
		if not MC.SV then return false end
		local stack = MC.SV.GetSelectedPlayerStack and MC.SV.GetSelectedPlayerStack( ply ) or nil
		if isShovel( stack ) then
			return MC.SV.DowseCampfireWithSelectedShovel
				and MC.SV.DowseCampfireWithSelectedShovel( ply, bx, by, bz ) == true or false
		end
		if not MC.SV.UseCampfire then return false end
		return MC.SV.UseCampfire( ply, bx, by, bz ) == true
	end,
	OnPlaced = function( context )
		if SERVER and MC.SV and MC.SV.WakeCampfire then
			MC.SV.WakeCampfire( context.bx, context.by, context.bz )
		end
	end,
	OnStateChanged = function( context, oldStateId, newStateId )
		-- Scheduled block ticks carry the state id that was current when they
		-- were queued. Lighting, dowsing, or rotating a campfire invalidates
		-- that tick, so install a fresh one for any stored food/progress.
		if SERVER and MC.SV then
			if MC.SV.HandleCampfireStateTransition then
				MC.SV.HandleCampfireStateTransition( context, oldStateId, newStateId )
			end
			if MC.SV.WakeCampfire then MC.SV.WakeCampfire( context.bx, context.by, context.bz ) end
		end
	end,
	OnRemoved = dropContents,
	OnReplaced = dropContents,
}

for _, block in pairs( MC.Blocks or {} ) do
	if block.mcid == "minecraft:campfire" or block.mcid == "minecraft:soul_campfire"
		or block.name == "campfire" or block.name == "soul_campfire" then
		block.handlers = MC.BlockHandlers.campfire
		block.handlerName = "campfire"
	end
end
