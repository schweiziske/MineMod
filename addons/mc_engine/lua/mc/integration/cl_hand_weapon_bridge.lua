-- Client helpers shared by the hotbar, inventory lifecycle and block outline.

if not CLIENT then return end

MC = MC or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local Bridge = MC.HandWeaponBridge
local activeManagedWeapons = setmetatable( {}, { __mode = "k" } )
local transitionStates = setmetatable( {}, { __mode = "k" } )

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
	if not IsValid( ply ) then return nil end
	local request = ply:GetNW2String( "MC_HandWeaponSwitchRequest", "" )
	local state = transitionStates[ply]
	if not state then
		state = {}
		transitionStates[ply] = state
	end
	if state.request ~= request then
		state.request = request
		local generation, className = string.match( request, "^(%d+):(.+)$" )
		state.generation, state.class = tonumber( generation ), className
	end
	return state.class, state.generation
end

local pendingSelectionClass, pendingSelectionGeneration
local previousSelectionClass, selectionSource
local canceledGeneration
local nextSelectionAt = 0
local function pendingSelection( ply )
	local className, generation = transitionTarget( ply )
	if className ~= pendingSelectionClass or generation ~= pendingSelectionGeneration then
		previousSelectionClass = generation == pendingSelectionGeneration and pendingSelectionClass or nil
		if generation ~= pendingSelectionGeneration then selectionSource = activeWeapon( ply ) end
		pendingSelectionClass = className
		pendingSelectionGeneration = generation
		nextSelectionAt = 0
	end
	return className, generation
end

hook.Add( "CreateMove", "mc_hand_weapon_bridge_switch", function( command )
	local ply = LocalPlayer()
	local className, generation = pendingSelection( ply )
	if not className or not ply:Alive() or canceledGeneration == generation then return end
	local weapon = ply:GetWeapon( className )
	-- The target class can replicate before a newly given SWEP entity does.
	if not IsValid( weapon ) then return end
	local currentWeapon = activeWeapon( ply )
	-- PlayerSwitchWeapon is not predicted clientside in singleplayer. Observe
	-- an actual manual activation there too, and discard an already queued retry.
	if currentWeapon and currentWeapon ~= selectionSource and currentWeapon ~= weapon
	and currentWeapon:GetClass() ~= previousSelectionClass then
		canceledGeneration = generation
		command:SelectWeapon( currentWeapon )
		input.SelectWeapon( currentWeapon )
		return
	end
	if currentWeapon == weapon then
		-- Old-stage/source exemptions only cover delayed prediction. Once the
		-- target is active, returning to either weapon is a manual activation.
		previousSelectionClass, selectionSource = nil, weapon
		return
	end
	if CurTime() < nextSelectionAt then return end
	-- Some SWEPs temporarily veto Holster without scheduling their own retry
	-- (e.g. during a runaway burst). Retry through normal predicted selection.
	input.SelectWeapon( weapon )
	nextSelectionAt = CurTime() + 0.25
end )

hook.Add( "PlayerSwitchWeapon", "mc_hand_weapon_bridge_switch", function( ply, oldWeapon, newWeapon )
	if ply ~= LocalPlayer() or not IsValid( newWeapon ) then return end
	local className, generation = pendingSelection( ply )
	if not className or newWeapon:GetClass() == className then return end
	if newWeapon:GetClass() == previousSelectionClass
	and ( not IsValid( oldWeapon ) or oldWeapon:GetClass() ~= className ) then return end
	-- CreateMove may already have queued a retry for the next command. Replace
	-- it as well as canceling retries, including later stages of this same chain.
	canceledGeneration = generation
	input.SelectWeapon( newWeapon )
end )

local function selectedResolvesTo( ply, className )
	local stack = selectedPayload( ply )
	if not stack or not Bridge.Resolve then return false end
	local resolved = Bridge.Resolve( stack, ply )
	return resolved == className
end

local function managedWeaponActive( ply, selectedOnly )
	if not IsValid( ply ) or not ply:Alive() then
		if ply ~= nil then activeManagedWeapons[ply] = nil end
		return false
	end
	local weapon = activeWeapon( ply )
	local targetClass = transitionTarget( ply )
	if not weapon then return targetClass ~= nil end
	local className = weapon:GetClass()
	local managed = className == Bridge.HandClass or className == Bridge.InventoryClass
		or targetClass == className or isInventoryProxy( weapon )
		or activeManagedWeapons[ply] == weapon or selectedResolvesTo( ply, className )
	-- A local pick/slot change updates the selected payload before the outgoing
	-- SWEP's proxy flag or replacement arrives. Retain the identity we already
	-- observed; class membership alone must never capture a foreign weapon.
	activeManagedWeapons[ply] = managed and weapon or nil
	return managed and ( not selectedOnly or className ~= Bridge.InventoryClass )
end

-- Engine-side presentation state is deliberately expressed in generic terms.
-- The game addon may expose compatibility names for its own inventory/HUD
-- consumers, but the standalone engine must not define survival concepts.
function Bridge.IsClientManagedWeaponActive( ply )
	return managedWeaponActive( ply, false )
end

function Bridge.IsClientSelectedWeaponActive( ply )
	return managedWeaponActive( ply, true )
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

-- True while the server is mid-switch between managed weapons. Engine-internal
-- networked state is deliberately not read directly by consumers; hotbar input
-- needs this because a slot key pressed inside the switch window would
-- otherwise fall through to Garry's Mod weapon selection.
function MC.API.HandWeapon.IsManagedSwitchPending( ply )
	return transitionTarget( ply ) ~= nil
end

-- Public presentation facade. Game-owned hand weapons consume these stable
-- operations instead of reaching into the creative placer's pose, lighting,
-- or held-block renderer implementation.
function MC.API.HandWeapon.GetBlockFirstPersonPose( weapon, leftHand )
	if not MC.CreativeHeldFirstPersonPose then return nil, "presentation_unavailable" end
	return MC.CreativeHeldFirstPersonPose( weapon, leftHand == true )
end

function MC.API.HandWeapon.GetBlockThirdPersonPose( ply, leftHand )
	if not IsValid( ply ) then return nil, "invalid_player" end
	if not MC.CreativeHeldThirdPersonPose then return nil, "presentation_unavailable" end
	return MC.CreativeHeldThirdPersonPose( ply, leftHand == true )
end

function MC.API.HandWeapon.GetItemThirdPersonAnchor( ply, leftHand )
	if not IsValid( ply ) then return nil, "invalid_player" end
	if not MC.CreativeHeldThirdPersonAnchor then return nil, "presentation_unavailable" end
	return MC.CreativeHeldThirdPersonAnchor( ply, leftHand == true )
end

-- pos is MC world space; callers must convert engine/render anchors first.
function MC.API.HandWeapon.SamplePresentationLighting( pos, state )
	if not isvector( pos ) then return nil, "invalid_position" end
	if state ~= nil and not istable( state ) then return nil, "invalid_lighting_state" end
	if not MC.CreativeHeldLightingAt then return nil, "presentation_unavailable" end
	return MC.CreativeHeldLightingAt( pos, state )
end

function MC.API.HandWeapon.DrawBlockState( stateId, pos, ang, scale, lighting )
	stateId = math.floor( tonumber( stateId ) or 0 )
	if stateId <= 0 then return false, "invalid_state" end
	if not isvector( pos ) or not isangle( ang ) then return false, "invalid_transform" end
	if not MC.DrawCreativeHeldBlockState then return false, "presentation_unavailable" end
	return MC.DrawCreativeHeldBlockState( stateId, pos, ang,
		math.max( tonumber( scale ) or 0.001, 0.001 ), lighting ) == true
end

-- Compatibility names retained on the public API for existing game clients.
MC.API.HandWeapon.IsInventoryActive = MC.API.HandWeapon.IsManagedActive
MC.API.HandWeapon.IsHeldItemActive = MC.API.HandWeapon.IsSelectedActive
