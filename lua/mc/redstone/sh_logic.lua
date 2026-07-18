-- Minecraft directional redstone logic: repeaters, comparators and observers.

MC = MC or {}

local GetBlockState = MC.GetBlockState
local GetStateProperty = MC.GetStateProperty
local StateWith = MC.StateWith
local Offset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
	up = { 0, 0, 1 }, down = { 0, 0, -1 },
}

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState( stateId )
	return schema and schema.name or nil
end

local function facingOffset( stateId )
	return Offset[GetStateProperty( stateId, "facing" )] or Offset.north
end

local function signalAtOffset( bx, by, bz, offset )
	return MC.RedstoneSignalAt(
		bx + offset[1], by + offset[2], bz + offset[3],
		-offset[1], -offset[2], -offset[3]
	)
end

local function sideOffsets( facing )
	if facing[1] ~= 0 then return Offset.north, Offset.south end
	return Offset.west, Offset.east
end

local function directionalOutput( stateId, towardX, towardY, towardZ, power )
	if GetStateProperty( stateId, "powered" ) ~= true then return 0 end
	local facing = facingOffset( stateId )
	if towardX ~= -facing[1] or towardY ~= -facing[2] or towardZ ~= -facing[3] then return 0 end
	return power
end

local function inputSignal( stateId, bx, by, bz )
	return signalAtOffset( bx, by, bz, facingOffset( stateId ) )
end

local function sideSignal( stateId, bx, by, bz, diodesOnly )
	local left, right = sideOffsets( facingOffset( stateId ) )
	local function sample( offset )
		local sx, sy, sz = bx + offset[1], by + offset[2], bz + offset[3]
		if diodesOnly then
			local name = stateName( GetBlockState( sx, sy, sz ) )
			if name ~= "minecraft:repeater" and name ~= "minecraft:comparator" then return 0 end
		end
		return MC.RedstoneSignalAt( sx, sy, sz, -offset[1], -offset[2], -offset[3] )
	end
	local a, b = sample( left ), sample( right )
	return a > b and a or b
end

local function transactionState( bx, by, bz, stateId, actor )
	if not SERVER or not MC.SV or not MC.SV.ApplyBlockTransaction then return false end
	local result = MC.SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = stateId },
	}, { actor = actor, fx = false, netMode = "bulk", compareCollision = false } )
	return result and result.ok == true and result.changed > 0 or false
end

MC.RegisterRedstoneSignalEmitter( "minecraft:repeater", function( stateId, _, _, _, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, 15 )
end )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:repeater", function( stateId, _, _, _, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, 15 )
end )

local function repeaterNeighbour( context )
	local stateId = context.stateId
	local locked = sideSignal( stateId, context.bx, context.by, context.bz, true ) > 0
	local wasLocked = GetStateProperty( stateId, "locked" ) == true
	local nextState = stateId
	if locked ~= wasLocked then nextState = StateWith( nextState, "locked", locked ) or nextState end
	local result
	if nextState ~= stateId then
		result = { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = nextState } } }
	end
	if not locked then
		local shouldPower = inputSignal( nextState, context.bx, context.by, context.bz ) > 0
		if shouldPower ~= ( GetStateProperty( nextState, "powered" ) == true ) then
			result = result or {}
			result.schedule = { {
				delayTicks = ( tonumber( GetStateProperty( nextState, "delay" ) ) or 1 ) * 2,
				expectedStateId = nextState,
			} }
		end
	end
	return result
end

local function repeaterTick( context )
	if sideSignal( context.stateId, context.bx, context.by, context.bz, true ) > 0 then return nil end
	local powered = GetStateProperty( context.stateId, "powered" ) == true
	local input = inputSignal( context.stateId, context.bx, context.by, context.bz ) > 0
	if powered then
		if input then return nil end
		return { cells = { {
			bx = context.bx, by = context.by, bz = context.bz,
			stateId = StateWith( context.stateId, "powered", false ) or context.stateId,
		} } }
	end
	-- Vanilla RepeaterBlock.tick turns the output on unconditionally once the
	-- delay elapses; a vanished input only schedules the matching turn-off.
	-- Re-checking the input here would swallow every pulse shorter than the
	-- repeater delay (observer pulses would die at the first repeater).
	local onState = StateWith( context.stateId, "powered", true ) or context.stateId
	local result = { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = onState } } }
	if not input then
		result.schedule = { {
			delayTicks = ( tonumber( GetStateProperty( context.stateId, "delay" ) ) or 1 ) * 2,
			expectedStateId = onState,
		} }
	end
	return result
end

MC.RegisterBlockUpdateHandler( "minecraft:repeater", {
	OnNeighborUpdate = repeaterNeighbour,
	OnScheduledTick = repeaterTick,
} )

local repeaterBlock = MC.BlockByName["minecraft:repeater"]
if repeaterBlock then
	repeaterBlock.handlers.OnUse = function( ply, bx, by, bz )
		local stateId = GetBlockState( bx, by, bz )
		if stateName( stateId ) ~= "minecraft:repeater" then return false end
		local delay = tonumber( GetStateProperty( stateId, "delay" ) ) or 1
		return transactionState( bx, by, bz, StateWith( stateId, "delay", delay % 4 + 1 ) or stateId, ply )
	end
end

local function comparatorOutput( stateId, bx, by, bz )
	local input = inputSignal( stateId, bx, by, bz )
	local side = sideSignal( stateId, bx, by, bz, false )
	if GetStateProperty( stateId, "mode" ) == "subtract" then
		local output = input - side
		return output > 0 and output or 0
	end
	return input >= side and input or 0
end

-- Vanilla comparators hold their output strength in a block entity: changes
-- propagate on a 2-tick schedule and the block in front is re-notified even
-- when the boolean powered flag never moves. Publish strength through this
-- cache so emitter queries stay cheap and analog changes reach the wire ahead.
local ComparatorOutput = {}

local NeighborOffsets = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

local function publishedComparatorOutput( stateId, bx, by, bz )
	if CLIENT then return comparatorOutput( stateId, bx, by, bz ) end
	local key = MC.CellKey( bx, by, bz )
	local cached = ComparatorOutput[key]
	if cached == nil then
		cached = comparatorOutput( stateId, bx, by, bz )
		ComparatorOutput[key] = cached
	end
	return cached
end

MC.RegisterRedstoneSignalEmitter( "minecraft:comparator", function( stateId, bx, by, bz, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, publishedComparatorOutput( stateId, bx, by, bz ) )
end )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:comparator", function( stateId, bx, by, bz, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, publishedComparatorOutput( stateId, bx, by, bz ) )
end )

MC.RegisterBlockUpdateHandler( "minecraft:comparator", {
	OnNeighborUpdate = function( context )
		local live = comparatorOutput( context.stateId, context.bx, context.by, context.bz )
		if live == publishedComparatorOutput( context.stateId, context.bx, context.by, context.bz )
		and ( live > 0 ) == ( GetStateProperty( context.stateId, "powered" ) == true ) then return nil end
		return { schedule = { { delayTicks = 2, expectedStateId = context.stateId } } }
	end,
	OnScheduledTick = function( context )
		local output = comparatorOutput( context.stateId, context.bx, context.by, context.bz )
		local key = MC.CellKey( context.bx, context.by, context.bz )
		local strengthChanged = ComparatorOutput[key] ~= output
		ComparatorOutput[key] = output
		local powered = output > 0
		if powered ~= ( GetStateProperty( context.stateId, "powered" ) == true ) then
			return { cells = { {
				bx = context.bx, by = context.by, bz = context.bz,
				stateId = StateWith( context.stateId, "powered", powered ) or context.stateId,
			} } }
		end
		if not strengthChanged then return nil end
		-- The powered flag did not move, so no transaction fans out: hand-deliver
		-- the front-of-comparator updates vanilla's updateNeighborsInFront sends
		-- on every analog strength change.
		local facing = facingOffset( context.stateId )
		local frontX, frontY, frontZ = context.bx - facing[1], context.by - facing[2], context.bz - facing[3]
		local updates = { { bx = frontX, by = frontY, bz = frontZ } }
		for index = 1, 6 do
			local side = NeighborOffsets[index]
			local nx, ny, nz = frontX + side[1], frontY + side[2], frontZ + side[3]
			if nx ~= context.bx or ny ~= context.by or nz ~= context.bz then
				updates[#updates + 1] = { bx = nx, by = ny, bz = nz }
			end
		end
		return { updates = updates }
	end,
} )

local comparatorBlock = MC.BlockByName["minecraft:comparator"]
if comparatorBlock then
	comparatorBlock.handlers.OnUse = function( ply, bx, by, bz )
		local stateId = GetBlockState( bx, by, bz )
		if stateName( stateId ) ~= "minecraft:comparator" then return false end
		local mode = GetStateProperty( stateId, "mode" ) == "subtract" and "compare" or "subtract"
		return transactionState( bx, by, bz, StateWith( stateId, "mode", mode ) or stateId, ply )
	end
end

local ObserverTiles = MC.Tiles or {}

local function observerVisual( stateId, _, visual )
	local faces = {}
	local powered = GetStateProperty( stateId, "powered" ) == true
	for face = 1, 6 do
		local tile, rot, flipU, flipV = MC.BlockFace( visual.id, face, visual.renderOrient )
		if powered and tile == ObserverTiles.observer_back and ObserverTiles.observer_back_on then
			tile = ObserverTiles.observer_back_on
		end
		if ( rot or 0 ) == 0 and not flipU and not flipV then
			faces[face] = tile
		else
			faces[face] = { tile = tile, rot = rot or 0, flipU = flipU == true, flipV = flipV == true }
		end
	end
	return { forceBaseRenderer = true, faces = faces }
end

MC.RegisterBlockStateVisual( "minecraft:observer", { Resolve = observerVisual } )

if CLIENT and timer and timer.Simple then
	timer.Simple( 0, function()
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "observer_visual_reload" ) end
	end )
end

MC.RegisterRedstoneSignalEmitter( "minecraft:observer", function( stateId, _, _, _, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, 15 )
end )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:observer", function( stateId, _, _, _, towardX, towardY, towardZ )
	return directionalOutput( stateId, towardX, towardY, towardZ, 15 )
end )

local function reserveObserverOffTick( context, poweredState )
	if not SERVER or not MC.SV or not MC.SV.ScheduleBlockTick then return true end
	local scheduled, reason = MC.SV.ScheduleBlockTick(
		context.bx, context.by, context.bz, 2, MC.BlockUpdateKind.SCHEDULED, poweredState
	)
	return scheduled == true or reason == "scheduled_tick_exists"
end

MC.RegisterBlockUpdateHandler( "minecraft:observer", {
	OnNeighborUpdate = function( context )
		if GetStateProperty( context.stateId, "powered" ) == true then
			-- Never leave permanent output if queue pressure discarded the original
			-- pulse-off reservation. Either restore it or fail safe to unpowered.
			if reserveObserverOffTick( context, context.stateId ) then return nil end
			return { cells = { {
				bx = context.bx, by = context.by, bz = context.bz,
				stateId = StateWith( context.stateId, "powered", false ) or context.stateId,
			} } }
		end
		local facing = facingOffset( context.stateId )
		local watchedX, watchedY, watchedZ = context.bx + facing[1], context.by + facing[2], context.bz + facing[3]
		local watched = context.sourceX == watchedX and context.sourceY == watchedY and context.sourceZ == watchedZ
		if not watched and context.sources then
			for index = 1, #context.sources do
				local source = context.sources[index]
				if source[1] == watchedX and source[2] == watchedY and source[3] == watchedZ then
					watched = true
					break
				end
			end
		end
		if not watched then return nil end
		return { schedule = { { delayTicks = 2, expectedStateId = context.stateId } } }
	end,
	OnScheduledTick = function( context )
		local powered = GetStateProperty( context.stateId, "powered" ) == true
		local nextState = StateWith( context.stateId, "powered", not powered ) or context.stateId
		-- Reserve the falling edge before publishing the rising edge. If the
		-- scheduler is full, skip this pulse instead of creating stuck power.
		if not powered and not reserveObserverOffTick( context, nextState ) then return nil end
		return { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = nextState } } }
	end,
} )

function MC.RedstoneLogicDiagnostics()
	return {
		repeater = MC.BlockUpdateHandlerForName( "minecraft:repeater" ) ~= nil,
		comparator = MC.BlockUpdateHandlerForName( "minecraft:comparator" ) ~= nil,
		observer = MC.BlockUpdateHandlerForName( "minecraft:observer" ) ~= nil,
	}
end
