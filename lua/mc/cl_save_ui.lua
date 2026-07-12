--[[----------------------------------------------------------------------------
	MC : client save manager UI.
------------------------------------------------------------------------------]]

MC = MC or {}

local function L( key, fallback, vars )
	return MC.T and MC.T( key, fallback, vars ) or fallback
end

local SAVE_COVER_DIR = "mc/save_covers"
local SAVE_COVER_PART_BYTES = 16384
local SAVE_COVER_UPLOAD_PART_INTERVAL = 0.05
local SAVE_COVER_UPLOAD_TIMEOUT = 20
local MAX_SAVE_COVER_BYTES = 1024 * 1024 * 2

-- Save manager variant of the mc_config palette. Keep this local so the
-- preset library can retain its lighter library theme.
local UI = {
	frame = Color( 31, 32, 34, 252 ),
	title = Color( 38, 39, 41, 255 ),
	panel = Color( 39, 40, 42, 255 ),
	panelInner = Color( 28, 29, 31, 255 ),
	sidebar = Color( 34, 35, 37, 255 ),
	row = Color( 44, 45, 47, 255 ),
	rowHover = Color( 48, 49, 51, 255 ),
	rowSelected = Color( 52, 76, 98, 255 ),
	control = Color( 82, 119, 153, 255 ),
	controlHover = Color( 98, 136, 169, 255 ),
	controlDown = Color( 52, 76, 98, 255 ),
	quiet = Color( 43, 44, 46, 255 ),
	quietHover = Color( 55, 57, 59, 255 ),
	danger = Color( 160, 74, 68, 255 ),
	dangerHover = Color( 178, 86, 79, 255 ),
	accent = Color( 82, 119, 153, 255 ),
	accentSoft = Color( 52, 76, 98, 255 ),
	input = Color( 28, 29, 31, 255 ),
	text = Color( 235, 233, 228, 255 ),
	textOnBlue = Color( 244, 244, 241, 255 ),
	textDim = Color( 170, 171, 168, 255 ),
	border = Color( 68, 70, 73, 255 ),
	error = Color( 160, 74, 68, 255 ),
	warm = Color( 199, 159, 96, 255 ),
	cover = Color( 43, 44, 46, 255 ),
	mapMismatch = Color( 74, 61, 48, 255 ),
	groupPill = Color( 55, 57, 59, 255 ),
	transparent = Color( 0, 0, 0, 0 ),
	imageTint = Color( 255, 255, 255, 255 ),
}

local CoverMaterialCache = {}
local PendingCoverDownloads = {}
local CoverDownloadBuffers = {}
local PendingCoverUploads = {}

local function trim( value )
	return string.Trim( tostring( value or "" ) )
end

local function canUseSaveManager()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return false end
	if ply:IsAdmin() then return true end
	local cv = GetConVar( "mc_save_public" )
	return cv and cv:GetBool() or false
end

local function saveSlotName( name )
	name = trim( name )
	if name == "" then return nil end
	name = string.gsub( name, "[%c/\\:%*%?\"<>|]", "_" )
	name = string.gsub( name, "%.%.+", "_" )
	name = string.gsub( name, "^%.+", "" )
	name = trim( string.sub( name, 1, 64 ) )
	if name == "" then return nil end
	return name
end

local function saveCoverPath( slotName )
	local safe = saveSlotName( slotName )
	if not safe then return nil end
	local stamp = math.floor( SysTime() * 1000 )
	return SAVE_COVER_DIR .. "/" .. safe .. "_" .. stamp .. ".jpg"
end

local function deleteLocalSaveCovers( slotName, keepPath )
	local safe = saveSlotName( slotName )
	if not safe then return end

	local function deletePath( path )
		if path == keepPath then return end
		CoverMaterialCache[path] = nil
		if file.Exists( path, "DATA" ) then file.Delete( path ) end
	end

	deletePath( SAVE_COVER_DIR .. "/" .. safe .. ".jpg" )

	local files = file.Find( SAVE_COVER_DIR .. "/" .. safe .. "_*.jpg", "DATA" ) or {}
	for _, fn in ipairs( files ) do
		deletePath( SAVE_COVER_DIR .. "/" .. fn )
	end
end

local function styleButton( btn, label, danger )
	MC.LibraryStyleButton( btn, label, danger and "danger" or nil, UI )
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

local function captureSaveCover( slotName, callback )
	callback = callback or function() end
	local coverPath = saveCoverPath( slotName )
	if not coverPath then callback( "", nil ) return end
	file.CreateDir( "mc" )
	file.CreateDir( SAVE_COVER_DIR )

	local hookName = "MC_SaveCoverCapture_" .. util.CRC( coverPath .. tostring( SysTime() ) )
	local timerName = hookName .. "_timeout"
	local finished = false
	local function finish( path, data )
		if finished then return end
		finished = true
		hook.Remove( "PostRender", hookName )
		timer.Remove( timerName )
		callback( path or "", data )
	end
	timer.Create( timerName, 5, 1, function() finish( "", nil ) end )
	local frames = 0
	hook.Add( "PostRender", hookName, function()
		frames = frames + 1
		if frames < 2 then return end

		local data = render.Capture( {
			format = "jpeg",
			quality = 65,
			x = 0,
			y = 0,
			w = ScrW(),
			h = ScrH(),
		} )
		if not data or data == "" then finish( "", nil ) return end

		file.Write( coverPath, data )
		CoverMaterialCache[coverPath] = nil
		deleteLocalSaveCovers( slotName, coverPath )
		finish( coverPath, data )
	end )
end

local function uploadSaveCover( slotName, coverPath, data, callback )
	callback = callback or function() end
	if not coverPath or coverPath == "" or not data or data == "" then callback( true, "" ) return end

	local totalBytes = #data
	if totalBytes > MAX_SAVE_COVER_BYTES then callback( false, "", "too_large" ) return end
	local parts = math.ceil( totalBytes / SAVE_COVER_PART_BYTES )
	if parts < 1 then callback( true, "" ) return end

	local timerName = "MC_SaveCoverUploadTimeout_" .. util.CRC( coverPath )
	PendingCoverUploads[coverPath] = { callback = callback, timerName = timerName }
	timer.Create( timerName, SAVE_COVER_UPLOAD_TIMEOUT, 1, function()
		local pending = PendingCoverUploads[coverPath]
		if not pending then return end
		PendingCoverUploads[coverPath] = nil
		pending.callback( false, "", "timeout" )
	end )

	net.Start( "mc_save_cover_begin" )
		net.WriteString( slotName )
		net.WriteString( coverPath )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( totalBytes, 32 )
	net.SendToServer()

	local i = 1
	local function sendNextPart()
		if not PendingCoverUploads[coverPath] or i > parts then return end

		local first = ( i - 1 ) * SAVE_COVER_PART_BYTES + 1
		local chunk = string.sub( data, first, first + SAVE_COVER_PART_BYTES - 1 )
		net.Start( "mc_save_cover_part" )
			net.WriteString( coverPath )
			net.WriteUInt( i, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.SendToServer()

		i = i + 1
		if i <= parts then timer.Simple( SAVE_COVER_UPLOAD_PART_INTERVAL, sendNextPart ) end
	end

	sendNextPart()
end

local function requestServerCover( cover )
	cover = trim( cover )
	if cover == "" or file.Exists( cover, "DATA" ) or PendingCoverDownloads[cover] then return end
	PendingCoverDownloads[cover] = true
	net.Start( "mc_save_cover_req" )
		net.WriteString( cover )
	net.SendToServer()
end

local function coverMaterialForSave( save )
	local cover = save and trim( save.cover )
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

local function drawSaveCover( save, x, y, w, h )
	surface.SetDrawColor( UI.cover )
	surface.DrawRect( x, y, w, h )
	surface.SetDrawColor( UI.border )
	surface.DrawOutlinedRect( x, y, w, h, 1 )

	local mat = coverMaterialForSave( save )
	if mat then
		surface.SetDrawColor( UI.imageTint )
		surface.SetMaterial( mat )
		surface.DrawTexturedRect( x + 5, y + 5, w - 10, h - 10 )
		return
	end

	draw.SimpleText( L( "save.no_cover", "暂无截图" ), "mc_hud", x + w * 0.5, y + h * 0.5 - 10, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	draw.SimpleText( L( "save.auto_cover", "保存一次会自动截图" ), "mc_hud_small", x + w * 0.5, y + h * 0.5 + 16, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
end

local function infoLine( x, y, label, value, color )
	draw.SimpleText( label, "mc_hud_small", x, y, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	MC.DrawFittedText( tostring( value or "" ), "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, x + 90, y - 2, color or UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 360 )
end

function MC.RequestSaveList()
	net.Start( "mc_save_list_req" )
	net.SendToServer()
end

local function sendSaveActionNow( action, slotName, coverPath )
	net.Start( "mc_save_action" )
		net.WriteString( action )
		net.WriteString( slotName )
		net.WriteString( coverPath or "" )
	net.SendToServer()
end

local function sendSaveAction( action, slotName, captureCover )
	if ( action == "save" or action == "load" ) and not canUseSaveManager() then
		setStatus( MC.SaveManagerFrame, L( "save.admin_only", "默认只有管理员可以保存和读取存档" ), true )
		return
	end
	slotName = trim( slotName )
	if slotName == "" then
		setStatus( MC.SaveManagerFrame, L( "save.enter_name", "请输入存档名" ), true )
		return
	end

	if action == "save" and captureCover ~= false then
		local frame = MC.SaveManagerFrame
		if IsValid( frame ) and frame.UploadBusy then
			setStatus( frame, L( "save.upload_busy", "截图正在上传，请稍候" ), true )
			return
		end
		if IsValid( frame ) then frame.UploadBusy = true end
		if IsValid( frame ) then frame:SetVisible( false ) end
		captureSaveCover( slotName, function( coverPath, data )
			if IsValid( frame ) then
				frame:SetVisible( true )
				frame:MakePopup()
				setStatus( frame, L( "save.uploading", "正在上传截图和保存存档..." ) )
			end

			uploadSaveCover( slotName, coverPath, data, function( ok, confirmedCover, err )
				if IsValid( frame ) then frame.UploadBusy = false end
				if not ok then
					setStatus( frame, L( "save.upload_failed", "截图上传失败，未执行保存: {err}", { err = tostring( err or "error" ) } ), true )
					return
				end
				sendSaveActionNow( action, slotName, confirmedCover or "" )
			end )
		end )
		return
	end

	sendSaveActionNow( action, slotName, "" )
end

local ROW_HEIGHT = 82
local ROW_GAP = 8

local function createSaveRow( parent, frame, save )
	local row = vgui.Create( "DButton", parent )
	row:SetText( "" )
	row.MCRowHeight = ROW_HEIGHT
	row.Save = save
	row.DoClick = function()
		frame:SelectSave( save )
	end
	row.Paint = function( s, w, h )
		local selected = frame.SelectedSave and frame.SelectedSave.name == save.name
		local bg = selected and UI.rowSelected or ( s:IsHovered() and UI.rowHover or UI.row )
		surface.SetDrawColor( bg )
		surface.DrawRect( 0, 0, w, h )
		if selected then
			surface.SetDrawColor( UI.accent )
			surface.DrawRect( 0, 0, 4, h )
		end

		local sameMap = save.map == game.GetMap()
		MC.DrawFittedText( save.name, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, 14, 11, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, w - 158 )
		local mapText = L( "save.map_prefix", "地图: {map}", { map = tostring( save.map ) } )
		local mapW = MC.LibraryDrawPill( mapText, 14, 43, sameMap and UI.accentSoft or UI.mapMismatch, sameMap and UI.text or UI.error )
		local groupName = MC.LibraryGetGroupName( MC.LibraryGetItemGroup( "save", save.name ) )
		if groupName then
			surface.SetFont( "mc_library_section" )
			local groupW = surface.GetTextSize( groupName ) + 16
			local groupX = w - groupW - 14
			if 20 + mapW < groupX then MC.LibraryDrawPill( groupName, groupX, 43, UI.groupPill, UI.textDim ) end
		end
		draw.SimpleText( tostring( save.savedAtText ), "mc_library_section", w - 14, h - 10, UI.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM )
	end
end

function MC.OpenSaveManager()
	if IsValid( MC.SaveManagerFrame ) then MC.SaveManagerFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "" )
	fr:ShowCloseButton( false )
	local frameH = math.Clamp( ScrH() - 60, 660, 880 )
	local frameW = math.Clamp( ScrW() - 60, 1020, 1240 )
	fr:SetSize( frameW, frameH )
	fr:Center()
	fr:MakePopup()
	fr:SetKeyboardInputEnabled( true )
	fr:DockPadding( 12, 68, 12, 12 )
	fr.MapFilter = "*"
	fr.GroupFilter = "*"
	fr.SearchText = ""
	fr.Paint = function( _, w, h )
		surface.SetDrawColor( UI.frame )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.title )
		surface.DrawRect( 0, 0, w, 58 )
		draw.SimpleText( L( "save.title", "MC 存档管理" ), "mc_library_title", 22, 13, UI.textOnBlue, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		draw.SimpleText( L( "library.save_subtitle", "整理、筛选并回到你的方块世界" ), "mc_library_section", 22, 40, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end
	fr.OnKeyCodePressed = function( _, key )
		if key == KEY_ESCAPE then fr:Close() end
	end
	MC.SaveManagerFrame = fr
	local canManage = canUseSaveManager()

	local close = vgui.Create( "DButton", fr )
	close:SetText( "" )
	close:SetSize( 36, 36 )
	close:SetPos( fr:GetWide() - 48, 11 )
	close:SetCursor( "hand" )
	close.Paint = function( s, w, h )
		surface.SetDrawColor( s:IsHovered() and UI.controlHover or UI.controlDown )
		surface.DrawRect( 0, 0, w, h )
		draw.SimpleText( "×", "mc_hud_big", w * 0.5, h * 0.5 - 1, UI.textOnBlue, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
	close.DoClick = function() fr:Close() end

	local header = vgui.Create( "DPanel", fr )
	header:Dock( TOP )
	header:DockMargin( 0, 0, 0, 10 )
	header:SetTall( 68 )
	header.Paint = function( _, w, h )
		surface.SetDrawColor( UI.panel )
		surface.DrawRect( 0, 0, w, h )
		draw.SimpleText( L( "save.current_map", "当前地图: {map}", { map = game.GetMap() } ), "mc_library_section", 14, 10, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	local nameEntry = vgui.Create( "DTextEntry", header )
	nameEntry:SetPos( 14, 32 )
	nameEntry:SetSize( 500, 28 )
	MC.LibraryStyleTextEntry( nameEntry, L( "save.new_name", "新存档名" ), UI )
	nameEntry:SetEnabled( canManage )
	fr.NameEntry = nameEntry

	local saveNew = vgui.Create( "DButton", header )
	saveNew:SetPos( 526, 32 )
	saveNew:SetSize( 110, 28 )
	styleButton( saveNew, L( "save.save_current", "保存当前" ) )
	saveNew:SetEnabled( canManage )
	saveNew.DoClick = function()
		sendSaveAction( "save", nameEntry:GetValue(), true )
	end

	local refresh = vgui.Create( "DButton", header )
	refresh:SetPos( 646, 32 )
	refresh:SetSize( 76, 28 )
	MC.LibraryStyleButton( refresh, L( "save.refresh", "刷新" ), "quiet", UI )
	refresh.DoClick = function()
		MC.RequestSaveList()
	end

	fr.StatusLabel = vgui.Create( "DLabel", header )
	fr.StatusLabel:SetPos( 734, 32 )
	fr.StatusLabel:SetSize( frameW - 760, 28 )
	fr.StatusLabel:SetTextColor( UI.textDim )
	fr.StatusLabel:SetText( L( "save.loading", "读取中..." ) )
	fr.StatusLabel:SetContentAlignment( 6 )

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body.Paint = function() end

	fr.LeftPane = vgui.Create( "DPanel", body )
	fr.LeftPane:Dock( LEFT )
	fr.LeftPane:SetWide( 210 )
	fr.LeftPane:DockMargin( 0, 0, 10, 0 )
	fr.LeftPane.Paint = function( _, w, h )
		surface.SetDrawColor( UI.sidebar )
		surface.DrawRect( 0, 0, w, h )
		draw.SimpleText( L( "library.filter", "筛选" ), "mc_hud", 12, 12, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	fr.CenterPane = vgui.Create( "DPanel", body )
	fr.CenterPane:Dock( LEFT )
	fr.CenterPane:SetWide( 360 )
	fr.CenterPane:DockMargin( 0, 0, 10, 0 )
	fr.CenterPane.Paint = function( _, w, h )
		surface.SetDrawColor( UI.panel )
		surface.DrawRect( 0, 0, w, h )
		draw.SimpleText( L( "save.list_title", "存档" ), "mc_hud", 12, 12, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	fr.RightPane = vgui.Create( "DPanel", body )
	fr.RightPane:Dock( FILL )
	fr.RightPane.Paint = function( _, w, h )
		surface.SetDrawColor( UI.panel )
		surface.DrawRect( 0, 0, w, h )
	end

	local filterScroll = vgui.Create( "DScrollPanel", fr.LeftPane )
	filterScroll:Dock( FILL )
	filterScroll:DockMargin( 8, 44, 8, 8 )
	hideScrollBar( filterScroll )
	local filterList = vgui.Create( "DPanel", filterScroll:GetCanvas() )
	filterList:Dock( TOP )
	filterList.Paint = function() end
	filterList.PerformLayout = function( s, w )
		local y = 0
		for _, child in ipairs( s:GetChildren() ) do
			if IsValid( child ) then
				local h = child.MCRowHeight or 34
				child:SetPos( 0, y )
				child:SetSize( w, h )
				y = y + h + 4
			end
		end
	end
	fr.FilterListPanel = filterList

	local search = vgui.Create( "DTextEntry", fr.CenterPane )
	search:Dock( TOP )
	search:DockMargin( 10, 44, 10, 8 )
	search:SetTall( 32 )
	MC.LibraryStyleTextEntry( search, L( "library.search", "搜索名称或地图" ), UI )
	search.OnValueChange = function( _, value )
		fr.SearchText = value or ""
		if fr.RefreshSaveRows then fr:RefreshSaveRows( "", false, true ) end
	end

	local scroll = vgui.Create( "DScrollPanel", fr.CenterPane )
	scroll:Dock( FILL )
	scroll:DockMargin( 10, 0, 10, 10 )
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
	fr.SaveListPanel = list

	local actions = vgui.Create( "DPanel", fr.RightPane )
	actions:Dock( BOTTOM )
	actions:DockMargin( 10, 0, 10, 10 )
	actions:SetTall( 86 )
	actions.Paint = function() end

	fr.DetailPanel = vgui.Create( "DPanel", fr.RightPane )
	fr.DetailPanel:Dock( FILL )
	fr.DetailPanel:DockMargin( 10, 10, 10, 6 )
	fr.DetailPanel.Paint = function( _, w, h )
		local save = fr.SelectedSave
		local infoHeight = save and 194 or 64
		local coverAspect = 16 / 9
		local coverY = 8
		local coverW = w - 16
		local coverH = coverW / coverAspect
		local maxCoverH = math.Clamp( h - infoHeight - 34, 80, coverH )
		if coverH > maxCoverH then
			coverH = maxCoverH
			coverW = coverH * coverAspect
		end
		drawSaveCover( save, 8 + ( w - 16 - coverW ) * 0.5, coverY, coverW, coverH )

		local infoY = coverY + coverH + 18
		draw.SimpleText( L( "save.info_title", "地图信息" ), "mc_hud", 8, infoY, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		if not save then
			draw.SimpleText( L( "save.select_hint", "左侧选择一个存档。" ), "mc_hud_small", 8, infoY + 32, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			return
		end

		local sameMap = save.map == game.GetMap()
		infoLine( 8, infoY + 32, L( "save.field_save", "存档" ), save.name )
		infoLine( 8, infoY + 58, L( "save.field_map", "地图" ), save.map, sameMap and UI.text or UI.error )
		infoLine( 8, infoY + 84, L( "save.field_saved", "保存" ), save.savedAtText )
		infoLine( 8, infoY + 110, L( "save.field_size", "规模" ), string.format( "%d blocks / %d chunks", save.blocks or 0, save.chunks or 0 ) )
		local groupName = MC.LibraryGetGroupName( MC.LibraryGetItemGroup( "save", save.name ) ) or L( "library.group_none", "未分组" )
		infoLine( 8, infoY + 136, L( "library.group", "分组" ), groupName )
	end

	local load = vgui.Create( "DButton", actions )
	load:SetPos( 0, 8 )
	load:SetSize( 96, 30 )
	styleButton( load, L( "save.load", "读取" ) )
	load:SetEnabled( canManage )
	load.DoClick = function()
		local save = fr.SelectedSave
		if not save then setStatus( fr, L( "save.select_first", "先选择一个存档" ), true ) return end
		Derma_Query(
			L( "save.load_confirm_body", "读取存档会替换当前 MC 方块世界，并重新同步所有客户端。" ),
			L( "save.load_confirm_title", "读取存档: {name}", { name = save.name } ),
			L( "save.load", "读取" ),
			function() sendSaveAction( "load", save.name, false ) end,
			L( "save.cancel", "取消" )
		)
	end

	local overwrite = vgui.Create( "DButton", actions )
	overwrite:SetPos( 104, 8 )
	overwrite:SetSize( 142, 30 )
	styleButton( overwrite, L( "save.overwrite", "覆盖并截图" ) )
	overwrite:SetEnabled( canManage )
	overwrite.DoClick = function()
		local save = fr.SelectedSave
		if not save then setStatus( fr, L( "save.select_first", "先选择一个存档" ), true ) return end
		Derma_Query(
			L( "save.overwrite_confirm_body", "用当前世界覆盖这个命名存档，并刷新截图？" ),
			L( "save.overwrite_confirm_title", "覆盖存档: {name}", { name = save.name } ),
			L( "save.overwrite", "覆盖" ),
			function() sendSaveAction( "save", save.name, true ) end,
			L( "save.cancel", "取消" )
		)
	end

	if LocalPlayer():IsAdmin() then
		local delete = vgui.Create( "DButton", actions )
		delete:SetPos( 254, 8 )
		delete:SetSize( 96, 30 )
		styleButton( delete, L( "save.delete", "删除" ), true )
		delete.DoClick = function()
			local save = fr.SelectedSave
			if not save then setStatus( fr, L( "save.select_first", "先选择一个存档" ), true ) return end
			Derma_Query(
				L( "save.delete_confirm_body", "删除后不会自动恢复。" ),
				L( "save.delete_confirm_title", "删除存档: {name}", { name = save.name } ),
				L( "save.delete", "删除" ),
				function() sendSaveAction( "delete", save.name, false ) end,
				L( "save.cancel", "取消" )
			)
		end
	end

	local groupLabel = vgui.Create( "DLabel", actions )
	groupLabel:SetFont( "mc_library_section" )
	groupLabel:SetText( L( "library.move_to_group", "整理到" ) )
	groupLabel:SetTextColor( UI.textDim )
	groupLabel:SetContentAlignment( 6 )

	local groupCombo = vgui.Create( "DComboBox", actions )
	groupCombo:SetTall( 30 )
	MC.LibraryStyleCombo( groupCombo, UI )
	groupCombo.OnSelect = function( _, _, _, data )
		if fr.UpdatingGroupCombo then return end
		local save = fr.SelectedSave
		if not save then return end
		local groupID = data ~= false and data or nil
		MC.LibraryAssignItemGroup( "save", save.name, groupID )
		fr:RefreshSaveRows( "", false )
	end
	actions.PerformLayout = function( _, w )
		groupLabel:SetPos( 0, 48 )
		groupLabel:SetSize( 54, 30 )
		groupCombo:SetPos( 62, 48 )
		groupCombo:SetSize( math.max( 120, w - 62 ), 30 )
	end
	fr.GroupCombo = groupCombo

	function fr:RefreshGroupCombo()
		if not IsValid( groupCombo ) then return end
		self.UpdatingGroupCombo = true
		groupCombo:Clear()
		local selectedID = self.SelectedSave and MC.LibraryGetItemGroup( "save", self.SelectedSave.name ) or nil
		groupCombo:AddChoice( L( "library.group_none", "未分组" ), false, not selectedID )
		for _, group in ipairs( MC.LibraryGetGroups() ) do
			groupCombo:AddChoice( group.name, group.id, selectedID == group.id )
		end
		groupCombo:SetEnabled( self.SelectedSave ~= nil )
		self.UpdatingGroupCombo = false
	end

	function fr:SelectSave( save )
		self.SelectedSave = save
		if save and IsValid( self.NameEntry ) then self.NameEntry:SetValue( save.name or "" ) end
		if IsValid( self.SaveListPanel ) then self.SaveListPanel:InvalidateLayout( true ) end
		if IsValid( self.DetailPanel ) then self.DetailPanel:InvalidateLayout( true ) end
		self:RefreshGroupCombo()
	end

	local function addFilterHeading( textValue, withAdd )
		local heading = vgui.Create( "DPanel", filterList )
		heading.MCRowHeight = 30
		heading.Paint = function( _, w, h )
			draw.SimpleText( textValue, "mc_library_section", 6, h * 0.5, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end
		if withAdd then
			local add = vgui.Create( "DButton", heading )
			add:Dock( RIGHT )
			add:DockMargin( 0, 3, 2, 3 )
			add:SetWide( 46 )
			MC.LibraryStyleButton( add, L( "library.new", "+ 新建" ), "quiet", UI )
			add.DoClick = function()
				Derma_StringRequest( L( "library.new_group", "新建分组" ), L( "library.group_name", "输入分组名称" ), "", function( name )
					local id = MC.LibraryCreateGroup( name )
					if not id then setStatus( fr, L( "library.group_exists", "分组名称不能为空或已存在" ), true ) return end
					fr.GroupFilter = "*"
					fr:RefreshSaveRows( "", false )
				end )
			end
		end
	end

	local function addFilterButton( label, count, value, isMap, groupID )
		local btn = vgui.Create( "DButton", filterList )
		btn:SetText( "" )
		btn:SetCursor( "hand" )
		btn.MCRowHeight = 34
		btn.Paint = function( s, w, h )
			local selected = isMap and fr.MapFilter == value or ( not isMap and fr.GroupFilter == value )
			local bg = selected and UI.panel or ( s:IsHovered() and UI.quietHover or UI.transparent )
			surface.SetDrawColor( bg )
			surface.DrawRect( 0, 0, w, h )
			if selected then
				surface.SetDrawColor( UI.accent )
				surface.DrawRect( 0, 0, 4, h )
			end
			MC.DrawFittedText( label, "mc_hud_small", { "mc_library_section" }, 10, h * 0.5, selected and UI.text or UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, w - 46 )
			draw.SimpleText( tostring( count or 0 ), "mc_library_section", w - 10, h * 0.5, UI.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			if isMap then fr.MapFilter = value else fr.GroupFilter = value end
			fr:RefreshSaveRows( "", false, true )
		end
		if groupID then
			btn:SetTooltip( L( "library.group_manage_hint", "右键可重命名或删除分组" ) )
			btn.DoRightClick = function()
				local menu = DermaMenu()
				menu:AddOption( L( "library.rename_group", "重命名分组" ), function()
					Derma_StringRequest( L( "library.rename_group", "重命名分组" ), L( "library.group_name", "输入分组名称" ), MC.LibraryGetGroupName( groupID ) or "", function( name )
						if MC.LibraryRenameGroup( groupID, name ) then fr:RefreshSaveRows( "", false ) end
					end )
				end )
				menu:AddOption( L( "library.delete_group", "删除分组" ), function()
					Derma_Query( L( "library.delete_group_hint", "分组会被删除，里面的条目会变成未分组。" ), L( "library.delete_group", "删除分组" ), L( "save.delete", "删除" ), function()
						MC.LibraryDeleteGroup( groupID )
						if fr.GroupFilter == groupID then fr.GroupFilter = "*" end
						fr:RefreshSaveRows( "", false )
					end, L( "save.cancel", "取消" ) )
				end )
				menu:Open()
			end
		end
	end

	function fr:RefreshFilters()
		for _, child in ipairs( filterList:GetChildren() ) do child:Remove() end
		local saves = MC.SaveManagerSaves or {}
		if string.StartWith( self.MapFilter or "", "map:" ) then
			local wantedMap, found = string.sub( self.MapFilter, 5 ), false
			for _, save in ipairs( saves ) do if save.map == wantedMap then found = true break end end
			if not found then self.MapFilter = "*" end
		end
		if self.GroupFilter ~= "*" and self.GroupFilter ~= "@none" and not MC.LibraryGetGroupName( self.GroupFilter ) then self.GroupFilter = "*" end
		addFilterHeading( L( "library.maps", "保存地图" ) )
		addFilterButton( L( "library.all", "全部" ), #saves, "*", true )
		local currentCount = 0
		for _, save in ipairs( saves ) do if save.map == game.GetMap() then currentCount = currentCount + 1 end end
		addFilterButton( L( "library.current_map", "当前地图" ), currentCount, "@current", true )
		for _, mapInfo in ipairs( MC.LibraryCollectMaps( saves ) ) do
			addFilterButton( mapInfo.name, mapInfo.count, "map:" .. mapInfo.name, true )
		end

		addFilterHeading( L( "library.groups", "自定义分组" ), true )
		addFilterButton( L( "library.all_groups", "全部分组" ), #saves, "*", false )
		local ungrouped = 0
		local groupCounts = {}
		for _, save in ipairs( saves ) do
			local groupID = MC.LibraryGetItemGroup( "save", save.name )
			if groupID then groupCounts[groupID] = ( groupCounts[groupID] or 0 ) + 1 else ungrouped = ungrouped + 1 end
		end
		addFilterButton( L( "library.group_none", "未分组" ), ungrouped, "@none", false )
		for _, group in ipairs( MC.LibraryGetGroups() ) do
			addFilterButton( group.name, groupCounts[group.id] or 0, group.id, false, group.id )
		end

		local totalH = 0
		for _, child in ipairs( filterList:GetChildren() ) do totalH = totalH + ( child.MCRowHeight or 34 ) + 4 end
		filterList:SetTall( math.max( 1, totalH - 4 ) )
		filterList:InvalidateLayout( true )
	end

	fr.RefreshSaveRows = function( self, message, isError, skipFilters )
		if not IsValid( list ) then return end
		for _, child in ipairs( list:GetChildren() ) do child:Remove() end
		local saves = MC.SaveManagerSaves or {}
		MC.LibrarySortNewestFirst( saves, "savedAtText" )
		if not skipFilters then self:RefreshFilters() end
		local filtered = {}
		for _, save in ipairs( saves ) do
			if MC.LibraryItemMatches( save, "save", self.MapFilter, self.GroupFilter, self.SearchText ) then filtered[#filtered + 1] = save end
		end
		local rowCount = 0
		local selectedName = self.SelectedSave and self.SelectedSave.name
		local nextSelected

		if #filtered == 0 then
			local empty = vgui.Create( "DLabel", list )
			empty.MCRowHeight = 72
			empty:SetText( #saves == 0 and L( "save.empty", "还没有命名存档。输入名字后点“保存当前”。" ) or L( "library.no_results", "没有符合当前筛选的内容。" ) )
			empty:SetTextColor( UI.textDim )
			empty:SetContentAlignment( 5 )
			empty:SetWrap( true )
			rowCount = 1
			self:SelectSave( nil )
		else
			for _, save in ipairs( filtered ) do
				if selectedName and save.name == selectedName then nextSelected = save end
				createSaveRow( list, self, save )
				rowCount = rowCount + 1
			end
			self:SelectSave( nextSelected or filtered[1] )
		end

		local totalH = rowCount > 0 and rowCount * ROW_HEIGHT + math.max( 0, rowCount - 1 ) * ROW_GAP or 0
		if #filtered == 0 then totalH = 72 end
		list:SetTall( totalH )
		list:InvalidateLayout( true )
		local countText = L( "library.showing", "显示 {visible} / {total}", { visible = #filtered, total = #saves } )
		setStatus( self, message ~= "" and message or countText, isError )
	end

	MC.RequestSaveList()
end

net.Receive( "mc_save_list_data", function()
	local message = net.ReadString()
	local isError = net.ReadBool()
	local count = net.ReadUInt( 12 )
	local saves = {}
	for i = 1, count do
		saves[i] = {
			name = net.ReadString(),
			map = net.ReadString(),
			blocks = net.ReadUInt( 32 ),
			chunks = net.ReadUInt( 32 ),
			savedAtText = net.ReadString(),
			cover = net.ReadString(),
		}
	end
	MC.SaveManagerSaves = saves
	MC.LibrarySortNewestFirst( MC.SaveManagerSaves, "savedAtText" )
	if IsValid( MC.SaveManagerFrame ) and MC.SaveManagerFrame.RefreshSaveRows then
		MC.SaveManagerFrame:RefreshSaveRows( message, isError )
	end
end )

net.Receive( "mc_save_cover_ack", function()
	local cover = trim( net.ReadString() )
	local ok = net.ReadBool()
	local err = net.ReadString()
	local pending = PendingCoverUploads[cover]
	if not pending then return end
	PendingCoverUploads[cover] = nil
	timer.Remove( pending.timerName )
	pending.callback( ok, ok and cover or "", err )
end )

net.Receive( "mc_save_cover_download_begin", function()
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

net.Receive( "mc_save_cover_download_part", function()
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
	file.CreateDir( SAVE_COVER_DIR )
	file.Write( cover, data )
	CoverMaterialCache[cover] = nil
	if IsValid( MC.SaveManagerFrame ) and IsValid( MC.SaveManagerFrame.DetailPanel ) then
		MC.SaveManagerFrame.DetailPanel:InvalidateLayout( true )
	end
end )

concommand.Add( "mc_save_manager", function()
	MC.OpenSaveManager()
end )

concommand.Add( "mc_saves_ui", function()
	MC.OpenSaveManager()
end )

if MC.RegisterLanguageChanged then
	MC.RegisterLanguageChanged( "mc_save_ui", function()
		if IsValid( MC.SaveManagerFrame ) then
			MC.SaveManagerFrame:Remove()
			MC.OpenSaveManager()
		end
	end )
end
