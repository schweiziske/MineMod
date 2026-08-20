-- Pure MapRenderer/MapTextureManager constants and provider-data adapters.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local function component( stack, name )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil end
	if components["minecraft:" .. name] ~= nil then return components["minecraft:" .. name] end
	return components[name]
end

local function scalar( value )
	if type( value ) == "table" then
		value = value.id or value.value or value.map_id or value.mapId or value.name
	end
	if type( value ) ~= "string" and type( value ) ~= "number" then return nil end
	return tostring( value )
end

function D.DecorationMapId( stack )
	return scalar( component( stack, "map_id" ) )
end

-- MapTextureManager keys textures by MapId and uploads only after its dirty
-- flag changes. Providers mirror that contract with a stable cache key plus a
-- revision. Mutable pixel tables must bump revision; the conservative default
-- revision is zero so missing metadata never rebuilds 128x128 pixels per frame.
function D.DecorationMapCacheIdentity( data, stack, fallbackKey )
	data = type( data ) == "table" and data or {}
	local cache = type( data.cache ) == "table" and data.cache or {}
	local key = scalar( data.cacheKey or data.cache_key or data.mapId or data.map_id
		or cache.key ) or D.DecorationMapId( stack ) or scalar( fallbackKey )
	local revision = scalar( data.revision or data.version or data.updateId
		or data.update_id or cache.revision ) or "0"
	return key, revision
end

function D.DecorationMapPixels( data )
	if type( data ) ~= "table" then return nil end
	return type( data.pixels ) == "table" and data.pixels
		or type( data.colors ) == "table" and data.colors or nil
end

function D.DecorationMapPixelValue( pixels, row, column )
	if type( pixels ) ~= "table" then return nil end
	row, column = math.floor( tonumber( row ) or 0 ), math.floor( tonumber( column ) or 0 )
	local line = pixels[row + 1]
	if type( line ) ~= "table" then line = pixels[row] end
	if type( line ) == "table" then
		if line[column + 1] ~= nil then return line[column + 1] end
		return line[column]
	end
	local index = row * 128 + column
	if pixels[index + 1] ~= nil then return pixels[index + 1] end
	return pixels[index]
end

-- Providers may return `{r,g,b,a}`, 0xRRGGBB, or Java-style 0xAARRGGBB.
-- `pixelFormat="argb"` is required when numeric zero means transparent NONE.
function D.DecorationMapPixelRGBA( value, pixelFormat )
	if type( value ) == "table" then
		return tonumber( value.r ) or tonumber( value[1] ) or 0,
			tonumber( value.g ) or tonumber( value[2] ) or 0,
			tonumber( value.b ) or tonumber( value[3] ) or 0,
			tonumber( value.a ) or tonumber( value[4] ) or 255
	end
	local number = tonumber( value )
	if not number then return nil end
	number = math.floor( number ) % 4294967296
	local argb = pixelFormat == "argb" or pixelFormat == "minecraft_argb"
		or number > 16777215
	local alpha = argb and math.floor( number / 16777216 ) % 256 or 255
	return math.floor( number / 65536 ) % 256,
		math.floor( number / 256 ) % 256, number % 256, alpha
end

-- ItemFrameRenderer translates map geometry by local Z=-1 after scaling by
-- 1/128; MapRenderer then emits its texture at Z=-0.01.
function D.DecorationMapTextureOutset()
	return 1.01 / 128
end

function D.DecorationMapVisibleOnFrame( decoration )
	if type( decoration ) ~= "table" then return false end
	return decoration.renderOnFrame == true or decoration.render_on_frame == true
end

-- MapRenderer is called with showOnlyFrame=true. x/y are signed map bytes and
-- therefore move by x/2 and y/2 texture pixels before the 1/128 map scale.
function D.DecorationMapDecorationTransform( decoration, visibleIndex )
	decoration = type( decoration ) == "table" and decoration or {}
	visibleIndex = math.max( 1, math.floor( tonumber( visibleIndex ) or 1 ) )
	local rotation = tonumber( decoration.rot ) or tonumber( decoration.rotation ) or 0
	return {
		x = ( tonumber( decoration.x ) or 0 ) / 256,
		y = -( tonumber( decoration.y ) or 0 ) / 256,
		rotation = rotation * 22.5,
		size = 1 / 16,
		-- scale(4), then translate(-0.125,+0.125): half a map pixel in
		-- the rotated sprite basis. The renderer's Y basis points upward.
		shiftX = -1 / 256,
		shiftY = -1 / 256,
		-- Decoration Z=-0.02; its vertex Z uses scaleZ=3 and -0.001 per
		-- already-visible decoration.
		outset = ( 1.02 + ( visibleIndex - 1 ) * 0.003 ) / 128,
	}
end

function D.DecorationMapDecorationName( decoration )
	local value = type( decoration ) == "table" and decoration.name or nil
	if type( value ) == "table" then value = value.text or value.value or value.string end
	return type( value ) == "string" and value ~= "" and value or nil
end

-- MapRenderer name transform: width is centred at x; y starts four map pixels
-- below the icon position. Font background=Integer.MIN_VALUE spans
-- (-1,-1)..(width,9), and the final Z translate is -0.025 + (-1*0.1).
function D.DecorationMapDecorationNameTransform( decoration, textWidth )
	decoration = type( decoration ) == "table" and decoration or {}
	textWidth = math.max( 0, tonumber( textWidth ) or 0 )
	local textScale = textWidth > 0 and math.min( 25 / textWidth, 6 / 9 ) or 6 / 9
	return {
		scale = textScale,
		x = ( tonumber( decoration.x ) or 0 ) / 256 - 0.5 * textScale / 128,
		y = -( tonumber( decoration.y ) or 0 ) / 256 - ( 4 + 4 * textScale ) / 128,
		width = ( textWidth + 1 ) * textScale / 128,
		height = 10 * textScale / 128,
		outset = 1.125 / 128,
	}
end
