--[[----------------------------------------------------------------------------
    Shared crafting-menu rules.

    The input grid and result are transient menu slots, just like Minecraft's
    TransientCraftingContainer/ResultSlot.  The server owns the menu and calls
    these functions through sh_click.lua; clients only receive the resulting
    slot deltas.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Crafting = MC.Crafting or {}

local function craftingData( container )
	return type( container ) == "table" and type( container.crafting ) == "table" and container.crafting or nil
end

local function inputGrid( container )
	local data = craftingData( container )
	if not data then return nil end
	local width = math.max( 1, math.floor( tonumber( data.width ) or 0 ) )
	local height = math.max( 1, math.floor( tonumber( data.height ) or 0 ) )
	local grid = {}
	for position = 1, width * height do
		local slotIndex = data.inputSlots and data.inputSlots[position]
		grid[position] = slotIndex ~= nil and MC.ContainerGetStack( container, slotIndex ) or nil
	end
	return grid, width, height
end

local function occupiedInputSlots( container )
	local data = craftingData( container )
	local output = {}
	for _, index in ipairs( data and data.inputSlots or {} ) do
		local stack = MC.ContainerGetStack( container, index )
		if not MC.IsEmptyItemStack( stack ) then output[#output + 1] = index end
	end
	return output
end

function MC.CraftingGetRecipe( container )
	local grid, width, height = inputGrid( container )
	if not grid or not MC.FindCraftingRecipe then return nil end
	return MC.FindCraftingRecipe( grid, width, height )
end

function MC.CraftingRefreshResult( container )
	local data = craftingData( container )
	if not data then return false, "crafting_data_missing" end
	local resultSlot = MC.ContainerGetSlot( container, data.resultSlot )
	if not resultSlot then return false, "crafting_result_slot_missing" end
	local recipe = MC.CraftingGetRecipe( container )
	local result = recipe and MC.AssembleRecipe( recipe ) or nil
	local ok, err = MC.InventorySlotSet( resultSlot, result )
	if not ok then return false, err or "crafting_result_set_failed" end
	data.recipe = recipe
	return true
end

local function sameOutput( left, right )
	return MC.ItemStacksCanMerge( left, right )
end

local function consumeInputs( container, context )
	local data = craftingData( container )
	local indices = occupiedInputSlots( container )
	if #indices < 1 then return false, "crafting_inputs_missing" end
	for _, index in ipairs( indices ) do
		local removed, err = MC.InventorySlotTake( MC.ContainerGetSlot( container, index ), 1, context )
		if not removed then return false, err or "crafting_input_consume_failed" end
	end
	return true
end

local function putIntoCursor( container, output, amount )
	local carried = container.cursor
	amount = math.max( 1, math.floor( tonumber( amount ) or 0 ) )
	if MC.IsEmptyItemStack( carried ) then
		return MC.ContainerSetCursor( container, MC.CopyItemStack( output, amount ) )
	end
	if not sameOutput( carried, output ) then return false, "result_cursor_different_item" end
	local room = MC.ItemStackMaxCount( carried ) - carried.count
	if room < amount then return false, "result_cursor_full" end
	return MC.ContainerSetCursor( container, MC.CopyItemStack( carried, carried.count + amount ) )
end

local function takeOneResult( container, button, state, context, mode )
	local data = craftingData( container)
	if not data then return false, "crafting_data_missing" end
	if not MC.CraftingRefreshResult( container ) then return false, "crafting_result_refresh_failed" end
	local result = MC.ContainerGetStack( container, data.resultSlot )
	if MC.IsEmptyItemStack( result ) then return false, "no_crafting_result" end

	if mode == "quick_move" then
		local targets = data.playerTargets or {}
		local moveSnapshot = MC.ContainerSnapshot( container )
		local remaining, moved = MC.ContainerMoveStackTo( container, result, targets, context )
		if not moved or not MC.IsEmptyItemStack( remaining ) then
			MC.ContainerRestore( container, moveSnapshot )
			return false, "crafting_inventory_full"
		end
	elseif mode == "swap" then
		local hotbarIndex = container.hotbarSlots[( tonumber( button ) or -1 ) + 1]
		local target = hotbarIndex ~= nil and MC.ContainerGetSlot( container, hotbarIndex ) or nil
		if not target then return false, "missing_hotbar_slot" end
		local existing = MC.InventorySlotGet( target )
		if MC.IsEmptyItemStack( existing ) then
			if not MC.InventorySlotMayPlace( target, result, context )
			or result.count > MC.InventorySlotLimit( target, result ) then
				return false, "result_hotbar_denied"
			end
			local ok, err = MC.InventorySlotSet( target, result )
			if not ok then return false, err end
		elseif sameOutput( existing, result ) then
			local room = MC.InventorySlotLimit( target, result ) - existing.count
			if room < result.count then return false, "result_hotbar_full" end
			local ok, err = MC.InventorySlotSet( target, MC.CopyItemStack( existing, existing.count + result.count ) )
			if not ok then return false, err end
		else
			return false, "result_hotbar_occupied"
		end
	else
		if button ~= 0 and button ~= 1 then return false, "invalid_button" end
		local amount = button == 1 and 1 or result.count
		local ok, err = putIntoCursor( container, result, amount )
		if not ok then return false, err end
	end

	local consumed, consumeError = consumeInputs( container, context )
	if not consumed then return false, consumeError end
	return true
end

function MC.CraftingTakeResult( container, slotIndex, button, state, context, mode )
	local data = craftingData( container )
	if not data or slotIndex ~= data.resultSlot then return false, "invalid_result_slot" end
	state = state or { drops = {} }
	context = context or container.context or {}

	if mode == "quick_move" then
		-- Shift-click repeatedly crafts while the output can be inserted.  Each
		-- iteration is atomic so a partially inserted output never consumes the
		-- grid and loses items.
		local crafted = 0
		if MC.CraftingRefreshResult( container ) then
			if MC.IsEmptyItemStack( MC.ContainerGetStack( container, data.resultSlot ) ) then return true end
		end
		for _ = 1, 64 do
			local snapshot = MC.ContainerSnapshot( container )
			local ok, err = takeOneResult( container, 0, state, context, mode )
			if not ok then
				MC.ContainerRestore( container, snapshot )
				if crafted > 0 then break end
				return false, err
			end
			crafted = crafted + 1
		end
		if crafted > 0 then return true end
		return false, "no_crafting_result"
	end

	if MC.CraftingRefreshResult( container )
	and MC.IsEmptyItemStack( MC.ContainerGetStack( container, data.resultSlot ) ) then
		return true
	end
	return takeOneResult( container, button, state, context, mode )
end

function MC.CraftingClearInputs( container )
	local data = craftingData( container )
	if not data then return {} end
	local output = {}
	for _, index in ipairs( data.inputSlots or {} ) do
		local stack = MC.ContainerGetStack( container, index )
		if not MC.IsEmptyItemStack( stack ) then
			output[#output + 1] = MC.CopyItemStack( stack )
			MC.ContainerSetStack( container, index, nil )
		end
	end
	MC.ContainerSetStack( container, data.resultSlot, nil )
	data.recipe = nil
	return output
end
