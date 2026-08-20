-- 20 Hz server runtime for Minecraft ItemEntity semantics. VPhysics supplies
-- collision placement only; gravity, drag, fluids, age and merge state are
-- advanced here in the same order as ItemEntity#tick.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.ItemEntityParity = MC.ItemEntityParity or {}

local R = MC.ItemEntityParity
local C = R.Constants
local SV = MC.SV
local BlockPhysics = MC.BlockPhysics

R.EntityStates = R.EntityStates or setmetatable( {}, { __mode = "k" } )

local function validDrop( entity )
	return IsValid( entity ) and entity.GetClass and entity:GetClass() == "mc_item_drop"
end

local function now()
	return CurTime and CurTime() or 0
end

local function physicsFor( entity )
	local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
	return IsValid( physics ) and physics or nil
end

local function blocksFromSource( velocity )
	local scale = R.BlockSize() / C.tickSeconds
	if not isvector( velocity ) then return 0, 0, 0 end
	return velocity.x / scale, velocity.y / scale, velocity.z / scale
end

local function sourceFromBlocks( x, y, z )
	local scale = R.BlockSize() / C.tickSeconds
	return Vector( ( tonumber( x ) or 0 ) * scale,
		( tonumber( y ) or 0 ) * scale, ( tonumber( z ) or 0 ) * scale )
end

local function setPhysicsVelocity( entity, x, y, z )
	local physics = physicsFor( entity )
	if not physics or not physics.SetVelocity then return false end
	physics:SetVelocity( sourceFromBlocks( x, y, z ) )
	if physics.Wake then physics:Wake() end
	return true
end

local function configurePhysics( entity, state )
	local physics = physicsFor( entity )
	if not physics then return end
	if not state.physicsConfigured then
		local vx, vy, vz = blocksFromSource( physics.GetVelocity and physics:GetVelocity() or vector_origin )
		if not state.initialVelocity then state.velocity = { x = vx, y = vy, z = vz } end
	end
	if physics.EnableGravity then physics:EnableGravity( false ) end
	if physics.EnableDrag then physics:EnableDrag( false ) end
	if physics.SetDamping then physics:SetDamping( 0, 0 ) end
	if physics.SetBuoyancyRatio then physics:SetBuoyancyRatio( 0 ) end
	if entity.SetElasticity then entity:SetElasticity( 0 ) end
	state.physicsConfigured = true
end

local function legacyAge( entity )
	if entity.MCItemAgeTicks ~= nil then return math.floor( tonumber( entity.MCItemAgeTicks ) or 0 ) end
	if entity.MCLifetime == nil and entity.MCCreatedAt == -math.huge then return C.infiniteAge end
	return math.max( 0, math.floor( ( now() - ( tonumber( entity.MCCreatedAt ) or now() ) ) / C.tickSeconds ) )
end

local function legacyPickupDelay( entity )
	if entity.MCPickupDelayTicks ~= nil then return math.floor( tonumber( entity.MCPickupDelayTicks ) or 0 ) end
	if entity.MCPickupReadyAt == math.huge then return C.infinitePickupDelay end
	return math.max( 0, math.ceil( ( ( tonumber( entity.MCPickupReadyAt ) or now() ) - now() ) / C.tickSeconds ) )
end

function R.StateFor( entity, create )
	local state = R.EntityStates[entity]
	if state or create == false or not validDrop( entity ) then return state end
	state = {
		started = false,
		tickCount = math.max( 0, math.floor( tonumber( entity.MCItemTickCount ) or 0 ) ),
		velocity = { x = 0, y = 0, z = 0 },
		onGround = false,
		collision = {},
	}
	R.EntityStates[entity] = state
	entity.MCItemAgeTicks = legacyAge( entity )
	entity.MCPickupDelayTicks = legacyPickupDelay( entity )
	entity.MCItemHealth = math.floor( tonumber( entity.MCItemHealth ) or C.defaultHealth )
	entity.MCItemFireTicks = math.max( 0, math.floor( tonumber( entity.MCItemFireTicks ) or 0 ) )
	if entity.MCItemLifetimeTicks == nil and entity.MCLifetime ~= nil then
		entity.MCItemLifetimeTicks = R.SecondsToTicks( entity.MCLifetime )
	end
	configurePhysics( entity, state )
	setPhysicsVelocity( entity, 0, 0, 0 )
	return state
end

function R.ConfigureEntity( entity )
	return R.StateFor( entity, true )
end

function R.RestoreLegacyEntity( entity )
	local state = R.EntityStates[entity]
	if not state then return false end
	local age = math.floor( tonumber( entity.MCItemAgeTicks ) or 0 )
	entity.MCCreatedAt = age == C.infiniteAge and -math.huge or now() - math.max( 0, age ) * C.tickSeconds
	entity.MCLifetime = age == C.infiniteAge and nil or math.max( C.tickSeconds,
		( tonumber( entity.MCItemLifetimeTicks ) or C.lifetimeTicks ) * C.tickSeconds )
	local delay = math.floor( tonumber( entity.MCPickupDelayTicks ) or 0 )
	entity.MCPickupReadyAt = delay == C.infinitePickupDelay and math.huge or now() + math.max( 0, delay ) * C.tickSeconds
	local physics = physicsFor( entity )
	if physics then
		if physics.EnableGravity then physics:EnableGravity( true ) end
		if physics.EnableDrag then physics:EnableDrag( true ) end
		if physics.SetDamping then physics:SetDamping( 0.1, 0.4 ) end
	end
	R.EntityStates[entity] = nil
	return true
end

function R.SetInitialVelocity( entity, velocity )
	local state = R.StateFor( entity, true )
	if not state then return false end
	configurePhysics( entity, state )
	local x, y, z = blocksFromSource( velocity )
	state.velocity = { x = x, y = y, z = z }
	state.initialVelocity = true
	state.started = false
	setPhysicsVelocity( entity, 0, 0, 0 )
	return true
end

function R.SetPickupDelayTicks( entity, ticks )
	ticks = math.floor( tonumber( ticks ) or 0 )
	entity.MCPickupDelayTicks = ticks == C.infinitePickupDelay and ticks or math.max( 0, ticks )
	entity.MCPickupReadyAt = entity.MCPickupDelayTicks == C.infinitePickupDelay
		and math.huge or now() + entity.MCPickupDelayTicks * C.tickSeconds
end

function R.SetAgeTicks( entity, ticks )
	entity.MCItemAgeTicks = math.floor( tonumber( ticks ) or 0 )
end

function R.SetLifetimeSeconds( entity, seconds )
	seconds = tonumber( seconds )
	if seconds and seconds <= 0 then
		R.SetAgeTicks( entity, C.infiniteAge )
		entity.MCItemLifetimeTicks = nil
	elseif seconds then
		entity.MCItemLifetimeTicks = math.max( 1, R.SecondsToTicks( seconds ) )
	end
end

function R.PickupReady( entity )
	return math.floor( tonumber( entity.MCPickupDelayTicks ) or 0 ) == 0
end

local function playerIdentity( playerEntity )
	if not IsValid( playerEntity ) then return nil end
	if playerEntity.SteamID64 then
		local value = tostring( playerEntity:SteamID64() or "" )
		if value ~= "" and value ~= "0" then return "steam64:" .. value end
	end
	if playerEntity.SteamID then
		local value = tostring( playerEntity:SteamID() or "" )
		if value ~= "" and value ~= "BOT" then return "steam:" .. value end
	end
	return "entity:" .. tostring( playerEntity.EntIndex and playerEntity:EntIndex() or playerEntity )
end

function R.SetDropOwner( entity, actor, target )
	entity.MCDropActor = IsValid( actor ) and actor or nil
	entity.MCPickupTarget = IsValid( target ) and target or nil
	entity.MCPickupTargetKey = playerIdentity( target )
end

function R.PickupTargetMatches( entity, playerEntity )
	local targetKey = entity.MCPickupTargetKey
	if targetKey ~= nil then return targetKey == playerIdentity( playerEntity ) end
	return not IsValid( entity.MCPickupTarget ) or entity.MCPickupTarget == playerEntity
end

local function targetKeysEqual( left, right )
	local leftKey, rightKey = left.MCPickupTargetKey, right.MCPickupTargetKey
	if leftKey ~= nil or rightKey ~= nil then return leftKey == rightKey end
	local a, b = left.MCPickupTarget, right.MCPickupTarget
	if IsValid( a ) or IsValid( b ) then return a == b end
	return true
end

local function effectiveMergeStack( stack )
	local copy = MC.CopyItemStack( stack )
	if not copy then return nil end
	local resistance = R.EffectiveDamageResistance and R.EffectiveDamageResistance( copy ) or nil
	if resistance ~= nil then
		if type( copy.components ) ~= "table" then copy.components = {} end
		if copy.components["minecraft:damage_resistant"] == nil
		and copy.components.damage_resistant == nil then
			copy.components["minecraft:damage_resistant"] = resistance
		end
	end
	return copy
end

local function stacksCanMerge( left, right )
	return MC.ItemStacksCanMerge( effectiveMergeStack( left ), effectiveMergeStack( right ) )
end

local function emitItemEvent( name, ... )
	if hook and hook.Run then hook.Run( name, ... ) end
end

function R.HurtItem( entity, damageType, damage, source )
	if not validDrop( entity ) then return false end
	local stack = entity.GetDropStack and entity:GetDropStack() or nil
	if MC.IsEmptyItemStack( stack ) or not R.StackCanBeHurtBy( stack, damageType ) then return false end
	local oldHealth = math.floor( tonumber( entity.MCItemHealth ) or C.defaultHealth )
	local newHealth = R.HealthAfterDamage( oldHealth, damage )
	entity.MCItemHealth = newHealth
	emitItemEvent( "MC.ItemEntityDamaged", entity, damageType, damage, oldHealth, newHealth, source )
	if newHealth <= 0 then
		emitItemEvent( "MC.ItemEntityDestroyed", entity, MC.CopyItemStack( stack ), damageType, source )
		entity:Remove()
	end
	return true
end

function R.IgniteForTicks( entity, ticks )
	local stack = entity.GetDropStack and entity:GetDropStack() or nil
	if not R.StackCanBeHurtBy( stack, "minecraft:in_fire" ) then return false end
	entity.MCItemFireTicks = math.max( math.floor( tonumber( entity.MCItemFireTicks ) or 0 ),
		math.max( 0, math.floor( tonumber( ticks ) or 0 ) ) )
	return true
end

local function supportingGround( entity, foot, velocity )
	if not util or not util.TraceHull or not entity.GetPos then return false end
	local distance = math.max( 1, R.BlockSize() * 0.02 )
	local start = entity:GetPos()
	local trace = util.TraceHull( {
		start = start,
		endpos = start - Vector( 0, 0, distance ),
		mins = entity.OBBMins and entity:OBBMins() or Vector( -1, -1, -1 ),
		maxs = entity.OBBMaxs and entity:OBBMaxs() or Vector( 1, 1, 1 ),
		filter = entity,
		mask = MASK_SOLID or nil,
	} )
	return trace and trace.Hit == true and ( tonumber( velocity and velocity.z ) or 0 ) <= 0
end

local function finishPreviousMovement( entity, state )
	local minimum, maximum = R.WorldBounds( entity )
	if not minimum then return true end
	local foot = R.FootWorldPosition( entity, minimum, maximum )
	local actualZ = state.startFoot and ( foot.z - state.startFoot.z ) / R.BlockSize() or 0
	local base = state.zeroAfterStuck and { x = 0, y = 0, z = 0 } or state.velocityBeforeMove
	local velocity = { x = base.x, y = base.y, z = base.z }
	if state.pendingVelocityAdd then
		velocity.x = velocity.x + state.pendingVelocityAdd.x
		velocity.y = velocity.y + state.pendingVelocityAdd.y
		velocity.z = velocity.z + state.pendingVelocityAdd.z
		state.pendingVelocityAdd = nil
	end
	if state.pendingAxisOverride then
		local override = state.pendingAxisOverride
		if override.x ~= nil then velocity.x = override.x end
		if override.y ~= nil then velocity.y = override.y end
		if override.z ~= nil then velocity.z = override.z end
		state.pendingAxisOverride = nil
	end

	local collision = state.collision or {}
	local requested = state.requestedMove or velocity
	local onGround = state.onGround == true
	if not state.skipped then
		onGround = collision.below == true
		if not onGround and supportingGround( entity, foot, requested ) then onGround = true end
		if not onGround and state.onGround and requested.z <= 0
		and math.abs( actualZ ) < 1.0e-5 then onGround = true end
		if collision.x then velocity.x = 0 end
		if collision.y then velocity.y = 0 end
	end
	local sample = R.MovementBlockSample( entity, minimum, maximum )
	if not state.skipped and ( collision.z or collision.below ) then
		local restitution = BlockPhysics and BlockPhysics.BounceRestitutionFor
			and BlockPhysics.BounceRestitutionFor( sample.belowName, false ) or 0
		if collision.below and velocity.z < 0 and restitution > 0
		and BlockPhysics and BlockPhysics.RestituteVerticalVelocity then
			velocity.z = BlockPhysics.RestituteVerticalVelocity(
				velocity.z, actualZ, C.gravity, C.airDrag, restitution )
		else
			velocity.z = 0
		end
	end
	if not state.skipped then
		local speedFactor = R.MovementSpeedFactor( sample )
		velocity.x, velocity.y = velocity.x * speedFactor, velocity.y * speedFactor
		if onGround and sample.belowName == "minecraft:slime_block"
		and BlockPhysics and BlockPhysics.SlimeStepScale then
			local stepScale = BlockPhysics.SlimeStepScale( velocity.z, false )
			velocity.x, velocity.y = velocity.x * stepScale, velocity.y * stepScale
		end
	end

	local cells
	if state.skipped and state.lastStartMinimum then
		cells = R.InsideCellsAlongPath( state.lastStartMinimum, state.lastStartMaximum,
			state.lastEndMinimum, state.lastEndMaximum )
	else
		cells = R.InsideCellsAlongPath( state.startMinimum, state.startMaximum, minimum, maximum )
		if not state.skipped then
			state.lastStartMinimum, state.lastStartMaximum = state.startMinimum, state.startMaximum
			state.lastEndMinimum, state.lastEndMaximum = minimum, maximum
		end
	end
	local insideOK
	velocity, insideOK = R.ApplyInsideEffects( entity, state, cells, sample, velocity, onGround )
	if insideOK ~= true then return false end
	if not IsValid( entity ) then return false end
	if not state.skipped then
		local friction = BlockPhysics and BlockPhysics.FrictionFor
			and BlockPhysics.FrictionFor( sample.belowName ) or 0.6
		velocity.x, velocity.y, velocity.z = R.ApplyDrag(
			velocity.x, velocity.y, velocity.z, onGround, friction )
	end

	local movedAcrossCell = R.MovedAcrossCell( state.startFoot, foot )
	if R.ShouldMergeThisTick( state.tickCount, movedAcrossCell ) then R.TryMergeNeighbours( entity ) end
	if not IsValid( entity ) then return false end
	local age = math.floor( tonumber( entity.MCItemAgeTicks ) or 0 )
	if age ~= C.infiniteAge then entity.MCItemAgeTicks = age + 1 end
	local secondFluids = R.FluidTrackersForBounds( minimum, maximum )
	velocity.x, velocity.y, velocity.z = R.ApplyTrackedCurrents(
		velocity.x, velocity.y, velocity.z, secondFluids )
	state.velocity, state.onGround = velocity, onGround
	local lifetime = entity.MCItemLifetimeTicks ~= nil
		and math.floor( tonumber( entity.MCItemLifetimeTicks ) or C.lifetimeTicks ) or C.lifetimeTicks
	if entity.MCItemAgeTicks ~= C.infiniteAge and entity.MCItemAgeTicks >= lifetime then
		entity:Remove()
		return false
	end
	return true
end

local function beginNextMovement( entity, state )
	state.tickCount = state.tickCount + 1
	entity.MCItemTickCount = state.tickCount
	local minimum, maximum = R.WorldBounds( entity )
	if not minimum then return false end
	local fluids = R.FluidTrackersForBounds( minimum, maximum )
	local velocity = state.velocity
	velocity.x, velocity.y, velocity.z = R.ApplyTrackedCurrents(
		velocity.x, velocity.y, velocity.z, fluids )
	if not R.FireBaseTick( entity, fluids, state.tickCount == 1 ) then return false end
	local delay = math.floor( tonumber( entity.MCPickupDelayTicks ) or 0 )
	if delay > 0 and delay ~= C.infinitePickupDelay then entity.MCPickupDelayTicks = delay - 1 end
	velocity.x, velocity.y, velocity.z = R.ApplyPreMoveForces(
		velocity.x, velocity.y, velocity.z, fluids )

	state.startMinimum, state.startMaximum = minimum, maximum
	state.startFoot = R.FootWorldPosition( entity, minimum, maximum )
	state.velocityBeforeMove = { x = velocity.x, y = velocity.y, z = velocity.z }
	state.zeroAfterStuck = false
	state.skipped = R.ShouldSkipMovement( state.onGround, velocity.x, velocity.y,
		state.tickCount, entity.EntIndex and entity:EntIndex() or 0 )
	local moveX, moveY, moveZ = velocity.x, velocity.y, velocity.z
	if not state.skipped and state.pendingWeb then
		local multiplierX, multiplierY, multiplierZ = BlockPhysics and BlockPhysics.WebMultiplier
			and BlockPhysics.WebMultiplier( false ) or 0.25, 0.25, 0.05
		moveX, moveY, moveZ = moveX * multiplierX, moveY * multiplierY, moveZ * multiplierZ
		state.pendingWeb = nil
		state.zeroAfterStuck = true
	end
	state.requestedMove = { x = moveX, y = moveY, z = moveZ }
	state.collision = {}
	if state.skipped then setPhysicsVelocity( entity, 0, 0, 0 )
	else setPhysicsVelocity( entity, moveX, moveY, moveZ ) end
	return true
end

function R.ThinkEntity( entity )
	local state = R.StateFor( entity, true )
	if not state then return false end
	configurePhysics( entity, state )
	if state.started and not finishPreviousMovement( entity, state ) then return false end
	if not IsValid( entity ) then return false end
	local began = beginNextMovement( entity, state )
	state.started = began == true
	return began
end

function R.RecordCollision( entity, data )
	local state = R.StateFor( entity, true )
	if not state then return false end
	local normal = type( data ) == "table" and data.HitNormal or nil
	local oldVelocity = type( data ) == "table" and data.OurOldVelocity or nil
	if isvector( normal ) then
		if math.abs( normal.x ) > 0.5 then state.collision.x = true end
		if math.abs( normal.y ) > 0.5 then state.collision.y = true end
		if math.abs( normal.z ) > 0.5 then
			state.collision.z = true
			if normal.z > 0 and ( not isvector( oldVelocity ) or oldVelocity.z <= 0 ) then state.collision.below = true end
		end
	elseif isvector( oldVelocity ) and oldVelocity.z < 0 then
		state.collision.z, state.collision.below = true, true
	end
	return true
end

function R.AddVelocityBlocks( entity, velocity )
	local state = R.StateFor( entity, true )
	if not state or not isvector( velocity ) then return false end
	state.pendingVelocityAdd = state.pendingVelocityAdd or { x = 0, y = 0, z = 0 }
	state.pendingVelocityAdd.x = state.pendingVelocityAdd.x + velocity.x
	state.pendingVelocityAdd.y = state.pendingVelocityAdd.y + velocity.y
	state.pendingVelocityAdd.z = state.pendingVelocityAdd.z + velocity.z
	local physics = physicsFor( entity )
	if physics and physics.AddVelocity then
		local sourceVelocity = sourceFromBlocks( velocity.x, velocity.y, velocity.z )
		physics:AddVelocity( sourceVelocity )
	end
	return true
end

function R.OverrideVelocityAxis( entity, dx, dy, dz )
	local state = R.StateFor( entity, true )
	if not state then return false end
	state.pendingAxisOverride = state.pendingAxisOverride or {}
	if dx ~= 0 then state.pendingAxisOverride.x = dx end
	if dy ~= 0 then state.pendingAxisOverride.y = dy end
	if dz ~= 0 then state.pendingAxisOverride.z = dz end
	return true
end

function R.ApplyDamageInfo( entity, damageInfo )
	local metadata = SV.GetCombatDamageContext and SV.GetCombatDamageContext( entity, damageInfo ) or nil
	local damageType = type( metadata ) == "table" and metadata.damageTypeId or nil
	if not damageType and ( ( tonumber( SV.MinecraftExplosionDamageDepth ) or 0 ) > 0
		or damageInfo and damageInfo.IsDamageType and DMG_BLAST ~= nil and damageInfo:IsDamageType( DMG_BLAST ) ) then
		damageType = "minecraft:explosion"
	elseif not damageType and damageInfo and damageInfo.IsDamageType
	and ( DMG_BURN ~= nil and damageInfo:IsDamageType( DMG_BURN )
		or DMG_SLOWBURN ~= nil and damageInfo:IsDamageType( DMG_SLOWBURN ) ) then
		damageType = "minecraft:on_fire"
	end
	-- ItemEntity#isAttackable is false. Unknown Source prop damage is therefore
	-- not promoted to a Minecraft damage source without explicit metadata.
	if not damageType then return false end
	local damage = damageInfo and damageInfo.GetDamage and damageInfo:GetDamage() or 0
	local source = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	return R.HurtItem( entity, damageType, damage, source )
end

local function isMergable( entity )
	if not validDrop( entity ) or entity.MCPickupDelayTicks == C.infinitePickupDelay
	or entity.MCItemAgeTicks == C.infiniteAge
	or ( tonumber( entity.MCItemAgeTicks ) or 0 ) >= C.lifetimeTicks then return false end
	local stack = entity.GetDropStack and entity:GetDropStack() or nil
	return not MC.IsEmptyItemStack( stack )
		and stack.count < ( MC.ItemStackMaxCount and MC.ItemStackMaxCount( stack ) or 0 )
end

local function candidateIntersects( expandedMin, expandedMax, candidate )
	local minimum, maximum = R.WorldBounds( candidate )
	return minimum and R.AABBIntersects( expandedMin, expandedMax, minimum, maximum ) or false
end

function R.TryMergeNeighbours( entity )
	if not isMergable( entity ) or entity.MCDropMerging or not ents or not ents.FindByClass then return false end
	local minimum, maximum = R.WorldBounds( entity )
	if not minimum then return false end
	local inflate = R.BlockSize() * C.mergeHorizontalInflate
	local expandedMin = minimum - Vector( inflate, inflate, 0 )
	local expandedMax = maximum + Vector( inflate, inflate, 0 )
	entity.MCDropMerging = true
	local merged = false
	for _, other in ipairs( ents.FindByClass( "mc_item_drop" ) or {} ) do
		if other ~= entity and isMergable( other ) and not other.MCDropMerging
		and candidateIntersects( expandedMin, expandedMax, other ) and targetKeysEqual( entity, other ) then
			local currentStack, otherStack = entity:GetDropStack(), other:GetDropStack()
			local maximumCount = MC.ItemStackMaxCount( currentStack )
			if stacksCanMerge( currentStack, otherStack )
			and R.CountsCanMerge( currentStack.count, otherStack.count, maximumCount ) then
				local target, source, targetStack, sourceStack
				if R.MergeTarget( currentStack.count, otherStack.count ) == "current" then
					target, source, targetStack, sourceStack = entity, other, currentStack, otherStack
				else
					target, source, targetStack, sourceStack = other, entity, otherStack, currentStack
				end
				local combined = MC.CopyItemStack( targetStack, targetStack.count + sourceStack.count )
				if target:SetDropStack( combined ) then
					target.MCPickupDelayTicks = math.max( tonumber( target.MCPickupDelayTicks ) or 0,
						tonumber( source.MCPickupDelayTicks ) or 0 )
					target.MCItemAgeTicks = math.min( tonumber( target.MCItemAgeTicks ) or 0,
						tonumber( source.MCItemAgeTicks ) or 0 )
					source:Remove()
					merged = true
					if source == entity then break end
				end
			end
		end
		if not IsValid( entity ) then break end
	end
	if IsValid( entity ) then entity.MCDropMerging = nil end
	return merged
end

function R.TryPickupPlayers( entity )
	if not R.PickupReady( entity ) or not player or not player.GetAll then return false end
	for _, ply in ipairs( player.GetAll() or {} ) do
		if IsValid( ply ) and ply.IsPlayer and ply:IsPlayer() and ply.Alive and ply:Alive()
		and R.PlayerTouchesItem( ply, entity ) and entity.TryPickup and entity:TryPickup( ply ) then return true end
		if not IsValid( entity ) then return true end
	end
	return false
end

hook.Add( "EntityRemoved", "mcgame_item_entity_parity_cleanup", function( entity )
	R.EntityStates[entity] = nil
end )
