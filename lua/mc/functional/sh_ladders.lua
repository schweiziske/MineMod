--[[----------------------------------------------------------------------------
	MC functional block: ladders.

	Ladders stay voxel blocks for rendering/selection. Normal chunk collision is
	disabled; touching one uses Source ladder movetype plus MoveData velocity
	because dynamic voxels cannot provide BSP CONTENTS_LADDER.
------------------------------------------------------------------------------]]

MC = MC or {}

local LADDER_CONTACT_PADDING = 3
local LADDER_CLIMB_SPEED = 115
local LADDER_DESCEND_SPEED = 95
local LADDER_IDLE_SLIDE_SPEED = 20
local LADDER_SIDE_SPEED = 115 / 2
local LADDER_DETACH_PUSH = -135
local LADDER_DETACH_UP = 85
MC.LadderMoveTypePlayers = MC.LadderMoveTypePlayers or {}

function MC.IsLadderBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.mcid == "minecraft:ladder" or false
end

local function blockBoxWorldBounds( bx, by, bz, box )
	local bs = MC.BS or 36.5
	local base = MC.CellWorldMin( bx, by, bz )
	return base.x + box[1] * bs,
		base.y + box[2] * bs,
		base.z + box[3] * bs,
		base.x + box[4] * bs,
		base.y + box[5] * bs,
		base.z + box[6] * bs
end

local function boxesOverlap( ax0, ay0, az0, ax1, ay1, az1, bx0, by0, bz0, bx1, by1, bz1 )
	return ax0 <= bx1 and ax1 >= bx0
		and ay0 <= by1 and ay1 >= by0
		and az0 <= bz1 and az1 >= bz0
end

local function playerMoveAABB( ply, mv, padding )
	local pos = mv:GetOrigin()
	local mins = ply:OBBMins()
	local maxs = ply:OBBMaxs()
	return pos.x + mins.x - padding,
		pos.y + mins.y - padding,
		pos.z + mins.z - padding,
		pos.x + maxs.x + padding,
		pos.y + maxs.y + padding,
		pos.z + maxs.z + padding
end

local function ladderNormalFromBox( box )
	local sx = math.abs( box[4] - box[1] )
	local sy = math.abs( box[5] - box[2] )
	if sx < sy then
		local cx = ( box[1] + box[4] ) * 0.5
		return Vector( cx >= 0.5 and 1 or -1, 0, 0 )
	end

	local cy = ( box[2] + box[5] ) * 0.5
	return Vector( 0, cy >= 0.5 and 1 or -1, 0 )
end

local function ladderContactAtCell( bx, by, bz, x0, y0, z0, x1, y1, z1 )
	local id = MC.GetBlock( bx, by, bz )
	if not MC.IsLadderBlock( id ) then return nil end

	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	local boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
	for _, box in ipairs( boxes or { { 0, 0, 0, 1, 1, 1 } } ) do
		local lx0, ly0, lz0, lx1, ly1, lz1 = blockBoxWorldBounds( bx, by, bz, box )
		if boxesOverlap( x0, y0, z0, x1, y1, z1, lx0, ly0, lz0, lx1, ly1, lz1 ) then
			return {
				bx = bx,
				by = by,
				bz = bz,
				id = id,
				orient = orient,
				normal = ladderNormalFromBox( box ),
			}
		end
	end

	return nil
end

function MC.PlayerLadderContact( ply, mv )
	if not IsValid( ply ) or not mv or not MC.WorldToCell or not MC.GetBlock then return nil end
	local padding = LADDER_CONTACT_PADDING
	local x0, y0, z0, x1, y1, z1 = playerMoveAABB( ply, mv, padding )
	local minBx, minBy, minBz = MC.WorldToCell( Vector( x0, y0, z0 ) )
	local maxBx, maxBy, maxBz = MC.WorldToCell( Vector( x1, y1, z1 ) )

	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local contact = ladderContactAtCell( bx, by, bz, x0, y0, z0, x1, y1, z1 )
				if contact then return contact end
			end
		end
	end

	return nil
end

local function canApplyLadderMove( ply )
	if not IsValid( ply ) or not ply:Alive() then return false end
	if ply:InVehicle() then return false end
	local moveType = ply:GetMoveType()
	return moveType == MOVETYPE_WALK or moveType == MOVETYPE_STEP or moveType == MOVETYPE_LADDER
end

function MC.ClearLadderMoveType( ply )
	if not IsValid( ply ) or not MC.LadderMoveTypePlayers[ply] then return false end
	MC.LadderMoveTypePlayers[ply] = nil
	if ply:GetMoveType() == MOVETYPE_LADDER then
		ply:SetMoveType( MOVETYPE_WALK )
	end
	return true
end

local function wantsDetachFromLadder( mv )
	return mv:KeyDown( IN_JUMP )
end

local function horizontalUnit( vec )
	local x, y = vec.x, vec.y
	local len = math.sqrt( x * x + y * y )
	if len <= 0.001 then return Vector( 0, 0, 0 ) end
	return Vector( x / len, y / len, 0 )
end

local function moveAngles( ply, mv )
	if mv.GetMoveAngles then return mv:GetMoveAngles() end
	return ply:EyeAngles()
end

local function ladderSideDirection( ply, mv, contact )
	local normal = contact and contact.normal or Vector( 0, 1, 0 )
	local tangent = horizontalUnit( Vector( -normal.y, normal.x, 0 ) )
	local right = horizontalUnit( moveAngles( ply, mv ):Right() )
	if right:Dot( tangent ) < 0 then tangent = -tangent end
	return tangent
end

local function sourceLadderVerticalSpeed( ply, mv )
	if mv:KeyDown( IN_DUCK ) then return -LADDER_DESCEND_SPEED end
	local input = 0
	if mv:GetForwardSpeed() > 10 then
		input = 1
	elseif mv:GetForwardSpeed() < -10 then
		input = -1
	end

	local z = moveAngles( ply, mv ):Forward().z
	local speed = input * z * LADDER_CLIMB_SPEED
	if math.abs( speed ) < 1 then return -LADDER_IDLE_SLIDE_SPEED end
	return math.Clamp( speed, -LADDER_DESCEND_SPEED, LADDER_CLIMB_SPEED )
end

local function detachLadderVelocity( ply, mv, contact )
	local normal = horizontalUnit( contact and contact.normal or Vector( 0, 0, 0 ) )
	if normal.x == 0 and normal.y == 0 then
		normal = horizontalUnit( moveAngles( ply, mv ):Forward() )
	end

	local vel = mv:GetVelocity()
	vel.x = normal.x * LADDER_DETACH_PUSH
	vel.y = normal.y * LADDER_DETACH_PUSH
	vel.z = math.max( vel.z, LADDER_DETACH_UP )
	mv:SetVelocity( vel )
	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
end

local function applyLadderVelocity( ply, mv, contact )
	local vel = mv:GetVelocity()
	local side = math.Clamp( mv:GetSideSpeed(), -LADDER_SIDE_SPEED, LADDER_SIDE_SPEED )
	local sideDir = ladderSideDirection( ply, mv, contact )
	vel.x = sideDir.x * side
	vel.y = sideDir.y * side
	vel.z = sourceLadderVerticalSpeed( ply, mv )
	mv:SetVelocity( vel )
	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
end

function MC.ApplyLadderMove( ply, mv )
	if not canApplyLadderMove( ply ) then
		return MC.ClearLadderMoveType( ply )
	end

	local contact = MC.PlayerLadderContact( ply, mv )
	if not contact then
		return MC.ClearLadderMoveType( ply )
	end
	if wantsDetachFromLadder( mv ) then
		detachLadderVelocity( ply, mv, contact )
		MC.ClearLadderMoveType( ply )
		return false, contact
	end

	MC.LadderMoveTypePlayers[ply] = true
	if ply:GetMoveType() ~= MOVETYPE_LADDER then
		ply:SetMoveType( MOVETYPE_LADDER )
	end
	applyLadderVelocity( ply, mv, contact )
	return true, contact
end

hook.Add( "SetupMove", "mc_ladder_climb", function( ply, mv )
	MC.ApplyLadderMove( ply, mv )
end )
