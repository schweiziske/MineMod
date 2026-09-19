-- Vanilla hotbar HUD and input routing for the inventory-driven hand SWEP.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local HandWeapon = MC.API and MC.API.HandWeapon or {}
local HOTBAR = UI.GetGuiMaterial( "hud/hotbar" )
local HOTBAR_SELECTION = UI.GetGuiMaterial( "hud/hotbar_selection" )
local selectedNameUntil = 0
local lastHandActiveAt = 0

local function handActive()
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return false end
	local weapon = ply:GetActiveWeapon()
	if not IsValid( weapon ) then
		return type( HandWeapon.IsInventoryActive ) == "function"
			and HandWeapon.IsInventoryActive( ply ) == true or false
	end
	if UI.IsInventoryWeapon then return UI.IsInventoryWeapon( weapon ) end
	if type( HandWeapon.IsInventoryActive ) == "function" then
		return HandWeapon.IsInventoryActive( ply ) == true
	end
	local class = weapon:GetClass()
	return class == "mc_item_hand" or class == "mc_inventory"
end

-- HUDPaint calls handActive() every frame while the hand is out, so wrapping it
-- here keeps the switch-grace stamp current instead of only refreshing it on a
-- key press.
local function handActiveNow()
	if not handActive() then return false end
	lastHandActiveAt = RealTime()
	return true
end

-- Switching hotbar slots makes the server swap the held SWEP, and a Garry's Mod
-- weapon switch is not instant: for a frame or two the active weapon can be the
-- outgoing proxy (already removed -> NULL) while the transition flag has been
-- cleared again. handActive() is false in exactly those frames, so a slot key
-- pressed there fell through to Garry's Mod weapon selection and yanked the
-- player onto the physgun. Switching fast just makes hitting that frame likely.
--
-- Consume the press through the whole switch instead. A deliberately held
-- foreign weapon is never NULL, so its slot keys keep working normally.
local SWITCH_GRACE = 0.5

local function hotbarInputActive()
	if handActiveNow() then return true end
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return false end
	if type( HandWeapon.IsManagedSwitchPending ) == "function"
	and HandWeapon.IsManagedSwitchPending( ply ) == true then return true end
	return not IsValid( ply:GetActiveWeapon() )
		and RealTime() - lastHandActiveAt < SWITCH_GRACE
end

local function inventoryScreenVisible()
	return IsValid( UI.Screen ) and UI.Screen:IsVisible()
end

local function inventoryTextEntryFocused()
	if not inventoryScreenVisible() or not vgui.GetKeyboardFocus then return false end
	local focus = vgui.GetKeyboardFocus()
	if not IsValid( focus ) then return false end
	local class = focus.GetClassName and focus:GetClassName() or ""
	return class == "TextEntry" or class == "DTextEntry"
end

local worldKeysDown = {}
local WORLD_KEYS = { [MOUSE_MIDDLE] = 0, [KEY_Q] = 1, [KEY_F] = 2 }

local function worldInputAvailable()
	return hotbarInputActive() and not inventoryScreenVisible()
		and not gui.IsGameUIVisible() and not vgui.CursorVisible()
		and not IsValid( vgui.GetKeyboardFocus() )
end

local function worldKeyPressed( button )
	local operation = WORLD_KEYS[button]
	if operation == nil or worldKeysDown[button] then return end
	worldKeysDown[button] = true
	if not worldInputAvailable() then return end
	local whole = input.IsKeyDown( KEY_LCONTROL ) or input.IsKeyDown( KEY_RCONTROL )
	MC.RequestInventoryWorldAction( operation, whole )
end

hook.Add( "PlayerButtonDown", "mc_inventory_world_shortcuts", function( ply, button )
	if ply == LocalPlayer() then worldKeyPressed( button ) end
end )
hook.Add( "PlayerButtonUp", "mc_inventory_world_shortcuts", function( ply, button )
	if ply == LocalPlayer() then worldKeysDown[button] = nil end
end )
-- Raw edges also cover an unbound middle button and single-player, where some
-- predicted PlayerButtonDown hooks are not delivered on the client.
hook.Add( "Think", "mc_inventory_world_shortcuts", function()
	for button in pairs( WORLD_KEYS ) do
		local down
		if button == MOUSE_MIDDLE then down = input.IsMouseDown( button ) else down = input.IsKeyDown( button ) end
		if down then worldKeyPressed( button ) else worldKeysDown[button] = nil end
	end
end )

local function selectedStack()
	local state = MC.ClientInventory
	return state and state.slots and state.slots[( state.selected or 0 ) + 1] or nil
end

local USE_INTERACT_OWN_COLLISION = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

local function traceHasForeignUseTarget( trace )
	if not trace or trace.HitWorld or not IsValid( trace.Entity ) then return false end
	return USE_INTERACT_OWN_COLLISION[trace.Entity:GetClass()] ~= true
end

local function announceSelection()
	selectedNameUntil = RealTime() + 2
end

hook.Add( "MC.InventorySelectionChanged", "mc_inventory_hotbar_selection_name", announceSelection )
hook.Add( "MC.InventoryChanged", "mc_inventory_hotbar_item_name", function( changed )
	if type( changed ) ~= "table" then return end
	local selected = MC.ClientInventory and MC.ClientInventory.selected or 0
	for _, index in ipairs( changed ) do if index == selected then announceSelection() return end end
end )

hook.Add( "HUDPaint", "mc_inventory_hotbar", function()
	if not handActiveNow() or inventoryScreenVisible() then return end
	local state = MC.ClientInventory or {}
	local slots = type( state.slots ) == "table" and state.slots or {}
	local scale = UI.HUDScale and UI.HUDScale() or UI.GuiScale()
	local offsetX, offsetY = 0, 0
	if UI.HUDOffset then offsetX, offsetY = UI.HUDOffset() end
	local width, height = 182 * scale, 22 * scale
	local x = math.floor( ScrW() * 0.5 - 91 * scale + offsetX )
	local y = ScrH() - height + offsetY
	UI.WithPointFiltering( function()
		UI.DrawTexture( HOTBAR, x, y, width, height )
		UI.DrawTexture( HOTBAR_SELECTION, x + ( ( state.selected or 0 ) * 20 - 1 ) * scale, y - scale, 24 * scale, 23 * scale )
	end )
	for index = 0, 8 do
		local stack = slots[index + 1]
		if not MC.IsEmptyItemStack( stack ) then
			UI.ItemRenderer.DrawStack( stack, x + ( 3 + index * 20 ) * scale, y + 3 * scale, 16 * scale, { scale = scale } )
		end
	end
	local stack = selectedStack()
	if RealTime() < selectedNameUntil and not MC.IsEmptyItemStack( stack ) then
		local definition = MC.GetItem( stack.item )
		local nameOffset = UI.SurvivalHUDBaseActive and UI.SurvivalHUDBaseActive() and 37 or 12
		UI.DrawText( UI.ItemRenderer.DisplayName( stack ), ScrW() * 0.5 + offsetX, y - nameOffset * scale, scale,
			UI.RarityColor( definition and definition.rarity ), TEXT_ALIGN_CENTER, true )
	end
end )

hook.Add( "PlayerBindPress", "mc_inventory_hotbar_input", function( ply, bind, pressed )
	if not pressed or ply ~= LocalPlayer() then return end
	bind = string.lower( tostring( bind or "" ) )
	-- Slot/scroll selection survives the switch window; opening the inventory
	-- does not, so +use still requires the hand to actually be out.
	local selectionBind = string.match( bind, "^slot([1-9])$" ) ~= nil
		or bind == "invnext" or bind == "invprev"
	if selectionBind then
		if not hotbarInputActive() then return end
	elseif not handActive() then
		return
	end
	if inventoryScreenVisible() then
		if bind == "+use" and not inventoryTextEntryFocused() then
			UI.Screen:CloseInventory( true )
			return true
		end
		return
	end
	if worldInputAvailable() and ( bind == "+menu" or bind == "impulse 100" or bind == "+attack3" ) then return true end
	local number = string.match( bind, "^slot([1-9])$" )
	if number then
		MC.SelectInventoryHotbarSlot( tonumber( number ) - 1 )
		return true
	end
	local selected = MC.ClientInventory and MC.ClientInventory.selected or 0
	if bind == "invnext" then
		MC.SelectInventoryHotbarSlot( ( selected + 1 ) % 9 )
		return true
	end
	if bind == "invprev" then
		MC.SelectInventoryHotbarSlot( ( selected + 8 ) % 9 )
		return true
	end
	if bind == "+use" then
		local trace = ply:GetEyeTrace()
		-- Foreign entities retain Garry's Mod's normal +use path. MC collision
		-- carriers are only implementation details and must not block the inventory key.
		if traceHasForeignUseTarget( trace ) then return end
		-- E is the inventory key, full stop. It used to send mc_block_use_request
		-- when the aimed block was usable, which made the inventory bind
		-- unreachable while looking at a chest/crafting table. Block interaction
		-- belongs to the weapon's own right-click gesture, not to +use.
		if MC.RequestInventoryOpen then MC.RequestInventoryOpen() end
		return true
	end
end )
