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
	ent:SetPos( position + Vector(
		math.Rand( -3, 3 ),
		math.Rand( -3, 3 ),
		math.Rand( 1, 5 )
	) )
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
