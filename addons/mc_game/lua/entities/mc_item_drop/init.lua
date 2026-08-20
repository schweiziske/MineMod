AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
include( "shared.lua" )

local PHYSICS_MODEL = "models/hunter/blocks/cube025x025x025.mdl"
local ITEM_LIFETIME = 300
local TRIGGER_PADDING = 18
local PICKUP_SCAN_EXTENT = 5 + TRIGGER_PADDING

local function now()
	return CurTime()
end

local function itemParity()
	local parity = MC and MC.ItemEntityParity
	return parity and parity.Enabled and parity.Enabled() == true or false
end

function ENT:Initialize()
	self:SetModel( PHYSICS_MODEL )
	self:SetModelScale( 0.45, 0 )
	if itemParity() then
		local size = MC.ItemEntityParity.BlockSize and MC.ItemEntityParity.BlockSize() or 36.5
		local half = math.max( 0.001, size * 0.125 )
		self:PhysicsInitBox( Vector( -half, -half, -half ), Vector( half, half, half ) )
	else
		self:PhysicsInitBox( Vector( -5, -5, -5 ), Vector( 5, 5, 5 ) )
	end
	self:SetMoveType( MOVETYPE_VPHYSICS )
	self:SetSolid( SOLID_VPHYSICS )
	self:SetCollisionGroup( COLLISION_GROUP_WEAPON )
	self:SetTrigger( true )
	self:UseTriggerBounds( true, TRIGGER_PADDING )
	self:SetUseType( SIMPLE_USE )
	self:DrawShadow( false )
	self.MCCreatedAt = now()
	self.MCLifetime = ITEM_LIFETIME
	self.MCPickupReadyAt = now() + 0.5
	self.MCNextMergeAt = now() + 0.5
	self.MCPickingUp = false
	if itemParity() then
		self.MCItemAgeTicks = 0
		self.MCPickupDelayTicks = MC.ItemEntityParity.Constants.defaultPickupDelayTicks
		self.MCItemHealth = MC.ItemEntityParity.Constants.defaultHealth
		self.MCItemFireTicks = 0
		self.MCItemTickCount = 0
	end
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
	if itemParity() and MC.ItemEntityParity.SetPickupDelayTicks then
		MC.ItemEntityParity.SetPickupDelayTicks( self, MC.ItemEntityParity.SecondsToTicks( seconds ) )
		return
	end
	self.MCPickupReadyAt = now() + math.max( 0, tonumber( seconds ) or 0 )
end

function ENT:SetNeverPickup()
	if itemParity() and MC.ItemEntityParity.SetPickupDelayTicks then
		MC.ItemEntityParity.SetPickupDelayTicks( self, MC.ItemEntityParity.Constants.infinitePickupDelay )
		return
	end
	self.MCPickupReadyAt = math.huge
end

function ENT:SetUnlimitedLifetime()
	if itemParity() and MC.ItemEntityParity.SetAgeTicks then
		MC.ItemEntityParity.SetAgeTicks( self, MC.ItemEntityParity.Constants.infiniteAge )
		return
	end
	self.MCLifetime = nil
	self.MCCreatedAt = -math.huge
end

function ENT:SetExtendedLifetime()
	if itemParity() and MC.ItemEntityParity.SetAgeTicks then
		MC.ItemEntityParity.SetAgeTicks( self, MC.ItemEntityParity.Constants.extendedAge )
		return
	end
	self.MCCreatedAt = now() - 300
end

function ENT:MakeFakeItem()
	if itemParity() and MC.ItemEntityParity.SetAgeTicks then
		MC.ItemEntityParity.SetPickupDelayTicks( self, MC.ItemEntityParity.Constants.infinitePickupDelay )
		MC.ItemEntityParity.SetAgeTicks( self, MC.ItemEntityParity.Constants.lifetimeTicks - 1 )
		return
	end
	self:SetNeverPickup()
	self.MCCreatedAt = now() - ( ITEM_LIFETIME - 0.05 )
end

function ENT:SetDropOwner( actor, target )
	if itemParity() and MC.ItemEntityParity.SetDropOwner then
		MC.ItemEntityParity.SetDropOwner( self, actor, target )
		return
	end
	self.MCDropActor = IsValid( actor ) and actor or nil
	self.MCPickupTarget = IsValid( target ) and target or nil
end

function ENT:MCBlockPhysicsWorldOrigin( minimum, _, origin )
	if not isvector( minimum ) or not isvector( origin ) then return origin end
	-- Minecraft ItemEntity#getY is the AABB foot, while this Source physics
	-- prop's origin is its centre.  The shared adapter asks the entity for this
	-- correction instead of guessing from a class name.
	return Vector( origin.x, origin.y, minimum.z )
end

function ENT:PhysicsCollide( data, physics )
	if itemParity() then
		if MC.ItemEntityParity.RecordCollision then MC.ItemEntityParity.RecordCollision( self, data ) end
		return
	end
	local blockPhysics = MC.BlockPhysics
	if not blockPhysics or not blockPhysics.Enabled or not blockPhysics.Enabled() then return end
	if not IsValid( physics ) or type( data ) ~= "table" or not isvector( data.OurOldVelocity ) then return end
	local sample = blockPhysics.SampleEntity and blockPhysics.SampleEntity( self ) or nil
	local blockName = sample and ( sample.onName == "minecraft:slime_block"
		and sample.onName or sample.belowName ) or "minecraft:air"
	if blockName ~= "minecraft:slime_block" or data.OurOldVelocity.z >= 0 then return end
	local current = physics:GetVelocity()
	local bounced = blockPhysics.SimpleBounceVelocity(
		data.OurOldVelocity.z, blockName, false, false
	)
	physics:SetVelocity( Vector( current.x, current.y, bounced ) )
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
	if self.MCPickingUp then return false end
	if itemParity() then
		if MC.ItemEntityParity.PickupReady and not MC.ItemEntityParity.PickupReady( self ) then return false end
	elseif CurTime() < ( self.MCPickupReadyAt or 0 ) then return false end
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	if itemParity() then
		if MC.ItemEntityParity.PickupTargetMatches and not MC.ItemEntityParity.PickupTargetMatches( self, ply ) then return false end
	elseif IsValid( self.MCPickupTarget ) and self.MCPickupTarget ~= ply then return false end
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
		if not itemParity() then self:SetPickupDelay( 0.2 ) end
	end
	return true
end

function ENT:StartTouch( other )
	if itemParity() and MC.ItemEntityParity.PlayerTouchesItem
	and not MC.ItemEntityParity.PlayerTouchesItem( other, self ) then return end
	self:TryPickup( other )
end

function ENT:Use( activator )
	self:TryPickup( activator )
end

-- Minecraft calls playerTouch for every entity in the player's inflated
-- pickup AABB on every aiStep. Source's StartTouch only fires on the overlap
-- transition, so a player already standing inside the trigger when the pickup
-- delay expires otherwise never gets another attempt until leaving/re-entering.
function ENT:TryPickupOverlaps()
	if itemParity() then
		return MC.ItemEntityParity.TryPickupPlayers and MC.ItemEntityParity.TryPickupPlayers( self ) or false
	end
	if CurTime() < ( self.MCPickupReadyAt or 0 ) or not ents or not ents.FindInBox then return false end
	local position = self:GetPos()
	local extent = Vector( PICKUP_SCAN_EXTENT, PICKUP_SCAN_EXTENT, PICKUP_SCAN_EXTENT )
	for _, other in ipairs( ents.FindInBox( position - extent, position + extent ) or {} ) do
		if self:TryPickup( other ) then return true end
		if not IsValid( self ) then return true end
	end
	return false
end

function ENT:MCAddExplosionVelocity( velocity )
	if not itemParity() or not MC.ItemEntityParity.AddVelocityBlocks then return false end
	return MC.ItemEntityParity.AddVelocityBlocks( self, velocity )
end

function ENT:OnTakeDamage( damageInfo )
	if not itemParity() or not MC.ItemEntityParity.ApplyDamageInfo then return 0 end
	MC.ItemEntityParity.ApplyDamageInfo( self, damageInfo )
	return 0
end

function ENT:Think()
	if itemParity() then
		if not MC.ItemEntityParity.ThinkEntity or not MC.ItemEntityParity.ThinkEntity( self ) then return end
		if IsValid( self ) and MC.LogisticsParity and MC.LogisticsParity.EntityInsideItemDrop then
			MC.LogisticsParity.EntityInsideItemDrop( self )
		end
		if IsValid( self ) and MC.ItemEntityParity.TryPickupPlayers then
			MC.ItemEntityParity.TryPickupPlayers( self )
		end
		if not IsValid( self ) then return end
		self:NextThink( now() + ( MC.ItemEntityParity.Constants.tickSeconds or 0.05 ) )
		return true
	end
	local current = CurTime()
	local logistics = MC.LogisticsParity
	local logisticsEnabled = logistics and logistics.Enabled and logistics.Enabled() == true or false
	if logisticsEnabled
	and logistics.EntityInsideItemDrop then
		logistics.EntityInsideItemDrop( self )
		if not IsValid( self ) then return end
	end
	if logisticsEnabled then
		local legacyAt = tonumber( self.MCLogisticsLegacyThinkAt )
		if legacyAt and current < legacyAt then
			self:NextThink( current + 0.05 )
			return true
		end
		self.MCLogisticsLegacyThinkAt = current + 0.25
	elseif self.MCLogisticsLegacyThinkAt then
		local legacyAt = tonumber( self.MCLogisticsLegacyThinkAt ) or current
		self.MCLogisticsLegacyThinkAt = nil
		if current < legacyAt then
			self:NextThink( legacyAt )
			return true
		end
	end
	if self.MCLifetime and current - ( self.MCCreatedAt or current ) >= self.MCLifetime then
		self:Remove()
		return
	end
	if current >= ( self.MCPickupReadyAt or 0 ) and self:TryPickupOverlaps() then
		if not IsValid( self ) then return end
		self:NextThink( current + ( logisticsEnabled and 0.05 or 0.25 ) )
		return true
	end
	if current >= ( self.MCNextMergeAt or 0 ) then
		self.MCNextMergeAt = current + 0.5
		if MC.SV and MC.SV.TryMergeItemDrop then MC.SV.TryMergeItemDrop( self ) end
		if not IsValid( self ) then return end
	end
	self:NextThink( current + ( logisticsEnabled and 0.05 or 0.25 ) )
	return true
end
