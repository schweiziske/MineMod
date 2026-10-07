-- Minecraft fluid-state decoding and liquid type registry.

MC = MC or {}
MC.Liquid = MC.Liquid or {}

local Liquid = MC.Liquid
local floor = math.floor

local KindsByName = {
	water = "water",
	["minecraft:water"] = "water",
	bubble_column = "water",
	["minecraft:bubble_column"] = "water",
	lava = "lava",
	["minecraft:lava"] = "lava",
}

-- These LiquidBlockContainer implementations always return WATER.getSource(false)
-- without a waterlogged property. Keep their plant model and attach a water layer.
local InherentWaterByName = {
	["minecraft:seagrass"] = true,
	["minecraft:tall_seagrass"] = true,
	["minecraft:kelp"] = true,
	["minecraft:kelp_plant"] = true,
}

local KindByState = {}
local OwnHeightByState = {}
local LevelByState = {}
local FallingByState = {}
local WaterloggedByState = {}

local function statePropertyValue( schema, stateId, propertyName )
	local property = schema and schema.propertyByName and schema.propertyByName[propertyName] or nil
	if not property then return nil end
	local ordinal = stateId - schema.firstStateId
	local valueIndex = floor( ordinal / property.stride ) % property.count + 1
	return property.values[valueIndex]
end

local function liquidKindForBlock( id )
	local block = MC.Blocks and MC.Blocks[id]
	if not block then return nil end
	return KindsByName[block.mcid] or KindsByName[block.name]
end

-- LiquidBlock stores the legacy LEVEL property, but every consumer works from
-- Minecraft's FluidState amount and falling flag:
--   level 0      -> source amount 8
--   level 1..7   -> flowing amount 8 - level
--   level 8..15  -> falling amount 8
-- FluidState#getOwnHeight is amount / 9. Results are indexed by StateId so
-- mesh rebuilds and movement never format block-state strings in hot paths.
local function decodeState( stateId )
	if type( stateId ) ~= "number" then stateId = tonumber( stateId ) or 0 end
	local cachedKind = KindByState[stateId]
	if cachedKind ~= nil then
		return cachedKind or nil,
			OwnHeightByState[stateId] or 0,
			LevelByState[stateId],
			FallingByState[stateId] == true,
			WaterloggedByState[stateId] == true
	end
	if MC.BlockStateRegistryFrozen ~= true then return nil, 0, nil, false, false end

	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local kind = id and liquidKindForBlock( id ) or nil
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local waterlogged = not kind and ( schema and InherentWaterByName[schema.name] == true
		or statePropertyValue( schema, stateId, "waterlogged" ) == true )
	if waterlogged then kind = "water" end
	if not kind then
		KindByState[stateId] = false
		OwnHeightByState[stateId] = 0
		FallingByState[stateId] = false
		WaterloggedByState[stateId] = false
		return nil, 0, nil, false, false
	end

	local level = 0
	local falling = false
	local ownHeight = 8 / 9
	if not waterlogged then
		level = math.Clamp( floor( tonumber( statePropertyValue( schema, stateId, "level" ) ) or 0 ), 0, 15 )
		falling = level >= 8
		local amount = falling and 8 or 8 - level
		ownHeight = amount / 9
	end

	KindByState[stateId] = kind
	OwnHeightByState[stateId] = ownHeight
	LevelByState[stateId] = level
	FallingByState[stateId] = falling
	WaterloggedByState[stateId] = waterlogged
	return kind, ownHeight, level, falling, waterlogged
end

Liquid.DecodeState = decodeState
Liquid.StatePropertyValue = statePropertyValue

function MC.LiquidKind( id )
	return liquidKindForBlock( id )
end

function MC.IsLiquidBlock( id )
	return liquidKindForBlock( id ) ~= nil
end

function MC.LiquidStateMetrics( stateId )
	return decodeState( stateId )
end

function MC.LiquidKindForState( stateId )
	local kind = decodeState( stateId )
	return kind
end

-- True only for a *pure* fluid block (water/lava/bubble_column), never for a
-- water-containing host (including aquatic plants), which keeps its block model.
--
-- This is the single predicate behind three Java rules that must agree, or the
-- player ends up able to mine a fluid but not fill it, or vice versa:
--   * Entity#pick uses ClipContext.Fluid.NONE, and LiquidBlock#getShape is
--     Shapes.empty(), so a fluid block has nothing to aim at -> cannot be mined.
--   * BlockBehaviour.Properties#replaceable is set for LiquidBlock, so placing
--     into a fluid cell overwrites it instead of being refused as occupied.
--   * BucketItem is the only way to take a fluid out, via Fluid.SOURCE_ONLY.
function MC.StateIsFluidBlock( stateId )
	local kind, _, _, _, waterlogged = decodeState( stateId )
	return kind ~= nil and waterlogged ~= true
end

function MC.CellIsFluidBlock( bx, by, bz )
	if not MC.GetBlockState then return false end
	return MC.StateIsFluidBlock( MC.GetBlockState( bx, by, bz ) or 0 )
end

function MC.LiquidOwnHeightForState( stateId )
	local _, ownHeight = decodeState( stateId )
	return ownHeight
end

function MC.IsWaterloggedState( stateId )
	-- Means a block plus water, not necessarily a literal waterlogged property.
	local _, _, _, _, waterlogged = decodeState( stateId )
	return waterlogged == true
end

function MC.LiquidHeightAtCell( bx, by, bz, requiredKind )
	if not MC.GetBlockState then return 0 end
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, ownHeight = decodeState( stateId )
	if not kind or requiredKind and kind ~= requiredKind then return 0 end
	local aboveKind = decodeState( MC.GetBlockState( bx, by, bz + 1 ) or 0 )
	return aboveKind == kind and 1 or ownHeight
end
