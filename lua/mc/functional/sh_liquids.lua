--[[----------------------------------------------------------------------------
	MC functional block: liquids.

	Liquids remain non-solid voxel blocks. Source water movement depends on BSP
	CONTENTS_WATER, so dynamic MC liquids emulate Minecraft's LivingEntity
	travelInWater/travelInLava logic in predicted SetupMove.
------------------------------------------------------------------------------]]

MC = MC or {}

local LIQUID_CONTACT_HORIZONTAL_INSET = 2
local LIQUID_CONTACT_VERTICAL_PADDING = 1
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
local MC_WATER_GROUND_INPUT_SCALE = 0.45
local MC_WATER_CURRENT_SCALE = 0.014
local MC_SWIM_LOOK_UP_MULTIPLIER = 0.085
local MC_SWIM_LOOK_NORMAL_MULTIPLIER = 0.06
local MC_LAVA_MOVE_RELATIVE = 0.02
local MC_LAVA_SLOWDOWN = 0.5
local MC_LAVA_VERTICAL_SLOWDOWN = 0.8
local MC_LAVA_GROUND_INPUT_SCALE = 0.25
local MC_LAVA_CURRENT_SCALE = 0.0023333333333333335

local LiquidKinds = {
	water = "water",
	["minecraft:water"] = "water",
	bubble_column = "water",
	["minecraft:bubble_column"] = "water",
	lava = "lava",
	["minecraft:lava"] = "lava",
}

MC.LiquidMovePlayers = MC.LiquidMovePlayers or {}

-- LiquidBlock stores the legacy block LEVEL (0..15), while Minecraft renders
-- and tests contact against the derived FluidState amount:
--   level 0      -> source amount 8
--   level 1..7   -> flowing amount 8 - level
--   level 8..15  -> falling amount 8
-- FlowingFluid.getOwnHeight then returns amount / 9. Keep the decoded result
-- indexed by StateId so mesh rebuilds do not repeatedly normalize property
-- names or allocate formatted block-state strings.
local LiquidKindByState = {}
local LiquidHeightByState = {}
local LiquidLevelByState = {}
local LiquidFallingByState = {}
local WaterloggedByState = {}

local function statePropertyValue( schema, stateId, propertyName )
	local property = schema and schema.propertyByName and schema.propertyByName[propertyName] or nil
	if not property then return nil end
	local ordinal = stateId - schema.firstStateId
	local valueIndex = math.floor( ordinal / property.stride ) % property.count + 1
	return property.values[valueIndex]
end

local function decodeLiquidState( stateId )
	if type( stateId ) ~= "number" then stateId = tonumber( stateId ) or 0 end
	local cachedKind = LiquidKindByState[stateId]
	if cachedKind ~= nil then
		return cachedKind or nil,
			LiquidHeightByState[stateId] or 0,
			LiquidLevelByState[stateId],
			LiquidFallingByState[stateId] == true,
			WaterloggedByState[stateId] == true
	end
	if MC.BlockStateRegistryFrozen ~= true then return nil, 0, nil, false, false end

	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local kind = id and MC.LiquidKind( id ) or nil
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local waterlogged = not kind and statePropertyValue( schema, stateId, "waterlogged" ) == true
	if waterlogged then kind = "water" end
	if not kind then
		LiquidKindByState[stateId] = false
		LiquidHeightByState[stateId] = 0
		LiquidFallingByState[stateId] = false
		WaterloggedByState[stateId] = false
		return nil, 0, nil, false, false
	end

	local rawLevel = statePropertyValue( schema, stateId, "level" )
	local level = math.Clamp( math.floor( tonumber( rawLevel ) or 0 ), 0, 15 )
	local falling = not waterlogged and level >= 8
	local amount = falling and 8 or 8 - level
	local height = amount / 9
	LiquidKindByState[stateId] = kind
	LiquidHeightByState[stateId] = height
	LiquidLevelByState[stateId] = level
	LiquidFallingByState[stateId] = falling
	WaterloggedByState[stateId] = waterlogged
	return kind, height, level, falling, waterlogged
end

function MC.LiquidKind( id )
	local b = MC.Blocks and MC.Blocks[id]
	if not b then return nil end
	return LiquidKinds[b.mcid] or LiquidKinds[b.name]
end

function MC.IsLiquidBlock( id )
	return MC.LiquidKind( id ) ~= nil
end

function MC.LiquidStateMetrics( stateId )
	return decodeLiquidState( stateId )
end

function MC.LiquidKindForState( stateId )
	local kind = decodeLiquidState( stateId )
	return kind
end

function MC.LiquidOwnHeightForState( stateId )
	local _, height = decodeLiquidState( stateId )
	return height
end

function MC.IsWaterloggedState( stateId )
	local _, _, _, _, waterlogged = decodeLiquidState( stateId )
	return waterlogged == true
end

function MC.LiquidHeightAtCell( bx, by, bz, requiredKind )
	if not MC.GetBlockState then return 0 end
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, ownHeight = decodeLiquidState( stateId )
	if not kind or requiredKind and kind ~= requiredKind then return 0 end
	local aboveState = MC.GetBlockState( bx, by, bz + 1 ) or 0
	local aboveKind = decodeLiquidState( aboveState )
	return aboveKind == kind and 1 or ownHeight
end

local function stateBlocksFluidFlow( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return false end
	if MC.BlockHasCollisionForState then return MC.BlockHasCollisionForState( stateId, bx, by, bz ) == true end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	return id ~= 0 and MC.BlockHasCollision and MC.BlockHasCollision( id ) == true or false
end

local function flowDistanceTo( bx, by, bz, kind, ownHeight, dx, dy )
	local nx, ny = bx + dx, by + dy
	local neighbourState = MC.GetBlockState( nx, ny, bz ) or 0
	local neighbourKind, neighbourHeight = decodeLiquidState( neighbourState )
	if neighbourKind == kind then return ownHeight - neighbourHeight end
	if stateBlocksFluidFlow( neighbourState, nx, ny, bz ) then return 0 end
	local belowState = MC.GetBlockState( nx, ny, bz - 1 ) or 0
	local belowKind, belowHeight = decodeLiquidState( belowState )
	if belowKind ~= kind or belowHeight <= 0 then return 0 end
	return ownHeight - ( belowHeight - 8 / 9 )
end

-- FlowingFluid.getFlow expressed in project X/Y/Z axes. The horizontal result
-- drives the flowing top UV and can also be reused by entity current handling.
function MC.LiquidFlowAtCell( bx, by, bz, requiredKind )
	if not MC.GetBlockState then return 0, 0, 0 end
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, ownHeight, _, falling = decodeLiquidState( stateId )
	if not kind or requiredKind and kind ~= requiredKind then return 0, 0, 0 end

	local flowX = flowDistanceTo( bx, by, bz, kind, ownHeight, 1, 0 )
		- flowDistanceTo( bx, by, bz, kind, ownHeight, -1, 0 )
	local flowY = flowDistanceTo( bx, by, bz, kind, ownHeight, 0, 1 )
		- flowDistanceTo( bx, by, bz, kind, ownHeight, 0, -1 )
	local length = math.sqrt( flowX * flowX + flowY * flowY )
	if length > 0.000001 then
		flowX, flowY = flowX / length, flowY / length
	else
		flowX, flowY = 0, 0
	end

	local flowZ = 0
	if falling then
		local blocked = stateBlocksFluidFlow( MC.GetBlockState( bx + 1, by, bz ) or 0, bx + 1, by, bz )
			or stateBlocksFluidFlow( MC.GetBlockState( bx - 1, by, bz ) or 0, bx - 1, by, bz )
			or stateBlocksFluidFlow( MC.GetBlockState( bx, by + 1, bz ) or 0, bx, by + 1, bz )
			or stateBlocksFluidFlow( MC.GetBlockState( bx, by - 1, bz ) or 0, bx, by - 1, bz )
			or stateBlocksFluidFlow( MC.GetBlockState( bx + 1, by, bz + 1 ) or 0, bx + 1, by, bz + 1 )
			or stateBlocksFluidFlow( MC.GetBlockState( bx - 1, by, bz + 1 ) or 0, bx - 1, by, bz + 1 )
			or stateBlocksFluidFlow( MC.GetBlockState( bx, by + 1, bz + 1 ) or 0, bx, by + 1, bz + 1 )
			or stateBlocksFluidFlow( MC.GetBlockState( bx, by - 1, bz + 1 ) or 0, bx, by - 1, bz + 1 )
		if blocked then
			flowZ = -6
			local length3 = math.sqrt( flowX * flowX + flowY * flowY + flowZ * flowZ )
			flowX, flowY, flowZ = flowX / length3, flowY / length3, flowZ / length3
		end
	end
	return flowX, flowY, flowZ
end

local function liquidAtPos( pos )
	if not pos or not MC.WorldToCell or not MC.GetBlockState then return nil end
	local bx, by, bz = MC.WorldToCell( pos )
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, _, level, falling = decodeLiquidState( stateId )
	if not kind then return nil end
	local height = MC.LiquidHeightAtCell( bx, by, bz, kind )
	local surfaceZ = ( bz + height ) * ( MC.BS or 36.5 )
	if pos.z >= surfaceZ then return nil end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	return {
		bx = bx, by = by, bz = bz,
		id = id, stateId = stateId, kind = kind,
		height = height, surfaceZ = surfaceZ,
		level = level, falling = falling,
	}
end

function MC.LiquidAtPos( pos )
	return liquidAtPos( pos )
end

function MC.PlayerEyeLiquid( ply )
	if not IsValid( ply ) or not ply.EyePos then return nil end
	return liquidAtPos( ply:EyePos() )
end

local function playerMoveAABB( ply, mv, horizontalInset, verticalPadding )
	local pos = mv and mv.GetOrigin and mv:GetOrigin() or ply:GetPos()
	local mins = ply:OBBMins()
	local maxs = ply:OBBMaxs()
	local maxInset = math.max( 0, math.min( ( maxs.x - mins.x ) * 0.45, ( maxs.y - mins.y ) * 0.45 ) )
	horizontalInset = math.Clamp( tonumber( horizontalInset ) or 0, 0, maxInset )
	verticalPadding = math.max( 0, tonumber( verticalPadding ) or 0 )
	return pos.x + mins.x + horizontalInset,
		pos.y + mins.y + horizontalInset,
		pos.z + mins.z - verticalPadding,
		pos.x + maxs.x - horizontalInset,
		pos.y + maxs.y - horizontalInset,
		pos.z + maxs.z + verticalPadding
end

function MC.PlayerLiquidContact( ply, mv )
	if not IsValid( ply ) or not MC.WorldToCell or not MC.GetBlockState then return nil end
	local x0, y0, z0, x1, y1, z1 = playerMoveAABB( ply, mv, LIQUID_CONTACT_HORIZONTAL_INSET, LIQUID_CONTACT_VERTICAL_PADDING )
	local minBx, minBy, minBz = MC.WorldToCell( Vector( x0, y0, z0 ) )
	local maxBx, maxBy, maxBz = MC.WorldToCell( Vector( x1, y1, z1 ) )
	local best
	local blockSize = MC.BS or 36.5

	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				local kind, _, level, falling = decodeLiquidState( stateId )
				if kind then
					local height = MC.LiquidHeightAtCell( bx, by, bz, kind )
					local cellBottom = bz * blockSize
					local surfaceZ = cellBottom + height * blockSize
					if z1 > cellBottom and z0 < surfaceZ then
						local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
						local contact = {
							bx = bx, by = by, bz = bz,
							id = id, stateId = stateId, kind = kind,
							height = height, surfaceZ = surfaceZ,
							depth = math.max( 0, ( surfaceZ - z0 ) / blockSize ),
							level = level, falling = falling,
						}
						if kind == "lava" then return contact end
						best = best or contact
					end
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

local function consumeLiquidGroundInput( ply, mv, scale )
	if ply:OnGround() then
		mv:SetForwardSpeed( mv:GetForwardSpeed() * scale )
		mv:SetSideSpeed( mv:GetSideSpeed() * scale )
		return
	end

	mv:SetForwardSpeed( 0 )
	mv:SetSideSpeed( 0 )
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

local function applyLiquidCurrent( vel, contact, scale, tickFactor )
	if not contact or not MC.LiquidFlowAtCell then return vel end
	local flowX, flowY, flowZ = MC.LiquidFlowAtCell( contact.bx, contact.by, contact.bz, contact.kind )
	if flowX == 0 and flowY == 0 and flowZ == 0 then return vel end
	local depthScale = contact.depth and contact.depth < 0.4 and contact.depth or 1
	local impulse = mcToSourceVelocity( scale * depthScale * tickFactor )
	vel.x = vel.x + flowX * impulse
	vel.y = vel.y + flowY * impulse
	vel.z = vel.z + flowZ * impulse
	return vel
end

local function bubbleColumnDrag( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema or schema.name ~= "minecraft:bubble_column" then return nil end
	return MC.GetStateProperty( stateId, "drag" ) == true
end

local function applyBubbleColumnVelocity( vel, contact, tickFactor )
	local dragDown = contact and bubbleColumnDrag( contact.stateId )
	if dragDown == nil then return vel end
	local aboveSurface = not liquidAbove( contact )
	local mcZ = sourceToMcVelocity( vel.z )
	if dragDown then
		local cap = aboveSurface and -0.9 or -0.3
		mcZ = math.max( cap, mcZ - 0.03 * tickFactor )
	else
		local cap = aboveSurface and 1.8 or 0.7
		local impulse = aboveSurface and 0.1 or 0.06
		mcZ = math.min( cap, mcZ + impulse * tickFactor )
	end
	vel.z = mcToSourceVelocity( mcZ )
	return vel
end

local function applyWaterVelocity( ply, mv, contact )
	local vel = mv:GetVelocity()
	local tickFactor = mcTickFactor()
	local isFalling = vel.z <= 0
	local sprinting = isWaterSprinting( ply, mv, contact )
	vel = applyLiquidCurrent( vel, contact, MC_WATER_CURRENT_SCALE, tickFactor )
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
	vel = applyBubbleColumnVelocity( vel, contact, tickFactor )
	mv:SetVelocity( vel )
	consumeLiquidGroundInput( ply, mv, MC_WATER_GROUND_INPUT_SCALE )
end

local function applyLavaVelocity( ply, mv, contact )
	local vel = mv:GetVelocity()
	local tickFactor = mcTickFactor()
	vel = applyLiquidCurrent( vel, contact, MC_LAVA_CURRENT_SCALE, tickFactor )
	vel = moveRelative( vel, ply, mv, MC_LAVA_MOVE_RELATIVE, tickFactor )
	local lavaSlowDown = math.pow( MC_LAVA_SLOWDOWN, tickFactor )
	local lavaVerticalSlowDown = math.pow( MC_LAVA_VERTICAL_SLOWDOWN, tickFactor )
	vel.x = vel.x * lavaSlowDown
	vel.y = vel.y * lavaSlowDown
	vel.z = vel.z * lavaVerticalSlowDown
	vel.z = vel.z - mcToSourceVelocity( MC_WATER_GRAVITY / 4 * tickFactor )
	vel = jumpOutOfFluid( ply, mv, vel )
	mv:SetVelocity( vel )
	consumeLiquidGroundInput( ply, mv, MC_LAVA_GROUND_INPUT_SCALE )
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
		applyLavaVelocity( ply, mv, contact )
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
