AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	-- Mirror exactly the solid/movetype state the owning client needs locally,
	-- so networked entity state can never stomp the client's values. No
	-- physics object exists serverside, so the carrier stays non-solid here.
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
end

function ENT:UpdateTransmitState()
	-- narrowed to the owning player via SetPreventTransmit in sv_collision_carriers.lua
	return TRANSMIT_ALWAYS
end

function ENT:PhysgunPickup()
	return false
end

function ENT:CanProperty()
	return false
end

function ENT:PhysicsUpdate() end
