--[[----------------------------------------------------------------------------
	MC : voxel store + coordinate math (shared, authoritative on server, mirror on client)

	Coordinate spaces:
	  world  : Source units (Vector)
	  cell   : integer block coords  bx,by,bz  (floor(world / BlockSize))
	  chunk  : integer chunk coords  cx,cy,cz  (floor(cell  / ChunkSize))
	  local  : index 0..4095 inside a chunk    li = lx + ly*CS + lz*CS*CS
------------------------------------------------------------------------------]]

MC = MC or {}

local CS  = MC.CS
local BS  = MC.BS
local CS2 = CS * CS

-- chunkKey -> chunk = { cx, cy, cz, key, blocks = { [li]=id }, count, ent (sv) }
MC.World = MC.World or {}

local floor = math.floor

--------------------------------------------------------------------------- keys
function MC.ChunkKey( cx, cy, cz )
	return cx .. ":" .. cy .. ":" .. cz
end

------------------------------------------------------------------ space mapping
function MC.WorldToCell( v )
	return floor( v.x / BS ), floor( v.y / BS ), floor( v.z / BS )
end

function MC.CellToChunk( bx, by, bz )
	local cx, cy, cz = floor( bx / CS ), floor( by / CS ), floor( bz / CS )
	local lx, ly, lz = bx - cx * CS, by - cy * CS, bz - cz * CS
	return cx, cy, cz, lx + ly * CS + lz * CS2
end

function MC.DecodeLocal( li )
	local lz = floor( li / CS2 )
	local ly = floor( ( li - lz * CS2 ) / CS )
	local lx = li - lz * CS2 - ly * CS
	return lx, ly, lz
end

function MC.CellWorldMin( bx, by, bz )
	return Vector( bx * BS, by * BS, bz * BS )
end

function MC.CellWorldCenter( bx, by, bz )
	local h = BS * 0.5
	return Vector( bx * BS + h, by * BS + h, bz * BS + h )
end

function MC.ChunkWorldOrigin( cx, cy, cz )
	return Vector( cx * MC.ChunkWorld, cy * MC.ChunkWorld, cz * MC.ChunkWorld )
end

-- recover chunk coords from a chunk entity's world origin (client side)
function MC.ChunkCoordsFromOrigin( v )
	local w = MC.ChunkWorld
	return math.Round( v.x / w ), math.Round( v.y / w ), math.Round( v.z / w )
end

--------------------------------------------------------------------- chunk store
function MC.GetChunkByKey( key )
	return MC.World[key]
end

function MC.GetChunk( cx, cy, cz )
	return MC.World[MC.ChunkKey( cx, cy, cz )]
end

function MC.EnsureChunk( cx, cy, cz )
	local key = MC.ChunkKey( cx, cy, cz )
	local c = MC.World[key]
	if not c then
		c = { cx = cx, cy = cy, cz = cz, key = key, blocks = {}, count = 0 }
		MC.World[key] = c
	end
	return c
end

------------------------------------------------------------------- block access
function MC.GetBlock( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	return c.blocks[li] or 0
end

--- Low-level store mutation used by BOTH realms.
-- id == 0 removes. Returns: chunk (or nil), created(bool), emptied(bool), changed(bool)
function MC.SetBlockRaw( bx, by, bz, id )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )

	if id == 0 then
		local c = MC.World[key]
		if not c or c.blocks[li] == nil then return nil, false, false, false end
		c.blocks[li] = nil
		c.count = c.count - 1
		local emptied = c.count <= 0
		if emptied then MC.World[key] = nil end
		return c, false, emptied, true
	end

	local created = ( MC.World[key] == nil )
	local c = MC.EnsureChunk( cx, cy, cz )
	if c.blocks[li] == id then return c, false, false, false end
	if c.blocks[li] == nil then c.count = c.count + 1 end
	c.blocks[li] = id
	return c, created, false, true
end

--- Iterate every (bx,by,bz,id) in a chunk. cb( bx,by,bz, lx,ly,lz, id )
function MC.ForEachBlock( chunk, cb )
	local ox, oy, oz = chunk.cx * CS, chunk.cy * CS, chunk.cz * CS
	for li, id in pairs( chunk.blocks ) do
		local lx, ly, lz = MC.DecodeLocal( li )
		cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, id )
	end
end