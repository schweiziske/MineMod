-- Predicted player swimming. Movement coefficients and integration follow
-- GWater2; voxel contact, Minecraft currents and bubble columns remain local.

MC = MC or {}
MC.Liquid = MC.Liquid or {}

local sqrt = math.sqrt
local abs = math.abs
local max = math.max

local MC_TICKS_PER_SECOND = 20
local WATER_CURRENT_SCALE = 0.014
local LAVA_CURRENT_SCALE = 0.0023333333333333335
local SWIM_SOUND_INTERVAL = 1
local SWIM_SOUND_EVENT = "Player.Swim"
local WADE_SOUND_EVENT = "Player.Wade"

-- Defaults from gwater2_interactions.lua at commit d21167c.
local SwimParameters = {
	speed = 2,
	buoyancy = 0.49,
	friction = 0,
	dragPerSecond = 2,
	finishGravityScale = 0.5,
}

-- Lava needs to feel like a dense, sticky liquid rather than water with a
-- different colour. It has deliberately weak input acceleration and quickly
-- damps both player input and carried velocity.
local LavaSwimParameters = {
	speed = 0.35,
	jumpScale = 0.25,
	dragPerSecond = 4,
}

MC.LiquidMovementParameters = SwimParameters
MC.LavaLiquidMovementParameters = LavaSwimParameters
MC.LiquidMovePlayers = setmetatable( {}, { __mode = "k" } )
MC.LiquidMoveContacts = setmetatable( {}, { __mode = "k" } )
local NextSwimSoundAt = setmetatable( {}, { __mode = "k" } )
local WasTouchingWater = setmetatable( {}, { __mode = "k" } )

local GravityConVar = GetConVar and GetConVar( "sv_gravity" ) or nil

local function canApplyMove( ply )
	if not IsValid( ply ) or not ply:Alive() or ply:InVehicle() then return false end
	local moveType = ply:GetMoveType()
	return moveType == MOVETYPE_WALK or moveType == MOVETYPE_STEP
end

local function tickFactor()
	if engine and engine.TickInterval then
		return math.Clamp( engine.TickInterval() * MC_TICKS_PER_SECOND, 0.05, 4 )
	end
	return 1
end

local function velocityScale()
	return ( MC.BS or 36.5 ) * MC_TICKS_PER_SECOND
end

local function toSourceVelocity( blocksPerTick )
	return blocksPerTick * velocityScale()
end

local function toMinecraftVelocity( sourceVelocity )
	return sourceVelocity / velocityScale()
end

local function applyCurrent( velocity, contact, scale, factor )
	if not contact then return velocity end
	local flowX, flowY, flowZ = contact.flowX, contact.flowY, contact.flowZ
	if flowX == nil and MC.LiquidFlowAtCell then
		flowX, flowY, flowZ = MC.LiquidFlowAtCell( contact.bx, contact.by, contact.bz, contact.kind )
	end
	flowX, flowY, flowZ = flowX or 0, flowY or 0, flowZ or 0
	local flowLengthSqr = flowX * flowX + flowY * flowY + flowZ * flowZ
	if flowLengthSqr < 0.00001 then return velocity end

	local impulseScale = scale * factor
	local impulseX, impulseY, impulseZ = flowX * impulseScale, flowY * impulseScale, flowZ * impulseScale
	local impulseLength = sqrt( impulseX * impulseX + impulseY * impulseY + impulseZ * impulseZ )
	local mcX, mcY = toMinecraftVelocity( velocity.x ), toMinecraftVelocity( velocity.y )
	if abs( mcX ) < 0.003 and abs( mcY ) < 0.003 and impulseLength < 0.0045 then
		local multiplier = 0.0045 / impulseLength
		impulseX, impulseY, impulseZ = impulseX * multiplier, impulseY * multiplier, impulseZ * multiplier
	end
	velocity.x = velocity.x + toSourceVelocity( impulseX )
	velocity.y = velocity.y + toSourceVelocity( impulseY )
	velocity.z = velocity.z + toSourceVelocity( impulseZ )
	return velocity
end

local function liquidAbove( contact )
	if not contact or not MC.GetBlockState then return false end
	return MC.LiquidKindForState( MC.GetBlockState( contact.bx, contact.by, contact.bz + 1 ) or 0 ) == contact.kind
end

local function bubbleColumnDrag( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema or schema.name ~= "minecraft:bubble_column" then return nil end
	return MC.GetStateProperty( stateId, "drag" ) == true
end

local function applyBubbleColumn( velocity, contact, factor )
	local dragDown = contact and bubbleColumnDrag( contact.stateId )
	if dragDown == nil then return velocity end
	local aboveSurface = not liquidAbove( contact )
	local mcZ = toMinecraftVelocity( velocity.z )
	if dragDown then
		mcZ = max( aboveSurface and -0.9 or -0.3, mcZ - 0.03 * factor )
	else
		mcZ = math.min( aboveSurface and 1.8 or 0.7, mcZ + ( aboveSurface and 0.1 or 0.06 ) * factor )
	end
	velocity.z = toSourceVelocity( mcZ )
	return velocity
end

local function swimAcceleration( ply, move )
	local angles = move.GetMoveAngles and move:GetMoveAngles() or ply:EyeAngles()
	local acceleration = angles:Forward() * move:GetForwardSpeed()
		+ angles:Right() * move:GetSideSpeed()
		+ angles:Up() * ( move.GetUpSpeed and move:GetUpSpeed() or 0 )
	local length = acceleration:Length()
	if length > 0 then
		acceleration:Mul( math.min( length, ply:GetMaxSpeed() ) / length * SwimParameters.speed )
	end
	if move:KeyDown( IN_JUMP ) then
		acceleration.z = acceleration.z + ply:GetMaxSpeed()
	end
	return acceleration
end

local function lavaSwimAcceleration( ply, move )
	local angles = move.GetMoveAngles and move:GetMoveAngles() or ply:EyeAngles()
	local acceleration = angles:Forward() * move:GetForwardSpeed()
		+ angles:Right() * move:GetSideSpeed()
		+ angles:Up() * ( move.GetUpSpeed and move:GetUpSpeed() or 0 )
	local length = acceleration:Length()
	if length > 0 then
		acceleration:Mul( math.min( length, ply:GetMaxSpeed() ) / length * LavaSwimParameters.speed )
	end
	if move:KeyDown( IN_JUMP ) then
		acceleration.z = acceleration.z + ply:GetMaxSpeed() * LavaSwimParameters.jumpScale
	end
	return acceleration
end

local function updateWaterTransitionSound( ply, contact )
	if not SERVER then return end
	local inWater = contact and contact.kind == "water" or false
	local previous = WasTouchingWater[ply]
	if previous == nil then
		WasTouchingWater[ply] = inWater
		return
	end
	if previous == inWater then return end
	WasTouchingWater[ply] = inWater
	ply:EmitSound( WADE_SOUND_EVENT )
	if not inWater then NextSwimSoundAt[ply] = nil end
end

local function playJumpSwimSound( ply, move, contact )
	if not SERVER or contact.kind ~= "water" or not move:KeyDown( IN_JUMP ) then return end
	local origin = move:GetOrigin()
	local mins, maxs = ply:OBBMins(), ply:OBBMaxs()
	local waistZ = origin.z + ( mins.z + maxs.z ) * 0.5
	local waistContact = MC.Liquid.PointContact( origin.x, origin.y, waistZ )
	if not waistContact or waistContact.kind ~= "water" then return end
	local now = CurTime()
	if now < ( NextSwimSoundAt[ply] or 0 ) then return end
	NextSwimSoundAt[ply] = now + SWIM_SOUND_INTERVAL
	ply:EmitSound( SWIM_SOUND_EVENT )
end

local function applyGWaterSwim( ply, move, contact )
	local velocity = move:GetVelocity()
	local factor = tickFactor()
	local lava = contact.kind == "lava"
	local currentScale = lava and LAVA_CURRENT_SCALE or WATER_CURRENT_SCALE
	velocity = applyCurrent( velocity, contact, currentScale, factor )

	local frameTime = FrameTime()
	local acceleration = swimAcceleration( ply, move )
	if lava then acceleration = lavaSwimAcceleration( ply, move ) end
	playJumpSwimSound( ply, move, contact )
	velocity = velocity + acceleration * frameTime
	if lava then
		velocity:Mul( max( 0, 1 - frameTime * LavaSwimParameters.dragPerSecond ) )
	else
		velocity:Mul( max( 0, 1 - frameTime * SwimParameters.dragPerSecond ) )
	end

	local gravityScale = ply:GetGravity()
	if gravityScale == 0 then gravityScale = 1 end
	local gravity = ( GravityConVar and GravityConVar:GetFloat() or 600 ) * gravityScale
	velocity.z = velocity.z + frameTime * gravity * SwimParameters.buoyancy
	if SwimParameters.friction ~= 0 then velocity:Mul( 1 - SwimParameters.friction ) end

	velocity = applyBubbleColumn( velocity, contact, factor )
	move:SetVelocity( velocity )
end

function MC.ApplyLiquidMove( ply, move )
	if not canApplyMove( ply ) then
		updateWaterTransitionSound( ply, nil )
		MC.LiquidMovePlayers[ply] = nil
		MC.LiquidMoveContacts[ply] = nil
		return false
	end
	local contact = MC.PlayerLiquidContact( ply, move )
	updateWaterTransitionSound( ply, contact )
	if not contact then
		MC.LiquidMovePlayers[ply] = nil
		MC.LiquidMoveContacts[ply] = nil
		return false
	end
	MC.LiquidMovePlayers[ply] = contact.kind
	MC.LiquidMoveContacts[ply] = contact
	applyGWaterSwim( ply, move, contact )
	return true, contact
end

hook.Add( "Move", "mc_liquid_swim", function( ply, move )
	MC.ApplyLiquidMove( ply, move )
end )

hook.Add( "FinishMove", "mc_liquid_swim", function( ply, move )
	if not MC.LiquidMoveContacts[ply] then return end
	local gravityScale = ply:GetGravity()
	if gravityScale == 0 then gravityScale = 1 end
	local gravity = GravityConVar and GravityConVar:GetFloat() or 600
	local velocity = move:GetVelocity()
	velocity.z = velocity.z + FrameTime() * gravity * gravityScale * SwimParameters.finishGravityScale
	move:SetVelocity( velocity )
end )

hook.Add( "CalcMainActivity", "mc_liquid_swim", function( ply )
	if not MC.LiquidMoveContacts[ply] or ply:InVehicle() then return end
	return ACT_MP_SWIM, -1
end )

hook.Add( "GetFallDamage", "mc_liquid_swim", function( ply )
	if not MC.LiquidMoveContacts[ply] and not MC.PlayerLiquidContact( ply ) then return end
	ply:EmitSound( "Physics.WaterSplash" )
	return 0
end )
