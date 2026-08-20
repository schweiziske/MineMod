include( "shared.lua" )

function ENT:Initialize()
	self:SetRenderBounds( Vector( -48, -48, -48 ), Vector( 48, 48, 48 ) )
end

function ENT:DrawTranslucent()
	if MC.DecorationRenderer and MC.DecorationRenderer.DrawItemFrame then
		MC.DecorationRenderer.DrawItemFrame( self )
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end

