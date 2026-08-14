ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Primed TNT"
ENT.Author = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar( "Int", 0, "FuseTicks" )
	self:NetworkVar( "Float", 0, "ExplosionPower" )
	self:NetworkVar( "Bool", 0, "Armed" )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end
