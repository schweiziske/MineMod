--[[----------------------------------------------------------------------------
	Generic selected-item -> SWEP integration registry.

	MCSWEP deliberately knows nothing about external addon class names. Addons
	register resolvers through MC.API.HandWeapon; the server bridge only switches
	between mc_item_hand/mc_inventory and classes returned by those resolvers.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}
MC.HandWeaponBridge = MC.HandWeaponBridge or {}

local API = MC.API
local Bridge = MC.HandWeaponBridge

Bridge.Resolvers = Bridge.Resolvers or {}
Bridge.ResolverOrder = Bridge.ResolverOrder or {}
Bridge.ManagedClasses = Bridge.ManagedClasses or {}
Bridge.ResolverErrors = Bridge.ResolverErrors or {}

Bridge.HandClass = "mc_item_hand"
Bridge.InventoryClass = "mc_inventory"

local function validIdentifier( value, maximum )
	return isstring( value ) and value ~= "" and #value <= maximum
end

local function validClassName( className )
	return validIdentifier( className, 128 ) and string.match( className, "^[%w_%.%-]+$" ) ~= nil
end

local function classNameFor( value )
	if isstring( value ) then return value end
	if IsValid( value ) and isfunction( value.GetClass ) then return value:GetClass() end
	return nil
end

local function rebuildResolverOrder()
	local order = {}
	for id, entry in pairs( Bridge.Resolvers ) do
		order[#order + 1] = { id = id, priority = entry.priority, resolve = entry.resolve }
	end
	table.sort( order, function( left, right )
		if left.priority == right.priority then return left.id < right.id end
		return left.priority > right.priority
	end )
	Bridge.ResolverOrder = order
end

function Bridge.RegisterResolver( id, resolver, priority )
	if not validIdentifier( id, 64 ) then return false, "invalid_resolver_id" end
	if not isfunction( resolver ) then return false, "invalid_resolver" end
	priority = math.Clamp( math.floor( tonumber( priority ) or 0 ), -32768, 32767 )
	Bridge.Resolvers[id] = { resolve = resolver, priority = priority }
	Bridge.ResolverErrors[id] = nil
	rebuildResolverOrder()
	if MC.RunEvent then MC.RunEvent( "MC.HandWeaponResolversChanged", id ) end
	return true
end

function Bridge.UnregisterResolver( id )
	if not validIdentifier( id, 64 ) or not Bridge.Resolvers[id] then return false end
	Bridge.Resolvers[id] = nil
	Bridge.ResolverErrors[id] = nil
	rebuildResolverOrder()
	if MC.RunEvent then MC.RunEvent( "MC.HandWeaponResolversChanged", id ) end
	return true
end

function Bridge.RegisterManagedClass( className )
	className = classNameFor( className )
	if not validClassName( className ) then return false, "invalid_weapon_class" end
	if Bridge.ManagedClasses[className] then return true end
	Bridge.ManagedClasses[className] = true
	return true
end

function Bridge.UnregisterManagedClass( className )
	className = classNameFor( className )
	if not validClassName( className ) or not Bridge.ManagedClasses[className] then return false end
	Bridge.ManagedClasses[className] = nil
	return true
end

function Bridge.IsManagedClass( value )
	local className = classNameFor( value )
	return className ~= nil and Bridge.ManagedClasses[className] == true
end

function Bridge.IsInventoryControlledClass( value )
	local className = classNameFor( value )
	return className == Bridge.HandClass or className == Bridge.InventoryClass or Bridge.IsManagedClass( className )
end

local function resolverStackCopy( stack )
	if MC.CopyItemStack then return MC.CopyItemStack( stack ) end
	return API.DeepCopy and API.DeepCopy( stack ) or stack
end

function Bridge.Resolve( stack, ply )
	if type( stack ) ~= "table" or ( MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) ) then
		return nil, "empty_stack"
	end
	for _, entry in ipairs( Bridge.ResolverOrder ) do
		local called, resolved = pcall( entry.resolve, resolverStackCopy( stack ), ply )
		if not called then
			local message = tostring( resolved )
			if Bridge.ResolverErrors[entry.id] ~= message then
				Bridge.ResolverErrors[entry.id] = message
				if ErrorNoHalt then
					ErrorNoHalt( "[MC] hand weapon resolver " .. entry.id .. " failed: " .. message .. "\n" )
				end
			end
		elseif resolved ~= nil then
			if not validClassName( resolved ) then return nil, "invalid_resolved_weapon_class" end
			Bridge.ResolverErrors[entry.id] = nil
			Bridge.RegisterManagedClass( resolved )
			return resolved, entry.id
		end
	end
	return nil, "unresolved"
end

API.HandWeapon = API.HandWeapon or {}
local HandWeapon = API.HandWeapon

function HandWeapon.RegisterResolver( id, resolver, priority )
	return Bridge.RegisterResolver( id, resolver, priority )
end

function HandWeapon.UnregisterResolver( id )
	return Bridge.UnregisterResolver( id )
end

function HandWeapon.RegisterManagedClass( className )
	return Bridge.RegisterManagedClass( className )
end

function HandWeapon.UnregisterManagedClass( className )
	return Bridge.UnregisterManagedClass( className )
end

function HandWeapon.IsManagedClass( value )
	return Bridge.IsManagedClass( value )
end

function HandWeapon.IsInventoryControlledClass( value )
	return Bridge.IsInventoryControlledClass( value )
end

function HandWeapon.Resolve( stack, ply )
	return Bridge.Resolve( stack, ply )
end

function HandWeapon.Refresh( ply )
	if not SERVER then return false, "server_only" end
	if not Bridge.Reconcile then return false, "hand_weapon_bridge_unavailable" end
	return Bridge.Reconcile( ply, nil, { reason = "api_refresh" } )
end
