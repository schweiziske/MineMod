--[[----------------------------------------------------------------------------
	mc_chunk_phys : invisible 8x8x8 collision subchunk for one mc_chunk.
	Server-authoritative collision + trace damage target. The client never
	attaches physics to these entities: clientside prediction collision is a
	local interest-bounds multiconvex on the mc_chunk shell (see mc_chunk
	RebuildPhysics), so these stay physics-less and non-colliding on clients.
------------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "MC Chunk Collision Subchunk"
ENT.Author    = "MC"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.DisableDuplicator = true

function ENT:ApplyPhysicsConvexes( convexes )
	if not istable( convexes ) or #convexes == 0 then
		self:PhysicsDestroy()
		return false
	end

	self:PhysicsDestroy()
	self:PhysicsInitMultiConvex( convexes )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
	self:SetNoDraw( true )

	local phys = self:GetPhysicsObject()
	if not IsValid( phys ) then return false end
	phys:EnableMotion( false )
	phys:Wake()
	if CLIENT and MC and MC.ClientCollisionDebug and MC.ClientCollisionDebug:GetBool() then
		print( "[MC][client-phys] subchunk convexes=" .. tostring( #convexes ) )
	end
	return true
end

local function pinToParentChunk( ent, phys )
	local pos, ang
	if ent.CollisionWorldSpace then
		pos = vector_origin
		ang = angle_zero
	else
		local parent = ent.ParentChunk
		if not IsValid( parent ) then return end
		pos = parent:GetPos()
		ang = parent:GetAngles()
	end

	local entPos = ent:GetPos()
	if entPos:DistToSqr( pos ) > 0.01 then
		ent:SetPos( pos )
	end
	ent:SetAngles( ang )

	phys = IsValid( phys ) and phys or ent:GetPhysicsObject()
	if IsValid( phys ) then
		if phys.SetPos and phys.GetPos and phys:GetPos():DistToSqr( pos ) > 0.01 then
			phys:SetPos( pos )
		end
		if phys.SetAngles then phys:SetAngles( ang ) end
		phys:EnableMotion( false )
	end
end

local function syncClientPhysMetadata( ent )
	if not CLIENT or not IsValid( ent ) or ent:EntIndex() <= 0 then return nil end
	local key = ent:GetNWString( "MCChunkKey", "" )
	local subkey = ent:GetNWString( "MCSubchunkKey", "" )
	if key == "" or subkey == "" then return nil end

	ent.ChunkKey = MC and MC.CanonicalChunkKey and MC.CanonicalChunkKey( key ) or key
	ent.CollisionSubchunkKey = subkey
	ent.CollisionPhysPage = ent:GetNWInt( "MCPhysPage", 0 )
	if MC and MC.ChunkKeyToCoords then
		ent.cx, ent.cy, ent.cz = MC.ChunkKeyToCoords( ent.ChunkKey )
	end
	if MC and MC.ChunkEnts and IsValid( MC.ChunkEnts[ent.ChunkKey] ) then
		ent.ParentChunk = MC.ChunkEnts[ent.ChunkKey]
	end
	return ent.ChunkKey, subkey
end

-- Keep split collision frozen at the chunk origin. Empty PhysicsUpdate was not
-- enough for clientside multiconvex children: the next VPhysics tick moved both
-- entity and phys object back to world origin.
function ENT:PhysicsUpdate( phys )
	pinToParentChunk( self, phys )
end

-- Client: metadata mirror only (chunk/subchunk keys for debug overlays and
-- probes). Never marks collision dirty -- prediction collision does not live
-- on these entities.
function ENT:SyncClientPhysMetadata()
	if not CLIENT then return nil end
	return syncClientPhysMetadata( self )
end

function ENT:Think()
	if CLIENT then
		syncClientPhysMetadata( self )
		self:SetNextClientThink( CurTime() + 0.5 )
		return true
	end
end
