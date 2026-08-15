-- Client-only capabilities consumed by optional engine presentation code.

if not CLIENT then return end

MC = MC or {}

local API = MC.API
if not API then return end

-- Compatibility facade for the game-layer HUD and hand weapon. The engine
-- only exposes generic managed/selected-weapon state; survival terminology is
-- intentionally kept in this addon.
local HandWeapon = API.HandWeapon
if HandWeapon then
	function MC.IsInventoryWeaponActive( ply )
		return HandWeapon.IsManagedActive
			and HandWeapon.IsManagedActive( ply ) == true or false
	end

	function MC.IsInventoryHeldItemWeaponActive( ply )
		return HandWeapon.IsSelectedActive
			and HandWeapon.IsSelectedActive( ply ) == true or false
	end
end

if API.HandWeapon then
	API.HandWeapon.RegisterSelectionProvider( "mc.game.client_inventory", {
		GetSelected = function( ply )
			if ply ~= LocalPlayer() or not MC.GetClientSelectedStack then return nil end
			return MC.GetClientSelectedStack()
		end,
		IsSessionOpen = function( ply )
			return ply == LocalPlayer() and MC.IsClientInventoryOpen
				and MC.IsClientInventoryOpen() == true or false
		end,
	}, 100 )
end

API.RegisterCapability( "mc.game.item_renderer", 1, {
	DrawDroppedBlock = function( ... )
		local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
		if not renderer or not renderer.DrawDroppedBlock then return false end
		return renderer.DrawDroppedBlock( ... )
	end,
	DrawHeldItem = function( ... )
		local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
		if not renderer or not renderer.DrawHeldItem then return false end
		return renderer.DrawHeldItem( ... )
	end,
}, "mc.game" )

API.RegisterCapability( "mc.game.inventory_ui", 1, {
	ToggleFromWeapon = function( weapon )
		return MC.InventoryUI and MC.InventoryUI.ToggleFromWeapon
			and MC.InventoryUI.ToggleFromWeapon( weapon ) == true or false
	end,
	IsOpen = function()
		return MC.InventoryUI and IsValid( MC.InventoryUI.Screen ) or false
	end,
}, "mc.game" )
