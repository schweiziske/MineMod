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
	return true
end

-- Keep the clientside collision frozen at the chunk origin during prediction,
-- exactly like the main mc_chunk entity. Without this override a MOVETYPE_VPHYSICS
-- subchunk drifts under client prediction (the server already overrides it), so the
-- player jitters / rubber-bands when standing on collision that lives on split
-- subchunk entities -- i.e. complex chunks past the convex split threshold.
function ENT:PhysicsUpdate() end
