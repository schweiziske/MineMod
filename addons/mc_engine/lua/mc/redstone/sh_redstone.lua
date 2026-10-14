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
	"sound/mc/random/click.wav",
	"sound/mc/tile/piston/in.wav",
	"sound/mc/tile/piston/out.wav",
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
		-- The legacy base renderer uses one fixed thin plate mesh and cannot
		-- represent the vanilla up/down state geometry. Always consume the exact
		-- imported blockstate model, including the normally unpowered default.
		if MC.RegisterBlockStateVisual then
			MC.RegisterBlockStateVisual( name, { forceGeneratedVisual = true } )
		end
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

local function redstoneConductor( stateId, bx, by, bz )
	-- Vanilla SLIME_BLOCK keeps the default full collision-shape conductor
	-- predicate even though its translucent imported visual is not classified as
	-- a normal full cube by our renderer/collision abstraction.
	if stateName( stateId ) == "minecraft:slime_block" then return true end
	return fullCube( stateId, bx, by, bz )
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
				if redstoneConductor( conductorState, cx, cy, cz ) then
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
	if not redstoneConductor( stateId, bx, by, bz ) then return 0 end
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
	local canClimb = not redstoneConductor( aboveState, bx, by, bz + 1 )
	for index = 1, 4 do
		local direction = WireDirections[index]
		local nx, ny = bx + direction[1], by + direction[2]
		local neighbourState = readState( nx, ny, bz )
		if IsRedstoneWireState( neighbourState ) then visit( nx, ny, bz, neighbourState ) end
		if redstoneConductor( neighbourState, nx, ny, bz ) then
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

local WireStats = {
	settlements = 0, wiresScanned = 0, wiresChanged = 0,
	-- Retained diagnostic keys for existing tools; whole-network settlement
	-- and revision suppression are no longer part of vanilla wire updates.
	revisionSkips = 0, oversizedFallbacks = 0,
}

function MC.ClearRedstoneWireRuntime()
	for key in pairs(WireStats) do WireStats[key] = 0 end
	if MC.ClearRedstoneLogicRuntime then MC.ClearRedstoneLogicRuntime() end
end

-- Build the two-ring notification stencil once. The old implementation
-- rebuilt a coordinate set and nested closures for every dust callback.
local WireFanoutOffsets = {}
do
	local seen = {}
	local function add(dx, dy, dz)
		local key = dx .. "," .. dy .. "," .. dz
		if seen[key] then return end
		seen[key] = true
		WireFanoutOffsets[#WireFanoutOffsets + 1] = { dx, dy, dz }
	end
	for i = 1, 6 do
		local d = NeighborDirections[i]
		add(d[1], d[2], d[3])
		for j = 1, 6 do
			local n = NeighborDirections[j]
			add(d[1] + n[1], d[2] + n[2], d[3] + n[3])
		end
	end
end

local function wireFanout(bx, by, bz)
	-- The stencil is immutable, so this hot path only allocates the result
	-- required by the scheduler.
	local updates = {}
	for index = 1, #WireFanoutOffsets do
		local offset = WireFanoutOffsets[index]
		updates[index] = { bx = bx + offset[1], by = by + offset[2], bz = bz + offset[3] }
	end
	return updates
end

local function updateWire(context)
	local bx, by, bz = context.bx, context.by, context.bz
	-- Match the ordinary Java evaluator: one local relaxation, then neighbour
	-- notifications. A connected network is never enumerated by one callback.
	local stateCache = {}
	local function readState(x, y, z)
		local key = CellKey(x, y, z)
		local state = stateCache[key]
		if state == nil then
			state = GetBlockState(x, y, z)
			stateCache[key] = state
		end
		return state
	end
	local power = strongestDirectSource(bx, by, bz, readState)
	if power < 15 then
		local incoming = 0
		visitWireNeighbours(bx, by, bz, readState, function(_, _, _, state)
			incoming = math.max(incoming, wirePower(state))
		end)
		power = math.max(power, incoming - 1)
	end
	WireStats.settlements = WireStats.settlements + 1
	WireStats.wiresScanned = WireStats.wiresScanned + 1
	if wirePower(context.stateId) == power then return nil end
	WireStats.wiresChanged = WireStats.wiresChanged + 1
	return {
		cells = {{bx=bx, by=by, bz=bz, stateId=StateWith(context.stateId, "power", power)}},
		updates = wireFanout(bx, by, bz),
		blockUpdates = false, compareCollision = true,
		-- Iterative dust decay is bounded by callback/cell budgets. It must not
		-- lose the remainder of an electrical update at the cascade-depth cap.
		continuePropagation = true,
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
		if changed then MC.PlayRedstoneSound( "mc/random/click.wav", bx, by, bz, 0.3, not powered and 0.6 or 0.5 ) end
		return changed
	end
	return true
end

installLeverHandler()

local function faceAttachedNeighborUpdate( context )
	if not MC.FaceAttachedCanSurvive
		or MC.FaceAttachedCanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
	return { dropResources = true, cells = { {
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
		MC.SV.ScheduleBlockTick( bx, by, bz, buttonDelay( name ), MC.BlockUpdateKind.SCHEDULED, nextState, {matchBlock=true} )
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
	return { schedule = { { delayTicks = 2, expectedStateId = context.stateId, matchBlock = true } } }
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
		if remaining > 0 then return { schedule = { { delayTicks = remaining, expectedStateId = context.stateId, matchBlock = true } } } end
	elseif not shouldLight and lit then
		local burnedOut = recordTorchOffToggle( key, context.logicTick )
		local nextState = StateWith( context.stateId, "lit", false ) or context.stateId
		local result = { cells = { {
			bx = context.bx, by = context.by, bz = context.bz, stateId = nextState,
		} } }
		if burnedOut then result.schedule = { { delayTicks = 160, expectedStateId = nextState, matchBlock = true } } end
		return result
	end
	if shouldLight == lit then return nil end
	return { cells = { {
		bx = context.bx, by = context.by, bz = context.bz,
		stateId = StateWith( context.stateId, "lit", shouldLight ) or context.stateId,
	} } }
end

local function redstoneLampVisual( stateId )
	return {
		forceGeneratedVisual = true,
		lightEmission = GetStateProperty( stateId, "lit" ) == true and 15 or 0,
	}
end

MC.RegisterBlockStateVisual( "minecraft:redstone_lamp", { Resolve = redstoneLampVisual } )

-- Shared equivalent of RedstoneLampBlock.getStateForPlacement: prediction and
-- authority both place the lamp with its final initial LIT value, avoiding a
-- false-state write followed by a second corrective transaction.
function MC.ResolveRedstonePlacementState( stateId, bx, by, bz )
	local name = stateName( stateId )
	if name == "minecraft:observer" then
		-- Imported schema default is powered=true, while vanilla onPlace always
		-- starts/reset observers unpowered and only scheduled ticks create pulses.
		return StateWith( stateId, "powered", false ) or stateId
	end
	if name ~= "minecraft:redstone_lamp" then return stateId end
	local powered = MC.RedstoneBestNeighborSignal( bx, by, bz ) > 0
	return StateWith( stateId, "lit", powered ) or stateId
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
			if not powered then return { schedule = { { delayTicks = 4, expectedStateId = context.stateId, matchBlock = true } } } end
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
