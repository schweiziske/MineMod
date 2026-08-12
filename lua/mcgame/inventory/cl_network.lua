--[[----------------------------------------------------------------------------
	Client inventory transport, optimistic prediction/reconciliation and
	resynchronization. Actions are sent immediately; State.actions retains the
	unacknowledged tail so authoritative deltas can be replayed over it.
------------------------------------------------------------------------------]]

MC = MC or {}

local State = MC.ClientInventory
local PROTOCOL_VERSION = 1
local SNAPSHOT_PART_BYTES = 30000
local SNAPSHOT_MAX_BYTES = 1024 * 1024
local BACKGROUND_ACTION = 65535
local SLOT_BITS = 7

State.transfers = State.transfers or {}

local function emit( eventName, ... )
	if MC.RunEvent then MC.RunEvent( eventName, ... ) end
	if hook and hook.Run then hook.Run( string.gsub( eventName, "%.", "" ), ... ) end
end

function MC.RequestInventoryResync()
	local now = RealTime()
	if State.lastResyncRequest and now - State.lastResyncRequest < 0.5 then return false end
	State.lastResyncRequest = now
	net.Start( "mc_inventory_resync" )
	net.SendToServer()
	return true
end

local function failTransfer( transferId, reason )
	State.transfers[transferId] = nil
	State.lastError = reason
	MC.RequestInventoryResync()
	return false
end

net.Receive( "mc_inventory_sync_begin", function()
	local protocol = net.ReadUInt( 8 )
	local transferId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local rawBytes = net.ReadUInt( 32 )
	local compressedBytes = net.ReadUInt( 32 )
	local parts = net.ReadUInt( 16 )
	local hash = net.ReadString()
	local reason = net.ReadString()
	if protocol ~= PROTOCOL_VERSION or parts < 1 or parts > 64 or compressedBytes > SNAPSHOT_MAX_BYTES
	or rawBytes > SNAPSHOT_MAX_BYTES * 4 or #hash > 128 or #reason > 64 then
		failTransfer( transferId, "invalid_snapshot_begin" )
		return
	end
	State.transfers[transferId] = {
		startedAt = RealTime(),
		revision = revision,
		selected = selected,
		rawBytes = rawBytes,
		compressedBytes = compressedBytes,
		partsExpected = parts,
		parts = {},
		received = 0,
		bytes = 0,
		hash = hash,
		reason = reason,
	}
end )

net.Receive( "mc_inventory_sync_part", function()
	local transferId = net.ReadUInt( 16 )
	local index = net.ReadUInt( 16 )
	local length = net.ReadUInt( 16 )
	local chunk = net.ReadData( length )
	local transfer = State.transfers[transferId]
	if not transfer then return end
	if index < 1 or index > transfer.partsExpected or length < 1 or length > SNAPSHOT_PART_BYTES
	or type( chunk ) ~= "string" or #chunk ~= length or transfer.parts[index] then
		failTransfer( transferId, "invalid_snapshot_part" )
		return
	end
	transfer.parts[index] = chunk
	transfer.received = transfer.received + 1
	transfer.bytes = transfer.bytes + length
	if transfer.bytes > transfer.compressedBytes or transfer.bytes > SNAPSHOT_MAX_BYTES then
		failTransfer( transferId, "snapshot_size_exceeded" )
	end
end )

net.Receive( "mc_inventory_sync_end", function()
	local transferId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local transfer = State.transfers[transferId]
	if not transfer then return end
	State.transfers[transferId] = nil
	if revision ~= transfer.revision or transfer.received ~= transfer.partsExpected or transfer.bytes ~= transfer.compressedBytes then
		MC.RequestInventoryResync()
		return
	end
	local payload = table.concat( transfer.parts )
	local hash = util.SHA256 and util.SHA256( payload ) or util.CRC( payload )
	if hash ~= transfer.hash then MC.RequestInventoryResync() return end
	local json = util.Decompress( payload )
	if not json or #json ~= transfer.rawBytes then MC.RequestInventoryResync() return end
	local data = util.JSONToTable( json )
	local ok, err = MC.ApplyClientInventorySnapshot( data )
	if not ok then State.lastError = err MC.RequestInventoryResync() return end
	State.selected = transfer.selected
	emit( "MC.InventorySyncComplete", transfer.reason, State )
end )

local function playerMenuIndex( menu, playerIndex )
	return menu.menuPlayerMap and menu.menuPlayerMap[playerIndex] or menu.playerOffset + playerIndex
end

local function predictionTransferRules( menu, creative )
	local function inventoryTargets( fallback )
		return function( _, source )
			local equipmentSlot = MC.ItemEquipmentSlot and MC.ItemEquipmentSlot( source ) or nil
			local targets = {}
			if equipmentSlot and equipmentSlot ~= "offhand" then targets[#targets + 1] = "armor_" .. equipmentSlot
			elseif equipmentSlot == "offhand" then targets[#targets + 1] = "offhand" end
			targets[#targets + 1] = fallback
			return targets
		end
	end
	if menu.kind == "chest" or menu.kind == "chest_double" then
		return {
			chest = { targets = { "main", "hotbar" } },
			main = { targets = { "chest", "hotbar" } },
			hotbar = { targets = { "chest", "main" } },
		}
	end
	if menu.kind == "furnace" or menu.kind == "blast_furnace" then
		local recipeType = menu.kind == "blast_furnace" and "minecraft:blasting" or "minecraft:smelting"
		local function furnaceTargets( _, source )
			if MC.FindCookingRecipe( source, recipeType ) then return { "furnace_input" } end
			if MC.FurnaceFuelTime( source ) > 0 then return { "furnace_fuel" } end
			return { "hotbar" }
		end
		return {
			furnace_input = { targets = { "main", "hotbar" } },
			furnace_fuel = { targets = { "main", "hotbar" } },
			furnace_result = { targets = { "main", "hotbar" } },
			main = { resolve = furnaceTargets },
			hotbar = { resolve = furnaceTargets },
		}
	end
	local rules = {
		main = { resolve = inventoryTargets( "hotbar" ) },
		hotbar = { resolve = inventoryTargets( "main" ) },
		armor_head = { targets = { "hotbar", "main" } },
		armor_chest = { targets = { "hotbar", "main" } },
		armor_legs = { targets = { "hotbar", "main" } },
		armor_feet = { targets = { "hotbar", "main" } },
		offhand = { targets = { "hotbar", "main" } },
	}
	if not creative then rules.crafting = { targets = { "hotbar", "main" } } end
	return rules
end

local function buildPredictionContainer()
	local menu, session = State.menu, State.session
	if not menu or not session or not MC.NewInventoryContainer then return nil end
	local definitions, playerTargets, inputSlots = {}, {}, {}
	local crafting, creative = session.crafting == true, session.creative == true
	local furnace = menu.kind == "furnace" or menu.kind == "blast_furnace"
	local recipeType = menu.kind == "blast_furnace" and "minecraft:blasting" or "minecraft:smelting"
	local inputCount = crafting and math.max( 1, ( session.craftingWidth or 0 ) * ( session.craftingHeight or 0 ) ) or 0
	for index = 0, menu.slotCount - 1 do
		local playerIndex = menu.menuPlayerMap and menu.menuPlayerMap[index] or nil
		local equipmentSlot = menu.equipmentSlotMap and menu.equipmentSlotMap[index] or nil
		local group, meta, maxStack, mayPlace = "main", nil, nil, nil
		if furnace and index == 0 then
			group, meta = "furnace_input", { role = "input" }
			mayPlace = function( _, stack ) return MC.FindCookingRecipe( stack, recipeType ) ~= nil end
		elseif furnace and index == 1 then
			group, meta = "furnace_fuel", { role = "fuel" }
			mayPlace = function( _, stack ) return MC.FurnaceFuelTime( stack ) > 0 end
		elseif furnace and index == 2 then
			group, meta, mayPlace = "furnace_result", { role = "result" }, function() return false end
		elseif crafting and index == ( session.resultSlot or 0 ) then
			group, meta, mayPlace = "result", { role = "result" }, function() return false end
		elseif crafting and index >= 1 and index <= inputCount then
			group, meta = "crafting", { role = "input", position = index - 1 }
		elseif equipmentSlot then
			group = equipmentSlot == "offhand" and "offhand" or "armor_" .. equipmentSlot
			maxStack = equipmentSlot == "offhand" and ( MC.ItemAbsoluteMaxStack or 99 ) or 1
			mayPlace = function( _, stack ) return MC.ItemCanEquipInSlot and MC.ItemCanEquipInSlot( stack, equipmentSlot ) or false end
			meta = { role = "equipment", equipmentSlot = equipmentSlot }
		elseif playerIndex ~= nil then
			group = playerIndex < 9 and "hotbar" or "main"
		elseif ( menu.kind == "chest" or menu.kind == "chest_double" ) and index < ( session.chestSlots or 0 ) then
			group = "chest"
		end
		definitions[#definitions + 1] = {
			index = index, storage = menu.slots, storageIndex = index + 1,
			group = group, maxStack = maxStack, mayPlace = mayPlace, meta = meta,
		}
		if playerIndex ~= nil then playerTargets[#playerTargets + 1] = index end
		if crafting and index >= 1 and index <= inputCount then inputSlots[#inputSlots + 1] = index end
	end
	local hotbarSlots = {}
	for button = 0, 8 do hotbarSlots[button + 1] = playerMenuIndex( menu, button ) end
	local container, err = MC.NewInventoryContainer( {
		id = session.containerId, kind = menu.kind,
		revision = State.authoritative and State.authoritative.revision or State.revision,
		slots = definitions, hotbarSlots = hotbarSlots,
		transferRules = predictionTransferRules( menu, creative ),
		cursor = State.authoritative and State.authoritative.cursor or State.cursor,
		context = { creative = creative, crafting = crafting, clientPrediction = true },
	} )
	if not container then State.lastError = err or "inventory_prediction_container_failed" return nil end
	if crafting then
		container.crafting = {
			width = math.max( 1, session.craftingWidth or 1 ),
			height = math.max( 1, session.craftingHeight or 1 ),
			resultSlot = session.resultSlot or 0, inputSlots = inputSlots,
			playerOffset = session.playerOffset or 0, playerTargets = playerTargets,
		}
		container.beforeCommit = MC.CraftingRefreshResult
		container.takeResult = MC.CraftingTakeResult
	elseif furnace then
		container.furnace = {
			inputSlot = 0, fuelSlot = 1, resultSlot = 2,
			playerTargets = playerTargets, recipeType = recipeType,
		}
		container.takeResult = MC.FurnaceTakeResult
	end
	return container
end

local function syncPredictionMirrors( container )
	local menu = State.menu
	if not menu or not container then return end
	State.slots = {}
	for playerIndex = 0, 35 do
		local menuIndex = playerMenuIndex( menu, playerIndex )
		State.slots[playerIndex + 1] = menuIndex ~= nil and MC.CopyItemStack( menu.slots[menuIndex + 1] ) or nil
	end
	State.equipment = {}
	for slot, menuIndex in pairs( menu.menuEquipmentMap or {} ) do
		State.equipment[slot] = MC.CopyItemStack( menu.slots[menuIndex + 1] )
	end
	State.cursor = MC.CopyItemStack( container.cursor )
	State.predictedRevision = container.revision
end

local function predictAction( container, action )
	local context = { creative = State.session and State.session.creative == true, clientPrediction = true, canDrop = true }
	if action.kind == "input" then
		return MC.ExecuteContainerInput( container, {
			revision = container.revision, actionId = action.actionId,
			input = action.input, slot = action.slot, button = action.button,
		}, context )
	end
	if action.kind == "recipe_place" then
		local recipe = MC.GetRecipe and MC.GetRecipe( action.recipeId ) or nil
		if not recipe then return { ok = false, error = "unknown_recipe" } end
		local furnace = State.session and ( State.session.kind == "furnace" or State.session.kind == "blast_furnace" )
		local result, err
		if furnace then result, err = MC.FurnacePlaceRecipe( container, recipe, context, action.useMax == true )
		else result, err = MC.CraftingPlaceRecipe( container, recipe, context, action.useMax == true ) end
		return result or { ok = false, error = err or "recipe_place_failed" }
	end
	if action.kind == "creative_pick" then
		local before = MC.ContainerSnapshot( container )
		local ok, err
		if action.targetSlot >= 0 then ok, err = MC.ContainerSetStack( container, action.targetSlot, action.stack )
		else ok, err = MC.ContainerSetCursor( container, action.stack ) end
		if not ok then return { ok = false, error = err or "creative_pick_failed" } end
		local changed = MC.ContainerChangedSlots( container, before )
		local cursorChanged = not MC.ItemStacksEqual( container.cursor, before.cursor )
		if #changed > 0 or cursorChanged then container.revision = container.revision + 1 end
		return { ok = true, changedSlots = changed, cursorChanged = cursorChanged, cursor = MC.CopyItemStack( container.cursor ) }
	end
	return { ok = false, error = "unsupported_prediction" }
end

function MC.RebuildClientPrediction( silent )
	local authoritative, menu = State.authoritative, State.menu
	if not authoritative or not menu or not State.session then return false end
	for index = 1, menu.slotCount do menu.slots[index] = MC.CopyItemStack( authoritative.menuSlots[index] ) end
	State.slots = {}
	for index = 1, 36 do State.slots[index] = MC.CopyItemStack( authoritative.playerSlots[index] ) end
	State.equipment = {}
	for slot, stack in pairs( authoritative.equipment or {} ) do State.equipment[slot] = MC.CopyItemStack( stack ) end
	State.revision, State.selected = authoritative.revision, authoritative.selected
	State.cursor = MC.CopyItemStack( authoritative.cursor )
	local container = buildPredictionContainer()
	if not container then return false end
	for _, action in ipairs( State.actions or {} ) do
		local result = predictAction( container, action )
		action.predictionOK = result and result.ok == true
		action.predictionError = result and result.error or nil
	end
	State.predictedContainer = container
	syncPredictionMirrors( container )
	if not silent then
		emit( "MC.InventoryMenuChanged", nil, State.revision, State )
		emit( "MC.InventoryChanged", nil, State.revision, State )
		emit( "MC.EquipmentChanged", nil, State.revision, State )
		emit( "MC.InventoryCursorChanged", State.cursor, State )
	end
	return true
end

local function pumpActions()
	if not State.session or #State.actions == 0 then return end
	for _, action in ipairs( State.actions ) do
		if not action.sent then
			action.sent = true
			action.revision = action.baseRevision or ( State.authoritative and State.authoritative.revision or State.revision )
			local messageName = action.kind == "creative_pick" and "mc_inventory_creative_pick"
				or action.kind == "recipe_place" and "mc_inventory_recipe_place"
				or "mc_inventory_action"
			net.Start( messageName )
				net.WriteUInt( State.session.containerId, 16 )
				net.WriteString( State.session.token )
				net.WriteUInt( action.revision, 32 )
				net.WriteUInt( action.actionId, 16 )
				if action.kind == "creative_pick" then
					net.WriteUInt( action.runtimeId, MC.ItemStackRuntimeIdBits )
					net.WriteUInt( action.count, 7 )
					net.WriteInt( action.targetSlot, 8 )
				elseif action.kind == "recipe_place" then
					net.WriteString( action.recipeId )
					net.WriteBool( action.useMax == true )
				else
					net.WriteUInt( action.input, 3 )
					net.WriteInt( action.slot, 16 )
					net.WriteInt( action.button, 8 )
				end
			net.SendToServer()
		end
	end
end

local function enqueueAction( action )
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	local actionId = State.nextActionId % BACKGROUND_ACTION
	State.nextActionId = ( actionId + 1 ) % BACKGROUND_ACTION
	action.actionId = actionId
	action.baseRevision = State.authoritative and State.authoritative.revision or State.revision
	State.actions[#State.actions + 1] = action
	MC.RebuildClientPrediction()
	pumpActions()
	return true, actionId
end

function MC.QueueRecipeBookPlacement( recipeId, useMax )
	local furnace = State.session and ( State.session.kind == "furnace" or State.session.kind == "blast_furnace" )
	if not State.session or State.session.crafting ~= true and not furnace then return false, "recipe_book_unavailable" end
	recipeId = tostring( recipeId or "" )
	if #recipeId < 1 or #recipeId > 128 then return false, "invalid_recipe_id" end
	if not MC.GetRecipe or not MC.GetRecipe( recipeId ) then return false, "unknown_recipe" end
	return enqueueAction( { kind = "recipe_place", recipeId = recipeId, useMax = useMax == true } )
end

function MC.QueueInventoryInput( input, slot, button )
	if not State.session then return false, "inventory_not_open" end
	input = math.floor( tonumber( input ) or -1 )
	slot = math.floor( tonumber( slot ) or -999 )
	button = math.floor( tonumber( button ) or 0 )
	local slotCount = State.session and math.floor( tonumber( State.session.slotCount ) or 36 ) or 36
	if input < 0 or input > 6 or ( slot ~= -999 and ( slot < 0 or slot >= slotCount ) )
	or button < -128 or button > 127 then return false, "invalid_inventory_action" end
	return enqueueAction( { kind = "input", input = input, slot = slot, button = button } )
end

function MC.QueueCreativeInventoryPick( item, count, targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	local definition = MC.GetItem( item )
	if not definition or definition.name == "minecraft:air" or definition.runtimeId == nil then return false, "unknown_item" end
	count = math.floor( tonumber( count ) or definition.maxStack or 1 )
	count = math.Clamp( count, 1, definition.maxStack or 1 )
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if targetSlot < -1 or targetSlot > 8 then return false, "invalid_creative_target" end
	local stack, stackError = MC.NewItemStack( definition.name, count )
	if not stack then return false, stackError or "item_stack_failed" end
	return enqueueAction( {
		kind = "creative_pick", runtimeId = definition.runtimeId, count = count,
		targetSlot = targetSlot, stack = stack,
	} )
end

function MC.QueueCreativeInventoryClear( targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if targetSlot < -1 or targetSlot > 8 then return false, "invalid_creative_target" end
	local air = MC.GetItem( "minecraft:air" )
	if not air or air.runtimeId == nil then return false, "item_registry_unavailable" end
	return enqueueAction( {
		kind = "creative_pick", runtimeId = air.runtimeId, count = 0,
		targetSlot = targetSlot, stack = nil,
	} )
end

local function acknowledgeAction( actionId, accepted )
	if actionId == BACKGROUND_ACTION then return end
	for index, action in ipairs( State.actions ) do
		if action.actionId == actionId then table.remove( State.actions, index ) break end
	end
	if accepted ~= true then State.actions = {} end
end

net.Receive( "mc_inventory_delta", function()
	local protocol = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local accepted = net.ReadBool()
	local actionId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local errorCode = net.ReadString()
	local changedCount = net.ReadUInt( SLOT_BITS )
	local changed, seen, decodeError = {}, {}, nil
	for _ = 1, changedCount do
		local index = net.ReadUInt( SLOT_BITS )
		local stack, err = MC.ReadItemStackNet()
		if err then decodeError = err end
		if seen[index] then decodeError = decodeError or "duplicate_inventory_delta_slot" end
		seen[index] = true
		changed[index] = stack or false
	end
	local cursor, cursorError = MC.ReadItemStackNet()
	decodeError = decodeError or cursorError
	local background = not State.session and containerId == 1 and token == ""
	local validSession = background or State.session and State.session.containerId == containerId and State.session.token == token
	local validSlotCount = not State.session or changedCount <= math.floor( tonumber( State.session.slotCount ) or 36 )
	if protocol ~= PROTOCOL_VERSION or not validSession or not validSlotCount or #token > 128 or #errorCode > 96 or decodeError then
		State.lastError = decodeError or "invalid_inventory_delta"
		MC.RequestInventoryResync()
		return
	end
	if background then
		local slots = {}
		for index = 0, 35 do slots[index + 1] = MC.CopyItemStack( State.slots[index + 1] ) end
		State.menu = {
			kind = "player", slotCount = 36, playerOffset = 0, chestSlots = 0,
			crafting = false, slots = slots,
		}
		State.authoritative = nil
	end
	acknowledgeAction( actionId, accepted )
	if actionId ~= BACKGROUND_ACTION and not accepted then
		State.lastError = errorCode ~= "" and errorCode or "inventory_action_rejected"
	end
	local cursorApplies = State.session and token == State.session.token or false
	local applied, applyError = MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, cursorApplies )
	if not applied then
		State.lastError = applyError or "inventory_delta_rejected"
		MC.RequestInventoryResync()
		return
	end
	emit( "MC.InventoryActionResult", actionId, accepted, errorCode, revision, State )
end )

net.Receive( "mc_equipment_delta", function()
	local protocol = net.ReadUInt( 8 )
	local revision = net.ReadUInt( 32 )
	local count = net.ReadUInt( 3 )
	local changed, seen, decodeError = {}, {}, nil
	for _ = 1, count do
		local id = net.ReadUInt( 3 )
		local slot = MC.EquipmentSlotsById and MC.EquipmentSlotsById[id] or nil
		local stack, stackError = MC.ReadItemStackNet()
		if not slot or seen[slot] then decodeError = decodeError or "invalid_equipment_delta_slot" end
		if stackError then decodeError = decodeError or stackError end
		if slot then seen[slot], changed[slot] = true, stack or false end
	end
	if protocol ~= PROTOCOL_VERSION or count > 5 or decodeError then
		State.lastError = decodeError or "invalid_equipment_delta"
		MC.RequestInventoryResync()
		return
	end
	local ok, err = MC.ApplyClientEquipmentDelta( revision, changed )
	if not ok then State.lastError = err MC.RequestInventoryResync() end
end )

local function initialOpenMaps( kind, creative, crafting, slotCount, playerOffset )
	local playerByMenu, menuByPlayer, equipmentByMenu, menuByEquipment = {}, {}, {}, {}
	if ( kind == "player" or kind == "" ) and crafting and not creative and slotCount >= 46 then
		for playerIndex = 9, 35 do
			playerByMenu[playerIndex], menuByPlayer[playerIndex] = playerIndex, playerIndex
		end
		for playerIndex = 0, 8 do
			local menuIndex = 36 + playerIndex
			playerByMenu[menuIndex], menuByPlayer[playerIndex] = playerIndex, menuIndex
		end
		for slot, menuIndex in pairs( MC.EquipmentMenuSlots or {} ) do
			equipmentByMenu[menuIndex], menuByEquipment[slot] = slot, menuIndex
		end
	elseif ( kind == "player" or kind == "" ) and creative and slotCount >= 41 and playerOffset == 0 then
		for playerIndex = 0, 35 do
			playerByMenu[playerIndex], menuByPlayer[playerIndex] = playerIndex, playerIndex
		end
		for slot, menuIndex in pairs( MC.CreativeEquipmentMenuSlots or {} ) do
			equipmentByMenu[menuIndex], menuByEquipment[slot] = slot, menuIndex
		end
	else
		for playerIndex = 0, 35 do
			local menuIndex = playerOffset + playerIndex
			if menuIndex >= 0 and menuIndex < slotCount then
				playerByMenu[menuIndex], menuByPlayer[playerIndex] = playerIndex, menuIndex
			end
		end
	end
	return playerByMenu, menuByPlayer, equipmentByMenu, menuByEquipment
end

net.Receive( "mc_inventory_open", function()
	local protocol = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local creative = net.ReadBool()
	local reason = net.ReadString()
	local cursor, err = MC.ReadItemStackNet()
	local kind = net.ReadString()
	local slotCount = net.ReadUInt( 8 )
	local playerOffset = net.ReadUInt( 8 )
	local chestSlots = net.ReadUInt( 8 )
	local crafting = net.ReadBool()
	local craftingWidth = net.ReadUInt( 4 )
	local craftingHeight = net.ReadUInt( 4 )
	local resultSlot = net.ReadUInt( 8 )
	if protocol ~= PROTOCOL_VERSION or containerId < 1 or token == "" or #token > 128 or err
	or slotCount < 1 or slotCount > 127 or playerOffset + 36 > slotCount or chestSlots > slotCount
	or ( crafting and ( craftingWidth < 1 or craftingHeight < 1 or craftingWidth * craftingHeight > 9
		or resultSlot >= slotCount or resultSlot == nil
		or playerOffset < resultSlot + craftingWidth * craftingHeight + 1 ) ) then
		State.lastError = err or "invalid_inventory_open"
		return
	end
	State.session = {
		containerId = containerId,
		token = token,
		creative = creative,
		reason = reason,
		kind = kind ~= "" and kind or "player",
		slotCount = slotCount,
		playerOffset = playerOffset,
		chestSlots = chestSlots,
		crafting = crafting,
		craftingWidth = craftingWidth,
		craftingHeight = craftingHeight,
		resultSlot = resultSlot,
	}
	State.revision = revision
	State.selected = selected
	State.cursor = cursor
	local playerByMenu, menuByPlayer, equipmentByMenu, menuByEquipment = initialOpenMaps(
		kind, creative, crafting, slotCount, playerOffset )
	local menuSlots = {}
	for playerIndex, menuIndex in pairs( menuByPlayer ) do
		menuSlots[menuIndex + 1] = MC.CopyItemStack( State.slots[playerIndex + 1] )
	end
	for slot, menuIndex in pairs( menuByEquipment ) do
		menuSlots[menuIndex + 1] = MC.CopyItemStack( State.equipment and State.equipment[slot] )
	end
	State.menu = {
		kind = kind ~= "" and kind or "player",
		recipeRegistryHash = tostring( MC.RecipeRegistryHash or "" ),
		slotCount = slotCount,
		playerOffset = playerOffset,
		chestSlots = chestSlots,
		crafting = crafting,
		craftingWidth = craftingWidth,
		craftingHeight = craftingHeight,
		resultSlot = resultSlot,
		slots = menuSlots,
		playerSlotMap = playerByMenu,
		menuPlayerMap = menuByPlayer,
		equipmentSlotMap = equipmentByMenu,
		menuEquipmentMap = menuByEquipment,
	}
	State.actions = {}
	State.authoritative = nil
	State.predictedContainer = nil
	emit( "MC.InventoryOpened", State.session, State )
end )

net.Receive( "mc_inventory_close", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local reason = net.ReadString()
	if State.session and State.session.containerId == containerId and State.session.token == token then
		State.session = nil
		State.cursor = nil
		State.actions = {}
		State.authoritative = nil
		State.predictedContainer = nil
		emit( "MC.InventoryClosed", reason, State )
	end
end )

function MC.RequestInventoryOpen()
	local now = RealTime()
	if State.lastOpenRequest and now - State.lastOpenRequest < 0.2 then return false end
	State.lastOpenRequest = now
	net.Start( "mc_inventory_open_request" )
	net.SendToServer()
	return true
end

function MC.CloseInventorySession()
	if not State.session then return false end
	net.Start( "mc_inventory_close" )
		net.WriteUInt( State.session.containerId, 16 )
		net.WriteString( State.session.token )
	net.SendToServer()
	return true
end

function MC.SelectInventoryHotbarSlot( selected )
	selected = math.floor( tonumber( selected ) or -1 )
	if selected < 0 or selected > 8 then return false end
	State.selected = selected
	if State.authoritative then State.authoritative.selected = selected end
	emit( "MC.InventorySelectionChanged", selected, State )
	net.Start( "mc_inventory_select" )
		net.WriteUInt( selected, 4 )
	net.SendToServer()
	return true
end

hook.Add( "Think", "mc_inventory_transfer_timeout", function()
	local now = RealTime()
	for transferId, transfer in pairs( State.transfers ) do
		if now - transfer.startedAt > 20 then failTransfer( transferId, "snapshot_timeout" ) end
	end
end )

concommand.Add( "mc_inventory", function() MC.RequestInventoryOpen() end )
