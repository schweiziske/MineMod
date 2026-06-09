--[[----------------------------------------------------------------------------
	MC : voxel store + coordinate math (shared, authoritative on server, mirror on client)

	Coordinate spaces:
	  world  : Source units (Vector)
	  cell   : integer block coords  bx,by,bz  (floor(world / BlockSize))
	  chunk  : integer chunk section coords  cx,cy,cz
	  local  : index inside a 16x16x32 section       li = lx + ly*CS + lz*CS*CS
------------------------------------------------------------------------------]]

MC = MC or {}

local CS  = MC.CS
local BS  = MC.BS
local CS2 = CS * CS
local CH  = MC.CH

-- chunkKey -> chunk = { cx, cy, cz, key, blocks = { [li]=id }, orients = { [li]=orient }, count, ent (sv) }
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
	local cx, cy, cz = floor( bx / CS ), floor( by / CS ), floor( bz / CH )
	local lx, ly, lz = bx - cx * CS, by - cy * CS, bz - cz * CH
	return cx, cy, cz, lx + ly * CS + lz * CS2
end

function MC.DecodeLocal( li )
	local lz = floor( li / CS2 )
	local ly = floor( ( li - lz * CS2 ) / CS )
	local lx = li - lz * CS2 - ly * CS
	return lx, ly, lz
end

function MC.LocalIndexInRange( li )
	return li >= 0 and li < CS2 * CH
end

function MC.CellWorldMin( bx, by, bz )
	return Vector( bx * BS, by * BS, bz * BS )
end

function MC.CellWorldCenter( bx, by, bz )
	local h = BS * 0.5
	return Vector( bx * BS + h, by * BS + h, bz * BS + h )
end

function MC.ReachAllowsEye( eyePos, bx, by, bz, reach )
	if reach <= 0 or not eyePos then return true end
	local mn = MC.CellWorldMin( bx, by, bz )
	local px = math.max( mn.x, math.min( eyePos.x, mn.x + BS ) )
	local py = math.max( mn.y, math.min( eyePos.y, mn.y + BS ) )
	local pz = math.max( mn.z, math.min( eyePos.z, mn.z + BS ) )
	local dx, dy, dz = eyePos.x - px, eyePos.y - py, eyePos.z - pz
	return dx * dx + dy * dy + dz * dz <= reach * reach
end

function MC.CurrentReach()
	local cv = GetConVar( "mc_reach" )
	local fallback = MC.Config and MC.Config.DefaultReach or BS * 5
	local reach = cv and cv:GetFloat() or fallback
	if math.abs( reach - 8192 ) < 0.01 then return fallback end
	return reach
end

function MC.CanPreviewPlace( ply, bx, by, bz )
	if not IsValid( ply ) then return false end
	return MC.GetBlock( bx, by, bz ) == 0
		and MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, MC.CurrentReach() )
end

local INF = math.huge
local TRACE_EPS = 0.000001

local function axisStep( pos, dir, cell )
	if math.abs( dir ) <= TRACE_EPS then return 0, INF, INF end
	local step = dir > 0 and 1 or -1
	local boundary = ( dir > 0 and cell + 1 or cell ) * BS
	local tMax = ( boundary - pos ) / dir
	if tMax < 0 then tMax = 0 end
	return step, tMax, BS / math.abs( dir )
end

function MC.TraceBlockRay( startPos, dir, maxDist )
	if not startPos or not dir then return nil end
	dir = Vector( dir.x, dir.y, dir.z )
	if dir:LengthSqr() <= TRACE_EPS then return nil end
	dir:Normalize()
	maxDist = tonumber( maxDist ) or MC.CurrentReach()
	if maxDist <= 0 then maxDist = BS * 5 end

	local bx, by, bz = MC.WorldToCell( startPos )
	local sx, tx, dx = axisStep( startPos.x, dir.x, bx )
	local sy, ty, dy = axisStep( startPos.y, dir.y, by )
	local sz, tz, dz = axisStep( startPos.z, dir.z, bz )
	local dist = 0
	local normal = Vector( 0, 0, 0 )
	local maxSteps = math.ceil( maxDist / BS ) * 3 + 8

	for _ = 1, maxSteps do
		local id = MC.GetBlock( bx, by, bz )
		if id ~= 0 and dist <= maxDist then
			local orient = MC.GetBlockOrient( bx, by, bz )
			return {
				Hit = true,
				HitMCBlock = true,
				Block = id,
				Orient = orient,
				bx = bx, by = by, bz = bz,
				HitPos = startPos + dir * dist,
				HitNormal = normal,
				Fraction = dist / maxDist,
				Distance = dist,
			}
		end

		if tx <= ty and tx <= tz then
			dist = tx
			if dist > maxDist then break end
			bx = bx + sx
			tx = tx + dx
			normal = Vector( -sx, 0, 0 )
		elseif ty <= tz then
			dist = ty
			if dist > maxDist then break end
			by = by + sy
			ty = ty + dy
			normal = Vector( 0, -sy, 0 )
		else
			dist = tz
			if dist > maxDist then break end
			bz = bz + sz
			tz = tz + dz
			normal = Vector( 0, 0, -sz )
		end
	end

	return nil
end

function MC.PlayerBlockAim( ply )
	if not IsValid( ply ) then return nil end
	local eye = ply:EyePos()
	local hit = MC.TraceBlockRay( eye, ply:EyeAngles():Forward(), MC.CurrentReach() )
	if not hit then return nil end
	local tr = ply:GetEyeTrace()
	local ent = tr and tr.Entity
	if tr and tr.Hit and not ( IsValid( ent ) and ent:GetClass() == "mc_chunk" ) then
		local mapDist = eye:Distance( tr.HitPos )
		if mapDist + 1 < ( hit.Distance or 0 ) then return nil end
	end
	return hit
end

function MC.ChunkWorldOrigin( cx, cy, cz )
	return Vector( cx * MC.ChunkWorld, cy * MC.ChunkWorld, cz * MC.ChunkWorldH )
end

-- recover chunk coords from a chunk entity's world origin (client side)
function MC.ChunkCoordsFromOrigin( v )
	local w = MC.ChunkWorld
	return math.Round( v.x / w ), math.Round( v.y / w ), math.Round( v.z / MC.ChunkWorldH )
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
		c = { cx = cx, cy = cy, cz = cz, key = key, blocks = {}, orients = {}, count = 0 }
		MC.World[key] = c
	end
	c.cz = c.cz or cz
	c.orients = c.orients or {}
	return c
end

------------------------------------------------------------------- block access
function MC.GetBlock( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	return c.blocks[li] or 0
end

function MC.GetBlockOrient( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	local id = c.blocks[li]
	if not id then return 0 end
	return MC.NormalizeOrient and MC.NormalizeOrient( id, c.orients and c.orients[li] ) or ( c.orients and c.orients[li] or 0 )
end

--- Low-level store mutation used by BOTH realms.
-- id == 0 removes. Returns: chunk (or nil), created(bool), emptied(bool), changed(bool)
function MC.SetBlockRaw( bx, by, bz, id, orient )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return nil, false, false, false end
	local key = MC.ChunkKey( cx, cy, cz )
	orient = id ~= 0 and ( MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or math.floor( tonumber( orient ) or 0 ) ) or 0

	if id == 0 then
		local c = MC.World[key]
		if not c or c.blocks[li] == nil then return nil, false, false, false end
		c.blocks[li] = nil
		if c.orients then c.orients[li] = nil end
		c.count = c.count - 1
		local emptied = c.count <= 0
		if emptied then MC.World[key] = nil end
		return c, false, emptied, true
	end

	local created = ( MC.World[key] == nil )
	local c = MC.EnsureChunk( cx, cy, cz )
	local old = c.blocks[li]
	local oldOrient = MC.NormalizeOrient and MC.NormalizeOrient( old, c.orients and c.orients[li] ) or ( c.orients and c.orients[li] or 0 )
	if old == id and oldOrient == orient then return c, false, false, false end
	if c.blocks[li] == nil then c.count = c.count + 1 end
	c.blocks[li] = id
	c.orients[li] = orient
	return c, created, false, true
end

--- Iterate every (bx,by,bz,id,orient) in a chunk. cb( bx,by,bz, lx,ly,lz, id, orient )
function MC.ForEachBlock( chunk, cb )
	local ox, oy, oz = chunk.cx * CS, chunk.cy * CS, chunk.cz * CH
	chunk.orients = chunk.orients or {}
	for li, id in pairs( chunk.blocks ) do
		local lx, ly, lz = MC.DecodeLocal( li )
		local orient = MC.NormalizeOrient and MC.NormalizeOrient( id, chunk.orients[li] ) or ( chunk.orients[li] or 0 )
		cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, id, orient )
	end
end
