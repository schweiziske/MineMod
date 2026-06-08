AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	-- placeholder model: never drawn (client overrides Draw); physics get replaced by
	-- RebuildPhysics(). Setup mirrors the proven voxel-destruction addon (sent_voxelmain).
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	self:PhysicsInit( SOLID_VPHYSICS )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
	self:EnsureKey()
end

function ENT:PhysgunPickup()
	return false
end

function ENT:CanProperty( ply, property )
	if property == "unfreeze" then return false end
end

-- frozen static build: never let physics forces move / drift a chunk
function ENT:PhysicsUpdate() end

hook.Add( "PhysgunPickup", "mc_chunk_no_physgun", function( _, ent )
	if IsValid( ent ) and ent:GetClass() == "mc_chunk" then return false end
end )

hook.Add( "CanPlayerUnfreeze", "mc_chunk_no_unfreeze", function( _, ent )
	if IsValid( ent ) and ent:GetClass() == "mc_chunk" then return false end
end )
