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

-- frozen static build: never let physics forces move / drift a chunk
function ENT:PhysicsUpdate() end