--[[----------------------------------------------------------------------------
	MC : authoritative server block-state transactions.

	World entry points live in sv_world.lua. This module owns normalization,
	preflight, atomic state/Block Entity commit, lifecycle dispatch and batched
	side effects so the world file does not become another monolith.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Host = SV.BlockTransactionHost
if not Host then error( "MC block transaction host is unavailable" ) end

local function failure( code, index )
	return { ok = false, changed = 0, error = code, index = index }
end

local function legacyProjectionForWrite( stateId, requireExact )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, nil, "invalid_state" end
	local id, orient, exact, err = MC.LegacyFromState( stateId )
	if requireExact and ( exact ~= true or id == nil ) then return nil, nil, err or "state_not_network_projectable" end
	return id or 0, orient or 0, nil, exact == true
end

local function blockEntityAtCell( bx, by, bz )
	return MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
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

local function prepareBlockEntity( info, requested )
	local expected = MC.BlockEntityTypeForState and MC.BlockEntityTypeForState( info.stateId ) or nil
	local oldRecord = info.oldBlockEntity
	if requested == false then
		if expected then return nil, "block_entity_required" end
		return nil
	end
	if istable( requested ) then
		local ok, err = MC.ValidateBlockEntityRecord( info.stateId, requested )
		if ok ~= true then return nil, err or "invalid_block_entity" end
		return copyValue( requested )
	end
	if oldRecord and oldRecord.type == expected then return oldRecord end
	if not expected then return nil end

	local definition = MC.BlockEntityTypes and MC.BlockEntityTypes[expected]
	if not definition then return nil, "unknown_block_entity_type" end
	if not definition.CreateDefault then return nil, "block_entity_required" end
	local created, record = pcall( definition.CreateDefault, info.stateId )
	if not created then return nil, "block_entity_create_default_failed" end
	if record and record.type == nil then record.type = expected end
	if record and record.codecVersion == nil then record.codecVersion = definition.codecVersion end
	local ok, err = MC.ValidateBlockEntityRecord( info.stateId, record )
	if ok ~= true then return nil, err or "invalid_block_entity" end
	return record
end

local function setCellBlockEntity( bx, by, bz, record )
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

local function lifecycleKind( oldStateId, stateId )
	if oldStateId == 0 then return "placed" end
	if stateId == 0 then return "removed" end
	local oldSchema = MC.BlockStateSchemaForState( oldStateId )
	local newSchema = MC.BlockStateSchemaForState( stateId )
	if not oldSchema or not newSchema or oldSchema.name ~= newSchema.name then return "replaced" end
	return "state_changed"
end

local function collisionChanged( info )
	if info.oldStateId == info.stateId then return false end
	local oldShape = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( info.oldStateId, info.bx, info.by, info.bz ) or nil
	local newShape = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( info.stateId, info.bx, info.by, info.bz ) or nil
	local oldHas = oldShape and oldShape.hasCollision == true
		or not oldShape and MC.BlockHasCollision and MC.BlockHasCollision( info.old ) == true or false
	local newHas = newShape and newShape.hasCollision == true
		or not newShape and MC.BlockHasCollision and MC.BlockHasCollision( info.id ) == true or false
	if oldHas ~= newHas then return true end
	if not oldHas then return false end
	if oldShape and newShape then return oldShape ~= newShape end
	-- Unknown colliding shapes stay conservative.
	return true
end

local function callLifecycleHandler( info, actor, revision )
	local context = {
		actor = actor,
		bx = info.bx, by = info.by, bz = info.bz,
		kind = info.kind,
		oldStateId = info.oldStateId,
		newStateId = info.stateId,
		oldBlockId = info.old,
		newBlockId = info.id,
		oldOrient = info.oldOrient,
		newOrient = info.orient,
		revision = revision,
	}
	local oldHandlers = MC.Blocks[info.old] and MC.Blocks[info.old].handlers or nil
	local newHandlers = MC.Blocks[info.id] and MC.Blocks[info.id].handlers or nil

	if info.kind == "placed" then
		if newHandlers and newHandlers.OnPlaced then
			newHandlers.OnPlaced( context, info.stateId )
		elseif info.id ~= 0 then
			Host.callBlockHandler( info.id, "OnPlace", actor, info.bx, info.by, info.bz, info.orient )
		end
	elseif info.kind == "removed" then
		if oldHandlers and oldHandlers.OnRemoved then
			oldHandlers.OnRemoved( context, info.oldStateId )
		elseif info.old ~= 0 then
			Host.callBlockHandler( info.old, "OnBreak", actor, info.bx, info.by, info.bz, info.oldOrient )
		end
	elseif info.kind == "replaced" then
		local replacementHandler = oldHandlers and oldHandlers.OnReplaced or newHandlers and newHandlers.OnReplaced
		if replacementHandler then
			replacementHandler( context, info.oldStateId, info.stateId )
		else
			Host.callBlockHandler( info.old, "OnBreak", actor, info.bx, info.by, info.bz, info.oldOrient )
			Host.callBlockHandler( info.id, "OnPlace", actor, info.bx, info.by, info.bz, info.orient )
		end
	elseif newHandlers and newHandlers.OnStateChanged then
		newHandlers.OnStateChanged( context, info.oldStateId, info.stateId )
	end
end

local function restoreTransactionStates( written, oldChunks )
	for i = #written, 1, -1 do
		local info = written[i]
		MC.SetBlockStateRaw( info.bx, info.by, info.bz, info.oldStateId )
		setCellBlockEntity( info.bx, info.by, info.bz, info.oldBlockEntity )
	end
	for key, oldChunk in pairs( oldChunks or {} ) do
		local chunk = MC.GetChunkByKey( key )
		if chunk and oldChunk and IsValid( oldChunk.ent ) then chunk.ent = oldChunk.ent end
	end
end

-- Every cell is normalized and checked before the first raw write. Duplicate
-- coordinates are last-write-wins unless rejectDuplicateCells is requested.
function SV.ApplyBlockTransaction( cells, options )
	options = Host.normalizeWriteOptions( options )
	if not istable( cells ) or #cells == 0 then
		return { ok = true, changed = 0, revision = SV.BlockRevision or 0, changes = {} }
	end
	if not MC.SetBlockStateRaw or not MC.GetBlockState then return failure( "state_storage_unavailable" ) end
	local byKey, ordered = {}, {}
	for i = 1, #cells do
		local cell = cells[i]
		if not istable( cell ) then return failure( "invalid_change", i ) end
		local bx = math.floor( tonumber( cell.bx ) or 0 )
		local by = math.floor( tonumber( cell.by ) or 0 )
		local bz = math.floor( tonumber( cell.bz ) or 0 )
		local stateId, err
		if cell.stateId ~= nil then
			stateId = math.floor( tonumber( cell.stateId ) or -1 )
		elseif cell.id ~= nil then
			stateId, err = Host.stateFromLegacyWrite( cell.id, cell.orient )
		else
			return failure( "missing_state", i )
		end
		if not stateId then return failure( err or "invalid_state", i ) end
		-- Full stateId is authoritative on the Phase 4 transport. A legacy view is
		-- still derived for existing collision/FX/handler code, but no state is
		-- rejected merely because that view loses properties.
		local id, orient, projectionErr = legacyProjectionForWrite( stateId, false )
		if id == nil then return failure( projectionErr or "state_not_network_projectable", i ) end
		local key = MC.CellKey( bx, by, bz )
		local info = byKey[key]
		if info then
			if options.rejectDuplicateCells then return failure( "duplicate_cell", i ) end
		else
			info = { key = key, bx = bx, by = by, bz = bz }
			byKey[key] = info
			ordered[#ordered + 1] = info
		end
		info.stateId = stateId
		info.id = id
		info.orient = orient
		info.blockEntityRequest = cell.blockEntity
		info.sourceIndex = i
	end

	local finalized, touchedChunkKeys, oldChunks = {}, {}, {}
	local blockDelta = 0
	for _, info in ipairs( ordered ) do
		info.oldStateId = MC.GetBlockState( info.bx, info.by, info.bz )
		if info.oldStateId == nil then return failure( "invalid_old_state", info.sourceIndex ) end
		-- The old state is never transmitted as authoritative state data. Use its
		-- best legacy view for FX/handlers so an imported full state can still be
		-- removed or replaced while the old network protocol is active.
		local oldId, oldOrient, oldProjectionErr = legacyProjectionForWrite( info.oldStateId, false )
		if oldId == nil then return failure( oldProjectionErr or "old_state_not_network_projectable", info.sourceIndex ) end
		info.old, info.oldOrient = oldId, oldOrient
		info.oldBlockEntity = blockEntityAtCell( info.bx, info.by, info.bz )
		info.newBlockEntity, info.blockEntityError = prepareBlockEntity( info, info.blockEntityRequest )
		if info.blockEntityError then return failure( info.blockEntityError, info.sourceIndex ) end
		local blockEntityChanged = info.newBlockEntity ~= info.oldBlockEntity
		info.blockEntityChanged = blockEntityChanged
		if blockEntityChanged and options.network ~= false and info.newBlockEntity and MC.PrepareBlockEntityWireEnvelope then
			local wire, wireError = MC.PrepareBlockEntityWireEnvelope( info.stateId, info.newBlockEntity )
			if not wire and wireError ~= "server_only" then
				return failure( wireError or "block_entity_wire_encode_failed", info.sourceIndex )
			end
			info.blockEntityWire = wire
		end
		local entityType = info.newBlockEntity and info.newBlockEntity.type or info.oldBlockEntity and info.oldBlockEntity.type
		info.blockEntityDefinition = entityType and MC.BlockEntityTypes and MC.BlockEntityTypes[entityType] or nil
		if options.preventPlayerOverlap and info.id ~= 0 and info.stateId ~= info.oldStateId
		and Host.wouldTrapPlayer( info.bx, info.by, info.bz, info.id, info.orient, info.stateId ) then
			return failure( "player_overlap", info.sourceIndex )
		end
		if options.validateChange then
			local ok, validateErr = options.validateChange( info, info.sourceIndex )
			if ok ~= true then return failure( validateErr or "change_rejected", info.sourceIndex ) end
		end

		if info.stateId ~= info.oldStateId or blockEntityChanged then
			info.kind = info.stateId ~= info.oldStateId and lifecycleKind( info.oldStateId, info.stateId ) or "block_entity_changed"
			if info.oldStateId == 0 and info.stateId ~= 0 then blockDelta = blockDelta + 1 end
			if info.oldStateId ~= 0 and info.stateId == 0 then blockDelta = blockDelta - 1 end
			local cx, cy, cz = MC.CellToChunk( info.bx, info.by, info.bz )
			local chunkKey = MC.ChunkKey( cx, cy, cz )
			info.chunkKey = chunkKey
			touchedChunkKeys[chunkKey] = true
			oldChunks[chunkKey] = oldChunks[chunkKey] or MC.GetChunkByKey( chunkKey )
			finalized[#finalized + 1] = info
		end
	end

	if #finalized == 0 then
		return { ok = true, changed = 0, revision = SV.BlockRevision or 0, changes = {} }
	end

	local written, stateTouchedChunkKeys = {}, {}
	for _, info in ipairs( finalized ) do
		if info.stateId ~= info.oldStateId then
			written[#written + 1] = info
			local cx, cy, cz, li = MC.CellToChunk( info.bx, info.by, info.bz )
			local chunk = MC.GetChunk( cx, cy, cz )
			local created = chunk == nil
			if not chunk then chunk = MC.EnsureChunk( cx, cy, cz ) end
			local ok, changed, rawErr = pcall( MC.SetChunkLocalStateRaw, chunk, li, info.stateId )
			if not ok or changed ~= true then
				restoreTransactionStates( written, oldChunks )
				return failure( ok and ( rawErr or "raw_write_failed" ) or "raw_write_error", info.sourceIndex )
			end
			info.chunk, info.created, info.emptied = chunk, created, chunk.count <= 0
			stateTouchedChunkKeys[info.chunkKey] = true
		end
	end

	for _, info in ipairs( finalized ) do setCellBlockEntity( info.bx, info.by, info.bz, info.newBlockEntity ) end
	for key in pairs( stateTouchedChunkKeys ) do
		local chunk = MC.GetChunkByKey( key )
		if chunk then
			MC.FinalizeChunkStateStorage( chunk )
			if chunk.count <= 0 then MC.World[key] = nil end
		end
	end

	SV.BlockCount = math.max( 0, SV.BlockCount + blockDelta )
	local generationRotated = false
	if MC.Net and ( SV.BlockRevision or 0 ) >= MC.Net.MAX_REVISION and SV.AdvanceWorldGeneration then
		SV.AdvanceWorldGeneration( true )
		generationRotated = true
	end
	SV.BlockRevision = ( SV.BlockRevision or 0 ) + 1
	local revision = SV.BlockRevision
	for _, info in ipairs( finalized ) do
		if info.blockEntityChanged and info.newBlockEntity then info.newBlockEntity.revision = revision end
	end
	local actor = options.actor
	local priorityPhys = options.priorityPhys == true
	local dirty, immediateDirty, dirtyBounds = {}, {}, {}
	local networkChanges = {}
	for _, info in ipairs( finalized ) do
		if info.stateId ~= info.oldStateId then
			if SV.ChunkStore and SV.ChunkStore.RecordEdit then
				SV.ChunkStore.RecordEdit( info.bx, info.by, info.bz, info.id, info.orient, info.stateId )
			end
			if options.compareCollision ~= true or collisionChanged( info ) then
				Host.collectCellPhysDirty( dirty, immediateDirty, dirtyBounds, info.bx, info.by, info.bz )
			end
		elseif info.blockEntityDefinition and info.blockEntityDefinition.affectsCollision then
			Host.collectCellPhysDirty( dirty, immediateDirty, dirtyBounds, info.bx, info.by, info.bz )
		end
		networkChanges[#networkChanges + 1] = {
			bx = info.bx, by = info.by, bz = info.bz,
			stateId = info.stateId,
			blockEntityChanged = info.blockEntityChanged,
			oldBlockEntity = info.oldBlockEntity and copyValue( info.oldBlockEntity ) or nil,
			blockEntity = info.blockEntityChanged and info.newBlockEntity and copyValue( info.newBlockEntity ) or nil,
			blockEntityWire = info.blockEntityChanged and info.blockEntityWire or nil,
			removeBlockEntity = info.oldBlockEntity ~= nil and info.newBlockEntity == nil,
		}
	end

	for key in pairs( touchedChunkKeys ) do
		local oldChunk = oldChunks[key]
		local chunk = MC.GetChunkByKey( key )
		if chunk and oldChunk and chunk ~= oldChunk and not IsValid( chunk.ent ) and IsValid( oldChunk.ent ) then
			chunk.ent = oldChunk.ent
		end
		if not chunk or not chunk.count or chunk.count <= 0 then
			SV.PhysDirty[key] = nil
			SV.PhysDirtyPriority[key] = nil
			if SV.PhysDirtyBulk then SV.PhysDirtyBulk[key] = nil end
			local ent = oldChunk and oldChunk.ent
			if IsValid( ent ) then ent:Remove() end
		end
	end
	for key in pairs( dirty ) do
		local chunk = MC.GetChunkByKey( key )
		if chunk and chunk.count and chunk.count > 0 then
			SV.EnsureChunkEnt( chunk )
			if options.deferPhys then SV.MarkPhysDirtyBulk( key )
			else SV.MarkPhysDirty( key, priorityPhys, dirtyBounds[key] ) end
		end
	end
	if options.immediatePhys == true then Host.flushPhysDirtyKeys( immediateDirty ) end

	if generationRotated and SV.BeginSync then
		for _, ply in ipairs( player.GetAll() ) do SV.BeginSync( ply ) end
	elseif options.network ~= false and #networkChanges > 0 then
		local netOptions = {
			explosionMeshThrottle = options.explosionMeshThrottle == true,
			netPaced = options.netPaced == true,
			cellsPerMessage = options.cellsPerMessage,
		}
		if SV.BroadcastStateTransaction then
			local sent, networkError = SV.BroadcastStateTransaction( networkChanges, revision, netOptions )
			if sent == false then
				local message = "[MC] state transaction network publication failed: " .. tostring( networkError ) .. "\n"
				if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
			end
		else
			-- Loader/runtime-test compatibility only. Production loads the Phase 4
			-- transport before transactions become callable.
			local legacyChanges = {}
			for _, change in ipairs( networkChanges ) do
				local id, orient = legacyProjectionForWrite( change.stateId, false )
				legacyChanges[#legacyChanges + 1] = {
					bx = change.bx, by = change.by, bz = change.bz,
					id = id or 0, orient = orient or 0,
				}
			end
			if #legacyChanges == 1 and options.netMode ~= "bulk" then
				local change = legacyChanges[1]
				Host.broadcastSet( change.bx, change.by, change.bz, change.id, change.orient )
			else
				Host.broadcastSetBulk( legacyChanges, netOptions )
			end
		end
	end

	local shouldFx = options.fx
	if shouldFx == nil then shouldFx = IsValid( actor ) end
	local fxIndex = math.max( 1, math.floor( tonumber( options.fxIndex ) or 1 ) )
	local fxInfo = finalized[fxIndex] or finalized[1]
	local fxLimit = options.fxLimit ~= nil and math.max( 0, math.floor( tonumber( options.fxLimit ) or 0 ) ) or nil
	local fxSent = 0
	SV.Dirty = true
	for _, info in ipairs( finalized ) do
		local playFx = shouldFx and ( options.fxAll == true or info == fxInfo )
		if fxLimit ~= nil then playFx = shouldFx and fxSent < fxLimit and info.kind == "removed" end
		if playFx then
			if info.kind == "removed" and info.old ~= 0 then Host.broadcastFx( 2, info.bx, info.by, info.bz, info.old, info.oldOrient, info.oldStateId )
			elseif info.kind == "placed" and info.id ~= 0 then Host.broadcastFx( 1, info.bx, info.by, info.bz, info.id, info.orient, info.stateId ) end
			fxSent = fxSent + 1
		end
		if options.handlers ~= false and info.kind ~= "block_entity_changed" then
			local ok, handlerError = pcall( callLifecycleHandler, info, actor, revision )
			if not ok then
				local message = "[MC] block lifecycle handler failed: " .. tostring( handlerError ) .. "\n"
				if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
			end
		end
	end

	if options.blockUpdates ~= false and SV.EnqueueTransactionNeighbours then
		local ok, updateError = pcall(
			SV.EnqueueTransactionNeighbours,
			finalized,
			revision,
			options.updateDepth
		)
		if not ok then
			local message = "[MC] block update enqueue failed: " .. tostring( updateError ) .. "\n"
			if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		end
	end

	return { ok = true, changed = #finalized, revision = revision, changes = finalized }
end
