-- Server-authoritative selected inventory item -> managed SWEP switching.

if not SERVER then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local Bridge = MC.HandWeaponBridge
local SWITCH_CONFIRM_TIMEOUT = 10

Bridge.PendingReconciles = Bridge.PendingReconciles or setmetatable( {}, { __mode = "k" } )
Bridge.SwitchGenerations = Bridge.SwitchGenerations or setmetatable( {}, { __mode = "k" } )
Bridge.PendingSwitches = Bridge.PendingSwitches or setmetatable( {}, { __mode = "k" } )

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
	-- Publish the chain identity and target together; separately replicated
	-- fields can otherwise combine a new generation with an old target.
	ply:SetNW2String( "MC_HandWeaponSwitchRequest", active
		and tostring( Bridge.SwitchGenerations[ply] ) .. ":" .. targetClass or "" )
end

local function nextSwitchGeneration( ply )
	local generation = ( Bridge.SwitchGenerations[ply] or 0 ) % 2147483647 + 1
	Bridge.SwitchGenerations[ply] = generation
	Bridge.PendingSwitches[ply] = nil
	return generation
end

local function storedWeapon( className )
	return Bridge.WeaponAdapters[className]
		or ( isstring( className ) and weapons and weapons.GetStored and weapons.GetStored( className ) or nil )
end

local function ensureOwnedWeapon( ply, className, adapter )
	if adapter then return adapter.acquire( ply, className ) end
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
			if weapon.MCHandWeaponRetain then
				weapon.MCHandWeaponBridgeProxy = nil
				weapon.MCHandWeaponRetain = nil
				weapon:SetNW2Bool( "MCITEM_InventoryProxy", false )
			else
				weapon:Remove()
			end
		end
	end
end

local function selectedStack( ply )
	return Bridge.GetSelected and Bridge.GetSelected( ply ) or nil
end

local function beginSwitch( ply, targetWeapon, generation )
	local pending = {
		weapon = targetWeapon,
		class = targetWeapon:GetClass(),
		source = activeWeapon( ply ),
		generation = generation,
	}
	Bridge.PendingSwitches[ply] = pending
	setTransition( ply, pending.class )
	-- The client selects the owned entity in a predicted usercmd. Keep the old
	-- proxy alive until that command actually activates the target; do not force
	-- Deploy/Holster out of prediction with Player:SelectWeapon retries.
	timer.Simple( SWITCH_CONFIRM_TIMEOUT, function()
		if Bridge.PendingSwitches[ply] ~= pending then return end
		Bridge.PendingSwitches[ply] = nil
		setTransition( ply, nil )
		MC.Fault( "hand_weapon_switch_timeout", "Could not activate %s", pending.class )
	end )
end

local function confirmSwitch( ply, pending )
	Bridge.PendingSwitches[ply] = nil
	local destination = pending.nextWeapon
	if destination and destination ~= pending.weapon then
		if not IsValid( destination ) or destination:GetOwner() ~= ply then
			setTransition( ply, nil )
			MC.Fault( "hand_weapon_switch_target", "Queued switch target is no longer owned" )
			return
		end
		-- Keep the chain identity stable so a late network update cannot revive
		-- a chain the client already canceled with a manual selection.
		beginSwitch( ply, destination, pending.generation )
		return
	end
	setTransition( ply, nil )
	timer.Simple( 0, function()
		if Bridge.SwitchGenerations[ply] ~= pending.generation then return end
		if activeWeapon( ply ) ~= pending.weapon then return end
		cleanupProxyWeapons( ply, pending.class )
	end )
end

hook.Add( "StartCommand", "mc_hand_weapon_bridge_switch", function( ply, command )
	local pending = Bridge.PendingSwitches[ply]
	if not pending then return end
	if not IsValid( pending.weapon ) or pending.weapon:GetOwner() ~= ply then
		Bridge.PendingSwitches[ply] = nil
		setTransition( ply, nil )
		MC.Fault( "hand_weapon_switch_target", "Switch target %s is no longer owned", pending.class )
		return
	end
	local currentWeapon = activeWeapon( ply )
	if currentWeapon == pending.weapon then
		confirmSwitch( ply, pending )
		return
	end
	if currentWeapon ~= pending.source and IsValid( currentWeapon ) and not mayAutoSwitch( currentWeapon ) then
		Bridge.PendingSwitches[ply] = nil
		setTransition( ply, nil )
		return
	end
	-- Bots have no owning client to produce the predicted selection command.
	if ply:IsBot() then command:SelectWeapon( pending.weapon ) end
end )

function Bridge.SelectOwnedWeapon( ply, weapon )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	if not IsValid( weapon ) or not weapon:IsWeapon() or weapon:GetOwner() ~= ply then
		return false, "weapon_not_owned"
	end
	Bridge.PendingReconciles[ply] = nil
	local pending = Bridge.PendingSwitches[ply]
	if pending then
		pending.nextWeapon = weapon
		return true, weapon:GetClass()
	end
	local generation = nextSwitchGeneration( ply )
	if activeWeapon( ply ) == weapon then
		setTransition( ply, nil )
		return true, weapon:GetClass()
	end
	beginSwitch( ply, weapon, generation )
	return true, weapon:GetClass()
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
		if Bridge.PendingReconciles[ply] ~= pending then return end
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
	-- Any open inventory/container session owns the weapon lifecycle. Slot changes
	-- update the authoritative selection immediately, but the visible SWEP changes
	-- only after ClosePlayerInventory clears the session and republishes the held
	-- item. This keeps the screen open while clicking ordinary or enchanted tools.
	if Bridge.IsSelectionSessionOpen and Bridge.IsSelectionSessionOpen( ply ) then
		local pending = Bridge.PendingSwitches[ply]
		if pending then pending.nextWeapon = nil end
		return false, "inventory_screen_open"
	end

	stack = stack or selectedStack( ply )
	local targetClass = stack and select( 1, Bridge.Resolve( stack, ply ) ) or nil
	if targetClass and not storedWeapon( targetClass ) then targetClass = nil end
	targetClass = targetClass or Bridge.HandClass
	if not storedWeapon( targetClass ) then
		return false, "fallback_weapon_unavailable"
	end

	local switching = currentClass ~= targetClass
	local adapter = Bridge.WeaponAdapters[targetClass]
	if adapter and not adapter.matches( stack ) then adapter = nil end
	local weapon, giveError = ensureOwnedWeapon( ply, targetClass, adapter )
	if not weapon and adapter then
		-- A denied native/custom acquisition must not leave the previous slot's
		-- weapon active under the newly selected inventory stack.
		adapter = nil
		targetClass = Bridge.HandClass
		switching = currentClass ~= targetClass
		weapon, giveError = ensureOwnedWeapon( ply, targetClass )
	end
	if not weapon then
		return false, giveError
	end
	if targetClass ~= Bridge.HandClass and targetClass ~= Bridge.InventoryClass then
		weapon.MCHandWeaponBridgeProxy = true
		weapon.MCHandWeaponRetain = adapter and adapter.retain or nil
		weapon:SetNW2Bool( "MCITEM_InventoryProxy", true )
		if not adapter and Bridge.ApplyPresentation then
			Bridge.ApplyPresentation( weapon, stack, ply )
		end
		hook.Run( "MC.HandWeaponStackBound", ply, weapon, stack )
	end
	local pending = Bridge.PendingSwitches[ply]
	if pending then
		-- Delayed Holster has captured the current stage's target. Keep it and
		-- replace only the destination to request after that stage activates.
		pending.nextWeapon = weapon
		return true, targetClass
	end
	local generation = nextSwitchGeneration( ply )
	if switching then
		beginSwitch( ply, weapon, generation )
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
	local pending = Bridge.PendingSwitches[ply]
	if pending then
		-- Holster may veto or delay this event. Confirmation belongs to the next
		-- usercmd that observes the target active, not to this pre-switch hook.
		if newWeapon == pending.weapon then return end
		nextSwitchGeneration( ply )
		setTransition( ply, nil )
	end
	local className = newWeapon:GetClass()
	-- Integrations may still register a separate inventory-only entry point.
	if className == Bridge.InventoryClass then return end
	local selectedClass
	if className ~= Bridge.HandClass then
		local stack = selectedStack( ply )
		if stack then selectedClass = Bridge.Resolve( stack, ply ) end
	end
	if className ~= Bridge.HandClass and not isInventoryProxy( newWeapon ) and selectedClass ~= className then
		-- Closing an inventory queues held-item reconciliation. A deliberate
		-- return to a GMod weapon must cancel that work before it can switch back.
		local generation = nextSwitchGeneration( ply )
		Bridge.PendingReconciles[ply] = nil
		setTransition( ply, nil )
		timer.Simple( 0, function()
			if Bridge.SwitchGenerations[ply] ~= generation then return end
			if IsValid( ply ) and activeWeapon( ply ) == newWeapon then
				cleanupProxyWeapons( ply, className )
			end
		end )
		return
	end
	local generation = Bridge.SwitchGenerations[ply]
	timer.Simple( 0, function()
		if Bridge.SwitchGenerations[ply] ~= generation then return end
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
	Bridge.PendingSwitches[ply] = nil
	Bridge.SwitchGenerations[ply] = nil
end )
