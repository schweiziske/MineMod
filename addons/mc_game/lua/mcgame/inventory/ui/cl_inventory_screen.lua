--[[----------------------------------------------------------------------------
    Vanilla-shaped player and creative inventory screens.

    Survival uses inventory.png at 176x166.  Creative uses the 195x136 tab
    backgrounds, 9x5 visible item window, original tab sprites and scrollbar.
    Survival player and crafting-table menus use the same 36 player slots plus
    the transient vanilla crafting grid/result slots.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local SURVIVAL_W, SURVIVAL_H = 176, 166
local CREATIVE_W, CREATIVE_H = 195, 136
local CREATIVE_COLS, CREATIVE_ROWS = 9, 5

local SURVIVAL_BACKGROUND = UI.GetGuiMaterial( "container/inventory" )
local CRAFTING_BACKGROUND = UI.GetGuiMaterial( "container/crafting_table" )
local CHEST_BACKGROUND = UI.GetGuiMaterial( "container/generic_54" )
local FURNACE_BACKGROUND = UI.GetGuiMaterial( "container/furnace" )
local BLAST_FURNACE_BACKGROUND = UI.GetGuiMaterial( "container/blast_furnace" )
local BREWING_BACKGROUND = UI.GetGuiMaterial( "container/brewing_stand" )
local ANVIL_BACKGROUND = UI.GetGuiMaterial( "container/anvil" )
local ENCHANTING_BACKGROUND = UI.GetGuiMaterial( "container/enchanting_table" )
local ANVIL_ERROR = UI.GetGuiMaterial( "sprites/container/anvil/error" )
local ANVIL_TEXT_FIELD = UI.GetGuiMaterial( "sprites/container/anvil/text_field" )
local ANVIL_TEXT_FIELD_DISABLED = UI.GetGuiMaterial( "sprites/container/anvil/text_field_disabled" )
local FURNACE_LIT = UI.GetGuiMaterial( "sprites/container/furnace/lit_progress" )
local FURNACE_BURN = UI.GetGuiMaterial( "sprites/container/furnace/burn_progress" )
local BREWING_FUEL = UI.GetGuiMaterial( "sprites/container/brewing_stand/fuel_length" )
local BREWING_PROGRESS = UI.GetGuiMaterial( "sprites/container/brewing_stand/brew_progress" )
local BREWING_BUBBLES = UI.GetGuiMaterial( "sprites/container/brewing_stand/bubbles" )
local BREWING_SLOT_FUEL = UI.GetGuiMaterial( "sprites/container/slot/brewing_fuel" )
local BREWING_SLOT_POTION = UI.GetGuiMaterial( "sprites/container/slot/potion" )
local ENCHANTING_SLOT_LAPIS = UI.GetGuiMaterial( "sprites/container/slot/lapis_lazuli" )
local ENCHANTING_OPTION = UI.GetGuiMaterial( "sprites/container/enchanting_table/enchantment_slot" )
local ENCHANTING_OPTION_HIGHLIGHTED = UI.GetGuiMaterial( "sprites/container/enchanting_table/enchantment_slot_highlighted" )
local ENCHANTING_OPTION_DISABLED = UI.GetGuiMaterial( "sprites/container/enchanting_table/enchantment_slot_disabled" )
local ENCHANTING_LEVEL = {
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_1" ),
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_2" ),
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_3" ),
}
local ENCHANTING_LEVEL_DISABLED = {
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_1_disabled" ),
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_2_disabled" ),
	UI.GetGuiMaterial( "sprites/container/enchanting_table/level_3_disabled" ),
}
local CREATIVE_ITEMS_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_items" )
local CREATIVE_SEARCH_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_item_search" )
local CREATIVE_INVENTORY_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_inventory" )
local SCROLLER = UI.GetGuiMaterial( "sprites/container/creative_inventory/scroller" )
local SCROLLER_DISABLED = UI.GetGuiMaterial( "sprites/container/creative_inventory/scroller_disabled" )

local function tabRows()
	local result = {}
	for _, source in ipairs( MC.GeneratedCreativeTabs or {} ) do
		if type( source ) == "table" and isstring( source.key ) then
			result[#result + 1] = {
				key = source.key,
				row = source.row == "bottom" and "bottom" or "top",
				column = math.Clamp( math.floor( tonumber( source.column ) or 0 ), 0, 6 ),
				title = tostring( source.title or source.key ),
				titleZH = tostring( source.titleZH or source.title or source.key ),
				titleKey = source.titleKey,
				icon = source.icon,
				items = type( source.items ) == "table" and source.items or {},
				alignedRight = ( tonumber( source.column ) or 0 ) >= 5,
			}
		end
	end
	return result
end

local function tabTitle( tab )
	if not tab then return "" end
	if MC.Language and MC.Language() == "zh_cn" then return tab.titleZH or tab.title end
	return tab.title
end

UI.CreativeTabs = tabRows()
UI.CreativeTabsByKey = {}
for _, tab in ipairs( UI.CreativeTabs ) do UI.CreativeTabsByKey[tab.key] = tab end

local function modifierDown( left, right )
	return input.IsKeyDown( left ) or input.IsKeyDown( right )
end

local NUMBER_KEYS = {
	[KEY_1] = 0, [KEY_2] = 1, [KEY_3] = 2,
	[KEY_4] = 3, [KEY_5] = 4, [KEY_6] = 5,
	[KEY_7] = 6, [KEY_8] = 7, [KEY_9] = 8,
}

local TAB = {}

function TAB:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
end

function TAB:Configure( screen, tab, scale )
	self.Screen, self.Tab, self.Scale = screen, tab, scale
	self:SetSize( 26 * scale, 32 * scale )
end

function TAB:Paint( w, h )
	if not self.Tab or not IsValid( self.Screen ) then return true end
	local selected = self.Screen.SelectedTabKey == self.Tab.key
	local row = self.Tab.row == "top" and "top" or "bottom"
	local state = selected and "selected" or "unselected"
	local index = self.Tab.column + 1
	local sprite = UI.GetGuiMaterial( "sprites/container/creative_inventory/tab_" .. row .. "_" .. state .. "_" .. tostring( index ) )
	UI.WithPointFiltering( function() UI.DrawTexture( sprite, 0, 0, w, h ) end )
	local stack = self.IconStack
	if stack == nil and self.Tab.icon then
		stack = MC.NewItemStack( self.Tab.icon, 1 )
		self.IconStack = stack or false
	end
	if stack and stack ~= false then
		local iconY = ( row == "top" and 9 or 7 ) * self.Scale
		UI.ItemRenderer.DrawStack( stack, 5 * self.Scale, iconY, 16 * self.Scale, { scale = self.Scale, drawCount = false } )
	end
	return true
end

function TAB:DoClick()
	if IsValid( self.Screen ) then
		UI.PlayButtonSound()
		self.Screen:SelectCreativeTab( self.Tab.key )
	end
end

function TAB:OnCursorEntered()
	if IsValid( self.Screen ) then self.Screen.HoveredTab = self.Tab end
end

function TAB:OnCursorExited()
	if IsValid( self.Screen ) and self.Screen.HoveredTab == self.Tab then self.Screen.HoveredTab = nil end
end

vgui.Register( "MCInventoryCreativeTab", TAB, "DButton" )

local SCROLL = {}

function SCROLL:Init()
	self:SetMouseInputEnabled( true )
	self:SetCursor( "hand" )
end

function SCROLL:SetScreen( screen ) self.Screen = screen end

function SCROLL:UpdateFromMouse()
	if not IsValid( self.Screen ) then return end
	local _, y = self:CursorPos()
	self.Screen:SetScrollFraction( ( y - 7.5 * self.Screen.Scale ) / ( 95 * self.Screen.Scale ) )
end

function SCROLL:OnMousePressed( code )
	if code ~= MOUSE_LEFT then return end
	self.Dragging = true
	self:MouseCapture( true )
	self:UpdateFromMouse()
end

function SCROLL:OnMouseReleased( code )
	if code ~= MOUSE_LEFT then return end
	self.Dragging = false
	self:MouseCapture( false )
end

function SCROLL:Think()
	if self.Dragging and input.IsMouseDown( MOUSE_LEFT ) then self:UpdateFromMouse()
	elseif self.Dragging then self.Dragging = false self:MouseCapture( false ) end
end

function SCROLL:OnMouseWheeled( delta )
	if IsValid( self.Screen ) then return self.Screen:OnMouseWheeled( delta ) end
end

function SCROLL:Paint( w, h )
	if not IsValid( self.Screen ) then return true end
	local maxRows = self.Screen:MaxScrollRows()
	local fraction = maxRows > 0 and self.Screen.ScrollRow / maxRows or 0
	local knob = maxRows > 0 and SCROLLER or SCROLLER_DISABLED
	local y = math.floor( fraction * 95 * self.Screen.Scale + 0.5 )
	UI.WithPointFiltering( function() UI.DrawTexture( knob, 0, y, 12 * self.Screen.Scale, 15 * self.Screen.Scale ) end )
	return true
end

vgui.Register( "MCInventoryScrollbar", SCROLL, "DPanel" )

local ENCHANTING_BUTTON = {}

function ENCHANTING_BUTTON:Init()
	self:SetText( "" )
	self:SetCursor( "arrow" )
end

function ENCHANTING_BUTTON:Configure( screen, optionIndex, scale )
	self.Screen, self.OptionIndex, self.Scale = screen, optionIndex, scale
	self:SetSize( 108 * scale, 19 * scale )
end

function ENCHANTING_BUTTON:OptionState()
	if not IsValid( self.Screen ) then return nil end
	local state = self.Screen.EnchantingState or self.Screen.Session and self.Screen.Session.enchantingState
	return state and state.options and state.options[( self.OptionIndex or 0 ) + 1] or nil
end

function ENCHANTING_BUTTON:Paint( w, h )
	local option = self:OptionState()
	local scale = math.max( 1, tonumber( self.Scale ) or 1 )
	local pending = MC.InventoryMenuButtonPending and MC.InventoryMenuButtonPending() or false
	local enabled = option and option.available == true and not pending
	local cost = math.max( 0, math.floor( tonumber( option and option.cost ) or 0 ) )
	local background = cost <= 0 and ENCHANTING_OPTION_DISABLED
		or enabled and self:IsHovered() and ENCHANTING_OPTION_HIGHLIGHTED
		or enabled and ENCHANTING_OPTION or ENCHANTING_OPTION_DISABLED
	self:SetCursor( enabled and "hand" or "arrow" )
	UI.WithPointFiltering( function()
		UI.DrawTexture( background, 0, 0, w, h )
		if cost > 0 then
			local levels = enabled and ENCHANTING_LEVEL or ENCHANTING_LEVEL_DISABLED
			UI.DrawTexture( levels[( self.OptionIndex or 0 ) + 1], scale, scale, 16 * scale, 16 * scale )
		end
	end )
	if cost <= 0 then return true end
	local label = tostring( option and option.displayName or "" )
	local textColor = enabled and ( self:IsHovered() and Color( 255, 255, 128 ) or Color( 104, 94, 74 ) )
		or Color( 52, 47, 37 )
	local costColor = enabled and Color( 128, 255, 32 ) or Color( 64, 127, 16 )
	local costWidth = UI.MeasureText( tostring( cost ), scale )
	local textWidth = math.max( 0, 86 * scale - costWidth )
	local screenX, screenY = self:LocalToScreen( 0, 0 )
	render.SetScissorRect( screenX + 20 * scale, screenY,
		screenX + 20 * scale + textWidth, screenY + h, true )
	UI.DrawText( label, 20 * scale, 2 * scale, scale, textColor, TEXT_ALIGN_LEFT, false, TEXT_ALIGN_TOP, "alt" )
	render.SetScissorRect( 0, 0, 0, 0, false )
	UI.DrawText( tostring( cost ), 106 * scale, 9 * scale, scale, costColor, TEXT_ALIGN_RIGHT, false )
	return true
end

function ENCHANTING_BUTTON:DoClick()
	local option = self:OptionState()
	if not option or option.available ~= true then return end
	local ok, errorCode = MC.RequestEnchantingOption( self.OptionIndex )
	if ok then
		UI.PlayButtonSound()
	elseif IsValid( self.Screen ) then
		self.Screen.ErrorText = tostring( errorCode or "enchantment_unavailable" )
		self.Screen.ErrorUntil = RealTime() + 2.5
	end
end

function ENCHANTING_BUTTON:OnCursorEntered()
	if IsValid( self.Screen ) then self.Screen.HoveredEnchantingOption = self.OptionIndex end
end

function ENCHANTING_BUTTON:OnCursorExited()
	if IsValid( self.Screen ) and self.Screen.HoveredEnchantingOption == self.OptionIndex then
		self.Screen.HoveredEnchantingOption = nil
	end
end

vgui.Register( "MCEnchantingOption", ENCHANTING_BUTTON, "DButton" )

local PANEL = {}

function PANEL:Init()
	self:SetSize( ScrW(), ScrH() )
	self:SetPos( 0, 0 )
	self:SetMouseInputEnabled( true )
	self:SetKeyboardInputEnabled( true )
	self:MakePopup()
	self.Scale = UI.GuiScale()
	self.ContentW, self.ContentH = SURVIVAL_W, SURVIVAL_H
	local initialOffsetX, initialOffsetY = 0, 0
	if UI.UIOffset then initialOffsetX, initialOffsetY = UI.UIOffset() end
	self.Left = math.floor( ( ScrW() - self.ContentW * self.Scale ) * 0.5 + initialOffsetX )
	self.Top = math.floor( ( ScrH() - self.ContentH * self.Scale ) * 0.5 + initialOffsetY )
	self.BaseLeft = self.Left
	self.ChestRows = 1
	self.ScrollRow = 0
	self.SlotPanels = {}
	self.VisibleSlotCount = 0
	self.InventorySlotViews = {}
	self.MenuSlotViews = {}
	self.CurrentItems = {}
	self.SelectedTabKey = UI.LastCreativeTab or "building_blocks"
	self.RecipeBookOpen = false
	self.RecipeBookToggle = vgui.Create( "MCRecipeBookToggle", self )
	self.RecipeBookToggle:Configure( self, self.Scale )
	self.RecipeBook = UI.CreateRecipeBook and UI.CreateRecipeBook( self ) or nil

	self.SearchEntry = vgui.Create( "DTextEntry", self )
	self.SearchEntry:SetDrawBackground( false )
	self.SearchEntry:SetTextColor( Color( 45, 45, 45, 255 ) )
	self.SearchEntry:SetHighlightColor( Color( 120, 150, 190, 120 ) )
	self.SearchEntry:SetCursorColor( Color( 45, 45, 45, 255 ) )
	self.SearchEntry:SetUpdateOnType( true )
	self.SearchEntry:SetVisible( false )
	self.SearchEntry:SetZPos( 20 )
	self.SearchEntry.MCBitmapScale = self.Scale
	UI.ConfigureBitmapTextEntry( self.SearchEntry, { color = Color( 45, 45, 45, 255 ), padding = 1 } )
	self.SearchEntry.OnChange = function( entry )
		if not IsValid( self ) then return end
		local generation = ( self.SearchGeneration or 0 ) + 1
		self.SearchGeneration = generation
		timer.Simple( 0.08, function()
			if not IsValid( self ) or self.SearchGeneration ~= generation then return end
			self.ScrollRow = 0
			self:RefreshCreativeItems()
			self:LayoutVisibleSlots()
		end )
	end

	self.AnvilEntry = vgui.Create( "DTextEntry", self )
	self.AnvilEntry:SetDrawBackground( false )
	self.AnvilEntry:SetTextColor( Color( 45, 45, 45, 255 ) )
	self.AnvilEntry:SetHighlightColor( Color( 120, 150, 190, 120 ) )
	self.AnvilEntry:SetCursorColor( Color( 45, 45, 45, 255 ) )
	self.AnvilEntry:SetUpdateOnType( true )
	self.AnvilEntry:SetVisible( false )
	self.AnvilEntry:SetZPos( 30 )
	self.AnvilEntry.MCBitmapScale = self.Scale
	UI.ConfigureBitmapTextEntry( self.AnvilEntry, { color = Color( 45, 45, 45, 255 ), padding = 1 } )
	self.AnvilEntry.OnChange = function( entry )
		if not IsValid( self ) or self.ApplyingAnvilState or not self.Anvil then return end
		local value = entry:GetValue() or ""
		local filtered, errorCode = MC.AnvilValidateName and MC.AnvilValidateName( value ) or value
		if not filtered then
			self.AnvilLocalError = errorCode or "invalid_name"
			return
		end
		self.AnvilLocalError = nil
		if filtered ~= value then
			self.ApplyingAnvilState = true
			entry:SetText( filtered )
			entry:SetCaretPos( utf8 and utf8.len and ( utf8.len( filtered ) or #filtered ) or #filtered )
			self.ApplyingAnvilState = false
		end
		-- Send every accepted edit immediately. Reliable net ordering then puts
		-- the authoritative rename ahead of a result-slot click made afterwards.
		local ok, err = MC.RequestAnvilRename( entry:GetValue() or "" )
		if not ok then self.AnvilLocalError = err or "anvil_rename_failed" end
	end

	self.EnchantingButtons = {}
	for optionIndex = 0, 2 do
		local button = vgui.Create( "MCEnchantingOption", self )
		button:Configure( self, optionIndex, self.Scale )
		button:SetVisible( false )
		button:SetZPos( 30 )
		self.EnchantingButtons[optionIndex + 1] = button
	end

	self.Scrollbar = vgui.Create( "MCInventoryScrollbar", self )
	self.Scrollbar:SetScreen( self )
	self.Scrollbar:SetVisible( false )
	self.Scrollbar:SetZPos( 20 )

	self.PlayerPreview = vgui.Create( "DModelPanel", self )
	self.PlayerPreview:SetMouseInputEnabled( false )
	self.PlayerPreview:SetAnimated( false )
	self.PlayerPreview:SetFOV( 31 )
	self.PlayerPreview:SetVisible( false )
	self.PlayerPreview:SetZPos( 20 )
	self.PlayerPreview.LayoutEntity = function( panel, entity )
		if not IsValid( entity ) then return end
		entity:SetAngles( Angle( 0, 10, 0 ) )
	end
	if util and util.IsValidModel and util.IsValidModel( "models/player/kleiner.mdl" ) then
		self.PlayerPreview:SetModel( "models/player/kleiner.mdl" )
	end

	self.TabButtons = {}
	for _, tab in ipairs( UI.CreativeTabs ) do
		local button = vgui.Create( "MCInventoryCreativeTab", self )
		button:Configure( self, tab, self.Scale )
		button:SetVisible( false )
		button:SetZPos( 0 )
		self.TabButtons[#self.TabButtons + 1] = button
	end

	self.ContentLayer = vgui.Create( "DPanel", self )
	self.ContentLayer:SetMouseInputEnabled( false )
	self.ContentLayer:SetKeyboardInputEnabled( false )
	self.ContentLayer:SetZPos( 10 )
	self.ContentLayer.Paint = function( _, w, h )
		if IsValid( self ) then return self:PaintContent( w, h ) end
	end

	hook.Add( "MC.InventoryChanged", self, function( panel, changed ) panel:RefreshInventorySlots( changed ) end )
	hook.Add( "MC.EquipmentChanged", self, function( panel ) panel:RefreshMenuSlots() end )
	hook.Add( "MC.InventoryMenuChanged", self, function( panel, changed ) panel:RefreshMenuSlots( changed ) end )
	hook.Add( "MC.InventorySnapshot", self, function( panel, state ) panel:ApplyLatestClientState( state ) end )
	hook.Add( "MC.InventorySelectionChanged", self, function( panel ) panel:RefreshInventorySlots() end )
	hook.Add( "MC.InventoryCursorChanged", self, function( panel ) panel:InvalidateLayout() end )
	hook.Add( "MC.InventoryActionResult", self, function( panel, _, accepted, errorCode )
		if accepted then return end
		panel.ErrorText = tostring( errorCode ~= "" and errorCode or "inventory_action_rejected" )
		panel.ErrorUntil = RealTime() + 2.5
	end )
	hook.Add( "MC.CreativeStackProvidersChanged", self, function( panel )
		if not panel.Creative then return end
		panel.ScrollRow = 0
		panel:RefreshCreativeItems()
		panel:LayoutVisibleSlots()
	end )
	hook.Add( "MCAnvilStateChanged", self, function( panel, anvilState ) panel:ApplyAnvilState( anvilState ) end )
	hook.Add( "MCEnchantingStateChanged", self, function( panel, enchantingState ) panel:ApplyEnchantingState( enchantingState ) end )
	hook.Add( "OnScreenSizeChanged", self, function( panel ) panel:Reflow() end )
end

function PANEL:Configure( session, state )
	self.Session = session
	self.State = state or MC.ClientInventory
	self.MenuKind = session and session.kind or "player"
	self.Chest = self.MenuKind == "chest"
	self.CraftingTable = self.MenuKind == "crafting_table"
	self.Furnace = self.MenuKind == "furnace" or self.MenuKind == "blast_furnace"
	self.BlastFurnace = self.MenuKind == "blast_furnace"
	self.Brewing = self.MenuKind == "brewing_stand"
	self.Anvil = self.MenuKind == "anvil"
	self.Enchanting = self.MenuKind == "enchanting_table"
	self.Crafting = session and session.crafting == true
		or self.State and self.State.menu and self.State.menu.crafting == true or false
	self.Creative = session and session.creative == true
	if not self.Crafting and not self.Furnace or self.Creative then self.RecipeBookOpen = false end
	if IsValid( self.RecipeBook ) then
		self.RecipeBook:Configure( self )
		self.RecipeBook:SetVisible( self.RecipeBookOpen and ( self.Crafting or self.Furnace ) and not self.Creative )
	end
	if self.Creative and not UI.CreativeTabsByKey[self.SelectedTabKey] then self.SelectedTabKey = "building_blocks" end
	self.ScrollRow = 0
	self:RefreshCreativeItems()
	self:Reflow()
	self:RefreshInventorySlots()
	self:ApplyAnvilState( session and session.anvilState )
	self:ApplyEnchantingState( session and session.enchantingState )
	self.ObservedStateMenu = self.State and self.State.menu or nil
	self.ObservedStateReady = self.State and self.State.ready == true or false
	self.ConfigureGeneration = ( self.ConfigureGeneration or 0 ) + 1
	local generation = self.ConfigureGeneration
	timer.Simple( 0, function()
		if not IsValid( self ) or self.ConfigureGeneration ~= generation then return end
		self:ApplyLatestClientState( MC.ClientInventory )
	end )
	self:RequestFocus()
end

function PANEL:ApplyEnchantingState( enchantingState )
	if not self.Enchanting then return end
	self.EnchantingState = enchantingState or self.Session and self.Session.enchantingState or { options = {} }
	for _, button in ipairs( self.EnchantingButtons or {} ) do
		if IsValid( button ) then button:InvalidateLayout( true ) end
	end
end

function PANEL:ApplyAnvilState( anvilState )
	if not self.Anvil or not IsValid( self.AnvilEntry ) then return end
	anvilState = anvilState or self.Session and self.Session.anvilState or {}
	self.AnvilState = anvilState
	self.AnvilLocalError = nil
	local left = MC.GetClientMenuStack and MC.GetClientMenuStack( 0 ) or nil
	local display = tostring( anvilState.renameText or "" )
	if anvilState.renameExplicit ~= true and not MC.IsEmptyItemStack( left ) then
		display = UI.ItemRenderer and UI.ItemRenderer.DisplayName and UI.ItemRenderer.DisplayName( left ) or display
	end
	self.ApplyingAnvilState = true
	self.AnvilEntry:SetText( display )
	self.AnvilEntry:SetCaretPos( utf8 and utf8.len and ( utf8.len( display ) or #display ) or #display )
	self.ApplyingAnvilState = false
	local editable = not MC.IsEmptyItemStack( left )
	self.AnvilEntry.MCBitmapColor = editable and Color( 45, 45, 45, 255 ) or Color( 120, 120, 120, 255 )
	self.AnvilEntry:SetEditable( editable )
	self.AnvilEntry:SetEnabled( editable )
end

function PANEL:ApplyLatestClientState( state )
	if not IsValid( self ) then return end
	self.State = state or MC.ClientInventory or self.State
	self.ObservedStateMenu = self.State and self.State.menu or nil
	self.ObservedStateReady = self.State and self.State.ready == true or false
	if self.Creative then self:RefreshCreativeItems() end
	self:LayoutVisibleSlots()
	self:LayoutSpecialControls()
	if self.Anvil then self:ApplyAnvilState( self.Session and self.Session.anvilState ) end
	if self.Enchanting then self:ApplyEnchantingState( self.Session and self.Session.enchantingState ) end
end

function PANEL:ConfigurePlayerPreview()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return end
	local model = ply:GetModel()
	if not isstring( model ) or model == "" then return end
	if util and util.IsValidModel and not util.IsValidModel( model ) then return end
	if not IsValid( self.PlayerPreview.Entity ) or self.PlayerPreview.Entity:GetModel() ~= model then
		self.PlayerPreview:SetModel( model )
	end
	local entity = self.PlayerPreview.Entity
	if not IsValid( entity ) then return end
	entity:SetSkin( ply:GetSkin() or 0 )
	for index = 0, ( ply:GetNumBodyGroups() or 0 ) - 1 do entity:SetBodygroup( index, ply:GetBodygroup( index ) ) end
	local minimum, maximum = entity:GetRenderBounds()
	local center = ( minimum + maximum ) * 0.5
	local height = math.max( 48, maximum.z - minimum.z )
	self.PlayerPreview:SetLookAt( center + Vector( 0, 0, height * 0.05 ) )
	self.PlayerPreview:SetCamPos( center + Vector( height * 1.25, 0, height * 0.08 ) )
end

function PANEL:Reflow()
	if not IsValid( self ) then return end
	self:SetSize( ScrW(), ScrH() )
	self.Scale = UI.GuiScale()
	local offsetX, offsetY = 0, 0
	if UI.UIOffset then offsetX, offsetY = UI.UIOffset() end
	if self.Chest then
		self.ChestRows = math.Clamp( math.floor( tonumber( self.Session and self.Session.chestSlots ) or 27 ) / 9, 1, 6 )
		self.ContentW, self.ContentH = 176, 114 + self.ChestRows * 18
		self.Left = math.floor( ( ScrW() - self.ContentW * self.Scale ) * 0.5 + offsetX )
		self.Top = math.floor( ( ScrH() - self.ContentH * self.Scale ) * 0.5 + offsetY )
	elseif self.Furnace or self.Brewing or self.Anvil or self.Enchanting then
		self.ContentW, self.ContentH = SURVIVAL_W, SURVIVAL_H
		self.Left = math.floor( ( ScrW() - SURVIVAL_W * self.Scale ) * 0.5 + offsetX )
		self.Top = math.floor( ( ScrH() - SURVIVAL_H * self.Scale ) * 0.5 + offsetY )
	elseif self.Creative then
		local totalHeight = ( CREATIVE_H + 56 ) * self.Scale
		self.ContentW, self.ContentH = CREATIVE_W, CREATIVE_H
		self.Left = math.floor( ( ScrW() - CREATIVE_W * self.Scale ) * 0.5 + offsetX )
		self.Top = math.floor( ( ScrH() - totalHeight ) * 0.5 + 28 * self.Scale + offsetY )
	else
		self.ContentW, self.ContentH = SURVIVAL_W, SURVIVAL_H
		self.Left = math.floor( ( ScrW() - SURVIVAL_W * self.Scale ) * 0.5 + offsetX )
		self.Top = math.floor( ( ScrH() - SURVIVAL_H * self.Scale ) * 0.5 + offsetY )
	end
	self.BaseLeft = self.Left
	if self.RecipeBookOpen and ( self.Crafting or self.Furnace ) and not self.Creative then
		local bookSpan = 149 + ( UI.RecipeBookLeftMargin or 30 )
		local combined = ( self.ContentW + bookSpan ) * self.Scale
		if ScrW() >= combined + 8 * self.Scale then
			self.Left = self.BaseLeft + math.floor( bookSpan * 0.5 ) * self.Scale
		end
	end
	self.SearchEntry.MCBitmapScale = self.Scale
	self.AnvilEntry.MCBitmapScale = self.Scale
	self.ContentLayer:SetSize( ScrW(), ScrH() )
	self:LayoutTabs()
	self:LayoutVisibleSlots()
	self:LayoutSpecialControls()
	self:LayoutRecipeBook()
end

function PANEL:LayoutTabs()
	for index, button in ipairs( self.TabButtons ) do
		local tab = UI.CreativeTabs[index]
		button:Configure( self, tab, self.Scale )
		button:SetVisible( self.Creative )
		button:SetZPos( tab.key == self.SelectedTabKey and 15 or 0 )
		if self.Creative then
			-- CreativeModeInventoryScreen.getTabX: right-aligned tabs use the
			-- same integer formula as Java. A fractional compensation here lands
			-- the selected tab between framebuffer pixels and opens a one-pixel seam.
			local x = tab.alignedRight and CREATIVE_W - 27 * ( 7 - tab.column ) + 1 or 27 * tab.column
			local y = tab.row == "top" and -28 or CREATIVE_H - 4
			button:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
		end
	end
end

function PANEL:AcquireSlot( ordinal )
	local slot = self.SlotPanels[ordinal]
	if not IsValid( slot ) then
		slot = vgui.Create( "MCInventorySlot", self )
		slot:SetScreen( self )
		self.SlotPanels[ordinal] = slot
	end
	slot:SetScale( self.Scale )
	slot:SetZPos( 20 )
	slot:SetVisible( true )
	self.VisibleSlotCount = math.max( self.VisibleSlotCount, ordinal )
	return slot
end

function PANEL:BeginSlotLayout()
	self.VisibleSlotCount = 0
	self.InventorySlotViews = {}
	self.MenuSlotViews = {}
end

function PANEL:FinishSlotLayout()
	for index = self.VisibleSlotCount + 1, #self.SlotPanels do
		if IsValid( self.SlotPanels[index] ) then self.SlotPanels[index]:SetVisible( false ) end
	end
end

function PANEL:PlaceInventorySlot( ordinal, inventoryIndex, x, y )
	local slot = self:AcquireSlot( ordinal )
	slot:SetInventorySlot( inventoryIndex, inventoryIndex )
	slot:SetPos( self.Left + x * self.Scale - self.Scale, self.Top + y * self.Scale - self.Scale )
	self.InventorySlotViews[inventoryIndex] = self.InventorySlotViews[inventoryIndex] or {}
	self.InventorySlotViews[inventoryIndex][#self.InventorySlotViews[inventoryIndex] + 1] = slot
	return ordinal + 1
end

function PANEL:PlaceMenuSlot( ordinal, menuIndex, playerIndex, x, y, role )
	local slot = self:AcquireSlot( ordinal )
	slot:SetMenuSlot( menuIndex, playerIndex, role )
	slot:SetPos( self.Left + x * self.Scale - self.Scale, self.Top + y * self.Scale - self.Scale )
	self.MenuSlotViews[menuIndex] = self.MenuSlotViews[menuIndex] or {}
	self.MenuSlotViews[menuIndex][#self.MenuSlotViews[menuIndex] + 1] = slot
	if playerIndex ~= nil then
		self.InventorySlotViews[playerIndex] = self.InventorySlotViews[playerIndex] or {}
		self.InventorySlotViews[playerIndex][#self.InventorySlotViews[playerIndex] + 1] = slot
	end
	return ordinal + 1
end

function PANEL:PlaceCreativeSlot( ordinal, item, x, y )
	local slot = self:AcquireSlot( ordinal )
	slot:SetCreativeItem( item )
	slot:SetPos( self.Left + x * self.Scale - self.Scale, self.Top + y * self.Scale - self.Scale )
	return ordinal + 1
end

function PANEL:PlaceDestroySlot( ordinal, x, y )
	local slot = self:AcquireSlot( ordinal )
	slot:SetDestroySlot()
	slot:SetPos( self.Left + x * self.Scale - self.Scale, self.Top + y * self.Scale - self.Scale )
	return ordinal + 1
end

function PANEL:LayoutVisibleSlots()
	if not self.Left then return end
	self:BeginSlotLayout()
	local ordinal = 1
	if self.Chest then
		local chestSlots = math.floor( tonumber( self.Session and self.Session.chestSlots ) or 27 )
		local rows = math.max( 1, math.floor( chestSlots / 9 ) )
		for index = 0, chestSlots - 1 do
			ordinal = self:PlaceMenuSlot( ordinal, index, nil, 8 + index % 9 * 18, 18 + math.floor( index / 9 ) * 18 )
		end
		local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or chestSlots )
		local inventoryTop = 31 + rows * 18
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
				8 + position % 9 * 18, inventoryTop + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, inventoryTop + 58 )
		end
	elseif self.Enchanting then
		ordinal = self:PlaceMenuSlot( ordinal, 0, nil, 15, 47, "input" )
		ordinal = self:PlaceMenuSlot( ordinal, 1, nil, 35, 47, "lapis" )
		local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or 2 )
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
				8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, 142 )
		end
	elseif self.Anvil then
		ordinal = self:PlaceMenuSlot( ordinal, 0, nil, 27, 47, "input" )
		ordinal = self:PlaceMenuSlot( ordinal, 1, nil, 76, 47, "input" )
		ordinal = self:PlaceMenuSlot( ordinal, 2, nil, 134, 47, "result" )
		local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or 3 )
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
				8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, 142 )
		end
	elseif self.Brewing then
		ordinal = self:PlaceMenuSlot( ordinal, 0, nil, 56, 51, "bottle" )
		ordinal = self:PlaceMenuSlot( ordinal, 1, nil, 79, 58, "bottle" )
		ordinal = self:PlaceMenuSlot( ordinal, 2, nil, 102, 51, "bottle" )
		ordinal = self:PlaceMenuSlot( ordinal, 3, nil, 79, 17, "ingredient" )
		ordinal = self:PlaceMenuSlot( ordinal, 4, nil, 17, 17, "fuel" )
		local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or 5 )
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
				8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, 142 )
		end
	elseif self.Furnace then
		ordinal = self:PlaceMenuSlot( ordinal, 0, nil, 56, 17, "input" )
		ordinal = self:PlaceMenuSlot( ordinal, 1, nil, 56, 53, "fuel" )
		ordinal = self:PlaceMenuSlot( ordinal, 2, nil, 116, 35, "result" )
		local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or 3 )
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
				8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do
			ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, 142 )
		end
	elseif self.Crafting and not self.Creative then
		local width = math.Clamp( math.floor( tonumber( self.Session and self.Session.craftingWidth ) or ( self.CraftingTable and 3 or 2 ) ), 1, 3 )
		local height = math.Clamp( math.floor( tonumber( self.Session and self.Session.craftingHeight ) or width ), 1, 3 )
		local resultSlot = math.floor( tonumber( self.Session and self.Session.resultSlot ) or 0 )
		local inputStartX, inputStartY, resultX, resultY
		if self.CraftingTable then
			inputStartX, inputStartY, resultX, resultY = 30, 17, 124, 35
		else
			inputStartX, inputStartY, resultX, resultY = 98, 18, 154, 28
		end
		ordinal = self:PlaceMenuSlot( ordinal, resultSlot, nil, resultX, resultY, "result" )
		for index = 0, width * height - 1 do
			ordinal = self:PlaceMenuSlot( ordinal, index + 1, nil,
				inputStartX + index % width * 18, inputStartY + math.floor( index / width ) * 18, "input" )
		end
		if not self.CraftingTable and self.MenuKind == "player" then
			for index, equipment in ipairs( {
				{ slot = "head", menu = MC.EquipmentMenuSlots.head },
				{ slot = "chest", menu = MC.EquipmentMenuSlots.chest },
				{ slot = "legs", menu = MC.EquipmentMenuSlots.legs },
				{ slot = "feet", menu = MC.EquipmentMenuSlots.feet },
			} ) do
				ordinal = self:PlaceMenuSlot( ordinal, equipment.menu, nil, 8, 8 + ( index - 1 ) * 18, "equipment" )
			end
			ordinal = self:PlaceMenuSlot( ordinal, MC.EquipmentMenuSlots.offhand, nil, 77, 62, "equipment" )
			for index = 9, 35 do
				local position = index - 9
				ordinal = self:PlaceMenuSlot( ordinal, index, index,
					8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
			end
			for index = 0, 8 do
				ordinal = self:PlaceMenuSlot( ordinal, 36 + index, index, 8 + index * 18, 142 )
			end
		else
			local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or ( width * height + 1 ) )
			for index = 9, 35 do
				local position = index - 9
				ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index,
					8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
			end
			for index = 0, 8 do
				ordinal = self:PlaceMenuSlot( ordinal, playerOffset + index, index, 8 + index * 18, 142 )
			end
		end
	elseif not self.Creative then
		for index = 9, 35 do
			local position = index - 9
			ordinal = self:PlaceInventorySlot( ordinal, index, 8 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
		end
		for index = 0, 8 do ordinal = self:PlaceInventorySlot( ordinal, index, 8 + index * 18, 142 ) end
	else
		local tab = UI.CreativeTabsByKey[self.SelectedTabKey]
		if tab and tab.key == "inventory" then
			local creativeEquipment = MC.CreativeEquipmentMenuSlots or {}
			ordinal = self:PlaceMenuSlot( ordinal, creativeEquipment.head or 36, nil, 54, 6, "equipment" )
			ordinal = self:PlaceMenuSlot( ordinal, creativeEquipment.chest or 37, nil, 54, 33, "equipment" )
			ordinal = self:PlaceMenuSlot( ordinal, creativeEquipment.legs or 38, nil, 108, 6, "equipment" )
			ordinal = self:PlaceMenuSlot( ordinal, creativeEquipment.feet or 39, nil, 108, 33, "equipment" )
			ordinal = self:PlaceMenuSlot( ordinal, creativeEquipment.offhand or 40, nil, 35, 20, "equipment" )
			for index = 9, 35 do
				local position = index - 9
				ordinal = self:PlaceInventorySlot( ordinal, index, 9 + position % 9 * 18, 54 + math.floor( position / 9 ) * 18 )
			end
			for index = 0, 8 do ordinal = self:PlaceInventorySlot( ordinal, index, 9 + index * 18, 112 ) end
			ordinal = self:PlaceDestroySlot( ordinal, 173, 112 )
		else
			local first = self.ScrollRow * CREATIVE_COLS + 1
			for visible = 0, CREATIVE_COLS * CREATIVE_ROWS - 1 do
				local item = self.CurrentItems[first + visible]
				if item then
					ordinal = self:PlaceCreativeSlot( ordinal, item, 9 + visible % CREATIVE_COLS * 18, 18 + math.floor( visible / CREATIVE_COLS ) * 18 )
				end
			end
			for index = 0, 8 do ordinal = self:PlaceInventorySlot( ordinal, index, 9 + index * 18, 112 ) end
		end
	end
	self.VisibleSlotCount = ordinal - 1
	self:FinishSlotLayout()
end

function PANEL:LayoutSpecialControls()
	if not self.Left then return end
	local tab = self.Creative and UI.CreativeTabsByKey[self.SelectedTabKey] or nil
	local search = tab and tab.key == "search"
	if IsValid( self.SearchEntry ) then self.SearchEntry:SetVisible( search == true ) end
	if search and IsValid( self.SearchEntry ) then
		self.SearchEntry:SetPos( self.Left + 82 * self.Scale, self.Top + 6 * self.Scale )
		self.SearchEntry:SetSize( 80 * self.Scale, 10 * self.Scale )
		self.SearchEntry:RequestFocus()
	end
	local scroll = self.Creative and tab and tab.key ~= "inventory" and self:MaxScrollRows() > 0
	if IsValid( self.Scrollbar ) then self.Scrollbar:SetVisible( scroll == true ) end
	if scroll and IsValid( self.Scrollbar ) then
		self.Scrollbar:SetPos( self.Left + 175 * self.Scale, self.Top + 18 * self.Scale )
		self.Scrollbar:SetSize( 12 * self.Scale, 112 * self.Scale )
	end
	if IsValid( self.AnvilEntry ) then self.AnvilEntry:SetVisible( self.Anvil == true ) end
	if self.Anvil and IsValid( self.AnvilEntry ) then
		self.AnvilEntry:SetPos( self.Left + 62 * self.Scale, self.Top + 23 * self.Scale )
		self.AnvilEntry:SetSize( 103 * self.Scale, 13 * self.Scale )
	end
	for optionIndex, button in ipairs( self.EnchantingButtons or {} ) do
		if IsValid( button ) then
			button:SetVisible( self.Enchanting == true )
			if self.Enchanting then
				button:Configure( self, optionIndex - 1, self.Scale )
				button:SetPos( self.Left + 60 * self.Scale, self.Top + ( 14 + ( optionIndex - 1 ) * 19 ) * self.Scale )
			end
		end
	end
	local preview = not self.Chest and not self.Furnace and not self.Brewing and not self.Anvil and not self.Enchanting and not self.CraftingTable
		and ( not self.Creative or tab and tab.key == "inventory" )
	if IsValid( self.PlayerPreview ) then self.PlayerPreview:SetVisible( preview == true ) end
	if preview and IsValid( self.PlayerPreview ) then
		if self.Creative then
			self.PlayerPreview:SetPos( self.Left + 73 * self.Scale, self.Top + 6 * self.Scale )
			self.PlayerPreview:SetSize( 32 * self.Scale, 43 * self.Scale )
		else
			self.PlayerPreview:SetPos( self.Left + 26 * self.Scale, self.Top + 8 * self.Scale )
			self.PlayerPreview:SetSize( 49 * self.Scale, 70 * self.Scale )
		end
		self:ConfigurePlayerPreview()
	end
end

function PANEL:LayoutRecipeBook()
	if not IsValid( self.RecipeBookToggle ) then return end
	local enabled = ( self.Crafting or self.Furnace ) and not self.Creative and not self.Chest
	self.RecipeBookToggle:SetVisible( enabled )
	if not enabled then
		if IsValid( self.RecipeBook ) then self.RecipeBook:SetVisible( false ) end
		return
	end
	self.RecipeBookToggle:Configure( self, self.Scale )
	local toggleY = self.CraftingTable and 31 or self.Furnace and 35 or 60
	self.RecipeBookToggle:SetPos( self.Left + ( self.CraftingTable and 5 or self.Furnace and 20 or 104 ) * self.Scale,
		self.Top + toggleY * self.Scale )
	self.RecipeBookToggle:MoveToFront()
	if IsValid( self.RecipeBook ) then
		local bookX = self.Left - 149 * self.Scale
		local minimumBookX = ( ( UI.RecipeBookLeftMargin or 30 ) + 2 ) * self.Scale
		if bookX < minimumBookX then bookX = minimumBookX end
		self.RecipeBook:SetGeometry( bookX, self.Top, self.Scale )
		self.RecipeBook:SetVisible( self.RecipeBookOpen )
		if self.RecipeBookOpen then self.RecipeBook:MoveToFront() end
	end
end

function PANEL:SetRecipeBookOpen( open )
	open = open == true and ( self.Crafting or self.Furnace ) and not self.Creative and not self.Chest
	if self.RecipeBookOpen == open and ( not open or IsValid( self.RecipeBook ) ) then
		if IsValid( self.RecipeBook ) then self.RecipeBook:SetVisible( open ) end
		return
	end
	self.RecipeBookOpen = open
	self:Reflow()
end

function PANEL:ToggleRecipeBook()
	self:SetRecipeBookOpen( not self.RecipeBookOpen )
end

function PANEL:RefreshInventorySlots( changed )
	if type( changed ) == "table" then
		for _, index in ipairs( changed ) do
			for _, slot in ipairs( self.InventorySlotViews[index] or {} ) do if IsValid( slot ) then slot:RefreshInventoryStack() end end
		end
	else
		for _, slot in ipairs( self.SlotPanels ) do if IsValid( slot ) and slot:IsInventorySlot() then slot:RefreshInventoryStack() end end
	end
	if self.Creative and self.SelectedTabKey == "hotbar" then
		self:RefreshCreativeItems()
		self:LayoutVisibleSlots()
	end
end

function PANEL:RefreshMenuSlots( changed )
	if type( changed ) == "table" then
		for _, index in ipairs( changed ) do
			for _, slot in ipairs( self.MenuSlotViews[index] or {} ) do
				if IsValid( slot ) then slot:RefreshInventoryStack() end
			end
		end
	else
		for _, slot in ipairs( self.SlotPanels ) do
			if IsValid( slot ) and slot:IsInventorySlot() then slot:RefreshInventoryStack() end
		end
	end
	if self.Anvil and ( type( changed ) ~= "table" or table.HasValue( changed, 0 ) ) then
		self:ApplyAnvilState( self.Session and self.Session.anvilState )
	end
end

function PANEL:RefreshCreativeItems()
	self.CurrentItems = {}
	if not self.Creative then return end
	local tab = UI.CreativeTabsByKey[self.SelectedTabKey]
	if not tab or tab.key == "inventory" then return end
	local source = tab.items
	if tab.key == "hotbar" then
		source = {}
		for index = 0, 8 do
			local stack = MC.ClientInventory and MC.ClientInventory.slots[index + 1]
			if stack then source[#source + 1] = MC.CopyItemStack( stack, 1 ) end
		end
	end
	local stacks = MC.BuildCreativeTabStacks and MC.BuildCreativeTabStacks( tab.key, source ) or {}
	local query = tab.key == "search" and string.lower( self.SearchEntry:GetValue() or "" ) or ""
	for _, stack in ipairs( stacks ) do
		local definition = MC.GetItem and MC.GetItem( stack.item ) or nil
		if definition and definition.name ~= "minecraft:air" then
			local include = true
			if query ~= "" then
				local displayName = UI.ItemRenderer and UI.ItemRenderer.DisplayName and UI.ItemRenderer.DisplayName( stack )
					or MC.ItemDisplayName and MC.ItemDisplayName( definition ) or definition.name
				local haystack = string.lower( tostring( definition.name ) .. " " .. tostring( displayName ) )
				include = string.find( haystack, query, 1, true ) ~= nil
			end
			if include then self.CurrentItems[#self.CurrentItems + 1] = MC.CopyItemStack( stack, 1 ) end
		end
	end
	self.ScrollRow = math.Clamp( self.ScrollRow, 0, self:MaxScrollRows() )
end

function PANEL:MaxScrollRows()
	return math.max( 0, math.ceil( #self.CurrentItems / CREATIVE_COLS ) - CREATIVE_ROWS )
end

function PANEL:SetScrollRow( row )
	row = math.Clamp( math.floor( tonumber( row ) or 0 ), 0, self:MaxScrollRows() )
	if row == self.ScrollRow then return end
	self.ScrollRow = row
	self:LayoutVisibleSlots()
end

function PANEL:SetScrollFraction( fraction )
	local maximum = self:MaxScrollRows()
	self:SetScrollRow( math.floor( math.Clamp( tonumber( fraction ) or 0, 0, 1 ) * maximum + 0.5 ) )
end

function PANEL:OnMouseWheeled( delta )
	if self.Scrollbar:IsVisible() then self:SetScrollRow( self.ScrollRow - math.floor( tonumber( delta ) or 0 ) ) return true end
end

function PANEL:SelectCreativeTab( key )
	if not self.Creative or not UI.CreativeTabsByKey[key] or key == self.SelectedTabKey then return end
	self.SelectedTabKey = key
	UI.LastCreativeTab = key
	self.ScrollRow = 0
	self.HoveredSlot = nil
	self:RefreshCreativeItems()
	self:LayoutTabs()
	self:LayoutVisibleSlots()
	self:LayoutSpecialControls()
end

function PANEL:SetHoveredSlot( slot ) self.HoveredSlot = slot end
function PANEL:ClearHoveredSlot( slot ) if self.HoveredSlot == slot then self.HoveredSlot = nil end end

function PANEL:BackgroundMaterial()
	if self.Chest then return CHEST_BACKGROUND end
	if self.Enchanting then return ENCHANTING_BACKGROUND end
	if self.Anvil then return ANVIL_BACKGROUND end
	if self.Brewing then return BREWING_BACKGROUND end
	if self.Furnace then return self.BlastFurnace and BLAST_FURNACE_BACKGROUND or FURNACE_BACKGROUND end
	if self.CraftingTable then return CRAFTING_BACKGROUND end
	if not self.Creative then return SURVIVAL_BACKGROUND end
	if self.SelectedTabKey == "search" then return CREATIVE_SEARCH_BACKGROUND end
	if self.SelectedTabKey == "inventory" then return CREATIVE_INVENTORY_BACKGROUND end
	return CREATIVE_ITEMS_BACKGROUND
end

function PANEL:Paint( w, h )
	if type( self.ContentW ) ~= "number" or type( self.ContentH ) ~= "number"
	or type( self.Scale ) ~= "number" or type( self.Left ) ~= "number" or type( self.Top ) ~= "number" then
		self:Reflow()
	end
	surface.SetDrawColor( UI.Colors.overlay )
	surface.DrawRect( 0, 0, w, h )
	return true
end

function PANEL:PaintContent()
	local mat = self:BackgroundMaterial()
	local width, height = self.ContentW * self.Scale, self.ContentH * self.Scale
	UI.WithPointFiltering( function()
		if self.Chest then
			local upperHeight = self.ChestRows * 18 + 17
			UI.DrawTexture( mat, self.Left, self.Top, width, upperHeight * self.Scale,
				0, 0, self.ContentW / 256, upperHeight / 256 )
			UI.DrawTexture( mat, self.Left, self.Top + upperHeight * self.Scale, width, 96 * self.Scale,
				0, 126 / 256, self.ContentW / 256, 222 / 256 )
		else
			UI.DrawTexture( mat, self.Left, self.Top, width, height, 0, 0, self.ContentW / 256, self.ContentH / 256 )
		end
	end )
	if self.Furnace then
		local state = self.Session and self.Session.furnaceState or {}
		local litTotal = math.max( 0, tonumber( state.litTotalTime ) or 0 )
		local litRemaining = math.max( 0, tonumber( state.litTimeRemaining ) or 0 )
		local litHeight = litTotal > 0 and math.ceil( math.Clamp( litRemaining / litTotal, 0, 1 ) * 13 ) + 1 or 0
		local cookTotal = math.max( 0, tonumber( state.cookingTotalTime ) or 0 )
		local cookSpent = math.max( 0, tonumber( state.cookingTimeSpent ) or 0 )
		local cookWidth = cookTotal > 0 and math.ceil( math.Clamp( cookSpent / cookTotal, 0, 1 ) * 24 ) or 0
		UI.WithPointFiltering( function()
			if litHeight > 0 then
				UI.DrawTexture( FURNACE_LIT, self.Left + 56 * self.Scale,
					self.Top + ( 36 + 14 - litHeight ) * self.Scale, 14 * self.Scale, litHeight * self.Scale,
					0, 1 - litHeight / 14, 1, 1 )
			end
			if cookWidth > 0 then
				UI.DrawTexture( FURNACE_BURN, self.Left + 79 * self.Scale, self.Top + 34 * self.Scale,
					cookWidth * self.Scale, 16 * self.Scale, 0, 0, cookWidth / 24, 1 )
			end
		end )
	end
	if self.Brewing then
		local state = self.Session and self.Session.brewingState or {}
		local fuel = math.Clamp( math.floor( tonumber( state.fuel ) or 0 ), 0, 20 )
		local fuelLength = math.Clamp( math.ceil( 18 * fuel / 20 ), 0, 18 )
		local brewTime = math.Clamp( math.floor( tonumber( state.brewTime ) or 0 ), 0, 400 )
		local bubbleLengths = { 29, 24, 20, 16, 11, 6, 0 }
		UI.WithPointFiltering( function()
			for slot, position in ipairs( { { 56, 51 }, { 79, 58 }, { 102, 51 } } ) do
				local stack = MC.GetClientMenuStack and MC.GetClientMenuStack( slot - 1 ) or nil
				if MC.IsEmptyItemStack( stack ) then
					UI.DrawTexture( BREWING_SLOT_POTION, self.Left + position[1] * self.Scale,
						self.Top + position[2] * self.Scale, 16 * self.Scale, 16 * self.Scale )
				end
			end
			local fuelStack = MC.GetClientMenuStack and MC.GetClientMenuStack( 4 ) or nil
			if MC.IsEmptyItemStack( fuelStack ) then
				UI.DrawTexture( BREWING_SLOT_FUEL, self.Left + 17 * self.Scale, self.Top + 17 * self.Scale,
					16 * self.Scale, 16 * self.Scale )
			end
			if fuelLength > 0 then
				UI.DrawTexture( BREWING_FUEL, self.Left + 60 * self.Scale, self.Top + 44 * self.Scale,
					fuelLength * self.Scale, 4 * self.Scale, 0, 0, fuelLength / 18, 1 )
			end
			if brewTime > 0 then
				local progressLength = math.floor( 28 * ( 1 - brewTime / 400 ) )
				if progressLength > 0 then
					UI.DrawTexture( BREWING_PROGRESS, self.Left + 97 * self.Scale, self.Top + 16 * self.Scale,
						9 * self.Scale, progressLength * self.Scale, 0, 0, 1, progressLength / 28 )
				end
				local bubbleLength = bubbleLengths[math.floor( brewTime / 2 ) % 7 + 1]
				if bubbleLength > 0 then
					UI.DrawTexture( BREWING_BUBBLES, self.Left + 63 * self.Scale,
						self.Top + ( 14 + 29 - bubbleLength ) * self.Scale,
						12 * self.Scale, bubbleLength * self.Scale,
						0, ( 29 - bubbleLength ) / 29, 1, 1 )
				end
			end
		end )
	end
	if self.Anvil then
		local left = MC.GetClientMenuStack and MC.GetClientMenuStack( 0 ) or nil
		UI.WithPointFiltering( function()
			UI.DrawTexture( MC.IsEmptyItemStack( left ) and ANVIL_TEXT_FIELD_DISABLED or ANVIL_TEXT_FIELD,
				self.Left + 59 * self.Scale, self.Top + 20 * self.Scale, 110 * self.Scale, 16 * self.Scale )
			local state = self.AnvilState or self.Session and self.Session.anvilState or {}
			local right = MC.GetClientMenuStack and MC.GetClientMenuStack( 1 ) or nil
			if not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right ) and state.resultAvailable ~= true then
				UI.DrawTexture( ANVIL_ERROR, self.Left + 99 * self.Scale, self.Top + 45 * self.Scale,
					28 * self.Scale, 21 * self.Scale )
			end
		end )
	end
	if self.Enchanting then
		local lapis = MC.GetClientMenuStack and MC.GetClientMenuStack( 1 ) or nil
		UI.WithPointFiltering( function()
			if MC.IsEmptyItemStack( lapis ) then
				UI.DrawTexture( ENCHANTING_SLOT_LAPIS, self.Left + 35 * self.Scale,
					self.Top + 47 * self.Scale, 16 * self.Scale, 16 * self.Scale )
			end
		end )
		if MC.DrawEnchantingBook2D then
			-- EnchantmentScreen.extractBook: exact 38x31 PIP bounds at +14,+14.
			MC.DrawEnchantingBook2D( self.Left + 14 * self.Scale, self.Top + 14 * self.Scale,
				self.EnchantingBookOpen or 0, self.EnchantingBookFlip or 0, self.Scale )
		end
	end
	if self.Chest then
		local title = self.ChestRows > 3 and "Large Chest" or "Chest"
		UI.DrawText( title, self.Left + 8 * self.Scale, self.Top + 6 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
		UI.DrawText( "Inventory", self.Left + 8 * self.Scale,
			self.Top + ( self.ChestRows * 18 + 20 ) * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	elseif self.Enchanting then
		local chinese = MC.Language and MC.Language() == "zh_cn"
		UI.DrawText( chinese and "附魔" or "Enchant", self.Left + 114 * self.Scale,
			self.Top + 6 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_CENTER, false )
		UI.DrawText( chinese and "物品栏" or "Inventory", self.Left + 8 * self.Scale,
			self.Top + 72 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	elseif self.Anvil then
		local chinese = MC.Language and MC.Language() == "zh_cn"
		UI.DrawText( chinese and "物品栏" or "Inventory", self.Left + 8 * self.Scale,
			self.Top + 72 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
		local state = self.AnvilState or self.Session and self.Session.anvilState or {}
		local errorCode = self.AnvilLocalError or state.error
		if state.tooExpensive then
			UI.DrawText( chinese and "过于昂贵！" or "Too Expensive!", self.Left + 166 * self.Scale,
				self.Top + 69 * self.Scale, self.Scale, Color( 255, 85, 85 ), TEXT_ALIGN_RIGHT, true )
		elseif ( tonumber( state.cost ) or 0 ) > 0 and state.resultAvailable then
			local label = ( chinese and "附魔花费：" or "Enchantment Cost: " ) .. tostring( state.cost )
			UI.DrawText( label, self.Left + 166 * self.Scale, self.Top + 69 * self.Scale,
				self.Scale, state.canTake == false and Color( 255, 85, 85 ) or Color( 128, 255, 32 ), TEXT_ALIGN_RIGHT, true )
		elseif errorCode == "name_too_long" then
			UI.DrawText( chinese and "名称过长" or "Name too long", self.Left + 166 * self.Scale,
				self.Top + 69 * self.Scale, self.Scale, Color( 255, 85, 85 ), TEXT_ALIGN_RIGHT, true )
		end
	elseif self.Brewing then
		local chinese = MC.Language and MC.Language() == "zh_cn"
		UI.DrawText( chinese and "酿造台" or "Brewing Stand", self.Left + 88 * self.Scale,
			self.Top + 6 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_CENTER, false )
		UI.DrawText( chinese and "物品栏" or "Inventory", self.Left + 8 * self.Scale,
			self.Top + 72 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	elseif self.Furnace then
		local chinese = MC.Language and MC.Language() == "zh_cn"
		local title = self.BlastFurnace and ( chinese and "高炉" or "Blast Furnace" )
			or ( chinese and "熔炉" or "Furnace" )
		UI.DrawText( title, self.Left + 88 * self.Scale, self.Top + 6 * self.Scale,
			self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_CENTER, false )
		UI.DrawText( chinese and "物品栏" or "Inventory", self.Left + 8 * self.Scale,
			self.Top + 72 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	elseif self.Crafting then
		local titleX = self.CraftingTable and 8 or 97
		UI.DrawText( "Crafting", self.Left + titleX * self.Scale, self.Top + 6 * self.Scale,
			self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
		UI.DrawText( "Inventory", self.Left + 8 * self.Scale, self.Top + 72 * self.Scale,
			self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	elseif not self.Creative then
		UI.DrawText( "Inventory", self.Left + 8 * self.Scale, self.Top + 72 * self.Scale,
			self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	end
	return true
end

function PANEL:PaintOver()
	if UI.DrawActiveEffectsInventory then UI.DrawActiveEffectsInventory( self ) end
	local mouseX, mouseY = gui.MousePos()
	local carried = MC.ClientInventory and MC.ClientInventory.cursor or nil
	if not MC.IsEmptyItemStack( carried ) then
		UI.ItemRenderer.DrawStack( carried, mouseX - 8 * self.Scale, mouseY - 8 * self.Scale, 16 * self.Scale, { scale = self.Scale } )
	elseif IsValid( self.HoveredSlot ) and not MC.IsEmptyItemStack( self.HoveredSlot:GetStack() ) then
		UI.Tooltip.DrawStack( self.HoveredSlot:GetStack(), mouseX, mouseY, self.Scale )
	elseif self.Enchanting and self.HoveredEnchantingOption ~= nil then
		local state = self.EnchantingState or self.Session and self.Session.enchantingState
		local option = state and state.options and state.options[self.HoveredEnchantingOption + 1] or nil
		local lines = MC.EnchantingOptionTooltipLines and MC.EnchantingOptionTooltipLines( option ) or nil
		if lines then UI.Tooltip.DrawLines( lines, mouseX, mouseY, self.Scale ) end
	elseif self.HoveredTab then
		UI.Tooltip.DrawLines( { { text = tabTitle( self.HoveredTab ), color = UI.Colors.text } }, mouseX, mouseY, self.Scale )
	elseif self.RecipeBookOpen and IsValid( self.RecipeBook ) and self.RecipeBook.HoveredTooltipLines then
		local lines = self.RecipeBook:HoveredTooltipLines()
		if lines then UI.Tooltip.DrawLines( lines, mouseX, mouseY, self.Scale ) end
	end
	if self.ErrorUntil and RealTime() < self.ErrorUntil then
		UI.DrawText( self.ErrorText, ScrW() * 0.5, self.Top - 44 * self.Scale, self.Scale, Color( 255, 85, 85, 255 ), TEXT_ALIGN_CENTER, true )
	end
end

function PANEL:PointInsideContent( x, y )
	if not self.Left then return false end
	local top = self.Top
	local bottom = self.Top + self.ContentH * self.Scale
	if self.Creative then top = top - 32 * self.Scale bottom = bottom + 32 * self.Scale end
	local insideMain = x >= self.Left and y >= top and x < self.Left + self.ContentW * self.Scale and y < bottom
	if insideMain then return true end
	if self.RecipeBookOpen and IsValid( self.RecipeBook ) then
		local bookX, bookY = self.RecipeBook:GetPos()
		return x >= bookX and y >= bookY
			and x < bookX + self.RecipeBook:GetWide() and y < bookY + self.RecipeBook:GetTall()
	end
	return false
end

function PANEL:OnMousePressed( code )
	local x, y = gui.MousePos()
	if not self:PointInsideContent( x, y ) then UI.Drag.DropOutside( code ) end
end

function PANEL:OnKeyCodePressed( code )
	if code == KEY_ESCAPE then
		if self.RecipeBookOpen then self:SetRecipeBookOpen( false ) else self:CloseInventory( true ) end
		return
	end
	if self.SearchEntry:IsVisible() and self.SearchEntry:HasFocus() then return end
	if IsValid( self.RecipeBook ) and self.RecipeBook.SearchEntry
	and self.RecipeBook.SearchEntry:IsVisible() and self.RecipeBook.SearchEntry:HasFocus() then return end
	if code == KEY_E then
		self:CloseInventory( true )
		return
	end
	local hotbar = NUMBER_KEYS[code]
	if hotbar ~= nil and IsValid( self.HoveredSlot ) then UI.Drag.HandleNumberKey( self.HoveredSlot, hotbar ) return end
	if code == KEY_Q and IsValid( self.HoveredSlot ) then UI.Drag.HandleThrowKey( self.HoveredSlot ) return end
	if code == KEY_F and modifierDown( KEY_LCONTROL, KEY_RCONTROL ) and self.Creative then self:SelectCreativeTab( "search" ) end
end

function PANEL:Think()
	local state = MC.ClientInventory
	local menu = state and state.menu or nil
	local ready = state and state.ready == true or false
	if state and ( menu ~= self.ObservedStateMenu or ready ~= self.ObservedStateReady ) then
		self:ApplyLatestClientState( state )
	end
	if self.Enchanting then
		self.NextEnchantingBookTick = self.NextEnchantingBookTick or RealTime()
		local steps = 0
		while RealTime() >= self.NextEnchantingBookTick and steps < 4 do
			self.NextEnchantingBookTick = self.NextEnchantingBookTick + 0.05
			local stack = MC.GetClientMenuStack and MC.GetClientMenuStack( 0 ) or nil
			local itemHash = MC.IsEmptyItemStack( stack ) and "" or ( MC.ItemStackHash and MC.ItemStackHash( stack ) or tostring( stack.item ) )
			if itemHash ~= self.EnchantingBookItemHash then
				self.EnchantingBookItemHash = itemHash
				local target = self.EnchantingBookFlipTarget or 0
				repeat target = target + math.random( 0, 3 ) - math.random( 0, 3 )
				until math.abs( ( self.EnchantingBookFlip or 0 ) - target ) > 1
				self.EnchantingBookFlipTarget = target
			end
			local hasOption = false
			local enchantingState = self.EnchantingState or self.Session and self.Session.enchantingState
			for _, option in ipairs( enchantingState and enchantingState.options or {} ) do
				if ( tonumber( option.cost ) or 0 ) > 0 then hasOption = true break end
			end
			self.EnchantingBookOpen = math.Clamp( ( self.EnchantingBookOpen or 0 ) + ( hasOption and 0.2 or -0.2 ), 0, 1 )
			local difference = math.Clamp( ( ( self.EnchantingBookFlipTarget or 0 ) - ( self.EnchantingBookFlip or 0 ) ) * 0.4, -0.2, 0.2 )
			self.EnchantingBookFlipAcceleration = ( self.EnchantingBookFlipAcceleration or 0 )
				+ ( difference - ( self.EnchantingBookFlipAcceleration or 0 ) ) * 0.9
			self.EnchantingBookFlip = ( self.EnchantingBookFlip or 0 ) + self.EnchantingBookFlipAcceleration
			steps = steps + 1
		end
	end
	local escape = input.IsKeyDown( KEY_ESCAPE )
	if escape and not self.EscapeWasDown then
		if self.RecipeBookOpen then self:SetRecipeBookOpen( false ) else self:CloseInventory( true ) end
		return
	end
	self.EscapeWasDown = escape
end

function PANEL:CloseInventory( notifyServer )
	if self.Closing then return end
	self.Closing = true
	UI.Drag.Cancel()
	if notifyServer then MC.CloseInventorySession() end
	if UI.Screen == self then UI.Screen = nil end
	self:Remove()
end

function PANEL:OnRemove()
	UI.Drag.Cancel()
	if IsValid( self.RecipeBook ) then self.RecipeBook:SetVisible( false ) end
	if UI.Screen == self then UI.Screen = nil end
end

vgui.Register( "MCInventoryScreen", PANEL, "EditablePanel" )

function UI.OpenInventoryScreen( session, state )
	if not IsValid( UI.Screen ) then UI.Screen = vgui.Create( "MCInventoryScreen" ) end
	UI.Screen:Configure( session, state )
	return UI.Screen
end

function UI.CloseInventoryScreen()
	if not IsValid( UI.Screen ) then return end
	UI.Screen:CloseInventory( false )
end

hook.Add( "MC.InventoryOpened", "mc_inventory_ui_open", function( session, state ) UI.OpenInventoryScreen( session, state ) end )
hook.Add( "MC.InventoryClosed", "mc_inventory_ui_close", function() UI.CloseInventoryScreen() end )
