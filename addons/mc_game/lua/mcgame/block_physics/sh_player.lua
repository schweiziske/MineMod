-- Player adapter for Java block friction/speed/jump/inside-block rules.
-- Source still owns hull collision; this file changes MoveData only after all
-- block identities and coefficients have been resolved through MC.API.

MC = MC or {}
MC.BlockPhysics = MC.BlockPhysics or {}

local P = MC.BlockPhysics
local C = P.Constants
local PlayerState = P.PlayerState or setmetatable( {}, { __mode = "k" } )
P.PlayerState = PlayerState

local function stateFor( player )
	local state = PlayerState[player]
	if state then return state end
	state = {}
	PlayerState[player] = state
	return state
end

local function validPlayer( player )
	return IsValid and IsValid( player ) and player.IsPlayer and player:IsPlayer()
end

local function grounded( player )
	return player.IsOnGround and player:IsOnGround() == true or false
end

local function steppingCarefully( player, move )
	if move and move.KeyDown and IN_DUCK and move:KeyDown( IN_DUCK ) then return true end
	if player.KeyDown and IN_DUCK and player:KeyDown( IN_DUCK ) then return true end
	return player.Crouching and player:Crouching() == true or false
end

local function frameSeconds()
	local seconds = FrameTime and FrameTime() or C.tickSeconds
	seconds = tonumber( seconds ) or C.tickSeconds
	return math.max( 0.001, math.min( 0.1, seconds ) )
end

local function vectorCopy( value )
	return Vector( value.x, value.y, value.z )
end

local function restoreJumpPower( player, state )
	if state.restoreJumpPower == nil then return end
	if player.SetJumpPower then player:SetJumpPower( state.restoreJumpPower ) end
	state.restoreJumpPower = nil
end

local function clearTransient( player, state )
	restoreJumpPower( player, state )
	state.pendingWeb = nil
	state.pendingBounce = nil
	state.soulSpeedActive = false
	state.previousVelocity = nil
	state.fallApexZ = nil
	state.lastAirVelocityZ = nil
	state.slimeLandingHandled = nil
end

local function scaleMoveInput( move, horizontal, vertical )
	if move.GetVelocity and move.SetVelocity then
		local velocity = move:GetVelocity()
		move:SetVelocity( Vector( velocity.x * horizontal, velocity.y * horizontal, velocity.z * vertical ) )
	end
	if move.GetForwardSpeed and move.SetForwardSpeed then
		move:SetForwardSpeed( move:GetForwardSpeed() * horizontal )
	end
	if move.GetSideSpeed and move.SetSideSpeed then
		move:SetSideSpeed( move:GetSideSpeed() * horizontal )
	end
	if move.GetUpSpeed and move.SetUpSpeed then
		move:SetUpSpeed( move:GetUpSpeed() * vertical )
	end
	if move.GetMaxSpeed and move.SetMaxSpeed then
		move:SetMaxSpeed( math.max( 0, move:GetMaxSpeed() * horizontal ) )
	end
	if move.GetMaxClientSpeed and move.SetMaxClientSpeed then
		move:SetMaxClientSpeed( math.max( 0, move:GetMaxClientSpeed() * horizontal ) )
	end
end

local function applyPendingWeb( state, move, seconds )
	local pending = state.pendingWeb
	state.pendingWeb = nil
	if not pending then return end
	local horizontal = P.PerTickFactor( pending.horizontal, seconds )
	local vertical = P.PerTickFactor( pending.vertical, seconds )
	scaleMoveInput( move, horizontal, vertical )
end

local function applyPendingBounce( state, move )
	local bounce = tonumber( state.pendingBounce )
	state.pendingBounce = nil
	if not bounce or bounce <= 0 or not move.GetVelocity or not move.SetVelocity then return end
	local velocity = move:GetVelocity()
	velocity = Vector( velocity.x, velocity.y, math.max( velocity.z, bounce ) )
	move:SetVelocity( velocity )
end

local function fallFlying( player )
	local runtime = MCITEM and MCITEM.EnchantmentRuntime or nil
	if not runtime or type( runtime.IsFallFlying ) ~= "function" then return false end
	local ok, active = pcall( runtime.IsFallFlying, player )
	return ok and active == true or false
end

local function updateSoulSpeedState( player, state, sample, isGrounded )
	local level = P.EquipmentEnchantmentLevel( player, "feet", "minecraft:soul_speed" )
	local inVehicle = player.InVehicle and player:InVehicle() == true or false
	if level <= 0 or inVehicle or fallFlying( player ) then
		state.soulSpeedActive = false
	elseif P.SoulSpeedBlocks[sample.belowName] or P.SoulSpeedBlocks[sample.onName] then
		state.soulSpeedActive = true
	elseif isGrounded then
		state.soulSpeedActive = false
	end
	return state.soulSpeedActive == true and C.soulSpeedMovementEfficiency or 0, level
end

local function trackFall( state, sample, isGrounded, velocity )
	if not sample or not sample.origin then return end
	if not isGrounded then
		state.slimeLandingHandled = false
		state.fallApexZ = math.max( tonumber( state.fallApexZ ) or sample.origin.z, sample.origin.z )
		local velocityZ = tonumber( velocity.z ) or 0
		if velocityZ < 0 then
			state.lastAirVelocityZ = math.min( tonumber( state.lastAirVelocityZ ) or velocityZ, velocityZ )
		end
	elseif state.wasGrounded == true then
		state.fallApexZ = nil
		state.lastAirVelocityZ = nil
	end
end

local function queueSlimeBounce( player, state, sample, move )
	if not sample or sample.onName ~= "minecraft:slime_block" or state.slimeLandingHandled == true then
		return false
	end
	-- Treat this landing as consumed even when Shift suppresses the bounce. A
	-- late OnPlayerHitGround callback must not re-evaluate a key released after
	-- contact or enqueue the same bounce for the following frame.
	state.slimeLandingHandled = true
	if steppingCarefully( player, move ) then return false end
	local incoming = math.min( tonumber( state.lastAirVelocityZ ) or 0, 0 )
	if incoming >= 0 then return false end
	local _, _, incomingBlocks = P.VelocityToBlocksPerTick( Vector( 0, 0, incoming ) )
	local restitution = P.BounceRestitutionFor( sample.onName, true )
	local bouncedBlocks = P.RestituteVerticalVelocity(
		incomingBlocks, 0, C.defaultGravity, C.defaultVerticalDrag, restitution
	)
	local bounce = P.BlocksPerTickToVelocity( 0, 0, bouncedBlocks ).z
	if bounce <= 0 then return false end
	state.pendingBounce = math.max( tonumber( state.pendingBounce ) or 0, bounce )
	return true
end

local function prepareHoneyJump( player, state, sample, move, isGrounded )
	if not isGrounded or not player.GetJumpPower or not player.SetJumpPower then return end
	if not move.KeyDown or not IN_JUMP or not move:KeyDown( IN_JUMP ) then return end
	local jumpFactor = P.EffectiveJumpFactor( sample.hereName, sample.belowName )
	if jumpFactor == C.defaultJumpFactor then return end
	local original = player:GetJumpPower()
	state.restoreJumpPower = original
	player:SetJumpPower( original * jumpFactor )
end

local function honeySlideVelocity( sample, velocity, isGrounded )
	if not sample or #sample.honeyCells == 0 then return velocity, false end
	local vx, vy, vz = P.VelocityToBlocksPerTick( velocity )
	local blockSize = P.BlockSize()
	local entityX = sample.origin.x / blockSize
	local entityY = sample.origin.y / blockSize
	local entityZ = sample.origin.z / blockSize
	for index = 1, #sample.honeyCells do
		local cell = sample.honeyCells[index]
		if P.IsHoneySliding( {
			blockX = cell.bx,
			blockY = cell.by,
			blockZ = cell.bz,
			entityX = entityX,
			entityY = entityY,
			entityZ = entityZ,
			width = sample.widthBlocks,
			onGround = isGrounded,
			velocityZ = vz,
		} ) then
			vx, vy, vz = P.HoneySlideVelocity( vx, vy, vz )
			return P.BlocksPerTickToVelocity( vx, vy, vz ), true
		end
	end
	return velocity, false
end

hook.Add( "SetupMove", "mcgame_block_physics_setup", function( player, move )
	if not validPlayer( player ) then return end
	local state = stateFor( player )
	restoreJumpPower( player, state )
	if not P.Enabled() then
		clearTransient( player, state )
		return
	end

	local seconds = frameSeconds()
	applyPendingBounce( state, move )
	applyPendingWeb( state, move, seconds )

	local sample = P.SampleEntity( player, move )
	if not sample or not move.GetVelocity then return end
	local isGrounded = grounded( player )
	local wasGrounded = state.wasGrounded
	local velocity = move:GetVelocity()
	trackFall( state, sample, isGrounded, velocity )
	-- Source occasionally omits OnPlayerHitGround for step/VPhysics landing
	-- transitions. Entity#updateEntityMovementAfterFallOn still runs in Java,
	-- so recover the same transition from consecutive movement frames.
	if isGrounded and wasGrounded == false then
		queueSlimeBounce( player, state, sample, move )
	end
	prepareHoneyJump( player, state, sample, move, isGrounded )
	state.setupSample = sample
	state.startVelocity = vectorCopy( velocity )
	state.wasGrounded = isGrounded
end )

hook.Add( "FinishMove", "mcgame_block_physics_finish", function( player, move )
	if not validPlayer( player ) then return end
	local state = stateFor( player )
	restoreJumpPower( player, state )
	if not P.Enabled() then
		clearTransient( player, state )
		return
	end
	if not move.GetVelocity or not move.SetVelocity then return end

	local sample = P.SampleEntity( player, move ) or state.setupSample
	state.setupSample = nil
	if not sample then return end
	local seconds = frameSeconds()
	local isGrounded = grounded( player )
	applyPendingBounce( state, move )
	local velocity = move:GetVelocity()
	local previous = state.startVelocity or state.previousVelocity or velocity
	state.startVelocity = nil

	if isGrounded then
		local frictionName = P.EffectiveFrictionBlock( sample )
		local friction = P.FrictionFor( frictionName )
		velocity.x, velocity.y = P.AdaptHorizontalVelocity(
			previous.x, previous.y, velocity.x, velocity.y, friction, seconds
		)
	end

	local movementName = P.EffectiveMovementBlock( sample )
	local movementEfficiency = updateSoulSpeedState( player, state, sample, isGrounded )
	local speedFactor = P.MovementSpeedFactor( movementName, movementEfficiency )
	if speedFactor ~= C.defaultSpeedFactor then
		local factor = P.PerTickFactor( speedFactor, seconds )
		velocity.x, velocity.y = velocity.x * factor, velocity.y * factor
	end

	if isGrounded and sample.onName == "minecraft:slime_block" then
		local _, _, verticalBlocks = P.VelocityToBlocksPerTick( velocity )
		local stepScale = P.SlimeStepScale( verticalBlocks, steppingCarefully( player, move ) )
		if stepScale ~= 1 then
			stepScale = P.PerTickFactor( stepScale, seconds )
			velocity.x, velocity.y = velocity.x * stepScale, velocity.y * stepScale
		end
	end

	local sliding
	velocity, sliding = honeySlideVelocity( sample, velocity, isGrounded )
	if sliding then
		state.fallApexZ = sample.origin.z
		state.lastAirVelocityZ = velocity.z
	end

	if sample.hasCobweb then
		local horizontal, _, vertical = P.WebMultiplier( P.HasMobEffect( player, "minecraft:weaving" ) )
		state.pendingWeb = { horizontal = horizontal, vertical = vertical }
	end

	move:SetVelocity( velocity )
	state.previousVelocity = vectorCopy( velocity )
	state.wasGrounded = isGrounded
end )

local function currentFallDistance( player, state, sample )
	if state.lastFallDistance and CurTime and CurTime() <= ( state.lastLandingAt or 0 ) + 0.1 then
		return state.lastFallDistance
	end
	if not sample or not sample.origin or not state.fallApexZ then return 0 end
	return math.max( 0, ( state.fallApexZ - sample.origin.z ) / P.BlockSize() )
end

hook.Add( "GetFallDamage", "mcgame_block_physics_fall_damage", function( player )
	if not validPlayer( player ) or not P.Enabled() then return end
	local state = stateFor( player )
	local sample = P.SampleEntity( player )
	if not sample then return end
	if sample.onName == "minecraft:slime_block" then return 0 end
	if sample.onName ~= "minecraft:honey_block" then return end
	return P.FallDamage( currentFallDistance( player, state, sample ), C.honeyFallDamageModifier )
end )

hook.Add( "OnPlayerHitGround", "mcgame_block_physics_landing", function( player )
	if not validPlayer( player ) or not P.Enabled() then return end
	local state = stateFor( player )
	local sample = P.SampleEntity( player )
	if not sample or not sample.origin then return end
	state.lastFallDistance = currentFallDistance( player, state, sample )
	state.lastLandingAt = CurTime and CurTime() or 0

	queueSlimeBounce( player, state, sample )

	state.fallApexZ = nil
	state.lastAirVelocityZ = nil
end )

hook.Add( "PlayerSpawn", "mcgame_block_physics_player_spawn", function( player )
	PlayerState[player] = nil
end )

hook.Add( "PlayerDisconnected", "mcgame_block_physics_player_disconnect", function( player )
	PlayerState[player] = nil
end )
