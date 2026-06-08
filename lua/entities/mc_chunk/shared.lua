--[[----------------------------------------------------------------------------
	mc_chunk : one entity per non-empty 16x16x32 Minecraft-style chunk section.
	  server -> provides collision (greedy-merged box multiconvex)
	  client -> draws the chunk's IMesh (MC.DrawChunk)
	This is the ONLY entity type the system spawns. Sections can stack vertically.
------------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "MC Chunk"
ENT.Author    = "MC"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.DisableDuplicator = true

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
	local solid = {}
	for li, id in pairs( chunk.blocks ) do
		local b = MC.Blocks[id]
		if not b or b.solid ~= false then
			solid[li] = true
		end
	end

	local function idx( x, y, z ) return x + y * CS + z * CS2 end

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

	return boxes
end

-- (re)build this chunk's multiconvex collision from current block data.
-- Server: authoritative collision. Client: so PREDICTED local-player movement
-- collides with blocks (server physics objects are not replicated to clients,
-- which would otherwise cause rubber-banding when walking on builds).
function ENT:RebuildPhysics()
	local chunk = MC.GetChunkByKey( self:EnsureKey() )
	if not chunk or chunk.count == 0 then
		self:PhysicsDestroy()
		return
	end

	local boxes = greedyBoxes( chunk )
	if #boxes == 0 then
		self:PhysicsDestroy()
		return
	end

	local BS = MC.BS
	local convexes = {}
	for i = 1, #boxes do
		local b = boxes[i]
		local x0, y0, z0 = b[1] * BS, b[2] * BS, b[3] * BS
		local x1, y1, z1 = b[4] * BS, b[5] * BS, b[6] * BS
		convexes[i] = {
			Vector( x0, y0, z0 ), Vector( x1, y0, z0 ),
			Vector( x0, y1, z0 ), Vector( x1, y1, z0 ),
			Vector( x0, y0, z1 ), Vector( x1, y0, z1 ),
			Vector( x0, y1, z1 ), Vector( x1, y1, z1 ),
		}
	end

	-- Collision recipe copied from the working voxel-destruction addon
	-- (sent_voxelmain): PhysicsInitMultiConvex + EnableCustomCollisions(true) is what
	-- makes BOTH player movement AND the build/break eye trace actually hit the convex
	-- mesh. Without EnableCustomCollisions the engine only tests the entity's bounding
	-- box, so you collide with / aim at an invisible chunk-sized box instead of the
	-- blocks -- exactly the "weird collision, can't build, can't break" symptom.
	-- (PhysicsInitMultiConvex auto-sets the collision bounds from the mesh, so we no
	-- longer override them. MOVETYPE_NONE = no collision at all, so VPHYSICS is required.)
	self:PhysicsInitMultiConvex( convexes )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )

	local phys = self:GetPhysicsObject()
	if IsValid( phys ) then
		phys:EnableMotion( false )   -- static build: blocks must never move
		phys:Wake()
	else
		MsgN( "[MC] !!! collision build FAILED for chunk " .. tostring( self.ChunkKey ) ..
			"  boxes=" .. #boxes )
	end
end
