--[[----------------------------------------------------------------------------
	MC : client net receivers (server is authoritative; we only mirror + redraw)
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net
MC.SyncProgress = MC.SyncProgress or { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = 0 }
MC.NativeLoadProfile = MC.NativeLoadProfile or { decompressMS = 0, jsonMS = 0, hydrateMS = 0, chunks = 0, cells = 0 }

local function effectiveStateRegistryHash()
	if MC.GetEffectiveBlockStateRegistryHash then
		return tostring( MC.GetEffectiveBlockStateRegistryHash() or "" )
	end
	local metadata = MC.BlockStateRegistryMetadata
	return metadata and tostring( metadata.schemaHash or "" ) or ""
end

local function validateSavedRegistryMetadata( data )
	if MC.ValidateModRegistrySnapshot then
		local registryOK, registryError = MC.ValidateModRegistrySnapshot( data.registry )
		if registryOK ~= true then return false, registryError or "invalid_registry_snapshot" end
	end
	if data.registryHash == nil then
		local metadata = MC.BlockStateRegistryMetadata
		local expectedVanillaHash = metadata and metadata.schemaHash or nil
		if not isstring( data.schemaHash ) or data.schemaHash == ""
		or expectedVanillaHash and data.schemaHash ~= expectedVanillaHash then
			return false, "state_registry_mismatch"
		end
		return true
	end
	if not isstring( data.registryHash ) or data.registryHash == "" then
		return false, "state_registry_mismatch"
	end
	local scopedHash = data.registry ~= nil and MC.ModRegistrySnapshotHash
		and MC.ModRegistrySnapshotHash( data.registry ) or nil
	local effectiveHash = effectiveStateRegistryHash()
	local vanillaHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil
	if data.registryHash ~= scopedHash and data.registryHash ~= effectiveHash and data.registryHash ~= vanillaHash then
		return false, "state_registry_mismatch"
	end
	return true
end

concommand.Add( "mc_native_load_profile", function()
	local p = MC.NativeLoadProfile or {}
	print( string.format( "[mcswep-native] load decompress=%.3fms json=%.3fms hydrate=%.3fms chunks=%d cells=%d",
		tonumber( p.decompressMS ) or 0, tonumber( p.jsonMS ) or 0, tonumber( p.hydrateMS ) or 0,
		tonumber( p.chunks ) or 0, tonumber( p.cells ) or 0 ) )
end, nil, "Print snapshot decode and NativeChunk hydration timings" )

local PendingReliableAckBytes = 0
local NextReliableAckAt = 0

local function flushReliableAck()
	if PendingReliableAckBytes <= 0 then return end
	-- the server clamps a single ack at 4MB; carry any remainder to the next flush
	local bytes = math.min( PendingReliableAckBytes, 4194304 )
	PendingReliableAckBytes = PendingReliableAckBytes - bytes
	net.Start( "mc_reliable_ack" )
		net.WriteUInt( bytes, 32 )
	net.SendToServer()
	NextReliableAckAt = CurTime() + 0.02
end

local function queueReliableAck( bytes )
	bytes = math.max( 0, math.ceil( tonumber( bytes ) or 0 ) )
	if bytes <= 0 then return end
	PendingReliableAckBytes = math.min( PendingReliableAckBytes + bytes, 4294967295 )
	if PendingReliableAckBytes >= 65536 or CurTime() >= NextReliableAckAt then
		flushReliableAck()
	end
end

timer.Create( "mc_reliable_ack_flush", 0.05, 0, flushReliableAck )

local function touchProgress()
	MC.SyncProgress.lastUpdate = CurTime()
end

local function beginProgressChunk( expected )
	local p = MC.SyncProgress
	p.active = true
	p.expected = p.expected + expected
	p.chunks = p.chunks + 1
	touchProgress()
end

local function addProgressCells( count )
	local p = MC.SyncProgress
	p.received = p.received + count
	touchProgress()
end

local function finishProgressChunk( key )
	local p = MC.SyncProgress
	p.doneChunks = p.doneChunks + 1
	touchProgress()
	if key then MC.MarkChunkDirty( key ) end
end

local function markNeighbours( cx, cy, cz )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx + 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx - 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy + 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy - 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz + 1 ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz - 1 ) )
end

local function cellCollisionDependsOnNeighbours( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	return MC.BlockCollisionDependsOnNeighbours and MC.BlockCollisionDependsOnNeighbours( id ) == true
end

local function markLightingDirtyForChange( bx, by, bz, oldId, oldOrient, newId, newOrient, rateLimited )
	if MC.MarkLightingDirtyForChange then
		MC.MarkLightingDirtyForChange( bx, by, bz, oldId, oldOrient, newId, newOrient, rateLimited )
	elseif MC.MarkLightingDirtyAroundCell then
		MC.MarkLightingDirtyAroundCell( bx, by, bz, nil, rateLimited )
	end
end

-- State-aware variant: block light emission/opacity can depend on state
-- properties (redstone lamp lit=true emits 15 while its legacy block id emits
-- 0), so every path that writes stateIds must not downgrade to id+orient here.
local function markLightingDirtyForStateChange( bx, by, bz, oldStateId, newStateId, rateLimited )
	if MC.MarkLightingDirtyForStateChange then
		MC.MarkLightingDirtyForStateChange( bx, by, bz, oldStateId, newStateId, rateLimited )
	elseif MC.MarkLightingDirtyAroundCell then
		MC.MarkLightingDirtyAroundCell( bx, by, bz, nil, rateLimited )
	end
end

local function addCellPhysBounds( boundsByKey, key, bounds )
	local list = boundsByKey[key]
	if not list then
		list = {}
		boundsByKey[key] = list
	end
	for _, e in ipairs( list ) do
		if e[1] == bounds[1] and e[2] == bounds[2] and e[3] == bounds[3]
		and e[4] == bounds[4] and e[5] == bounds[5] and e[6] == bounds[6] then return end
	end
	list[#list + 1] = bounds
end

local function clippedCellPhysBounds( a, b )
	local out = {
		math.max( a[1], b[1] ),
		math.max( a[2], b[2] ),
		math.max( a[3], b[3] ),
		math.min( a[4], b[4] ),
		math.min( a[5], b[5] ),
		math.min( a[6], b[6] ),
	}
	if out[1] <= out[4] and out[2] <= out[5] and out[3] <= out[6] then return out end
	return nil
end

local function addClientInterestCellPhysBounds( boundsByKey, key, subchunkBounds )
	local interest = MC.ClientCollisionInterest and MC.ClientCollisionInterest[key]
	if not interest then return end

	for _, interestBounds in ipairs( interest ) do
		local clipped = clippedCellPhysBounds( subchunkBounds, interestBounds )
		if clipped then
			addCellPhysBounds( boundsByKey, key, clipped )
		end
	end
end

local function collectCellPhysBounds( boundsByKey, bx, by, bz )
	local function mark( x, y, z )
		local key, bounds = MC.CellCollisionSubchunkBounds( x, y, z )
		addClientInterestCellPhysBounds( boundsByKey, key, bounds )
	end

	mark( bx, by, bz )
	if cellCollisionDependsOnNeighbours( bx + 1, by, bz ) then mark( bx + 1, by, bz ) end
	if cellCollisionDependsOnNeighbours( bx - 1, by, bz ) then mark( bx - 1, by, bz ) end
	if cellCollisionDependsOnNeighbours( bx, by + 1, bz ) then mark( bx, by + 1, bz ) end
	if cellCollisionDependsOnNeighbours( bx, by - 1, bz ) then mark( bx, by - 1, bz ) end
end

-- An edited cell (plus shape-dependent face neighbours) replaces the affected
-- collision subchunk objects, but only rebuilds the currently active client
-- AABB/aim interest inside those subchunks.
function MC.MarkCellPhysNeighbours( bx, by, bz, priority, bulk )
	local boundsByKey = {}
	collectCellPhysBounds( boundsByKey, bx, by, bz )

	for key, boundsList in pairs( boundsByKey ) do
		if bulk and MC.MarkChunkPhysDirtyBulk then
			MC.MarkChunkPhysDirtyBulk( key )
		else
			MC.MarkChunkPhysDirty( key, priority, boundsList )
		end
	end
end

local function flushCellPhysBounds( boundsByKey, bulk )
	for key, boundsList in pairs( boundsByKey or {} ) do
		if bulk and MC.MarkChunkPhysDirtyBulk then
			MC.MarkChunkPhysDirtyBulk( key )
		else
			MC.MarkChunkPhysDirty( key, false, boundsList )
		end
	end
end

local function applyNetCell( bx, by, bz, id, orient, meshRateLimited )
	MC.ConfirmPrediction( bx, by, bz, id, orient )
	local oldId = MC.GetBlock( bx, by, bz )
	local oldOrient = MC.GetBlockOrient( bx, by, bz )
	local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
	if changed then
		local newOrient = MC.GetBlockOrient( bx, by, bz )
		markLightingDirtyForChange( bx, by, bz, oldId, oldOrient, id, newOrient, meshRateLimited )
		MC.MarkDirty( bx, by, bz, meshRateLimited )
		MC.MarkCellPhysNeighbours( bx, by, bz, false, meshRateLimited == true )
	end
end

local function applyNetCellsBulk( cells, meshRateLimited )
	local boundsByKey = {}
	for _, cell in ipairs( cells or {} ) do
		MC.ConfirmPrediction( cell.bx, cell.by, cell.bz, cell.id, cell.orient )
		local oldId = MC.GetBlock( cell.bx, cell.by, cell.bz )
		local oldOrient = MC.GetBlockOrient( cell.bx, cell.by, cell.bz )
		local _, _, _, changed = MC.SetBlockRaw( cell.bx, cell.by, cell.bz, cell.id, cell.orient )
		if changed then
			local newOrient = MC.GetBlockOrient( cell.bx, cell.by, cell.bz )
			markLightingDirtyForChange( cell.bx, cell.by, cell.bz, oldId, oldOrient, cell.id, newOrient, meshRateLimited )
			MC.MarkDirty( cell.bx, cell.by, cell.bz, meshRateLimited )
			collectCellPhysBounds( boundsByKey, cell.bx, cell.by, cell.bz )
		end
	end
	flushCellPhysBounds( boundsByKey, meshRateLimited == true )
end

-- Phase 4 state transport calls these narrow application helpers. Transport
-- ordering/generation validation deliberately lives in state/cl_network_transport.lua;
-- this file remains the owner of client prediction, lighting, mesh and physics
-- invalidation after an authoritative cell value has been accepted.
function MC.ConfirmStatePrediction( bx, by, bz, stateId, revision, force )
	local key = MC.CellKey( bx, by, bz )
	local pending = MC.PendingPredictions and MC.PendingPredictions[key] or nil
	if not pending then return false, false end
	revision = math.floor( tonumber( revision ) or 0 )
	local baseline = pending.authoritativeRevisionAtPrediction or 0
	-- A rejected edit is sent as a correction at the current revision.  It is
	-- therefore allowed to confirm at the same revision, but never by an older
	-- packet that predates this prediction.
	if force ~= true then
		if revision <= baseline then return false, false end
	elseif revision < baseline then
		return false, false
	end
	if MC.ReconcileStatePredictionCells then
		local cleared = MC.ReconcileStatePredictionCells({ { bx = bx, by = by, bz = bz } }, revision, force == true )
		return cleared > 0, pending.stateId == stateId
	end
	MC.PendingPredictions[key] = nil
	return true, pending.stateId == stateId
end

function MC.ApplyStateNetCell( bx, by, bz, stateId, revision, meshRateLimited )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return false, "invalid_state_id" end
	if MC.ReconcileStatePredictionCells then
		MC.ReconcileStatePredictionCells( { { bx = bx, by = by, bz = bz } }, revision, false )
	end
	local oldStateId = MC.GetBlockState( bx, by, bz ) or 0
	local _, _, _, changed, setError = MC.SetBlockStateRaw( bx, by, bz, stateId )
	if not changed then return changed == false, setError end
	markLightingDirtyForStateChange( bx, by, bz, oldStateId, stateId, meshRateLimited )
	MC.MarkDirty( bx, by, bz, meshRateLimited )
	MC.MarkCellPhysNeighbours( bx, by, bz, false, meshRateLimited == true )
	return true
end

function MC.ApplyStateNetCellsBulk( cells, revision, meshRateLimited )
	local boundsByKey = {}
	if MC.ReconcileStatePredictionCells then
		MC.ReconcileStatePredictionCells( cells, revision, false )
	end
	for _, cell in ipairs( cells or {} ) do
		local stateId = math.floor( tonumber( cell.stateId ) or -1 )
		if MC.IsValidBlockState and MC.IsValidBlockState( stateId ) then
			local oldStateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
			local _, _, _, changed = MC.SetBlockStateRaw( cell.bx, cell.by, cell.bz, stateId )
			if changed then
				markLightingDirtyForStateChange( cell.bx, cell.by, cell.bz, oldStateId, stateId, meshRateLimited )
				MC.MarkDirty( cell.bx, cell.by, cell.bz, meshRateLimited )
				collectCellPhysBounds( boundsByKey, cell.bx, cell.by, cell.bz )
			end
		end
	end
	flushCellPhysBounds( boundsByKey, meshRateLimited == true )
	return true
end

MC.PendingPredictions = MC.PendingPredictions or {}
MC.PendingPredictionGroups = MC.PendingPredictionGroups or {}
MC.NextPredictionGroupId = MC.NextPredictionGroupId or 0

local function predictionKey( bx, by, bz )
	return MC.CellKey( bx, by, bz )
end

function MC.IsPendingPredictionCell( bx, by, bz )
	return MC.PendingPredictions[predictionKey( bx, by, bz )] ~= nil
end

local markPredictedCellDirty

local function rollbackPredictionCell( pending )
	if not pending then return end
	local currentStateId = MC.GetBlockState( pending.bx, pending.by, pending.bz )
	if currentStateId ~= pending.stateId then return end
	MC.SetBlockStateRaw( pending.bx, pending.by, pending.bz, pending.oldStateId or 0 )
	markPredictedCellDirty( pending.bx, pending.by, pending.bz, false,
		currentStateId, pending.oldStateId or 0 )
end

-- Reconcile a whole predicted placement/break plan against one authoritative
-- transaction. State-rich blocks can make the client and server plans differ;
-- cells predicted only on the client must be rolled back even when they are not
-- present in the server's correction packet.
function MC.ReconcileStatePredictionCells( cells, revision, correction )
	local authoritative = {}
	local groups = {}
	revision = math.floor( tonumber( revision ) or 0 )
	for _, cell in ipairs( cells or {} ) do
		local key = predictionKey( cell.bx, cell.by, cell.bz )
		authoritative[key] = true
		local pending = MC.PendingPredictions[key]
		if pending then
			local baseline = pending.authoritativeRevisionAtPrediction or 0
			local eligible = correction == true and revision >= baseline
				or correction ~= true and revision > baseline
			if eligible then groups[pending.groupId or key] = true end
		end
	end

	local cleared = 0
	for groupId in pairs( groups ) do
		local group = MC.PendingPredictionGroups[groupId]
		if not group then
			group = { keys = {} }
			for key, pending in pairs( MC.PendingPredictions ) do
				if pending.groupId == groupId then group.keys[#group.keys + 1] = key end
			end
			if #group.keys == 0 and MC.PendingPredictions[groupId] then group.keys[1] = groupId end
		end
		if group and group.keys then
			for _, key in ipairs( group.keys ) do
				local pending = MC.PendingPredictions[key]
				if pending then
					if not authoritative[key] then rollbackPredictionCell( pending ) end
					MC.PendingPredictions[key] = nil
					cleared = cleared + 1
				end
			end
		end
		MC.PendingPredictionGroups[groupId] = nil
	end
	return cleared
end

-- A chunk hydration payload has already overwritten the affected cells with
-- authoritative storage. Drop predictions in those chunks without rolling
-- them back; if a multi-cell prediction crosses the boundary, roll back only
-- the untouched members of that prediction group.
function MC.DiscardPredictionsForChunkKeys( chunkKeys )
	if not istable( chunkKeys ) then return 0 end
	local groups = {}
	for key, pending in pairs( MC.PendingPredictions or {} ) do
		local cx, cy, cz = MC.CellToChunk( pending.bx, pending.by, pending.bz )
		if chunkKeys[MC.ChunkKey( cx, cy, cz )] then groups[pending.groupId or key] = true end
	end
	local cleared = 0
	for groupId in pairs( groups ) do
		local group = MC.PendingPredictionGroups and MC.PendingPredictionGroups[groupId]
		local keys = group and group.keys or {}
		if #keys == 0 then
			for key, pending in pairs( MC.PendingPredictions or {} ) do
				if ( pending.groupId or key ) == groupId then keys[#keys + 1] = key end
			end
		end
		for _, key in ipairs( keys ) do
			local pending = MC.PendingPredictions[key]
			if pending then
				local cx, cy, cz = MC.CellToChunk( pending.bx, pending.by, pending.bz )
				if not chunkKeys[MC.ChunkKey( cx, cy, cz )] then rollbackPredictionCell( pending ) end
				MC.PendingPredictions[key] = nil
				cleared = cleared + 1
			end
		end
		if MC.PendingPredictionGroups then MC.PendingPredictionGroups[groupId] = nil end
	end
	return cleared
end

function MC.ClientEditPredictionEnabled()
	if game.SinglePlayer and game.SinglePlayer() then return false end
	if game.MaxPlayers and game.MaxPlayers() <= 1 then return false end

	local lp = LocalPlayer and LocalPlayer() or nil
	if IsValid( lp ) and lp.IsListenServerHost and lp:IsListenServerHost() then return false end

	return true
end

markPredictedCellDirty = function( bx, by, bz, priority, oldStateId, newStateId )
	markLightingDirtyForStateChange( bx, by, bz, oldStateId, newStateId )
	MC.MarkDirty( bx, by, bz )
	MC.MarkCellPhysNeighbours( bx, by, bz, priority == true )
end

local function predictCells( cells, priorityFn )
	if not istable( cells ) or #cells == 0 then return false end
	for _, cell in ipairs( cells ) do
		if MC.PendingPredictions[predictionKey( cell.bx, cell.by, cell.bz )] then return false end
	end

	local oldStates = {}
	local resolvedStates = {}
	for i, cell in ipairs( cells ) do
		local stateId
		if cell.stateId ~= nil then
			stateId = math.floor( tonumber( cell.stateId ) or -1 )
		else
			local legacyId = math.floor( tonumber( cell.id ) or 0 )
			local legacyOrient = legacyId ~= 0 and MC.NormalizeOrient( legacyId, cell.orient ) or 0
			stateId = MC.StateFromLegacy( legacyId, legacyOrient )
		end
		if not stateId or not MC.IsValidBlockState( stateId ) then return false end
		local id, orient = MC.LegacyFromState( stateId )
		if id == nil then return false end
		resolvedStates[i] = { stateId = stateId, id = id, orient = orient or 0 }
		oldStates[i] = {
			id = MC.GetBlock( cell.bx, cell.by, cell.bz ),
			orient = MC.GetBlockOrient( cell.bx, cell.by, cell.bz ),
			stateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ),
		}
	end

	MC.NextPredictionGroupId = MC.NextPredictionGroupId + 1
	local groupId = MC.NextPredictionGroupId
	local group = { keys = {} }
	MC.PendingPredictionGroups[groupId] = group
	for i, cell in ipairs( cells ) do
		local resolved = resolvedStates[i]
		local stateId, id, orient = resolved.stateId, resolved.id, resolved.orient
		local _, _, _, changed = MC.SetBlockStateRaw( cell.bx, cell.by, cell.bz, stateId )
		if changed then
			local key = predictionKey( cell.bx, cell.by, cell.bz )
			MC.PendingPredictions[key] = {
				bx = cell.bx,
				by = cell.by,
				bz = cell.bz,
				id = id,
				orient = orient,
				stateId = stateId,
				oldId = oldStates[i].id,
				oldOrient = oldStates[i].orient,
				oldStateId = oldStates[i].stateId,
				authoritativeRevisionAtPrediction = MC.AppliedStateRevision or 0,
				groupId = groupId,
				expire = CurTime() + 2.5,
			}
			group.keys[#group.keys + 1] = key
			markPredictedCellDirty( cell.bx, cell.by, cell.bz, priorityFn and priorityFn( cell ) or false,
				oldStates[i].stateId or 0, stateId )
		end
	end
	if #group.keys == 0 then MC.PendingPredictionGroups[groupId] = nil end

	return true
end

-- Prediction-side mirror of validatePlacementPlan's occupancy rule. Fluids are
-- replaceable, so a placement into water must be predicted like one into air --
-- otherwise the block only appears when the server broadcast lands.
local function predictedCellsArePlaceable( cells )
	for _, cell in ipairs( cells ) do
		local existingId = MC.GetBlock( cell.bx, cell.by, cell.bz )
		if cell.updateExisting then
			if existingId == 0 or existingId ~= cell.id then return false end
		elseif existingId ~= 0
		and not ( MC.CellIsFluidBlock and MC.CellIsFluidBlock( cell.bx, cell.by, cell.bz ) ) then
			return false
		end
	end
	return true
end

function MC.PredictSetBlockState( bx, by, bz, stateId )
	if not MC.ClientEditPredictionEnabled() then return false end
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId <= 0 or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return false end
	local plan = MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
	if not plan then return false end
	if not predictedCellsArePlaceable( plan.cells ) then return false end
	return predictCells( plan.cells, function() return true end )
end

function MC.PredictSetBlock( bx, by, bz, id, orient )
	if not MC.ClientEditPredictionEnabled() then return false end
	if not MC.IsValidBlock or not MC.IsValidBlock( id ) then return false end
	local plan = MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
	if not plan then return false end
	if not predictedCellsArePlaceable( plan.cells ) then return false end
	return predictCells( plan.cells, function() return true end )
end

function MC.PredictBreakBlock( bx, by, bz, ply )
	if not MC.ClientEditPredictionEnabled() then return false end
	if IsValid( ply ) and not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, MC.CurrentReach() ) then return false end
	local oldId = MC.GetBlock( bx, by, bz )
	if oldId == 0 then return false end
	local oldOrient = MC.GetBlockOrient( bx, by, bz )
	local oldStateId = MC.GetBlockState( bx, by, bz )
	local plan = MC.BuildBreakPlan and MC.BuildBreakPlan( bx, by, bz )
	if not plan then return false end
	if not predictCells( plan.cells, function() return true end ) then return false end
	if MC.PlayBlockFx then
		MC.PlayBlockFx( 2, oldId, oldOrient, bx, by, bz, true, oldStateId )
	end
	return true
end

function MC.ConfirmPrediction( bx, by, bz, id, orient )
	local key = predictionKey( bx, by, bz )
	local hadPrediction = MC.PendingPredictions[key] ~= nil
	if MC.ReconcileStatePredictionCells then
		MC.ReconcileStatePredictionCells( { { bx = bx, by = by, bz = bz } }, 4294967295, true )
	elseif hadPrediction then
		MC.PendingPredictions[key] = nil
	end
	return hadPrediction
end

local function rollbackExpiredPredictions()
	local now = CurTime()
	for key, pending in pairs( MC.PendingPredictions ) do
		if now >= pending.expire then
			rollbackPredictionCell( pending )
			MC.PendingPredictions[key] = nil
		end
	end
	for groupId, group in pairs( MC.PendingPredictionGroups ) do
		local alive = false
		for _, key in ipairs( group.keys or {} ) do
			if MC.PendingPredictions[key] then alive = true break end
		end
		if not alive then MC.PendingPredictionGroups[groupId] = nil end
	end
end

local function resetChunk( cx, cy, cz )
	local c = MC.EnsureChunk( cx, cy, cz )
	MC.ResetChunkStateStorage( c )
	if MC.TouchChunkCollisionVersion then MC.TouchChunkCollisionVersion( c ) end
	if MC.IndexChunkLightSources then MC.IndexChunkLightSources( c ) end
	return c
end

-- State chunk streams share the same ACK-windowed reliable queue as legacy
-- bulk transfers. The state transport loads after this file and calls through
-- this narrow public helper instead of maintaining a second congestion window.
MC.QueueReliableAck = queueReliableAck

local function activeNativeChunkBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	return backend and backend.native and backend.IsActive and backend.IsActive() and backend or nil
end

local function readCellsIntoChunk( c, count )
	local changed = false
	local nativeBackend = activeNativeChunkBackend()
	local nativeCells = nativeBackend and {} or nil
	MC.NativeChunkBulkLoading = nativeCells ~= nil
	for _ = 1, count do
		local li = net.ReadUInt( Net.LOCAL_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )
		if id ~= 0 and MC.LocalIndexInRange( li ) then
			local stateId = MC.StateFromLegacy( id, orient )
			if stateId then
				if nativeCells then
					nativeCells[#nativeCells + 1] = li; nativeCells[#nativeCells + 1] = stateId
					c.count = ( c.count or 0 ) + 1
					changed = true
				else
					local cellChanged = MC.SetChunkLocalStateRaw( c, li, stateId )
					if cellChanged then changed = true end
				end
			end
		end
	end
	MC.NativeChunkBulkLoading = false
	if nativeCells then nativeBackend.ApplyChunkCells( c, nativeCells, true ) end
	if changed and MC.FinalizeChunkStateStorage then MC.FinalizeChunkStateStorage( c ) end
	if changed and MC.IndexChunkLightSources then MC.IndexChunkLightSources( c ) end
end

-- Rendering is data-driven (PostDraw hooks over MC.Meshes) and prediction
-- collision lives on per-player mc_collision_carrier entities, so the client
-- needs NO mc_chunk entity at all (shells are TRANSMIT_NEVER). Keep only the
-- legacy registry entry coherent if one somehow exists.
local function reviveChunkEnt( c )
	MC.ChunkEnts = MC.ChunkEnts or {}
	local e = MC.ChunkEnts[c.key]
	if not IsValid( e ) then
		MC.ChunkEnts[c.key] = nil
		return
	end
	e.cx, e.cy, e.cz = c.cx, c.cy, c.cz
	e.ChunkKey = c.key
end

local function resetClientWorldForSnapshot( expectedChunks, expectedBlocks )
	if MC.FreeAllMeshes then MC.FreeAllMeshes() end
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native == true and backend.ClearWorld then backend.ClearWorld() end
	-- Only the lighting-cache wipe is wanted here: MC.World/MeshDirty are
	-- replaced a few lines below, so MarkAllMeshesDirty's chunk marking would
	-- be discarded and its block-light rebuild would run on the old world.
	if MC.ClearLightingCache then MC.ClearLightingCache() end
	for _, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then
			if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
			if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
			e:PhysicsDestroy()
		end
	end
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
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
	MC.PendingPredictions = {}
	MC.PendingPredictionGroups = {}
	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
	if MC.RunEvent then MC.RunEvent( "MC.ClientWorldProjectionChanged", "snapshot_reset", {} ) end
	MC.SyncProgress = {
		expected = math.max( 0, math.floor( tonumber( expectedBlocks ) or 0 ) ),
		received = 0,
		chunks = math.max( 0, math.floor( tonumber( expectedChunks ) or 0 ) ),
		doneChunks = 0,
		active = true,
		lastUpdate = CurTime(),
		snapshot = true,
	}
end

MC.ResetClientWorldForStateSync = resetClientWorldForSnapshot

local function snapshotPaletteEntry( cache, palette, index )
	local pi = math.floor( tonumber( index ) or -1 )
	if pi < 0 then return nil end
	local cached = cache[pi]
	if cached ~= nil then return cached ~= false and cached or nil end

	local spec = istable( palette ) and palette[pi + 1] or nil
	if not isstring( spec ) then return nil end
	local stateId = MC.ParseBlockState( spec )
	cache[pi] = stateId or false
	return stateId
end

local function loadSnapshotBlockEntities( chunk, envelopes, strict )
	if envelopes == nil then return true end
	if not istable( envelopes ) then return not strict end
	local seen = {}
	for _, envelope in ipairs( envelopes ) do
		local localIndex = istable( envelope ) and math.floor( tonumber( envelope.localIndex ) or -1 ) or -1
		if not MC.LocalIndexInRange( localIndex ) or seen[localIndex] then return false end
		seen[localIndex] = true
		local definition = MC.BlockEntityTypes and MC.BlockEntityTypes[envelope.type] or nil
		if not definition then return false end
		if not definition.serverOnly then
			local lx, ly, lz = MC.DecodeLocal( localIndex )
			local stateId = MC.GetBlockState(
				chunk.cx * MC.CS + lx,
				chunk.cy * MC.CS + ly,
				chunk.cz * MC.CH + lz
			)
			local record = MC.DecodeBlockEntityEnvelope and MC.DecodeBlockEntityEnvelope( stateId, envelope ) or nil
			if not record then return false end
			chunk.blockEntities = chunk.blockEntities or {}
			chunk.blockEntities[localIndex] = record
		end
	end
	return true
end

local function loadSnapshotChunk( data, cache, palette, strict, options )
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local chunkStarted = perfEnabled and SysTime() or nil
	local rawCX, rawCY, rawCZ = tonumber( data[1] ), tonumber( data[2] ), tonumber( data[3] )
	if strict and ( not rawCX or not rawCY or not rawCZ
		or rawCX ~= math.floor( rawCX ) or rawCY ~= math.floor( rawCY ) or rawCZ ~= math.floor( rawCZ ) ) then
		return nil, "invalid_snapshot_chunk_coords"
	end
	local cx = math.floor( rawCX or 0 )
	local cy = math.floor( rawCY or 0 )
	local cz = math.floor( rawCZ or 0 )
	local cells = data[4]
	local blockEntities = data[5]
	local storageStarted = perfEnabled and SysTime() or nil
	local c = MC.EnsureChunk( cx, cy, cz )
	MC.ResetChunkStateStorage( c )
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.ensure_reset", ( SysTime() - storageStarted ) * 1000 ) end
	local seen = {}
	local nativeBackend = activeNativeChunkBackend()
	local nativeCells = nativeBackend and {} or nil
	MC.NativeChunkBulkLoading = nativeCells ~= nil
	local loadError
	local cellsStarted = perfEnabled and SysTime() or nil

	if isstring( cells ) then
		for entry in string.gmatch( cells, "[^;]+" ) do
			local liText, piText = string.match( entry, "^(-?%d+):(-?%d+)$" )
			local li = math.floor( tonumber( liText ) or -1 )
			if strict and ( not liText or not MC.LocalIndexInRange( li ) or seen[li] ) then loadError = "invalid_snapshot_cell" break end
			if MC.LocalIndexInRange( li ) then
				local stateId = snapshotPaletteEntry( cache, palette, piText )
				if strict and ( not stateId or stateId == 0 ) then loadError = "invalid_snapshot_state" break end
				if stateId and stateId ~= 0 then
					if nativeCells then
						nativeCells[#nativeCells + 1] = li; nativeCells[#nativeCells + 1] = stateId
						c.count = ( c.count or 0 ) + 1
					else
						local changed = MC.SetChunkLocalStateRaw( c, li, stateId )
						if strict and changed ~= true then loadError = "snapshot_state_write_failed" break end
					end
					seen[li] = true
				end
			end
		end
	elseif istable( cells ) then
		if strict and #cells % 2 ~= 0 then loadError = "invalid_snapshot_cells" end
		for i = 1, #cells, 2 do
			if loadError then break end
			local li = math.floor( tonumber( cells[i] ) or -1 )
			if strict and ( not MC.LocalIndexInRange( li ) or seen[li] ) then loadError = "invalid_snapshot_cell" break end
			if MC.LocalIndexInRange( li ) then
				local stateId = snapshotPaletteEntry( cache, palette, cells[i + 1] )
				if strict and ( not stateId or stateId == 0 ) then loadError = "invalid_snapshot_state" break end
				if stateId and stateId ~= 0 then
					if nativeCells then
						nativeCells[#nativeCells + 1] = li; nativeCells[#nativeCells + 1] = stateId
						c.count = ( c.count or 0 ) + 1
					else
						local changed = MC.SetChunkLocalStateRaw( c, li, stateId )
						if strict and changed ~= true then loadError = "snapshot_state_write_failed" break end
					end
					seen[li] = true
				end
			end
		end
	elseif strict then
		loadError = "invalid_snapshot_cells"
	end
	if perfEnabled then MC.StreamPerformanceAddStage( nativeCells and "hydrate.native_cells_prepare" or "hydrate.lua_cells", ( SysTime() - cellsStarted ) * 1000, { hydratedCells = c.count or 0 } ) end
	if loadError then MC.NativeChunkBulkLoading = false; return nil, loadError end
	MC.NativeChunkBulkLoading = false
	local nativeStarted = perfEnabled and SysTime() or nil
	if nativeCells and not nativeBackend.ApplyChunkCells( c, nativeCells, true ) then
		if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.native_apply", ( SysTime() - nativeStarted ) * 1000 ) end
		return nil, "native_chunk_batch_failed"
	end
	if perfEnabled and nativeCells then MC.StreamPerformanceAddStage( "hydrate.native_apply", ( SysTime() - nativeStarted ) * 1000 ) end
	local blockEntitiesStarted = perfEnabled and SysTime() or nil
	if not loadSnapshotBlockEntities( c, blockEntities, strict ) then return nil, "invalid_snapshot_block_entities" end
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.block_entities", ( SysTime() - blockEntitiesStarted ) * 1000 ) end

	local finalizeStarted = perfEnabled and SysTime() or nil
	if MC.FinalizeChunkStateStorage then MC.FinalizeChunkStateStorage( c ) end
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.storage_finalize", ( SysTime() - finalizeStarted ) * 1000 ) end
	local deferLighting = istable( options ) and options.deferLighting == true
	if not deferLighting and MC.IndexChunkLightSources then MC.IndexChunkLightSources( c ) end
	local deferDirty = istable( options ) and options.deferDirty == true
	if c.count <= 0 then MC.World[c.key] = nil end
	if not deferDirty and MC.MarkChunkDirty then MC.MarkChunkDirty( c.key ) end
	if perfEnabled then
		local chunkMS = ( SysTime() - chunkStarted ) * 1000
		MC.StreamPerformanceAddStage( "hydrate.chunk_total", chunkMS, { hydratedChunks = 1 } )
		local state = MC.StreamPerformanceStats
		if state and ( not state.worstHydrateChunk or chunkMS > state.worstHydrateChunk.ms ) then
			state.worstHydrateChunk = { key = c.key, cells = c.count or 0, ms = chunkMS }
		end
	end
	return c.count
end

local function validateSnapshotChunkData( data, cache, palette )
	if not istable( data ) then return nil, "invalid_snapshot_chunk" end
	local cx, cy, cz = tonumber( data[1] ), tonumber( data[2] ), tonumber( data[3] )
	if not cx or not cy or not cz or cx ~= math.floor( cx ) or cy ~= math.floor( cy ) or cz ~= math.floor( cz ) then
		return nil, "invalid_snapshot_chunk_coords"
	end
	local cells, seen, states, count = data[4], {}, {}, 0
	local function validateCell( liValue, paletteIndex )
		local li = math.floor( tonumber( liValue ) or -1 )
		if not MC.LocalIndexInRange( li ) or seen[li] then return false, "invalid_snapshot_cell" end
		local stateId = snapshotPaletteEntry( cache, palette, paletteIndex )
		if not stateId or stateId == 0 or not MC.IsValidBlockState( stateId ) then return false, "invalid_snapshot_state" end
		seen[li], states[li], count = true, stateId, count + 1
		return true
	end
	if isstring( cells ) then
		for entry in string.gmatch( cells, "[^;]+" ) do
			local liText, piText = string.match( entry, "^(-?%d+):(-?%d+)$" )
			if not liText then return nil, "invalid_snapshot_cell" end
			local ok, err = validateCell( liText, piText ); if not ok then return nil, err end
		end
	elseif istable( cells ) then
		if #cells % 2 ~= 0 then return nil, "invalid_snapshot_cells" end
		for i = 1, #cells, 2 do local ok, err = validateCell( cells[i], cells[i + 1] ); if not ok then return nil, err end end
	else
		return nil, "invalid_snapshot_cells"
	end
	local envelopes = data[5]
	if envelopes ~= nil then
		if not istable( envelopes ) then return nil, "invalid_snapshot_block_entities" end
		local beSeen = {}
		for _, envelope in ipairs( envelopes ) do
			local li = istable( envelope ) and math.floor( tonumber( envelope.localIndex ) or -1 ) or -1
			if not MC.LocalIndexInRange( li ) or beSeen[li] then return nil, "invalid_snapshot_block_entities" end
			beSeen[li] = true
			local definition = MC.BlockEntityTypes and MC.BlockEntityTypes[envelope.type]
			if not definition then return nil, "invalid_snapshot_block_entities" end
			if not definition.serverOnly then
				local record = MC.DecodeBlockEntityEnvelope and MC.DecodeBlockEntityEnvelope( states[li] or 0, envelope ) or nil
				if not record then return nil, "invalid_snapshot_block_entities" end
			end
		end
	end
	return { cx = cx, cy = cy, cz = cz, key = MC.ChunkKey( cx, cy, cz ), count = count }
end

-- Hydrate only the listed chunks while keeping the rest of MC.World intact.
-- This is the client half of the storage-level /fill fast path: each Native
-- Chunk receives one replace batch, while the Lua backend rebuilds its packed
-- state sections directly from the same save-compatible payload.
-- Finalize a patch whose state cells were already committed atomically by the
-- native decoder. Lua retains only chunk shells, Block Entities, and the
-- lighting/collision bookkeeping consumed by the rest of the addon.
function MC.FinalizeNativeStateChunkPatch( committed, backendEpoch, options )
	if not istable( committed ) or not istable( committed.chunks ) then return false, "invalid_native_patch_result" end
	local backend = activeNativeChunkBackend()
	if not backend or not backend.Epoch or backend.Epoch() ~= backendEpoch then return false, "native_patch_epoch_mismatch" end
	local oldChunks, prepared, blocks = {}, {}, 0
	for index, item in ipairs( committed.chunks ) do
		local cx, cy, cz = tonumber( item.cx ), tonumber( item.cy ), tonumber( item.cz )
		local count = math.floor( tonumber( item.count ) or -1 )
		if not cx or not cy or not cz or cx ~= math.floor( cx ) or cy ~= math.floor( cy ) or cz ~= math.floor( cz )
		or count < 0 or count > ( MC.CS or 16 ) * ( MC.CS or 16 ) * ( MC.CH or 32 ) then
			return false, "invalid_native_patch_chunk:" .. tostring( index )
		end
		local key = MC.ChunkKey( cx, cy, cz )
		local old = MC.World and MC.World[key]
		if old then oldChunks[#oldChunks + 1] = old end
		local envelopes
		if isstring( item.blockEntitiesJSON ) and item.blockEntitiesJSON ~= "" then
			envelopes = util.JSONToTable( item.blockEntitiesJSON )
			if not istable( envelopes ) then return false, "invalid_native_patch_block_entities:" .. tostring( index ) end
		end
		prepared[index] = { cx = cx, cy = cy, cz = cz, key = key, count = count, blockEntities = envelopes }
		blocks = blocks + count
	end
	if math.floor( tonumber( committed.blocks ) or -1 ) ~= blocks then return false, "native_patch_block_count_mismatch" end
	local fullSnapshot = istable( options ) and options.fullSnapshot == true
	local lightingBatch = not fullSnapshot and MC.BeginPartialLightingBatch
		and MC.BeginPartialLightingBatch( oldChunks ) or nil
	local touched, newChunks = {}, {}
	for _, item in ipairs( prepared ) do
		local c = MC.EnsureChunk( item.cx, item.cy, item.cz )
		MC.ResetChunkStateStorage( c )
		c.count = item.count
		c.nativeMeshEpoch = backendEpoch
		c.nativeStateStorage = true
		c.chunkBackend = "native"
		c.stateSections = nil
		if MC.AttachNativeChunkCompatibilityProxy then MC.AttachNativeChunkCompatibilityProxy( c ) end
		if not loadSnapshotBlockEntities( c, item.blockEntities, true ) then
			if MC.CancelPartialLightingBatch then MC.CancelPartialLightingBatch( lightingBatch ) end
			return false, "invalid_native_patch_block_entities"
		end
		if MC.FinalizeChunkStateStorage then MC.FinalizeChunkStateStorage( c ) end
		if MC.IndexChunkLightSources then MC.IndexChunkLightSources( c ) end
		touched[#touched + 1] = { cx = item.cx, cy = item.cy, cz = item.cz, key = item.key, count = item.count }
		if item.count <= 0 then
			MC.World[item.key] = nil
			if MC.PhysDirty then MC.PhysDirty[item.key] = nil end
			if MC.PhysDirtyPriority then MC.PhysDirtyPriority[item.key] = nil end
		else
			newChunks[#newChunks + 1] = c
		end
	end
	if lightingBatch and MC.EndPartialLightingBatch then MC.EndPartialLightingBatch( lightingBatch, newChunks, true ) end
	return true, { chunks = touched, blocks = blocks }
end

local function forEachBinarySectionCell( item, callback )
	for sectionIndex = 1, 2 do
		local section = item.sections and item.sections[sectionIndex]
		if section then
			MC.StateSection.ForEach( section, function( sectionLocalIndex, stateId )
				callback( ( sectionIndex - 1 ) * 4096 + sectionLocalIndex, stateId )
			end )
		end
	end
end

-- Commits an already validated Binary Section patch. The Lua backend adopts
-- the packed sections directly; Native keeps its existing replace-batch API so
-- enabling the transport never disables native mesh ownership.
function MC.LoadBinaryStateChunkPatchData( data, options )
	if not istable( data ) or not istable( data.chunks ) then return false, "invalid_binary_patch" end
	local prepared, oldChunks, seen, blocks = {}, {}, {}, 0
	for index, item in ipairs( data.chunks ) do
		local cx, cy, cz = tonumber( item.cx ), tonumber( item.cy ), tonumber( item.cz )
		local count = math.floor( tonumber( item.count ) or -1 )
		if not cx or not cy or not cz or cx ~= math.floor( cx ) or cy ~= math.floor( cy ) or cz ~= math.floor( cz )
		or count < 0 or count > 8192 or not istable( item.sections ) or not istable( item.blockEntities ) then
			return false, "invalid_binary_chunk:" .. tostring( index )
		end
		local key = MC.ChunkKey( cx, cy, cz )
		if seen[key] then return false, "duplicate_binary_chunk:" .. tostring( index ) end
		seen[key] = true
		prepared[index] = item
		blocks = blocks + count
		local old = MC.World and MC.World[key]
		if old then oldChunks[#oldChunks + 1] = old end
	end
	if math.floor( tonumber( data.blocks ) or -1 ) ~= blocks then return false, "binary_patch_block_count_mismatch" end

	local fullSnapshot = istable( options ) and options.fullSnapshot == true
	local lightingBatch = not fullSnapshot and MC.BeginPartialLightingBatch
		and MC.BeginPartialLightingBatch( oldChunks ) or nil
	local nativeBackend = activeNativeChunkBackend()
	local touched, newChunks = {}, {}
	for index, item in ipairs( prepared ) do
		local c = MC.EnsureChunk( item.cx, item.cy, item.cz )
		MC.ResetChunkStateStorage( c )
		local commitError
		if nativeBackend then
			local nativeCells = {}
			forEachBinarySectionCell( item, function( localIndex, stateId )
				nativeCells[#nativeCells + 1] = localIndex
				nativeCells[#nativeCells + 1] = stateId
			end )
			c.count = item.count
			if nativeBackend.ApplyChunkCells( c, nativeCells, true ) ~= true then
				commitError = "native_binary_chunk_commit_failed"
			else
				c.nativeStateStorage = true
				c.chunkBackend = "native"
				c.stateSections = nil
				c.stateStorageMigrated = true
				if MC.AttachNativeChunkCompatibilityProxy then MC.AttachNativeChunkCompatibilityProxy( c ) end
			end
		else
			c.stateSections = item.sections
			c.stateStorageMigrated = true
			c.nativeStateStorage = false
			c.count = item.count
			c.blocks, c.orients = {}, {}
			forEachBinarySectionCell( item, function( localIndex, stateId )
				if commitError then return end
				local id, orient = MC.LegacyFromState( stateId )
				if not id then commitError = "binary_state_projection_failed" return end
				c.blocks[localIndex] = id
				c.orients[localIndex] = orient or 0
			end )
		end
		if commitError or not loadSnapshotBlockEntities( c, item.blockEntities, true ) then
			if MC.CancelPartialLightingBatch then MC.CancelPartialLightingBatch( lightingBatch ) end
			resetClientWorldForSnapshot( 0, 0 )
			return false, commitError or "invalid_binary_block_entities:" .. tostring( index )
		end
		if MC.FinalizeChunkStateStorage then MC.FinalizeChunkStateStorage( c ) end
		if MC.IndexChunkLightSources then MC.IndexChunkLightSources( c ) end
		local touchedItem = { cx = item.cx, cy = item.cy, cz = item.cz, key = c.key, count = item.count }
		touched[#touched + 1] = touchedItem
		if item.count <= 0 then
			MC.World[c.key] = nil
			if MC.PhysDirty then MC.PhysDirty[c.key] = nil end
			if MC.PhysDirtyPriority then MC.PhysDirtyPriority[c.key] = nil end
		else
			newChunks[#newChunks + 1] = c
		end
	end
	if lightingBatch and MC.EndPartialLightingBatch then MC.EndPartialLightingBatch( lightingBatch, newChunks, true ) end
	return true, { chunks = touched, blocks = blocks }
end

function MC.LoadStateChunkPatchData( data )
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local loaderStarted = perfEnabled and SysTime() or nil
	if not istable( data ) or data.chunkPatch ~= true or not istable( data.chunks ) then
		return false, "invalid_chunk_patch"
	end
	local registryOK, registryError = validateSavedRegistryMetadata( data )
	if not registryOK then return false, registryError end
	if math.floor( tonumber( data.cs ) or -1 ) ~= MC.CS
	or math.floor( tonumber( data.h ) or -1 ) ~= MC.CH then return false, "chunk_geometry_mismatch" end

	local cache = {}
	local palette = data.p or data.palette
	local touched, oldChunks, prepared = {}, {}, {}
	local seenChunks = {}
	local blocks = 0
	local validationStarted = perfEnabled and SysTime() or nil
	-- Phase one validates and resolves every sparse state/BE envelope without
	-- touching MC.World. Hostile later records therefore cannot leave an earlier
	-- chunk committed or a partial-light batch open.
	for index, chunkData in ipairs( data.chunks ) do
		local item, err = validateSnapshotChunkData( chunkData, cache, palette )
		if not item then return false, tostring( err ) .. ":" .. tostring( index ) end
		if seenChunks[item.key] then return false, "duplicate_chunk_patch_coords:" .. tostring( index ) end
		seenChunks[item.key], prepared[index] = true, item
		local old = MC.World and MC.World[item.key]
		if old then oldChunks[#oldChunks + 1] = old end
		blocks = blocks + item.count
	end
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.prevalidate", ( SysTime() - validationStarted ) * 1000, { validatedChunks = #prepared, validatedCells = blocks } ) end
	if math.floor( tonumber( data.blockCount ) or -1 ) ~= blocks then return false, "chunk_patch_block_count_mismatch" end
	local lightBeginStarted = perfEnabled and SysTime() or nil
	local lightingBatch = MC.BeginPartialLightingBatch and MC.BeginPartialLightingBatch( oldChunks ) or nil
	if perfEnabled then MC.StreamPerformanceAddStage( "lighting.begin_partial", ( SysTime() - lightBeginStarted ) * 1000 ) end
	local hydrationStarted = perfEnabled and SysTime() or nil
	for index, chunkData in ipairs( data.chunks ) do
		local item = prepared[index]
		local cx, cy, cz = item.cx, item.cy, item.cz
		local loaded, loadError = loadSnapshotChunk(
			chunkData, cache, palette, true, { deferDirty = true, deferLighting = true } )
		if loaded == nil then
			-- All semantic failures were rejected in phase one. A failure here is an
			-- internal/native commit failure; force a clean resync reset rather than
			-- attempting to continue with mixed backend ownership.
			if MC.CancelPartialLightingBatch then MC.CancelPartialLightingBatch( lightingBatch ) end
			resetClientWorldForSnapshot( 0, 0 )
			return false, loadError or "chunk_patch_hydrate_failed"
		end
		touched[#touched + 1] = {
			cx = cx, cy = cy, cz = cz,
			key = MC.ChunkKey( cx, cy, cz ),
			count = loaded,
		}
	end
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.commit_chunks", ( SysTime() - hydrationStarted ) * 1000 ) end
	local collectStarted = perfEnabled and SysTime() or nil
	local newChunks = {}
	for _, item in ipairs( touched ) do
		local chunk = MC.World and MC.World[item.key]
		if chunk then newChunks[#newChunks + 1] = chunk end
	end
	if perfEnabled then MC.StreamPerformanceAddStage( "hydrate.collect_new", ( SysTime() - collectStarted ) * 1000 ) end
	local lightEndStarted = perfEnabled and SysTime() or nil
	if lightingBatch and MC.EndPartialLightingBatch then MC.EndPartialLightingBatch( lightingBatch, newChunks, true ) end
	if perfEnabled then
		MC.StreamPerformanceAddStage( "lighting.end_partial", ( SysTime() - lightEndStarted ) * 1000 )
		MC.StreamPerformanceAddStage( "hydrate.loader_total", ( SysTime() - loaderStarted ) * 1000 )
	end
	return true, { chunks = touched, blocks = blocks }
end

function MC.LoadSnapshotSaveData( data )
	local hydrateStarted = SysTime()
	if not istable( data ) or not istable( data.chunks ) then return false end
	if data.v == 9 or data.v == 10 then
		local registryOK = validateSavedRegistryMetadata( data )
		if not registryOK then return false end
		if math.floor( tonumber( data.cs ) or -1 ) ~= MC.CS or math.floor( tonumber( data.h ) or -1 ) ~= MC.CH then return false end
	end
	local palette = data.p or data.palette
	if MC.BeginLightingBulkLoad then MC.BeginLightingBulkLoad() end
	resetClientWorldForSnapshot( #data.chunks, 0 )

	local cache = {}
	local blocks = 0
	for _, chunkData in ipairs( data.chunks ) do
		if istable( chunkData ) then
			local loaded, loadError = loadSnapshotChunk( chunkData, cache, palette, data.v == 9 or data.v == 10 )
			if loaded == nil then
				if MC.CancelLightingBulkLoad then MC.CancelLightingBulkLoad() end
				resetClientWorldForSnapshot( 0, 0 )
				return false, loadError
			end
			blocks = blocks + loaded
		elseif data.v == 9 or data.v == 10 then
			if MC.CancelLightingBulkLoad then MC.CancelLightingBulkLoad() end
			resetClientWorldForSnapshot( 0, 0 )
			return false, "invalid_snapshot_chunk"
		end
	end
	if MC.EndLightingBulkLoad then MC.EndLightingBulkLoad() end

	MC.SyncProgress.expected = blocks
	MC.SyncProgress.received = blocks
	MC.SyncProgress.doneChunks = #data.chunks
	MC.SyncProgress.active = false
	MC.SyncProgress.lastUpdate = CurTime()

	if MC.RefreshClientCollisionInterest then
		MC.RefreshClientCollisionInterest( true )
	end

	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
	if MC.RunEvent then
		MC.RunEvent( "MC.ClientWorldProjectionChanged", "native_snapshot_hydrated", {
			chunks = #data.chunks,
			blocks = blocks,
		} )
	end
	MC.NativeLoadProfile.hydrateMS = ( SysTime() - hydrateStarted ) * 1000
	MC.NativeLoadProfile.chunks = #data.chunks
	MC.NativeLoadProfile.cells = blocks

	return true
end

local function cleanHttpDataPath( path )
	path = string.Trim( tostring( path or "" ) )
	path = string.gsub( path, "\\", "/" )
	path = string.gsub( path, "^/+", "" )
	path = string.gsub( path, "%.%.+", "_" )
	return path
end

local function urlEscapePath( path )
	path = cleanHttpDataPath( path )
	return string.gsub( path, "([^%w%-%._~/])", function( c )
		return string.format( "%%%02X", string.byte( c ) )
	end )
end

local function ensureDataDirsForPath( path )
	local dir = string.GetPathFromFilename( cleanHttpDataPath( path ) )
	dir = string.gsub( dir or "", "/+$", "" )
	local built = ""
	for part in string.gmatch( dir, "[^/]+" ) do
		built = built == "" and part or ( built .. "/" .. part )
		file.CreateDir( built )
	end
end

local function parseHttpSaveJSON( raw )
	if not raw or raw == "" then return nil end
	if string.sub( raw, 1, 1 ) == "{" then return util.JSONToTable( raw ) end
	local json = util.Decompress( raw )
	return json and util.JSONToTable( json ) or nil
end

local function httpCachePath( state, relPath )
	return cleanHttpDataPath( ( state.cacheRoot or "mc/http_cache/default" ) .. "/" .. cleanHttpDataPath( relPath ) )
end

local function writeHttpCache( state, relPath, body )
	local path = httpCachePath( state, relPath )
	ensureDataDirsForPath( path )
	file.Write( path, body or "" )
end

local function httpURLForPath( state, relPath )
	return ( state.baseUrl or "" ) .. "/" .. urlEscapePath( relPath )
end

local function failHttpChunkSync( state, label, err )
	if not state or state.failed then return end
	state.failed = true
	if MC.HttpChunkSync == state then MC.HttpChunkSync = nil end

	local reason = string.Trim( tostring( label or "http" ) .. ": " .. tostring( err or "unknown" ) )
	MsgN( "[MC] HTTP chunk sync failed; falling back to server net: " .. reason )
	if MC.SyncProgress then
		MC.SyncProgress.active = false
		MC.SyncProgress.http = false
		MC.SyncProgress.lastUpdate = CurTime()
	end

	net.Start( "mc_http_failed" )
		net.WriteString( string.sub( reason, 1, 180 ) )
	net.SendToServer()
end

local function httpManifestRelativePath( state, relPath )
	relPath = cleanHttpDataPath( relPath )
	if relPath == "" then return nil end
	if string.StartWith( relPath, "mc/" ) then return relPath end
	return cleanHttpDataPath( ( state.baseDir or "" ) .. relPath )
end

local function httpPartEntryPath( entry )
	if istable( entry ) then return entry.path end
	return entry
end

local function httpPaletteEntry( state, cache, index )
	local pi = math.floor( tonumber( index ) or -1 )
	if pi < 0 then return 0, 0 end
	local cached = cache[pi]
	if cached then return cached.id, cached.orient end
	local spec = state.palette and state.palette[pi + 1]
	if not isstring( spec ) then return 0, 0 end
	local id, orient = MC.ParseBlockSpec( spec )
	id = math.floor( tonumber( id ) or 0 )
	orient = id ~= 0 and MC.NormalizeOrient( id, orient ) or 0
	cache[pi] = { id = id, orient = orient }
	return id, orient
end

local function decodeHttpLocalWithGeometry( li, chunkSize, height )
	chunkSize = math.floor( tonumber( chunkSize ) or MC.CS )
	if chunkSize <= 0 then chunkSize = MC.CS end
	li = math.floor( tonumber( li ) or -1 )
	height = math.floor( tonumber( height ) or MC.CH )
	if height <= 0 then height = MC.CH end
	local cs2 = chunkSize * chunkSize
	if li < 0 or li >= cs2 * height then return nil end
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / chunkSize )
	local lx = rem - ly * chunkSize
	return lx, ly, lz
end

local function httpChunkKeyForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function httpSavedChunkSize( state )
	local savedChunkSize = math.floor( tonumber( state and state.chunkSize ) or MC.CS )
	if savedChunkSize <= 0 then savedChunkSize = MC.CS end
	return savedChunkSize
end

local function httpSavedHeight( state )
	local savedHeight = math.floor( tonumber( state and state.height ) or MC.CH )
	if savedHeight <= 0 then savedHeight = MC.CH end
	return savedHeight
end

local function httpChunkEntriesForRuntimeKey( state, key )
	local rx, ry, rz = MC.ChunkKeyToCoords( key )
	if not state or not rx then return {} end
	local savedChunkSize = httpSavedChunkSize( state )
	local savedHeight = httpSavedHeight( state )
	local minBX, maxBX = rx * MC.CS, rx * MC.CS + MC.CS - 1
	local minBY, maxBY = ry * MC.CS, ry * MC.CS + MC.CS - 1
	local minBZ, maxBZ = rz * MC.CH, rz * MC.CH + MC.CH - 1
	local minSX, maxSX = math.floor( minBX / savedChunkSize ), math.floor( maxBX / savedChunkSize )
	local minSY, maxSY = math.floor( minBY / savedChunkSize ), math.floor( maxBY / savedChunkSize )
	local minSZ, maxSZ = math.floor( minBZ / savedHeight ), math.floor( maxBZ / savedHeight )
	local entries = {}

	for sz = minSZ, maxSZ do
		for sy = minSY, maxSY do
			for sx = minSX, maxSX do
				local savedKey = MC.ChunkKeyString( sx, sy, sz )
				local entry = state.chunkIndex and state.chunkIndex[savedKey]
				if istable( entry ) then
					entries[#entries + 1] = { key = savedKey, entry = entry }
				end
			end
		end
	end

	return entries
end

local function applyQueuedHttpDeltas( state, key )
	local queued = state.queuedDeltas and state.queuedDeltas[key]
	if not queued then return end
	state.queuedDeltas[key] = nil
	for _, cell in ipairs( queued ) do
		applyNetCell( cell.bx, cell.by, cell.bz, cell.id, cell.orient )
	end
end

local function queueHttpDelta( bx, by, bz, id, orient )
	local state = MC.HttpChunkSync
	if not state or not state.requestedKeys then return false end
	local key = httpChunkKeyForCell( bx, by, bz )
	if state.loadedKeys and state.loadedKeys[key] then return false end
	if not ( state.requestedKeys[key] or state.loadingKeys[key] or state.pendingKeys[key] ) then return false end
	state.queuedDeltas = state.queuedDeltas or {}
	state.queuedDeltas[key] = state.queuedDeltas[key] or {}
	state.queuedDeltas[key][#state.queuedDeltas[key] + 1] = {
		bx = bx,
		by = by,
		bz = bz,
		id = id,
		orient = orient,
	}
	return true
end

function MC.LoadHttpChunkRecord( key, record, partData )
	local state = MC.HttpChunkSync
	if not state or not istable( record ) or #record < 4 then return 0 end
	local srcCX = math.floor( tonumber( record[1] ) or 0 )
	local srcCY = math.floor( tonumber( record[2] ) or 0 )
	local srcCZ = math.floor( tonumber( record[3] ) or 0 )
	local cells = record[4]
	local savedChunkSize = math.floor( tonumber( partData and partData.cs ) or tonumber( state.chunkSize ) or MC.CS )
	local savedHeight = math.floor( tonumber( partData and partData.h ) or tonumber( state.height ) or MC.CH )
	local cache = {}
	local touched = {}
	local nativeBatches = {}
	local nativeBackend = activeNativeChunkBackend()
	local nativeActive = nativeBackend ~= nil
	MC.NativeChunkBulkLoading = nativeActive == true
	local blocks = 0

	local function loadOneCell( li, paletteIndex )
		local lx, ly, lz = decodeHttpLocalWithGeometry( li, savedChunkSize, savedHeight )
		if not lx then return end
		local bx = srcCX * savedChunkSize + lx
		local by = srcCY * savedChunkSize + ly
		local bz = srcCZ * savedHeight + lz
		local cx, cy, cz, nli = MC.CellToChunk( bx, by, bz )
		if not MC.LocalIndexInRange( nli ) then return end
		local id, orient = httpPaletteEntry( state, cache, paletteIndex )
		if not id or id == 0 or ( MC.IsValidBlock and not MC.IsValidBlock( id ) ) then return end
		local chunk = MC.EnsureChunk( cx, cy, cz )
		local existingState = MC.GetChunkBlockStateByLocalIndex( chunk, nli )
		if existingState and existingState ~= 0 then return end
		local normalized = MC.NormalizeOrient( id, orient )
		local stateId = MC.StateFromLegacy( id, normalized )
		if stateId == nil then return end
		if nativeActive then
			local batch = nativeBatches[chunk.key]
			if not batch then batch = {}; nativeBatches[chunk.key] = batch end
			batch[#batch + 1] = nli; batch[#batch + 1] = stateId
			chunk.count = ( chunk.count or 0 ) + 1
		else
			local changed = MC.SetChunkLocalStateRaw( chunk, nli, stateId )
			if changed ~= true then return end
		end
		touched[chunk.key] = chunk
		blocks = blocks + 1
	end

	if isstring( cells ) then
		for liText, piText in string.gmatch( cells, "([^:;]+):([^:;]*):?[^;]*;?" ) do
			loadOneCell( liText, piText )
		end
	elseif istable( cells ) then
		for i = 1, #cells, 2 do
			loadOneCell( cells[i], cells[i + 1] )
		end
	end
	MC.NativeChunkBulkLoading = false
	if nativeActive then
		for touchedKey, batch in pairs( nativeBatches ) do
			local chunk = touched[touchedKey]
			if chunk then nativeBackend.ApplyChunkCells( chunk, batch, false ) end
		end
	end

	for touchedKey, chunk in pairs( touched ) do
		if chunk.count and chunk.count > 0 then
			if MC.TouchChunkCollisionVersion then MC.TouchChunkCollisionVersion( chunk ) end
			if MC.IndexChunkLightSources then MC.IndexChunkLightSources( chunk ) end
			reviveChunkEnt( chunk )
			MC.MarkChunkDirty( touchedKey )
			local cx, cy, cz = MC.ChunkKeyToCoords( touchedKey )
			if cx then markNeighbours( cx, cy, cz ) end
			MC.MarkChunkPhysDirty( touchedKey, true )
		else
			MC.World[touchedKey] = nil
		end
	end
	return blocks
end

local function tryFinishHttpChunkLoad( state, key )
	if not state.requestedKeys[key] then return end
	local entries = state.requestedEntries and state.requestedEntries[key]
	if not istable( entries ) or #entries == 0 then return end
	local ready = {}

	for _, item in ipairs( entries ) do
		local entry = item.entry
		local partNo = math.floor( tonumber( entry and entry.part ) or 0 )
		local idx = math.floor( tonumber( entry and entry.index ) or 0 )
		local partData = state.partCache[partNo]
		if not partData then return false end
		local record = partData.chunks and partData.chunks[idx]
		if not istable( record ) then
			failHttpChunkSync( state, "chunk " .. tostring( item.key or key ), "invalid chunk index" )
			return false
		end
		ready[#ready + 1] = { record = record, partData = partData }
	end

	local blocks = 0
	for _, item in ipairs( ready ) do
		blocks = blocks + MC.LoadHttpChunkRecord( key, item.record, item.partData )
	end
	state.loadingKeys[key] = nil
	state.pendingKeys[key] = nil
	state.loadedKeys[key] = true
	if MC.MarkChunkLoaded then MC.MarkChunkLoaded( key ) end
	if blocks <= 0 and MC.IndexChunkLightSources and MC.ChunkKeyToCoords then
		local cx, cy, cz = MC.ChunkKeyToCoords( key )
		if cx then
			MC.IndexChunkLightSources( { cx = cx, cy = cy, cz = cz, key = key, blocks = {}, orients = {}, count = 0 } )
		end
	end
	state.requestedEntries[key] = nil
	beginProgressChunk( blocks )
	addProgressCells( blocks )
	finishProgressChunk( key )
	applyQueuedHttpDeltas( state, key )
	return true
end

local function processHttpPartWaiters( state, partNo )
	local waiting = state.pendingByPart[partNo]
	if not waiting then return end
	state.pendingByPart[partNo] = nil
	local partData = state.partCache[partNo]
	if not partData or not istable( partData.chunks ) then return end
	for key in pairs( waiting ) do
		tryFinishHttpChunkLoad( state, key )
	end
end

local function fetchHttpPart( state, partNo )
	partNo = math.floor( tonumber( partNo ) or 0 )
	if partNo <= 0 or state.partCache[partNo] or state.loadingParts[partNo] then return end
	local partPath = httpManifestRelativePath( state, httpPartEntryPath( state.parts and state.parts[partNo] ) )
	if not partPath then return end
	state.loadingParts[partNo] = true
	http.Fetch( httpURLForPath( state, partPath ), function( body )
		if MC.HttpChunkSync ~= state then return end
		state.loadingParts[partNo] = nil
		writeHttpCache( state, partPath, body )
		local data = parseHttpSaveJSON( body )
		if not istable( data ) or not istable( data.chunks ) then
			failHttpChunkSync( state, "part " .. tostring( partPath ), "invalid payload" )
			return
		end
		data.cs = data.cs or state.chunkSize
		data.h = data.h or state.height
		data.p = data.p or state.palette
		state.partCache[partNo] = data
		processHttpPartWaiters( state, partNo )
	end, function( err )
		if MC.HttpChunkSync ~= state then return end
		state.loadingParts[partNo] = nil
		failHttpChunkSync( state, "part " .. tostring( partPath ), err )
	end )
end

function MC.QueueHttpChunk( key )
	local state = MC.HttpChunkSync
	if not state then return false end
	key = tostring( key or "" )
	if key == "" or state.loadedKeys[key] then return true end
	state.requestedKeys[key] = true
	if not state.ready then
		state.pendingKeys[key] = true
		return true
	end
	local entries = httpChunkEntriesForRuntimeKey( state, key )
	if #entries == 0 then
		state.requestedKeys[key] = nil
		return false
	end
	state.requestedEntries[key] = entries
	state.loadingKeys[key] = true
	state.pendingKeys[key] = true

	for _, item in ipairs( entries ) do
		local entry = item.entry
		local partNo = math.floor( tonumber( entry and entry.part ) or 0 )
		local idx = math.floor( tonumber( entry and entry.index ) or 0 )
		if partNo <= 0 or idx <= 0 then
			state.requestedKeys[key] = nil
			state.loadingKeys[key] = nil
			state.pendingKeys[key] = nil
			state.requestedEntries[key] = nil
			return false
		end
		if not state.partCache[partNo] then
			state.pendingByPart[partNo] = state.pendingByPart[partNo] or {}
			state.pendingByPart[partNo][key] = true
			fetchHttpPart( state, partNo )
		end
	end
	tryFinishHttpChunkLoad( state, key )
	return true
end

local function finishHttpManifest( state, body )
	local data = parseHttpSaveJSON( body )
	if not istable( data ) or not istable( data.parts ) or not istable( data.chunkIndex ) then
		failHttpChunkSync( state, "manifest", "invalid payload" )
		return
	end
	writeHttpCache( state, state.manifestPath, body )
	state.manifest = data
	state.palette = data.p or data.palette or {}
	state.chunkIndex = data.chunkIndex or {}
	state.parts = data.parts or {}
	state.chunkSize = math.floor( tonumber( data.cs ) or tonumber( state.chunkSize ) or MC.CS )
	state.height = math.floor( tonumber( data.h ) or tonumber( state.height ) or MC.CH )
	state.ready = true
	local pending = {}
	for key in pairs( state.pendingKeys ) do
		pending[#pending + 1] = key
	end
	for _, key in ipairs( pending ) do
		MC.QueueHttpChunk( key )
	end
end

function MC.BeginHttpChunkSync( baseUrl, manifestPath, chunks, blocks, height )
	baseUrl = string.Trim( tostring( baseUrl or "" ) )
	baseUrl = string.gsub( baseUrl, "/+$", "" )
	manifestPath = cleanHttpDataPath( manifestPath )
	if baseUrl == "" or manifestPath == "" then return false end
	local token = util.CRC( baseUrl .. "|" .. manifestPath )
	local state = {
		baseUrl = baseUrl,
		manifestPath = manifestPath,
		baseDir = string.GetPathFromFilename( manifestPath ),
		cacheRoot = "mc/http_cache/" .. token,
		chunkSize = MC.CS,
		height = math.floor( tonumber( height ) or MC.CH ),
		palette = {},
		chunkIndex = {},
		parts = {},
		partCache = {},
		loadingParts = {},
		pendingByPart = {},
		pendingKeys = {},
		requestedKeys = {},
		loadingKeys = {},
		loadedKeys = {},
		requestedEntries = {},
		queuedDeltas = {},
		ready = false,
	}
	MC.HttpChunkSync = state
	resetClientWorldForSnapshot( 0, 0 )
	MC.SyncProgress.http = true
	MC.SyncProgress.snapshot = false
	MC.SyncProgress.httpTotalChunks = math.max( 0, math.floor( tonumber( chunks ) or 0 ) )
	MC.SyncProgress.httpTotalBlocks = math.max( 0, math.floor( tonumber( blocks ) or 0 ) )
	http.Fetch( httpURLForPath( state, manifestPath ), function( body )
		if MC.HttpChunkSync == state then finishHttpManifest( state, body ) end
	end, function( err )
		if MC.HttpChunkSync == state then
			failHttpChunkSync( state, "manifest", err )
		end
	end )
	return true
end

net.Receive( "mc_http_manifest", function()
	local baseUrl = net.ReadString()
	local manifestPath = net.ReadString()
	local chunks = net.ReadUInt( 32 )
	local blocks = net.ReadUInt( 32 )
	local height = net.ReadUInt( 16 )
	MC.BeginHttpChunkSync( baseUrl, manifestPath, chunks, blocks, height )
end )

net.Receive( "mc_http_chunk", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	MC.QueueHttpChunk( MC.ChunkKey( cx, cy, cz ) )
end )

net.Receive( "mc_http_chunk_bulk", function()
	local count = net.ReadUInt( Net.COUNT_BITS )
	for _ = 1, count do
		local cx = net.ReadInt( Net.COORD_BITS )
		local cy = net.ReadInt( Net.COORD_BITS )
		local cz = net.ReadInt( Net.COORD_BITS )
		MC.QueueHttpChunk( MC.ChunkKey( cx, cy, cz ) )
	end
end )

net.Receive( "mc_set", function()
	local bx = net.ReadInt( Net.COORD_BITS )
	local by = net.ReadInt( Net.COORD_BITS )
	local bz = net.ReadInt( Net.COORD_BITS )
	local id = net.ReadUInt( Net.ID_BITS )
	local orient = net.ReadUInt( Net.ORIENT_BITS )

	if queueHttpDelta( bx, by, bz, id, orient ) then return end
	applyNetCell( bx, by, bz, id, orient )
end )

local function receiveSetBulk()
	local count = net.ReadUInt( Net.COUNT_BITS )
	local changes = {}
	for _ = 1, count do
		local bx = net.ReadInt( Net.COORD_BITS )
		local by = net.ReadInt( Net.COORD_BITS )
		local bz = net.ReadInt( Net.COORD_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )

		changes[#changes + 1] = {
			bx = bx, by = by, bz = bz,
			id = id, orient = orient,
		}
	end

	local meshRateLimited = net.ReadBool()
	-- netPaced bulk messages carry a trailing UInt32 of their reliable byte cost;
	-- ack it so the server releases its per-player in-flight window. Plain
	-- (non-paced) mc_set_bulk_fast messages omit the field, so guard on BytesLeft.
	if net.BytesLeft() >= 4 then
		queueReliableAck( net.ReadUInt( 32 ) )
	end
	local applied = {}
	for _, cell in ipairs( changes ) do
		if not queueHttpDelta( cell.bx, cell.by, cell.bz, cell.id, cell.orient ) then
			applied[#applied + 1] = cell
		end
	end
	applyNetCellsBulk( applied, meshRateLimited )
end

net.Receive( "mc_set_bulk", receiveSetBulk )
net.Receive( "mc_set_bulk_fast", receiveSetBulk )

MC.StreamProfile = MC.StreamProfile or { patch = {}, unload = {} }

-- Detached cleanup is a sparse FIFO: consumed entries are nilled while newer
-- entries remain at higher numeric indices. Never use # or ipairs on it.
MC.StreamCleanupQueue = MC.StreamCleanupQueue or {}
MC.StreamCleanupHead = MC.StreamCleanupHead or 1
if MC.StreamCleanupTail == nil then
	local tail = 0
	for index in pairs( MC.StreamCleanupQueue ) do
		if isnumber( index ) and index > tail then tail = index end
	end
	MC.StreamCleanupTail = tail
end
local streamCleanupPendingByKey = {}
MC.StreamCleanupPending = 0
for index = MC.StreamCleanupHead, MC.StreamCleanupTail do
	local item = MC.StreamCleanupQueue[index]
	if item and not item.done then
		MC.StreamCleanupPending = MC.StreamCleanupPending + 1
		streamCleanupPendingByKey[item.key] = ( streamCleanupPendingByKey[item.key] or 0 ) + 1
	end
end

local function newStreamPerfAggregate()
	return { count = 0, totalMS = 0, maxMS = 0, lastMS = 0 }
end

local function streamPerfCopy( value, seen )
	if not istable( value ) then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local copy = {}
	seen[value] = copy
	for key, item in pairs( value ) do copy[streamPerfCopy( key, seen )] = streamPerfCopy( item, seen ) end
	return copy
end

local function streamPerfQueueDepths()
	local geometryKeys, geometrySections, lightKeys, lightSections = 0, 0, 0, 0
	for _, sections in pairs( MC.MeshDirty or {} ) do
		geometryKeys = geometryKeys + 1
		geometrySections = geometrySections + ( sections == true and ( MC.RENDER_SECTION_COUNT or 1 ) or table.Count( sections ) )
	end
	for _, sections in pairs( MC.MeshLightDirty or {} ) do
		lightKeys = lightKeys + 1
		lightSections = lightSections + ( sections == true and ( MC.RENDER_SECTION_COUNT or 1 ) or table.Count( sections ) )
	end
	local collision = 0
	local order, head, bulk = MC.PhysDirtyBulkOrder or {}, MC.PhysDirtyBulkOrderHead or 1, MC.PhysDirtyBulk or {}
	for index = head, #order do
		local key = order[index]
		if bulk[key] and MC.PhysDirty and MC.PhysDirty[key] then collision = collision + 1 end
	end
	local cleanup = math.max( 0, MC.StreamCleanupPending or 0 )
	return {
		geometryKeys = geometryKeys, geometrySections = geometrySections,
		lightKeys = lightKeys, lightSections = lightSections,
		collision = collision, cleanup = cleanup,
	}
end

local function newStreamPerformanceState( options )
	options = istable( options ) and options or {}
	return {
		enabled = true,
		startedAt = SysTime(),
		maxPatches = math.Clamp( math.floor( tonumber( options.maxPatches ) or 32 ), 1, 128 ),
		maxFrames = math.Clamp( math.floor( tonumber( options.maxAftermathFrames ) or 256 ), 16, 2048 ),
		stages = {}, counters = {}, failures = {}, patches = {}, patchByRevision = {}, frames = {},
		frameStages = {}, frameOrder = {}, latestCompletedFrame = nil,
		cleanup = {
			enqueued = 0, drained = 0, cleaned = 0, staleToken = 0, reloaded = 0,
			synchronous = 0, duplicate = 0, nativeOnly = 0, retainedChunks = 0,
			pending = 0, peakPending = 0,
		},
		memory = { baselineKB = 0, currentKB = 0, peakKB = 0, possibleNaturalGC = 0 },
		peaks = streamPerfQueueDepths(), latestQueues = streamPerfQueueDepths(),
		activeStage = nil, appliedPatches = 0, decodedPatches = 0, successfulPatches = 0,
		totalBytes = 0, totalChunks = 0, totalCells = 0, overlapped = false,
	}
end

MC.StreamPerformanceStats = MC.StreamPerformanceStats or newStreamPerformanceState()
MC.StreamPerformanceStats.enabled = false

function MC.StreamPerformanceEnabled()
	return MC.StreamPerformanceStats and MC.StreamPerformanceStats.enabled == true
end

function MC.ResetStreamPerformanceStats( options )
	MC.StreamPerformanceStats = newStreamPerformanceState( options )
	local state = MC.StreamPerformanceStats
	local memory = state.memory
	memory.baselineKB = collectgarbage( "count" )
	memory.currentKB, memory.peakKB = memory.baselineKB, memory.baselineKB
	local queue, head, tail = MC.StreamCleanupQueue or {}, MC.StreamCleanupHead or 1, MC.StreamCleanupTail or 0
	state.cleanup.pending = math.max( 0, MC.StreamCleanupPending or 0 )
	state.cleanup.peakPending = state.cleanup.pending
	for index = head, tail do
		local item = queue[index]
		if item and not item.done and item.chunk then state.cleanup.retainedChunks = state.cleanup.retainedChunks + 1 end
	end
	return true
end

function MC.SetStreamPerformanceEnabled( enabled )
	local state = MC.StreamPerformanceStats
	if not state then state = newStreamPerformanceState(); MC.StreamPerformanceStats = state end
	state.enabled = enabled == true
	if not state.enabled then state.stoppedAt = SysTime() end
	return state.enabled
end

function MC.StreamPerformanceAddStage( name, ms, counters )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	name, ms = tostring( name or "unknown" ), math.max( 0, tonumber( ms ) or 0 )
	local aggregate = state.stages[name]
	if not aggregate then aggregate = newStreamPerfAggregate(); state.stages[name] = aggregate end
	aggregate.count = aggregate.count + 1
	aggregate.totalMS = aggregate.totalMS + ms
	aggregate.lastMS = ms
	if ms > aggregate.maxMS then aggregate.maxMS = ms end
	for key, value in pairs( counters or {} ) do
		if isnumber( value ) then state.counters[key] = ( state.counters[key] or 0 ) + value end
	end
end

local function finalizeStreamPerformanceFrame( state, frame )
	if not frame or frame.finalized then return end
	frame.finalized = true
	frame.memoryKB = collectgarbage( "count" )
	local memory = state.memory
	local previousKB = memory.currentKB > 0 and memory.currentKB or memory.baselineKB
	frame.memoryDeltaKB = frame.memoryKB - previousKB
	memory.currentKB = frame.memoryKB
	memory.peakKB = math.max( memory.peakKB or 0, frame.memoryKB )
	if frame.memoryDeltaKB < -64 then
		frame.possibleNaturalGC = true
		memory.possibleNaturalGC = ( memory.possibleNaturalGC or 0 ) + 1
	end
	local cleanup = state.cleanup or {}
	frame.cleanupPending = cleanup.pending or 0
	frame.cleanupRetainedChunks = cleanup.retainedChunks or 0
	frame.cleanupEnqueued = cleanup.enqueued or 0
	frame.cleanupDrained = cleanup.drained or 0
	frame.collision = streamPerfQueueDepths().collision
	state.latestCompletedFrame = frame
end

function MC.StreamPerformanceAddFrameStage( name, ms, counters )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	local number = FrameNumber and FrameNumber() or 0
	local frame = state.frameStages[number]
	if not frame then
		local previousNumber = state.frameOrder[#state.frameOrder]
		if previousNumber ~= nil then finalizeStreamPerformanceFrame( state, state.frameStages[previousNumber] ) end
		frame = { number = number, stages = {}, measuredMCMS = 0 }
		state.frameStages[number] = frame
		state.frameOrder[#state.frameOrder + 1] = number
		while #state.frameOrder > 4 do
			local removed = table.remove( state.frameOrder, 1 )
			if removed ~= number and state.latestCompletedFrame ~= state.frameStages[removed] then state.frameStages[removed] = nil end
		end
	end
	name, ms = tostring( name or "unknown" ), math.max( 0, tonumber( ms ) or 0 )
	frame.stages[name] = ( frame.stages[name] or 0 ) + ms
	frame.measuredMCMS = frame.measuredMCMS + ms
	for key, value in pairs( counters or {} ) do
		if isnumber( value ) then frame[key] = ( frame[key] or 0 ) + value end
	end
end

function MC.StreamPerformanceLatestCompletedFrame()
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return nil end
	return state.latestCompletedFrame
end

function MC.StreamPerformanceSetStage( name )
	local state = MC.StreamPerformanceStats
	if state and state.enabled then state.activeStage = name end
end

function MC.StreamPerformancePatchBegin( metadata )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	local revision = tonumber( metadata and metadata.revision ) or -1
	local record = {
		generation = metadata and metadata.generation, revision = revision,
		bytes = metadata and metadata.totalBytes or 0, parts = metadata and metadata.partCount or 0,
		chunks = metadata and metadata.chunkCount or 0, cells = metadata and metadata.cellCount or 0,
		beganAt = SysTime(), status = "receiving", stages = {},
	}
	state.patchByRevision[revision] = record
	state.patches[#state.patches + 1] = record
	while #state.patches > state.maxPatches do
		local removed = table.remove( state.patches, 1 )
		if removed and state.patchByRevision[removed.revision] == removed then state.patchByRevision[removed.revision] = nil end
	end
end

function MC.StreamPerformancePatchStage( revision, name, ms )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	MC.StreamPerformanceAddStage( "patch." .. tostring( name ), ms )
	local record = state.patchByRevision[tonumber( revision )]
	if record then record.stages[name] = ( record.stages[name] or 0 ) + math.max( 0, tonumber( ms ) or 0 ) end
end

function MC.StreamPerformancePatchDecoded( revision )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	local record = state.patchByRevision[tonumber( revision )]
	if not record then return end
	record.decodedAt, record.status = SysTime(), "decoded_waiting_revision"
	state.decodedPatches = state.decodedPatches + 1
	state.totalBytes = state.totalBytes + ( record.bytes or 0 )
	state.totalChunks = state.totalChunks + ( record.chunks or 0 )
	state.totalCells = state.totalCells + ( record.cells or 0 )
end

function MC.StreamPerformancePatchApplied( revision, success, reason )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	local now = SysTime()
	local record = state.patchByRevision[tonumber( revision )]
	if record then
		record.appliedAt = now
		record.status = success == true and "aftermath_pending" or "apply_failed"
		record.error = reason
	end
	state.appliedPatches = state.appliedPatches + 1
	if success == true then state.successfulPatches = state.successfulPatches + 1
	else state.failures[tostring( reason or "apply_failed" )] = ( state.failures[tostring( reason or "apply_failed" )] or 0 ) + 1 end
	if state.aftermathStartedAt then state.overlapped = true end
	state.aftermathStartedAt = state.aftermathStartedAt or now
	state.latestQueues = streamPerfQueueDepths()
	for key, value in pairs( state.latestQueues ) do state.peaks[key] = math.max( state.peaks[key] or 0, value ) end
end

function MC.StreamPerformancePatchFailure( revision, reason )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	local record = state.patchByRevision[tonumber( revision )]
	if record then record.status, record.error = "decode_failed", tostring( reason or "unknown" ) end
	state.failures[tostring( reason or "unknown" )] = ( state.failures[tostring( reason or "unknown" )] or 0 ) + 1
end

function MC.StreamPerformanceRecordAftermathFrame( sample )
	local state = MC.StreamPerformanceStats
	if not state or not state.enabled then return end
	sample = istable( sample ) and sample or {}
	sample.time = SysTime()
	sample.queues = streamPerfQueueDepths()
	state.latestQueues = sample.queues
	for key, value in pairs( sample.queues ) do state.peaks[key] = math.max( state.peaks[key] or 0, value ) end
	state.frames[#state.frames + 1] = sample
	while #state.frames > state.maxFrames do table.remove( state.frames, 1 ) end
	if state.aftermathStartedAt and sample.queues.geometryKeys == 0 and sample.queues.lightKeys == 0
	and sample.queues.collision == 0 and sample.queues.cleanup == 0 then
		state.lastDrainMS = ( sample.time - state.aftermathStartedAt ) * 1000
		state.aftermathStartedAt = nil
		for _, record in ipairs( state.patches ) do
			if record.status == "aftermath_pending" then record.status, record.drainedAt = "completed_drained", sample.time end
		end
	end
end

function MC.GetStreamPerformanceSnapshot()
	local state = MC.StreamPerformanceStats or {}
	local copy = streamPerfCopy( state )
	copy.patchByRevision = nil
	copy.elapsedMS = ( ( state.stoppedAt or SysTime() ) - ( state.startedAt or SysTime() ) ) * 1000
	copy.latestQueues = streamPerfQueueDepths()
	return copy
end

function MC.GetStreamPerformanceSummary()
	local snapshot = MC.GetStreamPerformanceSnapshot()
	local summary = {
		enabled = snapshot.enabled == true, elapsedMS = snapshot.elapsedMS or 0,
		decodedPatches = snapshot.decodedPatches or 0, appliedPatches = snapshot.appliedPatches or 0,
		successfulPatches = snapshot.successfulPatches or 0, totalBytes = snapshot.totalBytes or 0,
		totalChunks = snapshot.totalChunks or 0, totalCells = snapshot.totalCells or 0,
		stages = {}, counters = snapshot.counters or {}, failures = snapshot.failures or {},
		peaks = snapshot.peaks or {}, latestQueues = snapshot.latestQueues or {},
		lastDrainMS = snapshot.lastDrainMS, overlapped = snapshot.overlapped == true,
	}
	for name, aggregate in pairs( snapshot.stages or {} ) do
		summary.stages[name] = {
			count = aggregate.count or 0, totalMS = aggregate.totalMS or 0,
			averageMS = ( aggregate.count or 0 ) > 0 and ( aggregate.totalMS or 0 ) / aggregate.count or 0,
			maxMS = aggregate.maxMS or 0, lastMS = aggregate.lastMS or 0,
		}
	end
	return summary
end

MC.StreamHiddenChunkKeys = MC.StreamHiddenChunkKeys or {}
MC.StreamDetachTokens = MC.StreamDetachTokens or {}

function MC.SetStreamChunkHidden( key, hidden )
	if not key then return end
	if ( MC.StreamHiddenChunkKeys[key] == true ) ~= ( hidden == true ) then
		MC.StreamVisibilityVersion = ( MC.StreamVisibilityVersion or 0 ) + 1
	end
	if hidden and MC.RenderOcclusion then MC.RenderOcclusion.Forget( key ) end
	MC.StreamHiddenChunkKeys[key] = hidden and true or nil
	local backend = MC.NativeChunkBackend
	if backend and backend.SetChunkVisible then backend.SetChunkVisible( key, not hidden ) end
end

local function streamCleanupPerf()
	local state = MC.StreamPerformanceStats
	return state and state.enabled and state.cleanup or nil
end

local function noteCleanupEnqueued( key, chunk, nativeOnly )
	MC.StreamCleanupPending = ( MC.StreamCleanupPending or 0 ) + 1
	local duplicate = ( streamCleanupPendingByKey[key] or 0 ) > 0
	streamCleanupPendingByKey[key] = ( streamCleanupPendingByKey[key] or 0 ) + 1
	local perf = streamCleanupPerf()
	if not perf then return end
	perf.enqueued = perf.enqueued + 1
	perf.pending = perf.pending + 1
	perf.peakPending = math.max( perf.peakPending, perf.pending )
	if chunk then perf.retainedChunks = perf.retainedChunks + 1 end
	if nativeOnly then perf.nativeOnly = perf.nativeOnly + 1 end
	if duplicate then perf.duplicate = perf.duplicate + 1 end
end

local function noteCleanupConsumed( item, reason, synchronous )
	if not item then return end
	MC.StreamCleanupPending = math.max( 0, ( MC.StreamCleanupPending or 0 ) - 1 )
	local count = math.max( 0, ( streamCleanupPendingByKey[item.key] or 1 ) - 1 )
	streamCleanupPendingByKey[item.key] = count > 0 and count or nil
	local perf = streamCleanupPerf()
	if not perf then return end
	perf.drained = perf.drained + 1
	if reason == "cleaned" then perf.cleaned = perf.cleaned + 1
	elseif reason == "stale_token" then perf.staleToken = perf.staleToken + 1
	elseif reason == "reloaded" then perf.reloaded = perf.reloaded + 1 end
	if synchronous then perf.synchronous = perf.synchronous + 1 end
	perf.pending = math.max( 0, perf.pending - 1 )
	if item.chunk then perf.retainedChunks = math.max( 0, perf.retainedChunks - 1 ) end
end

if CreateClientConVar then
	MC.StreamUnloadFrameMS = MC.StreamUnloadFrameMS or CreateClientConVar( "mc_stream_unload_frame_ms", "3", true, false,
		"Milliseconds per frame for detached streaming chunk cleanup", 2, 4 )
	MC.StreamUnloadChunksPerFrame = MC.StreamUnloadChunksPerFrame or CreateClientConVar( "mc_stream_unload_chunks_per_frame", "1", true, false,
		"Detached streaming chunks cleaned per frame", 1, 2 )
	MC.StreamProfileDebug = MC.StreamProfileDebug or CreateClientConVar( "mc_stream_profile_debug", "0", true, false,
		"Print dynamic streaming patch and unload frame profiles" )
end

local function cleanupDetachedChunk( item )
	if not item then return false, "invalid" end
	if MC.StreamDetachTokens[item.key] ~= item.token then return false, "stale_token" end
	if MC.World[item.key] ~= nil then return false, "reloaded" end
	local key, cx, cy, cz = item.key, item.cx, item.cy, item.cz
	MC.FreeChunkMesh( key )
	if MC.EvictChunkDrawMatrix then MC.EvictChunkDrawMatrix( key ) end
	if MC.ClearGpuChunkLightTexture then MC.ClearGpuChunkLightTexture( key ) end
	local e = MC.ChunkEnts and MC.ChunkEnts[key]
	if IsValid( e ) then
		if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
		if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
		e:PhysicsDestroy()
	end
	if MC.ChunkEnts then MC.ChunkEnts[key] = nil end
	if MC.RebuildChunkPhys then MC.RebuildChunkPhys( key, false ) end
	MC.MeshDirty[key], MC.MeshLightDirty[key] = nil, nil
	if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	if MC.MeshLightDirtyRateLimited then MC.MeshLightDirtyRateLimited[key] = nil end
	MC.PhysDirty[key], MC.PhysDirtyPriority[key] = nil, nil
	if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
	if MC.ClientPhysBuiltSignatures then MC.ClientPhysBuiltSignatures[key] = nil end
	if MC.ClientPhysBuiltHadObjects then MC.ClientPhysBuiltHadObjects[key] = nil end
	if MC.ClientPhysBuiltObjectCounts then MC.ClientPhysBuiltObjectCounts[key] = nil end
	if MC.ClientPhysTargetSignatures then MC.ClientPhysTargetSignatures[key] = nil end
	MC.SetStreamChunkHidden( key, false )
	return true, "cleaned"
end

function MC.FlushDetachedChunkCleanupForKeys( keys )
	local lightOld = {}
	local queue = MC.StreamCleanupQueue or {}
	for index = MC.StreamCleanupHead or 1, MC.StreamCleanupTail or 0 do
		local item = queue[index]
		if item and keys[item.key] and not item.done then
			item.done = true
			if item.chunk then lightOld[#lightOld + 1] = item.chunk end
			local _, reason = cleanupDetachedChunk( item )
			noteCleanupConsumed( item, reason, true )
			queue[index] = nil
		end
	end
	local head, tail = MC.StreamCleanupHead or 1, MC.StreamCleanupTail or 0
	while head <= tail and queue[head] == nil do head = head + 1 end
	MC.StreamCleanupHead = head
	if head > tail then
		MC.StreamCleanupQueue, MC.StreamCleanupHead, MC.StreamCleanupTail = {}, 1, 0
	end
	if #lightOld > 0 and MC.BeginPartialLightingBatch and MC.EndPartialLightingBatch then
		local batch = MC.BeginPartialLightingBatch( lightOld )
		MC.EndPartialLightingBatch( batch, {}, true )
	end
end

function MC.ResetStreamCleanupState()
	local backend = MC.NativeChunkBackend
	if backend and backend.SetChunkVisible then
		for key in pairs( MC.StreamHiddenChunkKeys or {} ) do backend.SetChunkVisible( key, true ) end
	end
	MC.StreamHiddenChunkKeys, MC.StreamDetachTokens, MC.StreamCleanupQueue = {}, {}, {}
	MC.StreamCleanupHead, MC.StreamCleanupTail, MC.StreamCleanupPending = 1, 0, 0
	streamCleanupPendingByKey = {}
	local perf = streamCleanupPerf()
	if perf then
		perf.pending, perf.retainedChunks = 0, 0
	end
end

function MC.UnloadClientChunks( chunks )
	if not istable( chunks ) or #chunks == 0 then return 0 end
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local perfStarted = perfEnabled and SysTime() or nil
	local memoryBefore = perfEnabled and collectgarbage( "count" ) or nil
	local unloading, oldChunks, neighbours = {}, {}, {}
	for _, coords in ipairs( chunks ) do
		local cx, cy, cz = coords.cx, coords.cy, coords.cz
		if isnumber( cx ) and isnumber( cy ) and isnumber( cz ) then unloading[MC.ChunkKey( cx, cy, cz )] = true end
	end
	for _, coords in ipairs( chunks ) do
		local cx, cy, cz = coords.cx, coords.cy, coords.cz
		local key = MC.ChunkKey( cx, cy, cz )
		local chunk = MC.World[key]
		MC.World[key] = nil
		if MC.MarkChunkUnloaded then MC.MarkChunkUnloaded( key ) end
		MC.SetStreamChunkHidden( key, true )
		local token = ( MC.StreamDetachTokens[key] or 0 ) + 1
		MC.StreamDetachTokens[key] = token
		if chunk then oldChunks[#oldChunks + 1] = chunk end
		local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
		local nativeMayOwn = backend and backend.native == true and ( not backend.IsActive or backend.IsActive() == true )
		local hasResources = chunk ~= nil
			or MC.Meshes[key] ~= nil or MC.MeshesTrans[key] ~= nil
			or MC.MeshSections and MC.MeshSections[key] ~= nil
			or MC.ChunkEnts and MC.ChunkEnts[key] ~= nil
			or MC.GpuChunkLightDirtyChunks and MC.GpuChunkLightDirtyChunks[key] ~= nil
			or MC.GpuChunkLightDirtyCells and MC.GpuChunkLightDirtyCells[key] ~= nil
			or MC.LightBlockChunks and MC.LightBlockChunks[key] ~= nil
			or MC.LightSkyChunks and MC.LightSkyChunks[key] ~= nil
			or MC.ClientPhysBuiltSignatures and MC.ClientPhysBuiltSignatures[key] ~= nil
			or MC.ClientPhysBuiltHadObjects and MC.ClientPhysBuiltHadObjects[key] ~= nil
			or MC.ClientPhysBuiltObjectCounts and MC.ClientPhysBuiltObjectCounts[key] ~= nil
			or MC.ClientPhysTargetSignatures and MC.ClientPhysTargetSignatures[key] ~= nil
			or nativeMayOwn
		if hasResources then
			local tail = ( MC.StreamCleanupTail or 0 ) + 1
			MC.StreamCleanupTail = tail
			MC.StreamCleanupQueue[tail] = { key = key, cx = cx, cy = cy, cz = cz, token = token, chunk = chunk }
			noteCleanupEnqueued( key, chunk, nativeMayOwn and chunk == nil
				and MC.Meshes[key] == nil and MC.MeshesTrans[key] == nil
				and ( not MC.MeshSections or MC.MeshSections[key] == nil )
				and ( not MC.ChunkEnts or MC.ChunkEnts[key] == nil ) )
		else
			MC.SetStreamChunkHidden( key, false )
		end
		for _, d in ipairs( { {1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1} } ) do
			local neighbour = MC.ChunkKey( cx + d[1], cy + d[2], cz + d[3] )
			if not unloading[neighbour] and MC.GetChunkByKey( neighbour ) then
				neighbours[neighbour] = { cx = cx + d[1], cy = cy + d[2], cz = cz + d[3], dx = -d[1], dy = -d[2], dz = -d[3] }
			end
		end
	end
	for key, face in pairs( neighbours ) do
		local cx, cy, cz, dx, dy, dz = face.cx, face.cy, face.cz, face.dx, face.dy, face.dz
		local minX, minY, minZ = cx * MC.CS, cy * MC.CS, cz * MC.CH
		local maxX, maxY, maxZ = minX + MC.CS - 1, minY + MC.CS - 1, minZ + MC.CH - 1
		if dx == 1 then minX = maxX elseif dx == -1 then maxX = minX end
		if dy == 1 then minY = maxY elseif dy == -1 then maxY = minY end
		if dz == 1 then minZ = maxZ elseif dz == -1 then maxZ = minZ end
		if MC.MarkRenderSectionsDirtyInBounds then MC.MarkRenderSectionsDirtyInBounds( minX, minY, minZ, maxX, maxY, maxZ )
		elseif MC.MarkChunkDirty then MC.MarkChunkDirty( key ) end
		if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = true end
	end
	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
	if MC.RunEvent then
		MC.RunEvent( "MC.ClientWorldProjectionChanged", "chunks_unloaded", { chunks = #chunks } )
	end
	if MC.ClearAllBlockConnectionMaskCaches then MC.ClearAllBlockConnectionMaskCaches() end
	if perfEnabled then
		local elapsed = ( SysTime() - perfStarted ) * 1000
		local memoryDelta = collectgarbage( "count" ) - memoryBefore
		MC.StreamPerformanceAddStage( "cleanup.enqueue", elapsed, { cleanupUnloadCoords = #chunks, cleanupEnqueueMemoryKB = memoryDelta } )
		MC.StreamPerformanceAddFrameStage( "cleanup.enqueue", elapsed, { cleanupUnloadCoords = #chunks, cleanupEnqueueMemoryKB = memoryDelta } )
	end
	return #chunks
end

hook.Remove( "Think", "mc_stream_detached_cleanup" )
hook.Add( "Think", "mc_stream_detached_cleanup", function()
	local queue, head, tail = MC.StreamCleanupQueue or {}, MC.StreamCleanupHead or 1, MC.StreamCleanupTail or 0
	if head > tail then return end
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local memoryBefore = perfEnabled and collectgarbage( "count" ) or nil
	local started = SysTime()
	local ms = MC.StreamUnloadFrameMS and MC.StreamUnloadFrameMS:GetFloat() or 3
	local limit = MC.StreamUnloadChunksPerFrame and MC.StreamUnloadChunksPerFrame:GetInt() or 1
	local processed, lightOld = 0, {}
	while head <= tail and processed < math.Clamp( limit, 1, 2 ) do
		local item = queue[head]; queue[head] = nil; head = head + 1
		if item and not item.done then
			if item.chunk then lightOld[#lightOld + 1] = item.chunk end
			local _, reason = cleanupDetachedChunk( item )
			noteCleanupConsumed( item, reason, false )
		end
		processed = processed + 1
		if processed > 0 and SysTime() >= started + math.Clamp( ms, 2, 4 ) / 1000 then break end
	end
	if #lightOld > 0 and MC.BeginPartialLightingBatch and MC.EndPartialLightingBatch then
		local lightingBatch = MC.BeginPartialLightingBatch( lightOld )
		MC.EndPartialLightingBatch( lightingBatch, {}, true )
	end
	MC.StreamCleanupHead = head
	local elapsed = ( SysTime() - started ) * 1000
	MC.StreamProfile.unload = { ms = elapsed, chunks = processed, remaining = math.max( 0, MC.StreamCleanupPending or 0 ) }
	if perfEnabled then
		local memoryDelta = collectgarbage( "count" ) - memoryBefore
		MC.StreamPerformanceAddStage( "cleanup.drain", elapsed, { cleanupDrained = processed, cleanupDrainMemoryKB = memoryDelta } )
		MC.StreamPerformanceAddFrameStage( "cleanup.drain", elapsed, { cleanupDrained = processed, cleanupDrainMemoryKB = memoryDelta } )
	end
	if MC.StreamProfileDebug and MC.StreamProfileDebug:GetBool() and elapsed >= 8 then
		print( string.format( "[MC stream] unload frame %.2fms chunks=%d", elapsed, processed ) )
	end
	if head > tail then
		MC.StreamCleanupQueue, MC.StreamCleanupHead, MC.StreamCleanupTail = {}, 1, 0
	end
end )

function MC.UnloadClientChunk( cx, cy, cz )
	return MC.UnloadClientChunks( { { cx = cx, cy = cy, cz = cz } } )
end

net.Receive( "mc_unload_chunk", function()
	MC.UnloadClientChunk( net.ReadInt( Net.COORD_BITS ), net.ReadInt( Net.COORD_BITS ), net.ReadInt( Net.COORD_BITS ) )
end )

net.Receive( "mc_clear", function()
	MC.FreeAllMeshes()
	if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	-- The world is emptied below: wipe lighting caches directly instead of
	-- MarkAllMeshesDirty (which would re-flood block light on the old world),
	-- and drop the sky column tops — otherwise pre-clear terrain keeps
	-- shading the now-empty space (entities sampled sky=0 under phantom
	-- column tops until a chunk load happened to cover them).
	if MC.ClearLightingCache then MC.ClearLightingCache() end
	if MC.ClearSkyColumnCache then MC.ClearSkyColumnCache() end
	for key, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then
			if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
			if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
			e:PhysicsDestroy()
		end
	end
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
	MC.ClientCollisionAABBDebugBoxes = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
	MC.PendingPredictions = {}
	MC.PendingPredictionGroups = {}
	MC.HttpChunkSync = nil
	if MC.MarkSignRenderEntriesDirty then MC.MarkSignRenderEntriesDirty() end
	if MC.MarkBannerRenderEntriesDirty then MC.MarkBannerRenderEntriesDirty() end
	if MC.RunEvent then MC.RunEvent( "MC.ClientWorldProjectionChanged", "world_cleared", {} ) end
	MC.SyncProgress = { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = CurTime() }
end )

net.Receive( "mc_collision_debug", function()
	local count = net.ReadUInt( 10 )
	local bounds = {}
	local bs = MC.BS or 36.5
	for i = 1, count do
		local cx = net.ReadInt( Net.COORD_BITS )
		local cy = net.ReadInt( Net.COORD_BITS )
		local cz = net.ReadInt( Net.COORD_BITS )
		local lx0 = net.ReadUInt( 6 )
		local ly0 = net.ReadUInt( 6 )
		local lz0 = net.ReadUInt( 6 )
		local lx1 = net.ReadUInt( 6 )
		local ly1 = net.ReadUInt( 6 )
		local lz1 = net.ReadUInt( 6 )
		local origin = MC.ChunkWorldOrigin( cx, cy, cz )
		bounds[i] = {
			mins = origin + Vector( lx0 * bs, ly0 * bs, lz0 * bs ),
			maxs = origin + Vector( ( lx1 + 1 ) * bs, ( ly1 + 1 ) * bs, ( lz1 + 1 ) * bs ),
			cx = cx, cy = cy, cz = cz,
		}
	end
	MC.ServerCollisionDebugBounds = bounds
	MC.ServerCollisionDebugUpdated = CurTime()
end )

hook.Add( "Think", "mc_prediction_rollback", rollbackExpiredPredictions )
