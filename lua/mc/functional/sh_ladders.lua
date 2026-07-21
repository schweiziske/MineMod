--[[----------------------------------------------------------------------------
	MC functional block: ladders.

	Ladders stay voxel blocks for rendering/selection. Normal chunk collision is
	disabled; touching one uses Source ladder movetype plus MoveData velocity
	because dynamic voxels cannot provide BSP CONTENTS_LADDER.
------------------------------------------------------------------------------]]

MC = MC or {}

-- CGameMovement defaults from Source SDK 2013.
local LADDER_DISTANCE = 2
local MAX_CLIMB_SPEED = 200
local LADDER_JUMP_OFF_SPEED = 270
MC.LadderMoveTypePlayers = setmetatable( MC.LadderMoveTypePlayers or {}, { __mode = "k" } )

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

local function playerMoveAABB( ply, mv )
	local pos = mv:GetOrigin()
	local mins = ply:OBBMins()
	local maxs = ply:OBBMaxs()
	return pos.x + mins.x,
		pos.y + mins.y,
		pos.z + mins.z,
		pos.x + maxs.x,
		pos.y + maxs.y,
		pos.z + maxs.z
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

local function sweptAABBHitFraction( ax0, ay0, az0, ax1, ay1, az1, offset, bx0, by0, bz0, bx1, by1, bz1 )
	local function axisTimes( amin, amax, delta, bmin, bmax )
		if math.abs( delta ) <= 0.000001 then
			if amax < bmin or amin > bmax then return nil end
			return -math.huge, math.huge
		end

		if delta > 0 then
			return ( bmin - amax ) / delta, ( bmax - amin ) / delta
		end
		return ( bmax - amin ) / delta, ( bmin - amax ) / delta
	end

	local xEnter, xExit = axisTimes( ax0, ax1, offset.x, bx0, bx1 )
	if not xEnter then return nil end
	local yEnter, yExit = axisTimes( ay0, ay1, offset.y, by0, by1 )
	if not yEnter then return nil end
	local zEnter, zExit = axisTimes( az0, az1, offset.z, bz0, bz1 )
	if not zEnter then return nil end

	local enter = math.max( xEnter, yEnter, zEnter )
	local leave = math.min( xExit, yExit, zExit )
	if enter > leave or leave < 0 or enter > 1 then return nil end
	return math.max( 0, enter )
end

local function ladderContactAtCell( bx, by, bz, x0, y0, z0, x1, y1, z1, offset, wishdir )
	local id = MC.GetBlock( bx, by, bz )
	if not MC.IsLadderBlock( id ) then return nil end

	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	local boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
	local best
	for _, box in ipairs( boxes or { { 0, 0, 0, 1, 1, 1 } } ) do
		local lx0, ly0, lz0, lx1, ly1, lz1 = blockBoxWorldBounds( bx, by, bz, box )
		local normal = ladderNormalFromBox( box )
		local approach = wishdir:Dot( normal )
		local fraction = approach < -0.0001 and sweptAABBHitFraction(
			x0, y0, z0, x1, y1, z1, offset,
			lx0, ly0, lz0, lx1, ly1, lz1
		) or nil
		if fraction and ( not best or fraction < best.fraction or fraction == best.fraction and approach < best.approach ) then
			best = {
				bx = bx,
				by = by,
				bz = bz,
				id = id,
				orient = orient,
				normal = normal,
				fraction = fraction,
				approach = approach,
			}
		end
	end

	return best
end

function MC.PlayerLadderContact( ply, mv, wishdir )
	if not IsValid( ply ) or not mv or not MC.WorldToCell or not MC.GetBlock then return nil end
	if not wishdir then return nil end
	local offset = wishdir * LADDER_DISTANCE
	local x0, y0, z0, x1, y1, z1 = playerMoveAABB( ply, mv )
	local sweepX0, sweepY0, sweepZ0 = x0 + math.min( 0, offset.x ), y0 + math.min( 0, offset.y ), z0 + math.min( 0, offset.z )
	local sweepX1, sweepY1, sweepZ1 = x1 + math.max( 0, offset.x ), y1 + math.max( 0, offset.y ), z1 + math.max( 0, offset.z )
	local minBx, minBy, minBz = MC.WorldToCell( Vector( sweepX0, sweepY0, sweepZ0 ) )
	local maxBx, maxBy, maxBz = MC.WorldToCell( Vector( sweepX1, sweepY1, sweepZ1 ) )

	local best
	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local contact = ladderContactAtCell( bx, by, bz, x0, y0, z0, x1, y1, z1, offset, wishdir )
				if contact and ( not best or contact.fraction < best.fraction or contact.fraction == best.fraction and contact.approach < best.approach ) then
					best = contact
				end
			end
		end
	end

	return best
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
	if ply.SetMoveCollide and MOVECOLLIDE_DEFAULT then
		ply:SetMoveCollide( MOVECOLLIDE_DEFAULT )
	end
	return true
end

local function wantsDetachFromLadder( mv )
	return mv:KeyDown( IN_JUMP )
end

local function moveAngles( ply, mv )
	if mv.GetMoveAngles then return mv:GetMoveAngles() end
	return ply:EyeAngles()
end

local function sourceLadderWishDirection( ply, mv )
	local state = MC.LadderMoveTypePlayers[ply]
	if istable( state ) and state.normal then
		return -state.normal
	end

	local forwardMove = mv:GetForwardSpeed()
	local sideMove = mv:GetSideSpeed()
	if forwardMove == 0 and sideMove == 0 then return nil end

	local angles = moveAngles( ply, mv )
	local wishdir = angles:Forward() * forwardMove + angles:Right() * sideMove
	local length = wishdir:Length()
	if length <= 0.0001 then return nil end
	return wishdir / length
end

local function sourceLadderInputSpeeds( mv )
	local forwardSpeed, rightSpeed = 0, 0
	if mv:KeyDown( IN_BACK ) then forwardSpeed = forwardSpeed - MAX_CLIMB_SPEED end
	if mv:KeyDown( IN_FORWARD ) then forwardSpeed = forwardSpeed + MAX_CLIMB_SPEED end
	if mv:KeyDown( IN_MOVELEFT ) then rightSpeed = rightSpeed - MAX_CLIMB_SPEED end
	if mv:KeyDown( IN_MOVERIGHT ) then rightSpeed = rightSpeed + MAX_CLIMB_SPEED end
	return forwardSpeed, rightSpeed
end

local function sourceLadderOnFloor( ply, mv )
	if ply.IsOnGround and ply:IsOnGround() then return true end
	if not util or not util.PointContents or not CONTENTS_SOLID then return false end
	local origin = mv:GetOrigin()
	local floor = Vector( origin.x, origin.y, origin.z + ply:OBBMins().z - 1 )
	return util.PointContents( floor ) == CONTENTS_SOLID
end

local function detachLadderVelocity( ply, mv, contact )
	mv:SetVelocity( contact.normal * LADDER_JUMP_OFF_SPEED )
end

local function sourceLadderVelocity( ply, mv, contact )
	local forwardSpeed, rightSpeed = sourceLadderInputSpeeds( mv )
	if forwardSpeed == 0 and rightSpeed == 0 then return Vector( 0, 0, 0 ) end

	local angles = moveAngles( ply, mv )
	local velocity = angles:Forward() * forwardSpeed + angles:Right() * rightSpeed
	local normal = contact.normal
	local perpendicular = Vector( 0, 0, 1 ):Cross( normal )
	perpendicular:Normalize()

	local normalSpeed = velocity:Dot( normal )
	local intoLadder = normal * normalSpeed
	local lateral = velocity - intoLadder
	local vertical = normal:Cross( perpendicular )
	velocity = lateral + vertical * -normalSpeed

	if sourceLadderOnFloor( ply, mv ) and normalSpeed > 0 then
		velocity = velocity + normal * MAX_CLIMB_SPEED
	end
	return velocity
end

local function applyLadderVelocity( ply, mv, contact )
	mv:SetVelocity( sourceLadderVelocity( ply, mv, contact ) )
	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
	if mv.SetUpSpeed then mv:SetUpSpeed( 0 ) end
end

function MC.ApplyLadderMove( ply, mv )
	if not canApplyLadderMove( ply ) then
		return MC.ClearLadderMoveType( ply )
	end

	local wishdir = sourceLadderWishDirection( ply, mv )
	if not wishdir then
		return MC.ClearLadderMoveType( ply )
	end

	local contact = MC.PlayerLadderContact( ply, mv, wishdir )
	if not contact then
		return MC.ClearLadderMoveType( ply )
	end

	MC.LadderMoveTypePlayers[ply] = {
		normal = Vector( contact.normal.x, contact.normal.y, contact.normal.z ),
	}
	if ply:GetMoveType() ~= MOVETYPE_LADDER then
		ply:SetMoveType( MOVETYPE_LADDER )
	end
	if ply.SetMoveCollide and MOVECOLLIDE_DEFAULT then
		ply:SetMoveCollide( MOVECOLLIDE_DEFAULT )
	end
	ply:SetGravity( 0 )

	if wantsDetachFromLadder( mv ) then
		detachLadderVelocity( ply, mv, contact )
		MC.ClearLadderMoveType( ply )
		return false, contact
	end

	applyLadderVelocity( ply, mv, contact )
	return true, contact
end

hook.Add( "SetupMove", "mc_ladder_climb", function( ply, mv )
	MC.ApplyLadderMove( ply, mv )
end )
