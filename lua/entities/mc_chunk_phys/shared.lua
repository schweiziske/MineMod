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

local function boundsTouch( a, b )
	return a[1] <= b[4] and a[4] >= b[1]
		and a[2] <= b[5] and a[5] >= b[2]
		and a[3] <= b[6] and a[6] >= b[3]
end

local function subchunkInClientInterest( key, subkey )
	local interest = MC and MC.ClientCollisionInterest and MC.ClientCollisionInterest[key]
	if not interest then return false end
	local subBounds = boundsForSubchunkKey( subkey )
	local sub = subBounds and subBounds[1]
	if not sub then return false end
	for _, bounds in ipairs( interest ) do
		if boundsTouch( sub, bounds ) then return true end
	end
	return false
end

local function syncClientPhysMetadata( ent )
	if not CLIENT or not IsValid( ent ) or ent:EntIndex() <= 0 then return nil end
	local key = ent:GetNWString( "MCChunkKey", "" )
	local subkey = ent:GetNWString( "MCSubchunkKey", "" )
	if key == "" or subkey == "" then return nil end

	ent.ChunkKey = key
	ent.CollisionSubchunkKey = subkey
	ent.CollisionPhysPage = ent:GetNWInt( "MCPhysPage", 0 )
	if MC and MC.ChunkKeyToCoords then
		ent.cx, ent.cy, ent.cz = MC.ChunkKeyToCoords( key )
	end
	if MC and MC.ChunkEnts and IsValid( MC.ChunkEnts[key] ) then
		ent.ParentChunk = MC.ChunkEnts[key]
	end
	return key, subkey
end

local function clientPhysNeedsRebuild( ent )
	if not IsValid( ent ) then return false end
	if ent.ChunkKey == nil or ent.CollisionSubchunkKey == nil then return true end
	if not IsValid( ent:GetPhysicsObject() ) then return true end
	if not IsValid( ent.ParentChunk ) then return true end
	return false
end

-- Keep split collision frozen at the chunk origin. Empty PhysicsUpdate was not
-- enough for clientside multiconvex children: the next VPhysics tick moved both
-- entity and phys object back to world origin.
function ENT:PhysicsUpdate( phys )
	pinToParentChunk( self, phys )
end

function ENT:MarkClientPhysDirtyFromMetadata()
	if not CLIENT then return false end
	local key, subkey = syncClientPhysMetadata( self )
	if not key or not clientPhysNeedsRebuild( self ) then return false end
	if not subchunkInClientInterest( key, subkey ) then return false end

	local now = CurTime()
	if now < ( self.NextClientPhysDirtyRequest or 0 ) then return false end
	self.NextClientPhysDirtyRequest = now + 0.2

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
