--[[----------------------------------------------------------------------------
	MC : client save manager UI.
------------------------------------------------------------------------------]]

MC = MC or {}

local SAVE_COVER_DIR = "mc/save_covers"
local SAVE_COVER_PART_BYTES = 60000

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
	danger = Color( 122, 58, 58, 245 ),
	dangerHover = Color( 156, 70, 70, 245 ),
	accent = Color( 236, 230, 190, 245 ),
	text = Color( 235, 240, 248, 245 ),
	textDim = Color( 165, 174, 188, 220 ),
	error = Color( 240, 110, 110, 245 ),
}

local CoverMaterialCache = {}
local PendingCoverDownloads = {}
local CoverDownloadBuffers = {}

local function trim( value )
	return string.Trim( tostring( value or "" ) )
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
	btn:SetText( "" )
	btn.Paint = function( s, w, h )
		local bg = danger and UI.danger or UI.control
		if s:IsDown() then
			bg = UI.controlDown
		elseif s:IsHovered() then
			bg = danger and UI.dangerHover or UI.controlHover
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

local function captureSaveCover( slotName, callback )
	callback = callback or function() end
	local coverPath = saveCoverPath( slotName )
	if not coverPath then callback( "", nil ) return end
	file.CreateDir( "mc" )
	file.CreateDir( SAVE_COVER_DIR )

	local hookName = "MC_SaveCoverCapture_" .. util.CRC( coverPath .. tostring( SysTime() ) )
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
		deleteLocalSaveCovers( slotName, coverPath )
		callback( coverPath, data )
	end )
end

local function uploadSaveCover( slotName, coverPath, data, callback )
	callback = callback or function() end
	if not coverPath or coverPath == "" or not data or data == "" then callback() return end

	local totalBytes = #data
	local parts = math.ceil( totalBytes / SAVE_COVER_PART_BYTES )
	if parts < 1 then callback() return end

	net.Start( "mc_save_cover_begin" )
		net.WriteString( slotName )
		net.WriteString( coverPath )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( totalBytes, 32 )
	net.SendToServer()

	local i = 1
	local function sendNextPart()
		if i > parts then callback() return end

		local first = ( i - 1 ) * SAVE_COVER_PART_BYTES + 1
		local chunk = string.sub( data, first, first + SAVE_COVER_PART_BYTES - 1 )
		net.Start( "mc_save_cover_part" )
			net.WriteString( coverPath )
			net.WriteUInt( i, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.SendToServer()

		i = i + 1
		timer.Simple( 0, sendNextPart )
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
	draw.RoundedBox( 4, x, y, w, h, Color( 10, 12, 15, 245 ) )
	surface.SetDrawColor( 88, 96, 110, 130 )
	surface.DrawOutlinedRect( x, y, w, h, 1 )

	local mat = coverMaterialForSave( save )
	if mat then
		surface.SetDrawColor( 255, 255, 255, 255 )
		surface.SetMaterial( mat )
		surface.DrawTexturedRect( x + 4, y + 4, w - 8, h - 8 )
		return
	end

	draw.SimpleText( "暂无截图", "mc_hud", x + w * 0.5, y + h * 0.5 - 10, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	draw.SimpleText( "保存一次会自动截图", "mc_hud_small", x + w * 0.5, y + h * 0.5 + 16, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
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
	slotName = trim( slotName )
	if slotName == "" then
		setStatus( MC.SaveManagerFrame, "请输入存档名", true )
		return
	end

	if action == "save" and captureCover ~= false then
		local frame = MC.SaveManagerFrame
		if IsValid( frame ) then frame:SetVisible( false ) end
		captureSaveCover( slotName, function( coverPath, data )
			if IsValid( frame ) then
				frame:SetVisible( true )
				frame:MakePopup()
				setStatus( frame, "正在上传截图和保存存档..." )
			end

			uploadSaveCover( slotName, coverPath, data, function()
				sendSaveActionNow( action, slotName, coverPath )
			end )
		end )
		return
	end

	sendSaveActionNow( action, slotName, "" )
end

local ROW_HEIGHT = 70
local ROW_GAP = 6

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
		draw.RoundedBox( 4, 0, 0, w, h, bg )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		surface.SetDrawColor( selected and UI.accent or Color( 88, 96, 110, 140 ) )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )

		local sameMap = save.map == game.GetMap()
		local mapColor = sameMap and UI.textDim or UI.error
		MC.DrawFittedText( save.name, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, 12, 10, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, w - 24 )
		MC.DrawFittedText( "地图: " .. tostring( save.map ), "mc_hud_small", { "mc_hud_fit_16" }, 12, 36, mapColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, w - 24 )
		draw.SimpleText( tostring( save.savedAtText ), "mc_hud_small", 12, 52, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end
end

function MC.OpenSaveManager()
	if IsValid( MC.SaveManagerFrame ) then MC.SaveManagerFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "MC 存档管理" )
	local frameH = math.Clamp( ScrH() - 80, 680, 760 )
	fr:SetSize( 1040, frameH )
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
	MC.SaveManagerFrame = fr

	local header = vgui.Create( "DPanel", fr )
	header:Dock( TOP )
	header:DockMargin( 8, 8, 8, 6 )
	header:SetTall( 78 )
	header.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		draw.SimpleText( "当前地图: " .. game.GetMap(), "mc_hud_small", 12, 12, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	local nameEntry = vgui.Create( "DTextEntry", header )
	nameEntry:SetPos( 12, 38 )
	nameEntry:SetSize( 520, 28 )
	nameEntry:SetPlaceholderText( "新存档名" )
	nameEntry:SetPaintBackground( false )
	nameEntry:SetTextColor( UI.text )
	if nameEntry.SetCursorColor then nameEntry:SetCursorColor( UI.accent ) end
	nameEntry.Paint = function( s, w, h )
		draw.RoundedBox( 3, 0, 0, w, h, Color( 16, 18, 22, 245 ) )
		surface.SetDrawColor( 88, 96, 110, s:HasFocus() and 190 or 110 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			draw.SimpleText( "新存档名", "mc_hud_small", 8, h * 0.5, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end
		s:DrawTextEntryText( UI.text, Color( 95, 145, 210 ), UI.text )
	end
	fr.NameEntry = nameEntry

	local saveNew = vgui.Create( "DButton", header )
	saveNew:SetPos( 544, 38 )
	saveNew:SetSize( 110, 28 )
	styleButton( saveNew, "保存当前" )
	saveNew.DoClick = function()
		sendSaveAction( "save", nameEntry:GetValue(), true )
	end

	local refresh = vgui.Create( "DButton", header )
	refresh:SetPos( 664, 38 )
	refresh:SetSize( 76, 28 )
	styleButton( refresh, "刷新" )
	refresh.DoClick = function()
		MC.RequestSaveList()
	end

	fr.StatusLabel = vgui.Create( "DLabel", header )
	fr.StatusLabel:SetPos( 752, 38 )
	fr.StatusLabel:SetSize( 260, 28 )
	fr.StatusLabel:SetTextColor( UI.textDim )
	fr.StatusLabel:SetText( "读取中..." )

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body:DockMargin( 8, 0, 8, 8 )
	body.Paint = function() end

	fr.LeftPane = vgui.Create( "DPanel", body )
	fr.LeftPane:Dock( LEFT )
	fr.LeftPane:SetWide( 330 )
	fr.LeftPane:DockMargin( 0, 0, 8, 0 )
	fr.LeftPane.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		draw.SimpleText( "选择地图 / 存档", "mc_hud", 12, 12, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
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
	fr.SaveListPanel = list

	local actions = vgui.Create( "DPanel", fr.RightPane )
	actions:Dock( BOTTOM )
	actions:DockMargin( 10, 0, 10, 10 )
	actions:SetTall( 42 )
	actions.Paint = function() end

	fr.DetailPanel = vgui.Create( "DPanel", fr.RightPane )
	fr.DetailPanel:Dock( FILL )
	fr.DetailPanel:DockMargin( 10, 10, 10, 6 )
	fr.DetailPanel.Paint = function( _, w, h )
		local save = fr.SelectedSave
		local infoHeight = save and 168 or 64
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
		draw.SimpleText( "地图信息", "mc_hud", 8, infoY, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		if not save then
			draw.SimpleText( "左侧选择一个存档。", "mc_hud_small", 8, infoY + 32, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
			return
		end

		local sameMap = save.map == game.GetMap()
		infoLine( 8, infoY + 32, "存档", save.name )
		infoLine( 8, infoY + 58, "地图", save.map, sameMap and UI.text or UI.error )
		infoLine( 8, infoY + 84, "保存", save.savedAtText )
		infoLine( 8, infoY + 110, "规模", string.format( "%d blocks / %d chunks", save.blocks or 0, save.chunks or 0 ) )
		infoLine( 8, infoY + 136, "截图", trim( save.cover ) ~= "" and save.cover or "无" )
	end

	local load = vgui.Create( "DButton", actions )
	load:SetPos( 0, 6 )
	load:SetSize( 96, 30 )
	styleButton( load, "读取" )
	load.DoClick = function()
		local save = fr.SelectedSave
		if not save then setStatus( fr, "先选择一个存档", true ) return end
		Derma_Query(
			"读取存档会替换当前 MC 方块世界，并重新同步所有客户端。",
			"读取存档: " .. save.name,
			"读取",
			function() sendSaveAction( "load", save.name, false ) end,
			"取消"
		)
	end

	local overwrite = vgui.Create( "DButton", actions )
	overwrite:SetPos( 104, 6 )
	overwrite:SetSize( 112, 30 )
	styleButton( overwrite, "覆盖并截图" )
	overwrite.DoClick = function()
		local save = fr.SelectedSave
		if not save then setStatus( fr, "先选择一个存档", true ) return end
		Derma_Query(
			"用当前世界覆盖这个命名存档，并刷新截图？",
			"覆盖存档: " .. save.name,
			"覆盖",
			function() sendSaveAction( "save", save.name, true ) end,
			"取消"
		)
	end

	if LocalPlayer():IsAdmin() then
		local delete = vgui.Create( "DButton", actions )
		delete:SetPos( 224, 6 )
		delete:SetSize( 96, 30 )
		styleButton( delete, "删除", true )
		delete.DoClick = function()
			local save = fr.SelectedSave
			if not save then setStatus( fr, "先选择一个存档", true ) return end
			Derma_Query(
				"删除后不会自动恢复。",
				"删除存档: " .. save.name,
				"删除",
				function() sendSaveAction( "delete", save.name, false ) end,
				"取消"
			)
		end
	end

	function fr:SelectSave( save )
		self.SelectedSave = save
		if save and IsValid( self.NameEntry ) then self.NameEntry:SetValue( save.name or "" ) end
		if IsValid( self.SaveListPanel ) then self.SaveListPanel:InvalidateLayout( true ) end
		if IsValid( self.DetailPanel ) then self.DetailPanel:InvalidateLayout( true ) end
	end

	fr.RefreshSaveRows = function( self, message, isError )
		if not IsValid( list ) then return end
		for _, child in ipairs( list:GetChildren() ) do child:Remove() end
		local saves = MC.SaveManagerSaves or {}
		local rowCount = 0
		local selectedName = self.SelectedSave and self.SelectedSave.name
		local nextSelected

		if #saves == 0 then
			local empty = vgui.Create( "DLabel", list )
			empty.MCRowHeight = 52
			empty:SetText( "还没有命名存档。输入名字后点“保存当前”。" )
			empty:SetTextColor( UI.textDim )
			empty:SetContentAlignment( 5 )
			rowCount = 1
			self:SelectSave( nil )
		else
			for _, save in ipairs( saves ) do
				if selectedName and save.name == selectedName then nextSelected = save end
				createSaveRow( list, self, save )
				rowCount = rowCount + 1
			end
			self:SelectSave( nextSelected or saves[1] )
		end

		local totalH = rowCount > 0 and rowCount * ROW_HEIGHT + math.max( 0, rowCount - 1 ) * ROW_GAP or 0
		if #saves == 0 then totalH = 52 end
		list:SetTall( totalH )
		list:InvalidateLayout( true )
		setStatus( self, message ~= "" and message or ( #saves .. " 个存档" ), isError )
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
	if IsValid( MC.SaveManagerFrame ) and MC.SaveManagerFrame.RefreshSaveRows then
		MC.SaveManagerFrame:RefreshSaveRows( message, isError )
	end
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
