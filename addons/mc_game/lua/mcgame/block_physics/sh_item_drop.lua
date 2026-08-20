-- ItemEntity-specific block effects.  The existing SENT remains responsible
-- for pickup/merge/lifetime; this adapter only applies the Java movement
-- recurrence at its tick boundary and deliberately does not invent a second
-- item-drop implementation.

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

hook.Add( "Think", "mcgame_block_physics_item_drop", function()
	if not P.Enabled() then return end
	local itemParity = MC.ItemEntityParity
	if itemParity and itemParity.Enabled and itemParity.Enabled() then return end
	for _, entity in ipairs( ents.FindByClass( "mc_item_drop" ) or {} ) do
		if validEntity( entity ) then
			local state = stateFor( entity )
			local now = CurTime and CurTime() or 0
			local seconds = math.max( 0.001, math.min( 0.1, now - ( state.lastThink or now ) ) )
			state.lastThink = now
			local velocity = entityVelocity( entity )
			local sample = P.SampleEntity( entity )
			local blockName = sample and sample.belowName or "minecraft:air"
			local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
			local onGround = entity.IsOnGround and entity:IsOnGround() == true or false
			if not onGround then
				onGround = IsValid and IsValid( physics ) and physics.IsAsleep and physics:IsAsleep() or false
			end

			-- ItemEntity#getDefaultGravity is 0.04 blocks/tick² and its air drag is
			-- inherited Entity#getAirDrag (0.98). Source's physics body already
			-- applies gravity; only apply this explicit correction when no body is
			-- available, keeping the default SENT behavior untouched otherwise.
			if not IsValid or not IsValid( physics ) then
				local velocityX, velocityY, velocityZ = P.VelocityToBlocksPerTick( velocity )
				velocityZ = velocityZ - C.defaultGravity * ( seconds / C.tickSeconds )
				velocity = P.BlocksPerTickToVelocity( velocityX, velocityY, velocityZ )
			end

			if state.pendingWeb then
				local horizontal, vertical = state.pendingWeb.horizontal, state.pendingWeb.vertical
				local vx, vy, vz = P.ScaleVelocityPerTick( velocity.x, velocity.y, velocity.z,
					horizontal, horizontal, vertical, seconds )
				velocity = Vector( vx, vy, vz )
			end
			state.pendingWeb = nil
			if sample and sample.hasCobweb then
				local horizontal, _, vertical = P.WebMultiplier( false )
				state.pendingWeb = { horizontal = horizontal, vertical = vertical }
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
					-- The VPhysics body already supplied the ordinary Source floor
					-- damping. Apply only the Java special-block ratio here; checkpoint
					-- 4 owns the complete ItemEntity gravity/drag replacement.
					local relative = P.PerTickFactor( friction / C.defaultFriction, seconds )
					velocity.x, velocity.y = velocity.x * relative, velocity.y * relative
				end
			end
			setEntityVelocity( entity, velocity )
		end
	end
end )

hook.Add( "EntityRemoved", "mcgame_block_physics_item_drop_cleanup", function( entity )
		if P.ItemDropState then P.ItemDropState[entity] = nil end
end )
