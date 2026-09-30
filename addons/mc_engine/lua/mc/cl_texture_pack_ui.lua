-- A deliberately small Minecraft-style picker for registered, pre-baked packs.
-- Resource-stack ordering and in-game atlas compilation are not exposed here.
local M = MC.TexturePackManager
local text = M.Text
local Font = MC.BitmapFont
local C = {
	background = Color( 41, 41, 41 ), list = Color( 23, 23, 23 ), hover = Color( 38, 38, 38 ),
	text = Color( 240, 240, 240 ), dim = Color( 164, 164, 164 ), line = Color( 69, 69, 69 ),
	button = Color( 105, 105, 105 ), light = Color( 155, 155, 155 ), dark = Color( 51, 51, 51 ),
	warning = Color( 226, 189, 112 ), disabled = Color( 95, 95, 95 ), white = Color( 255, 255, 255 ),
}
local previews = {}
local SEARCH_TIMER = "mc_texture_pack_manager_search"
local PAGE_SIZE = 32
local EVENTS = { "MC.TexturePackChanged", "MC.TexturePackRegistered", "MC.TexturePackUnregistered",
	"MC.TexturePackOwnerUnregistered", "MC.TexturePackLeaseChanged" }

surface.CreateFont( "mc_texture_pack_input", { font = "Tahoma", size = 18, weight = 400, extended = true } )

local function rectangle( color, x, y, w, h )
	surface.SetDrawColor( color )
	surface.DrawRect( x, y, w, h )
end

-- Trim only at the bitmap font's UTF-8 boundaries, and cache outside Paint.
local function fit( value, width, scale )
	return Font.TrimToWidth( value, math.max( 0, width ) / scale )
end

local function label( parent, value, color, scale, lines, centered )
	local panel = vgui.Create( "DPanel", parent )
	panel.Caption, panel.Lines = value or "", {}
	panel.Options = { color = color or C.text, scale = scale or 2, shadow = false }
	panel:SetMouseInputEnabled( false )
	function panel:SetCaption( caption )
		caption = tostring( caption or "" )
		if self.Caption == caption then return end
		self.Caption = caption
		self:InvalidateLayout( true )
	end
	function panel:PerformLayout( w )
		local remaining = self.Caption
		self.Lines = {}
		for index = 1, lines or 1 do
			if remaining == "" then break end
			local newline = remaining:find( "\n", 1, true )
			local line = newline and remaining:sub( 1, newline - 1 ) or remaining
			local part = fit( line, w, self.Options.scale )
			if part == "" and line ~= "" then break end
			remaining = remaining:sub( #part + 1 )
			if remaining:sub( 1, 1 ) == "\n" then remaining = remaining:sub( 2 ) end
			if index == ( lines or 1 ) and remaining ~= "" then
				part = fit( part, w - Font.Measure( "..." ) * self.Options.scale, self.Options.scale ) .. "..."
			end
			self.Lines[#self.Lines + 1] = { text = part,
				x = centered and math.floor( ( w - Font.Measure( part ) * self.Options.scale ) / 2 ) or 0 }
		end
	end
	panel.Paint = function( s )
		for index, line in ipairs( s.Lines ) do
			Font.Draw( line.text, line.x, ( index - 1 ) * 20, s.Options )
		end
	end
	return panel
end

local function button( parent, caption, callback, plain )
	local b = vgui.Create( "DButton", parent )
	b:SetText( "" )
	b.Caption, b.Options = caption, { scale = 2, color = C.text, shadow = false }
	b:SetTooltip( caption )
	b.PerformLayout = function( s, w )
		s.Fitted = fit( s.Caption, w - 10, 2 )
		s.TextX = math.floor( ( w - Font.Measure( s.Fitted ) * 2 ) / 2 )
	end
	b.Paint = function( s, w, h )
		local enabled = s:IsEnabled()
		local focus = enabled and ( s:IsHovered() or s:HasFocus() )
		if not plain then
			rectangle( C.dark, 0, 0, w, h )
			rectangle( C.button, 2, 2, w - 4, h - 4 )
			rectangle( s:IsDown() and C.dark or C.light, 2, 2, w - 4, 2 )
		end
		if focus then
			surface.SetDrawColor( C.text )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end
		s.Options.color = enabled and C.text or C.disabled
		Font.Draw( s.Fitted or "", s.TextX or 0, math.floor( ( h - 18 ) / 2 ), s.Options )
	end
	b.DoClick = callback
	return b
end

local function preview( path )
	path = path or "mc/resourcepacks/unknown"
	if previews[path] then return previews[path] end
	local material = Material( path .. ".png", "vertexcolor vertexalpha nocull" )
	if material:IsError() and path ~= "mc/resourcepacks/unknown" then
		MC.Fault( "texture_pack_preview", "Could not load pack preview %s", path )
		material = preview( "mc/resourcepacks/unknown" )
	end
	previews[path] = material
	return material
end

local ROW = {}
function ROW:Init()
	self:SetTall( 90 )
	self:DockPadding( 8, 8, 8, 8 )
	self.Transfer = button( self, ">", function() self.Manager:Choose( self.Entry.name ) end, true )
	self.Transfer:Dock( RIGHT )
	self.Transfer:SetWide( 36 )
	self.Pick = vgui.Create( "DButton", self )
	self.Pick:Dock( FILL )
	self.Pick:SetText( "" )
	self.Pick.DoClick = function()
		self.Manager.Session.focus = self.Entry.name
		self.Manager:UpdateState()
	end
	self.TitleOptions = { scale = 2, color = C.text, shadow = false }
	self.DescriptionOptions = { scale = 2, color = C.dim, shadow = false }
	self.Pick.PerformLayout = function( _, w )
		self.FittedTitle = fit( self.Entry.title, w - 72, 2 )
		self.FittedDescription = fit( self.Summary, w - 72, 2 )
	end
	self.Pick.Paint = function( s, w, h )
		render.PushFilterMin( TEXFILTER.POINT )
		render.PushFilterMag( TEXFILTER.POINT )
		surface.SetMaterial( self.Preview )
		surface.SetDrawColor( C.white )
		surface.DrawTexturedRect( 0, math.floor( ( h - 60 ) / 2 ), 60, 60 )
		render.PopFilterMag()
		render.PopFilterMin()
		Font.Draw( self.FittedTitle or "", 72, 12, self.TitleOptions )
		Font.Draw( self.FittedDescription or "", 72, 39, self.DescriptionOptions )
	end
end

function ROW:SetEntry( manager, entry, selected )
	self.Manager, self.Entry = manager, entry
	self.Preview = preview( entry.preview )
	self.Summary = entry.description
	if not entry.available then self.Summary = text( "Texture files missing", "贴图文件缺失" ) end
	self.DescriptionOptions.color = entry.available and C.dim or C.warning
	self.Pick:SetTooltip( entry.title .. "\n" .. self.Summary )
	self.Transfer:SetVisible( not selected )
	self.Transfer:SetEnabled( entry.available == true )
	self.Transfer:SetTooltip( text( "Select ", "选择 " ) .. entry.title )
	self:InvalidateLayout( true )
	self.Pick:InvalidateLayout( true )
end

function ROW:Paint( w, h )
	if self.Pick:IsHovered() then rectangle( C.hover, 0, 0, w, h ) end
	if self.Manager.Session.focus == self.Entry.name or self.Pick:HasFocus() then
		surface.SetDrawColor( C.text )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	end
end
vgui.Register( "MCTexturePackRow", ROW, "DPanel" )

local function lane( parent, title )
	local p = vgui.Create( "DPanel", parent )
	p.Paint = function() end
	p.Title = label( p, title )
	p.Title:Dock( TOP )
	p.Title:SetTall( 30 )
	p.Tools = vgui.Create( "DPanel", p )
	p.Tools:Dock( BOTTOM )
	p.Tools:SetTall( 36 )
	p.Tools.Paint = function() end
	p.Scroll = vgui.Create( "DScrollPanel", p )
	p.Scroll:Dock( FILL )
	p.Scroll.Paint = function( _, w, h ) rectangle( C.list, 0, 0, w, h ) end
	p.Scroll:GetCanvas():DockPadding( 5, 5, 5, 5 )
	local bar = p.Scroll:GetVBar()
	bar:SetWide( 8 )
	bar:SetHideButtons( true )
	bar.Paint = function() end
	bar.btnGrip.Paint = function( _, w, h ) rectangle( C.button, 1, 0, w - 2, h ) end
	p.Rows = {}
	return p
end

local FRAME = {}
function FRAME:Init()
	self:SetTitle( "" )
	self:ShowCloseButton( false )
	self:SetDraggable( false )
	self:SetSizable( false )
	self:SetDeleteOnClose( true )
	self:DockPadding( 24, 12, 24, 16 )
	self.Session = M.Session or M.New()
	M.Session = self.Session
	self.Page, self.NarrowTab, self.Query = 1, "available", ""
	self.Header = vgui.Create( "DPanel", self )
	self.Header:Dock( TOP )
	self.Header:SetTall( 42 )
	self.Header.Paint = function() end
	local close = button( self.Header, "X", function() self:Close() end, true )
	close:Dock( RIGHT )
	close:SetWide( 40 )
	close:SetTooltip( text( "Close", "关闭" ) )
	local title = label( self.Header, text( "Texture packs", "材质包" ), C.text, 2, 1, true )
	title:Dock( FILL )
	title:DockMargin( 40, 8, 0, 0 )
	self.Search = vgui.Create( "DTextEntry", self )
	self.Search:Dock( TOP )
	self.Search:SetTall( 34 )
	self.Search:DockMargin( 0, 0, 0, 18 )
	self.Search:SetFont( "mc_texture_pack_input" )
	self.Search:SetPlaceholderText( text( "Search texture packs", "搜索材质包" ) )
	self.Search:SetTextColor( C.text )
	self.Search:SetCursorColor( C.text )
	self.Search.Paint = function( s, w, h )
		rectangle( C.list, 0, 0, w, h )
		surface.SetDrawColor( s:HasFocus() and C.text or C.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			draw.SimpleText( text( "Search texture packs", "搜索材质包" ), "mc_texture_pack_input", 8, h / 2, C.dim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end
		s:DrawTextEntryText( C.text, C.button, C.text )
	end
	self.Search.OnChange = function( s )
		timer.Create( SEARCH_TIMER, 0.15, 1, function()
			if not IsValid( self ) then return end
			self.Query, self.Page = s:GetValue(), 1
			self:RefreshRows()
			self.Available.Scroll:GetVBar():SetScroll( 0 )
		end )
	end
	self.Search.OnKeyCodeTyped = function( _, code ) if code == KEY_ESCAPE then self:Close() end end
	self.Footer = vgui.Create( "DPanel", self )
	self.Footer:Dock( BOTTOM )
	self.Footer:SetTall( 108 )
	self.Footer.Paint = function() end
	self.Hint = label( self.Footer, text( "One texture pack can be active at a time.", "一次启用一个材质包。" ), C.dim, 2, 1, true )
	self.Status = label( self.Footer, "", C.warning, 2, 2, true )
	self.Undo = button( self.Footer, text( "Undo changes", "撤销更改" ), function()
		self.Session:Revert()
		self:RefreshRows()
	end )
	self.Apply = button( self.Footer, text( "Apply", "应用" ), function()
		local ok, err = self.Session:Apply()
		self:RefreshRows()
		if not ok then self:SetStatus( text( "Could not apply: ", "应用失败：" ) .. tostring( err ) ) end
	end )
	self.Footer.PerformLayout = function( _, w )
		self.Hint:SetPos( 0, 0 ) self.Hint:SetSize( w, 20 )
		self.Status:SetPos( 0, 22 ) self.Status:SetSize( w, 40 )
		local bw = math.min( 200, ( w - 12 ) / 2 )
		self.Undo:SetPos( math.floor( w / 2 - bw - 6 ), 68 ) self.Undo:SetSize( bw, 38 )
		self.Apply:SetPos( math.floor( w / 2 + 6 ), 68 ) self.Apply:SetSize( bw, 38 )
	end
	self.Details = label( self, "", C.dim, 2, 4 )
	self.Details:Dock( BOTTOM )
	self.Details:SetTall( 86 )
	self.Details:SetVisible( false )
	self.Board = vgui.Create( "DPanel", self )
	self.Board:Dock( FILL )
	self.Board.Paint = function() end
	self.Available = lane( self.Board, text( "Available", "可用" ) )
	self.Selected = lane( self.Board, text( "Selected", "已选择" ) )
	self.AvailableTab = button( self.Board, text( "Available", "可用" ), function() self.NarrowTab = "available" self.Board:InvalidateLayout( true ) end, true )
	self.SelectedTab = button( self.Board, text( "Selected", "已选择" ), function() self.NarrowTab = "selected" self.Board:InvalidateLayout( true ) end, true )
	self.Board.PerformLayout = function( _, w, h )
		local narrow = w < 760
		self.AvailableTab:SetVisible( narrow ) self.SelectedTab:SetVisible( narrow )
		self.AvailableTab:SetPos( 0, 0 ) self.AvailableTab:SetSize( w / 2, 34 )
		self.SelectedTab:SetPos( w / 2, 0 ) self.SelectedTab:SetSize( w / 2, 34 )
		self.Available:SetVisible( not narrow or self.NarrowTab == "available" )
		self.Selected:SetVisible( not narrow or self.NarrowTab == "selected" )
		local y, width = 0, math.floor( ( w - 24 ) / 2 )
		if narrow then y, width = 38, w end
		self.Available:SetPos( 0, y ) self.Available:SetSize( width, math.max( 0, h - y ) )
		self.Selected:SetPos( narrow and 0 or width + 24, y ) self.Selected:SetSize( width, math.max( 0, h - y ) )
	end
	local function tool( parent, caption, callback, width )
		local b = button( parent, caption, callback, true )
		b:Dock( LEFT ) b:SetWide( width or 76 )
		return b
	end
	tool( self.Available.Tools, text( "Refresh", "刷新" ), function() self:Refresh() end )
	local function detail() self.Details:SetVisible( not self.Details:IsVisible() ) self:UpdateState() self:InvalidateLayout( true ) end
	self.AvailableDetails = tool( self.Available.Tools, text( "Details", "详情" ), detail )
	tool( self.Selected.Tools, text( "Use default", "恢复默认" ), function() self:Choose( "default" ) end, 124 )
	self.SelectedDetails = tool( self.Selected.Tools, text( "Details", "详情" ), detail )
	self.Next = button( self.Available.Tools, ">", function()
		self.Page = self.Page + 1 self:RefreshRows() self.Available.Scroll:GetVBar():SetScroll( 0 )
	end, true )
	self.Next:Dock( RIGHT ) self.Next:SetWide( 32 )
	self.Previous = button( self.Available.Tools, "<", function()
		self.Page = self.Page - 1 self:RefreshRows() self.Available.Scroll:GetVBar():SetScroll( 0 )
	end, true )
	self.Previous:Dock( RIGHT ) self.Previous:SetWide( 32 )
	for _, event in ipairs( EVENTS ) do hook.Add( event, self, function( panel ) panel:QueueRefresh() end ) end
	cvars.AddChangeCallback( "mc_texture_pack", function() if IsValid( self ) then self:QueueRefresh() end end, "mc_texture_pack_manager" )
	hook.Add( "OnScreenSizeChanged", self, function( panel ) panel:FitScreen() end )
	self:Refresh()
end

function FRAME:Paint( w, h ) rectangle( C.background, 0, 0, w, h ) end
function FRAME:OnKeyCodePressed( code ) if code == KEY_ESCAPE then self:Close() end end

function FRAME:FitScreen()
	local sw, sh = ScrW(), ScrH()
	local margin = sh < 800 and 12 or 24
	self:SetSize( math.max( 1, math.min( 1200, sw - margin * 2 ) ), math.max( 1, math.min( 820, sh - margin * 2 ) ) )
	self:Center()
	self:InvalidateLayout( true )
end

function FRAME:SetStatus( value )
	self.Status:SetCaption( value )
	self.Apply:SetTooltip( value ~= "" and value or text( "Apply selected pack", "应用所选材质包" ) )
end

function FRAME:UpdateState()
	local s = self.Session
	self.Apply:SetEnabled( s:CanApply() )
	self.Undo:SetEnabled( s:IsDirty() )
	local state = ""
	if s.error then state = text( "Could not apply: ", "应用失败：" ) .. s.error
	elseif s.leaseOwner then state = text( "Controlled by ", "当前由模式控制：" ) .. s.leaseOwner .. " (" .. s.active .. ")"
	elseif not s.byName[s.draft] then state = text( "Selected pack was removed.", "所选材质包已被移除。" )
	elseif s:IsDirty() then state = text( "Changes not applied", "更改尚未应用" )
	elseif s.active ~= s.preference then state = text( "Currently active: ", "当前实际使用：" ) .. s.active end
	self:SetStatus( state )
	local entry = s.byName[s.focus]
	self.AvailableDetails:SetEnabled( entry ~= nil and s.focus ~= s.draft )
	self.SelectedDetails:SetEnabled( entry ~= nil and s.focus == s.draft )
	if entry then
		self.Details:SetCaption( entry.title .. "\n" .. entry.description .. "\n"
			.. text( "Provider: ", "提供者：" ) .. entry.owner .. "\n" .. entry.name )
		self.Details:SetTooltip( entry.description )
	else self.Details:SetCaption( text( "This pack is no longer registered.", "这个材质包已不再注册。" ) ) end
end

function FRAME:Choose( name )
	local ok, err = self.Session:Choose( name )
	if not ok then self:SetStatus( tostring( err ) ) return end
	self.NarrowTab = "selected"
	self:RefreshRows()
	self.Board:InvalidateLayout( true )
end

function FRAME:RefreshRows()
	local available = self.Session:VisiblePacks( self.Query )
	local pages = math.max( 1, math.ceil( #available / PAGE_SIZE ) )
	self.Page = math.Clamp( self.Page, 1, pages )
	self.Previous:SetVisible( pages > 1 ) self.Next:SetVisible( pages > 1 )
	self.Previous:SetEnabled( self.Page > 1 ) self.Next:SetEnabled( self.Page < pages )
	local function populate( column, entries, first, last, selected )
		local count = 0
		for i = first, last do
			count = count + 1
			local row = column.Rows[count]
			if not IsValid( row ) then
				row = vgui.Create( "MCTexturePackRow", column.Scroll:GetCanvas() )
				row:Dock( TOP ) column.Rows[count] = row
			end
			row:SetEntry( self, entries[i], selected ) row:SetVisible( true ) row:SetZPos( count )
		end
		for i = count + 1, #column.Rows do column.Rows[i]:SetVisible( false ) end
		if not IsValid( column.Empty ) then
			column.Empty = label( column.Scroll:GetCanvas(), text( "No matching packs", "没有匹配的材质包" ), C.dim )
			column.Empty:Dock( TOP ) column.Empty:SetTall( 40 )
		end
		column.Empty:SetVisible( count == 0 )
		column.Scroll:InvalidateLayout( true )
	end
	populate( self.Available, available, ( self.Page - 1 ) * PAGE_SIZE + 1, math.min( self.Page * PAGE_SIZE, #available ), false )
	local selected = self.Session.byName[self.Session.draft] or { name = self.Session.draft, title = self.Session.draft,
		description = text( "Pack removed", "材质包已移除" ), owner = "", available = false }
	populate( self.Selected, { selected }, 1, 1, true )
	self:UpdateState()
end

function FRAME:Refresh() self.Session:Refresh() self:RefreshRows() end
function FRAME:QueueRefresh()
	if self.RefreshQueued then return end
	self.RefreshQueued = true
	timer.Simple( 0, function()
		if not IsValid( self ) then return end
		self.RefreshQueued = nil
		self:Refresh()
	end )
end

function FRAME:OnRemove()
	timer.Remove( SEARCH_TIMER )
	cvars.RemoveChangeCallback( "mc_texture_pack", "mc_texture_pack_manager" )
	for _, event in ipairs( EVENTS ) do hook.Remove( event, self ) end
	hook.Remove( "OnScreenSizeChanged", self )
	if M.Frame == self then M.Frame = nil end
end

if IsValid( M.Frame ) then M.Frame:Remove() end
vgui.Register( "MCTexturePackManager", FRAME, "DFrame" )
function MC.OpenTexturePackManager()
	if not MC.Check( MC.TexturePack and MC.ListTexturePacks and MC.SetTexturePackPreference and Font,
		"texture_pack_manager_dependencies", "Texture pack manager dependencies are unavailable" ) then return end
	if not IsValid( M.Frame ) then M.Frame = vgui.Create( "MCTexturePackManager" ) end
	M.Frame:Refresh()
	M.Frame:FitScreen()
	M.Frame:MakePopup()
	return M.Frame
end
concommand.Add( "mc_texture_packs", MC.OpenTexturePackManager )
MC.RegisterLanguageChanged( "mc_texture_pack_manager", function()
	if not IsValid( M.Frame ) then return end
	M.Frame:Remove()
	MC.OpenTexturePackManager()
end )
