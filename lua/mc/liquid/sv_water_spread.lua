--[[----------------------------------------------------------------------------
	Minecraft WaterFluid / FlowingFluid spreading on the block update scheduler.

	The control flow mirrors FlowingFluid.tick, spread, getNewLiquid, getSpread
	and getSlopeDistance from the source tree under out/.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Water = MC.WaterSpread
local Kind = MC.BlockUpdateKind
if not Water or not Kind then error( "MC water spreading dependencies are unavailable" ) end

local FACE_TOP = MC.Liquid.FACE_TOP
local FACE_BOTTOM = MC.Liquid.FACE_BOTTOM
local FACE_XP = MC.Liquid.FACE_XP
local FACE_XN = MC.Liquid.FACE_XN
local FACE_YP = MC.Liquid.FACE_YP
local FACE_YN = MC.Liquid.FACE_YN

local Horizontal = {
	{ 1, 0, FACE_XP, 2 },
	{ -1, 0, FACE_XN, 1 },
	{ 0, 1, FACE_YP, 4 },
	{ 0, -1, FACE_YN, 3 },
}

local function worldBoundsOK( bx, by, bz )
	return not SV.WorldBoundsOK or SV.WorldBoundsOK( bx, by, bz )
end

local function newView()
	return {
		states = {},
		changes = {},
		changeByKey = {},
		schedule = {},
		scheduleSeen = {},
	}
end

local function viewState( view, bx, by, bz )
	if not worldBoundsOK( bx, by, bz ) then return Water.AirState() end
	local key = MC.CellKey( bx, by, bz )
	local stateId = view.states[key]
	if stateId ~= nil then return stateId end
	return MC.GetBlockState( bx, by, bz ) or Water.AirState()
end

local function scheduleWater( view, bx, by, bz )
	if not worldBoundsOK( bx, by, bz ) then return end
	local key = MC.CellKey( bx, by, bz )
	if view.scheduleSeen[key] then return end
	view.scheduleSeen[key] = true
	view.schedule[#view.schedule + 1] = {
		bx = bx, by = by, bz = bz,
		delayTicks = Water.TICK_DELAY,
		kind = Kind.SCHEDULED,
	}
end

local function planState( view, bx, by, bz, stateId, schedule )
	if not worldBoundsOK( bx, by, bz ) then return false end
	local key = MC.CellKey( bx, by, bz )
	local current = viewState( view, bx, by, bz )
	if current == stateId then
		if schedule then scheduleWater( view, bx, by, bz ) end
		return false
	end
	view.states[key] = stateId
	local change = view.changeByKey[key]
	if change then
		change.stateId = stateId
	else
		change = { bx = bx, by = by, bz = bz, stateId = stateId }
		view.changeByKey[key] = change
		view.changes[#view.changes + 1] = change
	end
	if schedule then scheduleWater( view, bx, by, bz ) end
	return true
end

local function getNewLiquid( getState, bx, by, bz )
	local stateId = getState( bx, by, bz )
	local highestNeighbor, neighborSources = 0, 0
	for index = 1, 4 do
		local direction = Horizontal[index]
		local nx, ny = bx + direction[1], by + direction[2]
		local neighborStateId = getState( nx, ny, bz )
		local isWater, amount, _, source = Water.Metrics( neighborStateId )
		if isWater and Water.CanPassThroughWall( stateId, bx, by, bz, neighborStateId, nx, ny, bz, direction[3] ) then
			if source then neighborSources = neighborSources + 1 end
			if amount > highestNeighbor then highestNeighbor = amount end
		end
	end

	if neighborSources >= 2 and Water.CanConvertToSource() then
		local belowStateId = getState( bx, by, bz - 1 )
		local belowWater, _, _, belowSource = Water.Metrics( belowStateId )
		if Water.StateIsSolid( belowStateId, bx, by, bz - 1 ) or belowWater and belowSource then
			return 8, false, true
		end
	end

	local aboveStateId = getState( bx, by, bz + 1 )
	local aboveWater = Water.Metrics( aboveStateId )
	if aboveWater and Water.CanPassThroughWall( stateId, bx, by, bz, aboveStateId, bx, by, bz + 1, FACE_TOP ) then
		return 8, true, false
	end

	local amount = highestNeighbor - Water.DROP_OFF
	if amount <= 0 then return 0, false, false end
	return amount, false, false
end

local function isWaterHole( getState, bx, by, bz )
	local bottomZ = bz - 1
	if not worldBoundsOK( bx, by, bottomZ ) then return false end
	local topStateId = getState( bx, by, bz )
	local bottomStateId = getState( bx, by, bottomZ )
	if not Water.CanPassThroughWall( topStateId, bx, by, bz, bottomStateId, bx, by, bottomZ, FACE_BOTTOM ) then
		return false
	end
	local bottomWater = Water.Metrics( bottomStateId )
	if bottomWater then return true end
	return Water.CanHoldAny( bottomStateId, bx, by, bottomZ ) and Water.CanHoldSpecific( bottomStateId )
end

local function newSpreadContext( getState )
	local context = { states = {}, holes = {} }
	context.getState = function( bx, by, bz )
		local key = MC.CellKey( bx, by, bz )
		local stateId = context.states[key]
		if stateId ~= nil then return stateId end
		stateId = getState( bx, by, bz )
		context.states[key] = stateId
		return stateId
	end
	return context
end

local function contextHole( context, bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	local hole = context.holes[key]
	if hole ~= nil then return hole end
	hole = isWaterHole( context.getState, bx, by, bz )
	context.holes[key] = hole
	return hole
end

local function slopeDistance( context, bx, by, bz, pass, fromIndex )
	local lowest = 1000
	for index = 1, 4 do
		if index ~= fromIndex then
			local direction = Horizontal[index]
			local nx, ny = bx + direction[1], by + direction[2]
			if Water.CanPassThrough( context.getState, bx, by, bz, direction[3], nx, ny, bz ) then
				if contextHole( context, nx, ny, bz ) then return pass end
				if pass < Water.SLOPE_DISTANCE then
					local distance = slopeDistance( context, nx, ny, bz, pass + 1, direction[4] )
					if distance < lowest then lowest = distance end
				end
			end
		end
	end
	return lowest
end

local function getSpread( getState, bx, by, bz )
	local lowest = 1000
	local result = {}
	local resultCount = 0
	local context
	for index = 1, 4 do
		local direction = Horizontal[index]
		local nx, ny = bx + direction[1], by + direction[2]
		local targetStateId = getState( nx, ny, bz )
		if Water.CanMaybePassThrough( getState, bx, by, bz, direction[3], nx, ny, bz ) then
			local amount, falling, source = getNewLiquid( getState, nx, ny, bz )
			if amount > 0 and Water.CanHoldSpecific( targetStateId ) then
				if not context then context = newSpreadContext( getState ) end
				local distance = contextHole( context, nx, ny, bz ) and 0
					or slopeDistance( context, nx, ny, bz, 1, direction[4] )
				if distance < lowest then
					for clearIndex = 1, resultCount do result[clearIndex] = nil end
					resultCount = 0
				end
				if distance <= lowest and Water.TargetCanBeReplaced( targetStateId ) then
					resultCount = resultCount + 1
					result[resultCount] = { nx, ny, bz, amount, falling, source }
				end
				if distance <= lowest then lowest = distance end
			end
		end
	end
	return result, resultCount
end

local function sourceNeighborCount( getState, bx, by, bz )
	local count = 0
	for index = 1, 4 do
		local direction = Horizontal[index]
		local isWater, _, _, source = Water.Metrics( getState( bx + direction[1], by + direction[2], bz ) )
		if isWater and source then count = count + 1 end
	end
	return count
end

local function spreadTo( view, bx, by, bz, amount, falling, source )
	local targetStateId = viewState( view, bx, by, bz )
	if not Water.TargetCanBeReplaced( targetStateId ) and not Water.CanPlaceWater( targetStateId ) then return false end
	local nextStateId = Water.PlaceFluidInState( targetStateId, amount, falling, source )
	if not nextStateId then return false end
	return planState( view, bx, by, bz, nextStateId, true )
end

local function spreadToSides( view, getState, bx, by, bz, amount, falling )
	local neighborAmount = falling and 7 or amount - Water.DROP_OFF
	if neighborAmount <= 0 then return end
	local spreads, spreadCount = getSpread( getState, bx, by, bz )
	for index = 1, spreadCount do
		local spread = spreads[index]
		spreadTo( view, spread[1], spread[2], spread[3], spread[4], spread[5], spread[6] )
	end
end

local function spread( view, getState, bx, by, bz, amount, falling, source )
	if amount <= 0 then return end
	local belowZ = bz - 1
	local belowStateId = getState( bx, by, belowZ )
	if Water.CanMaybePassThrough( getState, bx, by, bz, FACE_BOTTOM, bx, by, belowZ ) then
		local belowAmount, belowFalling, belowSource = getNewLiquid( getState, bx, by, belowZ )
		if belowAmount > 0 and Water.TargetCanBeReplaced( belowStateId ) and Water.CanHoldSpecific( belowStateId ) then
			spreadTo( view, bx, by, belowZ, belowAmount, belowFalling, belowSource )
			if sourceNeighborCount( getState, bx, by, bz ) >= 3 then
				spreadToSides( view, getState, bx, by, bz, amount, falling )
			end
			return
		end
	end
	if source or not isWaterHole( getState, bx, by, bz ) then
		spreadToSides( view, getState, bx, by, bz, amount, falling )
	end
end

local function scheduledWaterTick( context )
	local view = newView()
	local bx, by, bz = context.bx, context.by, context.bz
	local getState = function( x, y, z ) return viewState( view, x, y, z ) end
	local stateId = getState( bx, by, bz )
	local isWater, amount, falling, source = Water.Metrics( stateId )
	if not isWater then return nil end

	if not source then
		local nextAmount, nextFalling, nextSource = getNewLiquid( getState, bx, by, bz )
		if nextAmount <= 0 then
			planState( view, bx, by, bz, Water.AirState(), false )
			amount = 0
		else
			local nextStateId = Water.BlockStateForFluid( nextAmount, nextFalling, nextSource )
			if nextStateId ~= stateId then
				planState( view, bx, by, bz, nextStateId, true )
			end
			amount, falling, source = nextAmount, nextFalling, nextSource
		end
	end

	if amount > 0 then spread( view, getState, bx, by, bz, amount, falling, source ) end
	if #view.changes == 0 and #view.schedule == 0 then return nil end
	return { cells = view.changes, schedule = view.schedule, compareCollision = true }
end

local function neighborWaterUpdate( context )
	return {
		schedule = {
			{
				bx = context.bx, by = context.by, bz = context.bz,
				delayTicks = Water.TICK_DELAY,
				kind = Kind.SCHEDULED,
			},
		},
	}
end

local handler, registerError = MC.RegisterBlockUpdateStateHandler(
	"minecraft:water_fluid",
	function( stateId )
		local isWater = Water.Metrics( stateId )
		return isWater == true
	end,
	{
		OnNeighborUpdate = neighborWaterUpdate,
		OnScheduledTick = scheduledWaterTick,
	}
)

if not handler then error( "MC water update handler registration failed: " .. tostring( registerError ) ) end

Water.GetNewLiquid = getNewLiquid
Water.GetSpread = getSpread
Water.ScheduledTick = scheduledWaterTick
