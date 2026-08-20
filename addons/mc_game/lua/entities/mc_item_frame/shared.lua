ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Item Frame"
ENT.Author = "MCSWEP"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:SetupDataTables()
	MC.Decoration.DefineHangingData( self )
	self:NetworkVar( "String", 0, "FrameItemName" )
	self:NetworkVar( "String", 1, "FrameItemComponents" )
	self:NetworkVar( "Int", 4, "FrameItemCount" )
	self:NetworkVar( "Int", 5, "FrameItemDamage" )
	self:NetworkVar( "Int", 6, "FrameRotation" )
	self:NetworkVar( "Bool", 1, "FrameFixed" )
	self:NetworkVar( "Float", 0, "FrameDropChance" )
end

function ENT:GetFrameItemNameForDrop()
	return "minecraft:item_frame"
end

function ENT:IsGlowMinecraftFrame()
	return false
end

function ENT:FrameSoundEvent( action )
	return "entity.item_frame." .. tostring( action )
end

function ENT:GetMinecraftFrameItem()
	if SERVER and self.MCFramedStack then return MC.CopyItemStack( self.MCFramedStack ) end
	return MC.Decoration.DecodeNetworkStack( self, {
		name = self.GetFrameItemName,
		components = self.GetFrameItemComponents,
		count = self.GetFrameItemCount,
		damage = self.GetFrameItemDamage,
	} )
end

function ENT:SetMinecraftFrameItem( input, notify )
	local stack
	if input ~= nil then
		stack = MC.NormalizeItemStack and select( 1, MC.NormalizeItemStack( input ) ) or input
		if not stack then return false, "invalid_frame_item" end
		stack = MC.CopyItemStack and MC.CopyItemStack( stack, 1 ) or stack
	end
	local previous = self:GetAnalogOutput()
	-- ItemFrame#setItem does not call removeFramedMap. Map tracking is removed
	-- only by kill(), the dropItem branches, or the load-data replacement path.
	-- Keeping that side effect out of this setter is observable when
	-- ENTITY_DROPS is false and the damage source has an entity.
	if SERVER then self.MCFramedStack = stack and MC.CopyItemStack( stack, 1 ) or nil end
	MC.Decoration.EncodeNetworkStack( self, stack, {
		name = self.SetFrameItemName,
		components = self.SetFrameItemComponents,
		count = self.SetFrameItemCount,
		damage = self.SetFrameItemDamage,
	} )
	MC.Decoration.RecalculateHanging( self )
	if SERVER and stack then
		MC.Decoration.PlayDecorationSound( self:FrameSoundEvent( "add_item" ), self, 1, 1 )
	end
	if notify ~= false and SERVER and MC.Decoration.NotifyAnalogOutputChanged then
		MC.Decoration.NotifyAnalogOutputChanged( self, previous )
	end
	return true
end

function ENT:HasFramedMinecraftMap()
	return MC.Decoration.HasMap( self:GetMinecraftFrameItem() )
end

function ENT:SetMinecraftRotation( rotation, notify )
	local previous = self:GetAnalogOutput()
	self:SetFrameRotation( MC.Decoration.NormalizeRotation( rotation ) )
	if notify ~= false and SERVER and MC.Decoration.NotifyAnalogOutputChanged then
		MC.Decoration.NotifyAnalogOutputChanged( self, previous )
	end
end

function ENT:GetAnalogOutput()
	return MC.Decoration.AnalogOutput( self:GetMinecraftFrameItem(), self:GetFrameRotation() )
end

function ENT:GetDecorationGeometry( popBox )
	return MC.Decoration.FrameGeometry(
		self:GetDecorationDirection(), self:HasFramedMinecraftMap(), popBox == true )
end

function ENT:GetDecorationSupportCells()
	return { MC.Decoration.FrameSupportCell(
		self:GetDecorationBX(), self:GetDecorationBY(), self:GetDecorationBZ(),
		self:GetDecorationDirection() ) }
end

function ENT:UpdateTransmitState()
	return TRANSMIT_ALWAYS
end
