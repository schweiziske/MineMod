-- Client helpers shared by the hotbar, inventory lifecycle and block outline.

if not CLIENT then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local Bridge = MC.HandWeaponBridge

local function selectedPayload( ply )
	return Bridge.GetSelected and Bridge.GetSelected( ply ) or nil
end

local function activeWeapon( ply )
	if not IsValid( ply ) or not ply:Alive() then return nil end
	local weapon = ply:GetActiveWeapon()
	return IsValid( weapon ) and weapon or nil
end

local function isInventoryProxy( weapon )
	return IsValid( weapon ) and weapon.GetNW2Bool
		and weapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
end

local function transitionTarget( ply )
	if not IsValid( ply ) or not ply.GetNW2Bool
	or ply:GetNW2Bool( "MC_HandWeaponTransition", false ) ~= true then return nil end
	local className = ply.GetNW2String and ply:GetNW2String( "MC_HandWeaponTargetClass", "" ) or ""
	return className ~= "" and className or nil
end

local function selectedResolvesTo( ply, className )
	local stack = selectedPayload( ply )
	if not stack or not Bridge.Resolve then return false end
	local resolved = Bridge.Resolve( stack, ply )
	return resolved == className
end

-- Engine-side presentation state is deliberately expressed in generic terms.
-- The game addon may expose compatibility names for its own inventory/HUD
-- consumers, but the standalone engine must not define survival concepts.
function Bridge.IsClientManagedWeaponActive( ply )
	local weapon = activeWeapon( ply )
	local targetClass = transitionTarget( ply )
	if not weapon then return targetClass ~= nil end
	local className = weapon:GetClass()
	if className == Bridge.HandClass or className == Bridge.InventoryClass then return true end
	if targetClass == className then return true end
	-- A managed class from the spawn menu is not an inventory weapon merely
	-- because a resolver knows its name. It enters the lifecycle only when the
	-- selected stack really resolves to it (prediction window) or the server has
	-- promoted that exact instance to an authoritative inventory proxy.
	return isInventoryProxy( weapon ) or selectedResolvesTo( ply, className )
end

function Bridge.IsClientSelectedWeaponActive( ply )
	local weapon = activeWeapon( ply )
	local targetClass = transitionTarget( ply )
	if not weapon then return targetClass ~= nil end
	local className = weapon:GetClass()
	if className == Bridge.HandClass then return true end
	if targetClass == className then return true end
	return isInventoryProxy( weapon ) or selectedResolvesTo( ply, className )
end

-- Public client queries. Game addons must not reach into HandWeaponBridge;
-- these wrappers are the supported boundary for HUD and inventory lifecycle.
MC.API = MC.API or {}
MC.API.HandWeapon = MC.API.HandWeapon or {}

function MC.API.HandWeapon.IsManagedActive( ply )
	return Bridge.IsClientManagedWeaponActive( ply )
end

function MC.API.HandWeapon.IsSelectedActive( ply )
	return Bridge.IsClientSelectedWeaponActive( ply )
end

-- Compatibility names retained on the public API for existing game clients.
MC.API.HandWeapon.IsInventoryActive = MC.API.HandWeapon.IsManagedActive
MC.API.HandWeapon.IsHeldItemActive = MC.API.HandWeapon.IsSelectedActive
