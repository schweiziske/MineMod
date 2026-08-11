AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local ITEM_LIFETIME = 300

local function now()
	return CurTime()
end

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
	self.MCCreatedAt = now()
	self.MCLifetime = ITEM_LIFETIME
	self.MCPickupReadyAt = now() + 0.5
	self.MCNextMergeAt = now() + 0.5
	self.MCPickingUp = false
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
	self.MCPickupReadyAt = now() + math.max( 0, tonumber( seconds ) or 0 )
end

function ENT:SetNeverPickup()
	self.MCPickupReadyAt = math.huge
end

function ENT:SetUnlimitedLifetime()
	self.MCLifetime = nil
	self.MCCreatedAt = -math.huge
end

function ENT:SetDropOwner( actor, target )
	self.MCDropActor = IsValid( actor ) and actor or nil
	self.MCPickupTarget = IsValid( target ) and target or nil
end

function ENT:SetDropStack( input )
	local stack, stackError = MC.NormalizeItemStack( input )
	if not stack then return false, stackError or "invalid_stack" end
	self.MCItemStack = MC.CopyItemStack( stack )
	self:SetItemName( stack.item )
	self:SetItemCount( stack.count )
	self:SetItemDamage( stack.damage or 0 )
	local components = stack.components and util and util.TableToJSON and util.TableToJSON( stack.components, false ) or ""
	-- NetworkVar strings are intentionally kept below the engine's compact
	-- string limit; oversized component payloads remain server-side and simply
	-- use the definition/texture fallback on clients.
	if type( components ) ~= "string" or #components > 480 then components = "" end
	self:SetItemComponents( components )
	return true
end

function ENT:GetDropStack()
	return MC.CopyItemStack( self.MCItemStack )
end

function ENT:TryPickup( ply )
	if self.MCPickingUp or CurTime() < ( self.MCPickupReadyAt or 0 ) then return false end
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	if IsValid( self.MCPickupTarget ) and self.MCPickupTarget ~= ply then return false end
	local stack = self.MCItemStack
	if MC.IsEmptyItemStack( stack ) or not MC.SV or not MC.SV.InsertPlayerItem then return false end
	local pickupPosition = self:GetPos()
	self.MCPickingUp = true
	local remaining, result = MC.SV.InsertPlayerItem( ply, stack, {
		reason = "pickup",
		entity = self,
	} )
	self.MCPickingUp = false
	if not result or result.ok ~= true then return false end
	if remaining and remaining.count >= stack.count then return false end
	local moved = math.max( 0, ( tonumber( stack.count ) or 0 ) - ( tonumber( remaining and remaining.count ) or 0 ) )
	if moved > 0 and sound and sound.Play then
		local pitch = math.Clamp( math.floor( ( ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 0.7 + 1 ) * 200 + 0.5 ), 1, 255 )
		sound.Play( "mc/random/pop.ogg", pickupPosition, 70, pitch, 0.2 )
	end
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
	local current = CurTime()
	if self.MCLifetime and current - ( self.MCCreatedAt or current ) >= self.MCLifetime then
		self:Remove()
		return
	end
	if current >= ( self.MCNextMergeAt or 0 ) then
		self.MCNextMergeAt = current + 0.5
		if MC.SV and MC.SV.TryMergeItemDrop then MC.SV.TryMergeItemDrop( self ) end
		if not IsValid( self ) then return end
	end
	self:NextThink( current + 0.25 )
	return true
end
