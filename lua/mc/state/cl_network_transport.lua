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
local MAX_STREAM_CELLS = Net.MAX_STATE_STREAM_CELLS or 4294967295
local CHUNK_PATCH_PART_MAX = Net.CHUNK_PATCH_PART_BYTES or 30000
local CHUNK_PATCH_MAX_BYTES = Net.CHUNK_PATCH_MAX_BYTES or 16777216
local STREAM_PATCH_MAX_CHUNKS = 64
local STREAM_PATCH_MAX_CELLS = 131072
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
T.streaming = T.streaming or false
T.subscribedColumns = T.subscribedColumns or {}
T.pendingRevisionSkips = T.pendingRevisionSkips or {}
T.pendingPatchAnnouncements = T.pendingPatchAnnouncements or {}
T.resyncRequested = T.resyncRequested or false
MC.AppliedStateRevision = T.appliedRevision
MC.StateWorldGeneration = T.generation

local function publishAppliedRevision( revision )
	T.appliedRevision = revision
	MC.AppliedStateRevision = revision
	MC.StateWorldGeneration = T.generation
	if MC.RunEvent then MC.RunEvent( "MC.StateRevisionApplied", T.generation, revision ) end
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
		capability.CHUNK_HYDRATION or 0,
		capability.BINARY_CHUNK_PATCH or 0,
		capability.BINARY_STATE_SNAPSHOT or 0
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

local function beginBulkGroup( groupId, rateLimited, partialLighting )
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
		partialLighting = partialLighting == true,
	}
	if not group.partialLighting and MC.BeginLightingBulkLoad then
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

local function noteBulkChunk( group, cx, cy, cz, renderOnly )
	if not group then return end
	addBulkChunkKey( group.renderKeys, cx, cy, cz )
	addBulkChunkKey( group.renderKeys, cx - 1, cy, cz )
	addBulkChunkKey( group.renderKeys, cx + 1, cy, cz )
	addBulkChunkKey( group.renderKeys, cx, cy - 1, cz )
	addBulkChunkKey( group.renderKeys, cx, cy + 1, cz )
	addBulkChunkKey( group.renderKeys, cx, cy, cz - 1 )
	addBulkChunkKey( group.renderKeys, cx, cy, cz + 1 )
	if renderOnly == true then return end
	addBulkChunkKey( group.physKeys, cx, cy, cz )
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
	-- Full snapshots/coalesced edit groups retain the legacy global rebuild.
	-- Streaming partial patches update source/light state incrementally in cl_net.
	if not group.partialLighting then MC.LightSourceIndexReady = false end
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
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
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

local function activeNativeCompressedPatchBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if not backend or backend.native ~= true or not backend.SupportsCompressedPatches
	or backend.SupportsCompressedPatches() ~= true then return nil end
	return backend
end

local function activeNativeBinarySectionPatchBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if not backend or backend.native ~= true or not backend.SupportsBinarySectionPatches
	or backend.SupportsBinarySectionPatches() ~= true then return nil end
	return backend
end

local function cancelActiveBinarySnapshot()
	local binary = T.snapshot and T.snapshot.binary
	if not binary or not binary.activeJobId then return end
	local backend = activeNativeBinarySectionPatchBackend() or MC.NativeChunkBackend
	if backend and backend.CancelCompressedPatchDecode then
		backend.CancelCompressedPatchDecode( binary.activeJobId )
	end
	binary.activeJobId = nil
end

local function cancelPendingNativePatches()
	cancelActiveBinarySnapshot()
	local backend = MC.NativeChunkBackend
	for _, patch in pairs( T.pendingChunkPatches or {} ) do
		if patch.nativeJobId and backend and backend.CancelCompressedPatchDecode then
			backend.CancelCompressedPatchDecode( patch.nativeJobId )
		end
	end
end

local function resetClientWorld()
	cancelPendingNativePatches()
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
	MC.MeshLightDirtyRateLimited = {}
	if MC.ResetStreamCleanupState then MC.ResetStreamCleanupState() end
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PhysDirtyBulk = {}
	MC.PhysDirtyBulkOrder = {}
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
	cancelPendingNativePatches()
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
	cancelPendingNativePatches()
	T.streaming = math.floor( tonumber( hello.streamMode ) or 0 ) == 1
	T.subscribedColumns = {}
	T.pendingRevisionSkips = {}
	T.pendingPatchAnnouncements = {}
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
	T.awaitingSnapshot = not T.streaming
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
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
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
		local subscribed = not T.streaming or T.subscribedColumns[MC.ChunkColumnKey(
			math.floor( cell.bx / ( MC.CS or 16 ) ), math.floor( cell.by / ( MC.CS or 16 ) ) )] == true
		if subscribed then prepared[#prepared + 1] = {
			cell = cell,
			oldStateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0,
			oldBlockEntity = cloneValue( blockEntityAt( cell.bx, cell.by, cell.bz ) ),
		} end
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
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local applyStarted = perfEnabled and SysTime() or nil
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.apply" ) end
	local group, groupError = beginBulkGroup( patch.groupId or 0, true, true )
	if not group then
		if perfEnabled then MC.StreamPerformanceSetStage( nil ) end
		return false, groupError or "chunk_patch_group_failed"
	end
	local nativeBackend
	if patch.nativeJobId then
		if patch.nativeBinary then nativeBackend = activeNativeBinarySectionPatchBackend()
		else nativeBackend = activeNativeCompressedPatchBackend() end
	end
	if patch.nativeJobId and ( not nativeBackend or nativeBackend.Epoch() ~= patch.nativeEpoch ) then
		cancelBulkGroup()
		return false, "native_patch_backend_unavailable"
	end
	local ok, result
	if patch.binaryData then
		if not MC.LoadBinaryStateChunkPatchData then
			cancelBulkGroup()
			return false, "binary_patch_loader_unavailable"
		end
		local data = patch.binaryData
		if T.streaming then
			local filtered, filteredBlocks = {}, 0
			for _, chunk in ipairs( data.chunks or {} ) do
				if T.subscribedColumns[MC.ChunkColumnKey( chunk.cx, chunk.cy )] == true then
					filtered[#filtered + 1] = chunk
					filteredBlocks = filteredBlocks + ( chunk.count or 0 )
				end
			end
			data = { chunks = filtered, blocks = filteredBlocks }
		end
		ok, result = MC.LoadBinaryStateChunkPatchData( data )
	elseif nativeBackend then
		local committed
		if patch.nativeBinary then
			committed = nativeBackend.CommitBinarySectionPatch( patch.nativeJobId, patch.nativeInclude )
		else
			committed = nativeBackend.CommitCompressedPatch( patch.nativeJobId, patch.nativePalette, patch.nativeInclude )
		end
		if committed then ok, result = MC.FinalizeNativeStateChunkPatch( committed, patch.nativeEpoch )
		else ok, result = false, "native_patch_commit_failed" end
	else
		if not MC.LoadStateChunkPatchData then
			cancelBulkGroup()
			if perfEnabled then MC.StreamPerformanceSetStage( nil ) end
			return false, "chunk_patch_loader_unavailable"
		end
		local filterStarted = perfEnabled and SysTime() or nil
		if T.streaming and istable( patch.data.chunks ) then
			local filtered, filteredBlocks = {}, 0
			for _, chunk in ipairs( patch.data.chunks ) do
				if istable( chunk ) and T.subscribedColumns[MC.ChunkColumnKey( tonumber( chunk[1] ) or chunk.cx, tonumber( chunk[2] ) or chunk.cy )] then
					filtered[#filtered + 1] = chunk
					local cells = chunk[4]
					if istable( cells ) then filteredBlocks = filteredBlocks + math.floor( #cells / 2 )
					elseif isstring( cells ) then for _ in string.gmatch( cells, "[^;]+" ) do filteredBlocks = filteredBlocks + 1 end end
				end
			end
			patch.data.chunks = filtered
			patch.data.blockCount = filteredBlocks
		end
		if perfEnabled then MC.StreamPerformancePatchStage( patch.revision, "subscription_filter", ( SysTime() - filterStarted ) * 1000 ) end
		local loaderStarted = perfEnabled and SysTime() or nil
		ok, result = MC.LoadStateChunkPatchData( patch.data )
		if perfEnabled then MC.StreamPerformancePatchStage( patch.revision, "loader", ( SysTime() - loaderStarted ) * 1000 ) end
	end
	if ok ~= true or not istable( result ) then
		cancelBulkGroup()
		if perfEnabled then
			MC.StreamPerformancePatchApplied( patch.revision, false, result or "chunk_patch_apply_failed" )
			MC.StreamPerformanceSetStage( nil )
		end
		return false, result or "chunk_patch_apply_failed"
	end
	local publishStarted = perfEnabled and SysTime() or nil
	local predictionKeys = {}
	for _, chunk in ipairs( result.chunks or {} ) do
		noteBulkChunk( group, chunk.cx, chunk.cy, chunk.cz )
		predictionKeys[chunk.key] = true
	end
	if MC.DiscardPredictionsForChunkKeys then MC.DiscardPredictionsForChunkKeys( predictionKeys ) end
	if not finalizeBulkGroup( group.id ) then
		cancelBulkGroup()
		if perfEnabled then
			MC.StreamPerformancePatchApplied( patch.revision, false, "chunk_patch_finalize_failed" )
			MC.StreamPerformanceSetStage( nil )
		end
		return false, "chunk_patch_finalize_failed"
	end
	if perfEnabled then
		MC.StreamPerformancePatchStage( patch.revision, "dirty_publish", ( SysTime() - publishStarted ) * 1000 )
		MC.StreamPerformancePatchStage( patch.revision, "apply_total", ( SysTime() - applyStarted ) * 1000 )
		MC.StreamPerformancePatchApplied( patch.revision, true )
		MC.StreamPerformanceSetStage( nil )
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
		local skipTo = T.pendingRevisionSkips[revision]
		if not transaction and not patch and not skipTo then break end
		if skipTo and ( transaction or patch ) then T.RequestResync( "skip_payload_conflict" ) return end
		if skipTo then
			T.pendingRevisionSkips[revision] = nil
			publishAppliedRevision( skipTo )
			continue
		end
		local ok, err
		if patch then
			if patch.nativeJobId and not patch.nativeReady then break end
			T.pendingChunkPatches[revision] = nil
			ok, err = applyChunkPatchNow( patch )
		else
			T.pendingTransactions[revision] = nil
			ok, err = applyTransactionNow( transaction )
		end
		if not ok then T.RequestResync( err or ( patch and "chunk_patch_apply_failed" or "transaction_apply_failed" ) ) return end
		publishAppliedRevision( revision )
		T.pendingPatchAnnouncements[revision] = nil
	end

	local lowest
	for revision in pairs( T.pendingTransactions ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	for revision in pairs( T.pendingChunkPatches ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	for revision in pairs( T.pendingRevisionSkips ) do
		if revision > T.appliedRevision and ( not lowest or revision < lowest ) then lowest = revision end
	end
	if lowest and lowest > T.appliedRevision + 1 then T.gapSince = T.gapSince or SysTime()
	else T.gapSince = nil end
	drainCorrections()
	finishPendingBulkGroups()
end

-- A verified Workshop package is an external snapshot source. The state hello
-- already fixed generation/schema/revision; this only releases ordered dirty
-- transactions after the package has been committed into MC.World.
function T.AcceptExternalBase( generation, baseRevision )
	baseRevision = tonumber( baseRevision )
	if not T.ready or T.desynced then return false, "transport_not_ready" end
	if generation ~= T.generation then return false, "generation_mismatch" end
	if not validUInt32( baseRevision ) or baseRevision ~= T.appliedRevision then
		return false, "base_revision_mismatch"
	end
	T.snapshot = nil
	T.awaitingSnapshot = false
	T.resyncRequested = false
	drainTransactions()
	return not T.desynced
end

function T.GetAppliedRevision()
	return T.generation, T.appliedRevision, T.awaitingSnapshot == true, T.desynced == true
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

function T.AcceptRevisionSkip( generation, fromRevision, toRevision )
	if not T.ready or generation ~= T.generation then return false, "generation_mismatch" end
	if not validUInt32( fromRevision ) or not validUInt32( toRevision ) or toRevision < fromRevision then return false, "invalid_skip_range" end
	if toRevision <= T.appliedRevision then return true, "stale" end
	if fromRevision <= T.appliedRevision then fromRevision = T.appliedRevision + 1 end
	for revision = fromRevision, toRevision do
		if T.pendingTransactions[revision] or T.pendingChunkPatches[revision] then return false, "skip_payload_conflict" end
	end
	T.pendingRevisionSkips[fromRevision] = toRevision
	drainTransactions()
	return not T.desynced
end

function T.AcceptPatchPending( generation, revision )
	if not T.ready or generation ~= T.generation or not validUInt32( revision ) then return false end
	if revision == T.appliedRevision + 1 then T.pendingPatchAnnouncements[revision] = SysTime() + 30; T.gapSince = nil end
	return true
end

function T.ApplyStreamColumns( generation, minCZ, maxCZ, subscriptions, unsubscriptions )
	if not T.streaming or generation ~= T.generation then return false, "generation_mismatch" end
	local span = maxCZ - minCZ + 1
	if span < 1 or span > ( Net.MAX_STREAM_VERTICAL_CHUNKS or 1024 ) then return false, "invalid_vertical_span" end
	T.streamMinCZ, T.streamMaxCZ = minCZ, maxCZ
	local unload = {}
	for _, column in ipairs( unsubscriptions ) do
		local key = MC.ChunkColumnKey( column.cx, column.cy )
		T.subscribedColumns[key] = nil
		for cz = minCZ, maxCZ do unload[#unload + 1] = { cx = column.cx, cy = column.cy, cz = cz } end
	end
	if #unload > 0 and MC.UnloadClientChunks then MC.UnloadClientChunks( unload ) end
	for _, column in ipairs( subscriptions ) do
		T.subscribedColumns[MC.ChunkColumnKey( column.cx, column.cy )] = true
		local keys = {}
		for cz = minCZ, maxCZ do keys[MC.ChunkKey( column.cx, column.cy, cz )] = true end
		if MC.FlushDetachedChunkCleanupForKeys then MC.FlushDetachedChunkCleanupForKeys( keys ) end
		for key in pairs( keys ) do
			if MC.SetStreamChunkHidden then MC.SetStreamChunkHidden( key, false )
			elseif MC.StreamHiddenChunkKeys then MC.StreamHiddenChunkKeys[key] = nil end
			MC.MarkChunkLoaded( key )
		end
	end
	return true
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
	cancelActiveBinarySnapshot()
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
	MC.SyncProgress = {
		expected = totalBytes,
		received = 0,
		chunks = partCount,
		doneChunks = 0,
		active = true,
		lastUpdate = CurTime(),
		snapshot = true,
		bytes = true,
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
	local progress = MC.SyncProgress
	if progress and progress.bytes == true then
		progress.expected = snapshot.totalBytes
		progress.received = snapshot.receivedBytes
		progress.chunks = snapshot.partCount
		progress.doneChunks = snapshot.receivedParts
		progress.lastUpdate = CurTime()
	end
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

local function finishSnapshotApplication( snapshot )
	T.snapshot = nil
	T.awaitingSnapshot = false
	publishAppliedRevision( snapshot.baseRevision )
	for revision in pairs( T.pendingTransactions ) do
		if revision <= snapshot.baseRevision then T.pendingTransactions[revision] = nil end
	end
	for revision in pairs( T.pendingChunkPatches ) do
		if revision <= snapshot.baseRevision then T.pendingChunkPatches[revision] = nil end
	end
	T.pendingCorrections = {}
	drainTransactions()
	sendSnapshotAck( snapshot, not T.desynced )
	return not T.desynced
end

local function rejectBinarySnapshot( snapshot, reason )
	cancelActiveBinarySnapshot()
	cancelBulkGroup()
	sendSnapshotAck( snapshot, false )
	T.snapshot = nil
	resetClientWorld()
	T.awaitingSnapshot = true
	T.RequestResync( reason or "binary_snapshot_failed" )
	return false, reason or "binary_snapshot_failed"
end

local function validateBinarySnapshotBatchChunks( binary, chunks, expectedCount )
	if not istable( chunks ) or #chunks ~= expectedCount then return nil, "binary_snapshot_batch_chunk_count" end
	local keys = {}
	for index, chunk in ipairs( chunks ) do
		local cx, cy, cz = tonumber( chunk.cx ), tonumber( chunk.cy ), tonumber( chunk.cz )
		if not cx or not cy or not cz or cx ~= math.floor( cx )
		or cy ~= math.floor( cy ) or cz ~= math.floor( cz ) then
			return nil, "invalid_binary_snapshot_chunk:" .. tostring( index )
		end
		local key = MC.ChunkKey( cx, cy, cz )
		if binary.seenChunks[key] or keys[key] then return nil, "duplicate_binary_snapshot_chunk" end
		keys[key] = true
	end
	return keys
end

local function noteBinarySnapshotBatch( snapshot, result, keys )
	local binary = snapshot.binary
	for key in pairs( keys ) do binary.seenChunks[key] = true end
	for _, chunk in ipairs( result.chunks or {} ) do
		noteBulkChunk( binary.bulkGroup, chunk.cx, chunk.cy, chunk.cz, true )
	end
	binary.committedChunks = binary.committedChunks + #( result.chunks or {} )
	binary.committedCells = binary.committedCells + math.floor( tonumber( result.blocks ) or 0 )
	binary.nextBatch = binary.nextBatch + 1
	local progress = MC.SyncProgress
	if progress then
		progress.expected = binary.cellCount
		progress.received = binary.committedCells
		progress.chunks = binary.chunkCount
		progress.doneChunks = binary.committedChunks
		progress.active = true
		progress.lastUpdate = CurTime()
		progress.bytes = false
	end
end

local function finishBinarySnapshot( snapshot )
	local binary = snapshot.binary
	if binary.committedChunks ~= binary.chunkCount or binary.committedCells ~= binary.cellCount then
		return rejectBinarySnapshot( snapshot, "binary_snapshot_commit_count_mismatch" )
	end
	if not finalizeBulkGroup( binary.bulkGroup.id ) then
		return rejectBinarySnapshot( snapshot, "binary_snapshot_finalize_failed" )
	end
	if MC.SyncProgress then
		MC.SyncProgress.expected = binary.cellCount
		MC.SyncProgress.received = binary.cellCount
		MC.SyncProgress.chunks = binary.chunkCount
		MC.SyncProgress.doneChunks = binary.chunkCount
		MC.SyncProgress.active = false
		MC.SyncProgress.lastUpdate = CurTime()
		MC.SyncProgress.bytes = false
	end
	if MC.RefreshClientCollisionInterest then MC.RefreshClientCollisionInterest( true ) end
	return finishSnapshotApplication( snapshot )
end

function T.PollBinarySnapshot()
	local snapshot = T.snapshot
	local binary = snapshot and snapshot.binary
	if not binary or T.desynced then return false end
	if binary.nextBatch > #binary.batches then return finishBinarySnapshot( snapshot ) end

	local batch = binary.batches[binary.nextBatch]
	local nativeBackend = activeNativeBinarySectionPatchBackend()
	if binary.activeJobId and not nativeBackend then
		return rejectBinarySnapshot( snapshot, "native_binary_snapshot_backend_unavailable" )
	end
	if nativeBackend then
		if not binary.activeJobId then
			local jobId, epoch = nativeBackend.StartBinarySectionPatchDecode(
				batch.payload, batch.compression, batch.rawBytes,
				snapshot.generation, snapshot.baseRevision, batch.chunkCount, batch.cellCount )
			if not jobId then return rejectBinarySnapshot( snapshot, "native_binary_snapshot_submit_failed" ) end
			binary.activeJobId, binary.activeEpoch = jobId, epoch
			return true
		end
		local status = nativeBackend.PollBinarySectionPatchDecode( binary.activeJobId )
		if not status then return rejectBinarySnapshot( snapshot, "native_binary_snapshot_poll_failed" ) end
		if status.status == "failed" or status.status == "cancelled" then
			return rejectBinarySnapshot( snapshot, status.error or "native_binary_snapshot_decode_failed" )
		end
		if status.status ~= "ready" then return false end
		if status.generation ~= snapshot.generation or status.revision ~= snapshot.baseRevision
		or status.backendEpoch ~= binary.activeEpoch then
			return rejectBinarySnapshot( snapshot, "native_binary_snapshot_stale" )
		end
		local keys, keyError = validateBinarySnapshotBatchChunks( binary, status.chunks, batch.chunkCount )
		if not keys then return rejectBinarySnapshot( snapshot, keyError ) end
		local include = {}
		for index = 1, batch.chunkCount do include[index] = index end
		local committed = nativeBackend.CommitBinarySectionPatch( binary.activeJobId, include )
		binary.activeJobId = nil
		if not committed then return rejectBinarySnapshot( snapshot, "native_binary_snapshot_commit_failed" ) end
		local ok, result = MC.FinalizeNativeStateChunkPatch( committed, binary.activeEpoch, { fullSnapshot = true } )
		if ok ~= true or not istable( result ) then
			return rejectBinarySnapshot( snapshot, result or "native_binary_snapshot_finalize_failed" )
		end
		noteBinarySnapshotBatch( snapshot, result, keys )
		return true
	end

	local decoded, decodeError = MC.BinarySectionPatch.DecodeTransportPayload(
		batch.payload, batch.compression, batch.rawBytes, {
			chunkCount = batch.chunkCount,
			cellCount = batch.cellCount,
			revision = snapshot.baseRevision,
		} )
	if not decoded then return rejectBinarySnapshot( snapshot, decodeError or "binary_snapshot_decode_failed" ) end
	local keys, keyError = validateBinarySnapshotBatchChunks( binary, decoded.chunks, batch.chunkCount )
	if not keys then return rejectBinarySnapshot( snapshot, keyError ) end
	local ok, result = MC.LoadBinaryStateChunkPatchData( decoded, { fullSnapshot = true } )
	if ok ~= true or not istable( result ) then
		return rejectBinarySnapshot( snapshot, result or "binary_snapshot_load_failed" )
	end
	noteBinarySnapshotBatch( snapshot, result, keys )
	return true
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
	-- Drop reliable-part strings before decompression/container expansion. The
	-- assembled payload remains alive locally, avoiding a third full-size copy.
	snapshot.parts = nil
	if MC.BinarySectionPatch and MC.BinarySectionPatch.IsSnapshotPayload
	and MC.BinarySectionPatch.IsSnapshotPayload( compressed ) then
		local decoded, decodeError = MC.BinarySectionPatch.DecodeSnapshotPayload( compressed )
		if not decoded then return rejectBinarySnapshot( snapshot, decodeError or "binary_snapshot_decode_failed" ) end
		local bulkGroup, groupError = beginBulkGroup( snapshot.token, true, false )
		if not bulkGroup then return rejectBinarySnapshot( snapshot, groupError or "binary_snapshot_group_failed" ) end
		if MC.ResetClientWorldForStateSync then
			MC.ResetClientWorldForStateSync( decoded.chunkCount, decoded.cellCount )
		else
			resetClientWorld()
		end
		snapshot.binary = {
			batches = decoded.batches,
			chunkCount = decoded.chunkCount,
			cellCount = decoded.cellCount,
			nextBatch = 1,
			committedChunks = 0,
			committedCells = 0,
			seenChunks = {},
			bulkGroup = bulkGroup,
		}
		MC.SyncProgress = {
			expected = decoded.cellCount,
			received = 0,
			chunks = decoded.chunkCount,
			doneChunks = 0,
			active = true,
			lastUpdate = CurTime(),
			snapshot = true,
			bytes = false,
		}
		return T.PollBinarySnapshot()
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

	return finishSnapshotApplication( snapshot )
end

function T.CheckRevisionGap( now )
	if not T.gapSince or T.snapshot or T.chunkPatch or T.awaitingSnapshot or T.desynced then return false end
	now = tonumber( now ) or SysTime()
	local announcedDeadline = T.pendingPatchAnnouncements[T.appliedRevision + 1]
	if announcedDeadline and now <= announcedDeadline then return false end
	if announcedDeadline and now > announcedDeadline then T.pendingPatchAnnouncements[T.appliedRevision + 1] = nil end
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
	local cellCount = math.floor( tonumber( metadata.cellCount ) or -1 )
	local binary = metadata.binary == true
	local rawBytes = binary and math.floor( tonumber( metadata.rawBytes ) or -1 ) or nil
	local compression = binary and math.floor( tonumber( metadata.compression ) or -1 ) or nil
	if not validUInt32( revision ) or revision <= ( T.appliedRevision or 0 )
	or groupId <= 0 or not validUInt32( token )
	or totalBytes < 1 or totalBytes > CHUNK_PATCH_MAX_BYTES
	or partCount < 1 or partCount > 65535 or chunkCount < 1 or chunkCount > STREAM_PATCH_MAX_CHUNKS
	or cellCount < 0 or cellCount > STREAM_PATCH_MAX_CELLS then
		return false, "invalid_chunk_patch_header"
	end
	if binary and ( not MC.BinarySectionPatch
	or rawBytes < 1 or rawBytes > ( MC.BinarySectionPatch.MAX_RAW_BYTES or CHUNK_PATCH_MAX_BYTES )
	or compression < ( MC.BinarySectionPatch.COMPRESSION_NONE or 0 )
	or compression > ( MC.BinarySectionPatch.COMPRESSION_LZMA or 1 ) ) then
		return false, "invalid_binary_patch_header"
	end
	if T.chunkPatch then return false, "overlapping_chunk_patch" end
	if T.pendingTransactions[revision] or T.pendingChunkPatches[revision] then
		return false, "duplicate_chunk_patch_revision"
	end
	T.pendingPatchAnnouncements[revision] = nil
	T.chunkPatch = {
		generation = metadata.generation,
		revision = revision,
		groupId = groupId,
		token = token,
		totalBytes = totalBytes,
		partCount = partCount,
		chunkCount = chunkCount,
		cellCount = cellCount,
		binary = binary,
		rawBytes = rawBytes,
		compression = compression,
		parts = {},
		receivedParts = 0,
		receivedBytes = 0,
	}
	if MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled() and MC.StreamPerformancePatchBegin then
		MC.StreamPerformancePatchBegin( T.chunkPatch )
	end
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
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local debugEnabled = MC.StreamProfileDebug and MC.StreamProfileDebug:GetBool()
	local profileEnabled = perfEnabled or debugEnabled
	local totalStarted = profileEnabled and SysTime() or nil
	local patch = T.chunkPatch
	if not patch or generation ~= patch.generation or revision ~= patch.revision
	or groupId ~= patch.groupId or token ~= patch.token then return false, "chunk_patch_identity_mismatch" end
	if patch.binary then return false, "chunk_patch_encoding_mismatch" end
	if patch.receivedParts ~= patch.partCount or patch.receivedBytes ~= patch.totalBytes then
		return false, "chunk_patch_incomplete"
	end
	local function profileFailure( reason )
		if perfEnabled then
			MC.StreamPerformancePatchFailure( revision, reason )
			MC.StreamPerformanceSetStage( nil )
		end
		return false, reason
	end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.concat" ) end
	local started = perfEnabled and SysTime() or nil
	local payload = table.concat( patch.parts )
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "concat", ( SysTime() - started ) * 1000 ) end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.crc" ) end
	started = perfEnabled and SysTime() or nil
	if tostring( crc or "" ) ~= "" and util.CRC( payload ) ~= tostring( crc ) then
		if perfEnabled then MC.StreamPerformancePatchStage( revision, "crc", ( SysTime() - started ) * 1000 ) end
		return profileFailure( "chunk_patch_crc_mismatch" )
	end
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "crc", ( SysTime() - started ) * 1000 ) end
	local nativeBackend = activeNativeCompressedPatchBackend()
	if nativeBackend then
		started = perfEnabled and SysTime() or nil
		local jobId, epoch = nativeBackend.StartCompressedPatchDecode(
			payload, generation, revision, patch.chunkCount, patch.cellCount )
		if not jobId then return profileFailure( "native_patch_submit_failed" ) end
		T.pendingPatchAnnouncements[revision] = nil
		T.chunkPatch = nil
		T.pendingChunkPatches[revision] = {
			generation = generation,
			revision = revision,
			groupId = groupId,
			nativeJobId = jobId,
			nativeEpoch = epoch,
		}
		local elapsed = profileEnabled and ( SysTime() - totalStarted ) * 1000 or 0
		if perfEnabled then
			MC.StreamPerformancePatchStage( revision, "native_submit", ( SysTime() - started ) * 1000 )
			MC.StreamPerformancePatchStage( revision, "end_callback_before_drain", elapsed )
		end
		if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( nil ) end
		return true
	end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.decompress" ) end
	started = perfEnabled and SysTime() or nil
	local json = util.Decompress( payload )
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "decompress", ( SysTime() - started ) * 1000 ) end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.json" ) end
	started = perfEnabled and SysTime() or nil
	local data = json and util.JSONToTable( json ) or nil
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "json", ( SysTime() - started ) * 1000 ) end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.decode_validate" ) end
	started = perfEnabled and SysTime() or nil
	if not istable( data ) or data.chunkPatch ~= true or not istable( data.chunks )
	or #data.chunks ~= patch.chunkCount
	or math.floor( tonumber( data.blockCount ) or -1 ) ~= patch.cellCount then
		return profileFailure( "chunk_patch_decode_failed" )
	end
	local seen, counted = {}, 0
	for _, chunk in ipairs( data.chunks ) do
		if not istable( chunk ) then return profileFailure( "invalid_chunk_patch_record" ) end
		local cx, cy, cz = tonumber( chunk[1] ), tonumber( chunk[2] ), tonumber( chunk[3] )
		if not cx or not cy or not cz or cx ~= math.floor( cx ) or cy ~= math.floor( cy ) or cz ~= math.floor( cz ) then
			return profileFailure( "invalid_chunk_patch_coords" )
		end
		if T.streaming and ( cz < ( T.streamMinCZ or cz ) or cz > ( T.streamMaxCZ or cz ) ) then
			return profileFailure( "chunk_patch_vertical_bounds" )
		end
		local key = MC.ChunkKey( cx, cy, cz )
		if seen[key] then return profileFailure( "duplicate_chunk_patch_coords" ) end
		seen[key] = true
		local cells = chunk[4]
		if istable( cells ) then counted = counted + math.floor( #cells / 2 )
		elseif isstring( cells ) then for _ in string.gmatch( cells, "[^;]+" ) do counted = counted + 1 end
		else return profileFailure( "invalid_chunk_patch_cells" ) end
	end
	if counted ~= patch.cellCount then return profileFailure( "chunk_patch_cell_count_mismatch" ) end
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "decode_validate", ( SysTime() - started ) * 1000 ) end
	T.pendingPatchAnnouncements[revision] = nil
	T.chunkPatch = nil
	T.pendingChunkPatches[revision] = {
		generation = generation,
		revision = revision,
		groupId = groupId,
		data = data,
	}
	local elapsed = profileEnabled and ( SysTime() - totalStarted ) * 1000 or 0
	if profileEnabled then
		MC.StreamProfile = MC.StreamProfile or { patch = {}, unload = {} }
		MC.StreamProfile.patch = { decodeMS = elapsed, chunks = patch.chunkCount, cells = patch.cellCount, bytes = patch.totalBytes }
	end
	if perfEnabled then
		MC.StreamPerformancePatchStage( revision, "end_callback_before_drain", elapsed )
		MC.StreamPerformancePatchDecoded( revision )
	end
	if debugEnabled and elapsed >= 25 then
		print( string.format( "[MC stream] patch decode %.2fms chunks=%d cells=%d bytes=%d", elapsed, patch.chunkCount, patch.cellCount, patch.totalBytes ) )
	end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "revision.drain" ) end
	started = perfEnabled and SysTime() or nil
	drainTransactions()
	if perfEnabled then
		MC.StreamPerformanceAddStage( "revision.drain", ( SysTime() - started ) * 1000 )
		MC.StreamPerformanceAddStage( "patch.end_callback_total", ( SysTime() - totalStarted ) * 1000 )
		MC.StreamPerformanceSetStage( nil )
	end
	return not T.desynced
end

function T.EndBinaryChunkPatch( generation, revision, groupId, token, crc )
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local totalStarted = perfEnabled and SysTime() or nil
	local patch = T.chunkPatch
	if not patch or patch.binary ~= true or generation ~= patch.generation or revision ~= patch.revision
	or groupId ~= patch.groupId or token ~= patch.token then return false, "binary_patch_identity_mismatch" end
	if patch.receivedParts ~= patch.partCount or patch.receivedBytes ~= patch.totalBytes then
		return false, "binary_patch_incomplete"
	end
	local function fail( reason )
		if perfEnabled then
			MC.StreamPerformancePatchFailure( revision, reason )
			MC.StreamPerformanceSetStage( nil )
		end
		return false, reason
	end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.concat" ) end
	local started = perfEnabled and SysTime() or nil
	local payload = table.concat( patch.parts )
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "concat", ( SysTime() - started ) * 1000 ) end
	if tostring( crc or "" ) ~= "" and util.CRC( payload ) ~= tostring( crc ) then
		return fail( "binary_patch_crc_mismatch" )
	end
	if not MC.BinarySectionPatch or not MC.BinarySectionPatch.DecodeTransportPayload then
		return fail( "binary_patch_decoder_unavailable" )
	end
	local nativeBackend = activeNativeBinarySectionPatchBackend()
	if nativeBackend then
		started = perfEnabled and SysTime() or nil
		local jobId, epoch = nativeBackend.StartBinarySectionPatchDecode(
			payload, patch.compression, patch.rawBytes,
			generation, revision, patch.chunkCount, patch.cellCount )
		if not jobId then return fail( "native_binary_patch_submit_failed" ) end
		T.pendingPatchAnnouncements[revision] = nil
		T.chunkPatch = nil
		T.pendingChunkPatches[revision] = {
			generation = generation,
			revision = revision,
			groupId = groupId,
			nativeJobId = jobId,
			nativeEpoch = epoch,
			nativeBinary = true,
		}
		if perfEnabled then
			MC.StreamPerformancePatchStage( revision, "native_binary_submit", ( SysTime() - started ) * 1000 )
			MC.StreamPerformancePatchStage( revision, "end_callback_before_drain", ( SysTime() - totalStarted ) * 1000 )
			MC.StreamPerformanceSetStage( nil )
		end
		return true
	end
	if perfEnabled and MC.StreamPerformanceSetStage then MC.StreamPerformanceSetStage( "patch.binary_decode" ) end
	started = perfEnabled and SysTime() or nil
	local decoded, decodeError = MC.BinarySectionPatch.DecodeTransportPayload(
		payload, patch.compression, patch.rawBytes, {
			chunkCount = patch.chunkCount,
			cellCount = patch.cellCount,
			revision = revision,
		} )
	if perfEnabled then MC.StreamPerformancePatchStage( revision, "binary_decode", ( SysTime() - started ) * 1000 ) end
	if not decoded then return fail( decodeError or "binary_patch_decode_failed" ) end
	for _, chunk in ipairs( decoded.chunks ) do
		if T.streaming and ( chunk.cz < ( T.streamMinCZ or chunk.cz )
		or chunk.cz > ( T.streamMaxCZ or chunk.cz ) ) then return fail( "binary_patch_vertical_bounds" ) end
	end
	T.pendingPatchAnnouncements[revision] = nil
	T.chunkPatch = nil
	T.pendingChunkPatches[revision] = {
		generation = generation,
		revision = revision,
		groupId = groupId,
		binaryData = decoded,
	}
	if perfEnabled then
		MC.StreamPerformancePatchDecoded( revision )
		MC.StreamPerformancePatchStage( revision, "end_callback_before_drain", ( SysTime() - totalStarted ) * 1000 )
		MC.StreamPerformanceSetStage( "revision.drain" )
	end
	started = perfEnabled and SysTime() or nil
	drainTransactions()
	if perfEnabled then
		MC.StreamPerformanceAddStage( "revision.drain", ( SysTime() - started ) * 1000 )
		MC.StreamPerformanceAddStage( "patch.end_callback_total", ( SysTime() - totalStarted ) * 1000 )
		MC.StreamPerformanceSetStage( nil )
	end
	return not T.desynced
end

function T.PollNativeChunkPatches()
	if T.desynced then return false end
	local hasNativeJobs = false
	for _, patch in pairs( T.pendingChunkPatches ) do
		if patch.nativeJobId then hasNativeJobs = true break end
	end
	if not hasNativeJobs then return false end
	local progressed = false
	for revision, patch in pairs( T.pendingChunkPatches ) do
		if patch.nativeJobId and not patch.nativeReady then
			local patchBackend
			if patch.nativeBinary then patchBackend = activeNativeBinarySectionPatchBackend()
			else patchBackend = activeNativeCompressedPatchBackend() end
			if not patchBackend then T.RequestResync( "native_patch_backend_unavailable" ) return false end
			local status
			if patch.nativeBinary then status = patchBackend.PollBinarySectionPatchDecode( patch.nativeJobId )
			else status = patchBackend.PollCompressedPatchDecode( patch.nativeJobId ) end
			if not status then T.RequestResync( "native_patch_poll_failed" ) return false end
			if status.status == "failed" or status.status == "cancelled" then
				T.RequestResync( status.error or "native_patch_decode_failed" )
				return false
			elseif status.status == "ready" then
				if status.generation ~= T.generation or status.revision ~= revision
				or status.backendEpoch ~= patch.nativeEpoch then
					patchBackend.CancelCompressedPatchDecode( patch.nativeJobId )
					T.RequestResync( "native_patch_stale" )
					return false
				end
				local palette = {}
				if not patch.nativeBinary then
					for index, spec in ipairs( status.palette or {} ) do
						local stateId = isstring( spec ) and MC.ParseBlockState and MC.ParseBlockState( spec ) or nil
						if not stateId or stateId == 0 then
							patchBackend.CancelCompressedPatchDecode( patch.nativeJobId )
							T.RequestResync( "native_patch_palette_failed:" .. tostring( index ) )
							return false
						end
						palette[index] = stateId
					end
				end
				local include = {}
				for index, chunk in ipairs( status.chunks or {} ) do
					local subscribed = not T.streaming or T.subscribedColumns[MC.ChunkColumnKey( chunk.cx, chunk.cy )] == true
					local vertical = not T.streaming or ( chunk.cz >= ( T.streamMinCZ or chunk.cz ) and chunk.cz <= ( T.streamMaxCZ or chunk.cz ) )
					if subscribed and vertical then include[#include + 1] = index end
				end
				patch.nativePalette, patch.nativeInclude, patch.nativeReady = palette, include, true
				if MC.StreamPerformancePatchDecoded then MC.StreamPerformancePatchDecoded( revision ) end
				progressed = true
			end
		end
	end
	if progressed then drainTransactions() end
	return progressed
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
			streamMode = net.ReadUInt( 2 ),
		}
		local accepted, err = T.AcceptHello( hello )
		sendHelloAck( accepted )
		if not accepted then T.RequestResync( err or "hello_rejected" ) end
	end )

	net.Receive( "mc_stream_patch_pending", function()
		T.AcceptPatchPending( net.ReadUInt( Net.GENERATION_BITS or 32 ), net.ReadUInt( Net.REVISION_BITS or 32 ) )
	end )

	net.Receive( "mc_state_revision_skip", function()
		local ok, err = T.AcceptRevisionSkip( net.ReadUInt( Net.GENERATION_BITS or 32 ), net.ReadUInt( Net.REVISION_BITS or 32 ), net.ReadUInt( Net.REVISION_BITS or 32 ) )
		if not ok and not T.resyncRequested then T.RequestResync( err or "revision_skip_rejected" ) end
	end )

	net.Receive( "mc_stream_columns", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local minCZ, maxCZ = net.ReadInt( Net.COORD_BITS or 20 ), net.ReadInt( Net.COORD_BITS or 20 )
		local subscriptions, unsubscriptions = {}, {}
		local count = net.ReadUInt( 7 )
		if count > ( Net.MAX_STREAM_COLUMNS or 64 ) then T.RequestResync( "invalid_stream_column_count" ) return end
		for i = 1, count do subscriptions[i] = { cx = net.ReadInt( Net.COORD_BITS or 20 ), cy = net.ReadInt( Net.COORD_BITS or 20 ) } end
		count = net.ReadUInt( 7 )
		if count > ( Net.MAX_STREAM_COLUMNS or 64 ) then T.RequestResync( "invalid_stream_column_count" ) return end
		for i = 1, count do unsubscriptions[i] = { cx = net.ReadInt( Net.COORD_BITS or 20 ), cy = net.ReadInt( Net.COORD_BITS or 20 ) } end
		local ok, err = T.ApplyStreamColumns( generation, minCZ, maxCZ, subscriptions, unsubscriptions )
		if not ok and not T.resyncRequested then T.RequestResync( err or "stream_columns_rejected" ) end
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

	net.Receive( "mc_state_binary_patch_begin", function()
		local metadata = {
			binary = true,
			generation = net.ReadUInt( Net.GENERATION_BITS or 32 ),
			revision = net.ReadUInt( Net.REVISION_BITS or 32 ),
			groupId = net.ReadUInt( 32 ),
			token = net.ReadUInt( 32 ),
			totalBytes = net.ReadUInt( 32 ),
			rawBytes = net.ReadUInt( 32 ),
			compression = net.ReadUInt( 2 ),
			partCount = net.ReadUInt( 16 ),
			chunkCount = net.ReadUInt( 16 ),
			cellCount = net.ReadUInt( 32 ),
			schemaHash = net.ReadString(),
			blockEntityHash = net.ReadString(),
		}
		local ok, err = T.BeginChunkPatch( metadata )
		if not ok and not T.resyncRequested then T.RequestResync( err or "binary_patch_begin_rejected" ) end
	end )

	net.Receive( "mc_state_binary_patch_part", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local token = net.ReadUInt( 32 )
		local partIndex = net.ReadUInt( 16 )
		local length = net.ReadUInt( 16 )
		if length < 1 or length > CHUNK_PATCH_PART_MAX then
			T.RequestResync( "invalid_binary_patch_part_length" )
			return
		end
		local data = net.ReadData( length )
		if not isstring( data ) or #data ~= length then
			T.RequestResync( "invalid_binary_patch_part_data" )
			return
		end
		local ackBytes = math.Clamp( net.ReadUInt( 32 ), 0, CHUNK_PATCH_PART_MAX + 4096 )
		if MC.QueueReliableAck then MC.QueueReliableAck( ackBytes ) end
		local ok, err = T.AcceptChunkPatchPart( generation, token, partIndex, data )
		if not ok and not T.resyncRequested then T.RequestResync( err or "binary_patch_part_rejected" ) end
	end )

	net.Receive( "mc_state_binary_patch_end", function()
		local generation = net.ReadUInt( Net.GENERATION_BITS or 32 )
		local revision = net.ReadUInt( Net.REVISION_BITS or 32 )
		local groupId = net.ReadUInt( 32 )
		local token = net.ReadUInt( 32 )
		local crc = net.ReadString()
		local ok, err = T.EndBinaryChunkPatch( generation, revision, groupId, token, crc )
		if not ok and not T.resyncRequested then T.RequestResync( err or "binary_patch_end_rejected" ) end
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
		local ackBytes = math.Clamp( net.ReadUInt( 32 ), 0, SNAPSHOT_PART_MAX + 4096 )
		if MC.QueueReliableAck then MC.QueueReliableAck( ackBytes ) end
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
	timer.Create( "mc_state_native_patch_poll", 0.01, 0, function()
		T.PollBinarySnapshot()
		T.PollNativeChunkPatches()
	end )
end
