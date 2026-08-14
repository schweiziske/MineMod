ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Minecart"
ENT.Author = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar( "String", 0, "MinecartItemName" )
	self:NetworkVar( "Entity", 0, "VehicleSeat" )
	self:NetworkVar( "Bool", 0, "OnRails" )
	self:NetworkVar( "Float", 0, "VehicleDamage" )
	self:NetworkVar( "Int", 0, "HurtDirection" )
	self:NetworkVar( "Float", 1, "HurtUntil" )
	self:NetworkVar( "Float", 2, "RailPitch" )
	-- Horizontal Java blocks/tick, independent of Source's sometimes-zero
	-- client GetVelocity() for a server-authoritative VPhysics rail entity.
	self:NetworkVar( "Float", 3, "MotionSpeed" )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end
