--[[----------------------------------------------------------------------------
	MC authoritative block-state server transport.

	The world and transaction modules call this API; this module never mutates
	voxel storage. Every ordered message carries one world generation and block
	revision so clients can reject stale or skipped data and request a snapshot.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local N = MC.Net
if not N then error( "MC state network protocol is unavailable" ) end
local TRANSPORT_RELOAD = SV.StateNetworkTransportLoaded == true
SV.StateNetworkTransportLoaded = true

local SNAPSHOT_PART_BYTES = N.STATE_SNAPSHOT_PART_BYTES
local STREAM_PART_BYTES = N.STATE_STREAM_PART_BYTES or 30000
local MAX_STREAM_CELLS = N.MAX_STATE_STREAM_CELLS or 131072
local CHUNK_PATCH_PART_BYTES = N.CHUNK_PATCH_PART_BYTES or 30000
local CHUNK_PATCH_MAX_BYTES = N.CHUNK_PATCH_MAX_BYTES or 16777216
local BLOCK_ENTITY_PAYLOAD_MAX = N.BLOCK_ENTITY_PAYLOAD_MAX
local TRANSACTION_PAYLOAD_MAX = N.STATE_TRANSACTION_PAYLOAD_MAX
local TRANSACTION_FLAG_CORRECTION = N.TransactionFlag.CORRECTION
local TRANSACTION_FLAG_MESH_RATE_LIMITED = N.TransactionFlag.MESH_RATE_LIMITED
local TRANSACTION_FLAG_COALESCED_BULK = N.TransactionFlag.COALESCED_BULK or 0x04
local BLOCK_ENTITY_NONE = N.BlockEntityOp.NONE
local BLOCK_ENTITY_REMOVE = N.BlockEntityOp.REMOVE
local BLOCK_ENTITY_UPSERT = N.BlockEntityOp.UPSERT
local ALL_CAPABILITIES = bit.bor( N.REQUIRED_CAPABILITIES, N.Capability.BLOCK_ENTITY_ENVELOPE )

local function reliablePayloadBytes( overheadBytes, protocolMaximum )
	if SV.ReliableNetPayloadBytes then
		return SV.ReliableNetPayloadBytes( overheadBytes, protocolMaximum )
	end
	return math.max( 1, math.min( protocolMaximum, 2048 - overheadBytes ) )
end

local function reliableBudgetBytes()
	if SV.ReliableNetBudgetBytes then return SV.ReliableNetBudgetBytes() end
	return 2048
end

SV.StateNetClients = SV.StateNetClients or setmetatable( {}, { __mode = "k" } )
-- Lua 5.1 math.random cannot portably accept the full unsigned 32-bit range.
SV.WorldGeneration = math.floor( tonumber( SV.WorldGeneration ) or math.random( 1, 2147483647 ) )
SV.BlockRevision = math.floor( tonumber( SV.BlockRevision ) or 0 )
SV.StateSnapshotToken = math.floor( tonumber( SV.StateSnapshotToken ) or 0 )

local function schemaHash()
	return MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or ""
end

local function blockEntityRegistryHash()
	if not MC.BlockEntityRegistryFrozen and MC.FinalizeBlockEntityRegistry then
		MC.FinalizeBlockEntityRegistry()
	end
	return tostring( MC.BlockEntityRegistryHash or "" )
end

function SV.GetBlockEntityRegistryHash()
	return blockEntityRegistryHash()
end

local function nextSnapshotToken()
	SV.StateSnapshotToken = ( SV.StateSnapshotToken + 1 ) % 4294967296
	return SV.StateSnapshotToken
end

local function validPlayer( ply )
	return IsValid( ply ) and ply:IsPlayer()
end

local function compatibleClient( ply )
	local state = SV.StateNetClients[ply]
	return state and state.ready == true
end

local function writeOrderedHeader( revision )
	net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
	net.WriteUInt( revision, N.REVISION_BITS )
end

local function writeCell( change )
	net.WriteInt( math.floor( change.bx ), N.COORD_BITS )
	net.WriteInt( math.floor( change.by ), N.COORD_BITS )
	net.WriteInt( math.floor( change.bz ), N.COORD_BITS )
	net.WriteUInt( math.floor( change.stateId ), N.STATE_ID_BITS )
end

local function clientVisibleBlockEntity( record )
	if not istable( record ) or not isstring( record.type ) then return nil end
	local definition = MC.BlockEntityTypes and MC.BlockEntityTypes[record.type]
	if not definition or definition.serverOnly then return nil end
	return record, definition
end

-- Encode every envelope before net.Start. A failed codec/JSON/size check can
-- therefore fall back to a snapshot without emitting a partial transaction.
local function prepareBlockEntityEnvelope( change )
	if change.blockEntityChanged == false then return { op = BLOCK_ENTITY_NONE } end
	local oldRecord = change.oldBlockEntity
	local newRecord = change.newBlockEntity
	if newRecord == nil and change.blockEntity ~= nil then newRecord = change.blockEntity end
	local oldVisible = clientVisibleBlockEntity( oldRecord )
	local visible, definition = clientVisibleBlockEntity( newRecord )
	if not visible then
		return { op = ( oldVisible or change.removeBlockEntity == true ) and BLOCK_ENTITY_REMOVE or BLOCK_ENTITY_NONE }
	end
	local wire, wireError = change.blockEntityWire, nil
	if not wire and MC.PrepareBlockEntityWireEnvelope then
		wire, wireError = MC.PrepareBlockEntityWireEnvelope( change.stateId, visible )
	end
	if not wire then return nil, wireError or "block_entity_wire_encode_failed" end
	if not isstring( wire.payload ) or #wire.payload > BLOCK_ENTITY_PAYLOAD_MAX then
		return nil, "block_entity_payload_too_large"
	end
	return {
		op = BLOCK_ENTITY_UPSERT,
		type = wire.type or definition.name,
		codecVersion = wire.codecVersion or definition.codecVersion,
		payload = wire.payload,
	}
end

local function writeBlockEntityEnvelope( envelope )
	net.WriteUInt( envelope.op, 2 )
	if envelope.op ~= BLOCK_ENTITY_UPSERT then return end
	net.WriteString( envelope.type )
	net.WriteUInt( envelope.codecVersion, 16 )
	net.WriteUInt( #envelope.payload, 16 )
	net.WriteData( envelope.payload, #envelope.payload )
end

local function validateChange( change )
	if not istable( change ) then return false, "invalid_change" end
	if not N.ValidateStateId( change.stateId ) then return false, "invalid_state_id" end
	for _, key in ipairs( { "bx", "by", "bz" } ) do
		local value = tonumber( change[key] )
		if not value or value % 1 ~= 0 then return false, "invalid_coordinate" end
		local limit = 2 ^ ( N.COORD_BITS - 1 )
		if value < -limit or value >= limit then return false, "coordinate_out_of_range" end
	end
	return true
end

function SV.AdvanceWorldGeneration( resetRevision )
	SV.WorldGeneration = ( SV.WorldGeneration + 1 ) % 4294967296
	if SV.WorldGeneration == 0 then SV.WorldGeneration = 1 end
	if resetRevision ~= false then SV.BlockRevision = 0 end
	SV.StateNetClients = setmetatable( {}, { __mode = "k" } )
	return SV.WorldGeneration
end

function SV.SendStateHello( ply )
	if not validPlayer( ply ) then return false, "invalid_player" end
	net.Start( "mc_state_hello" )
		net.WriteUInt( N.PROTOCOL_VERSION, 16 )
		net.WriteUInt( ALL_CAPABILITIES, N.CAPABILITY_BITS )
		net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
		net.WriteUInt( SV.BlockRevision, N.REVISION_BITS )
		net.WriteUInt( math.min( N.MAX_STATE_ID, math.max( 0, ( MC.BlockStateCount or 1 ) - 1 ) ), N.STATE_ID_BITS )
		net.WriteString( schemaHash() )
		net.WriteString( blockEntityRegistryHash() )
	net.Send( ply )
	return true
end

function SV.ValidateStateProtocol( version, capabilities, clientSchemaHash, clientBEHash )
	if version ~= N.PROTOCOL_VERSION then return false, "protocol_version_mismatch" end
	if bit.band( capabilities or 0, N.REQUIRED_CAPABILITIES ) ~= N.REQUIRED_CAPABILITIES then
		return false, "required_capability_missing"
	end
	if clientSchemaHash ~= schemaHash() then return false, "schema_hash_mismatch" end
	if clientBEHash ~= blockEntityRegistryHash() then return false, "block_entity_registry_hash_mismatch" end
	return true
end

local function readyTargets( recipients )
	local targets = {}
	if recipients then
		local candidates = istable( recipients ) and recipients or { recipients }
		for _, ply in ipairs( candidates ) do
			if validPlayer( ply ) and compatibleClient( ply ) then targets[#targets + 1] = ply end
		end
	else
		for _, ply in ipairs( player.GetHumans() ) do
			if compatibleClient( ply ) then targets[#targets + 1] = ply end
		end
	end
	return targets
end

local function snapshotTargets( targets, reason )
	local payload, payloadError = SV.BuildStateSnapshotPayload()
	if not payload then return false, payloadError or reason end
	for _, ply in ipairs( targets ) do SV.SendStateSnapshot( ply, payload, SV.BlockRevision ) end
	return true, #targets, reason
end

local function preparedItemBytes( item )
	local bytes = 5 -- localIndex + stateId + Block Entity op
	local envelope = item.envelope
	if envelope.op == BLOCK_ENTITY_UPSERT then
		bytes = bytes + #envelope.type + #envelope.payload + 10
	end
	return bytes
end

-- Large ordered edits are encoded as chunk-local patches. Coordinates are
-- written once per segment and every part stays below the reliable byte budget;
-- this replaces the old full-world snapshot fallback used by /fill.
local function buildStateStreamParts( prepared, cellsPerPart, partByteLimit )
	if #prepared < 1 or #prepared > MAX_STREAM_CELLS then return nil, "state_stream_cell_limit" end
	cellsPerPart = math.Clamp( math.floor( tonumber( cellsPerPart ) or 4096 ), 1, MAX_STREAM_CELLS )
	partByteLimit = math.Clamp( math.floor( tonumber( partByteLimit ) or STREAM_PART_BYTES ), 256, STREAM_PART_BYTES )
	local chunks, order = {}, {}
	for _, item in ipairs( prepared ) do
		local change = item.change
		local cx, cy, cz, li = MC.CellToChunk( change.bx, change.by, change.bz )
		local key = MC.ChunkKey( cx, cy, cz )
		local chunk = chunks[key]
		if not chunk then
			chunk = { cx = cx, cy = cy, cz = cz, items = {} }
			chunks[key] = chunk
			order[#order + 1] = chunk
		end
		item.localIndex = li
		item.streamBytes = preparedItemBytes( item )
		if item.streamBytes + 128 > partByteLimit then return nil, "state_stream_item_too_large" end
		chunk.items[#chunk.items + 1] = item
	end

	local parts = {}
	local part = { segments = {}, cellCount = 0, bytes = 96 }
	local function flushPart()
		if part.cellCount <= 0 then return end
		parts[#parts + 1] = part
		part = { segments = {}, cellCount = 0, bytes = 96 }
	end

	for _, chunk in ipairs( order ) do
		local segment
		for _, item in ipairs( chunk.items ) do
			local segmentBytes = segment and 0 or 12
			if part.cellCount > 0 and ( part.cellCount >= cellsPerPart
			or part.bytes + segmentBytes + item.streamBytes > partByteLimit ) then
				flushPart()
				segment = nil
				segmentBytes = 12
			end
			if not segment then
				segment = { cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, items = {} }
				part.segments[#part.segments + 1] = segment
				part.bytes = part.bytes + segmentBytes
			end
			segment.items[#segment.items + 1] = item
			part.cellCount = part.cellCount + 1
			part.bytes = part.bytes + item.streamBytes
		end
	end
	flushPart()
	if #parts < 1 or #parts > 65535 then return nil, "state_stream_part_limit" end
	return parts
end

local function sendStateStreamPart( target, generation, revision, flags, groupId, partIndex, partCount, totalCells, part, ackBytes )
	if not validPlayer( target ) then return false end
	net.Start( "mc_state_chunk_stream" )
		net.WriteUInt( generation, N.GENERATION_BITS )
		net.WriteUInt( revision, N.REVISION_BITS )
		net.WriteUInt( flags, 8 )
		net.WriteUInt( groupId, 32 )
		net.WriteUInt( partIndex - 1, 16 )
		net.WriteUInt( partCount, 16 )
		net.WriteUInt( totalCells, 32 )
		net.WriteUInt( #part.segments, 16 )
		for _, segment in ipairs( part.segments ) do
			net.WriteInt( segment.cx, N.COORD_BITS )
			net.WriteInt( segment.cy, N.COORD_BITS )
			net.WriteInt( segment.cz, N.COORD_BITS )
			net.WriteUInt( #segment.items, N.COUNT_BITS )
			for _, item in ipairs( segment.items ) do
				net.WriteUInt( item.localIndex, N.LOCAL_BITS )
				net.WriteUInt( math.floor( item.change.stateId ), N.STATE_ID_BITS )
				writeBlockEntityEnvelope( item.envelope )
			end
		end
		net.WriteUInt( ackBytes, 32 )
	net.Send( target )
	return true
end

local function queueStateStream( targets, prepared, revision, options )
	local parts, partError = buildStateStreamParts( prepared, options.cellsPerMessage,
		math.min( STREAM_PART_BYTES, reliableBudgetBytes() ) )
	if not parts then return false, partError end
	local flags = TRANSACTION_FLAG_COALESCED_BULK
	if options.explosionMeshThrottle == true then flags = bit.bor( flags, TRANSACTION_FLAG_MESH_RATE_LIMITED ) end
	local groupId = math.floor( tonumber( options.stateGroupId ) or 0 ) % 4294967296
	local generation = SV.WorldGeneration
	local partCount, totalCells = #parts, #prepared
	for partIndex, streamPart in ipairs( parts ) do
		local queuedIndex, queuedPart = partIndex, streamPart
		local ackBytes = math.max( 1, math.ceil( queuedPart.bytes ) )
		local sendFn = function( ply )
			return sendStateStreamPart( ply, generation, revision, flags, groupId,
				queuedIndex, partCount, totalCells, queuedPart, ackBytes )
		end
		if SV.EnqueueReliableNet then
			SV.EnqueueReliableNet( targets, ackBytes, sendFn, true )
		else
			for _, ply in ipairs( targets ) do sendFn( ply ) end
		end
	end
	return true, #targets, #parts
end

function SV.EndStateBulkGroup( groupId, revision, recipients )
	groupId = math.floor( tonumber( groupId ) or 0 ) % 4294967296
	if groupId == 0 then return false, "invalid_bulk_group" end
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	local generation = SV.WorldGeneration
	local targets = readyTargets( recipients )
	if #targets == 0 then return true, 0 end
	local function sendEnd( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_bulk_group_end" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
		net.Send( ply )
		return true
	end
	if SV.EnqueueReliableNet then SV.EnqueueReliableNet( targets, 32, sendEnd, false )
	else for _, ply in ipairs( targets ) do sendEnd( ply ) end end
	return true, #targets
end

-- Queue one compressed partial-world snapshot. The payload contains the final
-- authoritative state of only the touched chunks, including empty tombstones.
-- Every part uses the same byte-budgeted, ACK-windowed queue as join snapshots
-- and ordered state streams. Large edits no longer have a bypass lane.
function SV.QueueStateChunkHydration( refs, revision, groupId, recipients )
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	groupId = math.floor( tonumber( groupId ) or 0 ) % 4294967296
	if groupId == 0 then return false, "invalid_chunk_patch_group" end
	local targets = readyTargets( recipients )
	if #targets == 0 then return true, 0, 0, 0 end
	if not SV.BuildStateChunkPatchData then return false, "chunk_patch_encoder_unavailable" end

	local data, chunks, buildError = SV.BuildStateChunkPatchData( refs, { forClient = true } )
	if not data then return false, buildError or "chunk_patch_encode_failed" end
	local json = util.TableToJSON( data, false )
	local payload = json and util.Compress( json ) or nil
	if not payload or #payload < 1 then return false, "chunk_patch_compress_failed" end
	if #payload > CHUNK_PATCH_MAX_BYTES then return false, "chunk_patch_too_large" end
	local chunkPatchPartBytes = reliablePayloadBytes( 96, CHUNK_PATCH_PART_BYTES )
	local partCount = math.ceil( #payload / chunkPatchPartBytes )
	if partCount < 1 or partCount > 65535 then return false, "chunk_patch_part_limit" end

	local generation = SV.WorldGeneration
	local token = nextSnapshotToken()
	local totalBytes = #payload
	local chunkCount = #chunks
	local cellCount = math.max( 0, math.floor( tonumber( data.blockCount ) or 0 ) )
	local crc = util.CRC( payload )
	local function sendBegin( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_chunk_patch_begin" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteUInt( totalBytes, 32 )
			net.WriteUInt( partCount, 16 )
			net.WriteUInt( chunkCount, 16 )
			net.WriteUInt( cellCount, 32 )
			net.WriteString( schemaHash() )
			net.WriteString( blockEntityRegistryHash() )
		net.Send( ply )
		return true
	end
	SV.EnqueueReliableNet( targets, 128, sendBegin, false )

	for partIndex = 0, partCount - 1 do
		local queuedIndex = partIndex
		local offset = queuedIndex * chunkPatchPartBytes + 1
		local queuedBytes = string.sub( payload, offset, offset + chunkPatchPartBytes - 1 )
		local ackBytes = #queuedBytes + 96
		SV.EnqueueReliableNet( targets, ackBytes, function( ply )
			if not validPlayer( ply ) then return false end
			net.Start( "mc_state_chunk_patch_part" )
				net.WriteUInt( generation, N.GENERATION_BITS )
				net.WriteUInt( token, 32 )
				net.WriteUInt( queuedIndex, 16 )
				net.WriteUInt( #queuedBytes, 16 )
				net.WriteData( queuedBytes, #queuedBytes )
				net.WriteUInt( ackBytes, 32 )
			net.Send( ply )
			return true
		end, true )
	end

	SV.EnqueueReliableNet( targets, 96, function( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_chunk_patch_end" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteString( crc )
		net.Send( ply )
		return true
	end, false )
	return true, #targets, partCount, totalBytes
end

function SV.BroadcastStateTransaction( changes, revision, options )
	options = istable( options ) and options or {}
	if istable( changes ) and changes.changes then
		revision = changes.revision
		changes = changes.changes
	end
	if not istable( changes ) or #changes == 0 then return true, 0 end
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	local targets = readyTargets( options.recipients )
	if #targets == 0 then return true, 0 end
	local prepared = {}
	local estimatedBytes = 32
	for i, change in ipairs( changes ) do
		local ok, err = validateChange( change )
		if not ok then return false, err, i end
		local envelope, envelopeError = prepareBlockEntityEnvelope( change )
		if not envelope then
			return snapshotTargets( targets, envelopeError )
		end
		prepared[i] = { change = change, envelope = envelope }
		estimatedBytes = estimatedBytes + 12
		if envelope.op == BLOCK_ENTITY_UPSERT then
			estimatedBytes = estimatedBytes + #envelope.type + #envelope.payload + 8
		end
	end
	if options.stateStream == true
	or ( options.netPaced == true and ( #changes > N.MAX_STATE_BULK_CELLS or estimatedBytes > TRANSACTION_PAYLOAD_MAX ) ) then
		local streamed, streamResult, partCount = queueStateStream( targets, prepared, revision, options )
		if streamed then return true, streamResult, "streamed", partCount end
		return snapshotTargets( targets, streamResult or "state_stream_failed" )
	end
	if #changes > N.MAX_STATE_BULK_CELLS or estimatedBytes > TRANSACTION_PAYLOAD_MAX then
		return snapshotTargets( targets, "too_many_changes_for_incremental_packet" )
	end

	if #changes == 1 then
		net.Start( "mc_state_set" )
			writeOrderedHeader( revision )
			net.WriteUInt( options.explosionMeshThrottle == true and TRANSACTION_FLAG_MESH_RATE_LIMITED or 0, 8 )
			writeCell( prepared[1].change )
			writeBlockEntityEnvelope( prepared[1].envelope )
	else
		net.Start( "mc_state_set_bulk" )
			writeOrderedHeader( revision )
			net.WriteUInt( options.explosionMeshThrottle == true and TRANSACTION_FLAG_MESH_RATE_LIMITED or 0, 8 )
			net.WriteUInt( #changes, N.COUNT_BITS )
			for _, item in ipairs( prepared ) do
				writeCell( item.change )
				writeBlockEntityEnvelope( item.envelope )
			end
	end
	net.Send( targets )
	return true, #targets
end

function SV.BroadcastStateChanges( changes, revision, recipients )
	return SV.BroadcastStateTransaction( changes, revision, { recipients = recipients } )
end

function SV.SendStateCorrection( ply, bx, by, bz, stateId, revision )
	if not validPlayer( ply ) then return false, "invalid_player" end
	local change = { bx = bx, by = by, bz = bz, stateId = stateId }
	local ok, err = validateChange( change )
	if not ok then return false, err end
	change.blockEntity = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
	local envelope, envelopeError = prepareBlockEntityEnvelope( change )
	if not envelope then return SV.SendStateSnapshot( ply ) end
	net.Start( "mc_state_set" )
		writeOrderedHeader( math.floor( tonumber( revision ) or SV.BlockRevision ) )
		net.WriteUInt( TRANSACTION_FLAG_CORRECTION, 8 )
		writeCell( change )
		writeBlockEntityEnvelope( envelope )
	net.Send( ply )
	return true
end

function SV.BuildStateSnapshotPayload( slotName )
	if not SV.BuildStateSaveData then return nil, "state_save_codec_unavailable" end
	local data, _, buildError = SV.BuildStateSaveData( slotName or "__network_snapshot", { forClient = true } )
	if not data then return nil, buildError or "snapshot_build_failed" end
	local json = util.TableToJSON( data, false )
	if not json then return nil, "snapshot_json_failed" end
	local compressed = util.Compress( json )
	if not compressed then return nil, "snapshot_compress_failed" end
	return compressed
end

function SV.SendStateSnapshot( ply, payload, baseRevision )
	if not validPlayer( ply ) then return false, "invalid_player" end
	if not compatibleClient( ply ) then return false, "protocol_not_ready" end
	if payload == nil then
		local err
		payload, err = SV.BuildStateSnapshotPayload()
		if not payload then return false, err end
	end
	if not isstring( payload ) then return false, "invalid_snapshot_payload" end
	baseRevision = math.floor( tonumber( baseRevision ) or SV.BlockRevision )
	local snapshotGeneration = SV.WorldGeneration
	local token = nextSnapshotToken()
	local totalBytes = #payload
	local snapshotPartBytes = reliablePayloadBytes( 64, SNAPSHOT_PART_BYTES )
	local partCount = math.ceil( totalBytes / snapshotPartBytes )
	if partCount > 65535 then return false, "snapshot_too_large" end
	if SV.ClearReliableNet then SV.ClearReliableNet( ply ) end

	net.Start( "mc_state_snapshot_begin" )
		net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
		net.WriteUInt( baseRevision, N.REVISION_BITS )
		net.WriteUInt( token, 32 )
		net.WriteUInt( totalBytes, 32 )
		net.WriteUInt( partCount, 16 )
		net.WriteString( schemaHash() )
		net.WriteString( blockEntityRegistryHash() )
	net.Send( ply )

	local function enqueue( bytes, callback, waitAck )
		if SV.EnqueueReliableNet then return SV.EnqueueReliableNet( ply, bytes, callback, waitAck ) end
		return callback( ply )
	end

	for partIndex = 0, partCount - 1 do
		local offset = partIndex * snapshotPartBytes + 1
		local bytes = string.sub( payload, offset, offset + snapshotPartBytes - 1 )
		local queuedIndex, queuedBytes = partIndex, bytes
		local ackBytes = #queuedBytes + 64
		enqueue( ackBytes, function( target )
			net.Start( "mc_state_snapshot_part" )
				net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
				net.WriteUInt( token, 32 )
				net.WriteUInt( queuedIndex, 16 )
				net.WriteUInt( #queuedBytes, 16 )
				net.WriteData( queuedBytes, #queuedBytes )
				net.WriteUInt( ackBytes, 32 )
			net.Send( target )
		end, true )
	end

	enqueue( 128, function( target )
		net.Start( "mc_state_snapshot_end" )
			net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
			net.WriteUInt( baseRevision, N.REVISION_BITS )
			net.WriteUInt( token, 32 )
			net.WriteString( tostring( util.CRC( payload ) ) )
		net.Send( target )
	end )
	local client = SV.StateNetClients[ply]
	if client then client.pendingSnapshotToken = token end
	return true, token, totalBytes, partCount
end

net.Receive( "mc_state_hello_ack", function( _, ply )
	local version = net.ReadUInt( 16 )
	local capabilities = net.ReadUInt( N.CAPABILITY_BITS )
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local clientSchemaHash = net.ReadString()
	local clientBEHash = net.ReadString()
	local ok, err = SV.ValidateStateProtocol( version, capabilities, clientSchemaHash, clientBEHash )
	SV.StateNetClients[ply] = {
		ready = ok and generation == SV.WorldGeneration,
		version = version,
		capabilities = capabilities,
		error = not ok and err or generation ~= SV.WorldGeneration and "generation_mismatch" or nil,
	}
	if SV.StateNetClients[ply].ready then
		SV.SendStateSnapshot( ply )
	else
		SV.SendStateHello( ply )
	end
end )

net.Receive( "mc_state_snapshot_ack", function( _, ply )
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local token = net.ReadUInt( 32 )
	local appliedRevision = net.ReadUInt( N.REVISION_BITS )
	local success = net.ReadBool()
	local client = SV.StateNetClients[ply]
	if not client or generation ~= SV.WorldGeneration or token ~= client.pendingSnapshotToken then return end
	client.pendingSnapshotToken = nil
	client.appliedRevision = success and appliedRevision or nil
end )

net.Receive( "mc_state_resync_request", function( _, ply )
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local revision = net.ReadUInt( N.REVISION_BITS )
	local reason = string.sub( net.ReadString(), 1, 128 )
	local client = SV.StateNetClients[ply]
	if not client or not client.ready then
		SV.SendStateHello( ply )
		return
	end
	client.resyncReason = reason
	client.appliedRevision = revision
	if generation ~= SV.WorldGeneration then
		SV.SendStateHello( ply )
		return
	end
	SV.SendStateSnapshot( ply )
end )

if TRANSPORT_RELOAD and timer and timer.Simple then
	timer.Simple( 0, function()
		SV.AdvanceWorldGeneration( true )
		if not SV.BeginSync then return end
		for _, ply in ipairs( player.GetAll() ) do SV.BeginSync( ply ) end
	end )
end
