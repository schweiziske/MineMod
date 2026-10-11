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
local PLACE_REJECT_PLAYER_PADDING = math.max( 2, BS * 0.08 )

-- chunkKey -> chunk = { cx, cy, cz, key, blocks = { [li]=id }, orients = { [li]=orient }, count, ent (sv) }
MC.World = MC.World or {}

local floor = math.floor
local bit_bor, bit_band = bit.bor, bit.band
local bit_lshift, bit_rshift = bit.lshift, bit.rshift

local CHUNK_KEY_X_BITS = 13
local CHUNK_KEY_Y_BITS = 13
local CHUNK_KEY_Z_BITS = 6
local CHUNK_KEY_X_SIZE = bit_lshift( 1, CHUNK_KEY_X_BITS )
local CHUNK_KEY_Y_SIZE = bit_lshift( 1, CHUNK_KEY_Y_BITS )
local CHUNK_KEY_Z_SIZE = bit_lshift( 1, CHUNK_KEY_Z_BITS )
local CHUNK_KEY_X_BIAS = CHUNK_KEY_X_SIZE / 2
local CHUNK_KEY_Y_BIAS = CHUNK_KEY_Y_SIZE / 2
local CHUNK_KEY_Z_BIAS = CHUNK_KEY_Z_SIZE / 2
local CHUNK_KEY_Y_SHIFT = CHUNK_KEY_X_BITS
local CHUNK_KEY_Z_SHIFT = CHUNK_KEY_X_BITS + CHUNK_KEY_Y_BITS
local CHUNK_KEY_X_MASK = CHUNK_KEY_X_SIZE - 1
local CHUNK_KEY_Y_MASK = CHUNK_KEY_Y_SIZE - 1
local CHUNK_KEY_Z_MASK = CHUNK_KEY_Z_SIZE - 1
local CHUNK_KEY_CELL_STRIDE = CS2 * CH
local CHUNK_COLUMN_BITS = 16
local CHUNK_COLUMN_SIZE = bit_lshift( 1, CHUNK_COLUMN_BITS )
local CHUNK_COLUMN_BIAS = CHUNK_COLUMN_SIZE / 2
local CHUNK_COLUMN_MASK = CHUNK_COLUMN_SIZE - 1
local CELL_COLUMN_STRIDE = CS2

--------------------------------------------------------------------------- keys
local function legacyChunkKeyString( cx, cy, cz )
	return cx .. ":" .. cy .. ":" .. cz
end

local function packedCoord( value, bias, size )
	value = floor( tonumber( value ) or 0 )
	if value < -bias or value >= size - bias then return nil end
	return value + bias, value
end

function MC.ChunkKey( cx, cy, cz )
	local x, nx = packedCoord( cx, CHUNK_KEY_X_BIAS, CHUNK_KEY_X_SIZE )
	local y, ny = packedCoord( cy, CHUNK_KEY_Y_BIAS, CHUNK_KEY_Y_SIZE )
	local z, nz = packedCoord( cz, CHUNK_KEY_Z_BIAS, CHUNK_KEY_Z_SIZE )
	if not x or not y or not z then
		return legacyChunkKeyString( nx or floor( tonumber( cx ) or 0 ), ny or floor( tonumber( cy ) or 0 ), nz or floor( tonumber( cz ) or 0 ) )
	end
	return bit_bor( x, bit_lshift( y, CHUNK_KEY_Y_SHIFT ), bit_lshift( z, CHUNK_KEY_Z_SHIFT ) )
end

function MC.ChunkKeyString( keyOrCX, cy, cz )
	if cy ~= nil and cz ~= nil then
		return legacyChunkKeyString( floor( tonumber( keyOrCX ) or 0 ), floor( tonumber( cy ) or 0 ), floor( tonumber( cz ) or 0 ) )
	end
	local cx, ccy, ccz = MC.ChunkKeyToCoords( keyOrCX )
	if not cx then return tostring( keyOrCX or "" ) end
	return legacyChunkKeyString( cx, ccy, ccz )
end

local function packedChunkKeyToCoords( key )
	key = tonumber( key )
	if not key then return nil end
	local x = bit_band( key, CHUNK_KEY_X_MASK ) - CHUNK_KEY_X_BIAS
	local y = bit_band( bit_rshift( key, CHUNK_KEY_Y_SHIFT ), CHUNK_KEY_Y_MASK ) - CHUNK_KEY_Y_BIAS
	local z = bit_band( bit_rshift( key, CHUNK_KEY_Z_SHIFT ), CHUNK_KEY_Z_MASK ) - CHUNK_KEY_Z_BIAS
	return x, y, z
end

function MC.ChunkKeyToCoords( key )
	if type( key ) == "number" then return packedChunkKeyToCoords( key ) end
	if type( key ) ~= "string" then return nil end
	local cx, cy, cz = string.match( key or "", "^(-?%d+):(-?%d+):(-?%d+)$" )
	if cx then return tonumber( cx ), tonumber( cy ), tonumber( cz ) end
	return packedChunkKeyToCoords( key )
end

function MC.CanonicalChunkKey( key )
	if key == nil then return nil end
	if type( key ) == "number" then return key end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return key end
	return MC.ChunkKey( cx, cy, cz )
end

MC.LoadedChunkKeys = MC.LoadedChunkKeys or {}

local function chunkKeyFromArgs( keyOrCX, cy, cz )
	if cy ~= nil and cz ~= nil then
		return MC.ChunkKey( keyOrCX, cy, cz )
	end
	return MC.CanonicalChunkKey( keyOrCX )
end

function MC.MarkChunkLoaded( keyOrCX, cy, cz )
	local key = chunkKeyFromArgs( keyOrCX, cy, cz )
	if key == nil then return nil end
	local backend = CLIENT and MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native and backend.MarkLoaded then backend.MarkLoaded( key ) end
	MC.LoadedChunkKeys = MC.LoadedChunkKeys or {}
	MC.LoadedChunkKeys[key] = true
	return key
end

function MC.MarkChunkUnloaded( keyOrCX, cy, cz )
	local key = chunkKeyFromArgs( keyOrCX, cy, cz )
	if key == nil then return nil end
	local backend = CLIENT and MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native and backend.MarkUnloaded then backend.MarkUnloaded( key ) end
	if MC.LoadedChunkKeys then MC.LoadedChunkKeys[key] = nil end
	return key
end

function MC.IsChunkLoaded( keyOrCX, cy, cz )
	local key = chunkKeyFromArgs( keyOrCX, cy, cz )
	if key == nil then return false end
	return ( MC.World and MC.World[key] ~= nil ) or ( MC.LoadedChunkKeys and MC.LoadedChunkKeys[key] == true )
end

function MC.CellKey( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local chunkKey = MC.ChunkKey( cx, cy, cz )
	if type( chunkKey ) == "number" then
		return chunkKey * CHUNK_KEY_CELL_STRIDE + li
	end
	return chunkKey .. ":" .. li
end

function MC.ChunkColumnKey( cx, cy )
	local x, nx = packedCoord( cx, CHUNK_COLUMN_BIAS, CHUNK_COLUMN_SIZE )
	local y, ny = packedCoord( cy, CHUNK_COLUMN_BIAS, CHUNK_COLUMN_SIZE )
	if not x or not y then
		return legacyChunkKeyString( nx or floor( tonumber( cx ) or 0 ), ny or floor( tonumber( cy ) or 0 ), 0 )
	end
	return bit_bor( x, bit_lshift( y, CHUNK_COLUMN_BITS ) )
end

function MC.CellColumnKey( bx, by )
	local cx, cy = floor( bx / CS ), floor( by / CS )
	local lx, ly = bx - cx * CS, by - cy * CS
	local columnKey = MC.ChunkColumnKey( cx, cy )
	local li = lx + ly * CS
	if type( columnKey ) == "number" then
		return columnKey * CELL_COLUMN_STRIDE + li
	end
	return columnKey .. ":" .. li
end

local function normalizeChunkSpan( span )
	span = math.floor( tonumber( span ) or 0 )
	if span < 0 then return 0 end
	return span
end

function MC.ChunkCoordWindow( center, span, fraction )
	span = normalizeChunkSpan( span )
	if span <= 0 then return nil, nil end
	center = floor( tonumber( center ) or 0 )
	fraction = tonumber( fraction ) or 0.5

	if span % 2 == 1 then
		local half = ( span - 1 ) / 2
		return center - half, center + half
	end

	local half = span / 2
	if fraction >= 0.5 then
		return center - half + 1, center + half
	end
	return center - half, center + half - 1
end

local function chunkCoordAndFraction( value, worldSize )
	local raw = ( tonumber( value ) or 0 ) / worldSize
	local coord = floor( raw )
	return coord, raw - coord
end

function MC.ChunkInterestKeysAroundPos( pos, spanXY, spanZ )
	local keys = {}
	if not pos then return keys end
	spanXY = normalizeChunkSpan( spanXY )
	spanZ = normalizeChunkSpan( spanZ == nil and spanXY or spanZ )
	if spanXY <= 0 or spanZ <= 0 then return keys end

	local cx, fx = chunkCoordAndFraction( pos.x, MC.ChunkWorld )
	local cy, fy = chunkCoordAndFraction( pos.y, MC.ChunkWorld )
	local cz, fz = chunkCoordAndFraction( pos.z, MC.ChunkWorldH )
	local minX, maxX = MC.ChunkCoordWindow( cx, spanXY, fx )
	local minY, maxY = MC.ChunkCoordWindow( cy, spanXY, fy )
	local minZ, maxZ = MC.ChunkCoordWindow( cz, spanZ, fz )

	for z = minZ, maxZ do
		for y = minY, maxY do
			for x = minX, maxX do
				keys[MC.ChunkKey( x, y, z )] = true
			end
		end
	end

	return keys
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

function MC.LocalCollisionSubchunkBounds( lx, ly, lz )
	local size = math.max( 1, math.floor( tonumber( MC.CollisionSubchunkSize ) or 8 ) )
	local minX = math.floor( lx / size ) * size
	local minY = math.floor( ly / size ) * size
	local minZ = math.floor( lz / size ) * size
	return {
		minX,
		minY,
		minZ,
		math.min( CS - 1, minX + size - 1 ),
		math.min( CS - 1, minY + size - 1 ),
		math.min( CH - 1, minZ + size - 1 ),
	}
end

function MC.CellCollisionSubchunkBounds( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local lx, ly, lz = MC.DecodeLocal( li )
	return MC.ChunkKey( cx, cy, cz ), MC.LocalCollisionSubchunkBounds( lx, ly, lz ), cx, cy, cz
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
	if reach <= 0 then return true end
	if not eyePos then return false end
	local mn = MC.CellWorldMin( bx, by, bz )
	local px = math.max( mn.x, math.min( eyePos.x, mn.x + BS ) )
	local py = math.max( mn.y, math.min( eyePos.y, mn.y + BS ) )
	local pz = math.max( mn.z, math.min( eyePos.z, mn.z + BS ) )
	local dx, dy, dz = eyePos.x - px, eyePos.y - py, eyePos.z - pz
	return dx * dx + dy * dy + dz * dz <= reach * reach
end

local function entityWorldAABB( ent )
	if MC.EntityWorldAABB then
		local minimum, maximum = MC.EntityWorldAABB( ent )
		if minimum and maximum then return minimum, maximum end
	end
	return ent:WorldSpaceAABB()
end

function MC.BlockAABBOverlapsPlayerHull( bx, by, bz, padding )
	padding = math.max( 0, tonumber( padding ) or 0 )
	local mn = MC.CellWorldMin( bx, by, bz )
	local mxx, mxy, mxz = mn.x + BS, mn.y + BS, mn.z + BS
	for _, p in ipairs( player.GetAll() ) do
		if p:Alive() then
			local pmn, pmx = entityWorldAABB( p )
			if mn.x - padding < pmx.x and mxx + padding > pmn.x
			and mn.y - padding < pmx.y and mxy + padding > pmn.y
			and mn.z - padding < pmx.z and mxz + padding > pmn.z then
				return true
			end
		end
	end
	return false
end

local function blockAABBOverlapsPlayerHullSidePadding( bx, by, bz, padding )
	padding = math.max( 0, tonumber( padding ) or 0 )
	local mn = MC.CellWorldMin( bx, by, bz )
	local mxx, mxy, mxz = mn.x + BS, mn.y + BS, mn.z + BS
	for _, p in ipairs( player.GetAll() ) do
		if p:Alive() then
			local pmn, pmx = entityWorldAABB( p )
			if mn.x - padding < pmx.x and mxx + padding > pmn.x
			and mn.y - padding < pmx.y and mxy + padding > pmn.y
			and mn.z < pmx.z and mxz > pmn.z then
				return true
			end
		end
	end
	return false
end

local function placementStateHasCollision( bx, by, bz, id, stateId )
	if stateId ~= nil and MC.BlockHasCollisionForState then
		return MC.BlockHasCollisionForState( stateId, bx, by, bz ) == true
	end
	if id == nil or id == 0 then return false end
	if MC.BlockHasCollision then return MC.BlockHasCollision( id ) == true end
	return true
end

function MC.PlacementOverlapsPlayerHull( bx, by, bz, id, orient, stateId )
	-- Non-colliding states cannot trap a player. Return before player.GetAll(),
	-- WorldSpaceAABB() and the full-cell overlap checks.
	if not placementStateHasCollision( bx, by, bz, id, stateId ) then return false end
	if MC.BlockAABBOverlapsPlayerHull( bx, by, bz, 0 ) then return true end
	if id ~= nil and id ~= 0 and MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
		return blockAABBOverlapsPlayerHullSidePadding( bx, by, bz, PLACE_REJECT_PLAYER_PADDING )
	end
	return false
end

function MC.CurrentReach()
	local cv = GetConVar( "mc_reach" )
	local fallback = MC.Config and MC.Config.DefaultReach or BS * 5
	local reach = cv and cv:GetFloat() or fallback
	if math.abs( reach - 8192 ) < 0.01 then return fallback end
	if math.abs( reach - 182.5 ) < 0.01 then return fallback end
	return reach
end

-- prediction-side mirrors of the server's SV.Place/SV.Break checks (sv_world):
-- the relevant ConVars are FCVAR_REPLICATED, so both realms see the same values
local function previewCanEdit( ply )
	local cv = GetConVar( "mc_admin_only" )
	if cv and cv:GetBool() and not ply:IsAdmin() then return false end
	return true
end

local function previewWorldBoundsOK( bx, by, bz )
	local cv = GetConVar( "mc_world_limit" )
	if MC.WorldBoundsOK then return MC.WorldBoundsOK( bx, by, bz, cv and cv:GetInt() or nil ) end
	if not cv then return true end
	local protoMax = bit.lshift( 1, MC.Net.COORD_BITS - 1 ) - 1
	local lim = math.min( cv:GetInt(), protoMax )
	return math.abs( bx ) <= lim and math.abs( by ) <= lim and math.abs( bz ) <= lim
end

local function previewWouldTrapPlayer( bx, by, bz, id, orient, stateId )
	return MC.PlacementOverlapsPlayerHull( bx, by, bz, id, orient, stateId )
end

local function previewCellIsFluid( bx, by, bz )
	return MC.CellIsFluidBlock and MC.CellIsFluidBlock( bx, by, bz ) == true
end

function MC.CanPreviewBreak( ply, bx, by, bz )
	if not IsValid( ply ) then return false end
	return MC.GetBlock( bx, by, bz ) ~= 0
		and not previewCellIsFluid( bx, by, bz )
		and previewCanEdit( ply )
		and MC.ReachAllowsEye( MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos(), bx, by, bz, MC.CurrentReach() )
end

function MC.CanPreviewPlace( ply, bx, by, bz, id, orient, stateId )
	if not IsValid( ply ) then return false end
	stateId = stateId or MC.StateFromLegacy( id, orient )
	return MC.PlacementCanReplaceState( MC.GetBlockState( bx, by, bz ), stateId )
		and previewCanEdit( ply )
		and previewWorldBoundsOK( bx, by, bz )
		and not previewWouldTrapPlayer( bx, by, bz, id, orient, stateId )
		and MC.ReachAllowsEye( MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos(), bx, by, bz, MC.CurrentReach() )
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

local function rayAxisSlab( pos, dir, minPos, maxPos, tMin, tMax, normal, negNormal, posNormal )
	if math.abs( dir ) <= TRACE_EPS then
		if pos < minPos or pos > maxPos then return nil end
		return tMin, tMax, normal
	end

	local near, far, nearNormal
	if dir > 0 then
		near = ( minPos - pos ) / dir
		far = ( maxPos - pos ) / dir
		nearNormal = negNormal
	else
		near = ( maxPos - pos ) / dir
		far = ( minPos - pos ) / dir
		nearNormal = posNormal
	end

	if near > tMin then
		tMin = near
		normal = nearNormal
	end
	if far < tMax then tMax = far end
	if tMin - tMax > TRACE_EPS then return nil end
	return tMin, tMax, normal
end

local function rayIntersectBox( startPos, dir, minX, minY, minZ, maxX, maxY, maxZ, maxDist, fallbackNormal )
	local tMin, tMax = 0, maxDist
	local normal = fallbackNormal or Vector( 0, 0, 0 )

	tMin, tMax, normal = rayAxisSlab( startPos.x, dir.x, minX, maxX, tMin, tMax, normal, Vector( -1, 0, 0 ), Vector( 1, 0, 0 ) )
	if not tMin then return nil end
	tMin, tMax, normal = rayAxisSlab( startPos.y, dir.y, minY, maxY, tMin, tMax, normal, Vector( 0, -1, 0 ), Vector( 0, 1, 0 ) )
	if not tMin then return nil end
	tMin, tMax, normal = rayAxisSlab( startPos.z, dir.z, minZ, maxZ, tMin, tMax, normal, Vector( 0, 0, -1 ), Vector( 0, 0, 1 ) )
	if not tMin then return nil end
	if tMax < -TRACE_EPS or tMin - maxDist > TRACE_EPS then return nil end
	return math.max( 0, tMin ), normal
end

local function traceBlockBoxes( startPos, dir, maxDist, bx, by, bz, id, orient, stateId, fallbackDist, fallbackNormal )
	local boxes = stateId ~= nil and MC.BlockSelectionBoxesForState
		and MC.BlockSelectionBoxesForState( stateId, bx, by, bz ) or nil
	if boxes == nil and stateId ~= nil and MC.BlockBoxesForState then
		boxes = MC.BlockBoxesForState( stateId, bx, by, bz )
	end
	if boxes == nil then
		if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
			return { dist = fallbackDist, normal = fallbackNormal }
		end
		boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
	end
	-- Both realms load the same compact model catalog and exact state selection
	-- boxes. This fallback is only for custom/technical blocks which genuinely
	-- have no authored collision, model, or selection geometry in either realm.
	if not boxes or boxes[1] == nil then
		return { dist = fallbackDist, normal = fallbackNormal }
	end

	local base = MC.CellWorldMin( bx, by, bz )
	local bestDist, bestNormal
	for _, box in ipairs( boxes ) do
		local dist, normal = rayIntersectBox(
			startPos,
			dir,
			base.x + box[1] * BS,
			base.y + box[2] * BS,
			base.z + box[3] * BS,
			base.x + box[4] * BS,
			base.y + box[5] * BS,
			base.z + box[6] * BS,
			maxDist,
			fallbackNormal
		)
		if dist and ( not bestDist or dist < bestDist ) then
			bestDist = dist
			bestNormal = normal
		end
	end
	if not bestDist then return nil end
	return { dist = bestDist, normal = bestNormal }
end

-- ClipContext.Fluid.NONE. Pass as MC.TraceBlockRay's options to walk straight
-- through fluid blocks, which is what Java's block picking does.
MC.ClipFluidNone = { skipFluid = true }

function MC.TraceBlockRay( startPos, dir, maxDist, options )
	if not startPos or not dir then return nil end
	dir = Vector( dir.x, dir.y, dir.z )
	if dir:LengthSqr() <= TRACE_EPS then return nil end
	dir:Normalize()
	maxDist = tonumber( maxDist ) or MC.CurrentReach()
	if maxDist <= 0 then maxDist = BS * 5 end
	local skipFluid = istable( options ) and options.skipFluid == true

	local bx, by, bz = MC.WorldToCell( startPos )
	local sx, tx, dx = axisStep( startPos.x, dir.x, bx )
	local sy, ty, dy = axisStep( startPos.y, dir.y, by )
	local sz, tz, dz = axisStep( startPos.z, dir.z, bz )
	local dist = 0
	local normal = Vector( 0, 0, 0 )
	local maxSteps = math.ceil( maxDist / BS ) * 3 + 8

	for _ = 1, maxSteps do
		local id = MC.GetBlock( bx, by, bz )
		-- Predicted placements already exist locally and can support the next
		-- click. Skipping all pending cells forced building to wait for a round trip.
		if id ~= 0 and dist <= maxDist then
			local orient = MC.GetBlockOrient( bx, by, bz )
			local stateId = MC.GetBlockState( bx, by, bz )
			-- Skipping the cell rather than the box test keeps the DDA walking, so
			-- the ray reports whatever is behind the fluid at its true distance.
			local clipped = skipFluid and MC.StateIsFluidBlock
				and MC.StateIsFluidBlock( stateId ) == true
			local hit = not clipped
				and traceBlockBoxes( startPos, dir, maxDist, bx, by, bz, id, orient, stateId, dist, normal )
			if hit then
				return {
					Hit = true,
					HitMCBlock = true,
					Block = id,
					Orient = orient,
					StateId = stateId,
					bx = bx, by = by, bz = bz,
					HitPos = startPos + dir * hit.dist,
					HitNormal = hit.normal,
					Fraction = hit.dist / maxDist,
					Distance = hit.dist,
				}
			end
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

function MC.PlayerBlockAim( ply, reach )
	if not IsValid( ply ) then return nil end
	local eye = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos()
	local maxDist = tonumber( reach )
	if not maxDist or maxDist <= 0 then
		maxDist = MC.CurrentReach()
	end
	-- Entity#pick passes ClipContext.Fluid.NONE, so the crosshair looks straight
	-- through water and lava at whatever is behind them. Every gesture that
	-- resolves its target through this -- mining, placing, use, igniters, shears
	-- -- inherits that, which is exactly why a fluid cannot be mined and why a
	-- block placed at a clicked face lands *inside* the fluid.
	local hit = MC.TraceBlockRay( eye, ply:EyeAngles():Forward(), maxDist, MC.ClipFluidNone )
	if not hit then return nil end
	return hit
end

function MC.ChunkWorldOrigin( cx, cy, cz )
	return Vector( cx * MC.ChunkWorld, cy * MC.ChunkWorld, cz * MC.ChunkWorldH )
end

-- recover chunk coords from a chunk entity's world origin (client side)
function MC.ChunkCoordsFromOrigin( v )
	if CLIENT and MC.RenderToWorldPos then v = MC.RenderToWorldPos( v ) end
	local w = MC.ChunkWorld
	return math.Round( v.x / w ), math.Round( v.y / w ), math.Round( v.z / MC.ChunkWorldH )
end

--------------------------------------------------------------------- chunk store
MC.ChunkBackends = MC.ChunkBackends or {}
MC.ChunkBackends.lua = MC.ChunkBackends.lua or {
	name = "lua",
	native = false,
	IsActive = function() return true end,
	CreateChunk = function() return true end,
}

function MC.RegisterChunkBackend( name, backend )
	if not isstring( name ) or name == "" or not istable( backend ) then return false end
	backend.name = name
	MC.ChunkBackends[name] = backend
	return true
end

function MC.GetChunkBackend()
	local native = MC.ChunkBackends and MC.ChunkBackends.native
	if native and native.IsActive and native.IsActive() then return native end
	return MC.ChunkBackends.lua
end

-- Native chunks keep these tables only as lightweight indexed compatibility
-- views. They do not duplicate all 8192 cells; a legacy numeric lookup is
-- resolved from the NativeChunk on demand. Code that needs iteration must use
-- MC.ForEachBlock/MC.ForEachBlockState because Lua 5.1 pairs() cannot expose a
-- virtual native key set.
function MC.AttachNativeChunkCompatibilityProxy( chunk )
	if not CLIENT or not chunk then return false end
	local function stateAt( li )
		if not MC.LocalIndexInRange( li ) then return 0 end
		local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
		if not backend or not backend.native or not backend.GetCell or not backend.Epoch
		or chunk.nativeMeshEpoch == nil or chunk.nativeMeshEpoch ~= backend.Epoch() then return 0 end
		return backend.GetCell( chunk, li ) or 0
	end
	chunk.blocks = setmetatable( {}, { __index = function( _, li )
		if not isnumber( li ) then return nil end
		local stateId = stateAt( li )
		if stateId == 0 then return nil end
		local id = MC.LegacyFromState( stateId )
		return id
	end } )
	chunk.orients = setmetatable( {}, { __index = function( _, li )
		if not isnumber( li ) then return nil end
		local stateId = stateAt( li )
		if stateId == 0 then return nil end
		local _, orient = MC.LegacyFromState( stateId )
		return orient or 0
	end } )
	return true
end

function MC.GetChunkByKey( key )
	local chunk = MC.World[key]
	if chunk ~= nil then return chunk end
	local canonical = MC.CanonicalChunkKey and MC.CanonicalChunkKey( key ) or key
	if canonical ~= key then return MC.World[canonical] end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if cx then return MC.World[legacyChunkKeyString( cx, cy, cz )] end
	return nil
end

function MC.GetChunk( cx, cy, cz )
	return MC.World[MC.ChunkKey( cx, cy, cz )]
end

function MC.EnsureChunk( cx, cy, cz )
	local key = MC.ChunkKey( cx, cy, cz )
	if MC.MarkChunkLoaded then MC.MarkChunkLoaded( key ) end
	local c = MC.GetChunkByKey( key )
	if not c then
		c = { cx = cx, cy = cy, cz = cz, key = key, blocks = {}, orients = {}, count = 0 }
		MC.World[key] = c
		local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
		if backend and backend.CreateChunk then
			local ok = backend.CreateChunk( c )
			c.chunkBackend = ok == true and backend.name or "lua"
		else
			c.chunkBackend = "lua"
		end
	elseif c.key ~= key then
		if c.key ~= nil then MC.World[c.key] = nil end
		c.key = key
		MC.World[key] = c
	end
	c.cz = c.cz or cz
	if not c.nativeStateStorage then c.orients = c.orients or {} end
	return c
end

function MC.TouchChunkCollisionVersion( chunk )
	if not chunk then return end
	MC.ChunkCollisionVersionCounter = ( MC.ChunkCollisionVersionCounter or 0 ) + 1
	chunk.collisionVersion = MC.ChunkCollisionVersionCounter
	if CLIENT and chunk.key then
		if MC.ClientPhysBuiltSignatures then MC.ClientPhysBuiltSignatures[chunk.key] = nil end
		if MC.ClientPhysBuiltHadObjects then MC.ClientPhysBuiltHadObjects[chunk.key] = nil end
		if MC.ClientPhysBuiltObjectCounts then MC.ClientPhysBuiltObjectCounts[chunk.key] = nil end
		if MC.ClientPhysTargetSignatures then MC.ClientPhysTargetSignatures[chunk.key] = nil end
	end
end

-- Keep the optional client render-section index coherent with a single-cell
-- store mutation.  The index is built lazily by the mesh renderer, so servers
-- and clients that have not built it pay nothing here.  Updating it in place
-- avoids rescanning every block in the chunk after each edit merely because
-- collisionVersion also changed.
local function updateCachedRenderSectionCell( chunk, li, stateId, previousVersion )
	if not CLIENT or not chunk or not chunk.renderSectionBlocks then return end
	local snapshot = MC.RenderSnapshot
	if not snapshot or not snapshot.UpdateCell then
		-- The renderer owns this cache. Never continue with a stale cached cell
		-- if its mutation handler disappeared during a partial Lua refresh.
		chunk.renderSectionBlocks = nil
		chunk.renderSectionBlocksReady = nil
		chunk.renderSectionIndexVersion = nil
		chunk.renderSectionIndexStoresStateId = nil
		chunk.renderSectionIndexStorage = nil
		MC.Fault( "render_snapshot_update_missing", "render snapshot cache exists without its mutation handler" )
		return
	end
	snapshot.UpdateCell( chunk, li, stateId, previousVersion )
end

------------------------------------------------------------------- block access
local STATE_SECTION_HEIGHT = 16
local STATE_SECTION_CELLS = CS2 * STATE_SECTION_HEIGHT

local function stateSectionAddress( li )
	return floor( li / STATE_SECTION_CELLS ) + 1, li % STATE_SECTION_CELLS
end

local function buildStateSectionsFromLegacy( chunk )
	local sections = {}
	for li, id in pairs( chunk.blocks or {} ) do
		if id ~= 0 and MC.LocalIndexInRange( li ) then
			local orient = MC.NormalizeOrient and MC.NormalizeOrient( id, chunk.orients and chunk.orients[li] )
				or ( chunk.orients and chunk.orients[li] or 0 )
			local stateId, _, err = MC.StateFromLegacy( id, orient )
			if stateId == nil then return nil, err or "legacy_state_migration_failed" end
			local sectionIndex, sectionLocalIndex = stateSectionAddress( li )
			local section = sections[sectionIndex]
			if not section then
				section = MC.StateSection.New()
				sections[sectionIndex] = section
			end
			local changed, setError = MC.StateSection.Set( section, sectionLocalIndex, stateId )
			if changed == nil then return nil, setError end
		end
	end
	return sections
end

--- Lazily converts a legacy blocks/orients mirror into the authoritative
-- two-section state store. The replacement is atomic: failed projections do
-- not leave a half-migrated chunk behind.
function MC.MigrateChunkStateStorage( chunk )
	if not chunk then return nil, "missing_chunk" end
	if chunk.nativeStateStorage then
		local native = MC.ChunkBackends and MC.ChunkBackends.native
		if native and native.MaterializeLuaStorage then
			return native.MaterializeLuaStorage( chunk )
		end
		return nil, "native_state_materialization_unavailable"
	end
	if chunk.stateStorageMigrated then return true end
	if not MC.StateSection then return nil, "state_section_unavailable" end
	local sections, err = buildStateSectionsFromLegacy( chunk )
	if not sections then return nil, err end
	chunk.stateSections = sections
	chunk.stateStorageMigrated = true
	chunk.packedStateOnly = nil
	return true
end

--- Marks direct legacy mirror hydration as needing a fresh lazy migration.
-- Bulk loaders that still assign chunk.blocks/chunk.orients must call this
-- once after their final assignment, never once per cell.
function MC.InvalidateChunkStateStorage( chunk )
	if not chunk then return end
	chunk.stateSections = nil
	chunk.stateStorageMigrated = nil
	chunk.packedStateOnly = nil
	chunk.renderSectionIndexStorage = nil
	chunk.renderSectionBlocks = nil
	chunk.renderSectionBlocksReady = nil
	chunk.renderSectionIndexVersion = nil
	chunk.renderSectionIndexStoresStateId = nil
end

--- Starts an empty authoritative chunk payload for future palette-aware bulk
-- loaders. It deliberately does not touch collision/render versions.
function MC.ResetChunkStateStorage( chunk )
	if not chunk then return nil, "missing_chunk" end
	local backend = CLIENT and MC.GetChunkBackend and MC.GetChunkBackend() or nil
	local nativeStorage = backend and backend.native and backend.Epoch
		and chunk.nativeMeshEpoch ~= nil and chunk.nativeMeshEpoch == backend.Epoch()
	chunk.stateSections = nativeStorage and nil or {}
	chunk.stateStorageMigrated = true
	chunk.packedStateOnly = nil
	chunk.nativeStateStorage = nativeStorage == true
	if nativeStorage then
		MC.AttachNativeChunkCompatibilityProxy( chunk )
	else
		chunk.blocks = {}
		chunk.orients = {}
	end
	chunk.blockEntities = nil
	chunk.opaqueBlockEntities = nil
	chunk.opaqueStates = nil
	chunk.count = 0
	if not nativeStorage then chunk.nativeMeshEpoch = nil end
	chunk.renderSectionIndexStorage = nil
	chunk.renderSectionBlocks = nil
	chunk.renderSectionBlocksReady = nil
	chunk.renderSectionIndexVersion = nil
	chunk.renderSectionIndexStoresStateId = nil
	return true
end

--- Bulk-loader primitive. Mutates one chunk-local state without publishing
-- collision/render/network side effects; callers finalize each touched chunk
-- once after the batch. The state section remains authoritative and the old
-- blocks/orients tables are updated only as a derived compatibility mirror.
function MC.SetChunkLocalStateRaw( chunk, li, stateId, knownOldStateId )
	li = math.floor( tonumber( li ) or -1 )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if not chunk or not MC.LocalIndexInRange( li ) then return nil, "invalid_local_index" end
	if stateId < 0 or ( MC.IsValidBlockState and not MC.IsValidBlockState( stateId ) ) then
		return nil, "invalid_state_id"
	end
	local oldStateId = 0
	if chunk.nativeStateStorage then
		local backend = CLIENT and MC.ChunkBackends and MC.ChunkBackends.native or nil
		if knownOldStateId ~= nil then
			oldStateId = math.floor( tonumber( knownOldStateId ) or 0 )
		elseif not MC.NativeChunkBulkLoading and backend and backend.GetCell then
			oldStateId = backend.GetCell( chunk, li ) or 0
		end
		if oldStateId == stateId then
			if MC.ReconcileChunkLocalBlockEntity then
				local reconciled, reconcileError = MC.ReconcileChunkLocalBlockEntity( chunk, li, stateId )
				if reconciled == nil then return nil, reconcileError end
			end
			return false, oldStateId
		end
		if not MC.NativeChunkBulkLoading then
			if not backend or not backend.Epoch or chunk.nativeMeshEpoch ~= backend.Epoch() then
				return nil, "native_state_owner_mismatch"
			end
			local finalCount = chunk.count + ( oldStateId == 0 and 1 or 0 ) - ( stateId == 0 and 1 or 0 )
			local accepted, err = backend.SetCell( chunk, li, stateId, finalCount )
			if not accepted then return nil, err or "native_state_mutation_failed" end
		end
	else
		local migrated, migrationError = MC.MigrateChunkStateStorage( chunk )
		if not migrated then return nil, migrationError end
		local sectionIndex, sectionLocalIndex = stateSectionAddress( li )
		local section = chunk.stateSections[sectionIndex]
		oldStateId = section and MC.StateSection.Get( section, sectionLocalIndex ) or 0
		if oldStateId == stateId then
			if MC.ReconcileChunkLocalBlockEntity then
				local reconciled, reconcileError = MC.ReconcileChunkLocalBlockEntity( chunk, li, stateId )
				if reconciled == nil then return nil, reconcileError end
			end
			return false, oldStateId
		end
		if not section then
			section = MC.StateSection.New()
			chunk.stateSections[sectionIndex] = section
		end
		local changed, setError = MC.StateSection.Set( section, sectionLocalIndex, stateId )
		if changed == nil then return nil, setError end
		if section.count <= 0 then chunk.stateSections[sectionIndex] = nil end
	end

	local id, orient
	if stateId ~= 0 then id, orient = MC.LegacyFromState( stateId ) end
	if not chunk.nativeStateStorage then
		chunk.blocks = chunk.blocks or {}
		chunk.orients = chunk.orients or {}
		if stateId == 0 or id == nil then
			chunk.blocks[li] = nil
			chunk.orients[li] = nil
		else
			chunk.blocks[li] = id
			chunk.orients[li] = orient or 0
		end
	end
	if oldStateId == 0 then chunk.count = ( chunk.count or 0 ) + 1 end
	if stateId == 0 then chunk.count = math.max( 0, ( chunk.count or 0 ) - 1 ) end
	-- Opaque imported Block Entities are archive-only and cannot participate in
	-- lifecycle compatibility checks. Any gameplay state mutation invalidates
	-- the archived attachment at that cell instead of risking an orphan record.
	if chunk.opaqueBlockEntities and chunk.opaqueBlockEntities[li] then
		chunk.opaqueBlockEntities[li] = nil
		if next( chunk.opaqueBlockEntities ) == nil then chunk.opaqueBlockEntities = nil end
	end
	if MC.ReconcileChunkLocalBlockEntity then
		local reconciled, reconcileError = MC.ReconcileChunkLocalBlockEntity( chunk, li, stateId )
		if reconciled == nil and ErrorNoHalt then
			ErrorNoHalt( "[MC] Block Entity default reconciliation failed: "
				.. tostring( reconcileError or "unknown" ) .. "\n" )
		end
	end
	return true, oldStateId, id, orient or 0
end

function MC.FinalizeChunkStateStorage( chunk, blockEntityCells )
	if not chunk then return nil, "missing_chunk" end
	if MC.ReconcileChunkBlockEntities then
		local reconciled, reconcileError = MC.ReconcileChunkBlockEntities( chunk, blockEntityCells )
		if reconciled == nil then return nil, reconcileError end
	end
	MC.TouchChunkCollisionVersion( chunk )
	if CLIENT then
		chunk.renderSectionIndexStorage = nil
		chunk.renderSectionBlocks = nil
		chunk.renderSectionBlocksReady = nil
		chunk.renderSectionIndexVersion = nil
		chunk.renderSectionIndexStoresStateId = nil
	end
	return true
end

function MC.GetBlockState( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	return MC.GetChunkBlockStateByLocalIndex( c, li )
end

function MC.GetChunkBlockStateByLocalIndex( chunk, li )
	if not chunk or not MC.LocalIndexInRange( li ) then return 0 end
	local backend = CLIENT and MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native and backend.GetCell and backend.Epoch
	and chunk.nativeMeshEpoch ~= nil and chunk.nativeMeshEpoch == backend.Epoch() then
		local stateId = backend.GetCell( chunk, li )
		if stateId ~= nil then return stateId end
	end
	local migrated, err = MC.MigrateChunkStateStorage( chunk )
	if not migrated then return nil, err end
	local sectionIndex, sectionLocalIndex = stateSectionAddress( li )
	local section = chunk.stateSections and chunk.stateSections[sectionIndex]
	if not section then return 0 end
	return MC.StateSection.Get( section, sectionLocalIndex ) or 0
end

function MC.GetBlock( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	if not c.nativeStateStorage and not c.packedStateOnly and c.blocks then return c.blocks[li] or 0 end
	local stateId = MC.GetChunkBlockStateByLocalIndex( c, li )
	if not stateId or stateId == 0 then return 0 end
	local id = MC.LegacyFromState( stateId )
	return id or 0
end

function MC.GetBlockOrient( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local c = MC.World[MC.ChunkKey( cx, cy, cz )]
	if not c then return 0 end
	if not c.nativeStateStorage and not c.packedStateOnly and c.blocks then
		local id = c.blocks[li]
		if not id then return 0 end
		return MC.NormalizeOrient and MC.NormalizeOrient( id, c.orients and c.orients[li] ) or ( c.orients and c.orients[li] or 0 )
	end
	local stateId = MC.GetChunkBlockStateByLocalIndex( c, li )
	if not stateId or stateId == 0 then return 0 end
	local _, orient = MC.LegacyFromState( stateId )
	return orient or 0
end

function MC.GetCellBlockBoxes( bx, by, bz )
	local stateId = MC.GetBlockState( bx, by, bz )
	if not stateId or stateId == 0 then return nil end
	return MC.BlockBoxesForState and MC.BlockBoxesForState( stateId, bx, by, bz ) or nil
end

function MC.GetCellCollisionBoxes( bx, by, bz )
	local stateId = MC.GetBlockState( bx, by, bz )
	if not stateId or stateId == 0 then return nil end
	return MC.GetBlockCollisionBoxesForState and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
end

function MC.GetCellBlockExtent( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 or not MC.GetBlockExtent then return nil, nil end
	return MC.GetBlockExtent( id, MC.GetBlockOrient( bx, by, bz ), bx, by, bz )
end

function MC.GetCellShapeInfo( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 or not MC.GetBlockShapeInfo then return nil end
	local info = MC.GetBlockShapeInfo( id, MC.GetBlockOrient( bx, by, bz ), bx, by, bz )
	if info then
		info.bx = bx
		info.by = by
		info.bz = bz
	end
	return info
end

--- Authoritative low-level state mutation used by both realms.
-- stateId zero removes. Returns: chunk, created, emptied, changed[, error].
function MC._SetBlockStateStorageRaw( bx, by, bz, stateId, knownOldStateId )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return nil, false, false, false end
	local key = MC.ChunkKey( cx, cy, cz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 0 or ( MC.IsValidBlockState and not MC.IsValidBlockState( stateId ) ) then
		return nil, false, false, false, "invalid_state_id"
	end

	local c = MC.World[key]
	if stateId == 0 and not c then return nil, false, false, false end
	local created = c == nil
	if not c then c = MC.EnsureChunk( cx, cy, cz ) end
	if not c.nativeStateStorage then
		local migrated, migrationError = MC.MigrateChunkStateStorage( c )
		if not migrated then
			if created then MC.World[key] = nil end
			return nil, false, false, false, migrationError
		end
	end

	local changed, oldOrError, id, orient = MC.SetChunkLocalStateRaw( c, li, stateId, knownOldStateId )
	if changed == nil then
		if created then MC.World[key] = nil end
		return nil, false, false, false, oldOrError
	end
	if not changed then return c, false, false, false end
	local emptied = ( c.count or 0 ) <= 0
	local previousVersion = c.collisionVersion or 0
	if stateId == 0 or id == nil then
		MC.TouchChunkCollisionVersion( c )
		updateCachedRenderSectionCell( c, li, 0, previousVersion )
	else
		MC.TouchChunkCollisionVersion( c )
		updateCachedRenderSectionCell( c, li, stateId, previousVersion )
	end
	if emptied then MC.World[key] = nil end
	if CLIENT and MC.RunEvent then
		MC.RunEvent( "MC.ClientBlockStateChanged", bx, by, bz, oldOrError or 0, stateId, "storage_write" )
	end
	return c, created, emptied, true
end

function MC.SetBlockStateRaw( bx, by, bz, stateId, knownOldStateId )
	return MC._SetBlockStateStorageRaw( bx, by, bz, stateId, knownOldStateId )
end

--- Legacy low-level mutation adapter. New callers should pass stateId to
-- SetBlockStateRaw; blocks/orients remain a compatibility mirror only.
function MC.SetBlockRaw( bx, by, bz, id, orient )
	id = math.floor( tonumber( id ) or 0 )
	orient = id ~= 0 and ( MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or math.floor( tonumber( orient ) or 0 ) ) or 0
	local stateId, _, err = MC.StateFromLegacy( id, orient )
	if stateId == nil then return nil, false, false, false, err end
	return MC.SetBlockStateRaw( bx, by, bz, stateId )
end

--- Iterate authoritative non-air states in deterministic local-index order.
-- cb( bx,by,bz, lx,ly,lz, stateId )
-- Optional stateFilter is evaluated per palette state, before decoding cells.
function MC.ForEachBlockState( chunk, cb, stateFilter )
	if not chunk or not cb then return end
	if chunk.nativeStateStorage then
		local backend = CLIENT and MC.ChunkBackends and MC.ChunkBackends.native or nil
		local cells = backend and backend.GetChunkCells and backend.GetChunkCells( chunk ) or nil
		if not cells then return end
		local ox, oy, oz = chunk.cx * CS, chunk.cy * CS, chunk.cz * CH
		if stateFilter then
			local selected = {}
			for i = 1, #cells, 2 do
				local li, stateId = cells[i], cells[i + 1]
				local accepted = selected[stateId]
				if accepted == nil then
					accepted = not not stateFilter( stateId )
					selected[stateId] = accepted
				end
				if accepted then
					local lx, ly, lz = MC.DecodeLocal( li )
					cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, stateId )
				end
			end
			return
		end
		for i = 1, #cells, 2 do
			local li, stateId = cells[i], cells[i + 1]
			local lx, ly, lz = MC.DecodeLocal( li )
			cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, stateId )
		end
		return
	end
	local migrated = MC.MigrateChunkStateStorage( chunk )
	if not migrated then return end
	local ox, oy, oz = chunk.cx * CS, chunk.cy * CS, chunk.cz * CH
	for sectionIndex = 1, 2 do
		local section = chunk.stateSections and chunk.stateSections[sectionIndex]
		if section then
			MC.StateSection.ForEach( section, function( sectionLocalIndex, stateId )
				local li = ( sectionIndex - 1 ) * STATE_SECTION_CELLS + sectionLocalIndex
				local lx, ly, lz = MC.DecodeLocal( li )
				cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, stateId )
			end, stateFilter )
		end
	end
end

--- Iterate every (bx,by,bz,id,orient) in a chunk. cb( bx,by,bz, lx,ly,lz, id, orient )
function MC.ForEachBlock( chunk, cb )
	if chunk.nativeStateStorage or chunk.packedStateOnly or not chunk.blocks then
		return MC.ForEachBlockState( chunk, function( bx, by, bz, lx, ly, lz, stateId )
			local id, orient = MC.LegacyFromState( stateId )
			if id then cb( bx, by, bz, lx, ly, lz, id, orient or 0 ) end
		end )
	end
	local ox, oy, oz = chunk.cx * CS, chunk.cy * CS, chunk.cz * CH
	chunk.orients = chunk.orients or {}
	for li, id in pairs( chunk.blocks or {} ) do
		local lx, ly, lz = MC.DecodeLocal( li )
		local orient = MC.NormalizeOrient and MC.NormalizeOrient( id, chunk.orients[li] ) or ( chunk.orients[li] or 0 )
		cb( ox + lx, oy + ly, oz + lz, lx, ly, lz, id, orient )
	end
end
