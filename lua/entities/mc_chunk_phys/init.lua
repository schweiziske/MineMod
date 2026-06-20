AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

function ENT:PhysgunPickup()
	return false
end

function ENT:CanProperty( ply, property )
	if property == "unfreeze" then return false end
end

function ENT:TraceAttack( dmginfo, dir, tr )
	if MC and MC.SV and MC.SV.HandleChunkTraceDamage then
		MC.SV.HandleChunkTraceDamage( self, dmginfo, dir, tr )
	end
end

function ENT:OnTakeDamage( dmginfo )
	if MC and MC.SV and MC.SV.HandleChunkDamage then
		MC.SV.HandleChunkDamage( self, dmginfo )
	end
	return 0
end

function ENT:PhysicsUpdate() end

hook.Add( "PhysgunPickup", "mc_chunk_phys_no_physgun", function( _, ent )
	if IsValid( ent ) and ent:GetClass() == "mc_chunk_phys" then return false end
end )

hook.Add( "CanPlayerUnfreeze", "mc_chunk_phys_no_unfreeze", function( _, ent )
	if IsValid( ent ) and ent:GetClass() == "mc_chunk_phys" then return false end
end )
