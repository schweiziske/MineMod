--[[----------------------------------------------------------------------------
	Lava FluidState helpers for server spreading.

	Source references:
	  out/net/minecraft/world/level/material/FlowingFluid.java
	  out/net/minecraft/world/level/material/LavaFluid.java
	  out/net/minecraft/world/level/block/LiquidBlock.java
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}
MC.LavaSpread = MC.LavaSpread or {}

local Lava = MC.LavaSpread
local Liquid = MC.Liquid
local floor = math.floor

-- This addon has no ultra-warm dimension, so use vanilla overworld lava rules.
Lava.TICK_DELAY = 30
Lava.DROP_OFF = 2
Lava.SLOPE_DISTANCE = 2

local LavaStates = {}
local CanHoldAnyByState = {}

local ExcludedHolders = {
	["minecraft:ladder"] = true,
	["minecraft:sugar_cane"] = true,
	["minecraft:bubble_column"] = true,
	["minecraft:nether_portal"] = true,
	["minecraft:end_portal"] = true,
	["minecraft:end_gateway"] = true,
	["minecraft:structure_void"] = true,
}

local function schemaForState( stateId )
	return MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
end

local function propertyIndex( schema, stateId, property )
	return floor( ( stateId - schema.firstStateId ) / property.stride ) % property.count + 1
end

local function stateWithPropertyIndex( schema, stateId, property, targetIndex )
	local currentIndex = propertyIndex( schema, stateId, property )
	return stateId + ( targetIndex - currentIndex ) * property.stride
end

local function lavaSchema()
	return MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:lava"] or nil
end

function Lava.StateForLevel( level )
	level = math.Clamp( floor( tonumber( level ) or 0 ), 0, 15 )
	local cached = LavaStates[level]
	if cached ~= nil then return cached or nil end
	local schema = lavaSchema()
	local property = schema and schema.propertyByName and schema.propertyByName.level or nil
	if not schema or not property then return nil end
	local targetIndex
	for index = 1, property.count do
		if property.values[index] == level then targetIndex = index break end
	end
	if not targetIndex then LavaStates[level] = false return nil end
	local stateId = stateWithPropertyIndex( schema, schema.defaultStateId, property, targetIndex )
	LavaStates[level] = stateId
	return stateId
end

function Lava.AirState()
	local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:air"] or nil
	return schema and schema.defaultStateId or 0
end

-- Returns: isLava, amount, falling, source, legacyLevel.
function Lava.Metrics( stateId )
	local kind, _, level, falling = Liquid.DecodeState( stateId )
	if kind ~= "lava" then return false, 0, false, false, nil end
	level = floor( tonumber( level ) or 0 )
	local source = level == 0
	local amount = source and 8 or falling and 8 or math.Clamp( 8 - level, 1, 7 )
	return true, amount, falling == true, source, level
end

function Lava.BlockStateForFluid( amount, falling, source )
	if source then return Lava.StateForLevel( 0 ) end
	amount = math.Clamp( floor( tonumber( amount ) or 0 ), 1, 8 )
	if falling then return Lava.StateForLevel( 8 ) end
	return Lava.StateForLevel( 8 - math.min( amount, 8 ) )
end

function Lava.CanHoldAny( stateId, bx, by, bz )
	if Lava.WorldCellBlocked and Lava.WorldCellBlocked( bx, by, bz ) then return false end
	local cached = CanHoldAnyByState[stateId]
	if cached ~= nil then return cached end
	local schema = schemaForState( stateId )
	if not schema then return false end
	-- Lava cannot occupy SimpleWaterloggedBlock containers.
	if schema.propertyByName and schema.propertyByName.waterlogged then
		CanHoldAnyByState[stateId] = false
		return false
	end
	local name = schema.name
	if ExcludedHolders[name] or string.match( name, "_door$" ) or string.match( name, "_sign$" ) then
		CanHoldAnyByState[stateId] = false
		return false
	end
	local blocksMotion = Liquid.StateBlocksMotion and Liquid.StateBlocksMotion( stateId, bx, by, bz ) == true
	CanHoldAnyByState[stateId] = not blocksMotion
	return not blocksMotion
end

function Lava.CanHoldSpecific( stateId )
	local schema = schemaForState( stateId )
	return not ( schema and schema.propertyByName and schema.propertyByName.waterlogged )
end

function Lava.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face )
	if Lava.WorldCanTraverse and not Lava.WorldCanTraverse( sx, sy, sz, tx, ty, tz, face ) then return false end
	return Liquid.CanPassThroughWall
		and Liquid.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face ) == true
end

function Lava.CanMaybePassThrough( getState, sx, sy, sz, face, tx, ty, tz )
	if MC.SV.WorldBoundsOK and not MC.SV.WorldBoundsOK( tx, ty, tz ) then return false end
	local sourceStateId = getState( sx, sy, sz )
	local targetStateId = getState( tx, ty, tz )
	local targetLava, _, _, targetSource = Lava.Metrics( targetStateId )
	if targetLava and targetSource then return false end
	return Lava.CanHoldAny( targetStateId, tx, ty, tz )
		and Lava.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face )
end

function Lava.CanPassThrough( getState, sx, sy, sz, face, tx, ty, tz )
	if not Lava.CanMaybePassThrough( getState, sx, sy, sz, face, tx, ty, tz ) then return false end
	return Lava.CanHoldSpecific( getState( tx, ty, tz ) )
end

function Lava.TargetCanBeReplaced( stateId )
	local kind = Liquid.DecodeState( stateId )
	return kind == nil
end

function Lava.PlaceFluidInState( _, amount, falling, source )
	return Lava.BlockStateForFluid( amount, falling, source )
end

function Lava.StateIsSolid( stateId, bx, by, bz )
	if Lava.WorldCellBlocked and Lava.WorldCellBlocked( bx, by, bz ) then return true end
	return Liquid.StateSolid and Liquid.StateSolid( stateId, bx, by, bz ) == true or false
end
