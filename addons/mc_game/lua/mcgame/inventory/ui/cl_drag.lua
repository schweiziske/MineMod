-- Central pointer/drag state machine for Minecraft container input semantics.
-- The shared click state machine predicts the local view immediately; the
-- authoritative delta later reconciles it without blocking the next input.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Drag = UI.Drag or {}
UI.Drag = Drag

local MOVE_THRESHOLD_SQR = 16
local DOUBLE_CLICK_TIME = 0.28

local function parityClicksEnabled()
	return MC.GameplayParityInventoryClicksEnabled and MC.GameplayParityInventoryClicksEnabled() == true
end

local function shiftDown()
	return input.IsKeyDown( KEY_LSHIFT ) or input.IsKeyDown( KEY_RSHIFT )
end

local function controlDown()
	return input.IsKeyDown( KEY_LCONTROL ) or input.IsKeyDown( KEY_RCONTROL )
end

local function cursorStack()
	return MC.ClientInventory and MC.ClientInventory.cursor or nil
end

local function slotKey( slot )
	if not IsValid( slot ) then return "invalid" end
	if slot:IsInventorySlot() then return "menu:" .. tostring( slot:GetActionIndex() ) end
	if slot.Kind == "creative" and slot.Stack then
		return "creative:" .. tostring( MC.ItemStackHash and MC.ItemStackHash( slot.Stack ) or slot.Stack.item )
	end
	return tostring( slot.Kind )
end

local function stackSameItem( left, right )
	return MC.ItemStacksCanMerge and MC.ItemStacksCanMerge( left, right )
		or ( not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right ) and left.item == right.item )
	end

local function slotBelongsToClickedContainer( screen, clicked, candidate )
	if not IsValid( screen ) or not IsValid( candidate ) or not candidate:IsInventorySlot() then return false end
	if not IsValid( clicked ) then return true end
	local session = screen.Session or {}
	local clickedIndex = clicked:GetActionIndex()
	local candidateIndex = candidate:GetActionIndex()
	if session.kind == "chest" or session.kind == "chest_double" then
		local chestSlots = math.floor( tonumber( session.chestSlots ) or 27 )
		local clickedInChest = clickedIndex < chestSlots
		return ( candidateIndex < chestSlots ) == clickedInChest
	end
	if session.kind == "hopper" or session.kind == "dispenser" or session.kind == "dropper" then
		local playerOffset = math.floor( tonumber( session.playerOffset ) or 0 )
		return ( candidateIndex < playerOffset ) == ( clickedIndex < playerOffset )
	end
	-- For player crafting/inventory menus, all menu slots belong to the same
	-- AbstractContainerMenu.  The result slot is intentionally excluded by the
	-- caller because vanilla's canTakeItemForPickAll gate handles it.
	return true
end

local function queueShiftDoubleClick( active, previous )
	local source = previous and previous.lastQuickMoved
	local clicked = active and active.slot
	local screen = IsValid( clicked ) and clicked.Screen or nil
	if MC.IsEmptyItemStack( source ) or not IsValid( screen ) or type( screen.SlotPanels ) ~= "table" then return false end
	for index = 1, screen.VisibleSlotCount or #screen.SlotPanels do
		local target = screen.SlotPanels[index]
		if slotBelongsToClickedContainer( screen, clicked, target )
		and target:IsInventorySlot()
		and stackSameItem( target:GetStack(), source ) then
			MC.QueueInventoryInput( MC.ContainerInput.QUICK_MOVE, target:GetActionIndex(), 0 )
		end
	end
	return true
end

local function creativePick( slot, count, target )
	local stack = IsValid( slot ) and slot:GetStack() or nil
	if MC.IsEmptyItemStack( stack ) then return false end
	local definition = MC.GetItem( stack.item )
	if not definition then return false end
	return MC.QueueCreativeInventoryPick( stack, count or definition.maxStack, target )
end

local function slotAtCursor( active )
	local source = active and active.slot
	local screen = IsValid( source ) and source.Screen or nil
	if not IsValid( screen ) or type( screen.SlotPanels ) ~= "table" then return active and active.hover end
	local mouseX, mouseY = gui.MousePos()
	for index = 1, screen.VisibleSlotCount or #screen.SlotPanels do
		local slot = screen.SlotPanels[index]
		if IsValid( slot ) and slot:IsVisible() and slot:IsMouseInputEnabled() then
			local x, y = slot:LocalToScreen( 0, 0 )
			if mouseX >= x and mouseY >= y and mouseX < x + slot:GetWide() and mouseY < y + slot:GetTall() then
				return slot
			end
		end
	end
	return nil
end

local function activateClick( active )
	local slot = active and active.slot
	if not IsValid( slot ) then return end
	if slot.Kind == "destroy" then
		MC.QueueCreativeInventoryClear( -1 )
		return
	end
	if slot.Kind == "creative" then
		-- Creative catalog slots are virtual.  When a cursor stack is carried,
		-- Minecraft consumes it on a left click instead of replacing it with the
		-- catalog entry; the server confirms the clear through the normal delta.
		if active.mouseCode == MOUSE_LEFT and not MC.IsEmptyItemStack( cursorStack() ) then
			MC.QueueCreativeInventoryClear( -1 )
			return
		end
		local definition = slot.Stack and MC.GetItem( slot.Stack.item ) or nil
		if not definition then return end
		local count = active.mouseCode == MOUSE_RIGHT and 1 or definition.maxStack
		local target = shiftDown() and ( MC.ClientInventory and MC.ClientInventory.selected or 0 ) or -1
		creativePick( slot, count, target )
		return
	end
	if not slot:IsInventorySlot() then return end
	local inputType, button
	local now = RealTime()
	local key = slotKey( slot )
	local previous = Drag.LastClick
	local isShift = shiftDown() and active.mouseCode ~= MOUSE_MIDDLE
	local isDouble = active.mouseCode == MOUSE_LEFT and active.hadStack
		and previous and previous.key == key and previous.mouseCode == MOUSE_LEFT
		and previous.cursorWasEmpty and previous.hadStack and now - previous.time <= DOUBLE_CLICK_TIME
	if isShift then
		if parityClicksEnabled() and isDouble and previous.shift and queueShiftDoubleClick( active, previous ) then
			Drag.LastClick = nil
			return
		end
		inputType, button = MC.ContainerInput.QUICK_MOVE, 0
		Drag.LastClick = {
			key = key, mouseCode = active.mouseCode, cursorWasEmpty = active.cursorWasEmpty,
			hadStack = active.hadStack, shift = true, lastQuickMoved = MC.CopyItemStack( slot:GetStack() ), time = now,
		}
	elseif active.mouseCode == MOUSE_MIDDLE then
		inputType, button = MC.ContainerInput.CLONE, 0
	elseif active.mouseCode == MOUSE_LEFT or active.mouseCode == MOUSE_RIGHT then
		if isDouble then
			inputType, button = MC.ContainerInput.PICKUP_ALL, 0
			Drag.LastClick = nil
		else
			inputType, button = MC.ContainerInput.PICKUP, active.mouseCode == MOUSE_RIGHT and 1 or 0
			Drag.LastClick = { key = key, mouseCode = active.mouseCode, cursorWasEmpty = active.cursorWasEmpty, hadStack = active.hadStack, time = now }
		end
	else
		return
	end
	MC.QueueInventoryInput( inputType, slot:GetActionIndex(), button )
end

local function craftTypeForMouse( mouseCode )
	if mouseCode == MOUSE_LEFT then return 0 end
	if mouseCode == MOUSE_RIGHT then return 1 end
	if mouseCode == MOUSE_MIDDLE and MC.ClientInventory and MC.ClientInventory.session
	and MC.ClientInventory.session.creative == true then return 2 end
	return nil
end

local function addQuickCraftSlot( active, slot )
	if not active.started or not IsValid( slot ) or not slot:CanQuickCraft() then return end
	local index = slot:GetActionIndex()
	if active.queued[index] then return end
	active.queued[index] = slot
	MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, index, active.craftType * 4 + 1 )
end

local function startQuickCraft( active )
	if active.started or MC.IsEmptyItemStack( cursorStack() ) or not active.slot:CanQuickCraft() then return false end
	local craftType = craftTypeForMouse( active.mouseCode )
	if craftType == nil then return false end
	active.started = true
	active.craftType = craftType
	active.queued = {}
	MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, craftType * 4 )
	addQuickCraftSlot( active, active.slot )
	addQuickCraftSlot( active, active.hover )
	return true
end

local function finishActive( activate )
	local active = Drag.Active
	if not active then return end
	Drag.Active = nil
	if active.started then
		if activate ~= false then
			MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 2 )
		end
	elseif activate ~= false and not active.activated then
		activateClick( active )
	end
end

function Drag.BeginPointer( slot, mouseCode )
	if not IsValid( slot ) or ( mouseCode ~= MOUSE_LEFT and mouseCode ~= MOUSE_RIGHT and mouseCode ~= MOUSE_MIDDLE ) then return end
	finishActive( false )
	local x, y = gui.MousePos()
	Drag.Active = {
		slot = slot,
		hover = slot,
		mouseCode = mouseCode,
		startX = x,
		startY = y,
		cursorWasEmpty = MC.IsEmptyItemStack( cursorStack() ),
		hadStack = not MC.IsEmptyItemStack( slot:GetStack() ),
		started = false,
		activated = false,
		queued = {},
	}
	if slot.MouseCapture then slot:MouseCapture( true ) end
	-- Vanilla executes clicks immediately when the cursor is empty.  Only a
	-- carried stack waits for release so the same gesture can become quick-craft.
	if Drag.Active.cursorWasEmpty then
		activateClick( Drag.Active )
		Drag.Active.activated = true
	end
end

function Drag.ReleasePointer( slot, mouseCode )
	local active = Drag.Active
	if not active then
		if Drag.SkipNextRelease then Drag.SkipNextRelease = nil end
		return
	end
	if active.mouseCode ~= mouseCode then
		-- AbstractContainerScreen cancels a quick-craft when a different mouse
		-- button is released; the following release of the initiating button is
		-- consumed and must not perform a normal pickup.
		if IsValid( active.slot ) and active.slot.MouseCapture then active.slot:MouseCapture( false ) end
		if parityClicksEnabled() then
			finishActive( false )
			Drag.SkipNextRelease = true
		end
		return
	end
	if IsValid( active.slot ) and active.slot.MouseCapture then active.slot:MouseCapture( false ) end
	finishActive( true )
end

function Drag.HoverSlot( slot )
	local active = Drag.Active
	if not active then return end
	active.hover = slot
	if active.started then addQuickCraftSlot( active, slot ) end
end

function Drag.IsQueued( slot )
	local active = Drag.Active
	local index = IsValid( slot ) and slot.GetActionIndex and slot:GetActionIndex() or nil
	return active and active.started and index ~= nil and active.queued[index] ~= nil or false
end

function Drag.Cancel()
	finishActive( false )
end

function Drag.ConsumeSkipRelease()
	if Drag.SkipNextRelease then Drag.SkipNextRelease = nil return true end
	return false
end

function Drag.DropOutside( mouseCode )
	if mouseCode ~= MOUSE_LEFT and mouseCode ~= MOUSE_RIGHT then return false end
	if MC.IsEmptyItemStack( cursorStack() ) then return false end
	if MC.ClientInventory and MC.ClientInventory.session and MC.ClientInventory.session.creative == true then
		return MC.QueueCreativeInventoryClear( -1 )
	end
	return MC.QueueInventoryInput( MC.ContainerInput.PICKUP, -999, mouseCode == MOUSE_RIGHT and 1 or 0 )
end

function Drag.HandleNumberKey( slot, hotbarIndex )
	hotbarIndex = math.floor( tonumber( hotbarIndex ) or -1 )
	if hotbarIndex < 0 or hotbarIndex > 8 or not IsValid( slot ) then return false end
	if slot.Kind == "creative" then return creativePick( slot, nil, hotbarIndex ) end
	if slot:IsInventorySlot() then return MC.QueueInventoryInput( MC.ContainerInput.SWAP, slot:GetActionIndex(), hotbarIndex ) end
	return false
end

function Drag.HandleOffhandKey( slot )
	if not parityClicksEnabled() then return false end
	if not IsValid( slot ) or not slot:IsInventorySlot() then return false end
	return MC.QueueInventoryInput( MC.ContainerInput.SWAP, slot:GetActionIndex(), 40 )
end

function Drag.HandleThrowKey( slot )
	if not IsValid( slot ) or not slot:IsInventorySlot() or slot.Kind == "result" then return false end
	return MC.QueueInventoryInput( MC.ContainerInput.THROW, slot:GetActionIndex(), controlDown() and 1 or 0 )
end

hook.Add( "Think", "mc_inventory_drag_input", function()
	local active = Drag.Active
	if not active then return end
	if not IsValid( active.slot ) then Drag.Active = nil return end
	if not input.IsMouseDown( active.mouseCode ) then
		if active.slot.MouseCapture then active.slot:MouseCapture( false ) end
		finishActive( true )
		return
	end
	if active.activated then return end
	if not active.started then
		local x, y = gui.MousePos()
		local dx, dy = x - active.startX, y - active.startY
		active.hover = slotAtCursor( active ) or active.hover
		if dx * dx + dy * dy >= MOVE_THRESHOLD_SQR then startQuickCraft( active ) end
	else
		active.hover = slotAtCursor( active )
		addQuickCraftSlot( active, active.hover )
	end
end )
