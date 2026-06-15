include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()
	self:DrawShadow( false )
	self:SetNoDraw( true )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
end

function ENT:Draw()
end

function ENT:DrawTranslucent()
end
