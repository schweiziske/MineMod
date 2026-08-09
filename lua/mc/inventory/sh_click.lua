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
	return MC.ContainerQuickMove( container, slotIndex, context )
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
	if button < 0 or button > 8 then return false, "invalid_hotbar_button" end
	local target = MC.ContainerGetSlot( container, slotIndex )
	if target and target.meta and target.meta.role == "result" then
		-- Vanilla treats a number-key click on a result as taking the crafted
		-- output into the selected hotbar slot.  The crafting menu may opt into
		-- this path; otherwise reject it rather than exposing a normal storage
		-- swap that could duplicate the output.
		if type( container.takeResult ) ~= "function" then return false, "result_unavailable" end
		return container.takeResult( container, slotIndex, button, state, context, "swap" )
	end
	local hotbarIndex = container.hotbarSlots[button + 1]
	local hotbar = hotbarIndex ~= nil and MC.ContainerGetSlot( container, hotbarIndex ) or nil
	if not target or not hotbar then return false, "missing_hotbar_slot" end
	if target == hotbar then return true end

	local sourceStack = MC.InventorySlotGet( hotbar )
	local targetStack = MC.InventorySlotGet( target )
	if MC.IsEmptyItemStack( sourceStack ) and MC.IsEmptyItemStack( targetStack ) then return true end
	if not MC.InventorySlotMayTake( target, context ) and not MC.IsEmptyItemStack( targetStack ) then return false, "take_denied" end
	if not MC.IsEmptyItemStack( sourceStack ) and not MC.InventorySlotMayPlace( target, sourceStack, context ) then return false, "place_denied" end
	if not MC.IsEmptyItemStack( targetStack ) and not MC.InventorySlotMayPlace( hotbar, targetStack, context ) then return false, "hotbar_place_denied" end

	if MC.IsEmptyItemStack( targetStack ) then
		local limit = MC.InventorySlotLimit( target, sourceStack )
		local placedCount = math.min( sourceStack.count, limit )
		local placed = MC.CopyItemStack( sourceStack, placedCount )
		local remaining = sourceStack.count > placedCount and MC.CopyItemStack( sourceStack, sourceStack.count - placedCount ) or nil
		local ok, err = MC.InventorySlotSet( target, placed )
		if not ok then return false, err end
		return MC.InventorySlotSet( hotbar, remaining )
	end

	if MC.IsEmptyItemStack( sourceStack ) then
		local ok, err = MC.InventorySlotSet( hotbar, targetStack )
		if not ok then return false, err end
		return MC.InventorySlotSet( target, nil )
	end

	local targetLimit = MC.InventorySlotLimit( target, sourceStack )
	if sourceStack.count <= targetLimit then
		local ok, err = MC.InventorySlotSet( target, sourceStack )
		if not ok then return false, err end
		return MC.InventorySlotSet( hotbar, targetStack )
	end

	-- Armor/result-like slots may accept only part of a hotbar stack.  Vanilla
	-- returns the displaced item to the rest of the player inventory or drops it.
	local placed = MC.CopyItemStack( sourceStack, targetLimit )
	local sourceRemainder = MC.CopyItemStack( sourceStack, sourceStack.count - targetLimit )
	local ok, err = MC.InventorySlotSet( target, placed )
	if not ok then return false, err end
	ok, err = MC.InventorySlotSet( hotbar, sourceRemainder )
	if not ok then return false, err end
	local displaced, moved = MC.ContainerMoveStackTo( container, targetStack, findInventoryTargets( container, hotbarIndex ), context )
	if not moved or not MC.IsEmptyItemStack( displaced ) then
		local dropped = displaced or targetStack
		local dropOK, dropError = queueDrop( container, state, dropped, context )
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
	if slot.meta and slot.meta.role == "result" then return false, "result_cannot_throw" end
	local stack = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( stack ) then return true end
	local amount = button == 0 and 1 or stack.count
	local extracted, err = MC.InventorySlotTake( slot, amount, context )
	if err then return false, err end
	return queueDrop( container, state, extracted, context )
end

local function quickCraftCanUse( slot, carried, context )
	if not slot or not MC.InventorySlotCanDrag( slot, carried, context ) then return false end
	local existing = MC.InventorySlotGet( slot )
	return MC.IsEmptyItemStack( existing ) or MC.ItemStacksCanMerge( existing, carried )
end

local function executeQuickCraft( container, slotIndex, button, state, context )
	local header = bit and bit.band and bit.band( button, 3 ) or button % 4
	local craftType = bit and bit.rshift and bit.band( bit.rshift( button, 2 ), 3 ) or math.floor( button / 4 ) % 4
	local quick = container.quickCraft

	if header == 0 then
		if MC.IsEmptyItemStack( container.cursor ) then resetQuickCraft( container ) return false, "empty_cursor" end
		if craftType ~= 0 and craftType ~= 1 and not ( craftType == 2 and context and context.creative == true ) then
			resetQuickCraft( container )
			return false, "invalid_quick_craft_type"
		end
		quick.status = 1
		quick.type = craftType
		quick.slots = {}
		return true
	end

	if quick.status ~= 1 or quick.type ~= craftType or MC.IsEmptyItemStack( container.cursor ) then
		resetQuickCraft( container )
		return false, "quick_craft_sequence"
	end
	if header == 1 then
		local slot = MC.ContainerGetSlot( container, slotIndex )
		local selectedCount = 0
		for _ in pairs( quick.slots ) do selectedCount = selectedCount + 1 end
		if quickCraftCanUse( slot, container.cursor, context )
		and ( craftType == 2 or container.cursor.count > selectedCount ) then
			quick.slots[slotIndex] = true
		end
		return true
	end
	if header ~= 2 then resetQuickCraft( container ) return false, "invalid_quick_craft_header" end

	local indices = {}
	for index in pairs( quick.slots ) do indices[#indices + 1] = index end
	table.sort( indices )
	if #indices == 1 then
		local only = indices[1]
		local pickupButton = craftType == 1 and 1 or 0
		resetQuickCraft( container )
		return executePickup( container, only, pickupButton, state, context )
	end
	if #indices == 0 then resetQuickCraft( container ) return true end

	local source = MC.CopyItemStack( container.cursor )
	local remaining = source.count
	local each = craftType == 0 and math.floor( source.count / #indices ) or craftType == 1 and 1 or MC.ItemStackMaxCount( source )
	for _, index in ipairs( indices ) do
		local slot = MC.ContainerGetSlot( container, index )
		if quickCraftCanUse( slot, source, context ) then
			local existing = MC.InventorySlotGet( slot )
			local current = existing and existing.count or 0
			local targetCount = math.min( current + each, MC.InventorySlotLimit( slot, source ) )
			local delta = math.max( 0, targetCount - current )
			if craftType == 2 or delta <= remaining then
				if delta > 0 then
					local placed = existing and MC.CopyItemStack( existing, targetCount ) or MC.CopyItemStack( source, targetCount )
					local ok, err = MC.InventorySlotSet( slot, placed )
					if not ok then resetQuickCraft( container ) return false, err end
					if craftType ~= 2 then remaining = remaining - delta end
				end
			end
		end
	end
	local cursor = craftType == 2 and source or remaining > 0 and MC.CopyItemStack( source, remaining ) or nil
	resetQuickCraft( container )
	return setCursor( container, cursor )
end

local function executePickupAll( container, slotIndex, button, context )
	if button ~= 0 and button ~= 1 then return false, "invalid_button" end
	if slotIndex < 0 then return false, "invalid_slot" end
	local carried = container.cursor
	if MC.IsEmptyItemStack( carried ) then return true end
	local clicked = MC.ContainerGetStack( container, slotIndex )
	if not MC.IsEmptyItemStack( clicked ) then return true end

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
			and not ( slot.meta and slot.meta.role == "result" )
			and MC.InventorySlotMayTake( slot, context )
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

function MC.ExecuteContainerInput( container, request, context )
	if type( container ) ~= "table" or type( request ) ~= "table" then return { ok = false, error = "invalid_request" } end
	local expectedRevision = request.revision ~= nil and math.floor( tonumber( request.revision ) or -1 ) or nil
	if expectedRevision ~= nil and expectedRevision ~= container.revision then
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
		MC.ContainerRestore( container, snapshot )
		return {
			ok = false,
			error = called and ( err or "input_rejected" ) or "input_error",
			revision = container.revision,
		}
	end
	if type( container.beforeCommit ) == "function" then
		local refreshCalled, refreshOK, refreshError = pcall( container.beforeCommit, container, context or container.context or {} )
		if not refreshCalled or refreshOK == false then
			MC.ContainerRestore( container, snapshot )
			return {
				ok = false,
				error = refreshCalled and ( refreshError or "before_commit_rejected" ) or "before_commit_error",
				revision = container.revision,
			}
		end
	end

	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	local cursorChanged = not MC.ItemStacksEqual( container.cursor, snapshot.cursor )
	if #changedSlots > 0 or cursorChanged then container.revision = container.revision + 1 end
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) ) end
	local result = {
		ok = true,
		actionId = request.actionId,
		revision = container.revision,
		changedSlots = changedSlots,
		changed = changed,
		cursorChanged = cursorChanged,
		cursor = MC.CopyItemStack( container.cursor ),
		drops = state.drops,
	}
	if type( container.onCommit ) == "function" and ( #changedSlots > 0 or cursorChanged or #state.drops > 0 ) then
		pcall( container.onCommit, container, result, context or container.context or {} )
	end
	return result
end
