--[[----------------------------------------------------------------------------
	Client mirror of the authoritative player inventory and active menu.

	State.slots always remains the 36-slot player inventory used by the hotbar
	and held-item renderer.  State.menu is the currently synchronized menu view
	(player, chest, crafting, ...), so block containers never replace that base
	player state.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ClientInventory = MC.ClientInventory or {
	ready = false,
	revision = 0,
	selected = 0,
	slots = {},
	menu = nil,
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

local function decodeEntries( entries, slotCount, errorCode )
	if entries ~= nil and type( entries ) ~= "table" then return nil, errorCode end
	local slots, seen = {}, {}
	for _, entry in ipairs( entries or {} ) do
		local index = math.floor( tonumber( entry and entry.slot ) or -1 )
		if index < 0 or index >= slotCount or seen[index] then return nil, errorCode end
		seen[index] = true
		local stack, err = MC.InventoryStackFromData( entry.stack )
		if not stack and err then return nil, err end
		slots[index + 1] = stack
	end
	return slots
end

local function playerSlotsFromMenu( menuSlots, playerOffset )
	local slots = {}
	for index = 0, 35 do slots[index + 1] = MC.CopyItemStack( menuSlots[playerOffset + index + 1] ) end
	return slots
end

function MC.ApplyClientInventorySnapshot( data )
	if type( data ) ~= "table" or math.floor( tonumber( data.version ) or -1 ) ~= 1 then
		return false, "invalid_inventory_snapshot"
	end
	if tostring( data.registryHash or "" ) ~= tostring( MC.ItemRegistryHash or "" ) then
		return false, "item_registry_mismatch"
	end
	local slotCount = math.floor( tonumber( data.slotCount ) or 36 )
	if slotCount < 1 or slotCount > 127 then return false, "invalid_inventory_slot_count" end
	local playerOffset = math.floor( tonumber( data.playerOffset ) or 0 )
	if playerOffset < 0 or playerOffset + 36 > slotCount then return false, "invalid_player_slot_offset" end
	local menuSlots, menuError = decodeEntries( data.items, slotCount, "invalid_inventory_menu_slot" )
	if not menuSlots then return false, menuError end
	local playerSlots
	if type( data.playerItems ) == "table" then
		playerSlots, menuError = decodeEntries( data.playerItems, 36, "invalid_inventory_slot" )
		if not playerSlots then return false, menuError end
	else
		playerSlots = playerSlotsFromMenu( menuSlots, playerOffset )
	end
	State.slots = playerSlots
	State.menu = {
		kind = tostring( data.menuKind or "player" ),
		slotCount = slotCount,
		playerOffset = playerOffset,
		chestSlots = math.max( 0, math.floor( tonumber( data.chestSlots ) or 0 ) ),
		slots = menuSlots,
	}
	State.revision = math.max( 0, math.floor( tonumber( data.revision ) or 0 ) )
	State.selected = math.Clamp( math.floor( tonumber( data.selected ) or 0 ), 0, 8 )
	State.ready = true
	emit( "MC.InventorySnapshot", State )
	emit( "MC.InventoryChanged", nil, State.revision, State )
	emit( "MC.InventoryMenuChanged", nil, State.revision, State )
	return true
end

function MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, cursorApplies )
	revision = math.max( 0, math.floor( tonumber( revision ) or 0 ) )
	if revision < State.revision then return false, "stale_inventory_delta" end
	local menu = State.menu or { kind = "player", slotCount = 36, playerOffset = 0, chestSlots = 0, slots = State.slots }
	State.menu = menu
	local menuChanged, playerChanged = {}, {}
	for index, stack in pairs( changed or {} ) do
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or index >= menu.slotCount then return false, "invalid_inventory_slot" end
		menu.slots[index + 1] = MC.CopyItemStack( stack )
		menuChanged[#menuChanged + 1] = index
		local playerIndex = index - menu.playerOffset
		if playerIndex >= 0 and playerIndex < 36 then
			State.slots[playerIndex + 1] = MC.CopyItemStack( stack )
			playerChanged[#playerChanged + 1] = playerIndex
		end
	end
	table.sort( menuChanged )
	table.sort( playerChanged )
	State.revision = revision
	State.selected = math.Clamp( math.floor( tonumber( selected ) or State.selected ), 0, 8 )
	if cursorApplies then State.cursor = MC.CopyItemStack( cursor ) end
	if #menuChanged > 0 then emit( "MC.InventoryMenuChanged", menuChanged, revision, State ) end
	if #playerChanged > 0 then emit( "MC.InventoryChanged", playerChanged, revision, State ) end
	emit( "MC.InventorySelectionChanged", State.selected, State )
	if cursorApplies then emit( "MC.InventoryCursorChanged", State.cursor, State ) end
	return true
end

function MC.GetClientInventoryStack( slot )
	slot = math.floor( tonumber( slot ) or -1 )
	if slot < 0 or slot >= 36 then return nil end
	return MC.CopyItemStack( State.slots[slot + 1] )
end

function MC.GetClientMenuStack( slot )
	local menu = State.menu
	slot = math.floor( tonumber( slot ) or -1 )
	if not menu or slot < 0 or slot >= menu.slotCount then return nil end
	return MC.CopyItemStack( menu.slots[slot + 1] )
end

function MC.GetClientSelectedStack() return MC.GetClientInventoryStack( State.selected ) end
function MC.GetClientInventorySelectedSlot() return State.selected end
function MC.IsClientInventoryReady() return State.ready == true end
function MC.IsClientInventoryOpen() return type( State.session ) == "table" and State.session.token ~= nil end
