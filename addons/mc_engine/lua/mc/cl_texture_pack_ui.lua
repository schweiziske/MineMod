-- A Minecraft-style picker for registered atlases and prepared source packs.
local M = MC.TexturePackManager
local L = M.Text
local C = {
	background = Color( 41, 41, 41 ), list = Color( 23, 23, 23 ), hover = Color( 38, 38, 38 ),
	text = Color( 255, 250, 237 ), secondary = Color( 238, 224, 189 ), line = Color( 100, 91, 69 ),
	button = Color( 91, 73, 39 ), light = Color( 177, 146, 82 ), dark = Color( 40, 33, 22 ),
	warning = Color( 255, 210, 117 ), disabled = Color( 208, 193, 153 ), disabledButton = Color( 55, 53, 46 ),
	focus = Color( 255, 222, 144 ), white = Color( 255, 255, 255 ),
}
local previews = {}
local SEARCH_TIMER = "mc_texture_pack_manager_search"
local PAGE_SIZE = 32
local EVENTS = { "MC.TexturePackChanged", "MC.TexturePackRegistered", "MC.TexturePackUnregistered",
	"MC.TexturePackOwnerUnregistered", "MC.TexturePackLeaseChanged", "MC.TexturePackSourcesChanged", "MC.ResourcePackApplyChanged", "MC.ResourcePackCatalogChanged" }

-- One immutable presentation snapshot per half-second bake checkpoint. Paint
-- only draws it; it never advances work, invents progress or polls the compiler.
local bakeProgress
hook.Add("MC.ResourcePackApplyChanged","mc_texture_pack_progress",function(status)
	if status.raw and (status.state=="baking" or status.state=="building") then
		local caption=L( "preparing_textures" )
		if status.phase=="bake" then caption=L( "baking_textures" ) end
		local count,total=status.completed or 0,status.total or 0
		if total>0 then caption=L("progress",{caption=caption,count=count,total=total}) end
		bakeProgress={caption=caption,fraction=total>0 and count/total or 0}
	else bakeProgress=nil end
end)
hook.Add("PostRenderVGUI","mc_texture_pack_progress",function()
	if not bakeProgress then return end
	local sw,sh=ScrW(),ScrH();local width=math.min(540,sw-32);local x,y=math.floor((sw-width)/2),math.floor(sh/2-44)
	surface.SetDrawColor(C.background);surface.DrawRect(x,y,width,88)
	draw.SimpleText(bakeProgress.caption,"mc_texture_pack_body_24",sw/2,y+20,C.text,TEXT_ALIGN_CENTER,TEXT_ALIGN_CENTER)
	surface.SetDrawColor(C.line);surface.DrawRect(x+16,y+52,width-32,16)
	surface.SetDrawColor(C.light);surface.DrawRect(x+18,y+54,math.floor((width-36)*bakeProgress.fraction),12)
end)

-- Rasterize CJK at its final screen size; never shrink or stretch the HUD glyph atlas.
local fonts = { body = "mc_texture_pack_body_24", title = "mc_texture_pack_title_26", heading = "mc_texture_pack_heading_30" }
local heights = {}
for role, size in pairs( { body = 24, title = 26, heading = 30 } ) do
	local name = fonts[role]
	surface.CreateFont( name, { font = "Microsoft YaHei", size = size, weight = role == "body" and 500 or 600,
		extended = true, antialias = true } )
	surface.SetFont( name )
	local _, height = surface.GetTextSize( "Ag国" )
	heights[name] = height
end

local function measure( value, font )
	surface.SetFont( font )
	local width = surface.GetTextSize( value )
	return width
end

local function drawText( value, font, x, y, color )
	surface.SetFont( font )
	surface.SetTextColor( color )
	surface.SetTextPos( math.floor( x ), math.floor( y ) )
	surface.DrawText( value )
end

local function rectangle( color, x, y, w, h )
	surface.SetDrawColor( color )
	surface.DrawRect( x, y, w, h )
end

-- Measure whole prefixes for kerning, and only cut at UTF-8 boundaries during layout.
local function fit( value, width, font )
	if width <= 0 then return "" end
	if measure( value, font ) <= width then return value end
	local ends = {}
	for offset in utf8.codes( value ) do ends[#ends + 1] = offset - 1 end
	ends[#ends + 1] = #value
	local low, high = 1, #ends
	while low < high do
		local middle = math.ceil( ( low + high ) / 2 )
		if measure( value:sub( 1, ends[middle] ), font ) <= width then low = middle
		else high = middle - 1 end
	end
	return value:sub( 1, ends[low] )
end

local function elide( value, width, font )
	if measure( value, font ) <= width then return value end
	local suffix = "…"
	local suffixWidth = measure( suffix, font )
	if suffixWidth > width then return "" end
	return fit( value, width - suffixWidth, font ) .. suffix
end

local function label( parent, value, color, font, lines, centered )
	local panel = vgui.Create( "DPanel", parent )
	panel.Caption, panel.Lines = value or "", {}
	panel.Options = { color = color or C.text, font = font or fonts.body }
	panel.LineHeight = heights[panel.Options.font] + 2
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
			local part = fit( line, w, self.Options.font )
			if part == "" and line ~= "" then break end
			remaining = remaining:sub( #part + 1 )
			if remaining:sub( 1, 1 ) == "\n" then remaining = remaining:sub( 2 ) end
			if index == ( lines or 1 ) and remaining ~= "" then
				part = elide( part .. "…", w, self.Options.font )
			end
			self.Lines[#self.Lines + 1] = { text = part,
				x = centered and math.floor( ( w - measure( part, self.Options.font ) ) / 2 ) or 0 }
		end
	end
	panel.Paint = function( s )
		for index, line in ipairs( s.Lines ) do
			drawText( line.text, s.Options.font, line.x, ( index - 1 ) * s.LineHeight, s.Options.color )
		end
	end
	return panel
end

local function button( parent, caption, callback, plain )
	local b = vgui.Create( "DButton", parent )
	b:SetText( "" )
	b.Caption, b.Options = caption, { font = fonts.title, color = C.text }
	b:SetTooltip( caption )
	b.PerformLayout = function( s, w, h )
		s.Fitted = elide( s.Caption, w - 10, s.Options.font )
		s.TextX = math.floor( ( w - measure( s.Fitted, s.Options.font ) ) / 2 )
		s.TextY = math.floor( ( h - heights[s.Options.font] ) / 2 )
	end
	b.Paint = function( s, w, h )
		local enabled = s:IsEnabled()
		local focus = enabled and ( s:IsHovered() or s:HasFocus() )
		if not plain then
			rectangle( C.dark, 0, 0, w, h )
			rectangle( enabled and C.button or C.disabledButton, 2, 2, w - 4, h - 4 )
			if enabled then rectangle( s:IsDown() and C.dark or C.light, 2, 2, w - 4, 2 ) end
		end
		if focus then
			surface.SetDrawColor( C.focus )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end
		s.Options.color = enabled and C.text or C.disabled
		drawText( s.Fitted or "", s.Options.font, s.TextX or 0, s.TextY or 0, s.Options.color )
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
	self.TitleOptions = { font = fonts.title, color = C.text }
	self.DescriptionOptions = { font = fonts.body, color = C.secondary }
	self.Pick.PerformLayout = function( _, w )
		self.FittedTitle = elide( self.Entry.title, w - 72, self.TitleOptions.font )
		self.FittedDescription = elide( self.Summary, w - 72, self.DescriptionOptions.font )
	end
	self.Pick.Paint = function( s, w, h )
		render.PushFilterMin( TEXFILTER.POINT )
		render.PushFilterMag( TEXFILTER.POINT )
		surface.SetMaterial( self.Preview )
		surface.SetDrawColor( C.white )
		surface.DrawTexturedRect( 0, math.floor( ( h - 60 ) / 2 ), 60, 60 )
		render.PopFilterMag()
		render.PopFilterMin()
		drawText( self.FittedTitle or "", self.TitleOptions.font, 72, 8, self.TitleOptions.color )
		drawText( self.FittedDescription or "", self.DescriptionOptions.font, 72, 38, self.DescriptionOptions.color )
	end
end

function ROW:SetEntry( manager, entry, selected )
	self.Manager, self.Entry = manager, entry
	self.Preview = preview( entry.preview )
	self.Summary = entry.description
	if not entry.available then self.Summary = L( "texture_files_missing" ) end
	self.DescriptionOptions.color = entry.available and C.secondary or C.warning
	self.Pick:SetTooltip( entry.title .. "\n" .. self.Summary )
	self.Transfer:SetVisible( not selected )
	self.Transfer:SetEnabled( entry.available == true )
	self.Transfer:SetTooltip( L( "select_pack", { pack = entry.title } ) )
	self:InvalidateLayout( true )
	self.Pick:InvalidateLayout( true )
end

function ROW:Paint( w, h )
	if self.Pick:IsHovered() then rectangle( C.hover, 0, 0, w, h ) end
	if self.Manager.Session.focus == self.Entry.name or self.Pick:HasFocus() then
		surface.SetDrawColor( C.focus )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	end
end
vgui.Register( "MCTexturePackRow", ROW, "DPanel" )

local function lane( parent, title )
	local p = vgui.Create( "DPanel", parent )
	p.Paint = function() end
	p.Title = label( p, title, C.text, fonts.title )
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
	close:SetTooltip( L( "close" ) )
	local title = label( self.Header, L( "texture_packs" ), C.text, fonts.heading, 1, true )
	title:Dock( FILL )
	title:DockMargin( 40, 0, 0, 0 )
	self.Search = vgui.Create( "DTextEntry", self )
	self.Search:Dock( TOP )
	self.Search:SetTall( 34 )
	self.Search:DockMargin( 0, 0, 0, 18 )
	self.Search:SetFont( fonts.body )
	self.Search:SetPlaceholderText( L( "search_texture_packs" ) )
	self.Search:SetTextColor( C.text )
	self.Search:SetCursorColor( C.text )
	self.Search.Paint = function( s, w, h )
		rectangle( C.list, 0, 0, w, h )
		surface.SetDrawColor( s:HasFocus() and C.text or C.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		if s:GetValue() == "" and not s:HasFocus() then
			drawText( L( "search_texture_packs" ), fonts.body, 8, ( h - heights[fonts.body] ) / 2, C.secondary )
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
	self.Footer:SetTall( ( heights[fonts.body] + 2 ) * 3 + 54 )
	self.Footer.Paint = function() end
	self.Hint = label( self.Footer, L( "one_texture_pack_can_be_active" ), C.secondary, fonts.body, 1, true )
	self.Status = label( self.Footer, "", C.warning, fonts.body, 2, true )
	self.Undo = button( self.Footer, L( "undo_changes" ), function()
		self.Session:Revert()
		self:RefreshRows()
	end )
	self.Apply = button( self.Footer, L( "apply" ), function()
		local function apply(confirmed)
			if not IsValid(self) then return end
			local ok, err = self.Session:Apply(confirmed)
			self:RefreshRows()
			if not ok then self:SetStatus(L("apply_failed", { error = tostring(err) })) end
		end
		local entry = self.Session.byName[self.Session.draft]
		if entry and entry.resourceSource and not entry.formatMatches then
			local name, revision = entry.name, entry.revision
			Derma_Query(L("format_mismatch_question"),
				L( "resource_format_mismatch" ), L( "apply" ), function()
					if IsValid(self) and self.Session.draft == name then apply({[name]=revision}) end
				end, L( "cancel" ))
		else apply() end
	end )
	self.Footer.PerformLayout = function( _, w )
		local line = self.Hint.LineHeight
		self.Hint:SetPos( 0, 0 ) self.Hint:SetSize( w, line )
		self.Status:SetPos( 0, line + 2 ) self.Status:SetSize( w, line * 2 )
		local bw = math.min( 200, ( w - 12 ) / 2 )
		self.Undo:SetPos( math.floor( w / 2 - bw - 6 ), line * 3 + 12 ) self.Undo:SetSize( bw, 38 )
		self.Apply:SetPos( math.floor( w / 2 + 6 ), line * 3 + 12 ) self.Apply:SetSize( bw, 38 )
	end
	self.Details = label( self, "", C.secondary, fonts.body, 4 )
	self.Details:Dock( BOTTOM )
	self.Details:SetTall( self.Details.LineHeight * 4 + 6 )
	self.Details:SetVisible( false )
	self.Board = vgui.Create( "DPanel", self )
	self.Board:Dock( FILL )
	self.Board.Paint = function() end
	self.Available = lane( self.Board, L( "available" ) )
	self.Selected = lane( self.Board, L( "selected" ) )
	self.AvailableTab = button( self.Board, L( "available" ), function() self.NarrowTab = "available" self.Board:InvalidateLayout( true ) end, true )
	self.SelectedTab = button( self.Board, L( "selected" ), function() self.NarrowTab = "selected" self.Board:InvalidateLayout( true ) end, true )
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
		b:Dock( LEFT ) b:SetWide( width or 94 )
		return b
	end
	tool( self.Available.Tools, L( "refresh" ), function()
		if MC.ResourceRepository and not MC.ResourcePacks.IsApplying() then MC.ResourceRepository.Refresh() end
		self:Refresh()
	end )
	self.Bake = tool( self.Available.Tools, L( "bake_atlas" ), function()
		if MC.AtlasBaker.IsBusy() then MC.AtlasBaker.Cancel() return end
		local function start( id )
			local ok, err = MC.AtlasBaker.Start( id )
			if not ok and IsValid( self ) then
				if err == "source_manifest_missing:" .. id then
					self:SetStatus( L( "sources_not_prepared", { pack = id } ) )
				else self:SetStatus( tostring( err ) ) end
			end
		end
		local menu = DermaMenu()
		for _, source in ipairs( MC.AtlasBaker.ListSourcePacks() ) do
			local id = source.bakeID
			local entry = self.Session.byName[source.name]
			menu:AddOption( entry and entry.title or source.title or source.name, function() start( id ) end )
		end
		menu:Open()
	end, 140 )
	local function detail() self.Details:SetVisible( not self.Details:IsVisible() ) self:UpdateState() self:InvalidateLayout( true ) end
	self.AvailableDetails = tool( self.Available.Tools, L( "details" ), detail )
	tool( self.Selected.Tools, L( "use_default" ), function() self:Choose( "default" ) end, 140 )
	self.SelectedDetails = tool( self.Selected.Tools, L( "details" ), detail )
	self.Next = button( self.Available.Tools, ">", function()
		self.Page = self.Page + 1 self:RefreshRows() self.Available.Scroll:GetVBar():SetScroll( 0 )
	end, true )
	self.Next:Dock( RIGHT ) self.Next:SetWide( 32 )
	self.Previous = button( self.Available.Tools, "<", function()
		self.Page = self.Page - 1 self:RefreshRows() self.Available.Scroll:GetVBar():SetScroll( 0 )
	end, true )
	self.Previous:Dock( RIGHT ) self.Previous:SetWide( 32 )
	for _, event in ipairs( EVENTS ) do hook.Add( event, self, function( panel ) panel:QueueRefresh() end ) end
	hook.Add( "MC.AtlasBakeChanged", self, function( panel ) panel:QueueRefresh() end )
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
	self.Apply:SetTooltip( value ~= "" and value or L( "apply_selected_pack" ) )
end

function FRAME:UpdateState()
	local s = self.Session
	local bake = MC.AtlasBaker.Status()
	local busy = MC.AtlasBaker.IsBusy()
	self.Bake.Caption = busy and L( "cancel_bake" ) or L( "bake_atlas" )
	self.Bake:SetTooltip( self.Bake.Caption )
	self.Bake:InvalidateLayout()
	self.Apply:SetEnabled( s:CanApply() )
	self.Undo:SetEnabled( s:IsDirty() )
	local state = ""
	if s.error then state = L( "apply_failed", { error = s.error } )
	elseif s.leaseOwner then state = L( "controlled_by", { owner = s.leaseOwner, pack = s.active } )
	elseif not s.byName[s.draft] then state = L( "selected_pack_was_removed" )
	elseif s:IsDirty() then state = L( "changes_not_applied" )
	elseif s.active ~= s.preference then state = L( "currently_active", { pack = s.active } ) end
	if busy then
		if s.pending then state = L( "preparing_selected_pack_it_will_apply" )
		else state = L( "waiting_to_bake", { pack = bake.pack } ) end
	elseif bake.state == "failed" then state = L( "bake_failed", { error = bake.error } ) end
	self:SetStatus( state )
	local entry = s.byName[s.focus]
	self.AvailableDetails:SetEnabled( entry ~= nil and s.focus ~= s.draft )
	self.SelectedDetails:SetEnabled( entry ~= nil and s.focus == s.draft )
	if entry then
		local support = entry.name
		if entry.resourceSource then
			support = entry.error or L( "java_textures_models_and_other_pack" )
			if entry.unsupported and #entry.unsupported > 0 then support = support .. " " .. table.concat(entry.unsupported, ", ") end
		end
		self.Details:SetCaption( entry.title .. "\n" .. entry.description .. "\n"
			.. L( "provider", { owner = entry.owner } ) .. "\n" .. support )
		self.Details:SetTooltip( entry.description .. "\n" .. support )
	else self.Details:SetCaption( L( "this_pack_is_no_longer_registered" ) ) end
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
			column.Empty = label( column.Scroll:GetCanvas(), L( "no_matching_packs" ), C.secondary )
			column.Empty:Dock( TOP ) column.Empty:SetTall( 40 )
		end
		column.Empty:SetVisible( count == 0 )
		column.Scroll:InvalidateLayout( true )
	end
	populate( self.Available, available, ( self.Page - 1 ) * PAGE_SIZE + 1, math.min( self.Page * PAGE_SIZE, #available ), false )
	local selected = self.Session.byName[self.Session.draft] or { name = self.Session.draft, title = self.Session.draft,
		description = L( "pack_removed" ), owner = "", available = false }
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
	hook.Remove( "MC.AtlasBakeChanged", self )
	if M.Frame == self then M.Frame = nil end
end

if IsValid( M.Frame ) then M.Frame:Remove() end
vgui.Register( "MCTexturePackManager", FRAME, "DFrame" )
function MC.OpenTexturePackManager()
	if not MC.Check( MC.TexturePack and MC.ListTexturePacks and MC.SetTexturePackPreference,
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
