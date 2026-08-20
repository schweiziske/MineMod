--[[----------------------------------------------------------------------------
	MC : public API, shared layer (v2).

	The ONLY supported surface for external addons. Everything in MC.API:
	- late-binds to internals at call time (load order and autorefresh safe)
	- validates its inputs and returns "value|ok, err" instead of throwing
	- never leaks live internal tables (results are fresh copies)

	Block currency is the block-state id. Anywhere a "block" argument is
	accepted it may be:
	  number  -> a valid block-state id (NOT a legacy block id)
	  string  -> a blockstate spec: "stone", "minecraft:oak_stairs[facing=north]"
	  0 / nil / "air" -> air (removal)

	Events (hook.Run) fired by the core are listed in MC.API.Events.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API

-- Registration surfaces live at the top of this file so separately shipped
-- addons can discover them immediately.  Give them the same copy boundary as
-- the rest of the facade before the full utility section is declared below.
local function copyRegistrationValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do out[copyRegistrationValue( key, seen )] = copyRegistrationValue( child, seen ) end
	return out
end

local function registrationValuesEqual( left, right, seen )
	if type( left ) ~= type( right ) then return false end
	if type( left ) ~= "table" then return left == right end
	seen = seen or {}
	if seen[left] ~= nil then return seen[left] == right end
	seen[left] = right
	for key, value in pairs( left ) do
		if not registrationValuesEqual( value, right[key], seen ) then return false end
	end
	for key in pairs( right ) do
		if left[key] == nil then return false end
	end
	return true
end

API.VERSION = 2
-- The engine API remains v2.  The content-registration contract is versioned
-- independently so it can evolve as a v1.x surface without pretending that the
-- whole API was downgraded to v1.
API.ModRegistryVersion = API.ModRegistryVersion or ( MC.ModRegistryVersion or "1.0" )

------------------------------------------------------------------ identifiers
API.Identifiers = API.Identifiers or {}
function API.Identifiers.Normalize( value )
	if not MC.NormalizeResourceLocation then return nil, "identifier_api_unavailable" end
	return MC.NormalizeResourceLocation( value )
end

function API.Identifiers.Parts( value )
	if not MC.IdentifierParts then return nil, "identifier_api_unavailable" end
	return MC.IdentifierParts( value )
end

---------------------------------------------------------------- neutral creative registry
-- CreativeModeTab-shaped metadata belongs to the engine contract.  The game
-- layer later turns string item entries into ItemStacks; the engine never
-- imports or names that type.
API.Creative = API.Creative or {}
local Creative = API.Creative
local creativeRegistry = MC.ModRegistry

local function normalizeCreativeId( value )
	-- Category registry keys follow the same Identifier rules as blocks/items.
	-- A missing namespace therefore becomes minecraft:, never a legacy bare key.
	return MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( value )
		or MC.NormalizeResourceLocation and MC.NormalizeResourceLocation( value ) or nil
end

local function creativeEntryCopy( entry )
	if type( entry ) ~= "table" then return nil end
	local kind = tostring( entry.kind or "item" )
	if kind ~= "block" and kind ~= "item" and kind ~= "stack" then return nil end
	if kind == "stack" then
		local stack = entry.stack
		if type( stack ) ~= "table" then return nil end
		local item = stack.item or stack.id or stack.name
		item = MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( item )
			or MC.NormalizeResourceLocation and MC.NormalizeResourceLocation( item ) or nil
		if not item then return nil end
		local count = stack.count == nil and 1 or tonumber( stack.count )
		if count == nil or count ~= count or count == math.huge or count == -math.huge
			or count ~= math.floor( count ) or count ~= 1 then return nil end
		local damage = stack.damage == nil and 0 or tonumber( stack.damage )
		if damage == nil or damage ~= damage or damage == math.huge or damage == -math.huge
			or damage ~= math.floor( damage ) or damage < 0 then return nil end
		if stack.components ~= nil and type( stack.components ) ~= "table" then return nil end
		return {
			kind = "stack",
			stack = {
				item = item,
				count = 1,
				damage = damage > 0 and damage or nil,
				components = copyRegistrationValue( stack.components ),
			},
		}
	end
	local value = entry.name or entry.id or entry.item or entry.stack
	if value == nil then return nil end
	if type( value ) == "string" then
		local normalized = MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( value )
			or MC.NormalizeResourceLocation and MC.NormalizeResourceLocation( value ) or value
		if not normalized then return nil end
		return { kind = kind, name = normalized }
	end
	return nil
end

function Creative.RegisterCategory( definition )
	if MC.BlockStateRegistryFrozen or MC.ModBlockRegistryFrozen or MC.API._freezeStarted
		or MC.ModCreativeRegistryFrozen or ( MC.ModRegistry and MC.ModRegistry.creativeFrozen ) then
		return false, "registry_frozen"
	end
	if type( definition ) ~= "table" then return false, "invalid_definition" end
	local id = normalizeCreativeId( definition.id or definition.key or definition.name )
	if not id then return false, "invalid_identifier" end
	if creativeRegistry.creativeCategories[id] then return false, "duplicate_creative_category" end
	local row = string.lower( tostring( definition.row or "top" ) )
	if row ~= "top" and row ~= "bottom" then return false, "invalid_creative_row" end
	local column = tonumber( definition.column )
	if column == nil or column ~= math.floor( column ) or column < 0 or column > 6 then return false, "invalid_creative_column" end
	-- Vanilla occupies all fourteen page-zero slots.  Extra addon categories
	-- therefore live on explicit tab pages while retaining CreativeModeTab's
	-- row/column shape inside each page.
	local page = tonumber( definition.page )
	if page == nil then page = 1 end
	if page ~= math.floor( page ) or page < 1 or page > 31 then return false, "invalid_creative_page" end
	for _, existing in pairs( creativeRegistry.creativeCategories ) do
		if existing.page == page and existing.row == row and existing.column == column then
			return false, "creative_slot_occupied"
		end
	end
	local title = tostring( definition.title or id )
	local titleZH = tostring( definition.titleZH or title )
	local icon = definition.icon ~= nil
		and ( MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( definition.icon )
			or MC.NormalizeResourceLocation( definition.icon ) ) or nil
	if definition.icon ~= nil and not icon then return false, "invalid_creative_icon" end
	local background = definition.background ~= nil and tostring( definition.background ) or "items"
	if background ~= "items" and background ~= "item_search" and background ~= "inventory" then
		return false, "invalid_creative_background"
	end
	local record = {
		id = id, key = id, row = row, column = column, page = page, title = title, titleZH = titleZH,
		titleKey = definition.titleKey, icon = icon,
		background = background, showTitle = definition.showTitle ~= false,
		canScroll = definition.canScroll ~= false,
	}
	creativeRegistry.creativeCategories[id] = record
	creativeRegistry.creativeEntries[id] = creativeRegistry.creativeEntries[id] or {}
	creativeRegistry.creativeOrder[#creativeRegistry.creativeOrder + 1] = id
	return true, copyRegistrationValue( record )
end

local function registerCreativeEntry( categoryId, entry )
	if MC.BlockStateRegistryFrozen or MC.ModBlockRegistryFrozen or MC.API._freezeStarted
		or MC.ModCreativeRegistryFrozen or ( MC.ModRegistry and MC.ModRegistry.creativeFrozen ) then return false, "registry_frozen" end
	local id = normalizeCreativeId( categoryId )
	if not id or not creativeRegistry.creativeCategories[id] then return false, "unknown_creative_category" end
	local normalized = creativeEntryCopy( entry )
	if not normalized then return false, "invalid_creative_entry" end
	if normalized.name == nil and normalized.kind ~= "stack" then return false, "invalid_identifier" end
	-- Do not resolve the target during bootstrap. CreativeModeTab generators
	-- are allowed to mention a block/item registered later in the same
	-- `MC.API.OnRegister` phase; the game adapter's freeze callback binds every
	-- reference after item runtime ids have been assigned. Syntax is validated
	-- above, so malformed ids still fail immediately without importing mc_game.
	local entries = creativeRegistry.creativeEntries[id]
	for _, existing in ipairs( entries ) do
		local sameNamedEntry = normalized.kind ~= "stack"
			and existing.kind == normalized.kind and existing.name == normalized.name
		local sameStackEntry = normalized.kind == "stack" and existing.kind == "stack"
			and registrationValuesEqual( existing.stack, normalized.stack )
		if sameNamedEntry or sameStackEntry then return false, "duplicate_creative_entry" end
	end
	entries[#entries + 1] = normalized
	if normalized.kind == "block" and normalized.name then
		creativeRegistry.creativeBlockCategories[normalized.name] = creativeRegistry.creativeBlockCategories[normalized.name] or {}
		creativeRegistry.creativeBlockCategories[normalized.name][id] = true
	end
	return true
end

function Creative.RegisterBlock( categoryId, blockName )
	if MC.ValidateModContentIdentifier and not MC.ValidateModContentIdentifier( blockName ) then return false, "invalid_identifier" end
	return registerCreativeEntry( categoryId, { kind = "block", name = blockName } )
end

function Creative.RegisterItem( categoryId, itemName )
	if MC.ValidateModContentIdentifier and not MC.ValidateModContentIdentifier( itemName ) then return false, "invalid_identifier" end
	return registerCreativeEntry( categoryId, { kind = "item", name = itemName } )
end

function Creative.RegisterStack( categoryId, stack )
	if type( stack ) ~= "table" then return false, "invalid_creative_entry" end
	return registerCreativeEntry( categoryId, { kind = "stack", stack = stack } )
end

function Creative.ListCategories()
	local out = {}
	for _, id in ipairs( creativeRegistry.creativeOrder or {} ) do
		local category = creativeRegistry.creativeCategories[id]
		if category then
			local copy = copyRegistrationValue( category )
			copy.entries = copyRegistrationValue( creativeRegistry.creativeEntries[id] or {} )
			out[#out + 1] = copy
		end
	end
	return out
end

function Creative.GetCategory( id )
	id = normalizeCreativeId( id )
	local category = id and creativeRegistry.creativeCategories[id] or nil
	if not category then return nil, "unknown_creative_category" end
	local copy = copyRegistrationValue( category )
	copy.entries = copyRegistrationValue( creativeRegistry.creativeEntries[id] or {} )
	return copy
end

function Creative.IsFrozen()
	return MC.BlockStateRegistryFrozen == true or MC.API._freezeStarted == true
		or MC.ModCreativeRegistryFrozen == true or creativeRegistry.creativeFrozen == true
end

---------------------------------------------------------------- item contract stub
-- The engine owns the neutral queue only.  mc_game replaces these methods with
-- the real item registry adapter when its shared layer is loaded.
API.Items = API.Items or {}
local Items = API.Items
MC.ModPendingItemDefinitions = MC.ModPendingItemDefinitions or {}

local function itemDefinitionName( definition )
	if type( definition ) ~= "table" then return nil, "invalid_definition" end
	local raw = definition.id or definition.name
	local name = MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( raw )
		or MC.NormalizeResourceLocation and MC.NormalizeResourceLocation( raw ) or nil
	if not name then return nil, "invalid_identifier" end
	return name
end

function Items.Register( definition )
	if MC.BlockStateRegistryFrozen or API._freezeStarted or API._ready then return nil, "registry_frozen" end
	local name, err = itemDefinitionName( definition )
	if not name then return nil, err end
	local blockName
	if definition.block ~= nil then
		blockName = MC.ValidateModContentIdentifier and MC.ValidateModContentIdentifier( definition.block )
			or MC.NormalizeResourceLocation and MC.NormalizeResourceLocation( definition.block ) or nil
		if not blockName then return nil, "invalid_block_item" end
		-- In an engine-only load there may be no block resolver yet. Keep the
		-- canonical target in the pending definition and defer only the existence
		-- check to the game adapter; when a resolver is available, fail early.
		if MC.ResolveBlock and not MC.ResolveBlock( blockName ) then return nil, "unknown_block" end
	end
	if MC.ModPendingItemDefinitions[name] then return nil, "duplicate_item" end
	local queued = copyRegistrationValue( definition )
	queued.name, queued.id = name, nil
	-- Persist the same canonical spelling that was validated above.  In
	-- particular, Identifier's ":stone" shorthand must not reach the game
	-- adapter as a raw value that its legacy item normalizer cannot replay.
	if blockName ~= nil then queued.block = blockName end
	MC.ModPendingItemDefinitions[name] = queued
	return true, { name = name, pending = true }
end

function Items.Resolve( _ )
	return nil, "item_registry_unavailable"
end

function Items.RuntimeId( _ )
	return nil, "item_registry_unavailable"
end

function Items.NameForRuntimeId( _ )
	return nil, "item_registry_unavailable"
end

function Items.ListNames()
	return nil, "item_registry_unavailable"
end

function Items.RegistrySnapshot()
	return nil, "item_registry_unavailable"
end

------------------------------------------------------------- block loot contract stub
-- The engine owns only a neutral, namespace-only queue. mc_game replaces this
-- method with the ItemStack-aware adapter and validates the BlockItem binding
-- at the shared bootstrap freeze boundary.
API.BlockLoot = API.BlockLoot or {}
local BlockLoot = API.BlockLoot
MC.ModPendingBlockLootDefinitions = MC.ModPendingBlockLootDefinitions or {}

local function modContentName( value )
	local name, err
	if MC.ValidateModContentIdentifier then
		name, err = MC.ValidateModContentIdentifier( value )
	elseif MC.NormalizeResourceLocation then
		name = MC.NormalizeResourceLocation( value )
	end
	return name, err or ( name and nil or "invalid_identifier" )
end

-- Register vanilla-style dropSelf behavior for a custom block. If itemName is
-- omitted, mc_game resolves the BlockItem bound to blockName at freeze time.
-- The existing `drops`/`lootTable` block-definition fields stay unsupported;
-- this separate adapter is the only public path that is actually consumed.
function BlockLoot.RegisterDefaultBlockItem( blockName, itemName )
	if MC.BlockStateRegistryFrozen or API._freezeStarted or API._ready then
		return nil, "registry_frozen"
	end
	local canonicalBlock, identifierError = modContentName( blockName )
	if not canonicalBlock then return nil, identifierError end
	if MC.ResolveBlock and not MC.ResolveBlock( canonicalBlock ) then return nil, "unknown_block" end
	local canonicalItem
	if itemName ~= nil then
		canonicalItem, identifierError = modContentName( itemName )
		if not canonicalItem then return nil, identifierError end
	end
	if MC.ModPendingBlockLootDefinitions[canonicalBlock] then return nil, "duplicate_block_loot" end
	MC.ModPendingBlockLootDefinitions[canonicalBlock] = {
		block = canonicalBlock,
		item = canonicalItem,
	}
	return true, {
		block = canonicalBlock,
		item = canonicalItem,
		pending = true,
	}
end

-------------------------------------------------------------------- event core
-- Core write paths call these; they exist on both realms. Listener errors are
-- contained so a broken external addon can never abort a world transaction.
function MC.EventHasListeners( name )
	local registry = hook.GetTable()
	local listeners = registry and registry[name]
	return listeners ~= nil and next( listeners ) ~= nil
end

function MC.RunEvent( name, ... )
	local ok, result = pcall( hook.Run, name, ... )
	if not ok then
		local message = "[MC] event listener error in " .. tostring( name ) .. ": " .. tostring( result ) .. "\n"
		if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		return nil
	end
	return result
end

--------------------------------------------------------------------- lifecycle
-- Two phases. Both replay for late subscribers, so an addon shipped separately
-- from the engine is immune to Garry's Mod autorun order:
--   register (MC.APIAvailable) : block/state registries are still OPEN.
--                                Register content, handlers and resolvers here.
--   ready    (MC.APIReady)     : registries frozen; the full API is usable.
--                                Start networking, UI and timers here.
--
-- The register phase stays usable across addons only because the registry
-- freeze runs on a zero-delay timer (sh_block_states.lua), i.e. after every
-- autorun file in the load tick. Do not make that freeze synchronous.
--
-- Canonical bootstrap for a separate addon (covers both load orders, and needs
-- no redundant OnReloaded/timer retries):
--   local function boot() ... end
--   if MC and MC.API and MC.API.OnRegister then MC.API.OnRegister( boot )
--   else hook.Add( "MC.APIAvailable", "myaddon_boot", boot ) end
local registerCallbacks = {}
local readyCallbacks = {}
local freezeCallbacks = {}

local function runPhaseCallbacks( queued, phase )
	for _, cb in ipairs( queued ) do
		local ok, err = pcall( cb )
		if not ok then ErrorNoHalt( "[MC] API." .. phase .. " callback error: " .. tostring( err ) .. "\n" ) end
	end
end

function API.IsAvailable()
	return API._available == true
end

function API.IsReady()
	return API._ready == true
end

-- Runs cb immediately if the register phase already happened, otherwise queues
-- it. Use this (not OnReady) to register blocks, items, handlers and resolvers:
-- once the registries freeze, registration is rejected.
function API.OnRegister( cb )
	if not isfunction( cb ) then return false end
	if API._available then
		local ok, err = pcall( cb )
		if not ok then ErrorNoHalt( "[MC] API.OnRegister callback error: " .. tostring( err ) .. "\n" ) end
		return true
	end
	registerCallbacks[#registerCallbacks + 1] = cb
	return true
end

-- Runs cb immediately if the API is ready, otherwise queues it. This is the
-- load-order safe way for an external addon to start using MC.API.
function API.OnReady( cb )
	if not isfunction( cb ) then return false end
	if API._ready then
		local ok, err = pcall( cb )
		if not ok then ErrorNoHalt( "[MC] API.OnReady callback error: " .. tostring( err ) .. "\n" ) end
		return true
	end
	readyCallbacks[#readyCallbacks + 1] = cb
	return true
end

-- Internal cross-addon bootstrap seam. The engine owns the freeze boundary;
-- optional consumers may contribute a finalizer without being imported here.
function API._RegisterFreezeCallback( owner, cb )
	if API._freezeStarted then return false, "registry_frozen" end
	if not isfunction( cb ) then return false, "invalid_freeze_callback" end
	owner = tostring( owner or "addon" )
	for _, record in ipairs( freezeCallbacks ) do
		if record.owner == owner then return false, "duplicate_freeze_callback" end
	end
	freezeCallbacks[#freezeCallbacks + 1] = { owner = owner, callback = cb }
	return true
end

function API._RunFreezeCallbacks()
	if API._freezeStarted then
		return API._freezeFailed ~= true, API._freezeError
	end
	API._freezeStarted = true
	local callbacks = freezeCallbacks
	freezeCallbacks = {}
	for _, record in ipairs( callbacks ) do
		local ok, callbackResult, callbackError = pcall( record.callback )
		if not ok or callbackResult == false then
			local reason = not ok and callbackResult or callbackError or "callback_returned_false"
			local reasonText = tostring( reason )
			if reasonText == "" then reasonText = "callback_returned_false" end
			if not API._freezeFailed then
				API._freezeError = "registry_freeze_failed:" .. tostring( record.owner ) .. ":" .. reasonText
			end
			API._freezeFailed = true
			local message = "[MC] API freeze callback '" .. tostring( record.owner )
				.. "' failed: " .. reasonText .. "\n"
			if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		end
	end
	return API._freezeFailed ~= true, API._freezeError
end

-- Engine/API version negotiation for separately shipped addons.  String ids
-- late-bind to the manifest module so this overload survives a single-file
-- autorefresh of sh_api.lua; numeric calls retain the original v2 behavior.
function API.Require( requirement, versionRange, addonName )
	if type( requirement ) == "string" then
		local label = tostring( addonName or "addon" )
		if not API._ManifestDependencyStatus then
			local err = "manifest_api_unavailable"
			local message = label .. " dependency check failed for " .. tostring( requirement )
				.. ": " .. err
			if ErrorNoHalt then ErrorNoHalt( "[MC] " .. message .. "\n" ) else print( "[MC] " .. message ) end
			return false, err
		end
		local ok, err = API._ManifestDependencyStatus( requirement, versionRange or "*", label )
		if ok then return true end
		local message = label .. " dependency check failed for " .. tostring( requirement )
			.. ": " .. tostring( err )
		if ErrorNoHalt then ErrorNoHalt( "[MC] " .. message .. "\n" ) else print( "[MC] " .. message ) end
		return false, err
	end
	local wanted = math.floor( tonumber( requirement ) or 0 )
	local label = tostring( versionRange or "addon" )
	if API.VERSION < wanted then
		local err = label .. " requires MC API v" .. wanted .. ", engine provides v" .. API.VERSION
		ErrorNoHalt( "[MC] " .. err .. "\n" )
		return false, err
	end
	return true
end

-- Called once by the loader while the registries are still open.
function API._FireAvailable()
	if API._available then return end
	API._available = true
	MC.RunEvent( "MC.APIAvailable", API.VERSION )
	local queued = registerCallbacks
	registerCallbacks = {}
	runPhaseCallbacks( queued, "OnRegister" )
end

-- Called once by the loader after the block/state registries have frozen.
function API._FireReady()
	if API._ready then return end
	if API._freezeFailed then return false, API._freezeError or "registry_freeze_failed" end
	API._ready = true
	MC.RunEvent( "MC.APIReady", API.VERSION )
	local queued = readyCallbacks
	readyCallbacks = {}
	runPhaseCallbacks( queued, "OnReady" )
end

--------------------------------------------------------------------- utilities
local function deepCopy( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[deepCopy( key, seen )] = deepCopy( item, seen ) end
	return out
end

API.DeepCopy = deepCopy

--------------------------------------------------------------- API capabilities
-- Optional surfaces supplied by separately shipped addons. Core callers use
-- GetCapability/OnCapability instead of probing another layer's private tables;
-- registration is replay-safe and reports an explicit per-capability version.
API._capabilities = API._capabilities or {}
API._capabilityCallbacks = API._capabilityCallbacks or {}

local function capabilityName( value )
	local name = string.lower( string.Trim( tostring( value or "" ) ) )
	if name == "" or #name > 128 then return nil end
	if not string.match( name, "^[a-z0-9_.:-]+$" ) then return nil end
	return name
end

local function capabilityOwner( value )
	local owner = tostring( value or "" )
	if owner == "" or #owner > 128 then return nil end
	return owner
end

local function capabilitySurface( surface )
	if not istable( surface ) then return nil end
	local copy = {}
	for key, value in pairs( surface ) do copy[key] = value end
	return copy
end

function API.RegisterCapability( name, version, surface, owner )
	name = capabilityName( name )
	owner = capabilityOwner( owner )
	version = math.floor( tonumber( version ) or 0 )
	local published = capabilitySurface( surface )
	if not name then return false, "invalid_capability_name" end
	if not owner then return false, "invalid_capability_owner" end
	if version < 1 then return false, "invalid_capability_version" end
	if not published then return false, "invalid_capability_surface" end
	local existing = API._capabilities[name]
	if existing and existing.owner ~= owner then return false, "capability_owned" end
	API._capabilities[name] = { name = name, version = version, surface = published, owner = owner }
	local callbacks = API._capabilityCallbacks[name]
	if callbacks then
		local pending = {}
		for _, request in ipairs( callbacks ) do
			if version >= request.minimum then
				local ok, err = pcall( request.callback, published, version, owner )
				if not ok and ErrorNoHalt then
					ErrorNoHalt( "[MC] capability callback " .. name .. " failed: " .. tostring( err ) .. "\n" )
				end
			else
				pending[#pending + 1] = request
			end
		end
		API._capabilityCallbacks[name] = #pending > 0 and pending or nil
	end
	MC.RunEvent( "MC.APICapabilityAvailable", name, version, published, owner )
	return true, published
end

function API.UnregisterCapability( name, owner )
	name = capabilityName( name )
	owner = capabilityOwner( owner )
	local existing = name and API._capabilities[name] or nil
	if not existing then return false, "capability_unavailable" end
	if not owner or existing.owner ~= owner then return false, "capability_owner_mismatch" end
	API._capabilities[name] = nil
	MC.RunEvent( "MC.APICapabilityRemoved", name, existing.version, owner )
	return true
end

function API.GetCapability( name, minimumVersion )
	name = capabilityName( name )
	if not name then return nil, "invalid_capability_name" end
	local entry = API._capabilities[name]
	if not entry then return nil, "capability_unavailable" end
	local minimum = math.max( 1, math.floor( tonumber( minimumVersion ) or 1 ) )
	if entry.version < minimum then return nil, "capability_version_too_old", entry.version end
	return entry.surface, nil, entry.version, entry.owner
end

function API.HasCapability( name, minimumVersion )
	return API.GetCapability( name, minimumVersion ) ~= nil
end

function API.RequireCapability( name, minimumVersion, addonName )
	local surface, err, actual = API.GetCapability( name, minimumVersion )
	if surface then return surface, actual end
	local label = tostring( addonName or "addon" )
	local wanted = math.max( 1, math.floor( tonumber( minimumVersion ) or 1 ) )
	local message = label .. " requires capability " .. tostring( name ) .. " v" .. tostring( wanted )
		.. ( actual and ", provider has v" .. tostring( actual ) or "" )
	if ErrorNoHalt then ErrorNoHalt( "[MC] " .. message .. "\n" ) end
	return nil, err or "capability_unavailable"
end

function API.OnCapability( name, minimumVersion, callback )
	name = capabilityName( name )
	local minimum = math.max( 1, math.floor( tonumber( minimumVersion ) or 1 ) )
	if not name then return false, "invalid_capability_name" end
	if not isfunction( callback ) then return false, "invalid_callback" end
	local entry = API._capabilities[name]
	if entry and entry.version >= minimum then
		local ok, err = pcall( callback, entry.surface, entry.version, entry.owner )
		if not ok and ErrorNoHalt then
			ErrorNoHalt( "[MC] capability callback " .. name .. " failed: " .. tostring( err ) .. "\n" )
		end
		return true
	end
	local callbacks = API._capabilityCallbacks[name] or {}
	callbacks[#callbacks + 1] = { minimum = minimum, callback = callback }
	API._capabilityCallbacks[name] = callbacks
	return true
end

API.Events = API.Events or {}
API._eventOwners = API._eventOwners or {}

function API.RegisterEvents( owner, definitions )
	owner = capabilityOwner( owner )
	if not owner then return false, "invalid_event_owner" end
	if not istable( definitions ) then return false, "invalid_event_definitions" end
	for name, definition in pairs( definitions ) do
		if not isstring( name ) or name == "" or not istable( definition ) then
			return false, "invalid_event_definition"
		end
		local existingOwner = API._eventOwners[name]
		if existingOwner and existingOwner ~= owner then return false, "event_owned" end
	end
	for name, definition in pairs( definitions ) do
		API.Events[name] = deepCopy( definition )
		API._eventOwners[name] = owner
	end
	return true
end

---------------------------------------------------------------- API.Network
-- Addons own their network names just like capabilities and events. Registering
-- during MC.APIAvailable is early enough for every later net.Receive/net.Start
-- include, while keeping the engine protocol table free of game-layer names.
API.Network = API.Network or {}
API._networkMessageOwners = API._networkMessageOwners or {}
local Network = API.Network

local function networkMessageName( value )
	local name = tostring( value or "" )
	if name == "" or #name > 128 then return nil end
	if not string.match( name, "^[%w_%.:-]+$" ) then return nil end
	return name
end

function Network.Register( owner, names )
	owner = capabilityOwner( owner )
	if not owner then return false, "invalid_network_owner" end
	if isstring( names ) then names = { names } end
	if not istable( names ) or #names == 0 then return false, "invalid_network_names" end
	local normalized = {}
	for index, value in ipairs( names ) do
		local name = networkMessageName( value )
		if not name then return false, "invalid_network_name" end
		local existingOwner = API._networkMessageOwners[name]
		if existingOwner and existingOwner ~= owner then return false, "network_name_owned" end
		normalized[index] = name
	end
	for _, name in ipairs( normalized ) do
		API._networkMessageOwners[name] = owner
		if SERVER and util and util.AddNetworkString then util.AddNetworkString( name ) end
	end
	return true, deepCopy( normalized )
end

function Network.Owner( name )
	name = networkMessageName( name )
	return name and API._networkMessageOwners[name] or nil
end

-- Bit width used by the engine's signed block/chunk coordinate payloads.
-- Game-owned network messages use this accessor instead of reaching into the
-- engine protocol table, so a future protocol-width change stays centralized.
function Network.CoordinateBits()
	local bits = MC.Net and tonumber( MC.Net.COORD_BITS ) or 20
	return math.Clamp( math.floor( bits ), 2, 31 )
end

---------------------------------------------------------------------- sound
-- Stable wrapper around the generated Java sound-event catalog.  External
-- addons must call MC.API.Sound rather than the internal MC.PlayJavaSoundEvent
-- helper so load order and catalog failures stay contained.
API.Sound = API.Sound or {}
local Sound = API.Sound

function Sound.Candidates( eventName )
	eventName = tostring( eventName or "" )
	if eventName == "" then return nil, "invalid_sound_event" end
	local candidates = MC.JavaSoundEventCandidates and MC.JavaSoundEventCandidates( eventName ) or nil
	if not candidates or #candidates == 0 then return nil, "unknown_sound_event" end
	return deepCopy( candidates )
end

-- options: volume multiplier, pitch multiplier, soundLevel.
-- Returns ok, selectedCandidateCopy, err.
function Sound.Play( eventName, position, options )
	eventName = tostring( eventName or "" )
	if eventName == "" then return false, nil, "invalid_sound_event" end
	if not position or tonumber( position.x ) == nil or tonumber( position.y ) == nil
	or tonumber( position.z ) == nil then
		return false, nil, "invalid_sound_position"
	end
	options = istable( options ) and options or {}
	if not MC.PlayJavaSoundEvent then return false, nil, "sound_api_unavailable" end
	local ok, candidate = MC.PlayJavaSoundEvent(
		eventName,
		position,
		math.max( 0, tonumber( options.volume ) or 1 ),
		math.max( 0.01, tonumber( options.pitch ) or 1 ),
		math.Clamp( tonumber( options.soundLevel ) or 72, 0, 511 )
	)
	if ok ~= true then return false, nil, "unknown_or_unplayable_sound_event" end
	return true, deepCopy( candidate )
end

local function cellCoord( v )
	v = tonumber( v )
	if v == nil or v ~= v then return nil end -- reject nil and NaN
	return math.floor( v )
end

local function cellCoords( bx, by, bz )
	local x, y, z = cellCoord( bx ), cellCoord( by ), cellCoord( bz )
	if not x or not y or not z then return nil end
	return x, y, z
end

local function airStateId()
	if MC.StateFromLegacy then
		local stateId = MC.StateFromLegacy( 0, 0 )
		if stateId then return stateId end
	end
	return 0
end

-- Shared "block argument" resolver; see the header contract.
local function resolveStateInput( block )
	if block == nil or block == 0 or block == "air" or block == "minecraft:air" then
		return airStateId()
	end
	if isnumber( block ) then
		local stateId = math.floor( block )
		if MC.IsValidBlockState and MC.IsValidBlockState( stateId ) then return stateId end
		return nil, "invalid_state"
	end
	if isstring( block ) then
		if not MC.ParseBlockState then return nil, "state_registry_unavailable" end
		local stateId, err = MC.ParseBlockState( block )
		if not stateId then return nil, err or "invalid_state" end
		return stateId
	end
	return nil, "invalid_block_argument"
end

API.ResolveStateInput = resolveStateInput

-------------------------------------------------------------------- API.Coords
-- THREE distinct spaces exist; mixing them is the most common API mistake:
--   MC world space   the voxel world's own continuous frame. All cell math
--                    below, and every bx/by/bz in this API, live here.
--   engine space     what ent:GetPos() / EyePos() / traces return. Identical
--                    to world space on a normal map, but on InfMap worlds the
--                    active world adapter re-origins it per player, so the
--                    same engine vector means different cells for different
--                    players.
--   render space     world space shifted for drawing only (client).
-- Convert engine -> world with EngineToCell / EntityCell, never by handing a
-- raw ent:GetPos() to WorldToCell.
API.Coords = API.Coords or {}
local Coords = API.Coords

function Coords.BlockSize()
	return MC.BS or 36.5
end

-- MC world-space Vector -> integer cell coords.
function Coords.WorldToCell( pos )
	if not isvector( pos ) then return nil, nil, nil end
	return MC.WorldToCell( pos )
end

-- Engine-space Vector -> integer cell coords. context is the player/entity the
-- position came from; on InfMap worlds it selects the right origin offset, and
-- omitting it silently reads the wrong cell far from the map centre.
function Coords.EngineToCell( pos, context )
	if not isvector( pos ) then return nil, nil, nil end
	local worldPos = MC.EngineToWorldPos and MC.EngineToWorldPos( pos, context ) or pos
	return MC.WorldToCell( worldPos )
end

-- Cell an entity currently occupies (feet). InfMap-safe.
function Coords.EntityCell( ent )
	if not IsValid( ent ) then return nil, nil, nil end
	local worldPos = MC.EntityWorldPos and MC.EntityWorldPos( ent ) or ent:GetPos()
	return MC.WorldToCell( worldPos )
end

-- Continuous entity position in MC world space. This is the InfMap-safe
-- counterpart of Entity:GetPos(); callers receive a fresh Vector.
function Coords.EntityWorldPos( ent )
	if not IsValid( ent ) then return nil, "invalid_entity" end
	local position = MC.EntityWorldPos and MC.EntityWorldPos( ent ) or ent:GetPos()
	if not isvector( position ) then return nil, "world_position_unavailable" end
	return Vector( position.x, position.y, position.z )
end

-- Cell an entity is looking from (eyes). InfMap-safe.
function Coords.EntityEyeCell( ent )
	if not IsValid( ent ) then return nil, nil, nil end
	local worldPos = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ent ) or ent:EyePos()
	return MC.WorldToCell( worldPos )
end

-- Continuous eye position in MC world space. This is the InfMap-safe
-- counterpart of Entity:EyePos(); callers receive a fresh Vector.
function Coords.EntityEyeWorldPos( ent )
	if not IsValid( ent ) then return nil, "invalid_entity" end
	local position = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ent ) or ent:EyePos()
	if not isvector( position ) then return nil, "eye_world_position_unavailable" end
	return Vector( position.x, position.y, position.z )
end

-- InfMap-safe world-space bounds. Both vectors are fresh copies.
function Coords.EntityWorldAABB( ent )
	if not IsValid( ent ) then return nil, nil, "invalid_entity" end
	local minimum, maximum
	if MC.EntityWorldAABB then minimum, maximum = MC.EntityWorldAABB( ent )
	elseif ent.WorldSpaceAABB then minimum, maximum = ent:WorldSpaceAABB() end
	if not isvector( minimum ) or not isvector( maximum ) then
		return nil, nil, "world_bounds_unavailable"
	end
	return Vector( minimum.x, minimum.y, minimum.z ), Vector( maximum.x, maximum.y, maximum.z )
end

-- Min corner / center of a cell in MC world units.
function Coords.CellMin( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellWorldMin( x, y, z )
end

function Coords.CellCenter( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellWorldCenter( x, y, z )
end

-- Render-space counterparts. Only correct inside a client render hook of the
-- current frame; use these (not CellMin/CellCenter) to draw on InfMap worlds.
function Coords.CellRenderMin( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	if not MC.CellRenderMin then return MC.CellWorldMin( x, y, z ) end
	return MC.CellRenderMin( x, y, z )
end

function Coords.CellRenderCenter( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	if not MC.CellRenderCenter then return MC.CellWorldCenter( x, y, z ) end
	return MC.CellRenderCenter( x, y, z )
end

function Coords.CellToChunk( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellToChunk( x, y, z )
end

--------------------------------------------------------------------- API.World
API.World = API.World or {}
local World = API.World

-- stateId at a cell; 0 = air. Never returns nil.
function World.GetBlockState( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return 0 end
	local stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
	return stateId or 0
end

function World.IsAir( bx, by, bz )
	return World.GetBlockState( bx, by, bz ) == 0
end

-- Fresh info table: { stateId, id, orient, name, mcid, spec }; nil for air.
function World.GetBlockInfo( bx, by, bz )
	local stateId = World.GetBlockState( bx, by, bz )
	if stateId == 0 then return nil end
	local id, orient = 0, 0
	if MC.LegacyFromState then
		id, orient = MC.LegacyFromState( stateId )
		id, orient = id or 0, orient or 0
	end
	local block = MC.Blocks and MC.Blocks[id] or nil
	local spec = MC.FormatBlockState and MC.FormatBlockState( stateId ) or nil
	return {
		stateId = stateId,
		id = id,
		orient = orient,
		name = block and block.name or nil,
		mcid = block and block.mcid or nil,
		spec = spec,
	}
end

-- Iterate every NON-AIR cell in the inclusive cell box, chunk-aware (skips
-- missing chunks wholesale). cb( bx, by, bz, stateId ); return false to stop.
--
-- Returns ok, skippedChunks. A chunk is skipped when it is not resident: on
-- lazy MCB4 worlds it may not be hydrated from disk yet, and on the client
-- horizontal column streaming only keeps chunks near the player. Both look
-- exactly like "all air" from in here, so ANY caller drawing a gameplay
-- conclusion from an empty result must check skippedChunks > 0 first.
function World.ForEachBlock( x1, y1, z1, x2, y2, z2, cb )
	if not isfunction( cb ) then return false, "invalid_callback" end
	local ax, ay, az = cellCoords( x1, y1, z1 )
	local bx2, by2, bz2 = cellCoords( x2, y2, z2 )
	if not ax or not bx2 then return false, "invalid_cell" end
	local minx, maxx = math.min( ax, bx2 ), math.max( ax, bx2 )
	local miny, maxy = math.min( ay, by2 ), math.max( ay, by2 )
	local minz, maxz = math.min( az, bz2 ), math.max( az, bz2 )
	if not MC.GetChunk or not MC.GetChunkBlockStateByLocalIndex then return false, "world_unavailable" end

	local CS, CH = MC.CS or 16, MC.CH or 32
	local skipped = 0
	for cz = math.floor( minz / CH ), math.floor( maxz / CH ) do
		for cy = math.floor( miny / CS ), math.floor( maxy / CS ) do
			for cx = math.floor( minx / CS ), math.floor( maxx / CS ) do
				local chunk = MC.GetChunk( cx, cy, cz )
				if not chunk then
					-- "Known empty" is loaded and really is air; anything else
					-- is an absence we cannot see through.
					if not ( MC.IsChunkLoaded and MC.IsChunkLoaded( cx, cy, cz ) ) then
						skipped = skipped + 1
					end
				else
					local x0, xEnd = math.max( minx, cx * CS ), math.min( maxx, cx * CS + CS - 1 )
					local y0, yEnd = math.max( miny, cy * CS ), math.min( maxy, cy * CS + CS - 1 )
					local z0, zEnd = math.max( minz, cz * CH ), math.min( maxz, cz * CH + CH - 1 )
					for bz = z0, zEnd do
						local rowZ = ( bz - cz * CH ) * CS * CS
						for by = y0, yEnd do
							local row = rowZ + ( by - cy * CS ) * CS
							for bxi = x0, xEnd do
								local stateId = MC.GetChunkBlockStateByLocalIndex( chunk, bxi - cx * CS + row )
								if stateId and stateId ~= 0 then
									if cb( bxi, by, bz, stateId ) == false then return true, skipped end
								end
							end
						end
					end
				end
			end
		end
	end
	return true, skipped
end

-- Iterate every currently loaded non-air cell without exposing MC.World or a
-- chunk object. This is intended for rebuilding client-side derived indexes
-- after MC.ClientWorldProjectionChanged, not for per-frame polling.
function World.ForEachLoadedBlock( callback )
	if not isfunction( callback ) then return false, "invalid_callback" end
	if not MC.ForEachBlockState then return false, "world_iteration_unavailable" end
	local visited = 0
	for _, chunk in pairs( MC.World or {} ) do
		local stopped = false
		MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
			visited = visited + 1
			local ok, result = pcall( callback, bx, by, bz, stateId )
			if not ok then stopped = "callback_failed" return false end
			if result == false then stopped = true return false end
		end )
		if stopped == "callback_failed" then return false, stopped, visited end
		if stopped == true then break end
	end
	return true, visited
end

-- Fresh shape info for a world cell (selection boxes, collision, extent).
-- Box/convex tables are copies: safe to keep and mutate.
function World.GetCellShape( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	if not MC.GetBlockShapeInfo then return nil, "shape_api_unavailable" end
	local id = MC.GetBlock and MC.GetBlock( x, y, z ) or 0
	if id == 0 then return nil end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( x, y, z ) or 0
	local info = MC.GetBlockShapeInfo( id, orient, x, y, z )
	if not info then return nil end
	return {
		bx = x, by = y, bz = z,
		id = info.id,
		orient = info.orient,
		boxes = deepCopy( info.boxes ),
		collisionBoxes = deepCopy( info.collisionBoxes ),
		collisionConvexes = deepCopy( info.collisionConvexes ),
		extentLo = info.extentLo,
		extentHi = info.extentHi,
		hasCollision = info.hasCollision,
		fullCube = info.fullCube,
	}
end

-- Voxel-only ray trace (does not hit map/prop geometry). Result is a fresh
-- table: { bx, by, bz, StateId, HitPos, HitNormal, ... } or nil.
function World.TraceRay( startPos, dir, maxDist )
	if not isvector( startPos ) or not isvector( dir ) then return nil, "invalid_ray" end
	if not MC.TraceBlockRay then return nil, "trace_unavailable" end
	return MC.TraceBlockRay( startPos, dir, tonumber( maxDist ) or 0 )
end

function World.PlayerAim( ply, reach )
	if not IsValid( ply ) then return nil, "invalid_player" end
	if not MC.PlayerBlockAim then return nil, "trace_unavailable" end
	return MC.PlayerBlockAim( ply, tonumber( reach ) )
end

-- True when the cell's chunk is loaded (present in the world or known
-- empty). On lazy-loaded large worlds a false here means "not hydrated yet,
-- don't draw gameplay conclusions" - GetBlockState cannot tell that apart
-- from air on its own.
function World.IsCellLoaded( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.IsChunkLoaded or not MC.CellToChunk then return false end
	local cx, cy, cz = MC.CellToChunk( x, y, z )
	return MC.IsChunkLoaded( cx, cy, cz ) == true
end

function World.IsChunkLoaded( cx, cy, cz )
	local x, y, z = cellCoords( cx, cy, cz )
	if not x or not MC.IsChunkLoaded then return false end
	return MC.IsChunkLoaded( x, y, z ) == true
end

-- Heightmap-level sky access; no lateral flood into overhangs. The realms
-- intentionally differ in strictness: the SERVER (authoritative for
-- gameplay) blocks on light opacity > 0 (leaves and water count as cover),
-- while the CLIENT reuses the render sky column, which only blocks on
-- opacity >= 15 (full cubes). Glass (opacity 0) never blocks on either.
function World.CanSeeSky( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	if SERVER then
		if not MC.SV or not MC.SV.CanSeeSky then return false, "lighting_unavailable" end
		return MC.SV.CanSeeSky( x, y, z )
	end
	if not MC.SkyExposedAt then return false, "lighting_unavailable" end
	return MC.SkyExposedAt( x, y, z ) == true
end

-- Read-only deep copy of the block entity record at a cell (or nil).
function World.GetBlockEntity( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	if not MC.GetBlockEntity then return nil, "block_entity_api_unavailable" end
	return MC.GetBlockEntity( x, y, z )
end

-- Fresh snapshot of every currently loaded block entity, optionally filtered
-- by type. Consumers never receive MC.World/chunk/blockEntities references.
function World.ListBlockEntities( typeName )
	typeName = typeName ~= nil and tostring( typeName ) or nil
	local output = {}
	for key, chunk in pairs( MC.World or {} ) do
		local cx, cy, cz = chunk.cx, chunk.cy, chunk.cz
		if cx == nil and MC.ChunkKeyToCoords then cx, cy, cz = MC.ChunkKeyToCoords( key ) end
		if cx ~= nil then
			for localIndex, record in pairs( chunk.blockEntities or {} ) do
				if typeName == nil or record.type == typeName then
					local lx, ly, lz = MC.DecodeLocal( localIndex )
					output[#output + 1] = {
						bx = cx * MC.CS + lx,
						by = cy * MC.CS + ly,
						bz = cz * MC.CH + lz,
						record = deepCopy( record ),
					}
				end
			end
		end
	end
	return output
end

function World.ForEachBlockEntity( typeName, callback )
	if not isfunction( callback ) then return false, "invalid_callback" end
	local entries = World.ListBlockEntities( typeName )
	for _, entry in ipairs( entries ) do
		local ok, result = pcall( callback, entry.bx, entry.by, entry.bz, entry.record )
		if not ok then return false, "callback_failed" end
		if result == false then break end
	end
	return true, #entries
end

------------------------------------------------------------------- API.Farming
-- Authoritative implementations live in sv_api.lua. Declare the namespace on
-- both realms so separately shipped item addons can feature-detect it without
-- depending on autorun/include order.
API.Farming = API.Farming or {}

-------------------------------------------------------------------- API.Blocks
API.Blocks = API.Blocks or {}
local Blocks = API.Blocks

-- Accepts id / "stone" / "minecraft:stone" / alias. Fresh result table.
function Blocks.Resolve( input )
	if not MC.ResolveBlock then return nil, "block_registry_unavailable" end
	local lookup = input
	if type( input ) == "string" and ( MC.ValidateModContentIdentifier or MC.NormalizeResourceLocation ) then
		local canonical, identifierError
		if MC.ValidateModContentIdentifier then
			canonical, identifierError = MC.ValidateModContentIdentifier( input )
		else
			canonical, identifierError = MC.NormalizeResourceLocation( input )
		end
		if not canonical then return nil, identifierError or "invalid_identifier" end
		lookup = canonical
	end
	local resolved = MC.ResolveBlock( lookup )
	-- Preserve valid legacy aliases such as custom_oak_slope without restoring
	-- the old trim/lowercase behavior.  Canonical minecraft:* lookup remains the
	-- first choice; only an already-valid unqualified spelling gets the fallback.
	if not resolved and type( input ) == "string" and not string.find( input, ":", 1, true ) then
		resolved = MC.ResolveBlock( input )
	end
	if not resolved then return nil, "unknown_block" end
	local defaultStateId = MC.DefaultBlockState and MC.DefaultBlockState( resolved.id ) or nil
	local canonical = resolved.mcid
	if canonical and MC.NormalizeResourceLocation then canonical = MC.NormalizeResourceLocation( canonical ) or canonical end
	local modRecord = canonical and MC.ModBlockRecord and MC.ModBlockRecord( canonical ) or nil
	return {
		id = resolved.id,
		blockId = resolved.id,
		runtimeId = modRecord and modRecord.runtimeId or resolved.id,
		name = canonical or resolved.name,
		mcid = canonical or resolved.mcid,
		defaultStateId = defaultStateId,
	}
end

function Blocks.ParseState( spec )
	return resolveStateInput( spec )
end

function Blocks.FormatState( stateId )
	if not MC.FormatBlockState then return nil, "state_registry_unavailable" end
	return MC.FormatBlockState( stateId )
end

-- Canonical minecraft:block_name for a state, without leaking the schema or
-- block registry records that own it.
function Blocks.Name( stateId )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then
		return nil, "invalid_state"
	end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local name = schema and schema.name or nil
	if not name then
		local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
		local block = id and MC.Blocks and MC.Blocks[id] or nil
		name = block and ( block.mcid or block.name ) or nil
	end
	if not name then return nil, "unknown_block" end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return name
end

function Blocks.IsValidState( stateId )
	return MC.IsValidBlockState and MC.IsValidBlockState( stateId ) == true or false
end

-- Legacy block id owning a state (nil for invalid states).
function Blocks.StateBlockId( stateId )
	return MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
end

-- Compatibility conversion for transaction plans that still carry the
-- engine's legacy block id + orient pair. The resulting state id is the only
-- value exposed; registry/cache tables remain private.
function Blocks.StateFromLegacy( blockId, orient )
	if not MC.StateFromLegacy then return nil, "state_registry_unavailable" end
	blockId = tonumber( blockId )
	if blockId == nil then return nil, "invalid_legacy_block_id" end
	local stateId, ok, err = MC.StateFromLegacy(
		math.floor( blockId ), math.floor( tonumber( orient ) or 0 )
	)
	if ok ~= true or stateId == nil then return nil, err or "legacy_state_unavailable" end
	return stateId
end

function Blocks.DefaultState( input )
	if not MC.DefaultBlockState then return nil, "state_registry_unavailable" end
	if isstring( input ) or isnumber( input ) then
		local stateId = MC.DefaultBlockState( input )
		if stateId then return stateId end
	end
	return nil, "unknown_block"
end

function Blocks.GetProperty( stateId, propertyName )
	if not MC.GetStateProperty then return nil, "state_registry_unavailable" end
	return MC.GetStateProperty( stateId, propertyName )
end

function Blocks.WithProperty( stateId, propertyName, value )
	if not MC.StateWith then return nil, "state_registry_unavailable" end
	return MC.StateWith( stateId, propertyName, value )
end

-- Localized display name. Numbers are ambiguous (legacy block ids and state
-- ids share the same integer range): a number naming a registered block is
-- treated as a BLOCK id. For state ids use DisplayNameForState.
function Blocks.DisplayName( idOrStateId )
	local block = MC.Blocks and MC.Blocks[idOrStateId] or nil
	if not block and MC.IsValidBlockState and MC.IsValidBlockState( idOrStateId ) and MC.BlockTypeForState then
		local id = MC.BlockTypeForState( idOrStateId )
		block = id and MC.Blocks and MC.Blocks[id] or nil
	end
	if not block then return nil, "unknown_block" end
	return MC.BlockDisplayName and MC.BlockDisplayName( block ) or block.name
end

function Blocks.DisplayNameForState( stateId )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, "invalid_state" end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	if not block then return nil, "unknown_block" end
	return MC.BlockDisplayName and MC.BlockDisplayName( block ) or block.name
end

function Blocks.Hardness( id )
	return MC.BlockHardness and MC.BlockHardness( id ) or 1
end

function Blocks.RequiresCorrectTool( id )
	return MC.BlockRequiresCorrectTool and MC.BlockRequiresCorrectTool( id ) == true
end

function Blocks.ExplosionResistance( id )
	return MC.BlockExplosionResistance and MC.BlockExplosionResistance( id ) or 1
end

function Blocks.LightEmission( id )
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

-- Per-state light opacity 0..15 (0 = fully transparent like glass, 15 = a
-- full opaque cube). Pass bx/by/bz for connection-dependent shapes.
function Blocks.LightOpacity( stateId, bx, by, bz )
	if not MC.BlockLightOpacityForState then return 15 end
	return MC.BlockLightOpacityForState( stateId, bx, by, bz )
end

local function stateShapeExtent( boxes, convexes )
	local lo, hi = math.huge, -math.huge
	for _, box in ipairs( boxes or {} ) do
		local z1, z2 = tonumber( box[3] ), tonumber( box[6] )
		if z1 and z1 < lo then lo = z1 end
		if z2 and z2 > hi then hi = z2 end
	end
	for _, convex in ipairs( convexes or {} ) do
		for _, point in ipairs( convex or {} ) do
			local z = tonumber( point[3] ~= nil and point[3] or point.z )
			if z and z < lo then lo = z end
			if z and z > hi then hi = z end
		end
	end
	if lo == math.huge or hi == -math.huge then return nil, nil end
	return lo, hi
end

-- Exact state-level outline and collision geometry at a cell. Coordinates are
-- mandatory because connection/state resolvers may depend on neighboring
-- cells. Returned geometry is deeply copied and can be retained or mutated.
function Blocks.StateShapeAt( stateId, bx, by, bz )
	stateId = tonumber( stateId )
	if stateId == nil or stateId ~= stateId or stateId ~= math.floor( stateId )
	or not MC.IsValidBlockState or MC.IsValidBlockState( stateId ) ~= true then
		return nil, "invalid_state"
	end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	if not MC.BlockBoxesForState or not MC.GetBlockCollisionBoxesForState
	or not MC.BlockCollisionConvexesForState or not MC.BlockHasCollisionForState
	or not MC.BlockIsFullCubeForState then
		return nil, "shape_api_unavailable"
	end
	local boxes = MC.BlockBoxesForState( stateId, x, y, z )
	local collisionBoxes = MC.GetBlockCollisionBoxesForState( stateId, x, y, z )
	local collisionConvexes = MC.BlockCollisionConvexesForState( stateId, x, y, z )
	local hasCollision = MC.BlockHasCollisionForState( stateId, x, y, z ) == true
	local extentLo, extentHi
	if hasCollision then extentLo, extentHi = stateShapeExtent( collisionBoxes, collisionConvexes ) end
	return {
		stateId = stateId,
		bx = x, by = y, bz = z,
		boxes = deepCopy( boxes ),
		collisionBoxes = deepCopy( collisionBoxes ),
		collisionConvexes = deepCopy( collisionConvexes ),
		extentLo = extentLo,
		extentHi = extentHi,
		hasCollision = hasCollision,
		fullCube = MC.BlockIsFullCubeForState( stateId, x, y, z ) == true,
	}
end

local NARROW_CONNECTIONS = {
	fence = true, fence_gate = true, wall = true, pane = true, bars = true, pipe6 = true,
}
local RULE_KINDS = {
	stairs = "stairs", slab = "slab", door = "door", trapdoor = "trapdoor", bed = "bed",
}

-- Coarse shape classification for pathfinding/AI. One of:
--   "air"      empty cell state
--   "liquid"   water/lava source or flow (waterlogged blocks keep their own kind)
--   "narrow"   thin-but-tall colliders: fence / fence_gate / wall / pane / bars / pipe6
--              (block movement but cannot be stood on top of like a full cube)
--   "door" | "trapdoor" | "bed" | "stairs" | "slab"
--   "slope"    convex-collision ramp blocks
--   "none"     no collision at all (torch, flowers, rails, ladders, ...)
--   "full"     full opaque-collision cube
--   "partial"  everything else with a reduced collision box
function Blocks.Kind( stateId )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, "invalid_state" end
	if stateId == 0 then return "air" end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	if not block then return nil, "unknown_block" end
	if MC.IsLiquidBlock and MC.IsLiquidBlock( id ) then return "liquid" end
	if block.connection and NARROW_CONNECTIONS[block.connection] then return "narrow" end
	local ruleKind = block.stateRule and RULE_KINDS[block.stateRule]
	if ruleKind then return ruleKind end
	if block.collisionConvexes then return "slope" end
	if MC.BlockHasCollision and not MC.BlockHasCollision( id ) then return "none" end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId ) then return "full" end
	return "partial"
end

-- Fresh array of every registered block id.
function Blocks.List()
	local out = {}
	for i, id in ipairs( MC.BlockList or {} ) do out[i] = id end
	return out
end

-- Namespace-first registry views.  Runtime numbers are intentionally exposed
-- only as query results for the current process; callers must persist Name /
-- FormatState strings instead.
function Blocks.ListNames()
	local names = {}
	local seen = {}
	for _, id in ipairs( MC.BlockList or {} ) do
		local block = MC.Blocks and MC.Blocks[id]
		local name = block and ( block.mcid or block.name ) or nil
		name = name and MC.NormalizeResourceLocation and ( MC.NormalizeResourceLocation( name ) or name ) or name
		if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
	end
	table.sort( names )
	return names
end

function Blocks.RuntimeId( input )
	local resolved, err = Blocks.Resolve( input )
	if not resolved then return nil, err end
	return resolved.runtimeId
end

function Blocks.NameForRuntimeId( runtimeId )
	if MC.ModBlockNameForRuntimeId then
		local name = MC.ModBlockNameForRuntimeId( runtimeId )
		if name then return name end
	end
	local resolved = Blocks.Resolve( tonumber( runtimeId ) )
	return resolved and resolved.name or nil, resolved and nil or "unknown_block"
end

function Blocks.StateName( stateId )
	if not MC.FormatBlockState then return nil, "state_registry_unavailable" end
	return MC.FormatBlockState( stateId )
end

function Blocks.RegistrySnapshot()
	if not MC.BuildModRegistrySnapshot then return nil, "registry_unavailable" end
	return API.DeepCopy( MC.BuildModRegistrySnapshot() )
end

function Blocks.ResolveRegistrySnapshot( snapshot )
	if not MC.ResolveModRegistrySnapshot then return nil, "registry_unavailable" end
	local resolved, err = MC.ResolveModRegistrySnapshot( snapshot )
	if not resolved then return nil, err end
	return API.DeepCopy( resolved )
end

function Blocks.RegistryHash()
	if not MC.GetEffectiveBlockStateRegistryHash then return nil, "registry_unavailable" end
	return tostring( MC.GetEffectiveBlockStateRegistryHash() or "" )
end

-- Hash used by the state-network handshake.  It is intentionally separate
-- from RegistryHash/persistence schema hashing because it binds legacy block
-- runtime mappings that must match while numeric transport is active.
function Blocks.NetworkHash()
	if MC.GetModRegistryNetworkHash then
		return tostring( MC.GetModRegistryNetworkHash() or "" )
	end
	if not MC.GetEffectiveBlockStateRegistryHash then return nil, "registry_unavailable" end
	return tostring( MC.GetEffectiveBlockStateRegistryHash() or "" )
end

-- Register a namespace-first block. MUST be called during file load (autorun
-- include time) or inside hook "MC.APIAvailable" - the registry freezes on the
-- first tick after load. See docs/api.md for the definition table fields.
-- Returns true, a result record whose runtimeId is process-local. This is the
-- Mod Registry v1.x entry; persisted identity is always result.name.
function Blocks.RegisterNamespaced( def )
	if not istable( def ) then return nil, "invalid_definition" end
	if MC.BlockStateRegistryFrozen or MC.ModBlockRegistryFrozen or MC.API._freezeStarted then return nil, "registry_frozen" end
	if not MC.RegisterModBlock then return nil, "block_registry_unavailable" end
	local result, err = MC.RegisterModBlock( def )
	if not result then return nil, err or "register_failed" end
	return true, result
end

-- Compatibility entry retained from MC.API v1/v2. Numeric or omitted `id`
-- keeps the old MC.RegisterCustomBlock behavior and returns true, blockId.
-- A non-numeric string `id` with no legacy name/mcid fields is unambiguously a
-- new namespace definition, so it is forwarded to RegisterNamespaced. New
-- addons should call RegisterNamespaced explicitly instead of relying on this
-- overload: it keeps old definitions byte-for-byte compatible while giving
-- simple v1.x definitions a safe upgrade path.
function Blocks.Register( def )
	if not istable( def ) then return nil, "invalid_definition" end
	local stringIdentity = type( def.id ) == "string" and tonumber( def.id ) == nil
		and def.name == nil and def.mcid == nil
	if stringIdentity then return Blocks.RegisterNamespaced( def ) end
	if MC.BlockStateRegistryFrozen or MC.ModBlockRegistryFrozen or MC.API._freezeStarted then return nil, "registry_frozen" end
	if not MC.RegisterCustomBlock then return nil, "block_registry_unavailable" end
	local block = MC.RegisterCustomBlock( def )
	-- Preserve the historical facade error: the compatibility overload never
	-- exposed MC.RegisterCustomBlock's internal validation reasons.
	if not block then return nil, "register_failed" end
	return true, block.id or def.id
end

local HANDLER_KEYS = {
	CanUse = true, OnUse = true, OnPlace = true, OnBreak = true, OnTick = true,
	OnPlaced = true, OnRemoved = true, OnReplaced = true, OnStateChanged = true, OnMoved = true,
}

-- Attach/replace lifecycle handlers on an existing block after load.
-- Pass false for a key to clear that handler. Validates everything first so
-- a rejected call never applies a partial set.
function Blocks.SetHandlers( nameOrId, handlers )
	if not istable( handlers ) then return false, "invalid_handlers" end
	local resolved = MC.ResolveBlock and MC.ResolveBlock( nameOrId ) or nil
	local block = resolved and MC.Blocks and MC.Blocks[resolved.id] or nil
	if not block then return false, "unknown_block" end
	for key, fn in pairs( handlers ) do
		if not HANDLER_KEYS[key] then return false, "unknown_handler_" .. tostring( key ) end
		if fn ~= false and not isfunction( fn ) then return false, "invalid_handler_" .. tostring( key ) end
	end
	block.handlers = block.handlers or {}
	for key, fn in pairs( handlers ) do
		block.handlers[key] = fn ~= false and fn or nil
	end
	if handlers.OnTick then MC.HasBlockTickHandlers = true end
	return true
end

function Blocks.RegisterUpdateHandler( blockName, definition )
	if not MC.RegisterBlockUpdateHandler then return false, "block_update_api_unavailable" end
	local handler, err = MC.RegisterBlockUpdateHandler( blockName, definition )
	if not handler then return false, err or "register_failed" end
	return true
end

function Blocks.UnregisterUpdateHandler( blockName )
	if not MC.UnregisterBlockUpdateHandler then return false end
	return MC.UnregisterBlockUpdateHandler( blockName ) == true
end

-- Update handler bound by STATE MATCHER instead of block name - for behavior
-- that covers a state family (the water fluid handler matches every
-- waterlogged state this way). matcher( stateId, schema ) -> boolean runs
-- once per stateId and is cached, so it must be pure and rely only on
-- immutable data. key is your own unique id; registering the same key
-- replaces the previous handler, first matching handler in order wins.
function Blocks.RegisterStateUpdateHandler( key, matcher, definition )
	if not MC.RegisterBlockUpdateStateHandler then return false, "block_update_api_unavailable" end
	if not isfunction( matcher ) then return false, "invalid_state_matcher" end
	local handler, err = MC.RegisterBlockUpdateStateHandler( key, matcher, definition )
	if not handler then return false, err or "register_failed" end
	return true
end

function Blocks.UnregisterStateUpdateHandler( key )
	if not MC.UnregisterBlockUpdateStateHandler then return false end
	return MC.UnregisterBlockUpdateStateHandler( key ) == true
end

function Blocks.RegisterBlockEntityType( definition )
	if not MC.RegisterBlockEntityType then return false, "block_entity_api_unavailable" end
	local registered, err = MC.RegisterBlockEntityType( definition )
	if not registered then return false, err or "register_failed" end
	return true
end

function Blocks.IsBlockEntityTypeRegistered( typeName )
	return MC.IsBlockEntityTypeRegistered and MC.IsBlockEntityTypeRegistered( typeName ) == true or false
end

function Blocks.BindBlockEntityType( blockNames, typeName )
	if not MC.BindBlockEntityType then return false, "block_entity_api_unavailable" end
	return MC.BindBlockEntityType( deepCopy( blockNames ), typeName )
end

-- Fresh default record for the Block Entity bound to a state, or nil when the
-- state has no Block Entity. The registry definition itself remains private.
function Blocks.CreateDefaultBlockEntity( stateId )
	if not MC.CreateDefaultBlockEntityRecord then return nil, "block_entity_api_unavailable" end
	local record, err = MC.CreateDefaultBlockEntityRecord( stateId )
	return deepCopy( record ), err
end

function Blocks.RegisterPlacementStateProvider( id, provider, priority )
	if not MC.RegisterPlacementStateUpdateProvider then return false, "placement_provider_api_unavailable" end
	return MC.RegisterPlacementStateUpdateProvider( id, provider, priority )
end

function Blocks.UnregisterPlacementStateProvider( id )
	if not MC.UnregisterPlacementStateUpdateProvider then return false end
	return MC.UnregisterPlacementStateUpdateProvider( id )
end

function Blocks.IsFlammable( block )
	local stateId, err = resolveStateInput( block )
	if stateId == nil then return false, err end
	if stateId == 0 then return false end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local name = schema and schema.name or nil
	return name ~= nil and MC.GeneratedBlockFlammability
		and MC.GeneratedBlockFlammability[name] == true or false
end

------------------------------------------------------------------ API.Banners
-- Banner block data belongs to the engine; converting that data to/from an
-- ItemStack belongs to the game addon. These helpers expose only the block
-- half of that boundary.
API.Banners = API.Banners or {}
local Banners = API.Banners

function Banners.MaxStoredPatterns()
	return math.max( 0, math.floor( tonumber( MC.BannerMaxStoredPatterns ) or 16 ) )
end

function Banners.IsState( stateId )
	return MC.IsBannerState and MC.IsBannerState( stateId ) == true or false
end

function Banners.IsWallState( stateId )
	return MC.IsWallBannerState and MC.IsWallBannerState( stateId ) == true or false
end

function Banners.NormalizeData( data, maxLayers )
	if not MC.NormalizeBannerData then return nil, "banner_api_unavailable" end
	local normalized, err = MC.NormalizeBannerData( deepCopy( data ), maxLayers )
	return deepCopy( normalized ), err
end

------------------------------------------------------------------ API.Redstone
API.Redstone = API.Redstone or {}
local Redstone = API.Redstone

-- Best redstone power reaching a cell from any neighbor (0..15).
function Redstone.GetPower( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.RedstoneBestNeighborSignal then return 0 end
	return MC.RedstoneBestNeighborSignal( x, y, z )
end

-- Power offered TO the cell by its neighbor at offset (dx,dy,dz), 0..15.
-- (MC.RedstoneSignalAt asks what a cell EMITS, so the neighbor is sampled
-- with the offset reversed - same convention as RedstoneBestNeighborSignal.)
function Redstone.GetPowerToward( bx, by, bz, dx, dy, dz )
	local x, y, z = cellCoords( bx, by, bz )
	local ox, oy, oz = cellCoords( dx, dy, dz )
	if not x or not ox or not MC.RedstoneSignalAt then return 0 end
	return MC.RedstoneSignalAt( x + ox, y + oy, z + oz, -ox, -oy, -oz )
end

function Redstone.RegisterEmitter( blockName, emitter )
	if not MC.RegisterRedstoneSignalEmitter then return false, "redstone_api_unavailable" end
	local registered, err = MC.RegisterRedstoneSignalEmitter( blockName, emitter )
	if not registered then return false, err or "register_failed" end
	return true
end

function Redstone.RegisterDirectEmitter( blockName, emitter )
	if not MC.RegisterRedstoneDirectSignalEmitter then return false, "redstone_api_unavailable" end
	local registered, err = MC.RegisterRedstoneDirectSignalEmitter( blockName, emitter )
	if not registered then return false, err or "register_failed" end
	return true
end

-------------------------------------------------------------------- API.Liquid
API.Liquid = API.Liquid or {}
local Liquid = API.Liquid

-- Fresh table { kind, height, level, falling, waterlogged } or nil when not
-- liquid.  `height` is the exact 0..1 FluidState surface height for this cell,
-- including the full-height case when the same liquid continues above it.
function Liquid.GetAt( bx, by, bz )
	local stateId = World.GetBlockState( bx, by, bz )
	if stateId == 0 or not MC.LiquidStateMetrics then return nil end
	local kind, ownHeight, level, falling, waterlogged = MC.LiquidStateMetrics( stateId )
	if not kind then return nil end
	local height = ownHeight
	if MC.LiquidHeightAtCell then height = MC.LiquidHeightAtCell( bx, by, bz, kind ) end
	return {
		kind = kind,
		height = math.Clamp( tonumber( height ) or 0, 0, 1 ),
		level = level,
		falling = falling == true,
		waterlogged = waterlogged == true,
	}
end

-- Bucket-facing read-only description.  A source is a level-0 water/lava
-- state; waterlogged blocks also contain a source water FluidState even though
-- their visible block identity is not minecraft:water.
function Liquid.GetBucketSource( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	local stateId = World.GetBlockState( x, y, z )
	if stateId == 0 or not MC.LiquidStateMetrics then return nil end
	local kind, _, level, falling, waterlogged = MC.LiquidStateMetrics( stateId )
	if not kind then return nil end
	local source = waterlogged == true or ( math.floor( tonumber( level ) or -1 ) == 0 and falling ~= true )
	return {
		bx = x, by = y, bz = z,
		stateId = stateId,
		kind = kind,
		level = level,
		falling = falling == true,
		waterlogged = waterlogged == true,
		source = source,
	}
end

-- Liquid contact at an exact world position (fresh table or nil).
function Liquid.AtPos( pos )
	if not isvector( pos ) or not MC.LiquidAtPos then return nil end
	return MC.LiquidAtPos( pos )
end

function Liquid.PlayerEye( ply )
	if not IsValid( ply ) or not MC.PlayerEyeLiquid then return nil end
	return MC.PlayerEyeLiquid( ply )
end

-- Exact forwarding of MC.LiquidFlowAtCell: three normalized components, or
-- 0,0,0 for no/mismatched/still liquid. Do not reinterpret requiredKind.
function Liquid.FlowAt( bx, by, bz, requiredKind )
	if not MC.LiquidFlowAtCell then return 0, 0, 0 end
	return MC.LiquidFlowAtCell( bx, by, bz, requiredKind )
end

------------------------------------------------------------------ API.DayCycle
API.DayCycle = API.DayCycle or {}
local DayCycle = API.DayCycle

function DayCycle.GetTicks()
	return MC.DayCycleTicks and MC.DayCycleTicks() or 0
end

function DayCycle.IsEnabled()
	return MC.DayCycleEnabled and MC.DayCycleEnabled() == true or false
end

function DayCycle.IsPaused()
	return MC.DayCyclePaused and MC.DayCyclePaused() == true or false
end

-- Sky light LEVEL 0..15 for the current time (the nonlinear MC mapping;
-- SkyBrightness() is the 0..1 render brightness, not this).
function DayCycle.SkyLevel()
	return MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
end

-- Fresh Vector pointing TOWARD the sun, plus elevation (cosine, -1..1;
-- positive = sun above the horizon).
function DayCycle.SunVector()
	if not MC.DayCycleSunVector then return Vector( 0, 0, 1 ), 1 end
	local dir, elevation = MC.DayCycleSunVector()
	return Vector( dir ), elevation
end

function DayCycle.NightAmount()
	return MC.DayCycleNightAmount and MC.DayCycleNightAmount() or 0
end

-- Continuous celestial-angle smoothstep. This is deliberately not an alias
-- for the SkyLevel-quantized NightAmount curve.
function DayCycle.NightBlend()
	return MC.DayCycleNightBlend and MC.DayCycleNightBlend() or 0
end

function DayCycle.IsNight()
	return DayCycle.NightAmount() >= 0.5
end

function DayCycle.SkyBrightness()
	return MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
end

function DayCycle.CelestialAngle()
	return MC.DayCycleCelestialAngle and MC.DayCycleCelestialAngle() or 0
end

-- Server only; 0..23999 Minecraft ticks (0 = sunrise, 6000 = noon).
function DayCycle.SetTicks( ticks )
	if not SERVER then return false, "server_only" end
	if not MC.DayCycle or not MC.DayCycle.SetTime then return false, "daycycle_unavailable" end
	ticks = tonumber( ticks )
	if not ticks then return false, "invalid_ticks" end
	MC.DayCycle.SetTime( math.floor( ticks ) % ( MC.DAYCYCLE_TICKS_PER_DAY or 24000 ) )
	return true
end

------------------------------------------------------------------ API.GameMode
API.GameMode = API.GameMode or {}
local GameMode = API.GameMode

function GameMode.Get( ply )
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return "survival", "invalid_player"
	end
	return MC.PlayerGameMode and MC.PlayerGameMode( ply ) or "survival"
end

function GameMode.IsCreative( ply )
	local mode, err = GameMode.Get( ply )
	return mode == "creative", err
end

----------------------------------------------------------------------- API.I18n
API.I18n = API.I18n or {}
local I18n = API.I18n

function I18n.Language()
	return MC.Language and MC.Language() or "en_us"
end

function I18n.LanguageForPlayer( ply )
	if MC.LanguageForPlayer then return MC.LanguageForPlayer( ply ) end
	return I18n.Language()
end

function I18n.Translate( key, fallback, vars, lang )
	if MC.T then return MC.T( key, fallback, deepCopy( vars ), lang ) end
	return tostring( fallback or key or "" )
end

function I18n.TranslateForPlayer( ply, key, fallback, vars )
	if MC.TFor then return MC.TFor( ply, key, fallback, deepCopy( vars ) ) end
	return I18n.Translate( key, fallback, vars, I18n.LanguageForPlayer( ply ) )
end

function I18n.LanguageOptions()
	return deepCopy( MC.LanguageOptions and MC.LanguageOptions() or {} )
end

function I18n.SetLanguage( lang )
	if not MC.SetLanguage then return nil, "i18n_unavailable" end
	return MC.SetLanguage( lang )
end

function I18n.RegisterLanguageChanged( name, callback )
	if not isfunction( callback ) then return false, "invalid_callback" end
	if not MC.RegisterLanguageChanged then return false, "i18n_unavailable" end
	MC.RegisterLanguageChanged( tostring( name or callback ), callback )
	return true
end

-------------------------------------------------------------------- API.Config
-- Lets an external addon put its own ConVars into the in-game MC settings menu
-- instead of asking players to type console commands. The menu data itself is
-- plain metadata (see mc/sh_config_ui.lua); these entry points only validate and
-- append, so registering twice with the same category id is a no-op.
--
--   scope    "client" | "server" (server entries are admin-only and networked)
--   group    { id, label, zhLabel }
--   category { id, group, label, zhLabel, description, descriptionZH, items = {
--                { name = "cvar_name", label, labelZH, kind = "bool|number|choice|string",
--                  help, helpZH, unit, choices = { { value, label, labelZH }, ... } }, ... } }
API.Config = API.Config or {}
local Config = API.Config

local function configScope( scope )
	if scope ~= "client" and scope ~= "server" then return nil end
	if not istable( MC.ConfigConVars ) or not istable( MC.ConfigGroups ) then return nil end
	MC.ConfigConVars[scope] = MC.ConfigConVars[scope] or {}
	MC.ConfigGroups[scope] = MC.ConfigGroups[scope] or {}
	return scope
end

function Config.HasGroup( scope, id )
	if not configScope( scope ) then return false end
	for _, group in ipairs( MC.ConfigGroups[scope] ) do
		if group.id == id then return true end
	end
	return false
end

function Config.HasCategory( scope, id )
	if not configScope( scope ) then return false end
	for _, category in ipairs( MC.ConfigConVars[scope] ) do
		if category.id == id then return true end
	end
	return false
end

function Config.RegisterGroup( scope, group )
	if not configScope( scope ) then return false, "config_ui_unavailable" end
	if not istable( group ) or not isstring( group.id ) or group.id == "" then return false, "invalid_group" end
	if Config.HasGroup( scope, group.id ) then return true end
	table.insert( MC.ConfigGroups[scope], {
		id = group.id,
		label = tostring( group.label or group.id ),
		zhLabel = tostring( group.zhLabel or group.label or group.id ),
	} )
	return true
end

function Config.RegisterCategory( scope, category )
	if not configScope( scope ) then return false, "config_ui_unavailable" end
	if not istable( category ) or not isstring( category.id ) or category.id == "" then
		return false, "invalid_category"
	end
	if not istable( category.items ) or #category.items == 0 then return false, "invalid_items" end
	if Config.HasCategory( scope, category.id ) then return true end

	local entry = deepCopy( category )
	entry.scope = scope
	for _, item in ipairs( entry.items ) do
		if not isstring( item.name ) or item.name == "" then return false, "invalid_item" end
		item.category = entry.id
		item.scope = scope
		item.kind = item.kind or "number"
	end

	table.insert( MC.ConfigConVars[scope], entry )
	return true
end

-------------------------------------------------------------------- API.Events
-- Documentation of every event the core fires (hook.Run). Listen with
-- hook.Add( name, id, fn ). "veto" events deny the action when a listener
-- returns false.
API.RegisterEvents( "mc.engine", {
	["MC.APIAvailable"] = { realm = "shared", args = "version", desc = "MC has finished loading; registries still open - register custom blocks here" },
	["MC.APIReady"] = { realm = "shared", args = "version", desc = "registries frozen; the full API is usable" },
	["MC.ModCreativeRegistryReady"] = { realm = "shared", args = "version", desc = "neutral CreativeModeTab metadata is frozen and queryable" },
	["MC.APICapabilityAvailable"] = { realm = "shared", args = "name, version, surface, owner", desc = "an optional public API capability was registered or replaced" },
	["MC.APICapabilityRemoved"] = { realm = "shared", args = "name, version, owner", desc = "an optional public API capability was removed by its owner" },
	["MC.ClientBlockStateChanged"] = { realm = "client", args = "bx, by, bz, oldStateId, newStateId, reason", desc = "one client voxel state projection changed; observers update derived caches without engine-to-game calls" },
	["MC.ClientWorldProjectionChanged"] = { realm = "client", args = "reason, context", desc = "a bulk snapshot/hydration/unload/reset changed client world projections" },
	["MC.BlocksChanged"] = { realm = "server", args = "changes{bx,by,bz,stateId,oldStateId,kind}[], revision, actor", desc = "one committed world transaction; kind: placed|removed|replaced|state_changed|block_entity_changed (not fired by /fill volume fills or mc_import raw imports)" },
	["MC.CanPlayerEdit"] = { realm = "server", args = "ply", desc = "veto: return false to deny all world editing for this player action" },
	["MC.CanPlayerEditCell"] = { realm = "server", args = "ply, bx, by, bz, placing", desc = "veto: return false to deny a player place/break/use at a cell" },
	["MC.PlayerPlacedBlock"] = { realm = "server", args = "ply, bx, by, bz, stateId", desc = "player placement committed" },
	["MC.PlayerBrokeBlock"] = { realm = "server", args = "ply, bx, by, bz, oldStateId, context", desc = "player break committed; context.damageTool requests game-layer durability" },
	["MC.PlayerUsedBlock"] = { realm = "server", args = "ply, bx, by, bz, stateId", desc = "player right-click used a block (OnUse returned true)" },
	["MC.PlayerPickedUpFluid"] = { realm = "server", args = "ply, kind, bx, by, bz, oldStateId, newStateId", desc = "a bucket source pickup committed after the caller's inventory transaction" },
	["MC.PlayerPlacedFluid"] = { realm = "server", args = "ply, kind, bx, by, bz, stateId", desc = "a bucket source placement committed after the caller's inventory transaction" },
	["MC.BlockDamaged"] = { realm = "server", args = "bx, by, bz, id, damage, health, actor", desc = "block took damage but survived" },
	["MC.BlocksExploded"] = { realm = "server", args = "center, radius, cells{bx,by,bz}[], broken, actor", desc = "explosion removed blocks" },
	["MC.TriggerExplosionBlock"] = { realm = "server", args = "context", desc = "query: return true/false to override one TRIGGER_BLOCK onExplosionHit interaction" },
	["MC.TriggerExplosionFinished"] = { realm = "server", args = "center, radius, triggeredCount, selectedCount, options", desc = "a non-destructive TRIGGER_BLOCK explosion finished" },
	["MC.BellRungByExplosion"] = { realm = "server", args = "context", desc = "a TRIGGER_BLOCK explosion rang a bell; context.ringDirection is the state facing" },
	["MC.CandleExtinguishedByExplosion"] = { realm = "server", args = "context", desc = "a TRIGGER_BLOCK explosion changed a lit candle or candle cake to lit=false" },
	["MC.BeehiveAngeredByExplosion"] = { realm = "server", args = "context", desc = "beehive/bee nest explosion hook; bee integrations should apply Java's 8x6x8 anger targeting" },
	["MC.WorldFilled"] = { realm = "server", args = "fill{x1,y1,z1,x2,y2,z2,stateId,changed}, actor", desc = "a volume fill committed (chunk-level; not in MC.BlocksChanged)" },
	["MC.WorldCleared"] = { realm = "server", args = "", desc = "the voxel world was cleared" },
	["MC.PreWorldLoad"] = { realm = "server", args = "path, name", desc = "a save is about to replace the world (last chance to read the old one)" },
	["MC.WorldLoaded"] = { realm = "server", args = "path, name, blockCount", desc = "a save finished loading" },
	["MC.WorldSaved"] = { realm = "server", args = "path, slotName", desc = "the world was written to disk" },
	["MC.SaveDeleted"] = { realm = "server", args = "slotName", desc = "a named save was deleted" },
	["MC.PresetPlaced"] = { realm = "server", args = "ply, name, origin{bx,by,bz}, rotation, changed, overwrite", desc = "a building preset was placed" },
	["MC.PresetSaved"] = { realm = "server", args = "name, ply", desc = "a building preset was saved" },
	["MC.PresetDeleted"] = { realm = "server", args = "name", desc = "a building preset was deleted" },
	["MC.ClusterSpawned"] = { realm = "server", args = "ent, record", desc = "a block-cluster entity spawned (convert, save load or API)" },
	["MC.ClusterConverted"] = { realm = "server", args = "ply, ent, blockCount", desc = "a player converted world blocks into a cluster entity" },
	["MC.ClusterPasted"] = { realm = "server", args = "ply, ent, changed", desc = "a cluster was placed back onto the grid (ent removes right after)" },
	["MC.ClusterBroken"] = { realm = "server", args = "ent, attacker", desc = "a cluster entity broke (blocks are lost)" },
	["MC.MinecraftVehicleDestroyed"] = { realm = "server", args = "vehicle, snapshot{dropItem,position,velocity,attacker,suppressDrop}", desc = "an engine-owned Minecraft vehicle was destroyed; game addons may create their own drop" },
	["MC.PlayerWorldSynced"] = { realm = "server", args = "ply, revision", desc = "a player finished applying the world snapshot" },
	["MC.ChunkHydrated"] = { realm = "server", args = "key, cx, cy, cz", desc = "a lazy-world chunk finished loading from disk (raw storage writes, no per-block events)" },
	["MC.StateRevisionApplied"] = { realm = "client", args = "generation, revision", desc = "the client applied one authoritative state revision" },
	["MC.WorkshopBaseReady"] = { realm = "server", args = "generation, workshopId, contentHash", desc = "all required players finished loading the approved Workshop base world" },
	["MC.PlayerGameModeChanged"] = { realm = "server", args = "ply, oldMode, newMode, actor", desc = "a player's authoritative Minecraft game mode changed" },
	["MC.HandWeaponResolversChanged"] = { realm = "shared", args = "resolverId", desc = "an external selected-item SWEP resolver was registered or removed" },
} )
