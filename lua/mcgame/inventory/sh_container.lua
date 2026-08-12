--[[----------------------------------------------------------------------------
	Container/menu state shared by player inventories and block containers.
	Slots are zero-based to match Minecraft's packets and UI semantics.
------------------------------------------------------------------------------]]

MC = MC or {}

local function copyQuickCraft( quickCraft )
	local slots = {}
	for index in pairs( quickCraft and quickCraft.slots or {} ) do slots[index] = true end
	return {
		status = math.floor( tonumber( quickCraft and quickCraft.status ) or 0 ),
		type = math.floor( tonumber( quickCraft and quickCraft.type ) or 0 ),
		slots = slots,
	}
end

function MC.NewInventoryContainer( options )
	options = options or {}
	local container = {
		id = math.floor( tonumber( options.id ) or 0 ),
		kind = tostring( options.kind or "generic" ),
		revision = math.max( 0, math.floor( tonumber( options.revision ) or 0 ) ),
		slots = {},
		slotByIndex = {},
		groups = {},
		hotbarSlots = {},
		transferRules = options.transferRules or {},
		cursor = nil,
		quickCraft = { status = 0, type = 0, slots = {} },
		context = options.context,
		beforeCommit = options.beforeCommit,
		onCommit = options.onCommit,
	}
	if options.cursor ~= nil then
		local cursor, err = MC.NormalizeItemStack( options.cursor )
		if not cursor and err then return nil, err end
		container.cursor = cursor
	end
	for _, definition in ipairs( options.slots or {} ) do
		local slot, err = MC.ContainerAddSlot( container, definition )
		if not slot then return nil, err end
	end
	if type( options.hotbarSlots ) == "table" then
		for button = 1, 9 do
			local index = tonumber( options.hotbarSlots[button] )
			if index ~= nil then container.hotbarSlots[button] = math.floor( index ) end
		end
	end
	return container
end

function MC.ContainerAddSlot( container, definition )
	if type( container ) ~= "table" or type( definition ) ~= "table" then return nil, "invalid_slot_definition" end
	local index = definition.index
	if index == nil then index = #container.slots end
	index = math.floor( tonumber( index ) or -1 )
	if container.slotByIndex[index] then return nil, "duplicate_slot_index" end
	if #container.slots >= 128 then return nil, "too_many_slots" end
	local slot, err = MC.NewInventorySlot( definition, index )
	if not slot then return nil, err end
	container.slots[#container.slots + 1] = slot
	container.slotByIndex[index] = slot
	container.groups[slot.group] = container.groups[slot.group] or {}
	container.groups[slot.group][#container.groups[slot.group] + 1] = index
	return slot
end

function MC.ContainerGetSlot( container, index )
	return type( container ) == "table" and container.slotByIndex
		and container.slotByIndex[math.floor( tonumber( index ) or -32768 )] or nil
end

function MC.ContainerGetStack( container, index )
	local slot = MC.ContainerGetSlot( container, index )
	return slot and MC.InventorySlotGet( slot ) or nil
end

function MC.ContainerSetStack( container, index, stack )
	local slot = MC.ContainerGetSlot( container, index )
	if not slot then return false, "invalid_slot" end
	return MC.InventorySlotSet( slot, stack )
end

function MC.ContainerSetCursor( container, stack )
	if MC.IsEmptyItemStack( stack ) then container.cursor = nil return true end
	local normalized, err = MC.NormalizeItemStack( stack )
	if not normalized then return false, err end
	container.cursor = normalized
	return true
end

function MC.ContainerSnapshot( container )
	local snapshot = {
		revision = container.revision,
		cursor = MC.CopyItemStack( container.cursor ),
		quickCraft = copyQuickCraft( container.quickCraft ),
		slots = {},
	}
	for _, slot in ipairs( container.slots ) do
		snapshot.slots[slot.index] = MC.CopyItemStack( MC.InventorySlotGet( slot ) )
	end
	return snapshot
end

function MC.ContainerRestore( container, snapshot )
	for _, slot in ipairs( container.slots ) do
		slot.storage[slot.storageIndex] = MC.CopyItemStack( snapshot.slots[slot.index] )
	end
	container.cursor = MC.CopyItemStack( snapshot.cursor )
	container.quickCraft = copyQuickCraft( snapshot.quickCraft )
	container.revision = snapshot.revision
end

function MC.ContainerChangedSlots( container, snapshot )
	local changed = {}
	for _, slot in ipairs( container.slots ) do
		local current = MC.InventorySlotGet( slot )
		if not MC.ItemStacksEqual( current, snapshot.slots[slot.index] ) then changed[#changed + 1] = slot.index end
	end
	table.sort( changed )
	return changed
end

local function appendIndices( output, seen, values, reverse )
	if reverse then
		for position = #values, 1, -1 do
			local index = values[position]
			if not seen[index] then seen[index] = true output[#output + 1] = index end
		end
	else
		for _, index in ipairs( values ) do
			if not seen[index] then seen[index] = true output[#output + 1] = index end
		end
	end
end

function MC.ContainerResolveTargets( container, targetSpec, reverse )
	local output, seen = {}, {}
	for _, target in ipairs( targetSpec or {} ) do
		if type( target ) == "string" then
			appendIndices( output, seen, container.groups[target] or {}, reverse )
		elseif tonumber( target ) ~= nil then
			local index = math.floor( tonumber( target ) )
			if container.slotByIndex[index] and not seen[index] then seen[index] = true output[#output + 1] = index end
		end
	end
	return output
end

function MC.ContainerMoveStackTo( container, sourceStack, targetIndices, context )
	if MC.IsEmptyItemStack( sourceStack ) then return nil, false end
	local remaining = MC.CopyItemStack( sourceStack )
	local changed = false

	-- Vanilla first tops up compatible stacks, then occupies empty slots.
	for pass = 1, 2 do
		for _, index in ipairs( targetIndices or {} ) do
			if MC.IsEmptyItemStack( remaining ) then break end
			local slot = MC.ContainerGetSlot( container, index )
			if slot and MC.InventorySlotMayPlace( slot, remaining, context ) then
				local existing = MC.InventorySlotGet( slot )
				local eligible = pass == 1 and not MC.IsEmptyItemStack( existing ) and MC.ItemStacksCanMerge( existing, remaining )
					or pass == 2 and MC.IsEmptyItemStack( existing )
				if eligible then
					local moved
					remaining, moved = MC.InventorySlotInsert( slot, remaining, remaining.count, context )
					if moved and moved > 0 then changed = true end
				end
			end
		end
	end
	return remaining, changed
end

function MC.ContainerQuickMove( container, sourceIndex, context )
	local sourceSlot = MC.ContainerGetSlot( container, sourceIndex )
	if not sourceSlot then return false, "invalid_slot" end
	if not MC.InventorySlotMayTake( sourceSlot, context ) then return false, "take_denied" end
	local source = MC.InventorySlotGet( sourceSlot )
	if MC.IsEmptyItemStack( source ) then return true, false end

	local rule = container.transferRules[sourceSlot.group]
	if type( rule ) ~= "table" then return false, "no_quick_move_rule" end
	local targetSpec = rule.targets or rule
	if type( rule.resolve ) == "function" then
		local called, resolved = pcall( rule.resolve, container, source, sourceSlot, context or {} )
		if not called or type( resolved ) ~= "table" then return false, "quick_move_resolve_failed" end
		targetSpec = resolved
	end
	local targets = MC.ContainerResolveTargets( container, targetSpec, rule.reverse == true )
	local filtered = {}
	for _, index in ipairs( targets ) do if index ~= sourceIndex then filtered[#filtered + 1] = index end end
	local remaining, changed = MC.ContainerMoveStackTo( container, source, filtered, context )
	if not changed then return true, false end
	local ok, err = MC.InventorySlotSet( sourceSlot, remaining )
	if not ok then return false, err end
	return true, true
end

function MC.ContainerFullState( container )
	local state = {
		id = container.id,
		kind = container.kind,
		revision = container.revision,
		cursor = MC.CopyItemStack( container.cursor ),
		slots = {},
	}
	for _, slot in ipairs( container.slots ) do
		state.slots[#state.slots + 1] = {
			index = slot.index,
			group = slot.group,
			stack = MC.CopyItemStack( MC.InventorySlotGet( slot ) ),
		}
	end
	return state
end
