-- Vanilla hotbar HUD and input routing for the inventory-driven hand SWEP.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local HOTBAR = UI.GetGuiMaterial( "hud/hotbar" )
local HOTBAR_SELECTION = UI.GetGuiMaterial( "hud/hotbar_selection" )
local selectedNameUntil = 0

local function handActive()
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return false end
	local weapon = ply:GetActiveWeapon()
	if not IsValid( weapon ) then return false end
	if MC.IsInventoryWeaponActive then return MC.IsInventoryWeaponActive( ply ) end
	local class = weapon:GetClass()
	return class == "mc_item_hand" or class == "mc_inventory"
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
	if not handActive() or inventoryScreenVisible() then return end
	local state = MC.ClientInventory or {}
	local slots = type( state.slots ) == "table" and state.slots or {}
	local scale = UI.GuiScale()
	local width, height = 182 * scale, 22 * scale
	local x = math.floor( ( ScrW() - width ) * 0.5 )
	local y = ScrH() - height - 8 * scale
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
		UI.DrawText( UI.ItemRenderer.DisplayName( stack ), ScrW() * 0.5, y - 12 * scale, scale,
			UI.RarityColor( definition and definition.rarity ), TEXT_ALIGN_CENTER, true )
	end
end )

hook.Add( "PlayerBindPress", "mc_inventory_hotbar_input", function( ply, bind, pressed )
	if not pressed or ply ~= LocalPlayer() or not handActive() then return end
	bind = string.lower( tostring( bind or "" ) )
	if inventoryScreenVisible() then
		if bind == "+use" and not inventoryTextEntryFocused() then
			UI.Screen:CloseInventory( true )
			return true
		end
		return
	end
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
		local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
		local usableBlock = aim and MC.Blocks and MC.Blocks[aim.Block]
		usableBlock = usableBlock and usableBlock.handlers and usableBlock.handlers.OnUse ~= nil
		-- Foreign entities retain Garry's Mod's normal +use path. MC collision
		-- carriers are only implementation details and must not block the inventory key.
		if traceHasForeignUseTarget( trace ) then return end
		if usableBlock then
			net.Start( "mc_block_use_request" )
			net.SendToServer()
			return true
		end
		if MC.RequestInventoryOpen then MC.RequestInventoryOpen() end
		return true
	end
end )
