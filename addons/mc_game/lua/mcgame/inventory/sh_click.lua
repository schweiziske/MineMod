--[[----------------------------------------------------------------------------
	Minecraft AbstractContainerMenu click semantics.

	All operations run against an atomic snapshot and return only changed slots.
	The server layer supplies ownership/session/reach/rate validation around this
	pure state machine; clients may run the same function for prediction.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ContainerInput = {
	PICKUP = 0,
	QUICK_MOVE = 1,
	SWAP = 2,
	CLONE = 3,
	THROW = 4,
	QUICK_CRAFT = 5,
	PICKUP_ALL = 6,
}

MC.ContainerInputName = {
	[0] = "pickup",
	[1] = "quick_move",
	[2] = "swap",
	[3] = "clone",
	[4] = "throw",
	[5] = "quick_craft",
	[6] = "pickup_all",
}

local OUTSIDE_SLOT = -999

local function resetQuickCraft( container )
	container.quickCraft = { status = 0, type = 0, slots = {} }
end

local function parityClicksEnabled( container, context )
	if type( context ) == "table" and context.parityClicks ~= nil then return context.parityClicks == true end
	return type( container ) == "table" and container.parityClicks == true
end

-- ItemStack.isSameItem (used by vanilla's repeated quick-move/throw loops)
-- intentionally ignores count and components.  Stack merging below still uses
-- ItemStack.isSameItemSameComponents where the reference does.
local function sameItem( left, right )
	return not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right )
		and left.item == right.item
end

local function canDragTo( container, slot, context )
	if not MC.ContainerCanDragTo then return true end
	return MC.ContainerCanDragTo( container, slot, context )
end

local function canTakeItemForPickAll( container, carried, slot, context )
	if slot.meta and slot.meta.role == "result" and ( container.crafting or container.anvil or container.merchant ) then return false end
	if not MC.ContainerCanTakeItemForPickAll then return true end
	return MC.ContainerCanTakeItemForPickAll( container, carried, slot, context )
end

local function canDrop( container, stack, context )
	if context and context.canDrop == false then return false end
	if type( container.canDrop ) == "function" then
		local called, allowed = pcall( container.canDrop, container, stack, context )
		return called and allowed ~= false
	end
	return true
end

local function queueDrop( container, state, stack, context )
	if MC.IsEmptyItemStack( stack ) then return true end
	if not canDrop( container, stack, context ) then return false, "drop_denied" end
	state.drops[#state.drops + 1] = MC.CopyItemStack( stack )
	return true
end

local function setCursor( container, stack )
	local ok, err = MC.ContainerSetCursor( container, stack )
	return ok, err
end

local function pickupOutside( container, button, state, context )
	local carried = container.cursor
	if MC.IsEmptyItemStack( carried ) then return true end
	if button == 0 then
		local ok, err = queueDrop( container, state, carried, context )
		if not ok then return false, err end
		return setCursor( container, nil )
	end
	if button == 1 then
		local remaining, dropped = MC.SplitItemStack( carried, 1 )
		local ok, err = queueDrop( container, state, dropped, context )
		if not ok then return false, err end
		return setCursor( container, remaining )
	end
	return false, "invalid_button"
end

local function executePickup( container, slotIndex, button, state, context )
	if button ~= 0 and button ~= 1 then return false, "invalid_button" end
	if slotIndex == OUTSIDE_SLOT then return pickupOutside( container, button, state, context ) end
	local slot = MC.ContainerGetSlot( container, slotIndex )
	if not slot then return false, "invalid_slot" end
	if slot.meta and slot.meta.role == "result" then
		if type( container.takeResult ) ~= "function" then return false, "result_unavailable" end
		return container.takeResult( container, slotIndex, button, state, context, "pickup" )
	end

	local clicked = MC.InventorySlotGet( slot )
	local carried = container.cursor
	if MC.IsEmptyItemStack( clicked ) then
		if MC.IsEmptyItemStack( carried ) then return true end
		if not MC.InventorySlotMayPlace( slot, carried, context ) then return false, "place_denied" end
		local amount = button == 0 and carried.count or 1
		local remaining, moved, err = MC.InventorySlotInsert( slot, carried, amount, context )
		if err and moved == 0 then return false, err end
		return setCursor( container, remaining )
	end

	if not MC.InventorySlotMayTake( slot, context ) then return false, "take_denied" end
	if MC.IsEmptyItemStack( carried ) then
		local amount = button == 0 and clicked.count or math.floor( ( clicked.count + 1 ) / 2 )
		local extracted, err = MC.InventorySlotTake( slot, amount, context )
		if err then return false, err end
		return setCursor( container, extracted )
	end

	if MC.InventorySlotMayPlace( slot, carried, context ) then
		if MC.ItemStacksCanMerge( clicked, carried ) then
			local amount = button == 0 and carried.count or 1
			local remaining, _, err = MC.InventorySlotInsert( slot, carried, amount, context )
			if err and err ~= "different_item" then return false, err end
			return setCursor( container, remaining )
		end
		if carried.count <= MC.InventorySlotLimit( slot, carried ) then
			local ok, err = MC.InventorySlotSet( slot, carried )
			if not ok then return false, err end
			return setCursor( container, clicked )
		end
	elseif MC.ItemStacksCanMerge( clicked, carried ) then
		local room = MC.ItemStackMaxCount( carried ) - carried.count
		if room > 0 then
			local extracted, err = MC.InventorySlotTake( slot, math.min( clicked.count, room ), context )
			if err then return false, err end
			if extracted then return setCursor( container, MC.CopyItemStack( carried, carried.count + extracted.count ) ) end
		end
	end
	return true
end

local function executeQuickMove( container, slotIndex, state, context )
	if slotIndex < 0 then return false, "invalid_slot" end
	local slot = MC.ContainerGetSlot( container, slotIndex )
	if slot and slot.meta and slot.meta.role == "result" then
		if type( container.takeResult ) ~= "function" then return false, "result_unavailable" end
		return container.takeResult( container, slotIndex, 0, state, context, "quick_move" )
	end
	if not parityClicksEnabled( container, context ) then
		return MC.ContainerQuickMove( container, slotIndex, context )
	end

	-- AbstractContainerMenu keeps calling quickMoveStack while the returned
	-- stack is still the same item as the source.  This matters for menus whose
	-- target has less than one full stack of room: one packet may move several
	-- partial stacks before the source finally becomes empty or changes type.
	local changedAny = false
	local limit = math.max( 1, math.floor( tonumber( MC.ItemAbsoluteMaxStack ) or 99 ) + 1 )
	for _ = 1, limit do
		local before = MC.CopyItemStack( MC.ContainerGetStack( container, slotIndex ) )
		local called, ok, changed, returned = pcall( MC.ContainerQuickMove, container, slotIndex, context )
		if not called then return false, "quick_move_error" end
		if ok ~= true then return false, changed or "quick_move_rejected" end
		if changed ~= true then break end
		changedAny = true
		local after = MC.ContainerGetStack( container, slotIndex )
		local comparison = returned or before
		if MC.IsEmptyItemStack( after ) or not sameItem( after, comparison ) then break end
	end
	return true, changedAny
end

local function findInventoryTargets( container, excluded )
	local targets = {}
	for _, group in ipairs( { "main", "hotbar" } ) do
		for _, index in ipairs( container.groups[group] or {} ) do
			if index ~= excluded then targets[#targets + 1] = index end
		end
	end
	return targets
end

local function executeSwap( container, slotIndex, button, state, context )
	local parity = parityClicksEnabled( container, context )
	if ( button < 0 or button > 8 ) and ( not parity or button ~= 40 ) then return false, "invalid_hotbar_button" end
	local target = MC.ContainerGetSlot( container, slotIndex )
	if not target then return false, "invalid_slot" end
	if target and target.meta and target.meta.role == "result" then
		if type( container.takeResult ) ~= "function" then return false, "result_unavailable" end
		local existing, _, sourceError = MC.ContainerGetSwapStack( container, button, context )
		if sourceError then return false, sourceError end
		-- Result slots reject placement, so SWAP can take only into an empty
		-- hotbar/offhand endpoint. Use the result transaction for both endpoints.
		if not MC.IsEmptyItemStack( existing ) then return true end
		local carried = container.cursor
		container.cursor = nil
		local ok, err = container.takeResult( container, slotIndex, 0, state, context, "pickup" )
		if not ok then return false, err end
		ok, err = MC.ContainerSetSwapStack( container, button, container.cursor, context )
		if not ok then return false, err end
		return setCursor( container, carried )
	end
	local sourceStack, sourceSlot, sourceError = MC.ContainerGetSwapStack( container, button, context )
	if sourceError then return false, sourceError end
	if sourceSlot and sourceSlot == target then return true end
	if button == 40 and target.meta and target.meta.equipmentSlot == "offhand" then return true end
	local targetStack = MC.InventorySlotGet( target )
	if MC.IsEmptyItemStack( sourceStack ) and MC.IsEmptyItemStack( targetStack ) then return true end
	if not MC.InventorySlotMayTake( target, context ) and not MC.IsEmptyItemStack( targetStack ) then return false, "take_denied" end
	if not MC.IsEmptyItemStack( sourceStack ) and not MC.InventorySlotMayPlace( target, sourceStack, context ) then return false, "place_denied" end

	if MC.IsEmptyItemStack( targetStack ) then
		local limit = MC.InventorySlotLimit( target, sourceStack )
		local placedCount = math.min( sourceStack.count, limit )
		local placed = MC.CopyItemStack( sourceStack, placedCount )
		local remaining = sourceStack.count > placedCount and MC.CopyItemStack( sourceStack, sourceStack.count - placedCount ) or nil
		local ok, err = MC.InventorySlotSet( target, placed )
		if not ok then return false, err end
		return MC.ContainerSetSwapStack( container, button, remaining, context )
	end

	if MC.IsEmptyItemStack( sourceStack ) then
		local ok, err = MC.ContainerSetSwapStack( container, button, targetStack, context )
		if not ok then return false, err end
		ok, err = MC.InventorySlotSet( target, nil )
		return ok, err
	end

	local targetLimit = MC.InventorySlotLimit( target, sourceStack )
	if sourceStack.count <= targetLimit then
		local ok, err = MC.InventorySlotSet( target, sourceStack )
		if not ok then return false, err end
		return MC.ContainerSetSwapStack( container, button, targetStack, context )
	end

	-- Vanilla puts only the target slot's capacity into the menu and returns the
	-- displaced target stack through Inventory.add (or drops it if that fails).
	local placed = MC.CopyItemStack( sourceStack, targetLimit )
	local sourceRemainder = MC.CopyItemStack( sourceStack, sourceStack.count - targetLimit )
	local ok, err = MC.InventorySlotSet( target, placed )
	if not ok then return false, err end
	ok, err = MC.ContainerSetSwapStack( container, button, sourceRemainder, context )
	if not ok then return false, err end
	local displaced = targetStack
	local moved = false
	if type( container.addToInventory ) == "function" then
		local called, remainder, inserted = pcall( container.addToInventory, container, displaced, context )
		if not called then return false, "inventory_add_error" end
		moved = inserted == true or ( type( inserted ) == "number" and inserted > 0 )
		displaced = remainder
	else
		local targets = findInventoryTargets( container, sourceSlot and sourceSlot.index or nil )
		displaced, moved = MC.ContainerMoveStackTo( container, displaced, targets, context )
	end
	if not moved or not MC.IsEmptyItemStack( displaced ) then
		local dropOK, dropError = queueDrop( container, state, displaced or targetStack, context )
		if not dropOK then return false, dropError end
	end
	return true
end

local function executeClone( container, slotIndex, context )
	if not context or context.creative ~= true then return false, "creative_only" end
	if not MC.IsEmptyItemStack( container.cursor ) then return true end
	local slot = MC.ContainerGetSlot( container, slotIndex )
	if not slot then return false, "invalid_slot" end
	local stack = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( stack ) then return true end
	return setCursor( container, MC.CopyItemStack( stack, MC.ItemStackMaxCount( stack ) ) )
end

local function executeThrow( container, slotIndex, button, state, context )
	if button ~= 0 and button ~= 1 then return false, "invalid_button" end
	if not MC.IsEmptyItemStack( container.cursor ) then return true end
	local slot = MC.ContainerGetSlot( container, slotIndex )
	if not slot then return false, "invalid_slot" end
	if slot.meta and slot.meta.role == "result" then
		if type( container.takeResult ) ~= "function" then return false, "result_unavailable" end
		-- Taking a virtual result must run its recipe/payment transaction. Removing
		-- the display stack directly would leave the ingredients untouched.
		local initial = MC.InventorySlotGet( slot )
		local limit = button == 1 and ( MC.ItemAbsoluteMaxStack or 99 ) + 1 or 1
		for _ = 1, limit do
			if MC.IsEmptyItemStack( initial ) or not sameItem( initial, MC.InventorySlotGet( slot ) ) then break end
			local ok, err = container.takeResult( container, slotIndex, button, state, context, "throw" )
			if not ok then return false, err end
			local dropped = container.cursor
			if MC.IsEmptyItemStack( dropped ) then break end
			ok, err = queueDrop( container, state, dropped, context )
			if not ok then return false, err end
			ok, err = setCursor( container, nil )
			if not ok then return false, err end
		end
		return true
	end
	local initial = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( initial ) then return true end
	local amount = button == 0 and 1 or initial.count
	local extracted, err = MC.InventorySlotTake( slot, amount, context )
	if err then return false, err end
	local ok, dropError = queueDrop( container, state, extracted, context )
	if not ok then return false, dropError end
	if button == 1 and parityClicksEnabled( container, context ) then
		local last = extracted
		local limit = math.max( 1, math.floor( tonumber( MC.ItemAbsoluteMaxStack ) or 99 ) + 1 )
		for _ = 1, limit do
			local current = MC.InventorySlotGet( slot )
			if MC.IsEmptyItemStack( last ) or not sameItem( current, last ) then break end
			local nextStack, takeError = MC.InventorySlotTake( slot, amount, context )
			if takeError then return false, takeError end
			if MC.IsEmptyItemStack( nextStack ) then break end
			ok, dropError = queueDrop( container, state, nextStack, context )
			if not ok then return false, dropError end
			last = nextStack
		end
	end
	return true
end

local function quickCraftCanUse( container, slot, carried, context )
	if not slot or not MC.InventorySlotCanDrag( slot, carried, context ) then return false end
	if not canDragTo( container, slot, context ) then return false end
	local existing = MC.InventorySlotGet( slot )
	return MC.IsEmptyItemStack( existing ) or MC.ItemStacksCanMerge( existing, carried )
end

local function executeQuickCraft( container, slotIndex, button, state, context )
	local parity = parityClicksEnabled( container, context )
	local header = bit and bit.band and bit.band( button, 3 ) or button % 4
	local craftType = bit and bit.rshift and bit.band( bit.rshift( button, 2 ), 3 ) or math.floor( button / 4 ) % 4
	local quick = container.quickCraft

	-- This is the exact header state gate in AbstractContainerMenu#doClick:
	-- only status 1 -> header 2 and same-status repeats are legal.  Invalid
	-- sequences are ignored after resetting, rather than becoming a rejected
	-- mutation that changes the menu revision.
	local expectedStatus = quick.status
	if not parity then
		if header == 0 then
			if MC.IsEmptyItemStack( container.cursor ) then resetQuickCraft( container ) return false, "empty_cursor" end
			if craftType ~= 0 and craftType ~= 1 and not ( craftType == 2 and context and context.creative == true ) then
				resetQuickCraft( container )
				return false, "invalid_quick_craft_type"
			end
			quick.status, quick.type, quick.slots = 1, craftType, {}
			return true
		end
		if quick.status ~= 1 or quick.type ~= craftType or MC.IsEmptyItemStack( container.cursor ) then
			resetQuickCraft( container )
			return false, "quick_craft_sequence"
		end
	else
		quick.status = header
		if ( ( expectedStatus ~= 1 or quick.status ~= 2 ) and expectedStatus ~= quick.status ) then
			resetQuickCraft( container )
			return true
		end
		if MC.IsEmptyItemStack( container.cursor ) then
			resetQuickCraft( container )
			return true
		end
	end

	if header == 0 then
		if craftType ~= 0 and craftType ~= 1 and not ( craftType == 2 and context and context.creative == true ) then
			resetQuickCraft( container )
			return true
		end
		quick.status = 1
		quick.type = craftType
		quick.slots = {}
		return true
	end

	if quick.type ~= craftType then
		resetQuickCraft( container )
		return true
	end
	if header == 1 then
		local slot = MC.ContainerGetSlot( container, slotIndex )
		local selectedCount = 0
		for _ in pairs( quick.slots ) do selectedCount = selectedCount + 1 end
		if quickCraftCanUse( container, slot, container.cursor, context )
		and ( craftType == 2 or container.cursor.count > selectedCount ) then
			quick.slots[slotIndex] = true
		end
		return true
	end
	if header ~= 2 then
		resetQuickCraft( container )
		return parity and true or false, parity and nil or "invalid_quick_craft_header"
	end

	local indices = {}
	for index in pairs( quick.slots ) do indices[#indices + 1] = index end
	table.sort( indices )
	if #indices == 1 then
		local only = indices[1]
		resetQuickCraft( container )
		-- AbstractContainerMenu calls doClick(only, quickcraftType, PICKUP).
		-- Type 2 therefore intentionally does nothing here: button 2 is not a
		-- normal pickup button, even in creative mode.
		if parity and craftType == 2 then return true end
		return executePickup( container, only, parity and craftType or ( craftType == 1 and 1 or 0 ), state, context )
	end
	if #indices == 0 then resetQuickCraft( container ) return true end

	local source = MC.CopyItemStack( container.cursor )
	local remaining = source.count
	local each = craftType == 0 and math.floor( source.count / #indices ) or craftType == 1 and 1 or MC.ItemStackMaxCount( source )
	for _, index in ipairs( indices ) do
		local slot = MC.ContainerGetSlot( container, index )
		if quickCraftCanUse( container, slot, source, context )
		and ( craftType == 2 or source.count >= #indices ) then
			local existing = MC.InventorySlotGet( slot )
			local current = existing and existing.count or 0
			local targetCount = math.min( current + each, MC.InventorySlotLimit( slot, source ) )
			local delta = math.max( 0, targetCount - current )
			if delta > 0 then
				local placed = existing and MC.CopyItemStack( existing, targetCount ) or MC.CopyItemStack( source, targetCount )
				local ok, err = MC.InventorySlotSet( slot, placed )
				if not ok then resetQuickCraft( container ) return false, err end
				if parity or craftType ~= 2 then remaining = remaining - delta end
			end
		end
	end
	local cursor = not parity and craftType == 2 and source or remaining > 0 and MC.CopyItemStack( source, remaining ) or nil
	resetQuickCraft( container )
	return setCursor( container, cursor )
end

local function executePickupAll( container, slotIndex, button, context )
	if button ~= 0 and button ~= 1 then return false, "invalid_button" end
	if slotIndex < 0 then return false, "invalid_slot" end
	local carried = container.cursor
	if MC.IsEmptyItemStack( carried ) then return true end
	local clickedSlot = MC.ContainerGetSlot( container, slotIndex )
	if not clickedSlot then return false, "invalid_slot" end
	local clicked = MC.InventorySlotGet( clickedSlot )
	if not parityClicksEnabled( container, context ) then
		if not MC.IsEmptyItemStack( clicked ) then return true end
	elseif not MC.IsEmptyItemStack( clicked ) and MC.InventorySlotMayTake( clickedSlot, context ) then
		return true
	end

	local ordered = {}
	if button == 0 then
		for _, slot in ipairs( container.slots ) do ordered[#ordered + 1] = slot end
	else
		for index = #container.slots, 1, -1 do ordered[#ordered + 1] = container.slots[index] end
	end
	for pass = 1, 2 do
		for _, slot in ipairs( ordered ) do
			if carried.count >= MC.ItemStackMaxCount( carried ) then break end
			local stack = MC.InventorySlotGet( slot )
			if not MC.IsEmptyItemStack( stack ) and MC.ItemStacksCanMerge( stack, carried )
			and MC.InventorySlotMayTake( slot, context )
			and canTakeItemForPickAll( container, carried, slot, context )
			and ( pass == 2 or stack.count < MC.ItemStackMaxCount( stack ) ) then
				local room = MC.ItemStackMaxCount( carried ) - carried.count
				local extracted, err = MC.InventorySlotTake( slot, math.min( stack.count, room ), context )
				if err then return false, err end
				if extracted then carried = MC.CopyItemStack( carried, carried.count + extracted.count ) end
			end
		end
	end
	return setCursor( container, carried )
end

local handlers = {
	[MC.ContainerInput.PICKUP] = executePickup,
	[MC.ContainerInput.QUICK_MOVE] = function( container, slotIndex, _, state, context ) return executeQuickMove( container, slotIndex, state, context ) end,
	[MC.ContainerInput.SWAP] = executeSwap,
	[MC.ContainerInput.CLONE] = function( container, slotIndex, _, _, context ) return executeClone( container, slotIndex, context ) end,
	[MC.ContainerInput.THROW] = executeThrow,
	[MC.ContainerInput.QUICK_CRAFT] = executeQuickCraft,
	[MC.ContainerInput.PICKUP_ALL] = function( container, slotIndex, button, _, context ) return executePickupAll( container, slotIndex, button, context ) end,
}

local function restoreFailedInput( container, snapshot, context, errorCode )
	MC.ContainerRestore( container, snapshot )
	if context and context.cancelDrops then context.cancelDrops() end
	if type( container.onInputRollback ) == "function" then
		pcall( container.onInputRollback, container, snapshot, context or container.context or {}, errorCode )
	end
end

function MC.ExecuteContainerInput( container, request, context )
	if type( container ) ~= "table" or type( request ) ~= "table" then return { ok = false, error = "invalid_request" } end
	local expectedRevision = request.revision ~= nil and math.floor( tonumber( request.revision ) or -1 ) or nil
	-- Reliable net messages are processed in action-id order.  Several locally
	-- predicted clicks can therefore share an older authoritative base while the
	-- server advances the container between them.  A future revision is invalid;
	-- an older one is reconciled by the authoritative delta returned below.
	if expectedRevision ~= nil and expectedRevision > container.revision then
		return { ok = false, error = "revision_mismatch", revision = container.revision, full = MC.ContainerFullState( container ) }
	end
	local input = math.floor( tonumber( request.input ) or -1 )
	local slotIndex = math.floor( tonumber( request.slot ) or OUTSIDE_SLOT )
	local button = math.floor( tonumber( request.button ) or 0 )
	local handler = handlers[input]
	if not handler then return { ok = false, error = "invalid_input", revision = container.revision } end

	if input ~= MC.ContainerInput.QUICK_CRAFT and container.quickCraft and container.quickCraft.status ~= 0 then resetQuickCraft( container ) end
	local snapshot = MC.ContainerSnapshot( container )
	local state = { drops = {} }
	local called, ok, err = pcall( handler, container, slotIndex, button, state, context or container.context or {} )
	if not called or ok ~= true then
		local errorCode = called and ( err or "input_rejected" ) or "input_error"
		restoreFailedInput( container, snapshot, context, errorCode )
		return {
			ok = false,
			error = errorCode,
			revision = container.revision,
		}
	end
	-- Reserve drop entities before the menu commits recipe/payment side effects.
	-- Entity exhaustion must roll the input back, including external offhand
	-- storage, rather than consume an item that can never appear in the world.
	if #state.drops > 0 and context and context.prepareDrops then
		local prepared, prepareOK, prepareError = pcall( context.prepareDrops, state.drops )
		if not prepared or prepareOK ~= true then
			local errorCode = prepared and ( prepareError or "drop_spawn_failed" ) or "drop_reservation_error"
			restoreFailedInput( container, snapshot, context, errorCode )
			MC.Fault( "inventory_drop_reservation_failed", "%s", tostring( prepared and errorCode or prepareOK ) )
			return { ok = false, error = errorCode, revision = container.revision }
		end
	end
	if type( container.beforeCommit ) == "function" then
		local refreshCalled, refreshOK, refreshError = pcall( container.beforeCommit, container, context or container.context or {} )
		if not refreshCalled or refreshOK == false then
			local errorCode = refreshCalled and ( refreshError or "before_commit_rejected" ) or "before_commit_error"
			restoreFailedInput( container, snapshot, context, errorCode )
			return {
				ok = false,
				error = errorCode,
				revision = container.revision,
			}
		end
	end

	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	local cursorChanged = not MC.ItemStacksEqual( container.cursor, snapshot.cursor )
	local offhandChanged = container.swapRecord ~= nil
		and not MC.ItemStacksEqual( container.swapRecord.equipment.offhand, snapshot.offhand )
	if #changedSlots > 0 or cursorChanged or offhandChanged then container.revision = container.revision + 1 end
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) ) end
	local result = {
		ok = true,
		actionId = request.actionId,
		revision = container.revision,
		changedSlots = changedSlots,
		changed = changed,
		cursorChanged = cursorChanged,
		offhandChanged = offhandChanged,
		cursor = MC.CopyItemStack( container.cursor ),
		drops = state.drops,
	}
	if type( container.onCommit ) == "function" and ( #changedSlots > 0 or cursorChanged or offhandChanged or #state.drops > 0 ) then
		pcall( container.onCommit, container, result, context or container.context or {} )
	end
	return result
end
