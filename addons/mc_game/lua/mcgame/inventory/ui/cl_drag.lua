-- AbstractContainerScreen pointer semantics. Empty-cursor pickups execute on
-- press; carried stacks use the release target or an explicit quick-craft.
MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}
local UI = MC.InventoryUI
local Drag = UI.Drag or {}
UI.Drag = Drag
local DOUBLE_CLICK_TIME = 0.25
local MOVE_THRESHOLD_SQR = 16

local function shiftDown() return input.IsKeyDown( KEY_LSHIFT ) or input.IsKeyDown( KEY_RSHIFT ) end
local function controlDown() return input.IsKeyDown( KEY_LCONTROL ) or input.IsKeyDown( KEY_RCONTROL ) end
local function cursorStack() return MC.ClientInventory.cursor end
local function creative() return MC.ClientInventory.session and MC.ClientInventory.session.creative == true end

local function slotKey( slot )
	if slot:IsInventorySlot() then return "menu:" .. slot:GetActionIndex() end
	return slot.Kind .. ":" .. tostring( slot.Stack and slot.Stack.item )
end

local function slotAtCursor( active )
	local screen = active.screen
	if not IsValid( screen ) then return nil end
	local x, y = gui.MousePos()
	for index = 1, screen.VisibleSlotCount or #screen.SlotPanels do
		local slot = screen.SlotPanels[index]
		if IsValid( slot ) and slot:IsVisible() and slot:IsMouseInputEnabled() then
			local sx, sy = slot:LocalToScreen( 0, 0 )
			if x >= sx and y >= sy and x < sx + slot:GetWide() and y < sy + slot:GetTall() then return slot end
		end
	end
end

local function creativePick( slot, count, target )
	local stack = slot:GetStack()
	if MC.IsEmptyItemStack( stack ) then return false end
	return MC.QueueCreativeInventoryPick( stack, count or MC.ItemStackMaxCount( stack ), target )
end

local function catalogClick( slot, mouseCode )
	local carried, clicked = cursorStack(), slot:GetStack()
	if MC.IsEmptyItemStack( clicked ) then
		if creative() and not MC.IsEmptyItemStack( carried ) and (mouseCode == MOUSE_LEFT or mouseCode == MOUSE_RIGHT) then
			return MC.QueueCreativeInventoryClear( -1 )
		end
		return false
	end
	if mouseCode == MOUSE_MIDDLE then
		if MC.IsEmptyItemStack( carried ) then return creativePick( slot, nil, -1 ) end
		return false
	end
	if MC.IsEmptyItemStack( carried ) then return creativePick( slot, shiftDown() and MC.ItemStackMaxCount( clicked ) or 1, -1 ) end
	local count = carried.count
	if MC.ItemStacksCanMerge( carried, clicked ) then
		if mouseCode == MOUSE_LEFT then count = shiftDown() and MC.ItemStackMaxCount( carried ) or math.min( count + 1, MC.ItemStackMaxCount( carried ) )
		else count = count - 1 end
	elseif mouseCode == MOUSE_LEFT then count = 0
	else count = count - 1 end
	if count <= 0 then return MC.QueueCreativeInventoryClear( -1 ) end
	return MC.QueueCreativeInventoryPick( carried, count, -1 )
end

local function click( slot, mouseCode )
	if not IsValid( slot ) then return false end
	if slot.Kind == "destroy" then return MC.QueueCreativeInventoryClear( shiftDown() and -2 or -1 ) end
	if slot.Kind == "creative" then return catalogClick( slot, mouseCode ) end
	if not slot:IsInventorySlot() then return false end
	if mouseCode == MOUSE_MIDDLE then
		if creative() then return MC.QueueInventoryInput( MC.ContainerInput.CLONE, slot:GetActionIndex(), 0 ) end
		return false
	end
	if shiftDown() then
		local stack = slot:GetStack()
		if not MC.IsEmptyItemStack( stack ) then Drag.LastQuickMoved = MC.CopyItemStack( stack ) end
		return MC.QueueInventoryInput( MC.ContainerInput.QUICK_MOVE, slot:GetActionIndex(), 0 )
	end
	return MC.QueueInventoryInput( MC.ContainerInput.PICKUP, slot:GetActionIndex(), mouseCode == MOUSE_RIGHT and 1 or 0 )
end

local function sameStorage( screen, source, target )
	local state = MC.ClientInventory
	local map = state.menu and state.menu.playerSlotMap
	local sourceIndex, targetIndex = source:GetActionIndex(), target:GetActionIndex()
	if map then return ( map[sourceIndex] ~= nil ) == ( map[targetIndex] ~= nil ) end
	local offset = screen.Session and screen.Session.playerOffset or 0
	return ( sourceIndex >= offset ) == ( targetIndex >= offset )
end

local function shiftDoubleClick( active, clicked )
	local source = Drag.LastQuickMoved
	if MC.IsEmptyItemStack( source ) then return end
	local screen = active.screen
	for index = 1, screen.VisibleSlotCount or #screen.SlotPanels do
		local slot = screen.SlotPanels[index]
		if IsValid( slot ) and slot:IsInventorySlot() and slot.Kind ~= "result"
		and sameStorage( screen, clicked, slot ) and MC.ItemStacksCanMerge( source, slot:GetStack() ) then
			MC.QueueInventoryInput( MC.ContainerInput.QUICK_MOVE, slot:GetActionIndex(), 0 )
		end
	end
end

local function addQuickCraftSlot( active, slot )
	if not IsValid( slot ) or not slot:CanQuickCraft() then return end
	local index = slot:GetActionIndex()
	if active.queued[index] then return end
	local container = MC.ClientInventory.predictedContainer
	local target = container and MC.ContainerGetSlot( container, index )
	if not target or not MC.InventorySlotCanDrag( target, cursorStack(), container.context )
		or not MC.ContainerCanDragTo( container, target, container.context ) then return end
	local existing = MC.InventorySlotGet( target )
	if not MC.IsEmptyItemStack( existing ) and not MC.ItemStacksCanMerge( existing, cursorStack() ) then return end
	local ok = MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, index, active.craftType * 4 + 1 )
	if ok then active.queued[index] = slot end
end

local function startQuickCraft( active )
	if active.started or MC.IsEmptyItemStack( cursorStack() ) then return end
	local craftType = active.mouseCode == MOUSE_RIGHT and 1 or active.mouseCode == MOUSE_MIDDLE and 2 or 0
	if craftType == 2 and not creative() then return end
	if not MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, craftType * 4 ) then return end
	active.started, active.craftType = true, craftType
	addQuickCraftSlot( active, active.slot )
	addQuickCraftSlot( active, slotAtCursor( active ) )
end

local function finishActive( accept )
	local active = Drag.Active
	if not active then return end
	Drag.Active = nil
	if IsValid( active.slot ) then active.slot:MouseCapture( false ) end
	if not accept then
		if active.started then MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 3 ) end
		return
	end
	local target = slotAtCursor( active )
	if target and target.Kind == "creative" and MC.IsEmptyItemStack( target:GetStack() )
		and creative() and not MC.IsEmptyItemStack( cursorStack() )
		and (active.mouseCode == MOUSE_LEFT or active.mouseCode == MOUSE_RIGHT) then
		-- Deletion wins over a distribution preview and also handles pickups
		-- already performed on press. Never place the preview before clearing.
		if active.started then MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 3 ) end
		MC.QueueCreativeInventoryClear( -1 )
		Drag.LastClick = nil
	elseif active.doubleClick and target == active.slot and target:IsInventorySlot() and target.Kind ~= "result" then
		if active.started then MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 3 ) end
		if shiftDown() then shiftDoubleClick( active, target )
		else MC.QueueInventoryInput( MC.ContainerInput.PICKUP_ALL, target:GetActionIndex(), 0 ) end
		Drag.LastClick = nil
	elseif active.started then
		MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 2 )
	elseif not active.activated then
		if target then click( target, active.mouseCode )
		elseif IsValid( active.screen ) then
			local x, y = gui.MousePos()
			if not active.screen:PointInsideContent( x, y ) then Drag.DropOutside( active.mouseCode ) end
		end
	end
end

function Drag.BeginPointer( slot, mouseCode )
	if not IsValid( slot ) or ( mouseCode ~= MOUSE_LEFT and mouseCode ~= MOUSE_RIGHT and mouseCode ~= MOUSE_MIDDLE ) then return end
	if mouseCode == MOUSE_MIDDLE and not creative() then return end
	if Drag.Active and Drag.Active.mouseCode ~= mouseCode then return end
	finishActive( false )
	Drag.SkipNextRelease = nil
	local x, y = gui.MousePos()
	local previous, now, key = Drag.LastClick, RealTime(), slotKey( slot )
	local active = { slot = slot, screen = slot.Screen, mouseCode = mouseCode, startX = x, startY = y,
		queued = {}, activated = false,
		doubleClick = mouseCode == MOUSE_LEFT and previous ~= nil and previous.key == key
			and previous.mouseCode == mouseCode and now - previous.time <= DOUBLE_CLICK_TIME }
	Drag.Active = active
	Drag.LastClick = { key = key, mouseCode = mouseCode, time = now }
	slot:MouseCapture( true )
	if MC.IsEmptyItemStack( cursorStack() ) or slot.Kind == "creative" or slot.Kind == "destroy" then
		active.activated = true
		click( slot, mouseCode )
	end
end

function Drag.ReleasePointer( _, mouseCode )
	local active = Drag.Active
	if not active then Drag.SkipNextRelease = nil return end
	if mouseCode ~= active.mouseCode then finishActive( false ) Drag.SkipNextRelease = true return end
	finishActive( true )
end

function Drag.HoverSlot( slot )
	local active = Drag.Active
	if active and active.started then addQuickCraftSlot( active, slot ) end
end

function Drag.IsQueued( slot )
	local active = Drag.Active
	return active ~= nil and active.started == true and slot:GetActionIndex() ~= nil
		and active.queued[slot:GetActionIndex()] ~= nil
end

function Drag.Cancel()
	finishActive( false )
	Drag.LastClick, Drag.LastQuickMoved, Drag.SkipNextRelease = nil, nil, nil
end

function Drag.ConsumeSkipRelease()
	if Drag.SkipNextRelease then Drag.SkipNextRelease = nil return true end
	return false
end

function Drag.DropOutside( mouseCode )
	if mouseCode ~= MOUSE_LEFT and mouseCode ~= MOUSE_RIGHT or MC.IsEmptyItemStack( cursorStack() ) then return false end
	return MC.QueueInventoryInput( MC.ContainerInput.PICKUP, -999, mouseCode == MOUSE_RIGHT and 1 or 0 )
end

function Drag.HandleNumberKey( slot, hotbarIndex )
	if not IsValid( slot ) or hotbarIndex < 0 or hotbarIndex > 8 or not MC.IsEmptyItemStack( cursorStack() ) then return false end
	if slot.Kind == "creative" then return creativePick( slot, nil, hotbarIndex ) end
	if slot:IsInventorySlot() then return MC.QueueInventoryInput( MC.ContainerInput.SWAP, slot:GetActionIndex(), hotbarIndex ) end
	return false
end

function Drag.HandleOffhandKey( slot )
	if not IsValid( slot ) or not MC.IsEmptyItemStack( cursorStack() ) then return false end
	if slot.Kind == "creative" then return creativePick( slot, nil, 40 ) end
	if slot:IsInventorySlot() then return MC.QueueInventoryInput( MC.ContainerInput.SWAP, slot:GetActionIndex(), 40 ) end
	return false
end

function Drag.HandleThrowKey( slot )
	if not IsValid( slot ) or not MC.IsEmptyItemStack( cursorStack() ) then return false end
	if slot.Kind == "creative" then return creativePick( slot, controlDown() and MC.ItemStackMaxCount( slot:GetStack() ) or 1, -3 ) end
	if slot:IsInventorySlot() then return MC.QueueInventoryInput( MC.ContainerInput.THROW, slot:GetActionIndex(), controlDown() and 1 or 0 ) end
	return false
end

hook.Add( "Think", "mc_inventory_drag_input", function()
	local active = Drag.Active
	if not active then return end
	if not IsValid( active.slot ) or not IsValid( active.screen ) then finishActive( false ) return end
	if not input.IsMouseDown( active.mouseCode ) then finishActive( true ) return end
	if active.activated then return end
	local x, y = gui.MousePos()
	if not active.started then
		local dx, dy = x - active.startX, y - active.startY
		if dx * dx + dy * dy >= MOVE_THRESHOLD_SQR then startQuickCraft( active ) end
	else addQuickCraftSlot( active, slotAtCursor( active ) ) end
end )
