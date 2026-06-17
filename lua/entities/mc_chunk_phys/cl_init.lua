include( "shared.lua" )

ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:Initialize()
	self:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
	self:DrawShadow( false )
	self:SetNoDraw( true )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:EnableCustomCollisions( true )
	if self.MarkClientPhysDirtyFromMetadata then
		timer.Simple( 0, function()
			if IsValid( self ) and self.MarkClientPhysDirtyFromMetadata then
				self:MarkClientPhysDirtyFromMetadata()
			end
		end )
	end
end

function ENT:Draw()
end

function ENT:DrawTranslucent()
end
