-- Project-owned generated colour and slope blocks.
-- Loaded after sh_blocks.lua so generated slopes can share one compact model.
MC = MC or {}

local COLOR_BASE_ID = 50000
local SLOPE_BASE_ID = 52000
local MAX_BLOCK_ID = 65535
local COLOR_HUES = 12
local COLOR_VARIANTS = {
	{ 35, 95 }, { 50, 95 }, { 65, 95 }, { 80, 95 }, { 100, 95 },
	{ 35, 75 }, { 50, 75 }, { 65, 75 }, { 80, 75 }, { 100, 75 },
	{ 65, 55 }, { 100, 55 },
}

local SLOPE_COLLISION_CONVEXES = {
	{
		{ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 },
		{ 1, 1, 0 }, { 0, 0, 1 }, { 1, 0, 1 },
	},
}

-- surface slots: 1=top, 2=bottom, 3=side. Vertices are flat x/y/z/u/v
-- arrays so hundreds of generated slopes do not allocate vertex hash tables.
local SLOPE_GEOMETRY = {
	compact = true,
	-- Broad bounds only. Physics, picking and outlines use the wedge convex.
	boxes = { { 0, 0, 0, 1, 1, 1 } },
	modelQuads = {
		{ face = 1, surface = 1, uv = { 0, 0, 16, 16 }, verts = {
			0, 0, 1, 0, 0,  1, 0, 1, 1, 0,  1, 1, 0, 1, 1,  0, 1, 0, 0, 1,
		} },
		{ face = 2, surface = 2, uv = { 0, 0, 16, 16 }, verts = {
			0, 1, 0, 0, 1,  1, 1, 0, 1, 1,  1, 0, 0, 1, 0,  0, 0, 0, 0, 0,
		} },
		{ face = 6, surface = 3, uv = { 0, 0, 16, 16 }, verts = {
			0, 0, 0, 0, 1,  1, 0, 0, 1, 1,  1, 0, 1, 1, 0,  0, 0, 1, 0, 0,
		} },
		{ face = 4, surface = 3, uv = { 0, 0, 16, 16 }, verts = {
			0, 1, 0, 1, 1,  0, 0, 0, 0, 1,  0, 0, 1, 0, 0,  0, 0, 1, 0, 0,
		} },
		{ face = 3, surface = 3, uv = { 0, 0, 16, 16 }, verts = {
			1, 0, 0, 0, 1,  1, 1, 0, 1, 1,  1, 0, 1, 0, 0,  1, 0, 1, 0, 0,
		} },
	},
}

local REQUIRED_SLOPES = {
	oak_planks_slope = true,
	oak_log_slope = true,
	stone_slope = true,
	quartz_block_slope = true,
	dirt_slope = true,
	mcswep_color_h000_s035_v095_slope = true,
}

local function generatedName( hue, saturation, value )
	return string.format( "mcswep_color_h%03d_s%03d_v%03d", hue, saturation, value )
end

-- Names are templates of mc_engine's dictionary: the colour components, and
-- for a slope the name of the block it is cut from.
local function colorNameVars( hue, saturation, value )
	return { hue = string.format( "%03d", hue ), saturation = string.format( "%03d", saturation ),
		value = string.format( "%03d", value ) }
end

local function slopeNameVars( source )
	return { block = { key = source.translationKey, vars = source.translationVars } }
end

local function isSlopeSource( block )
	if not block or block.custom == true then return false end
	if block.solid == false or block.transparent == true or block.shape ~= nil then return false end
	if type( block.name ) ~= "string" or string.match( block.name, "_slope$" ) then return false end
	return block.top ~= nil and block.side ~= nil and block.bottom ~= nil
end

local sourceIds = {}
for _, id in ipairs( MC.BlockList or {} ) do
	local block = MC.Blocks[id]
	if block and string.StartWith( block.mcid or "", "minecraft:" ) then sourceIds[#sourceIds + 1] = id end
end

local colorCount = 0
for hueIndex = 0, COLOR_HUES - 1 do
	local hue = hueIndex * 30
	for variantIndex = 1, #COLOR_VARIANTS do
		local variant = COLOR_VARIANTS[variantIndex]
		local name = generatedName( hue, variant[1], variant[2] )
		local tile = MC.GeneratedTiles and MC.GeneratedTiles[name] or 0
		local blockId = COLOR_BASE_ID + hueIndex * #COLOR_VARIANTS + variantIndex - 1
		MC.RegisterBlock( {
			id = blockId,
			name = name,
			mcid = "mcswep:" .. name,
			translationKey = "block.mcswep.generated_color",
			translationVars = colorNameVars( hue, variant[1], variant[2] ),
			solid = true,
			transparent = false,
			creativeCategory = "color_blocks",
			top = tile,
			side = tile,
			bottom = tile,
			hardness = 1.2,
			explosionResistance = 1.2,
		} )
		sourceIds[#sourceIds + 1] = blockId
		colorCount = colorCount + 1
	end
end

local slopeCount = 0
local nextSlopeID = SLOPE_BASE_ID
for index = 1, #sourceIds do
	local source = MC.Blocks[sourceIds[index]]
	if isSlopeSource( source ) and nextSlopeID <= MAX_BLOCK_ID then
		local name = source.name .. "_slope"
		local block = MC.RegisterBlock( {
			id = nextSlopeID,
			name = name,
			mcid = "mcswep:" .. name,
			translationKey = "block.mcswep.generated_slope",
			translationVars = slopeNameVars( source ),
			solid = true,
			transparent = false,
			creativeCategory = "slopes",
			stateRule = "stairs",
			placeRule = "look",
			iconSource = source.mcid or source.name,
			shape = "model",
			top = source.top,
			side = source.side,
			bottom = source.bottom,
			generatedGeometry = SLOPE_GEOMETRY,
			modelSurfaces = {
				MC.PackBlockModelSurface( source.top, 0 ),
				MC.PackBlockModelSurface( source.bottom, 0 ),
				MC.PackBlockModelSurface( source.side, 0 ),
			},
			generatedCollisionConvexes = SLOPE_COLLISION_CONVEXES,
			hardness = source.hardness or 1.5,
			explosionResistance = source.explosionResistance or source.hardness or 1.5,
		} )
		if REQUIRED_SLOPES[name] then block.requiredSlope = true end
		slopeCount = slopeCount + 1
		nextSlopeID = nextSlopeID + 1
	end
end

MC.GeneratedMCSwepBlockStats = {
	colors = colorCount,
	slopes = slopeCount,
	sharedSlopeGeometry = SLOPE_GEOMETRY,
}
MC.RefreshBlockList()
