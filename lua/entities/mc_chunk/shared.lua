--[[----------------------------------------------------------------------------
	mc_chunk : one render owner per non-empty 16x16x32 Minecraft-style chunk section.
	  server -> provides collision (8x8x8 subchunk multiconvex via mc_chunk_phys)
	  client -> draws the chunk's IMesh (MC.DrawChunk) and hosts the local
	            prediction collision: a small interest-bounds multiconvex built
	            directly on this networked shell entity. The client never touches
	            mc_chunk_phys entities, so server-side collision entity churn
	            cannot break prediction.
	Sections can stack vertically.
------------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "MC Chunk"
ENT.Author    = "MC"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.DisableDuplicator = true

local PHYSICS_CONVEXES_PER_ENTITY = 128
local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local PHYSICS_SUBCHUNK_SIZE = MC.CollisionSubchunkSize or 8

local function ensurePhysicsModel( ent )
	if not IsValid( ent ) then return end
	if ent:GetModel() ~= PHYSICS_MODEL then
		ent:SetModel( PHYSICS_MODEL )
	end
end

local function freezePhysicsObject( ent )
	local phys = ent:GetPhysicsObject()
	if IsValid( phys ) then
		phys:EnableMotion( false )
		phys:Wake()
		return true
	end
	return false
end

local function clientCollisionAABBOnly()
	return CLIENT
end

local function removeSubchunkEntity( subchunk )
	if not IsValid( subchunk ) then return end

	if CLIENT and subchunk:EntIndex() > 0 then
		subchunk:PhysicsDestroy()
		subchunk:SetSolid( SOLID_NONE )
		return
	end

	subchunk:Remove()
end

function ENT:ClearPhysicsSubchunks()
	local subchunks = self.PhysicsSubchunks
	if not subchunks then return end
	for _, subchunk in ipairs( subchunks ) do
		removeSubchunkEntity( subchunk )
	end
	self.PhysicsSubchunks = nil
	self.PhysicsSubchunksByKey = nil
end

ENT.ClearPhysicsShards = ENT.ClearPhysicsSubchunks

-- Server-only: collision subchunk entities exist for authoritative collision and
-- bullet/trace damage. The client's prediction collision lives on the mc_chunk
-- shell instead (see RebuildPhysics), so no clientside spawn/match path exists.
local function spawnPhysicsSubchunk( owner, index, group, convexes, pageIndex )
	pageIndex = math.floor( tonumber( pageIndex ) or 0 )
	local subchunk = ents.Create( "mc_chunk_phys" )
	if not IsValid( subchunk ) then return nil end

	subchunk.ChunkKey = owner.ChunkKey
	subchunk.cx, subchunk.cy, subchunk.cz = owner.cx, owner.cy, owner.cz
	subchunk.ParentChunk = owner
	subchunk.SubchunkIndex = index
	subchunk.CollisionSubchunkKey = group.key
	subchunk.CollisionPhysPage = pageIndex
	subchunk:SetNWString( "MCChunkKey", tostring( owner.ChunkKey ) )
	subchunk:SetNWString( "MCSubchunkKey", tostring( group.key ) )
	subchunk:SetNWInt( "MCPhysPage", pageIndex )
	ensurePhysicsModel( subchunk )
	subchunk:SetPos( owner:GetPos() )
	subchunk:SetAngles( Angle( 0, 0, 0 ) )
	if subchunk.Spawn then subchunk:Spawn() end
	if subchunk.Activate then subchunk:Activate() end
	subchunk:SetNoDraw( true )

	if not subchunk.ApplyPhysicsConvexes or not subchunk:ApplyPhysicsConvexes( convexes or group.convexes ) then
		subchunk:Remove()
		return nil, "apply_failed"
	end
	return subchunk
end

local function rememberPhysicsSubchunk( subchunks, byKey, group, subchunk )
	subchunks[#subchunks + 1] = subchunk
	local list = byKey[group.key]
	if not list then
		list = {}
		byKey[group.key] = list
	end
	list[#list + 1] = subchunk
end

local function spawnPhysicsSubchunkPages( owner, group, subchunks, byKey )
	local built = 0
	for first = 1, #group.convexes, PHYSICS_CONVEXES_PER_ENTITY do
		local part = {}
		local last = math.min( #group.convexes, first + PHYSICS_CONVEXES_PER_ENTITY - 1 )
		for i = first, last do
			part[#part + 1] = group.convexes[i]
		end

		local pageIndex = math.floor( ( first - 1 ) / PHYSICS_CONVEXES_PER_ENTITY )
		local subchunk, reason = spawnPhysicsSubchunk( owner, #subchunks + 1, group, part, pageIndex )
		if not IsValid( subchunk ) then return built, false, #part, reason end
		rememberPhysicsSubchunk( subchunks, byKey, group, subchunk )
		built = built + 1
	end
	return built, true, 0
end

local function countValidSubchunkPhysics( subchunks )
	local count = 0
	for _, subchunk in ipairs( subchunks or {} ) do
		if IsValid( subchunk ) and IsValid( subchunk:GetPhysicsObject() ) then
			count = count + 1
		end
	end
	return count
end

local function shouldPrintClientPhysStats( ent, mode, bounds, boxes, customConvexes, convexes, subchunkCount, subchunkObjects )
	if not CLIENT then return false end
	local key = tostring( ent and ent.ChunkKey or "" )
	local sig = table.concat( {
		key,
		tostring( mode ),
		tostring( bounds and #bounds or "full" ),
		tostring( boxes ),
		tostring( customConvexes ),
		tostring( convexes ),
		tostring( subchunkCount ),
		tostring( subchunkObjects ),
		tostring( IsValid( ent and ent:GetPhysicsObject() ) ),
	}, "|" )
	MC.ClientPhysDebugPrintState = MC.ClientPhysDebugPrintState or {}
	local state = MC.ClientPhysDebugPrintState[key]
	local now = CurTime()
	if state and state.sig == sig and now < state.nextPrint then return false end
	MC.ClientPhysDebugPrintState[key] = { sig = sig, nextPrint = now + 1.0 }
	return true
end

local function rememberClientPhysStats( ent, mode, bounds, boxes, customConvexes, convexes, subchunks )
	if not CLIENT then return end
	MC.ClientPhysStats = MC.ClientPhysStats or {}
	local subchunkCount = subchunks and #subchunks or 0
	local subchunkObjects = countValidSubchunkPhysics( subchunks )
	MC.ClientPhysStats.lastClientPhysMode = mode
	MC.ClientPhysStats.lastClientPhysChunkKey = tostring( ent.ChunkKey )
	MC.ClientPhysStats.lastClientPhysInputBounds = bounds and #bounds or "full"
	MC.ClientPhysStats.lastClientPhysBoxes = boxes
	MC.ClientPhysStats.lastClientPhysCustomConvexes = customConvexes
	MC.ClientPhysStats.lastClientPhysConvexes = convexes
	MC.ClientPhysStats.lastClientPhysSubchunks = subchunkCount
	MC.ClientPhysStats.lastClientPhysSubchunkObjects = subchunkObjects
	MC.ClientPhysStats.lastClientPhysShards = subchunkCount
	MC.ClientPhysStats.lastClientPhysShardObjects = subchunkObjects
	MC.ClientPhysStats.lastClientPhysMainObject = IsValid( ent:GetPhysicsObject() )
	MC.ClientPhysStats.lastClientPhysReason = nil
	if MC.ClientCollisionDebug and MC.ClientCollisionDebug:GetBool()
	and shouldPrintClientPhysStats( ent, mode, bounds, boxes, customConvexes, convexes, subchunkCount, subchunkObjects ) then
		print( "[MC][client-phys] chunk=" .. tostring( ent.ChunkKey ) ..
			" mode=" .. tostring( mode ) ..
			" bounds=" .. tostring( bounds and #bounds or "full" ) ..
			" boxes=" .. tostring( boxes ) ..
			" customConvexes=" .. tostring( customConvexes ) ..
			" convexes=" .. tostring( convexes ) ..
			" subchunks=" .. tostring( subchunkCount ) ..
			" subchunkPhys=" .. tostring( subchunkObjects ) ..
			" mainPhys=" .. tostring( IsValid( ent:GetPhysicsObject() ) ) )
	end
end

local function clearClientAABBDebugBoxes( ent )
	if not CLIENT then return end
	local key = ent and ent.ChunkKey
	if key and MC.ClientCollisionAABBDebugBoxes then
		MC.ClientCollisionAABBDebugBoxes[key] = nil
	end
end

local function rememberClientAABBDebugBoxes( ent, boxes )
	if not CLIENT then return end
	local key = ent and ent.ChunkKey
	if not key then return end
	MC.ClientCollisionAABBDebugBoxes = MC.ClientCollisionAABBDebugBoxes or {}
	if not boxes or #boxes == 0 then
		MC.ClientCollisionAABBDebugBoxes[key] = nil
		return
	end

	local origin = ent:GetPos()
	local bs = MC.BS
	local out = {}
	for i, b in ipairs( boxes ) do
		out[i] = {
			mins = origin + Vector( b[1] * bs, b[2] * bs, b[3] * bs ),
			maxs = origin + Vector( b[4] * bs, b[5] * bs, b[6] * bs ),
		}
	end
	MC.ClientCollisionAABBDebugBoxes[key] = out
end

function ENT:ClearClientCollisionAABBDebugBoxes()
	clearClientAABBDebugBoxes( self )
end

function ENT:EnsureKey()
	if self.ChunkKey then return self.ChunkKey end
	local cx, cy, cz = MC.ChunkCoordsFromOrigin( self:GetPos() )
	self.cx, self.cy, self.cz = cx, cy, cz
	self.ChunkKey = MC.ChunkKey( cx, cy, cz )
	if SERVER then
		self:SetNWString( "MCChunkKey", tostring( self.ChunkKey ) )
	end
	return self.ChunkKey
end

local function collisionWindowsForBounds( bounds )
	local CS = MC.CS
	local CH = MC.CH
	local size = PHYSICS_SUBCHUNK_SIZE
	local ordered = {}

	local function addWindow( sx, sy, sz, x0, y0, z0, x1, y1, z1 )
		ordered[#ordered + 1] = {
			sx = sx,
			sy = sy,
			sz = sz,
			x0 = x0,
			y0 = y0,
			z0 = z0,
			x1 = x1,
			y1 = y1,
			z1 = z1,
		}
	end

	if bounds then
		for _, b in ipairs( bounds ) do
			local bx0 = math.max( 0, math.floor( tonumber( b[1] ) or 0 ) )
			local by0 = math.max( 0, math.floor( tonumber( b[2] ) or 0 ) )
			local bz0 = math.max( 0, math.floor( tonumber( b[3] ) or 0 ) )
			local bx1 = math.min( CS, math.floor( tonumber( b[4] ) or -1 ) + 1 )
			local by1 = math.min( CS, math.floor( tonumber( b[5] ) or -1 ) + 1 )
			local bz1 = math.min( CH, math.floor( tonumber( b[6] ) or -1 ) + 1 )
			if bx0 < bx1 and by0 < by1 and bz0 < bz1 then
				local sx0 = math.floor( bx0 / size ) * size
				local sy0 = math.floor( by0 / size ) * size
				local sz0 = math.floor( bz0 / size ) * size
				local sx1 = math.floor( ( bx1 - 1 ) / size ) * size
				local sy1 = math.floor( ( by1 - 1 ) / size ) * size
				local sz1 = math.floor( ( bz1 - 1 ) / size ) * size
				for sz = sz0, sz1, size do
					for sy = sy0, sy1, size do
						for sx = sx0, sx1, size do
							local xLimit = math.min( CS, sx + size )
							local yLimit = math.min( CS, sy + size )
							local zLimit = math.min( CH, sz + size )
							addWindow( sx, sy, sz,
								math.max( bx0, sx ), math.max( by0, sy ), math.max( bz0, sz ),
								math.min( bx1, xLimit ), math.min( by1, yLimit ), math.min( bz1, zLimit ) )
						end
					end
				end
			end
		end
	else
		for sz = 0, CH - 1, size do
			for sy = 0, CS - 1, size do
				for sx = 0, CS - 1, size do
					addWindow( sx, sy, sz, sx, sy, sz,
						math.min( CS, sx + size ),
						math.min( CS, sy + size ),
						math.min( CH, sz + size ) )
				end
			end
		end
	end

	table.sort( ordered, function( a, b )
		if a.sz ~= b.sz then return a.sz < b.sz end
		if a.sy ~= b.sy then return a.sy < b.sy end
		return a.sx < b.sx
	end )
	return ordered
end

-- greedy-merge solid cells into a minimal set of boxes (local cell coords);
-- high corner is exclusive. Shared so both realms can build collision.
local function greedyBoxes( chunk, bounds )
	local CS = MC.CS
	local CS2 = CS * CS
	local CH = MC.CH
	local function idx( x, y, z ) return x + y * CS + z * CS2 end
	local windows = collisionWindowsForBounds( bounds )

	local solid = {}
	local customConvexes = {}
	local shapeGroups = {}
	local function shapeKey( box )
		return table.concat( { box[1], box[2], box[3], box[4], box[5], box[6] }, ":" )
	end
	local function addShapeBox( lx, ly, lz, box )
		local key = shapeKey( box )
		local group = shapeGroups[key]
		if not group then
			group = {
				cells = {},
				fx0 = box[1], fy0 = box[2], fz0 = box[3],
				fx1 = box[4], fy1 = box[5], fz1 = box[6],
				fullX = box[1] <= 0 and box[4] >= 1,
				fullY = box[2] <= 0 and box[5] >= 1,
				fullZ = box[3] <= 0 and box[6] >= 1,
			}
			shapeGroups[key] = group
		end
		group.cells[idx( lx, ly, lz )] = true
	end
	local function addCustomConvex( lx, ly, lz, convex )
		if type( convex ) ~= "table" then return end
		local points = {}
		for _, p in ipairs( convex ) do
			if type( p ) == "table" then
				local x = tonumber( p[1] or p.x )
				local y = tonumber( p[2] or p.y )
				local z = tonumber( p[3] or p.z )
				if x and y and z then
					points[#points + 1] = { lx + x, ly + y, lz + z }
				end
			end
		end
		if #points >= 4 then customConvexes[#customConvexes + 1] = points end
	end

	for _, window in ipairs( windows ) do
		for lz = window.z0, window.z1 - 1 do
			for ly = window.y0, window.y1 - 1 do
				for lx = window.x0, window.x1 - 1 do
					local li = idx( lx, ly, lz )
					local stateId = MC.GetChunkBlockStateByLocalIndex and MC.GetChunkBlockStateByLocalIndex( chunk, li ) or 0
					if stateId and stateId ~= 0 then
						local bx = chunk.cx * CS + lx
						local by = chunk.cy * CS + ly
						local bz = chunk.cz * CH + lz
						local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId, bx, by, bz ) or nil
						local id = visual and visual.id or nil
						if id and ( not MC.BlockVisualHasCollision or MC.BlockVisualHasCollision( visual, bx, by, bz ) ) then
							if MC.BlockVisualIsFullCube and MC.BlockVisualIsFullCube( visual, bx, by, bz ) then
								solid[li] = true
							else
								local blockConvexes = not clientCollisionAABBOnly() and MC.BlockVisualCollisionConvexes
									and MC.BlockVisualCollisionConvexes( visual, bx, by, bz ) or nil
								if blockConvexes then
									for _, convex in ipairs( blockConvexes ) do
										addCustomConvex( lx, ly, lz, convex )
									end
								else
									local blockBoxes = MC.BlockVisualCollisionBoxes
										and MC.BlockVisualCollisionBoxes( visual, bx, by, bz ) or nil
									if clientCollisionAABBOnly() and ( not blockBoxes or #blockBoxes == 0 ) and MC.BlockVisualBoxes then
										blockBoxes = MC.BlockVisualBoxes( visual, bx, by, bz )
									end
									for _, box in ipairs( blockBoxes or {} ) do
										addShapeBox( lx, ly, lz, box )
									end
								end
							end
						end
					end
				end
			end
		end
	end

	local visited = {}
	local boxes = {}

	for _, window in ipairs( windows ) do
		local xLimit = window.x1
		local yLimit = window.y1
		local zLimit = window.z1
		for z = window.z0, zLimit - 1 do
			for y = window.y0, yLimit - 1 do
				for x = window.x0, xLimit - 1 do
							local i0 = idx( x, y, z )
							if solid[i0] and not visited[i0] then
								local x1 = x + 1
								while x1 < xLimit do
									local i = idx( x1, y, z )
									if not solid[i] or visited[i] then break end
									x1 = x1 + 1
								end
								local y1 = y + 1
								while y1 < yLimit do
									local ok = true
									for xx = x, x1 - 1 do
										local i = idx( xx, y1, z )
										if not solid[i] or visited[i] then ok = false break end
									end
									if not ok then break end
									y1 = y1 + 1
								end
								local z1 = z + 1
								while z1 < zLimit do
									local ok = true
									for yy = y, y1 - 1 do
										for xx = x, x1 - 1 do
											local i = idx( xx, yy, z1 )
											if not solid[i] or visited[i] then ok = false break end
										end
										if not ok then break end
									end
									if not ok then break end
									z1 = z1 + 1
								end
								for zz = z, z1 - 1 do
									for yy = y, y1 - 1 do
										for xx = x, x1 - 1 do
											visited[ idx( xx, yy, zz ) ] = true
										end
									end
								end
								boxes[#boxes + 1] = { x, y, z, x1, y1, z1 }
							end
						end
					end
				end
	end

	local function addMergedShapeGroup( group )
		local seen = {}
		for _, window in ipairs( windows ) do
			local xLimit = window.x1
			local yLimit = window.y1
			local zLimit = window.z1
			for z = window.z0, zLimit - 1 do
				for y = window.y0, yLimit - 1 do
					for x = window.x0, xLimit - 1 do
								local i0 = idx( x, y, z )
								if group.cells[i0] and not seen[i0] then
									local x1 = x + 1
									if group.fullX then
										while x1 < xLimit do
											local i = idx( x1, y, z )
											if not group.cells[i] or seen[i] then break end
											x1 = x1 + 1
										end
									end

									local y1 = y + 1
									if group.fullY then
										while y1 < yLimit do
											local ok = true
											for xx = x, x1 - 1 do
												local i = idx( xx, y1, z )
												if not group.cells[i] or seen[i] then ok = false break end
											end
											if not ok then break end
											y1 = y1 + 1
										end
									end

									local z1 = z + 1
									if group.fullZ then
										while z1 < zLimit do
											local ok = true
											for yy = y, y1 - 1 do
												for xx = x, x1 - 1 do
													local i = idx( xx, yy, z1 )
													if not group.cells[i] or seen[i] then ok = false break end
												end
												if not ok then break end
											end
											if not ok then break end
											z1 = z1 + 1
										end
									end

									for zz = z, z1 - 1 do
										for yy = y, y1 - 1 do
											for xx = x, x1 - 1 do
												seen[idx( xx, yy, zz )] = true
											end
										end
									end

									boxes[#boxes + 1] = {
										x + group.fx0,
										y + group.fy0,
										z + group.fz0,
										( x1 - 1 ) + group.fx1,
										( y1 - 1 ) + group.fy1,
										( z1 - 1 ) + group.fz1,
									}
								end
							end
						end
					end
		end
	end

	for _, group in pairs( shapeGroups ) do
		addMergedShapeGroup( group )
	end

	return boxes, customConvexes
end

local function collisionSubchunkKey( x, y, z )
	local sx = math.floor( x / PHYSICS_SUBCHUNK_SIZE )
	local sy = math.floor( y / PHYSICS_SUBCHUNK_SIZE )
	local sz = math.floor( z / PHYSICS_SUBCHUNK_SIZE )
	return sx .. ":" .. sy .. ":" .. sz, sx, sy, sz
end

local function collisionSubchunkGroup( groups, ordered, x, y, z )
	local key, sx, sy, sz = collisionSubchunkKey( x, y, z )
	local group = groups[key]
	if not group then
		group = {
			key = key,
			sx = sx,
			sy = sy,
			sz = sz,
			boxes = {},
			customConvexes = {},
			convexes = {},
		}
		groups[key] = group
		ordered[#ordered + 1] = group
	end
	return group
end

local function groupCollisionPartsBySubchunk( boxes, customConvexes )
	local groups = {}
	local ordered = {}

	for i = 1, #boxes do
		local b = boxes[i]
		local group = collisionSubchunkGroup( groups, ordered, b[1], b[2], b[3] )
		group.boxes[#group.boxes + 1] = b
	end

	for _, convex in ipairs( customConvexes ) do
		local p0 = convex[1]
		local minX, minY, minZ = p0[1], p0[2], p0[3]
		for i = 2, #convex do
			local p = convex[i]
			minX = math.min( minX, p[1] )
			minY = math.min( minY, p[2] )
			minZ = math.min( minZ, p[3] )
		end
		local group = collisionSubchunkGroup( groups, ordered, minX, minY, minZ )
		group.customConvexes[#group.customConvexes + 1] = convex
	end

	table.sort( ordered, function( a, b )
		if a.sz ~= b.sz then return a.sz < b.sz end
		if a.sy ~= b.sy then return a.sy < b.sy end
		return a.sx < b.sx
	end )

	return ordered
end

local function appendBoxConvex( convexes, box, blockSize )
	local x0, y0, z0 = box[1] * blockSize, box[2] * blockSize, box[3] * blockSize
	local x1, y1, z1 = box[4] * blockSize, box[5] * blockSize, box[6] * blockSize
	convexes[#convexes + 1] = {
		Vector( x0, y0, z0 ), Vector( x1, y0, z0 ),
		Vector( x0, y1, z0 ), Vector( x1, y1, z0 ),
		Vector( x0, y0, z1 ), Vector( x1, y0, z1 ),
		Vector( x0, y1, z1 ), Vector( x1, y1, z1 ),
	}
end

local function appendCustomConvex( convexes, convex, blockSize )
	local points = {}
	for _, p in ipairs( convex ) do
		points[#points + 1] = Vector( p[1] * blockSize, p[2] * blockSize, p[3] * blockSize )
	end
	if #points >= 4 then convexes[#convexes + 1] = points end
end

local function buildSubchunkConvexGroups( boxes, customConvexes, blockSize )
	local groups = groupCollisionPartsBySubchunk( boxes, customConvexes )
	local totalConvexes = 0

	for _, group in ipairs( groups ) do
		for i = 1, #group.boxes do
			appendBoxConvex( group.convexes, group.boxes[i], blockSize )
		end
		for _, convex in ipairs( group.customConvexes ) do
			appendCustomConvex( group.convexes, convex, blockSize )
		end
		totalConvexes = totalConvexes + #group.convexes
	end

	return groups, totalConvexes
end

local function flattenConvexGroups( groups )
	local convexes = {}
	for _, group in ipairs( groups ) do
		for i = 1, #group.convexes do
			convexes[#convexes + 1] = group.convexes[i]
		end
	end
	return convexes
end

-- Shared with the client collision carriers (mc/render/cl_collision.lua):
-- build one chunk's (optionally bounded) collision convex groups without
-- touching any entity.
function MC.BuildChunkCollisionConvexGroups( chunk, bounds )
	local boxes, customConvexes = greedyBoxes( chunk, bounds )
	local groups, totalConvexes = buildSubchunkConvexGroups( boxes, customConvexes, MC.BS )
	return groups, totalConvexes, boxes, customConvexes
end

-- (re)build this chunk's collision from current block data.
-- Server: authoritative collision; oversized chunks split into mc_chunk_phys
--   subchunk entities (paged at PHYSICS_CONVEXES_PER_ENTITY convexes).
-- Client: PREDICTED local-player movement collision. The client only ever
--   builds the small AABB/aim interest bounds, so the whole set fits on this
--   networked shell entity as one multiconvex. Building locally on the shell
--   (instead of matching server mc_chunk_phys entities) keeps prediction
--   collision alive across server-side entity churn after edits.
function ENT:RebuildPhysics( bounds )
	if bounds == true then bounds = nil end
	local chunk = MC.GetChunkByKey( self:EnsureKey() )
	if not chunk or chunk.count == 0 then
		clearClientAABBDebugBoxes( self )
		self:ClearPhysicsSubchunks()
		self:PhysicsDestroy()
		return true
	end

	local boxes, customConvexes = greedyBoxes( chunk, bounds )
	if #boxes == 0 and #customConvexes == 0 then
		clearClientAABBDebugBoxes( self )
		self:ClearPhysicsSubchunks()
		self:PhysicsDestroy()
		return true
	end
	rememberClientAABBDebugBoxes( self, boxes )

	local groups, totalConvexes = buildSubchunkConvexGroups( boxes, customConvexes, MC.BS )
	if SERVER and totalConvexes > PHYSICS_CONVEXES_PER_ENTITY then
		self:ClearPhysicsSubchunks()
		self:PhysicsDestroy()
		self:SetSolid( SOLID_NONE )
		local subchunks = {}
		local byKey = {}
		local failed = 0
		local lastFailureReason

		for _, group in ipairs( groups ) do
			local _, ok, partSize, reason = spawnPhysicsSubchunkPages( self, group, subchunks, byKey )
			if not ok then
				failed = failed + 1
				lastFailureReason = reason or "subchunk_failed"
			end
		end

		self.PhysicsSubchunks = subchunks
		self.PhysicsSubchunksByKey = byKey
		return failed == 0, failed > 0 and lastFailureReason or nil
	end

	local convexes = flattenConvexGroups( groups )

	-- if SERVER then
	-- 	MsgN( "[MC][phys-debug] chunk=" .. tostring( self.ChunkKey ) ..
	-- 		" mode=single" ..
	-- 		" blocks=" .. tostring( chunk.count or 0 ) ..
	-- 		" bounds=" .. tostring( bounds and #bounds or "full" ) ..
	-- 		" boxes=" .. #boxes ..
	-- 		" customConvexes=" .. #customConvexes ..
	-- 		" convexes=" .. #convexes ..
	-- 		" pageSize=" .. PHYSICS_CONVEXES_PER_ENTITY )
	-- end

	-- Collision recipe copied from the working voxel-destruction addon
	-- (sent_voxelmain): PhysicsInitMultiConvex + EnableCustomCollisions(true) is what
	-- makes BOTH player movement AND the build/break eye trace actually hit the convex
	-- mesh. Without EnableCustomCollisions the engine only tests the entity's bounding
	-- box, so you collide with / aim at an invisible chunk-sized box instead of the
	-- blocks -- exactly the "weird collision, can't build, can't break" symptom.
	-- (PhysicsInitMultiConvex auto-sets the collision bounds from the mesh, so we no
	-- longer override them. MOVETYPE_NONE = no collision at all, so VPHYSICS is required.)
	self:ClearPhysicsSubchunks()
	self:PhysicsDestroy()
	ensurePhysicsModel( self )
	self:PhysicsInitMultiConvex( convexes )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	if not freezePhysicsObject( self ) then
		MsgN( "[MC] !!! collision build FAILED for chunk " .. tostring( self.ChunkKey ) ..
			"  boxes=" .. #boxes )
		rememberClientPhysStats( self, "single", bounds, #boxes, #customConvexes, totalConvexes, nil )
		if CLIENT and MC.ClientPhysStats then MC.ClientPhysStats.lastClientPhysReason = "single_apply_failed" end
		return false, "single_apply_failed"
	end
	rememberClientPhysStats( self, "single", bounds, #boxes, #customConvexes, totalConvexes, nil )
	return true
end
