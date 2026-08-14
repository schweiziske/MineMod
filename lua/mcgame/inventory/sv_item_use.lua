-- Server-authoritative item-use state machine.
-- Timings/behavior kinds are classified in item/sh_behavior.lua from the
-- corresponding Minecraft Item subclasses in out/.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local HUNGER_MAX = 20
local HUNGER_DEFAULT = 20
local SATURATION_DEFAULT = 5
local EXHAUSTION_DEFAULT = 0
local USE_NET_ROOT = "mc_item_using"
local USE_NET_PREFIX = USE_NET_ROOT .. "_"

local function activeMinecraftHand( ply, context )
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	if context and context.allowAnyWeapon == true then
		-- External resolver-driven SWEPs may reuse this state machine, but the
		-- bridge must stay bound to the exact weapon class that requested the
		-- operation.  A bare allowAnyWeapon flag would let any active weapon
		-- start or keep another selected stack's use state alive.
		local expectedClass = tostring( context.expectedClass or "" )
		return expectedClass ~= "" and IsValid( weapon ) and weapon.GetClass
			and weapon:GetClass() == expectedClass
	end
	return IsValid( weapon ) and weapon:GetClass() == "mc_item_hand"
end

local function foodState( ply )
	local level = math.Clamp( ply:GetNWInt( "mc_food_level", HUNGER_DEFAULT ), 0, HUNGER_MAX )
	local saturation = math.max( 0, ply:GetNWFloat( "mc_food_saturation", SATURATION_DEFAULT ) )
	return level, saturation
end

local function playerCanEatAtFull( ply )
	return SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) == true
end

local function resetFoodState( ply )
	if not IsValid( ply ) or not ply:IsPlayer() then return end
	ply:SetNWInt( "mc_food_level", HUNGER_DEFAULT )
	ply:SetNWFloat( "mc_food_saturation", SATURATION_DEFAULT )
	ply:SetNWFloat( "mc_food_exhaustion", EXHAUSTION_DEFAULT )
end

local function setUseNetwork( ply, state )
	if not IsValid( ply ) then return end
	if not ply.SetNWBool then return end
	local using = state ~= nil
	ply:SetNWBool( USE_NET_ROOT, using )
	if not using then
		if ply.SetNWString then
			ply:SetNWString( USE_NET_PREFIX .. "item", "" )
			ply:SetNWString( USE_NET_PREFIX .. "hand", "" )
		end
		if ply.SetNWFloat then
			ply:SetNWFloat( USE_NET_PREFIX .. "start", 0 )
			ply:SetNWFloat( USE_NET_PREFIX .. "duration", 0 )
			ply:SetNWFloat( USE_NET_PREFIX .. "progress", 0 )
		end
		return
	end
	if ply.SetNWString then
		ply:SetNWString( USE_NET_PREFIX .. "item", tostring( state.itemName or "" ) )
		ply:SetNWString( USE_NET_PREFIX .. "hand", tostring( state.hand or "mainhand" ) )
	end
	if ply.SetNWFloat then
		ply:SetNWFloat( USE_NET_PREFIX .. "start", tonumber( state.startedAt ) or CurTime() )
		ply:SetNWFloat( USE_NET_PREFIX .. "duration", tonumber( state.duration ) or 0 )
		ply:SetNWFloat( USE_NET_PREFIX .. "progress", 0 )
	end
end

local function recordStackForHand( ply, hand )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record or not record.container then return nil, nil, nil end
	local stack
	if hand == "offhand" then
		stack = MC.CopyItemStack( record.equipment and record.equipment.offhand )
	else
		stack = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
		hand = "mainhand"
	end
	local definition = stack and MC.GetItem( stack.item ) or nil
	return record, stack, definition, hand
end

local function selectedRecordStack( ply ) return recordStackForHand( ply, "mainhand" ) end

local function consumeOne( record, stack, ply, context )
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) then return nil, true end
	if context.hand == "offhand" then
		if not SV.EquipmentSnapshot or not SV.CommitEquipmentMutation then return nil, false, "equipment_unavailable" end
		local snapshot = SV.EquipmentSnapshot( record )
		local replacement
		if stack.count > 1 then replacement = MC.CopyItemStack( stack, stack.count - 1 ) end
		record.equipment.offhand = replacement
		local result, commitError = SV.CommitEquipmentMutation( record, snapshot, {
			player = ply, reason = context.reason or "item_use", actionId = context.actionId,
		} )
		if not result then
			for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do record.equipment[slot] = MC.CopyItemStack( snapshot[slot] ) end
			return nil, false, commitError or "item_consume_commit_failed"
		end
		return result, false
	end
	local snapshot = MC.ContainerSnapshot( record.container )
	local replacement
	if stack.count > 1 then replacement = MC.CopyItemStack( stack, stack.count - 1 ) end
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

local function useDetails( stack, definition )
	if not stack or not definition then return nil, nil, false end
	local kind = MC.ItemBehavior and MC.ItemBehavior( stack ) or nil
	if not kind and MC.ItemFoodData and MC.ItemFoodData( stack ) then kind = "food" end
	local spec = MC.ItemBehaviorSpec and MC.ItemBehaviorSpec( stack ) or nil
	local usable = kind ~= nil or stack.item == "minecraft:flint_and_steel"
		or stack.item == "minecraft:fire_charge"
		or MC.ItemIsConsumable and MC.ItemIsConsumable( stack ) or definition.useHandler ~= nil
	return kind, spec, usable == true
end

local function sameUsingStack( state, stack )
	if not state or not stack then return false end
	if state.stackHash and MC.ItemStackHash then
		return state.stackHash == MC.ItemStackHash( stack )
	end
	return state.itemName == stack.item
		and ( tonumber( state.damage ) or 0 ) == ( tonumber( stack.damage ) or 0 )
end

local function shieldDisabled( ply )
	return SV.IsPlayerShieldDisabled and SV.IsPlayerShieldDisabled( ply ) == true
end

local function clearUse( ply, record, reason, finished )
	if record then record.itemUse = nil end
	setUseNetwork( ply, nil )
	if MC.RunEvent then
		if finished then MC.RunEvent( "MC.ItemUseFinished", ply, reason or "finished" )
		else MC.RunEvent( "MC.ItemUseCancelled", ply, reason or "cancelled" ) end
	end
end

local function mergedContext( state, context )
	local result = {}
	for key, value in pairs( state and state.context or {} ) do result[key] = value end
	for key, value in pairs( context or {} ) do result[key] = value end
	return result
end

local function finishFood( ply, record, stack, context )
	local food = MC.ItemFoodData and MC.ItemFoodData( stack ) or nil
	if not food then return false, "food_data_missing" end
	local hunger, saturation = foodState( ply )
	if hunger >= HUNGER_MAX and not food.alwaysEdible and not playerCanEatAtFull( ply ) then
		return false, "food_full"
	end
	local result, infinite, consumeError = consumeOne( record, stack, ply, context )
	if consumeError then return false, consumeError end
	local nutrition = math.floor( tonumber( food.nutrition ) or 0 )
	local newHunger = math.Clamp( hunger + nutrition, 0, HUNGER_MAX )
	-- MC.ItemFoodData.saturation is the final FoodProperties.saturation value.
	-- The `* 2` belongs only to FoodData.eat(nutrition, modifier), not to the
	-- component-backed FoodProperties path used by MCITEM/MCSWEP stacks.
	local newSaturation = math.max( saturation, math.min( newHunger, saturation + ( tonumber( food.saturation ) or 0 ) ) )
	ply:SetNWInt( "mc_food_level", newHunger )
	ply:SetNWFloat( "mc_food_saturation", newSaturation )
	if MC.RunEvent then MC.RunEvent( "MC.ItemConsumed", ply, stack, food, infinite == true ) end
	return true, result
end

local function finishGeneric( ply, record, stack, context )
	local result, infinite, consumeError = consumeOne( record, stack, ply, context )
	if consumeError then return false, consumeError end
	if MC.RunEvent then MC.RunEvent( "MC.ItemConsumed", ply, stack, nil, infinite == true ) end
	return true, result
end

local function dispatchFinishedUse( ply, record, stack, definition, state, context )
	local kind = state.kind
	if kind == "food" then return finishFood( ply, record, stack, context ) end
	if kind == "bow" and SV.FireBow then return SV.FireBow( ply, record, stack, state, context ) end
	if kind == "crossbow" and SV.FinishCrossbowUse then return SV.FinishCrossbowUse( ply, record, stack, state, context ) end
	if kind == "trident" and SV.ThrowTrident then return SV.ThrowTrident( ply, record, stack, state, context ) end
	if kind == "projectile" and SV.ThrowItemProjectile then return SV.ThrowItemProjectile( ply, record, stack, context ) end
	if kind == "shield" or kind == "spyglass" or kind == "brush" then
		if MC.RunEvent then MC.RunEvent( "MC.ItemUsed", ply, stack, context ) end
		return true
	end
	if stack and stack.item == "minecraft:flint_and_steel" and SV.UseSelectedFlintAndSteel then
		return SV.UseSelectedFlintAndSteel( ply, context )
	end
	if stack and stack.item == "minecraft:fire_charge" and SV.UseSelectedFireCharge then
		return SV.UseSelectedFireCharge( ply, context )
	end
	if definition and definition.useHandler then
		local called, handled = pcall( definition.useHandler, ply, stack, context )
		if called and handled == true then
			if MC.RunEvent then MC.RunEvent( "MC.ItemUsed", ply, stack, context ) end
			return true
		end
	end
	if MC.ItemIsConsumable and MC.ItemIsConsumable( stack ) then return finishGeneric( ply, record, stack, context ) end
	return false, "item_not_usable"
end

function SV.BeginSelectedItemUse( ply, context )
	context = context or {}
	if not IsValid( ply ) or not ply:Alive() or not activeMinecraftHand( ply, context ) then return false, "invalid_item_use" end
	local record, stack, definition, hand = selectedRecordStack( ply )
	if not record then return false, "inventory_not_loaded" end
	-- Resolver-driven SWEPs are selected from the mainhand stack. Pinning the
	-- expected item before the ordinary offhand-shield fallback prevents a stale
	-- resolver weapon from starting some other selected stack (or an offhand
	-- shield) after the hotbar selection changes between weapon resolution and
	-- the server-authoritative Begin call.
	local expectedItem = tostring( context.expectedItem or "" )
	if expectedItem ~= "" and ( not stack or stack.item ~= expectedItem ) then
		return false, "selected_item_mismatch"
	end
	if record.itemUse then return true, "already_using" end
	local now = CurTime()
	if record.lastItemUse and now - record.lastItemUse < 0.08 then return false, "item_use_cooldown" end
	local kind, spec, usable = useDetails( stack, definition )
	if not usable and ( not definition or not definition.blockId ) then
		local offRecord, offStack, offDefinition = recordStackForHand( ply, "offhand" )
		local offKind, offSpec, offUsable = useDetails( offStack, offDefinition )
		if offRecord and offUsable and offKind == "shield" then
			stack, definition, hand, kind, spec, usable = offStack, offDefinition, "offhand", offKind, offSpec, true
		end
	end
	if not stack or not definition then return false, "empty_hand" end
	if not usable then return false, "item_not_usable" end
	if kind == "shield" and shieldDisabled( ply ) then return false, "shield_disabled" end
	local useContext = {}
	for key, value in pairs( context ) do useContext[key] = value end
	useContext.hand = hand
	if kind == "food" then
		local food = MC.ItemFoodData( stack )
		local hunger = foodState( ply )
		if hunger >= HUNGER_MAX and not food.alwaysEdible and not playerCanEatAtFull( ply ) then
			return false, "food_full"
		end
	end
	if ( kind == "bow" or kind == "crossbow" or kind == "trident" )
		and SV.CanBeginProjectileUse then
		local allowed, projectileError = SV.CanBeginProjectileUse( ply, record, stack, kind )
		if allowed ~= true then return false, projectileError or "projectile_unavailable" end
	end
	local duration = spec and spec.duration or 0
	if kind == "crossbow" and MC.ItemCrossbowCharged and MC.ItemCrossbowCharged( stack ) then duration = 0 end
	if context.instant == true or duration <= 0 then
		local instantState = { kind = kind or "generic", itemName = stack.item, damage = stack.damage,
			hand = hand, startedAt = now, duration = 0 }
		local ok, resultOrError = dispatchFinishedUse( ply, record, stack, definition, instantState, useContext )
		if ok then record.lastItemUse = now end
		return ok, resultOrError
	end
	record.itemUse = {
		kind = kind or "generic",
		itemName = stack.item,
		damage = stack.damage,
		stackHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
		hand = hand,
		selected = hand == "mainhand" and record.selected or nil,
		startedAt = now,
		duration = duration,
		context = useContext,
	}
	setUseNetwork( ply, record.itemUse )
	if MC.RunEvent then MC.RunEvent( "MC.ItemUseStarted", ply, stack, record.itemUse ) end
	return true, "started"
end

function SV.TickSelectedItemUse( ply, context )
	context = context or {}
	if not IsValid( ply ) or not ply:Alive() or not activeMinecraftHand( ply, context ) then
		SV.CancelSelectedItemUse( ply, "invalid_item_use" )
		return false, "invalid_item_use"
	end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local state = record and record.itemUse or nil
	if not state then return false, "not_using" end
	if state.kind == "shield" and shieldDisabled( ply ) then
		clearUse( ply, record, "shield_disabled" )
		return false, "shield_disabled"
	end
	local _, stack, definition = recordStackForHand( ply, state.hand )
	if not stack or not sameUsingStack( state, stack )
		or state.hand == "mainhand" and state.selected ~= record.selected then
		clearUse( ply, record, "selected_item_changed" )
		return false, "selected_item_changed"
	end
	local progress = MC.ItemUseProgress and MC.ItemUseProgress( state.startedAt, state.duration, CurTime() )
		or math.Clamp( ( CurTime() - state.startedAt ) * 20 / state.duration, 0, 1 )
	if ply.SetNWFloat then ply:SetNWFloat( USE_NET_PREFIX .. "progress", progress ) end
	if ( state.kind == "food" or state.kind == "crossbow" ) and progress >= 1 then
		state.progress = progress
		local ok, resultOrError = dispatchFinishedUse( ply, record, stack, definition, state, mergedContext( state, context ) )
		if ok then record.lastItemUse = CurTime() end
		clearUse( ply, record, ok and "finished" or resultOrError, ok )
		return ok, resultOrError
	end
	return true, progress
end

function SV.ReleaseSelectedItemUse( ply, context )
	context = context or {}
	if not IsValid( ply ) or not ply:Alive() or not activeMinecraftHand( ply, context ) then
		SV.CancelSelectedItemUse( ply, "invalid_item_use" )
		return false, "invalid_item_use"
	end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local state = record and record.itemUse or nil
	if not state then return false, "not_using" end
	if state.kind == "shield" and shieldDisabled( ply ) then
		clearUse( ply, record, "shield_disabled" )
		return false, "shield_disabled"
	end
	local _, stack, definition = recordStackForHand( ply, state.hand )
	if not stack or not sameUsingStack( state, stack )
		or state.hand == "mainhand" and state.selected ~= record.selected then
		clearUse( ply, record, "selected_item_changed" )
		return false, "selected_item_changed"
	end
	local progress = MC.ItemUseProgress and MC.ItemUseProgress( state.startedAt, state.duration, CurTime() ) or 0
	if state.kind == "food" and progress < 1 then
		clearUse( ply, record, "released_early" )
		return false, "released_early"
	end
	state.progress = progress
	local ok, resultOrError = dispatchFinishedUse( ply, record, stack, definition, state, mergedContext( state, context ) )
	if ok then record.lastItemUse = CurTime() end
	clearUse( ply, record, ok and "finished" or resultOrError, ok )
	return ok, resultOrError
end

function SV.CancelSelectedItemUse( ply, reason )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record or not record.itemUse then return false end
	clearUse( ply, record, reason or "cancelled" )
	return true
end

-- Compatibility API used by older callers/tests: perform an instant use.
function SV.UseSelectedItem( ply, context )
	context = context or {}
	context.instant = true
	return SV.BeginSelectedItemUse( ply, context )
end

MC.UseSelectedItem = SV.UseSelectedItem

if hook and hook.Add then
	hook.Add( "PlayerSpawn", "mc_item_food_state_spawn", resetFoodState )
	hook.Add( "PlayerDeath", "mc_item_use_cancel_death", function( ply )
		SV.CancelSelectedItemUse( ply, "death" )
	end )
	hook.Add( "PlayerDisconnected", "mc_item_use_cancel_disconnect", function( ply )
		SV.CancelSelectedItemUse( ply, "disconnect" )
	end )
	hook.Add( "ShutDown", "mc_item_use_cancel_shutdown", function()
		for ply in pairs( SV.PlayerInventories or {} ) do SV.CancelSelectedItemUse( ply, "shutdown" ) end
	end )
end
