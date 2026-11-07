-- Predicted voxel swimming with Source-style wish speed, drag and acceleration.
-- Algorithm reference: Valve Source SDK CGameMovement::WaterMove and
-- CheckJumpButton. This Lua implementation owns voxel contact and hull motion.

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

local SwimParameters = {
	speedScale = 0.8,
	idleSinkSpeed = 60,
	jumpSpeed = 100,
}

-- Lava needs to feel like a dense, sticky liquid rather than water with a
-- different colour. It has deliberately weak input acceleration and quickly
-- damps both player input and carried velocity.
local LavaSwimParameters = {
	speedScale = 0.35,
	idleSinkSpeed = 30,
	jumpSpeed = 80,
	frictionScale = 2,
}

MC.LiquidMovementParameters = SwimParameters
MC.LavaLiquidMovementParameters = LavaSwimParameters
MC.LiquidMovePlayers = setmetatable( {}, { __mode = "k" } )
MC.LiquidMoveContacts = setmetatable( {}, { __mode = "k" } )
local NextSwimSoundAt = setmetatable( {}, { __mode = "k" } )
local WasTouchingWater = setmetatable( {}, { __mode = "k" } )

local FrictionConVar = GetConVar( "sv_friction" )
local AccelerateConVar = GetConVar( "sv_accelerate" )

local function canApplyMove( ply )
	if not IsValid( ply ) or not ply:Alive() or ply:InVehicle() or ply:IsFrozen() then return false end
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
	return MC.API.Coords.BlockSize() * MC_TICKS_PER_SECOND
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

local function waistSubmerged( ply, move, contact )
	local origin, err = MC.API.Coords.MoveOriginWorldPos( ply, move:GetOrigin() )
	if not origin then
		MC.Fault( "liquid_waist_world_position", "liquid waist query: %s", tostring( err ) )
		return false
	end
	local mins, maxs
	if ply:Crouching() then mins, maxs = ply:GetHullDuck() else mins, maxs = ply:GetHull() end
	local waist = MC.Liquid.PointContact( origin.x + ( mins.x + maxs.x ) * 0.5,
		origin.y + ( mins.y + maxs.y ) * 0.5, origin.z + ( mins.z + maxs.z ) * 0.5 )
	return waist ~= nil and waist.kind == contact.kind
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
	local now = CurTime()
	if now < ( NextSwimSoundAt[ply] or 0 ) then return end
	NextSwimSoundAt[ply] = now + SWIM_SOUND_INTERVAL
	ply:EmitSound( SWIM_SOUND_EVENT )
end

local function applySourceSwim( ply, move, contact )
	local velocity = move:GetVelocity()
	local factor = tickFactor()
	local lava = contact.kind == "lava"
	local currentScale = lava and LAVA_CURRENT_SCALE or WATER_CURRENT_SCALE
	if not contact.swimming then
		applyCurrent( velocity, contact, currentScale, factor )
		move:SetVelocity( velocity )
		return
	end
	local parameters = lava and LavaSwimParameters or SwimParameters
	local seconds = FrameTime()
	local angles = move:GetMoveAngles()
	local forward, right = angles:Forward(), angles:Right()
	local forwardSpeed, sideSpeed, upSpeed = move:GetForwardSpeed(), move:GetSideSpeed(), move:GetUpSpeed()
	local clientSpeed = move:GetMaxClientSpeed()
	local speedLimit = move:GetMaxSpeed()
	if clientSpeed > 0 then speedLimit = math.min( speedLimit, clientSpeed ) else clientSpeed = speedLimit end
	local wx = forward.x * forwardSpeed + right.x * sideSpeed
	local wy = forward.y * forwardSpeed + right.y * sideSpeed
	local wz = forward.z * forwardSpeed + right.z * sideSpeed
	if move:KeyDown( IN_JUMP ) then
		wz = wz + clientSpeed
		velocity.z = parameters.jumpSpeed
		playJumpSwimSound( ply, move, contact )
	elseif forwardSpeed == 0 and sideSpeed == 0 and upSpeed == 0 then
		wz = wz - parameters.idleSinkSpeed
	else
		wz = wz + upSpeed + math.min( max( forwardSpeed * forward.z * 2, 0 ), clientSpeed )
	end
	local wishLength = sqrt( wx * wx + wy * wy + wz * wz )
	local wishSpeed = math.min( wishLength, speedLimit ) * parameters.speedScale
	local friction = ply:GetFriction()
	local speed = velocity:Length()
	local retained = speed * max( 0, 1 - seconds * FrictionConVar:GetFloat() * friction * ( lava and parameters.frictionScale or 1 ) )
	if retained < 0.1 then retained = 0 end
	if speed > 0 then velocity:Mul( retained / speed ) end
	if wishSpeed >= 0.1 and wishSpeed > retained then
		local gain = math.min( wishSpeed - retained, AccelerateConVar:GetFloat() * wishSpeed * seconds * friction ) / wishLength
		velocity.x, velocity.y, velocity.z = velocity.x + wx * gain, velocity.y + wy * gain, velocity.z + wz * gain
	end
	applyCurrent( velocity, contact, currentScale, factor )
	applyBubbleColumn( velocity, contact, factor )
	MC.Liquid.MoveSwimming( ply, move, velocity, seconds )
end

function MC.ApplyLiquidMove( ply, move )
	if not canApplyMove( ply ) or ply:WaterLevel() >= 2 then
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
	contact.swimming = waistSubmerged( ply, move, contact )
	applySourceSwim( ply, move, contact )
	return true, contact
end

hook.Add( "Move", "mc_liquid_swim", function( ply, move )
	local applied, contact = MC.ApplyLiquidMove( ply, move )
	if applied and contact.swimming then return true end
end )

-- Remove the old gravity compensation when this file is hot reloaded.
hook.Remove( "FinishMove", "mc_liquid_swim" )

hook.Add( "CalcMainActivity", "mc_liquid_swim", function( ply )
	local contact = MC.LiquidMoveContacts[ply]
	if not contact or not contact.swimming or ply:InVehicle() then return end
	return ACT_MP_SWIM, -1
end )

hook.Add( "GetFallDamage", "mc_liquid_swim", function( ply )
	if not MC.LiquidMoveContacts[ply] and not MC.PlayerLiquidContact( ply ) then return end
	ply:EmitSound( "Physics.WaterSplash" )
	return 0
end )
