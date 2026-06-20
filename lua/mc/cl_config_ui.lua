--[[----------------------------------------------------------------------------
	MC : in-game ConVar config menu.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.ConfigServerValues = MC.ConfigServerValues or {}

local UI = {
	bg = Color( 28, 30, 34, 250 ),
	header = Color( 18, 20, 24, 255 ),
	panel = Color( 38, 42, 49, 245 ),
	panelHover = Color( 52, 58, 68, 245 ),
	panelActive = Color( 68, 78, 94, 250 ),
	field = Color( 14, 16, 20, 245 ),
	line = Color( 90, 98, 112, 130 ),
	text = Color( 235, 238, 242 ),
	textDim = Color( 165, 172, 184 ),
	accent = Color( 120, 170, 235 ),
	warn = Color( 245, 190, 110 ),
}

local function configText( en, zh )
	if zh and MC.Language and MC.Language() == "zh_cn" then
		return zh
	end
	return en
end

local function itemLabel( item )
	return configText( item.label or item.name, item.labelZH )
end

local function itemHelp( item )
	return configText( item.help or "", item.helpZH )
end

local function categoryLabel( category )
	return configText( category.label or category.id, category.zhLabel )
end

local function getCVarValue( scope, name )
	if scope == "server" then
		return MC.ConfigServerValues[name] or ""
	end

	local cvar = GetConVar and GetConVar( name ) or nil
	if not cvar then return "" end
	return cvar:GetString()
end

local function isTruthyValue( value )
	value = string.lower( tostring( value or "" ) )
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function styleButton( btn, isActive )
	btn:SetTextColor( UI.text )
	btn.Paint = function( s, w, h )
		local bg = isActive and isActive() and UI.panelActive or ( s:IsHovered() and UI.panelHover or UI.panel )
		draw.RoundedBox( 4, 0, 0, w, h, bg )
		surface.SetDrawColor( UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	end
end

local function applyConfigValue( scope, item, value )
	value = tostring( value or "" )
	if scope == "client" then
		RunConsoleCommand( item.name, value )
		return
	end

	net.Start( "mc_config_set" )
		net.WriteString( item.name )
		net.WriteString( value )
	net.SendToServer()
end

local function requestServerConfigValues()
	net.Start( "mc_config_get" )
	net.SendToServer()
end

local function clearPanel( pnl )
	for _, child in ipairs( pnl:GetChildren() ) do
		child:Remove()
	end
end

local function scrollCanvas( scroll )
	return scroll.GetCanvas and scroll:GetCanvas() or scroll
end

local function createBoolControl( parent, scope, item, editable )
	local holder = vgui.Create( "DPanel", parent )
	holder:Dock( RIGHT )
	holder:DockMargin( 0, 16, 10, 16 )
	holder:SetWide( 70 )
	holder.MCEnabled = isTruthyValue( getCVarValue( scope, item.name ) )
	holder.Paint = function() end

	local function makeChoice( value, label, x )
		local btn = vgui.Create( "DButton", holder )
		btn:SetPos( x, 0 )
		btn:SetSize( 32, 32 )
		btn:SetText( "" )
		btn:SetEnabled( editable )
		btn.Paint = function( s, w, h )
			local active = holder.MCEnabled == value
			local bg = active and UI.accent or Color( 50, 56, 66, 245 )
			if not editable then bg = active and Color( 78, 88, 104, 210 ) or Color( 44, 48, 56, 210 ) end
			if s:IsHovered() and editable then
				bg = active and Color( 140, 190, 245 ) or Color( 68, 76, 90, 245 )
			end

			draw.RoundedBox( 0, 0, 0, w, h, bg )
			surface.SetDrawColor( active and Color( 220, 235, 255, 210 ) or UI.line )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
			draw.SimpleText( label, "mc_hud_small", w * 0.5, h * 0.5, UI.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			if not editable or holder.MCEnabled == value then return end
			holder.MCEnabled = value
			applyConfigValue( scope, item, value and "1" or "0" )
		end
		return btn
	end

	makeChoice( false, configText( "OFF", "关" ), 0 )
	makeChoice( true, configText( "ON", "开" ), 38 )
	return holder
end

local function createConfigRow( parent, scope, item )
	local editable = scope == "client" or ( LocalPlayer():IsAdmin() )

	local row = vgui.Create( "DPanel", parent )
	row:Dock( TOP )
	row:DockMargin( 0, 0, 0, 8 )
	row:SetTall( item.kind == "bool" and 64 or 88 )
	row.Paint = function( _, w, h )
		draw.RoundedBox( 4, 0, 0, w, h, UI.panel )
		surface.SetDrawColor( UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	end

	if item.kind == "bool" then
		createBoolControl( row, scope, item, editable )
	end

	local title = vgui.Create( "DLabel", row )
	title:Dock( TOP )
	title:DockMargin( 10, 7, 10, 0 )
	title:SetTall( 18 )
	title:SetTextColor( UI.text )
	title:SetText( itemLabel( item ) .. "  (" .. item.name .. ")" )

	local help = vgui.Create( "DLabel", row )
	help:Dock( TOP )
	help:DockMargin( 10, 1, 10, 4 )
	help:SetTall( 20 )
	help:SetTextColor( editable and UI.textDim or UI.warn )
	help:SetText( editable and itemHelp( item ) or configText( "Admin only", "仅管理员可改" ) )

	if item.kind == "bool" then
		return row
	end

	local line = vgui.Create( "DPanel", row )
	line:Dock( BOTTOM )
	line:DockMargin( 10, 4, 10, 10 )
	line:SetTall( 28 )
	line.Paint = function() end

	local apply = vgui.Create( "DButton", line )
	apply:Dock( RIGHT )
	apply:SetWide( 72 )
	apply:SetText( configText( "Apply", "应用" ) )
	apply:SetEnabled( editable )
	styleButton( apply )

	local entry = vgui.Create( "DTextEntry", line )
	entry:Dock( FILL )
	entry:DockMargin( 0, 0, 8, 0 )
	entry:SetText( getCVarValue( scope, item.name ) )
	entry:SetEnabled( editable )
	entry:SetTextColor( UI.text )
	entry:SetDrawBackground( false )
	if entry.SetCursorColor then entry:SetCursorColor( UI.accent ) end
	entry.Paint = function( s, w, h )
		draw.RoundedBox( 3, 0, 0, w, h, UI.field )
		surface.SetDrawColor( UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		s:DrawTextEntryText( UI.text, UI.accent, UI.text )
	end
	entry.OnEnter = function()
		if editable then applyConfigValue( scope, item, entry:GetValue() ) end
	end
	apply.DoClick = function()
		applyConfigValue( scope, item, entry:GetValue() )
	end

	return row
end

function MC.OpenConfigMenu()
	if IsValid( MC.ConfigFrame ) then MC.ConfigFrame:Remove() end

	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( configText( "MC Config", "MC 配置" ) )
	fr:SetSize( 980, 680 )
	fr:Center()
	fr:MakePopup()
	fr.Paint = function( _, w, h )
		draw.RoundedBox( 6, 0, 0, w, h, UI.bg )
		draw.RoundedBoxEx( 6, 0, 0, w, 28, UI.header, true, true, false, false )
	end
	MC.ConfigFrame = fr

	local activeScope = "client"
	local activeCategory = nil
	local scopeButtons = {}
	local categoryButtons = {}
	MC.ConfigScopeButtons = scopeButtons

	local top = vgui.Create( "DPanel", fr )
	top:Dock( TOP )
	top:DockMargin( 8, 8, 8, 6 )
	top:SetTall( 34 )
	top.Paint = function() end

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body:DockMargin( 8, 0, 8, 8 )
	body.Paint = function() end

	local left = vgui.Create( "DScrollPanel", body )
	left:Dock( LEFT )
	left:SetWide( 190 )
	left:DockMargin( 0, 0, 8, 0 )

	local right = vgui.Create( "DScrollPanel", body )
	right:Dock( FILL )

	local function categoriesForScope()
		return ( MC.ConfigConVars and MC.ConfigConVars[activeScope] ) or {}
	end

	local function rebuildRows()
		local canvas = scrollCanvas( right )
		clearPanel( canvas )
		for _, cat in ipairs( categoriesForScope() ) do
			if cat.id == activeCategory then
				for _, item in ipairs( cat.items or {} ) do
					createConfigRow( canvas, activeScope, item )
				end
				break
			end
		end
	end
	MC.ConfigRefreshRows = rebuildRows

	local function categoryExists( id )
		for _, cat in ipairs( categoriesForScope() ) do
			if cat.id == id then return true end
		end
		return false
	end

	local function rebuildCategories()
		local canvas = scrollCanvas( left )
		clearPanel( canvas )
		categoryButtons = {}
		local cats = categoriesForScope()
		if not activeCategory or not categoryExists( activeCategory ) then
			activeCategory = cats[1] and cats[1].id or nil
		end

		for _, cat in ipairs( cats ) do
			local btn = vgui.Create( "DButton", canvas )
			btn:Dock( TOP )
			btn:DockMargin( 0, 0, 0, 6 )
			btn:SetTall( 32 )
			btn:SetText( categoryLabel( cat ) )
			btn.CategoryButton = true
			categoryButtons[cat.id] = btn
			styleButton( btn, function() return activeCategory == cat.id end )
			btn.DoClick = function()
				activeCategory = cat.id
				rebuildRows()
			end
		end
		rebuildRows()
	end

	for _, scope in ipairs( { "client", "server" } ) do
		local btn = vgui.Create( "DButton", top )
		btn:Dock( LEFT )
		btn:DockMargin( 0, 0, 8, 0 )
		btn:SetWide( 120 )
		btn:SetText( scope == "client" and configText( "Client", "客户端" ) or configText( "Server (Admin)", "服务端 (管理员)" ) )
		scopeButtons[scope] = btn
		styleButton( btn, function() return activeScope == scope end )
		btn.DoClick = function()
			activeScope = scope
			activeCategory = nil
			if activeScope == "server" then requestServerConfigValues() end
			rebuildCategories()
		end
	end

	local hint = vgui.Create( "DLabel", top )
	hint:Dock( FILL )
	hint:SetTextColor( UI.textDim )
	hint:SetContentAlignment( 6 )
	hint:SetText( configText( "Server settings require admin rights.", "服务端设置需要管理员权限。" ) )

	rebuildCategories()
end

net.Receive( "mc_config_values", function()
	local values = {}
	for _ = 1, net.ReadUInt( 12 ) do
		values[net.ReadString()] = net.ReadString()
	end

	MC.ConfigServerValues = values
	if IsValid( MC.ConfigFrame ) and MC.ConfigRefreshRows then
		MC.ConfigRefreshRows()
	end
end )

concommand.Add( "mc_config", function()
	MC.OpenConfigMenu()
end )

if MC.RegisterLanguageChanged then
	MC.RegisterLanguageChanged( "mc_config_ui", function()
		if IsValid( MC.ConfigFrame ) then
			MC.OpenConfigMenu()
		end
	end )
end
