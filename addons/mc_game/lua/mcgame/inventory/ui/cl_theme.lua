--[[----------------------------------------------------------------------------
    Minecraft inventory UI theme and low-allocation drawing helpers.

    The container textures are the visual system.  This file only supplies the
    public Minecraft bitmap-font text, crisp texture drawing and semantic colors;
    layout and inventory state stay in the screen/slot modules.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Font = MC.API and MC.API.Font or {}
local GeneratedSprites = MC.GeneratedGuiSpriteData or {}
local SpriteDefinitions = type( GeneratedSprites.sprites ) == "table" and GeneratedSprites.sprites or {}
local MAX_GUI_SCALE = 32

local function usesHudRasterPhase( name )
	-- The already-calibrated HUD sprites need Source's leading half-texel
	-- compensation to keep 9x9 hearts/food and the 182px bars pixel-even.
	-- Container sprites have authored opaque borders and must keep Java's exact
	-- atlas boundaries; a negative UV there exposes Source's red error border.
	return string.sub( name, 1, 12 ) == "sprites/hud/"
		or string.sub( name, 1, 4 ) == "hud/"
end

local function usesClippedContainerRasterPhase( name )
	-- These opaque-edged widgets make Source's one-pixel leading raster phase
	-- immediately visible. Keep the same calibrated half-texel phase as the HUD,
	-- then clip the material's out-of-bounds guard pixel at the call site.
	return name == "sprites/container/anvil/text_field"
		or name == "sprites/container/anvil/text_field_disabled"
		or name == "sprites/container/enchanting_table/enchantment_slot"
		or name == "sprites/container/enchanting_table/enchantment_slot_disabled"
		or name == "sprites/container/enchanting_table/enchantment_slot_highlighted"
end

UI.ButtonSound = "mc/random/click.ogg"

function UI.PlayButtonSound()
	if surface and surface.PlaySound then surface.PlaySound( UI.ButtonSound ) end
end

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
UI.PixelMaterials = UI.PixelMaterials or {}
UI.GuiSpriteMappings = UI.GuiSpriteMappings or {}
UI.WorldItemHDRColorScale = 0.1

local function sourceMaterial( path, flags )
	local key = tostring( path ) .. "|" .. tostring( flags or "" )
	local cached = UI.Materials[key]
	if cached then return cached end
	local value = Material( path, flags or "vertexcolor vertexalpha nocull" )
	UI.Materials[key] = value
	return value
end

local function pixelMaterial( path, flags, hdrColorScale, noCull, alphaTest )
	local sourcePath = tostring( path or "" )
	local sourceFlags = tostring( flags or "vertexcolor vertexalpha nocull" )
	local hdrKey = hdrColorScale and tostring( hdrColorScale ) or "ui"
	if noCull == nil then noCull = true end
	if alphaTest == nil then alphaTest = true end
	local alphaMode = alphaTest and "cutout" or "blend"
	local key = sourcePath .. "|" .. sourceFlags .. "|pixel_v5|" .. hdrKey .. "|"
		.. ( noCull and "double" or "culled" ) .. "|" .. alphaMode
	local cached = UI.PixelMaterials[key]
	if cached then return cached end

	local source = sourceMaterial( sourcePath, sourceFlags )
	if not ( CreateMaterial and source and source.GetTexture ) then
		UI.PixelMaterials[key] = source
		return source
	end

	local texture = source:GetTexture( "$basetexture" )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not textureName or textureName == "" or ( texture.IsError and texture:IsError() ) then
		UI.PixelMaterials[key] = source
		return source
	end

	local identity = sourcePath .. "|" .. sourceFlags .. "|" .. hdrKey .. "|" .. alphaMode
	local suffix = util and util.CRC and util.CRC( identity ) or string.gsub( identity, "[^%w_]", "_" )
	local params = {
		["$basetexture"] = textureName,
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = noCull and "1" or "0",
		["$pointsample"] = "1",
		["$nomip"] = "1",
		["$nolod"] = "1",
		["$clamps"] = "1",
		["$clampt"] = "1",
	}
	if alphaTest then
		params["$alphatest"] = "1"
		params["$alphatestreference"] = "0.5"
	else
		params["$translucent"] = "1"
	end
	if hdrColorScale then params["$hdrcolorscale"] = tostring( hdrColorScale ) end
	local value = CreateMaterial( "mc_inventory_pixel_" .. tostring( suffix ), "UnlitGeneric", params )
	if value and not value:IsError() then
		value:SetTexture( "$basetexture", texture )
		if hdrColorScale and value.SetFloat then value:SetFloat( "$hdrcolorscale", hdrColorScale ) end
		UI.PixelMaterials[key] = value
		return value
	end

	UI.PixelMaterials[key] = source
	return source
end

function UI.GetMaterial( path )
	if not isstring( path ) or path == "" then return nil end
	-- UI PNGs must retain their authored alpha. The hotbar background uses alpha
	-- 186 and its selection frame uses 174; routing them through the world-item
	-- alpha-test material turns those pixels opaque and makes the HUD look heavy.
	-- POINT sampling is applied by WithPointFiltering at draw time.
	return sourceMaterial( path, "vertexcolor vertexalpha nocull" )
end

function UI.GetWorldItemMaterial( path )
	if not isstring( path ) or path == "" then return nil end
	return pixelMaterial( path, "vertexcolor vertexalpha", UI.WorldItemHDRColorScale, false, true )
end

function UI.GetGuiMaterial( name )
	name = tostring( name or "" )
	local definition = SpriteDefinitions[name]
	if type( definition ) == "table" then
		local material = pixelMaterial( definition.material, "vertexcolor vertexalpha nocull", nil, true, false )
		if material then
			local mappingWidth = math.max( 1, tonumber( definition.mappingWidth ) or 1 )
			local mappingHeight = math.max( 1, tonumber( definition.mappingHeight ) or 1 )
			local hudRasterPhase = usesHudRasterPhase( name )
			local clippedContainerRasterPhase = usesClippedContainerRasterPhase( name )
			local calibratedRasterPhase = hudRasterPhase or clippedContainerRasterPhase
			UI.GuiSpriteMappings[material] = {
				uScale = math.max( 1, tonumber( definition.width ) or 1 )
					/ mappingWidth,
				vScale = math.max( 1, tonumber( definition.height ) or 1 )
					/ mappingHeight,
				uInset = calibratedRasterPhase and 0.5 / mappingWidth or 0,
				vInset = calibratedRasterPhase and 0.5 / mappingHeight or 0,
				-- Source paints a pure-red guard sample when some translucent
				-- generated materials touch the leading DrawTexturedRectUV edge.
				-- Container sprites are stored on transparent POT canvases, so draw
				-- that complete canvas instead: the authored pixels retain their
				-- exact integer scale and the transparent padding remains invisible.
				paddedFullDraw = not calibratedRasterPhase,
			}
		end
		return material
	end
	return sourceMaterial( "mc/gui/" .. name .. ".png", "vertexcolor vertexalpha nocull" )
end

function UI.GetMobEffectMaterial( effectId )
	effectId = string.lower( tostring( effectId or "" ) )
	if effectId == "" or not string.match( effectId, "^[a-z0-9_]+$" ) then return nil end
	return UI.GetMaterial( "mc/gui/mob_effect/" .. effectId .. ".png" )
end

function UI.GetEffectBackgroundMaterial( ambient, inventory )
	local prefix = inventory and "sprites/container/inventory/" or "sprites/hud/"
	return UI.GetGuiMaterial( prefix .. "effect_background" .. ( ambient and "_ambient" or "" ) )
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

function UI.DrawTexture( mat, x, y, w, h, u0, v0, u1, v1, color )
	if not mat then return false end
	surface.SetMaterial( mat )
	color = color or color_white
	surface.SetDrawColor( color.r or 255, color.g or 255, color.b or 255, color.a or 255 )
	local mapping = UI.GuiSpriteMappings[mat]
	if mapping then
		local uScale = tonumber( mapping.uScale ) or 1
		local vScale = tonumber( mapping.vScale ) or 1
		if u0 == nil and mapping.paddedFullDraw == true then
			surface.DrawTexturedRect( x, y, w / uScale, h / vScale )
			return true
		end
		local uInset = tonumber( mapping.uInset ) or 0
		local vInset = tonumber( mapping.vInset ) or 0
		if u0 ~= nil then
			u0, v0 = u0 * uScale - uInset, ( v0 or 0 ) * vScale - vInset
			u1, v1 = ( u1 or 1 ) * uScale, ( v1 or 1 ) * vScale
		else
			u0, v0, u1, v1 = -uInset, -vInset, uScale, vScale
		end
	end
	if u0 ~= nil then
		surface.DrawTexturedRectUV( x, y, w, h, u0, v0, u1, v1 )
	else
		surface.DrawTexturedRect( x, y, w, h )
	end
	return true
end

function UI.DrawTextureClipped( mat, x, y, w, h, clipX, clipY, clipW, clipH, u0, v0, u1, v1, color )
	if not ( render and render.SetScissorRect ) then
		return UI.DrawTexture( mat, x, y, w, h, u0, v0, u1, v1, color )
	end
	clipX = math.floor( tonumber( clipX ) or tonumber( x ) or 0 )
	clipY = math.floor( tonumber( clipY ) or tonumber( y ) or 0 )
	clipW = math.max( 0, math.floor( tonumber( clipW ) or tonumber( w ) or 0 ) )
	clipH = math.max( 0, math.floor( tonumber( clipH ) or tonumber( h ) or 0 ) )
	render.SetScissorRect( clipX, clipY, clipX + clipW, clipY + clipH, true )
	local ok, result = pcall( UI.DrawTexture, mat, x, y, w, h, u0, v0, u1, v1, color )
	render.SetScissorRect( 0, 0, 0, 0, false )
	if not ok then error( result, 0 ) end
	return result
end

function UI.DrawAnvilTextField( mat, x, y, scale )
	scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	x, y = math.floor( tonumber( x ) or 0 ), math.floor( tonumber( y ) or 0 )
	-- The base anvil background intentionally stores a red 110x16 placeholder
	-- at logical (59,20). Source's atlas raster phase exposes its top and left
	-- edges by one framebuffer pixel before this widget is drawn. Restore the
	-- exact surrounding background pixels from the Java PNG first.
	surface.SetDrawColor( 198, 198, 198, 255 )
	surface.DrawRect( x - 1, y - 1, 110 * scale + 1, 1 )
	surface.DrawRect( x - 1, y, 1, 16 * scale )
	return UI.DrawTexture( mat, x, y, 110 * scale, 16 * scale )
end

function UI.DrawEnchantingTopFrame( left, top, scale )
	-- enchanting_table.png contains the outer 109x1 dark frame at logical
	-- (59,13); the option sprite begins at (60,14). Source samples the atlas
	-- transition one framebuffer pixel early, leaving the following bevel row
	-- visible as a second line. Reconstruct that one authored row at its exact
	-- Java coordinates so it remains a single Minecraft pixel at every GUI scale.
	scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	local x = math.floor( tonumber( left ) or 0 ) + 59 * scale
	local y = math.floor( tonumber( top ) or 0 ) + 13 * scale
	surface.SetDrawColor( 198, 198, 198, 255 )
	surface.DrawRect( x - 1, y - 1, 109 * scale + 1, scale + 1 )
	surface.SetDrawColor( 55, 55, 55, 255 )
	surface.DrawRect( x, y, 109 * scale, scale )
	return true
end

function UI.DrawGuiRegion( name, x, y, w, h, sourceW, sourceH )
	local mat = UI.GetGuiMaterial( name )
	return UI.DrawTexture( mat, x, y, w, h, 0, 0, ( sourceW or w ) / 256, ( sourceH or h ) / 256 )
end

function UI.MeasureText( text, scale, fontName )
	scale = math.max( 0.01, tonumber( scale ) or 1 )
	if type( Font.Measure ) == "function" then
		return Font.Measure( tostring( text or "" ), fontName ) * scale
	end
	return #tostring( text or "" ) * 6 * scale
end

function UI.TrimText( text, maxWidth, scale, fontName )
	scale = math.max( 0.01, tonumber( scale ) or 1 )
	if type( Font.TrimToWidth ) == "function" then
		return Font.TrimToWidth( tostring( text or "" ), math.max( 0, tonumber( maxWidth ) or 0 ) / scale, fontName )
	end
	return tostring( text or "" )
end

function UI.DrawText( text, x, y, scale, color, align, shadow, verticalAlign, fontName )
	text = tostring( text or "" )
	scale = math.max( 0.01, tonumber( scale ) or 1 )
	color = color or UI.Colors.text
	verticalAlign = verticalAlign or TEXT_ALIGN_TOP
	if type( Font.Draw ) == "function" then
		return Font.Draw( text, x, y, {
			font = fontName or "default",
			scale = scale,
			color = color,
			align = align,
			verticalAlign = verticalAlign,
			shadow = shadow == true,
		} )
	end
	return draw.SimpleText( text, "DermaDefault", x, y, color, align, verticalAlign )
end

local function createClientSetting( name, default, help, minimum, maximum )
	local existing = GetConVar and GetConVar( name ) or nil
	if existing then return existing end
	if not CreateClientConVar then return nil end
	return CreateClientConVar( name, tostring( default ), true, false, help, minimum, maximum )
end

UI.HUDScaleConVar = UI.HUDScaleConVar or createClientSetting( "mc_inventory_hud_scale", 0,
	"Minecraft inventory HUD scale: 0 uses the Java-style automatic integer scale", 0, MAX_GUI_SCALE )
UI.HUDOffsetXConVar = UI.HUDOffsetXConVar or createClientSetting( "mc_inventory_hud_offset_x", 0,
	"Minecraft inventory HUD horizontal offset in screen pixels", -4096, 4096 )
UI.HUDOffsetYConVar = UI.HUDOffsetYConVar or createClientSetting( "mc_inventory_hud_offset_y", 0,
	"Minecraft inventory HUD vertical offset in screen pixels", -4096, 4096 )
UI.UIScaleConVar = UI.UIScaleConVar or createClientSetting( "mc_inventory_ui_scale", 0,
	"Minecraft inventory screen scale: 0 uses the Java-style automatic integer scale", 0, MAX_GUI_SCALE )
UI.UIOffsetXConVar = UI.UIOffsetXConVar or createClientSetting( "mc_inventory_ui_offset_x", 0,
	"Minecraft inventory screen horizontal offset in screen pixels", -4096, 4096 )
UI.UIOffsetYConVar = UI.UIOffsetYConVar or createClientSetting( "mc_inventory_ui_offset_y", 0,
	"Minecraft inventory screen vertical offset in screen pixels", -4096, 4096 )

local function convarNumber( convar, fallback )
	if convar and convar.GetFloat then
		local value = tonumber( convar:GetFloat() )
		if value and value == value then return value end
	end
	return fallback
end

function UI.AutoGuiScale()
	-- Window.calculateScale( 0, false ): choose the largest integer scale that
	-- still leaves at least 320x240 logical GUI pixels. The cap is only a GMod
	-- safety limit for pathological render targets; it is above current 8K use.
	return math.Clamp( math.floor( math.min( ScrW() / 320, ScrH() / 240 ) ), 1, MAX_GUI_SCALE )
end

local function selectedScale( convar )
	local requested = math.floor( convarNumber( convar, 0 ) )
	return requested > 0 and math.Clamp( requested, 1, MAX_GUI_SCALE ) or UI.AutoGuiScale()
end

function UI.GuiScale()
	return selectedScale( UI.UIScaleConVar )
end

function UI.HUDScale()
	return selectedScale( UI.HUDScaleConVar )
end

function UI.HUDOffset()
	return math.floor( convarNumber( UI.HUDOffsetXConVar, 0 ) ),
		math.floor( convarNumber( UI.HUDOffsetYConVar, 0 ) )
end

function UI.UIOffset()
	return math.floor( convarNumber( UI.UIOffsetXConVar, 0 ) ),
		math.floor( convarNumber( UI.UIOffsetYConVar, 0 ) )
end

local function utf8Prefix( text, count )
	count = math.max( 0, math.floor( tonumber( count ) or 0 ) )
	if count == 0 then return "" end
	if utf8 and utf8.sub then return utf8.sub( text, 1, count ) end
	local byteIndex = 1
	for _ = 1, count do
		local first = string.byte( text, byteIndex )
		if not first then return text end
		local width = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or first < 0xF8 and 4 or 1
		byteIndex = math.min( #text + 1, byteIndex + width )
	end
	return string.sub( text, 1, byteIndex - 1 )
end

local function utf8Length( text )
	if utf8 and utf8.len then return utf8.len( text ) or #text end
	local count, byteIndex = 0, 1
	while byteIndex <= #text do
		local first = string.byte( text, byteIndex )
		local width = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or first < 0xF8 and 4 or 1
		byteIndex, count = byteIndex + width, count + 1
	end
	return count
end

function UI.PaintBitmapTextEntry( entry, w, h )
	if not IsValid( entry ) then return true end
	local options = entry.MCBitmapTextOptions or {}
	local scale = math.max( 1, math.floor( tonumber( entry.MCBitmapScale ) or 1 ) )
	local padding = math.max( 0, tonumber( options.padding ) or 1 ) * scale
	local available = math.max( 0, w - padding * 2 )
	local text = tostring( entry:GetValue() or "" )
	local focused = entry.HasFocus and entry:HasFocus()
		or vgui and vgui.GetKeyboardFocus and vgui.GetKeyboardFocus() == entry
	local caret = entry.GetCaretPos and entry:GetCaretPos() or 0
	local caretWidth = UI.MeasureText( utf8Prefix( text, caret ), scale, options.font )
	local totalWidth = UI.MeasureText( text, scale, options.font )
	local scroll = focused and math.max( 0, caretWidth - available + scale ) or 0
	if not focused and totalWidth > available then scroll = 0 end
	local top = options.verticalOffset ~= nil and tonumber( options.verticalOffset ) * scale
		or math.floor( ( h - 8 * scale ) * 0.5 )
	local screenX, screenY = entry:LocalToScreen( 0, 0 )
	if render and render.SetScissorRect then
		render.SetScissorRect( screenX + padding, screenY, screenX + w - padding, screenY + h, true )
	end

	if focused and entry.GetHighlightPos then
		local ok, first, second = pcall( entry.GetHighlightPos, entry )
		if ok and tonumber( first ) and tonumber( second ) and first ~= second then
			local left = math.min( first, second )
			local right = math.max( first, second )
			local x0 = padding + UI.MeasureText( utf8Prefix( text, left ), scale, options.font ) - scroll
			local x1 = padding + UI.MeasureText( utf8Prefix( text, right ), scale, options.font ) - scroll
			surface.SetDrawColor( options.highlightColor or Color( 120, 150, 190, 120 ) )
			surface.DrawRect( x0, top, math.max( scale, x1 - x0 ), 8 * scale )
		end
	end

	local shown = text
	local color = entry.MCBitmapColor or options.color or Color( 45, 45, 45, 255 )
	if shown == "" and not focused and entry.GetPlaceholderText then
		shown = tostring( entry:GetPlaceholderText() or "" )
		color = options.placeholderColor or Color( 128, 128, 128, 255 )
	end
	UI.DrawText( shown, padding - scroll, top, scale, color, TEXT_ALIGN_LEFT,
		options.shadow == true, TEXT_ALIGN_TOP, options.font )
	local focusTime = tonumber( entry.MCBitmapFocusTime ) or 0
	if focused and math.floor( math.max( 0, RealTime() - focusTime ) / 0.3 ) % 2 == 0 then
		local cursorColor = options.cursorColor or color
		local textLength = utf8Length( text )
		local maxLength = tonumber( options.maxLength )
		if not maxLength or maxLength ~= maxLength or maxLength == math.huge then
			maxLength = math.huge
		else
			maxLength = math.max( 0, math.floor( maxLength ) )
		end
		local append = caret >= textLength and textLength < maxLength
		if append then
			local cursorX = padding + caretWidth - scroll + ( text ~= "" and scale or 0 )
			UI.DrawText( "_", cursorX, top, scale, cursorColor, TEXT_ALIGN_LEFT,
				options.shadow == true, TEXT_ALIGN_TOP, options.font )
		else
			local cursorX = padding + caretWidth - scroll
			surface.SetDrawColor( cursorColor )
			surface.DrawRect( cursorX, top - scale, scale, 11 * scale )
		end
	end
	if render and render.SetScissorRect then render.SetScissorRect( 0, 0, 0, 0, false ) end
	return true
end

function UI.ConfigureBitmapTextEntry( entry, options )
	if not IsValid( entry ) then return false end
	entry.MCBitmapTextOptions = type( options ) == "table" and options or {}
	entry.MCBitmapColor = entry.MCBitmapTextOptions.color
	entry:SetTextColor( Color( 0, 0, 0, 0 ) )
	entry:SetCursorColor( Color( 0, 0, 0, 0 ) )
	entry:SetDrawBackground( false )
	entry.MCBitmapFocusTime = RealTime()
	local oldOnGetFocus = entry.OnGetFocus
	entry.OnGetFocus = function( self, ... )
		self.MCBitmapFocusTime = RealTime()
		if oldOnGetFocus then return oldOnGetFocus( self, ... ) end
	end
	entry.Paint = UI.PaintBitmapTextEntry
	return true
end

if cvars and cvars.AddChangeCallback then
	for _, name in ipairs( { "mc_inventory_ui_scale", "mc_inventory_ui_offset_x", "mc_inventory_ui_offset_y" } ) do
		cvars.AddChangeCallback( name, function()
			if IsValid( UI.Screen ) and UI.Screen.Reflow then UI.Screen:Reflow() end
		end, "mc_inventory_ui_layout" )
	end
end

function UI.RarityColor( rarity )
	rarity = string.lower( tostring( rarity or "common" ) )
	return UI.Colors[rarity] or UI.Colors.common
end
