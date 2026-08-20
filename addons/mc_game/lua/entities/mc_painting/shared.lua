ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Painting"
ENT.Author = "MCSWEP"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:SetupDataTables()
	MC.Decoration.DefineHangingData( self )
	self:NetworkVar( "String", 0, "PaintingVariant" )
end

function ENT:GetMinecraftVariant()
	return MC.Decoration.PaintingVariant( self:GetPaintingVariant() )
		or MC.Decoration.PaintingVariant( "minecraft:kebab" )
end

function ENT:SetMinecraftVariant( variant )
	local resolved = MC.Decoration.PaintingVariant( variant )
	if not resolved then return false, "unknown_painting_variant" end
	self:SetPaintingVariant( resolved.name )
	MC.Decoration.RecalculateHanging( self )
	return true
end

function ENT:GetDecorationGeometry()
	local variant = self:GetMinecraftVariant()
	return MC.Decoration.PaintingGeometry(
		variant.width, variant.height, self:GetDecorationDirection() )
end

function ENT:GetDecorationSupportCells()
	local variant = self:GetMinecraftVariant()
	return MC.Decoration.SupportCells(
		self:GetDecorationBX(), self:GetDecorationBY(), self:GetDecorationBZ(),
		variant.width, variant.height, self:GetDecorationDirection() )
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end

