--[[----------------------------------------------------------------------------
	MC : in-game ConVar config menu.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.ConfigServerValues = MC.ConfigServerValues or {}

surface.CreateFont( "mc_config_title", { font = "Roboto", size = 24, weight = 600, antialias = true, extended = true } )
surface.CreateFont( "mc_config_heading", { font = "Roboto", size = 19, weight = 600, antialias = true, extended = true } )
surface.CreateFont( "mc_config_body", { font = "Roboto", size = 16, weight = 500, antialias = true, extended = true } )
surface.CreateFont( "mc_config_small", { font = "Roboto", size = 14, weight = 400, antialias = true, extended = true } )
surface.CreateFont( "mc_config_meta", { font = "Roboto", size = 12, weight = 400, antialias = true, extended = true } )
surface.CreateFont( "mc_config_group", { font = "Roboto", size = 12, weight = 600, antialias = true, extended = true } )

-- Muted denim blue on warm charcoal. The menu intentionally avoids neon,
-- gradients, glow and rounded cards so it reads like a normal settings panel.
local UI = {
	window = Color( 31, 32, 34, 252 ),
	header = Color( 38, 39, 41, 255 ),
	toolbar = Color( 35, 36, 38, 255 ),
	sidebar = Color( 34, 35, 37, 255 ),
	content = Color( 39, 40, 42, 255 ),
	contentHeader = Color( 43, 44, 46, 255 ),
	row = Color( 44, 45, 47, 255 ),
	rowAlt = Color( 42, 43, 45, 255 ),
	rowHover = Color( 48, 49, 51, 255 ),
	field = Color( 28, 29, 31, 255 ),
	fieldDisabled = Color( 34, 35, 37, 255 ),
	neutralSelected = Color( 69, 71, 74, 255 ),
	line = Color( 68, 70, 73, 255 ),
	lineSoft = Color( 55, 57, 59, 255 ),
	text = Color( 235, 233, 228, 255 ),
	textDim = Color( 170, 171, 168, 255 ),
	textFaint = Color( 122, 124, 123, 255 ),
	accent = Color( 82, 119, 153, 255 ),
	accentHover = Color( 98, 136, 169, 255 ),
	accentDark = Color( 52, 76, 98, 255 ),
	accentText = Color( 244, 244, 241, 255 ),
	warn = Color( 199, 159, 96, 255 ),
	success = Color( 91, 132, 103, 255 ),
	danger = Color( 160, 74, 68, 255 ),
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

local function categoryDescription( category )
	return configText( category.description or "", category.descriptionZH )
end

local function groupLabel( group )
	return configText( group.label or group.id, group.zhLabel )
end

local function choiceLabel( entry )
	return configText( entry.label or entry.value, entry.labelZH )
end

local function unitLabel( unit )
	local units = {
		blocks = { "blocks", "方块" },
		chunks = { "chunks", "区块" },
		["chunks/frame"] = { "chunks/frame", "区块/帧" },
		bytes = { "bytes", "字节" },
		ms = { "ms", "毫秒" },
		s = { "seconds", "秒" },
		px = { "px", "像素" },
		deg = { "degrees", "度" },
		texels = { "texels", "纹素" },
		u = { "Source units", "Source 单位" },
	}
	local labels = units[unit]
	if not labels then return tostring( unit or "" ) end
	return configText( labels[1], labels[2] )
end

local function configEntryVisible( entry )
	if entry.requiresNativeMesh then
		return MC.NativeMeshModuleAvailable ~= false
	end
	return true
end

local function getCVarValue( scope, name )
	if scope == "server" then
		return MC.ConfigServerValues[name] or ""
	end

	local cvar = GetConVar and GetConVar( name ) or nil
	if not cvar then return "" end
	return cvar:GetString()
end

-- Items may carry get/set instead of naming a ConVar (e.g. shader pack settings).
local function itemValue( scope, item )
	if item.get then
		local value = item.get()
		return value == nil and "" or tostring( value )
	end
	return getCVarValue( scope, item.name )
end

local function isTruthyValue( value )
	value = string.lower( tostring( value or "" ) )
	return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function canEditScope( scope )
	if scope == "client" then return true end
	local ply = LocalPlayer()
	return IsValid( ply ) and ply:IsAdmin()
end

local function applyConfigValue( scope, item, value )
	value = tostring( value or "" )
	if item.set then
		local ok, err = item.set( value )
		if ok == false then
			MC.RefreshConfigControlValue( item.name, itemValue( scope, item ) )
			Derma_Message( tostring( err ), configText( "Setting failed", "设置失败" ), "OK" )
			return false
		end
		-- Show the stored value, e.g. after clamping to the setting's range.
		MC.RefreshConfigControlValue( item.name, itemValue( scope, item ) )
		return true
	end
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

local function styleScrollPanel( scroll )
	local bar = scroll:GetVBar()
	bar:SetWide( 7 )
	bar.Paint = function( _, w, h )
		surface.SetDrawColor( UI.content )
		surface.DrawRect( 0, 0, w, h )
	end

	bar.btnGrip.Paint = function( s, w, h )
		surface.SetDrawColor( s:IsHovered() and UI.accentHover or UI.accentDark )
		surface.DrawRect( 1, 0, w - 2, h )
	end

	bar.btnUp:SetVisible( false )
	bar.btnDown:SetVisible( false )
end

local function styleTextEntry( entry, placeholder )
	entry:SetFont( "mc_config_body" )
	entry:SetTextColor( UI.text )
	entry:SetDrawBackground( false )
	if entry.SetCursorColor then entry:SetCursorColor( UI.accentHover ) end
	if entry.SetHighlightColor then entry:SetHighlightColor( UI.accentDark ) end

	entry.Paint = function( s, w, h )
		local enabled = s:IsEnabled()
		surface.SetDrawColor( enabled and UI.field or UI.fieldDisabled )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( s:HasFocus() and UI.accent or UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )

		if s:GetValue() == "" and not s:HasFocus() and placeholder then
			draw.SimpleText( placeholder, "mc_config_small", 10, h * 0.5, UI.textFaint, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		end

		s:DrawTextEntryText( enabled and UI.text or UI.textFaint, UI.accentHover, enabled and UI.text or UI.textFaint )
	end
end

local function styleFlatButton( button, options )
	options = options or {}
	button:SetText( "" )
	button.Paint = function( s, w, h )
		local enabled = s:IsEnabled()
		local active = options.active and options.active() or false
		local selectedColor = options.selectedColor and options.selectedColor() or UI.accent
		local bg
		if not enabled then
			bg = UI.fieldDisabled
		elseif active then
			bg = s:IsHovered() and UI.accentHover or selectedColor
		else
			bg = s:IsHovered() and UI.rowHover or UI.field
		end

		surface.SetDrawColor( bg )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( active and UI.accent or UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )

		local label = options.label
		if isfunction( label ) then label = label() end
		draw.SimpleText( tostring( label or "" ), options.font or "mc_config_small", w * 0.5, h * 0.5,
			enabled and ( active and UI.accentText or UI.text ) or UI.textFaint,
			TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
end

local function registerControl( name, control )
	MC.ConfigControlRows = MC.ConfigControlRows or {}
	MC.ConfigControlRows[name] = MC.ConfigControlRows[name] or {}
	table.insert( MC.ConfigControlRows[name], control )
end

function MC.RefreshConfigControlValue( name, value, force )
	for _, control in ipairs( MC.ConfigControlRows and MC.ConfigControlRows[name] or {} ) do
		if IsValid( control ) and control.MCSetValue then control:MCSetValue( value, force ) end
	end
end

local function createBoolControl( parent, scope, item, editable )
	local holder = vgui.Create( "DPanel", parent )
	holder:Dock( FILL )
	holder:DockMargin( 0, 27, 12, 27 )
	holder.MCEnabled = isTruthyValue( itemValue( scope, item ) )
	holder.Paint = function() end

	local function makeChoice( value, label )
		local btn = vgui.Create( "DButton", holder )
		btn:Dock( LEFT )
		if value then btn:DockMargin( 4, 0, 0, 0 ) end
		btn:SetWide( 108 )
		btn:SetEnabled( editable )
		styleFlatButton( btn, {
			label = label,
			active = function() return holder.MCEnabled == value end,
			selectedColor = function() return value and UI.accent or UI.neutralSelected end,
		} )
		btn.DoClick = function()
			if not editable or holder.MCEnabled == value then return end
			holder.MCEnabled = value
			applyConfigValue( scope, item, value and "1" or "0" )
		end
	end

	makeChoice( false, configText( "Off", "关闭" ) )
	makeChoice( true, configText( "On", "开启" ) )

	holder.MCSetValue = function( _, value )
		holder.MCEnabled = isTruthyValue( value )
	end
	registerControl( item.name, holder )
	return holder
end

local function createChoiceControl( parent, scope, item, editable )
	local holder = vgui.Create( "DPanel", parent )
	holder:Dock( FILL )
	holder:DockMargin( 0, 27, 12, 27 )
	holder.Paint = function() end

	local combo = vgui.Create( "DComboBox", holder )
	combo:Dock( FILL )
	combo:SetFont( "mc_config_small" )
	combo:SetTextColor( editable and UI.text or UI.textFaint )
	combo:SetContentAlignment( 4 )
	if combo.SetTextInset then combo:SetTextInset( 11, 0 ) end
	if combo.SetSortItems then combo:SetSortItems( false ) end
	combo:SetEnabled( editable )

	if IsValid( combo.DropButton ) then
		combo.DropButton:SetVisible( false )
	end

	for _, entry in ipairs( item.choices or {} ) do
		combo:AddChoice( choiceLabel( entry ), tostring( entry.value ) )
	end

	combo.Paint = function( s, w, h )
		surface.SetDrawColor( s:IsEnabled() and UI.field or UI.fieldDisabled )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( s:IsMenuOpen() and UI.accent or UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		draw.SimpleText( "v", "mc_config_meta", w - 13, h * 0.5 - 1, s:IsEnabled() and UI.textDim or UI.textFaint,
			TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
	combo.OnMenuOpened = function( _, menu )
		menu.Paint = function( _, w, h )
			surface.SetDrawColor( UI.field )
			surface.DrawRect( 0, 0, w, h )
			surface.SetDrawColor( UI.line )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end

		local canvas = menu:GetCanvas()
		for _, option in ipairs( canvas:GetChildren() ) do
			if option.SetFont then option:SetFont( "mc_config_small" ) end
			if option.SetTextColor then option:SetTextColor( UI.text ) end
			if option.SetTextInset then option:SetTextInset( 10, 0 ) end
			option.Paint = function( s, w, h )
				if s:IsHovered() then
					surface.SetDrawColor( UI.accentDark )
					surface.DrawRect( 1, 0, w - 2, h )
				end
				return false
			end
		end
	end

	local function setDisplayedValue( value )
		value = tostring( value or "" )
		for _, entry in ipairs( item.choices or {} ) do
			if tostring( entry.value ) == value then
				combo:SetValue( choiceLabel( entry ) )
				return
			end
		end
		combo:SetValue( value )
	end

	setDisplayedValue( itemValue( scope, item ) )
	combo.OnSelect = function( _, _, _, data )
		if not editable then return end
		applyConfigValue( scope, item, tostring( data or "" ) )
	end

	holder.MCSetValue = function( _, value )
		setDisplayedValue( value )
	end
	registerControl( item.name, holder )
	return holder
end

local function createValueControl( parent, scope, item, editable )
	local holder = vgui.Create( "DPanel", parent )
	holder:Dock( FILL )
	holder:DockMargin( 0, 27, 12, 27 )
	holder.Paint = function() end

	local apply = vgui.Create( "DButton", holder )
	apply:Dock( RIGHT )
	apply:SetWide( 72 )
	apply:DockMargin( 7, 0, 0, 0 )
	apply:SetEnabled( editable )

	local unit
	if item.unit then
		unit = vgui.Create( "DLabel", holder )
		unit:Dock( RIGHT )
		unit:SetWide( 76 )
		unit:SetFont( "mc_config_meta" )
		unit:SetTextColor( UI.textDim )
		unit:SetContentAlignment( 5 )
		unit:SetText( unitLabel( item.unit ) )
	end

	local entry = vgui.Create( "DTextEntry", holder )
	entry:Dock( FILL )
	entry:SetText( itemValue( scope, item ) )
	entry:SetEnabled( editable )
	entry.MCOriginalValue = entry:GetValue()
	styleTextEntry( entry )

	styleFlatButton( apply, {
		label = function()
			if apply.MCSavedUntil and apply.MCSavedUntil > CurTime() then
				return configText( "Saved", "已保存" )
			end
			return configText( "Save", "保存" )
		end,
		active = function()
			return editable and ( apply.MCDirty or ( apply.MCSavedUntil and apply.MCSavedUntil > CurTime() ) )
		end,
		selectedColor = function()
			if apply.MCSavedUntil and apply.MCSavedUntil > CurTime() then return UI.success end
			return UI.accent
		end,
	} )

	local function markSaved()
		if not editable then return end
		local value = entry:GetValue()
		if applyConfigValue( scope, item, value ) == false then return end
		if item.set then value = itemValue( scope, item ) end
		entry:SetText( value )
		entry.MCOriginalValue = value
		apply.MCDirty = false
		apply.MCSavedUntil = CurTime() + 1.1
	end

	entry.OnChange = function()
		apply.MCDirty = entry:GetValue() ~= tostring( entry.MCOriginalValue or "" )
	end
	entry.OnEnter = markSaved
	apply.DoClick = markSaved

	holder.MCSetValue = function( _, value, force )
		value = tostring( value or "" )
		entry.MCOriginalValue = value
		if force or not entry:HasFocus() and not apply.MCDirty then
			entry:SetText( value )
			apply.MCDirty, apply.MCSavedUntil = false, nil
		end
	end
	registerControl( item.name, holder )
	return holder
end

local function createPresetControl( parent )
	local settings = MC.RenderPackSettings
	local pack = settings.pack
	local holder = vgui.Create( "DPanel", parent )
	holder:Dock( FILL )
	holder:DockMargin( 0, 8, 12, 8 )
	holder.Paint = function() end
	local tools = vgui.Create( "DPanel", holder )
	tools:Dock( BOTTOM )
	tools:SetTall( 32 )
	tools:DockMargin( 0, 6, 0, 0 )
	tools.Paint = function() end
	local item = { name = "mc_render_pack_preset_choice", choices = {},
		get = settings.CurrentPreset, set = settings.ApplyPreset }
	local choice = createChoiceControl( holder, "client", item, true )
	choice:DockMargin( 0, 0, 0, 0 )
	local combo = choice:GetChildren()[1]
	local sourceName, sourceReference
	local function report( ok, err )
		if ok then return end
		Derma_Message( tostring( err ), configText( "Preset failed", "预设操作失败" ), "OK" )
	end
	local function samePack()
		settings.Refresh()
		if settings.pack == pack then return true end
		report( false, configText( "The shader pack has changed.", "光影包已切换。" ) )
		return false
	end
	local function confirm( title, name, action )
		Derma_Query( name, title, configText( "Confirm", "确认" ), function()
			if samePack() then action() end
		end, configText( "Cancel", "取消" ) )
	end
	local function saveAs()
		Derma_StringRequest( configText( "Save preset as", "预设另存为" ), configText( "Name", "名称" ), "",
			function( name )
				if not samePack() then return end
				local ok, err = settings.SavePreset( name )
				if not ok and err == "preset_exists" then
					confirm( configText( "Overwrite preset?", "覆盖预设？" ), name,
						function()
							local saved, reason = settings.SavePreset( name, true )
							report( saved, reason )
						end )
				else report( ok, err ) end
			end, nil, configText( "Save", "保存" ), configText( "Cancel", "取消" ) )
	end
	local function button( icon, tooltip, action )
		local control = vgui.Create( "DImageButton", tools )
		control:Dock( LEFT )
		control:DockMargin( 0, 0, 6, 0 )
		control:SetWide( 32 )
		control:SetImage( "icon16/" .. icon .. ".png" )
		control:SetStretchToFit( false )
		control:SetTooltip( tooltip )
		control:SetName( tooltip )
		control.Paint = function( s, w, h )
			surface.SetDrawColor( s:IsHovered() and UI.rowHover or UI.field )
			surface.DrawRect( 0, 0, w, h )
			surface.SetDrawColor( UI.line )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end
		control.DoClick = function() if samePack() then action() end end
		return control
	end
	button( "page_copy", configText( "Save preset as", "预设另存为" ), saveAs )
	local overwrite = button( "disk", configText( "Overwrite user preset", "覆盖用户预设" ), function()
		local name = sourceName
		confirm( configText( "Overwrite preset?", "覆盖预设？" ), name,
			function()
				local ok, err = settings.SavePreset( name, true )
				report( ok, err )
			end )
	end )
	local delete = button( "delete", configText( "Delete user preset", "删除用户预设" ), function()
		local reference = sourceReference
		confirm( configText( "Delete preset?", "删除预设？" ), sourceName,
			function()
				local ok, err = settings.DeletePreset( reference, true )
				report( ok, err )
			end )
	end )
	button( "arrow_undo", configText( "Restore default preset", "恢复默认预设" ),
		function()
			local ok, err = settings.Reset()
			report( ok, err )
		end )
	holder.MCSetValue = function()
		local current, origin = settings.CurrentPreset()
		local source = current == "custom" and origin or current
		item.choices = settings.Presets()
		combo:Clear()
		sourceName, sourceReference = nil, nil
		for _, preset in ipairs( item.choices ) do
			combo:AddChoice( choiceLabel( preset ), preset.value )
			if preset.value == source and not preset.builtin then
				sourceName, sourceReference = preset.label, preset.value
			end
		end
		choice:MCSetValue( current )
		if current == "custom" then combo:SetValue( configText( "Custom", "自定义" ) ) end
		overwrite:SetEnabled( sourceName ~= nil )
		delete:SetEnabled( sourceName ~= nil )
	end
	holder:MCSetValue()
	registerControl( "mc_render_pack_preset", holder )
	return holder
end

local function createConfigRow( parent, scope, item, rowIndex )
	local editable = canEditScope( scope )
	local row = vgui.Create( "DPanel", parent )
	row:Dock( TOP )
	row:DockMargin( 0, 0, 0, 1 )
	row:SetTall( 92 )
	row.Paint = function( s, w, h )
		local base = rowIndex % 2 == 0 and UI.rowAlt or UI.row
		surface.SetDrawColor( s:IsHovered() and UI.rowHover or base )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.lineSoft )
		surface.DrawRect( 0, h - 1, w, 1 )
	end

	local controls = vgui.Create( "DPanel", row )
	controls:Dock( RIGHT )
	controls:SetWide( 350 )
	controls.Paint = function() end

	if item.kind == "action" and ( item.action == "texture_pack_manager" or item.action == "save_manager" ) then
		local open = vgui.Create( "DButton", controls )
		open:Dock( FILL )
		open:DockMargin( 0, 27, 12, 27 )
		styleFlatButton( open, { label = configText( "Open manager", "打开管理器" ) } )
		open.DoClick = function()
			if item.action == "save_manager" then MC.OpenSaveManager()
			else MC.OpenTexturePackManager() end
		end
	elseif item.kind == "preset" then
		createPresetControl( controls )
	elseif item.kind == "bool" then
		createBoolControl( controls, scope, item, editable )
	elseif item.kind == "choice" or item.choices then
		createChoiceControl( controls, scope, item, editable )
	else
		createValueControl( controls, scope, item, editable )
	end

	local information = vgui.Create( "DPanel", row )
	information:Dock( FILL )
	information:DockMargin( 16, 10, 10, 8 )
	information.Paint = function() end

	local title = vgui.Create( "DLabel", information )
	title:Dock( TOP )
	title:SetTall( 21 )
	title:SetFont( "mc_config_body" )
	title:SetTextColor( UI.text )
	title:SetText( itemLabel( item ) )

	local help = vgui.Create( "DLabel", information )
	help:Dock( TOP )
	help:SetTall( 34 )
	help:SetFont( "mc_config_small" )
	help:SetTextColor( UI.textDim )
	help:SetWrap( true )
	help:SetText( itemHelp( item ) )

	local meta = vgui.Create( "DLabel", information )
	meta:Dock( TOP )
	meta:SetTall( 16 )
	meta:SetFont( "mc_config_meta" )
	meta:SetTextColor( editable and UI.textFaint or UI.warn )
	local suffix = ""
	if item.advanced then suffix = suffix .. configText( "  ·  advanced", "  ·  高级设置" ) end
	if not editable then suffix = suffix .. configText( "  ·  administrator only", "  ·  仅管理员可修改" ) end
	meta:SetText( item.name .. suffix )

	return row
end

local function createResultHeading( parent, category, count )
	local heading = vgui.Create( "DPanel", parent )
	heading:Dock( TOP )
	heading:DockMargin( 0, 12, 0, 0 )
	heading:SetTall( 38 )
	heading.Paint = function( _, w, h )
		surface.SetDrawColor( UI.contentHeader )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.accent )
		surface.DrawRect( 0, h - 2, w, 2 )
		draw.SimpleText( categoryLabel( category ), "mc_config_body", 13, h * 0.5, UI.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
		draw.SimpleText( tostring( count ), "mc_config_meta", w - 14, h * 0.5, UI.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
	end
end

local function createEmptyState( parent, titleText, helpText )
	local empty = vgui.Create( "DPanel", parent )
	empty:Dock( TOP )
	empty:SetTall( 150 )
	empty.Paint = function( _, w, h )
		draw.SimpleText( titleText, "mc_config_heading", w * 0.5, 49, UI.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		draw.SimpleText( helpText, "mc_config_small", w * 0.5, 78, UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
end

function MC.OpenConfigMenu()
	if IsValid( MC.ConfigFrame ) then MC.ConfigFrame:Remove() end

	local frameWidth = math.min( 1160, ScrW() - 40 )
	local frameHeight = math.min( 760, ScrH() - 40 )
	local fr = vgui.Create( "DFrame" )
	fr:SetTitle( "" )
	fr:ShowCloseButton( false )
	fr:SetSize( frameWidth, frameHeight )
	fr:SetMinimumSize( math.min( 820, frameWidth ), math.min( 580, frameHeight ) )
	fr:SetSizable( true )
	fr:SetDeleteOnClose( true )
	fr:DockPadding( 0, 0, 0, 0 )
	fr:Center()
	fr:MakePopup()
	fr.Paint = function( _, w, h )
		surface.SetDrawColor( UI.window )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.line )
		surface.DrawOutlinedRect( 0, 0, w, h, 1 )
	end
	MC.ConfigFrame = fr

	local activeScope = "client"
	local activeCategory
	local searchQuery = ""
	local scopeButtons = {}
	local categoryButtons = {}
	MC.ConfigScopeButtons = scopeButtons
	MC.ConfigControlRows = {}

	local header = vgui.Create( "DPanel", fr )
	header:Dock( TOP )
	header:SetTall( 66 )
	header.Paint = function( _, w, h )
		surface.SetDrawColor( UI.header )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.accent )
		surface.DrawRect( 0, 0, 5, h )
		surface.SetDrawColor( UI.lineSoft )
		surface.DrawRect( 0, h - 1, w, 1 )
	end

	local title = vgui.Create( "DLabel", header )
	title:SetPos( 22, 10 )
	title:SetSize( 500, 27 )
	title:SetFont( "mc_config_title" )
	title:SetTextColor( UI.text )
	title:SetText( configText( "MC Settings", "MC 设置" ) )

	local subtitle = vgui.Create( "DLabel", header )
	subtitle:SetPos( 23, 37 )
	subtitle:SetSize( 620, 19 )
	subtitle:SetFont( "mc_config_small" )
	subtitle:SetTextColor( UI.textDim )
	subtitle:SetText( configText( "Client preferences and server administration", "客户端偏好与服务器管理" ) )

	local close = vgui.Create( "DButton", header )
	close:Dock( RIGHT )
	close:SetWide( 50 )
	close:SetText( "" )
	close.Paint = function( s, w, h )
		if s:IsHovered() then
			surface.SetDrawColor( UI.danger )
			surface.DrawRect( 0, 0, w, h )
		end
		draw.SimpleText( "X", "mc_config_body", w * 0.5, h * 0.5, s:IsHovered() and UI.accentText or UI.textDim,
			TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
	end
	close.DoClick = function() fr:Close() end

	local toolbar = vgui.Create( "DPanel", fr )
	toolbar:Dock( TOP )
	toolbar:SetTall( 48 )
	toolbar.Paint = function( _, w, h )
		surface.SetDrawColor( UI.toolbar )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.lineSoft )
		surface.DrawRect( 0, h - 1, w, 1 )
	end

	local scopeHolder = vgui.Create( "DPanel", toolbar )
	scopeHolder:Dock( LEFT )
	scopeHolder:SetWide( 410 )
	scopeHolder:DockMargin( 12, 0, 0, 0 )
	scopeHolder.Paint = function() end

	local scopeHint = vgui.Create( "DLabel", toolbar )
	scopeHint:Dock( FILL )
	scopeHint:DockMargin( 10, 0, 18, 0 )
	scopeHint:SetFont( "mc_config_small" )
	scopeHint:SetContentAlignment( 6 )
	scopeHint:SetTextColor( UI.textDim )

	local body = vgui.Create( "DPanel", fr )
	body:Dock( FILL )
	body.Paint = function() end

	local sidebar = vgui.Create( "DPanel", body )
	sidebar:Dock( LEFT )
	sidebar:SetWide( 255 )
	sidebar.Paint = function( _, w, h )
		surface.SetDrawColor( UI.sidebar )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.lineSoft )
		surface.DrawRect( w - 1, 0, 1, h )
	end

	local searchHolder = vgui.Create( "DPanel", sidebar )
	searchHolder:Dock( TOP )
	searchHolder:SetTall( 59 )
	searchHolder.Paint = function() end

	local search = vgui.Create( "DTextEntry", searchHolder )
	search:Dock( FILL )
	search:DockMargin( 12, 12, 12, 11 )
	styleTextEntry( search, configText( "Search settings", "搜索设置" ) )

	local categoryScroll = vgui.Create( "DScrollPanel", sidebar )
	categoryScroll:Dock( FILL )
	styleScrollPanel( categoryScroll )

	local contentArea = vgui.Create( "DPanel", body )
	contentArea:Dock( FILL )
	contentArea.Paint = function( _, w, h )
		surface.SetDrawColor( UI.content )
		surface.DrawRect( 0, 0, w, h )
	end

	local contentHeader = vgui.Create( "DPanel", contentArea )
	contentHeader:Dock( TOP )
	contentHeader:SetTall( 82 )
	contentHeader.Paint = function( _, w, h )
		surface.SetDrawColor( UI.contentHeader )
		surface.DrawRect( 0, 0, w, h )
		surface.SetDrawColor( UI.lineSoft )
		surface.DrawRect( 0, h - 1, w, 1 )
	end

	local contentTitle = vgui.Create( "DLabel", contentHeader )
	contentTitle:SetPos( 18, 12 )
	contentTitle:SetSize( 650, 25 )
	contentTitle:SetFont( "mc_config_heading" )
	contentTitle:SetTextColor( UI.text )

	local contentDescription = vgui.Create( "DLabel", contentHeader )
	contentDescription:SetPos( 19, 39 )
	contentDescription:SetSize( 720, 32 )
	contentDescription:SetFont( "mc_config_small" )
	contentDescription:SetTextColor( UI.textDim )
	contentDescription:SetWrap( true )

	local contentCount = vgui.Create( "DLabel", contentHeader )
	contentCount:Dock( RIGHT )
	contentCount:SetWide( 130 )
	contentCount:DockMargin( 0, 0, 18, 0 )
	contentCount:SetFont( "mc_config_meta" )
	contentCount:SetTextColor( UI.textDim )
	contentCount:SetContentAlignment( 6 )

	local restoreButton
	local function visibilityButton( parent, tooltip )
		local button = vgui.Create( "DImageButton", parent )
		button:SetSize( 32, 32 )
		button:SetImage( "icon16/eye.png" )
		button:SetStretchToFit( false )
		button:SetTooltip( tooltip )
		button:SetName( tooltip )
		button.Paint = function( s, w, h )
			surface.SetDrawColor( s:IsHovered() and UI.rowHover or UI.field )
			surface.DrawRect( 0, 0, w, h )
			surface.SetDrawColor( UI.line )
			surface.DrawOutlinedRect( 0, 0, w, h, 1 )
		end
		return button
	end

	local hideButton = visibilityButton( contentHeader, configText( "Hide settings UI", "隐藏设置界面" ) )
	hideButton:Dock( RIGHT )
	hideButton:DockMargin( 0, 25, 8, 25 )
	hideButton:SetVisible( false )
	hideButton.DoClick = function()
		if IsValid( restoreButton ) then return end
		local x, y = hideButton:LocalToScreen( 0, 0 )
		restoreButton = visibilityButton( nil, configText( "Show settings UI", "显示设置界面" ) )
		restoreButton:SetPos( math.Clamp( x, 0, ScrW() - 32 ), math.Clamp( y, 0, ScrH() - 32 ) )
		restoreButton.DoClick = function()
			restoreButton:Remove()
			restoreButton = nil
			fr:SetVisible( true )
			fr:MakePopup()
			fr:MoveToFront()
		end
		fr:SetVisible( false )
		restoreButton:MakePopup()
		restoreButton:SetKeyboardInputEnabled( false )
	end

	contentHeader.PerformLayout = function( _, w )
		local reserved = contentCount:GetWide() + 18
		if hideButton:IsVisible() then reserved = reserved + 40 end
		contentTitle:SetWide( math.max( 0, w - reserved - 28 ) )
		contentDescription:SetWide( math.max( 0, w - reserved - 29 ) )
	end

	local settingsScroll = vgui.Create( "DScrollPanel", contentArea )
	settingsScroll:Dock( FILL )
	styleScrollPanel( settingsScroll )

	local function categoriesForScope()
		local visible = {}
		for _, entryCategory in ipairs( ( MC.ConfigConVars and MC.ConfigConVars[activeScope] ) or {} ) do
			if configEntryVisible( entryCategory ) then
				local items = {}
				local source = entryCategory.items or {}
				local dynamic = entryCategory.dynamic and MC.ConfigDynamicItems and MC.ConfigDynamicItems[entryCategory.dynamic]
				if dynamic then source = dynamic() end
				for _, entry in ipairs( source ) do
					if configEntryVisible( entry ) then items[#items + 1] = entry end
				end

				local settingCount = 0
				for _, entry in ipairs( items ) do
					if entry.kind ~= "heading" then settingCount = settingCount + 1 end
				end
				if #items > 0 then
					local visibleCategory = {}
					for key, value in pairs( entryCategory ) do visibleCategory[key] = value end
					visibleCategory.items, visibleCategory.settingCount = items, settingCount
					visible[#visible + 1] = visibleCategory
				end
			end
		end
		return visible
	end

	local function activeCategoryData()
		for _, entry in ipairs( categoriesForScope() ) do
			if entry.id == activeCategory then return entry end
		end
	end

	local function categoryExists( id )
		for _, entry in ipairs( categoriesForScope() ) do
			if entry.id == id then return true end
		end
		return false
	end

	local function itemMatches( item, entryCategory, query )
		if query == "" then return true end
		local haystack = table.concat( {
			item.name or "",
			item.label or "",
			item.labelZH or "",
			item.help or "",
			item.helpZH or "",
			entryCategory.label or "",
			entryCategory.zhLabel or "",
		}, " " )
		return string.find( string.lower( haystack ), string.lower( query ), 1, true ) ~= nil
	end

	local rebuildRows
	local rebuildCategories

	rebuildRows = function( resetScroll )
		local canvas = scrollCanvas( settingsScroll )
		clearPanel( canvas )
		canvas:DockPadding( 12, 0, 5, 12 )
		MC.ConfigControlRows = {}

		local rowIndex = 0
		local total = 0
		local query = string.Trim( searchQuery or "" )
		hideButton:SetVisible( activeScope == "client" and activeCategory == "shader_pack" and query == "" )
		contentHeader:InvalidateLayout()
		if query ~= "" then
			for _, entryCategory in ipairs( categoriesForScope() ) do
				local matches = {}
				for _, entry in ipairs( entryCategory.items or {} ) do
					if entry.kind ~= "heading" and itemMatches( entry, entryCategory, query ) then
						table.insert( matches, entry )
					end
				end

				if #matches > 0 then
					createResultHeading( canvas, entryCategory, #matches )
					for _, entry in ipairs( matches ) do
						rowIndex = rowIndex + 1
						total = total + 1
						createConfigRow( canvas, activeScope, entry, rowIndex )
					end
				end
			end

			contentTitle:SetText( configText( "Search results", "搜索结果" ) )
			contentDescription:SetText( configText( "Matching settings across the current scope.", "当前范围内所有匹配的设置。" ) )
		else
			local entryCategory = activeCategoryData()
			if entryCategory then
				for _, entry in ipairs( entryCategory.items or {} ) do
					if entry.kind == "heading" then
						createResultHeading( canvas, { label = entry.label, zhLabel = entry.labelZH }, entry.count or "" )
					else
						rowIndex = rowIndex + 1
						total = total + 1
						createConfigRow( canvas, activeScope, entry, rowIndex )
					end
				end
				contentTitle:SetText( categoryLabel( entryCategory ) )
				contentDescription:SetText( categoryDescription( entryCategory ) )
			else
				contentTitle:SetText( configText( "No settings", "没有设置" ) )
				contentDescription:SetText( "" )
			end
		end

		if total == 0 then
			createEmptyState( canvas, configText( "Nothing found", "没有找到设置" ),
				configText( "Try a setting name, description or ConVar.", "可以尝试设置名称、说明或 ConVar。" ) )
		end

		contentCount:SetText( configText( total .. ( total == 1 and " setting" or " settings" ), total .. " 项设置" ) )
		canvas:InvalidateLayout( true )
		if resetScroll then settingsScroll:GetVBar():SetScroll( 0 ) end
	end
	MC.ConfigRefreshRows = function() rebuildRows( false ) end

	rebuildCategories = function()
		local canvas = scrollCanvas( categoryScroll )
		clearPanel( canvas )
		canvas:DockPadding( 9, 0, 9, 14 )
		categoryButtons = {}

		local categories = categoriesForScope()
		if not activeCategory or not categoryExists( activeCategory ) then
			activeCategory = categories[1] and categories[1].id or nil
		end

		for _, group in ipairs( ( MC.ConfigGroups and MC.ConfigGroups[activeScope] ) or {} ) do
			local groupEntry = group
			local groupHeader = vgui.Create( "DLabel", canvas )
			groupHeader:Dock( TOP )
			groupHeader:DockMargin( 6, 10, 6, 4 )
			groupHeader:SetTall( 20 )
			groupHeader:SetFont( "mc_config_group" )
			groupHeader:SetTextColor( UI.textFaint )
			groupHeader:SetText( groupLabel( groupEntry ) )

			for _, entryCategory in ipairs( categories ) do
				if entryCategory.group == groupEntry.id then
					local categoryEntry = entryCategory
					local btn = vgui.Create( "DButton", canvas )
					btn:Dock( TOP )
					btn:DockMargin( 0, 0, 0, 2 )
					btn:SetTall( 39 )
					btn:SetText( "" )
					btn.CategoryButton = true
					categoryButtons[categoryEntry.id] = btn
					btn.Paint = function( s, w, h )
						local selected = searchQuery == "" and activeCategory == categoryEntry.id
						local bg = selected and UI.accentDark or ( s:IsHovered() and UI.rowHover or UI.sidebar )
						surface.SetDrawColor( bg )
						surface.DrawRect( 0, 0, w, h )
						if selected then
							surface.SetDrawColor( UI.accent )
							surface.DrawRect( 0, 0, 4, h )
						end
						draw.SimpleText( categoryLabel( categoryEntry ), "mc_config_small", 13, h * 0.5,
							selected and UI.accentText or UI.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )
						draw.SimpleText( tostring( categoryEntry.settingCount ), "mc_config_meta", w - 11, h * 0.5,
							selected and UI.accentText or UI.textFaint, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER )
					end
					btn.DoClick = function()
						activeCategory = categoryEntry.id
						if search:GetValue() ~= "" then search:SetText( "" ) end
						searchQuery = ""
						rebuildRows( true )
					end
				end
			end
		end

		rebuildRows( true )
	end

	local function updateScopeHint()
		if activeScope == "client" then
			scopeHint:SetTextColor( UI.textDim )
			scopeHint:SetText( configText( "Changes apply to this client.", "修改只应用到当前客户端。" ) )
		elseif canEditScope( "server" ) then
			scopeHint:SetTextColor( UI.textDim )
			scopeHint:SetText( configText( "Server changes apply immediately.", "服务器设置修改后立即生效。" ) )
		else
			scopeHint:SetTextColor( UI.warn )
			scopeHint:SetText( configText( "Server settings are read-only without administrator access.", "没有管理员权限时，服务器设置仅可查看。" ) )
		end
	end

	for _, scopeName in ipairs( { "client", "server" } ) do
		local scope = scopeName
		local btn = vgui.Create( "DButton", scopeHolder )
		btn:Dock( LEFT )
		btn:SetWide( 190 )
		btn:SetText( "" )
		scopeButtons[scope] = btn
		btn.Paint = function( s, w, h )
			local selected = activeScope == scope
			if selected or s:IsHovered() then
				surface.SetDrawColor( selected and UI.contentHeader or UI.rowHover )
				surface.DrawRect( 0, 0, w, h )
			end
			if selected then
				surface.SetDrawColor( UI.accent )
				surface.DrawRect( 0, h - 3, w, 3 )
			end
			local label = scope == "client" and configText( "Client settings", "客户端设置" )
				or configText( "Server settings", "服务器设置" )
			draw.SimpleText( label, "mc_config_body", w * 0.5, h * 0.5 - 1,
				selected and UI.text or UI.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER )
		end
		btn.DoClick = function()
			if activeScope == scope then return end
			activeScope = scope
			activeCategory = nil
			searchQuery = ""
			search:SetText( "" )
			if activeScope == "server" then requestServerConfigValues() end
			updateScopeHint()
			rebuildCategories()
		end
	end

	search.OnChange = function( s )
		searchQuery = string.Trim( s:GetValue() or "" )
		rebuildRows( true )
	end

	updateScopeHint()
	rebuildCategories()
	MC.ConfigRefreshVisibility = function()
		if IsValid( fr ) then rebuildCategories() end
	end
	fr.OnRemove = function()
		if IsValid( restoreButton ) then restoreButton:Remove() end
		if MC.ConfigFrame == fr then MC.ConfigFrame = nil end
		MC.ConfigRefreshVisibility = nil
	end
end

net.Receive( "mc_config_values", function()
	local values = {}
	for _ = 1, net.ReadUInt( 12 ) do
		values[net.ReadString()] = net.ReadString()
	end

	MC.ConfigServerValues = values
	if not IsValid( MC.ConfigFrame ) then return end

	for name, controls in pairs( MC.ConfigControlRows or {} ) do
		local value = values[name]
		if value ~= nil then
			for _, control in ipairs( controls ) do
				if IsValid( control ) and control.MCSetValue then
					control:MCSetValue( value )
				end
			end
		end
	end
end )

-- Dynamic categories name a builder here; it runs each time rows are rebuilt.
MC.ConfigDynamicItems = MC.ConfigDynamicItems or {}
MC.ConfigDynamicItems.render_pack = function()
	return MC.RenderPackSettings and MC.RenderPackSettings.ConfigItems() or {}
end

-- A pack switch completes a few frames after selection; show its settings then.
hook.Add( "MCRenderPackSettingsChanged", "mc_config_ui", function()
	timer.Simple( 0, function()
		if IsValid( MC.ConfigFrame ) and MC.ConfigRefreshVisibility then MC.ConfigRefreshVisibility() end
	end )
end )

hook.Add( "MCRenderPackSettingChanged", "mc_config_ui", function( _, key, value )
	MC.RefreshConfigControlValue( "mc_render_pack_set " .. key, value )
end )

hook.Add( "MCRenderPackPresetChanged", "mc_config_ui", function( _, bulk )
	if bulk then
		for _, key in ipairs( MC.RenderPackSettings.Keys() ) do
			MC.RefreshConfigControlValue( "mc_render_pack_set " .. key, MC.RenderPackSettings.Get( key ), true )
		end
	end
	MC.RefreshConfigControlValue( "mc_render_pack_preset" )
end )

concommand.Add( "mc_config", function()
	MC.OpenConfigMenu()
end )

list.Set( "DesktopWindows", "mc_config", {
	title = "MC Config",
	icon = "mc/ui/config_grass.png",
	width = 1,
	height = 1,
	init = function( _, window )
		-- The configuration UI owns its frame; discard the sandbox placeholder.
		window:Remove()
		MC.OpenConfigMenu()
	end,
} )

if MC.RegisterLanguageChanged then
	MC.RegisterLanguageChanged( "mc_config_ui", function()
		if IsValid( MC.ConfigFrame ) then
			MC.OpenConfigMenu()
		end
	end )
end
