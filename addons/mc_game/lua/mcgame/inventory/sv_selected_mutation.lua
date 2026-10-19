-- Atomic, server-authoritative mutations for the currently selected hotbar slot.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function expectedItemName( value )
	if value == nil then return nil end
	local definition = MC.GetItem and MC.GetItem( value ) or nil
	return definition and definition.name or nil
end

function SV.SelectedStackMatches( ply, context )
	context = context or {}
	if not IsValid( ply ) or not ply:IsPlayer() then return nil, nil, nil, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record or not record.container then return nil, nil, nil, "inventory_not_loaded" end
	if context.hand ~= nil and context.hand ~= "mainhand" and context.hand ~= "offhand" then
		return nil, nil, nil, "invalid_hand"
	end
	local slotIndex = context.hand == "offhand" and 40 or record.selected
	if context.expectedSlot ~= nil and slotIndex ~= context.expectedSlot then
		return nil, nil, nil, "selected_slot_changed"
	end
	local stack = SV.InteractionStack( record, slotIndex )
	if not stack then return nil, nil, nil, "selected_item_missing" end

	if context.expectedItem ~= nil then
		local expected = expectedItemName( context.expectedItem )
		if not expected then return nil, nil, nil, "unknown_expected_item" end
		if stack.item ~= expected then return nil, nil, nil, "selected_item_mismatch" end
	end
	if context.expectedStackHash ~= nil then
		local hash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil
		if hash ~= tostring( context.expectedStackHash ) then return nil, nil, nil, "selected_stack_changed" end
	end
	if context.expectedClass ~= nil and context.hand == "offhand" then
		local active = ply:GetActiveWeapon()
		if not IsValid( active ) or active:GetClass() ~= context.expectedClass then
			return nil, nil, nil, "selected_weapon_mismatch"
		end
	elseif context.expectedClass ~= nil then
		local bridge = MC.HandWeaponBridge
		if not bridge or not bridge.Resolve then return nil, nil, nil, "hand_weapon_bridge_unavailable" end
		local resolved = bridge.Resolve( stack, ply )
		if resolved ~= context.expectedClass then return nil, nil, nil, "selected_weapon_mismatch" end
	end
	return record, slotIndex, stack
end

local function replacementStack( replacement, amount, context )
	if replacement == nil then return nil end
	if isstring( replacement ) then
		return MC.NewItemStack( replacement, math.max( 1, math.floor( tonumber( context.replacementCount ) or amount ) ) )
	end
	if type( replacement ) ~= "table" then return nil, "invalid_replacement" end
	return MC.NormalizeItemStack( replacement )
end

local function inventoryTargets( record )
	local targets = {}
	for index = 0, 35 do targets[#targets + 1] = index end
	return targets
end

local function dropOverflow( ply, stack, context )
	if not stack or context.dropOverflow == false or not SV.SpawnItemDrop then return stack, false end
	local position = SV.PlayerItemDropPosition and SV.PlayerItemDropPosition( ply ) or ply:GetShootPos()
	local entity = SV.SpawnItemDrop( position, stack, ply, {
		noMerge = true,
		pickupDelay = MC.ItemEntityParity and MC.ItemEntityParity.Enabled
			and MC.ItemEntityParity.Enabled() and 2.0 or nil,
		velocity = SV.PlayerThrownDropVelocity and SV.PlayerThrownDropVelocity( ply ) or nil,
		reason = context.reason or "selected_consume_overflow",
	} )
	if IsValid( entity ) then return nil, true end
	return stack, false
end

function SV.ConsumeSelectedItem( ply, amount, replacement, context )
	context = context or {}
	amount = math.floor( tonumber( amount ) or 0 )
	if amount <= 0 then return nil, 0, nil, false, "invalid_consume_amount" end
	local record, slotIndex, stack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, 0, nil, false, matchError end
	if stack.count < amount then return nil, 0, nil, false, "selected_item_count_too_low" end

	local converted, replacementError = replacementStack( replacement, amount, context )
	if replacement ~= nil and not converted then
		return nil, 0, nil, false, replacementError or "invalid_replacement"
	end
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply )
	and context.consumeInInfiniteMaterials ~= true then
		return { ok = true, infinite = true, changedSlots = {} }, amount, nil, true
	end

	local snapshot = SV.InteractionSnapshot( record, slotIndex == 40 )
	local remainingCount = stack.count - amount
	local remaining = remainingCount > 0 and MC.CopyItemStack( stack, remainingCount ) or nil
	local selectedReplacement = remaining or converted
	local ok, setError = SV.SetInteractionStack( record, slotIndex, selectedReplacement )
	if not ok then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, 0, nil, false, setError or "selected_consume_failed"
	end

	local overflow
	if remaining and converted then
		overflow = select( 1, MC.ContainerMoveStackTo( record.container, converted, inventoryTargets( record ), context ) )
	end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "selected_consume",
		actionId = context.actionId,
	} )
	if not result then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, 0, nil, false, commitError or "selected_consume_commit_failed"
	end

	overflow, result.replacementDropped = dropOverflow( ply, overflow, context )
	result.consumed = amount
	result.infinite = false
	result.replacementOverflow = MC.CopyItemStack( overflow )
	if MC.RunEvent then
		local eventResult = MC.API and MC.API.DeepCopy and MC.API.DeepCopy( result ) or result
		MC.RunEvent(
			"MC.SelectedItemConsumed",
			ply,
			slotIndex,
			MC.CopyItemStack( stack ),
			amount,
			MC.CopyItemStack( converted ),
			eventResult
		)
	end
	return result, amount, MC.CopyItemStack( overflow ), false
end

MC.ConsumeSelectedItem = SV.ConsumeSelectedItem

-- Held-stack consumers use exact main/off-hand storage. The default remains a
-- real shrink even in infinite-material mode because death protection calls
-- ItemStack.shrink(1) directly. Callers whose Java path uses ItemStack.consume
-- or Player#interactOn may opt into `respectInfiniteMaterials=true`.
local function heldStackMatches( stack, context )
	if not stack then return false end
	if context.expectedItem and stack.item ~= context.expectedItem then return false end
	if context.expectedHash and MC.ItemStackHash and MC.ItemStackHash( stack ) ~= context.expectedHash then return false end
	return true
end

function SV.ConsumeHeldItem( ply, amount, context )
	context = context or {}
	amount = math.floor( tonumber( amount ) or 0 )
	if amount <= 0 then return nil, 0, nil, "invalid_consume_amount" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record then return nil, 0, nil, "inventory_not_loaded" end

	local hand = tostring( context.hand or "mainhand" )
	if hand == "main" then hand = "mainhand" end
	if hand == "off" then hand = "offhand" end
	if hand ~= "mainhand" and hand ~= "offhand" then return nil, 0, nil, "invalid_hand" end

	if hand == "offhand" then
		local stack = record.equipment and record.equipment.offhand or nil
		if not heldStackMatches( stack, context ) then return nil, 0, nil, "held_item_mismatch" end
		if stack.count < amount then return nil, 0, nil, "held_item_count_too_low" end
		if context.respectInfiniteMaterials == true and SV.PlayerHasInfiniteMaterials
		and SV.PlayerHasInfiniteMaterials( ply ) then
			return { ok = true, infinite = true, changedSlots = {} }, amount, MC.CopyItemStack( stack )
		end
		if not SV.EquipmentSnapshot or not SV.CommitEquipmentMutation then
			return nil, 0, nil, "equipment_api_unavailable"
		end
		local snapshot = SV.EquipmentSnapshot( record )
		local remainingCount = stack.count - amount
		record.equipment.offhand = remainingCount > 0 and MC.CopyItemStack( stack, remainingCount ) or nil
		local result, commitError = SV.CommitEquipmentMutation( record, snapshot, {
			player = ply,
			reason = context.reason or "held_item_consume",
			actionId = context.actionId,
		} )
		if not result then
			record.equipment.offhand = MC.CopyItemStack( snapshot.offhand )
			return nil, 0, nil, commitError or "held_item_consume_commit_failed"
		end
		if MC.RunEvent then
			MC.RunEvent( "MC.HeldItemConsumed", ply, hand, MC.CopyItemStack( stack ), amount, result )
		end
		return result, amount, MC.CopyItemStack( stack )
	end

	local slotIndex = math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 )
	local stack = record.storage and record.storage[slotIndex + 1] or nil
	if not heldStackMatches( stack, context ) then return nil, 0, nil, "held_item_mismatch" end
	if stack.count < amount then return nil, 0, nil, "held_item_count_too_low" end
	if context.respectInfiniteMaterials == true and SV.PlayerHasInfiniteMaterials
	and SV.PlayerHasInfiniteMaterials( ply ) then
		return { ok = true, infinite = true, changedSlots = {} }, amount, MC.CopyItemStack( stack )
	end
	local snapshot = SV.InteractionSnapshot( record, slotIndex == 40 )
	local remainingCount = stack.count - amount
	local remaining = remainingCount > 0 and MC.CopyItemStack( stack, remainingCount ) or nil
	local ok, setError = SV.SetInteractionStack( record, slotIndex, remaining )
	if not ok then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, 0, nil, setError or "held_item_consume_failed"
	end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "held_item_consume",
		actionId = context.actionId,
	} )
	if not result then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, 0, nil, commitError or "held_item_consume_commit_failed"
	end
	if MC.RunEvent then
		MC.RunEvent( "MC.HeldItemConsumed", ply, hand, MC.CopyItemStack( stack ), amount, result )
	end
	return result, amount, MC.CopyItemStack( stack )
end

MC.ConsumeHeldItem = SV.ConsumeHeldItem

-- Atomically replace the complete selected ItemStack. External resolver-driven
-- SWEPs use this for component state that belongs to the item itself (not the
-- transient weapon entity), notably a crossbow's charged_projectiles payload.
function SV.ReplaceSelectedItem( ply, input, context )
	context = context or {}
	local record, slotIndex, stack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, nil, matchError end

	local replacement, replacementError = MC.NormalizeItemStack( input )
	if input ~= nil and not replacement then return nil, nil, replacementError or "invalid_replacement" end
	if replacement and replacement.item ~= stack.item and context.allowItemChange ~= true then
		return nil, nil, "selected_item_change_rejected"
	end
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply )
	and context.mutateInInfinite ~= true then
		return { ok = true, infinite = true, changedSlots = {} }, MC.CopyItemStack( stack )
	end

	local snapshot = SV.InteractionSnapshot( record, slotIndex == 40 )
	local ok, setError = SV.SetInteractionStack( record, slotIndex, replacement )
	if not ok then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, nil, setError or "selected_replace_failed"
	end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "selected_replace",
		actionId = context.actionId,
	} )
	if not result then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, nil, commitError or "selected_replace_commit_failed"
	end
	if MC.RunEvent then
		MC.RunEvent(
			"MC.SelectedItemReplaced",
			ply,
			slotIndex,
			MC.CopyItemStack( stack ),
			MC.CopyItemStack( replacement ),
			result
		)
	end
	return result, MC.CopyItemStack( replacement )
end

MC.ReplaceSelectedItem = SV.ReplaceSelectedItem

-- Atomically take one copy of the selected stack after applying a durability
-- use that is not allowed to break the item.  This mirrors the ordering used by
-- TridentItem.releaseUsing: nextDamageWillBreak(), hurtWithoutBreaking(1), then
-- consumeAndReturn(1).  External projectile addons receive the complete stack
-- (damage + components) without having to compose separate damage/consume
-- transactions that could race or duplicate the item.
local function selectedDurabilityTakeState( ply, durabilityAmount, context )
	context = context or {}
	durabilityAmount = math.floor( tonumber( durabilityAmount ) or 0 )
	if durabilityAmount < 0 then return nil, nil, nil, nil, nil, "invalid_durability_amount" end
	durabilityAmount = math.min( durabilityAmount, 255 )

	local record, slotIndex, stack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, nil, nil, nil, nil, matchError end
	if stack.count < 1 then return nil, nil, nil, nil, nil, "selected_item_count_too_low" end

	local definition = MC.GetItem and MC.GetItem( stack.item ) or nil
	if not definition then return nil, nil, nil, nil, nil, "unknown_selected_item" end
	local maximum = math.max( 0, math.floor( tonumber( definition.maxDamage ) or 0 ) )
	local currentDamage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) )
	local unbreakable = MC.ItemIsUnbreakable and MC.ItemIsUnbreakable( stack ) == true or false
	local damageable = maximum > 0 and not unbreakable
	local infinite = SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true or false

	-- nextDamageWillBreak() is checked before hurtWithoutBreaking().  Equality is
	-- rejected: a trident at maxDamage - 1 cannot begin or finish a throw.
	if damageable and durabilityAmount > 0 and currentDamage + durabilityAmount >= maximum then
		return nil, nil, nil, nil, nil, "selected_item_would_break"
	end

	-- ItemStack.processDurabilityChange returns zero for infinite-material players,
	-- so hurtWithoutBreaking leaves both the held stack and projectile copy at the
	-- original damage value in creative mode.
	local nextDamage = damageable and not infinite and currentDamage + durabilityAmount or currentDamage
	return record, slotIndex, stack, infinite, nextDamage, nil, durabilityAmount
end

function SV.CanTakeSelectedItemWithDurability( ply, durabilityAmount, context )
	local _, _, stack, infinite, _, err = selectedDurabilityTakeState( ply, durabilityAmount, context )
	if not stack then return false, false, nil, err end
	return true, infinite == true, MC.CopyItemStack( stack ), nil
end

function SV.TakeSelectedItemWithDurability( ply, durabilityAmount, context )
	context = context or {}
	local record, slotIndex, stack, infinite, nextDamage, stateError, normalizedAmount =
		selectedDurabilityTakeState( ply, durabilityAmount, context )
	if not record then return nil, false, nil, stateError end
	durabilityAmount = normalizedAmount

	local extracted = MC.CopyItemStack( stack, 1 )
	if not extracted then return nil, false, nil, "selected_item_copy_failed" end
	extracted.damage = nextDamage > 0 and nextDamage or nil

	if infinite then
		local result = { ok = true, infinite = true, changedSlots = {}, changed = {} }
		if MC.RunEvent then
			MC.RunEvent(
				"MC.SelectedItemTakenWithDurability",
				ply,
				slotIndex,
				MC.CopyItemStack( stack ),
				MC.CopyItemStack( extracted ),
				durabilityAmount,
				true,
				result
			)
		end
		return extracted, true, result
	end

	local snapshot = SV.InteractionSnapshot( record, slotIndex == 40 )
	local remaining = stack.count > 1 and MC.CopyItemStack( stack, stack.count - 1 ) or nil
	-- ItemStack is damaged before consumeAndReturn copies/splits it.  Damageable
	-- stacks are non-stackable in valid Minecraft data, but preserving this order
	-- also makes the helper deterministic for externally supplied definitions.
	if remaining then remaining.damage = nextDamage > 0 and nextDamage or nil end
	local ok, setError = SV.SetInteractionStack( record, slotIndex, remaining )
	if not ok then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, false, nil, setError or "selected_take_failed"
	end

	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "selected_take_with_durability",
		actionId = context.actionId,
	} )
	if not result then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, false, nil, commitError or "selected_take_commit_failed"
	end

	result.infinite = false
	result.durabilityDamage = durabilityAmount
	if MC.RunEvent then
		local eventResult = MC.API and MC.API.DeepCopy and MC.API.DeepCopy( result ) or result
		MC.RunEvent(
			"MC.SelectedItemTakenWithDurability",
			ply,
			slotIndex,
			MC.CopyItemStack( stack ),
			MC.CopyItemStack( extracted ),
			durabilityAmount,
			false,
			eventResult
		)
	end
	return extracted, false, result
end

MC.TakeSelectedItemWithDurability = SV.TakeSelectedItemWithDurability
MC.CanTakeSelectedItemWithDurability = SV.CanTakeSelectedItemWithDurability
