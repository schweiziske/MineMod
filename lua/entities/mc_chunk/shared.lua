--[[----------------------------------------------------------------------------
mc_chunk : one render owner per non-empty 16x16x32 Minecraft-style chunk section.
	  server -> provides collision (per-block-box multiconvex, sharded if huge)
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

local PHYSICS_CONVEXES_PER_ENTITY = 256

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

local function countValidShardPhysics( shards )
	local count = 0
	for _, shard in ipairs( shards or {} ) do
		if IsValid( shard ) and IsValid( shard:GetPhysicsObject() ) then
			count = count + 1
		end
	end
	return count
end

local function rememberClientPhysStats( ent, mode, bounds, boxes, customConvexes, convexes, shards )
	if not CLIENT then return end
	MC.ClientPhysStats = MC.ClientPhysStats or {}
	local shardCount = shards and #shards or 0
	local shardObjects = countValidShardPhysics( shards )
	MC.ClientPhysStats.lastClientPhysMode = mode
	MC.ClientPhysStats.lastClientPhysChunkKey = tostring( ent.ChunkKey )
	MC.ClientPhysStats.lastClientPhysInputBounds = bounds and #bounds or "full"
	MC.ClientPhysStats.lastClientPhysBoxes = boxes
	MC.ClientPhysStats.lastClientPhysCustomConvexes = customConvexes
	MC.ClientPhysStats.lastClientPhysConvexes = convexes
	MC.ClientPhysStats.lastClientPhysShards = shardCount
	MC.ClientPhysStats.lastClientPhysShardObjects = shardObjects
	MC.ClientPhysStats.lastClientPhysMainObject = IsValid( ent:GetPhysicsObject() )
	if MC.ClientCollisionDebug and MC.ClientCollisionDebug:GetBool() then
		print( "[MC][client-phys] chunk=" .. tostring( ent.ChunkKey ) ..
			" mode=" .. tostring( mode ) ..
			" bounds=" .. tostring( bounds and #bounds or "full" ) ..
			" boxes=" .. tostring( boxes ) ..
			" customConvexes=" .. tostring( customConvexes ) ..
			" convexes=" .. tostring( convexes ) ..
			" shards=" .. tostring( shardCount ) ..
			" shardPhys=" .. tostring( shardObjects ) ..
			" mainPhys=" .. tostring( IsValid( ent:GetPhysicsObject() ) ) )
	end
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

-- Build one collision box per block box. Adjacent blocks intentionally stay
-- separate so large connected builds shard instead of becoming one big hull.
local function collisionBoxes( chunk, bounds )
	local CS = MC.CS
	local CH = MC.CH

	local customConvexes = {}
	local boxes = {}
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
	local function addBlockBox( lx, ly, lz, box )
		if type( box ) ~= "table" then return end
		boxes[#boxes + 1] = {
			lx + ( tonumber( box[1] ) or 0 ),
			ly + ( tonumber( box[2] ) or 0 ),
			lz + ( tonumber( box[3] ) or 0 ),
			lx + ( tonumber( box[4] ) or 1 ),
			ly + ( tonumber( box[5] ) or 1 ),
			lz + ( tonumber( box[6] ) or 1 ),
		}
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
					boxes[#boxes + 1] = { lx, ly, lz, lx + 1, ly + 1, lz + 1 }
				else
					local blockConvexes = MC.BlockCollisionConvexes and MC.BlockCollisionConvexes( id, orient, bx, by, bz ) or nil
					if blockConvexes then
						for _, convex in ipairs( blockConvexes ) do
							addCustomConvex( lx, ly, lz, convex )
						end
					else
						local blockBoxes = ( MC.BlockCollisionBoxes or MC.BlockBoxes )( id, orient, bx, by, bz )
						for _, box in ipairs( blockBoxes or {} ) do
							addBlockBox( lx, ly, lz, box )
						end
					end
				end
			end
		end
	end

	return boxes, customConvexes
end

-- (re)build this chunk's multiconvex collision from current block data.
-- Server: authoritative collision. Client: so PREDICTED local-player movement
-- collides with blocks (server physics objects are not replicated to clients,
-- which would otherwise cause rubber-banding when walking on builds).
function ENT:RebuildPhysics( bounds )
	local chunk = MC.GetChunkByKey( self:EnsureKey() )
	if not chunk or chunk.count == 0 then
		self:ClearPhysicsShards()
		self:PhysicsDestroy()
		return
	end

	local boxes, customConvexes = collisionBoxes( chunk, bounds )
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

	if #convexes > PHYSICS_CONVEXES_PER_ENTITY then
		-- if SERVER then
		-- 	MsgN( "[MC][phys-debug] chunk=" .. tostring( self.ChunkKey ) ..
		-- 		" mode=shard" ..
		-- 		" blocks=" .. tostring( chunk.count or 0 ) ..
		-- 		" bounds=" .. tostring( bounds and #bounds or "full" ) ..
		-- 		" boxes=" .. #boxes ..
		-- 		" customConvexes=" .. #customConvexes ..
		-- 		" convexes=" .. #convexes ..
		-- 		" pageSize=" .. PHYSICS_CONVEXES_PER_ENTITY )
		-- end
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
				rememberClientPhysStats( self, "shard_failed", bounds, #boxes, #customConvexes, #convexes, shards )
				MsgN( "[MC] !!! collision shard build FAILED for chunk " .. tostring( self.ChunkKey ) ..
					"  convexes=" .. #convexes .. " shard=" .. shardIndex )
				return
			end
			shards[#shards + 1] = shard
			shardIndex = shardIndex + 1
		end

		self.PhysicsShards = shards
		rememberClientPhysStats( self, "shard", bounds, #boxes, #customConvexes, #convexes, shards )
		MsgN( "[MC] collision sharded for chunk " .. tostring( self.ChunkKey ) ..
			"  convexes=" .. #convexes .. " shards=" .. #shards )
		return
	end

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
	rememberClientPhysStats( self, "single", bounds, #boxes, #customConvexes, #convexes, nil )
end
