-- Server-authoritative selected inventory item -> managed SWEP switching.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local SV = MC.SV
local Bridge = MC.HandWeaponBridge

local function activeWeaponClass( ply )
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	return IsValid( weapon ) and weapon:GetClass() or nil
end

local function mayAutoSwitch( className )
	return className ~= nil and Bridge.IsInventoryControlledClass( className )
end

local function storedWeapon( className )
	return isstring( className ) and weapons and weapons.GetStored and weapons.GetStored( className ) or nil
end

local function ensureOwnedWeapon( ply, className )
	local existing = ply.GetWeapon and ply:GetWeapon( className ) or nil
	if IsValid( existing ) then return existing end
	if not storedWeapon( className ) then return nil, "weapon_class_unavailable" end
	local weapon = ply:Give( className, true )
	if not IsValid( weapon ) and ply.GetWeapon then weapon = ply:GetWeapon( className ) end
	if not IsValid( weapon ) then return nil, "weapon_give_failed" end
	if className ~= Bridge.HandClass and className ~= Bridge.InventoryClass then
		weapon.MCHandWeaponBridgeProxy = true
	end
	return weapon
end

local function cleanupProxyWeapons( ply, keepClass )
	if not IsValid( ply ) then return end
	for _, weapon in ipairs( ply:GetWeapons() or {} ) do
		if IsValid( weapon ) and weapon.MCHandWeaponBridgeProxy == true and weapon:GetClass() ~= keepClass then
			weapon:Remove()
		end
	end
end

local function selectedStack( ply )
	return SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
end

function Bridge.Reconcile( ply, stack, context )
	context = context or {}
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	local currentClass = activeWeaponClass( ply )
	if not mayAutoSwitch( currentClass ) then return false, "foreign_weapon_active" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if currentClass == Bridge.InventoryClass and record and record.session then
		return false, "inventory_screen_open"
	end

	stack = stack or selectedStack( ply )
	local targetClass = stack and select( 1, Bridge.Resolve( stack, ply ) ) or nil
	if targetClass and not storedWeapon( targetClass ) then targetClass = nil end
	targetClass = targetClass or Bridge.HandClass
	if not storedWeapon( targetClass ) then return false, "fallback_weapon_unavailable" end

	local weapon, giveError = ensureOwnedWeapon( ply, targetClass )
	if not weapon then return false, giveError end
	if targetClass ~= Bridge.HandClass and targetClass ~= Bridge.InventoryClass then
		weapon:SetNW2Bool( "MCITEM_InventoryProxy", true )
		weapon:SetNW2Bool( "MCITEM_ItemFoil", stack and MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) or false )
	end
	if currentClass ~= targetClass then ply:SelectWeapon( targetClass ) end
	timer.Simple( 0, function() cleanupProxyWeapons( ply, targetClass ) end )
	return true, targetClass
end

hook.Add( "MC.PlayerHeldItemChanged", "mc_hand_weapon_bridge_selected_item", function( ply, _, stack, context )
	Bridge.Reconcile( ply, stack, context )
end )

local refreshQueued = false
local function queueRefreshAll()
	if refreshQueued then return end
	refreshQueued = true
	timer.Simple( 0, function()
		refreshQueued = false
		for _, ply in ipairs( player.GetAll() ) do Bridge.Reconcile( ply, nil, { reason = "resolver_changed" } ) end
	end )
end

hook.Add( "MC.HandWeaponResolversChanged", "mc_hand_weapon_bridge_refresh_resolvers", queueRefreshAll )

hook.Add( "PlayerSwitchWeapon", "mc_hand_weapon_bridge_enter_inventory_hand", function( ply, _, newWeapon )
	if not IsValid( newWeapon ) then return end
	local className = newWeapon:GetClass()
	if className ~= Bridge.HandClass and className ~= Bridge.InventoryClass then return end
	timer.Simple( 0, function()
		if IsValid( ply ) then Bridge.Reconcile( ply, nil, { reason = "entered_inventory_hand" } ) end
	end )
end )

timer.Simple( 0, queueRefreshAll )
