-- Persistent Hopper / Dispenser / Dropper block-entity records.

MC = MC or {}

local API = MC.API or {}
local Blocks = API.Blocks or {}
local L = MC.LogisticsParity or {}
local C = L.Constants or {}
local CODEC_VERSION = 1

local TYPES = {
	["minecraft:hopper"] = { kind = "hopper", slots = C.hopperSlots or 5 },
	["minecraft:dispenser"] = { kind = "dispenser", slots = C.dispenserSlots or 9 },
	["minecraft:dropper"] = { kind = "dropper", slots = C.dispenserSlots or 9 },
}

local function boundedInteger( value, minimum, maximum, fallback )
	value = tonumber( value )
	if value == nil then value = fallback or minimum end
	return math.max( minimum, math.min( maximum, math.floor( value ) ) )
end

local function normalizeData( typeName, data )
	local definition = TYPES[typeName]
	if not definition then return nil, "unknown_logistics_type" end
	data = data == nil and {} or data
	if type( data ) ~= "table" then return nil, "invalid_logistics_data" end
	local items, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		if type( entry ) ~= "table" then return nil, "invalid_logistics_item" end
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot < 0 or slot >= definition.slots or seen[slot] then return nil, "invalid_logistics_slot" end
		seen[slot] = true
		local stack, stackError = MC.NormalizeItemStack( entry.stack )
		if stackError then return nil, stackError end
		if stack then items[#items + 1] = { slot = slot, stack = stack } end
	end
	table.sort( items, function( left, right ) return left.slot < right.slot end )
	local normalized = { items = items }
	local customName = data.customName
	if customName ~= nil then
		if type( customName ) ~= "string" or #customName > 256 then return nil, "invalid_logistics_name" end
		if customName ~= "" then normalized.customName = customName end
	end
	if definition.kind == "hopper" then
		normalized.transferCooldown = boundedInteger( data.transferCooldown, -1, 2147483647,
			C.hopperInitialCooldown or -1 )
		normalized.tickedGameTime = boundedInteger( data.tickedGameTime, 0, 9007199254740991, 0 )
	end
	return normalized
end

local function createDefault( typeName )
	local data = { items = {} }
	if typeName == "minecraft:hopper" then
		data.transferCooldown = C.hopperInitialCooldown or -1
		data.tickedGameTime = 0
	end
	return { type = typeName, codecVersion = CODEC_VERSION, data = data }
end

for typeName in pairs( TYPES ) do
	if Blocks and not Blocks.IsBlockEntityTypeRegistered( typeName ) then
		local captured = typeName
		Blocks.RegisterBlockEntityType( {
			name = captured,
			codecVersion = CODEC_VERSION,
			serverOnly = true,
			Validate = function( data ) return normalizeData( captured, data ) ~= nil end,
			Encode = function( data ) return normalizeData( captured, data ) end,
			Decode = function( data ) return normalizeData( captured, data ) end,
			CollectComponents = function( data )
				local normalized, err = normalizeData( captured, data )
				if not normalized then return nil, err end
				return normalized.customName and { ["minecraft:custom_name"] = normalized.customName } or nil
			end,
			CreateDefault = function() return createDefault( captured ) end,
		} )
	end
	if Blocks then Blocks.BindBlockEntityType( typeName, typeName ) end
end

function L.ContainerDefinitionForState( stateId )
	local blockName = Blocks and Blocks.Name and Blocks.Name( stateId ) or nil
	local definition = blockName and TYPES[blockName] or nil
	if not definition then return nil end
	return { type = blockName, kind = definition.kind, slots = definition.slots }
end

function L.ContainerDefinitionForRecord( record )
	local definition = type( record ) == "table" and TYPES[record.type] or nil
	if not definition then return nil end
	return { type = record.type, kind = definition.kind, slots = definition.slots }
end

function L.StorageFromRecord( record )
	local definition = L.ContainerDefinitionForRecord( record )
	if not definition then return nil, "invalid_logistics_record" end
	local storage = {}
	for _, entry in ipairs( record.data and record.data.items or {} ) do
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot >= 0 and slot < definition.slots then storage[slot + 1] = MC.CopyItemStack( entry.stack ) end
	end
	return storage
end

function L.RecordFromStorage( typeName, storage, state )
	local definition = TYPES[typeName]
	if not definition then return nil, "unknown_logistics_type" end
	local items = {}
	for slot = 0, definition.slots - 1 do
		local stack = type( storage ) == "table" and storage[slot + 1] or nil
		if not MC.IsEmptyItemStack( stack ) then
			items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack ) }
		end
	end
	state = type( state ) == "table" and state or {}
	local data = { items = items }
	if type( state.customName ) == "string" and state.customName ~= "" then data.customName = state.customName end
	if definition.kind == "hopper" then
		data.transferCooldown = boundedInteger( state.transferCooldown, -1, 2147483647,
			C.hopperInitialCooldown or -1 )
		data.tickedGameTime = boundedInteger( state.tickedGameTime, 0, 9007199254740991, 0 )
	end
	return { type = typeName, codecVersion = CODEC_VERSION, data = data }
end

function L.ContainerSlotCount( kind )
	for _, definition in pairs( TYPES ) do
		if definition.kind == kind then return definition.slots end
	end
	return nil
end

