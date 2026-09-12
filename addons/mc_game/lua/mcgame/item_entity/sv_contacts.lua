-- Source-verified ItemEntity fire and inside-block effects. Direct block
-- callbacks run while intersections are collected; deferred fire/fluid effects
-- then replay by movement step in InsideBlockEffectType enum order.

if not SERVER then return end

MC = MC or {}
MC.ItemEntityParity = MC.ItemEntityParity or {}

local R = MC.ItemEntityParity
local C = R.Constants
local BlockPhysics = MC.BlockPhysics

function R.FireBaseTick( entity, fluids, firstTick )
	local fireTicks = math.max( 0, math.floor( tonumber( entity.MCItemFireTicks ) or 0 ) )
	if fireTicks <= 0 then return true end
	local stack = entity.MCItemStack
	if not R.StackCanBeHurtBy( stack, "minecraft:in_fire" ) then
		entity.MCItemFireTicks = 0
		return true
	end
	local inLava = fluids.lava and ( tonumber( fluids.lava.height ) or 0 ) > 0
	-- Entity#isInLava deliberately returns false during the first baseTick.
	if fireTicks % C.onFireDamageInterval == 0 and ( firstTick == true or not inLava ) then
		R.HurtItem( entity, "minecraft:on_fire", 1, nil )
		if not IsValid( entity ) then return false end
	end
	entity.MCItemFireTicks = fireTicks - 1
	return true
end

local function applyHoneySlide( cell, sample, velocity, onGround )
	if not BlockPhysics or not BlockPhysics.IsHoneySliding
	or not BlockPhysics.HoneySlideVelocity then return velocity end
	local cellMin = R.CellWorldBounds( cell.bx, cell.by, cell.bz )
	local foot = sample and sample.foot or nil
	if not cellMin or not foot then return velocity end
	local size = R.BlockSize()
	local absoluteX = cell.bx + ( foot.x - cellMin.x ) / size
	local absoluteY = cell.by + ( foot.y - cellMin.y ) / size
	local absoluteZ = cell.bz + ( foot.z - cellMin.z ) / size
	if not BlockPhysics.IsHoneySliding( {
		blockX = cell.bx, blockY = cell.by, blockZ = cell.bz,
		entityX = absoluteX, entityY = absoluteY, entityZ = absoluteZ,
		width = C.width, onGround = onGround, velocityZ = velocity.z,
	} ) then return velocity end
	local x, y, z = BlockPhysics.HoneySlideVelocity( velocity.x, velocity.y, velocity.z )
	velocity.x, velocity.y, velocity.z = x, y, z
	return velocity
end

local function newDeferredStep( stepIndex )
	return {
		stepIndex = stepIndex,
		fireIgnite = false,
		fireDamage = {},
		fireDamageCount = 0,
		lavaIgnite = false,
		lavaDamageCount = 0,
		extinguish = false,
	}
end

local function applyDeferredStep( entity, queued )
	-- InsideBlockEffectType order in out is FIRE_IGNITE, LAVA_IGNITE,
	-- EXTINGUISH (FREEZE entries are irrelevant to ItemEntity here). Each
	-- runAfter callback follows its own type before the next enum value.
	if queued.fireIgnite then
		R.IgniteForTicks( entity, C.fireSeconds * C.fireTicksPerSecond )
		for i = 1, queued.fireDamageCount do
			R.HurtItem( entity, "minecraft:in_fire", queued.fireDamage[i], nil )
			if not IsValid( entity ) then return false end
		end
	end
	if queued.lavaIgnite then
		local stack = entity.MCItemStack
		-- Entity#lavaHurt guards both ignition and the lava DamageSource with
		-- ItemEntity#fireImmune, which is defined against in_fire specifically.
		if R.StackCanBeHurtBy( stack, "minecraft:in_fire" ) then
			R.IgniteForTicks( entity, C.lavaFireSeconds * C.fireTicksPerSecond )
			for _ = 1, queued.lavaDamageCount do
				R.HurtItem( entity, "minecraft:lava", C.lavaDamage, nil )
				if not IsValid( entity ) then return false end
			end
		end
	end
	if queued.extinguish then entity.MCItemFireTicks = 0 end
	return true
end

function R.ApplyInsideEffects( entity, state, cells, sample, velocity, onGround )
	if not cells or #cells == 0 then return velocity, true end
	local deferred = state.insideDeferred
	if not deferred then deferred = {}; state.insideDeferred = deferred end
	local pendingWeb, current, stepCount = false, nil, 0
	for i = 1, #cells do
		local cell = cells[i]
		local stepIndex = math.floor( tonumber( cell.stepIndex ) or 0 )
		if not current or current.stepIndex ~= stepIndex then
			stepCount = stepCount + 1
			current = deferred[stepCount]
			if not current then current = newDeferredStep( stepIndex ); deferred[stepCount] = current end
			current.stepIndex, current.fireDamageCount, current.lavaDamageCount = stepIndex, 0, 0
			current.fireIgnite, current.lavaIgnite, current.extinguish = false, false, false
		end
		if cell.name == "minecraft:cobweb" then
			pendingWeb = true
		elseif cell.name == "minecraft:honey_block" then
			velocity = applyHoneySlide( cell, sample, velocity, onGround )
		elseif cell.name == "minecraft:cactus" then
			R.HurtItem( entity, "minecraft:cactus", C.cactusDamage, nil )
		elseif cell.name == "minecraft:fire" or cell.name == "minecraft:soul_fire" then
			current.fireIgnite = true
			current.fireDamageCount = current.fireDamageCount + 1
			current.fireDamage[current.fireDamageCount] = cell.name == "minecraft:soul_fire"
				and C.soulFireDamage or C.inFireDamage
		end
		if not IsValid( entity ) then return velocity, false end
		if cell.fluid and cell.fluid.kind == "lava" then
			current.lavaIgnite = true
			current.lavaDamageCount = current.lavaDamageCount + 1
		elseif cell.fluid and cell.fluid.kind == "water" then
			current.extinguish = true
		end
	end
	if pendingWeb then state.pendingWeb = true end
	for i = 1, stepCount do
		if not applyDeferredStep( entity, deferred[i] ) then return velocity, false end
	end
	return velocity, true
end

function R.MovementSpeedFactor( sample )
	if not BlockPhysics or not BlockPhysics.SpeedFactorFor then return 1 end
	local here = sample and sample.hereName or "minecraft:air"
	if here == "minecraft:water" or here == "minecraft:bubble_column" then
		return BlockPhysics.SpeedFactorFor( here )
	end
	local factor = BlockPhysics.SpeedFactorFor( here )
	return factor == 1 and BlockPhysics.SpeedFactorFor( sample and sample.belowName ) or factor
end
