--[[----------------------------------------------------------------------------
    Minecraft inventory UI theme and low-allocation drawing helpers.

    The container textures are the visual system.  This file only supplies the
    pixel-font fallback, nearest-neighbour texture drawing and semantic colors;
    layout and inventory state stay in the screen/slot modules.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI

UI.Colors = UI.Colors or {
	overlay = Color( 0, 0, 0, 105 ),
	text = Color( 255, 255, 255, 255 ),
	textShadow = Color( 0, 0, 0, 255 ),
	textDim = Color( 170, 170, 170, 255 ),
	tooltipBackground = Color( 16, 0, 16, 245 ),
	tooltipBorder = Color( 80, 0, 80, 255 ),
	tooltipBorderBright = Color( 40, 0, 40, 255 ),
	selection = Color( 255, 255, 255, 235 ),
	selectionDark = Color( 255, 255, 255, 80 ),
	valid = Color( 255, 255, 255, 120 ),
	invalid = Color( 255, 50, 50, 120 ),
	common = Color( 255, 255, 255, 255 ),
	uncommon = Color( 85, 255, 85, 255 ),
	rare = Color( 85, 170, 255, 255 ),
	epic = Color( 255, 85, 255, 255 ),
}

UI.Materials = UI.Materials or {}

local function material( path, flags )
	local key = tostring( path ) .. "|" .. tostring( flags or "" )
	local cached = UI.Materials[key]
	if cached then return cached end
	local value = Material( path, flags or "vertexcolor vertexalpha nocull" )
	UI.Materials[key] = value
	return value
end

function UI.GetMaterial( path )
	if not isstring( path ) or path == "" then return nil end
	return material( path, "vertexcolor vertexalpha nocull" )
end

function UI.GetGuiMaterial( name )
	return material( "mc/gui/" .. tostring( name ) .. ".png", "vertexcolor vertexalpha nocull" )
end

function UI.WithPointFiltering( callback )
	if not isfunction( callback ) then return end
	local pushedMin, pushedMag = false, false
	if render and render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ); pushedMin = true end
	if render and render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ); pushedMag = true end
	local ok, err = pcall( callback )
	if pushedMag and render.PopFilterMag then render.PopFilterMag() end
	if pushedMin and render.PopFilterMin then render.PopFilterMin() end
	if not ok and ErrorNoHalt then ErrorNoHalt( "[MC Inventory UI] draw error: " .. tostring( err ) .. "\n" ) end
end

function UI.DrawTexture( mat, x, y, w, h, u0, v0, u1, v1 )
	if not mat then return false end
	surface.SetMaterial( mat )
	surface.SetDrawColor( 255, 255, 255, 255 )
	if u0 ~= nil then
		surface.DrawTexturedRectUV( x, y, w, h, u0, v0, u1, v1 )
	else
		surface.DrawTexturedRect( x, y, w, h )
	end
	return true
end

function UI.DrawGuiRegion( name, x, y, w, h, sourceW, sourceH )
	local mat = UI.GetGuiMaterial( name )
	return UI.DrawTexture( mat, x, y, w, h, 0, 0, ( sourceW or w ) / 256, ( sourceH or h ) / 256 )
end

local FONT_ATLASES = {
	{ material = material( "mc/font/ascii.png", "vertexcolor vertexalpha nocull" ), first = 32, last = 126, cols = 16, rows = 16, ascii = true },
	{ material = material( "mc/font/nonlatin_european.png", "vertexcolor vertexalpha nocull" ), first = 0x00A1, last = 0x2FFF, cols = 16, rows = 16 },
	{ material = material( "mc/font/unifont_cjk_0.png", "vertexcolor vertexalpha nocull" ), first = 0x3000, last = 0x6FFF, cols = 128, rows = 128 },
	{ material = material( "mc/font/unifont_cjk_1.png", "vertexcolor vertexalpha nocull" ), first = 0x7000, last = 0x9FFF, cols = 128, rows = 96 },
	{ material = material( "mc/font/unifont_cjk_compat.png", "vertexcolor vertexalpha nocull" ), first = 0xF900, last = 0xFAFF, cols = 128, rows = 4 },
	{ material = material( "mc/font/unifont_fullwidth.png", "vertexcolor vertexalpha nocull" ), first = 0xFF01, last = 0xFF5E, cols = 128, rows = 1 },
}

local function nextCodepoint( text, index )
	local first = string.byte( text, index )
	if not first then return nil end
	if first < 0x80 then return first, index + 1, string.sub( text, index, index ) end
	if first >= 0xC2 and first <= 0xDF then
		local b = string.byte( text, index + 1 ) or 0
		return ( first - 0xC0 ) * 64 + b - 0x80, index + 2, string.sub( text, index, index + 1 )
	end
	if first >= 0xE0 and first <= 0xEF then
		local b, c = string.byte( text, index + 1 ) or 0, string.byte( text, index + 2 ) or 0
		return ( first - 0xE0 ) * 4096 + ( b - 0x80 ) * 64 + c - 0x80, index + 3, string.sub( text, index, index + 2 )
	end
	if first >= 0xF0 and first <= 0xF4 then
		local b, c, d = string.byte( text, index + 1 ) or 0, string.byte( text, index + 2 ) or 0, string.byte( text, index + 3 ) or 0
		return ( first - 0xF0 ) * 262144 + ( b - 0x80 ) * 4096 + ( c - 0x80 ) * 64 + d - 0x80, index + 4, string.sub( text, index, index + 3 )
	end
	return 0xFFFD, index + 1, string.sub( text, index, index )
end

local glyphCache, glyphCacheCount = {}, 0
local function glyphsFor( text )
	text = tostring( text or "" )
	local cached = glyphCache[text]
	if cached then return cached end
	local glyphs, width, index = {}, 0, 1
	while index <= #text do
		local codepoint, nextIndex, bytes = nextCodepoint( text, index )
		local atlas, u0, v0, u1, v1
		for _, candidate in ipairs( FONT_ATLASES ) do
			if codepoint >= candidate.first and codepoint <= candidate.last then
				local slot = candidate.ascii and codepoint or codepoint - candidate.first
				local column, row = slot % candidate.cols, math.floor( slot / candidate.cols )
				atlas = candidate
				u0, v0 = column / candidate.cols, row / candidate.rows
				u1, v1 = ( column + 1 ) / candidate.cols, ( row + 1 ) / candidate.rows
				break
			end
		end
		local advance = MC.SignGlyphAdvance and MC.SignGlyphAdvance( codepoint ) or ( codepoint == 32 and 4 or 6 )
		glyphs[#glyphs + 1] = { text = bytes, atlas = atlas, u0 = u0, v0 = v0, u1 = u1, v1 = v1, advance = advance }
		width = width + advance
		index = nextIndex
	end
	cached = { glyphs = glyphs, width = width }
	if glyphCacheCount >= 2048 then glyphCache, glyphCacheCount = {}, 0 end
	glyphCache[text], glyphCacheCount = cached, glyphCacheCount + 1
	return cached
end

function UI.MeasureText( text, scale )
	return glyphsFor( text ).width * ( tonumber( scale ) or 1 )
end

function UI.DrawText( text, x, y, scale, color, align, shadow )
	scale = tonumber( scale ) or 1
	color = color or UI.Colors.text
	local line = glyphsFor( text )
	local width = line.width * scale
	if align == TEXT_ALIGN_CENTER then x = x - width * 0.5
	elseif align == TEXT_ALIGN_RIGHT then x = x - width end
	local function drawAt( ox, oy, drawColor )
		local cursor = x + ox
		for _, glyph in ipairs( line.glyphs ) do
			if glyph.atlas then
				surface.SetMaterial( glyph.atlas.material )
				surface.SetDrawColor( drawColor )
				surface.DrawTexturedRectUV( cursor, y + oy, 8 * scale, 8 * scale, glyph.u0, glyph.v0, glyph.u1, glyph.v1 )
			else
				draw.SimpleText( glyph.text, "MCInventoryFallback", cursor + glyph.advance * scale * 0.5, y + oy + 4 * scale, drawColor, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
			end
			cursor = cursor + glyph.advance * scale
		end
	end
	if shadow then drawAt( scale, scale, UI.Colors.textShadow ) end
	drawAt( 0, 0, color )
	return width
end

if surface and surface.CreateFont then
	surface.CreateFont( "MCInventoryFallback", {
		font = "Tahoma",
		size = 8,
		weight = 500,
		antialias = false,
		extended = true,
	} )
end

function UI.GuiScale()
	local width, height = ScrW(), ScrH()
	return math.Clamp( math.floor( math.min( width / 320, height / 240 ) ), 2, 4 )
end

function UI.RarityColor( rarity )
	rarity = string.lower( tostring( rarity or "common" ) )
	return UI.Colors[rarity] or UI.Colors.common
end

