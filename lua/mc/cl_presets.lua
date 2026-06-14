--[[----------------------------------------------------------------------------
	MC : client preset UI, screenshots, selection state, and projection rendering.
------------------------------------------------------------------------------]]

MC = MC or {}

local function L( key, fallback, vars )
	return MC.T and MC.T( key, fallback, vars ) or fallback
end

local PRESET_COVER_DIR = "mc/preset_covers"
local PRESET_COVER_PART_BYTES = 16384
local PRESET_DATA_PART_BYTES = 16384
local PRESET_UPLOAD_PART_INTERVAL = 0.05

local UI = {
	frame = Color( 30, 32, 37, 250 ),
	title = Color( 18, 20, 24, 255 ),
	panel = Color( 24, 26, 30, 245 ),
	panelInner = Color( 13, 15, 18, 230 ),
	row = Color( 42, 45, 51, 245 ),
	rowHover = Color( 56, 64, 78, 245 ),
	rowSelected = Color( 72, 84, 104, 245 ),
	control = Color( 44, 48, 55, 245 ),
	controlHover = Color( 80, 92, 112, 245 ),
	controlDown = Color( 104, 112, 132, 245 ),
	accent = Color( 236, 230, 190, 245 ),
	text = Color( 235, 240, 248, 245 ),
	textDim = Color( 165, 174, 188, 220 ),
	error = Color( 240, 110, 110, 245 ),
}

MC.PresetSelectionStep = MC.PresetSelectionStep or 0
MC.PresetSelection = MC.PresetSelection or {}
MC.PresetMode = MC.PresetMode or nil
MC.PresetDraftName = MC.PresetDraftName or nil
MC.ActivePreset = MC.ActivePreset or nil
MC.ActivePresetName = MC.ActivePresetName or nil
MC.PresetProjectionMeshes = MC.PresetProjectionMeshes or nil
if MC.PresetOverwrite == nil then
	MC.PresetOverwrite = false
end
if MC.PresetRotation == nil then
	MC.PresetRotation = 0
end

local CoverMaterialCache = {}
local PendingCoverDownloads = {}
local CoverDownloadBuffers = {}
local PresetDataBuffers = {}

local function trim( value )
	return string.Trim( tostring( value or "" ) )
end

local function presetName( name )
	name = trim( name )
	if name == "" then return nil end
	name = string.gsub( name, "[%c/\\:%*%?\"<>|]", "_" )
	name = string.gsub( name, "%.%.+", "_" )
	name = string.gsub( name, "^%.+", "" )
	name = trim( string.sub( name, 1, 64 ) )
	if name == "" then return nil end
	return name
end

local function generatedPresetName()
	return "preset_" .. os.date( "%Y%m%d_%H%M%S" )
end

local function presetCoverPath( name )
	local safe = presetName( name )
	if not safe then return nil end
	return PRESET_COVER_DIR .. "/" .. safe .. "_" .. math.floor( SysTime() * 1000 ) .. ".jpg"
end

local function chat( msg )
	local ply = LocalPlayer()
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. msg ) end
end

function MC.PresetChat( msg )
	chat( msg )
end

function MC.TogglePresetOverwrite()
	MC.PresetOverwrite = MC.PresetOverwrite ~= true
	if MC.PresetOverwrite then
		chat( L( "preset.overwrite_on", "预设覆盖模式: 开。放置时会覆盖目标体积里的已有方块。" ) )
	else
		chat( L( "preset.overwrite_off", "预设覆盖模式: 关。目标位置有方块时不会放置。" ) )
	end
end

function MC.SetPresetRotation( rotation, silent )
	MC.PresetRotation = MC.PresetNormalizeRotation and MC.PresetNormalizeRotation( rotation ) or 0
	if MC.ActivePreset and MC.BuildPresetProjectionMesh then
		MC.BuildPresetProjectionMesh( MC.ActivePreset, MC.PresetRotation )
	end
	if not silent then
		local degrees = MC.PresetRotationDegrees and MC.PresetRotationDegrees( MC.PresetRotation ) or ( MC.PresetRotation * 90 )
		chat( L( "preset.rotation_chat", "Preset rotation: {degrees} deg", { degrees = degrees } ) )
	end
end

function MC.CyclePresetRotation()
	MC.SetPresetRotation( ( MC.PresetRotation or 0 ) + 1 )
end

local function styleButton( btn, label )
	btn:SetText( "" )
	btn.Paint = function( s, w, h )
		local bg = UI.control
		if s:IsDown() then
			bg = UI.controlDown
		elseif s:IsHovered() then
			bg = UI.controlHover
		end
		draw.RoundedBox( 3, 0, 0, w, h, bg )
		draw.RoundedBox( 2, 3, 3, w - 6, h - 6, Color( 20, 22, 26, 200 ) )
		surface.SetDrawColor( 120, 130, 148, 150 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		draw.SimpleText( label, "mc_hud_small", w * 0.5, h * 0.5, UI.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
end

local function hideScrollBar( scroll )
	if not IsValid( scroll ) or not scroll.GetVBar then return end
	local bar = scroll:GetVBar()
	if not IsValid( bar ) then return end
	bar:SetWide( 0 )
	bar.Paint = function() end
	if IsValid( bar.btnGrip ) then bar.btnGrip.Paint = function() end end
	if IsValid( bar.btnUp ) then bar.btnUp.Paint = function() end end
	if IsValid( bar.btnDown ) then bar.btnDown.Paint = function() end end
end

local function setStatus( frame, message, isError )
	if not IsValid( frame ) or not IsValid( frame.StatusLabel ) then return end
	frame.StatusLabel:SetText( message or "" )
	frame.StatusLabel:SetTextColor( isError and UI.error or UI.textDim )
end

local function requestServerCover( cover )
	cover = trim( cover )
	if cover == "" or file.Exists( cover, "DATA" ) or PendingCoverDownloads[cover] then return end
	PendingCoverDownloads[cover] = true
	net.Start( "mc_preset_cover_req" )
		net.WriteString( cover )
	net.SendToServer()
end

local function coverMaterialForPreset( preset )
	local cover = preset and trim( preset.cover )
	if not cover or cover == "" then return nil end
	if not file.Exists( cover, "DATA" ) then
		requestServerCover( cover )
		return nil
	end
	if CoverMaterialCache[cover] then return CoverMaterialCache[cover] end
	local mat = Material( "../data/" .. cover, "smooth noclamp" )
	if not mat or mat:IsError() then return nil end
	CoverMaterialCache[cover] = mat
	return mat
end

local function drawPresetCover( preset, x, y, w, h )
	draw.RoundedBox( 4, x, y, w, h, Color( 10, 12, 15, 245 ) )
	surface.SetDrawColor( 88, 96, 110, 130 )
	surface.DrawOutlinedRect( x, y, w, h, 1 )

	local mat = coverMaterialForPreset( preset )
	if mat then
		surface.SetDrawColor( 255, 255, 255, 255 )
		surface.SetMaterial( mat )
		surface.DrawTexturedRect( x + 4, y + 4, w - 8, h - 8 )
		return
	end

	draw.SimpleText( L( "preset.no_cover", "暂无截图" ), "mc_hud", x + w * 0.5, y + h * 0.5 - 10, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	draw.SimpleText( L( "preset.auto_cover", "保存预设时自动截图" ), "mc_hud_small", x + w * 0.5, y + h * 0.5 + 16, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

local function capturePresetCover( name, callback )
	callback = callback or function() end
	local coverPath = presetCoverPath( name )
	if not coverPath then callback( "", nil ) return end
	file.CreateDir( "mc" )
	file.CreateDir( PRESET_COVER_DIR )

	local hookName = "MC_PresetCoverCapture_" .. util.CRC( coverPath .. tostring( SysTime() ) )
	local frames = 0
	hook.Add( "PostRender", hookName, function()
		frames = frames + 1
		if frames < 2 then return end
		hook.Remove( "PostRender", hookName )

		local data = render.Capture( {
			format = "jpeg",
			quality = 75,
			x = 0,
			y = 0,
			w = ScrW(),
			h = ScrH(),
		} )
		if not data or data == "" then callback( "", nil ) return end
		file.Write( coverPath, data )
		CoverMaterialCache[coverPath] = nil
		callback( coverPath, data )
	end )
end

local function uploadPresetCover( name, coverPath, data, callback )
	callback = callback or function() end
	if not coverPath or coverPath == "" or not data or data == "" then callback() return end

	local totalBytes = #data
	local parts = math.ceil( totalBytes / PRESET_COVER_PART_BYTES )
	if parts < 1 then callback() return end

	net.Start( "mc_preset_cover_begin" )
		net.WriteString( name )
		net.WriteString( coverPath )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( totalBytes, 32 )
	net.SendToServer()

	local i = 1
	local function sendNextPart()
		if i > parts then callback() return end
		local first = ( i - 1 ) * PRESET_COVER_PART_BYTES + 1
		local chunk = string.sub( data, first, first + PRESET_COVER_PART_BYTES - 1 )
		net.Start( "mc_preset_cover_part" )
			net.WriteString( coverPath )
			net.WriteUInt( i, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.SendToServer()
		i = i + 1
		timer.Simple( PRESET_UPLOAD_PART_INTERVAL, sendNextPart )
	end

	sendNextPart()
end

function MC.RequestPresetList()
	net.Start( "mc_preset_list_req" )
	net.SendToServer()
end

local function requestPresetData( name )
	net.Start( "mc_preset_load_req" )
		net.WriteString( name )
	net.SendToServer()
end

local function freePresetProjectionMeshes()
	for _, m in ipairs( MC.PresetProjectionMeshes or {} ) do
		if m then m:Destroy() end
	end
	MC.PresetProjectionMeshes = nil
end

local function cellKey( x, y, z )
	return x .. ":" .. y .. ":" .. z
end

local TRI = { 1, 3, 2, 1, 4, 3 }
local VERT_LIMIT = 60000
local PROJECTION_COLOR = Color( 165, 210, 255, 145 )

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

local FACE_NORMALS = {
	[MC.Face.TOP] = N_UP,
	[MC.Face.BOTTOM] = N_DOWN,
	[MC.Face.XP] = N_XP,
	[MC.Face.XN] = N_XN,
	[MC.Face.YP] = N_YP,
	[MC.Face.YN] = N_YN,
}

local FACE_OFFSETS = {
	[MC.Face.TOP] = { 0, 0, 1 },
	[MC.Face.BOTTOM] = { 0, 0, -1 },
	[MC.Face.XP] = { 1, 0, 0 },
	[MC.Face.XN] = { -1, 0, 0 },
	[MC.Face.YP] = { 0, 1, 0 },
	[MC.Face.YN] = { 0, -1, 0 },
}

local BOX_FACE_CORNERS = {
	[MC.Face.TOP] = function( b ) return { { b[1], b[2], b[6], 0, 1 }, { b[4], b[2], b[6], 1, 1 }, { b[4], b[5], b[6], 1, 0 }, { b[1], b[5], b[6], 0, 0 } } end,
	[MC.Face.BOTTOM] = function( b ) return { { b[1], b[5], b[3], 0, 1 }, { b[4], b[5], b[3], 1, 1 }, { b[4], b[2], b[3], 1, 0 }, { b[1], b[2], b[3], 0, 0 } } end,
	[MC.Face.XP] = function( b ) return { { b[4], b[2], b[3], 0, 1 }, { b[4], b[5], b[3], 1, 1 }, { b[4], b[5], b[6], 1, 0 }, { b[4], b[2], b[6], 0, 0 } } end,
	[MC.Face.XN] = function( b ) return { { b[1], b[5], b[3], 0, 1 }, { b[1], b[2], b[3], 1, 1 }, { b[1], b[2], b[6], 1, 0 }, { b[1], b[5], b[6], 0, 0 } } end,
	[MC.Face.YP] = function( b ) return { { b[4], b[5], b[3], 0, 1 }, { b[1], b[5], b[3], 1, 1 }, { b[1], b[5], b[6], 1, 0 }, { b[4], b[5], b[6], 0, 0 } } end,
	[MC.Face.YN] = function( b ) return { { b[1], b[2], b[3], 0, 1 }, { b[4], b[2], b[3], 1, 1 }, { b[4], b[2], b[6], 1, 0 }, { b[1], b[2], b[6], 0, 0 } } end,
}

local function rotatedUVFlags( uf, vf, rot )
	rot = ( rot or 0 ) % 4
	if rot == 1 then return vf, 1 - uf end
	if rot == 2 then return 1 - uf, 1 - vf end
	if rot == 3 then return 1 - vf, uf end
	return uf, vf
end

local function isFullBlockBox( box )
	return box[1] == 0 and box[2] == 0 and box[3] == 0 and box[4] == 1 and box[5] == 1 and box[6] == 1
end

function MC.BuildPresetProjectionMesh( preset, rotation )
	freePresetProjectionMeshes()
	if not preset or not istable( preset.cells ) then return nil end

	rotation = MC.PresetNormalizeRotation and MC.PresetNormalizeRotation( rotation ) or 0
	local mat = MC.MaterialTranslucent or MC.Material
	local meshes = {}
	local verts = {}
	local nv = 0
	local fullCells = {}
	local cellInfo = {}
	local origin = { bx = 0, by = 0, bz = 0 }
	local transformedCells = MC.PresetCells and MC.PresetCells( preset, origin, rotation ) or {}

	for _, cell in ipairs( transformedCells ) do
		local dx = math.floor( tonumber( cell.dx or cell.bx ) or 0 )
		local dy = math.floor( tonumber( cell.dy or cell.by ) or 0 )
		local dz = math.floor( tonumber( cell.dz or cell.bz ) or 0 )
		local id = math.floor( tonumber( cell.id ) or 0 )
		local orient = MC.NormalizeOrient( id, cell.orient )
		if MC.IsValidBlock and MC.IsValidBlock( id ) then
			local info = { dx = dx, dy = dy, dz = dz, id = id, orient = orient }
			cellInfo[#cellInfo + 1] = info
			if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then
				fullCells[cellKey( dx, dy, dz )] = true
			end
		end
	end

	local function flush()
		if nv == 0 then return end
		local meshObj = Mesh( mat )
		meshObj:BuildFromTriangles( verts )
		meshes[#meshes + 1] = meshObj
		verts = {}
		nv = 0
	end

	local function push( vert )
		nv = nv + 1
		verts[nv] = vert
		if nv >= VERT_LIMIT then flush() end
	end

	local function emitBoxFace( info, box, face )
		local tile, rot = MC.BlockFace( info.id, face, info.orient )
		local u0, v0, u1, v1 = MC.TileUV( tile or 0 )
		local corners = BOX_FACE_CORNERS[face]( box )
		local normal = FACE_NORMALS[face] or N_UP
		for t = 1, 6 do
			local corner = corners[TRI[t]]
			local uf, vf = rotatedUVFlags( corner[4], corner[5], rot or 0 )
			push( {
				pos = Vector( ( info.dx + corner[1] ) * MC.BS, ( info.dy + corner[2] ) * MC.BS, ( info.dz + corner[3] ) * MC.BS ),
				normal = normal,
				u = uf == 1 and u1 or u0,
				v = vf == 1 and v1 or v0,
				color = PROJECTION_COLOR,
			} )
		end
	end

	for _, info in ipairs( cellInfo ) do
		local boxes = MC.BlockBoxes and MC.BlockBoxes( info.id, info.orient ) or { { 0, 0, 0, 1, 1, 1 } }
		for _, box in ipairs( boxes ) do
			for face = 1, 6 do
				local off = FACE_OFFSETS[face]
				local hidden = isFullBlockBox( box ) and fullCells[cellKey( info.dx + off[1], info.dy + off[2], info.dz + off[3] )]
				if not hidden then emitBoxFace( info, box, face ) end
			end
		end
	end

	flush()
	MC.PresetProjectionMeshes = meshes
	return meshes
end

function MC.LoadPresetForProjection( preset )
	if not preset or not istable( preset.cells ) then return false end
	MC.ActivePreset = preset
	MC.ActivePresetName = preset.name
	MC.PresetMode = "place"
	MC.PresetSelectionStep = 0
	MC.PresetSelection = {}
	MC.PresetRotation = 0
	MC.BuildPresetProjectionMesh( preset, MC.PresetRotation )
	chat( L( "preset.loaded_chat", "已读取预设: {name}。移动准星看投影，G 旋转，左键放置，右键取消。", { name = tostring( preset.name ) } ) )
	return true
end

local function aimedPlacementCell()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
	if aim then
		return aim.bx + math.Round( aim.HitNormal.x ),
			aim.by + math.Round( aim.HitNormal.y ),
			aim.bz + math.Round( aim.HitNormal.z )
	end

	local tr = ply:GetEyeTrace()
	if not tr or not tr.Hit then return nil end
	return MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
end

function MC.PresetCurrentOrigin()
	local preset = MC.ActivePreset
	if not preset or not preset.anchor then return nil end
	local tx, ty, tz = aimedPlacementCell()
	if not tx then return nil end
	local anchor = preset.anchor
	return tx - math.floor( tonumber( anchor[1] ) or 0 ),
		ty - math.floor( tonumber( anchor[2] ) or 0 ),
		tz - math.floor( tonumber( anchor[3] ) or 0 )
end

function MC.DrawPresetProjection()
	if not MC.ActivePreset or not MC.PresetProjectionMeshes then return end
	local ox, oy, oz = MC.PresetCurrentOrigin()
	if not ox then return end

	local mat = MC.MaterialTranslucent or MC.Material
	local matrix = Matrix()
	matrix:SetTranslation( MC.CellWorldMin( ox, oy, oz ) )
	cam.PushModelMatrix( matrix )
		render.SetMaterial( mat )
		render.SetBlend( 0.52 )
		render.SetColorModulation( 0.78, 0.92, 1 )
		for _, meshObj in ipairs( MC.PresetProjectionMeshes ) do
			meshObj:Draw()
		end
		render.SetColorModulation( 1, 1, 1 )
		render.SetBlend( 1 )
	cam.PopModelMatrix()
end

local function aimedExistingBlock()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	return MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
end

local function inSelection( cell, a, b )
	local minx, maxx = math.min( a.bx, b.bx ), math.max( a.bx, b.bx )
	local miny, maxy = math.min( a.by, b.by ), math.max( a.by, b.by )
	local minz, maxz = math.min( a.bz, b.bz ), math.max( a.bz, b.bz )
	return cell.bx >= minx and cell.bx <= maxx
		and cell.by >= miny and cell.by <= maxy
		and cell.bz >= minz and cell.bz <= maxz
end

function MC.StartPresetCapture( name )
	name = presetName( name ) or generatedPresetName()
	freePresetProjectionMeshes()
	MC.ActivePreset = nil
	MC.ActivePresetName = nil
	MC.PresetMode = "create"
	MC.PresetDraftName = name
	MC.PresetSelectionStep = 0
	MC.PresetSelection = {}
	chat( L( "preset.start_chat", "开始新建预设 {name}：左键选择第一个方块。", { name = name } ) )
end

local function sendPresetSave( name, selection, coverPath )
	net.Start( "mc_preset_save" )
		net.WriteString( name )
		net.WriteInt( selection.a.bx, MC.Net.COORD_BITS )
		net.WriteInt( selection.a.by, MC.Net.COORD_BITS )
		net.WriteInt( selection.a.bz, MC.Net.COORD_BITS )
		net.WriteInt( selection.b.bx, MC.Net.COORD_BITS )
		net.WriteInt( selection.b.by, MC.Net.COORD_BITS )
		net.WriteInt( selection.b.bz, MC.Net.COORD_BITS )
		net.WriteInt( selection.anchor.bx, MC.Net.COORD_BITS )
		net.WriteInt( selection.anchor.by, MC.Net.COORD_BITS )
		net.WriteInt( selection.anchor.bz, MC.Net.COORD_BITS )
		net.WriteInt( selection.anchor.nx or 0, 3 )
		net.WriteInt( selection.anchor.ny or 0, 3 )
		net.WriteInt( selection.anchor.nz or 1, 3 )
		net.WriteString( coverPath or "" )
	net.SendToServer()
end

function MC.SavePresetSelection()
	local selection = MC.PresetSelection or {}
	local name = presetName( MC.PresetDraftName ) or generatedPresetName()
	if not selection.a or not selection.b or not selection.anchor then
		chat( L( "preset.selection_incomplete", "预设选择还没完成。" ) )
		return
	end

	MC.PresetSelectionStep = 4
	chat( L( "preset.saving_chat", "正在截图并保存预设: {name}", { name = name } ) )
	capturePresetCover( name, function( coverPath, data )
		uploadPresetCover( name, coverPath, data, function()
			sendPresetSave( name, selection, coverPath )
		end )
	end )
end

function MC.PresetAdvanceSelection()
	if MC.PresetMode ~= "create" then
		MC.StartPresetCapture( MC.PresetDraftName or generatedPresetName() )
	end

	local step = MC.PresetSelectionStep or 0
	local aim = aimedExistingBlock()
	if step < 3 and not aim then
		chat( L( "preset.aim_block", "请准星对准一个 MC 方块。" ) )
		return
	end

	local selection = MC.PresetSelection
	if step == 0 then
		selection.a = { bx = aim.bx, by = aim.by, bz = aim.bz }
		MC.PresetSelectionStep = 1
		chat( L( "preset.step1_chat", "已选择第一个方块。左键选择第二个方块完成范围，右键撤销。" ) )
	elseif step == 1 then
		selection.b = { bx = aim.bx, by = aim.by, bz = aim.bz }
		MC.PresetSelectionStep = 2
		chat( L( "preset.step2_chat", "范围已完成。左键选择一个基准面，之后预设会用它对齐准星。" ) )
	elseif step == 2 then
		local anchor = { bx = aim.bx, by = aim.by, bz = aim.bz }
		if not inSelection( anchor, selection.a, selection.b ) then
			chat( L( "preset.anchor_outside", "基准面必须在刚才选择的范围里。" ) )
			return
		end
		anchor.nx = math.Round( aim.HitNormal.x )
		anchor.ny = math.Round( aim.HitNormal.y )
		anchor.nz = math.Round( aim.HitNormal.z )
		selection.anchor = anchor
		MC.PresetSelectionStep = 3
		chat( L( "preset.step3_chat", "基准面已选择。再按一次左键截图并保存。" ) )
	elseif step == 3 then
		MC.SavePresetSelection()
	end
end

function MC.PresetUndoSelection()
	if MC.PresetMode == "place" and MC.ActivePreset then
		freePresetProjectionMeshes()
		MC.ActivePreset = nil
		MC.ActivePresetName = nil
		MC.PresetMode = nil
		chat( L( "preset.projection_cancelled", "已取消预设投影。" ) )
		return
	end

	local step = MC.PresetSelectionStep or 0
	if step <= 0 then
		MC.PresetMode = nil
		MC.PresetSelection = {}
		chat( L( "preset.selection_cancelled", "已取消预设选择。" ) )
		return
	end

	if step >= 3 then MC.PresetSelection.anchor = nil
	elseif step >= 2 then MC.PresetSelection.b = nil
	elseif step >= 1 then MC.PresetSelection.a = nil end
	MC.PresetSelectionStep = step - 1
	chat( L( "preset.undo", "已撤销一步。" ) )
end

function MC.PlaceActivePreset()
	if not MC.ActivePreset or not MC.ActivePresetName then
		chat( L( "preset.load_first", "先按 R 读取一个预设。" ) )
		return
	end
	local ox, oy, oz = MC.PresetCurrentOrigin()
	if not ox then
		chat( L( "preset.aim_place", "请准星对准可以放置预设的位置。" ) )
		return
	end
	net.Start( "mc_preset_place" )
		net.WriteString( MC.ActivePresetName )
		net.WriteInt( ox, MC.Net.COORD_BITS )
		net.WriteInt( oy, MC.Net.COORD_BITS )
		net.WriteInt( oz, MC.Net.COORD_BITS )
		net.WriteBool( MC.PresetOverwrite == true )
		net.WriteUInt( MC.PresetRotation or 0, 2 )
	net.SendToServer()
end

local ROW_HEIGHT = 72
local ROW_GAP = 6

local function createPresetRow( parent, frame, preset )
	local row = vgui.Create( "DButton", parent )
	row:SetText( "" )
	row.MCRowHeight = ROW_HEIGHT
	row.DoClick = function()
		frame:SelectPreset( preset )
	end
	row.Paint = function( s, w, h )
		local selected = frame.SelectedPreset and frame.SelectedPreset.name == preset.name
		local bg = selected and UI.rowSelected or ( s:IsHovered() and UI.rowHover or UI.row )
		draw.RoundedBox( 4, 0, 0, w, h, bg )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		surface.SetDrawColor( selected and UI.accent or Color( 88, 96, 110, 140 ) )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		MC.DrawFittedText( preset.name, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, 12, 10, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, w - 24 )
		draw.SimpleText( string.format( "%d blocks  %dx%dx%d", preset.blocks or 0, preset.sx or 0, preset.sy or 0, preset.sz or 0 ), "mc_hud_small", 12, 38, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		draw.SimpleText( tostring( preset.createdAtText or "?" ), "mc_hud_small", 12, 54, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end
end

local function infoLine( x, y, label, value, color )
	draw.SimpleText( label, "mc_hud_small", x, y, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	MC.DrawFittedText( tostring( value or "" ), "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, x + 92, y - 2, color or UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 390 )
end

function MC.OpenPresetManager()
	if IsValid( MC.PresetManagerFrame ) then MC.PresetManagerFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( L( "preset.manager_title", "MC 预设放置器" ) )
	local frameH = math.Clamp( ScrH() - 90, 620, 760 )
	fr:SetSize( 980, frameH )
	fr:Center()
	fr:MakePopup()
	fr:SetKeyboardInputEnabled( true )
	fr.Paint = function( _, w, h )
		draw.RoundedBox( 6, 0, 0, w, h, UI.frame )
		draw.RoundedBoxEx( 6, 0, 0, w, 28, UI.title, true, true, false, false )
	end
	fr.OnKeyCodePressed = function( _, key )
		if key == KEY_ESCAPE then fr:Close() end
	end
	MC.PresetManagerFrame = fr

	local header = vgui.Create( "DPanel", fr )
	header:Dock( TOP )
	header:DockMargin( 8, 8, 8, 6 )
	header:SetTall( 78 )
	header.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		draw.SimpleText( L( "preset.header", "新建或读取建筑预设" ), "mc_hud_small", 12, 12, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	local nameEntry = vgui.Create( "DTextEntry", header )
	nameEntry:SetPos( 12, 38 )
	nameEntry:SetSize( 430, 28 )
	nameEntry:SetPlaceholderText( L( "preset.new_name", "新预设名" ) )
	nameEntry:SetValue( generatedPresetName() )
	nameEntry:SetPaintBackground( false )
	nameEntry:SetTextColor( UI.text )
	if nameEntry.SetCursorColor then nameEntry:SetCursorColor( UI.accent ) end
	nameEntry.Paint = function( s, w, h )
		draw.RoundedBox( 3, 0, 0, w, h, Color( 16, 18, 22, 245 ) )
		surface.SetDrawColor( 88, 96, 110, s:HasFocus() and 190 or 110 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		s:DrawTextEntryText( UI.text, Color( 95, 145, 210 ), UI.text )
	end

	local create = vgui.Create( "DButton", header )
	create:SetPos( 454, 38 )
	create:SetSize( 116, 28 )
	styleButton( create, L( "preset.create", "新建预设" ) )
	create.DoClick = function()
		MC.StartPresetCapture( nameEntry:GetValue() )
		fr:Close()
	end

	local refresh = vgui.Create( "DButton", header )
	refresh:SetPos( 582, 38 )
	refresh:SetSize( 76, 28 )
	styleButton( refresh, L( "preset.refresh", "刷新" ) )
	refresh.DoClick = function()
		MC.RequestPresetList()
	end

	fr.StatusLabel = vgui.Create( "DLabel", header )
	fr.StatusLabel:SetPos( 672, 38 )
	fr.StatusLabel:SetSize( 280, 28 )
	fr.StatusLabel:SetTextColor( UI.textDim )
	fr.StatusLabel:SetText( L( "preset.loading", "读取中..." ) )

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body:DockMargin( 8, 0, 8, 8 )
	body.Paint = function() end

	fr.LeftPane = vgui.Create( "DPanel", body )
	fr.LeftPane:Dock( LEFT )
	fr.LeftPane:SetWide( 320 )
	fr.LeftPane:DockMargin( 0, 0, 8, 0 )
	fr.LeftPane.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		draw.SimpleText( L( "preset.list_title", "预设列表" ), "mc_hud", 12, 12, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	fr.RightPane = vgui.Create( "DPanel", body )
	fr.RightPane:Dock( FILL )
	fr.RightPane.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
	end

	local scroll = vgui.Create( "DScrollPanel", fr.LeftPane )
	scroll:Dock( FILL )
	scroll:DockMargin( 8, 42, 8, 8 )
	hideScrollBar( scroll )
	local list = vgui.Create( "DPanel", scroll:GetCanvas() )
	list:Dock( TOP )
	list.Paint = function() end
	list.PerformLayout = function( s, w )
		local y = 0
		for _, child in ipairs( s:GetChildren() ) do
			if IsValid( child ) then
				local h = child.MCRowHeight or ROW_HEIGHT
				child:SetPos( 0, y )
				child:SetSize( w, h )
				y = y + h + ROW_GAP
			end
		end
	end
	fr.PresetListPanel = list

	local actions = vgui.Create( "DPanel", fr.RightPane )
	actions:Dock( BOTTOM )
	actions:DockMargin( 10, 0, 10, 10 )
	actions:SetTall( 42 )
	actions.Paint = function() end

	fr.DetailPanel = vgui.Create( "DPanel", fr.RightPane )
	fr.DetailPanel:Dock( FILL )
	fr.DetailPanel:DockMargin( 10, 10, 10, 6 )
	fr.DetailPanel.Paint = function( _, w, h )
		local preset = fr.SelectedPreset
		local coverAspect = 16 / 9
		local coverW = w - 16
		local coverH = math.min( coverW / coverAspect, h - 178 )
		if coverH < 120 then coverH = 120 end
		coverW = coverH * coverAspect
		drawPresetCover( preset, 8 + ( w - 16 - coverW ) * 0.5, 8, coverW, coverH )

		local infoY = coverH + 28
		draw.SimpleText( L( "preset.info_title", "预设信息" ), "mc_hud", 8, infoY, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		if not preset then
			draw.SimpleText( L( "preset.select_hint", "左侧选择一个预设，或输入名字新建。" ), "mc_hud_small", 8, infoY + 32, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			return
		end
		local sameMap = preset.map == game.GetMap()
		infoLine( 8, infoY + 32, L( "preset.field_preset", "预设" ), preset.name )
		infoLine( 8, infoY + 58, L( "preset.field_map", "地图" ), preset.map, sameMap and UI.text or UI.error )
		infoLine( 8, infoY + 84, L( "preset.field_size", "规模" ), string.format( "%d blocks / %dx%dx%d", preset.blocks or 0, preset.sx or 0, preset.sy or 0, preset.sz or 0 ) )
		infoLine( 8, infoY + 110, L( "preset.field_created", "创建" ), preset.createdAtText )
	end

	local load = vgui.Create( "DButton", actions )
	load:SetPos( 0, 6 )
	load:SetSize( 110, 30 )
	styleButton( load, L( "preset.load_projection", "读取投影" ) )
	load.DoClick = function()
		local preset = fr.SelectedPreset
		if not preset then setStatus( fr, L( "preset.select_first", "先选择一个预设" ), true ) return end
		requestPresetData( preset.name )
		setStatus( fr, L( "preset.loading_projection", "正在读取预设..." ) )
		fr:Close()
	end

	function fr:SelectPreset( preset )
		self.SelectedPreset = preset
		if IsValid( self.PresetListPanel ) then self.PresetListPanel:InvalidateLayout( true ) end
		if IsValid( self.DetailPanel ) then self.DetailPanel:InvalidateLayout( true ) end
	end

	function fr:RefreshPresetRows( message, isError )
		if not IsValid( list ) then return end
		for _, child in ipairs( list:GetChildren() ) do child:Remove() end
		local presets = MC.PresetManagerPresets or {}
		local rowCount = 0
		local selectedName = self.SelectedPreset and self.SelectedPreset.name
		local nextSelected
		for _, preset in ipairs( presets ) do
			if selectedName and preset.name == selectedName then nextSelected = preset end
			createPresetRow( list, self, preset )
			rowCount = rowCount + 1
		end
		if #presets == 0 then
			local empty = vgui.Create( "DLabel", list )
			empty.MCRowHeight = 52
			empty:SetText( L( "preset.empty", "还没有预设。输入名字后点“新建预设”。" ) )
			empty:SetTextColor( UI.textDim )
			empty:SetContentAlignment( 5 )
			rowCount = 1
			self:SelectPreset( nil )
		else
			self:SelectPreset( nextSelected or presets[1] )
		end
		local totalH = rowCount * ROW_HEIGHT + math.max( 0, rowCount - 1 ) * ROW_GAP
		if #presets == 0 then totalH = 52 end
		list:SetTall( totalH )
		list:InvalidateLayout( true )
		setStatus( self, message ~= "" and message or L( "preset.count", "{count} 个预设", { count = #presets } ), isError )
	end

	MC.RequestPresetList()
end

net.Receive( "mc_preset_list_data", function()
	local message = net.ReadString()
	local isError = net.ReadBool()
	local count = net.ReadUInt( 12 )
	local presets = {}
	for i = 1, count do
		presets[i] = {
			name = net.ReadString(),
			map = net.ReadString(),
			blocks = net.ReadUInt( 32 ),
			sx = net.ReadUInt( 16 ),
			sy = net.ReadUInt( 16 ),
			sz = net.ReadUInt( 16 ),
			createdAtText = net.ReadString(),
			cover = net.ReadString(),
		}
	end
	MC.PresetManagerPresets = presets
	if IsValid( MC.PresetManagerFrame ) and MC.PresetManagerFrame.RefreshPresetRows then
		MC.PresetManagerFrame:RefreshPresetRows( message, isError )
	elseif message ~= "" then
		chat( message )
	end
end )

net.Receive( "mc_preset_data", function()
	local name = net.ReadString()
	local message = net.ReadString()
	local isError = net.ReadBool()
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	if isError or expectedParts < 1 or totalBytes < 1 then
		chat( L( "preset.load_failed", "预设读取失败: {message}", { message = tostring( message ) } ) )
		return
	end
	PresetDataBuffers[name] = {
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		receivedParts = 0,
		receivedBytes = 0,
		parts = {},
	}
end )

net.Receive( "mc_preset_data_part", function()
	local name = net.ReadString()
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	local download = PresetDataBuffers[name]
	if not download or index < 1 or index > download.expectedParts then return end
	if len < 1 or len > PRESET_DATA_PART_BYTES or not chunk or #chunk ~= len or download.parts[index] then return end

	download.parts[index] = chunk
	download.receivedParts = download.receivedParts + 1
	download.receivedBytes = download.receivedBytes + len
	if download.receivedBytes > download.totalBytes then
		PresetDataBuffers[name] = nil
		return
	end
	if download.receivedParts < download.expectedParts then return end

	local data = table.concat( download.parts )
	PresetDataBuffers[name] = nil
	if #data ~= download.totalBytes then return end

	local json = util.Decompress( data )
	local preset = json and util.JSONToTable( json ) or nil
	if not preset then
		chat( L( "preset.load_damaged", "预设读取失败: 数据损坏" ) )
		return
	end
	MC.LoadPresetForProjection( preset )
end )

net.Receive( "mc_preset_cover_download_begin", function()
	local cover = trim( net.ReadString() )
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	if cover == "" or expectedParts < 1 or totalBytes < 1 then return end
	CoverDownloadBuffers[cover] = {
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		receivedParts = 0,
		receivedBytes = 0,
		parts = {},
	}
end )

net.Receive( "mc_preset_cover_download_part", function()
	local cover = trim( net.ReadString() )
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	local download = CoverDownloadBuffers[cover]
	if not download or index < 1 or index > download.expectedParts then return end
	if len < 1 or not chunk or #chunk ~= len or download.parts[index] then return end

	download.parts[index] = chunk
	download.receivedParts = download.receivedParts + 1
	download.receivedBytes = download.receivedBytes + len
	if download.receivedBytes > download.totalBytes then
		CoverDownloadBuffers[cover] = nil
		PendingCoverDownloads[cover] = nil
		return
	end
	if download.receivedParts < download.expectedParts then return end

	local data = table.concat( download.parts )
	CoverDownloadBuffers[cover] = nil
	PendingCoverDownloads[cover] = nil
	if #data ~= download.totalBytes then return end

	file.CreateDir( "mc" )
	file.CreateDir( PRESET_COVER_DIR )
	file.Write( cover, data )
	CoverMaterialCache[cover] = nil
	if IsValid( MC.PresetManagerFrame ) and IsValid( MC.PresetManagerFrame.DetailPanel ) then
		MC.PresetManagerFrame.DetailPanel:InvalidateLayout( true )
	end
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_preset_projection", function( _, bSky, bSky3D )
	if bSky or bSky3D then return end
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return end
	local wep = ply:GetActiveWeapon()
	if not IsValid( wep ) or wep:GetClass() ~= "mc_preset_placer" then return end
	if MC.PresetMode ~= "place" then return end
	MC.DrawPresetProjection()
end )

concommand.Add( "mc_preset_manager", function()
	MC.OpenPresetManager()
end )

concommand.Add( "mc_presets_ui", function()
	MC.OpenPresetManager()
end )

if MC.RegisterLanguageChanged then
	MC.RegisterLanguageChanged( "mc_preset_ui", function()
		if IsValid( MC.PresetManagerFrame ) then
			MC.PresetManagerFrame:Remove()
			MC.OpenPresetManager()
		end
	end )
end
