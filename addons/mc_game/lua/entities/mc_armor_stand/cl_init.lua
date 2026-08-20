include( "shared.lua" )

function ENT:Initialize()
	self:SetRenderBounds( Vector( -96, -96, -8 ), Vector( 96, 96, 128 ) )
	-- ElytraAnimationState starts at zero when the client entity is constructed.
	self.MCArmorStandAnimationCreatedAt = CurTime and CurTime() or 0
end

function ENT:DrawTranslucent()
	if MC.DecorationRenderer and MC.DecorationRenderer.DrawArmorStand then
		MC.DecorationRenderer.DrawArmorStand( self )
	end
end

function ENT:Draw()
	self:DrawTranslucent()
end
