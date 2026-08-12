-- Atomic, server-authoritative mutations for the currently selected hotbar slot.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function selectedSlot( record )
	local index = math.Clamp( math.floor( tonumber( record and record.selected ) or 0 ), 0, 8 )
	return index, record and MC.ContainerGetSlot( record.container, index ) or nil
end

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
	local slotIndex, slot = selectedSlot( record )
	local stack = slot and MC.InventorySlotGet( slot ) or nil
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
	if context.expectedClass ~= nil then
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
		velocity = SV.PlayerThrownDropVelocity and SV.PlayerThrownDropVelocity( ply ) or nil,
		reason = context.reason or "selected_consume_overflow",
	} )
	return IsValid( entity ) and nil or stack, IsValid( entity )
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
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) then
		return { ok = true, infinite = true, changedSlots = {} }, amount, nil, true
	end

	local snapshot = MC.ContainerSnapshot( record.container )
	local remainingCount = stack.count - amount
	local remaining = remainingCount > 0 and MC.CopyItemStack( stack, remainingCount ) or nil
	local selectedReplacement = remaining or converted
	local ok, setError = MC.ContainerSetStack( record.container, slotIndex, selectedReplacement )
	if not ok then
		MC.ContainerRestore( record.container, snapshot )
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
		MC.ContainerRestore( record.container, snapshot )
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
