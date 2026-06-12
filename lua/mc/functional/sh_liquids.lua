--[[----------------------------------------------------------------------------
	MC functional block: liquids.

	Liquids remain non-solid voxel blocks. Source water movement depends on BSP
	CONTENTS_WATER, so dynamic MC liquids emulate the feel in predicted
	SetupMove by applying drag, buoyancy and view-direction swim velocity.
------------------------------------------------------------------------------]]

MC = MC or {}

local LIQUID_CONTACT_PADDING = 1
local LIQUID_DRAG = 0.72
local LIQUID_ACCEL = 0.28
local LIQUID_SWIM_SPEED = 165
local LIQUID_SIDE_SPEED = 125
local LIQUID_VERTICAL_SPEED = 130
local LIQUID_IDLE_SINK_SPEED = 18
local LIQUID_MAX_SPEED = 190
local LAVA_SPEED_SCALE = 0.52

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

local function inputAxis( speed )
	return math.Clamp( speed / 400, -1, 1 )
end

local function scaledLiquidSpeeds( kind )
	if kind == "lava" then return LAVA_SPEED_SCALE, LIQUID_MAX_SPEED * LAVA_SPEED_SCALE end
	return 1, LIQUID_MAX_SPEED
end

local function clampVectorLength( vec, maxLen )
	local len = vec:Length()
	if len <= maxLen or len <= 0.001 then return vec end
	return vec * ( maxLen / len )
end

local function applyLiquidVelocity( ply, mv, contact )
	local scale, maxSpeed = scaledLiquidSpeeds( contact and contact.kind or "water" )
	local forward = moveAngles( ply, mv ):Forward()
	local right = moveAngles( ply, mv ):Right()
	local wish = Vector( 0, 0, 0 )
	local hadInput = false

	local forwardInput = inputAxis( mv:GetForwardSpeed() )
	local sideInput = inputAxis( mv:GetSideSpeed() )
	if math.abs( forwardInput ) > 0.01 then
		wish = wish + forward * ( forwardInput * LIQUID_SWIM_SPEED * scale )
		hadInput = true
	end
	if math.abs( sideInput ) > 0.01 then
		wish = wish + right * ( sideInput * LIQUID_SIDE_SPEED * scale )
		hadInput = true
	end
	if mv:KeyDown( IN_JUMP ) then
		wish.z = wish.z + LIQUID_VERTICAL_SPEED * scale
		hadInput = true
	end
	if mv:KeyDown( IN_DUCK ) then
		wish.z = wish.z - LIQUID_VERTICAL_SPEED * scale
		hadInput = true
	end
	if not hadInput then
		wish.z = -LIQUID_IDLE_SINK_SPEED * scale
	end

	wish = clampVectorLength( wish, maxSpeed )
	local vel = mv:GetVelocity() * LIQUID_DRAG + wish * LIQUID_ACCEL
	vel = clampVectorLength( vel, maxSpeed )
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
	applyLiquidVelocity( ply, mv, contact )
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
