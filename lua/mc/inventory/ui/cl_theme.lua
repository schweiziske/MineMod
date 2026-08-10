--[[----------------------------------------------------------------------------
    Minecraft inventory UI theme and low-allocation drawing helpers.

    The container textures are the visual system.  This file only supplies the
    built-in GMod font text, crisp texture drawing and semantic colors;
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
UI.PixelMaterials = UI.PixelMaterials or {}

local function sourceMaterial( path, flags )
	local key = tostring( path ) .. "|" .. tostring( flags or "" )
	local cached = UI.Materials[key]
	if cached then return cached end
	local value = Material( path, flags or "vertexcolor vertexalpha nocull" )
	UI.Materials[key] = value
	return value
end

local function pixelMaterial( path, flags )
	local sourcePath = tostring( path or "" )
	local sourceFlags = tostring( flags or "vertexcolor vertexalpha nocull" )
	local key = sourcePath .. "|" .. sourceFlags .. "|pixel_v2"
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

	local identity = sourcePath .. "|" .. sourceFlags
	local suffix = util and util.CRC and util.CRC( identity ) or string.gsub( identity, "[^%w_]", "_" )
	local value = CreateMaterial( "mc_inventory_pixel_" .. tostring( suffix ), "UnlitGeneric", {
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
		UI.PixelMaterials[key] = value
		return value
	end

	UI.PixelMaterials[key] = source
	return source
end

function UI.GetMaterial( path )
	if not isstring( path ) or path == "" then return nil end
	return pixelMaterial( path, "vertexcolor vertexalpha nocull" )
end

function UI.GetGuiMaterial( name )
	return pixelMaterial( "mc/gui/" .. tostring( name ) .. ".png", "vertexcolor vertexalpha nocull" )
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

local INVENTORY_FONTS = {}
if surface and surface.CreateFont then
	for fontScale = 1, 4 do
		local name = "MCInventoryRoboto" .. fontScale
		INVENTORY_FONTS[fontScale] = name
		surface.CreateFont( name, {
			font = "Roboto",
			size = 8 * fontScale,
			weight = 500,
			antialias = true,
			extended = true,
		} )
	end
end

local function inventoryFont( scale )
	local fontScale = math.Clamp( math.floor( tonumber( scale ) or 1 ), 1, 4 )
	return INVENTORY_FONTS[fontScale] or "Roboto"
end

function UI.MeasureText( text, scale )
	text = tostring( text or "" )
	scale = tonumber( scale ) or 1
	local font = inventoryFont( scale )
	if surface and surface.SetFont and surface.GetTextSize then
		surface.SetFont( font )
		local width = surface.GetTextSize( text )
		return width
	end
	return #text * 6 * scale
end

function UI.DrawText( text, x, y, scale, color, align, _shadow, verticalAlign )
	text = tostring( text or "" )
	scale = tonumber( scale ) or 1
	color = color or UI.Colors.text
	verticalAlign = verticalAlign or TEXT_ALIGN_TOP
	local font = inventoryFont( scale )
	local width = UI.MeasureText( text, scale )
	if _shadow == true then
		-- Keep the shadow at one screen pixel; scaling it with the bitmap UI made
		-- the old text look like it had a heavy outline at larger resolutions.
		draw.SimpleText( text, font, x + 2, y + 2, UI.Colors.textShadow, align, verticalAlign )
	end
	draw.SimpleText( text, font, x, y, color, align, verticalAlign )
	return width
end

function UI.GuiScale()
	local width, height = ScrW(), ScrH()
	return math.Clamp( math.floor( math.min( width / 320, height / 240 ) ), 2, 4 )
end

function UI.RarityColor( rarity )
	rarity = string.lower( tostring( rarity or "common" ) )
	return UI.Colors[rarity] or UI.Colors.common
end
