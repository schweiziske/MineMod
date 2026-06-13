--[[----------------------------------------------------------------------------
	MC custom block registration.

	Other addons can call MC.RegisterCustomBlock(def) with the same fields used by
	MC.RegisterBlock. Definitions loaded before sh_blocks.lua are queued, then
	drained once the core registry exists.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.CustomBlockBaseID = 61000
MC.CustomBlockMaxID = 2 ^ ( ( MC.Net and MC.Net.ID_BITS ) or 16 ) - 1
MC.CustomBlockDefs = MC.CustomBlockDefs or {}
MC.CustomBlockOrder = MC.CustomBlockOrder or {}
MC.CustomBlockOrderSeen = MC.CustomBlockOrderSeen or {}
MC.CustomNextBlockID = math.floor( tonumber( MC.CustomNextBlockID ) or 0 )
if MC.CustomNextBlockID <= MC.CustomBlockBaseID or MC.CustomNextBlockID > MC.CustomBlockMaxID then
	MC.CustomNextBlockID = MC.CustomBlockBaseID + 1
end
MC.CustomLegacyBlockIDMap = MC.CustomLegacyBlockIDMap or {}
MC.CustomLegacyBlockIDMap[60001] = 61001
MC.CustomLegacyBlockIDMap[70001] = 61001
MC.CustomLegacyBlockIDMap[60010] = 61010
MC.CustomLegacyBlockIDMap[60011] = 61011
MC.CustomLegacyBlockIDMap[60012] = 61012
MC.CustomLegacyBlockIDMap[60013] = 61013
MC.CustomLegacyBlockIDMap[60014] = 61014

function MC.NormalizeLegacyBlockID( id )
	id = math.floor( tonumber( id ) or -1 )
	local mapped = MC.CustomLegacyBlockIDMap and MC.CustomLegacyBlockIDMap[id]
	return mapped or id
end

local function normalizeCustomKey( s )
	s = string.lower( tostring( s or "" ) )
	return string.match( s, "^%s*(.-)%s*$" )
end

local function shallowCopy( src )
	local out = {}
	for k, v in pairs( src or {} ) do out[k] = v end
	return out
end

local function customIDInUse( id )
	if MC.Blocks and MC.Blocks[id] then return true end
	for _, def in pairs( MC.CustomBlockDefs ) do
		if tonumber( def.id ) == id then return true end
	end
	return false
end

local function nextCustomID()
	local id = math.max( MC.CustomBlockBaseID + 1, math.floor( tonumber( MC.CustomNextBlockID ) or ( MC.CustomBlockBaseID + 1 ) ) )
	while id <= MC.CustomBlockMaxID and customIDInUse( id ) do id = id + 1 end
	if id > MC.CustomBlockMaxID then return nil end
	MC.CustomNextBlockID = id + 1
	return id
end

local function customBlockKey( def )
	local name = normalizeCustomKey( def.name or "" )
	local mcid = normalizeCustomKey( def.mcid or ( name ~= "" and ( "mcswep:" .. name ) or "" ) )
	return mcid ~= "" and mcid or name
end

local function prepareCustomDef( def )
	if type( def ) ~= "table" then return nil end
	local out = shallowCopy( def )
	local key = customBlockKey( out )
	if not key or key == "" then return nil end
	out.name = normalizeCustomKey( out.name or string.match( key, "^[^:]+:(.+)$" ) or key )
	out.mcid = normalizeCustomKey( out.mcid or ( "mcswep:" .. out.name ) )
	local explicitID = tonumber( out.id )
	out.id = explicitID and math.floor( explicitID ) or nextCustomID()
	if not out.id or out.id < 0 or out.id > MC.CustomBlockMaxID then
		if MsgN then MsgN( "[MC] custom block '" .. key .. "' has invalid id " .. tostring( out.id ) .. " (max " .. tostring( MC.CustomBlockMaxID ) .. ")" ) end
		return nil
	end
	out.custom = true
	out.creativeCategory = out.creativeCategory or "custom"
	return out, key
end

local function stampCustomMetadata( b, def )
	if not b then return nil end
	b.custom = true
	b.creativeCategory = def.creativeCategory or "custom"
	return b
end

function MC.RegisterCustomBlock( def )
	local prepared, key = prepareCustomDef( def )
	if not prepared then return nil end

	if not MC.CustomBlockOrderSeen[key] then
		MC.CustomBlockOrder[#MC.CustomBlockOrder + 1] = key
		MC.CustomBlockOrderSeen[key] = true
	end
	MC.CustomBlockDefs[key] = prepared

	if MC.RegisterBlock then
		local b = stampCustomMetadata( MC.RegisterBlock( prepared ), prepared )
		if b and MC.RefreshBlockList then MC.RefreshBlockList() end
		return b
	end

	return prepared
end

function MC.RegisterPendingCustomBlocks()
	if not MC.RegisterBlock then return end
	for _, key in ipairs( MC.CustomBlockOrder ) do
		local def = MC.CustomBlockDefs[key]
		if def then stampCustomMetadata( MC.RegisterBlock( def ), def ) end
	end
end

local SLOPE_BOXES = {
	{ 0, 0, 0, 1, 0.25, 1 },
	{ 0, 0.25, 0, 1, 0.5, 0.75 },
	{ 0, 0.5, 0, 1, 0.75, 0.5 },
	{ 0, 0.75, 0, 1, 1, 0.25 },
}

local SLOPE_QUADS = {
	{
		face = 1, tile = "oak_planks", uv = { 0, 0, 16, 16 },
		verts = {
			{ x = 0, y = 0, z = 1, u = 0, v = 0 },
			{ x = 1, y = 0, z = 1, u = 1, v = 0 },
			{ x = 1, y = 1, z = 0, u = 1, v = 1 },
			{ x = 0, y = 1, z = 0, u = 0, v = 1 },
		},
	},
	{
		face = 2, tile = "oak_planks", uv = { 0, 0, 16, 16 },
		verts = {
			{ x = 0, y = 1, z = 0, u = 0, v = 1 },
			{ x = 1, y = 1, z = 0, u = 1, v = 1 },
			{ x = 1, y = 0, z = 0, u = 1, v = 0 },
			{ x = 0, y = 0, z = 0, u = 0, v = 0 },
		},
	},
	{
		face = 6, tile = "oak_planks", uv = { 0, 0, 16, 16 },
		verts = {
			{ x = 0, y = 0, z = 0, u = 0, v = 1 },
			{ x = 1, y = 0, z = 0, u = 1, v = 1 },
			{ x = 1, y = 0, z = 1, u = 1, v = 0 },
			{ x = 0, y = 0, z = 1, u = 0, v = 0 },
		},
	},
	{
		face = 4, tile = "oak_planks", uv = { 0, 0, 16, 16 },
		verts = {
			{ x = 0, y = 1, z = 0, u = 1, v = 1 },
			{ x = 0, y = 0, z = 0, u = 0, v = 1 },
			{ x = 0, y = 0, z = 1, u = 0, v = 0 },
			{ x = 0, y = 0, z = 1, u = 0, v = 0 },
		},
	},
	{
		face = 3, tile = "oak_planks", uv = { 0, 0, 16, 16 },
		verts = {
			{ x = 1, y = 0, z = 0, u = 0, v = 1 },
			{ x = 1, y = 1, z = 0, u = 1, v = 1 },
			{ x = 1, y = 0, z = 1, u = 0, v = 0 },
			{ x = 1, y = 0, z = 1, u = 0, v = 0 },
		},
	},
}

MC.RegisterCustomBlock( {
	id = 61001,
	name = "custom_oak_slope",
	mcid = "mcswep:oak_slope",
	disp = "自定义橡木斜坡",
	creativeCategory = "custom",
	solid = true,
	transparent = false,
	textures = { top = "oak_planks", side = "oak_planks", bottom = "oak_planks" },
	orient = "horizontal_facing",
	shape = "model",
	boxes = SLOPE_BOXES,
	modelQuads = SLOPE_QUADS,
	hardness = 2,
	explosionResistance = 3,
} )

local COLOR_BLOCKS = {
	{ id = 61010, name = "red_color_block", mcid = "mcswep:red_color_block", disp = "自定义红色块", tile = "red_concrete" },
	{ id = 61011, name = "green_color_block", mcid = "mcswep:green_color_block", disp = "自定义绿色块", tile = "lime_concrete" },
	{ id = 61012, name = "blue_color_block", mcid = "mcswep:blue_color_block", disp = "自定义蓝色块", tile = "blue_concrete" },
	{ id = 61013, name = "white_color_block", mcid = "mcswep:white_color_block", disp = "自定义白色块", tile = "white_concrete" },
	{ id = 61014, name = "black_color_block", mcid = "mcswep:black_color_block", disp = "自定义黑色块", tile = "black_concrete" },
}

for _, def in ipairs( COLOR_BLOCKS ) do
	MC.RegisterCustomBlock( {
		id = def.id,
		name = "custom_" .. def.name,
		mcid = def.mcid,
		disp = def.disp,
		creativeCategory = "custom",
		solid = true,
		transparent = false,
		textures = { top = def.tile, side = def.tile, bottom = def.tile },
		hardness = 1.2,
		explosionResistance = 1.2,
	} )
end
