--[[----------------------------------------------------------------------------
	MC : client net receivers (server is authoritative; we only mirror + redraw)
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net
MC.PendingFull = MC.PendingFull or {}
MC.SyncProgress = MC.SyncProgress or { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = 0 }

local PendingFullAckBytes = 0
local NextFullAckAt = 0

local function flushFullAck()
	if PendingFullAckBytes <= 0 then return end
	local bytes = math.min( PendingFullAckBytes, 4294967295 )
	PendingFullAckBytes = 0
	net.Start( "mc_full_ack" )
		net.WriteUInt( bytes, 32 )
	net.SendToServer()
	NextFullAckAt = CurTime() + 0.02
end

local function queueFullAck( bytes, immediate )
	bytes = math.max( 0, math.ceil( tonumber( bytes ) or 0 ) )
	if bytes <= 0 then return end
	PendingFullAckBytes = math.min( PendingFullAckBytes + bytes, 4294967295 )
	if immediate or PendingFullAckBytes >= 65536 or CurTime() >= NextFullAckAt then
		flushFullAck()
	end
end

timer.Create( "mc_full_ack_flush", 0.05, 0, flushFullAck )

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

local function finishProgressChunk()
	local p = MC.SyncProgress
	p.doneChunks = p.doneChunks + 1
	touchProgress()

	if not p.finalMeshRefresh and p.doneChunks >= p.chunks and p.received >= p.expected then
		p.finalMeshRefresh = true
		for key, c in pairs( MC.World or {} ) do
			if c.count and c.count > 0 then
				MC.MarkChunkDirty( key )
			end
		end
	end
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

function MC.MarkCellPhysNeighbours( bx, by, bz, priority )
	local seen = {}
	local function mark( x, y, z )
		local cx, cy, cz = MC.CellToChunk( x, y, z )
		local key = MC.ChunkKey( cx, cy, cz )
		if seen[key] then return end
		seen[key] = true
		MC.MarkChunkPhysDirty( key, priority )
	end

	mark( bx, by, bz )
	mark( bx + 1, by, bz )
	mark( bx - 1, by, bz )
	mark( bx, by + 1, bz )
	mark( bx, by - 1, bz )
end

MC.PendingPredictions = MC.PendingPredictions or {}
local PLACE_PHYS_PLAYER_PADDING = MC.BS * 0.75

local function predictionKey( bx, by, bz )
	return bx .. ":" .. by .. ":" .. bz
end

local function markPredictedCellDirty( bx, by, bz, priority )
	MC.MarkDirty( bx, by, bz )
	MC.MarkCellPhysNeighbours( bx, by, bz, priority )
end

function MC.PredictSetBlock( bx, by, bz, id, orient )
	if not MC.IsValidBlock or not MC.IsValidBlock( id ) then return false end
	if MC.GetBlock( bx, by, bz ) ~= 0 then return false end

	local key = predictionKey( bx, by, bz )
	local pending = MC.PendingPredictions[key]
	local oldId = pending and pending.oldId or MC.GetBlock( bx, by, bz )
	local oldOrient = pending and pending.oldOrient or MC.GetBlockOrient( bx, by, bz )
	orient = MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or orient

	local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
	if not changed then return false end

	MC.PendingPredictions[key] = {
		bx = bx,
		by = by,
		bz = bz,
		id = id,
		orient = orient,
		oldId = oldId,
		oldOrient = oldOrient,
		expire = CurTime() + 2.5,
	}
	markPredictedCellDirty( bx, by, bz, MC.BlockAABBOverlapsPlayerHull( bx, by, bz, PLACE_PHYS_PLAYER_PADDING ) )
	return true
end

function MC.PredictBreakBlock( bx, by, bz, ply )
	if IsValid( ply ) and not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, MC.CurrentReach() ) then return false end
	local oldId = MC.GetBlock( bx, by, bz )
	if oldId == 0 then return false end

	local key = predictionKey( bx, by, bz )
	if MC.PendingPredictions[key] then return false end

	local oldOrient = MC.GetBlockOrient( bx, by, bz )
	local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, 0, 0 )
	if not changed then return false end

	MC.PendingPredictions[key] = {
		bx = bx,
		by = by,
		bz = bz,
		id = 0,
		orient = 0,
		oldId = oldId,
		oldOrient = oldOrient,
		expire = CurTime() + 2.5,
	}
	markPredictedCellDirty( bx, by, bz, true )
	if MC.PlayBlockFx then
		MC.PlayBlockFx( 2, oldId, oldOrient, bx, by, bz, true )
	end
	return true
end

function MC.ConfirmPrediction( bx, by, bz, id, orient )
	local key = predictionKey( bx, by, bz )
	local hadPrediction = MC.PendingPredictions[key] ~= nil
	if MC.PendingPredictions[key] then
		MC.PendingPredictions[key] = nil
	end
	return hadPrediction
end

local function rollbackExpiredPredictions()
	local now = CurTime()
	for key, pending in pairs( MC.PendingPredictions ) do
		if now >= pending.expire then
			local current = MC.GetBlock( pending.bx, pending.by, pending.bz )
			local currentOrient = MC.GetBlockOrient( pending.bx, pending.by, pending.bz )
			if current == pending.id and currentOrient == pending.orient then
				MC.SetBlockRaw( pending.bx, pending.by, pending.bz, pending.oldId, pending.oldOrient )
				markPredictedCellDirty( pending.bx, pending.by, pending.bz )
			end
			MC.PendingPredictions[key] = nil
		end
	end
end

local function resetChunk( cx, cy, cz )
	local c = MC.EnsureChunk( cx, cy, cz )
	c.blocks = {}
	c.orients = {}
	c.count = 0
	return c
end

local function readCellsIntoChunk( c, count )
	for _ = 1, count do
		local li = net.ReadUInt( Net.LOCAL_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )
		if id ~= 0 and MC.LocalIndexInRange( li ) then
			if c.blocks[li] == nil then c.count = c.count + 1 end
			c.blocks[li] = id
			c.orients[li] = MC.NormalizeOrient( id, orient )
		end
	end
end

local function reviveChunkEnt( c )
	MC.ChunkEnts = MC.ChunkEnts or {}
	local e = MC.ChunkEnts[c.key]
	if not IsValid( e ) then
		for _, candidate in ipairs( ents.FindByClass( "mc_chunk" ) ) do
			if candidate:EnsureKey() == c.key then
				e = candidate
				MC.ChunkEnts[c.key] = candidate
				break
			end
		end
	end
	if not IsValid( e ) then return end
	e:SetNoDraw( false )
	e.ChunkKey = c.key
end

net.Receive( "mc_full", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )

	local c = resetChunk( cx, cy, cz )
	beginProgressChunk( count )
	readCellsIntoChunk( c, count )
	addProgressCells( count )
	reviveChunkEnt( c )
	if c.count == 0 then MC.World[c.key] = nil end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( c.key )
	finishProgressChunk()
end )

net.Receive( "mc_full_begin", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local expected = net.ReadUInt( Net.COUNT_BITS )
	queueFullAck( MC.EstimateSyncBeginBytes() )
	local c = resetChunk( cx, cy, cz )
	MC.PendingFull[c.key] = { expected = expected, received = 0 }
	beginProgressChunk( expected )
	reviveChunkEnt( c )
end )

net.Receive( "mc_full_part", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )
	queueFullAck( MC.EstimateSyncPartBytes( count ) )
	local c = MC.EnsureChunk( cx, cy, cz )
	readCellsIntoChunk( c, count )
	addProgressCells( count )
	reviveChunkEnt( c )

	local pending = MC.PendingFull[c.key]
	if pending then pending.received = pending.received + count end
end )

net.Receive( "mc_full_end", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	queueFullAck( MC.EstimateSyncEndBytes(), true )
	local key = MC.ChunkKey( cx, cy, cz )
	local c = MC.GetChunkByKey( key )
	MC.PendingFull[key] = nil
	if c and c.count == 0 then
		MC.World[key] = nil
	end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( key )
	finishProgressChunk()
end )

net.Receive( "mc_set", function()
	local bx = net.ReadInt( Net.COORD_BITS )
	local by = net.ReadInt( Net.COORD_BITS )
	local bz = net.ReadInt( Net.COORD_BITS )
	local id = net.ReadUInt( Net.ID_BITS )
	local orient = net.ReadUInt( Net.ORIENT_BITS )

	MC.ConfirmPrediction( bx, by, bz, id, orient )
	local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
	if changed then
		MC.MarkDirty( bx, by, bz )
		MC.MarkCellPhysNeighbours( bx, by, bz )
	end
end )

net.Receive( "mc_set_bulk", function()
	local count = net.ReadUInt( Net.COUNT_BITS )
	for _ = 1, count do
		local bx = net.ReadInt( Net.COORD_BITS )
		local by = net.ReadInt( Net.COORD_BITS )
		local bz = net.ReadInt( Net.COORD_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )

		MC.ConfirmPrediction( bx, by, bz, id, orient )
		local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
		if changed then
			MC.MarkDirty( bx, by, bz )
			MC.MarkCellPhysNeighbours( bx, by, bz )
		end
	end
end )

net.Receive( "mc_clear", function()
	MC.FreeAllMeshes()
	for key, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then
			e:PhysicsDestroy()
		end
	end
	MC.World = {}
	MC.MeshDirty = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PendingFull = {}
	MC.PendingPredictions = {}
	MC.SyncProgress = { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = CurTime() }
	PendingFullAckBytes = 0
end )

hook.Add( "Think", "mc_prediction_rollback", rollbackExpiredPredictions )
