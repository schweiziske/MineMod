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

local function activeClass( ply )
	if not IsValid( ply ) or not ply:Alive() then return nil end
	local weapon = ply:GetActiveWeapon()
	return IsValid( weapon ) and weapon:GetClass() or nil
end

local function selectedResolvesTo( ply, className )
	local stack = selectedStack( ply )
	if not stack or not Bridge.Resolve then return false end
	local resolved = Bridge.Resolve( stack, ply )
	return resolved == className
end

function Bridge.IsClientInventoryWeaponActive( ply )
	local className = activeClass( ply )
	if not className then return false end
	if className == Bridge.HandClass or className == Bridge.InventoryClass then return true end
	return Bridge.IsManagedClass( className ) or selectedResolvesTo( ply, className )
end

function Bridge.IsClientHeldItemWeaponActive( ply )
	local className = activeClass( ply )
	if not className then return false end
	if className == Bridge.HandClass then return true end
	return Bridge.IsManagedClass( className ) or selectedResolvesTo( ply, className )
end

function MC.IsInventoryWeaponActive( ply )
	return Bridge.IsClientInventoryWeaponActive( ply )
end

function MC.IsInventoryHeldItemWeaponActive( ply )
	return Bridge.IsClientHeldItemWeaponActive( ply )
end
