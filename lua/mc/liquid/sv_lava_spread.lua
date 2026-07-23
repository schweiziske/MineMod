--[[----------------------------------------------------------------------------
	Minecraft LavaFluid / FlowingFluid spreading on the block update scheduler.

	The algorithm matches the water spreader but keeps LavaFluid's vanilla
	slower tick rate, steeper drop-off and shorter slope search distance.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Lava = MC.LavaSpread
local Kind = MC.BlockUpdateKind
if not Lava or not Kind then error( "MC lava spreading dependencies are unavailable" ) end

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
	if not worldBoundsOK( bx, by, bz ) then return Lava.AirState() end
	local key = MC.CellKey( bx, by, bz )
	local stateId = view.states[key]
	if stateId ~= nil then return stateId end
	return MC.GetBlockState( bx, by, bz ) or Lava.AirState()
end

local function scheduleLava( view, bx, by, bz )
	if not worldBoundsOK( bx, by, bz ) then return end
	local key = MC.CellKey( bx, by, bz )
	if view.scheduleSeen[key] then return end
	view.scheduleSeen[key] = true
	view.schedule[#view.schedule + 1] = {
		bx = bx, by = by, bz = bz,
		delayTicks = Lava.TICK_DELAY,
		kind = Kind.SCHEDULED,
	}
end

local function planState( view, bx, by, bz, stateId, schedule )
	if not worldBoundsOK( bx, by, bz ) then return false end
	local key = MC.CellKey( bx, by, bz )
	local current = viewState( view, bx, by, bz )
	if current == stateId then
		if schedule then scheduleLava( view, bx, by, bz ) end
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
	if schedule then scheduleLava( view, bx, by, bz ) end
	return true
end

local function getNewLiquid( getState, bx, by, bz )
	local stateId = getState( bx, by, bz )
	local highestNeighbor = 0
	for index = 1, 4 do
		local direction = Horizontal[index]
		local nx, ny = bx + direction[1], by + direction[2]
		local neighborStateId = getState( nx, ny, bz )
		local isLava, amount = Lava.Metrics( neighborStateId )
		if isLava and Lava.CanPassThroughWall( stateId, bx, by, bz, neighborStateId, nx, ny, bz, direction[3] ) then
			if amount > highestNeighbor then highestNeighbor = amount end
		end
	end

	local aboveStateId = getState( bx, by, bz + 1 )
	local aboveLava = Lava.Metrics( aboveStateId )
	if aboveLava and Lava.CanPassThroughWall( stateId, bx, by, bz, aboveStateId, bx, by, bz + 1, FACE_TOP ) then
		return 8, true, false
	end

	local amount = highestNeighbor - Lava.DROP_OFF
	if amount <= 0 then return 0, false, false end
	return amount, false, false
end

local function isLavaHole( getState, bx, by, bz )
	local bottomZ = bz - 1
	if not worldBoundsOK( bx, by, bottomZ ) then return false end
	local topStateId = getState( bx, by, bz )
	local bottomStateId = getState( bx, by, bottomZ )
	if not Lava.CanPassThroughWall( topStateId, bx, by, bz, bottomStateId, bx, by, bottomZ, FACE_BOTTOM ) then
		return false
	end
	local bottomLava = Lava.Metrics( bottomStateId )
	if bottomLava then return true end
	return Lava.CanHoldAny( bottomStateId, bx, by, bottomZ ) and Lava.CanHoldSpecific( bottomStateId )
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
	hole = isLavaHole( context.getState, bx, by, bz )
	context.holes[key] = hole
	return hole
end

local function slopeDistance( context, bx, by, bz, pass, fromIndex )
	local lowest = 1000
	for index = 1, 4 do
		if index ~= fromIndex then
			local direction = Horizontal[index]
			local nx, ny = bx + direction[1], by + direction[2]
			if Lava.CanPassThrough( context.getState, bx, by, bz, direction[3], nx, ny, bz ) then
				if contextHole( context, nx, ny, bz ) then return pass end
				if pass < Lava.SLOPE_DISTANCE then
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
		if Lava.CanMaybePassThrough( getState, bx, by, bz, direction[3], nx, ny, bz ) then
			local amount, falling, source = getNewLiquid( getState, nx, ny, bz )
			if amount > 0 and Lava.CanHoldSpecific( targetStateId ) then
				if not context then context = newSpreadContext( getState ) end
				local distance = contextHole( context, nx, ny, bz ) and 0
					or slopeDistance( context, nx, ny, bz, 1, direction[4] )
				if distance < lowest then
					for clearIndex = 1, resultCount do result[clearIndex] = nil end
					resultCount = 0
				end
				if distance <= lowest and Lava.TargetCanBeReplaced( targetStateId ) then
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
		local isLava, _, _, source = Lava.Metrics( getState( bx + direction[1], by + direction[2], bz ) )
		if isLava and source then count = count + 1 end
	end
	return count
end

local function spreadTo( view, bx, by, bz, amount, falling, source )
	local targetStateId = viewState( view, bx, by, bz )
	if not Lava.TargetCanBeReplaced( targetStateId ) then return false end
	local nextStateId = Lava.PlaceFluidInState( targetStateId, amount, falling, source )
	if not nextStateId then return false end
	return planState( view, bx, by, bz, nextStateId, true )
end

local function spreadToSides( view, getState, bx, by, bz, amount, falling )
	local neighborAmount = falling and 7 or amount - Lava.DROP_OFF
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
	if Lava.CanMaybePassThrough( getState, bx, by, bz, FACE_BOTTOM, bx, by, belowZ ) then
		local belowAmount, belowFalling, belowSource = getNewLiquid( getState, bx, by, belowZ )
		if belowAmount > 0 and Lava.TargetCanBeReplaced( belowStateId ) and Lava.CanHoldSpecific( belowStateId ) then
			spreadTo( view, bx, by, belowZ, belowAmount, belowFalling, belowSource )
			if sourceNeighborCount( getState, bx, by, bz ) >= 3 then
				spreadToSides( view, getState, bx, by, bz, amount, falling )
			end
			return
		end
	end
	if source or not isLavaHole( getState, bx, by, bz ) then
		spreadToSides( view, getState, bx, by, bz, amount, falling )
	end
end

local function scheduledLavaTick( context )
	local view = newView()
	local bx, by, bz = context.bx, context.by, context.bz
	local getState = function( x, y, z ) return viewState( view, x, y, z ) end
	local stateId = getState( bx, by, bz )
	local isLava, amount, falling, source = Lava.Metrics( stateId )
	if not isLava then return nil end

	if not source then
		local nextAmount, nextFalling, nextSource = getNewLiquid( getState, bx, by, bz )
		if nextAmount <= 0 then
			planState( view, bx, by, bz, Lava.AirState(), false )
			amount = 0
		else
			local nextStateId = Lava.BlockStateForFluid( nextAmount, nextFalling, nextSource )
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

local function neighborLavaUpdate( context )
	return {
		schedule = {
			{
				bx = context.bx, by = context.by, bz = context.bz,
				delayTicks = Lava.TICK_DELAY,
				kind = Kind.SCHEDULED,
			},
		},
	}
end

local handler, registerError = MC.RegisterBlockUpdateStateHandler(
	"minecraft:lava_fluid",
	function( stateId )
		local isLava = Lava.Metrics( stateId )
		return isLava == true
	end,
	{
		OnNeighborUpdate = neighborLavaUpdate,
		OnScheduledTick = scheduledLavaTick,
	}
)

if not handler then error( "MC lava update handler registration failed: " .. tostring( registerError ) ) end

Lava.GetNewLiquid = getNewLiquid
Lava.GetSpread = getSpread
Lava.ScheduledTick = scheduledLavaTick
