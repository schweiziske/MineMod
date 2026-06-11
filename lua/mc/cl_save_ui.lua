--[[----------------------------------------------------------------------------
	MC : client save manager UI.
------------------------------------------------------------------------------]]

MC = MC or {}

local UI = {
	frame = Color( 30, 32, 37, 250 ),
	title = Color( 18, 20, 24, 255 ),
	panel = Color( 24, 26, 30, 245 ),
	panelInner = Color( 13, 15, 18, 230 ),
	row = Color( 42, 45, 51, 245 ),
	rowHover = Color( 56, 64, 78, 245 ),
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

local function trim( value )
	return string.Trim( tostring( value or "" ) )
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

function MC.RequestSaveList()
	net.Start( "mc_save_list_req" )
	net.SendToServer()
end

local function sendSaveAction( action, slotName )
	slotName = trim( slotName )
	if slotName == "" then
		setStatus( MC.SaveManagerFrame, "请输入存档名", true )
		return
	end
	net.Start( "mc_save_action" )
		net.WriteString( action )
		net.WriteString( slotName )
	net.SendToServer()
end

local ROW_HEIGHT = 76
local ROW_GAP = 8

local function createSaveRow( parent, frame, save )
	local row = vgui.Create( "DPanel", parent )
	row.MCRowHeight = ROW_HEIGHT
	row.Paint = function( s, w, h )
		local bg = s:IsHovered() and UI.rowHover or UI.row
		draw.RoundedBox( 4, 0, 0, w, h, bg )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		surface.SetDrawColor( 88, 96, 110, 140 )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )

		local currentMap = game.GetMap()
		local sameMap = save.map == currentMap
		local mapColor = sameMap and UI.textDim or UI.error
		MC.DrawFittedText( save.name, "mc_hud", { "mc_hud_small", "mc_hud_fit_16" }, 12, 12, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 200 )
		MC.DrawFittedText( "地图: " .. tostring( save.map ), "mc_hud_small", { "mc_hud_fit_16" }, 12, 39, mapColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 195 )
		draw.SimpleText( "保存: " .. tostring( save.savedAtText ), "mc_hud_small", 220, 39, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		MC.DrawFittedText( string.format( "%d blocks / %d chunks", save.blocks or 0, save.chunks or 0 ), "mc_hud_small", { "mc_hud_fit_16" }, 465, 39, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 150 )
		if not sameMap then
			draw.SimpleText( "非当前地图", "mc_hud_small", 220, 15, UI.error, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
		end
	end

	local load = vgui.Create( "DButton", row )
	load:SetSize( 64, 28 )
	load:SetPos( 626, 24 )
	styleButton( load, "读取" )
	load.DoClick = function()
		Derma_Query(
			"读取存档会替换当前 MC 方块世界，并重新同步所有客户端。",
			"读取存档: " .. save.name,
			"读取",
			function() sendSaveAction( "load", save.name ) end,
			"取消"
		)
	end

	local overwrite = vgui.Create( "DButton", row )
	overwrite:SetSize( 64, 28 )
	overwrite:SetPos( 698, 24 )
	styleButton( overwrite, "覆盖" )
	overwrite.DoClick = function()
		Derma_Query(
			"用当前世界覆盖这个命名存档？",
			"覆盖存档: " .. save.name,
			"覆盖",
			function() sendSaveAction( "save", save.name ) end,
			"取消"
		)
	end

	if LocalPlayer():IsAdmin() then
		local delete = vgui.Create( "DButton", row )
		delete:SetSize( 64, 28 )
		delete:SetPos( 770, 24 )
		styleButton( delete, "删除", true )
		delete.DoClick = function()
			Derma_Query(
				"删除后不会自动恢复。",
				"删除存档: " .. save.name,
				"删除",
				function() sendSaveAction( "delete", save.name ) end,
				"取消"
			)
		end
	end
end

function MC.OpenSaveManager()
	if IsValid( MC.SaveManagerFrame ) then MC.SaveManagerFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "MC 存档管理" )
	fr:SetSize( 880, 560 )
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
	header:SetTall( 72 )
	header.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
		draw.SimpleText( "当前地图: " .. game.GetMap(), "mc_hud_small", 12, 12, UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP )
	end

	local nameEntry = vgui.Create( "DTextEntry", header )
	nameEntry:SetPos( 12, 34 )
	nameEntry:SetSize( 520, 28 )
	nameEntry:SetPlaceholderText( "新存档名" )
	nameEntry:SetDrawBackground( false )
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

	local saveNew = vgui.Create( "DButton", header )
	saveNew:SetPos( 544, 34 )
	saveNew:SetSize( 96, 28 )
	styleButton( saveNew, "保存当前" )
	saveNew.DoClick = function()
		sendSaveAction( "save", nameEntry:GetValue() )
	end

	local refresh = vgui.Create( "DButton", header )
	refresh:SetPos( 648, 34 )
	refresh:SetSize( 72, 28 )
	styleButton( refresh, "刷新" )
	refresh.DoClick = function()
		MC.RequestSaveList()
	end

	fr.StatusLabel = vgui.Create( "DLabel", header )
	fr.StatusLabel:SetPos( 732, 34 )
	fr.StatusLabel:SetSize( 120, 28 )
	fr.StatusLabel:SetTextColor( UI.textDim )
	fr.StatusLabel:SetText( "读取中..." )

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body:DockMargin( 8, 0, 8, 8 )
	body.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		draw.RoundedBox( 3, 4, 4, w - 8, h - 8, UI.panelInner )
	end

	local scroll = vgui.Create( "DScrollPanel", body )
	scroll:Dock( FILL )
	scroll:DockMargin( 8, 8, 8, 8 )
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

	fr.RefreshSaveRows = function( _, message, isError )
		if not IsValid( list ) then return end
		for _, child in ipairs( list:GetChildren() ) do child:Remove() end
		local saves = MC.SaveManagerSaves or {}
		local rowCount = 0
		if #saves == 0 then
			local empty = vgui.Create( "DLabel", list )
			empty.MCRowHeight = 52
			empty:SetText( "还没有命名存档。输入名字后点“保存当前”。" )
			empty:SetTextColor( UI.textDim )
			empty:SetContentAlignment( 5 )
			rowCount = 1
		else
			for _, save in ipairs( saves ) do
				createSaveRow( list, fr, save )
				rowCount = rowCount + 1
			end
		end
		local totalH = rowCount > 0 and rowCount * ROW_HEIGHT + math.max( 0, rowCount - 1 ) * ROW_GAP or 0
		if #saves == 0 then totalH = 52 end
		list:SetTall( totalH )
		list:InvalidateLayout( true )
		setStatus( fr, message ~= "" and message or ( #saves .. " 个存档" ), isError )
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
		}
	end
	MC.SaveManagerSaves = saves
	if IsValid( MC.SaveManagerFrame ) and MC.SaveManagerFrame.RefreshSaveRows then
		MC.SaveManagerFrame:RefreshSaveRows( message, isError )
	end
end )

concommand.Add( "mc_save_manager", function()
	MC.OpenSaveManager()
end )

concommand.Add( "mc_saves_ui", function()
	MC.OpenSaveManager()
end )
