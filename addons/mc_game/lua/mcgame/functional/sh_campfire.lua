-- Shared campfire interaction/lifecycle binding.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

local function dropContents( context )
	if SERVER and MC.SV and MC.SV.DropCampfireContents then
		MC.SV.DropCampfireContents( context.actor, context.bx, context.by, context.bz, context.oldBlockEntity )
	end
end

local function isShovel( stack )
	local spec = stack and MC.ItemToolSpec and MC.ItemToolSpec( stack ) or nil
	return spec and spec.type == "shovel" or false
end

local HANDLERS = {
	CanUse = function( stack )
		return isShovel( stack ) or stack ~= nil and MC.FindCookingRecipe ~= nil
			and MC.FindCookingRecipe( stack, "minecraft:campfire_cooking" ) ~= nil
	end,
	OnUse = function( ply, bx, by, bz, orient, blockId, context )
		if CLIENT then return true end
		if not MC.SV then return false end
		local stack = MC.SV.GetPlayerHandStack( ply, context and context.hand )
		if isShovel( stack ) then
			return MC.SV.DowseCampfireWithSelectedShovel
				and MC.SV.DowseCampfireWithSelectedShovel( ply, bx, by, bz,
					{ hand = context and context.hand, alreadyValidated = true } ) == true or false
		end
		if not MC.SV.UseCampfire then return false end
		return MC.SV.UseCampfire( ply, bx, by, bz, context ) == true
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

if Blocks then
	Blocks.SetHandlers( "minecraft:campfire", HANDLERS )
	Blocks.SetHandlers( "minecraft:soul_campfire", HANDLERS )
end
