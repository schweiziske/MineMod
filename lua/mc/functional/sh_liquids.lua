--[[----------------------------------------------------------------------------
	MC functional block: liquids.

	Liquids remain non-solid voxel blocks. Source water movement depends on BSP
	CONTENTS_WATER, so dynamic MC liquids emulate Minecraft's LivingEntity
	travelInWater/travelInLava logic in predicted SetupMove.
------------------------------------------------------------------------------]]

MC = MC or {}

local LIQUID_CONTACT_PADDING = 1
local MC_FLUID_TICKS_PER_SECOND = 20
local MC_WATER_MOVE_RELATIVE = 0.02
local MC_WATER_SLOWDOWN = 0.8
local MC_WATER_SPRINT_SLOWDOWN = 0.9
local MC_WATER_VERTICAL_INPUT = 0.04
local MC_WATER_GRAVITY = 0.08
local MC_WATER_GRAVITY_DIVISOR = 16
local MC_WATER_FALL_EPSILON = 0.003
local MC_WATER_FALL_SNAP = 0.005
local MC_WATER_FALL_SLOW = -0.003
local MC_WATER_JUMP_OUT = 0.3
local MC_SWIM_LOOK_UP_MULTIPLIER = 0.085
local MC_SWIM_LOOK_NORMAL_MULTIPLIER = 0.06
local MC_LAVA_MOVE_RELATIVE = 0.02
local MC_LAVA_SLOWDOWN = 0.5
local MC_LAVA_VERTICAL_SLOWDOWN = 0.8

local LiquidKinds = {
	water = "water",
	["minecraft:water"] = "water",
	bubble_column = "water",
	["minecraft:bubble_column"] = "water",
	lava = "lava",
	["minecraft:lava"] = "lava",
}

MC.LiquidMovePlayers = MC.LiquidMovePlayers or {}

function MC.LiquidKind( id )
	local b = MC.Blocks and MC.Blocks[id]
	if not b then return nil end
	return LiquidKinds[b.mcid] or LiquidKinds[b.name]
end

function MC.IsLiquidBlock( id )
	return MC.LiquidKind( id ) ~= nil
end

local function liquidAtPos( pos )
	if not pos or not MC.WorldToCell or not MC.GetBlock then return nil end
	local bx, by, bz = MC.WorldToCell( pos )
	local id = MC.GetBlock( bx, by, bz )
	local kind = MC.LiquidKind( id )
	if not kind then return nil end
	return { bx = bx, by = by, bz = bz, id = id, kind = kind }
end

function MC.LiquidAtPos( pos )
	return liquidAtPos( pos )
end

function MC.PlayerEyeLiquid( ply )
	if not IsValid( ply ) or not ply.EyePos then return nil end
	return liquidAtPos( ply:EyePos() )
end

local function playerMoveAABB( ply, mv, padding )
	local pos = mv and mv.GetOrigin and mv:GetOrigin() or ply:GetPos()
	local mins = ply:OBBMins()
	local maxs = ply:OBBMaxs()
	return pos.x + mins.x - padding,
		pos.y + mins.y - padding,
		pos.z + mins.z - padding,
		pos.x + maxs.x + padding,
		pos.y + maxs.y + padding,
		pos.z + maxs.z + padding
end

function MC.PlayerLiquidContact( ply, mv )
	if not IsValid( ply ) or not MC.WorldToCell or not MC.GetBlock then return nil end
	local x0, y0, z0, x1, y1, z1 = playerMoveAABB( ply, mv, LIQUID_CONTACT_PADDING )
	local minBx, minBy, minBz = MC.WorldToCell( Vector( x0, y0, z0 ) )
	local maxBx, maxBy, maxBz = MC.WorldToCell( Vector( x1, y1, z1 ) )
	local best

	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local id = MC.GetBlock( bx, by, bz )
				local kind = MC.LiquidKind( id )
				if kind then
					local contact = { bx = bx, by = by, bz = bz, id = id, kind = kind }
					if kind == "lava" then return contact end
					best = best or contact
				end
			end
		end
	end

	return best
end

local function canApplyLiquidMove( ply )
	if not IsValid( ply ) or not ply:Alive() then return false end
	if ply:InVehicle() then return false end
	local moveType = ply:GetMoveType()
	if moveType == MOVETYPE_LADDER then return false end
	return moveType == MOVETYPE_WALK or moveType == MOVETYPE_STEP
end

local function moveAngles( ply, mv )
	if mv.GetMoveAngles then return mv:GetMoveAngles() end
	return ply:EyeAngles()
end

local function mcVelocityScale()
	return ( MC.BS or 36.5 ) * MC_FLUID_TICKS_PER_SECOND
end

local function mcToSourceVelocity( blocksPerTick )
	return blocksPerTick * mcVelocityScale()
end

local function sourceToMcVelocity( sourceVelocity )
	return sourceVelocity / mcVelocityScale()
end

local function mcTickFactor()
	if engine and engine.TickInterval then
		return math.Clamp( engine.TickInterval() * MC_FLUID_TICKS_PER_SECOND, 0.05, 4 )
	end
	return 1
end

local function inputAxis( speed )
	return math.Clamp( speed / 400, -1, 1 )
end

local function horizontalMoveAngles( ply, mv )
	local ang = moveAngles( ply, mv )
	return Angle( 0, ang.y or ang.yaw or 0, 0 )
end

local function moveRelative( vel, ply, mv, speed, tickFactor )
	local forwardInput = inputAxis( mv:GetForwardSpeed() )
	local sideInput = inputAxis( mv:GetSideSpeed() )
	local lenSqr = forwardInput * forwardInput + sideInput * sideInput
	if lenSqr < 0.0000001 then return vel, false end
	if lenSqr > 1 then
		local invLen = 1 / math.sqrt( lenSqr )
		forwardInput = forwardInput * invLen
		sideInput = sideInput * invLen
	end

	local ang = horizontalMoveAngles( ply, mv )
	local wish = ang:Forward() * forwardInput + ang:Right() * sideInput
	return vel + wish * mcToSourceVelocity( speed * tickFactor ), true
end

local function liquidAbove( contact )
	if not contact or not MC.GetBlock or not MC.LiquidKind then return false end
	return MC.LiquidKind( MC.GetBlock( contact.bx, contact.by, contact.bz + 1 ) ) == contact.kind
end

local function isWaterSprinting( ply, mv, contact )
	if not contact or contact.kind ~= "water" then return false end
	if ply.IsSprinting and ply:IsSprinting() then return true end
	return mv:KeyDown( IN_SPEED ) and inputAxis( mv:GetForwardSpeed() ) > 0.01
end

local function applySwimmingLookAdjustment( ply, mv, contact, vel, tickFactor )
	if not isWaterSprinting( ply, mv, contact ) then return vel end
	local look = moveAngles( ply, mv ):Forward()
	local lookZ = look.z or 0
	if lookZ > 0 and not mv:KeyDown( IN_JUMP ) and not liquidAbove( contact ) then return vel end
	local baseMultiplier = lookZ < -0.2 and MC_SWIM_LOOK_UP_MULTIPLIER or MC_SWIM_LOOK_NORMAL_MULTIPLIER
	local multiplier = 1 - math.pow( 1 - baseMultiplier, tickFactor )
	local mcZ = sourceToMcVelocity( vel.z )
	vel.z = mcToSourceVelocity( mcZ + ( lookZ - mcZ ) * multiplier )
	return vel
end

local function getFluidFallingAdjustedVelocity( vel, gravity, isFalling, sprinting, tickFactor )
	if gravity == 0 or sprinting then return vel end
	local mcZ = sourceToMcVelocity( vel.z )
	local scaledGravity = gravity * tickFactor
	local yd
	if isFalling and math.abs( mcZ - MC_WATER_FALL_SNAP * tickFactor ) >= MC_WATER_FALL_EPSILON and math.abs( mcZ - scaledGravity / MC_WATER_GRAVITY_DIVISOR ) < MC_WATER_FALL_EPSILON then
		yd = MC_WATER_FALL_SLOW * tickFactor
	else
		yd = mcZ - scaledGravity / MC_WATER_GRAVITY_DIVISOR
	end
	vel.z = mcToSourceVelocity( yd )
	return vel
end

local function horizontalCollisionFromVelocity( ply, mv, vel )
	if not util or not util.TraceHull then return false end
	local horizontal = Vector( vel.x, vel.y, 0 )
	if horizontal:LengthSqr() < 1 then return false end
	local origin = mv:GetOrigin()
	local step = horizontal:GetNormalized() * math.min( ( MC.BS or 36.5 ) * 0.25, 12 )
	local tr = util.TraceHull( {
		start = origin,
		endpos = origin + step,
		mins = ply:OBBMins(),
		maxs = ply:OBBMaxs(),
		filter = ply,
		mask = MASK_PLAYERSOLID,
	} )
	return tr.Hit == true
end

local function freeForFluidJumpOut( ply, mv, vel )
	if not util or not util.TraceHull then return false end
	local origin = mv:GetOrigin()
	local tickInterval = engine and engine.TickInterval and engine.TickInterval() or ( 1 / MC_FLUID_TICKS_PER_SECOND )
	local up = ( MC.BS or 36.5 ) * 0.6
	local tr = util.TraceHull( {
		start = origin,
		endpos = origin + Vector( vel.x * tickInterval, vel.y * tickInterval, up ),
		mins = ply:OBBMins(),
		maxs = ply:OBBMaxs(),
		filter = ply,
		mask = MASK_PLAYERSOLID,
	} )
	return tr.Hit ~= true
end

local function jumpOutOfFluid( ply, mv, vel )
	if horizontalCollisionFromVelocity( ply, mv, vel ) and freeForFluidJumpOut( ply, mv, vel ) then
		vel.z = mcToSourceVelocity( MC_WATER_JUMP_OUT )
	end
	return vel
end

local function applyWaterVelocity( ply, mv, contact )
	local vel = mv:GetVelocity()
	local tickFactor = mcTickFactor()
	local isFalling = vel.z <= 0
	local sprinting = isWaterSprinting( ply, mv, contact )
	vel = applySwimmingLookAdjustment( ply, mv, contact, vel, tickFactor )
	vel = moveRelative( vel, ply, mv, MC_WATER_MOVE_RELATIVE, tickFactor )
	if mv:KeyDown( IN_JUMP ) then
		vel.z = vel.z + mcToSourceVelocity( MC_WATER_VERTICAL_INPUT )
	end
	if mv:KeyDown( IN_DUCK ) then
		vel.z = vel.z - mcToSourceVelocity( MC_WATER_VERTICAL_INPUT )
	end

	local slowDown = sprinting and MC_WATER_SPRINT_SLOWDOWN or MC_WATER_SLOWDOWN
	local horizontalSlowDown = math.pow( slowDown, tickFactor )
	local verticalSlowDown = math.pow( MC_WATER_SLOWDOWN, tickFactor )
	vel.x = vel.x * horizontalSlowDown
	vel.y = vel.y * horizontalSlowDown
	vel.z = vel.z * verticalSlowDown
	vel = getFluidFallingAdjustedVelocity( vel, MC_WATER_GRAVITY, isFalling, sprinting, tickFactor )
	vel = jumpOutOfFluid( ply, mv, vel )
	mv:SetVelocity( vel )
	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
end

local function applyLavaVelocity( ply, mv )
	local vel = mv:GetVelocity()
	local tickFactor = mcTickFactor()
	vel = moveRelative( vel, ply, mv, MC_LAVA_MOVE_RELATIVE, tickFactor )
	local lavaSlowDown = math.pow( MC_LAVA_SLOWDOWN, tickFactor )
	local lavaVerticalSlowDown = math.pow( MC_LAVA_VERTICAL_SLOWDOWN, tickFactor )
	vel.x = vel.x * lavaSlowDown
	vel.y = vel.y * lavaSlowDown
	vel.z = vel.z * lavaVerticalSlowDown
	vel.z = vel.z - mcToSourceVelocity( MC_WATER_GRAVITY / 4 * tickFactor )
	vel = jumpOutOfFluid( ply, mv, vel )
	mv:SetVelocity( vel )
	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
end

function MC.ApplyLiquidMove( ply, mv )
	if not canApplyLiquidMove( ply ) then
		MC.LiquidMovePlayers[ply] = nil
		return false
	end

	local contact = MC.PlayerLiquidContact( ply, mv )
	if not contact then
		MC.LiquidMovePlayers[ply] = nil
		return false
	end

	MC.LiquidMovePlayers[ply] = contact.kind
	if contact.kind == "lava" then
		applyLavaVelocity( ply, mv )
	else
		applyWaterVelocity( ply, mv, contact )
	end
	return true, contact
end

hook.Add( "SetupMove", "mc_liquid_swim", function( ply, mv )
	MC.ApplyLiquidMove( ply, mv )
end )

if CLIENT then
	local WaterColorModify = {
		["$pp_colour_addr"] = 0,
		["$pp_colour_addg"] = 0.015,
		["$pp_colour_addb"] = 0.055,
		["$pp_colour_brightness"] = -0.04,
		["$pp_colour_contrast"] = 0.86,
		["$pp_colour_colour"] = 0.72,
		["$pp_colour_mulr"] = 0,
		["$pp_colour_mulg"] = 0.08,
		["$pp_colour_mulb"] = 0.18,
	}

	local LavaColorModify = {
		["$pp_colour_addr"] = 0.08,
		["$pp_colour_addg"] = 0.025,
		["$pp_colour_addb"] = 0,
		["$pp_colour_brightness"] = -0.025,
		["$pp_colour_contrast"] = 1.08,
		["$pp_colour_colour"] = 0.62,
		["$pp_colour_mulr"] = 0.22,
		["$pp_colour_mulg"] = 0.04,
		["$pp_colour_mulb"] = 0,
	}

	local function localEyeLiquid()
		local ply = LocalPlayer()
		if not IsValid( ply ) then return nil end
		return MC.PlayerEyeLiquid( ply )
	end

	hook.Add( "RenderScreenspaceEffects", "mc_liquid_underwater", function()
		local liquid = localEyeLiquid()
		if not liquid then return end
		local lava = liquid.kind == "lava"
		DrawColorModify( lava and LavaColorModify or WaterColorModify )
		DrawMotionBlur( 0.025, lava and 0.45 or 0.32, 0.015 )
	end )

	hook.Add( "HUDPaint", "mc_liquid_underwater_overlay", function()
		local liquid = localEyeLiquid()
		if not liquid then return end
		if liquid.kind == "lava" then
			surface.SetDrawColor( 255, 92, 20, 58 )
		else
			surface.SetDrawColor( 34, 104, 190, 46 )
		end
		surface.DrawRect( 0, 0, ScrW(), ScrH() )
	end )
end
