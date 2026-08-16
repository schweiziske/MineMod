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
