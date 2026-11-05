--[[----------------------------------------------------------------------------
	Client inventory transport, optimistic prediction/reconciliation and
	resynchronization. Actions are sent immediately; State.actions retains the
	unacknowledged tail so authoritative deltas can be replayed over it.
------------------------------------------------------------------------------]]

MC = MC or {}

local State = MC.ClientInventory
local PROTOCOL_VERSION = MC.InventoryProtocolVersion
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
	if not ok then
		if err ~= "stale_inventory_snapshot" then State.lastError = err MC.RequestInventoryResync() end
		return
	end
	emit( "MC.InventorySyncComplete", transfer.reason, State )
end )

local function playerMenuIndex( menu, playerIndex )
	if menu.menuPlayerMap then return menu.menuPlayerMap[playerIndex] end
	return menu.playerOffset + playerIndex
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
			chest = { targets = { "hotbar", "main" }, reverse = true },
			main = { targets = { "chest" } },
			hotbar = { targets = { "chest" } },
		}
	end
	if menu.kind == "menu" then
		return { main = { targets = { "hotbar" } }, hotbar = { targets = { "main" } } }
	end
	if menu.kind == "crafting_table" then
		return {
			crafting = { targets = { "main", "hotbar" } },
			main = { targets = { "crafting" }, fallback = { "hotbar" } },
			hotbar = { targets = { "crafting" }, fallback = { "main" } },
		}
	end
	if menu.kind == "anvil" then
		return {
			anvil_left = { targets = { "main", "hotbar" } },
			anvil_right = { targets = { "main", "hotbar" } },
			main = { targets = { "anvil_left", "anvil_right" } },
			hotbar = { targets = { "anvil_left", "anvil_right" } },
		}
	end
	if menu.kind == "merchant" then
		return {
			merchant_payment_a = { targets = { "main", "hotbar" } },
			merchant_payment_b = { targets = { "main", "hotbar" } },
			main = { targets = { "hotbar" } }, hotbar = { targets = { "main" } },
		}
	end
	if menu.kind == "brewing_stand" then
		local function targets( fallback )
			return function( container, source )
				if MC.BrewingIsFuel( source ) then
					local slot = MC.ContainerGetSlot( container, 4 )
					local existing = MC.InventorySlotGet( slot )
					if MC.IsEmptyItemStack( existing ) or MC.ItemStacksCanMerge( existing, source )
					and existing.count < MC.InventorySlotLimit( slot, source ) then return { "brewing_fuel" } end
					return { "brewing_ingredient" }
				end
				if MC.BrewingIsIngredient( source ) then return { "brewing_ingredient" } end
				if MC.BrewingIsBottle( source ) then return { "brewing_bottles" } end
				return { fallback }
			end
		end
		return {
			brewing_bottles = { targets = { "hotbar", "main" }, reverse = true },
			brewing_ingredient = { targets = { "hotbar", "main" }, reverse = true },
			brewing_fuel = { targets = { "hotbar", "main" }, reverse = true },
			main = { resolve = targets( "hotbar" ) }, hotbar = { resolve = targets( "main" ) },
		}
	end
	if menu.kind == "hopper" or menu.kind == "dispenser" or menu.kind == "dropper" then
		return {
			logistics_container = { targets = { "hotbar", "main" }, reverse = true },
			main = { targets = { "logistics_container" } },
			hotbar = { targets = { "logistics_container" } },
		}
	end
	if menu.kind == "furnace" or menu.kind == "blast_furnace" then
		local recipeType = menu.kind == "blast_furnace" and "minecraft:blasting" or "minecraft:smelting"
		local function furnaceTargets( fallback )
			return function( _, source )
				if MC.FindCookingRecipe( source, recipeType ) then return { "furnace_input" } end
				if MC.FurnaceFuelTime( source ) > 0 then return { "furnace_fuel" } end
				return { fallback }
			end
		end
		return {
			furnace_input = { targets = { "main", "hotbar" } },
			furnace_fuel = { targets = { "main", "hotbar" } },
			furnace_result = { targets = { "main", "hotbar" } },
			main = { resolve = furnaceTargets( "hotbar" ) },
			hotbar = { resolve = furnaceTargets( "main" ) },
		}
	end
	if menu.kind == "enchanting_table" then
		local function enchantingTargets( _, source )
			if not MC.IsEmptyItemStack( source ) and source.item == "minecraft:lapis_lazuli" then
				return { "enchanting_lapis" }
			end
			if MC.EnchantingIsItemEnchantable and MC.EnchantingIsItemEnchantable( source ) then
				return { "enchanting_item" }
			end
			return {}
		end
		return {
			enchanting_item = { targets = { "hotbar", "main" }, reverse = true },
			enchanting_lapis = { targets = { "hotbar", "main" }, reverse = true },
			main = { resolve = enchantingTargets },
			hotbar = { resolve = enchantingTargets },
		}
	end
	local rules = {
		main = { resolve = inventoryTargets( "hotbar" ) },
		hotbar = { resolve = inventoryTargets( "main" ) },
		armor_head = { targets = { "main", "hotbar" } },
		armor_chest = { targets = { "main", "hotbar" } },
		armor_legs = { targets = { "main", "hotbar" } },
		armor_feet = { targets = { "main", "hotbar" } },
		offhand = { targets = { "main", "hotbar" } },
	}
	if not creative then rules.crafting = { targets = { "main", "hotbar" } } end
	return rules
end

local function buildPredictionContainer()
	local menu, session = State.menu, State.session
	if not menu then return nil end
	if not session then
		session = { containerId = 1, creative = MC.PlayerIsCreative and MC.PlayerIsCreative( LocalPlayer() ) == true }
	end
	local definitions, playerTargets, inputSlots = {}, {}, {}
	local crafting, creative = session.crafting == true, session.creative == true
	local furnace = menu.kind == "furnace" or menu.kind == "blast_furnace"
	local enchanting = menu.kind == "enchanting_table"
	local brewing = menu.kind == "brewing_stand"
	local anvil, merchant = menu.kind == "anvil", menu.kind == "merchant"
	local virtualMenu = menu.kind == "menu"
	local logistics = menu.kind == "hopper" or menu.kind == "dispenser" or menu.kind == "dropper"
	local recipeType = menu.kind == "blast_furnace" and "minecraft:blasting" or "minecraft:smelting"
	local inputCount = crafting and math.max( 1, ( session.craftingWidth or 0 ) * ( session.craftingHeight or 0 ) ) or 0
	for index = 0, menu.slotCount - 1 do
		local playerIndex
		if menu.playerSlotMap then playerIndex = menu.playerSlotMap[index]
		elseif index >= menu.playerOffset then playerIndex = index - menu.playerOffset end
		local equipmentSlot = menu.equipmentSlotMap and menu.equipmentSlotMap[index] or nil
		local group, meta, maxStack, mayPlace, readOnly = "main", nil, nil, nil, nil
		if virtualMenu and index < ( session.chestSlots or 0 ) then
			group, meta, readOnly = "menu_display", { role = "result" }, true
		elseif ( anvil or merchant ) and index == 2 then
			group, meta, mayPlace = "result", { role = "result" }, function() return false end
		elseif anvil and index < 2 then
			group, meta = index == 0 and "anvil_left" or "anvil_right", { role = "input" }
		elseif merchant and index < 2 then
			group, meta = index == 0 and "merchant_payment_a" or "merchant_payment_b", { role = "input" }
		elseif brewing and index < 3 then
			group, maxStack, mayPlace = "brewing_bottles", 1, function( _, stack ) return MC.BrewingIsBottle( stack ) end
		elseif brewing and index == 3 then
			group, mayPlace = "brewing_ingredient", function( _, stack ) return MC.BrewingIsIngredient( stack ) end
		elseif brewing and index == 4 then
			group, mayPlace = "brewing_fuel", function( _, stack ) return MC.BrewingIsFuel( stack ) end
		elseif enchanting and index == 0 then
			group, meta, maxStack = "enchanting_item", { role = "input" }, 1
			mayPlace = function( _, stack )
				return MC.EnchantingIsItemEnchantable and MC.EnchantingIsItemEnchantable( stack ) or false
			end
		elseif enchanting and index == 1 then
			group, meta = "enchanting_lapis", { role = "lapis" }
			mayPlace = function( _, stack )
				return not MC.IsEmptyItemStack( stack ) and stack.item == "minecraft:lapis_lazuli"
			end
		elseif furnace and index == 0 then
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
		elseif logistics and index < ( session.playerOffset or 0 ) then
			group = "logistics_container"
		elseif ( menu.kind == "chest" or menu.kind == "chest_double" ) and index < ( session.chestSlots or 0 ) then
			group = "chest"
		end
		definitions[#definitions + 1] = {
			index = index, storage = menu.slots, storageIndex = index + 1,
			group = group, maxStack = maxStack, mayPlace = mayPlace, meta = meta, readOnly = readOnly,
		}
		if playerIndex ~= nil then playerTargets[#playerTargets + 1] = index end
		if crafting and index >= 1 and index <= inputCount then inputSlots[#inputSlots + 1] = index end
	end
	local hotbarSlots = {}
	for button = 0, 8 do hotbarSlots[button + 1] = playerMenuIndex( menu, button ) end
	local equipmentMap = menu.menuEquipmentMap or {}
	local container, err = MC.NewInventoryContainer( {
		id = session.containerId, kind = menu.kind,
		revision = State.authoritative and State.authoritative.revision or State.revision,
		slots = definitions, hotbarSlots = hotbarSlots,
		transferRules = predictionTransferRules( menu, creative ),
		cursor = State.cursor,
		context = { creative = creative, crafting = crafting, clientPrediction = true },
		getSwapStack = function( committed, button )
			if button ~= 40 then return nil end
			local index = equipmentMap.offhand
			return index ~= nil and menu.slots[index + 1] or nil
		end,
		setSwapStack = function( committed, button, stack )
			if button ~= 40 then return false, "invalid_swap_button" end
			local index = equipmentMap.offhand
			if index == nil then return false, "missing_offhand_slot" end
			local normalized, setError = MC.NormalizeItemStack( stack )
			if stack == nil then normalized = nil end
			if stack ~= nil and not normalized then return false, setError end
			menu.slots[index + 1] = normalized
			return true
		end,
	} )
	if not container then State.lastError = err or "inventory_prediction_container_failed" return nil end
	container.quickCraft = MC.CopyInventoryQuickCraft( State.authoritative.quickCraft )
	container.canTakeItemForPickAll = function( _, _, slot )
		return not ( ( crafting or anvil or merchant ) and slot.meta and slot.meta.role == "result" )
	end
	if MC.ConfigurePlayerSwap then
		MC.ConfigurePlayerSwap( container, { equipment = State.equipment }, menu.menuEquipmentMap )
	end
	if crafting then
		container.crafting = {
			width = math.max( 1, session.craftingWidth or 1 ),
			height = math.max( 1, session.craftingHeight or 1 ),
			resultSlot = session.resultSlot or 0, inputSlots = inputSlots,
			playerOffset = session.playerOffset or 0, playerTargets = playerTargets,
			resultTargets = MC.ContainerResolveTargets( container, { "hotbar", "main" }, true ),
		}
		container.beforeCommit = MC.CraftingRefreshResult
		container.takeResult = MC.CraftingTakeResult
	elseif furnace then
		container.furnace = {
			inputSlot = 0, fuelSlot = 1, resultSlot = 2,
			playerTargets = playerTargets, recipeType = recipeType,
			resultTargets = MC.ContainerResolveTargets( container, { "hotbar", "main" }, true ),
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
	for slot, menuIndex in pairs( menu.menuEquipmentMap or {} ) do
		State.equipment[slot] = MC.CopyItemStack( menu.slots[menuIndex + 1] )
	end
	State.cursor = MC.CopyItemStack( container.cursor )
	State.predictedRevision = container.revision
	State.quickCraftPreview = MC.InventoryQuickCraftPreview( container )
end

local function predictAction( container, action )
	local context = {
		creative = container.context.creative == true,
		clientPrediction = true,
		canDrop = true,
		parityClicks = MC.GameplayParityInventoryClicksEnabled
			and MC.GameplayParityInventoryClicksEnabled() or false,
	}
	if action.kind == "input" then
		local slot = MC.ContainerGetSlot( container, action.slot )
		if ( container.kind == "anvil" or container.kind == "merchant" ) and slot and slot.meta and slot.meta.role == "result"
		and action.input ~= MC.ContainerInput.CLONE and action.input ~= MC.ContainerInput.QUICK_CRAFT then
			return { ok = true, authoritativeOnly = true }
		end
		-- Virtual menu buttons are server code; any input on them waits for it.
		if container.kind == "menu" and slot and slot.meta and slot.meta.role == "result" then
			return { ok = true, authoritativeOnly = true }
		end
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
	if action.kind == "menu_button" then
		-- Business buttons never predict authoritative stack, experience or seed
		-- changes. Keeping the local container untouched lets the normal delta
		-- reconcile the single server-computed result.
		return { ok = true, authoritativeOnly = true }
	end
	if action.kind == "world" then
		if action.operation == 0 then
			local ok, selected, err = MC.PickInventoryStack( container, action.selected, action.stack, context.creative )
			if State.pendingSelection and State.pendingSelection.id == action.selectionId then
				State.pendingSelection.selected = selected
			end
			State.selected = MC.ClientInventoryVisibleSelection( selected )
			return { ok = ok, error = err }
		end
		return MC.ExecuteContainerInput( container, {
			input = action.operation == 1 and MC.ContainerInput.THROW or MC.ContainerInput.SWAP,
			slot = action.selected, button = action.operation == 1 and ( action.whole and 1 or 0 ) or 40,
		}, context )
	end
	if action.kind == "creative_pick" then
		local before = MC.ContainerSnapshot( container )
		local ok, err = MC.MutateCreativeInventory( container, action.targetSlot, action.stack )
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
	if not authoritative or not menu then return false end
	for index = 1, menu.slotCount do menu.slots[index] = MC.CopyItemStack( authoritative.menuSlots[index] ) end
	State.slots = {}
	for index = 1, 36 do State.slots[index] = MC.CopyItemStack( authoritative.playerSlots[index] ) end
	State.equipment = {}
	for slot, stack in pairs( authoritative.equipment or {} ) do State.equipment[slot] = MC.CopyItemStack( stack ) end
	State.revision, State.selected = authoritative.revision, MC.ClientInventoryVisibleSelection( authoritative.selected )
	State.cursor = MC.CopyItemStack( authoritative.cursor )
	local container = buildPredictionContainer()
	if not container then return false end
	State.predictionBarrier = false
	for _, action in ipairs( State.actions or {} ) do
		local result = predictAction( container, action )
		action.predictionOK = result and result.ok == true
		action.predictionError = result and result.error or nil
		if result and result.authoritativeOnly then State.predictionBarrier = true break end
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
	if #State.actions == 0 then return end
	for _, action in ipairs( State.actions ) do
		if not action.sent then
			action.sent = true
			action.revision = action.baseRevision or ( State.authoritative and State.authoritative.revision or State.revision )
			local messageName = action.kind == "world" and "mc_inventory_world_action"
				or action.kind == "creative_pick" and "mc_inventory_creative_pick"
				or action.kind == "recipe_place" and "mc_inventory_recipe_place"
				or action.kind == "menu_button" and "mc_inventory_menu_button"
				or "mc_inventory_action"
			net.Start( messageName )
			if action.kind == "world" then
				net.WriteUInt( action.actionId, 16 )
				net.WriteUInt( action.operation, 2 )
				net.WriteUInt( action.selectionId, 32 )
				net.WriteUInt( action.selected, 4 )
				net.WriteBool( action.whole == true )
				if action.operation == 0 then
					net.WriteInt( action.bx, MC.Net.COORD_BITS )
					net.WriteInt( action.by, MC.Net.COORD_BITS )
					net.WriteInt( action.bz, MC.Net.COORD_BITS )
				end
			else
				net.WriteUInt( State.session.containerId, 16 )
				net.WriteString( State.session.token )
				net.WriteUInt( action.revision, 32 )
				net.WriteUInt( action.actionId, 16 )
				if action.kind == "creative_pick" then
					MC.WriteItemStackNet( action.stack )
					net.WriteInt( action.targetSlot, 8 )
				elseif action.kind == "recipe_place" then
					net.WriteString( action.recipeId )
					net.WriteBool( action.useMax == true )
				elseif action.kind == "menu_button" then
					net.WriteUInt( action.button, 2 )
				else
					net.WriteUInt( action.input, 3 )
					net.WriteInt( action.slot, 16 )
					net.WriteInt( action.button, 8 )
				end
			end
			net.SendToServer()
		end
	end
end

local function enqueueAction( action )
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	if not State.authoritative then return false, "inventory_sync_pending" end
	local actionId = State.nextActionId % BACKGROUND_ACTION
	State.nextActionId = ( actionId + 1 ) % BACKGROUND_ACTION
	action.actionId = actionId
	action.baseRevision = State.authoritative and State.authoritative.revision or State.revision
	State.actions[#State.actions + 1] = action
	if State.predictedContainer and not State.predictionBarrier then
		local result = predictAction( State.predictedContainer, action )
		action.predictionOK, action.predictionError = result.ok == true, result.error
		State.predictionBarrier = result.authoritativeOnly == true
		syncPredictionMirrors( State.predictedContainer )
		emit( "MC.InventoryMenuChanged", nil, State.revision, State )
		emit( "MC.InventoryChanged", nil, State.revision, State )
		emit( "MC.EquipmentChanged", nil, State.revision, State )
		emit( "MC.InventoryCursorChanged", State.cursor, State )
	else
		MC.RebuildClientPrediction()
	end
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

function MC.InventoryMenuButtonPending()
	for _, action in ipairs( State.actions or {} ) do
		if action.kind == "menu_button" then return true, action.actionId end
	end
	return false
end

function MC.QueueInventoryMenuButton( button )
	if not State.session then return false, "inventory_not_open" end
	button = math.floor( tonumber( button ) or -1 )
	if button < 0 or button > 2 then return false, "invalid_menu_button" end
	if MC.InventoryMenuButtonPending() then return false, "menu_button_pending" end
	return enqueueAction( { kind = "menu_button", button = button } )
end

function MC.QueueCreativeInventoryPick( item, count, targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	local source, sourceError = MC.NormalizeItemStack( item )
	if not source then return false, sourceError or "unknown_item" end
	local definition = MC.GetItem( source.item )
	if not definition or definition.name == "minecraft:air" or definition.runtimeId == nil then return false, "unknown_item" end
	count = math.floor( tonumber( count ) or definition.maxStack or 1 )
	count = math.Clamp( count, 1, definition.maxStack or 1 )
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if ( targetSlot < -1 or targetSlot > 8 ) and targetSlot ~= 40 and targetSlot ~= -3 then return false, "invalid_creative_target" end
	local stack, stackError = MC.NormalizeItemStack( {
		item = source.item,
		count = count,
		damage = source.damage,
		components = source.components,
	} )
	if not stack then return false, stackError or "item_stack_failed" end
	return enqueueAction( {
		kind = "creative_pick", targetSlot = targetSlot, stack = stack,
	} )
end

function MC.QueueCreativeInventoryClear( targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if ( targetSlot < -2 or targetSlot > 8 ) and targetSlot ~= 40 then return false, "invalid_creative_target" end
	return enqueueAction( {
		kind = "creative_pick", targetSlot = targetSlot, stack = nil,
	} )
end

local function acknowledgeAction( actionId, accepted )
	-- Rejection rolls back this action, not later clicks already in flight.
	MC.AcknowledgeClientInventoryActions( actionId, false )
end

net.Receive( "mc_inventory_delta", function()
	local protocol = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local accepted = net.ReadBool()
	local actionId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local selectionId = net.ReadUInt( 32 )
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
	local slotCount = State.session and State.session.slotCount or 36
	local quickCraft, quickError = MC.ReadInventoryQuickCraftNet( slotCount )
	local offhand, offhandError = MC.ReadItemStackNet()
	decodeError = decodeError or quickError or offhandError
	local background = not State.session and containerId == 1 and token == ""
	local validSession = background or State.session and State.session.containerId == containerId and State.session.token == token
	local validSlotCount = not State.session or changedCount <= math.floor( tonumber( State.session.slotCount ) or 36 )
	if protocol ~= PROTOCOL_VERSION or not validSession or not validSlotCount or #token > 128 or #errorCode > 96 or decodeError then
		State.lastError = decodeError or "invalid_inventory_delta"
		MC.RequestInventoryResync()
		return
	end
	if background then
		if not State.menu or State.menu.slotCount ~= 36 then
			MC.UseClientPlayerInventoryView()
		end
	end
	acknowledgeAction( actionId, accepted )
	if actionId ~= BACKGROUND_ACTION and not accepted then
		State.lastError = errorCode ~= "" and errorCode or "inventory_action_rejected"
	end
	local applied, applyError = MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, true,
		quickCraft, selectionId, offhand or false )
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
	local title = net.ReadString()
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
		title = title ~= "" and title or nil,
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
	State.quickCraftPreview = nil
	emit( "MC.InventoryOpened", State.session, State )
end )

net.Receive( "mc_inventory_close", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local reason = net.ReadString()
	if State.session and State.session.containerId == containerId and State.session.token == token then
		State.session = nil
		State.actions = {}
		MC.UseClientPlayerInventoryView()
		MC.RebuildClientPrediction( true )
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

function MC.RequestInventoryExitHand()
	if not State.session or State.session.kind ~= "player" then return false end
	local now = RealTime()
	if State.lastExitHandRequest and now - State.lastExitHandRequest < 0.25 then return false end
	State.lastExitHandRequest = now
	net.Start( "mc_inventory_exit_hand" )
		net.WriteString( State.session.token )
	net.SendToServer()
	return true
end

net.Receive( "mc_inventory_exit_hand", function()
	local screen = MC.InventoryUI and MC.InventoryUI.Screen
	if not IsValid( screen ) then return end
	MC.InventoryUI.SetError( screen, "no_gmod_weapon", nil, "inventory.no_gmod_weapon" )
end )

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
	if selected == State.selected then return true end
	State.selectionId = ( State.selectionId + 1 ) % 4294967296
	State.pendingSelection = { id = State.selectionId, selected = selected }
	State.selected = selected
	emit( "MC.InventorySelectionChanged", selected, State )
	net.Start( "mc_inventory_select" )
		net.WriteUInt( selected, 4 )
		net.WriteUInt( State.selectionId, 32 )
	net.SendToServer()
	return true
end

function MC.RequestInventoryWorldAction( operation, whole )
	if State.session or not State.ready or not State.authoritative then return false, "inventory_unavailable" end
	if operation ~= 0 and operation ~= 1 and operation ~= 2 then return false, "invalid_world_action" end
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	local action = { kind = "world", operation = operation, selected = State.selected, whole = whole == true }
	if operation == 0 then
		local aim = MC.PlayerBlockAim( LocalPlayer() )
		if not aim or MC.EntityOccludesBlockAim( LocalPlayer(), aim ) then return false, "no_pick_target" end
		action.bx, action.by, action.bz = aim.bx, aim.by, aim.bz
		action.stack = MC.InventoryPickStackForState( MC.GetBlockState( aim.bx, aim.by, aim.bz ) )
		if not action.stack then return false, "no_pick_item" end
	end
	State.selectionId = ( State.selectionId + 1 ) % 4294967296
	State.pendingSelection = { id = State.selectionId, selected = State.selected }
	action.selectionId = State.selectionId
	return enqueueAction( action )
end

hook.Add( "Think", "mc_inventory_transfer_timeout", function()
	local now = RealTime()
	for transferId, transfer in pairs( State.transfers ) do
		if now - transfer.startedAt > 20 then failTransfer( transferId, "snapshot_timeout" ) end
	end
end )

concommand.Add( "mc_inventory", function() MC.RequestInventoryOpen() end )
