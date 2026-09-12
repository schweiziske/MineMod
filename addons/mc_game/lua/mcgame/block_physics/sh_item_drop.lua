-- ItemEntity-specific block effects.  The existing SENT remains responsible
-- for pickup/merge/lifetime; this adapter only applies the Java movement
-- recurrence at its tick boundary and deliberately does not invent a second
-- item-drop implementation.

-- These bodies are server-authoritative, unlike predicted player movement.
-- Also remove the old client hook when this shared file is auto-refreshed.
if not SERVER then
	hook.Remove( "Think", "mcgame_block_physics_item_drop" )
	hook.Remove( "EntityRemoved", "mcgame_block_physics_item_drop_cleanup" )
	return
end

MC = MC or {}
MC.BlockPhysics = MC.BlockPhysics or {}

local P = MC.BlockPhysics
local C = P.Constants

local function validEntity( entity )
	return IsValid and IsValid( entity ) and entity.GetClass and entity:GetClass() == "mc_item_drop"
end

local function stateFor( entity )
	P.ItemDropState = P.ItemDropState or setmetatable( {}, { __mode = "k" } )
	local state = P.ItemDropState[entity]
	if state then return state end
	state = { lastThink = CurTime and CurTime() or 0 }
	P.ItemDropState[entity] = state
	return state
end

local function entityVelocity( entity )
	if entity.GetVelocity then return entity:GetVelocity() end
	local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
	return IsValid and IsValid( physics ) and physics.GetVelocity and physics:GetVelocity() or vector_origin
end

local function setEntityVelocity( entity, velocity )
	local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
	if IsValid and IsValid( physics ) and physics.SetVelocity then physics:SetVelocity( velocity ); return true end
	if entity.SetVelocity then
		local current = entityVelocity( entity )
		entity:SetVelocity( velocity - current )
		return true
	end
	return false
end

local function honeySlideVelocity( sample, velocity )
	if not sample or #sample.honeyCells == 0 then return velocity end
	local vx, vy, vz = P.VelocityToBlocksPerTick( velocity )
	local blockSize = P.BlockSize()
	for index = 1, #sample.honeyCells do
		local cell = sample.honeyCells[index]
		if P.IsHoneySliding( {
			blockX = cell.bx, blockY = cell.by, blockZ = cell.bz,
			entityX = sample.origin.x / blockSize,
			entityY = sample.origin.y / blockSize,
			entityZ = sample.origin.z / blockSize,
			width = sample.widthBlocks,
			onGround = false,
			velocityZ = vz,
		} ) then
			vx, vy, vz = P.HoneySlideVelocity( vx, vy, vz )
			return P.BlocksPerTickToVelocity( vx, vy, vz )
		end
	end
	return velocity
end

local function tickItem( entity, state, physics, seconds )
	local velocity = entityVelocity( entity )
	local oldX, oldY, oldZ = velocity.x, velocity.y, velocity.z
	local sample = P.SampleEntity( entity )
	local blockName = sample and sample.belowName or "minecraft:air"
	local onGround = entity.IsOnGround and entity:IsOnGround() == true or false
	-- VPhysics already supplies ordinary gravity and floor damping.
	if not IsValid( physics ) then
		local vx, vy, vz = P.VelocityToBlocksPerTick( velocity )
		vz = vz - C.defaultGravity * ( seconds / C.tickSeconds )
		velocity = P.BlocksPerTickToVelocity( vx, vy, vz )
	end
	if state.hasPendingWeb then
		velocity.x, velocity.y, velocity.z = P.ScaleVelocityPerTick( velocity.x, velocity.y, velocity.z,
			state.webHorizontal, state.webHorizontal, state.webVertical, seconds )
	end
	state.hasPendingWeb = sample and sample.hasCobweb == true or false
	if state.hasPendingWeb then
		local horizontal, _, vertical = P.WebMultiplier( false )
		state.webHorizontal, state.webVertical = horizontal, vertical
	end
	velocity = honeySlideVelocity( sample, velocity )
	local movementName = sample and P.EffectiveMovementBlock( sample ) or "minecraft:air"
	local speedFactor = P.SpeedFactorFor( movementName )
	if speedFactor ~= C.defaultSpeedFactor then
		local factor = P.PerTickFactor( speedFactor, seconds )
		velocity.x, velocity.y = velocity.x * factor, velocity.y * factor
	end
	if onGround then
		local friction = P.FrictionFor( blockName )
		if friction ~= C.defaultFriction then
			local relative = P.PerTickFactor( friction / C.defaultFriction, seconds )
			velocity.x, velocity.y = velocity.x * relative, velocity.y * relative
		end
	end
	-- Setting an unchanged velocity wakes resting physics bodies and causes
	-- collision/network work even on ordinary blocks with no special effect.
	if velocity.x ~= oldX or velocity.y ~= oldY or velocity.z ~= oldZ then
		setEntityVelocity( entity, velocity )
	end
end

hook.Add( "Think", "mcgame_block_physics_item_drop", function()
	if not P.Enabled() then return end
	local itemParity = MC.ItemEntityParity
	if itemParity and itemParity.Enabled and itemParity.Enabled() then return end
	local records = MC.ItemDropQuery.All()
	local current = CurTime()
	for i = 1, #records do
		local entity = records[i].entity
		if validEntity( entity ) then
			local state = stateFor( entity )
			local seconds = math.max( 0.001, math.min( 0.1, current - state.lastThink ) )
			state.lastThink = current
			local physics = entity:GetPhysicsObject()
			if not IsValid( physics ) or not physics:IsAsleep() then tickItem( entity, state, physics, seconds ) end
		end
	end
end )

hook.Add( "EntityRemoved", "mcgame_block_physics_item_drop_cleanup", function( entity )
		if P.ItemDropState then P.ItemDropState[entity] = nil end
end )
