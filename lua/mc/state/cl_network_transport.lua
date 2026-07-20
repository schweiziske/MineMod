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
local FLAG_COALESCED_BULK = Net.TransactionFlag and Net.TransactionFlag.COALESCED_BULK or 0x04
local BE_NONE = Net.BlockEntityOp and Net.BlockEntityOp.NONE or 0
local BE_REMOVE = Net.BlockEntityOp and Net.BlockEntityOp.REMOVE or 1
local BE_UPSERT = Net.BlockEntityOp and Net.BlockEntityOp.UPSERT or 2
local SNAPSHOT_PART_MAX = Net.STATE_SNAPSHOT_PART_BYTES or 30000
local STREAM_PART_MAX = Net.STATE_STREAM_PART_BYTES or 30000
local MAX_STREAM_CELLS = Net.MAX_STATE_STREAM_CELLS or 131072
local CHUNK_PATCH_PART_MAX = Net.CHUNK_PATCH_PART_BYTES or 30000
local CHUNK_PATCH_MAX_BYTES = Net.CHUNK_PATCH_MAX_BYTES or 16777216
local BLOCK_ENTITY_PAYLOAD_MAX = Net.BLOCK_ENTITY_PAYLOAD_MAX or 32768
local GAP_GRACE_SECONDS = 0.35

T.generation = T.generation
T.appliedRevision = T.appliedRevision or 0
T.ready = T.ready or false
T.desynced = T.desynced or false
T.pendingTransactions = T.pendingTransactions or {}
T.pendingCorrections = T.pendingCorrections or {}
T.pendingStreams = T.pendingStreams or {}
T.pendingBulkGroupEnds = T.pendingBulkGroupEnds or {}
T.pendingChunkPatches = T.pendingChunkPatches or {}
T.activeBulkGroup = T.activeBulkGroup
T.chunkPatch = T.chunkPatch
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
		capability.REGISTRY_HASH or 0,
		capability.STATE_STREAM or 0,
		capability.CHUNK_HYDRATION or 0
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

local function cancelBulkGroup()
	local group = T.activeBulkGroup
	if group and group.lightingStarted and MC.CancelLightingBulkLoad then MC.CancelLightingBulkLoad() end
	T.activeBulkGroup = nil
	T.pendingBulkGroupEnds = {}
end

local function activeNativeBatchBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if not backend or backend.native ~= true or not backend.ApplyChunkCells then return nil end
	if backend.IsActive and backend.IsActive() ~= true then return nil end
	return backend
end

local function beginBulkGroup( groupId, rateLimited )
	groupId = math.floor( tonumber( groupId ) or 0 )
	local active = T.activeBulkGroup
	if active then
		if active.id ~= groupId then return nil, "overlapping_bulk_group" end
		return active
	end
	local group = {
		id = groupId,
		renderKeys = {},
		physKeys = {},
		lightingStarted = false,
		rateLimited = rateLimited == true,
	}
	if MC.BeginLightingBulkLoad then
		MC.BeginLightingBulkLoad()
		group.lightingStarted = true
	end
	T.activeBulkGroup = group
	return group
end

local function addBulkChunkKey( keys, cx, cy, cz )
	if not MC.ChunkKey then return end
	keys[MC.ChunkKey( cx, cy, cz )] = true
end

local function noteBulkChunk( group, cx, cy, cz )
	if not group then return end
	addBulkChunkKey( group.renderKeys, cx, cy, cz )
	addBulkChunkKey( group.physKeys, cx, cy, cz )
	addBulkChunkKey( group.renderKeys, cx - 1, cy, cz )
	addBulkChunkKey( group.renderKeys, cx + 1, cy, cz )
	addBulkChunkKey( group.renderKeys, cx, cy - 1, cz )
	addBulkChunkKey( group.renderKeys, cx, cy + 1, cz )
	addBulkChunkKey( group.renderKeys, cx, cy, cz - 1 )
	addBulkChunkKey( group.renderKeys, cx, cy, cz + 1 )
	addBulkChunkKey( group.physKeys, cx - 1, cy, cz )
	addBulkChunkKey( group.physKeys, cx + 1, cy, cz )
	addBulkChunkKey( group.physKeys, cx, cy - 1, cz )
	addBulkChunkKey( group.physKeys, cx, cy + 1, cz )
end

local function noteBulkCell( group, bx, by, bz )
	if not group or not MC.CellToChunk then return end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cs2 = cs * cs
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / cs )
	local lx = rem - ly * cs
	addBulkChunkKey( group.renderKeys, cx, cy, cz )
	addBulkChunkKey( group.physKeys, cx, cy, cz )
	if lx == 0 then addBulkChunkKey( group.renderKeys, cx - 1, cy, cz ); addBulkChunkKey( group.physKeys, cx - 1, cy, cz ) end
	if lx == cs - 1 then addBulkChunkKey( group.renderKeys, cx + 1, cy, cz ); addBulkChunkKey( group.physKeys, cx + 1, cy, cz ) end
	if ly == 0 then addBulkChunkKey( group.renderKeys, cx, cy - 1, cz ); addBulkChunkKey( group.physKeys, cx, cy - 1, cz ) end
	if ly == cs - 1 then addBulkChunkKey( group.renderKeys, cx, cy + 1, cz ); addBulkChunkKey( group.physKeys, cx, cy + 1, cz ) end
	if lz == 0 then addBulkChunkKey( group.renderKeys, cx, cy, cz - 1 ) end
	if lz == ch - 1 then addBulkChunkKey( group.renderKeys, cx, cy, cz + 1 ) end
end

local function finalizeBulkGroup( groupId )
	local group = T.activeBulkGroup
	if not group or ( groupId and group.id ~= groupId ) then return false end
	-- BeginLightingBulkLoad clears the global source index. A partial Chunk patch
	-- only re-indexes touched chunks, so force one authoritative whole-world index
	-- rebuild before lighting commits. Native treats this as a cheap worker kick.
	MC.LightSourceIndexReady = false
	if group.lightingStarted and MC.EndLightingBulkLoad then MC.EndLightingBulkLoad() end
	if MC.ClearAllBlockConnectionMaskCaches then MC.ClearAllBlockConnectionMaskCaches() end
	for key in pairs( group.renderKeys ) do
		if MC.MarkChunkDirty then MC.MarkChunkDirty( key ) end
		if MC.MeshDirtyRateLimited then
			MC.MeshDirtyRateLimited[key] = group.rateLimited and true or nil
		end
	end
	for key in pairs( group.physKeys ) do
		if MC.MarkChunkPhysDirtyBulk then MC.MarkChunkPhysDirtyBulk( key ) end
	end
	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
	T.activeBulkGroup = nil
	T.pendingBulkGroupEnds[group.id] = nil
	return true
end

local function finishPendingBulkGroups()
	local group = T.activeBulkGroup
	if not group then
		for groupId, revision in pairs( T.pendingBulkGroupEnds ) do
			if revision <= ( T.appliedRevision or 0 ) then T.pendingBulkGroupEnds[groupId] = nil end
		end
		return
	end
	local revision = T.pendingBulkGroupEnds[group.id]
	if revision and ( T.appliedRevision or 0 ) >= revision then finalizeBulkGroup( group.id ) end
end

local function resetClientWorld()
	cancelBulkGroup()
	T.chunkPatch = nil
	T.pendingChunkPatches = {}
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
	MC.PendingPredictionGroups = {}
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
	cancelBulkGroup()
	T.chunkPatch = nil
	T.pendingChunkPatches = {}
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
	if T.activeBulkGroup then cancelBulkGroup() end
	T.generation = generation
	publishAppliedRevision( revision )
	T.ready = true
	T.desynced = false
	T.resyncRequested = false
	T.pendingTransactions = {}
	T.pendingCorrections = {}
	T.pendingStreams = {}
	T.pendingBulkGroupEnds = {}
	T.pendingChunkPatches = {}
	T.chunkPatch = nil
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
	if MC.MarkFluidGeometryDirtyForStateChange then
		MC.MarkFluidGeometryDirtyForStateChange( cell.bx, cell.by, cell.bz, oldStateId, cell.stateId )
	end
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
	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
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
	local correction = bit.band( transaction.flags or 0, FLAG_CORRECTION ) ~= 0
	local coalesced = bit.band( transaction.flags or 0, FLAG_COALESCED_BULK ) ~= 0
	local bulkGroup, transientBulkGroup
	if coalesced then
		local groupError
		bulkGroup, groupError = beginBulkGroup( transaction.groupId or 0,
			bit.band( transaction.flags or 0, FLAG_MESH_RATE_LIMITED ) ~= 0 )
		if not bulkGroup then return false, groupError end
		transientBulkGroup = ( bulkGroup.id or 0 ) == 0
	end
	if MC.ReconcileStatePredictionCells then
		MC.ReconcileStatePredictionCells( transaction.cells, transaction.revision, correction )
	end

	local written = 0
	local nativeBackend = coalesced and activeNativeBatchBackend() or nil
	local nativeBatches = {}
	local previousNativeBulkLoading = MC.NativeChunkBulkLoading
	if nativeBackend then MC.NativeChunkBulkLoading = true end
	for index, item in ipairs( prepared ) do
		local chunk, _, _, changed, writeError = MC.SetBlockStateRaw(
			item.cell.bx, item.cell.by, item.cell.bz, item.cell.stateId,
			nativeBackend and item.oldStateId or nil )
		if writeError ~= nil then
			MC.NativeChunkBulkLoading = previousNativeBulkLoading
			for rollback = written, 1, -1 do
				local old = prepared[rollback]
				MC.SetBlockStateRaw( old.cell.bx, old.cell.by, old.cell.bz, old.oldStateId )
				setBlockEntityAt( old.cell.bx, old.cell.by, old.cell.bz, old.oldBlockEntity )
			end
			return false, writeError or "state_write_failed:" .. index
		end
		item.changed = changed == true
		item.chunk = chunk
		if item.changed and nativeBackend and chunk and chunk.nativeStateStorage then
			local batch = nativeBatches[chunk.key]
			if not batch then batch = { chunk = chunk, cells = {} }; nativeBatches[chunk.key] = batch end
			local _, _, _, li = MC.CellToChunk( item.cell.bx, item.cell.by, item.cell.bz )
			batch.cells[#batch.cells + 1] = li
			batch.cells[#batch.cells + 1] = item.cell.stateId
		end
		written = index
	end
	MC.NativeChunkBulkLoading = previousNativeBulkLoading
	if nativeBackend then
		for _, batch in pairs( nativeBatches ) do
			if nativeBackend.ApplyChunkCells( batch.chunk, batch.cells, false ) ~= true then
				return false, "native_chunk_batch_failed"
			end
		end
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
	for _, item in ipairs( prepared ) do
		if coalesced then
			local affectsBulk = item.changed
			if not affectsBulk and item.cell.blockEntityOp ~= BE_NONE then
				local oldDefinition = item.oldBlockEntityDefinition
				local newDefinition = item.blockEntityDefinition
				affectsBulk = ( oldDefinition and ( oldDefinition.affectsGeometry or oldDefinition.affectsCollision ) )
					or ( newDefinition and ( newDefinition.affectsGeometry or newDefinition.affectsCollision ) )
			end
			if affectsBulk then noteBulkCell( bulkGroup, item.cell.bx, item.cell.by, item.cell.bz ) end
		elseif item.changed then
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
	end
	if transientBulkGroup then finalizeBulkGroup( bulkGroup.id ) end
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

local function applyChunkPatchNow( patch )
	local group, groupError = beginBulkGroup( patch.groupId or 0, false )
	if not group then return false, groupError or "chunk_patch_group_failed" end
	if not MC.LoadStateChunkPatchData then
		cancelBulkGroup()
		return false, "chunk_patch_loader_unavailable"
	end
	local ok, result = MC.LoadStateChunkPatchData( patch.data )
	if ok ~= true or not istable( result ) then
		cancelBulkGroup()
		return false, result or "chunk_patch_apply_failed"
	end
	local predictionKeys = {}
	for _, chunk in ipairs( result.chunks or {} ) do
		noteBulkChunk( group, chunk.cx, chunk.cy, chunk.cz )
		predictionKeys[chunk.key] = true
	end
	if MC.DiscardPredictionsForChunkKeys then MC.DiscardPredictionsForChunkKeys( predictionKeys ) end
	if not finalizeBulkGroup( group.id ) then
		cancelBulkGroup()
		return false, "chunk_patch_finalize_failed"
	end
	return true
end

local function drainTransactions()
	if T.snapshot or T.awaitingSnapshot or T.desynced then return end
	while true do
		local revision = ( T.appliedRevision or 0 ) + 1
		local transaction = T.pendingTransactions[revision]
		local patch = T.pendingChunkPatches[revision]
		if transaction and patch then T.RequestResync( "duplicate_revision_payload" ) return end
		if not transaction and not patch then break end
		local ok, err
		if patch then
			T.pendingChunkPatches[revision] = nil
			ok, err = applyChunkPatchNow( patch )
		else
			T.pendingTransactions[revision] = nil
			ok, err = applyTransactionNow( transaction )
		end
		if not ok then T.RequestResync( err or ( patch and "chunk_patch_apply_failed" or "transaction_apply_failed" ) ) return end
		publishAppliedRevision( revision )
	end

	local lowest
	for revision in pairs( T.pendingTransactions ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	for revision in pairs( T.pendingChunkPatches ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	if lowest and lowest > T.appliedRevision + 1 then T.gapSince = T.gapSince or SysTime()
	else T.gapSince = nil end
	drainCorrections()
	finishPendingBulkGroups()
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
	for revision in pairs( T.pendingChunkPatches ) do
		if revision <= baseRevision then T.pendingChunkPatches[revision] = nil end
	end
	cancelBulkGroup()
	T.pendingStreams = {}
	T.chunkPatch = nil
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
	for revision in pairs( T.pendingChunkPatches ) do
		if revision <= baseRevision then T.pendingChunkPatches[revision] = nil end
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
	if not T.gapSince or T.snapshot or T.chunkPatch or T.awaitingSnapshot or T.desynced then return false end
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

local function streamCellFromLocal( cx, cy, cz, li, stateId, operation, envelope )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cs2 = cs * cs
	if li < 0 or li >= cs2 * ch then return nil, "invalid_stream_local_index" end
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / cs )
	local lx = rem - ly * cs
	return {
		bx = cx * cs + lx,
		by = cy * cs + ly,
		bz = cz * ch + lz,
		stateId = stateId,
		blockEntityOp = operation,
		blockEntityEnvelope = envelope,
	}
end

function T.AcceptStreamPart( part )
	if not T.ready or T.desynced then return false, "transport_not_ready" end
	if not istable( part ) or part.generation ~= T.generation then return false, "generation_mismatch" end
	local revision = tonumber( part.revision )
	local partIndex = math.floor( tonumber( part.partIndex ) or -1 )
	local partCount = math.floor( tonumber( part.partCount ) or -1 )
	local totalCells = math.floor( tonumber( part.totalCells ) or -1 )
	if not validUInt32( revision ) or partIndex < 0 or partIndex >= partCount
	or partCount < 1 or partCount > 65535 or totalCells < 1 or totalCells > MAX_STREAM_CELLS then
		return false, "invalid_state_stream_header"
	end
	if revision <= ( T.appliedRevision or 0 ) then return true, "stale" end

	local stream = T.pendingStreams[revision]
	if not stream then
		stream = {
			generation = part.generation,
			revision = revision,
			flags = math.floor( tonumber( part.flags ) or 0 ),
			groupId = math.floor( tonumber( part.groupId ) or 0 ),
			partCount = partCount,
			totalCells = totalCells,
			parts = {},
			receivedParts = 0,
			receivedCells = 0,
		}
		T.pendingStreams[revision] = stream
	elseif stream.partCount ~= partCount or stream.totalCells ~= totalCells
	or stream.flags ~= math.floor( tonumber( part.flags ) or 0 )
	or stream.groupId ~= math.floor( tonumber( part.groupId ) or 0 ) then
		return false, "state_stream_identity_mismatch"
	end

	local slot = partIndex + 1
	if stream.parts[slot] then return true, "duplicate" end
	local cells = istable( part.cells ) and part.cells or {}
	if stream.receivedCells + #cells > totalCells then return false, "state_stream_cell_overflow" end
	stream.parts[slot] = cells
	stream.receivedParts = stream.receivedParts + 1
	stream.receivedCells = stream.receivedCells + #cells
	if stream.receivedParts < stream.partCount then return true, "partial" end
	if stream.receivedCells ~= stream.totalCells then return false, "state_stream_incomplete" end

	local combined = {}
	for index = 1, stream.partCount do
		local cellsPart = stream.parts[index]
		if not cellsPart then return false, "state_stream_missing_part" end
		for _, cell in ipairs( cellsPart ) do combined[#combined + 1] = cell end
	end
	T.pendingStreams[revision] = nil
	return T.AcceptTransaction( {
		generation = stream.generation,
		revision = stream.revision,
		flags = stream.flags,
		groupId = stream.groupId,
		cells = combined,
	} )
end

function T.AcceptBulkGroupEnd( generation, revision, groupId )
	if not T.ready or T.desynced then return false, "transport_not_ready" end
	if generation ~= T.generation or not validUInt32( revision ) then return false, "generation_mismatch" end
	groupId = math.floor( tonumber( groupId ) or 0 )
	if groupId <= 0 then return false, "invalid_bulk_group" end
	if not T.activeBulkGroup and revision <= ( T.appliedRevision or 0 ) then return true, "stale" end
	T.pendingBulkGroupEnds[groupId] = revision
	finishPendingBulkGroups()
	return true
end

function T.BeginChunkPatch( metadata )
	if not T.ready or T.desynced or not istable( metadata ) then return false, "transport_not_ready" end
	if metadata.generation ~= T.generation then return false, "generation_mismatch" end
	if tostring( metadata.schemaHash or "" ) ~= localSchemaHash() then return false, "state_registry_mismatch" end
	if tostring( metadata.blockEntityHash or "" ) ~= localBlockEntityHash() then
		return false, "block_entity_registry_mismatch"
	end
	local revision = tonumber( metadata.revision )
	local groupId = math.floor( tonumber( metadata.groupId ) or 0 )
	local token = tonumber( metadata.token )
	local totalBytes = math.floor( tonumber( metadata.totalBytes ) or -1 )
	local partCount = math.floor( tonumber( metadata.partCount ) or -1 )
	local chunkCount = math.floor( tonumber( metadata.chunkCount ) or -1 )
	if not validUInt32( revision ) or revision <= ( T.appliedRevision or 0 )
	or groupId <= 0 or not validUInt32( token )
	or totalBytes < 1 or totalBytes > CHUNK_PATCH_MAX_BYTES
	or partCount < 1 or partCount > 65535 or chunkCount < 1 or chunkCount > 65535 then
		return false, "invalid_chunk_patch_header"
	end
	if T.chunkPatch then return false, "overlapping_chunk_patch" end
	if T.pendingTransactions[revision] or T.pendingChunkPatches[revision] then
		return false, "duplicate_chunk_patch_revision"
	end
	T.chunkPatch = {
		generation = metadata.generation,
		revision = revision,
		groupId = groupId,
		token = token,
		totalBytes = totalBytes,
		partCount = partCount,
		chunkCount = chunkCount,
		cellCount = math.max( 0, math.floor( tonumber( metadata.cellCount ) or 0 ) ),
		parts = {},
		receivedParts = 0,
		receivedBytes = 0,
	}
	T.gapSince = nil
	return true
end

function T.AcceptChunkPatchPart( generation, token, partIndex, data )
	local patch = T.chunkPatch
	if not patch or generation ~= patch.generation or token ~= patch.token then
		return false, "chunk_patch_identity_mismatch"
	end
	partIndex = math.floor( tonumber( partIndex ) or -1 )
	if partIndex < 0 or partIndex >= patch.partCount or not isstring( data )
	or #data < 1 or #data > CHUNK_PATCH_PART_MAX then return false, "invalid_chunk_patch_part" end
	local slot = partIndex + 1
	if patch.parts[slot] then return true, "duplicate" end
	patch.parts[slot] = data
	patch.receivedParts = patch.receivedParts + 1
	patch.receivedBytes = patch.receivedBytes + #data
	if patch.receivedBytes > patch.totalBytes then return false, "chunk_patch_too_large" end
	return true
end

function T.EndChunkPatch( generation, revision, groupId, token, crc )
	local patch = T.chunkPatch
	if not patch or generation ~= patch.generation or revision ~= patch.revision
	or groupId ~= patch.groupId or token ~= patch.token then return false, "chunk_patch_identity_mismatch" end
	if patch.receivedParts ~= patch.partCount or patch.receivedBytes ~= patch.totalBytes then
		return false, "chunk_patch_incomplete"
	end
	local payload = table.concat( patch.parts )
	if tostring( crc or "" ) ~= "" and util.CRC( payload ) ~= tostring( crc ) then
		return false, "chunk_patch_crc_mismatch"
	end
	local json = util.Decompress( payload )
	local data = json and util.JSONToTable( json ) or nil
	if not istable( data ) or data.chunkPatch ~= true or not istable( data.chunks )
	or #data.chunks ~= patch.chunkCount then return false, "chunk_patch_decode_failed" end
	T.chunkPatch = nil
	T.pendingChunkPatches[revision] = {
		generation = generation,
		revision = revision,
		groupId = groupId,
		data = data,
	}
	drainTransactions()
	return not T.desynced
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

	net.Receive( "mc_state_chunk_stream", function()
		local part = {
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			flags = net.ReadUInt( 8 ),
			groupId = net.ReadUInt( 32 ),
			partIndex = net.ReadUInt( 16 ),
			partCount = net.ReadUInt( 16 ),
			totalCells = net.ReadUInt( 32 ),
			cells = {},
		}
		local segmentCount = net.ReadUInt( 16 )
		local decodeError
		if part.partCount < 1 or part.partCount > 65535 or part.partIndex >= part.partCount
		or part.totalCells < 1 or part.totalCells > MAX_STREAM_CELLS then
			T.RequestResync( "invalid_state_stream_header" )
			return
		end
		if segmentCount < 1 or segmentCount > 4096 then
			T.RequestResync( "invalid_state_stream_segments" )
			return
		end
		for _ = 1, segmentCount do
			local cx = net.ReadInt( Net.COORD_BITS or 20 )
			local cy = net.ReadInt( Net.COORD_BITS or 20 )
			local cz = net.ReadInt( Net.COORD_BITS or 20 )
			local count = net.ReadUInt( Net.COUNT_BITS or 14 )
			if count < 1 or #part.cells + count > part.totalCells then
				T.RequestResync( "invalid_state_stream_count" )
				return
			end
			for _ = 1, count do
				local li = net.ReadUInt( Net.LOCAL_BITS or 13 )
				local stateId = net.ReadUInt( Net.STATE_ID_BITS or 20 )
				local operation, envelope, envelopeError = readBlockEntityOperation()
				if envelopeError then decodeError = decodeError or envelopeError end
				local cell, cellError = streamCellFromLocal( cx, cy, cz, li, stateId, operation, envelope )
				if not cell then decodeError = decodeError or cellError
				else part.cells[#part.cells + 1] = cell end
			end
		end
		local ackBytes = math.Clamp( net.ReadUInt( 32 ), 0, STREAM_PART_MAX + 4096 )
		if MC.QueueReliableAck then MC.QueueReliableAck( ackBytes ) end
		if decodeError then T.RequestResync( decodeError ) return end
		local ok, acceptError = T.AcceptStreamPart( part )
		if not ok and not T.resyncRequested then T.RequestResync( acceptError or "state_stream_rejected" ) end
	end )

	net.Receive( "mc_state_bulk_group_end", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local revision = net.ReadUInt( Net.REVISION_BITS or 32 )
		local groupId = net.ReadUInt( 32 )
		local ok, err = T.AcceptBulkGroupEnd( generation, revision, groupId )
		if not ok and not T.resyncRequested then T.RequestResync( err or "bulk_group_end_rejected" ) end
	end )

	net.Receive( "mc_state_chunk_patch_begin", function()
		local metadata = {
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			groupId = net.ReadUInt( 32 ),
			token = net.ReadUInt( 32 ),
			totalBytes = net.ReadUInt( 32 ),
			partCount = net.ReadUInt( 16 ),
			chunkCount = net.ReadUInt( 16 ),
			cellCount = net.ReadUInt( 32 ),
			schemaHash = net.ReadString(),
			blockEntityHash = net.ReadString(),
		}
		local ok, err = T.BeginChunkPatch( metadata )
		if not ok and not T.resyncRequested then T.RequestResync( err or "chunk_patch_begin_rejected" ) end
	end )

	net.Receive( "mc_state_chunk_patch_part", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local token = net.ReadUInt( 32 )
		local partIndex = net.ReadUInt( 16 )
		local length = net.ReadUInt( 16 )
		if length < 1 or length > CHUNK_PATCH_PART_MAX then
			T.RequestResync( "invalid_chunk_patch_part_length" )
			return
		end
		local data = net.ReadData( length )
		if not isstring( data ) or #data ~= length then
			T.RequestResync( "invalid_chunk_patch_part_data" )
			return
		end
		local ackBytes = math.Clamp( net.ReadUInt( 32 ), 0, CHUNK_PATCH_PART_MAX + 4096 )
		if MC.QueueReliableAck then MC.QueueReliableAck( ackBytes ) end
		local ok, err = T.AcceptChunkPatchPart( generation, token, partIndex, data )
		if not ok and not T.resyncRequested then T.RequestResync( err or "chunk_patch_part_rejected" ) end
	end )

	net.Receive( "mc_state_chunk_patch_end", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local revision = net.ReadUInt( Net.REVISION_BITS or 32 )
		local groupId = net.ReadUInt( 32 )
		local token = net.ReadUInt( 32 )
		local crc = net.ReadString()
		local ok, err = T.EndChunkPatch( generation, revision, groupId, token, crc )
		if not ok and not T.resyncRequested then T.RequestResync( err or "chunk_patch_end_rejected" ) end
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
