--[[----------------------------------------------------------------------------
	MC : sparse Block Entity type registry and read interface.

	A Block Entity is data attached to a voxel cell. It is deliberately not a
	Garry's Mod Entity. Concrete codecs and lifecycle writes are added in later
	phases; this file reserves the stable type boundary without allocating data
	for ordinary chunks.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.PendingBlockEntityTypes = MC.PendingBlockEntityTypes or {}
MC.BlockEntityTypes = MC.BlockEntityTypes or {}
MC.BlockEntityTypesById = MC.BlockEntityTypesById or {}
MC.BlockEntityRegistryFrozen = MC.BlockEntityRegistryFrozen or false
MC.BlockEntityRegistryHash = MC.BlockEntityRegistryHash or nil

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

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local OPTIONAL_CALLBACKS = {
	"Validate",
	"Encode",
	"Decode",
	"CreateDefault",
	"Migrate",
	"ClientRender",
	"OnUse",
	"OnTick",
	"CollectComponents",
}

function MC.RegisterBlockEntityType( definition )
	if MC.BlockEntityRegistryFrozen then return nil, "registry_frozen" end
	if type( definition ) ~= "table" then return nil, "invalid_definition" end
	local name = normalizeName( definition.name )
	if not name then return nil, "invalid_type_name" end
	if #name > 128 then return nil, "type_name_too_long" end
	if MC.PendingBlockEntityTypes[name] then return nil, "duplicate_type" end
	local codecVersion = tonumber( definition.codecVersion )
	if not codecVersion or math.floor( codecVersion ) ~= codecVersion or codecVersion < 1 or codecVersion > 65535 then
		return nil, "invalid_codec_version"
	end
	for _, callbackName in ipairs( OPTIONAL_CALLBACKS ) do
		local callback = definition[callbackName]
		if callback ~= nil and type( callback ) ~= "function" then return nil, "invalid_" .. string.lower( callbackName ) end
	end

	local registered = {
		name = name,
		codecVersion = codecVersion,
		serverOnly = definition.serverOnly == true,
		affectsGeometry = definition.affectsGeometry == true,
		affectsCollision = definition.affectsCollision == true,
	}
	for _, callbackName in ipairs( OPTIONAL_CALLBACKS ) do registered[callbackName] = definition[callbackName] end
	MC.PendingBlockEntityTypes[name] = registered
	return registered
end

function MC.IsBlockEntityTypeRegistered( typeName )
	local name = normalizeName( typeName )
	if not name then return false end
	return ( MC.PendingBlockEntityTypes and MC.PendingBlockEntityTypes[name] ) ~= nil
		or ( MC.BlockEntityTypes and MC.BlockEntityTypes[name] ) ~= nil
end

-- Public registration-time bridge between a block-state schema and a block
-- entity codec. Game/content addons must use this instead of mutating the
-- pending/finalized schema tables, which are engine-owned implementation data.
function MC.BindBlockEntityType( blockNames, typeName )
	if MC.BlockStateRegistryFrozen then return false, "registry_frozen" end
	local normalizedType = normalizeName( typeName )
	if not normalizedType or not MC.IsBlockEntityTypeRegistered( normalizedType ) then
		return false, "unknown_block_entity_type"
	end
	local names = isstring( blockNames ) and { blockNames } or blockNames
	if not istable( names ) or #names == 0 then return false, "invalid_block_names" end
	local schemas = MC.PendingBlockStateSchemas
	if not istable( schemas ) then return false, "state_registry_unavailable" end
	local resolved = {}
	for index, value in ipairs( names ) do
		local name = normalizeName( value )
		local schema = name and schemas[name] or nil
		if not schema then return false, "unknown_block_state_schema" end
		resolved[index] = schema
	end
	for _, schema in ipairs( resolved ) do schema.blockEntityType = normalizedType end
	return true, #resolved
end

function MC.FinalizeBlockEntityRegistry()
	if MC.BlockEntityRegistryFrozen then return #MC.BlockEntityTypesById end
	if not MC.BlockStateRegistryFrozen and MC.FinalizePreparedBlockStateRegistry then
		local stateCount = MC.FinalizePreparedBlockStateRegistry()
		if not stateCount then return nil, "block_state_registry_unavailable" end
	end
	local names = {}
	for name in pairs( MC.PendingBlockEntityTypes ) do names[#names + 1] = name end
	table.sort( names )
	local byName, byId = {}, {}
	for id, name in ipairs( names ) do
		local definition = MC.PendingBlockEntityTypes[name]
		definition.runtimeId = id
		byName[name] = definition
		byId[id] = definition
	end
	MC.BlockEntityTypes = byName
	MC.BlockEntityTypesById = byId
	local hashLines = { "mc-be-registry-v1\n" }
	for _, name in ipairs( names ) do
		local definition = byName[name]
		-- Only client-visible wire contracts participate. Server-only types never
		-- cross the network and therefore must not make an otherwise compatible
		-- client fail its handshake.
		if not definition.serverOnly then
			hashLines[#hashLines + 1] = table.concat( {
				definition.name,
				tostring( definition.codecVersion ),
				definition.affectsGeometry and "1" or "0",
				definition.affectsCollision and "1" or "0",
			}, "\0" ) .. "\n"
		end
	end
	local mapped = {}
	for stateName, schema in pairs( MC.BlockStateSchemaByName or {} ) do
		if schema.blockEntityType then
			mapped[#mapped + 1] = tostring( stateName ) .. "\0" .. tostring( schema.blockEntityType ) .. "\n"
		end
	end
	table.sort( mapped )
	if #mapped > 0 then
		hashLines[#hashLines + 1] = "mappings\n"
		for _, line in ipairs( mapped ) do hashLines[#hashLines + 1] = line end
	end
	local canonical = table.concat( hashLines )
	MC.BlockEntityRegistryHash = util and util.SHA256 and util.SHA256( canonical )
		or util and util.CRC and util.CRC( canonical ) or canonical
	MC.BlockEntityRegistryFrozen = true
	return #byId
end

function MC.EncodeBlockEntityEnvelope( stateId, record, forClient )
	local valid, definition = MC.ValidateBlockEntityRecord( stateId, record )
	if valid ~= true then return nil, definition or "invalid_block_entity" end
	if forClient == true and definition.serverOnly then return nil, "server_only" end
	local payload = record.data
	if definition.Encode then
		local ok, encoded, encodeError = pcall( definition.Encode, copyValue( record.data ), forClient == true )
		if not ok or encoded == nil then return nil, encodeError or encoded or "block_entity_encode_failed" end
		payload = encoded
	end
	return {
		type = definition.name,
		codecVersion = definition.codecVersion,
		data = payload,
		revision = record.revision,
	}, definition
end

function MC.PrepareBlockEntityWireEnvelope( stateId, record )
	local envelope, definitionOrError = MC.EncodeBlockEntityEnvelope( stateId, record, true )
	if not envelope then return nil, definitionOrError end
	local json = util and util.TableToJSON and util.TableToJSON( {
		hasData = envelope.data ~= nil,
		data = envelope.data,
	}, false ) or nil
	if not json then return nil, "block_entity_json_failed" end
	if #json > 32768 then return nil, "block_entity_payload_too_large" end
	return {
		type = envelope.type,
		codecVersion = envelope.codecVersion,
		payload = json,
	}, definitionOrError
end

function MC.BlockEntityTypeForState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.blockEntityType or nil
end

function MC.ValidateBlockEntityRecord( stateId, record )
	if type( record ) ~= "table" then return false, "invalid_record" end
	local typeName = normalizeName( record.type )
	if not typeName then return false, "invalid_type_name" end
	local expected = MC.BlockEntityTypeForState( stateId )
	if expected ~= typeName then return false, "block_entity_incompatible" end
	local definition = MC.BlockEntityTypes[typeName]
	if not definition then return false, "unknown_block_entity_type" end
	if record.codecVersion ~= nil and tonumber( record.codecVersion ) ~= definition.codecVersion then
		return false, "codec_version_mismatch"
	end
	if definition.Validate then
		local called, ok, err = pcall( definition.Validate, copyValue( record.data ) )
		if not called then return false, "block_entity_validate_failed" end
		if ok ~= true then return false, err or "invalid_block_entity_data" end
	end
	return true, definition
end

-- Construct the canonical default attachment for a state without exposing a
-- registered definition table to callers. Bound states are expected to supply
-- CreateDefault so raw fills, imports and legacy saves can restore the same
-- Block Entity invariant as ordinary transactions.
function MC.CreateDefaultBlockEntityRecord( stateId )
	local expected = MC.BlockEntityTypeForState( stateId )
	if not expected then return nil, "not_block_entity_state" end
	local definition = ( MC.BlockEntityTypes and MC.BlockEntityTypes[expected] )
		or ( MC.PendingBlockEntityTypes and MC.PendingBlockEntityTypes[expected] )
	if not definition then return nil, "unknown_block_entity_type" end
	if CLIENT and definition.serverOnly then return nil, "server_only" end
	if not definition.CreateDefault then return nil, "block_entity_default_unavailable" end
	local called, record, createError = pcall( definition.CreateDefault, stateId )
	if not called or type( record ) ~= "table" then
		return nil, createError or record or "block_entity_create_default_failed"
	end
	record = copyValue( record )
	if record.type == nil then record.type = expected end
	if record.codecVersion == nil then record.codecVersion = definition.codecVersion end
	local valid, validationError = MC.ValidateBlockEntityRecord( stateId, record )
	if valid ~= true then return nil, validationError or "invalid_default_block_entity" end
	return record
end

local function removeChunkBlockEntity( chunk, localIndex )
	if not chunk.blockEntities or chunk.blockEntities[localIndex] == nil then return false end
	chunk.blockEntities[localIndex] = nil
	if next( chunk.blockEntities ) == nil then chunk.blockEntities = nil end
	return true
end

-- Reconcile one cell after a low-level state write. This is intentionally an
-- engine invariant, not a game-layer repair pass: registered callbacks may be
-- supplied by another addon, but the engine owns when their records exist.
function MC.ReconcileChunkLocalBlockEntity( chunk, localIndex, stateId )
	localIndex = math.floor( tonumber( localIndex ) or -1 )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if type( chunk ) ~= "table" or localIndex < 0 then return nil, "invalid_chunk_cell" end
	local expected = MC.BlockEntityTypeForState( stateId )
	local definition = expected and ( ( MC.BlockEntityTypes and MC.BlockEntityTypes[expected] )
		or ( MC.PendingBlockEntityTypes and MC.PendingBlockEntityTypes[expected] ) ) or nil
	local changed = false

	-- Opaque records are archive-preservation payloads. Never manufacture a
	-- second, authoritative record beside one; a later gameplay state mutation
	-- removes the opaque attachment before this function runs.
	if chunk.opaqueBlockEntities and chunk.opaqueBlockEntities[localIndex] ~= nil then
		return removeChunkBlockEntity( chunk, localIndex )
	end

	if not expected or CLIENT and definition and definition.serverOnly then
		return removeChunkBlockEntity( chunk, localIndex )
	end

	local current = chunk.blockEntities and chunk.blockEntities[localIndex] or nil
	if current then
		local valid = MC.ValidateBlockEntityRecord( stateId, current )
		if valid == true then return false end
		changed = removeChunkBlockEntity( chunk, localIndex ) or changed
	end

	local record, createError = MC.CreateDefaultBlockEntityRecord( stateId )
	if not record then
		if createError == "server_only" then return changed end
		return nil, createError
	end
	chunk.blockEntities = chunk.blockEntities or {}
	chunk.blockEntities[localIndex] = record
	return true
end

-- Bulk loaders may install native/packed state storage without visiting the
-- per-cell Lua setter. Finalization calls this once per touched chunk to add
-- missing defaults and discard stale/incompatible attachments.
function MC.ReconcileChunkBlockEntities( chunk )
	if type( chunk ) ~= "table" then return nil, "missing_chunk" end
	if not MC.GetChunkBlockStateByLocalIndex or not MC.ForEachBlockState then
		return nil, "state_storage_unavailable"
	end
	local changed = 0
	local existing = {}
	for localIndex in pairs( chunk.blockEntities or {} ) do existing[#existing + 1] = localIndex end
	for _, localIndex in ipairs( existing ) do
		local stateId = MC.GetChunkBlockStateByLocalIndex( chunk, localIndex ) or 0
		local reconciled, err = MC.ReconcileChunkLocalBlockEntity( chunk, localIndex, stateId )
		if reconciled == nil then return nil, err end
		if reconciled then changed = changed + 1 end
	end
	local reconcileError
	MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
		if reconcileError then return end
		local _, _, _, localIndex = MC.CellToChunk( bx, by, bz )
		local reconciled, err = MC.ReconcileChunkLocalBlockEntity( chunk, localIndex, stateId )
		if reconciled == nil then reconcileError = err return end
		if reconciled then changed = changed + 1 end
	end )
	if reconcileError then return nil, reconcileError end
	return true, changed
end

function MC.DecodeBlockEntityEnvelope( stateId, envelope )
	if type( envelope ) ~= "table" then return nil, "invalid_block_entity_envelope" end
	local definition = MC.BlockEntityTypes[envelope.type]
	if not definition then return nil, "unknown_block_entity_type" end
	local savedVersion = math.floor( tonumber( envelope.codecVersion ) or -1 )
	local data = envelope.data
	if savedVersion ~= definition.codecVersion then
		if not definition.Migrate then return nil, "block_entity_codec_mismatch" end
		local ok, migrated, migrateError = pcall( definition.Migrate, savedVersion, data )
		if not ok or migrated == nil then return nil, migrateError or migrated or "block_entity_migrate_failed" end
		data = migrated
	elseif definition.Decode then
		local ok, decoded, decodeError = pcall( definition.Decode, data, savedVersion )
		if not ok or decoded == nil then return nil, decodeError or decoded or "block_entity_decode_failed" end
		data = decoded
	end
	local record = {
		type = definition.name,
		codecVersion = definition.codecVersion,
		data = data,
		revision = envelope.revision,
	}
	local valid, validationError = MC.ValidateBlockEntityRecord( stateId, record )
	if valid ~= true then return nil, validationError or "invalid_block_entity" end
	return record, definition
end

function MC.GetBlockEntity( bx, by, bz )
	if not MC.CellToChunk or not MC.GetChunk then return nil end
	local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
	if MC.LocalIndexInRange and not MC.LocalIndexInRange( localIndex ) then return nil end
	local chunk = MC.GetChunk( cx, cy, cz )
	local record = chunk and chunk.blockEntities and chunk.blockEntities[localIndex] or nil
	if not record then return nil end
	return copyValue( record )
end

-- CopyComponentsFunction reads BlockEntity#collectComponents before the block
-- is removed. Keep the same boundary here so loot evaluation does not need to
-- know the private storage format of banners, chests, or future block entities.
function MC.CollectBlockEntityComponents( stateId, record )
	if type( record ) ~= "table" then return nil end
	local definition = ( MC.BlockEntityTypes and MC.BlockEntityTypes[record.type] )
		or ( MC.PendingBlockEntityTypes and MC.PendingBlockEntityTypes[record.type] )
	local output = {}
	local stored = type( record.components ) == "table" and record.components
		or type( record.data ) == "table" and type( record.data.components ) == "table" and record.data.components or nil
	for name, value in pairs( stored or {} ) do output[name] = copyValue( value ) end
	if definition and definition.CollectComponents then
		local ok, implicit, collectError = pcall( definition.CollectComponents,
			copyValue( record.data ), stateId, copyValue( record ) )
		if not ok then return nil, "block_entity_component_collect_failed" end
		if implicit == nil and collectError ~= nil then return nil, collectError end
		if implicit ~= nil and type( implicit ) ~= "table" then return nil, "invalid_block_entity_components" end
		for name, value in pairs( implicit or {} ) do output[name] = copyValue( value ) end
	end
	return next( output ) and output or nil
end

if timer and timer.Simple then
	timer.Simple( 0, function()
		if not MC.BlockEntityRegistryFrozen then MC.FinalizeBlockEntityRegistry() end
	end )
else
	MC.FinalizeBlockEntityRegistry()
end
