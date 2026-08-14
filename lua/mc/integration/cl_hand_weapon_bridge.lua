-- Client helpers shared by the hotbar, inventory lifecycle and block outline.

if not CLIENT then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local Bridge = MC.HandWeaponBridge

local function selectedStack( ply )
	if ply ~= LocalPlayer() then return nil end
	local state = MC.ClientInventory
	local selected = state and math.Clamp( math.floor( tonumber( state.selected ) or 0 ), 0, 8 ) or 0
	return state and state.slots and state.slots[selected + 1] or nil
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
	local stack = selectedStack( ply )
	if not stack or not Bridge.Resolve then return false end
	local resolved = Bridge.Resolve( stack, ply )
	return resolved == className
end

function Bridge.IsClientInventoryWeaponActive( ply )
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

function Bridge.IsClientHeldItemWeaponActive( ply )
	local weapon = activeWeapon( ply )
	local targetClass = transitionTarget( ply )
	if not weapon then return targetClass ~= nil end
	local className = weapon:GetClass()
	if className == Bridge.HandClass then return true end
	if targetClass == className then return true end
	return isInventoryProxy( weapon ) or selectedResolvesTo( ply, className )
end

function MC.IsInventoryWeaponActive( ply )
	return Bridge.IsClientInventoryWeaponActive( ply )
end

function MC.IsInventoryHeldItemWeaponActive( ply )
	return Bridge.IsClientHeldItemWeaponActive( ply )
end
