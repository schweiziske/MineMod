--[[----------------------------------------------------------------------------
	MC : client net receivers (server is authoritative; we only mirror + redraw)
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net

local function markNeighbours( cx, cy, cz )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx + 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx - 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy + 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy - 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz + 1 ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz - 1 ) )
end

-- full chunk (initial sync / resync)
net.Receive( "mc_full", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )

	local c = MC.EnsureChunk( cx, cy, cz )
	c.blocks = {}
	c.count = 0
	for _ = 1, count do
		local li = net.ReadUInt( Net.LOCAL_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		if c.blocks[li] == nil then c.count = c.count + 1 end
		c.blocks[li] = id
	end
	if c.count == 0 then MC.World[c.key] = nil end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( c.key )
end )

-- single block change
net.Receive( "mc_set", function()
	local bx = net.ReadInt( Net.COORD_BITS )
	local by = net.ReadInt( Net.COORD_BITS )
	local bz = net.ReadInt( Net.COORD_BITS )
	local id = net.ReadUInt( Net.ID_BITS )

	MC.SetBlockRaw( bx, by, bz, id )
	MC.MarkDirty( bx, by, bz )

	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	MC.MarkChunkPhysDirty( MC.ChunkKey( cx, cy, cz ) )
end )

-- wipe
net.Receive( "mc_clear", function()
	MC.FreeAllMeshes()
	MC.World = {}
	MC.MeshDirty = {}
	MC.PhysDirty = {}
end )