-- Persistent furnace block entities and shared fuel/cooking helpers.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

local FURNACE_TYPE = "minecraft:furnace"
local FURNACE_CODEC_VERSION = 1
local FURNACE_SLOTS = 3
local FURNACE_BLOCKS = {
	["minecraft:furnace"] = "minecraft:smelting",
	["minecraft:blast_furnace"] = "minecraft:blasting",
}

local function normalizeData( data )
	data = data == nil and {} or data
	if type( data ) ~= "table" then return nil, "invalid_furnace_data" end
	local items, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		if type( entry ) ~= "table" then return nil, "invalid_furnace_item" end
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot < 0 or slot >= FURNACE_SLOTS or seen[slot] then return nil, "invalid_furnace_slot" end
		seen[slot] = true
		local stack, stackError = MC.NormalizeItemStack( entry.stack )
		if stackError then return nil, stackError end
		if stack then items[#items + 1] = { slot = slot, stack = stack } end
	end
	table.sort( items, function( left, right ) return left.slot < right.slot end )
	local function bounded( value, minimum, maximum )
		return math.Clamp( math.floor( tonumber( value ) or 0 ), minimum, maximum )
	end
	return {
		items = items,
		litTimeRemaining = bounded( data.litTimeRemaining, 0, 72000 ),
		litTotalTime = bounded( data.litTotalTime, 0, 72000 ),
		cookingTimeSpent = bounded( data.cookingTimeSpent, 0, 72000 ),
		cookingTotalTime = bounded( data.cookingTotalTime, 0, 72000 ),
		recipeUses = bounded( data.recipeUses, 0, 2147483647 ),
	}
end

local function encodeData( data ) return normalizeData( data ) end
local function decodeData( data ) return normalizeData( data ) end
local function validateData( data ) return normalizeData( data ) ~= nil end

if Blocks and not Blocks.IsBlockEntityTypeRegistered( FURNACE_TYPE ) then
	Blocks.RegisterBlockEntityType( {
		name = FURNACE_TYPE,
		codecVersion = FURNACE_CODEC_VERSION,
		serverOnly = true,
		Validate = validateData,
		Encode = encodeData,
		Decode = decodeData,
		CreateDefault = function()
			return {
				type = FURNACE_TYPE,
				codecVersion = FURNACE_CODEC_VERSION,
				data = { items = {}, litTimeRemaining = 0, litTotalTime = 0,
					cookingTimeSpent = 0, cookingTotalTime = 0, recipeUses = 0 },
			}
		end,
	} )
end

if Blocks then
	local names = {}
	for blockName in pairs( FURNACE_BLOCKS ) do names[#names + 1] = blockName end
	Blocks.BindBlockEntityType( names, FURNACE_TYPE )
end

local function stateInfo( stateId )
	local name = Blocks and Blocks.Name( stateId ) or nil
	local recipeType = name and FURNACE_BLOCKS[name] or nil
	if not recipeType then return nil end
	return { name = name, recipeType = recipeType,
		lit = Blocks.GetProperty( stateId, "lit" ) == true }
end

function MC.FurnaceStateInfo( stateId ) return stateInfo( stateId ) end
function MC.FurnaceRecipeType( stateId )
	local info = stateInfo( stateId )
	return info and info.recipeType or nil
end
function MC.IsFurnaceState( stateId ) return stateInfo( stateId ) ~= nil end

local function storageFromData( data )
	local storage = {}
	for _, entry in ipairs( data and data.items or {} ) do
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot >= 0 and slot < FURNACE_SLOTS then storage[slot + 1] = MC.CopyItemStack( entry.stack ) end
	end
	return storage
end

function MC.FurnaceStorageFromRecord( record ) return storageFromData( record and record.data ) end

function MC.FurnaceRecordFromStorage( storage, state )
	local items = {}
	for slot = 0, FURNACE_SLOTS - 1 do
		local stack = storage and storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) then items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack ) } end
	end
	state = state or {}
	return {
		type = FURNACE_TYPE,
		codecVersion = FURNACE_CODEC_VERSION,
		data = {
			items = items,
			litTimeRemaining = state.litTimeRemaining or 0,
			litTotalTime = state.litTotalTime or 0,
			cookingTimeSpent = state.cookingTimeSpent or 0,
			cookingTotalTime = state.cookingTotalTime or 0,
			recipeUses = state.recipeUses or 0,
		},
	}
end

function MC.FurnaceSlotCount() return FURNACE_SLOTS end

local EXACT_FUEL_TIMES = {
	["minecraft:lava_bucket"] = 20000,
	["minecraft:coal_block"] = 16000,
	["minecraft:blaze_rod"] = 2400,
	["minecraft:coal"] = 1600,
	["minecraft:charcoal"] = 1600,
	["minecraft:stick"] = 100,
	["minecraft:bowl"] = 100,
	["minecraft:bamboo_mosaic"] = 300,
	["minecraft:bamboo_mosaic_stairs"] = 300,
	["minecraft:bamboo_mosaic_slab"] = 150,
	["minecraft:note_block"] = 300,
	["minecraft:bookshelf"] = 300,
	["minecraft:chiseled_bookshelf"] = 300,
	["minecraft:lectern"] = 300,
	["minecraft:jukebox"] = 300,
	["minecraft:chest"] = 300,
	["minecraft:trapped_chest"] = 300,
	["minecraft:crafting_table"] = 300,
	["minecraft:daylight_detector"] = 300,
	["minecraft:bow"] = 300,
	["minecraft:fishing_rod"] = 300,
	["minecraft:ladder"] = 300,
	["minecraft:wooden_sword"] = 200,
	["minecraft:wooden_shovel"] = 200,
	["minecraft:wooden_pickaxe"] = 200,
	["minecraft:wooden_axe"] = 200,
	["minecraft:wooden_hoe"] = 200,
	["minecraft:wooden_spear"] = 200,
	["minecraft:crossbow"] = 300,
	["minecraft:dried_kelp_block"] = 4001,
	["minecraft:bamboo"] = 50,
	["minecraft:dead_bush"] = 100,
	["minecraft:short_dry_grass"] = 100,
	["minecraft:tall_dry_grass"] = 100,
	["minecraft:scaffolding"] = 50,
	["minecraft:loom"] = 300,
	["minecraft:barrel"] = 300,
	["minecraft:cartography_table"] = 300,
	["minecraft:fletching_table"] = 300,
	["minecraft:smithing_table"] = 300,
	["minecraft:composter"] = 300,
	["minecraft:azalea"] = 100,
	["minecraft:flowering_azalea"] = 100,
	["minecraft:mangrove_roots"] = 300,
	["minecraft:leaf_litter"] = 100,
}

local TAG_FUEL_TIMES = {
	{ "minecraft:logs", 300 }, { "minecraft:bamboo_blocks", 300 },
	{ "minecraft:planks", 300 }, { "minecraft:wooden_stairs", 300 },
	{ "minecraft:wooden_slabs", 150 }, { "minecraft:wooden_doors", 200 },
	{ "minecraft:wooden_trapdoors", 300 }, { "minecraft:wooden_pressure_plates", 300 },
	{ "minecraft:wooden_shelves", 300 }, { "minecraft:wooden_fences", 300 },
	{ "minecraft:fence_gates", 300 }, { "minecraft:wool", 100 },
	{ "minecraft:wooden_buttons", 100 }, { "minecraft:saplings", 100 },
	{ "minecraft:wool_carpets", 167 }, { "minecraft:boats", 1200 },
	{ "minecraft:banners", 300 }, { "minecraft:signs", 200 },
	{ "minecraft:hanging_signs", 800 },
}

function MC.FurnaceFuelTime( stack )
	if MC.IsEmptyItemStack( stack ) then return 0 end
	local item = tostring( stack.item or "" )
	local exact = EXACT_FUEL_TIMES[item]
	if exact then return exact end
	for _, entry in ipairs( TAG_FUEL_TIMES ) do
		if MC.ItemInTag and MC.ItemInTag( item, entry[1] ) then
			if not ( MC.ItemInTag( item, "minecraft:non_flammable_wood" ) ) then return entry[2] end
		end
	end
	return 0
end

function MC.FurnaceFuelRemainder( stack )
	if not MC.IsEmptyItemStack( stack ) and stack.item == "minecraft:lava_bucket" then
		return MC.NewItemStack( "minecraft:bucket", 1 )
	end
end

local function putFurnaceResultInCursor( container, output, amount )
	local carried = container.cursor
	amount = math.max( 1, math.floor( tonumber( amount ) or 1 ) )
	if MC.IsEmptyItemStack( carried ) then
		return MC.ContainerSetCursor( container, MC.CopyItemStack( output, amount ) )
	end
	if not MC.ItemStacksCanMerge( carried, output ) then return false, "result_cursor_different_item" end
	if carried.count + amount > MC.ItemStackMaxCount( carried ) then return false, "result_cursor_full" end
	return MC.ContainerSetCursor( container, MC.CopyItemStack( carried, carried.count + amount ) )
end

function MC.FurnaceTakeResult( container, slotIndex, button, _, context, mode )
	local data = container and container.furnace
	if not data or slotIndex ~= data.resultSlot then return false, "invalid_result_slot" end
	local slot = MC.ContainerGetSlot( container, data.resultSlot )
	local output = slot and MC.InventorySlotGet( slot ) or nil
	if MC.IsEmptyItemStack( output ) then return true end
	context = context or container.context or {}

	if mode == "quick_move" then
		local remaining, moved = MC.ContainerMoveStackTo( container, output, data.resultTargets or data.playerTargets, context )
		if not moved then return false, "furnace_inventory_full" end
		return MC.InventorySlotSet( slot, remaining )
	end
	if mode == "swap" then
		local hotbarIndex = container.hotbarSlots[( tonumber( button ) or -1 ) + 1]
		local target = hotbarIndex ~= nil and MC.ContainerGetSlot( container, hotbarIndex ) or nil
		if not target then return false, "missing_hotbar_slot" end
		local existing = MC.InventorySlotGet( target )
		if MC.IsEmptyItemStack( existing ) then
			if output.count > MC.InventorySlotLimit( target, output ) then return false, "result_hotbar_full" end
			local ok, err = MC.InventorySlotSet( target, output )
			if not ok then return false, err end
		elseif MC.ItemStacksCanMerge( existing, output ) then
			if existing.count + output.count > MC.InventorySlotLimit( target, output ) then return false, "result_hotbar_full" end
			local ok, err = MC.InventorySlotSet( target, MC.CopyItemStack( existing, existing.count + output.count ) )
			if not ok then return false, err end
		else
			return false, "result_hotbar_occupied"
		end
		return MC.InventorySlotSet( slot, nil )
	end
	if button ~= 0 and button ~= 1 then return false, "invalid_button" end
	local amount = output.count
	if mode == "throw" then
		amount = button == 0 and 1 or output.count
	elseif button == 1 and MC.IsEmptyItemStack( container.cursor ) then
		amount = math.floor( ( output.count + 1 ) / 2 )
	end
	local ok, err = putFurnaceResultInCursor( container, output, amount )
	if not ok then return false, err end
	return MC.InventorySlotSet( slot,
		output.count > amount and MC.CopyItemStack( output, output.count - amount ) or nil )
end

local function finishPlacement( container, snapshot, context )
	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	local cursorChanged = not MC.ItemStacksEqual( container.cursor, snapshot.cursor )
	if #changedSlots > 0 or cursorChanged then container.revision = container.revision + 1 end
	local changed = {}
	for _, index in ipairs( changedSlots ) do
		changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) )
	end
	local result = {
		ok = true, revision = container.revision, changedSlots = changedSlots, changed = changed,
		cursorChanged = cursorChanged, cursor = MC.CopyItemStack( container.cursor ), drops = {},
	}
	if type( container.onCommit ) == "function" and ( #changedSlots > 0 or cursorChanged ) then
		local called, commitError = pcall( container.onCommit, container, result, context or container.context or {} )
		if not called then MC.ContainerRestore( container, snapshot ) return nil, commitError or "container_commit_failed" end
	end
	return result
end

function MC.FurnacePlaceRecipe( container, recipe, context, useMax )
	local data = container and container.furnace
	if not data or not recipe or recipe.supported ~= true or recipe.type ~= data.recipeType then
		return nil, "recipe_does_not_fit"
	end
	local snapshot = MC.ContainerSnapshot( container )
	local input = MC.ContainerGetStack( container, data.inputSlot )
	if not MC.IsEmptyItemStack( input ) and not MC.IngredientMatches( recipe.ingredient, input ) then
		local remaining, moved = MC.ContainerMoveStackTo( container, input, data.playerTargets, context )
		if not moved or not MC.IsEmptyItemStack( remaining ) then
			MC.ContainerRestore( container, snapshot )
			return nil, "furnace_input_occupied"
		end
		MC.ContainerSetStack( container, data.inputSlot, nil )
		input = nil
	end

	local chosen = not MC.IsEmptyItemStack( input ) and MC.CopyItemStack( input ) or nil
	if not chosen then
		for _, index in ipairs( data.playerTargets or {} ) do
			local stack = MC.ContainerGetStack( container, index )
			if MC.IngredientMatches( recipe.ingredient, stack ) then chosen = MC.CopyItemStack( stack ) break end
		end
	end
	if not chosen then MC.ContainerRestore( container, snapshot ) return nil, "recipe_ingredients_missing" end

	local currentCount = not MC.IsEmptyItemStack( input ) and input.count or 0
	local available = currentCount
	for _, index in ipairs( data.playerTargets or {} ) do
		local stack = MC.ContainerGetStack( container, index )
		if not MC.IsEmptyItemStack( stack ) and MC.ItemStacksCanMerge( chosen, stack )
		and MC.IngredientMatches( recipe.ingredient, stack ) then available = available + stack.count end
	end
	local maximum = MC.ItemStackMaxCount( chosen )
	local desired = useMax == true and math.min( available, maximum ) or math.min( available, currentCount + 1 )
	if desired <= currentCount then return finishPlacement( container, snapshot, context ) end
	local needed = desired - currentCount
	for _, index in ipairs( data.playerTargets or {} ) do
		if needed <= 0 then break end
		local stack = MC.ContainerGetStack( container, index )
		if not MC.IsEmptyItemStack( stack ) and MC.ItemStacksCanMerge( chosen, stack )
		and MC.IngredientMatches( recipe.ingredient, stack ) then
			local taken = math.min( needed, stack.count )
			MC.ContainerSetStack( container, index,
				stack.count > taken and MC.CopyItemStack( stack, stack.count - taken ) or nil )
			needed = needed - taken
		end
	end
	if needed > 0 then MC.ContainerRestore( container, snapshot ) return nil, "recipe_ingredients_missing" end
	MC.ContainerSetStack( container, data.inputSlot, MC.CopyItemStack( chosen, desired ) )
	return finishPlacement( container, snapshot, context )
end
