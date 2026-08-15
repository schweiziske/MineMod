--[[----------------------------------------------------------------------------
	mc_collision_carrier : per-player prediction collision carrier.
	The server spawns a small fixed pool per player (mc/sv_collision_carriers.lua)
	and transmits each pool only to its owner. The owning client bakes its
	AABB/aim interest collision into world-space multiconvex pages on these
	entities (<= MC.CollisionCarrierConvexLimit convexes per carrier, the same
	page size the server uses for mc_chunk_phys). Carriers are never removed or
	rebuilt server-side while the player is connected, so client prediction
	collision cannot be broken by chunk entity churn. Serverside they carry no
	physics object and are therefore effectively non-solid.
------------------------------------------------------------------------------]]

ENT.Type      = "anim"
ENT.Base      = "base_anim"
ENT.PrintName = "MC Collision Carrier"
ENT.Author    = "MC"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.DisableDuplicator = true

MC = MC or {}
MC.CollisionCarrierConvexLimit = MC.CollisionCarrierConvexLimit or 128

-- CLIENT: bake one page of world-space convexes onto this carrier.
function ENT:ApplyCarrierConvexes( convexes )
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
	return true
end

-- Convexes are baked in world space, so entity and physics object stay pinned
-- at the world origin. That matches the networked server position exactly, so
-- interpolation/netvar updates can never fight the client's local state.
local function pinToWorldOrigin( ent, phys )
	if ent:GetPos():DistToSqr( vector_origin ) > 0.01 then
		ent:SetPos( vector_origin )
	end
	ent:SetAngles( angle_zero )

	phys = IsValid( phys ) and phys or ent:GetPhysicsObject()
	if IsValid( phys ) then
		if phys.SetPos and phys.GetPos and phys:GetPos():DistToSqr( vector_origin ) > 0.01 then
			phys:SetPos( vector_origin )
		end
		if phys.SetAngles then phys:SetAngles( angle_zero ) end
		phys:EnableMotion( false )
	end
end

function ENT:PhysicsUpdate( phys )
	pinToWorldOrigin( self, phys )
end
