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
local CREATIVE_ITEMS_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_items" )
local CREATIVE_SEARCH_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_item_search" )
local CREATIVE_INVENTORY_BACKGROUND = UI.GetGuiMaterial( "container/creative_inventory/tab_inventory" )
local SCROLLER = UI.GetGuiMaterial( "sprites/container/creative_inventory/scroller" )
local SCROLLER_DISABLED = UI.GetGuiMaterial( "sprites/container/creative_inventory/scroller_disabled" )

for scale = 2, 4 do
	surface.CreateFont( "MCInventorySearch" .. scale, {
		font = "Tahoma",
		size = 8 * scale,
		weight = 500,
		antialias = false,
		extended = true,
	} )
end

local function tabRows()
	local result = {}
	for _, source in ipairs( MC.GeneratedCreativeTabs or {} ) do
		if type( source ) == "table" and isstring( source.key ) then
			result[#result + 1] = {
				key = source.key,
				row = source.row == "bottom" and "bottom" or "top",
				column = math.Clamp( math.floor( tonumber( source.column ) or 0 ), 0, 6 ),
				title = tostring( source.title or source.key ),
				icon = source.icon,
				items = type( source.items ) == "table" and source.items or {},
				alignedRight = source.key == "inventory",
			}
		end
	end
	return result
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
	if IsValid( self.Screen ) then self.Screen:SelectCreativeTab( self.Tab.key ) end
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

local PANEL = {}

function PANEL:Init()
	self:SetSize( ScrW(), ScrH() )
	self:SetPos( 0, 0 )
	self:SetMouseInputEnabled( true )
	self:SetKeyboardInputEnabled( true )
	self:MakePopup()
	self.Scale = UI.GuiScale()
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

	self.Scrollbar = vgui.Create( "MCInventoryScrollbar", self )
	self.Scrollbar:SetScreen( self )
	self.Scrollbar:SetVisible( false )

	self.PlayerPreview = vgui.Create( "DModelPanel", self )
	self.PlayerPreview:SetMouseInputEnabled( false )
	self.PlayerPreview:SetAnimated( false )
	self.PlayerPreview:SetFOV( 26 )
	self.PlayerPreview:SetVisible( false )
	self.PlayerPreview.LayoutEntity = function( panel, entity )
		if not IsValid( entity ) then return end
		entity:SetAngles( Angle( 0, 18, 0 ) )
	end

	self.TabButtons = {}
	for _, tab in ipairs( UI.CreativeTabs ) do
		local button = vgui.Create( "MCInventoryCreativeTab", self )
		button:Configure( self, tab, self.Scale )
		button:SetVisible( false )
		self.TabButtons[#self.TabButtons + 1] = button
	end

	hook.Add( "MC.InventoryChanged", self, function( panel, changed ) panel:RefreshInventorySlots( changed ) end )
	hook.Add( "MC.EquipmentChanged", self, function( panel ) panel:RefreshMenuSlots() end )
	hook.Add( "MC.InventoryMenuChanged", self, function( panel, changed ) panel:RefreshMenuSlots( changed ) end )
	hook.Add( "MC.InventorySelectionChanged", self, function( panel ) panel:RefreshInventorySlots() end )
	hook.Add( "MC.InventoryCursorChanged", self, function( panel ) panel:InvalidateLayout() end )
	hook.Add( "MC.InventoryActionResult", self, function( panel, _, accepted, errorCode )
		if accepted then return end
		panel.ErrorText = tostring( errorCode ~= "" and errorCode or "inventory_action_rejected" )
		panel.ErrorUntil = RealTime() + 2.5
	end )
	hook.Add( "OnScreenSizeChanged", self, function( panel ) panel:Reflow() end )
end

function PANEL:Configure( session, state )
	self.Session = session
	self.State = state or MC.ClientInventory
	self.MenuKind = session and session.kind or "player"
	self.Chest = self.MenuKind == "chest"
	self.CraftingTable = self.MenuKind == "crafting_table"
	self.Crafting = session and session.crafting == true
		or self.State and self.State.menu and self.State.menu.crafting == true or false
	self.Creative = session and session.creative == true
	if not self.Crafting or self.Creative then self.RecipeBookOpen = false end
	if IsValid( self.RecipeBook ) then
		self.RecipeBook:Configure( self )
		self.RecipeBook:SetVisible( self.RecipeBookOpen and self.Crafting and not self.Creative )
	end
	if self.Creative and not UI.CreativeTabsByKey[self.SelectedTabKey] then self.SelectedTabKey = "building_blocks" end
	self.ScrollRow = 0
	self:RefreshCreativeItems()
	self:Reflow()
	self:RefreshInventorySlots()
	self:RequestFocus()
end

function PANEL:ConfigurePlayerPreview()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return end
	local model = ply:GetModel()
	if model and model ~= "" and ( not IsValid( self.PlayerPreview.Entity ) or self.PlayerPreview.Entity:GetModel() ~= model ) then
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
	if self.Chest then
		self.ChestRows = math.Clamp( math.floor( tonumber( self.Session and self.Session.chestSlots ) or 27 ) / 9, 1, 6 )
		self.ContentW, self.ContentH = 176, 114 + self.ChestRows * 18
		self.Left = math.floor( ( ScrW() - self.ContentW * self.Scale ) * 0.5 )
		self.Top = math.floor( ( ScrH() - self.ContentH * self.Scale ) * 0.5 )
	elseif self.Creative then
		local totalHeight = ( CREATIVE_H + 56 ) * self.Scale
		self.ContentW, self.ContentH = CREATIVE_W, CREATIVE_H
		self.Left = math.floor( ( ScrW() - CREATIVE_W * self.Scale ) * 0.5 )
		self.Top = math.floor( ( ScrH() - totalHeight ) * 0.5 + 28 * self.Scale )
	else
		self.ContentW, self.ContentH = SURVIVAL_W, SURVIVAL_H
		self.Left = math.floor( ( ScrW() - SURVIVAL_W * self.Scale ) * 0.5 )
		self.Top = math.floor( ( ScrH() - SURVIVAL_H * self.Scale ) * 0.5 )
	end
	self.BaseLeft = self.Left
	if self.RecipeBookOpen and self.Crafting and not self.Creative then
		local combined = ( self.ContentW + 149 ) * self.Scale
		if ScrW() >= combined + 8 * self.Scale then self.Left = self.BaseLeft + 74 * self.Scale end
	end
	self.SearchEntry:SetFont( "MCInventorySearch" .. tostring( self.Scale ) )
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
		if self.Creative then
			local x = tab.alignedRight and CREATIVE_W - 27 * ( 7 - tab.column ) + 1 or 27 * tab.column
			local y = tab.row == "top" and -28 or CREATIVE_H - 4
			button:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
			if tab.key == self.SelectedTabKey then button:MoveToFront() end
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
	slot:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
	self.InventorySlotViews[inventoryIndex] = self.InventorySlotViews[inventoryIndex] or {}
	self.InventorySlotViews[inventoryIndex][#self.InventorySlotViews[inventoryIndex] + 1] = slot
	return ordinal + 1
end

function PANEL:PlaceMenuSlot( ordinal, menuIndex, playerIndex, x, y, role )
	local slot = self:AcquireSlot( ordinal )
	slot:SetMenuSlot( menuIndex, playerIndex, role )
	slot:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
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
	slot:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
	return ordinal + 1
end

function PANEL:PlaceDestroySlot( ordinal, x, y )
	local slot = self:AcquireSlot( ordinal )
	slot:SetDestroySlot()
	slot:SetPos( self.Left + x * self.Scale, self.Top + y * self.Scale )
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
	self.SearchEntry:SetVisible( search == true )
	if search then
		self.SearchEntry:SetPos( self.Left + 82 * self.Scale, self.Top + 6 * self.Scale )
		self.SearchEntry:SetSize( 80 * self.Scale, 10 * self.Scale )
		self.SearchEntry:RequestFocus()
	end
	local scroll = self.Creative and tab and tab.key ~= "inventory" and self:MaxScrollRows() > 0
	self.Scrollbar:SetVisible( scroll == true )
	if scroll then
		self.Scrollbar:SetPos( self.Left + 175 * self.Scale, self.Top + 18 * self.Scale )
		self.Scrollbar:SetSize( 12 * self.Scale, 112 * self.Scale )
	end
	local preview = not self.Chest and not self.CraftingTable and ( not self.Creative or tab and tab.key == "inventory" )
	self.PlayerPreview:SetVisible( preview == true )
	if preview then
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
	local enabled = self.Crafting and not self.Creative and not self.Chest
	self.RecipeBookToggle:SetVisible( enabled )
	if not enabled then
		if IsValid( self.RecipeBook ) then self.RecipeBook:SetVisible( false ) end
		return
	end
	self.RecipeBookToggle:Configure( self, self.Scale )
	local toggleY = self.CraftingTable and 31 or 60
	self.RecipeBookToggle:SetPos( self.Left + ( self.CraftingTable and 5 or 104 ) * self.Scale,
		self.Top + toggleY * self.Scale )
	self.RecipeBookToggle:MoveToFront()
	if IsValid( self.RecipeBook ) then
		local bookX = self.Left - 149 * self.Scale
		if bookX < 2 * self.Scale then bookX = 2 * self.Scale end
		self.RecipeBook:SetGeometry( bookX, self.Top, self.Scale )
		self.RecipeBook:SetVisible( self.RecipeBookOpen )
		if self.RecipeBookOpen then self.RecipeBook:MoveToFront() end
	end
end

function PANEL:SetRecipeBookOpen( open )
	open = open == true and self.Crafting and not self.Creative and not self.Chest
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
end

function PANEL:RefreshCreativeItems()
	self.CurrentItems = {}
	if not self.Creative then return end
	local tab = UI.CreativeTabsByKey[self.SelectedTabKey]
	if not tab or tab.key == "inventory" then return end
	local source = tab.items
	if tab.key == "hotbar" then
		source = {}
		local seen = {}
		for index = 0, 8 do
			local stack = MC.ClientInventory and MC.ClientInventory.slots[index + 1]
			if stack and not seen[stack.item] then seen[stack.item] = true source[#source + 1] = stack.item end
		end
	end
	local query = tab.key == "search" and string.lower( self.SearchEntry:GetValue() or "" ) or ""
	for _, itemName in ipairs( source or {} ) do
		local definition = MC.GetItem and MC.GetItem( itemName ) or nil
		if definition and definition.name ~= "minecraft:air" then
			local include = true
			if query ~= "" then
				local haystack = string.lower( tostring( definition.name ) .. " " .. tostring( MC.ItemDisplayName( definition ) ) )
				include = string.find( haystack, query, 1, true ) ~= nil
			end
			if include then self.CurrentItems[#self.CurrentItems + 1] = definition.name end
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
	if self.CraftingTable then return CRAFTING_BACKGROUND end
	if not self.Creative then return SURVIVAL_BACKGROUND end
	if self.SelectedTabKey == "search" then return CREATIVE_SEARCH_BACKGROUND end
	if self.SelectedTabKey == "inventory" then return CREATIVE_INVENTORY_BACKGROUND end
	return CREATIVE_ITEMS_BACKGROUND
end

function PANEL:Paint( w, h )
	surface.SetDrawColor( UI.Colors.overlay )
	surface.DrawRect( 0, 0, w, h )
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
	if self.Chest then
		local title = self.ChestRows > 3 and "Large Chest" or "Chest"
		UI.DrawText( title, self.Left + 8 * self.Scale, self.Top + 6 * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
		UI.DrawText( "Inventory", self.Left + 8 * self.Scale,
			self.Top + ( self.ChestRows * 18 + 20 ) * self.Scale, self.Scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
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
	local mouseX, mouseY = gui.MousePos()
	local carried = MC.ClientInventory and MC.ClientInventory.cursor or nil
	if not MC.IsEmptyItemStack( carried ) then
		UI.ItemRenderer.DrawStack( carried, mouseX - 8 * self.Scale, mouseY - 8 * self.Scale, 16 * self.Scale, { scale = self.Scale } )
	elseif IsValid( self.HoveredSlot ) and not MC.IsEmptyItemStack( self.HoveredSlot:GetStack() ) then
		UI.Tooltip.DrawStack( self.HoveredSlot:GetStack(), mouseX, mouseY, self.Scale )
	elseif self.HoveredTab then
		UI.Tooltip.DrawLines( { { text = self.HoveredTab.title, color = UI.Colors.text } }, mouseX, mouseY, self.Scale )
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
		return x >= bookX - 30 * self.Scale and y >= bookY
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
	local hotbar = NUMBER_KEYS[code]
	if hotbar ~= nil and IsValid( self.HoveredSlot ) then UI.Drag.HandleNumberKey( self.HoveredSlot, hotbar ) return end
	if code == KEY_Q and IsValid( self.HoveredSlot ) then UI.Drag.HandleThrowKey( self.HoveredSlot ) return end
	if code == KEY_F and modifierDown( KEY_LCONTROL, KEY_RCONTROL ) and self.Creative then self:SelectCreativeTab( "search" ) end
end

function PANEL:Think()
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
