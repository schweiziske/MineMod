include( "shared.lua" )

function ENT:Initialize()
	self:SetRenderBounds( Vector( -128, -128, -128 ), Vector( 128, 128, 128 ) )
end

function ENT:DrawTranslucent()
	if MC.DecorationRenderer and MC.DecorationRenderer.DrawPainting then
		MC.DecorationRenderer.DrawPainting( self )
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end
