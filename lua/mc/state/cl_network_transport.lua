--[[----------------------------------------------------------------------------
	MC Phase 4 client block-state transport.

	The wire decoder is intentionally kept separate from cl_net.lua.  This file
	owns registry negotiation, world generation/revision ordering, state snapshot
	assembly and atomic state/Block Entity transaction application.
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net or {}
local T = MC.StateNetworkTransport or {}
MC.StateNetworkTransport = T

local FLAG_CORRECTION = Net.TransactionFlag and Net.TransactionFlag.CORRECTION or 0x01
local FLAG_MESH_RATE_LIMITED = Net.TransactionFlag and Net.TransactionFlag.MESH_RATE_LIMITED or 0x02
local BE_NONE = Net.BlockEntityOp and Net.BlockEntityOp.NONE or 0
local BE_REMOVE = Net.BlockEntityOp and Net.BlockEntityOp.REMOVE or 1
local BE_UPSERT = Net.BlockEntityOp and Net.BlockEntityOp.UPSERT or 2
local SNAPSHOT_PART_MAX = Net.STATE_SNAPSHOT_PART_BYTES or 30000
local BLOCK_ENTITY_PAYLOAD_MAX = Net.BLOCK_ENTITY_PAYLOAD_MAX or 32768
local GAP_GRACE_SECONDS = 0.35

T.generation = T.generation
T.appliedRevision = T.appliedRevision or 0
T.ready = T.ready or false
T.desynced = T.desynced or false
T.pendingTransactions = T.pendingTransactions or {}
T.pendingCorrections = T.pendingCorrections or {}
T.snapshot = T.snapshot
T.awaitingSnapshot = T.awaitingSnapshot or false
T.resyncRequested = T.resyncRequested or false
MC.AppliedStateRevision = T.appliedRevision
MC.StateWorldGeneration = T.generation

local function publishAppliedRevision( revision )
	T.appliedRevision = revision
	MC.AppliedStateRevision = revision
	MC.StateWorldGeneration = T.generation
end

local function localSchemaHash()
	local metadata = MC.BlockStateRegistryMetadata
	return metadata and tostring( metadata.schemaHash or "" ) or ""
end

local function localBlockEntityHash()
	if isfunction( MC.BlockEntityRegistryHash ) then return tostring( MC.BlockEntityRegistryHash() or "" ) end
	if isstring( MC.BlockEntityRegistryHash ) then return MC.BlockEntityRegistryHash end
	local metadata = MC.BlockEntityRegistryMetadata
	return metadata and tostring( metadata.registryHash or metadata.hash or "" ) or ""
end

local function supportedCapabilities()
	local capability = Net.Capability or {}
	return bit.bor(
		capability.STATE_ID or 0,
		capability.SECTION_PALETTE or 0,
		capability.STATE_SNAPSHOT or 0,
		capability.BLOCK_ENTITY_ENVELOPE or 0,
		capability.REGISTRY_HASH or 0
	)
end

local function validUInt32( value )
	return isnumber( value ) and value >= 0 and value <= 4294967295 and value == math.floor( value )
end

local function cloneValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[cloneValue( key, seen )] = cloneValue( item, seen ) end
	return out
end

local function resetClientWorld()
	if MC.ResetClientWorldForStateSync then return MC.ResetClientWorldForStateSync() end
	if MC.StateNetworkResetWorld then return MC.StateNetworkResetWorld() end
	if MC.FreeAllMeshes then MC.FreeAllMeshes() end
	if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	MC.World = {}
	MC.LoadedChunkKeys = {}
	MC.MeshDirty = {}
	MC.MeshDirtyRateLimited = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PhysDirtyBulk = {}
	MC.PhysDirtyBulkOrder = {}
	MC.PendingFull = {}
	MC.PendingPredictions = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end

local function sendHelloAck( accepted )
	if not net or not net.Start then return end
	net.Start( "mc_state_hello_ack" )
		net.WriteUInt( accepted and ( Net.PROTOCOL_VERSION or 0 ) or 0, 16 )
		net.WriteUInt( supportedCapabilities(), Net.CAPABILITY_BITS or 16 )
		net.WriteUInt( T.generation or 0, Net.GENERATION_BITS or 32 )
		net.WriteString( localSchemaHash() )
		net.WriteString( localBlockEntityHash() )
	net.SendToServer()
end

function T.RequestResync( reason )
	if T.resyncRequested then return false end
	T.resyncRequested = true
	T.desynced = true
	if net and net.Start then
		net.Start( "mc_state_resync_request" )
			net.WriteUInt( T.generation or 0, Net.GENERATION_BITS or 32 )
			net.WriteUInt( T.appliedRevision or 0, Net.REVISION_BITS or 32 )
			net.WriteString( string.sub( tostring( reason or "state_desync" ), 1, 160 ) )
		net.SendToServer()
	elseif RunConsoleCommand then
		RunConsoleCommand( "mc_resync" )
	end
	return true
end

function T.AcceptHello( hello )
	if not istable( hello ) then return false, "invalid_hello" end
	local version = math.floor( tonumber( hello.protocolVersion ) or -1 )
	local capabilities = math.floor( tonumber( hello.capabilities ) or 0 )
	local generation = tonumber( hello.generation )
	local revision = tonumber( hello.revision )
	local maxStateId = math.floor( tonumber( hello.maxStateId ) or -1 )
	if version < ( Net.MIN_PROTOCOL_VERSION or Net.PROTOCOL_VERSION or 0 )
	or version > ( Net.PROTOCOL_VERSION or version ) then return false, "protocol_version_mismatch" end
	if bit.band( capabilities, Net.REQUIRED_CAPABILITIES or 0 ) ~= ( Net.REQUIRED_CAPABILITIES or 0 ) then
		return false, "missing_required_capability"
	end
	if not validUInt32( generation ) or not validUInt32( revision ) then return false, "invalid_generation_revision" end
	if maxStateId < math.max( 0, ( MC.BlockStateCount or 1 ) - 1 ) then return false, "remote_state_range_too_small" end
	if tostring( hello.schemaHash or "" ) ~= localSchemaHash() then return false, "state_registry_mismatch" end
	local localBEHash = localBlockEntityHash()
	if tostring( hello.blockEntityHash or "" ) ~= localBEHash then
		return false, "block_entity_registry_mismatch"
	end

	if T.generation ~= nil and T.generation ~= generation then resetClientWorld() end
	T.generation = generation
	publishAppliedRevision( revision )
	T.ready = true
	T.desynced = false
	T.resyncRequested = false
	T.pendingTransactions = {}
	T.pendingCorrections = {}
	T.snapshot = nil
	T.awaitingSnapshot = true
	return true
end

local function markCellChanged( cell, oldStateId, rateLimited )
	if MC.MarkLightingDirtyForStateChange then
		MC.MarkLightingDirtyForStateChange( cell.bx, cell.by, cell.bz,
			oldStateId, cell.stateId, rateLimited )
	elseif MC.MarkLightingDirtyAroundCell then
		MC.MarkLightingDirtyAroundCell( cell.bx, cell.by, cell.bz, nil, rateLimited )
	end
	if MC.MarkDirty then MC.MarkDirty( cell.bx, cell.by, cell.bz, rateLimited ) end
	if MC.MarkCellPhysNeighbours then
		MC.MarkCellPhysNeighbours( cell.bx, cell.by, cell.bz, false, rateLimited == true )
	end
end

local function blockEntityAt( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local chunk = MC.GetChunk( cx, cy, cz )
	return chunk and chunk.blockEntities and chunk.blockEntities[li] or nil
end

local function setBlockEntityAt( bx, by, bz, record )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local chunk = MC.GetChunk( cx, cy, cz )
	if record then
		chunk = chunk or MC.EnsureChunk( cx, cy, cz )
		chunk.blockEntities = chunk.blockEntities or {}
		chunk.blockEntities[li] = record
	elseif chunk and chunk.blockEntities then
		chunk.blockEntities[li] = nil
		if next( chunk.blockEntities ) == nil then chunk.blockEntities = nil end
	end
end

local function decodeBlockEntity( cell, revision )
	if cell.blockEntityOp == nil or cell.blockEntityOp == BE_NONE then return nil, nil end
	if cell.blockEntityOp == BE_REMOVE then return false, nil end
	if cell.blockEntityOp ~= BE_UPSERT or not istable( cell.blockEntityEnvelope ) then
		return nil, "invalid_block_entity_operation"
	end
	local envelope = cloneValue( cell.blockEntityEnvelope )
	envelope.revision = revision
	local record, definition = MC.DecodeBlockEntityEnvelope( cell.stateId, envelope )
	if not record then return nil, definition or "invalid_block_entity_envelope" end
	record.revision = revision
	return record, nil, definition
end

local function applyTransactionNow( transaction )
	if not MC.SetBlockStateRaw or not MC.GetBlockState then return false, "state_storage_unavailable" end
	local seen, prepared = {}, {}
	for index, cell in ipairs( transaction.cells or {} ) do
		if not istable( cell ) then return false, "invalid_cell:" .. index end
		cell.bx = math.floor( tonumber( cell.bx ) or 0 )
		cell.by = math.floor( tonumber( cell.by ) or 0 )
		cell.bz = math.floor( tonumber( cell.bz ) or 0 )
		cell.stateId = math.floor( tonumber( cell.stateId ) or -1 )
		if not Net.ValidateStateId( cell.stateId )
		or ( MC.IsValidBlockState and not MC.IsValidBlockState( cell.stateId ) ) then return false, "invalid_state_id" end
		local key = MC.CellKey( cell.bx, cell.by, cell.bz )
		if seen[key] then return false, "duplicate_cell" end
		seen[key] = true
		prepared[#prepared + 1] = {
			cell = cell,
			oldStateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0,
			oldBlockEntity = cloneValue( blockEntityAt( cell.bx, cell.by, cell.bz ) ),
		}
	end

	local written = 0
	for index, item in ipairs( prepared ) do
		local _, _, _, changed, writeError = MC.SetBlockStateRaw(
			item.cell.bx, item.cell.by, item.cell.bz, item.cell.stateId )
		if writeError ~= nil then
			for rollback = written, 1, -1 do
				local old = prepared[rollback]
				MC.SetBlockStateRaw( old.cell.bx, old.cell.by, old.cell.bz, old.oldStateId )
				setBlockEntityAt( old.cell.bx, old.cell.by, old.cell.bz, old.oldBlockEntity )
			end
			return false, writeError or "state_write_failed:" .. index
		end
		item.changed = changed == true
		written = index
	end

	for index, item in ipairs( prepared ) do
		local record, decodeError, definition = decodeBlockEntity( item.cell, transaction.revision )
		if decodeError then
			for rollback = #prepared, 1, -1 do
				local old = prepared[rollback]
				MC.SetBlockStateRaw( old.cell.bx, old.cell.by, old.cell.bz, old.oldStateId )
				setBlockEntityAt( old.cell.bx, old.cell.by, old.cell.bz, old.oldBlockEntity )
			end
			return false, decodeError .. ":" .. index
		end
		if record == false then setBlockEntityAt( item.cell.bx, item.cell.by, item.cell.bz, nil )
		elseif record then setBlockEntityAt( item.cell.bx, item.cell.by, item.cell.bz, record ) end
		item.blockEntityDefinition = definition
		item.oldBlockEntityDefinition = item.oldBlockEntity and MC.BlockEntityTypes
			and MC.BlockEntityTypes[item.oldBlockEntity.type] or nil
	end

	local rateLimited = bit.band( transaction.flags or 0, FLAG_MESH_RATE_LIMITED ) ~= 0
	local correction = bit.band( transaction.flags or 0, FLAG_CORRECTION ) ~= 0
	for _, item in ipairs( prepared ) do
		if item.changed then
			markCellChanged( item.cell, item.oldStateId, rateLimited )
		elseif item.cell.blockEntityOp ~= BE_NONE then
			local oldDefinition = item.oldBlockEntityDefinition
			local newDefinition = item.blockEntityDefinition
			if ( oldDefinition and oldDefinition.affectsGeometry ) or ( newDefinition and newDefinition.affectsGeometry ) then
				if MC.MarkDirty then MC.MarkDirty( item.cell.bx, item.cell.by, item.cell.bz, rateLimited ) end
			end
			if ( oldDefinition and oldDefinition.affectsCollision ) or ( newDefinition and newDefinition.affectsCollision ) then
				if MC.MarkCellPhysNeighbours then
					MC.MarkCellPhysNeighbours( item.cell.bx, item.cell.by, item.cell.bz, false, rateLimited == true )
				end
			end
		end
		if MC.ConfirmStatePrediction then
			MC.ConfirmStatePrediction( item.cell.bx, item.cell.by, item.cell.bz,
				item.cell.stateId, transaction.revision )
		end
	end
	return true
end

local function drainCorrections()
	if T.snapshot or T.awaitingSnapshot or T.desynced then return end
	local pending = T.pendingCorrections
	T.pendingCorrections = {}
	for _, correction in ipairs( pending ) do
		if correction.revision == T.appliedRevision then
			local ok, err = applyTransactionNow( correction )
			if not ok then T.RequestResync( err or "correction_apply_failed" ) return end
		elseif correction.revision > T.appliedRevision then
			T.pendingCorrections[#T.pendingCorrections + 1] = correction
		end
	end
end

local function drainTransactions()
	if T.snapshot or T.awaitingSnapshot or T.desynced then return end
	while true do
		local revision = ( T.appliedRevision or 0 ) + 1
		local transaction = T.pendingTransactions[revision]
		if not transaction then break end
		T.pendingTransactions[revision] = nil
		local ok, err = applyTransactionNow( transaction )
		if not ok then T.RequestResync( err or "transaction_apply_failed" ) return end
		publishAppliedRevision( revision )
	end

	local lowest
	for revision in pairs( T.pendingTransactions ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	if lowest and lowest > T.appliedRevision + 1 then T.gapSince = T.gapSince or SysTime()
	else T.gapSince = nil end
	drainCorrections()
end

function T.AcceptTransaction( transaction )
	if not T.ready or T.desynced then return false, "transport_not_ready" end
	if not istable( transaction ) or transaction.generation ~= T.generation then return false, "generation_mismatch" end
	local revision = tonumber( transaction.revision )
	if not validUInt32( revision ) then return false, "invalid_revision" end
	transaction.revision = revision
	transaction.flags = math.floor( tonumber( transaction.flags ) or 0 )

	if bit.band( transaction.flags, FLAG_CORRECTION ) ~= 0 then
		if revision < T.appliedRevision then return true, "stale_correction" end
		if T.snapshot or T.awaitingSnapshot then
			T.pendingCorrections[#T.pendingCorrections + 1] = transaction
			return true
		end
		if revision > T.appliedRevision then
			T.pendingCorrections[#T.pendingCorrections + 1] = transaction
			return true, "correction_waiting_for_revision"
		end
		local ok, err = applyTransactionNow( transaction )
		if not ok then T.RequestResync( err or "correction_apply_failed" ) end
		return ok, err
	end
	if revision <= T.appliedRevision then return true, "stale" end
	if T.pendingTransactions[revision] then return true, "duplicate" end
	T.pendingTransactions[revision] = transaction
	drainTransactions()
	return not T.desynced
end

function T.BeginSnapshot( metadata )
	if not T.ready or not istable( metadata ) then return false, "transport_not_ready" end
	if metadata.generation ~= T.generation then return false, "generation_mismatch" end
	if tostring( metadata.schemaHash or "" ) ~= localSchemaHash() then return false, "state_registry_mismatch" end
	local localBEHash = localBlockEntityHash()
	if tostring( metadata.blockEntityHash or "" ) ~= localBEHash then
		return false, "block_entity_registry_mismatch"
	end
	local baseRevision = tonumber( metadata.baseRevision )
	local token = tonumber( metadata.token )
	local totalBytes = math.floor( tonumber( metadata.totalBytes ) or -1 )
	local partCount = math.floor( tonumber( metadata.partCount ) or -1 )
	if not validUInt32( baseRevision ) or not validUInt32( token )
	or totalBytes < 1 or partCount < 1 or partCount > 65535 then return false, "invalid_snapshot_header" end
	for revision in pairs( T.pendingTransactions ) do
		if revision <= baseRevision then T.pendingTransactions[revision] = nil end
	end
	T.snapshot = {
		generation = T.generation,
		baseRevision = baseRevision,
		token = token,
		totalBytes = totalBytes,
		partCount = partCount,
		parts = {},
		receivedParts = 0,
		receivedBytes = 0,
		ended = false,
		crc = nil,
	}
	T.awaitingSnapshot = true
	T.desynced = false
	T.resyncRequested = false
	return true
end

function T.AcceptSnapshotPart( generation, token, partIndex, data )
	local snapshot = T.snapshot
	if not snapshot or generation ~= snapshot.generation or token ~= snapshot.token then return false, "snapshot_identity_mismatch" end
	partIndex = math.floor( tonumber( partIndex ) or -1 )
	if partIndex < 0 or partIndex >= snapshot.partCount or not isstring( data )
	or #data < 1 or #data > SNAPSHOT_PART_MAX then return false, "invalid_snapshot_part" end
	if snapshot.parts[partIndex + 1] then return true, "duplicate" end
	snapshot.parts[partIndex + 1] = data
	snapshot.receivedParts = snapshot.receivedParts + 1
	snapshot.receivedBytes = snapshot.receivedBytes + #data
	if snapshot.receivedBytes > snapshot.totalBytes then return false, "snapshot_too_large" end
	return true
end

local function sendSnapshotAck( snapshot, success )
	if not net or not net.Start then return end
	net.Start( "mc_state_snapshot_ack" )
		net.WriteUInt( snapshot.generation, Net.GENERATION_BITS or 32 )
		net.WriteUInt( snapshot.token, 32 )
		net.WriteUInt( T.appliedRevision or 0, Net.REVISION_BITS or 32 )
		net.WriteBool( success == true )
	net.SendToServer()
end

function T.EndSnapshot( generation, baseRevision, token, crc )
	local snapshot = T.snapshot
	if not snapshot or generation ~= snapshot.generation or token ~= snapshot.token
	or baseRevision ~= snapshot.baseRevision then return false, "snapshot_identity_mismatch" end
	if snapshot.receivedParts ~= snapshot.partCount or snapshot.receivedBytes ~= snapshot.totalBytes then
		return false, "snapshot_incomplete"
	end
	local compressed = table.concat( snapshot.parts )
	if tostring( crc or "" ) ~= "" and util.CRC( compressed ) ~= tostring( crc ) then
		sendSnapshotAck( snapshot, false )
		T.snapshot = nil
		T.RequestResync( "snapshot_crc_mismatch" )
		return false, "snapshot_crc_mismatch"
	end
	local json = util.Decompress( compressed )
	local saveData = json and util.JSONToTable( json ) or nil
	local ok, loadError = saveData and MC.LoadSnapshotSaveData and MC.LoadSnapshotSaveData( saveData )
	if ok ~= true then
		sendSnapshotAck( snapshot, false )
		T.snapshot = nil
		T.RequestResync( loadError or "snapshot_decode_failed" )
		return false, loadError or "snapshot_decode_failed"
	end

	T.snapshot = nil
	T.awaitingSnapshot = false
	publishAppliedRevision( baseRevision )
	for revision in pairs( T.pendingTransactions ) do
		if revision <= baseRevision then T.pendingTransactions[revision] = nil end
	end
	-- Corrections received before/during the snapshot target predictions that
	-- the snapshot loader has just discarded. Reapplying them could overwrite
	-- a newer ordered transaction, so the snapshot itself supersedes them.
	T.pendingCorrections = {}
	drainTransactions()
	sendSnapshotAck( snapshot, not T.desynced )
	return not T.desynced
end

function T.CheckRevisionGap( now )
	if not T.gapSince or T.snapshot or T.awaitingSnapshot or T.desynced then return false end
	now = tonumber( now ) or SysTime()
	if now - T.gapSince < GAP_GRACE_SECONDS then return false end
	return T.RequestResync( "revision_gap" )
end

local function readBlockEntityOperation()
	local operation = net.ReadUInt( 2 )
	if operation == BE_NONE or operation == BE_REMOVE then return operation end
	if operation ~= BE_UPSERT then return nil, nil, "invalid_block_entity_operation" end
	local typeName = net.ReadString()
	local codecVersion = net.ReadUInt( 16 )
	local payloadLength = net.ReadUInt( 16 )
	if typeName == "" or #typeName > 160 or payloadLength > BLOCK_ENTITY_PAYLOAD_MAX then
		return nil, nil, "invalid_block_entity_header"
	end
	local payload = net.ReadData( payloadLength )
	local decoded = payload and #payload == payloadLength and util.JSONToTable( payload ) or nil
	if not istable( decoded ) or decoded.hasData == nil
	or ( decoded.hasData == true and decoded.data == nil ) then return nil, nil, "invalid_block_entity_payload" end
	return operation, {
		type = typeName,
		codecVersion = codecVersion,
		data = decoded.hasData == true and decoded.data or nil,
	}
end

local function readStateCell()
	local cell = {
		bx = net.ReadInt( Net.COORD_BITS or 20 ),
		by = net.ReadInt( Net.COORD_BITS or 20 ),
		bz = net.ReadInt( Net.COORD_BITS or 20 ),
		stateId = net.ReadUInt( Net.STATE_ID_BITS or 20 ),
	}
	local operation, envelope, err = readBlockEntityOperation()
	cell.blockEntityOp = operation
	cell.blockEntityEnvelope = envelope
	return cell, err
end

if net and net.Receive then
	net.Receive( "mc_state_hello", function()
		local hello = {
			protocolVersion = net.ReadUInt( 16 ),
			capabilities = net.ReadUInt( Net.CAPABILITY_BITS or 16 ),
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			maxStateId = net.ReadUInt( Net.STATE_ID_BITS or 20 ),
			schemaHash = net.ReadString(),
			blockEntityHash = net.ReadString(),
		}
		local accepted, err = T.AcceptHello( hello )
		sendHelloAck( accepted )
		if not accepted then T.RequestResync( err or "hello_rejected" ) end
	end )

	net.Receive( "mc_state_set", function()
		local transaction = {
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			flags = net.ReadUInt( 8 ),
			cells = {},
		}
		local cell, err = readStateCell()
		if err then T.RequestResync( err ) return end
		transaction.cells[1] = cell
		local ok, acceptError = T.AcceptTransaction( transaction )
		if not ok and not T.resyncRequested then T.RequestResync( acceptError or "state_set_rejected" ) end
	end )

	net.Receive( "mc_state_set_bulk", function()
		local transaction = {
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			flags = net.ReadUInt( 8 ),
			cells = {},
		}
		local count = net.ReadUInt( Net.COUNT_BITS or 14 )
		if count < 1 or count > ( Net.MAX_STATE_BULK_CELLS or 768 ) then
			T.RequestResync( "invalid_state_bulk_count" )
			return
		end
		for index = 1, count do
			local cell, err = readStateCell()
			if err then T.RequestResync( err ) return end
			transaction.cells[index] = cell
		end
		local ok, acceptError = T.AcceptTransaction( transaction )
		if not ok and not T.resyncRequested then T.RequestResync( acceptError or "state_bulk_rejected" ) end
	end )

	net.Receive( "mc_state_snapshot_begin", function()
		local metadata = {
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			baseRevision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			token = net.ReadUInt( 32 ),
			totalBytes = net.ReadUInt( 32 ),
			partCount = net.ReadUInt( 16 ),
			schemaHash = net.ReadString(),
			blockEntityHash = net.ReadString(),
		}
		local ok, err = T.BeginSnapshot( metadata )
		if not ok then T.RequestResync( err or "snapshot_begin_rejected" ) end
	end )

	net.Receive( "mc_state_snapshot_part", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local token = net.ReadUInt( 32 )
		local partIndex = net.ReadUInt( 16 )
		local length = net.ReadUInt( 16 )
		local data = length > 0 and length <= SNAPSHOT_PART_MAX and net.ReadData( length ) or nil
		local ok, err = T.AcceptSnapshotPart( generation, token, partIndex, data )
		if not ok then T.RequestResync( err or "snapshot_part_rejected" ) end
	end )

	net.Receive( "mc_state_snapshot_end", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local baseRevision = net.ReadUInt( Net.REVISION_BITS or 32 )
		local token = net.ReadUInt( 32 )
		local crc = net.ReadString()
		local ok, err = T.EndSnapshot( generation, baseRevision, token, crc )
		if not ok and not T.resyncRequested then T.RequestResync( err or "snapshot_end_rejected" ) end
	end )

	timer.Create( "mc_state_revision_gap", 0.1, 0, function() T.CheckRevisionGap() end )
end
