ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Armor Stand"
ENT.Author = "MineMod"
ENT.Spawnable = false
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

local SLOTS = { "mainhand", "offhand", "feet", "legs", "chest", "head" }

function ENT:SetupDataTables()
	self:NetworkVar( "Int", 0, "ArmorStandFlags" )
	self:NetworkVar( "Int", 1, "ArmorStandDisabledSlots" )
	self:NetworkVar( "Float", 0, "ArmorStandYaw" )
	self:NetworkVar( "Float", 1, "ArmorStandHealth" )
	self:NetworkVar( "Float", 2, "ArmorStandLastHit" )
	self:NetworkVar( "Bool", 0, "ArmorStandInvisible" )
	self:NetworkVar( "Bool", 1, "ArmorStandHasCustomName" )
	self:NetworkVar( "String", 24, "ArmorStandCustomName" )
	for index, slot in ipairs( SLOTS ) do
		local base = ( index - 1 ) * 4
		self:NetworkVar( "String", base, "ArmorStand" .. slot .. "Name" )
		self:NetworkVar( "String", base + 1, "ArmorStand" .. slot .. "Components" )
		self:NetworkVar( "Int", 2 + index, "ArmorStand" .. slot .. "Count" )
		self:NetworkVar( "Int", 8 + index, "ArmorStand" .. slot .. "Damage" )
	end
	local poses = { "Head", "Body", "LeftArm", "RightArm", "LeftLeg", "RightLeg" }
	for index, pose in ipairs( poses ) do self:NetworkVar( "Angle", index - 1, "ArmorStand" .. pose .. "Pose" ) end
end

function ENT:GetArmorStandScale()
	return self:IsArmorStandMarker() and 0 or ( self:IsArmorStandSmall() and MC.Decoration.Constants.armorStandSmallScale or 1 )
end

function ENT:GetDecorationScale()
	return self:GetArmorStandScale()
end

function ENT:IsArmorStandSmall()
	return MC.Decoration.ArmorStandFlag( self:GetArmorStandFlags(), MC.Decoration.Constants.armorStandFlagSmall )
end

function ENT:SetArmorStandSmall( value )
	local flags = self:GetArmorStandFlags()
	local bitValue = MC.Decoration.Constants.armorStandFlagSmall
	if bit and bit.bor and bit.band and bit.bnot then
		self:SetArmorStandFlags( value and bit.bor( flags, bitValue ) or bit.band( flags, bit.bnot( bitValue ) ) )
	else
		local present = flags % ( bitValue * 2 ) >= bitValue
		self:SetArmorStandFlags( value and ( present and flags or flags + bitValue )
			or ( present and flags - bitValue or flags ) )
	end
	self:RefreshArmorStandBounds()
end

function ENT:ShowArmorStandArms()
	return MC.Decoration.ArmorStandFlag( self:GetArmorStandFlags(), MC.Decoration.Constants.armorStandFlagShowArms )
end

function ENT:SetShowArmorStandArms( value )
	local flags = self:GetArmorStandFlags()
	local bitValue = MC.Decoration.Constants.armorStandFlagShowArms
	if bit and bit.bor and bit.band then
		self:SetArmorStandFlags( value and bit.bor( flags, bitValue ) or bit.band( flags, bit.bnot( bitValue ) ) )
	else
		local present = flags % ( bitValue * 2 ) >= bitValue
		self:SetArmorStandFlags( value and ( present and flags or flags + bitValue ) or ( present and flags - bitValue or flags ) )
	end
end

function ENT:ShowArmorStandBasePlate()
	return not MC.Decoration.ArmorStandFlag( self:GetArmorStandFlags(), MC.Decoration.Constants.armorStandFlagNoBasePlate )
end

function ENT:IsArmorStandMarker()
	return MC.Decoration.ArmorStandFlag( self:GetArmorStandFlags(), MC.Decoration.Constants.armorStandFlagMarker )
end

function ENT:SetArmorStandMarker( value )
	local flags = self:GetArmorStandFlags()
	local bitValue = MC.Decoration.Constants.armorStandFlagMarker
	if bit and bit.bor and bit.band then
		self:SetArmorStandFlags( value and bit.bor( flags, bitValue ) or bit.band( flags, bit.bnot( bitValue ) ) )
	else
		local present = flags % ( bitValue * 2 ) >= bitValue
		self:SetArmorStandFlags( value and ( present and flags or flags + bitValue ) or ( present and flags - bitValue or flags ) )
	end
	self:RefreshArmorStandBounds()
end

function ENT:IsArmorStandInvisible()
	return self.GetArmorStandInvisible and self:GetArmorStandInvisible() or false
end

function ENT:SetupArmorStandData()
	self:SetArmorStandFlags( 0 )
	self:SetArmorStandDisabledSlots( 0 )
	self:SetArmorStandYaw( 0 )
	self:SetArmorStandHealth( MC.Decoration.Constants.armorStandMaxHealth )
	self:SetArmorStandLastHit( 0 )
	self:SetArmorStandCustomName( "" )
	self:SetArmorStandHasCustomName( false )
	for _, slot in ipairs( SLOTS ) do self:SetArmorStandSlot( slot, nil, false ) end
	local defaults = MC.Decoration.ArmorStandDefaultPoses
	for _, pose in ipairs( { "Head", "Body", "LeftArm", "RightArm", "LeftLeg", "RightLeg" } ) do
		local value = defaults[string.lower( pose:sub( 1, 1 ) ) .. pose:sub( 2 )]
		if pose == "LeftArm" then value = defaults.leftArm elseif pose == "RightArm" then value = defaults.rightArm
		elseif pose == "LeftLeg" then value = defaults.leftLeg elseif pose == "RightLeg" then value = defaults.rightLeg
		elseif pose == "Head" then value = defaults.head else value = defaults.body end
		self["SetArmorStand" .. pose .. "Pose"]( self, Angle( value.x, value.y, value.z ) )
	end
end

function ENT:SetArmorStandRotation( yaw )
	self:SetArmorStandYaw( tonumber( yaw ) or 0 )
	self:SetAngles( Angle( 0, tonumber( yaw ) or 0, 0 ) )
end

function ENT:GetArmorStandSlot( slot )
	slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or slot
	if slot == "mainhand" or slot == "offhand" then
		-- NormalizeEquipmentSlot intentionally covers only player equipment. Keep
		-- the hand names explicit for ArmorStand's six-slot table.
		slot = slot
	end
	local prefix = "ArmorStand" .. tostring( slot or "" )
	local getter = self["Get" .. prefix .. "Name"]
	if not getter then return nil end
	return MC.Decoration.DecodeNetworkStack( self, {
		name = getter,
		components = self["Get" .. prefix .. "Components"],
		count = self["Get" .. prefix .. "Count"],
		damage = self["Get" .. prefix .. "Damage"],
	} )
end

function ENT:SetArmorStandSlot( slot, input, recalculate )
	slot = tostring( slot or "" )
	local prefix = "ArmorStand" .. slot
	local setter = self["Set" .. prefix .. "Name"]
	if not setter then return false, "invalid_equipment_slot" end
	local stack = input and ( MC.NormalizeItemStack and select( 1, MC.NormalizeItemStack( input ) ) or input ) or nil
	if stack then stack = MC.CopyItemStack( stack, 1 ) end
	MC.Decoration.EncodeNetworkStack( self, stack, {
		name = setter,
		components = self["Set" .. prefix .. "Components"],
		count = self["Set" .. prefix .. "Count"],
		damage = self["Set" .. prefix .. "Damage"],
	} )
	if recalculate ~= false and self.RefreshArmorStandBounds then self:RefreshArmorStandBounds() end
	return true
end

function ENT:GetItemBySlot( slot ) return self:GetArmorStandSlot( slot ) end
function ENT:HasItemInSlot( slot ) return self:GetArmorStandSlot( slot ) ~= nil end

function ENT:GetDecorationGeometry()
	local scale = self:GetArmorStandScale()
	if scale <= 0 then return { size = { x = 0, y = 0, z = 0 }, centerOffset = { x = 0, y = 0, z = 0 } } end
	return { size = { x = 0.5 * scale, y = 0.5 * scale, z = 1.975 * scale }, centerOffset = { x = 0, y = 0, z = 0.9875 * scale } }
end

function ENT:RefreshArmorStandBounds()
	if not self.SetCollisionBounds then return end
	local geometry = self:GetDecorationGeometry()
	local size = MC.Decoration.SizeToEngine( geometry.size )
	local half = size * 0.5
	if self:IsArmorStandMarker() then
		self:SetCollisionBounds( Vector( 0, 0, 0 ), Vector( 0, 0, 0 ) )
		self:SetSolid( SOLID_NONE )
	else
		-- ArmorStandItem uses Vec3.atBottomCenterOf(blockPos): the entity origin
		-- is the feet plane, not the AABB centre.
		self:SetCollisionBounds( Vector( -half.x, -half.y, 0 ), Vector( half.x, half.y, size.z ) )
		self:SetSolid( SOLID_BBOX )
	end
end

function ENT:UpdateTransmitState() return TRANSMIT_ALWAYS end
