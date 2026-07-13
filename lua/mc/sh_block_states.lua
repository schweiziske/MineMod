--[[----------------------------------------------------------------------------
	MC : immutable block-state registry.

	This module deliberately does not replace the legacy id + orient world store.
	It provides the Phase 1 schema/identity layer so generated vanilla schemas,
	custom schemas, parsing and property transitions can be validated before the
	storage/network migration begins.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.PendingBlockStateSchemas = MC.PendingBlockStateSchemas or {}
MC.BlockStateSchemas = MC.BlockStateSchemas or {}
MC.BlockStateSchemaByName = MC.BlockStateSchemaByName or {}
MC.BlockStateRanges = MC.BlockStateRanges or {}
MC.BlockStateRegistryFrozen = MC.BlockStateRegistryFrozen or false
MC.BlockStateCount = MC.BlockStateCount or 0
MC.LegacyStateByBlockOrient = MC.LegacyStateByBlockOrient or {}
MC.LegacyProjectionByState = MC.LegacyProjectionByState or {}

local MAX_STATE_ID = 2147483647

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizeName( value )
	local name = string.lower( trim( value ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	if not string.match( name, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return name
end

local function canonicalValue( value )
	if type( value ) == "boolean" then return value and "true" or "false" end
	if type( value ) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return nil end
		return tostring( value )
	end
	local out = string.lower( trim( value ) )
	return out ~= "" and out or nil
end

local function typedValue( kind, value )
	local canonical = canonicalValue( value )
	if not canonical then return nil end
	if kind == "bool" then
		if canonical == "true" then return true end
		if canonical == "false" then return false end
		return nil
	end
	if kind == "int" then
		local number = tonumber( canonical )
		if not number or math.floor( number ) ~= number then return nil end
		return number
	end
	return canonical
end

local function sortedKeys( input )
	local out = {}
	for key in pairs( input or {} ) do out[#out + 1] = tostring( key ) end
	table.sort( out )
	return out
end

local function copyOrder( input )
	local out = {}
	for i, value in ipairs( input or {} ) do out[i] = tostring( value ) end
	return out
end

local function normalizeProperty( name, definition )
	if not string.match( name, "^[a-z0-9_]+$" ) then return nil, "invalid_property_name" end
	if type( definition ) ~= "table" then return nil, "invalid_property_definition" end

	local kind = string.lower( trim( definition.kind or "enum" ) )
	if kind ~= "bool" and kind ~= "int" and kind ~= "enum" then return nil, "invalid_property_kind" end

	local sourceValues = definition.values
	if kind == "bool" and type( sourceValues ) ~= "table" then sourceValues = { false, true } end
	if kind == "int" and type( sourceValues ) ~= "table" then
		local minValue = tonumber( definition.min )
		local maxValue = tonumber( definition.max )
		if not minValue or not maxValue or math.floor( minValue ) ~= minValue or math.floor( maxValue ) ~= maxValue or minValue > maxValue then
			return nil, "invalid_integer_range"
		end
		sourceValues = {}
		for value = minValue, maxValue do sourceValues[#sourceValues + 1] = value end
	end
	if type( sourceValues ) ~= "table" or #sourceValues == 0 then return nil, "missing_property_values" end

	local values = {}
	local canonicalValues = {}
	local valueIndex = {}
	for i, raw in ipairs( sourceValues ) do
		local typed = typedValue( kind, raw )
		local canonical = canonicalValue( typed )
		if typed == nil or not canonical then return nil, "invalid_property_value" end
		if valueIndex[canonical] ~= nil then return nil, "duplicate_property_value" end
		values[i] = typed
		canonicalValues[i] = canonical
		valueIndex[canonical] = i
	end

	return {
		name = name,
		kind = kind,
		values = values,
		canonicalValues = canonicalValues,
		valueIndex = valueIndex,
		count = #values,
	}
end

local function schemaBlockId( definition, name )
	local blockId = tonumber( definition.blockId )
	if blockId ~= nil and math.floor( blockId ) == blockId and blockId >= 0 then return blockId end
	if MC.ResolveBlock then
		local resolved = MC.ResolveBlock( name )
		if resolved then return resolved.id end
	end
	return nil
end

function MC.RegisterBlockStateSchema( definition )
	if MC.BlockStateRegistryFrozen then return nil, "registry_frozen" end
	if type( definition ) ~= "table" then return nil, "invalid_schema" end

	local name = normalizeName( definition.name or definition.mcid )
	if not name then return nil, "invalid_block_name" end
	if MC.PendingBlockStateSchemas[name] then return nil, "duplicate_block_schema" end

	local properties = definition.properties or {}
	if type( properties ) ~= "table" then return nil, "invalid_properties" end
	local propertyOrder = definition.propertyOrder and copyOrder( definition.propertyOrder ) or sortedKeys( properties )
	if #propertyOrder ~= #sortedKeys( properties ) then return nil, "invalid_property_order" end

	local normalizedProperties = {}
	local propertyByName = {}
	local seen = {}
	local stateCount = 1
	for index, rawName in ipairs( propertyOrder ) do
		local propertyName = string.lower( trim( rawName ) )
		if seen[propertyName] or properties[propertyName] == nil then return nil, "invalid_property_order" end
		seen[propertyName] = true
		local property, err = normalizeProperty( propertyName, properties[propertyName] )
		if not property then return nil, err end
		property.id = index
		normalizedProperties[index] = property
		propertyByName[propertyName] = property
		stateCount = stateCount * property.count
		if stateCount > MAX_STATE_ID then return nil, "too_many_block_states" end
	end
	if definition.stateCount ~= nil and tonumber( definition.stateCount ) ~= stateCount then
		return nil, "state_count_mismatch"
	end

	local defaults = definition.defaults or {}
	if type( defaults ) ~= "table" then return nil, "invalid_defaults" end
	local defaultIndexes = {}
	for index, property in ipairs( normalizedProperties ) do
		local rawDefault = defaults[property.name]
		if rawDefault == nil then return nil, "missing_default_property" end
		local canonical = canonicalValue( typedValue( property.kind, rawDefault ) )
		local valueIndex = canonical and property.valueIndex[canonical] or nil
		if not valueIndex then return nil, "invalid_default_property" end
		defaultIndexes[index] = valueIndex
	end

	local schema = {
		name = name,
		blockId = schemaBlockId( definition, name ),
		blockEntityType = definition.blockEntityType and normalizeName( definition.blockEntityType ) or nil,
		properties = normalizedProperties,
		propertyByName = propertyByName,
		propertyOrder = propertyOrder,
		defaultIndexes = defaultIndexes,
		stateCount = stateCount,
	}
	if definition.blockEntityType and not schema.blockEntityType then return nil, "invalid_block_entity_type" end

	MC.PendingBlockStateSchemas[name] = schema
	return schema
end

local function schemaSort( a, b )
	if a.name == "minecraft:air" then return b.name ~= "minecraft:air" end
	if b.name == "minecraft:air" then return false end
	if a.generated ~= b.generated then return a.generated == true end
	return a.name < b.name
end

function MC.FinalizeBlockStateRegistry( metadata )
	if MC.BlockStateRegistryFrozen then return MC.BlockStateCount end

	local schemas = {}
	for _, schema in pairs( MC.PendingBlockStateSchemas ) do schemas[#schemas + 1] = schema end
	table.sort( schemas, schemaSort )
	local air = MC.PendingBlockStateSchemas["minecraft:air"]
	if not air then return nil, "missing_air_schema" end
	if air.stateCount ~= 1 or air.blockId ~= 0 then return nil, "invalid_air_schema" end
	local seenBlockIds = {}
	local totalStates = 0
	for _, schema in ipairs( schemas ) do
		if schema.blockId ~= nil then
			if seenBlockIds[schema.blockId] then return nil, "duplicate_block_id" end
			seenBlockIds[schema.blockId] = true
		end
		totalStates = totalStates + schema.stateCount
		if totalStates - 1 > MAX_STATE_ID then return nil, "too_many_global_states" end
	end

	local blockSchemas = {}
	local schemasByName = {}
	local ranges = {}
	local firstStateId = 0
	for _, schema in ipairs( schemas ) do
		schema.firstStateId = firstStateId
		schema.lastStateId = firstStateId + schema.stateCount - 1
		schema.strides = {}
		local stride = 1
		for index = #schema.properties, 1, -1 do
			schema.strides[index] = stride
			schema.properties[index].stride = stride
			stride = stride * schema.properties[index].count
		end

		local defaultOrdinal = 0
		for index, valueIndex in ipairs( schema.defaultIndexes ) do
			defaultOrdinal = defaultOrdinal + ( valueIndex - 1 ) * schema.strides[index]
		end
		schema.defaultOrdinal = defaultOrdinal
		schema.defaultStateId = firstStateId + defaultOrdinal

		if schema.blockId ~= nil then
			blockSchemas[schema.blockId] = schema
		end
		schemasByName[schema.name] = schema
		ranges[#ranges + 1] = {
			first = schema.firstStateId,
			last = schema.lastStateId,
			schema = schema,
		}
		firstStateId = schema.lastStateId + 1
	end

	MC.BlockStateSchemas = blockSchemas
	MC.BlockStateSchemaByName = schemasByName
	MC.BlockStateRanges = ranges
	MC.BlockStateCount = firstStateId
	MC.BlockStateRegistryMetadata = metadata or MC.GeneratedStateMetadata or {}
	MC.BlockStateRegistryFrozen = true
	return MC.BlockStateCount
end

local function schemaForState( stateId )
	stateId = tonumber( stateId )
	if not stateId or math.floor( stateId ) ~= stateId or stateId < 0 or stateId >= MC.BlockStateCount then return nil end
	local ranges = MC.BlockStateRanges
	local low, high = 1, #ranges
	while low <= high do
		local middle = math.floor( ( low + high ) * 0.5 )
		local range = ranges[middle]
		if stateId < range.first then
			high = middle - 1
		elseif stateId > range.last then
			low = middle + 1
		else
			return range.schema
		end
	end
	return nil
end

local function resolveSchema( block )
	if type( block ) == "table" and block.firstStateId ~= nil then return block end
	if type( block ) == "number" then return MC.BlockStateSchemas[block] end
	local name = normalizeName( block )
	return name and MC.BlockStateSchemaByName[name] or nil
end

local function statePropertyIndex( schema, stateId, property )
	local ordinal = stateId - schema.firstStateId
	return math.floor( ordinal / property.stride ) % property.count + 1
end

function MC.IsValidBlockState( stateId )
	return schemaForState( stateId ) ~= nil
end

function MC.BlockStateSchemaForState( stateId )
	return schemaForState( stateId )
end

function MC.BlockTypeForState( stateId )
	local schema = schemaForState( stateId )
	return schema and schema.blockId or nil
end

function MC.DefaultBlockState( block )
	local schema = resolveSchema( block )
	return schema and schema.defaultStateId or nil
end

function MC.GetStateProperty( stateId, propertyName )
	local schema = schemaForState( stateId )
	if not schema then return nil, "invalid_state" end
	local property = type( propertyName ) == "number" and schema.properties[propertyName]
		or schema.propertyByName[string.lower( trim( propertyName ) )]
	if not property then return nil, "unknown_property" end
	return property.values[statePropertyIndex( schema, stateId, property )]
end

function MC.StateWith( stateId, propertyName, value )
	local schema = schemaForState( stateId )
	if not schema then return nil, "invalid_state" end
	local property = type( propertyName ) == "number" and schema.properties[propertyName]
		or schema.propertyByName[string.lower( trim( propertyName ) )]
	if not property then return nil, "unknown_property" end
	local canonical = canonicalValue( typedValue( property.kind, value ) )
	local targetIndex = canonical and property.valueIndex[canonical] or nil
	if not targetIndex then return nil, "invalid_property_value" end
	local currentIndex = statePropertyIndex( schema, stateId, property )
	return stateId + ( targetIndex - currentIndex ) * property.stride
end

local function parseStateSpec( spec )
	local text = trim( spec )
	local blockName, properties = string.match( text, "^([^%s%[]+)%s*%[(.*)%]%s*$" )
	if blockName then return normalizeName( blockName ), properties end
	if string.find( text, "[", 1, true ) or string.find( text, "]", 1, true ) then return nil, nil, "invalid_brackets" end
	return normalizeName( text ), nil
end

function MC.ParseBlockState( spec )
	if not MC.BlockStateRegistryFrozen then return nil, "registry_not_frozen" end
	local blockName, propertyText, parseError = parseStateSpec( spec )
	if parseError then return nil, parseError end
	local schema = blockName and MC.BlockStateSchemaByName[blockName] or nil
	if not schema then return nil, "unknown_block" end

	local indexes = {}
	for i, value in ipairs( schema.defaultIndexes ) do indexes[i] = value end
	local seen = {}
	if propertyText ~= nil and trim( propertyText ) ~= "" then
		for part in string.gmatch( propertyText, "[^,]+" ) do
			local propertyName, rawValue = string.match( part, "^%s*([a-zA-Z0-9_]+)%s*=%s*([^,%s]+)%s*$" )
			propertyName = propertyName and string.lower( propertyName ) or nil
			local property = propertyName and schema.propertyByName[propertyName] or nil
			if not propertyName or not property then return nil, "unknown_property" end
			if seen[propertyName] then return nil, "duplicate_property" end
			seen[propertyName] = true
			local canonical = canonicalValue( typedValue( property.kind, rawValue ) )
			local valueIndex = canonical and property.valueIndex[canonical] or nil
			if not valueIndex then return nil, "invalid_property_value" end
			indexes[property.id] = valueIndex
		end
	elseif propertyText ~= nil and #schema.properties > 0 and trim( propertyText ) == "" then
		return nil, "empty_properties"
	end

	local ordinal = 0
	for index, valueIndex in ipairs( indexes ) do ordinal = ordinal + ( valueIndex - 1 ) * schema.strides[index] end
	return schema.firstStateId + ordinal
end

function MC.FormatBlockState( stateId )
	local schema = schemaForState( stateId )
	if not schema then return nil, "invalid_state" end
	if #schema.properties == 0 then return schema.name end
	local properties = {}
	for index, property in ipairs( schema.properties ) do
		properties[index] = property.name .. "=" .. property.canonicalValues[statePropertyIndex( schema, stateId, property )]
	end
	return schema.name .. "[" .. table.concat( properties, "," ) .. "]"
end

function MC.StateFromLegacy( blockId, orient )
	if not MC.BlockStateRegistryFrozen then return nil, false, "registry_not_frozen" end
	blockId = math.floor( tonumber( blockId ) or 0 )
	if blockId == 0 then
		local air = MC.DefaultBlockState( 0 )
		return air, air ~= nil, air and nil or "missing_air_state"
	end
	local schema = MC.BlockStateSchemas[blockId]
	if not schema then return nil, false, "missing_block_schema" end
	orient = MC.NormalizeOrient and MC.NormalizeOrient( blockId, orient ) or math.floor( tonumber( orient ) or 0 )
	local blockCache = MC.LegacyStateByBlockOrient[blockId]
	if not blockCache then
		blockCache = {}
		MC.LegacyStateByBlockOrient[blockId] = blockCache
	end
	local cached = blockCache[orient]
	if cached ~= nil then return cached, true end

	local stateText = MC.BlockStateText and MC.BlockStateText( blockId, orient ) or ""
	local spec = schema.name
	if stateText ~= "" then spec = spec .. "[" .. stateText .. "]" end
	local stateId, err = MC.ParseBlockState( spec )
	if not stateId then return nil, false, err or "legacy_state_parse_failed" end
	blockCache[orient] = stateId
	return stateId, true
end

function MC.LegacyFromState( stateId )
	if not MC.BlockStateRegistryFrozen then return nil, nil, false, "registry_not_frozen" end
	stateId = tonumber( stateId )
	local cached = stateId and MC.LegacyProjectionByState[stateId] or nil
	if cached then return cached.blockId, cached.orient, cached.exact end
	local schema = schemaForState( stateId )
	if not schema or schema.blockId == nil then return nil, nil, false, "missing_block_id" end
	if schema.blockId == 0 then return 0, 0, stateId == schema.defaultStateId end

	local formatted = MC.FormatBlockState( stateId )
	local stateText = formatted and string.match( formatted, "%[(.*)%]$" ) or ""
	local orient = MC.StateToOrient and MC.StateToOrient( schema.blockId, stateText ) or 0
	if MC.NormalizeOrient then orient = MC.NormalizeOrient( schema.blockId, orient ) end
	local projected = MC.StateFromLegacy( schema.blockId, orient )
	local exact = projected == stateId
	MC.LegacyProjectionByState[stateId] = {
		blockId = schema.blockId,
		orient = orient,
		exact = exact,
	}
	return schema.blockId, orient, exact
end

function MC.StateIsLegacyProjectable( stateId )
	local _, _, exact = MC.LegacyFromState( stateId )
	return exact == true
end

function MC.GetBlockState( bx, by, bz )
	if not MC.GetBlock then return nil, "legacy_store_unavailable" end
	local blockId = MC.GetBlock( bx, by, bz )
	local orient = blockId ~= 0 and MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	local stateId, _, err = MC.StateFromLegacy( blockId, orient )
	return stateId, err
end

function MC.RegisterGeneratedBlockStateSchemas()
	if MC.BlockStateRegistryFrozen then return nil, "registry_frozen" end
	local generated = MC.GeneratedBlockStateSchemas
	if type( generated ) ~= "table" then return 0 end
	local count = 0
	local stateCount = 0
	for _, definition in ipairs( generated ) do
		local schema, err = MC.RegisterBlockStateSchema( definition )
		if not schema then return nil, err end
		schema.generated = true
		count = count + 1
		stateCount = stateCount + schema.stateCount
	end
	local metadata = MC.GeneratedStateMetadata or {}
	if metadata.blockCount ~= nil and tonumber( metadata.blockCount ) ~= count then return nil, "generated_block_count_mismatch" end
	if metadata.stateCount ~= nil and tonumber( metadata.stateCount ) ~= stateCount then return nil, "generated_state_count_mismatch" end
	return count
end

local function reportRegistryError( err )
	local message = "[MC] block-state registry: " .. tostring( err or "unknown error" ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
end

function MC.FinalizePreparedBlockStateRegistry()
	if MC.BlockStateRegistryFrozen then return MC.BlockStateCount end
	local count, err = MC.FinalizeBlockStateRegistry( MC.GeneratedStateMetadata )
	if not count then
		reportRegistryError( err )
		return nil, err
	end
	return count
end

if type( MC.GeneratedBlockStateSchemas ) == "table" and next( MC.PendingBlockStateSchemas ) == nil then
	local _, err = MC.RegisterGeneratedBlockStateSchemas()
	if err then
		reportRegistryError( err )
	elseif timer and timer.Simple then
		-- Freeze after all autorun files in the current load tick had a chance to
		-- register custom schemas. Late registration is intentionally rejected.
		timer.Simple( 0, function()
			if not MC.BlockStateRegistryFrozen then MC.FinalizePreparedBlockStateRegistry() end
		end )
	else
		MC.FinalizePreparedBlockStateRegistry()
	end
end
