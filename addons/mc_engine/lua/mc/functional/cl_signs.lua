-- Client editor and block-entity renderer for vanilla plain and hanging signs.

MC = MC or {}

local Coords = MC.API.Coords
local TEXT_COLOR = Color( 25, 12, 4, 255 )
local EDIT_TEXT_COLOR = Color( 55, 28, 10, 255 )
local SIGN_GUI_MATERIALS = {}
local signPosition, signRight, signNormal = Vector(), Vector(), Vector()
local DOWN = Vector( 0, 0, -1 )
-- mesh.Position copies each glyph corner before the next glyph reuses it.
local topLeft, topRight, bottomLeft, bottomRight = Vector(), Vector(), Vector(), Vector()

local function fontAtlasMaterial( path )
	return Material( path .. ".png", "alphatest vertexcolor vertexalpha nocull" )
end

local FONT_ATLASES = {
	{ material = fontAtlasMaterial( "mc/font/ascii" ), first = 32, last = 126,
		textureW = 256, textureH = 256, cellW = 8, cellH = 8,
		strideX = 9, strideY = 9, cols = 16, rows = 16, ascii = true, separated = true },
}
for _, definition in ipairs( MC.GeneratedUnihexAtlasData and MC.GeneratedUnihexAtlasData.ranges or {} ) do
	FONT_ATLASES[#FONT_ATLASES + 1] = {
		material = fontAtlasMaterial( tostring( definition.material or "" ) ),
		first = math.floor( tonumber( definition.first ) or 0 ),
		last = math.floor( tonumber( definition.last ) or -1 ),
		textureW = math.max( 1, tonumber( definition.mappingWidth ) or 1 ),
		textureH = math.max( 1, tonumber( definition.mappingHeight ) or 1 ),
		cellW = math.max( 1, tonumber( definition.cellWidth ) or 16 ),
		cellH = math.max( 1, tonumber( definition.cellHeight ) or 16 ),
		strideX = math.max( 1, tonumber( definition.strideX ) or 17 ),
		strideY = math.max( 1, tonumber( definition.strideY ) or 17 ),
		cols = math.max( 1, math.floor( tonumber( definition.columns ) or 1 ) ),
		rows = math.max( 1, math.floor( tonumber( definition.rows ) or 1 ) ),
		separated = true,
	}
end

surface.CreateFont( "mc_sign_fallback", {
	font = "Microsoft YaHei",
	size = 9,
	weight = 500,
	antialias = false,
	extended = true,
} )
surface.CreateFont( "mc_sign_fallback_editor", {
	font = "Microsoft YaHei",
	size = 18,
	weight = 500,
	antialias = false,
	extended = true,
} )
surface.CreateFont( "mc_sign_title", {
	font = "Microsoft YaHei",
	size = 18,
	weight = 600,
	extended = true,
} )

local function atlasGlyphUV( atlas, slot )
	local column = slot % atlas.cols
	local row = math.floor( slot / atlas.cols )
	if row < 0 or row >= atlas.rows then return nil end
	local left = column * ( atlas.strideX or atlas.cellW )
	local top = row * ( atlas.strideY or atlas.cellH )
	if atlas.separated then
		return ( left - 0.5 ) / atlas.textureW,
			( top - 0.5 ) / atlas.textureH,
			( left + atlas.cellW ) / atlas.textureW,
			( top + atlas.cellH ) / atlas.textureH
	end
	local inset = math.min( 0.5, ( atlas.cellW - 1 ) * 0.5, ( atlas.cellH - 1 ) * 0.5 )
	return ( left + inset ) / atlas.textureW, ( top + inset ) / atlas.textureH,
		( left + atlas.cellW - inset ) / atlas.textureW,
		( top + atlas.cellH - inset ) / atlas.textureH
end

local function utf8Glyphs( text )
	local glyphs, count, index = {}, 0, 1
	while index <= #text do
		local first = string.byte( text, index )
		local length = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or 4
		local bytes = string.sub( text, index, index + length - 1 )
		local codepoint
		if length == 1 then codepoint = first
		elseif length == 2 then codepoint = ( first - 0xC0 ) * 64 + string.byte( text, index + 1 ) - 0x80
		elseif length == 3 then codepoint = ( first - 0xE0 ) * 4096
			+ ( string.byte( text, index + 1 ) - 0x80 ) * 64 + string.byte( text, index + 2 ) - 0x80
		else codepoint = ( first - 0xF0 ) * 262144
			+ ( string.byte( text, index + 1 ) - 0x80 ) * 4096
			+ ( string.byte( text, index + 2 ) - 0x80 ) * 64 + string.byte( text, index + 3 ) - 0x80 end
		local atlas, u0, v0, u1, v1
		for atlasIndex = 1, #FONT_ATLASES do
			local candidate = FONT_ATLASES[atlasIndex]
			if codepoint >= candidate.first and codepoint <= candidate.last then
				local slot = candidate.ascii and codepoint or codepoint - candidate.first
				atlas = candidate
				u0, v0, u1, v1 = atlasGlyphUV( candidate, slot )
				break
			end
		end
		count = count + 1
		glyphs[count] = {
			codepoint = codepoint, text = bytes,
			advance = MC.SignGlyphAdvance( codepoint ),
			atlas = atlas, u0 = u0, v0 = v0, u1 = u1, v1 = v1,
		}
		index = index + length
	end
	return glyphs
end

local LineCache, LineCacheCount = {}, 0
local function cachedLine( text )
	local cached = LineCache[text]
	if cached then return cached end
	local width = MC.SignMeasureLine( text ) or 0
	cached = { glyphs = utf8Glyphs( text ), width = width }
	if LineCacheCount >= 1024 then LineCache, LineCacheCount = {}, 0 end
	LineCache[text] = cached
	LineCacheCount = LineCacheCount + 1
	return cached
end

local function drawMinecraftLine( text, centerX, topY, color, drawScale, fallbackFont )
	drawScale = tonumber( drawScale ) or 1
	fallbackFont = fallbackFont or "mc_sign_fallback"
	local line = cachedLine( text )
	local x = centerX - line.width * drawScale * 0.5
	if render and render.PushFilterMin and TEXFILTER then render.PushFilterMin( TEXFILTER.POINT ) end
	if render and render.PushFilterMag and TEXFILTER then render.PushFilterMag( TEXFILTER.POINT ) end
	for index = 1, #line.glyphs do
		local glyph = line.glyphs[index]
		if glyph.atlas then
			surface.SetMaterial( glyph.atlas.material )
			surface.SetDrawColor( color )
			surface.DrawTexturedRectUV( x, topY, 8 * drawScale, 8 * drawScale,
				glyph.u0, glyph.v0, glyph.u1, glyph.v1 )
		else
			draw.SimpleText( glyph.text, fallbackFont,
				x + glyph.advance * drawScale * 0.5, topY + 4 * drawScale,
				color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		x = x + glyph.advance * drawScale
	end
	if render and render.PopFilterMag and TEXFILTER then render.PopFilterMag() end
	if render and render.PopFilterMin and TEXFILTER then render.PopFilterMin() end
end

local function signYaw( stateId, name )
	if string.match( name, "_wall_sign$" ) or string.match( name, "_wall_hanging_sign$" ) then
		local facing = MC.GetStateProperty( stateId, "facing" )
		return facing == "south" and 0 or facing == "west" and 90
			or facing == "north" and 180 or 270
	end
	return ( tonumber( MC.GetStateProperty( stateId, "rotation" ) ) or 0 ) * 22.5
end

local function signTransform( bx, by, bz, stateId, name, bs )
	local yaw = signYaw( stateId, name )
	local radians = math.rad( yaw )
	local nx, ny = -math.sin( radians ), math.cos( radians )
	local base = Coords.CellRenderMin( bx, by, bz )
	local hanging = string.match( name, "_hanging_sign$" ) ~= nil
	local wall = string.match( name, "_wall_sign$" ) ~= nil
	local offset = hanging and 0.073 or wall and -0.390833333 or 0.046666667
	signPosition.x = base.x + bs * ( 0.5 + nx * offset )
	signPosition.y = base.y + bs * ( 0.5 + ny * offset )
	signPosition.z = base.z + bs * ( hanging and 0.305 or wall and 0.520833333 or 0.833333333 )
	-- The generated sign model's front-face local X runs opposite the state yaw
	-- basis used here. Negate it so glyph order and glyph UVs read left-to-right
	-- from the visible side instead of appearing horizontally mirrored.
	signRight.x, signRight.y, signRight.z = -math.cos( radians ), -math.sin( radians ), 0
	signNormal.x, signNormal.y, signNormal.z = nx, ny, 0
	return signPosition, signRight, DOWN, signNormal,
		hanging and bs * 0.0140625 or bs / 96, hanging and 9 or 10
end

local function emitWorldGlyph( origin, right, down, normal, scale, x, y, glyph, color )
	local sx, sy, size = x * scale, y * scale, 8 * scale
	local tx = origin.x + right.x * sx + down.x * sy + normal.x * 0.02
	local ty = origin.y + right.y * sx + down.y * sy + normal.y * 0.02
	local tz = origin.z + right.z * sx + down.z * sy + normal.z * 0.02
	topLeft.x, topLeft.y, topLeft.z = tx, ty, tz
	topRight.x, topRight.y, topRight.z = tx + right.x * size, ty + right.y * size, tz + right.z * size
	bottomLeft.x, bottomLeft.y, bottomLeft.z = tx + down.x * size, ty + down.y * size, tz + down.z * size
	bottomRight.x = topRight.x + down.x * size
	bottomRight.y = topRight.y + down.y * size
	bottomRight.z = topRight.z + down.z * size
	mesh.Position( topLeft ); mesh.Color( color.r, color.g, color.b, color.a ); mesh.TexCoord( 0, glyph.u0, glyph.v0 ); mesh.AdvanceVertex()
	mesh.Position( topRight ); mesh.Color( color.r, color.g, color.b, color.a ); mesh.TexCoord( 0, glyph.u1, glyph.v0 ); mesh.AdvanceVertex()
	mesh.Position( bottomRight ); mesh.Color( color.r, color.g, color.b, color.a ); mesh.TexCoord( 0, glyph.u1, glyph.v1 ); mesh.AdvanceVertex()
	mesh.Position( bottomLeft ); mesh.Color( color.r, color.g, color.b, color.a ); mesh.TexCoord( 0, glyph.u0, glyph.v1 ); mesh.AdvanceVertex()
end

local function drawSignText( bx, by, bz, stateId, record, bs )
	local schema = MC.BlockStateSchemaForState( stateId )
	if not schema or not record.data or not record.data.lines then return end
	local origin, right, down, normal, scale, lineHeight = signTransform( bx, by, bz, stateId, schema.name, bs )
	local lineMidpoint = 4 * lineHeight * 0.5
	local lines = record.data.lines
	for atlasIndex = 1, #FONT_ATLASES do
		local atlas = FONT_ATLASES[atlasIndex]
		local glyphCount = 0
		for lineIndex = 1, 4 do
			local line = cachedLine( lines[lineIndex] or "" )
			for glyphIndex = 1, #line.glyphs do
				if line.glyphs[glyphIndex].atlas == atlas then glyphCount = glyphCount + 1 end
			end
		end
		if glyphCount > 0 then
			render.SetMaterial( atlas.material )
			mesh.Begin( MATERIAL_QUADS, glyphCount )
			for lineIndex = 1, 4 do
				local line = cachedLine( lines[lineIndex] or "" )
				local x = -line.width * 0.5
				local y = ( lineIndex - 1 ) * lineHeight - lineMidpoint
				for glyphIndex = 1, #line.glyphs do
					local glyph = line.glyphs[glyphIndex]
					if glyph.atlas == atlas then emitWorldGlyph( origin, right, down, normal, scale, x, y, glyph, TEXT_COLOR ) end
					x = x + glyph.advance
				end
			end
			mesh.End()
		end
	end
end

local SignRenderEntries, SignRenderCount = {}, 0
local SignRenderRevision, SignRenderGeneration = -1, -1
local SignRenderDirty = true

function MC.MarkSignRenderEntriesDirty()
	SignRenderDirty = true
end

local function rebuildSignRenderEntries()
	for index = 1, SignRenderCount do SignRenderEntries[index] = nil end
	SignRenderCount = 0
	for _, chunk in pairs( MC.World or {} ) do
		for localIndex, record in pairs( chunk.blockEntities or {} ) do
			if record.type == "minecraft:sign" or record.type == "minecraft:hanging_sign" then
				local lx, ly, lz = MC.DecodeLocal( localIndex )
				SignRenderCount = SignRenderCount + 1
				SignRenderEntries[SignRenderCount] = {
					bx = chunk.cx * MC.CS + lx,
					by = chunk.cy * MC.CS + ly,
					bz = chunk.cz * MC.CH + lz,
					record = record,
				}
			end
		end
	end
	SignRenderRevision = tonumber( MC.AppliedStateRevision ) or 0
	SignRenderGeneration = tonumber( MC.StateWorldGeneration ) or 0
	SignRenderDirty = false
end

hook.Add( "PostDrawTranslucentRenderables", "mc_sign_block_entities", function( _, bSky, bSky3D )
	-- bSky (DF_DRAWSKYBOX) is also true on the main pass on 2D-sky maps; skip only the 3D skybox pass
	if bSky3D then return end
	local revision = tonumber( MC.AppliedStateRevision ) or 0
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if SignRenderDirty or revision ~= SignRenderRevision or generation ~= SignRenderGeneration then
		rebuildSignRenderEntries()
	end
	local eye = EyePos()
	local bs = Coords.BlockSize()
	local maxDistanceSqr = ( bs * 64 ) ^ 2
	for index = 1, SignRenderCount do
		local entry = SignRenderEntries[index]
		local center = Coords.CellRenderCenter( entry.bx, entry.by, entry.bz )
		if eye:DistToSqr( center ) <= maxDistanceSqr then
			local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
			if MC.IsEditableSignState( stateId ) then
				drawSignText( entry.bx, entry.by, entry.bz, stateId, entry.record, bs )
			end
		end
	end
end )

local function signWood( stateId )
	local schema = MC.BlockStateSchemaForState( stateId )
	local name = schema and schema.name or "minecraft:oak_sign"
	name = string.gsub( name, "^minecraft:", "" )
	name = string.gsub( name, "_wall_hanging_sign$", "" )
	name = string.gsub( name, "_hanging_sign$", "" )
	name = string.gsub( name, "_wall_sign$", "" )
	return string.gsub( name, "_sign$", "" )
end

local function openEditor( bx, by, bz, lines )
	if IsValid( MC.SignEditorFrame ) then MC.SignEditorFrame:Remove() end
	local editorScale = 2
	local frameWidth, frameHeight = 560, 420
	local stateId = MC.GetBlockState( bx, by, bz )
	local wood = signWood( stateId )
	local schema = MC.BlockStateSchemaForState( stateId )
	local hanging = schema and string.match( schema.name, "_hanging_sign$" ) ~= nil or false
	local wall = schema and string.match( schema.name, "_wall_sign$" ) ~= nil or false
	local maxLineWidth = MC.SignMaxLineWidthForState( stateId )
	local logicalLineHeight = hanging and 9 or 10
	local lineWidth, lineHeight = maxLineWidth * editorScale, logicalLineHeight * editorScale
	local signWidth = ( hanging and 72 or 94 ) * editorScale
	local signHeight = ( hanging and 72 or 101 ) * editorScale
	-- Hanging-sign GUI textures are 16 px tall: rows 0-5 are the beam/chains,
	-- while rows 6-15 are the writable board face. Center text on the board only.
	local hangingBoardTop = signHeight * 6 / 16
	local hangingBoardHeight = signHeight * 10 / 16
	local linesTop = hanging
		and 66 + hangingBoardTop + ( hangingBoardHeight - lineHeight * 4 ) * 0.5
		or 74
	local materialKey = ( hanging and "hanging:" or "plain:" ) .. wood
	local signMaterial = SIGN_GUI_MATERIALS[materialKey]
	if not signMaterial then
		local directory = hanging and "mc/gui/hanging_signs/" or "mc/gui/signs/"
		signMaterial = Material( directory .. wood .. ".png", "noclamp" )
		SIGN_GUI_MATERIALS[materialKey] = signMaterial
	end
	local frame = vgui.Create( "DFrame" )
	MC.SignEditorFrame = frame
	frame:SetSize( frameWidth, frameHeight )
	frame:Center()
	frame:SetTitle( "" )
	frame:MakePopup()
	frame:SetDeleteOnClose( true )

	local submitted = false
	local entries = {}
	local function submit()
		if submitted then return end
		submitted = true
		net.Start( "mc_sign_update" )
			net.WriteInt( bx, MC.Net.COORD_BITS )
			net.WriteInt( by, MC.Net.COORD_BITS )
			net.WriteInt( bz, MC.Net.COORD_BITS )
			for index = 1, 4 do net.WriteString( IsValid( entries[index] ) and entries[index]:GetValue() or "" ) end
		net.SendToServer()
	end
	frame.OnRemove = submit

	frame.Paint = function( _, w, h )
		draw.RoundedBox( 8, 0, 0, w, h, Color( 28, 30, 34, 245 ) )
		draw.SimpleText( hanging and "Edit Hanging Sign" or "Edit Sign", "mc_sign_title",
			w * 0.5, 40, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		surface.SetDrawColor( 255, 255, 255, 255 )
		surface.SetMaterial( signMaterial )
		if hanging then
			surface.DrawTexturedRect( w * 0.5 - signWidth * 0.5, 66, signWidth, signHeight )
		elseif wall then
			surface.DrawTexturedRectUV( w * 0.5 - signWidth * 0.5, 66,
				signWidth, 47 * editorScale, 0, 0, 1, 12 / 26 )
		else
			surface.DrawTexturedRect( w * 0.5 - signWidth * 0.5, 66, signWidth, signHeight )
		end
	end

	for index = 1, 4 do
		local entry = vgui.Create( "DTextEntry", frame )
		entries[index] = entry
		entry:SetPos( ( frameWidth - lineWidth ) * 0.5, linesTop + ( index - 1 ) * lineHeight )
		entry:SetSize( lineWidth, lineHeight )
		entry:SetText( lines[index] or "" )
		entry:SetFont( "mc_sign_fallback_editor" )
		entry:SetTextColor( EDIT_TEXT_COLOR )
		entry:SetDrawBackground( false )
		entry:SetUpdateOnType( true )
		entry:SetEnterAllowed( true )
		entry.Paint = function( self, w, h )
			self:DrawTextEntryText( Color( 0, 0, 0, 0 ), Color( 120, 150, 190, 100 ), Color( 0, 0, 0, 0 ) )
			drawMinecraftLine( self:GetValue(), w * 0.5, ( h - 8 * editorScale ) * 0.5,
				EDIT_TEXT_COLOR, editorScale, "mc_sign_fallback_editor" )
		end
		local accepted = entry:GetValue()
		entry.OnValueChange = function( self, value )
			local _, _, err = MC.SignMeasureLine( value, maxLineWidth )
			if err then
				self:SetText( accepted )
				self:SetCaretPos( #accepted )
			else accepted = value end
		end
		entry.OnEnter = function()
			local nextEntry = entries[index % 4 + 1]
			if IsValid( nextEntry ) then nextEntry:RequestFocus(); nextEntry:SetCaretPos( #nextEntry:GetValue() ) end
		end
	end
	entries[1]:RequestFocus()

	local done = vgui.Create( "DButton", frame )
	done:SetPos( ( frameWidth - 240 ) * 0.5, frameHeight - 48 )
	done:SetSize( 240, 30 )
	done:SetText( "Done" )
	done.DoClick = function() frame:Close() end
end

net.Receive( "mc_sign_open", function()
	local bx = net.ReadInt( MC.Net.COORD_BITS )
	local by = net.ReadInt( MC.Net.COORD_BITS )
	local bz = net.ReadInt( MC.Net.COORD_BITS )
	openEditor( bx, by, bz, { net.ReadString(), net.ReadString(), net.ReadString(), net.ReadString() } )
end )
