ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Item"
ENT.Author = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false

function ENT:SetupDataTables()
	self:NetworkVar( "String", 0, "ItemName" )
	self:NetworkVar( "Int", 0, "ItemCount" )
	self:NetworkVar( "Int", 1, "ItemDamage" )
end
