--[[----------------------------------------------------------------------------
	mc_chunk : one render owner per non-empty 16x16x32 Minecraft-style chunk section.
	  server -> provides collision (greedy-merged box multiconvex, sharded if huge)
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

local PHYSICS_CONVEXES_PER_ENTITY = 255

local function freezePhysicsObject( ent )
	local phys = ent:GetPhysicsObject()
	if IsValid( phys ) then
		phys:EnableMotion( false )
		phys:Wake()
		return true
	end
	return false
end

function ENT:ClearPhysicsShards()
	if not self.PhysicsShards then return end
	for _, shard in ipairs( self.PhysicsShards ) do
		if IsValid( shard ) then shard:Remove() end
	end
	self.PhysicsShards = nil
end

local function spawnPhysicsShard( owner, index, convexes )
	local shard
	if SERVER then
		shard = ents.Create( "mc_chunk_phys" )
	else
		shard = ents.CreateClientside( "mc_chunk_phys" )
	end
	if not IsValid( shard ) then return nil end

	shard.ChunkKey = owner.ChunkKey
	shard.cx, shard.cy, shard.cz = owner.cx, owner.cy, owner.cz
	shard.ParentChunk = owner
	shard.ShardIndex = index
	shard:SetPos( owner:GetPos() )
	shard:SetAngles( Angle( 0, 0, 0 ) )
	if shard.Spawn then shard:Spawn() end
	if SERVER and shard.Activate then shard:Activate() end
	shard:SetNoDraw( true )

	if not shard.ApplyPhysicsConvexes or not shard:ApplyPhysicsConvexes( convexes ) then
		shard:Remove()
		return nil
	end
	return shard
end

function ENT:EnsureKey()
	if self.ChunkKey then return self.ChunkKey end
	local cx, cy, cz = MC.ChunkCoordsFromOrigin( self:GetPos() )
	self.cx, self.cy, self.cz = cx, cy, cz
	self.ChunkKey = MC.ChunkKey( cx, cy, cz )
	return self.ChunkKey
end

-- greedy-merge solid cells into a minimal set of boxes (local cell coords);
-- high corner is exclusive. Shared so both realms can build collision.
local function greedyBoxes( chunk )
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
			local bx = chunk.cx * CS + lx
			local by = chunk.cy * CS + ly
			local bz = chunk.cz * CH + lz
			if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
				solid[li] = true
			else
				local blockConvexes = MC.BlockCollisionConvexes and MC.BlockCollisionConvexes( id, orient, bx, by, bz ) or nil
				if blockConvexes then
					for _, convex in ipairs( blockConvexes ) do
						addCustomConvex( lx, ly, lz, convex )
					end
				else
					local blockBoxes = ( MC.BlockCollisionBoxes or MC.BlockBoxes )( id, orient, bx, by, bz )
					for _, box in ipairs( blockBoxes or {} ) do
						addShapeBox( lx, ly, lz, box )
					end
				end
			end
		end
	end

	local visited = {}
	local boxes = {}

	for z = 0, CH - 1 do
		for y = 0, CS - 1 do
			for x = 0, CS - 1 do
				local i0 = idx( x, y, z )
				if solid[i0] and not visited[i0] then
					local x1 = x + 1
					while x1 < CS do
						local i = idx( x1, y, z )
						if not solid[i] or visited[i] then break end
						x1 = x1 + 1
					end
					local y1 = y + 1
					while y1 < CS do
						local ok = true
						for xx = x, x1 - 1 do
							local i = idx( xx, y1, z )
							if not solid[i] or visited[i] then ok = false break end
						end
						if not ok then break end
						y1 = y1 + 1
					end
					local z1 = z + 1
					while z1 < CH do
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

	local function addMergedShapeGroup( group )
		local seen = {}
		for z = 0, CH - 1 do
			for y = 0, CS - 1 do
				for x = 0, CS - 1 do
					local i0 = idx( x, y, z )
					if group.cells[i0] and not seen[i0] then
						local x1 = x + 1
						if group.fullX then
							while x1 < CS do
								local i = idx( x1, y, z )
								if not group.cells[i] or seen[i] then break end
								x1 = x1 + 1
							end
						end

						local y1 = y + 1
						if group.fullY then
							while y1 < CS do
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
							while z1 < CH do
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

	for _, group in pairs( shapeGroups ) do
		addMergedShapeGroup( group )
	end

	return boxes, customConvexes
end

-- (re)build this chunk's multiconvex collision from current block data.
-- Server: authoritative collision. Client: so PREDICTED local-player movement
-- collides with blocks (server physics objects are not replicated to clients,
-- which would otherwise cause rubber-banding when walking on builds).
function ENT:RebuildPhysics()
	local chunk = MC.GetChunkByKey( self:EnsureKey() )
	if not chunk or chunk.count == 0 then
		self:ClearPhysicsShards()
		self:PhysicsDestroy()
		return
	end

	local boxes, customConvexes = greedyBoxes( chunk )
	if #boxes == 0 and #customConvexes == 0 then
		self:ClearPhysicsShards()
		self:PhysicsDestroy()
		return
	end

	local BS = MC.BS
	local convexes = {}
	for i = 1, #boxes do
		local b = boxes[i]
		local x0, y0, z0 = b[1] * BS, b[2] * BS, b[3] * BS
		local x1, y1, z1 = b[4] * BS, b[5] * BS, b[6] * BS
		convexes[#convexes + 1] = {
			Vector( x0, y0, z0 ), Vector( x1, y0, z0 ),
			Vector( x0, y1, z0 ), Vector( x1, y1, z0 ),
			Vector( x0, y0, z1 ), Vector( x1, y0, z1 ),
			Vector( x0, y1, z1 ), Vector( x1, y1, z1 ),
		}
	end
	for _, convex in ipairs( customConvexes ) do
		local points = {}
		for _, p in ipairs( convex ) do
			points[#points + 1] = Vector( p[1] * BS, p[2] * BS, p[3] * BS )
		end
		if #points >= 4 then convexes[#convexes + 1] = points end
	end

	if SERVER then
		MsgN( "[MC][phys-debug] chunk=" .. tostring( self.ChunkKey ) ..
			" blocks=" .. tostring( chunk.count or 0 ) ..
			" boxes=" .. #boxes ..
			" customConvexes=" .. #customConvexes ..
			" convexes=" .. #convexes )
	end

	if #convexes > PHYSICS_CONVEXES_PER_ENTITY then
		self:ClearPhysicsShards()
		self:PhysicsDestroy()
		self:SetSolid( SOLID_NONE )
		local shards = {}
		local shardIndex = 1

		for first = 1, #convexes, PHYSICS_CONVEXES_PER_ENTITY do
			local part = {}
			local last = math.min( #convexes, first + PHYSICS_CONVEXES_PER_ENTITY - 1 )
			for i = first, last do
				part[#part + 1] = convexes[i]
			end
			local shard = spawnPhysicsShard( self, shardIndex, part )
			if not IsValid( shard ) then
				for _, existing in ipairs( shards ) do
					if IsValid( existing ) then existing:Remove() end
				end
				MsgN( "[MC] !!! collision shard build FAILED for chunk " .. tostring( self.ChunkKey ) ..
					"  convexes=" .. #convexes .. " shard=" .. shardIndex )
				return
			end
			shards[#shards + 1] = shard
			shardIndex = shardIndex + 1
		end

		self.PhysicsShards = shards
		MsgN( "[MC] collision sharded for chunk " .. tostring( self.ChunkKey ) ..
			"  convexes=" .. #convexes .. " shards=" .. #shards )
		return
	end

	-- Collision recipe copied from the working voxel-destruction addon
	-- (sent_voxelmain): PhysicsInitMultiConvex + EnableCustomCollisions(true) is what
	-- makes BOTH player movement AND the build/break eye trace actually hit the convex
	-- mesh. Without EnableCustomCollisions the engine only tests the entity's bounding
	-- box, so you collide with / aim at an invisible chunk-sized box instead of the
	-- blocks -- exactly the "weird collision, can't build, can't break" symptom.
	-- (PhysicsInitMultiConvex auto-sets the collision bounds from the mesh, so we no
	-- longer override them. MOVETYPE_NONE = no collision at all, so VPHYSICS is required.)
	self:ClearPhysicsShards()
	self:PhysicsDestroy()
	self:PhysicsInitMultiConvex( convexes )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	if not freezePhysicsObject( self ) then
		MsgN( "[MC] !!! collision build FAILED for chunk " .. tostring( self.ChunkKey ) ..
			"  boxes=" .. #boxes )
	end
end
