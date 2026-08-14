ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Projectile"
ENT.Author = "schweiziske"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:SetupDataTables()
	self:NetworkVar( "String", 0, "ProjectileItemName" )
	self:NetworkVar( "Int", 0, "ProjectileDamage" )
	self:NetworkVar( "Vector", 0, "ProjectileVelocity" )
	self:NetworkVar( "Bool", 0, "ProjectileCritical" )
	self:NetworkVar( "Bool", 1, "ProjectileOnFire" )
end

function ENT:SetProjectileItem( item, damage )
	self:SetProjectileItemName( tostring( item or "" ) )
	self:SetProjectileDamage( math.max( 0, math.floor( tonumber( damage ) or 0 ) ) )
	return true
end

-- Keep a small compatibility alias for callers that use the generated
-- NetworkVar-style name directly.
function ENT:SetProjectileIdentity( item, damage )
	return self:SetProjectileItem( item, damage )
end

function ENT:GetProjectileStack()
	local item = self:GetProjectileItemName()
	if item == "" or not MC or not MC.NewItemStack then return nil end
	return MC.NewItemStack( item, 1, nil, self:GetProjectileDamage() )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end
