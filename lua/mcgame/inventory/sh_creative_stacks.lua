--[[----------------------------------------------------------------------------
	Creative-catalog ItemStack entries.

	GeneratedCreativeTabs contains the ordinary one-stack-per-item entries that
	can be extracted directly from CreativeModeTabs.java. Java also generates
	component-bearing entries at runtime (potions are the important example), so
	the catalog must be able to carry complete ItemStacks rather than item IDs.

	External addons may register providers. Providers run in deterministic
	priority/id order and receive a fresh array of normalized base stacks. They
	may return a replacement array; malformed entries are ignored at the final
	normalization boundary instead of reaching the creative UI or network path.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.CreativeStackProviders = MC.CreativeStackProviders or {}
MC.CreativeStackProviderRevision = MC.CreativeStackProviderRevision or 0

local function normalizeStack( value )
	local stack = MC.NormalizeItemStack and MC.NormalizeItemStack( value ) or nil
	if MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) then return nil end
	return stack and MC.CopyItemStack( stack, 1 ) or nil
end

local function normalizeList( source )
	local result = {}
	for _, value in ipairs( source or {} ) do
		local stack = normalizeStack( value )
		if stack then result[#result + 1] = stack end
	end
	return result
end

function MC.RegisterCreativeStackProvider( id, provider, priority )
	id = tostring( id or "" )
	if id == "" or type( provider ) ~= "function" then return false, "invalid_creative_stack_provider" end
	MC.CreativeStackProviders[id] = {
		id = id,
		provider = provider,
		priority = math.floor( tonumber( priority ) or 0 ),
	}
	MC.CreativeStackProviderRevision = MC.CreativeStackProviderRevision + 1
	MC.CreativeStackAllowCache = nil
	if MC.RunEvent then MC.RunEvent( "MC.CreativeStackProvidersChanged", id ) end
	return true
end

function MC.UnregisterCreativeStackProvider( id )
	id = tostring( id or "" )
	if MC.CreativeStackProviders[id] == nil then return false end
	MC.CreativeStackProviders[id] = nil
	MC.CreativeStackProviderRevision = MC.CreativeStackProviderRevision + 1
	MC.CreativeStackAllowCache = nil
	if MC.RunEvent then MC.RunEvent( "MC.CreativeStackProvidersChanged", id ) end
	return true
end

local function orderedProviders()
	local providers = {}
	for _, record in pairs( MC.CreativeStackProviders or {} ) do providers[#providers + 1] = record end
	table.sort( providers, function( left, right )
		if left.priority ~= right.priority then return left.priority < right.priority end
		return left.id < right.id
	end )
	return providers
end

function MC.BuildCreativeTabStacks( tabKey, entries )
	local stacks = normalizeList( entries )
	for _, record in ipairs( orderedProviders() ) do
		local ok, replacement = pcall( record.provider, tostring( tabKey or ""), normalizeList( stacks ) )
		if not ok then
			if ErrorNoHalt then
				ErrorNoHalt( "[MCGame] creative stack provider '" .. record.id .. "' failed: " .. tostring( replacement ) .. "\n" )
			end
		elseif replacement ~= nil then
			stacks = normalizeList( replacement )
		end
	end
	return stacks
end

local function stackKey( stack )
	stack = normalizeStack( stack )
	if not stack then return nil end
	local components = MC.CanonicalItemComponents and MC.CanonicalItemComponents( stack.components ) or nil
	if components == nil then return nil end
	-- This key gates a client-authored creative request. Do not use util.CRC:
	-- collisions are acceptable for UI cache hints, not for an allow-list.
	-- Count is intentionally omitted because left click requests max stack while
	-- the Java creative catalog stores one representative ItemStack.
	return table.concat( { stack.item, tostring( stack.damage or 0 ), components }, "\0" )
end

local function creativeAllowSet()
	local revision = MC.CreativeStackProviderRevision or 0
	local cached = MC.CreativeStackAllowCache
	if cached and cached.revision == revision then return cached.stacks end
	local allowed = {}
	for _, tab in ipairs( MC.GeneratedCreativeTabs or {} ) do
		if type( tab ) == "table" and tab.key ~= "inventory" and tab.key ~= "hotbar" then
			for _, stack in ipairs( MC.BuildCreativeTabStacks( tab.key, tab.items ) ) do
				local key = stackKey( stack )
				if key then allowed[key] = true end
			end
		end
	end
	MC.CreativeStackAllowCache = { revision = revision, stacks = allowed }
	return allowed
end

function MC.CreativeCatalogContainsStack( stack )
	local key = stackKey( stack )
	return key ~= nil and creativeAllowSet()[key] == true
end

MC.API = MC.API or {}
MC.API.CreativeStacks = MC.API.CreativeStacks or {}

function MC.API.CreativeStacks.RegisterProvider( id, provider, priority )
	return MC.RegisterCreativeStackProvider( id, provider, priority )
end

function MC.API.CreativeStacks.UnregisterProvider( id )
	return MC.UnregisterCreativeStackProvider( id )
end

function MC.API.CreativeStacks.Contains( stack )
	return MC.CreativeCatalogContainsStack( stack )
end

-- This module belongs to the separately loaded game layer, so MC.APIReady is
-- not a sufficient signal for external addons: the engine may already be
-- ready before the inventory layer has installed this API.  Fire a dedicated,
-- replayable readiness marker after every public method above exists.
MC.CreativeStacksAPIReady = true
if MC.RunEvent then MC.RunEvent( "MC.CreativeStacksAPIReady", MC.API.CreativeStacks ) end
