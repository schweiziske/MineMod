--[[----------------------------------------------------------------------------
	MC : client UI helpers (block icons, palette picker, fonts)
------------------------------------------------------------------------------]]

MC = MC or {}

local function L( key, fallback, vars )
	return MC.T and MC.T( key, fallback, vars ) or fallback
end

local function blockDisplayText( blockOrID )
	local b = type( blockOrID ) == "table" and blockOrID or MC.Blocks[blockOrID]
	if not b then return "" end
	return MC.BlockDisplayName and MC.BlockDisplayName( b, b.dispZH or b.disp ) or b.disp
end

surface.CreateFont( "mc_hud", { font = "Roboto", size = 22, weight = 600 } )
surface.CreateFont( "mc_hud_small", { font = "Roboto", size = 16, weight = 500 } )
surface.CreateFont( "mc_hud_big", { font = "Roboto", size = 28, weight = 700 } )
surface.CreateFont( "mc_hud_fit_24", { font = "Roboto", size = 24, weight = 700 } )
surface.CreateFont( "mc_hud_fit_20", { font = "Roboto", size = 20, weight = 700 } )
surface.CreateFont( "mc_hud_fit_16", { font = "Roboto", size = 16, weight = 700 } )
surface.CreateFont( "mc_library_title", { font = "Roboto", size = 26, weight = 700 } )
surface.CreateFont( "mc_library_section", { font = "Roboto", size = 14, weight = 700 } )

-- Save/preset managers intentionally use a muted denim-blue palette.  Flat
-- surfaces, warm text and generous spacing keep it closer to a tidy library
-- than a glowing sci-fi dashboard.
MC.LibraryUI = {
	frame = Color( 228, 234, 235, 252 ),
	title = Color( 61, 84, 99, 255 ),
	panel = Color( 248, 248, 245, 252 ),
	panelInner = Color( 248, 248, 245, 252 ),
	sidebar = Color( 218, 228, 231, 252 ),
	row = Color( 238, 242, 241, 255 ),
	rowHover = Color( 226, 235, 237, 255 ),
	rowSelected = Color( 205, 222, 229, 255 ),
	control = Color( 92, 126, 145, 255 ),
	controlHover = Color( 106, 140, 158, 255 ),
	controlDown = Color( 76, 108, 126, 255 ),
	quiet = Color( 224, 232, 233, 255 ),
	quietHover = Color( 211, 223, 226, 255 ),
	danger = Color( 164, 83, 76, 255 ),
	dangerHover = Color( 181, 96, 87, 255 ),
	accent = Color( 82, 124, 147, 255 ),
	accentSoft = Color( 190, 213, 222, 255 ),
	input = Color( 252, 251, 247, 255 ),
	text = Color( 43, 54, 61, 255 ),
	textOnBlue = Color( 248, 247, 242, 255 ),
	textDim = Color( 104, 118, 124, 235 ),
	border = Color( 190, 203, 206, 220 ),
	error = Color( 169, 70, 66, 255 ),
	warm = Color( 205, 151, 82, 255 ),
}

local LIBRARY_GROUP_PATH = "mc/library_groups.json"
local LibraryGroupData

local function libraryTrim( value )
	return string.Trim( tostring( value or "" ) )
end

local function libraryGroupName( value )
	local name = libraryTrim( value )
	name = string.gsub( name, "[%c]", " " )
	name = libraryTrim( string.sub( name, 1, 32 ) )
	return name ~= "" and name or nil
end

local function libraryLoadGroups()
	if LibraryGroupData then return LibraryGroupData end

	local raw = file.Read( LIBRARY_GROUP_PATH, "DATA" )
	local parsed = raw and util.JSONToTable( raw ) or nil
	LibraryGroupData = istable( parsed ) and parsed or {}
	LibraryGroupData.v = 1
	LibraryGroupData.groups = istable( LibraryGroupData.groups ) and LibraryGroupData.groups or {}
	LibraryGroupData.assignments = istable( LibraryGroupData.assignments ) and LibraryGroupData.assignments or {}
	LibraryGroupData.assignments.save = istable( LibraryGroupData.assignments.save ) and LibraryGroupData.assignments.save or {}
	LibraryGroupData.assignments.preset = istable( LibraryGroupData.assignments.preset ) and LibraryGroupData.assignments.preset or {}

	local clean = {}
	local seen = {}
	for _, group in ipairs( LibraryGroupData.groups ) do
		local id = libraryTrim( group.id )
		local name = libraryGroupName( group.name )
		if id ~= "" and name and not seen[id] then
			clean[#clean + 1] = { id = id, name = name }
			seen[id] = true
		end
	end
	LibraryGroupData.groups = clean
	return LibraryGroupData
end

local function librarySaveGroups()
	local data = libraryLoadGroups()
	file.CreateDir( "mc" )
	local json = util.TableToJSON( data, true )
	if json then file.Write( LIBRARY_GROUP_PATH, json ) end
end

function MC.LibraryGetGroups()
	return libraryLoadGroups().groups
end

function MC.LibraryGetGroupName( groupID )
	groupID = libraryTrim( groupID )
	if groupID == "" then return nil end
	for _, group in ipairs( libraryLoadGroups().groups ) do
		if group.id == groupID then return group.name end
	end
	return nil
end

function MC.LibraryGetItemGroup( kind, itemName )
	local assignments = libraryLoadGroups().assignments[kind]
	if not assignments then return nil end
	local id = assignments[tostring( itemName or "" )]
	return MC.LibraryGetGroupName( id ) and id or nil
end

function MC.LibraryAssignItemGroup( kind, itemName, groupID )
	local data = libraryLoadGroups()
	if not data.assignments[kind] then return false end
	itemName = tostring( itemName or "" )
	if itemName == "" then return false end
	if groupID and not MC.LibraryGetGroupName( groupID ) then return false end
	data.assignments[kind][itemName] = groupID
	librarySaveGroups()
	return true
end

function MC.LibraryCreateGroup( requestedName )
	local name = libraryGroupName( requestedName )
	if not name then return nil, "empty" end
	local data = libraryLoadGroups()
	for _, group in ipairs( data.groups ) do
		if string.lower( group.name ) == string.lower( name ) then return nil, "exists" end
	end

	local id = "group_" .. util.CRC( name .. "|" .. tostring( SysTime() ) .. "|" .. tostring( math.random() ) )
	data.groups[#data.groups + 1] = { id = id, name = name }
	librarySaveGroups()
	return id
end

function MC.LibraryRenameGroup( groupID, requestedName )
	local name = libraryGroupName( requestedName )
	if not name then return false end
	local data = libraryLoadGroups()
	for _, group in ipairs( data.groups ) do
		if group.id ~= groupID and string.lower( group.name ) == string.lower( name ) then return false end
	end
	for _, group in ipairs( data.groups ) do
		if group.id == groupID then
			group.name = name
			librarySaveGroups()
			return true
		end
	end
	return false
end

function MC.LibraryDeleteGroup( groupID )
	local data = libraryLoadGroups()
	local removed = false
	for i = #data.groups, 1, -1 do
		if data.groups[i].id == groupID then
			table.remove( data.groups, i )
			removed = true
		end
	end
	if not removed then return false end
	for _, assignments in pairs( data.assignments ) do
		for itemName, assignedID in pairs( assignments ) do
			if assignedID == groupID then assignments[itemName] = nil end
		end
	end
	librarySaveGroups()
	return true
end

function MC.LibraryCollectMaps( items )
	local counts = {}
	for _, item in ipairs( items or {} ) do
		local map = libraryTrim( item.map )
		if map == "" then map = "unknown" end
		counts[map] = ( counts[map] or 0 ) + 1
	end
	local maps = {}
	for map, count in pairs( counts ) do maps[#maps + 1] = { name = map, count = count } end
	table.sort( maps, function( a, b )
		if a.name == game.GetMap() then return true end
		if b.name == game.GetMap() then return false end
		return a.name < b.name
	end )
	return maps
end

function MC.LibrarySortNewestFirst( items, timeField )
	table.sort( items or {}, function( a, b )
		local at = libraryTrim( a and a[timeField] )
		local bt = libraryTrim( b and b[timeField] )
		local aHasTime = at ~= "" and at ~= "?"
		local bHasTime = bt ~= "" and bt ~= "?"
		if aHasTime ~= bHasTime then return aHasTime end
		if at ~= bt then return at > bt end
		return string.lower( tostring( a and a.name or "" ) ) < string.lower( tostring( b and b.name or "" ) )
	end )
	return items
end

function MC.LibraryItemMatches( item, kind, mapFilter, groupFilter, search )
	local itemMap = libraryTrim( item and item.map )
	if mapFilter == "@current" and itemMap ~= game.GetMap() then return false end
	if mapFilter and string.StartWith( mapFilter, "map:" ) and itemMap ~= string.sub( mapFilter, 5 ) then return false end

	local assigned = MC.LibraryGetItemGroup( kind, item and item.name )
	if groupFilter == "@none" and assigned then return false end
	if groupFilter and groupFilter ~= "*" and groupFilter ~= "@none" and assigned ~= groupFilter then return false end

	search = string.lower( libraryTrim( search ) )
	if search ~= "" then
		local haystack = string.lower( tostring( item and item.name or "" ) .. " " .. itemMap )
		if not string.find( haystack, search, 1, true ) then return false end
	end
	return true
end

function MC.LibraryStyleButton( btn, label, kind, palette )
	local UI = palette or MC.LibraryUI
	btn:SetText( "" )
	btn:SetCursor( "hand" )
	btn.Paint = function( s, w, h )
		local bg, fg = UI.control, UI.textOnBlue
		if kind == "quiet" then bg, fg = UI.quiet, UI.text end
		if kind == "danger" then bg, fg = UI.danger, UI.textOnBlue end
		if not s:IsEnabled() then
			bg, fg = UI.quiet, UI.textDim
		elseif s:IsDown() then
			bg = kind == "danger" and UI.dangerHover or UI.controlDown
		elseif s:IsHovered() then
			bg = kind == "danger" and UI.dangerHover or ( kind == "quiet" and UI.quietHover or UI.controlHover )
		end
		surface.SetDrawColor( bg )
		surface.DrawRect( 0, 0, w, h )
		draw.SimpleText( label, "mc_hud_small", w * 0.5, h * 0.5, fg, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
end

function MC.LibraryStyleTextEntry( entry, placeholder, palette )
	local UI = palette or MC.LibraryUI
	entry:SetPlaceholderText( placeholder or "" )
	entry:SetPaintBackground( false )
	entry:SetTextColor( UI.text )
	if entry.SetCursorColor then entry:SetCursorColor( UI.accent ) end
	entry.Paint = function( s, w, h )
		surface.SetDrawColor( UI.input )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( s:HasFocus() and UI.accent or UI.border )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			draw.SimpleText( placeholder or "", "mc_hud_small", 10, h * 0.5, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end
		s:DrawTextEntryText( UI.text, UI.accent, UI.text )
	end
end

function MC.LibraryStyleCombo( combo, palette )
	local UI = palette or MC.LibraryUI
	combo:SetTextColor( UI.text )
	combo:SetFont( "mc_hud_small" )
	combo.UpdateColours = function( s )
		s:SetTextStyleColor( s:IsEnabled() and UI.text or UI.textDim )
	end
	if IsValid( combo.DropButton ) then
		combo.DropButton.Paint = function( _, w, h )
			draw.SimpleText( "▾", "mc_hud_small", w * 0.5, h * 0.5 - 1, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
	end
	combo.Paint = function( s, w, h )
		surface.SetDrawColor( UI.input )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( s:IsHovered() and UI.accent or UI.border )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		return false
	end
end

function MC.LibraryDrawPill( textValue, x, y, background, foreground )
	local text = tostring( textValue or "" )
	surface.SetFont( "mc_library_section" )
	local tw, th = surface.GetTextSize( text )
	local w, h = tw + 16, math.max( 22, th + 6 )
	surface.SetDrawColor( background or MC.LibraryUI.accentSoft )
	surface.DrawRect( x, y, w, h )
	draw.SimpleText( text, "mc_library_section", x + w * 0.5, y + h * 0.5, foreground or MC.LibraryUI.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	return w, h
end

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

function MC.DrawTile( tile, x, y, w, h, mat, tintCode, worldColor )
	local u0, v0, u1, v1 = MC.TileUV( tile )
	surface.SetMaterial( mat or MC.MaterialCreativeIcon or MC.Material )
	local r, g, b = 255, 255, 255
	if tintCode and tintCode ~= 0 and MC.BlockTintRGB then
		r, g, b = MC.BlockTintRGB( tintCode )
	end
	if worldColor then
		r = math.floor( r * ( worldColor.r or 255 ) / 255 + 0.5 )
		g = math.floor( g * ( worldColor.g or 255 ) / 255 + 0.5 )
		b = math.floor( b * ( worldColor.b or 255 ) / 255 + 0.5 )
	end
	surface.SetDrawColor( r, g, b, 255 )
	surface.DrawTexturedRectUV( x, y, w, h, u0, v0, u1, v1 )
end

-- Semi-transparent blocks (stained/tinted glass, ice, slime, honey) have low
-- texel alpha that the cutout atlas material's alpha test discards, so their icons
-- would render blank. Route those to the opaque atlas variant instead.
local function iconMaterialFor( id )
	if MC.MaterialIconOpaque and MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) then
		return MC.MaterialIconOpaque
	end
	return MC.MaterialCreativeIcon or MC.Material
end

function MC.DrawBlockIcon( id, x, y, w, h, stateId, materialOverride, worldColor )
	if not MC.Blocks[id] then return end
	if not stateId and MC.StateFromLegacy then stateId = MC.StateFromLegacy( id, 0 ) end
	local tintCode = stateId and MC.BlockStateTintCode and MC.BlockStateTintCode( stateId, id, 0 ) or 0
	MC.DrawTile( MC.BlockIconTile( id ), x, y, w, h, materialOverride or iconMaterialFor( id ), tintCode, worldColor )
end

local function iconRotatedUV( uf, vf, rot, flipU, flipV )
	rot = ( rot or 0 ) % 4
	if rot == 1 then uf, vf = vf, 1 - uf
	elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
	elseif rot == 3 then uf, vf = 1 - vf, uf end
	if flipU then uf = 1 - uf end
	if flipV then vf = 1 - vf end
	return uf, vf
end

-- A single textured, flat-shaded quad. uf/vf are face-space texture coords in
-- 0..1, lerped into the tile's atlas rect after the per-face rotate/flip; this
-- lets partial boxes (slabs, stairs, fence posts, ...) sample only the slice of
-- the texture they actually cover, just like the in-world mesh.
local function drawIconQuad( tile, verts, shade, rot, flipU, flipV, mat, tintCode, worldColor )
	local u0, v0, u1, v1 = MC.TileUV( tile )
	local poly = {}
	for i = 1, 4 do
		local c = verts[i]
		local ru, rv = iconRotatedUV( c.uf, c.vf, rot, flipU, flipV )
		poly[i] = { x = c.px, y = c.py, u = u0 + ru * ( u1 - u0 ), v = v0 + rv * ( v1 - v0 ) }
	end
	surface.SetMaterial( mat or MC.MaterialCreativeIcon or MC.Material )
	local r, g, b = shade, shade, shade
	if tintCode and tintCode ~= 0 and MC.BlockTintRGB then
		local tr, tg, tb = MC.BlockTintRGB( tintCode )
		r = math.floor( shade * tr / 255 + 0.5 )
		g = math.floor( shade * tg / 255 + 0.5 )
		b = math.floor( shade * tb / 255 + 0.5 )
	end
	if worldColor then
		r = math.floor( r * ( worldColor.r or 255 ) / 255 + 0.5 )
		g = math.floor( g * ( worldColor.g or 255 ) / 255 + 0.5 )
		b = math.floor( b * ( worldColor.b or 255 ) / 255 + 0.5 )
	end
	surface.SetDrawColor( r, g, b, 255 )
	surface.DrawPoly( poly )
end

local ICON_FACE_SHADE = { top = 255, xp = 215, yp = 170 }

-- Project one block-space box [x0,y0,z0,x1,y1,z1] into the icon and append its
-- three viewer-facing faces (+Z top, +X, +Y) to pool, tagged with a painter's
-- depth so multi-box shapes (stairs, fences) composite back-to-front.
local function appendIconBoxFaces( pool, box, faces, project )
	local x0, y0, z0 = box[1], box[2], box[3]
	local x1, y1, z1 = box[4], box[5], box[6]

	local function addFace( info, shade, corners )
		local verts, depth = {}, 0
		for i = 1, 4 do
			local c = corners[i]
			local px, py = project( c[1], c[2], c[3] )
			verts[i] = { px = px, py = py, uf = c[4], vf = c[5] }
			depth = depth + c[1] + c[2] + c[3]
		end
		pool[#pool + 1] = {
			tile = info.tile, shade = shade, depth = depth * 0.25,
			rot = info.rot, flipU = info.flipU, flipV = info.flipV, tintCode = info.tintCode, verts = verts,
		}
	end

	addFace( faces.top, ICON_FACE_SHADE.top, {
		{ x0, y0, z1, x0, y0 }, { x1, y0, z1, x1, y0 },
		{ x1, y1, z1, x1, y1 }, { x0, y1, z1, x0, y1 },
	} )
	addFace( faces.xp, ICON_FACE_SHADE.xp, {
		{ x1, y1, z1, 1 - y1, 1 - z1 }, { x1, y0, z1, 1 - y0, 1 - z1 },
		{ x1, y0, z0, 1 - y0, 1 - z0 }, { x1, y1, z0, 1 - y1, 1 - z0 },
	} )
	addFace( faces.yp, ICON_FACE_SHADE.yp, {
		{ x0, y1, z1, x0, 1 - z1 }, { x1, y1, z1, x1, 1 - z1 },
		{ x1, y1, z0, x1, 1 - z0 }, { x0, y1, z0, x0, 1 - z0 },
	} )
end

-- Icon-only geometry for blocks whose collision boxes collapse to a full cube
-- but should still read as their shape in the palette (walls show a centre post,
-- like the Minecraft wall item) rather than as an indistinct full block.
local ICON_SHAPE_BOXES = {
	wall = { { 0.25, 0.25, 0, 0.75, 0.75, 1 } },
}

local function iconBoxes( id, orient, visual )
	local b = visual and visual.block or MC.Blocks[id]
	if b and b.connection and ICON_SHAPE_BOXES[b.connection] then
		return ICON_SHAPE_BOXES[b.connection]
	end
	if visual and MC.BlockBoxesForState then return MC.BlockBoxesForState( visual.stateId ) end
	return MC.BlockBoxes and MC.BlockBoxes( id, orient ) or nil
end

function MC.DrawMinecraftBlockIcon( id, x, y, w, h, orient, forceModel, visual, materialOverride, worldColor )
	local b = visual and visual.block or MC.Blocks[id]
	if not b then return end
	orient = visual and visual.renderOrient or ( MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or math.floor( tonumber( orient ) or 0 ) )

	if b.iconSource and MC.ResolveBlock then
		local source = MC.ResolveBlock( b.iconSource )
		if source and source.id and source.id ~= id then
			MC.DrawMinecraftBlockIcon( source.id, x, y, w, h, nil, forceModel, visual, materialOverride, worldColor )
			return
		end
	end
	local tintStateId = visual and visual.stateId or nil
	if not tintStateId and MC.StateFromLegacy then tintStateId = MC.StateFromLegacy( id, orient ) end

	-- Blocks with a real Minecraft item sprite (doors, torches, flowers, rails,
	-- signs, panes, ...) draw that flat icon exactly like the inventory does;
	-- cross-shaped plants without a sprite stay flat too. Everything else is
	-- drawn as a 3D model from its actual boxes so slabs read as slabs, stairs
	-- as stairs and fences as fence posts instead of a flat full-block square.
	if not forceModel then
		if b.icon then
			MC.DrawBlockIcon( id, x, y, w, h, tintStateId, materialOverride, worldColor )
			return
		end
		if b.shape == "cross" then
			MC.DrawBlockIcon( id, x, y, w, h, tintStateId, materialOverride, worldColor )
			return
		end
	end

	-- Solid cubes and blocks with real slab/stairs/model/connection geometry get
	-- the 3D treatment. Shapeless non-solid blocks (banners, water, air, ...) only
	-- carry placeholder textures, so leave those on the flat fallback.
	local has3DShape = b.solid ~= false or b.shape ~= nil or b.connection ~= nil
	local boxes = has3DShape and iconBoxes( id, orient, visual ) or nil
	if not boxes or #boxes == 0 then
		MC.DrawBlockIcon( id, x, y, w, h, tintStateId, materialOverride, worldColor )
		return
	end

	local face = MC.Face or { TOP = 1, XP = 3, YP = 5 }
	local faceForState = visual and MC.BlockFaceForState
	local function iconFace( faceIndex )
		if faceForState then return faceForState( visual.stateId, faceIndex ) end
		return MC.BlockFace( id, faceIndex, orient )
	end
	local topTile, topRot, topFlipU, topFlipV = iconFace( face.TOP )
	local xpTile, xpRot, xpFlipU, xpFlipV = iconFace( face.XP )
	local ypTile, ypRot, ypFlipU, ypFlipV = iconFace( face.YP )
	local faces = {
		top = { tile = topTile, rot = topRot, flipU = topFlipU, flipV = topFlipV },
		xp = { tile = xpTile, rot = xpRot, flipU = xpFlipU, flipV = xpFlipV },
		yp = { tile = ypTile, rot = ypRot, flipU = ypFlipU, flipV = ypFlipV },
	}
	if tintStateId and MC.BlockStateTintCode then
		local tintCode = MC.BlockStateTintCode( tintStateId, id, 0 )
		faces.top.tintCode = tintCode
		faces.xp.tintCode = tintCode
		faces.yp.tintCode = tintCode
	end

	-- Vanilla block/item models are anchored at the exact centre of the 16x16
	-- GUI slot, then use the block-model GUI transform: X=30, Y=225 and a
	-- uniform 0.625 scale. This orthographic projection is the 2D equivalent;
	-- keeping the model origin at (0.5, 0.5, 0.5) also aligns partial blocks
	-- exactly as Minecraft does instead of tuning their top edge separately.
	local size = math.min( w, h )
	local cx, cy = x + w * 0.5, y + h * 0.5
	local modelScale = size * 0.625
	local horizontal = modelScale * 0.70710678118655
	local groundVertical = horizontal * 0.5
	local blockVertical = modelScale * 0.86602540378444
	local function project( px, py, pz )
		return cx + ( px - py ) * horizontal,
			cy + ( px + py - 1 ) * groundVertical - ( pz - 0.5 ) * blockVertical
	end

	local pool = {}
	for _, box in ipairs( boxes ) do
		appendIconBoxFaces( pool, box, faces, project )
	end
	table.sort( pool, function( a, c ) return a.depth < c.depth end )
	local mat = materialOverride or iconMaterialFor( id )
	for _, f in ipairs( pool ) do
		drawIconQuad( f.tile, f.verts, f.shade, f.rot, f.flipU, f.flipV, mat, f.tintCode, worldColor )
	end
end

MC.CreativeCategories = MC.CreativeCategories or {
	{ id = "all", labelKey = "creative.category.all", label = MC.T( "creative.category.all", "全部" ) },
	{ id = "color_blocks", labelKey = "creative.category.color_blocks", label = "色块" },
	{ id = "slopes", labelKey = "creative.category.slopes", label = "斜坡" },
	{ id = "custom", labelKey = "creative.category.custom", label = "自定义" },
	{ id = "building", labelKey = "creative.category.building", label = "建筑方块" },
	{ id = "natural", labelKey = "creative.category.natural", label = "自然方块" },
	{ id = "functional", labelKey = "creative.category.functional", label = "功能方块" },
	{ id = "redstone", labelKey = "creative.category.redstone", label = "红石" },
	{ id = "decoration", labelKey = "creative.category.decoration", label = "装饰" },
	{ id = "transparent", labelKey = "creative.category.transparent", label = "透明/玻璃" },
	{ id = "plants", labelKey = "creative.category.plants", label = "植物" },
}

function MC.RefreshCreativeCategories()
	local seen = {}
	for _, category in ipairs( MC.CreativeCategories or {} ) do seen[category.id] = true end
	local creative = MC.API and MC.API.Creative
	for _, category in ipairs( creative and creative.ListCategories and creative.ListCategories() or {} ) do
		if type( category ) == "table" and category.id and not seen[category.id] then
			MC.CreativeCategories[#MC.CreativeCategories + 1] = {
				id = category.id,
				labelKey = category.titleKey,
				label = category.title,
			}
			seen[category.id] = true
		end
	end
	return MC.CreativeCategories
end
local CREATIVE_GRID_COLS = 9
local CREATIVE_GRID_ROWS = 4
local CREATIVE_PAGE_SIZE = CREATIVE_GRID_COLS * CREATIVE_GRID_ROWS
local CREATIVE_HOTBAR_SIZE = 9
local CREATIVE_HOTBAR_SAVE_DIR = "mcswep"
local CREATIVE_HOTBAR_SAVE_PATH = CREATIVE_HOTBAR_SAVE_DIR .. "/creative_hotbar.json"
local CREATIVE_INVENTORY_SAVE_PATH = CREATIVE_HOTBAR_SAVE_DIR .. "/creative_inventory.json"
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
local creativeHotbarLoaded = false
local lastCreativeHotbarSyncID = nil
local lastCreativeHotbarSyncState = nil
local lastCreativeHotbarSyncAt = 0
local CREATIVE_HOTBAR_SYNC_INTERVAL = 0.25
local creativeInventoryStateLoaded = false

local function loadCreativeInventoryState()
	if creativeInventoryStateLoaded then return MC.CreativeInventoryState end
	creativeInventoryStateLoaded = true
	local raw = file.Read( CREATIVE_INVENTORY_SAVE_PATH, "DATA" )
	local saved = raw and util.JSONToTable( raw ) or nil
	MC.CreativeInventoryState = type( saved ) == "table" and saved or ( MC.CreativeInventoryState or {} )
	MC.CreativeInventoryState.pages = type( MC.CreativeInventoryState.pages ) == "table" and MC.CreativeInventoryState.pages or {}
	return MC.CreativeInventoryState
end

function MC.DrawMinecraftBlockStateIcon( stateId, x, y, w, h, forceModel, materialOverride, worldColor )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return false end
	local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId ) or nil
	if not visual then return false end
	MC.DrawMinecraftBlockIcon( visual.id, x, y, w, h, visual.renderOrient, forceModel or visual.forceModelIcon == true, visual, materialOverride, worldColor )
	return true
end

local function saveCreativeInventoryState()
	local state = MC.CreativeInventoryState
	if type( state ) ~= "table" then return end
	local json = util.TableToJSON( state, true )
	if not json then return end
	file.CreateDir( CREATIVE_HOTBAR_SAVE_DIR )
	file.Write( CREATIVE_INVENTORY_SAVE_PATH, json )
end

local function normalizeHotbarSlot( slot )
	slot = math.floor( tonumber( slot ) or 1 )
	return math.Clamp( slot, 1, CREATIVE_HOTBAR_SIZE )
end

local function normalizeHotbarID( id )
	id = tonumber( id )
	if not id then return nil end
	id = math.floor( id )
	if MC.NormalizeLegacyBlockID then id = MC.NormalizeLegacyBlockID( id ) end
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

local function creativeDefaultSelectedID()
	return resolveHotbarDefault( 1 )
end

local function currentHotbarSelectedID()
	local hotbar = MC.CreativeHotbar
	if type( hotbar ) ~= "table" or type( hotbar.slots ) ~= "table" then return nil end
	local slot = normalizeHotbarSlot( hotbar.selected )
	return normalizeHotbarID( hotbar.slots[slot] )
end

local function canonicalStateForBlock( id, value )
	id = normalizeHotbarID( id )
	if not id or value == nil then return nil, nil end
	local stateId
	if type( value ) == "number" then
		stateId = math.floor( value )
	elseif type( value ) == "string" then
		stateId = MC.ParseBlockState and MC.ParseBlockState( value ) or nil
	end
	if not stateId or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, nil end
	if not MC.BlockTypeForState or MC.BlockTypeForState( stateId ) ~= id then return nil, nil end
	local spec = MC.FormatBlockState and MC.FormatBlockState( stateId ) or nil
	if not spec then return nil, nil end
	return stateId, spec
end

local function currentHotbarSelectedStateSpec()
	local hotbar = MC.CreativeHotbar
	if type( hotbar ) ~= "table" or type( hotbar.states ) ~= "table" then return nil end
	local slot = normalizeHotbarSlot( hotbar.selected )
	local id = currentHotbarSelectedID()
	local _, spec = canonicalStateForBlock( id, hotbar.states[slot] )
	return spec
end

local function currentHotbarSelectedStateID()
	local id = currentHotbarSelectedID()
	local stateId = canonicalStateForBlock( id, currentHotbarSelectedStateSpec() )
	return stateId
end

local function currentHotbarSelectedOrient()
	local stateId = currentHotbarSelectedStateID()
	if not stateId or not MC.LegacyFromState then return nil end
	local _, orient = MC.LegacyFromState( stateId )
	return orient
end

local function hotbarIDToSaveValue( id )
	id = normalizeHotbarID( id )
	local b = id and MC.Blocks and MC.Blocks[id] or nil
	if not b then return nil end
	return b.mcid or b.name or tostring( id )
end

local function resolveSavedHotbarValue( value )
	local stateSpec, legacyOrient, mode
	if type( value ) == "table" then
		stateSpec = value.state
		legacyOrient = tonumber( value.orient )
		mode = value.mode
		value = value.block or value.id
	end
	if type( value ) == "number" then
		local id = normalizeHotbarID( value )
		if mode == "auto" then return id end
		local _, spec = canonicalStateForBlock( id, stateSpec )
		if spec then return id, spec end
		if id and legacyOrient and legacyOrient >= 0 then
			local stateId = MC.StateFromLegacy( id, legacyOrient )
			return id, stateId and MC.FormatBlockState( stateId ) or nil
		end
		return id
	end
	if type( value ) ~= "string" then return nil, nil end
	if string.find( value, "[", 1, true ) and MC.ParseBlockState then
		local stateId = MC.ParseBlockState( value )
		local id = stateId and MC.BlockTypeForState( stateId ) or nil
		local _, spec = canonicalStateForBlock( id, stateId )
		if id and spec then return id, spec end
	end

	local b = MC.ResolveBlock and MC.ResolveBlock( value ) or nil
	local id = b and normalizeHotbarID( b.id ) or normalizeHotbarID( tonumber( value ) )
	if mode == "auto" then return id end
	local _, spec = canonicalStateForBlock( id, stateSpec )
	if spec then return id, spec end
	if id and legacyOrient and legacyOrient >= 0 then
		local stateId = MC.StateFromLegacy( id, legacyOrient )
		return id, stateId and MC.FormatBlockState( stateId ) or nil
	end
	return id
end

local function loadCreativeHotbar()
	if creativeHotbarLoaded then return end
	creativeHotbarLoaded = true

	local raw = file.Read( CREATIVE_HOTBAR_SAVE_PATH, "DATA" )
	local data = raw and util.JSONToTable( raw ) or nil
	if type( data ) ~= "table" then return end

	local hotbar = MC.CreativeHotbar or {}
	hotbar.slots = hotbar.slots or {}
	hotbar.states = hotbar.states or {}
	hotbar.selected = normalizeHotbarSlot( data.selected or hotbar.selected )
	hotbar.needsV2Migration = tonumber( data.version ) ~= 2

	local slots = type( data.slots ) == "table" and data.slots or {}
	for i = 1, CREATIVE_HOTBAR_SIZE do
		local id, stateSpec = resolveSavedHotbarValue( slots[i] or slots[tostring( i )] )
		if id then
			hotbar.slots[i] = id
			hotbar.states[i] = stateSpec
		end
	end

	MC.CreativeHotbar = hotbar
end

local function saveCreativeHotbar()
	if not creativeHotbarLoaded then return end
	local hotbar = MC.CreativeHotbar
	if type( hotbar ) ~= "table" or type( hotbar.slots ) ~= "table" then return end

	local data = {
		version = 2,
		selected = normalizeHotbarSlot( hotbar.selected ),
		slots = {},
	}
	for i = 1, CREATIVE_HOTBAR_SIZE do
		local block = hotbarIDToSaveValue( hotbar.slots[i] ) or hotbarIDToSaveValue( resolveHotbarDefault( i ) )
		local _, stateSpec = canonicalStateForBlock( hotbar.slots[i], hotbar.states and hotbar.states[i] )
		data.slots[i] = stateSpec and { block = block, mode = "state", state = stateSpec }
			or { block = block, mode = "auto" }
	end

	local json = util.TableToJSON( data, true )
	if not json then return end
	file.CreateDir( CREATIVE_HOTBAR_SAVE_DIR )
	file.Write( CREATIVE_HOTBAR_SAVE_PATH, json )
end

function MC.EnsureCreativeHotbar()
	loadCreativeHotbar()
	local hotbar = MC.CreativeHotbar or {}
	hotbar.slots = hotbar.slots or {}
	hotbar.states = hotbar.states or {}
	hotbar.selected = normalizeHotbarSlot( hotbar.selected )
	for i = 1, CREATIVE_HOTBAR_SIZE do
		hotbar.slots[i] = normalizeHotbarID( hotbar.slots[i] ) or resolveHotbarDefault( i )
		local _, spec = canonicalStateForBlock( hotbar.slots[i], hotbar.states[i] )
		hotbar.states[i] = spec
	end
	MC.CreativeHotbar = hotbar
	if hotbar.needsV2Migration then
		hotbar.needsV2Migration = nil
		saveCreativeHotbar()
	end
	MC.SyncCreativeHotbarSelection( lastCreativeHotbarSyncID == nil )
	return hotbar
end

function MC.SyncCreativeHotbarSelection( force )
	-- Legacy v1 used RunConsoleCommand( "mc_block_sel", id, orient ); v2 sends a canonical state spec.
	local id = currentHotbarSelectedID()
	if not id then return false end
	local stateSpec = currentHotbarSelectedStateSpec()
	local now = CurTime and CurTime() or 0
	if not force and lastCreativeHotbarSyncID == id and lastCreativeHotbarSyncState == stateSpec and now - lastCreativeHotbarSyncAt < CREATIVE_HOTBAR_SYNC_INTERVAL then
		return true, id, currentHotbarSelectedStateID()
	end
	lastCreativeHotbarSyncID = id
	lastCreativeHotbarSyncState = stateSpec
	lastCreativeHotbarSyncAt = now
	RunConsoleCommand( "mc_block_sel_v2", tostring( id ), stateSpec or "-" )
	return true, id, currentHotbarSelectedStateID()
end

function MC.CreativeHotbarSelectionSynced( ply, id, stateId )
	id = normalizeHotbarID( id ) or currentHotbarSelectedID()
	if not id then return false end
	if stateId == nil then stateId = currentHotbarSelectedStateID() end
	if not IsValid( ply ) then return true end

	local serverID = math.floor( tonumber( ply:GetNWInt( "mc_block", -1 ) ) or -1 )
	local serverStateId = math.floor( tonumber( ply:GetNWInt( "mc_block_state", -1 ) ) or -1 )
	local wantedStateId = stateId ~= nil and math.floor( stateId ) or -1
	if serverID == id and serverStateId == wantedStateId then return true end
	if serverID < 0 and id == creativeDefaultSelectedID() then return true end

	MC.SyncCreativeHotbarSelection( false )
	return false
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

function MC.GetCreativeHotbarSelectedOrient()
	MC.EnsureCreativeHotbar()
	return currentHotbarSelectedOrient()
end

function MC.GetCreativeHotbarSelectedStateID()
	MC.EnsureCreativeHotbar()
	return currentHotbarSelectedStateID()
end

function MC.GetCreativeHotbarSelectedStateSpec()
	MC.EnsureCreativeHotbar()
	return currentHotbarSelectedStateSpec()
end

function MC.SelectCreativeHotbarSlot( slot, noCommand )
	local hotbar = MC.EnsureCreativeHotbar()
	hotbar.selected = normalizeHotbarSlot( slot )
	local id = normalizeHotbarID( hotbar.slots[hotbar.selected] )
	saveCreativeHotbar()
	if id and not noCommand then
		MC.SyncCreativeHotbarSelection( true )
	end
	return id ~= nil, id
end

function MC.StepCreativeHotbarSlot( delta, noCommand )
	local hotbar = MC.EnsureCreativeHotbar()
	local current = normalizeHotbarSlot( hotbar.selected )
	delta = math.floor( tonumber( delta ) or 0 )
	return MC.SelectCreativeHotbarSlot( ( current - 1 + delta ) % CREATIVE_HOTBAR_SIZE + 1, noCommand )
end

function MC.SetCreativeHotbarSlot( slot, id, noCommand )
	id = normalizeHotbarID( id )
	if not id then return false end
	local hotbar = MC.EnsureCreativeHotbar()
	hotbar.selected = normalizeHotbarSlot( slot )
	hotbar.slots[hotbar.selected] = id
	hotbar.states[hotbar.selected] = nil
	saveCreativeHotbar()
	if not noCommand then
		MC.SyncCreativeHotbarSelection( true )
	end
	return true
end

function MC.SetCreativeHotbarSlotStateID( slot, id, state, noCommand )
	id = normalizeHotbarID( id )
	if not id then return false end
	local stateId, stateSpec = canonicalStateForBlock( id, state )
	if not stateId or not stateSpec then return false end
	local hotbar = MC.EnsureCreativeHotbar()
	hotbar.selected = normalizeHotbarSlot( slot )
	hotbar.slots[hotbar.selected] = id
	hotbar.states[hotbar.selected] = stateSpec
	saveCreativeHotbar()
	if not noCommand then
		MC.SyncCreativeHotbarSelection( true )
	end
	return true
end

function MC.SetCreativeHotbarSlotState( slot, id, orient, noCommand )
	id = normalizeHotbarID( id )
	if not id then return false end
	if orient == nil then return MC.SetCreativeHotbarSlot( slot, id, noCommand ) end
	local stateId = MC.StateFromLegacy and MC.StateFromLegacy( id, orient ) or nil
	if not stateId then return false end
	return MC.SetCreativeHotbarSlotStateID( slot, id, stateId, noCommand )
end

function MC.PickCreativeHotbarBlock( ply, includeState )
	ply = ply or LocalPlayer()
	if not IsValid( ply ) or not MC.PlayerBlockAim then return false end
	local hit = MC.PlayerBlockAim( ply )
	local id = hit and normalizeHotbarID( hit.Block )
	if not id then return false end
	if includeState ~= true then
		return MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
	end
	local stateId = hit.StateId or ( MC.StateFromLegacy and MC.StateFromLegacy( id, hit.Orient ) )
	return stateId and MC.SetCreativeHotbarSlotStateID( MC.GetCreativeHotbarSelectedSlot(), id, stateId ) or false
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
		local stateId = canonicalStateForBlock( id, hotbar.states and hotbar.states[i] )
		draw.RoundedBox( 3, sx, y, slotSize, slotSize, selected and Color( 235, 235, 210, 245 ) or Color( 28, 30, 35, 235 ) )
		draw.RoundedBox( 2, sx + 3, y + 3, slotSize - 6, slotSize - 6, selected and Color( 66, 68, 72, 245 ) or Color( 42, 45, 51, 245 ) )
		if id then
			if not stateId or not MC.DrawMinecraftBlockStateIcon( stateId, sx + 7, y + 7, slotSize - 14, slotSize - 14 ) then
				MC.DrawMinecraftBlockIcon( id, sx + 7, y + 7, slotSize - 14, slotSize - 14 )
			end
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

local function exitCreativePlacerWeapon( ply )
	if not IsValid( ply ) then return false end
	local active = ply:GetActiveWeapon()
	for _, wep in ipairs( ply:GetWeapons() or {} ) do
		if IsValid( wep ) and wep ~= active and wep:GetClass() ~= "mc_creative_placer" then
			if input and input.SelectWeapon then
				input.SelectWeapon( wep )
				return true
			end
			break
		end
	end
	RunConsoleCommand( "lastinv" )
	return true
end

local function textEntryHasFocus()
	local focus = vgui.GetKeyboardFocus and vgui.GetKeyboardFocus() or nil
	if not IsValid( focus ) then return false end
	local class = focus.GetClassName and focus:GetClassName() or ""
	return class == "TextEntry" or class == "DTextEntry"
end

local lastCreativePickAt = 0
local function creativePickIncludesState()
	if not input or not input.IsKeyDown then return false end
	return input.IsKeyDown( KEY_LSHIFT ) or input.IsKeyDown( KEY_RSHIFT )
end

local function pickCreativeHotbarBlockDebounced( ply )
	local now = CurTime()
	if now - lastCreativePickAt < 0.08 then return true end
	lastCreativePickAt = now
	return MC.PickCreativeHotbarBlock( ply, creativePickIncludesState() )
end

hook.Remove( "PlayerBindPress", "mc_creative_hotbar_binds" )
hook.Add( "PlayerBindPress", "mc_creative_hotbar_binds", function( ply, bind, pressed )
	if not pressed or not activeCreativePlacer( ply ) then return end
	if bind == "+showscores" then
		if not textEntryHasFocus() then
			exitCreativePlacerWeapon( ply )
		end
		return true
	end
	local slot = string.match( bind or "", "^slot([1-9])$" )
	if slot then
		if not textEntryHasFocus() then
			MC.SelectCreativeHotbarSlot( tonumber( slot ) )
		end
		return true
	end
	if bind == "invnext" then
		if not textEntryHasFocus() then
			MC.StepCreativeHotbarSlot( 1 )
		end
		return true
	end
	if bind == "invprev" then
		if not textEntryHasFocus() then
			MC.StepCreativeHotbarSlot( -1 )
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
	if button == KEY_TAB then
		if not textEntryHasFocus() then
			exitCreativePlacerWeapon( ply )
		end
		return
	end
	if button == MOUSE_MIDDLE then
		pickCreativeHotbarBlockDebounced( ply )
	end
end )

hook.Remove( "InitPostEntity", "mc_creative_hotbar_initial_sync" )
hook.Add( "InitPostEntity", "mc_creative_hotbar_initial_sync", function()
	timer.Simple( 0.5, function()
		if MC.EnsureCreativeHotbar then MC.EnsureCreativeHotbar() end
		if MC.SyncCreativeHotbarSelection then MC.SyncCreativeHotbarSelection( true ) end
	end )
end )

local function blockText( b )
	return string.lower( table.concat( {
		tostring( b and b.name or "" ),
		tostring( b and b.mcid or "" ),
		tostring( b and b.disp or "" ),
		tostring( b and b.dispZH or "" ),
		tostring( b and MC.BlockDisplayName and MC.BlockDisplayName( b, b.dispZH or b.disp, "en_us" ) or "" ),
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
	if b and b.creativeCategory then return b.creativeCategory end
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
	MC.RefreshCreativeCategories()
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
			-- A public Creative.RegisterBlock entry is authoritative membership
			-- for addon categories.  Keep the legacy single creativeCategory field
			-- for vanilla content, but allow one block to appear in multiple
			-- registered tabs just like CreativeModeTab search contents.
			local canonical = b.mcid and MC.NormalizeResourceLocation
				and MC.NormalizeResourceLocation( b.mcid ) or b.mcid
			local memberships = MC.ModRegistry and MC.ModRegistry.creativeBlockCategories
				and canonical and MC.ModRegistry.creativeBlockCategories[canonical] or nil
			for categoryId in pairs( memberships or {} ) do
				if categoryId ~= cat then
					groups[categoryId] = groups[categoryId] or {}
					groups[categoryId][#groups[categoryId] + 1] = id
				end
			end
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

local function creativeInventoryIconMaterialFor( id )
	if MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) then
		return MC.MaterialCreativeIconOpaque or MC.MaterialIconOpaque
	end
	return MC.MaterialCreativeIcon or MC.Material
end

local function drawCreativeInventoryBlockIcon( id, x, y, w, h )
	MC.DrawMinecraftBlockIcon( id, x, y, w, h, nil, nil, nil, creativeInventoryIconMaterialFor( id ) )
end

local function drawCreativeInventoryBlockStateIcon( id, stateId, x, y, w, h, forceModel )
	return MC.DrawMinecraftBlockStateIcon(
		stateId, x, y, w, h, forceModel, creativeInventoryIconMaterialFor( id )
	)
end

local function paintCreativeButtonSurface( s, w, h, label, selected )
	local enabled = s:IsEnabled()
	local bg = selected and Color( 76, 82, 70, 255 ) or ( enabled and CREATIVE_UI.control or CREATIVE_UI.controlDisabled )
	if enabled and not selected and s:IsDown() then
		bg = CREATIVE_UI.controlDown
	elseif enabled and not selected and s:IsHovered() then
		bg = CREATIVE_UI.controlHover
	end

	draw.RoundedBox( 3, 0, 0, w, h, bg )
	draw.RoundedBox( 2, 3, 3, w - 6, h - 6, selected and Color( 37, 41, 35, 235 ) or Color( 20, 22, 26, enabled and 210 or 120 ) )
	surface.SetDrawColor( selected and CREATIVE_UI.accent or ( enabled and Color( 120, 130, 148, 160 ) or Color( 70, 75, 84, 120 ) ) )
	surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	draw.SimpleText( label or "", "mc_hud_small", w * 0.5, h * 0.5, selected and CREATIVE_UI.accent or ( enabled and CREATIVE_UI.text or CREATIVE_UI.textDim ), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

function MC.StyleCreativePagerButton( btn, label, isSelected )
	if not IsValid( btn ) then return end
	btn:SetText( "" )
	btn.Paint = function( s, w, h )
		local selected = type( isSelected ) == "function" and isSelected( s ) == true or isSelected == true
		local text = type( label ) == "function" and label( selected, s ) or label
		paintCreativeButtonSurface( s, w, h, text, selected )
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

function MC.StyleCreativeStateComboBox( combo )
	if not IsValid( combo ) then return end
	combo:SetFont( "mc_hud_small" )
	combo:SetTextColor( CREATIVE_UI.text )
	combo:SetContentAlignment( 4 )
	if combo.SetTextInset then combo:SetTextInset( 12, 0 ) end
	if IsValid( combo.DropButton ) then combo.DropButton:SetVisible( false ) end

	combo.Paint = function( s, w, h )
		local bg = s:IsMenuOpen() and Color( 34, 39, 47, 255 )
			or ( s:IsHovered() and CREATIVE_UI.controlHover or CREATIVE_UI.control )
		draw.RoundedBox( 3, 0, 0, w, h, bg )
		draw.RoundedBox( 2, 3, 3, w - 6, h - 6, CREATIVE_UI.panelInner )
		surface.SetDrawColor( s:IsMenuOpen() and CREATIVE_UI.accent or Color( 104, 114, 132, 180 ) )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		draw.SimpleText( "▼", "mc_hud_small", w - 15, h * 0.5, CREATIVE_UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end

	combo.OnMenuOpened = function( s, menu )
		if not IsValid( menu ) then return end
		if menu.SetMinimumWidth then menu:SetMinimumWidth( s:GetWide() ) end
		menu.Paint = function( _, w, h )
			draw.RoundedBox( 3, 0, 0, w, h, Color( 18, 20, 24, 255 ) )
			surface.SetDrawColor( Color( 104, 114, 132, 200 ) )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end

		local canvas = menu.GetCanvas and menu:GetCanvas() or nil
		for _, option in ipairs( IsValid( canvas ) and canvas:GetChildren() or {} ) do
			if option.SetFont then option:SetFont( "mc_hud_small" ) end
			if option.SetTextColor then option:SetTextColor( CREATIVE_UI.text ) end
			if option.SetContentAlignment then option:SetContentAlignment( 4 ) end
			if option.SetTextInset then option:SetTextInset( 12, 0 ) end
			if option.SetTall then option:SetTall( 30 ) end
			option.Paint = function( item, w, h )
				local selected = tostring( item:GetText() ) == tostring( s:GetValue() )
				local color = selected and Color( 76, 82, 70, 255 )
					or ( item:IsHovered() and CREATIVE_UI.controlHover or Color( 24, 27, 32, 255 ) )
				surface.SetDrawColor( color )
				surface.DrawRect( 1, 0, w - 2, h )
				if selected then
					surface.SetDrawColor( CREATIVE_UI.accent )
					surface.DrawRect( 1, 0, 3, h )
				end
				return false
			end
		end
	end
end

local function creativeBlockStateSchema( id )
	local b = MC.Blocks[id]
	local schema = MC.BlockStateSchemas and MC.BlockStateSchemas[id] or nil
	return b, schema
end

local function positionCreativeStateFrame( frame, parent )
	if not IsValid( frame ) then return end
	if not IsValid( parent ) then
		frame:Center()
		return
	end
	local px, py = parent:GetPos()
	local pw = parent:GetWide()
	local fw, fh = frame:GetSize()
	local x = px - fw - 8
	if x < 8 then
		local right = px + pw + 8
		x = right + fw <= ScrW() - 8 and right or px + math.floor( ( pw - fw ) * 0.5 )
	end
	frame:SetPos( math.Clamp( x, 8, ScrW() - fw - 8 ), math.Clamp( py + 40, 8, ScrH() - fh - 8 ) )
end

function MC.OpenCreativeStatePicker( id, onSelect, parent, selectedStateId )
	local b, schema = creativeBlockStateSchema( id )
	if not b or not schema or type( schema.properties ) ~= "table" or #schema.properties == 0 then return false end
	local automaticSelected = not selectedStateId or not MC.IsValidBlockState( selectedStateId ) or MC.BlockTypeForState( selectedStateId ) ~= id
	if automaticSelected then
		selectedStateId = schema.defaultStateId
	end
	if IsValid( MC.CreativeStateFrame ) then MC.CreativeStateFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( L( "creative.state.title", "方块状态" ) .. " · " .. blockDisplayText( b ) )
	fr:SetSize( 520, 620 )
	positionCreativeStateFrame( fr, parent )
	fr:MakePopup()
	fr:SetKeyboardInputEnabled( true )
	-- Keep hotbar number keys working while the block-state picker is open.
	-- DFrame receives the key event and otherwise prevents PlayerBindPress from
	-- seeing slot1..slot9, so explicitly route those keys to the creative bar.
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
	fr.Paint = function( _, w, h )
		draw.RoundedBox( 6, 0, 0, w, h, CREATIVE_UI.frame )
		draw.RoundedBoxEx( 6, 0, 0, w, 28, CREATIVE_UI.title, true, true, false, false )
	end
	fr.OnRemove = function()
		if MC.CreativeStateFrame == fr then MC.CreativeStateFrame = nil end
	end
	MC.CreativeStateFrame = fr
	local propertyControls = {}
	local function propertyDisplayValue( propertyName )
		local value = MC.GetStateProperty( selectedStateId, propertyName )
		if value == nil then return "" end
		return tostring( value )
	end
	local function refreshPropertyControls()
		for propertyName, combo in pairs( propertyControls ) do
			if IsValid( combo ) then
				combo:SetValue( propertyDisplayValue( propertyName ) )
			end
		end
	end

	local preview = vgui.Create( "DPanel", fr )
	preview:Dock( TOP )
	preview:DockMargin( 8, 8, 8, 6 )
	preview:SetTall( 156 )
	preview.Paint = function( _, w, h )
		draw.RoundedBox( 5, 0, 0, w, h, CREATIVE_UI.panel )
		draw.RoundedBox( 4, 5, 5, 136, h - 10, CREATIVE_UI.panelInner )
		drawCreativeInventoryBlockStateIcon( id, selectedStateId, 15, 17, 116, 116, true )
		local state = MC.FormatBlockState( selectedStateId ) or "?"
		draw.SimpleText( blockDisplayText( b ), "mc_hud", 154, 16, CREATIVE_UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		draw.DrawText( state, "mc_hud_fit_16", 154, 46, CREATIVE_UI.textDim, TEXT_ALIGN_LEFT )
	end

	local automatic = vgui.Create( "DButton", fr )
	automatic:Dock( TOP )
	automatic:DockMargin( 8, 0, 8, 6 )
	automatic:SetTall( 34 )
	local automaticLabel = L( "creative.state.auto", "自动放置" )
	local selectedLabel = L( "creative.state.selected", "已选中" )
	MC.StyleCreativePagerButton( automatic, function( selected )
		return selected and ( automaticLabel .. "  ·  " .. selectedLabel ) or automaticLabel
	end, function()
		return automaticSelected
	end )
	automatic.DoClick = function()
		automaticSelected = true
		onSelect( id, nil )
	end

	local explicitDefault = vgui.Create( "DButton", fr )
	explicitDefault:Dock( TOP )
	explicitDefault:DockMargin( 8, 0, 8, 6 )
	explicitDefault:SetTall( 30 )
	MC.StyleCreativePagerButton( explicitDefault, L( "creative.state.explicit_default", "显式默认状态" ) )
	explicitDefault.DoClick = function()
		automaticSelected = false
		selectedStateId = schema.defaultStateId
		onSelect( id, selectedStateId )
		refreshPropertyControls()
	end

	local scroll = vgui.Create( "DScrollPanel", fr )
	scroll:Dock( FILL )
	scroll:DockMargin( 8, 0, 8, 8 )
	local scrollBar = scroll:GetVBar()
	if IsValid( scrollBar ) then
		scrollBar:SetWide( 0 )
		scrollBar:SetHideButtons( true )
		scrollBar.Paint = function() end
		if IsValid( scrollBar.btnGrip ) then scrollBar.btnGrip.Paint = function() end end
	end

	for _, property in ipairs( schema.properties ) do
		local row = vgui.Create( "DPanel", scroll )
		row:Dock( TOP )
		row:DockMargin( 0, 0, 0, 6 )
		row:SetTall( 54 )
		row.Paint = function( _, w, h )
			draw.RoundedBox( 4, 0, 0, w, h, CREATIVE_UI.panel )
		end

		local label = vgui.Create( "DLabel", row )
		label:Dock( LEFT )
		label:DockMargin( 12, 0, 8, 0 )
		label:SetWide( 170 )
		label:SetContentAlignment( 4 )
		label:SetTextColor( CREATIVE_UI.text )
		label:SetFont( "mc_hud" )
		label:SetText( property.name )

		local combo = vgui.Create( "DComboBox", row )
		combo:Dock( FILL )
		combo:DockMargin( 0, 9, 10, 9 )
		combo:SetSortItems( false )
		MC.StyleCreativeStateComboBox( combo )
		for _, value in ipairs( property.canonicalValues or {} ) do combo:AddChoice( value, value ) end
		combo:SetValue( propertyDisplayValue( property.name ) )
		propertyControls[property.name] = combo
		combo.OnSelect = function( _, _, text, data )
			local value = data ~= nil and data or text
			local nextState = MC.StateWith( selectedStateId, property.name, value )
			if not nextState then return end
			automaticSelected = false
			selectedStateId = nextState
			onSelect( id, selectedStateId )
			refreshPropertyControls()
		end
	end

	return true
end

local function addCreativeButton( layout, id, onBlockClicked, frame, closeOnSelect )
	local b = MC.Blocks[id]
	if not b then return end
	local btn = layout:Add( "DButton" )
	btn:SetSize( 96, 108 )
	btn:SetText( "" )

	local hint = MC.BlockStateHint( id )
	btn:SetTooltip( blockDisplayText( b ) .. "\n" .. ( b.mcid or b.name or tostring( id ) ) .. ( hint ~= "" and "\n" .. hint or "" ) )

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
		drawCreativeInventoryBlockIcon( id, w * 0.5 - icon * 0.5, 8, icon, icon )
		MC.DrawFittedText( blockDisplayText( b ), "mc_hud_small", { "mc_hud_fit_16" }, w * 0.5, h - 17, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 8 )
	end

	btn.DoClick = function()
		local keepOpen = onBlockClicked( id ) == true
		if closeOnSelect and not keepOpen and IsValid( frame ) then frame:Close() end
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
			local stateId = canonicalStateForBlock( id, hotbar.states and hotbar.states[i] )
			local b = id and MC.Blocks[id] or nil
			local bg = selected and Color( 236, 230, 190, 245 ) or ( s:IsHovered() and Color( 80, 92, 112 ) or Color( 44, 48, 55 ) )
			draw.RoundedBox( 4, 0, 0, w, h, bg )
			draw.RoundedBox( 3, 4, 4, w - 8, h - 8, selected and Color( 58, 60, 64 ) or Color( 34, 37, 43 ) )
			draw.SimpleText( tostring( i ), "mc_hud_small", 8, 6, selected and Color( 255, 244, 170 ) or Color( 205, 212, 224 ), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			if id then
				if not stateId or not drawCreativeInventoryBlockStateIcon( id, stateId, w * 0.5 - 22, 11, 44, 44 ) then
					drawCreativeInventoryBlockIcon( id, w * 0.5 - 22, 11, 44, 44 )
				end
			end
			if b then
				MC.DrawFittedText( blockDisplayText( b ), "mc_hud_small", { "mc_hud_fit_16" }, w * 0.5, h - 13, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 8 )
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
	if IsValid( MC.CreativeStateFrame ) then MC.CreativeStateFrame:Remove() end
	opts = opts or {}
	-- Settle the category list BEFORE the tabs are built. rebuild() below calls
	-- MC.BuildCreativeBlockGroups, which calls MC.RefreshCreativeCategories and
	-- APPENDS any mod-registered categories. Since mod categories are allocated
	-- lazily on the first ListCategories() call, that first rebuild grew the
	-- list after the tab loop had already run, and rebuild then looked up a
	-- layout for a category that never got a tab -> clearLayout( nil ).
	if MC.RefreshCreativeCategories then MC.RefreshCreativeCategories() end
	local cachedState = loadCreativeInventoryState()
	local closeOnSelect = opts.closeOnSelect
	if closeOnSelect == nil then closeOnSelect = true end
	onSelect = onSelect or function( id, stateId )
		if stateId ~= nil then
			MC.SetCreativeHotbarSlotStateID( MC.GetCreativeHotbarSelectedSlot(), id, stateId )
		else
			MC.SetCreativeHotbarSlot( MC.GetCreativeHotbarSelectedSlot(), id )
		end
	end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( L( "creative.title", "创造物品栏" ) )
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
	search:SetValue( tostring( cachedState.search or "" ) )
	search:SetPlaceholderText( L( "creative.search", "搜索中文名 / 英文名 / minecraft:id" ) )
	search:SetDrawBackground( false )
	search:SetTextColor( CREATIVE_UI.text )
	if search.SetCursorColor then search:SetCursorColor( CREATIVE_UI.accent ) end
	search.Paint = function( s, w, h )
		draw.RoundedBox( 3, 0, 0, w, h, Color( 16, 18, 22, 245 ) )
		surface.SetDrawColor( 88, 96, 110, s:HasFocus() and 190 or 110 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			draw.SimpleText( L( "creative.search", "搜索中文名 / 英文名 / minecraft:id" ), "mc_hud_small", 8, h * 0.5, CREATIVE_UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
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
	local categoryTabs = {}
	local activeCategory = tostring( cachedState.category or "all" )
	local page = math.max( 1, math.floor( tonumber( cachedState.pages[activeCategory] ) or 1 ) )
	for _, cat in ipairs( MC.CreativeCategories ) do
		local label = L( cat.labelKey, cat.label )
		local grid = vgui.Create( "DPanel", tabs )
		MC.StyleCreativeGridPanel( grid )
		local layout = vgui.Create( "DPanel", grid )
		layout:Dock( FILL )
		layout:DockMargin( 8, 8, 8, 8 )
		layout.Paint = function() end
		layout.PerformLayout = layoutCreativeGridSlots
		layouts[cat.id] = layout
		local sheet = tabs:AddSheet( label, grid, nil, false, false, label )
		if sheet and sheet.Tab then
			categoryTabs[cat.id] = sheet.Tab
			sheet.Tab.MCCategoryID = cat.id
			sheet.Tab.MCCategoryLabelKey = cat.labelKey
			sheet.Tab.MCCategoryFallback = cat.label
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
	if not layouts[activeCategory] then activeCategory = "all" end

	local function cacheInventoryPosition()
		cachedState.category = activeCategory
		cachedState.search = search:GetValue()
		cachedState.pages[activeCategory] = page
		saveCreativeInventoryState()
	end

	local function selectCreativeBlock( id )
		local stateId = currentHotbarSelectedID() == id and currentHotbarSelectedStateID() or nil
		onSelect( id, stateId )
		local _, schema = creativeBlockStateSchema( id )
		if schema and type( schema.properties ) == "table" and #schema.properties > 0 then
			MC.OpenCreativeStatePicker( id, onSelect, fr, stateId )
			return true
		end
		if IsValid( MC.CreativeStateFrame ) then MC.CreativeStateFrame:Remove() end
		return false
	end

	local function rebuild()
		local groups = MC.BuildCreativeBlockGroups( search:GetValue() )
		-- Correct the selection before ids/pages are derived from it.
		if not IsValid( layouts[activeCategory] ) then activeCategory = "all" end
		local ids = groups[activeCategory] or {}
		local pages = math.max( 1, math.ceil( #ids / CREATIVE_PAGE_SIZE ) )
		page = math.Clamp( page, 1, pages )

		for _, cat in ipairs( MC.CreativeCategories ) do
			-- A category registered after this frame was built has no tab here.
			-- Skip it rather than crash; it appears next time the picker opens.
			local layout = layouts[cat.id]
			if IsValid( layout ) then
				clearLayout( layout )
				layout:InvalidateLayout( true )
			end
		end

		local layout = layouts[activeCategory]
		if not IsValid( layout ) then return end
		local first = ( page - 1 ) * CREATIVE_PAGE_SIZE + 1
		local last = math.min( #ids, first + CREATIVE_PAGE_SIZE - 1 )
		for i = first, last do
			addCreativeButton( layout, ids[i], selectCreativeBlock, fr, closeOnSelect )
		end
		layout:InvalidateLayout( true )
		pageLabel:SetText( L( "creative.page", "{page} / {pages}    {count} 个方块", { page = page, pages = pages, count = #ids } ) )
		prev:SetEnabled( page > 1 )
		next:SetEnabled( page < pages )
		cacheInventoryPosition()
	end

	tabs.OnActiveTabChanged = function( _, _, new )
		activeCategory = new and new.MCCategoryID or activeCategory
		page = math.max( 1, math.floor( tonumber( cachedState.pages[activeCategory] ) or 1 ) )
		rebuild()
	end
	search.OnChange = function()
		page = 1
		cachedState.pages[activeCategory] = page
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
	fr.OnClose = function()
		cacheInventoryPosition()
		if IsValid( MC.CreativeStateFrame ) then MC.CreativeStateFrame:Remove() end
	end
	fr.MCRefreshLanguage = function()
		fr:SetTitle( L( "creative.title", "创造物品栏" ) )
		search:SetPlaceholderText( L( "creative.search", "搜索中文名 / 英文名 / minecraft:id" ) )
		local items = tabs.GetItems and tabs:GetItems() or tabs.Items or {}
		for _, item in ipairs( items ) do
			local tab = item.Tab
			if IsValid( tab ) and tab.MCCategoryLabelKey then
				tab:SetText( L( tab.MCCategoryLabelKey, tab.MCCategoryFallback or "" ) )
			end
		end
		rebuild()
	end
	if categoryTabs[activeCategory] then tabs:SetActiveTab( categoryTabs[activeCategory] ) end
	fr.MCRefreshLanguage()
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

function MC.DrawBlockOutline( id, orient, bx, by, bz, color, stateId )
	local base = MC.CellWorldMin( bx, by, bz )
	color = color or Color( 0, 0, 0, 235 )
	local b = MC.Blocks[id]
	if b and b.shape == "cross" then
		drawCrossOutline( base, color )
		return
	end

	if stateId == nil and MC.GetBlockState then stateId = MC.GetBlockState( bx, by, bz ) end
	local boxes = stateId ~= nil and MC.BlockSelectionBoxesForState
		and MC.BlockSelectionBoxesForState( stateId, bx, by, bz ) or nil
	if boxes == nil then boxes = MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil end
	for _, box in ipairs( boxes or { { 0, 0, 0, 1, 1, 1 } } ) do
		local mn = Vector( box[1] * MC.BS, box[2] * MC.BS, box[3] * MC.BS )
		local mx = Vector( box[4] * MC.BS, box[5] * MC.BS, box[6] * MC.BS )
		render.DrawWireframeBox( base, angle_zero, mn, mx, color, true )
	end
end

function MC.OpenPalette( onSelect )
	if IsValid( MC.PaletteFrame ) then MC.PaletteFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( L( "palette.title", "选择方块" ) )
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
		btn:SetTooltip( blockDisplayText( b ) .. ( hint ~= "" and "\n" .. hint or "" ) )

		btn.Paint = function( s, w, h )
			draw.RoundedBox( 4, 0, 0, w, h, s:IsHovered() and Color( 80, 90, 110 ) or Color( 45, 47, 52 ) )
			MC.DrawBlockIcon( id, w * 0.5 - 36, 10, 72, 72 )
			MC.DrawFittedText( blockDisplayText( b ), "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, w * 0.5, h - 24, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, w - 10 )
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
	local label
	if p.workshop == true then
		label = L( "sync.workshop_progress", "本地读取创意工坊世界 {received}/{expected} 方块  {done}/{chunks} 区块", {
			received = p.received,
			expected = p.expected,
			done = p.doneChunks,
			chunks = p.chunks,
		} )
	elseif p.bytes == true then
		label = L( "sync.progress_bytes", "MC 同步 {received}/{expected} KB  {done}/{chunks} 分片", {
			received = math.floor( ( p.received or 0 ) / 1024 + 0.5 ),
			expected = math.max( 1, math.floor( ( p.expected or 0 ) / 1024 + 0.5 ) ),
			done = p.doneChunks,
			chunks = p.chunks,
		} )
	else
		label = L( "sync.progress", "MC 同步 {received}/{expected} 方块  {done}/{chunks} 区块", {
			received = p.received,
			expected = p.expected,
			done = p.doneChunks,
			chunks = p.chunks,
		} )
	end
	if complete then
		if p.workshop == true then
			label = L( "sync.workshop_complete", "创意工坊基础世界已从本地读取完成" )
		else
			label = L( "sync.complete", "MC 同步完成  {label}", { label = label } )
		end
	end

	draw.RoundedBox( 4, x - 10, y - 28, w + 20, 58, Color( 0, 0, 0, 180 ) )
	draw.SimpleText( label, "mc_hud_small", x, y - 20, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	draw.RoundedBox( 3, x, y, w, h, Color( 35, 38, 42, 230 ) )
	draw.RoundedBox( 3, x, y, math.floor( w * frac ), h, complete and Color( 120, 220, 150, 240 ) or Color( 90, 180, 255, 240 ) )
end )

if MC.RegisterLanguageChanged then
	MC.RegisterLanguageChanged( "mc_cl_ui", function()
		if IsValid( MC.CreativeFrame ) and MC.CreativeFrame.MCRefreshLanguage then
			MC.CreativeFrame:MCRefreshLanguage()
		end
		if IsValid( MC.PaletteFrame ) then
			MC.PaletteFrame:SetTitle( L( "palette.title", "选择方块" ) )
			MC.PaletteFrame:InvalidateLayout( true )
		end
	end )
end
