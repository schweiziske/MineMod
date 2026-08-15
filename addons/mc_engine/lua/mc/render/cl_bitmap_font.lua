-- Minecraft Java bitmap fonts for public client UI consumers.
--
-- The generated provider data preserves the exact sparse codepoint grids and
-- alpha-derived advances from BitmapProvider. Game addons only see MC.API.Font;
-- atlas materials, caches and fallback handling remain engine-private.

if not CLIENT then return end

MC = MC or {}

local DATA = MC.GeneratedBitmapFontData or {}
local LINE_HEIGHT = 9
local FONT_NAMES = { default = true, alt = true }
local ALIGN_CENTER = TEXT_ALIGN_CENTER or 1
local ALIGN_RIGHT = TEXT_ALIGN_RIGHT or 2
local ALIGN_MIDDLE = TEXT_ALIGN_CENTER or 1
local ALIGN_BOTTOM = TEXT_ALIGN_BOTTOM or 4
local Materials = {}
local Fonts = {}
local LineCache = {}
local LineCacheCount = 0

local function fontMaterial( path )
	local cached = Materials[path]
	if cached then return cached end
	local source = Material( path .. ".png", "alphatest vertexcolor vertexalpha nocull" )
	if not ( CreateMaterial and source and source.GetTexture ) then
		Materials[path] = source
		return source
	end
	local texture = source:GetTexture( "$basetexture" )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not textureName or textureName == "" or texture.IsError and texture:IsError() then
		Materials[path] = source
		return source
	end
	local suffix = util and util.CRC and util.CRC( path .. "|bitmap_font_v1" )
		or string.gsub( path, "[^%w_]", "_" )
	local value = CreateMaterial( "mc_bitmap_font_" .. tostring( suffix ), "UnlitGeneric", {
		["$basetexture"] = textureName,
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = "1",
		["$alphatest"] = "1",
		["$alphatestreference"] = "0.5",
		["$pointsample"] = "1",
		["$nomip"] = "1",
		["$nolod"] = "1",
		["$clamps"] = "1",
		["$clampt"] = "1",
	} )
	if value and not value:IsError() then
		value:SetTexture( "$basetexture", texture )
		Materials[path] = value
		return value
	end
	Materials[path] = source
	return source
end

local function normalizeFontName( name )
	name = string.lower( tostring( name or "default" ) )
	return FONT_NAMES[name] and name or "default"
end

local function nextCodepoint( text, index )
	local first = string.byte( text, index )
	if not first then return nil end
	if first < 0x80 then return first, index + 1, string.sub( text, index, index ) end
	local needed, value
	if first >= 0xC2 and first <= 0xDF then needed, value = 1, first - 0xC0
	elseif first >= 0xE0 and first <= 0xEF then needed, value = 2, first - 0xE0
	elseif first >= 0xF0 and first <= 0xF4 then needed, value = 3, first - 0xF0
	else return 0xFFFD, index + 1, string.sub( text, index, index ) end
	local nextIndex = index + needed + 1
	if nextIndex - 1 > #text then return 0xFFFD, index + 1, string.sub( text, index, index ) end
	for offset = 1, needed do
		local byte = string.byte( text, index + offset )
		if not byte or byte < 0x80 or byte > 0xBF then
			return 0xFFFD, index + 1, string.sub( text, index, index )
		end
		value = value * 64 + byte - 0x80
	end
	if needed == 2 and value < 0x800 or needed == 3 and value < 0x10000
	or value >= 0xD800 and value <= 0xDFFF or value > 0x10FFFF then
		return 0xFFFD, index + 1, string.sub( text, index, index )
	end
	return value, nextIndex, string.sub( text, index, nextIndex - 1 )
end

local function generatedProvider( definition )
	if type( definition ) ~= "table" or not util or not util.Base64Decode then return nil end
	local codepoints = util.Base64Decode( tostring( definition.codepoints or "" ) )
	local advances = util.Base64Decode( tostring( definition.advances or "" ) )
	if type( codepoints ) ~= "string" or type( advances ) ~= "string" then return nil end
	local columns = math.max( 1, math.floor( tonumber( definition.columns ) or 1 ) )
	local rows = math.max( 1, math.floor( tonumber( definition.rows ) or 1 ) )
	local cellWidth = math.max( 1, tonumber( definition.cell_width ) or 8 )
	local cellHeight = math.max( 1, tonumber( definition.cell_height ) or 8 )
	local logicalHeight = math.max( 1, tonumber( definition.height ) or 8 )
	return {
		material = fontMaterial( tostring( definition.material or "mc/font/ascii" ) ),
		textureWidth = math.max( 1, tonumber( definition.texture_width ) or columns * cellWidth ),
		textureHeight = math.max( 1, tonumber( definition.texture_height ) or rows * cellHeight ),
		columns = columns,
		rows = rows,
		cellWidth = cellWidth,
		cellHeight = cellHeight,
		drawWidth = cellWidth * logicalHeight / cellHeight,
		drawHeight = logicalHeight,
		topOffset = 7 - ( tonumber( definition.ascent ) or 7 ),
		codepoints = codepoints,
		advances = advances,
	}
end

local function addGeneratedProviders( font, definitions )
	for _, definition in ipairs( type( definitions ) == "table" and definitions or {} ) do
		local provider = generatedProvider( definition )
		if provider then
			local count = provider.columns * provider.rows
			for slot = 0, count - 1 do
				local byteIndex = slot * 3 + 1
				local high, middle, low = string.byte( provider.codepoints, byteIndex, byteIndex + 2 )
				local codepoint = high and high * 65536 + middle * 256 + low or 0
				local advance = string.byte( provider.advances, slot + 1 ) or 0
				if codepoint ~= 0 and font.glyphs[codepoint] == nil then
					local column, row = slot % provider.columns, math.floor( slot / provider.columns )
					local left, top = column * provider.cellWidth, row * provider.cellHeight
					font.glyphs[codepoint] = {
						advance = advance,
						material = provider.material,
						drawWidth = provider.drawWidth,
						drawHeight = provider.drawHeight,
						topOffset = provider.topOffset,
						u0 = ( left + 0.01 ) / provider.textureWidth,
						v0 = ( top + 0.01 ) / provider.textureHeight,
						u1 = ( left + provider.cellWidth - 0.01 ) / provider.textureWidth,
						v1 = ( top + provider.cellHeight - 0.01 ) / provider.textureHeight,
					}
				end
			end
		end
	end
end

local function rangeProvider( path, first, last, textureWidth, textureHeight, columns, rows )
	return {
		material = fontMaterial( path ), first = first, last = last,
		textureWidth = textureWidth, textureHeight = textureHeight,
		columns = columns, rows = rows,
		cellWidth = textureWidth / columns, cellHeight = textureHeight / rows,
	}
end

local function buildFont( name )
	local font = { glyphs = {}, ranges = {} }
	-- include/space is the first provider in both vanilla fonts. It must win
	-- over ascii.png's blank one-pixel space cell.
	local spaces = DATA.spaces and DATA.spaces[name]
	if type( spaces ) == "table" then
		for codepoint, advance in pairs( spaces ) do
			font.glyphs[tonumber( codepoint ) or 0] = { advance = tonumber( advance ) or 0 }
		end
	else
		-- Backward compatibility for stale generated data during hot reload.
		font.glyphs[32] = { advance = 4 }
		font.glyphs[0x200C] = { advance = 0 }
	end
	addGeneratedProviders( font, DATA.fonts and DATA.fonts[name] )
	if name == "default" then
		font.ranges = {
			rangeProvider( "mc/font/unifont_cjk_0", 0x3000, 0x6FFF, 2048, 2048, 128, 128 ),
			rangeProvider( "mc/font/unifont_cjk_1", 0x7000, 0x9FFF, 2048, 1536, 128, 96 ),
			rangeProvider( "mc/font/unifont_cjk_compat", 0xF900, 0xFAFF, 2048, 64, 128, 4 ),
			rangeProvider( "mc/font/unifont_fullwidth", 0xFF01, 0xFF5E, 2048, 16, 128, 1 ),
		}
	end
	return font
end

local function glyphFor( font, codepoint, bytes )
	local glyph = font.glyphs[codepoint]
	if glyph then return glyph end
	for _, provider in ipairs( font.ranges ) do
		if codepoint >= provider.first and codepoint <= provider.last then
			local slot = codepoint - provider.first
			local column, row = slot % provider.columns, math.floor( slot / provider.columns )
			if row < provider.rows then
				local left, top = column * provider.cellWidth, row * provider.cellHeight
				glyph = {
					advance = 9,
					material = provider.material,
					drawWidth = 8,
					drawHeight = 8,
					topOffset = 0,
					u0 = ( left + 0.01 ) / provider.textureWidth,
					v0 = ( top + 0.01 ) / provider.textureHeight,
					u1 = ( left + provider.cellWidth - 0.01 ) / provider.textureWidth,
					v1 = ( top + provider.cellHeight - 0.01 ) / provider.textureHeight,
				}
				font.glyphs[codepoint] = glyph
				return glyph
			end
		end
	end
	return { advance = codepoint == 32 and 4 or 9, fallback = bytes }
end

local function shapedLine( text, fontName )
	text = tostring( text or "" )
	fontName = normalizeFontName( fontName )
	local key = fontName .. "\0" .. text
	local cached = LineCache[key]
	if cached then return cached end
	local font = Fonts[fontName] or Fonts.default
	local glyphs, width, index = {}, 0, 1
	while index <= #text do
		local codepoint, nextIndex, bytes = nextCodepoint( text, index )
		local glyph = glyphFor( font, codepoint, bytes )
		glyphs[#glyphs + 1] = {
			advance = glyph.advance, material = glyph.material,
			drawWidth = glyph.drawWidth, drawHeight = glyph.drawHeight,
			topOffset = glyph.topOffset, u0 = glyph.u0, v0 = glyph.v0, u1 = glyph.u1, v1 = glyph.v1,
			fallback = glyph.fallback, text = bytes,
		}
		width = width + glyph.advance
		index = nextIndex
	end
	cached = { glyphs = glyphs, width = width, text = text, font = fontName }
	if LineCacheCount >= 4096 then LineCache, LineCacheCount = {}, 0 end
	LineCache[key], LineCacheCount = cached, LineCacheCount + 1
	return cached
end

for name in pairs( FONT_NAMES ) do Fonts[name] = buildFont( name ) end

local FallbackFonts = {}
local function fallbackFont( scale )
	if not surface or not surface.CreateFont then return "DermaDefault" end
	scale = math.Clamp( math.floor( ( tonumber( scale ) or 1 ) + 0.5 ), 1, 32 )
	local cached = FallbackFonts[scale]
	if cached then return cached end
	local name = "MCBitmapFontFallback" .. scale
	surface.CreateFont( name, {
		font = "Microsoft YaHei",
		size = 8 * scale,
		weight = 500,
		antialias = false,
		extended = true,
	} )
	FallbackFonts[scale] = name
	return name
end

local BitmapFont = {}

function BitmapFont.Measure( text, fontName )
	return shapedLine( text, fontName ).width
end

function BitmapFont.TrimToWidth( text, maxWidth, fontName )
	maxWidth = math.max( 0, tonumber( maxWidth ) or 0 )
	local line = shapedLine( text, fontName )
	if line.width <= maxWidth then return line.text end
	local width, result = 0, {}
	for _, glyph in ipairs( line.glyphs ) do
		if width + glyph.advance > maxWidth then break end
		width = width + glyph.advance
		result[#result + 1] = glyph.text
	end
	return table.concat( result )
end

local function shadowColor( color )
	return Color(
		math.floor( ( tonumber( color.r ) or 255 ) * 0.25 ),
		math.floor( ( tonumber( color.g ) or 255 ) * 0.25 ),
		math.floor( ( tonumber( color.b ) or 255 ) * 0.25 ),
		tonumber( color.a ) or 255
	)
end

local function drawLineAt( line, x, y, scale, color )
	local cursor = x
	for _, glyph in ipairs( line.glyphs ) do
		if glyph.material then
			surface.SetMaterial( glyph.material )
			surface.SetDrawColor( color.r or 255, color.g or 255, color.b or 255, color.a or 255 )
			surface.DrawTexturedRectUV(
				cursor,
				y + ( glyph.topOffset or 0 ) * scale,
				( glyph.drawWidth or 8 ) * scale,
				( glyph.drawHeight or 8 ) * scale,
				glyph.u0, glyph.v0, glyph.u1, glyph.v1
			)
		elseif glyph.fallback and draw and draw.SimpleText then
			draw.SimpleText( glyph.fallback, fallbackFont( scale ),
				cursor + glyph.advance * scale * 0.5, y + 4 * scale,
				color, ALIGN_CENTER, ALIGN_MIDDLE )
		end
		cursor = cursor + glyph.advance * scale
	end
end

function BitmapFont.Draw( text, x, y, options )
	options = type( options ) == "table" and options or {}
	local scale = math.max( 0.01, tonumber( options.scale ) or 1 )
	local fontName = normalizeFontName( options.font )
	if options.maxWidth ~= nil then
		text = BitmapFont.TrimToWidth( text, ( tonumber( options.maxWidth ) or 0 ) / scale, fontName )
	end
	local line = shapedLine( text, fontName )
	local width = line.width * scale
	local align = options.align
	if align == ALIGN_CENTER then x = x - width * 0.5
	elseif align == ALIGN_RIGHT then x = x - width end
	local verticalAlign = options.verticalAlign
	if verticalAlign == ALIGN_MIDDLE then y = y - LINE_HEIGHT * scale * 0.5
	elseif verticalAlign == ALIGN_BOTTOM then y = y - LINE_HEIGHT * scale end
	local color = options.color or color_white or Color( 255, 255, 255, 255 )
	if options.shadow == true then drawLineAt( line, x + scale, y + scale, scale, shadowColor( color ) ) end
	drawLineAt( line, x, y, scale, color )
	return width
end

function BitmapFont.LineHeight()
	return LINE_HEIGHT
end

MC.BitmapFont = BitmapFont
