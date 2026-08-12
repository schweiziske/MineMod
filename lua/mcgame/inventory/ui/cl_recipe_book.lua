--[[----------------------------------------------------------------------------
	Vanilla recipe-book panel for the 2x2 player and 3x3 crafting-table menus.

	The dimensions, paging (20 entries), tabs and sprite names follow
	RecipeBookComponent/RecipeBookPage from the reference sources in out/.  It
	does not predict input mutations: clicking an entry queues only its recipe
	id and the server performs the authoritative placement.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Book = MC.RecipeBook
local PANEL_W, PANEL_H = 147, 166
local TAB_MARGIN = 30
local ITEMS_PER_PAGE = 20

UI.RecipeBookLeftMargin = TAB_MARGIN

local BOOK_BACKGROUND = UI.GetGuiMaterial( "recipe_book" )
local function sprite( name ) return UI.GetGuiMaterial( "sprites/recipe_book/" .. name ) end

local BUTTON = {}

function BUTTON:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
	self:SetMouseInputEnabled( true )
	self.Recipe = nil
	self.Owner = nil
	self.Hovered = false
end

function BUTTON:Configure( owner, recipe, craftable, scale )
	self.Owner = owner
	self.Recipe = recipe
	self.Craftable = craftable == true
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 25 * self.Scale, 25 * self.Scale )
	return self
end

function BUTTON:Paint( w, h )
	local stack = self.Recipe and self.Recipe.result or nil
	local many = stack and ( tonumber( stack.count ) or 0 ) > 1
	local name = many and ( self.Craftable and "slot_many_craftable" or "slot_many_uncraftable" )
		or ( self.Craftable and "slot_craftable" or "slot_uncraftable" )
	local mat = sprite( name )
	UI.WithPointFiltering( function() UI.DrawTexture( mat, 0, 0, w, h ) end )
	if self:IsHovered() then
		surface.SetDrawColor( 255, 255, 255, 48 )
		surface.DrawRect( self.Scale, self.Scale, w - 2 * self.Scale, h - 2 * self.Scale )
	end
	if not MC.IsEmptyItemStack( stack ) then
		UI.ItemRenderer.DrawStack( stack, 4 * self.Scale, 4 * self.Scale, 16 * self.Scale,
			{ scale = self.Scale } )
	end
	return true
end

function BUTTON:DoClick()
	if IsValid( self.Owner ) and self.Recipe then
		UI.PlayButtonSound()
		local shift = input.IsKeyDown( KEY_LSHIFT ) or input.IsKeyDown( KEY_RSHIFT )
		self.Owner:PlaceRecipe( self.Recipe, shift )
	end
end

function BUTTON:DoRightClick()
	if IsValid( self.Owner ) and self.Recipe then
		UI.PlayButtonSound()
		self.Owner:PlaceRecipe( self.Recipe, true )
	end
end

function BUTTON:OnCursorEntered()
	self.Hovered = true
	if IsValid( self.Owner ) then self.Owner.HoveredRecipe = self end
end

function BUTTON:OnCursorExited()
	self.Hovered = false
	if IsValid( self.Owner ) and self.Owner.HoveredRecipe == self then self.Owner.HoveredRecipe = nil end
end

vgui.Register( "MCRecipeBookButton", BUTTON, "DButton" )

local TAB = {}

function TAB:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
	self:SetMouseInputEnabled( true )
	self.Key = "search"
	self.Owner = nil
	self.Icon = nil
end

function TAB:Configure( owner, key, icon, scale, mode )
	self.Owner, self.Key, self.Icon, self.Mode = owner, key, icon, mode
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 35 * self.Scale, 27 * self.Scale )
	return self
end

function TAB:Paint( w, h )
	local selected = IsValid( self.Owner ) and self.Owner.SelectedCategory == self.Key
	local mat = sprite( selected and "tab_selected" or "tab" )
	UI.WithPointFiltering( function() UI.DrawTexture( mat, 0, 0, w, h ) end )
	if self.Icon then
		local definition = MC.GetItem and MC.GetItem( self.Icon ) or nil
		local stack = definition and MC.NewItemStack( definition.name, 1 ) or nil
		if stack then UI.ItemRenderer.DrawStack( stack, 9 * self.Scale, 5 * self.Scale, 16 * self.Scale, { scale = self.Scale } ) end
	elseif self.Key == "search" then
		-- The search tab in the vanilla sprite is a magnifier.  Keep the same
		-- silhouette without introducing a non-Minecraft icon asset.
		surface.SetDrawColor( 60, 60, 60, 255 )
		surface.DrawOutlinedRect( 10 * self.Scale, 7 * self.Scale, 10 * self.Scale, 10 * self.Scale, self.Scale )
		surface.DrawLine( 19 * self.Scale, 16 * self.Scale, 24 * self.Scale, 21 * self.Scale )
	end
	return true
end

function TAB:DoClick()
	if IsValid( self.Owner ) then
		UI.PlayButtonSound()
		self.Owner:SelectCategory( self.Key )
	end
end

function TAB:OnCursorEntered()
	if IsValid( self.Owner ) then self.Owner.HoveredTab = self end
end

function TAB:OnCursorExited()
	if IsValid( self.Owner ) and self.Owner.HoveredTab == self then self.Owner.HoveredTab = nil end
end

vgui.Register( "MCRecipeBookTab", TAB, "DButton" )

local FILTER = {}

function FILTER:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
	self:SetMouseInputEnabled( true )
	self.Owner = nil
end

function FILTER:Configure( owner, scale )
	self.Owner = owner
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 26 * self.Scale, 16 * self.Scale )
end

function FILTER:Paint( w, h )
	local enabled = IsValid( self.Owner ) and self.Owner.OnlyCraftable
	local hovered = self:IsHovered()
	local name = enabled and ( hovered and "filter_enabled_highlighted" or "filter_enabled" )
		or ( hovered and "filter_disabled_highlighted" or "filter_disabled" )
	UI.WithPointFiltering( function() UI.DrawTexture( sprite( name ), 0, 0, w, h ) end )
	return true
end

function FILTER:DoClick()
	if IsValid( self.Owner ) then
		UI.PlayButtonSound()
		self.Owner:ToggleFilter()
	end
end

vgui.Register( "MCRecipeBookFilter", FILTER, "DButton" )

local ARROW = {}

function ARROW:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
	self:SetMouseInputEnabled( true )
	self.Direction = 1
	self.Owner = nil
end

function ARROW:Configure( owner, direction, scale )
	self.Owner, self.Direction = owner, direction
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 12 * self.Scale, 17 * self.Scale )
end

function ARROW:Paint( w, h )
	local enabled = IsValid( self.Owner ) and self.Owner:CanTurnPage( self.Direction )
	local base = self.Direction > 0 and "page_forward" or "page_backward"
	local mat = sprite( enabled and ( base .. ( self:IsHovered() and "_highlighted" or "" ) ) or base )
	UI.WithPointFiltering( function() UI.DrawTexture( mat, 0, 0, w, h ) end )
	return true
end

function ARROW:DoClick()
	if IsValid( self.Owner ) and self.Owner:CanTurnPage( self.Direction ) then
		UI.PlayButtonSound()
		self.Owner:TurnPage( self.Direction )
	end
end

vgui.Register( "MCRecipeBookArrow", ARROW, "DButton" )

local TOGGLE = {}

function TOGGLE:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
	self:SetMouseInputEnabled( true )
	self.Owner = nil
end

function TOGGLE:Configure( owner, scale )
	self.Owner = owner
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	self:SetSize( 20 * self.Scale, 18 * self.Scale )
end

function TOGGLE:Paint( w, h )
	local name = self:IsHovered() and "button_highlighted" or "button"
	UI.WithPointFiltering( function() UI.DrawTexture( sprite( name ), 0, 0, w, h ) end )
	return true
end

function TOGGLE:DoClick()
	if IsValid( self.Owner ) then
		UI.PlayButtonSound()
		self.Owner:ToggleRecipeBook()
	end
end

vgui.Register( "MCRecipeBookToggle", TOGGLE, "DButton" )

local BOOK = {}

local function ensureEntries( panel )
	if type( panel.Entries ) ~= "table" then panel.Entries = {} end
	return panel.Entries
end

function BOOK:Init()
	self:SetMouseInputEnabled( true )
	self:SetKeyboardInputEnabled( true )
	-- Some GMod branches do not expose SetClipsToBounds on EditablePanel.  The
	-- tab strip therefore lives inside this panel's real bounds (see TAB_MARGIN).
	if self.SetClipsToBounds then self:SetClipsToBounds( false ) end
	self:SetVisible( false )
	self.Scale = 2
	self.SelectedCategory = "search"
	self.OnlyCraftable = false
	self.Page = 0
	self.Entries = {}
	self.EntryKey = nil
	self.HoveredRecipe = nil
	self.HoveredTab = nil
	self.RegistryMismatch = false

	self.SearchEntry = vgui.Create( "DTextEntry", self )
	self.SearchEntry:SetDrawBackground( false )
	self.SearchEntry:SetTextColor( Color( 35, 35, 35, 255 ) )
	self.SearchEntry:SetHighlightColor( Color( 120, 150, 190, 120 ) )
	self.SearchEntry:SetCursorColor( Color( 35, 35, 35, 255 ) )
	self.SearchEntry:SetUpdateOnType( true )
	self.SearchGeneration = 0
	self.SearchEntry.OnChange = function()
		if not IsValid( self ) then return end
		self.SearchGeneration = self.SearchGeneration + 1
		local generation = self.SearchGeneration
		timer.Simple( 0.08, function()
			if IsValid( self ) and self.SearchGeneration == generation then
				self.Page = 0
				self:RefreshEntries( true )
			end
		end )
	end

	self.Tabs = {}
	local tabInfo = {
		{ key = "search", icon = nil, mode = "all" },
		{ key = "equipment", icon = "minecraft:iron_axe", mode = "crafting" },
		{ key = "building", icon = "minecraft:bricks", mode = "crafting" },
		{ key = "redstone", icon = "minecraft:redstone", mode = "crafting" },
		{ key = "food", icon = "minecraft:cooked_beef", mode = "furnace" },
		{ key = "blocks", icon = "minecraft:stone", mode = "furnace" },
		{ key = "misc", icon = "minecraft:lava_bucket", mode = "all" },
	}
	for _, info in ipairs( tabInfo ) do
		local tab = vgui.Create( "MCRecipeBookTab", self )
		tab:Configure( self, info.key, info.icon, self.Scale, info.mode )
		self.Tabs[#self.Tabs + 1] = tab
	end

	self.FilterButton = vgui.Create( "MCRecipeBookFilter", self )
	self.FilterButton:Configure( self, self.Scale )
	self.BackButton = vgui.Create( "MCRecipeBookArrow", self )
	self.BackButton:Configure( self, -1, self.Scale )
	self.ForwardButton = vgui.Create( "MCRecipeBookArrow", self )
	self.ForwardButton:Configure( self, 1, self.Scale )

	self.RecipeButtons = {}
	for index = 1, ITEMS_PER_PAGE do
		local button = vgui.Create( "MCRecipeBookButton", self )
		self.RecipeButtons[index] = button
	end

	hook.Add( "MC.InventoryChanged", self, function( panel ) panel:RefreshEntries() end )
	hook.Add( "MC.InventoryMenuChanged", self, function( panel ) panel:RefreshEntries() end )
	hook.Add( "MC.InventorySnapshot", self, function( panel ) panel:RefreshEntries( true ) end )
	hook.Add( "MC.InventoryActionResult", self, function( panel, _, accepted )
		if accepted then panel:RefreshEntries() end
	end )
end

function BOOK:Configure( screen )
	self.Screen = screen
	local state = MC.ClientInventory
	local session = state and state.session or nil
	self.GridWidth = math.Clamp( math.floor( tonumber( session and session.craftingWidth ) or 2 ), 1, 3 )
	self.GridHeight = math.Clamp( math.floor( tonumber( session and session.craftingHeight ) or self.GridWidth ), 1, 3 )
	self.Furnace = session and ( session.kind == "furnace" or session.kind == "blast_furnace" ) or false
	self.RecipeType = session and session.kind == "blast_furnace" and "minecraft:blasting" or "minecraft:smelting"
	local allowed = self.Furnace and { search = true, food = true, blocks = true, misc = true }
		or { search = true, equipment = true, building = true, misc = true, redstone = true }
	if not allowed[self.SelectedCategory] then self.SelectedCategory = "search" self.Page = 0 end
	self.Scale = screen and screen.Scale or UI.GuiScale()
	self:SetSize( ( TAB_MARGIN + PANEL_W ) * self.Scale, PANEL_H * self.Scale )
	self.SearchEntry:SetFont( "MCInventorySearch" .. tostring( self.Scale ) )
	local oldSearch = self.SearchEntry:GetValue() or ""
	self.SearchEntry:SetValue( oldSearch )
	for _, tab in ipairs( self.Tabs ) do tab:Configure( self, tab.Key, tab.Icon, self.Scale, tab.Mode ) end
	self.FilterButton:Configure( self, self.Scale )
	self.BackButton:Configure( self, -1, self.Scale )
	self.ForwardButton:Configure( self, 1, self.Scale )
	for _, button in ipairs( self.RecipeButtons ) do
		button.Scale = self.Scale
		button:SetSize( 25 * self.Scale, 25 * self.Scale )
	end
	self.RegistryMismatch = state and state.menu and state.menu.recipeRegistryHash ~= ""
		and tostring( state.menu.recipeRegistryHash ) ~= tostring( MC.RecipeRegistryHash or "" ) or false
	self:RefreshEntries( true )
	return self
end

function BOOK:SetGeometry( x, y, scale )
	self.Scale = math.max( 1, math.floor( tonumber( scale ) or self.Scale or 1 ) )
	self:SetSize( ( TAB_MARGIN + PANEL_W ) * self.Scale, PANEL_H * self.Scale )
	self:SetPos( math.floor( x or 0 ) - TAB_MARGIN * self.Scale, math.floor( y or 0 ) )
	self.SearchEntry:SetFont( "MCInventorySearch" .. tostring( self.Scale ) )
	self.SearchEntry:SetPos( ( TAB_MARGIN + 25 ) * self.Scale, 12 * self.Scale )
	self.SearchEntry:SetSize( 81 * self.Scale, 14 * self.Scale )
	local visibleTab = 0
	for _, tab in ipairs( self.Tabs ) do
		local visible = tab.Mode == "all" or tab.Mode == ( self.Furnace and "furnace" or "crafting" )
		tab:SetVisible( visible )
		if visible then tab:SetPos( 0, ( 3 + visibleTab * 27 ) * self.Scale ) visibleTab = visibleTab + 1 end
	end
	self.FilterButton:SetPos( ( TAB_MARGIN + 110 ) * self.Scale, 12 * self.Scale )
	self.BackButton:SetPos( ( TAB_MARGIN + 38 ) * self.Scale, 137 * self.Scale )
	self.ForwardButton:SetPos( ( TAB_MARGIN + 93 ) * self.Scale, 137 * self.Scale )
	for index, button in ipairs( self.RecipeButtons ) do
		local visibleIndex = index - 1
		button:SetPos( ( TAB_MARGIN + 11 + ( visibleIndex % 5 ) * 25 ) * self.Scale,
			( 31 + math.floor( visibleIndex / 5 ) * 25 ) * self.Scale )
	end
end

function BOOK:ToggleOpen()
	if not IsValid( self.Screen ) then return end
	self:SetVisible( not self:IsVisible() )
	self.Screen:SetRecipeBookOpen( self:IsVisible() )
	if self:IsVisible() then self:RequestFocus() else self.SearchEntry:KillFocus() end
end

function BOOK:SelectCategory( category )
	category = tostring( category or "search" )
	if self.SelectedCategory == category then return end
	self.SelectedCategory = category
	self.Page = 0
	self:RefreshEntries( true )
	self:InvalidateLayout( true )
end

function BOOK:ToggleFilter()
	self.OnlyCraftable = not self.OnlyCraftable
	self.Page = 0
	self:RefreshEntries( true )
	self:InvalidateLayout( true )
end

function BOOK:CanTurnPage( direction )
	local pages = math.max( 1, math.ceil( #ensureEntries( self ) / ITEMS_PER_PAGE ) )
	return direction < 0 and self.Page > 0 or direction > 0 and self.Page < pages - 1
end

function BOOK:TurnPage( direction )
	if not self:CanTurnPage( direction ) then return end
	self.Page = self.Page + ( direction < 0 and -1 or 1 )
	self:LayoutButtons()
end

function BOOK:CollectStacks()
	local state = MC.ClientInventory or {}
	local stacks = {}
	local menu = state.menu
	local menuByPlayer = menu and menu.menuPlayerMap or nil
	for playerIndex = 0, 35 do
		local menuIndex = menuByPlayer and menuByPlayer[playerIndex] or nil
		local stack = menuIndex ~= nil and menu and menu.slots and menu.slots[menuIndex + 1]
			or state.slots and state.slots[playerIndex + 1] or nil
		if not MC.IsEmptyItemStack( stack ) then stacks[#stacks + 1] = stack end
	end
	if menu and menu.crafting then
		local count = math.max( 0, ( menu.craftingWidth or self.GridWidth ) * ( menu.craftingHeight or self.GridHeight ) )
		for index = 1, count do
			local stack = menu.slots and menu.slots[index + 1] or nil
			if not MC.IsEmptyItemStack( stack ) then stacks[#stacks + 1] = stack end
		end
	end
	if self.Furnace and menu and menu.slots and not MC.IsEmptyItemStack( menu.slots[1] ) then
		stacks[#stacks + 1] = menu.slots[1]
	end
	return stacks
end

function BOOK:RefreshEntries( force )
	if not self.Screen then return end
	local state = MC.ClientInventory or {}
	local query = string.lower( tostring( self.SearchEntry:GetValue() or "" ) )
	local revision = math.max( tonumber( state.revision ) or 0, tonumber( state.predictedRevision ) or 0 )
	local key = table.concat( { self.SelectedCategory, query, tostring( self.OnlyCraftable ),
		tostring( self.GridWidth ), tostring( self.GridHeight ), tostring( revision ), tostring( self.RegistryMismatch ) }, "\0" )
	if not force and key == self.EntryKey then return end
	self.EntryKey = key
	local category = self.SelectedCategory == "search" and nil or self.SelectedCategory
	local options = {
		category = category,
		query = query,
		onlyCraftable = self.OnlyCraftable,
		stacks = self:CollectStacks(),
	}
	local entries
	if self.Furnace then
		entries = Book and Book.BuildCookingEntries and Book.BuildCookingEntries( self.RecipeType, options ) or {}
	else
		entries = Book and Book.BuildEntries and Book.BuildEntries( self.GridWidth, self.GridHeight, options ) or {}
	end
	self.Entries = type( entries ) == "table" and entries or {}
	self.Page = math.Clamp( self.Page, 0, math.max( 0, math.ceil( #self.Entries / ITEMS_PER_PAGE ) - 1 ) )
	self:LayoutButtons()
end

function BOOK:LayoutButtons()
	local entries = ensureEntries( self )
	local first = self.Page * ITEMS_PER_PAGE
	for index, button in ipairs( self.RecipeButtons ) do
		local entry = entries[first + index]
		if entry then
			button:Configure( self, entry.recipe, entry.craftable, self.Scale )
			button:SetVisible( true )
		else
			button.Recipe = nil
			button:SetVisible( false )
		end
	end
end

function BOOK:PlaceRecipe( recipe, useMax )
	if self.RegistryMismatch or not recipe then return false end
	local ok, actionOrError = MC.QueueRecipeBookPlacement( recipe.id, useMax == true )
	if not ok then
		self.ErrorText = tostring( actionOrError or "recipe_place_failed" )
		self.ErrorUntil = RealTime() + 2
		return false
	end
	self.PendingRecipeId = recipe.id
	return true, actionOrError
end

function BOOK:Paint( w, h )
	local entries = ensureEntries( self )
	UI.WithPointFiltering( function()
		UI.DrawTexture( BOOK_BACKGROUND, TAB_MARGIN * self.Scale, 0,
			PANEL_W * self.Scale, PANEL_H * self.Scale, 0, 0, PANEL_W / 256, PANEL_H / 256 )
	end )
	local pages = math.max( 1, math.ceil( #entries / ITEMS_PER_PAGE ) )
	if pages > 1 then
		UI.DrawText( tostring( self.Page + 1 ) .. " / " .. tostring( pages ), ( TAB_MARGIN + 73 ) * self.Scale,
			141 * self.Scale, self.Scale, UI.Colors.text, TEXT_ALIGN_CENTER, true )
	end
	if self.RegistryMismatch then
		surface.SetDrawColor( 0, 0, 0, 120 )
		surface.DrawRect( TAB_MARGIN * self.Scale, 0, PANEL_W * self.Scale, h )
		UI.DrawText( "Recipe data mismatch", ( TAB_MARGIN + PANEL_W * 0.5 ) * self.Scale, 76 * self.Scale,
			self.Scale, Color( 255, 120, 90 ), TEXT_ALIGN_CENTER, true )
	end
	return true
end

function BOOK:HoveredTooltipLines()
	if IsValid( self.HoveredRecipe ) and self.HoveredRecipe.Recipe then
		local recipe = self.HoveredRecipe.Recipe
		local lines = UI.Tooltip.LinesForStack( recipe.result )
		lines[#lines + 1] = { text = self.HoveredRecipe.Craftable and "Click to place" or "Missing ingredients", color = self.HoveredRecipe.Craftable and UI.Colors.text or Color( 255, 120, 90 ) }
		return lines
	end
	if IsValid( self.HoveredTab ) then
		return { { text = Book.CATEGORY_TITLES[self.HoveredTab.Key] or "Search", color = UI.Colors.text } }
	end
end

function BOOK:PaintOver()
	if self.ErrorUntil and RealTime() < self.ErrorUntil then
		UI.DrawText( self.ErrorText, ( TAB_MARGIN + PANEL_W * 0.5 ) * self.Scale, -14 * self.Scale,
			self.Scale, Color( 255, 85, 85 ), TEXT_ALIGN_CENTER, true )
	end
end

function BOOK:Think()
	if not self:IsVisible() then return end
	local state = MC.ClientInventory
	local mismatch = state and state.menu and state.menu.recipeRegistryHash ~= ""
		and tostring( state.menu.recipeRegistryHash ) ~= tostring( MC.RecipeRegistryHash or "" ) or false
	if mismatch ~= self.RegistryMismatch then self.RegistryMismatch = mismatch; self:RefreshEntries( true ) end
end

function BOOK:OnRemove()
	self.SearchGeneration = ( self.SearchGeneration or 0 ) + 1
	if IsValid( self.Screen ) and self.Screen.RecipeBook == self then self.Screen.RecipeBook = nil end
end

vgui.Register( "MCInventoryRecipeBook", BOOK, "EditablePanel" )

function UI.CreateRecipeBook( screen )
	local book = vgui.Create( "MCInventoryRecipeBook", screen )
	book:Configure( screen )
	return book
end
