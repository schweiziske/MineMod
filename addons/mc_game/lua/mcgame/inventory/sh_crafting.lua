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
		local targets = data.resultTargets or data.playerTargets or {}
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
		-- ResultContainer.removeItem takes the entire recipe batch, including
		-- secondary click and Q. Consuming inputs for a single item loses output.
		local ok, err = putIntoCursor( container, result, result.count )
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

local function placementFits( recipe, width, height )
	if MC.RecipeBook and MC.RecipeBook.RecipeFitsGrid then
		return MC.RecipeBook.RecipeFitsGrid( recipe, width, height )
	end
	if not recipe or recipe.supported ~= true then return false end
	if recipe.type == "minecraft:crafting_shaped" then
		return recipe.width <= width and recipe.height <= height
	end
	return recipe.type == "minecraft:crafting_shapeless"
		and ( recipe.ingredientCount or 0 ) <= width * height
end

local function sourcePool( container, data )
	local pool, seen = {}, {}
	local function add( index )
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or seen[index] then return end
		local stack = MC.ContainerGetStack( container, index )
		if not MC.IsEmptyItemStack( stack ) then
			pool[#pool + 1] = { index = index, stack = MC.CopyItemStack( stack ) }
		end
		seen[index] = true
	end
	for _, index in ipairs( data.inputSlots or {} ) do add( index ) end
	for _, index in ipairs( data.playerTargets or {} ) do add( index ) end
	return pool
end

local function poolCounts( pool )
	local counts = {}
	for _, entry in ipairs( pool ) do
		local stack = entry.stack
		if not MC.IsEmptyItemStack( stack ) then
			counts[stack.item] = ( counts[stack.item] or 0 ) + stack.count
		end
	end
	return counts
end

local function takePoolAmount( pool, ingredient, amount )
	amount = math.max( 1, math.floor( tonumber( amount ) or 1 ) )
	for _, entry in ipairs( pool ) do
		local stack = entry.stack
		if not MC.IsEmptyItemStack( stack ) and stack.count >= amount
		and MC.IngredientMatches( ingredient, stack ) then
			local taken = MC.CopyItemStack( stack, amount )
			entry.stack = stack.count > amount and MC.CopyItemStack( stack, stack.count - amount ) or nil
			return taken
		end
	end
	return nil
end

local function placementList( recipe, width, height, inputSlots )
	local output = {}
	if recipe.type == "minecraft:crafting_shaped" then
		local offsetX = math.floor( ( width - recipe.width ) * 0.5 )
		local offsetY = math.floor( ( height - recipe.height ) * 0.5 )
		for y = 0, recipe.height - 1 do
			for x = 0, recipe.width - 1 do
				local ingredient = recipe.ingredients[x + y * recipe.width + 1]
				if ingredient then
					local gridIndex = ( x + offsetX ) + ( y + offsetY ) * width + 1
					output[#output + 1] = { slot = inputSlots[gridIndex], ingredient = ingredient }
				end
			end
		end
	else
		for index, ingredient in ipairs( recipe.ingredients or {} ) do
			output[#output + 1] = { slot = inputSlots[index], ingredient = ingredient }
		end
	end
	return output
end

local function clearCraftingAndPlayer( container, data )
	for _, index in ipairs( data.inputSlots or {} ) do
		local ok, err = MC.ContainerSetStack( container, index, nil )
		if not ok then return false, err end
	end
	for _, index in ipairs( data.playerTargets or {} ) do
		local ok, err = MC.ContainerSetStack( container, index, nil )
		if not ok then return false, err end
	end
	return true
end

local function restorePool( container, pool, targets, context )
	for _, entry in ipairs( pool ) do
		if not MC.IsEmptyItemStack( entry.stack ) then
			local remaining = select( 1, MC.ContainerMoveStackTo( container, entry.stack, targets, context ) )
			if not MC.IsEmptyItemStack( remaining ) then return false end
		end
	end
	return true
end

-- Place one recipe (or as many complete copies as the available stacks allow)
-- into a transient 2x2/3x3 menu.  The operation is intentionally atomic: all
-- old grid contents are included in the source pool, the required inputs are
-- selected on the server, and the original snapshot is restored on any
-- capacity/ingredient failure.
function MC.CraftingPlaceRecipe( container, recipe, context, useMax )
	local data = craftingData( container )
	if not data or not recipe then return false, "crafting_recipe_missing" end
	local width = math.max( 1, math.floor( tonumber( data.width ) or 0 ) )
	local height = math.max( 1, math.floor( tonumber( data.height ) or 0 ) )
	if not placementFits( recipe, width, height ) then return false, "recipe_does_not_fit" end
	if not MC.IsEmptyItemStack( container.cursor ) then return false, "recipe_cursor_not_empty" end
	if type( data.inputSlots ) ~= "table" or #data.inputSlots ~= width * height then
		return false, "crafting_input_slots_invalid"
	end

	local snapshot = MC.ContainerSnapshot( container )
	local pool = sourcePool( container, data )
	local counts = poolCounts( pool )
	local amount = 1
	if useMax == true and MC.RecipeBook and MC.RecipeBook.MaxCraftCount then
		amount = MC.RecipeBook.MaxCraftCount( recipe, counts, 64 )
	end
	if amount < 1 then return false, "recipe_ingredients_missing" end

	local placements = placementList( recipe, width, height, data.inputSlots )
	if #placements < 1 then return false, "recipe_ingredients_missing" end
	-- A single input slot cannot hold a mixed tag result.  Reduce a bulk
	-- placement until each selected source stack can represent the whole slot.
	local selectedAmount
	for tryAmount = amount, 1, -1 do
		local trialPool = {}
		for index, entry in ipairs( pool ) do trialPool[index] = { index = entry.index, stack = MC.CopyItemStack( entry.stack ) } end
		local trial = {}
		local valid = true
		for _, placement in ipairs( placements ) do
			local taken = takePoolAmount( trialPool, placement.ingredient, tryAmount )
			if not taken then valid = false break end
			local slot = MC.ContainerGetSlot( container, placement.slot )
			if not slot or tryAmount > MC.InventorySlotLimit( slot, taken ) then valid = false break end
			trial[#trial + 1] = { slot = placement.slot, stack = taken }
		end
		if valid then selectedAmount = tryAmount break end
	end
	if not selectedAmount then return false, "recipe_ingredients_missing" end

	local ok, err = clearCraftingAndPlayer( container, data )
	if not ok then MC.ContainerRestore( container, snapshot ) return false, err or "recipe_clear_failed" end
	local placed = {}
	-- Re-run the deterministic selection against the chosen amount so the
	-- remaining pool exactly matches the stacks that will be returned.
	for _, placement in ipairs( placements ) do
		local taken = takePoolAmount( pool, placement.ingredient, selectedAmount )
		if not taken then
			MC.ContainerRestore( container, snapshot )
			return false, "recipe_ingredients_missing"
		end
		local setOK, setError = MC.ContainerSetStack( container, placement.slot, taken )
		if not setOK then
			MC.ContainerRestore( container, snapshot )
			return false, setError or "recipe_input_set_failed"
		end
		placed[#placed + 1] = placement.slot
	end

	local targets = data.playerTargets or {}
	if not restorePool( container, pool, targets, context or {} ) then
		MC.ContainerRestore( container, snapshot )
		return false, "crafting_inventory_full"
	end
	local refreshed, refreshError = MC.CraftingRefreshResult( container )
	if not refreshed then
		MC.ContainerRestore( container, snapshot )
		return false, refreshError or "crafting_result_refresh_failed"
	end

	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	if #changedSlots > 0 then container.revision = container.revision + 1 end
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) ) end
	local result = {
		ok = true,
		revision = container.revision,
		actionId = context and context.actionId,
		changedSlots = changedSlots,
		changed = changed,
		cursorChanged = false,
		cursor = MC.CopyItemStack( container.cursor ),
		drops = {},
		recipeId = recipe.id,
		amount = selectedAmount,
	}
	if type( container.onCommit ) == "function" and #changedSlots > 0 then
		pcall( container.onCommit, container, result, context or container.context or {} )
	end
	return result
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
