ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Boat"
ENT.Author = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
	self:NetworkVar( "String", 0, "BoatType" )
	self:NetworkVar( "String", 1, "BoatItemName" )
	self:NetworkVar( "Bool", 0, "Raft" )
	self:NetworkVar( "Bool", 1, "PaddleLeft" )
	self:NetworkVar( "Bool", 2, "PaddleRight" )
	self:NetworkVar( "String", 2, "BoatStatus" )
	self:NetworkVar( "Entity", 0, "VehicleSeat" )
	self:NetworkVar( "Entity", 1, "PassengerSeat" )
	self:NetworkVar( "Float", 0, "PaddlePhaseLeft" )
	self:NetworkVar( "Float", 1, "PaddlePhaseRight" )
	self:NetworkVar( "Float", 2, "VehicleDamage" )
	self:NetworkVar( "Int", 0, "HurtDirection" )
	self:NetworkVar( "Float", 3, "HurtUntil" )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end
