--[[----------------------------------------------------------------------------
	Water FluidState helpers for server spreading.

	Source references:
	  out/net/minecraft/world/level/material/FlowingFluid.java
	  out/net/minecraft/world/level/material/WaterFluid.java
	  out/net/minecraft/world/level/block/LiquidBlock.java
	  out/net/minecraft/world/level/block/SimpleWaterloggedBlock.java
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}
MC.WaterSpread = MC.WaterSpread or {}

local Water = MC.WaterSpread
local Liquid = MC.Liquid
local floor = math.floor

Water.TICK_DELAY = 5
Water.DROP_OFF = 1
Water.SLOPE_DISTANCE = 4

local cvSourceConversion = CreateConVar( "mc_water_source_conversion", "1", FCVAR_ARCHIVE,
	"Allow two adjacent water sources above solid/source support to form a new source." )

local WaterStates = {}
local CanHoldAnyByState = {}
local CanPlaceWaterByState = {}

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

local function propertyValue( schema, stateId, name )
	local property = schema and schema.propertyByName and schema.propertyByName[name] or nil
	if not property then return nil end
	return property.values[propertyIndex( schema, stateId, property )]
end

local function stateWithPropertyIndex( schema, stateId, property, targetIndex )
	local currentIndex = propertyIndex( schema, stateId, property )
	return stateId + ( targetIndex - currentIndex ) * property.stride
end

local function waterSchema()
	return MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:water"] or nil
end

function Water.StateForLevel( level )
	level = math.Clamp( floor( tonumber( level ) or 0 ), 0, 15 )
	local cached = WaterStates[level]
	if cached ~= nil then return cached or nil end
	local schema = waterSchema()
	local property = schema and schema.propertyByName and schema.propertyByName.level or nil
	if not schema or not property then return nil end
	local targetIndex
	for index = 1, property.count do
		if property.values[index] == level then targetIndex = index break end
	end
	if not targetIndex then WaterStates[level] = false return nil end
	local stateId = stateWithPropertyIndex( schema, schema.defaultStateId, property, targetIndex )
	WaterStates[level] = stateId
	return stateId
end

function Water.AirState()
	local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:air"] or nil
	return schema and schema.defaultStateId or 0
end

-- Returns: isWater, amount, falling, source, waterlogged, legacyLevel.
function Water.Metrics( stateId )
	local kind, _, level, falling, waterlogged = Liquid.DecodeState( stateId )
	if kind ~= "water" then return false, 0, false, false, false, nil end
	level = floor( tonumber( level ) or 0 )
	local source = waterlogged == true or level == 0
	local amount = source and 8 or falling and 8 or math.Clamp( 8 - level, 1, 7 )
	return true, amount, falling == true, source, waterlogged == true, level
end

function Water.BlockStateForFluid( amount, falling, source )
	if source then return Water.StateForLevel( 0 ) end
	amount = math.Clamp( floor( tonumber( amount ) or 0 ), 1, 8 )
	if falling then return Water.StateForLevel( 8 ) end
	return Water.StateForLevel( 8 - math.min( amount, 8 ) )
end

local function canWaterlogState( stateId, schema )
	local cached = CanPlaceWaterByState[stateId]
	if cached ~= nil then return cached end
	local property = schema and schema.propertyByName and schema.propertyByName.waterlogged or nil
	if not property or propertyValue( schema, stateId, "waterlogged" ) == true then
		CanPlaceWaterByState[stateId] = false
		return false
	end
	-- SlabBlock overrides SimpleWaterloggedBlock for DOUBLE slabs.
	if propertyValue( schema, stateId, "type" ) == "double" then
		CanPlaceWaterByState[stateId] = false
		return false
	end
	CanPlaceWaterByState[stateId] = true
	return true
end

function Water.CanPlaceWater( stateId )
	return canWaterlogState( stateId, schemaForState( stateId ) )
end

function Water.WaterloggedState( stateId )
	local schema = schemaForState( stateId )
	if not canWaterlogState( stateId, schema ) then return nil end
	local property = schema.propertyByName.waterlogged
	local targetIndex = property.valueIndex and property.valueIndex["true"] or nil
	if not targetIndex then
		for index = 1, property.count do
			if property.values[index] == true then targetIndex = index break end
		end
	end
	if not targetIndex then return nil end
	local nextStateId = stateWithPropertyIndex( schema, stateId, property, targetIndex )
	-- CandleBlock and CampfireBlock extinguish while accepting water. The project
	-- already models the same generic waterlogged+lit invariant.
	local lit = schema.propertyByName.lit
	if lit and propertyValue( schema, nextStateId, "lit" ) == true then
		local falseIndex = lit.valueIndex and lit.valueIndex["false"] or nil
		if falseIndex then nextStateId = stateWithPropertyIndex( schema, nextStateId, lit, falseIndex ) end
	end
	return nextStateId
end

function Water.CanHoldAny( stateId, bx, by, bz )
	if Water.WorldCellBlocked and Water.WorldCellBlocked( bx, by, bz ) then return false end
	local cached = CanHoldAnyByState[stateId]
	if cached ~= nil then return cached end
	local schema = schemaForState( stateId )
	if not schema then return false end
	-- LiquidBlockContainer is considered before blocksMotion in FlowingFluid.
	if schema.propertyByName and schema.propertyByName.waterlogged then
		CanHoldAnyByState[stateId] = true
		return true
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

function Water.CanHoldSpecific( stateId )
	local schema = schemaForState( stateId )
	if schema and schema.propertyByName and schema.propertyByName.waterlogged then
		return canWaterlogState( stateId, schema )
	end
	return true
end

function Water.CanConvertToSource()
	return not cvSourceConversion or cvSourceConversion:GetBool()
end

function Water.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face )
	if Water.WorldCanTraverse and not Water.WorldCanTraverse( sx, sy, sz, tx, ty, tz, face ) then return false end
	return Liquid.CanPassThroughWall
		and Liquid.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face ) == true
end

function Water.CanMaybePassThrough( getState, sx, sy, sz, face, tx, ty, tz )
	if MC.SV.WorldBoundsOK and not MC.SV.WorldBoundsOK( tx, ty, tz ) then return false end
	local sourceStateId = getState( sx, sy, sz )
	local targetStateId = getState( tx, ty, tz )
	local targetWater, _, _, targetSource = Water.Metrics( targetStateId )
	if targetWater and targetSource then return false end
	return Water.CanHoldAny( targetStateId, tx, ty, tz )
		and Water.CanPassThroughWall( sourceStateId, sx, sy, sz, targetStateId, tx, ty, tz, face )
end

function Water.CanPassThrough( getState, sx, sy, sz, face, tx, ty, tz )
	if not Water.CanMaybePassThrough( getState, sx, sy, sz, face, tx, ty, tz ) then return false end
	return Water.CanHoldSpecific( getState( tx, ty, tz ) )
end

function Water.TargetCanBeReplaced( stateId )
	local kind = Liquid.DecodeState( stateId )
	return kind == nil
end

function Water.PlaceFluidInState( targetStateId, amount, falling, source )
	local waterlogged = Water.WaterloggedState( targetStateId )
	if waterlogged then return waterlogged end
	return Water.BlockStateForFluid( amount, falling, source )
end

function Water.StateIsSolid( stateId, bx, by, bz )
	if Water.WorldCellBlocked and Water.WorldCellBlocked( bx, by, bz ) then return true end
	return Liquid.StateSolid and Liquid.StateSolid( stateId, bx, by, bz ) == true or false
end
