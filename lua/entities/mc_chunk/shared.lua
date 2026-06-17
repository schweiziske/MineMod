--[[----------------------------------------------------------------------------
	mc_chunk : one render owner per non-empty 16x16x32 Minecraft-style chunk section.
	  server -> provides collision (8x8x8 subchunk multiconvex)
	  client -> draws the chunk's IMesh (MC.DrawChunk)
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

function ENT:ClearPhysicsSubchunks()
	local subchunks = self.PhysicsSubchunks
	if not subchunks then return end
	for _, subchunk in ipairs( subchunks ) do
		if IsValid( subchunk ) then subchunk:Remove() end
	end
	self.PhysicsSubchunks = nil
	self.PhysicsSubchunksByKey = nil
end

ENT.ClearPhysicsShards = ENT.ClearPhysicsSubchunks

local function removeSubchunkEntity( subchunk )
	if IsValid( subchunk ) then subchunk:Remove() end
end

local function removePhysicsSubchunkKey( ent, key )
	local byKey = ent.PhysicsSubchunksByKey
	local mapped = byKey and byKey[key]
	if istable( mapped ) then
		for _, subchunk in ipairs( mapped ) do
			removeSubchunkEntity( subchunk )
		end
	else
		removeSubchunkEntity( mapped )
	end
	if byKey then byKey[key] = nil end

	local old = ent.PhysicsSubchunks
	if not old then return end
	local kept = {}
	for _, existing in ipairs( old ) do
		if IsValid( existing ) and existing.CollisionSubchunkKey ~= key then
			kept[#kept + 1] = existing
		end
	end
	ent.PhysicsSubchunks = kept
end

local function spawnPhysicsSubchunk( owner, index, group, convexes )
	local subchunk
	if SERVER then
		subchunk = ents.Create( "mc_chunk_phys" )
	else
		subchunk = ents.CreateClientside( "mc_chunk_phys" )
	end
	if not IsValid( subchunk ) then return nil end

	subchunk.ChunkKey = owner.ChunkKey
	subchunk.cx, subchunk.cy, subchunk.cz = owner.cx, owner.cy, owner.cz
	subchunk.ParentChunk = owner
	subchunk.SubchunkIndex = index
	subchunk.CollisionSubchunkKey = group.key
	ensurePhysicsModel( subchunk )
	subchunk:SetPos( owner:GetPos() )
	subchunk:SetAngles( Angle( 0, 0, 0 ) )
	if subchunk.Spawn then subchunk:Spawn() end
	if SERVER and subchunk.Activate then subchunk:Activate() end
	subchunk:SetNoDraw( true )

	if not subchunk.ApplyPhysicsConvexes or not subchunk:ApplyPhysicsConvexes( convexes or group.convexes ) then
		subchunk:Remove()
		return nil
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

		local subchunk = spawnPhysicsSubchunk( owner, #subchunks + 1, group, part )
		if not IsValid( subchunk ) then return built, false, #part end
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

local function collisionSubchunkKeysForBounds( bounds )
	if not bounds then return nil end
	local keys = {}
	for _, b in ipairs( bounds ) do
		local minX = math.floor( b[1] / PHYSICS_SUBCHUNK_SIZE )
		local minY = math.floor( b[2] / PHYSICS_SUBCHUNK_SIZE )
		local minZ = math.floor( b[3] / PHYSICS_SUBCHUNK_SIZE )
		local maxX = math.floor( b[4] / PHYSICS_SUBCHUNK_SIZE )
		local maxY = math.floor( b[5] / PHYSICS_SUBCHUNK_SIZE )
		local maxZ = math.floor( b[6] / PHYSICS_SUBCHUNK_SIZE )
		for sz = minZ, maxZ do
			for sy = minY, maxY do
				for sx = minX, maxX do
					keys[sx .. ":" .. sy .. ":" .. sz] = true
				end
			end
		end
	end
	return keys
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
	if MC.ClientCollisionDebug and MC.ClientCollisionDebug:GetBool() then
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
	return self.ChunkKey
end

local function localBoundsContains( bounds, lx, ly, lz )
	if not bounds then return true end
	for _, b in ipairs( bounds ) do
		if lx >= b[1] and lx <= b[4]
		and ly >= b[2] and ly <= b[5]
		and lz >= b[3] and lz <= b[6] then
			return true
		end
	end
	return false
end

-- greedy-merge solid cells into a minimal set of boxes (local cell coords);
-- high corner is exclusive. Shared so both realms can build collision.
local function greedyBoxes( chunk, bounds )
	local CS = MC.CS
	local CS2 = CS * CS
	local CH = MC.CH
	local function idx( x, y, z ) return x + y * CS + z * CS2 end

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

	for li, id in pairs( chunk.blocks ) do
		local b = MC.Blocks[id]
		if not b or b.solid ~= false then
			local orient = MC.NormalizeOrient and MC.NormalizeOrient( id, chunk.orients and chunk.orients[li] ) or 0
			local lx, ly, lz = MC.DecodeLocal( li )
			if localBoundsContains( bounds, lx, ly, lz ) then
				local bx = chunk.cx * CS + lx
				local by = chunk.cy * CS + ly
				local bz = chunk.cz * CH + lz
				if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
					solid[li] = true
				else
					local blockConvexes = MC.BlockCollisionConvexes
						and MC.BlockCollisionConvexes( id, orient, bx, by, bz ) or nil
					if blockConvexes then
						for _, convex in ipairs( blockConvexes ) do
							addCustomConvex( lx, ly, lz, convex )
						end
					else
						-- identical to the server: real collision boxes, never a
						-- client-only bounding-box approximation (that mismatch is what
						-- made the predicted player jitter on non-cube blocks).
						local blockBoxes = ( MC.BlockCollisionBoxes or MC.BlockBoxes )( id, orient, bx, by, bz )
						for _, box in ipairs( blockBoxes or {} ) do
							addShapeBox( lx, ly, lz, box )
						end
					end
				end
			end
		end
	end

	local visited = {}
	local boxes = {}

	for sz = 0, CH - 1, PHYSICS_SUBCHUNK_SIZE do
		local zLimit = math.min( CH, sz + PHYSICS_SUBCHUNK_SIZE )
		for sy = 0, CS - 1, PHYSICS_SUBCHUNK_SIZE do
			local yLimit = math.min( CS, sy + PHYSICS_SUBCHUNK_SIZE )
			for sx = 0, CS - 1, PHYSICS_SUBCHUNK_SIZE do
				local xLimit = math.min( CS, sx + PHYSICS_SUBCHUNK_SIZE )
				for z = sz, zLimit - 1 do
					for y = sy, yLimit - 1 do
						for x = sx, xLimit - 1 do
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
		end
	end

	local function addMergedShapeGroup( group )
		local seen = {}
		for sz = 0, CH - 1, PHYSICS_SUBCHUNK_SIZE do
			local zLimit = math.min( CH, sz + PHYSICS_SUBCHUNK_SIZE )
			for sy = 0, CS - 1, PHYSICS_SUBCHUNK_SIZE do
				local yLimit = math.min( CS, sy + PHYSICS_SUBCHUNK_SIZE )
				for sx = 0, CS - 1, PHYSICS_SUBCHUNK_SIZE do
					local xLimit = math.min( CS, sx + PHYSICS_SUBCHUNK_SIZE )
					for z = sz, zLimit - 1 do
						for y = sy, yLimit - 1 do
							for x = sx, xLimit - 1 do
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

-- (re)build this chunk's multiconvex collision from current block data.
-- Server: authoritative collision. Client: so PREDICTED local-player movement
-- collides with blocks (server physics objects are not replicated to clients,
-- which would otherwise cause rubber-banding when walking on builds).
function ENT:RebuildPhysics( bounds )
	local chunk = MC.GetChunkByKey( self:EnsureKey() )
	if not chunk or chunk.count == 0 then
		clearClientAABBDebugBoxes( self )
		self:ClearPhysicsSubchunks()
		self:PhysicsDestroy()
		return
	end

	if bounds and not self.PhysicsSubchunks then
		self:RebuildPhysics()
		return
	end

	local boxes, customConvexes = greedyBoxes( chunk, bounds )
	if #boxes == 0 and #customConvexes == 0 then
		clearClientAABBDebugBoxes( self )
		local affectedKeys = collisionSubchunkKeysForBounds( bounds )
		if affectedKeys then
			for key in pairs( affectedKeys ) do
				removePhysicsSubchunkKey( self, key )
			end
		else
			self:ClearPhysicsSubchunks()
			self:PhysicsDestroy()
		end
		return
	end
	rememberClientAABBDebugBoxes( self, boxes )

	local groups, totalConvexes = buildSubchunkConvexGroups( boxes, customConvexes, MC.BS )
	if bounds then
		local affectedKeys = collisionSubchunkKeysForBounds( bounds )
		for key in pairs( affectedKeys or {} ) do
			removePhysicsSubchunkKey( self, key )
		end

		if IsValid( self:GetPhysicsObject() ) then
			self:PhysicsDestroy()
		end
		self:SetSolid( SOLID_NONE )

		local subchunks = self.PhysicsSubchunks or {}
		local byKey = self.PhysicsSubchunksByKey or {}
		local failed = 0

		for _, group in ipairs( groups ) do
			local _, ok, partSize = spawnPhysicsSubchunkPages( self, group, subchunks, byKey )
			if not ok then
				failed = failed + 1
				MsgN( "[MC] !!! collision subchunk build FAILED for chunk " .. tostring( self.ChunkKey ) ..
					"  subchunk=" .. tostring( group.key ) ..
					" convexes=" .. #group.convexes ..
					" part=" .. tostring( partSize ) )
			end
		end

		self.PhysicsSubchunks = subchunks
		self.PhysicsSubchunksByKey = byKey
		rememberClientPhysStats( self, "subchunk_update", bounds, #boxes, #customConvexes, totalConvexes, subchunks )
		if failed > 0 then
			MsgN( "[MC] collision subchunk update for chunk " .. tostring( self.ChunkKey ) ..
				"  convexes=" .. totalConvexes ..
				" subchunks=" .. #groups ..
				" built=" .. countValidSubchunkPhysics( subchunks ) ..
				" failed=" .. failed )
		end
		return
	end

	if totalConvexes > PHYSICS_CONVEXES_PER_ENTITY then
		self:ClearPhysicsSubchunks()
		self:PhysicsDestroy()
		self:SetSolid( SOLID_NONE )
		local subchunks = {}
		local byKey = {}
		local failed = 0

		for _, group in ipairs( groups ) do
			local _, ok, partSize = spawnPhysicsSubchunkPages( self, group, subchunks, byKey )
			if not ok then
				failed = failed + 1
				MsgN( "[MC] !!! collision subchunk build FAILED for chunk " .. tostring( self.ChunkKey ) ..
					"  subchunk=" .. tostring( group.key ) ..
					" convexes=" .. #group.convexes ..
					" part=" .. tostring( partSize ) )
			end
		end

		self.PhysicsSubchunks = subchunks
		self.PhysicsSubchunksByKey = byKey
		rememberClientPhysStats( self, "subchunks", bounds, #boxes, #customConvexes, totalConvexes, subchunks )
		MsgN( "[MC] collision subchunks for chunk " .. tostring( self.ChunkKey ) ..
			"  convexes=" .. totalConvexes ..
			" subchunks=" .. #groups ..
			" built=" .. countValidSubchunkPhysics( subchunks ) ..
			" failed=" .. failed )
		return
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
	end
	rememberClientPhysStats( self, "single", bounds, #boxes, #customConvexes, totalConvexes, nil )
end
