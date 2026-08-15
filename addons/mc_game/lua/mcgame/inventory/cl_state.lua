--[[----------------------------------------------------------------------------
	Client mirror of the authoritative player inventory and active menu.

	State.slots remains the 36-slot non-equipment inventory used by the hotbar.
	State.equipment mirrors EntityEquipment (armor/offhand), while State.menu is
	the currently synchronized player/chest/crafting view.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ClientInventory = MC.ClientInventory or {
	ready = false,
	revision = 0,
	selected = 0,
	slots = {},
	equipment = {},
	menu = nil,
	cursor = nil,
	session = nil,
	actions = {},
	nextActionId = 0,
	authoritative = nil,
	predictedContainer = nil,
	predictedRevision = 0,
}

local State = MC.ClientInventory
State.slots = State.slots or {}
State.equipment = State.equipment or {}
State.actions = State.actions or {}

local function copyArray( values, count )
	local output = {}
	for index = 1, count or #values do output[index] = MC.CopyItemStack( values and values[index] ) end
	return output
end

local function rememberAuthoritative()
	local menu = State.menu
	State.authoritative = {
		revision = State.revision,
		selected = State.selected,
		cursor = MC.CopyItemStack( State.cursor ),
		menuSlots = copyArray( menu and menu.slots or {}, menu and menu.slotCount or 0 ),
		playerSlots = copyArray( State.slots, 36 ),
		equipment = {},
	}
	for slot, stack in pairs( State.equipment or {} ) do
		State.authoritative.equipment[slot] = MC.CopyItemStack( stack )
	end
end

local function updateAuthoritativeFromDelta( revision, selected, changed, cursor, cursorApplies )
	local authoritative = State.authoritative
	if not authoritative then
		rememberAuthoritative()
		authoritative = State.authoritative
	end
	local menu = State.menu
	for index, stack in pairs( changed or {} ) do
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or not menu or index >= menu.slotCount then return false, "invalid_inventory_slot" end
		authoritative.menuSlots[index + 1] = MC.CopyItemStack( stack )
		local playerIndex = menu.playerSlotMap and menu.playerSlotMap[index] or index - menu.playerOffset
		if playerIndex ~= nil and playerIndex >= 0 and playerIndex < 36 then
			authoritative.playerSlots[playerIndex + 1] = MC.CopyItemStack( stack )
		end
		local equipmentSlot = menu.equipmentSlotMap and menu.equipmentSlotMap[index] or nil
		if equipmentSlot then authoritative.equipment[equipmentSlot] = MC.CopyItemStack( stack ) end
	end
	authoritative.revision = revision
	authoritative.selected = math.Clamp( math.floor( tonumber( selected ) or authoritative.selected or 0 ), 0, 8 )
	if cursorApplies then authoritative.cursor = MC.CopyItemStack( cursor ) end
	return true
end

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

local function decodeEquipmentEntries( entries )
	if entries ~= nil and type( entries ) ~= "table" then return nil, "invalid_equipment_items" end
	local equipment, seen = {}, {}
	for _, entry in ipairs( entries or {} ) do
		local slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( entry and entry.slot ) or nil
		if not slot or seen[slot] then return nil, "invalid_equipment_slot" end
		seen[slot] = true
		local stack, err = MC.InventoryStackFromData( entry.stack )
		if not stack and err then return nil, err end
		if stack and not MC.ItemCanEquipInSlot( stack, slot ) then return nil, "equipment_slot_rejected" end
		equipment[slot] = stack
	end
	return equipment
end

local function decodeSlotMaps( data, slotCount )
	if data.playerSlotMap ~= nil and type( data.playerSlotMap ) ~= "table" then
		return nil, "invalid_player_slot_map"
	end
	if data.equipmentSlotMap ~= nil and type( data.equipmentSlotMap ) ~= "table" then
		return nil, "invalid_equipment_slot_map"
	end
	local playerByMenu, menuByPlayer, equipmentByMenu, menuByEquipment = {}, {}, {}, {}
	for _, entry in ipairs( data.playerSlotMap or {} ) do
		local playerIndex = math.floor( tonumber( entry and entry.player ) or -1 )
		local menuIndex = math.floor( tonumber( entry and entry.menu ) or -1 )
		if playerIndex < 0 or playerIndex >= 36 or menuIndex < 0 or menuIndex >= slotCount
		or playerByMenu[menuIndex] ~= nil or menuByPlayer[playerIndex] ~= nil then
			return nil, "invalid_player_slot_map"
		end
		playerByMenu[menuIndex], menuByPlayer[playerIndex] = playerIndex, menuIndex
	end
	for _, entry in ipairs( data.equipmentSlotMap or {} ) do
		local slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( entry and entry.slot ) or nil
		local menuIndex = math.floor( tonumber( entry and entry.menu ) or -1 )
		if not slot or menuIndex < 0 or menuIndex >= slotCount
		or equipmentByMenu[menuIndex] ~= nil or menuByEquipment[slot] ~= nil
		or playerByMenu[menuIndex] ~= nil then
			return nil, "invalid_equipment_slot_map"
		end
		equipmentByMenu[menuIndex], menuByEquipment[slot] = slot, menuIndex
	end
	return {
		playerByMenu = playerByMenu, menuByPlayer = menuByPlayer,
		equipmentByMenu = equipmentByMenu, menuByEquipment = menuByEquipment,
	}
end

local function playerSlotsFromMenu( menuSlots, playerOffset, menuByPlayer )
	local slots = {}
	for index = 0, 35 do
		local menuIndex = menuByPlayer and menuByPlayer[index] or playerOffset + index
		slots[index + 1] = menuIndex ~= nil and MC.CopyItemStack( menuSlots[menuIndex + 1] ) or nil
	end
	return slots
end

function MC.ApplyClientInventorySnapshot( data )
	if type( data ) ~= "table" or math.floor( tonumber( data.version ) or -1 ) ~= 1 then
		return false, "invalid_inventory_snapshot"
	end
	if tostring( data.registryHash or "" ) ~= tostring( MC.ItemRegistryHash or "" ) then
		return false, "item_registry_mismatch"
	end
	if data.recipeRegistryHash ~= nil
	and tostring( data.recipeRegistryHash or "" ) ~= tostring( MC.RecipeRegistryHash or "" ) then
		return false, "recipe_registry_mismatch"
	end
	local slotCount = math.floor( tonumber( data.slotCount ) or 36 )
	if slotCount < 1 or slotCount > 127 then return false, "invalid_inventory_slot_count" end
	local playerOffset = math.floor( tonumber( data.playerOffset ) or 0 )
	if playerOffset < 0 or playerOffset + 36 > slotCount then return false, "invalid_player_slot_offset" end
	local crafting = data.crafting == true
	local craftingWidth = math.floor( tonumber( data.craftingWidth ) or 0 )
	local craftingHeight = math.floor( tonumber( data.craftingHeight ) or 0 )
	local resultSlot = math.floor( tonumber( data.resultSlot ) or 0 )
	if crafting and ( craftingWidth < 1 or craftingHeight < 1 or craftingWidth * craftingHeight > 9
		or resultSlot < 0 or resultSlot >= slotCount
		or playerOffset < resultSlot + craftingWidth * craftingHeight + 1 ) then
		return false, "invalid_crafting_menu"
	end
	local menuSlots, menuError = decodeEntries( data.items, slotCount, "invalid_inventory_menu_slot" )
	if not menuSlots then return false, menuError end
	local maps, mapError = decodeSlotMaps( data, slotCount )
	if not maps then return false, mapError end
	local playerSlots
	if type( data.playerItems ) == "table" then
		playerSlots, menuError = decodeEntries( data.playerItems, 36, "invalid_inventory_slot" )
		if not playerSlots then return false, menuError end
	else
		playerSlots = playerSlotsFromMenu( menuSlots, playerOffset, maps.menuByPlayer )
	end
	local equipment, equipmentError = decodeEquipmentEntries( data.equipmentItems )
	if not equipment then return false, equipmentError end
	State.slots = playerSlots
	State.equipment = equipment
	State.menu = {
		kind = tostring( data.menuKind or "player" ),
		recipeRegistryHash = tostring( data.recipeRegistryHash or MC.RecipeRegistryHash or "" ),
		slotCount = slotCount,
		playerOffset = playerOffset,
		chestSlots = math.max( 0, math.floor( tonumber( data.chestSlots ) or 0 ) ),
		crafting = crafting,
		craftingWidth = math.max( 0, craftingWidth ),
		craftingHeight = math.max( 0, craftingHeight ),
		resultSlot = math.max( 0, resultSlot ),
		slots = menuSlots,
		playerSlotMap = maps.playerByMenu,
		menuPlayerMap = maps.menuByPlayer,
		equipmentSlotMap = maps.equipmentByMenu,
		menuEquipmentMap = maps.menuByEquipment,
	}
	State.revision = math.max( 0, math.floor( tonumber( data.revision ) or 0 ) )
	State.selected = math.Clamp( math.floor( tonumber( data.selected ) or 0 ), 0, 8 )
	State.ready = true
	State.actions = {}
	State.predictedContainer = nil
	State.predictedRevision = State.revision
	rememberAuthoritative()
	emit( "MC.InventorySnapshot", State )
	emit( "MC.InventoryChanged", nil, State.revision, State )
	emit( "MC.InventoryMenuChanged", nil, State.revision, State )
	emit( "MC.EquipmentChanged", nil, State.revision, State )
	return true
end

function MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, cursorApplies )
	revision = math.max( 0, math.floor( tonumber( revision ) or 0 ) )
	if revision < State.revision then return false, "stale_inventory_delta" end
	local menu = State.menu or {
		kind = "player", slotCount = 36, playerOffset = 0, chestSlots = 0,
		recipeRegistryHash = tostring( MC.RecipeRegistryHash or "" ), slots = State.slots,
	}
	State.menu = menu
	local menuChanged, playerChanged, equipmentChanged = {}, {}, {}
	for index in pairs( changed or {} ) do
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or index >= menu.slotCount then return false, "invalid_inventory_slot" end
		menuChanged[#menuChanged + 1] = index
		local playerIndex = menu.playerSlotMap and menu.playerSlotMap[index] or index - menu.playerOffset
		if playerIndex ~= nil and playerIndex >= 0 and playerIndex < 36 then playerChanged[#playerChanged + 1] = playerIndex end
		local equipmentSlot = menu.equipmentSlotMap and menu.equipmentSlotMap[index] or nil
		if equipmentSlot then equipmentChanged[#equipmentChanged + 1] = equipmentSlot end
	end
	local cursorApplies = cursorApplies == true
	local remembered, rememberError = updateAuthoritativeFromDelta( revision, selected, changed, cursor, cursorApplies )
	if not remembered then return false, rememberError end
	local predictionRebuilt = MC.RebuildClientPrediction and MC.RebuildClientPrediction( true ) == true
	if not predictionRebuilt then
		for index, stack in pairs( changed or {} ) do menu.slots[index + 1] = MC.CopyItemStack( stack ) end
		State.slots = copyArray( State.authoritative.playerSlots, 36 )
		State.equipment = State.authoritative.equipment
		State.revision = revision
		State.selected = State.authoritative.selected
		if cursorApplies then State.cursor = MC.CopyItemStack( cursor ) end
	end
	table.sort( menuChanged )
	table.sort( playerChanged )
	State.revision = revision
	State.selected = math.Clamp( math.floor( tonumber( selected ) or State.selected ), 0, 8 )
	if #menuChanged > 0 then emit( "MC.InventoryMenuChanged", menuChanged, revision, State ) end
	if #playerChanged > 0 then emit( "MC.InventoryChanged", playerChanged, revision, State ) end
	if #equipmentChanged > 0 then emit( "MC.EquipmentChanged", equipmentChanged, revision, State ) end
	emit( "MC.InventorySelectionChanged", State.selected, State )
	if cursorApplies then emit( "MC.InventoryCursorChanged", State.cursor, State ) end
	return true
end

function MC.ApplyClientEquipmentDelta( revision, changed )
	revision = math.max( 0, math.floor( tonumber( revision ) or 0 ) )
	if revision < State.revision then return false, "stale_equipment_delta" end
	local changedSlots = {}
	State.equipment = State.equipment or {}
	if not State.authoritative then rememberAuthoritative() end
	for slot, stack in pairs( changed or {} ) do
		slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or nil
		if not slot then return false, "invalid_equipment_slot" end
		if stack and not MC.ItemCanEquipInSlot( stack, slot ) then return false, "equipment_slot_rejected" end
		State.equipment[slot] = MC.CopyItemStack( stack )
		changedSlots[#changedSlots + 1] = slot
		local menuIndex = State.menu and State.menu.menuEquipmentMap and State.menu.menuEquipmentMap[slot] or nil
		if menuIndex ~= nil then State.menu.slots[menuIndex + 1] = MC.CopyItemStack( stack ) end
	end
	State.revision = revision
	for slot, stack in pairs( changed or {} ) do
		State.authoritative.equipment[slot] = MC.CopyItemStack( stack )
		local menuIndex = State.menu and State.menu.menuEquipmentMap and State.menu.menuEquipmentMap[slot] or nil
		if menuIndex ~= nil then State.authoritative.menuSlots[menuIndex + 1] = MC.CopyItemStack( stack ) end
	end
	if MC.RebuildClientPrediction then MC.RebuildClientPrediction( true ) end
	table.sort( changedSlots )
	emit( "MC.EquipmentChanged", changedSlots, revision, State )
	emit( "MC.InventoryMenuChanged", nil, revision, State )
	return true
end

function MC.GetClientInventoryStack( slot )
	slot = math.floor( tonumber( slot ) or -1 )
	if slot < 0 or slot >= 36 then return nil end
	return MC.CopyItemStack( State.slots[slot + 1] )
end

function MC.GetClientEquipmentStack( slot )
	slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or nil
	return slot and MC.CopyItemStack( State.equipment and State.equipment[slot] ) or nil
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
