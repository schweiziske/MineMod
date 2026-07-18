--[[----------------------------------------------------------------------------
	MC : state-native redstone core.

	Power is stored in vanilla block states. The authoritative scheduler fans out
	local changes, so an idle circuit costs no work and propagation never scans
	the world. Directional logic and controlled devices extend the emitter API.
------------------------------------------------------------------------------]]

MC = MC or {}

if not MC._SetBlockStateStorageRaw then
	error( "MC redstone core must load after state-native voxel storage" )
end

local StateWith = MC.StateWith
local GetStateProperty = MC.GetStateProperty
local BlockStateSchemaForState = MC.BlockStateSchemaForState
local BlockIsFullCubeForState = MC.BlockIsFullCubeForState
local GetBlockState = MC.GetBlockState
local IsRedstoneWireState = MC.IsRedstoneWireState
local CellKey = MC.CellKey

local WireDirections = {
	{ 0, -1, "north" },
	{ 0, 1, "south" },
	{ -1, 0, "west" },
	{ 1, 0, "east" },
}

local NeighborDirections = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

local OppositeDirection = {
	north = "south", south = "north",
	west = "east", east = "west",
}

local SignalEmitters = {}
local SignalEmitterCache = {}
local DirectSignalEmitters = {}
local DirectSignalEmitterCache = {}

local RedstoneSoundResources = {
	"sound/mc/random/click.ogg",
	"sound/mc/tile/piston/in.ogg",
	"sound/mc/tile/piston/out.ogg",
}

if SERVER and resource and resource.AddFile then
	for index = 1, #RedstoneSoundResources do resource.AddFile( RedstoneSoundResources[index] ) end
end

function MC.PlayRedstoneSound( soundPath, bx, by, bz, volume, pitch )
	if not SERVER or not sound or not sound.Play or type( soundPath ) ~= "string" then return false end
	local position = MC.CellWorldCenter and MC.CellWorldCenter( bx, by, bz ) or Vector( 0, 0, 0 )
	local sourcePitch = math.floor( ( tonumber( pitch ) or 1 ) * 100 + 0.5 )
	sound.Play( soundPath, position, 70, sourcePitch, tonumber( volume ) or 1 )
	return true
end

local function stateName( stateId )
	local schema = BlockStateSchemaForState and BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

local function clampPower( value )
	value = math.floor( tonumber( value ) or 0 )
	if value < 0 then return 0 end
	if value > 15 then return 15 end
	return value
end

function MC.RegisterRedstoneSignalEmitter( blockName, emitter )
	if type( blockName ) ~= "string" or type( emitter ) ~= "function" then return nil, "invalid_emitter" end
	if not string.find( blockName, ":", 1, true ) then blockName = "minecraft:" .. blockName end
	SignalEmitters[blockName] = emitter
	SignalEmitterCache = {}
	return emitter
end

function MC.RegisterRedstoneDirectSignalEmitter( blockName, emitter )
	if type( blockName ) ~= "string" or type( emitter ) ~= "function" then return nil, "invalid_direct_emitter" end
	if not string.find( blockName, ":", 1, true ) then blockName = "minecraft:" .. blockName end
	DirectSignalEmitters[blockName] = emitter
	DirectSignalEmitterCache = {}
	return emitter
end

-- RedStoneWireBlock.shouldConnectTo: horizontal dust connects to every signal
-- source, with the vanilla directional restrictions for repeaters/observers.
-- Calls without a horizontal direction are intentionally wire-only; those are
-- used by the one-block-up/down dust path checks.
function MC.RedstoneWireConnectsToState( stateId, directionName )
	if IsRedstoneWireState( stateId ) then return true end
	if directionName == nil then return false end
	local name = stateName( stateId )
	if name == "minecraft:repeater" then
		local facing = GetStateProperty( stateId, "facing" )
		return facing == directionName or OppositeDirection[facing] == directionName
	end
	if name == "minecraft:observer" then
		return GetStateProperty( stateId, "facing" ) == directionName
	end
	return SignalEmitters[name] ~= nil
end

function MC.RedstoneSignalFromState( stateId, bx, by, bz, towardX, towardY, towardZ )
	if not stateId or stateId == 0 or IsRedstoneWireState( stateId ) then return 0 end
	local emitter = SignalEmitterCache[stateId]
	if emitter == nil then
		emitter = SignalEmitters[stateName( stateId )] or false
		SignalEmitterCache[stateId] = emitter
	end
	if not emitter then return 0 end
	return clampPower( emitter( stateId, bx, by, bz, towardX, towardY, towardZ ) )
end

function MC.RedstoneDirectSignalFromState( stateId, bx, by, bz, towardX, towardY, towardZ )
	if not stateId or stateId == 0 or IsRedstoneWireState( stateId ) then return 0 end
	local emitter = DirectSignalEmitterCache[stateId]
	if emitter == nil then
		emitter = DirectSignalEmitters[stateName( stateId )] or false
		DirectSignalEmitterCache[stateId] = emitter
	end
	if not emitter then return 0 end
	return clampPower( emitter( stateId, bx, by, bz, towardX, towardY, towardZ ) )
end

local function poweredEmitter( stateId )
	return GetStateProperty( stateId, "powered" ) == true and 15 or 0
end

local TorchFacingOffset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
}

local function torchEmitter( stateId, _, _, _, towardX, towardY, towardZ )
	if GetStateProperty( stateId, "lit" ) ~= true then return 0 end
	local name = stateName( stateId )
	if name == "minecraft:redstone_torch" then
		return towardX == 0 and towardY == 0 and towardZ == -1 and 0 or 15
	end
	local facing = TorchFacingOffset[GetStateProperty( stateId, "facing" )]
	if facing and towardX == -facing[1] and towardY == -facing[2] and towardZ == 0 then return 0 end
	return 15
end

local function analogPowerEmitter( stateId )
	return GetStateProperty( stateId, "power" ) or 0
end

local FacingVector = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
	up = { 0, 0, 1 }, down = { 0, 0, -1 },
}

local function faceAttachedDirectEmitter( stateId, bx, by, bz, towardX, towardY, towardZ )
	if GetStateProperty( stateId, "powered" ) ~= true or not MC.FaceAttachedSupportCell then return 0 end
	local sx, sy, sz = MC.FaceAttachedSupportCell( bx, by, bz, stateId )
	if sx == nil then return 0 end
	return sx - bx == towardX and sy - by == towardY and sz - bz == towardZ and 15 or 0
end

local function downwardDirectPower( stateId, _, _, _, _, _, towardZ )
	local power = GetStateProperty( stateId, "power" )
	if power == nil then power = GetStateProperty( stateId, "powered" ) == true and 15 or 0 end
	return towardZ == -1 and power or 0
end

local function upwardTorchDirectPower( stateId, _, _, _, _, _, towardZ )
	return towardZ == 1 and GetStateProperty( stateId, "lit" ) == true and 15 or 0
end

local function facingBackDirectPower( stateId, _, _, _, towardX, towardY, towardZ )
	if GetStateProperty( stateId, "powered" ) ~= true then return 0 end
	local facing = FacingVector[GetStateProperty( stateId, "facing" )]
	return facing and towardX == -facing[1] and towardY == -facing[2] and towardZ == -facing[3] and 15 or 0
end

MC.RegisterRedstoneSignalEmitter( "minecraft:redstone_block", function() return 15 end )
MC.RegisterRedstoneSignalEmitter( "minecraft:lever", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:redstone_torch", torchEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:redstone_wall_torch", torchEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:repeater", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:comparator", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:observer", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:daylight_detector", analogPowerEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:target", analogPowerEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:sculk_sensor", analogPowerEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:calibrated_sculk_sensor", analogPowerEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:detector_rail", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:tripwire_hook", poweredEmitter )
MC.RegisterRedstoneSignalEmitter( "minecraft:lightning_rod", poweredEmitter )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:lever", faceAttachedDirectEmitter )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:redstone_torch", upwardTorchDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:redstone_wall_torch", upwardTorchDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:repeater", facingBackDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:comparator", facingBackDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:observer", facingBackDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:sculk_sensor", downwardDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:calibrated_sculk_sensor", downwardDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:detector_rail", downwardDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:tripwire_hook", facingBackDirectPower )
MC.RegisterRedstoneDirectSignalEmitter( "minecraft:lightning_rod", facingBackDirectPower )

local ButtonNames = {
	"stone_button", "polished_blackstone_button", "oak_button", "spruce_button",
	"birch_button", "jungle_button", "acacia_button", "cherry_button",
	"dark_oak_button", "pale_oak_button", "mangrove_button", "bamboo_button",
	"crimson_button", "warped_button",
}
for index = 1, #ButtonNames do
	MC.RegisterRedstoneSignalEmitter( "minecraft:" .. ButtonNames[index], poweredEmitter )
	MC.RegisterRedstoneDirectSignalEmitter( "minecraft:" .. ButtonNames[index], faceAttachedDirectEmitter )
end

local function pressurePlateEmitter( stateId )
	local power = GetStateProperty( stateId, "power" )
	if power ~= nil then return power end
	return GetStateProperty( stateId, "powered" ) == true and 15 or 0
end

for name in pairs( MC.BlockByName ) do
	if string.match( name, "_pressure_plate$" ) then
		MC.RegisterRedstoneSignalEmitter( name, pressurePlateEmitter )
		MC.RegisterRedstoneDirectSignalEmitter( name, downwardDirectPower )
	end
end

local function redstoneTorchVisual( stateId )
	local lit = GetStateProperty( stateId, "lit" ) == true
	return {
		-- The generated legacy block record uses redstone_torch_off as its base
		-- surface. Force the exact imported blockstate model for both lit states.
		forceGeneratedVisual = true,
		lightEmission = lit and 7 or 0,
	}
end

if MC.RegisterBlockStateVisual then
	MC.RegisterBlockStateVisual( "minecraft:redstone_torch", { Resolve = redstoneTorchVisual } )
	MC.RegisterBlockStateVisual( "minecraft:redstone_wall_torch", { Resolve = redstoneTorchVisual } )
end

local function fullCube( stateId, bx, by, bz )
	return stateId ~= nil and stateId ~= 0
		and BlockIsFullCubeForState and BlockIsFullCubeForState( stateId, bx, by, bz ) == true
end

local function redstoneUpdateSourceState( stateId )
	if not stateId or stateId == 0 then return false end
	if IsRedstoneWireState( stateId ) then return true end
	return SignalEmitters[stateName( stateId )] ~= nil
end

-- Transactions already notify direct neighbours. A redstone source can also
-- power an adjacent full cube, so notify that conductor's neighbours as one
-- bounded extra layer. This reaches wall/standing torches on the far faces
-- without recursively flooding through solid structures.
function MC.AppendRedstoneConductorFanout( changes, add )
	if type( changes ) ~= "table" or type( add ) ~= "function" then return 0 end
	local added = 0
	for changeIndex = 1, #changes do
		local change = changes[changeIndex]
		if redstoneUpdateSourceState( change.stateId )
		or redstoneUpdateSourceState( change.oldStateId ) then
			local bx, by, bz = change.bx, change.by, change.bz
			for directionIndex = 1, 6 do
				local direction = NeighborDirections[directionIndex]
				local cx, cy, cz = bx + direction[1], by + direction[2], bz + direction[3]
				local conductorState = GetBlockState( cx, cy, cz )
				if fullCube( conductorState, cx, cy, cz ) then
					for targetIndex = 1, 6 do
						local target = NeighborDirections[targetIndex]
						add( cx + target[1], cy + target[2], cz + target[3], bx, by, bz )
						added = added + 1
					end
				end
			end
		end
	end
	return added
end

local function wirePower( stateId )
	if not IsRedstoneWireState( stateId ) then return 0 end
	return clampPower( GetStateProperty( stateId, "power" ) )
end

local function wireSignalToward( stateId, towardX, towardY, towardZ )
	local power = wirePower( stateId )
	if power <= 0 or towardZ == 1 then return 0 end
	if towardZ == -1 then return power end
	local direction
	if towardX == 1 and towardY == 0 then direction = "east"
	elseif towardX == -1 and towardY == 0 then direction = "west"
	elseif towardY == 1 and towardX == 0 then direction = "south"
	elseif towardY == -1 and towardX == 0 then direction = "north" end
	if not direction or GetStateProperty( stateId, direction ) == "none" then return 0 end
	return power
end

local function directSignalAt( bx, by, bz, towardX, towardY, towardZ, suppressWire, readState )
	local stateId = ( readState or GetBlockState )( bx, by, bz )
	if IsRedstoneWireState( stateId ) then
		return suppressWire and 0 or wireSignalToward( stateId, towardX, towardY, towardZ )
	end
	return MC.RedstoneDirectSignalFromState( stateId, bx, by, bz, towardX, towardY, towardZ )
end

local function conductorSample( sx, sy, sz, tx, ty, tz, targetX, targetY, targetZ, suppressWire, readState )
	if sx == targetX and sy == targetY and sz == targetZ then return 0 end
	return directSignalAt( sx, sy, sz, tx, ty, tz, suppressWire, readState )
end

local function conductorSignal( stateId, bx, by, bz, towardX, towardY, towardZ, suppressWire, readState )
	if not fullCube( stateId, bx, by, bz ) then return 0 end
	local targetX, targetY, targetZ = bx + towardX, by + towardY, bz + towardZ
	local best = conductorSample( bx + 1, by, bz, -1, 0, 0, targetX, targetY, targetZ, suppressWire, readState )
	local value = conductorSample( bx - 1, by, bz, 1, 0, 0, targetX, targetY, targetZ, suppressWire, readState )
	if value > best then best = value end
	value = conductorSample( bx, by + 1, bz, 0, -1, 0, targetX, targetY, targetZ, suppressWire, readState )
	if value > best then best = value end
	value = conductorSample( bx, by - 1, bz, 0, 1, 0, targetX, targetY, targetZ, suppressWire, readState )
	if value > best then best = value end
	value = conductorSample( bx, by, bz + 1, 0, 0, -1, targetX, targetY, targetZ, suppressWire, readState )
	if value > best then best = value end
	value = conductorSample( bx, by, bz - 1, 0, 0, 1, targetX, targetY, targetZ, suppressWire, readState )
	if value > best then best = value end
	return best
end

-- Rebind after wirePower exists.  Keeping this public helper below the local
-- declaration avoids a global lookup in the propagation hot path.
function MC.RedstoneSignalAt( bx, by, bz, towardX, towardY, towardZ )
	local stateId = GetBlockState( bx, by, bz )
	local signal = IsRedstoneWireState( stateId ) and wireSignalToward( stateId, towardX, towardY, towardZ )
		or MC.RedstoneSignalFromState( stateId, bx, by, bz, towardX, towardY, towardZ )
	local conducted = conductorSignal( stateId, bx, by, bz, towardX, towardY, towardZ )
	return conducted > signal and conducted or signal
end

local function neighbourSignal( sx, sy, sz, towardX, towardY, towardZ, ignoreX, ignoreY, ignoreZ )
	if sx == ignoreX and sy == ignoreY and sz == ignoreZ then return 0 end
	return MC.RedstoneSignalAt( sx, sy, sz, towardX, towardY, towardZ )
end

function MC.RedstoneBestNeighborSignal( bx, by, bz, ignoreX, ignoreY, ignoreZ )
	local best = neighbourSignal( bx + 1, by, bz, -1, 0, 0, ignoreX, ignoreY, ignoreZ )
	local value = neighbourSignal( bx - 1, by, bz, 1, 0, 0, ignoreX, ignoreY, ignoreZ )
	if value > best then best = value end
	value = neighbourSignal( bx, by + 1, bz, 0, -1, 0, ignoreX, ignoreY, ignoreZ )
	if value > best then best = value end
	value = neighbourSignal( bx, by - 1, bz, 0, 1, 0, ignoreX, ignoreY, ignoreZ )
	if value > best then best = value end
	value = neighbourSignal( bx, by, bz + 1, 0, 0, -1, ignoreX, ignoreY, ignoreZ )
	if value > best then best = value end
	value = neighbourSignal( bx, by, bz - 1, 0, 0, 1, ignoreX, ignoreY, ignoreZ )
	if value > best then best = value end
	return best
end

local function sourcePowerAt( bx, by, bz, towardX, towardY, towardZ, readState )
	local stateId = readState( bx, by, bz )
	if IsRedstoneWireState( stateId ) then return 0 end
	local signal = MC.RedstoneSignalFromState( stateId, bx, by, bz, towardX, towardY, towardZ )
	-- RedStoneWireBlock.getBlockSignal temporarily disables every dust output
	-- while finding non-wire power. Without this, two powered wires separated by
	-- one conductor can feed each other forever after the real source is gone.
	local conducted = conductorSignal( stateId, bx, by, bz, towardX, towardY, towardZ, true, readState )
	return conducted > signal and conducted or signal
end

local function strongestDirectSource( bx, by, bz, readState )
	local best = sourcePowerAt( bx + 1, by, bz, -1, 0, 0, readState )
	local value = sourcePowerAt( bx - 1, by, bz, 1, 0, 0, readState )
	if value > best then best = value end
	value = sourcePowerAt( bx, by + 1, bz, 0, -1, 0, readState )
	if value > best then best = value end
	value = sourcePowerAt( bx, by - 1, bz, 0, 1, 0, readState )
	if value > best then best = value end
	value = sourcePowerAt( bx, by, bz + 1, 0, 0, -1, readState )
	if value > best then best = value end
	value = sourcePowerAt( bx, by, bz - 1, 0, 0, 1, readState )
	if value > best then best = value end
	return best
end

local function visitWireNeighbours( bx, by, bz, readState, visit )
	local aboveState = readState( bx, by, bz + 1 )
	local canClimb = not fullCube( aboveState, bx, by, bz + 1 )
	for index = 1, 4 do
		local direction = WireDirections[index]
		local nx, ny = bx + direction[1], by + direction[2]
		local neighbourState = readState( nx, ny, bz )
		if IsRedstoneWireState( neighbourState ) then visit( nx, ny, bz, neighbourState ) end
		if fullCube( neighbourState, nx, ny, bz ) then
			if canClimb then
				local upperState = readState( nx, ny, bz + 1 )
				if IsRedstoneWireState( upperState ) then visit( nx, ny, bz + 1, upperState ) end
			end
		else
			local lowerState = readState( nx, ny, bz - 1 )
			if IsRedstoneWireState( lowerState ) then visit( nx, ny, bz - 1, lowerState ) end
		end
	end
end

local WireSettledRevision = {}
local WireStats = {
	settlements = 0,
	wiresScanned = 0,
	wiresChanged = 0,
	revisionSkips = 0,
	oversizedFallbacks = 0,
}

local function wireBatchCellLimit()
	local cv = GetConVar and GetConVar( "mc_block_update_max_cells_per_tick" ) or nil
	local limit = cv and tonumber( cv:GetInt() ) or 16384
	limit = math.floor( limit or 16384 )
	return limit > 0 and limit or 16384
end

local function appendWireFanout( updates, bx, by, bz )
	local count = 0
	for index = 1, 4 do
		local direction = WireDirections[index]
		local nx, ny = bx + direction[1], by + direction[2]
		count = count + 1
		updates[count] = { bx = nx, by = ny, bz = bz }
		count = count + 1
		updates[count] = { bx = nx, by = ny, bz = bz - 1 }
		count = count + 1
		updates[count] = { bx = nx, by = ny, bz = bz + 1 }
	end
	return updates
end

local function updateSingleWire( context, readState )
	local bx, by, bz = context.bx, context.by, context.bz
	local power = strongestDirectSource( bx, by, bz, readState )
	local neighbourPower = 0
	visitWireNeighbours( bx, by, bz, readState, function( _, _, _, stateId )
		local value = wirePower( stateId )
		if value > neighbourPower then neighbourPower = value end
	end )
	neighbourPower = neighbourPower - 1
	if neighbourPower > power then power = neighbourPower end
	if power < 0 then power = 0 end
	local stateId = readState( bx, by, bz )
	if wirePower( stateId ) == power then return nil end
	local nextState = StateWith( stateId, "power", power ) or stateId
	if nextState == stateId then return nil end
	return {
		cells = { { bx = bx, by = by, bz = bz, stateId = nextState } },
		updates = appendWireFanout( {}, bx, by, bz ),
		compareCollision = true,
	}
end

local function markWireNetworkCommitted( keys, transaction )
	if type( transaction ) ~= "table" or transaction.ok ~= true then return end
	local revision = tonumber( transaction.revision )
	if not revision then return end
	for index = 1, #keys do WireSettledRevision[keys[index]] = revision end
end

function MC.ClearRedstoneWireRuntime()
	WireSettledRevision = {}
end

local function updateWire( context )
	local startX, startY, startZ = context.bx, context.by, context.bz
	local startKey = CellKey( startX, startY, startZ )
	local inputRevision = tonumber( context.revision )
	if inputRevision and ( WireSettledRevision[startKey] or -1 ) >= inputRevision then
		WireStats.revisionSkips = WireStats.revisionSkips + 1
		return nil
	end

	-- One settlement owns a small, revision-local state cache. Conductors around
	-- a long line otherwise make strongestDirectSource repeat the same chunk and
	-- neighbour lookups dozens of times per wire.
	local stateCache = {}
	local function readState( bx, by, bz )
		local key = CellKey( bx, by, bz )
		local stateId = stateCache[key]
		if stateId == nil then
			stateId = GetBlockState( bx, by, bz )
			stateCache[key] = stateId
		end
		return stateId
	end

	local startState = readState( startX, startY, startZ )
	if not IsRedstoneWireState( startState ) then return nil end

	-- Parallel numeric arrays keep the LuaJIT hot path monomorphic. Edges contain
	-- integer wire indices rather than per-neighbour tables or coordinate strings.
	local xs, ys, zs, states, keys = {}, {}, {}, {}, {}
	local byKey, edgeStarts, edgeEnds, edges = {}, {}, {}, {}
	local function addWire( bx, by, bz, stateId )
		local key = CellKey( bx, by, bz )
		local wireIndex = byKey[key]
		if wireIndex then return wireIndex end
		wireIndex = #xs + 1
		byKey[key] = wireIndex
		xs[wireIndex], ys[wireIndex], zs[wireIndex] = bx, by, bz
		states[wireIndex], keys[wireIndex] = stateId, key
		return wireIndex
	end

	addWire( startX, startY, startZ, startState )
	local batchLimit = wireBatchCellLimit()
	local function collectNeighbour( bx, by, bz, stateId )
		edges[#edges + 1] = addWire( bx, by, bz, stateId )
	end
	local scanIndex = 1
	while scanIndex <= #xs do
		edgeStarts[scanIndex] = #edges + 1
		visitWireNeighbours( xs[scanIndex], ys[scanIndex], zs[scanIndex], readState, collectNeighbour )
		edgeEnds[scanIndex] = #edges
		if #xs > batchLimit then
			-- Preserve bounded scheduler behavior for pathological networks. The
			-- legacy one-cell relaxation remains a correctness fallback instead of
			-- submitting an oversized transaction that the scheduler would reject.
			WireStats.oversizedFallbacks = WireStats.oversizedFallbacks + 1
			return updateSingleWire( context, readState )
		end
		scanIndex = scanIndex + 1
	end

	-- A 16-level descending bucket queue is a bounded multi-source shortest-path
	-- solve. Each external source seeds its local wire, then every graph edge
	-- attenuates by exactly one; stale lower bucket entries are ignored.
	local powers, buckets = {}, {}
	for power = 1, 15 do buckets[power] = {} end
	for wireIndex = 1, #xs do
		local power = strongestDirectSource( xs[wireIndex], ys[wireIndex], zs[wireIndex], readState )
		powers[wireIndex] = power
		if power > 0 then
			local bucket = buckets[power]
			bucket[#bucket + 1] = wireIndex
		end
	end
	for power = 15, 2, -1 do
		local bucket = buckets[power]
		local nextPower = power - 1
		for bucketIndex = 1, #bucket do
			local wireIndex = bucket[bucketIndex]
			if powers[wireIndex] == power then
				for edgeIndex = edgeStarts[wireIndex], edgeEnds[wireIndex] do
					local neighbourIndex = edges[edgeIndex]
					if powers[neighbourIndex] < nextPower then
						powers[neighbourIndex] = nextPower
						local nextBucket = buckets[nextPower]
						nextBucket[#nextBucket + 1] = neighbourIndex
					end
				end
			end
		end
	end

	local cells = {}
	for wireIndex = 1, #xs do
		local stateId = states[wireIndex]
		local power = powers[wireIndex]
		if wirePower( stateId ) ~= power then
			local nextState = StateWith( stateId, "power", power ) or stateId
			if nextState ~= stateId then
				cells[#cells + 1] = {
					bx = xs[wireIndex], by = ys[wireIndex], bz = zs[wireIndex], stateId = nextState,
				}
			end
		end
	end

	WireStats.settlements = WireStats.settlements + 1
	WireStats.wiresScanned = WireStats.wiresScanned + #xs
	WireStats.wiresChanged = WireStats.wiresChanged + #cells
	if #cells == 0 then
		if inputRevision then
			for wireIndex = 1, #keys do WireSettledRevision[keys[wireIndex]] = inputRevision end
		end
		return nil
	end
	return {
		cells = cells,
		compareCollision = true,
		afterTransaction = markWireNetworkCommitted,
		afterTransactionData = keys,
	}
end

if MC.RegisterBlockUpdateHandler then
	MC.RegisterBlockUpdateHandler( "minecraft:redstone_wire", {
		OnNeighborUpdate = updateWire,
	} )
end

local function installLeverHandler()
	local block = MC.BlockByName and MC.BlockByName["minecraft:lever"] or nil
	if not block then return false end
	block.handlers = block.handlers or {}
	block.handlers.OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV or not MC.SV.ApplyBlockTransaction then return false end
		local stateId = GetBlockState( bx, by, bz )
		if stateName( stateId ) ~= "minecraft:lever" then return false end
		local powered = GetStateProperty( stateId, "powered" ) == true
		local nextState = StateWith( stateId, "powered", not powered ) or stateId
		if nextState == stateId then return false end
		local result = MC.SV.ApplyBlockTransaction( {
			{ bx = bx, by = by, bz = bz, stateId = nextState },
		}, { actor = ply, fx = false, netMode = "bulk", compareCollision = false } )
		local changed = result and result.ok == true and result.changed > 0 or false
		if changed then MC.PlayRedstoneSound( "mc/random/click.ogg", bx, by, bz, 0.3, not powered and 0.6 or 0.5 ) end
		return changed
	end
	return true
end

installLeverHandler()

local function faceAttachedNeighborUpdate( context )
	if not MC.FaceAttachedCanSurvive
		or MC.FaceAttachedCanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
	return { cells = { {
		bx = context.bx, by = context.by, bz = context.bz, stateId = 0,
	} } }
end

if MC.RegisterBlockUpdateHandler then
	MC.RegisterBlockUpdateHandler( "minecraft:lever", {
		OnNeighborUpdate = faceAttachedNeighborUpdate,
	} )
end

local function setPoweredState( bx, by, bz, stateId, powered, actor )
	local nextState = StateWith( stateId, "powered", powered ) or stateId
	if nextState == stateId or not MC.SV or not MC.SV.ApplyBlockTransaction then return false end
	local result = MC.SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = nextState },
	}, { actor = actor, fx = false, netMode = "bulk", compareCollision = false } )
	return result and result.ok == true and result.changed > 0 or false
end

local function buttonDelay( name )
	if name == "minecraft:stone_button" or name == "minecraft:polished_blackstone_button" then return 20 end
	return 30
end

local function installButton( shortName )
	local name = "minecraft:" .. shortName
	local block = MC.BlockByName and MC.BlockByName[name] or nil
	if not block then return end
	block.handlers = block.handlers or {}
	block.handlers.OnUse = function( ply, bx, by, bz )
		if not SERVER or not MC.SV then return false end
		local stateId = GetBlockState( bx, by, bz )
		if stateName( stateId ) ~= name or GetStateProperty( stateId, "powered" ) == true then return false end
		local nextState = StateWith( stateId, "powered", true ) or stateId
		if not setPoweredState( bx, by, bz, stateId, true, ply ) then return false end
		MC.SV.ScheduleBlockTick( bx, by, bz, buttonDelay( name ), MC.BlockUpdateKind.SCHEDULED, nextState )
		return true
	end
	if MC.RegisterBlockUpdateHandler then
		MC.RegisterBlockUpdateHandler( name, {
			OnNeighborUpdate = faceAttachedNeighborUpdate,
			OnScheduledTick = function( context )
				if GetStateProperty( context.stateId, "powered" ) ~= true then return nil end
				return { cells = { {
					bx = context.bx, by = context.by, bz = context.bz,
					stateId = StateWith( context.stateId, "powered", false ) or context.stateId,
				} } }
			end,
		} )
	end
end

for index = 1, #ButtonNames do installButton( ButtonNames[index] ) end

local FacingOffset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
}

local function torchAttachedCell( stateId, bx, by, bz )
	if stateName( stateId ) == "minecraft:redstone_torch" then return bx, by, bz - 1 end
	local facing = FacingOffset[GetStateProperty( stateId, "facing" )]
	if not facing then return bx, by, bz - 1 end
	return bx - facing[1], by - facing[2], bz
end

-- Vanilla torch logic samples only the attachment block: the torch goes out
-- when its support emits power itself or receives direct power (dust on top of
-- or pointing into it, repeater/observer output, an attached lever/button).
-- Sampling RedstoneBestNeighborSignal at the support instead would let every
-- weakly powered block NEXT TO the support re-radiate the torch's own wire
-- signal back into it, so a torch feeding nearby dust extinguishes itself and
-- oscillates forever.
local function torchShouldBeLit( stateId, bx, by, bz )
	local ax, ay, az = torchAttachedCell( stateId, bx, by, bz )
	local towardX, towardY, towardZ = bx - ax, by - ay, bz - az
	local supportState = GetBlockState( ax, ay, az )
	if MC.RedstoneSignalFromState( supportState, ax, ay, az, towardX, towardY, towardZ ) > 0 then return false end
	return conductorSignal( supportState, ax, ay, az, towardX, towardY, towardZ ) <= 0
end

local function torchNeighborUpdate( context )
	local shouldLight = torchShouldBeLit( context.stateId, context.bx, context.by, context.bz )
	if shouldLight == ( GetStateProperty( context.stateId, "lit" ) == true ) then return nil end
	return { schedule = { { delayTicks = 2, expectedStateId = context.stateId } } }
end

local TorchToggleHistory = {}
local TorchBurnedUntil = {}

local function torchBurnoutRemaining( key, logicTick )
	local untilTick = TorchBurnedUntil[key]
	if not untilTick then return 0 end
	if logicTick >= untilTick then
		TorchBurnedUntil[key] = nil
		return 0
	end
	return untilTick - logicTick
end

local function recordTorchOffToggle( key, logicTick )
	local history = TorchToggleHistory[key]
	if not history then history = {}; TorchToggleHistory[key] = history end
	local first = 1
	while first <= #history and logicTick - history[first] > 60 do first = first + 1 end
	if first > 1 then
		local count = #history - first + 1
		for index = 1, count do history[index] = history[index + first - 1] end
		for index = count + 1, #history do history[index] = nil end
	end
	history[#history + 1] = logicTick
	if #history < 8 then return false end
	TorchBurnedUntil[key] = logicTick + 160
	return true
end

local function torchScheduledTick( context )
	local shouldLight = torchShouldBeLit( context.stateId, context.bx, context.by, context.bz )
	local lit = GetStateProperty( context.stateId, "lit" ) == true
	local key = MC.CellKey( context.bx, context.by, context.bz )
	if shouldLight and not lit then
		local remaining = torchBurnoutRemaining( key, context.logicTick )
		if remaining > 0 then return { schedule = { { delayTicks = remaining, expectedStateId = context.stateId } } } end
	elseif not shouldLight and lit then
		local burnedOut = recordTorchOffToggle( key, context.logicTick )
		local nextState = StateWith( context.stateId, "lit", false ) or context.stateId
		local result = { cells = { {
			bx = context.bx, by = context.by, bz = context.bz, stateId = nextState,
		} } }
		if burnedOut then result.schedule = { { delayTicks = 160, expectedStateId = nextState } } end
		return result
	end
	if shouldLight == lit then return nil end
	return { cells = { {
		bx = context.bx, by = context.by, bz = context.bz,
		stateId = StateWith( context.stateId, "lit", shouldLight ) or context.stateId,
	} } }
end

if MC.RegisterBlockUpdateHandler then
	local torchHandler = { OnNeighborUpdate = torchNeighborUpdate, OnScheduledTick = torchScheduledTick }
	MC.RegisterBlockUpdateHandler( "minecraft:redstone_torch", torchHandler )
	MC.RegisterBlockUpdateHandler( "minecraft:redstone_wall_torch", torchHandler )

	MC.RegisterBlockUpdateHandler( "minecraft:redstone_lamp", {
		OnNeighborUpdate = function( context )
			local powered = MC.RedstoneBestNeighborSignal( context.bx, context.by, context.bz ) > 0
			local lit = GetStateProperty( context.stateId, "lit" ) == true
			if powered == lit then return nil end
			if not powered then return { schedule = { { delayTicks = 4, expectedStateId = context.stateId } } } end
			return { cells = { {
				bx = context.bx, by = context.by, bz = context.bz,
				stateId = StateWith( context.stateId, "lit", true ) or context.stateId,
			} } }
		end,
		OnScheduledTick = function( context )
			if MC.RedstoneBestNeighborSignal( context.bx, context.by, context.bz ) > 0 then return nil end
			if GetStateProperty( context.stateId, "lit" ) ~= true then return nil end
			return { cells = { {
				bx = context.bx, by = context.by, bz = context.bz,
				stateId = StateWith( context.stateId, "lit", false ) or context.stateId,
			} } }
		end,
	} )
end

function MC.RedstoneDiagnostics()
	local emitterCount = 0
	for _ in pairs( SignalEmitters ) do emitterCount = emitterCount + 1 end
	return {
		emitters = emitterCount,
		wireSettlements = WireStats.settlements,
		wireScanned = WireStats.wiresScanned,
		wireChanged = WireStats.wiresChanged,
		wireRevisionSkips = WireStats.revisionSkips,
		wireOversizedFallbacks = WireStats.oversizedFallbacks,
		wireHandler = MC.BlockUpdateHandlerForName
			and MC.BlockUpdateHandlerForName( "minecraft:redstone_wire" ) ~= nil or false,
		leverHandler = MC.BlockByName and MC.BlockByName["minecraft:lever"]
			and MC.BlockByName["minecraft:lever"].handlers.OnUse ~= nil or false,
	}
end
