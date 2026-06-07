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

net.Receive( "mc_full", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )

	local c = MC.EnsureChunk( cx, cy, cz )
	c.blocks = {}
	c.orients = {}
	c.count = 0
	for _ = 1, count do
		local li = net.ReadUInt( Net.LOCAL_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )
		if MC.LocalIndexInRange( li ) then
			if c.blocks[li] == nil then c.count = c.count + 1 end
			c.blocks[li] = id
			c.orients[li] = MC.NormalizeOrient( id, orient )
		end
	end
	if c.count == 0 then MC.World[c.key] = nil end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( c.key )
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
			e:SetNoDraw( true )
			e.ChunkKey = nil
		end
		MC.ChunkEnts[key] = nil
	end
	MC.World = {}
	MC.MeshDirty = {}
	MC.PhysDirty = {}
	MC.ChunkEnts = {}
end )
