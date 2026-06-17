--[[----------------------------------------------------------------------------
	mc_chunk_phys : invisible 8x8x8 collision subchunk for one mc_chunk.
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

local function boundsForSubchunkKey( key )
	local sx, sy, sz = tostring( key or "" ):match( "^(-?%d+):(-?%d+):(-?%d+)$" )
	if not sx then return nil end
	local size = math.max( 1, math.floor( tonumber( MC and MC.CollisionSubchunkSize ) or 8 ) )
	local cs = MC and MC.CS or 16
	local ch = MC and MC.CH or 32
	local x0 = math.max( 0, tonumber( sx ) * size )
	local y0 = math.max( 0, tonumber( sy ) * size )
	local z0 = math.max( 0, tonumber( sz ) * size )
	return {
		{
			x0,
			y0,
			z0,
			math.min( cs - 1, x0 + size - 1 ),
			math.min( cs - 1, y0 + size - 1 ),
			math.min( ch - 1, z0 + size - 1 ),
		}
	}
end

-- Keep split collision frozen at the chunk origin. Empty PhysicsUpdate was not
-- enough for clientside multiconvex children: the next VPhysics tick moved both
-- entity and phys object back to world origin.
function ENT:PhysicsUpdate( phys )
	pinToParentChunk( self, phys )
end

function ENT:MarkClientPhysDirtyFromMetadata()
	if not CLIENT then return false end
	if self:EntIndex() <= 0 or self.ClientPhysDirtyMarked then return false end
	local key = self:GetNWString( "MCChunkKey", "" )
	local subkey = self:GetNWString( "MCSubchunkKey", "" )
	if key == "" or subkey == "" then return false end
	self.ClientPhysDirtyMarked = true
	if MC and MC.MarkChunkPhysDirty then
		MC.MarkChunkPhysDirty( key, true, boundsForSubchunkKey( subkey ) )
	end
	return true
end

function ENT:Think()
	if CLIENT then
		self:MarkClientPhysDirtyFromMetadata()
		pinToParentChunk( self )
		self:NextThink( CurTime() )
		return true
	end
end
