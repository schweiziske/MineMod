AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local ITEM_LIFETIME = 300

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	self:SetModelScale( 0.45, 0 )
	self:PhysicsInitBox( Vector( -5, -5, -5 ), Vector( 5, 5, 5 ) )
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_WEAPON )
	self:SetTrigger( true )
	self:UseTriggerBounds( true, 18 )
	self:SetUseType( SIMPLE_USE )
	self:DrawShadow( false )
	self.MCCreatedAt = CurTime()
	self.MCPickupReadyAt = CurTime() + 0.5
	local physics = self:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetMass( 0.2 )
		physics:SetDamping( 0.1, 0.4 )
		physics:Wake()
	end
end

function ENT:UpdateTransmitState()
	-- MC worlds commonly extend beyond the BSP PVS.
	return TRANSMIT_ALWAYS
end

function ENT:SetPickupDelay( seconds )
	self.MCPickupReadyAt = CurTime() + math.max( 0, tonumber( seconds ) or 0 )
end

function ENT:SetDropStack( input )
	local stack, stackError = MC.NormalizeItemStack( input )
	if not stack then return false, stackError or "invalid_stack" end
	self.MCItemStack = MC.CopyItemStack( stack )
	self:SetItemName( stack.item )
	self:SetItemCount( stack.count )
	self:SetItemDamage( stack.damage or 0 )
	return true
end

function ENT:GetDropStack()
	return MC.CopyItemStack( self.MCItemStack )
end

function ENT:TryPickup( ply )
	if self.MCPickingUp or CurTime() < ( self.MCPickupReadyAt or 0 ) then return false end
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	local stack = self.MCItemStack
	if MC.IsEmptyItemStack( stack ) or not MC.SV or not MC.SV.InsertPlayerItem then return false end
	self.MCPickingUp = true
	local remaining, result = MC.SV.InsertPlayerItem( ply, stack, {
		reason = "pickup",
		entity = self,
	} )
	self.MCPickingUp = false
	if not result or result.ok ~= true then return false end
	if remaining and remaining.count >= stack.count then return false end
	if MC.IsEmptyItemStack( remaining ) then
		self:Remove()
	else
		self:SetDropStack( remaining )
		self:SetPickupDelay( 0.2 )
	end
	return true
end

function ENT:StartTouch( other )
	self:TryPickup( other )
end

function ENT:Use( activator )
	self:TryPickup( activator )
end

function ENT:Think()
	if CurTime() - ( self.MCCreatedAt or CurTime() ) >= ITEM_LIFETIME then
		self:Remove()
		return
	end
	self:NextThink( CurTime() + 1 )
	return true
end
