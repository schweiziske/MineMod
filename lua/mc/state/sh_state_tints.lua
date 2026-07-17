-- Minecraft block-color/tint dispatch.
--
-- tintindex belongs to a baked model face; the block decides what that index
-- means for its current state. The renderer consumes a compact byte code so
-- GPU payload meshes do not need RGB strings/tables or per-vertex resolvers.

MC = MC or {}

MC.BlockTintResolvers = MC.BlockTintResolvers or {}

local floor = math.floor
local TintCodeCache = {}

local REDSTONE_FIRST = 1       -- 1..16 => power 0..15
local STEM_FIRST = 17          -- 17..24 => age 0..7
local ATTACHED_STEM = 25

local function normalizeBlockName( name )
	name = string.lower( string.match( tostring( name or "" ), "^%s*(.-)%s*$" ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return name
end

function MC.RegisterBlockTintResolver( blockName, resolver )
	blockName = normalizeBlockName( blockName )
	if not blockName or type( resolver ) ~= "function" then return nil, "invalid_tint_resolver" end
	MC.BlockTintResolvers[blockName] = resolver
	TintCodeCache = {}
	return resolver
end

function MC.ClearBlockTintCache()
	TintCodeCache = {}
end

function MC.BlockStateTintCode( stateId, blockId, tintIndex )
	tintIndex = floor( tonumber( tintIndex ) or -1 )
	if tintIndex < 0 then return 0 end
	stateId = floor( tonumber( stateId ) or -1 )
	if stateId < 0 then return 0 end

	local byTint = TintCodeCache[stateId]
	if byTint and byTint[tintIndex] ~= nil then return byTint[tintIndex] end
	if not byTint then
		byTint = {}
		TintCodeCache[stateId] = byTint
	end

	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local name = schema and schema.name or nil
	local code = 0
	if name == "minecraft:redstone_wire" then
		local power = MC.GetStateProperty and MC.GetStateProperty( stateId, "power" ) or 0
		code = REDSTONE_FIRST + math.max( 0, math.min( 15, floor( tonumber( power ) or 0 ) ) )
	elseif name == "minecraft:pumpkin_stem" or name == "minecraft:melon_stem" then
		local age = MC.GetStateProperty and MC.GetStateProperty( stateId, "age" ) or 0
		code = STEM_FIRST + math.max( 0, math.min( 7, floor( tonumber( age ) or 0 ) ) )
	elseif name == "minecraft:attached_pumpkin_stem" or name == "minecraft:attached_melon_stem" then
		code = ATTACHED_STEM
	else
		local resolver = name and MC.BlockTintResolvers[name] or nil
		if resolver then
			code = math.max( 0, math.min( 255, floor( tonumber( resolver( stateId, blockId, tintIndex, schema ) ) or 0 ) ) )
		end
	end

	byTint[tintIndex] = code
	return code
end

function MC.BlockTintRGB( code )
	code = floor( tonumber( code ) or 0 )
	if code >= REDSTONE_FIRST and code < REDSTONE_FIRST + 16 then
		local power = code - REDSTONE_FIRST
		local f = power / 15
		local r = power == 0 and 0.3 or f * 0.6 + 0.4
		local g = math.max( 0, f * f * 0.7 - 0.5 )
		local b = math.max( 0, f * f * 0.6 - 0.7 )
		return floor( r * 255 + 0.5 ), floor( g * 255 + 0.5 ), floor( b * 255 + 0.5 )
	end
	if code >= STEM_FIRST and code < STEM_FIRST + 8 then
		local age = code - STEM_FIRST
		return age * 32, 255 - age * 8, age * 4
	end
	if code == ATTACHED_STEM then return 224, 199, 28 end
	return 255, 255, 255
end

MC.BlockTintCode = {
	REDSTONE_FIRST = REDSTONE_FIRST,
	STEM_FIRST = STEM_FIRST,
	ATTACHED_STEM = ATTACHED_STEM,
}
