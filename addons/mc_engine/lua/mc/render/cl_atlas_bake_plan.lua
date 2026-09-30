-- Pure Lua planning: validate once, then consume parallel numeric arrays.
MC = MC or {}
MC.AtlasBakePlan = {}
local P = MC.AtlasBakePlan
P.VERSION = 1
local floor = math.floor
local FIELDS = { "COLS", "ROWS", "TILE", "PAD", "STRIDE", "W", "H" }
local KINDS = { empty = 0, image = 1, overlay = 2, solid = 3, missing = 4 }

local function integer( value, low, high )
	return type( value ) == "number" and value == floor( value ) and value >= low and value <= high
end

function P.New( recipe, layout, tiles )
	if type( recipe ) ~= "table" or recipe.version ~= 1 or type( recipe.layout ) ~= "table"
		or type( recipe.sources ) ~= "table" or type( recipe.tiles ) ~= "table"
		or type( recipe.revision ) ~= "string" or not recipe.revision:match( "^[a-f0-9]+$" ) or #recipe.revision ~= 64 then
		return nil, "invalid_recipe"
	end
	for i = 1, #FIELDS do
		local key = FIELDS[i]
		if recipe.layout[key] ~= layout[key] then return nil, "layout_mismatch_" .. key end
	end
	if not integer( layout.W, 1, 4096 ) or not integer( layout.H, 1, 4096 )
		or not integer( layout.COLS, 1, 64 ) or not integer( layout.TILE, 1, 128 )
		or not integer( layout.PAD, 1, 16 ) or layout.STRIDE ~= layout.TILE + layout.PAD * 2 then
		return nil, "unsupported_layout"
	end
	local count, sourceCount = #recipe.tiles, #recipe.sources
	if count < 1 or count > 4096 or sourceCount < 1 or sourceCount > 4096 then return nil, "recipe_too_large" end
	local known = 0
	for _ in pairs( tiles ) do known = known + 1 end
	if count ~= known then return nil, "tile_catalog_changed" end
	local p = { count = count, sourceCount = sourceCount, revision = recipe.revision, width = layout.W, height = layout.H,
		tile = layout.TILE, pad = layout.PAD, stride = layout.STRIDE,
		paths = {}, hashes = {}, widths = {}, heights = {}, us = {}, vs = {},
		u0 = {}, v0 = {}, u1 = {}, v1 = {}, left = {}, right = {}, top = {}, bottom = {},
		x = {}, y = {}, kind = {}, source = {}, overlay = {}, red = {}, green = {}, blue = {} }
	local paths, pixels = {}, 0
	for i = 1, sourceCount do
		local s = recipe.sources[i]
		if type( s ) ~= "table" or type( s[1] ) ~= "string" or #s[1] > 240
			or not s[1]:match( "^mc/atlas_sources/vanilla/[a-z0-9_/]+%.png$" ) or paths[s[1]]
			or not integer( s[2], 1, 4096 ) or not integer( s[3], 1, 4096 )
			or type( s[4] ) ~= "string" or #s[4] ~= 64 or not s[4]:match( "^[a-f0-9]+$" ) then
			return nil, "invalid_source_" .. i
		end
		pixels = pixels + s[2] * s[3]
		if pixels > 16777216 then return nil, "source_pixel_budget" end
		paths[s[1]] = true
		p.paths[i], p.hashes[i], p.widths[i], p.heights[i] = s[1], s[4], s[2], s[3]
		local side = math.min( s[2], s[3] )
		p.us[i], p.vs[i] = side / s[2], side / s[3]
	end
	for i = 1, count do
		local row = recipe.tiles[i]
		if type( row ) ~= "table" or row[2] ~= i - 1 or tiles[row[1]] ~= i - 1 then return nil, "invalid_tile_" .. i end
		local kind = KINDS[row[3]]
		if kind == nil or not integer( row[4], 0, sourceCount ) or not integer( row[8], 0, sourceCount )
			or not integer( row[5], 0, 255 ) or not integer( row[6], 0, 255 ) or not integer( row[7], 0, 255 )
			or ( ( kind == 1 or kind == 2 ) and row[4] == 0 ) or ( kind == 2 and row[8] == 0 ) then
			return nil, "invalid_tile_recipe_" .. i
		end
		local x, y = ( i - 1 ) % layout.COLS * layout.STRIDE, floor( ( i - 1 ) / layout.COLS ) * layout.STRIDE
		if x + layout.STRIDE > layout.W or y + layout.STRIDE > layout.H then return nil, "tile_outside_atlas" end
		p.x[i], p.y[i], p.kind[i], p.source[i], p.overlay[i] = x, y, kind, row[4], row[8]
		p.red[i], p.green[i], p.blue[i] = row[5], row[6], row[7]
	end
	return p
end
