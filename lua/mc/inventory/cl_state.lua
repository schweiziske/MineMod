--[[----------------------------------------------------------------------------
	Client mirror of the authoritative 36-slot player inventory.
	Rendering code subscribes to changes; it never polls or owns canonical state.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ClientInventory = MC.ClientInventory or {
	ready = false,
	revision = 0,
	selected = 0,
	slots = {},
	cursor = nil,
	session = nil,
	actions = {},
	nextActionId = 0,
}

local State = MC.ClientInventory

local function emit( eventName, ... )
	if MC.RunEvent then MC.RunEvent( eventName, ... ) end
	if hook and hook.Run then hook.Run( string.gsub( eventName, "%.", "" ), ... ) end
end

function MC.ApplyClientInventorySnapshot( data )
	if type( data ) ~= "table" or math.floor( tonumber( data.version ) or -1 ) ~= 1 then
		return false, "invalid_inventory_snapshot"
	end
	if tostring( data.registryHash or "" ) ~= tostring( MC.ItemRegistryHash or "" ) then
		return false, "item_registry_mismatch"
	end
	local slots, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		local index = math.floor( tonumber( entry and entry.slot ) or -1 )
		if index < 0 or index >= 36 or seen[index] then return false, "invalid_inventory_slot" end
		seen[index] = true
		local stack, err = MC.InventoryStackFromData( entry.stack )
		if not stack and err then return false, err end
		slots[index + 1] = stack
	end
	State.slots = slots
	State.revision = math.max( 0, math.floor( tonumber( data.revision ) or 0 ) )
	State.selected = math.Clamp( math.floor( tonumber( data.selected ) or 0 ), 0, 8 )
	State.ready = true
	emit( "MC.InventorySnapshot", State )
	emit( "MC.InventoryChanged", nil, State.revision, State )
	return true
end

function MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, cursorApplies )
	revision = math.max( 0, math.floor( tonumber( revision ) or 0 ) )
	if revision < State.revision then return false, "stale_inventory_delta" end
	local changedIndices = {}
	for index, stack in pairs( changed or {} ) do
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or index >= 36 then return false, "invalid_inventory_slot" end
		State.slots[index + 1] = MC.CopyItemStack( stack )
		changedIndices[#changedIndices + 1] = index
	end
	table.sort( changedIndices )
	State.revision = revision
	State.selected = math.Clamp( math.floor( tonumber( selected ) or State.selected ), 0, 8 )
	if cursorApplies then State.cursor = MC.CopyItemStack( cursor ) end
	if #changedIndices > 0 then emit( "MC.InventoryChanged", changedIndices, revision, State ) end
	emit( "MC.InventorySelectionChanged", State.selected, State )
	if cursorApplies then emit( "MC.InventoryCursorChanged", State.cursor, State ) end
	return true
end

function MC.GetClientInventoryStack( slot )
	slot = math.floor( tonumber( slot ) or -1 )
	if slot < 0 or slot >= 36 then return nil end
	return MC.CopyItemStack( State.slots[slot + 1] )
end

function MC.GetClientSelectedStack()
	return MC.GetClientInventoryStack( State.selected )
end

function MC.GetClientInventorySelectedSlot()
	return State.selected
end

function MC.IsClientInventoryReady()
	return State.ready == true
end

function MC.IsClientInventoryOpen()
	return type( State.session ) == "table" and State.session.token ~= nil
end
