--[[----------------------------------------------------------------------------
	Inventory slot adapter.  Menu slots may point at player, chest, crafting or
	other backing tables while exposing one stable zero-based container index.
------------------------------------------------------------------------------]]

MC = MC or {}

local function callbackResult( callback, fallback, ... )
	if type( callback ) ~= "function" then return fallback end
	local called, result = pcall( callback, ... )
	return called and result ~= false
end

-- Equipment slots have one additional, game-layer veto boundary.  Keeping it
-- here makes every menu path (normal click, quick-move, number-key swap and
-- pickup-all) honor effects such as Minecraft's Curse of Binding.  The
-- authoritative server passes context.player; client previews without a player
-- simply remain permissive and are corrected by the server action result.
local function equipmentTakeAllowed( slot, stack, context )
	if not stack or type( slot ) ~= "table" or type( slot.meta ) ~= "table"
		or slot.meta.role ~= "equipment" then return true end
	local player = type( context ) == "table" and context.player or nil
	if not player or not hook or type( hook.Run ) ~= "function" then return true end
	local called, result = pcall( hook.Run, "MC.CanTakeEquipmentStack", player,
		slot.meta.equipmentSlot, stack, context or {} )
	return called and result ~= false
end

function MC.NewInventorySlot( definition, index )
	definition = definition or {}
	index = math.floor( tonumber( index ~= nil and index or definition.index ) or -1 )
	if index < 0 or index > 32767 then return nil, "invalid_slot_index" end
	local storage = definition.storage
	if type( storage ) ~= "table" then return nil, "invalid_slot_storage" end
	local storageIndex = definition.storageIndex
	if storageIndex == nil then storageIndex = index + 1 end
	if type( storageIndex ) ~= "number" and type( storageIndex ) ~= "string" then return nil, "invalid_storage_index" end

	local maxStack = math.floor( tonumber( definition.maxStack ) or ( MC.ItemAbsoluteMaxStack or 99 ) )
	if maxStack < 1 or maxStack > ( MC.ItemAbsoluteMaxStack or 99 ) then return nil, "invalid_slot_limit" end
	return {
		index = index,
		storage = storage,
		storageIndex = storageIndex,
		group = tostring( definition.group or "default" ),
		maxStack = maxStack,
		active = definition.active ~= false,
		readOnly = definition.readOnly == true,
		mayPlace = definition.mayPlace,
		mayTake = definition.mayTake,
		canDrag = definition.canDrag,
		meta = definition.meta,
	}
end

function MC.InventorySlotGet( slot )
	if type( slot ) ~= "table" or type( slot.storage ) ~= "table" then return nil end
	local stack = slot.storage[slot.storageIndex]
	if MC.IsEmptyItemStack( stack ) then return nil end
	return stack
end

function MC.InventorySlotSet( slot, stack )
	if type( slot ) ~= "table" or type( slot.storage ) ~= "table" then return false, "invalid_slot" end
	if not MC.IsEmptyItemStack( stack ) then
		local normalized, err = MC.NormalizeItemStack( stack )
		if not normalized then return false, err or "invalid_stack" end
		if normalized.count > MC.InventorySlotLimit( slot, normalized ) then return false, "slot_stack_too_large" end
		stack = normalized
	else
		stack = nil
	end
	slot.storage[slot.storageIndex] = stack
	return true
end

function MC.InventorySlotLimit( slot, stack )
	local itemLimit = MC.ItemStackMaxCount( stack )
	if itemLimit <= 0 then itemLimit = MC.ItemAbsoluteMaxStack or 99 end
	return math.min( math.floor( tonumber( slot and slot.maxStack ) or itemLimit ), itemLimit )
end

function MC.InventorySlotMayPlace( slot, stack, context )
	if type( slot ) ~= "table" or slot.active == false or slot.readOnly == true then return false end
	if MC.IsEmptyItemStack( stack ) then return true end
	return callbackResult( slot.mayPlace, true, slot, stack, context )
end

function MC.InventorySlotMayTake( slot, context )
	if type( slot ) ~= "table" or slot.active == false or slot.readOnly == true then return false end
	local stack = MC.InventorySlotGet( slot )
	if not callbackResult( slot.mayTake, true, slot, stack, context ) then return false end
	return equipmentTakeAllowed( slot, stack, context )
end

function MC.InventorySlotCanDrag( slot, stack, context )
	if not MC.InventorySlotMayPlace( slot, stack, context ) then return false end
	return callbackResult( slot.canDrag, true, slot, stack, context )
end

function MC.InventorySlotTake( slot, amount, context )
	if not MC.InventorySlotMayTake( slot, context ) then return nil, "take_denied" end
	local stack = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( stack ) then return nil end
	local remaining, extracted = MC.SplitItemStack( stack, amount )
	local ok, err = MC.InventorySlotSet( slot, remaining )
	if not ok then return nil, err end
	return extracted
end

function MC.InventorySlotInsert( slot, input, amount, context )
	if MC.IsEmptyItemStack( input ) then return nil, 0 end
	if not MC.InventorySlotMayPlace( slot, input, context ) then return MC.CopyItemStack( input ), 0, "place_denied" end
	local existing = MC.InventorySlotGet( slot )
	if not MC.IsEmptyItemStack( existing ) and not MC.ItemStacksCanMerge( existing, input ) then
		return MC.CopyItemStack( input ), 0, "different_item"
	end
	local limit = MC.InventorySlotLimit( slot, input )
	local room = limit - ( existing and existing.count or 0 )
	local move = math.min( room, input.count, math.max( 0, math.floor( tonumber( amount ) or input.count ) ) )
	if move <= 0 then return MC.CopyItemStack( input ), 0 end

	local placed = existing and MC.CopyItemStack( existing, existing.count + move ) or MC.CopyItemStack( input, move )
	local ok, err = MC.InventorySlotSet( slot, placed )
	if not ok then return MC.CopyItemStack( input ), 0, err end
	local remaining = input.count > move and MC.CopyItemStack( input, input.count - move ) or nil
	return remaining, move
end
