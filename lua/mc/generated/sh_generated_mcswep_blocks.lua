-- Generated/project-owned MCSwep blocks that are not vanilla Minecraft blocks.
-- Loaded after generated vanilla data and before sh_blocks.lua registers it.
MC = MC or {}
MC.GeneratedBlocks = MC.GeneratedBlocks or {}

local MCSWEP_COLOR_BASE_ID = 50000
local MCSWEP_SLOPE_BASE_ID = 52000
local MCSWEP_MAX_BLOCK_ID = 65535
local MCSWEP_COLOR_HUES = 12
local MCSWEP_COLOR_VARIANTS = {
	{ s = 35, v = 95 },
	{ s = 50, v = 95 },
	{ s = 65, v = 95 },
	{ s = 80, v = 95 },
	{ s = 100, v = 95 },
	{ s = 35, v = 75 },
	{ s = 50, v = 75 },
	{ s = 65, v = 75 },
	{ s = 80, v = 75 },
	{ s = 100, v = 75 },
	{ s = 65, v = 55 },
	{ s = 100, v = 55 },
}

local SLOPE_COLLISION_CONVEXES = {
	{
		{ 0, 0, 0 },
		{ 1, 0, 0 },
		{ 0, 1, 0 },
		{ 1, 1, 0 },
		{ 0, 0, 1 },
		{ 1, 0, 1 },
	},
}

local MCSWEP_REQUIRED_SLOPE_NAMES = {
	oak_planks_slope = true,
	oak_log_slope = true,
	stone_slope = true,
	quartz_block_slope = true,
	dirt_slope = true,
	mcswep_color_h000_s035_v095_slope = true,
}

local function generatedName( hue, variant )
	return string.format( "mcswep_color_h%03d_s%03d_v%03d", hue, variant.s, variant.v )
end

local function addGeneratedBlock( def )
	MC.GeneratedBlocks[#MC.GeneratedBlocks + 1] = def
	return def
end

local function generatedDisplayName( source )
	if not source then return nil end
	local names = MC.GeneratedBlockNames or {}
	return source.disp or names[source.mcid] or names[source.name] or source.name
end

local function sourceTextures( source )
	local textures = source and source.textures or nil
	local top = textures and textures.top or source and source.top
	local side = textures and textures.side or source and source.side or top
	local bottom = textures and textures.bottom or source and source.bottom or top
	if not top or not side or not bottom then return nil end
	return { top = top, side = side, bottom = bottom }
end

local function hasTile( name )
	return name ~= nil and MC.GeneratedTiles and MC.GeneratedTiles[name] ~= nil
end

local function isSlopeSource( source )
	if type( source ) ~= "table" then return false end
	if source.solid == false or source.transparent == true or source.shape ~= nil then return false end
	if type( source.name ) ~= "string" or string.match( source.name, "_slope$" ) then return false end
	local textures = sourceTextures( source )
	return textures ~= nil and hasTile( textures.top ) and hasTile( textures.side ) and hasTile( textures.bottom )
end

local function slopeQuads( topTile, sideTile, bottomTile )
	return {
		{
			face = 1, tile = topTile, uv = { 0, 0, 16, 16 },
			verts = {
				{ x = 0, y = 0, z = 1, u = 0, v = 0 },
				{ x = 1, y = 0, z = 1, u = 1, v = 0 },
				{ x = 1, y = 1, z = 0, u = 1, v = 1 },
				{ x = 0, y = 1, z = 0, u = 0, v = 1 },
			},
		},
		{
			face = 2, tile = bottomTile, uv = { 0, 0, 16, 16 },
			verts = {
				{ x = 0, y = 1, z = 0, u = 0, v = 1 },
				{ x = 1, y = 1, z = 0, u = 1, v = 1 },
				{ x = 1, y = 0, z = 0, u = 1, v = 0 },
				{ x = 0, y = 0, z = 0, u = 0, v = 0 },
			},
		},
		{
			face = 6, tile = sideTile, uv = { 0, 0, 16, 16 },
			verts = {
				{ x = 0, y = 0, z = 0, u = 0, v = 1 },
				{ x = 1, y = 0, z = 0, u = 1, v = 1 },
				{ x = 1, y = 0, z = 1, u = 1, v = 0 },
				{ x = 0, y = 0, z = 1, u = 0, v = 0 },
			},
		},
		{
			face = 4, tile = sideTile, uv = { 0, 0, 16, 16 },
			verts = {
				{ x = 0, y = 1, z = 0, u = 1, v = 1 },
				{ x = 0, y = 0, z = 0, u = 0, v = 1 },
				{ x = 0, y = 0, z = 1, u = 0, v = 0 },
				{ x = 0, y = 0, z = 1, u = 0, v = 0 },
			},
		},
		{
			face = 3, tile = sideTile, uv = { 0, 0, 16, 16 },
			verts = {
				{ x = 1, y = 0, z = 0, u = 0, v = 1 },
				{ x = 1, y = 1, z = 0, u = 1, v = 1 },
				{ x = 1, y = 0, z = 1, u = 0, v = 0 },
				{ x = 1, y = 0, z = 1, u = 0, v = 0 },
			},
		},
	}
end

MC.MCSwepColorBlockDefs = {}
for hueIndex = 0, MCSWEP_COLOR_HUES - 1 do
	local hue = hueIndex * 30
	for variantIndex, variant in ipairs( MCSWEP_COLOR_VARIANTS ) do
		local name = generatedName( hue, variant )
		local def = addGeneratedBlock( {
			id = MCSWEP_COLOR_BASE_ID + hueIndex * #MCSWEP_COLOR_VARIANTS + variantIndex - 1,
			name = name,
			mcid = "mcswep:" .. name,
			disp = string.format( "色块 H%03d S%03d V%03d", hue, variant.s, variant.v ),
			solid = true,
			transparent = false,
			creativeCategory = "color_blocks",
			textures = { top = name, side = name, bottom = name },
			hardness = 1.2,
			explosionResistance = 1.2,
		} )
		MC.MCSwepColorBlockDefs[#MC.MCSwepColorBlockDefs + 1] = def
	end
end

MC.MCSwepSlopeBlockDefs = {}
local sourceCount = #MC.GeneratedBlocks
local nextSlopeID = MCSWEP_SLOPE_BASE_ID
for i = 1, sourceCount do
	local source = MC.GeneratedBlocks[i]
	if isSlopeSource( source ) and nextSlopeID <= MCSWEP_MAX_BLOCK_ID then
		local textures = sourceTextures( source )
		local name = source.name .. "_slope"
		local def = addGeneratedBlock( {
			id = nextSlopeID,
			name = name,
			mcid = "mcswep:" .. name,
			disp = ( generatedDisplayName( source ) or source.name ) .. "斜坡",
			solid = true,
			transparent = false,
			creativeCategory = "slopes",
			stateRule = "horizontal_facing",
			placeRule = "look",
			iconSource = source.mcid or source.name,
			shape = "model",
			boxes = { { 0, 0, 0, 1, 1, 1 } },
			modelQuads = slopeQuads( textures.top, textures.side, textures.bottom ),
			collisionConvexes = SLOPE_COLLISION_CONVEXES,
			hardness = source.hardness or 1.5,
			explosionResistance = source.explosionResistance or source.hardness or 1.5,
		} )
		if MCSWEP_REQUIRED_SLOPE_NAMES[name] then def.requiredSlope = true end
		MC.MCSwepSlopeBlockDefs[#MC.MCSwepSlopeBlockDefs + 1] = def
		nextSlopeID = nextSlopeID + 1
	end
end
