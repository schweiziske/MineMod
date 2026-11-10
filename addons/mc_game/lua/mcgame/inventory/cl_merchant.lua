-- Client transport and Minecraft 26.2 merchant screen wrapper.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local BaseScreen = vgui.GetControlTable( "MCInventoryScreen" )
if not BaseScreen then return end

local STATE_VERSION = 1
local MAX_STATE_BYTES = 60000
local VISIBLE_OFFERS = 7
local MERCHANT_W, MERCHANT_H = 276, 166
local BACKGROUND = UI.GetGuiMaterial( "container/villager" )
local OUT_OF_STOCK = UI.GetGuiMaterial( "sprites/container/villager/out_of_stock" )
local EXPERIENCE_BACKGROUND = UI.GetGuiMaterial( "sprites/container/villager/experience_bar_background" )
local EXPERIENCE_CURRENT = UI.GetGuiMaterial( "sprites/container/villager/experience_bar_current" )
local EXPERIENCE_RESULT = UI.GetGuiMaterial( "sprites/container/villager/experience_bar_result" )
local SCROLLER = UI.GetGuiMaterial( "sprites/container/villager/scroller" )
local SCROLLER_DISABLED = UI.GetGuiMaterial( "sprites/container/villager/scroller_disabled" )
local TRADE_ARROW = UI.GetGuiMaterial( "sprites/container/villager/trade_arrow" )
local TRADE_ARROW_OUT_OF_STOCK = UI.GetGuiMaterial( "sprites/container/villager/trade_arrow_out_of_stock" )
local DISCOUNT_STRIKETHROUGH = UI.GetGuiMaterial( "sprites/container/villager/discount_strikethrough" )
local TRADE_BUTTON = UI.GetGuiMaterial( "sprites/widget/button" )
local TRADE_BUTTON_HIGHLIGHTED = UI.GetGuiMaterial( "sprites/widget/button_highlighted" )

local LEVEL_MIN_XP = { [1] = 0, [2] = 10, [3] = 70, [4] = 150, [5] = 250 }
-- Unavailable trades name their reason; any other reason uses .default.
local UNAVAILABLE_REASONS = {
	exploration_map_pending = true,
	unsupported_trade_modifier = true,
	unsupported_potion_options = true,
	modifier_filtered_out = true,
}

local function emit( eventName, ... )
	if hook and hook.Run then hook.Run( eventName, ... ) end
end

local function integer( value, fallback, minimum, maximum )
	value = math.floor( tonumber( value ) or tonumber( fallback ) or 0 )
	if minimum ~= nil then value = math.max( minimum, value ) end
	if maximum ~= nil then value = math.min( maximum, value ) end
	return value
end

local function decodeStack( value )
	if value == nil then return nil end
	if type( value ) ~= "table" then return nil, "invalid_merchant_item" end
	return MC.InventoryStackFromData( value )
end

local function decodeMerchantState( value )
	if type( value ) ~= "table" or integer( value.version, -1 ) ~= STATE_VERSION
	or type( value.offers ) ~= "table" or #value.offers > ( MC.MerchantMaxOffers or 64 ) then
		return nil, "invalid_merchant_state"
	end
	local state = {
		version = STATE_VERSION,
		entityIndex = integer( value.entityIndex, 0, 0, 65535 ),
		entityClass = tostring( value.entityClass or "" ),
		revision = integer( value.revision, 0, 0, 4294967295 ),
		profession = tostring( value.profession or "none" ),
		villagerType = tostring( value.villagerType or "plains" ),
		level = integer( value.level, 0, 0, 5 ),
		experience = integer( value.experience, 0, 0 ),
		nextLevelExperience = integer( value.nextLevelExperience, 0, 0 ),
		showProgressBar = value.showProgressBar == true,
		canRestock = value.canRestock == true,
		selected = integer( value.selected, 0, 0, math.max( 0, #value.offers - 1 ) ),
		activeOffer = integer( value.activeOffer, -1, -1, math.max( -1, #value.offers - 1 ) ),
		futureExperience = integer( value.futureExperience, 0, 0 ),
		error = value.error and tostring( value.error ) or nil,
		offers = {},
		receivedAt = RealTime(),
	}
	local seen = {}
	for position, rawOffer in ipairs( value.offers ) do
		if type( rawOffer ) ~= "table" then return nil, "invalid_merchant_offer" end
		local offerIndex = integer( rawOffer.index, position, 1, MC.MerchantMaxOffers or 64 )
		if seen[offerIndex] then return nil, "duplicate_merchant_offer" end
		seen[offerIndex] = true
		local baseCostA, stackError = decodeStack( rawOffer.baseCostA )
		if stackError then return nil, stackError end
		local costA
		costA, stackError = decodeStack( rawOffer.costA )
		if stackError then return nil, stackError end
		local costB
		costB, stackError = decodeStack( rawOffer.costB )
		if stackError then return nil, stackError end
		local result
		result, stackError = decodeStack( rawOffer.result )
		if stackError then return nil, stackError end
		state.offers[position] = {
			index = offerIndex,
			id = tostring( rawOffer.id or "minecraft:unknown" ),
			level = integer( rawOffer.level, 1, 1, 5 ),
			baseCostA = baseCostA,
			costA = costA,
			costB = costB,
			result = result,
			uses = integer( rawOffer.uses, 0, 0 ),
			maxUses = integer( rawOffer.maxUses, 1, 1 ),
			availableUses = integer( rawOffer.availableUses, 0, 0 ),
			xp = integer( rawOffer.xp, 0, 0 ),
			outOfStock = rawOffer.outOfStock == true,
			unavailable = rawOffer.unavailable == true,
			unavailableReason = rawOffer.unavailableReason and tostring( rawOffer.unavailableReason ) or nil,
		}
	end
	return state
end

net.Receive( "mc_merchant_state", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local rawBytes = net.ReadUInt( 20 )
	local payloadBytes = net.ReadUInt( 16 )
	if payloadBytes < 1 or payloadBytes > MAX_STATE_BYTES or rawBytes < 2 or rawBytes > MAX_STATE_BYTES * 4 then
		MC.ClientInventory.lastError = "invalid_merchant_state_size"
		return
	end
	local payload = net.ReadData( payloadBytes )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "merchant" or session.containerId ~= containerId
	or session.token ~= token or type( payload ) ~= "string" or #payload ~= payloadBytes then return end
	local json = util.Decompress( payload )
	if not json or #json ~= rawBytes then state.lastError = "merchant_state_decompress_failed" return end
	local decoded, decodeError = decodeMerchantState( util.JSONToTable( json ) )
	if not decoded then state.lastError = decodeError or "merchant_state_decode_failed" return end
	session.merchantState = decoded
	if decoded.error then state.lastError = decoded.error end
	emit( "MCMerchantStateChanged", decoded, state )
end )

function MC.RequestMerchantSelection( selection )
	local state = MC.ClientInventory
	local session = state and state.session
	local merchantState = session and session.merchantState
	if not session or session.kind ~= "merchant" or not merchantState then
		return false, "merchant_not_open"
	end
	if #( state.actions or {} ) > 0 then return false, "inventory_action_pending" end
	selection = integer( selection, -1 )
	if selection < 0 or selection >= #merchantState.offers then return false, "invalid_offer" end
	local now = RealTime()
	if session.lastMerchantSelectionAt and now - session.lastMerchantSelectionAt < 0.03 then
		return false, "merchant_selection_rate_limited"
	end
	session.lastMerchantSelectionAt = now
	net.Start( "mc_merchant_select" )
		net.WriteUInt( session.containerId, 16 )
		net.WriteString( session.token )
		net.WriteUInt( integer( state.revision, 0, 0, 4294967295 ), 32 )
		net.WriteUInt( merchantState.revision, 32 )
		net.WriteUInt( selection, 6 )
	net.SendToServer()
	return true
end

-- Ordinary payment/inventory clicks predict in cl_network. Taking a trade
-- result is a replay barrier until the server confirms payment and stock.

local OFFER_BUTTON = {}

function OFFER_BUTTON:Init()
	self:SetText( "" )
	self:SetCursor( "hand" )
end

function OFFER_BUTTON:Configure( screen, row, offerIndex )
	self.Screen, self.Row, self.OfferIndex = screen, row, offerIndex
	self:SetVisible( offerIndex ~= nil )
end

function OFFER_BUTTON:Paint() return true end

-- AbstractWidget#mouseClicked: a left press plays ui.button.click and then
-- runs onPress (MerchantScreen: shopItem = index + scrollOff, postButtonClick),
-- whether or not the selection is accepted. DButton:DoClick fires on release,
-- so the press is handled here and DButton's depressed/DoClick path is unused.
function OFFER_BUTTON:OnMousePressed( code )
	if code ~= MOUSE_LEFT or not IsValid( self.Screen ) or self.OfferIndex == nil then return end
	UI.PlayButtonSound()
	-- ContainerEventHandler#mouseClicked focuses the clicked widget and Button
	-- draws button_highlighted while hovered or focused, so this row stays lit.
	self.Screen.FocusedMerchantRow = self.Row
	local ok, err = MC.RequestMerchantSelection( self.OfferIndex )
	if not ok then
		UI.SetError( self.Screen, err or "merchant_selection_failed" )
	end
end

vgui.Register( "MCMerchantOfferButton", OFFER_BUTTON, "DButton" )

local MERCHANT_SCROLLER = {}

function MERCHANT_SCROLLER:Init()
	self:SetCursor( "sizens" )
	self:SetMouseInputEnabled( true )
end

function MERCHANT_SCROLLER:SetScreen( screen ) self.Screen = screen end
function MERCHANT_SCROLLER:Paint() return true end

function MERCHANT_SCROLLER:CanScroll()
	return IsValid( self.Screen ) and self.Screen:MaxMerchantScrollOffset() > 0
end

function MERCHANT_SCROLLER:UpdateFromCursor( y )
	if not self:CanScroll() then return end
	self.Screen:SetMerchantScrollFraction( ( y - 13.5 * self.Screen.Scale ) / ( 112 * self.Screen.Scale ) )
end

function MERCHANT_SCROLLER:OnMousePressed( code )
	if code ~= MOUSE_LEFT or not self:CanScroll() then return end
	self.Dragging = true
	self:MouseCapture( true )
	local _, y = self:CursorPos()
	self:UpdateFromCursor( y )
end

function MERCHANT_SCROLLER:OnCursorMoved( _, y )
	if self.Dragging then self:UpdateFromCursor( y ) end
end

function MERCHANT_SCROLLER:OnMouseReleased( code )
	if code ~= MOUSE_LEFT then return end
	self.Dragging = false
	self:MouseCapture( false )
end

function MERCHANT_SCROLLER:Think()
	if self.Dragging and input.IsMouseDown( MOUSE_LEFT ) then
		local _, y = self:CursorPos()
		self:UpdateFromCursor( y )
	elseif self.Dragging then
		self.Dragging = false
		self:MouseCapture( false )
	end
end

function MERCHANT_SCROLLER:OnMouseWheeled( delta )
	return self:CanScroll() and self.Screen:OnMouseWheeled( delta )
end

vgui.Register( "MCMerchantScroller", MERCHANT_SCROLLER, "DPanel" )

local PANEL = {}

function PANEL:Init()
	-- vgui.Create builds the MCInventoryScreen base first and already ran its
	-- Init. Calling BaseScreen.Init again created a second set of controls and
	-- left the first return button and recipe-book toggle visible, unsized, at
	-- the top-left corner of the screen.
	self.Merchant = true
	self.MerchantScrollOffset = 0
	self.MerchantOfferButtons = {}
	for row = 0, VISIBLE_OFFERS - 1 do
		local button = vgui.Create( "MCMerchantOfferButton", self )
		button:SetZPos( 35 )
		self.MerchantOfferButtons[row + 1] = button
	end
	self.MerchantScroller = vgui.Create( "MCMerchantScroller", self )
	self.MerchantScroller:SetScreen( self )
	self.MerchantScroller:SetZPos( 35 )
	hook.Add( "MCMerchantStateChanged", self, function( panel, merchantState )
		panel:ApplyMerchantState( merchantState )
	end )
end

function PANEL:Configure( session, state )
	self.Merchant = true
	BaseScreen.Configure( self, session, state )
	self.Merchant = true
	self.RecipeBookOpen = false
	self.FocusedMerchantRow = nil
	self:ApplyMerchantState( session and session.merchantState )
end

function PANEL:ApplyMerchantState( merchantState )
	if not self.Merchant then return end
	self.MerchantState = merchantState or self.Session and self.Session.merchantState
	local maximum = math.max( 0, #( self.MerchantState and self.MerchantState.offers or {} ) - VISIBLE_OFFERS )
	self.MerchantScrollOffset = math.Clamp( self.MerchantScrollOffset or 0, 0, maximum )
	if self.MerchantState and self.MerchantState.error then
		UI.SetError( self, self.MerchantState.error )
	end
	self:LayoutSpecialControls()
end

function PANEL:Reflow()
	BaseScreen.Reflow( self )
	if not self.Merchant then return end
	local offsetX, offsetY = 0, 0
	if UI.UIOffset then offsetX, offsetY = UI.UIOffset() end
	self.ContentW, self.ContentH = MERCHANT_W, MERCHANT_H
	self.Left = math.floor( ( ScrW() - MERCHANT_W * self.Scale ) * 0.5 + offsetX )
	self.Top = math.floor( ( ScrH() - MERCHANT_H * self.Scale ) * 0.5 + offsetY )
	self.BaseLeft = self.Left
	self.ContentLayer:SetSize( ScrW(), ScrH() )
	self:LayoutVisibleSlots()
	self:LayoutSpecialControls()
	self:LayoutRecipeBook()
end

function PANEL:LayoutVisibleSlots()
	if not self.Merchant or not self.Left then return BaseScreen.LayoutVisibleSlots( self ) end
	self:BeginSlotLayout()
	local ordinal = 1
	ordinal = self:PlaceMenuSlot( ordinal, 0, nil, 136, 37, "input" )
	ordinal = self:PlaceMenuSlot( ordinal, 1, nil, 162, 37, "input" )
	ordinal = self:PlaceMenuSlot( ordinal, 2, nil, 220, 37, "result" )
	local playerOffset = math.floor( tonumber( self.Session and self.Session.playerOffset ) or 3 )
	for playerIndex = 9, 35 do
		local position = playerIndex - 9
		ordinal = self:PlaceMenuSlot( ordinal, playerOffset + playerIndex, playerIndex,
			108 + position % 9 * 18, 84 + math.floor( position / 9 ) * 18 )
	end
	for playerIndex = 0, 8 do
		ordinal = self:PlaceMenuSlot( ordinal, playerOffset + playerIndex, playerIndex,
			108 + playerIndex * 18, 142 )
	end
	self:FinishSlotLayout()
end

function PANEL:LayoutSpecialControls()
	if not self.Merchant then return BaseScreen.LayoutSpecialControls( self ) end
	for _, control in ipairs( {
		self.SearchEntry, self.AnvilEntry, self.Scrollbar, self.PlayerPreview,
		self.RecipeBookToggle, self.RecipeBook,
	} ) do if IsValid( control ) then control:SetVisible( false ) end end
	for _, button in ipairs( self.TabButtons or {} ) do if IsValid( button ) then button:SetVisible( false ) end end
	for _, button in ipairs( self.EnchantingButtons or {} ) do if IsValid( button ) then button:SetVisible( false ) end end
	local offers = self.MerchantState and self.MerchantState.offers or {}
	for row = 0, VISIBLE_OFFERS - 1 do
		local button = self.MerchantOfferButtons and self.MerchantOfferButtons[row + 1]
		local offerIndex = self.MerchantScrollOffset + row
		if IsValid( button ) then
			button:Configure( self, row, offers[offerIndex + 1] and offerIndex or nil )
			button:SetPos( self.Left + 5 * self.Scale, self.Top + ( 18 + row * 20 ) * self.Scale )
			button:SetSize( 88 * self.Scale, 20 * self.Scale )
		end
	end
	if IsValid( self.MerchantScroller ) then
		-- MerchantScreen.extractScroller always paints a thumb: the normal
		-- 6x27 sprite is used only for >7 offers, otherwise the disabled sprite
		-- stays at the top of the 139px track. Java skips extractContents when
		-- there are no offers at all, so only that empty state hides the panel.
		-- For 1..7 offers the hit panel remains alive; its input methods reject
		-- dragging when there is no range.
		self.MerchantScroller:SetVisible( #offers > 0 )
		self.MerchantScroller:SetPos( self.Left + 94 * self.Scale, self.Top + 18 * self.Scale )
		self.MerchantScroller:SetSize( 6 * self.Scale, 139 * self.Scale )
	end
end

-- Hover is read from the row panels every frame, like AbstractWidget's
-- isHovered: enter/exit events miss rows that scroll under a resting cursor.
function PANEL:HoveredMerchantRow()
	for index, button in ipairs( self.MerchantOfferButtons or {} ) do
		if IsValid( button ) and button:IsVisible() and button:IsHovered() then return index - 1 end
	end
	return nil
end

function PANEL:MaxMerchantScrollOffset()
	return math.max( 0, #( self.MerchantState and self.MerchantState.offers or {} ) - VISIBLE_OFFERS )
end

function PANEL:SetMerchantScrollOffset( value )
	value = math.Clamp( integer( value, 0 ), 0, self:MaxMerchantScrollOffset() )
	if value == self.MerchantScrollOffset then return end
	self.MerchantScrollOffset = value
	self:LayoutSpecialControls()
end

function PANEL:SetMerchantScrollFraction( fraction )
	local maximum = self:MaxMerchantScrollOffset()
	self:SetMerchantScrollOffset( math.floor( math.Clamp( tonumber( fraction ) or 0, 0, 1 ) * maximum + 0.5 ) )
end

function PANEL:OnMouseWheeled( delta )
	if not self.Merchant then return BaseScreen.OnMouseWheeled( self, delta ) end
	self:SetMerchantScrollOffset( self.MerchantScrollOffset - integer( delta, 0 ) )
	return true
end

function PANEL:BackgroundMaterial() return BACKGROUND end

local function drawExplicitCount( stack, x, y, scale )
	if MC.IsEmptyItemStack( stack ) then return end
	UI.DrawText( tostring( integer( stack.count, 1, 1 ) ), x + 16 * scale, y + 16 * scale,
		scale, UI.Colors.text, TEXT_ALIGN_RIGHT, true, TEXT_ALIGN_BOTTOM )
end

local function drawOfferCostA( offer, x, y, scale )
	if MC.IsEmptyItemStack( offer.costA ) then return end
	local discounted = not MC.IsEmptyItemStack( offer.baseCostA )
		and offer.baseCostA.count ~= offer.costA.count
	if not discounted then
		UI.ItemRenderer.DrawStack( offer.costA, x, y, 16 * scale, { scale = scale } )
		return
	end
	UI.ItemRenderer.DrawStack( offer.costA, x, y, 16 * scale, { scale = scale, drawCount = false } )
	drawExplicitCount( offer.baseCostA, x, y, scale )
	drawExplicitCount( offer.costA, x + 14 * scale, y, scale )
	UI.DrawTexture( DISCOUNT_STRIKETHROUGH, x + 7 * scale, y + 12 * scale, 9 * scale, 2 * scale )
end

local function scrollerOffset( offerCount, scrollOffset )
	local rows = offerCount + 1 - VISIBLE_OFFERS
	if rows <= 1 then return 0 end
	local reduced = 139 - ( 27 + math.floor( ( rows - 1 ) * 139 / rows ) )
	local step = 1 + math.floor( reduced / rows ) + math.floor( 139 / rows )
	local offset = math.min( 113, scrollOffset * step )
	if scrollOffset == rows - 1 then offset = 113 end
	return offset
end

local function unavailableReasonText( reason )
	reason = tostring( reason or "" )
	return MC.T( "inventory.merchant.unavailable." .. ( UNAVAILABLE_REASONS[reason] and reason or "default" ) )
end

-- MerchantScreen: the profession name (Minecraft's entity keys), with
-- merchant.title and merchant.level.<n> while the villager shows its level.
local function merchantTitle( state )
	local profession = tostring( state.profession or "none" )
	local key = profession == "wandering_trader" and "entity.minecraft.wandering_trader"
		or "entity.minecraft.villager." .. profession
	if not MC.I18n.Has( key, MC.I18n.BASE_LOCALE ) then key = "entity.minecraft.villager" end
	if state.showProgressBar and state.level >= 1 and state.level <= 5 then
		-- MC.T only interpolates flat values; nested { key = ... } specs printed as
		-- "table: 0x..." here. I18n.Resolve translates them first.
		return MC.I18n.Resolve( "merchant.title", { { key = key }, { key = "merchant.level." .. state.level } } )
	end
	return MC.T( key )
end

function PANEL:PaintContent()
	if not self.Merchant then return BaseScreen.PaintContent( self ) end
	local state = self.MerchantState or self.Session and self.Session.merchantState
	local offers = state and state.offers or {}
	local scale, left, top = self.Scale, self.Left, self.Top
	local hoveredRow = self:HoveredMerchantRow()
	UI.WithPointFiltering( function()
		-- villager.png already stores the 276x166 screen on a transparent
		-- 512x256 canvas. Draw that complete padded canvas through the shared
		-- GUI mapping so Source cannot flatten its one-pixel slot bevels.
		UI.DrawTextureClipped( BACKGROUND, left, top, MERCHANT_W * scale, MERCHANT_H * scale,
			left, top, MERCHANT_W * scale, MERCHANT_H * scale )
		for row = 0, VISIBLE_OFFERS - 1 do
			local offer = offers[self.MerchantScrollOffset + row + 1]
			if offer then
				local buttonMaterial = ( hoveredRow == row or self.FocusedMerchantRow == row )
					and TRADE_BUTTON_HIGHLIGHTED or TRADE_BUTTON
				UI.DrawHorizontalNineSlice( buttonMaterial,
					left + 5 * scale, top + ( 18 + row * 20 ) * scale,
					88 * scale, 20 * scale, 200, 20, 3, scale )
				local y = top + ( 19 + row * 20 ) * scale
				if offer.unavailable and surface and surface.SetDrawColor and surface.DrawRect then
					surface.SetDrawColor( UI.Colors.invalid )
					surface.DrawRect( left + 5 * scale, top + ( 18 + row * 20 ) * scale,
						89 * scale, 20 * scale )
				end
				drawOfferCostA( offer, left + 10 * scale, y, scale )
				if not MC.IsEmptyItemStack( offer.costB ) then
					UI.ItemRenderer.DrawStack( offer.costB, left + 40 * scale, y,
						16 * scale, { scale = scale } )
				end
				UI.DrawTexture( offer.outOfStock and TRADE_ARROW_OUT_OF_STOCK or TRADE_ARROW,
					left + 60 * scale, top + ( 20 + row * 20 ) * scale, 10 * scale, 9 * scale )
				if not MC.IsEmptyItemStack( offer.result ) then
					UI.ItemRenderer.DrawStack( offer.result, left + 73 * scale, y,
						16 * scale, { scale = scale } )
				end
			end
		end
		if #offers > VISIBLE_OFFERS then
			UI.DrawTexture( SCROLLER, left + 94 * scale,
				top + ( 18 + scrollerOffset( #offers, self.MerchantScrollOffset ) ) * scale,
				6 * scale, 27 * scale )
		elseif #offers > 0 then
			UI.DrawTexture( SCROLLER_DISABLED, left + 94 * scale, top + 18 * scale,
				6 * scale, 27 * scale )
		end
		if state and state.showProgressBar and state.level >= 1 and state.level < 5 then
			UI.DrawTexture( EXPERIENCE_BACKGROUND, left + 136 * scale, top + 16 * scale,
				102 * scale, 5 * scale )
			local minimum = LEVEL_MIN_XP[state.level] or 0
			local maximum = math.max( minimum + 1, state.nextLevelExperience or minimum + 1 )
			if state.experience >= minimum then
				local factor = 102 / ( maximum - minimum )
				local current = math.min( math.floor( ( state.experience - minimum ) * factor ), 102 )
				if current > 0 then
					UI.DrawTexture( EXPERIENCE_CURRENT, left + 136 * scale, top + 16 * scale,
						current * scale, 5 * scale, 0, 0, current / 102, 1 )
				end
				local future = math.min( math.floor( ( state.futureExperience or 0 ) * factor ), 102 - current )
				if future > 0 then
					UI.DrawTexture( EXPERIENCE_RESULT, left + ( 136 + current ) * scale, top + 16 * scale,
						future * scale, 5 * scale, current / 102, 0, ( current + future ) / 102, 1 )
				end
			end
		end
		local selected = state and offers[state.selected + 1] or nil
		if selected and selected.outOfStock then
			UI.DrawTexture( OUT_OF_STOCK, left + 182 * scale, top + 35 * scale, 28 * scale, 21 * scale )
		end
	end )
	UI.DrawText( state and merchantTitle( state ) or MC.T( "entity.minecraft.villager" ),
		left + 187 * scale, top + 6 * scale, scale, Color( 64, 64, 64 ), TEXT_ALIGN_CENTER, false )
	UI.DrawText( MC.T( "merchant.trades" ), left + 48 * scale, top + 6 * scale,
		scale, Color( 64, 64, 64 ), TEXT_ALIGN_CENTER, false )
	UI.DrawText( MC.T( "container.inventory" ), left + 107 * scale, top + 72 * scale,
		scale, Color( 64, 64, 64 ), TEXT_ALIGN_LEFT, false )
	return true
end

function PANEL:MerchantTooltipStack()
	local row = self:HoveredMerchantRow()
	local state = self.MerchantState
	local offer = row ~= nil and state and state.offers[self.MerchantScrollOffset + row + 1] or nil
	if not offer then return nil end
	local mouseX = gui.MouseX()
	local buttonX = self.Left + 5 * self.Scale
	if mouseX < buttonX + 20 * self.Scale then return offer.costA end
	if mouseX > buttonX + 30 * self.Scale and mouseX < buttonX + 50 * self.Scale then return offer.costB end
	if mouseX > buttonX + 65 * self.Scale then return offer.result end
	return nil
end

function PANEL:PaintOver()
	BaseScreen.PaintOver( self )
	if not self.Merchant or not MC.IsEmptyItemStack( MC.ClientInventory and MC.ClientInventory.cursor )
	or IsValid( self.HoveredSlot ) then return end
	local stack = self:MerchantTooltipStack()
	if not MC.IsEmptyItemStack( stack ) then
		UI.Tooltip.DrawStack( stack, gui.MouseX(), gui.MouseY(), self.Scale )
		return
	end
	local state = self.MerchantState
	local selected = state and state.offers[state.selected + 1] or nil
	local x, y = gui.MousePos()
	if selected and selected.unavailable
	and x >= self.Left + 186 * self.Scale and x <= self.Left + 208 * self.Scale
	and y >= self.Top + 35 * self.Scale and y <= self.Top + 56 * self.Scale then
		UI.Tooltip.DrawLines( { unavailableReasonText( selected.unavailableReason ) },
			x, y, self.Scale )
		return
	end
	if selected and selected.outOfStock and not selected.unavailable and state.canRestock
	and x >= self.Left + 186 * self.Scale and x <= self.Left + 208 * self.Scale
	and y >= self.Top + 35 * self.Scale and y <= self.Top + 56 * self.Scale then
		UI.Tooltip.DrawLines( { MC.T( "inventory.merchant.out_of_stock" ) },
			x, y, self.Scale )
	end
end

vgui.Register( "MCMerchantInventoryScreen", PANEL, "MCInventoryScreen" )

local openInventoryScreen = UI.OpenInventoryScreen
local function screenClassName( screen )
	if not IsValid( screen ) or type( screen.GetClassName ) ~= "function" then return nil end
	local called, className = pcall( screen.GetClassName, screen )
	return called and className or nil
end

function UI.OpenInventoryScreen( session, state )
	if session and session.kind == "merchant" then
		if IsValid( UI.Screen ) and screenClassName( UI.Screen ) ~= "MCMerchantInventoryScreen" then
			UI.Screen:Remove()
			UI.Screen = nil
		end
		if not IsValid( UI.Screen ) then UI.Screen = vgui.Create( "MCMerchantInventoryScreen" ) end
		UI.Screen:Configure( session, state )
		return UI.Screen
	end
	if IsValid( UI.Screen ) and screenClassName( UI.Screen ) == "MCMerchantInventoryScreen" then
		UI.Screen:Remove()
		UI.Screen = nil
	end
	return openInventoryScreen( session, state )
end
