--[[----------------------------------------------------------------------------
	MC : client UI helpers (block icons, palette picker, fonts)
------------------------------------------------------------------------------]]

MC = MC or {}

surface.CreateFont( "mc_hud", { font = "Roboto", size = 22, weight = 600 } )
surface.CreateFont( "mc_hud_small", { font = "Roboto", size = 16, weight = 500 } )
surface.CreateFont( "mc_hud_big", { font = "Roboto", size = 28, weight = 700 } )
surface.CreateFont( "mc_hud_fit_24", { font = "Roboto", size = 24, weight = 700 } )
surface.CreateFont( "mc_hud_fit_20", { font = "Roboto", size = 20, weight = 700 } )
surface.CreateFont( "mc_hud_fit_16", { font = "Roboto", size = 16, weight = 700 } )

function MC.DrawFittedText( text, font, fallbackFonts, x, y, color, ax, ay, maxw )
	local useFont = font
	if maxw and maxw > 0 then
		surface.SetFont( useFont )
		local tw = surface.GetTextSize( text )
		for _, f in ipairs( fallbackFonts or {} ) do
			if tw <= maxw then break end
			useFont = f
			surface.SetFont( useFont )
			tw = surface.GetTextSize( text )
		end
	end
	draw.SimpleText( text, useFont, x, y, color, ax, ay )
end

function MC.DrawTile( tile, x, y, w, h )
	local u0, v0, u1, v1 = MC.TileUV( tile )
	surface.SetMaterial( MC.Material )
	surface.SetDrawColor( 255, 255, 255, 255 )
	surface.DrawTexturedRectUV( x, y, w, h, u0, v0, u1, v1 )
end

function MC.DrawBlockIcon( id, x, y, w, h )
	if not MC.Blocks[id] then return end
	MC.DrawTile( MC.BlockIconTile( id ), x, y, w, h )
end

local ICON_UV_FLAGS = {
	{ 0, 0 },
	{ 1, 0 },
	{ 1, 1 },
	{ 0, 1 },
}

local function iconRotatedUV( uf, vf, rot, flipU, flipV )
	rot = ( rot or 0 ) % 4
	if rot == 1 then uf, vf = vf, 1 - uf
	elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
	elseif rot == 3 then uf, vf = 1 - vf, uf end
	if flipU then uf = 1 - uf end
	if flipV then vf = 1 - vf end
	return uf, vf
end

local function iconUVPoint( tile, flags, rot, flipU, flipV )
	local u0, v0, u1, v1 = MC.TileUV( tile )
	local uf, vf = iconRotatedUV( flags[1], flags[2], rot, flipU, flipV )
	return uf == 1 and u1 or u0, vf == 1 and v1 or v0
end

local function iconVertex( point, tile, flags, rot, flipU, flipV )
	local u, v = iconUVPoint( tile, flags, rot, flipU, flipV )
	return { x = point.x, y = point.y, u = u, v = v }
end

local function drawIconFace( tile, points, shade, rot, flipU, flipV )
	surface.SetMaterial( MC.Material )
	surface.SetDrawColor( shade, shade, shade, 255 )
	surface.DrawPoly( {
		iconVertex( points[1], tile, ICON_UV_FLAGS[1], rot, flipU, flipV ),
		iconVertex( points[2], tile, ICON_UV_FLAGS[2], rot, flipU, flipV ),
		iconVertex( points[3], tile, ICON_UV_FLAGS[3], rot, flipU, flipV ),
		iconVertex( points[4], tile, ICON_UV_FLAGS[4], rot, flipU, flipV ),
	} )
end

function MC.DrawMinecraftBlockIcon( id, x, y, w, h )
	local b = MC.Blocks[id]
	if not b then return end

	local orient = MC.DefaultOrient and MC.DefaultOrient( id ) or 0
	if MC.BlockIsFullCube and not MC.BlockIsFullCube( id, orient ) then
		MC.DrawBlockIcon( id, x, y, w, h )
		return
	end

	local face = MC.Face or { TOP = 1, XP = 3, YP = 5 }
	local topTile, topRot, topFlipU, topFlipV = MC.BlockFace( id, face.TOP, orient )
	local rightTile, rightRot, rightFlipU, rightFlipV = MC.BlockFace( id, face.XP, orient )
	local leftTile, leftRot, leftFlipU, leftFlipV = MC.BlockFace( id, face.YP, orient )

	local size = math.min( w, h )
	local cx = x + w * 0.5
	local topY = y + h * 0.1
	local halfW = size * 0.38
	local halfH = size * 0.2
	local cubeH = size * 0.43

	local pTop = { x = cx, y = topY }
	local pRight = { x = cx + halfW, y = topY + halfH }
	local pBottom = { x = cx, y = topY + halfH * 2 }
	local pLeft = { x = cx - halfW, y = topY + halfH }
	local pRightBottom = { x = pRight.x, y = pRight.y + cubeH }
	local pBottomDown = { x = pBottom.x, y = pBottom.y + cubeH }
	local pLeftBottom = { x = pLeft.x, y = pLeft.y + cubeH }

	drawIconFace( leftTile, { pLeft, pBottom, pBottomDown, pLeftBottom }, 170, leftRot, leftFlipU, leftFlipV )
	drawIconFace( rightTile, { pBottom, pRight, pRightBottom, pBottomDown }, 215, rightRot, rightFlipU, rightFlipV )
	drawIconFace( topTile, { pTop, pRight, pBottom, pLeft }, 255, topRot, topFlipU, topFlipV )
end

MC.CreativeCategories = MC.CreativeCategories or {
	{ id = "all", label = "全部" },
	{ id = "building", label = "建筑方块" },
	{ id = "natural", label = "自然方块" },
	{ id = "functional", label = "功能方块" },
	{ id = "redstone", label = "红石" },
	{ id = "decoration", label = "装饰" },
	{ id = "transparent", label = "透明/玻璃" },
	{ id = "plants", label = "植物" },
}
local CREATIVE_GRID_COLS = 9
local CREATIVE_GRID_ROWS = 4
local CREATIVE_PAGE_SIZE = CREATIVE_GRID_COLS * CREATIVE_GRID_ROWS
local CREATIVE_HOTBAR_SIZE = 9
local CREATIVE_HOTBAR_DEFAULTS = {
	"minecraft:stone",
	"minecraft:dirt",
	"minecraft:oak_planks",
	"minecraft:cobblestone",
	"minecraft:glass",
	"minecraft:oak_fence",
	"minecraft:oak_stairs",
	"minecraft:oak_slab",
	"minecraft:torch",
}
local CREATIVE_HOTBAR_KEYS = {
	[KEY_1] = 1,
	[KEY_2] = 2,
	[KEY_3] = 3,
	[KEY_4] = 4,
	[KEY_5] = 5,
	[KEY_6] = 6,
	[KEY_7] = 7,
	[KEY_8] = 8,
	[KEY_9] = 9,
}

MC.CreativeHotbar = MC.CreativeHotbar or { selected = 1, slots = {} }

local function normalizeHotbarSlot( slot )
	slot = math.floor( tonumber( slot ) or 1 )
	return math.Clamp( slot, 1, CREATIVE_HOTBAR_SIZE )
end

local function normalizeHotbarID( id )
	id = tonumber( id )
	if not id then return nil end
	id = math.floor( id )
	if MC.IsValidBlock and MC.IsValidBlock( id ) then return id end
	return nil
end

local function resolveHotbarDefault( slot )
	local name = CREATIVE_HOTBAR_DEFAULTS[slot]
	local resolved = name and MC.ResolveBlock and MC.ResolveBlock( name ) or nil
	if resolved and normalizeHotbarID( resolved.id ) then return resolved.id end
	for _, id in ipairs( MC.BlockList or {} ) do
		local valid = normalizeHotbarID( id )
		if valid then return valid end
	end
	return 1
end

function MC.EnsureCreativeHotbar()
	local hotbar = MC.CreativeHotbar or {}
	hotbar.slots = hotbar.slots or {}
	hotbar.selected = normalizeHotbarSlot( hotbar.selected )
	for i = 1, CREATIVE_HOTBAR_SIZE do
		hotbar.slots[i] = normalizeHotbarID( hotbar.slots[i] ) or resolveHotbarDefault( i )
	end
	MC.CreativeHotbar = hotbar
	return hotbar
end

function MC.GetCreativeHotbarSelectedSlot()
	return MC.EnsureCreativeHotbar().selected
end

function MC.GetCreativeHotbarSelectedID( ply )
	local hotbar = MC.EnsureCreativeHotbar()
	local id = normalizeHotbarID( hotbar.slots[hotbar.selected] )
	if id then return id end
	if IsValid( ply ) then
		id = normalizeHotbarID( ply:GetNWInt( "mc_block", 1 ) )
		if id then return id end
	end
	return resolveHotbarDefault( 1 )
end

function MC.SelectCreativeHotbarSlot( slot, noCommand )
	local hotbar = MC.EnsureCreativeHotbar()
	hotbar.selected = normalizeHotbarSlot( slot )
	local id = normalizeHotbarID( hotbar.slots[hotbar.selected] )
	if id and not noCommand then
		RunConsoleCommand( "mc_block_sel", tostring( id ) )
	end
	return id ~= nil, id
end

function MC.SetCreativeHotbarSlot( slot, id, noCommand )
	id = normalizeHotbarID( id )
	if not id then return false end
	local hotbar = MC.EnsureCreativeHotbar()
	hotbar.selected = normalizeHotbarSlot( slot )
	hotbar.slots[hotbar.selected] = id
	if not noCommand then
		RunConsoleCommand( "mc_block_sel", tostring( id ) )
	end
	return true
end

function MC.PickCreativeHotbarBlock( ply )
	ply = ply or LocalPlayer()
	if not IsValid( ply ) or not MC.PlayerBlockAim then return false end
	local hit = MC.PlayerBlockAim( ply )
	local id = hit and normalizeHotbarID( hit.Block )
	if not id then return false end
	local ok = MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
	return ok
end

function MC.DrawCreativeHotbar( cx, y, opts )
	opts = opts or {}
	local hotbar = MC.EnsureCreativeHotbar()
	local slotSize = opts.slotSize or 54
	local gap = opts.gap or 4
	local totalW = CREATIVE_HOTBAR_SIZE * slotSize + ( CREATIVE_HOTBAR_SIZE - 1 ) * gap
	local x = math.floor( cx - totalW * 0.5 )

	draw.RoundedBox( 4, x - 8, y - 8, totalW + 16, slotSize + 16, Color( 8, 9, 11, 190 ) )
	for i = 1, CREATIVE_HOTBAR_SIZE do
		local sx = x + ( i - 1 ) * ( slotSize + gap )
		local selected = hotbar.selected == i
		local id = normalizeHotbarID( hotbar.slots[i] )
		draw.RoundedBox( 3, sx, y, slotSize, slotSize, selected and Color( 235, 235, 210, 245 ) or Color( 28, 30, 35, 235 ) )
		draw.RoundedBox( 2, sx + 3, y + 3, slotSize - 6, slotSize - 6, selected and Color( 66, 68, 72, 245 ) or Color( 42, 45, 51, 245 ) )
		if id then
			MC.DrawMinecraftBlockIcon( id, sx + 7, y + 7, slotSize - 14, slotSize - 14 )
		end
		draw.SimpleText( tostring( i ), "mc_hud_small", sx + 6, y + 4, selected and Color( 255, 245, 160 ) or Color( 220, 225, 235, 210 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	return x, y, totalW, slotSize
end

local function activeCreativePlacer( ply )
	if not IsValid( ply ) then return false end
	local wep = ply:GetActiveWeapon()
	return IsValid( wep ) and wep:GetClass() == "mc_creative_placer"
end

local function textEntryHasFocus()
	local focus = vgui.GetKeyboardFocus and vgui.GetKeyboardFocus() or nil
	if not IsValid( focus ) then return false end
	local class = focus.GetClassName and focus:GetClassName() or ""
	return class == "TextEntry" or class == "DTextEntry"
end

local lastCreativePickAt = 0
local function pickCreativeHotbarBlockDebounced( ply )
	local now = CurTime()
	if now - lastCreativePickAt < 0.08 then return true end
	lastCreativePickAt = now
	return MC.PickCreativeHotbarBlock( ply )
end

hook.Remove( "PlayerBindPress", "mc_creative_hotbar_binds" )
hook.Add( "PlayerBindPress", "mc_creative_hotbar_binds", function( ply, bind, pressed )
	if not pressed or not activeCreativePlacer( ply ) then return end
	local slot = string.match( bind or "", "^slot([1-9])$" )
	if slot then
		if not textEntryHasFocus() then
			MC.SelectCreativeHotbarSlot( tonumber( slot ) )
		end
		return true
	end
	if bind == "+attack3" then
		pickCreativeHotbarBlockDebounced( ply )
		return true
	end
end )

hook.Remove( "PlayerButtonDown", "mc_creative_hotbar_buttons" )
hook.Add( "PlayerButtonDown", "mc_creative_hotbar_buttons", function( ply, button )
	if not activeCreativePlacer( ply ) then return end
	if button == MOUSE_MIDDLE then
		pickCreativeHotbarBlockDebounced( ply )
	end
end )

local function blockText( b )
	return string.lower( table.concat( {
		tostring( b and b.name or "" ),
		tostring( b and b.mcid or "" ),
		tostring( b and b.disp or "" ),
	}, " " ) )
end

local function textHas( text, ... )
	for _, needle in ipairs( { ... } ) do
		if string.find( text, needle, 1, true ) then return true end
	end
	return false
end

local function blockMatchesSearch( b, search )
	search = string.Trim( string.lower( tostring( search or "" ) ) )
	if search == "" then return true end
	return string.find( blockText( b ), search, 1, true ) ~= nil
end

function MC.CreativeCategoryForBlock( b )
	local text = blockText( b )
	if textHas( text, "glass", "pane", "ice", "slime", "honey", "water" ) then return "transparent" end
	if textHas( text, "sapling", "leaves", "flower", "tulip", "grass", "moss", "bush", "vines", "vine", "coral", "kelp", "seagrass", "cactus", "crop", "wheat", "carrot", "potato", "beetroot" ) then return "plants" end
	if textHas( text, "redstone", "repeater", "comparator", "piston", "observer", "dispenser", "dropper", "hopper", "lever", "button", "pressure_plate", "target", "rail", "detector_rail", "activator_rail" ) then return "redstone" end
	if textHas( text, "crafting", "furnace", "chest", "barrel", "anvil", "enchanting", "brewing", "cauldron", "bed", "door", "trapdoor", "ladder", "scaffolding", "sign", "bell", "lantern", "torch", "campfire", "beacon", "table", "lectern", "loom", "stonecutter", "grindstone" ) then return "functional" end
	if textHas( text, "ore", "stone", "dirt", "sand", "gravel", "clay", "mud", "snow", "netherrack", "end_stone", "deepslate", "tuff", "calcite", "basalt", "soil", "nylium", "obsidian" ) then return "natural" end
	if textHas( text, "wool", "carpet", "banner", "candle", "pot", "skull", "head", "painting", "frame", "bed", "shulker", "terracotta", "glazed" ) then return "decoration" end
	return "building"
end

function MC.BuildCreativeBlockGroups( search )
	local groups = {}
	for _, cat in ipairs( MC.CreativeCategories ) do
		groups[cat.id] = {}
	end
	for _, id in ipairs( MC.BlockList or {} ) do
		local b = MC.Blocks[id]
		if b and blockMatchesSearch( b, search ) then
			groups.all[#groups.all + 1] = id
			local cat = MC.CreativeCategoryForBlock( b )
			groups[cat] = groups[cat] or {}
			groups[cat][#groups[cat] + 1] = id
		end
	end
	return groups
end

local function clearLayout( layout )
	for _, child in ipairs( layout:GetChildren() ) do
		child:Remove()
	end
end

local function layoutCreativeGridSlots( layout, w, h )
	local gap = 6
	local usableW = math.max( 1, w - gap * ( CREATIVE_GRID_COLS - 1 ) )
	local usableH = math.max( 1, h - gap * ( CREATIVE_GRID_ROWS - 1 ) )
	local baseW = math.floor( usableW / CREATIVE_GRID_COLS )
	local baseH = math.floor( usableH / CREATIVE_GRID_ROWS )
	local extraW = usableW - baseW * CREATIVE_GRID_COLS
	local extraH = usableH - baseH * CREATIVE_GRID_ROWS
	local children = layout:GetChildren()

	local y = 0
	for row = 1, CREATIVE_GRID_ROWS do
		local cellH = baseH + ( row <= extraH and 1 or 0 )
		local x = 0
		for col = 1, CREATIVE_GRID_COLS do
			local cellW = baseW + ( col <= extraW and 1 or 0 )
			local child = children[( row - 1 ) * CREATIVE_GRID_COLS + col]
			if IsValid( child ) then
				child:SetPos( x, y )
				child:SetSize( cellW, cellH )
			end
			x = x + cellW + gap
		end
		y = y + cellH + gap
	end
end

local CREATIVE_UI = {
	frame = Color( 30, 32, 37, 250 ),
	title = Color( 18, 20, 24, 255 ),
	panel = Color( 24, 26, 30, 245 ),
	panelInner = Color( 13, 15, 18, 230 ),
	control = Color( 44, 48, 55, 245 ),
	controlHover = Color( 80, 92, 112, 245 ),
	controlDown = Color( 104, 112, 132, 245 ),
	controlDisabled = Color( 42, 44, 48, 160 ),
	accent = Color( 236, 230, 190, 245 ),
	text = Color( 235, 240, 248, 245 ),
	textDim = Color( 165, 174, 188, 220 ),
}

local function paintCreativeButtonSurface( s, w, h, label )
	local enabled = s:IsEnabled()
	local bg = enabled and CREATIVE_UI.control or CREATIVE_UI.controlDisabled
	if enabled and s:IsDown() then
		bg = CREATIVE_UI.controlDown
	elseif enabled and s:IsHovered() then
		bg = CREATIVE_UI.controlHover
	end

	draw.RoundedBox( 3, 0, 0, w, h, bg )
	draw.RoundedBox( 2, 3, 3, w - 6, h - 6, Color( 20, 22, 26, enabled and 210 or 120 ) )
	surface.SetDrawColor( enabled and Color( 120, 130, 148, 160 ) or Color( 70, 75, 84, 120 ) )
	surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	draw.SimpleText( label or "", "mc_hud_small", w * 0.5, h * 0.5, enabled and CREATIVE_UI.text or CREATIVE_UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

function MC.StyleCreativePagerButton( btn, label )
	if not IsValid( btn ) then return end
	btn:SetText( "" )
	btn.Paint = function( s, w, h )
		paintCreativeButtonSurface( s, w, h, label )
	end
end

function MC.StyleCreativeGridPanel( panel )
	if not IsValid( panel ) then return end
	panel.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, CREATIVE_UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, CREATIVE_UI.panelInner )
	end
end

function MC.StyleCreativePropertySheet( tabs )
	if not IsValid( tabs ) then return end
	tabs.Paint = function( _, w, h )
		draw.RoundedBox( 5, 0, 0, w, h, CREATIVE_UI.panel )
		draw.RoundedBox( 4, 8, 28, w - 16, h - 36, CREATIVE_UI.panelInner )
	end
end

local function addCreativeButton( layout, id, onSelect, frame, closeOnSelect )
	local b = MC.Blocks[id]
	if not b then return end
	local btn = layout:Add( "DButton" )
	btn:SetSize( 96, 108 )
	btn:SetText( "" )

	local hint = MC.BlockStateHint( id )
	btn:SetTooltip( b.disp .. "\n" .. ( b.mcid or b.name or tostring( id ) ) .. ( hint ~= "" and "\n" .. hint or "" ) )

	btn.Paint = function( s, w, h )
		local hotbar = MC.EnsureCreativeHotbar()
		local active = hotbar.slots[hotbar.selected] == id
		local bg = active and Color( 76, 82, 70 ) or ( s:IsHovered() and Color( 80, 92, 112 ) or Color( 43, 45, 50 ) )
		draw.RoundedBox( 3, 0, 0, w, h, bg )
		if active then
			surface.SetDrawColor( 235, 225, 170, 230 )
			surface.DrawOutlinedRect( 1, 1, w - 2, h - 2, 2 )
		end
		local icon = math.min( w - 22, h - 38, 76 )
		MC.DrawMinecraftBlockIcon( id, w * 0.5 - icon * 0.5, 8, icon, icon )
		MC.DrawFittedText( b.disp, "mc_hud_small", { "mc_hud_fit_16" }, w * 0.5, h - 17, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 8 )
	end

	btn.DoClick = function()
		onSelect( id )
		if closeOnSelect and IsValid( frame ) then frame:Close() end
	end
end

local function createCreativeHotbarPanel( parent )
	local panel = vgui.Create( "DPanel", parent )
	panel:SetTall( 86 )
	panel.Paint = function( _, w, h )
		draw.RoundedBox( 5, 0, 0, w, h, Color( 24, 26, 30, 245 ) )
		draw.RoundedBox( 4, 8, 8, w - 16, h - 16, Color( 13, 15, 18, 210 ) )
	end

	local buttons = {}
	for i = 1, CREATIVE_HOTBAR_SIZE do
		local btn = vgui.Create( "DButton", panel )
		btn:SetText( "" )
		buttons[i] = btn
		btn.DoClick = function()
			MC.SelectCreativeHotbarSlot( i )
		end
		btn.Paint = function( s, w, h )
			local hotbar = MC.EnsureCreativeHotbar()
			local selected = hotbar.selected == i
			local id = normalizeHotbarID( hotbar.slots[i] )
			local b = id and MC.Blocks[id] or nil
			local bg = selected and Color( 236, 230, 190, 245 ) or ( s:IsHovered() and Color( 80, 92, 112 ) or Color( 44, 48, 55 ) )
			draw.RoundedBox( 4, 0, 0, w, h, bg )
			draw.RoundedBox( 3, 4, 4, w - 8, h - 8, selected and Color( 58, 60, 64 ) or Color( 34, 37, 43 ) )
			draw.SimpleText( tostring( i ), "mc_hud_small", 8, 6, selected and Color( 255, 244, 170 ) or Color( 205, 212, 224 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			if id then
				MC.DrawMinecraftBlockIcon( id, w * 0.5 - 22, 11, 44, 44 )
			end
			if b then
				MC.DrawFittedText( b.disp, "mc_hud_small", { "mc_hud_fit_16" }, w * 0.5, h - 13, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 8 )
			end
		end
	end

	panel.PerformLayout = function( _, w, h )
		local slotW, gap = 76, 6
		local total = CREATIVE_HOTBAR_SIZE * slotW + ( CREATIVE_HOTBAR_SIZE - 1 ) * gap
		local x = math.floor( ( w - total ) * 0.5 )
		local y = 8
		for i, btn in ipairs( buttons ) do
			btn:SetPos( x + ( i - 1 ) * ( slotW + gap ), y )
			btn:SetSize( slotW, h - y * 2 )
		end
	end

	return panel
end

function MC.OpenCreativeInventory( onSelect, opts )
	if IsValid( MC.CreativeFrame ) then MC.CreativeFrame:Remove() end
	opts = opts or {}
	local closeOnSelect = opts.closeOnSelect
	if closeOnSelect == nil then closeOnSelect = true end
	onSelect = onSelect or function( id )
		MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
	end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "创造物品栏" )
	fr:SetSize( 960, 700 )
	fr:Center()
	fr:MakePopup()
	fr:SetKeyboardInputEnabled( true )
	fr.Paint = function( _, w, h )
		draw.RoundedBox( 6, 0, 0, w, h, Color( 30, 32, 37, 250 ) )
		draw.RoundedBoxEx( 6, 0, 0, w, 28, Color( 18, 20, 24, 255 ), true, true, false, false )
	end
	fr.OnKeyCodePressed = function( _, key )
		if key == KEY_ESCAPE then
			fr:Close()
			return
		end
		local slot = CREATIVE_HOTBAR_KEYS[key]
		if slot then
			MC.SelectCreativeHotbarSlot( slot )
		end
	end
	MC.CreativeFrame = fr

	local hotbar = createCreativeHotbarPanel( fr )
	hotbar:Dock( TOP )
	hotbar:DockMargin( 8, 8, 8, 6 )

	local search = vgui.Create( "DTextEntry", fr )
	search:Dock( TOP )
	search:DockMargin( 8, 0, 8, 6 )
	search:SetTall( 30 )
	search:SetPlaceholderText( "搜索中文名 / 英文名 / minecraft:id" )
	search:SetDrawBackground( false )
	search:SetTextColor( CREATIVE_UI.text )
	if search.SetCursorColor then search:SetCursorColor( CREATIVE_UI.accent ) end
	search.Paint = function( s, w, h )
		draw.RoundedBox( 3, 0, 0, w, h, Color( 16, 18, 22, 245 ) )
		surface.SetDrawColor( 88, 96, 110, s:HasFocus() and 190 or 110 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			draw.SimpleText( "搜索中文名 / 英文名 / minecraft:id", "mc_hud_small", 8, h * 0.5, CREATIVE_UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end
		s:DrawTextEntryText( CREATIVE_UI.text, Color( 95, 145, 210 ), CREATIVE_UI.text )
	end

	local controls = vgui.Create( "DPanel", fr )
	controls:Dock( BOTTOM )
	controls:DockMargin( 8, 0, 8, 8 )
	controls:SetTall( 30 )
	controls.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, CREATIVE_UI.panel )
		draw.RoundedBox( 3, 48, 3, w - 96, h - 6, CREATIVE_UI.panelInner )
	end

	local prev = vgui.Create( "DButton", controls )
	prev:Dock( LEFT )
	prev:SetWide( 42 )
	MC.StyleCreativePagerButton( prev, "<" )

	local next = vgui.Create( "DButton", controls )
	next:Dock( RIGHT )
	next:SetWide( 42 )
	MC.StyleCreativePagerButton( next, ">" )

	local pageLabel = vgui.Create( "DLabel", controls )
	pageLabel:Dock( FILL )
	pageLabel:SetContentAlignment( 5 )
	pageLabel:SetTextColor( CREATIVE_UI.text )

	local tabs = vgui.Create( "DPropertySheet", fr )
	tabs:Dock( FILL )
	tabs:DockMargin( 8, 0, 8, 8 )
	MC.StyleCreativePropertySheet( tabs )

	local layouts = {}
	local activeCategory = "all"
	local page = 1
	for _, cat in ipairs( MC.CreativeCategories ) do
		local grid = vgui.Create( "DPanel", tabs )
		MC.StyleCreativeGridPanel( grid )
		local layout = vgui.Create( "DPanel", grid )
		layout:Dock( FILL )
		layout:DockMargin( 8, 8, 8, 8 )
		layout.Paint = function() end
		layout.PerformLayout = layoutCreativeGridSlots
		layouts[cat.id] = layout
		local sheet = tabs:AddSheet( cat.label, grid, nil, false, false, cat.label )
		if sheet and sheet.Tab then
			sheet.Tab.MCCategoryID = cat.id
			sheet.Tab:SetTextColor( CREATIVE_UI.text )
			sheet.Tab.Paint = function( s, w, h )
				local active = tabs:GetActiveTab() == s
				local bg = active and CREATIVE_UI.panelInner or ( s:IsHovered() and CREATIVE_UI.controlHover or Color( 38, 42, 49, 245 ) )
				draw.RoundedBoxEx( 4, 0, 0, w, h, bg, true, true, false, false )
				surface.SetDrawColor( active and Color( 236, 230, 190, 180 ) or Color( 85, 92, 104, 120 ) )
				surface.DrawOutlinedRect( 0, 0, w, h, 1 )
			end
		end
	end

	local function rebuild()
		local groups = MC.BuildCreativeBlockGroups( search:GetValue() )
		local ids = groups[activeCategory] or {}
		local pages = math.max( 1, math.ceil( #ids / CREATIVE_PAGE_SIZE ) )
		page = math.Clamp( page, 1, pages )

		for _, cat in ipairs( MC.CreativeCategories ) do
			local layout = layouts[cat.id]
			clearLayout( layout )
			layout:InvalidateLayout( true )
		end

		local layout = layouts[activeCategory]
		local first = ( page - 1 ) * CREATIVE_PAGE_SIZE + 1
		local last = math.min( #ids, first + CREATIVE_PAGE_SIZE - 1 )
		for i = first, last do
			addCreativeButton( layout, ids[i], onSelect, fr, closeOnSelect )
		end
		layout:InvalidateLayout( true )
		pageLabel:SetText( string.format( "%d / %d    %d 个方块", page, pages, #ids ) )
		prev:SetEnabled( page > 1 )
		next:SetEnabled( page < pages )
	end

	tabs.OnActiveTabChanged = function( _, _, new )
		activeCategory = new and new.MCCategoryID or activeCategory
		page = 1
		rebuild()
	end
	search.OnChange = function()
		page = 1
		rebuild()
	end
	prev.DoClick = function()
		page = page - 1
		rebuild()
	end
	next.DoClick = function()
		page = page + 1
		rebuild()
	end
	rebuild()
end

function MC.DrawBlockGhost( id, orient, bx, by, bz, color )
	local base = MC.CellWorldMin( bx, by, bz )
	local boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
	for _, box in ipairs( boxes or { { 0, 0, 0, 1, 1, 1 } } ) do
		local mn = Vector( box[1] * MC.BS, box[2] * MC.BS, box[3] * MC.BS )
		local mx = Vector( box[4] * MC.BS, box[5] * MC.BS, box[6] * MC.BS )
		render.DrawWireframeBox( base, angle_zero, mn, mx, color or Color( 255, 255, 255, 230 ), true )
	end
end

local function drawLineLoop( points, color )
	for i = 1, #points do
		local j = i == #points and 1 or i + 1
		render.DrawLine( points[i], points[j], color, true )
	end
end

local function drawCrossOutline( base, color )
	local bs = MC.BS
	local a, c = 0.08 * bs, 0.92 * bs
	local z0, z1 = 0, bs
	drawLineLoop( {
		base + Vector( a, a, z0 ),
		base + Vector( c, c, z0 ),
		base + Vector( c, c, z1 ),
		base + Vector( a, a, z1 ),
	}, color )
	drawLineLoop( {
		base + Vector( c, a, z0 ),
		base + Vector( a, c, z0 ),
		base + Vector( a, c, z1 ),
		base + Vector( c, a, z1 ),
	}, color )
end

function MC.DrawBlockOutline( id, orient, bx, by, bz, color )
	local base = MC.CellWorldMin( bx, by, bz )
	color = color or Color( 0, 0, 0, 235 )
	local b = MC.Blocks[id]
	if b and b.shape == "cross" then
		drawCrossOutline( base, color )
		return
	end

	local boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
	for _, box in ipairs( boxes or { { 0, 0, 0, 1, 1, 1 } } ) do
		local mn = Vector( box[1] * MC.BS, box[2] * MC.BS, box[3] * MC.BS )
		local mx = Vector( box[4] * MC.BS, box[5] * MC.BS, box[6] * MC.BS )
		render.DrawWireframeBox( base, angle_zero, mn, mx, color, true )
	end
end

function MC.OpenPalette( onSelect )
	if IsValid( MC.PaletteFrame ) then MC.PaletteFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "选择方块" )
	fr:SetSize( 780, 560 )
	fr:Center()
	fr:MakePopup()
	MC.PaletteFrame = fr

	local scroll = vgui.Create( "DScrollPanel", fr )
	scroll:Dock( FILL )

	local layout = vgui.Create( "DIconLayout", scroll )
	layout:Dock( FILL )
	layout:SetSpaceX( 8 )
	layout:SetSpaceY( 8 )

	for _, id in ipairs( MC.BlockList ) do
		local b = MC.Blocks[id]
		local btn = layout:Add( "DButton" )
		btn:SetSize( 104, 124 )
		btn:SetText( "" )

		local hint = MC.BlockStateHint( id )
		btn:SetTooltip( b.disp .. ( hint ~= "" and "\n" .. hint or "" ) )

		btn.Paint = function( s, w, h )
			draw.RoundedBox( 4, 0, 0, w, h, s:IsHovered() and Color( 80, 90, 110 ) or Color( 45, 47, 52 ) )
			MC.DrawBlockIcon( id, w * 0.5 - 36, 10, 72, 72 )
			MC.DrawFittedText( b.disp, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, w * 0.5, h - 24, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 10 )
		end

		btn.DoClick = function()
			onSelect( id )
			fr:Close()
		end
	end
end

hook.Remove( "HUDPaint", "mc_sync_progress" )
hook.Add( "HUDPaint", "mc_sync_progress", function()
	local p = MC.SyncProgress
	if not p or p.expected <= 0 then return end

	local now = CurTime()
	local complete = p.received >= p.expected and p.doneChunks >= p.chunks
	if complete and now - ( p.lastUpdate or 0 ) > 5 then return end

	local frac = math.Clamp( p.received / math.max( p.expected, 1 ), 0, 1 )
	local sw = ScrW()
	local w, h = 420, 18
	local x, y = sw * 0.5 - w * 0.5, 96
	local label = string.format( "MC 同步 %d/%d 方块  %d/%d 区块", p.received, p.expected, p.doneChunks, p.chunks )
	if complete then label = "MC 同步完成  " .. label end

	draw.RoundedBox( 4, x - 10, y - 28, w + 20, 58, Color( 0, 0, 0, 180 ) )
	draw.SimpleText( label, "mc_hud_small", x, y - 20, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	draw.RoundedBox( 3, x, y, w, h, Color( 35, 38, 42, 230 ) )
	draw.RoundedBox( 3, x, y, math.floor( w * frac ), h, complete and Color( 120, 220, 150, 240 ) or Color( 90, 180, 255, 240 ) )
end )
