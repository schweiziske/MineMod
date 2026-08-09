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

local function saveKey( save )
	return save and trim( save.key ) ~= "" and save.key or save and save.name or ""
end

local function isMountedSave( save )
	return save and save.source == "mounted"
end

local function canUseSaveManager()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return false end
	if ply:IsAdmin() then return true end
	local cv = GetConVar( "mc_save_public" )
	return cv and cv:GetBool() or false
end

local function canManageWorkshop()
	if MC.CanManageWorkshop then return MC.CanManageWorkshop() end
	local ply = LocalPlayer()
	if not IsValid( ply ) then return false end
	local cv = GetConVar( "mc_workshop_manage" )
	local mode = cv and math.Clamp( cv:GetInt(), 0, 2 ) or 0
	if mode <= 0 then return ply:IsSuperAdmin() end
	if mode == 1 then return ply:IsAdmin() end
	return true
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

function MC.SetSaveManagerWorkshopStatus( message, isError, pending )
	local frame = MC.SaveManagerFrame
	if not IsValid( frame ) then return end
	setStatus( frame, message, isError )
	if frame.SetWorkshopPending then frame:SetWorkshopPending( pending == true ) end
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
		local selected = frame.SelectedSave and saveKey( frame.SelectedSave ) == saveKey( save )
		local bg = selected and UI.rowSelected or ( s:IsHovered() and UI.rowHover or UI.row )
		surface.SetDrawColor( bg )
		surface.DrawRect( 0, 0, w, h )
		if selected then
			surface.SetDrawColor( UI.accent )
			surface.DrawRect( 0, 0, 4, h )
		end

		local sameMap = save.map == game.GetMap()
		local workshopId = MC.Workshop and MC.Workshop.NormalizeWorkshopId( save.workshopId ) or nil
		local workshopText = workshopId and ( "Workshop #" .. workshopId )
			or isMountedSave( save ) and L( "workshop.source_mounted_badge", "已挂载" ) or nil
		local titleWidth = w - 28
		if workshopText then
			surface.SetFont( "mc_library_section" )
			local badgeWidth = surface.GetTextSize( workshopText ) + 16
			titleWidth = math.max( 80, titleWidth - badgeWidth - 8 )
			MC.LibraryDrawPill( workshopText, w - badgeWidth - 14, 9, UI.accentSoft, UI.text )
		end
		MC.DrawFittedText( save.name, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, 14, 11, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, titleWidth )
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
	fr.SourceFilter = "*"
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
	fr.SaveCurrentButton = saveNew

	local importWorkshop = vgui.Create( "DButton", header )
	importWorkshop:SetSize( 136, 28 )
	styleButton( importWorkshop, L( "workshop.import", "读取创意工坊" ) )
	importWorkshop:SetEnabled( canManageWorkshop() )
	importWorkshop:SetTooltip( canManageWorkshop()
		and L( "workshop.import_hint", "输入 Workshop ID 或 Steam 创意工坊链接；服务端批准后才会接收并读取世界包。" )
		or L( "workshop.permission_hint", "当前 mc_workshop_manage 不允许你管理创意工坊世界。" ) )
	importWorkshop.DoClick = function()
		if MC.PromptWorkshopImport then MC.PromptWorkshopImport() end
	end
	fr.ImportWorkshopButton = importWorkshop

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

	header.PerformLayout = function( _, w )
		local x, gap = 14, 10
		local statusWidth = math.max( 150, math.floor( w * 0.18 ) )
		local entryWidth = math.max( 210, w - x - 110 - 136 - 76 - statusWidth - gap * 4 - 14 )
		nameEntry:SetPos( x, 32 )
		nameEntry:SetSize( entryWidth, 28 )
		x = x + entryWidth + gap
		saveNew:SetPos( x, 32 )
		saveNew:SetSize( 110, 28 )
		x = x + 110 + gap
		importWorkshop:SetPos( x, 32 )
		x = x + 136 + gap
		refresh:SetPos( x, 32 )
		refresh:SetSize( 76, 28 )
		x = x + 76 + gap
		fr.StatusLabel:SetPos( x, 32 )
		fr.StatusLabel:SetSize( math.max( 80, w - x - 14 ), 28 )
	end

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
	actions:SetTall( 126 )
	actions.Paint = function() end

	fr.DetailPanel = vgui.Create( "DPanel", fr.RightPane )
	fr.DetailPanel:Dock( FILL )
	fr.DetailPanel:DockMargin( 10, 10, 10, 6 )
	fr.DetailPanel.Paint = function( _, w, h )
		local save = fr.SelectedSave
		local infoHeight = save and 246 or 64
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
		local workshopId = MC.Workshop and MC.Workshop.NormalizeWorkshopId( save.workshopId ) or nil
		local sourceText
		if save.source == "mounted" then
			sourceText = L( "workshop.source_mounted", "创意工坊挂载（只读）" )
		elseif save.source == "workshop" then
			sourceText = L( "workshop.source_imported", "创意工坊导入" )
		elseif workshopId then
			sourceText = L( "workshop.source_published", "本地存档（已发布）" )
		else
			sourceText = L( "workshop.source_local", "本地存档" )
		end
		infoLine( 8, infoY + 136, L( "workshop.field_source", "来源" ), sourceText )
		infoLine( 8, infoY + 162, L( "workshop.field_id", "Workshop ID" ), workshopId or L( "save.none", "无" ), workshopId and UI.warm or UI.textDim )
		local groupName = MC.LibraryGetGroupName( MC.LibraryGetItemGroup( "save", save.name ) ) or L( "library.group_none", "未分组" )
		infoLine( 8, infoY + 188, L( "library.group", "分组" ), groupName )
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
			function() sendSaveAction( "load", saveKey( save ), false ) end,
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
		if isMountedSave( save ) then setStatus( fr, L( "save.mounted_read_only", "挂载的创意工坊存档只能读取" ), true ) return end
		Derma_Query(
			L( "save.overwrite_confirm_body", "用当前世界覆盖这个命名存档，并刷新截图？" ),
			L( "save.overwrite_confirm_title", "覆盖存档: {name}", { name = save.name } ),
			L( "save.overwrite", "覆盖" ),
			function() sendSaveAction( "save", save.name, true ) end,
			L( "save.cancel", "取消" )
		)
	end

	local delete
	if LocalPlayer():IsAdmin() then
		delete = vgui.Create( "DButton", actions )
		delete:SetPos( 254, 8 )
		delete:SetSize( 96, 30 )
		styleButton( delete, L( "save.delete", "删除" ), true )
		delete.DoClick = function()
			local save = fr.SelectedSave
			if not save then setStatus( fr, L( "save.select_first", "先选择一个存档" ), true ) return end
			if isMountedSave( save ) then setStatus( fr, L( "save.mounted_read_only", "挂载的创意工坊存档只能读取" ), true ) return end
			Derma_Query(
				L( "save.delete_confirm_body", "删除后不会自动恢复。" ),
				L( "save.delete_confirm_title", "删除存档: {name}", { name = save.name } ),
				L( "save.delete", "删除" ),
				function() sendSaveAction( "delete", save.name, false ) end,
				L( "save.cancel", "取消" )
			)
		end
	end

	local publishWorkshop = vgui.Create( "DButton", actions )
	styleButton( publishWorkshop, L( "workshop.publish", "发布到创意工坊" ) )
	publishWorkshop:SetTooltip( canManageWorkshop()
		and L( "workshop.publish_hint", "服务端导出存档后，客户端截图并打开 GMod 发布窗口。" )
		or L( "workshop.permission_hint", "当前 mc_workshop_manage 不允许你管理创意工坊世界。" ) )
	publishWorkshop.DoClick = function()
		local save = fr.SelectedSave
		if not save then setStatus( fr, L( "save.select_first", "先选择一个存档" ), true ) return end
		if isMountedSave( save ) then setStatus( fr, L( "save.mounted_read_only", "挂载的创意工坊存档只能读取" ), true ) return end
		Derma_Query(
			L( "workshop.publish_confirm_body", "客户端将向服务端请求这个存档，隐藏界面拍摄封面，然后打开 Garry's Mod 创意工坊发布窗口。是否继续？" ),
			L( "workshop.publish_confirm_title", "发布到创意工坊: {name}", { name = save.name } ),
			L( "workshop.publish", "发布到创意工坊" ),
			function()
				if MC.PublishSaveToWorkshop then MC.PublishSaveToWorkshop( save ) end
			end,
			L( "save.cancel", "取消" )
		)
	end

	local viewWorkshop = vgui.Create( "DButton", actions )
	MC.LibraryStyleButton( viewWorkshop, L( "workshop.view", "查看创意工坊" ), "quiet", UI )
	viewWorkshop.DoClick = function()
		local save = fr.SelectedSave
		if save and MC.ViewWorkshopFile then MC.ViewWorkshopFile( save.workshopId ) end
	end
	fr.PublishWorkshopButton = publishWorkshop
	fr.ViewWorkshopButton = viewWorkshop
	fr.LoadSaveButton = load
	fr.OverwriteSaveButton = overwrite
	fr.DeleteSaveButton = delete

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
		load:SetPos( 0, 6 )
		load:SetSize( 88, 30 )
		overwrite:SetPos( 96, 6 )
		overwrite:SetSize( 134, 30 )
		if IsValid( delete ) then
			delete:SetPos( 238, 6 )
			delete:SetSize( math.max( 72, math.min( 92, w - 238 ) ), 30 )
		end
		publishWorkshop:SetPos( 0, 46 )
		publishWorkshop:SetSize( math.min( 166, math.max( 132, w * 0.54 ) ), 30 )
		viewWorkshop:SetPos( publishWorkshop:GetWide() + 8, 46 )
		viewWorkshop:SetSize( math.max( 112, w - publishWorkshop:GetWide() - 8 ), 30 )
		groupLabel:SetPos( 0, 88 )
		groupLabel:SetSize( 54, 30 )
		groupCombo:SetPos( 62, 88 )
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

	function fr:RefreshWorkshopActions()
		local save = self.SelectedSave
		local busy = self.WorkshopPending == true or ( MC.WorkshopBusy and MC.WorkshopBusy() )
		local workshopAllowed = canManageWorkshop()
		local mounted = isMountedSave( save )
		local workshopId = save and MC.Workshop and MC.Workshop.NormalizeWorkshopId( save.workshopId ) or nil
		if IsValid( load ) then load:SetEnabled( canManage and save ~= nil and not busy ) end
		if IsValid( overwrite ) then overwrite:SetEnabled( canManage and save ~= nil and not mounted and not busy ) end
		if IsValid( delete ) then delete:SetEnabled( save ~= nil and not mounted and not busy ) end
		if IsValid( publishWorkshop ) then publishWorkshop:SetEnabled( workshopAllowed and save ~= nil and not mounted and not busy ) end
		if IsValid( viewWorkshop ) then
			viewWorkshop:SetVisible( workshopId ~= nil )
			viewWorkshop:SetEnabled( workshopId ~= nil and not busy )
		end
		if IsValid( groupCombo ) then groupCombo:SetEnabled( save ~= nil and not busy ) end
		if IsValid( importWorkshop ) then importWorkshop:SetEnabled( workshopAllowed and not busy ) end
		if IsValid( saveNew ) then saveNew:SetEnabled( canManage and not busy ) end
	end

	function fr:SetWorkshopPending( pending )
		self.WorkshopPending = pending == true
		self:RefreshWorkshopActions()
	end

	function fr:SelectSave( save )
		self.SelectedSave = save
		if save and IsValid( self.NameEntry ) then self.NameEntry:SetValue( save.name or "" ) end
		if IsValid( self.SaveListPanel ) then self.SaveListPanel:InvalidateLayout( true ) end
		if IsValid( self.DetailPanel ) then self.DetailPanel:InvalidateLayout( true ) end
		self:RefreshGroupCombo()
		self:RefreshWorkshopActions()
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

	local function addFilterButton( label, count, value, kind, groupID )
		local btn = vgui.Create( "DButton", filterList )
		btn:SetText( "" )
		btn:SetCursor( "hand" )
		btn.MCRowHeight = 34
		btn.Paint = function( s, w, h )
			local selected = kind == "map" and fr.MapFilter == value
				or kind == "source" and fr.SourceFilter == value
				or kind == "group" and fr.GroupFilter == value
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
			if kind == "map" then fr.MapFilter = value
			elseif kind == "source" then fr.SourceFilter = value
			else fr.GroupFilter = value end
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
		if self.SourceFilter ~= "*" and self.SourceFilter ~= "@local" and self.SourceFilter ~= "@workshop" then self.SourceFilter = "*" end
		local workshopCount = 0
		for _, save in ipairs( saves ) do
			if save.source == "workshop" or save.source == "mounted"
				or MC.Workshop and MC.Workshop.NormalizeWorkshopId( save.workshopId ) then
				workshopCount = workshopCount + 1
			end
		end
		addFilterHeading( L( "workshop.filter_source", "来源" ) )
		addFilterButton( L( "library.all", "全部" ), #saves, "*", "source" )
		addFilterButton( L( "workshop.filter_local", "本地存档" ), #saves - workshopCount, "@local", "source" )
		addFilterButton( L( "workshop.filter_workshop", "创意工坊" ), workshopCount, "@workshop", "source" )

		addFilterHeading( L( "library.maps", "保存地图" ) )
		addFilterButton( L( "library.all", "全部" ), #saves, "*", "map" )
		local currentCount = 0
		for _, save in ipairs( saves ) do if save.map == game.GetMap() then currentCount = currentCount + 1 end end
		addFilterButton( L( "library.current_map", "当前地图" ), currentCount, "@current", "map" )
		for _, mapInfo in ipairs( MC.LibraryCollectMaps( saves ) ) do
			addFilterButton( mapInfo.name, mapInfo.count, "map:" .. mapInfo.name, "map" )
		end

		addFilterHeading( L( "library.groups", "自定义分组" ), true )
		addFilterButton( L( "library.all_groups", "全部分组" ), #saves, "*", "group" )
		local ungrouped = 0
		local groupCounts = {}
		for _, save in ipairs( saves ) do
			local groupID = MC.LibraryGetItemGroup( "save", save.name )
			if groupID then groupCounts[groupID] = ( groupCounts[groupID] or 0 ) + 1 else ungrouped = ungrouped + 1 end
		end
		addFilterButton( L( "library.group_none", "未分组" ), ungrouped, "@none", "group" )
		for _, group in ipairs( MC.LibraryGetGroups() ) do
			addFilterButton( group.name, groupCounts[group.id] or 0, group.id, "group", group.id )
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
		if MC.SaveManagerPendingSelection then
			self.SourceFilter = "*"
			self.MapFilter = "*"
			self.GroupFilter = "*"
			skipFilters = false
		end
		if not skipFilters then self:RefreshFilters() end
		local filtered = {}
		for _, save in ipairs( saves ) do
			local workshopLinked = save.source == "workshop" or save.source == "mounted"
				or MC.Workshop and MC.Workshop.NormalizeWorkshopId( save.workshopId ) ~= nil
			local sourceMatches = self.SourceFilter == "*"
				or self.SourceFilter == "@workshop" and workshopLinked
				or self.SourceFilter == "@local" and not workshopLinked
			if sourceMatches and MC.LibraryItemMatches( save, "save", self.MapFilter, self.GroupFilter, self.SearchText ) then
				filtered[#filtered + 1] = save
			end
		end
		local rowCount = 0
		local selectedName = MC.SaveManagerPendingSelection or self.SelectedSave and saveKey( self.SelectedSave )
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
				if selectedName and saveKey( save ) == selectedName then nextSelected = save end
				createSaveRow( list, self, save )
				rowCount = rowCount + 1
			end
			self:SelectSave( nextSelected or filtered[1] )
			if nextSelected and MC.SaveManagerPendingSelection == saveKey( nextSelected ) then MC.SaveManagerPendingSelection = nil end
		end

		local totalH = rowCount > 0 and rowCount * ROW_HEIGHT + math.max( 0, rowCount - 1 ) * ROW_GAP or 0
		if #filtered == 0 then totalH = 72 end
		list:SetTall( totalH )
		list:InvalidateLayout( true )
		local countText = L( "library.showing", "显示 {visible} / {total}", { visible = #filtered, total = #saves } )
		local workshopStatus = MC.Workshop and MC.Workshop.Client and MC.Workshop.Client.status or nil
		if self.WorkshopPending and workshopStatus and workshopStatus.pending then
			setStatus( self, workshopStatus.message, workshopStatus.isError )
		else
			setStatus( self, message ~= "" and message or countText, isError )
		end
	end

	fr:RefreshWorkshopActions()
	local workshopStatus = MC.Workshop and MC.Workshop.Client and MC.Workshop.Client.status or nil
	if workshopStatus then MC.SetSaveManagerWorkshopStatus( workshopStatus.message, workshopStatus.isError, workshopStatus.pending ) end
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
			key = net.ReadString(),
			map = net.ReadString(),
			blocks = net.ReadUInt( 32 ),
			chunks = net.ReadUInt( 32 ),
			savedAtText = net.ReadString(),
			cover = net.ReadString(),
			source = net.ReadString(),
			workshopId = net.ReadString(),
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
