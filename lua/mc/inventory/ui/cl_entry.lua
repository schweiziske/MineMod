-- Minecraft inventory entry/lifecycle bridge shared by both inventory SWEPs.

if not CLIENT then return end

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI

function UI.IsInventoryWeapon( weapon )
	if not IsValid( weapon ) then return false end
	local class = weapon:GetClass()
	return class == "mc_inventory" or class == "mc_item_hand"
end

function UI.ActiveInventoryWeapon()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	local weapon = ply:GetActiveWeapon()
	return UI.IsInventoryWeapon( weapon ) and weapon or nil
end

function UI.ToggleFromWeapon( weapon )
	if not UI.IsInventoryWeapon( weapon ) then return false end
	local owner = weapon:GetOwner()
	if IsValid( owner ) and owner ~= LocalPlayer() then return false end
	if IsValid( UI.Screen ) then
		UI.Screen:CloseInventory( true )
		return true
	end
	if MC.IsClientInventoryOpen and MC.IsClientInventoryOpen() then
		MC.CloseInventorySession()
		return true
	end
	return MC.RequestInventoryOpen and MC.RequestInventoryOpen() == true
end

function UI.CloseFromWeapon( reason )
	if IsValid( UI.Screen ) then
		UI.Screen:CloseInventory( true )
		return true
	end
	if MC.IsClientInventoryOpen and MC.IsClientInventoryOpen() then
		MC.CloseInventorySession()
		return true
	end
	return false
end

local function closeIfInvalid( reason )
	local state = MC.ClientInventory
	if not state or not state.session then return end
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() or not UI.ActiveInventoryWeapon() then
		UI.CloseFromWeapon( reason )
	end
end

hook.Add( "Think", "mc_inventory_weapon_lifecycle", function()
	closeIfInvalid( "weapon_changed" )
end )

hook.Add( "PlayerDeath", "mc_inventory_client_close_on_death", function( ply )
	if ply == LocalPlayer() then UI.CloseFromWeapon( "death" ) end
end )

hook.Add( "ShutDown", "mc_inventory_client_close_on_shutdown", function()
	UI.CloseFromWeapon( "shutdown" )
end )
