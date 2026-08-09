-- Server-authoritative right-click use/consume path for held Minecraft items.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local HUNGER_MAX = 20

local function activeMinecraftHand( ply, context )
	if context and context.allowAnyWeapon == true then return true end
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	return IsValid( weapon ) and weapon:GetClass() == "mc_item_hand"
end

local function foodState( ply )
	local level = math.Clamp( ply:GetNWInt( "mc_food_level", HUNGER_MAX ), 0, HUNGER_MAX )
	local saturation = math.max( 0, ply:GetNWFloat( "mc_food_saturation", 0 ) )
	return level, saturation
end

local function consumeOne( record, stack, ply, context )
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) then return nil, true end
	local snapshot = MC.ContainerSnapshot( record.container )
	local replacement = stack.count > 1 and MC.CopyItemStack( stack, stack.count - 1 ) or nil
	local selected = math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 )
	local ok, err = MC.ContainerSetStack( record.container, selected, replacement )
	if not ok then MC.ContainerRestore( record.container, snapshot ) return nil, false, err or "item_consume_failed" end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "item_use",
		actionId = context.actionId,
	} )
	if not result then
		MC.ContainerRestore( record.container, snapshot )
		return nil, false, commitError or "item_consume_commit_failed"
	end
	return result, false
end

function SV.UseSelectedItem( ply, context )
	context = context or {}
	if not IsValid( ply ) or not ply:Alive() or not activeMinecraftHand( ply, context ) then return false, "invalid_item_use" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record or not record.container then return false, "inventory_not_loaded" end
	local now = CurTime()
	if record.lastItemUse and now - record.lastItemUse < 0.08 then return false, "item_use_cooldown" end
	local stack = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	local definition = stack and MC.GetItem( stack.item ) or nil
	if not stack or not definition then return false, "empty_hand" end

	if definition.useHandler then
		local called, handled = pcall( definition.useHandler, ply, stack, context )
		if called and handled == true then
			record.lastItemUse = now
			if MC.RunEvent then MC.RunEvent( "MC.ItemUsed", ply, stack, context ) end
			return true
		end
	end

	local food = MC.ItemFoodData and MC.ItemFoodData( stack ) or nil
	if not food and not ( MC.ItemIsConsumable and MC.ItemIsConsumable( stack ) ) then return false, "item_not_usable" end
	if food then
		local hunger, saturation = foodState( ply )
		if hunger >= HUNGER_MAX and not food.alwaysEdible then return false, "food_full" end
		local result, infinite, consumeError = consumeOne( record, stack, ply, context )
		if consumeError then return false, consumeError end
		local newHunger = math.Clamp( hunger + math.floor( tonumber( food.nutrition ) or 0 ), 0, HUNGER_MAX )
		local newSaturation = math.max( saturation, math.min( newHunger, saturation + ( tonumber( food.saturation ) or 0 ) * 2 ) )
		ply:SetNWInt( "mc_food_level", newHunger )
		ply:SetNWFloat( "mc_food_saturation", newSaturation )
		record.lastItemUse = now
		if MC.RunEvent then MC.RunEvent( "MC.ItemConsumed", ply, stack, food, infinite == true ) end
		return true, result
	end

	-- A custom consumable without FoodProperties is still allowed to invoke
	-- the lifecycle event; the registered handler can apply its own effects.
	local result, infinite, consumeError = consumeOne( record, stack, ply, context )
	if consumeError then return false, consumeError end
	record.lastItemUse = now
	if MC.RunEvent then MC.RunEvent( "MC.ItemConsumed", ply, stack, nil, infinite == true ) end
	return true, result
end

MC.UseSelectedItem = SV.UseSelectedItem

