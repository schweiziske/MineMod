--[[----------------------------------------------------------------------------
	MC : shared block-cluster helpers.

	A cluster is an arbitrary set of grid cells captured into one movable
	physics entity (mc_block_cluster). Cells are stored relative to the
	cluster's min corner as a flat array { dx, dy, dz, stateId, ... }; the
	entity origin sits at the world position of local cell (0,0,0)'s min
	corner, so a cell's local offset is simply d * MC.BS.

	Rotation is a 0..3 quarter turn about +Z using the same cell/state
	transform family as presets (sh_presets.lua), so pasted structures keep
	facing/axis/connection properties consistent with preset placement.
------------------------------------------------------------------------------]]

MC = MC or {}

if CLIENT then MC.I18n.BindPhrase( "mc.cluster.undo_text", "cluster.undo_text" ) end

-- Engine-style rendering extras (VertexLit engine lighting, RTT shadow hack,
-- color tool support, spawn FX) collected behind one switch after playtesting
-- hit too many physgun-interaction bugs. false = the stable classic look
-- (unlit atlas + baked face shading, no shadow). Flip to true to iterate on
-- the engine-style pipeline again.
MC.ClusterEngineStyle = false

-- Tunable physics limits (convars below; this table is the fallback when no
-- convar exists, e.g. pure-Lua test environments). Live-tested guidance
-- (2026-07-26):
--  * maxConvexes — precise-mode cap. Moving multiconvex impacts against
--    chunk collision crash srcds probabilistically, scaling with convex
--    count: 64 keeps the dice small; 256 initialized fine frozen but died
--    on unfreeze/impact. Crate-mode records bypass the cap entirely.
--  * mergeCells — max merged box edge in cells. IVP can crash outright on
--    very large single convexes; everything proven in this addon stays
--    within the 8-cell collision-subchunk envelope.
--  * collisionInset — per-face collision skin shrink in units, so
--    converted-in-place structures never start flush / zero-distance
--    against the surrounding chunk collision.
MC.ClusterDefaults = {
	maxConvexes = 64,
	mergeCells = 8,
	collisionInset = 0.5,
}
MC.ClusterPayloadMaxBytes = 56000
MC.ClusterAbsoluteMaxBlocks = 8191 -- convert net message count field is 13 bits

if SERVER then
	local F = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.ClusterMaxBlocks = GetConVar( "mc_cluster_max_blocks" )
		or CreateConVar( "mc_cluster_max_blocks", "8191", F, "Max blocks one cluster entity may hold", 1, MC.ClusterAbsoluteMaxBlocks )
	MC.Config.ClusterMaxExtent = GetConVar( "mc_cluster_max_extent" )
		or CreateConVar( "mc_cluster_max_extent", "96", F, "Max cluster selection edge length in blocks", 1, 255 )
	MC.Config.ClusterHealthPerBlock = GetConVar( "mc_cluster_health_per_block" )
		or CreateConVar( "mc_cluster_health_per_block", "4", F, "Cluster entity health per block; 0 = indestructible" )
	MC.Config.ClusterMassPerBlock = GetConVar( "mc_cluster_mass_per_block" )
		or CreateConVar( "mc_cluster_mass_per_block", "10", F, "Cluster entity mass per block (kg)" )
	MC.Config.ClusterMaxPerPlayer = GetConVar( "mc_cluster_max_per_player" )
		or CreateConVar( "mc_cluster_max_per_player", "8", F, "Max cluster entities per player; 0 = unlimited" )
	MC.Config.ClusterMaxConvexes = GetConVar( "mc_cluster_max_convexes" )
		or CreateConVar( "mc_cluster_max_convexes", "64", F,
			"Max collision convexes per precise-mode cluster (crate mode bypasses). 64 tested-safe; higher risks srcds crashes on unfreeze/impact", 1, 1024 )
	MC.Config.ClusterMergeCells = GetConVar( "mc_cluster_merge_cells" )
		or CreateConVar( "mc_cluster_merge_cells", "8", F,
			"Max merged collision box edge in cells; above the 8-cell envelope IVP can crash srcds on large convexes", 1, 32 )
	MC.Config.ClusterCollisionInset = GetConVar( "mc_cluster_collision_inset" )
		or CreateConVar( "mc_cluster_collision_inset", "0.5", F,
			"Collision skin inset per face in units; keeps converted structures from starting flush against block collision. 0 disables", 0, 8 )

	-- Lua-created FCVAR_REPLICATED convars never actually reach clients
	-- (long-standing engine bug), so the client would enforce default caps
	-- (e.g. select up to 8191 while the server caps at 5000) and build its
	-- prediction mirror with mismatched physics settings. Push every limit
	-- the client reads as a networked global instead; change callbacks keep
	-- live edits in sync.
	local REPLICATED_LIMITS = {
		{ name = "mc_cluster_max_blocks" },
		{ name = "mc_cluster_max_extent" },
		{ name = "mc_cluster_max_convexes" },
		{ name = "mc_cluster_merge_cells" },
		{ name = "mc_cluster_collision_inset", float = true },
	}
	local function pushLimit( entry )
		local cv = GetConVar( entry.name )
		if not cv then return end
		if entry.float then
			SetGlobalFloat( entry.name, cv:GetFloat() )
		else
			SetGlobalInt( entry.name, cv:GetInt() )
		end
	end
	local function pushAllLimits()
		for _, entry in ipairs( REPLICATED_LIMITS ) do pushLimit( entry ) end
	end
	for _, entry in ipairs( REPLICATED_LIMITS ) do
		cvars.RemoveChangeCallback( entry.name, "mc_cluster_limit_push" )
		cvars.AddChangeCallback( entry.name, function() pushLimit( entry ) end, "mc_cluster_limit_push" )
	end
	pushAllLimits()
	hook.Add( "InitPostEntity", "mc_cluster_limit_push", pushAllLimits )
end

-- Server reads the convar; clients read the server-pushed networked global
-- (see REPLICATED_LIMITS above). Pure-Lua test environments have neither and
-- land on the default.
local function clampedConVarInt( name, default, minValue, maxValue )
	local value
	if SERVER then
		local cv = GetConVar( name )
		value = cv and cv:GetInt() or default
	else
		value = GetGlobalInt and GetGlobalInt( name, default ) or default
	end
	return math.Clamp( math.floor( tonumber( value ) or default ), minValue, maxValue )
end

local function clampedConVarFloat( name, default, minValue, maxValue )
	local value
	if SERVER then
		local cv = GetConVar( name )
		value = cv and cv:GetFloat() or default
	else
		value = GetGlobalFloat and GetGlobalFloat( name, default ) or default
	end
	return math.Clamp( tonumber( value ) or default, minValue, maxValue )
end

function MC.ClusterMaxBlocks()
	return clampedConVarInt( "mc_cluster_max_blocks", 8191, 1, MC.ClusterAbsoluteMaxBlocks )
end

function MC.ClusterMaxExtent()
	return clampedConVarInt( "mc_cluster_max_extent", 96, 1, 255 )
end

function MC.ClusterMaxConvexes()
	return clampedConVarInt( "mc_cluster_max_convexes", MC.ClusterDefaults.maxConvexes, 1, 1024 )
end

function MC.ClusterMaxMergeCells()
	return clampedConVarInt( "mc_cluster_merge_cells", MC.ClusterDefaults.mergeCells, 1, 32 )
end

function MC.ClusterCollisionInset()
	return clampedConVarFloat( "mc_cluster_collision_inset", MC.ClusterDefaults.collisionInset, 0, 8 )
end

--------------------------------------------------------------- payload codec
-- One codec feeds three consumers: the entity payload served to clients, the
-- per-save-slot clusters sidecar file, and the load-time validator.

function MC.ClusterEncode( record )
	if not record or not istable( record.cells ) or not istable( record.size ) then return nil, "invalid_record" end
	local json = util.TableToJSON( {
		v = 1,
		size = record.size,
		cells = record.cells,
		crate = record.crate == true or nil,
	} )
	if not json then return nil, "encode_failed" end
	local compressed = util.Compress( json )
	if not compressed or #compressed == 0 then return nil, "compress_failed" end
	if #compressed > MC.ClusterPayloadMaxBytes then return nil, "payload_too_large" end
	return compressed
end

function MC.ClusterDecode( blob )
	if not isstring( blob ) or blob == "" then return nil, "empty_payload" end
	local json = util.Decompress( blob )
	if not json then return nil, "decompress_failed" end
	local data = util.JSONToTable( json )
	local ok, err = MC.ClusterValidateRecord( data )
	if not ok then return nil, err end
	return { size = data.size, cells = data.cells, crate = data.crate == true }
end

function MC.ClusterValidateRecord( data )
	if not istable( data ) or not istable( data.cells ) or not istable( data.size ) then return false, "invalid_record" end
	local sx = math.floor( tonumber( data.size[1] ) or 0 )
	local sy = math.floor( tonumber( data.size[2] ) or 0 )
	local sz = math.floor( tonumber( data.size[3] ) or 0 )
	if sx < 1 or sy < 1 or sz < 1 or sx > 255 or sy > 255 or sz > 255 then return false, "invalid_size" end
	data.size[1], data.size[2], data.size[3] = sx, sy, sz

	local cells = data.cells
	local n = #cells
	if n == 0 or n % 4 ~= 0 then return false, "invalid_cells" end
	if n / 4 > MC.ClusterAbsoluteMaxBlocks then return false, "too_many_cells" end
	for i = 1, n, 4 do
		local dx = math.floor( tonumber( cells[i] ) or -1 )
		local dy = math.floor( tonumber( cells[i + 1] ) or -1 )
		local dz = math.floor( tonumber( cells[i + 2] ) or -1 )
		local stateId = math.floor( tonumber( cells[i + 3] ) or 0 )
		if dx < 0 or dx >= sx or dy < 0 or dy >= sy or dz < 0 or dz >= sz then return false, "cell_out_of_bounds" end
		if stateId <= 0 or ( MC.IsValidBlockState and not MC.IsValidBlockState( stateId ) ) then return false, "invalid_cell_state" end
		cells[i], cells[i + 1], cells[i + 2], cells[i + 3] = dx, dy, dz, stateId
	end
	return true
end

------------------------------------------------------------------- rotation
-- Quarter turns about +Z with the preset convention: r=1 maps local +X to +Y
-- (counter-clockwise seen from above, matching increasing entity yaw).

function MC.ClusterRotationFromYaw( yaw )
	return math.Round( math.NormalizeAngle( tonumber( yaw ) or 0 ) / 90 ) % 4
end

-- Returns a new flat cell array plus the rotated size; coordinates stay
-- 0-based so the rotated structure's min corner is again local (0,0,0).
function MC.ClusterRotateCells( cells, size, rotation )
	rotation = math.floor( tonumber( rotation ) or 0 ) % 4
	local sx = math.floor( tonumber( size[1] ) or 1 )
	local sy = math.floor( tonumber( size[2] ) or 1 )
	local sz = math.floor( tonumber( size[3] ) or 1 )
	if rotation == 0 then return cells, { sx, sy, sz } end

	local out = {}
	local n = 0
	for i = 1, #cells, 4 do
		local dx, dy, dz, stateId = cells[i], cells[i + 1], cells[i + 2], cells[i + 3]
		local rx, ry
		if rotation == 1 then
			rx, ry = sy - 1 - dy, dx
		elseif rotation == 2 then
			rx, ry = sx - 1 - dx, sy - 1 - dy
		else
			rx, ry = dy, sx - 1 - dx
		end
		if MC.PresetRotateState then stateId = MC.PresetRotateState( stateId, rotation ) end
		out[n + 1], out[n + 2], out[n + 3], out[n + 4] = rx, ry, dz, stateId
		n = n + 4
	end
	if rotation % 2 == 1 then
		return out, { sy, sx, sz }
	end
	return out, { sx, sy, sz }
end

-- World-space offset of the rotated structure's AABB min corner relative to
-- the entity origin (local cell (0,0,0) corner), for a snapped quarter turn.
function MC.ClusterRotatedMinOffset( rotatedSize, rotation )
	rotation = math.floor( tonumber( rotation ) or 0 ) % 4
	local BS = MC.BS
	if rotation == 1 then return Vector( -rotatedSize[1] * BS, 0, 0 ) end
	if rotation == 2 then return Vector( -rotatedSize[1] * BS, -rotatedSize[2] * BS, 0 ) end
	if rotation == 3 then return Vector( 0, -rotatedSize[2] * BS, 0 ) end
	return Vector( 0, 0, 0 )
end

-- Snap an entity transform to the grid: rotation quarter + target min cell.
-- Returns nil when the entity is tilted too far to map onto the grid.
function MC.ClusterComputeSnap( pos, ang )
	local pitch = math.NormalizeAngle( ang.p )
	local roll = math.NormalizeAngle( ang.r )
	if math.abs( pitch ) > 7 or math.abs( roll ) > 7 then return nil, "tilted" end

	local rotation = MC.ClusterRotationFromYaw( ang.y )
	return { rotation = rotation, pos = pos }
end

-- Resolve the snapped world target cells of a record placed at pos/rotation.
-- Returns targetMin = {tx,ty,tz}, rotatedCells, rotatedSize.
function MC.ClusterSnapTargets( record, pos, rotation )
	local rotatedCells, rotatedSize = MC.ClusterRotateCells( record.cells, record.size, rotation )
	local offset = MC.ClusterRotatedMinOffset( rotatedSize, rotation )
	local BS = MC.BS
	local tx = math.Round( ( pos.x + offset.x ) / BS )
	local ty = math.Round( ( pos.y + offset.y ) / BS )
	local tz = math.Round( ( pos.z + offset.z ) / BS )
	return { tx, ty, tz }, rotatedCells, rotatedSize
end

------------------------------------------------------------ physics building
-- Collision skin inset (mc_cluster_collision_inset): every convex shrinks
-- inward so converted-in-place structures never start flush / zero-distance
-- against the surrounding chunk collision (the unfreeze contact burst and
-- seam grinding both start there). Uniform per-box inset — adjacent merged
-- boxes gain a 2*inset internal gap, accepted for simplicity. Thin shapes
-- clamp so carpets/plates cannot shrink away. Visually invisible at 0.5u on
-- 36.5u blocks; paste snapping uses the entity transform and is unaffected.
local function axisInset( extent )
	local inset = MC.ClusterCollisionInset()
	if inset <= 0 or extent <= 0 then return 0 end
	return math.min( inset, extent * 0.25 )
end

local function cellIndex( dx, dy, dz, sx, sy )
	return dx + dy * sx + dz * sx * sy
end

local function appendBoxConvex( convexes, x0, y0, z0, x1, y1, z1 )
	local BS = MC.BS
	x0, y0, z0 = x0 * BS, y0 * BS, z0 * BS
	x1, y1, z1 = x1 * BS, y1 * BS, z1 * BS
	local ix = axisInset( x1 - x0 )
	local iy = axisInset( y1 - y0 )
	local iz = axisInset( z1 - z0 )
	x0, y0, z0 = x0 + ix, y0 + iy, z0 + iz
	x1, y1, z1 = x1 - ix, y1 - iy, z1 - iz
	convexes[#convexes + 1] = {
		Vector( x0, y0, z0 ), Vector( x1, y0, z0 ),
		Vector( x0, y1, z0 ), Vector( x1, y1, z0 ),
		Vector( x0, y0, z1 ), Vector( x1, y0, z1 ),
		Vector( x0, y1, z1 ), Vector( x1, y1, z1 ),
	}
end

-- Arbitrary convex point sets (stairs etc.): approximate the inward offset
-- with a per-axis shrink toward the centroid — exact for boxes, negligible
-- slope change for wedges at 0.5u scale.
local function insetConvexPoints( points )
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in ipairs( points ) do
		minX, minY, minZ = math.min( minX, p.x ), math.min( minY, p.y ), math.min( minZ, p.z )
		maxX, maxY, maxZ = math.max( maxX, p.x ), math.max( maxY, p.y ), math.max( maxZ, p.z )
	end
	local ex, ey, ez = maxX - minX, maxY - minY, maxZ - minZ
	local sx = ex > 0 and ( ex - 2 * axisInset( ex ) ) / ex or 1
	local sy = ey > 0 and ( ey - 2 * axisInset( ey ) ) / ey or 1
	local sz = ez > 0 and ( ez - 2 * axisInset( ez ) ) / ez or 1
	local cx, cy, cz = ( minX + maxX ) * 0.5, ( minY + maxY ) * 0.5, ( minZ + maxZ ) * 0.5
	for _, p in ipairs( points ) do
		p.x = cx + ( p.x - cx ) * sx
		p.y = cy + ( p.y - cy ) * sy
		p.z = cz + ( p.z - cz ) * sz
	end
	return points
end

-- Build entity-local physics convexes for a cluster record. Full-cube
-- collision cells greedy-merge into boxes (X run, then Y, then Z, same
-- ordering as the chunk collision merger); every other collision shape keeps
-- its exact per-cell boxes/convexes. Returns convexes, or nil + reason
-- (+ count when the convex cap is exceeded).
function MC.BuildClusterConvexes( cells, size )
	local sx, sy, sz = size[1], size[2], size[3]
	local solid = {}
	local extra = {}

	for i = 1, #cells, 4 do
		local dx, dy, dz, stateId = cells[i], cells[i + 1], cells[i + 2], cells[i + 3]
		local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId, dx, dy, dz ) or nil
		if visual and ( not MC.BlockVisualHasCollision or MC.BlockVisualHasCollision( visual, dx, dy, dz ) ) then
			if MC.BlockVisualIsFullCube and MC.BlockVisualIsFullCube( visual, dx, dy, dz ) then
				solid[cellIndex( dx, dy, dz, sx, sy )] = true
			else
				local convexList = MC.BlockVisualCollisionConvexes and MC.BlockVisualCollisionConvexes( visual, dx, dy, dz ) or nil
				if convexList and #convexList > 0 then
					for _, convex in ipairs( convexList ) do
						extra[#extra + 1] = { convex = convex, dx = dx, dy = dy, dz = dz }
					end
				else
					local boxes = MC.BlockVisualCollisionBoxes and MC.BlockVisualCollisionBoxes( visual, dx, dy, dz ) or nil
					if not boxes or #boxes == 0 then boxes = { { 0, 0, 0, 1, 1, 1 } } end
					for _, box in ipairs( boxes ) do
						extra[#extra + 1] = { box = box, dx = dx, dy = dy, dz = dz }
					end
				end
			end
		end
	end

	local convexes = {}
	local visited = {}
	local mergeLimit = MC.ClusterMaxMergeCells()
	for dz = 0, sz - 1 do
		for dy = 0, sy - 1 do
			for dx = 0, sx - 1 do
				local li = cellIndex( dx, dy, dz, sx, sy )
				if solid[li] and not visited[li] then
					local x1 = dx
					while x1 + 1 < sx and x1 - dx + 1 < mergeLimit do
						local i2 = cellIndex( x1 + 1, dy, dz, sx, sy )
						if solid[i2] and not visited[i2] then x1 = x1 + 1 else break end
					end

					local y1 = dy
					while y1 + 1 < sy and y1 - dy + 1 < mergeLimit do
						local rowOK = true
						for x = dx, x1 do
							local i2 = cellIndex( x, y1 + 1, dz, sx, sy )
							if not solid[i2] or visited[i2] then rowOK = false break end
						end
						if not rowOK then break end
						y1 = y1 + 1
					end

					local z1 = dz
					while z1 + 1 < sz and z1 - dz + 1 < mergeLimit do
						local layerOK = true
						for y = dy, y1 do
							for x = dx, x1 do
								local i2 = cellIndex( x, y, z1 + 1, sx, sy )
								if not solid[i2] or visited[i2] then layerOK = false break end
							end
							if not layerOK then break end
						end
						if not layerOK then break end
						z1 = z1 + 1
					end

					for z = dz, z1 do
						for y = dy, y1 do
							for x = dx, x1 do
								visited[cellIndex( x, y, z, sx, sy )] = true
							end
						end
					end
					appendBoxConvex( convexes, dx, dy, dz, x1 + 1, y1 + 1, z1 + 1 )
				end
			end
		end
	end

	local BS = MC.BS
	for _, part in ipairs( extra ) do
		if part.box then
			local b = part.box
			appendBoxConvex( convexes,
				part.dx + ( tonumber( b[1] ) or 0 ), part.dy + ( tonumber( b[2] ) or 0 ), part.dz + ( tonumber( b[3] ) or 0 ),
				part.dx + ( tonumber( b[4] ) or 1 ), part.dy + ( tonumber( b[5] ) or 1 ), part.dz + ( tonumber( b[6] ) or 1 ) )
		else
			local points = {}
			for _, p in ipairs( part.convex ) do
				local px = tonumber( p[1] or p.x )
				local py = tonumber( p[2] or p.y )
				local pz = tonumber( p[3] or p.z )
				if px and py and pz then
					points[#points + 1] = Vector( ( part.dx + px ) * BS, ( part.dy + py ) * BS, ( part.dz + pz ) * BS )
				end
			end
			if #points >= 4 then convexes[#convexes + 1] = insetConvexPoints( points ) end
		end
	end

	if #convexes == 0 then return nil, "no_collision" end
	if #convexes > MC.ClusterMaxConvexes() then return nil, "too_complex", #convexes end
	return convexes
end

-- Collision for a record. Crate records ("箱体" conversions) collide as one
-- full-size AABB box — physically trivial regardless of structure size —
-- while precise records use the greedy multiconvex under the convex cap.
-- The block cells stay exact either way, so paste-back is always precise.
function MC.ClusterCollisionConvexes( record )
	if record.crate == true then
		local x1 = record.size[1] * MC.BS
		local y1 = record.size[2] * MC.BS
		local z1 = record.size[3] * MC.BS
		local ix, iy, iz = axisInset( x1 ), axisInset( y1 ), axisInset( z1 )
		return { {
			Vector( ix, iy, iz ), Vector( x1 - ix, iy, iz ),
			Vector( ix, y1 - iy, iz ), Vector( x1 - ix, y1 - iy, iz ),
			Vector( ix, iy, z1 - iz ), Vector( x1 - ix, iy, z1 - iz ),
			Vector( ix, y1 - iy, z1 - iz ), Vector( x1 - ix, y1 - iy, z1 - iz ),
		} }
	end
	return MC.BuildClusterConvexes( record.cells, record.size )
end
