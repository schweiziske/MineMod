-- Server-authoritative selected inventory item -> managed SWEP switching.

if not SERVER then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local Bridge = MC.HandWeaponBridge
local SWITCH_CONFIRM_ATTEMPTS = 8

Bridge.PendingReconciles = Bridge.PendingReconciles or setmetatable( {}, { __mode = "k" } )
Bridge.SwitchGenerations = Bridge.SwitchGenerations or setmetatable( {}, { __mode = "k" } )

local function activeWeapon( ply )
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	return IsValid( weapon ) and weapon or nil
end

local function isInventoryProxy( weapon )
	if not IsValid( weapon ) then return false end
	if weapon.MCHandWeaponBridgeProxy == true then return true end
	return weapon.GetNW2Bool and weapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
end

local function mayAutoSwitch( weapon, context )
	if not IsValid( weapon ) then return context and context.allowMissingWeapon == true end
	local className = weapon:GetClass()
	if className == Bridge.HandClass or className == Bridge.InventoryClass then return true end
	if isInventoryProxy( weapon ) then return true end
	-- A spawn-menu weapon is standalone until the explicit switch hook proves
	-- that its class matches the authoritative selected stack. Resolver-wide
	-- managed-class membership alone must never let unrelated inventory events
	-- pull a weapon that is not actually present in the player's inventory.
	return context and context.allowManualAdoption == true and Bridge.IsManagedClass( weapon )
end

-- Server inventory actions use the same authoritative ownership gate as
-- reconciliation. A registered class alone does not make a standalone SWEP
-- an inventory proxy, and client switch prediction cannot authorize a packet.
function MC.API.HandWeapon.IsManagedActive( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	return mayAutoSwitch( activeWeapon( ply ) ) == true
end

MC.API.HandWeapon.IsInventoryActive = MC.API.HandWeapon.IsManagedActive

local function copyContext( context )
	local result = {}
	if istable( context ) then
		for key, value in pairs( context ) do result[key] = value end
	end
	return result
end

local function copyStack( stack )
	if not istable( stack ) then return nil end
	if MC.API and MC.API.DeepCopy then return MC.API.DeepCopy( stack ) end
	return table.Copy and table.Copy( stack ) or stack
end

local function setTransition( ply, targetClass )
	if not IsValid( ply ) then return end
	local active = isstring( targetClass ) and targetClass ~= ""
	if ply.SetNW2Bool then ply:SetNW2Bool( "MC_HandWeaponTransition", active ) end
	if ply.SetNW2String then ply:SetNW2String( "MC_HandWeaponTargetClass", active and targetClass or "" ) end
end

local function nextSwitchGeneration( ply )
	local generation = ( Bridge.SwitchGenerations[ply] or 0 ) + 1
	Bridge.SwitchGenerations[ply] = generation
	return generation
end

local function storedWeapon( className )
	return isstring( className ) and weapons and weapons.GetStored and weapons.GetStored( className ) or nil
end

local function ensureOwnedWeapon( ply, className )
	local existing = ply.GetWeapon and ply:GetWeapon( className ) or nil
	-- Garry's Mod only owns one SWEP instance per class. If the player acquired
	-- weapon_mcitem_* from the spawn menu, reuse that exact instance when the
	-- selected inventory stack resolves to its class and promote it to a proxy.
	if IsValid( existing ) then return existing end
	if not storedWeapon( className ) then return nil, "weapon_class_unavailable" end
	local weapon = ply:Give( className, true )
	if not IsValid( weapon ) and ply.GetWeapon then weapon = ply:GetWeapon( className ) end
	if not IsValid( weapon ) then return nil, "weapon_give_failed" end
	if className ~= Bridge.HandClass and className ~= Bridge.InventoryClass then
		weapon.MCHandWeaponBridgeProxy = true
		weapon:SetNW2Bool( "MCITEM_InventoryProxy", true )
	end
	return weapon
end

local function cleanupProxyWeapons( ply, keepClass )
	if not IsValid( ply ) then return end
	for _, weapon in ipairs( ply:GetWeapons() or {} ) do
		if isInventoryProxy( weapon ) and weapon:GetClass() ~= keepClass then
			weapon:Remove()
		end
	end
end

local function selectedStack( ply )
	return Bridge.GetSelected and Bridge.GetSelected( ply ) or nil
end

local function finishSwitch( ply, targetClass, targetWeapon, generation, attempt )
	if Bridge.SwitchGenerations[ply] ~= generation then return end
	if not IsValid( ply ) or not ply:Alive() or not IsValid( targetWeapon ) then
		setTransition( ply, nil )
		return
	end

	local currentWeapon = activeWeapon( ply )
	if currentWeapon == targetWeapon then
		setTransition( ply, nil )
		timer.Simple( 0, function()
			if Bridge.SwitchGenerations[ply] ~= generation then return end
			if activeWeapon( ply ) ~= targetWeapon then return end
			cleanupProxyWeapons( ply, targetClass )
		end )
		return
	end

	-- A deliberate switch to a foreign weapon cancels the pending inventory
	-- transition.  NULL or the previous inventory proxy is only an engine timing
	-- window, so retry without deleting either proxy.
	if IsValid( currentWeapon ) and not mayAutoSwitch( currentWeapon ) then
		setTransition( ply, nil )
		return
	end
	if attempt >= SWITCH_CONFIRM_ATTEMPTS then
		setTransition( ply, nil )
		if ErrorNoHalt then
			ErrorNoHalt( "[MC] hand weapon switch did not activate " .. targetClass .. "\n" )
		end
		return
	end

	ply:SelectWeapon( targetClass )
	timer.Simple( 0, function()
		finishSwitch( ply, targetClass, targetWeapon, generation, attempt + 1 )
	end )
end

function Bridge.QueueReconcile( ply, stack, context )
	if not IsValid( ply ) or not ply:IsPlayer() then return false, "invalid_player" end
	local pending = Bridge.PendingReconciles[ply]
	if not pending then
		pending = {}
		Bridge.PendingReconciles[ply] = pending
	end
	pending.stack = copyStack( stack )
	pending.context = copyContext( context )
	if pending.queued then return true end

	pending.queued = true
	timer.Simple( 0, function()
		local request = Bridge.PendingReconciles[ply]
		Bridge.PendingReconciles[ply] = nil
		if not request or not IsValid( ply ) then return end
		Bridge.Reconcile( ply, request.stack, request.context )
	end )
	return true
end

function Bridge.Reconcile( ply, stack, context )
	context = context or {}
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	local currentWeapon = activeWeapon( ply )
	if not mayAutoSwitch( currentWeapon, context ) then return false, "foreign_weapon_active" end
	local currentClass = IsValid( currentWeapon ) and currentWeapon:GetClass() or nil
	local generation = nextSwitchGeneration( ply )
	-- Any open inventory/container session owns the weapon lifecycle. Slot changes
	-- update the authoritative selection immediately, but the visible SWEP changes
	-- only after ClosePlayerInventory clears the session and republishes the held
	-- item. This keeps the screen open while clicking ordinary or enchanted tools.
	if Bridge.IsSelectionSessionOpen and Bridge.IsSelectionSessionOpen( ply ) then
		setTransition( ply, nil )
		return false, "inventory_screen_open"
	end

	stack = stack or selectedStack( ply )
	local targetClass = stack and select( 1, Bridge.Resolve( stack, ply ) ) or nil
	if targetClass and not storedWeapon( targetClass ) then targetClass = nil end
	targetClass = targetClass or Bridge.HandClass
	if not storedWeapon( targetClass ) then
		setTransition( ply, nil )
		return false, "fallback_weapon_unavailable"
	end

	local switching = currentClass ~= targetClass
	if switching then setTransition( ply, targetClass ) end
	local weapon, giveError = ensureOwnedWeapon( ply, targetClass )
	if not weapon then
		setTransition( ply, nil )
		return false, giveError
	end
	if targetClass ~= Bridge.HandClass and targetClass ~= Bridge.InventoryClass then
		weapon.MCHandWeaponBridgeProxy = true
		weapon:SetNW2Bool( "MCITEM_InventoryProxy", true )
		if Bridge.ApplyPresentation then Bridge.ApplyPresentation( weapon, stack, ply ) end
	end
	if switching then
		ply:SelectWeapon( targetClass )
		timer.Simple( 0, function()
			finishSwitch( ply, targetClass, weapon, generation, 1 )
		end )
	else
		setTransition( ply, nil )
		timer.Simple( 0, function()
			if Bridge.SwitchGenerations[ply] ~= generation then return end
			if activeWeapon( ply ) ~= weapon then return end
			cleanupProxyWeapons( ply, targetClass )
		end )
	end
	return true, targetClass
end

local refreshQueued = false
local function queueRefreshAll()
	if refreshQueued then return end
	refreshQueued = true
	timer.Simple( 0, function()
		refreshQueued = false
		for _, ply in ipairs( player.GetAll() ) do
			Bridge.Reconcile( ply, nil, { reason = "resolver_changed", allowMissingWeapon = true } )
		end
	end )
end

hook.Add( "MC.HandWeaponResolversChanged", "mc_hand_weapon_bridge_refresh_resolvers", queueRefreshAll )

hook.Add( "PlayerSwitchWeapon", "mc_hand_weapon_bridge_enter_inventory_hand", function( ply, _, newWeapon )
	if not IsValid( newWeapon ) then return end
	local className = newWeapon:GetClass()
	-- Integrations may still register a separate inventory-only entry point.
	if className == Bridge.InventoryClass then return end
	if className ~= Bridge.HandClass and not Bridge.IsManagedClass( className ) then
		-- Closing an inventory queues held-item reconciliation. A deliberate
		-- return to a GMod weapon must cancel that work before it can switch back.
		nextSwitchGeneration( ply )
		Bridge.PendingReconciles[ply] = nil
		setTransition( ply, nil )
		return
	end
	timer.Simple( 0, function()
		if not IsValid( ply ) or activeWeapon( ply ) ~= newWeapon then return end
		if className ~= Bridge.HandClass then
			-- Selecting a manual weapon_mcitem_* only adopts it when it represents
			-- the currently selected stack. A different class remains standalone
			-- until the player actually changes the Minecraft hotbar selection.
			local stack = selectedStack( ply )
			local resolved = stack and select( 1, Bridge.Resolve( stack, ply ) ) or nil
			if resolved ~= className then return end
		end
		Bridge.Reconcile( ply, nil, {
			reason = "entered_inventory_hand",
			allowManualAdoption = className ~= Bridge.HandClass,
		} )
	end )
end )

timer.Simple( 0, queueRefreshAll )

hook.Add( "PlayerDeath", "mc_hand_weapon_bridge_clear_transition_on_death", function( ply )
	nextSwitchGeneration( ply )
	Bridge.PendingReconciles[ply] = nil
	setTransition( ply, nil )
end )

hook.Add( "PlayerDisconnected", "mc_hand_weapon_bridge_clear_transition_on_disconnect", function( ply )
	Bridge.PendingReconciles[ply] = nil
	Bridge.SwitchGenerations[ply] = nil
end )
