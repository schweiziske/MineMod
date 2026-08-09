-- Central pointer/drag state machine for Minecraft container input semantics.
-- Slots never move themselves; this module emits ordered menu actions and the
-- authoritative delta later refreshes the views.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Drag = UI.Drag or {}
UI.Drag = Drag

local MOVE_THRESHOLD_SQR = 16
local DOUBLE_CLICK_TIME = 0.28

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
	if slot.Kind == "inventory" then return "inventory:" .. tostring( slot.InventoryIndex ) end
	if slot.Kind == "creative" and slot.Stack then return "creative:" .. tostring( slot.Stack.item ) end
	return tostring( slot.Kind )
end

local function creativePick( slot, count, target )
	local stack = IsValid( slot ) and slot:GetStack() or nil
	if MC.IsEmptyItemStack( stack ) then return false end
	local definition = MC.GetItem( stack.item )
	if not definition then return false end
	return MC.QueueCreativeInventoryPick( definition, count or definition.maxStack, target )
end

local function activateClick( active )
	local slot = active and active.slot
	if not IsValid( slot ) then return end
	if slot.Kind == "destroy" then
		MC.QueueCreativeInventoryClear( -1 )
		return
	end
	if slot.Kind == "creative" then
		local definition = slot.Stack and MC.GetItem( slot.Stack.item ) or nil
		if not definition then return end
		local count = active.mouseCode == MOUSE_RIGHT and 1 or definition.maxStack
		local target = shiftDown() and ( MC.ClientInventory and MC.ClientInventory.selected or 0 ) or -1
		creativePick( slot, count, target )
		return
	end
	if not slot:IsInventorySlot() then return end
	local inputType, button
	if shiftDown() and active.mouseCode ~= MOUSE_MIDDLE then
		inputType, button = MC.ContainerInput.QUICK_MOVE, 0
	elseif active.mouseCode == MOUSE_MIDDLE then
		inputType, button = MC.ContainerInput.CLONE, 0
	elseif active.mouseCode == MOUSE_LEFT or active.mouseCode == MOUSE_RIGHT then
		local now = RealTime()
		local key = slotKey( slot )
		local previous = Drag.LastClick
		local double = active.mouseCode == MOUSE_LEFT and active.hadStack
			and previous and previous.key == key and previous.mouseCode == MOUSE_LEFT
			and previous.cursorWasEmpty and previous.hadStack and now - previous.time <= DOUBLE_CLICK_TIME
		if double then
			inputType, button = MC.ContainerInput.PICKUP_ALL, 0
			Drag.LastClick = nil
		else
			inputType, button = MC.ContainerInput.PICKUP, active.mouseCode == MOUSE_RIGHT and 1 or 0
			Drag.LastClick = { key = key, mouseCode = active.mouseCode, cursorWasEmpty = active.cursorWasEmpty, hadStack = active.hadStack, time = now }
		end
	else
		return
	end
	MC.QueueInventoryInput( inputType, slot.InventoryIndex, button )
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
	local index = slot.InventoryIndex
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
		MC.QueueInventoryInput( MC.ContainerInput.QUICK_CRAFT, -999, active.craftType * 4 + 2 )
	elseif activate ~= false then
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
		queued = {},
	}
	if slot.MouseCapture then slot:MouseCapture( true ) end
end

function Drag.ReleasePointer( slot, mouseCode )
	local active = Drag.Active
	if not active or active.mouseCode ~= mouseCode then return end
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
	return active and active.started and slot.InventoryIndex ~= nil and active.queued[slot.InventoryIndex] ~= nil or false
end

function Drag.Cancel()
	finishActive( false )
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
	if slot:IsInventorySlot() then return MC.QueueInventoryInput( MC.ContainerInput.SWAP, slot.InventoryIndex, hotbarIndex ) end
	return false
end

function Drag.HandleThrowKey( slot )
	if not IsValid( slot ) or not slot:IsInventorySlot() then return false end
	return MC.QueueInventoryInput( MC.ContainerInput.THROW, slot.InventoryIndex, controlDown() and 1 or 0 )
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
	if not active.started then
		local x, y = gui.MousePos()
		local dx, dy = x - active.startX, y - active.startY
		if dx * dx + dy * dy >= MOVE_THRESHOLD_SQR then startQuickCraft( active ) end
	elseif IsValid( active.hover ) then
		addQuickCraftSlot( active, active.hover )
	end
end )
