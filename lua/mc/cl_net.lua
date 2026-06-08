--[[----------------------------------------------------------------------------
	MC : client net receivers (server is authoritative; we only mirror + redraw)
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net
MC.PendingFull = MC.PendingFull or {}
MC.SyncProgress = MC.SyncProgress or { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = 0 }

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

	MC.SetBlockRaw( bx, by, bz, id, orient )
	MC.MarkDirty( bx, by, bz )

	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	MC.MarkChunkPhysDirty( MC.ChunkKey( cx, cy, cz ) )
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
	MC.PendingFull = {}
	MC.SyncProgress = { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = CurTime() }
end )
