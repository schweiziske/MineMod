--[[----------------------------------------------------------------------------
	Authoritative dropped ItemStack spawning.

	Dropped items are transient Garry's Mod entities; persistent inventories and
	containers remain plain tables. The entity only networks the small visual
	identity while the complete stack (including components) stays server-side.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local MERGE_RADIUS = 24
local MINECRAFT_TICKS_PER_SECOND = 20

local function appendDeathDrop( drops, stack )
	if MC.IsEmptyItemStack( stack ) then return end
	drops[#drops + 1] = MC.CopyItemStack( stack )
end

local function samePickupTarget( left, right )
	local a, b = left and left.MCPickupTarget, right and right.MCPickupTarget
	if IsValid( a ) or IsValid( b ) then return a == b end
	return true
end

-- Pure stack merge primitive used by entities and runtime tests.  Components,
-- damage and item identity are compared by the shared ItemStack rules.
function SV.MergeItemStacks( toStack, fromStack, maxCount )
	if MC.IsEmptyItemStack( toStack ) or MC.IsEmptyItemStack( fromStack )
		or not MC.ItemStacksCanMerge( toStack, fromStack ) then
		return MC.CopyItemStack( toStack ), MC.CopyItemStack( fromStack ), 0
	end
	local limit = math.min( MC.ItemStackMaxCount( toStack ), math.floor( tonumber( maxCount ) or MC.ItemStackMaxCount( toStack ) ) )
	local room = math.max( 0, limit - math.floor( tonumber( toStack.count ) or 0 ) )
	local moved = math.min( room, math.floor( tonumber( fromStack.count ) or 0 ) )
	if moved <= 0 then return MC.CopyItemStack( toStack ), MC.CopyItemStack( fromStack ), 0 end
	local merged = MC.CopyItemStack( toStack, toStack.count + moved )
	local remaining = fromStack.count > moved and MC.CopyItemStack( fromStack, fromStack.count - moved ) or nil
	return merged, remaining, moved
end

local function mergeInto( target, sourceStack, sourceEntity )
	if not IsValid( target ) or target == sourceEntity or not target.GetDropStack then return sourceStack, 0 end
	if not samePickupTarget( target, sourceEntity ) then return sourceStack, 0 end
	local merged, remaining, moved = SV.MergeItemStacks( target:GetDropStack(), sourceStack, 64 )
	if moved <= 0 then return sourceStack, 0 end
	local oldDelay = math.max( tonumber( target.MCPickupReadyAt ) or 0, tonumber( sourceEntity and sourceEntity.MCPickupReadyAt ) or 0 )
	local oldCreated = math.min( tonumber( target.MCCreatedAt ) or CurTime(), tonumber( sourceEntity and sourceEntity.MCCreatedAt ) or CurTime() )
	if not target:SetDropStack( merged ) then return sourceStack, 0 end
	target.MCPickupReadyAt = oldDelay
	target.MCCreatedAt = oldCreated
	if sourceEntity and IsValid( sourceEntity ) and not MC.IsEmptyItemStack( remaining ) then
		sourceEntity:SetDropStack( remaining )
	elseif sourceEntity and IsValid( sourceEntity ) then
		sourceEntity:Remove()
	end
	return remaining, moved
end

function SV.TryMergeItemDrop( ent )
	if not IsValid( ent ) or ent.MCDropMerging or ent.MCPickupReadyAt == math.huge then return false end
	if not ents or not ents.FindInSphere then return false end
	ent.MCDropMerging = true
	local merged = false
	local sourceStack = ent.GetDropStack and ent:GetDropStack() or nil
	if not MC.IsEmptyItemStack( sourceStack ) then
		for _, other in ipairs( ents.FindInSphere( ent:GetPos(), MERGE_RADIUS ) or {} ) do
			if IsValid( other ) and other:GetClass() == "mc_item_drop" and other:EntIndex() < ent:EntIndex()
			and not other.MCDropMerging and other.GetDropStack then
				local before = sourceStack.count
				local remaining, moved = mergeInto( other, sourceStack, ent )
				if moved > 0 then
					merged = true
					sourceStack = remaining
					if MC.IsEmptyItemStack( sourceStack ) then break end
					if sourceStack.count >= before then break end
				end
			end
		end
	end
	ent.MCDropMerging = nil
	return merged
end

local function mergeAtPosition( position, stack, actor, options )
	if options.noMerge == true or not ents or not ents.FindInSphere then return nil end
	for _, ent in ipairs( ents.FindInSphere( position, MERGE_RADIUS ) or {} ) do
		local requestedTarget = options.target
		local ownerOK = ( IsValid( requestedTarget ) and ent and ent.MCPickupTarget == requestedTarget )
			or ( not IsValid( requestedTarget ) and not IsValid( ent and ent.MCPickupTarget ) )
		if IsValid( ent ) and ent:GetClass() == "mc_item_drop" and ent.GetDropStack and ownerOK then
			local candidate = ent:GetDropStack()
			local merged, remaining, moved = SV.MergeItemStacks( candidate, stack, 64 )
			if moved > 0 and ent:SetDropStack( merged ) then
				local requestedDelay = math.max( 0, tonumber( options.pickupDelay ) or 0 )
				ent.MCPickupReadyAt = math.max( tonumber( ent.MCPickupReadyAt ) or 0, CurTime() + requestedDelay )
				return ent, remaining
			end
		end
	end
	return nil
end

local function randomVelocity()
	return Vector(
		math.Rand( -45, 45 ),
		math.Rand( -45, 45 ),
		math.Rand( 55, 95 )
	)
end

local function minecraftVelocityScale()
	return math.max( 1, tonumber( MC.BS ) or 36.5 ) * MINECRAFT_TICKS_PER_SECOND
end

-- LivingEntity#createItemStackToDrop(false, true): 0.3 block/tick along the
-- player's view, plus Minecraft's small random spread and upward bias.
function SV.PlayerThrownDropVelocity( ply )
	local aim = IsValid( ply ) and ply.GetAimVector and ply:GetAimVector() or Vector( 1, 0, 0 )
	local direction = math.Rand( 0, math.pi * 2 )
	local spread = 0.02 * math.Rand( 0, 1 )
	local velocity = aim * 0.3 + Vector(
		math.cos( direction ) * spread,
		math.sin( direction ) * spread,
		0.1 + ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 0.1
	)
	return velocity * minecraftVelocityScale()
end

-- LivingEntity#createItemStackToDrop(true, false): inventory contents fan out
-- horizontally with a fixed upward kick when the player dies.
function SV.PlayerDeathDropVelocity()
	local power = math.Rand( 0, 1 ) * 0.5
	local direction = math.Rand( 0, math.pi * 2 )
	return Vector(
		-math.sin( direction ) * power,
		math.cos( direction ) * power,
		0.2
	) * minecraftVelocityScale()
end

function SV.PlayerItemDropPosition( ply )
	if not IsValid( ply ) then return nil end
	local eyePosition = ply.EyePos and ply:EyePos() or ply:GetPos()
	return eyePosition - Vector( 0, 0, ( tonumber( MC.BS ) or 36.5 ) * 0.3 )
end

function SV.SpawnItemDrop( position, input, actor, options )
	local stack, stackError = MC.NormalizeItemStack( input )
	if not stack then return nil, stackError or "invalid_stack" end
	if not position then return nil, "invalid_position" end
	options = istable( options ) and options or {}
	local mergedEntity, remaining = mergeAtPosition( position, stack, actor, options )
	if IsValid( mergedEntity ) then
		if not MC.IsEmptyItemStack( remaining ) then
			local retryOptions = {}
			for key, value in pairs( options ) do retryOptions[key] = value end
			retryOptions.noMerge = true
			return SV.SpawnItemDrop( position, remaining, actor, retryOptions )
		end
		return mergedEntity
	end

	local ent = ents.Create( "mc_item_drop" )
	if not IsValid( ent ) then return nil, "item_drop_entity_unavailable" end
	local spawnPosition = position
	if options.positionJitter ~= false then
		spawnPosition = position + Vector(
			math.Rand( -3, 3 ),
			math.Rand( -3, 3 ),
			math.Rand( 1, 5 )
		)
	end
	ent:SetPos( spawnPosition )
	ent:Spawn()
	ent:Activate()
	local accepted, setError = ent:SetDropStack( stack )
	if accepted ~= true then
		ent:Remove()
		return nil, setError or "item_drop_stack_rejected"
	end
	ent:SetPickupDelay( tonumber( options.pickupDelay ) or 0.5 )
	ent:SetDropOwner( actor, options.target )
	if options.lifetime ~= nil then
		local lifetime = tonumber( options.lifetime )
		if lifetime and lifetime <= 0 then ent:SetUnlimitedLifetime() elseif lifetime then ent.MCLifetime = math.min( lifetime, 86400 ) end
	end

	local velocity = options.velocity
	if not isvector( velocity ) then velocity = randomVelocity() end
	local physics = ent:GetPhysicsObject()
	if IsValid( physics ) then
		physics:SetVelocity( velocity )
		physics:AddAngleVelocity( VectorRand() * 120 )
	end
	return ent
end

-- Close transient menus first, then atomically move the persistent inventory
-- into a drop snapshot. Clearing before spawning makes repeated death hooks safe.
function SV.DropPlayerInventoryOnDeath( ply )
	if not IsValid( ply ) or not ply:IsPlayer() then return 0, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record then return 0, "inventory_not_loaded" end

	if record.session and SV.ClosePlayerInventory then
		SV.ClosePlayerInventory( ply, "death" )
	end
	if MC.Config.KeepInventory and MC.Config.KeepInventory:GetBool() then
		return 0, "keep_inventory"
	end

	local drops = {}
	local container = record.container
	local inventorySnapshot = container and MC.ContainerSnapshot( container ) or nil
	if container then
		for slot = 0, 35 do appendDeathDrop( drops, MC.ContainerGetStack( container, slot ) ) end
		appendDeathDrop( drops, container.cursor )
	else
		for slot = 1, 36 do appendDeathDrop( drops, record.storage and record.storage[slot] ) end
	end
	local equipmentSnapshot = SV.EquipmentSnapshot and SV.EquipmentSnapshot( record ) or {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		appendDeathDrop( drops, record.equipment and record.equipment[slot] )
	end
	appendDeathDrop( drops, record.carried )

	if container and inventorySnapshot then
		for slot = 0, 35 do MC.ContainerSetStack( container, slot, nil ) end
		container.cursor = nil
		SV.CommitPlayerInventoryMutation( record, inventorySnapshot, { reason = "death_drop" } )
	else
		for slot = 1, 36 do record.storage[slot] = nil end
		record.revision = math.max( 0, math.floor( tonumber( record.revision ) or 0 ) ) + 1
		record.dirty = true
	end

	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do record.equipment[slot] = nil end
	if SV.CommitEquipmentMutation then
		SV.CommitEquipmentMutation( record, equipmentSnapshot, { reason = "death_drop" } )
	elseif SV.UpdatePlayerEquipmentNetwork then
		SV.UpdatePlayerEquipmentNetwork( record )
		record.dirty = true
	end
	record.carried = nil
	record.dirty = true
	if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end

	if SV.SavePlayerInventory then
		local saved, saveError = SV.SavePlayerInventory( record, true )
		if saved ~= true and ErrorNoHalt then
			ErrorNoHalt( "[MC Inventory] death drop save failed: " .. tostring( saveError ) .. "\n" )
		end
	end

	local position = SV.PlayerItemDropPosition( ply ) or ply:GetPos()
	local spawned = 0
	for _, stack in ipairs( drops ) do
		local ent = SV.SpawnItemDrop( position, stack, ply, {
			pickupDelay = 1.0,
			noMerge = true,
			velocity = SV.PlayerDeathDropVelocity(),
		} )
		if IsValid( ent ) then spawned = spawned + 1 end
	end
	return spawned, #drops
end
