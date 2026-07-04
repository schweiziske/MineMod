include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()
	self:DrawShadow( false )
	self:SetNoDraw( true )
end

function ENT:Draw()
end

function ENT:DrawTranslucent()
end
