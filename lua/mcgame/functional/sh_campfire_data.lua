-- Persistent, client-visible campfire block entities.
--
-- Java's update tag contains only Items; CookingTimes and CookingTotalTimes are
-- server persistence data. Encode's forClient flag mirrors that split.

MC = MC or {}

local CAMPFIRE_TYPE = "minecraft:campfire"
local CAMPFIRE_CODEC_VERSION = 1
local CAMPFIRE_SLOTS = 4
local CAMPFIRE_BLOCKS = {
	["minecraft:campfire"] = true,
	["minecraft:soul_campfire"] = true,
}

local function boundedTick( value )
	return math.Clamp( math.floor( tonumber( value ) or 0 ), 0, 72000 )
end

local function normalizeData( data, clientPayload )
	data = data == nil and {} or data
	if type( data ) ~= "table" then return nil, "invalid_campfire_data" end
	local items, occupied = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		if type( entry ) ~= "table" then return nil, "invalid_campfire_item" end
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot < 0 or slot >= CAMPFIRE_SLOTS or occupied[slot] then return nil, "invalid_campfire_slot" end
		occupied[slot] = true
		local stack, stackError = MC.NormalizeItemStack( entry.stack )
		if stackError then return nil, stackError end
		if stack then
			-- CampfireBlockEntity#placeFood always stores exactly one item.
			items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack, 1 ) }
		end
	end
	table.sort( items, function( left, right ) return left.slot < right.slot end )
	local normalized = { items = items }
	if clientPayload == true then return normalized end
	local progress, totals = {}, {}
	for slot = 0, CAMPFIRE_SLOTS - 1 do
		progress[slot + 1] = boundedTick( data.cookingProgress and data.cookingProgress[slot + 1] )
		totals[slot + 1] = boundedTick( data.cookingTotalTime and data.cookingTotalTime[slot + 1] )
		if not occupied[slot] then progress[slot + 1], totals[slot + 1] = 0, 0 end
		if totals[slot + 1] > 0 then progress[slot + 1] = math.min( progress[slot + 1], totals[slot + 1] ) end
	end
	normalized.cookingProgress = progress
	normalized.cookingTotalTime = totals
	return normalized
end

local function validateData( data ) return normalizeData( data, false ) ~= nil end

if not ( MC.PendingBlockEntityTypes and MC.PendingBlockEntityTypes[CAMPFIRE_TYPE] )
	and MC.RegisterBlockEntityType then
	MC.RegisterBlockEntityType( {
		name = CAMPFIRE_TYPE,
		codecVersion = CAMPFIRE_CODEC_VERSION,
		serverOnly = false,
		Validate = validateData,
		Encode = function( data, forClient ) return normalizeData( data, forClient ) end,
		Decode = function( data ) return normalizeData( data, data and data.cookingProgress == nil ) end,
		CreateDefault = function()
			return {
				type = CAMPFIRE_TYPE,
				codecVersion = CAMPFIRE_CODEC_VERSION,
				data = { items = {}, cookingProgress = { 0, 0, 0, 0 }, cookingTotalTime = { 0, 0, 0, 0 } },
			}
		end,
	} )
end

for blockName in pairs( CAMPFIRE_BLOCKS ) do
	local schema = ( MC.PendingBlockStateSchemas or {} )[blockName]
		or ( MC.BlockStateSchemaByName or {} )[blockName]
	if schema then schema.blockEntityType = CAMPFIRE_TYPE end
end

local function stateInfo( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema or not CAMPFIRE_BLOCKS[schema.name] then return nil end
	return {
		name = schema.name,
		lit = MC.GetStateProperty( stateId, "lit" ) == true,
		facing = MC.GetStateProperty( stateId, "facing" ) or "north",
	}
end

function MC.CampfireStateInfo( stateId ) return stateInfo( stateId ) end
function MC.IsCampfireState( stateId ) return stateInfo( stateId ) ~= nil end
function MC.CampfireSlotCount() return CAMPFIRE_SLOTS end

function MC.CampfireStorageFromRecord( record )
	local storage = {}
	for _, entry in ipairs( record and record.data and record.data.items or {} ) do
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot >= 0 and slot < CAMPFIRE_SLOTS then storage[slot + 1] = MC.CopyItemStack( entry.stack, 1 ) end
	end
	return storage
end

function MC.CampfireRecordFromStorage( storage, progress, totals )
	local items = {}
	for slot = 0, CAMPFIRE_SLOTS - 1 do
		local stack = storage and storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) then
			items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack, 1 ) }
		end
	end
	return {
		type = CAMPFIRE_TYPE,
		codecVersion = CAMPFIRE_CODEC_VERSION,
		data = {
			items = items,
			cookingProgress = { boundedTick( progress and progress[1] ), boundedTick( progress and progress[2] ),
				boundedTick( progress and progress[3] ), boundedTick( progress and progress[4] ) },
			cookingTotalTime = { boundedTick( totals and totals[1] ), boundedTick( totals and totals[2] ),
				boundedTick( totals and totals[3] ), boundedTick( totals and totals[4] ) },
		},
	}
end
