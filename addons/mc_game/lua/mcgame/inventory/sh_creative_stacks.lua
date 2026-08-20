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

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do out[copyValue( key, seen )] = copyValue( child, seen ) end
	return out
end

local function dynamicCategoryEntries( category )
	local output = {}
	for _, entry in ipairs( category and category.entries or {} ) do
		if type( entry ) == "table" and entry.kind == "stack" and type( entry.stack ) == "table" then
			output[#output + 1] = copyValue( entry.stack )
		elseif type( entry ) == "table" and ( entry.kind == "item" or entry.kind == "block" ) and entry.name then
			-- BlockItem names intentionally match their block namespace id in the
			-- generated registry. If a game addon chooses a different item name it
			-- can use RegisterItem/stack instead.
			local name = tostring( entry.name )
			local item = MC.GetItem and MC.GetItem( name ) or nil
			if item then output[#output + 1] = name
			elseif entry.kind == "block" and MC.GetItem and MC.GetItem( name ) == nil then
				-- A block category may be registered before its optional BlockItem;
				-- resolve the canonical block-item name only when the game registry
				-- already exposes it. Never synthesize an invalid stack.
				local blockItem = MC.ItemForBlock and MC.ItemForBlock( MC.API and MC.API.Blocks and MC.API.Blocks.RuntimeId and MC.API.Blocks.RuntimeId( name ) or -1 )
				if blockItem and blockItem.name then output[#output + 1] = blockItem.name end
			end
		end
	end
	return output
end

-- Fresh CreativeModeTab-shaped catalog for the game UI and server allow-list.
-- Generated vanilla tabs remain the source of truth; engine-owned dynamic
-- categories are appended deterministically by registration order.
function MC.GetCreativeTabCatalog()
	local output, seen = {}, {}
	for _, source in ipairs( MC.GeneratedCreativeTabs or {} ) do
		if type( source ) == "table" and isstring( source.key ) then
			local copy = copyValue( source )
			copy.items = type( copy.items ) == "table" and copy.items or {}
			output[#output + 1] = copy
			seen[copy.key] = true
		end
	end
	local creative = MC.API and MC.API.Creative
	local categories = creative and creative.ListCategories and creative.ListCategories() or {}
	for _, category in ipairs( categories ) do
		if type( category ) == "table" and isstring( category.id ) and not seen[category.id] then
			output[#output + 1] = {
				key = category.id,
				row = category.row,
				column = category.column,
				page = category.page,
				title = category.title,
				titleZH = category.titleZH,
				titleKey = category.titleKey,
				icon = category.icon,
				background = category.background,
				items = dynamicCategoryEntries( category ),
				showTitle = category.showTitle,
				canScroll = category.canScroll,
			}
			seen[category.id] = true
		end
	end
	return output
end

local function normalizeStack( value )
	local stack = MC.NormalizeItemStack and MC.NormalizeItemStack( value ) or nil
	if MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) then return nil end
	return stack and MC.CopyItemStack( stack, 1 ) or nil
end

local function normalizedStackKey( stack )
	if type( stack ) ~= "table" or type( stack.item ) ~= "string" then return nil end
	local components = MC.CanonicalItemComponents and MC.CanonicalItemComponents( stack.components ) or nil
	if components == nil then return nil end
	-- Count is intentionally omitted: creative catalogs store one representative
	-- stack while a pick request may ask for that item's maximum stack size.
	return table.concat( { stack.item, tostring( stack.damage or 0 ), components }, "\0" )
end

local function normalizeList( source, deduplicate )
	local result, seen = {}, deduplicate and {} or nil
	for _, value in ipairs( source or {} ) do
		local stack = normalizeStack( value )
		if stack then
			local key = seen and normalizedStackKey( stack ) or nil
			if not seen or ( key and not seen[key] ) then
				result[#result + 1] = stack
				if seen then seen[key] = true end
			end
		end
	end
	return result
end

local function searchEntries( baseEntries )
	local result = {}
	for _, entry in ipairs( baseEntries or {} ) do result[#result + 1] = entry end
	local creative = MC.API and MC.API.Creative
	for _, category in ipairs( creative and creative.ListCategories and creative.ListCategories() or {} ) do
		for _, entry in ipairs( dynamicCategoryEntries( category ) ) do result[#result + 1] = entry end
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
	local key = tostring( tabKey or "" )
	local isSearch = key == "search"
	if isSearch then
		-- Generated search contents only know vanilla bootstrap items. Vanilla's
		-- search set also receives every category entry, so merge registered tabs
		-- here and deduplicate by the same item+components identity.
		entries = searchEntries( entries )
	elseif entries == nil then
		local creative = MC.API and MC.API.Creative
		local category = creative and creative.GetCategory and creative.GetCategory( tabKey ) or nil
		if category then entries = dynamicCategoryEntries( category ) end
	end
	local stacks = normalizeList( entries, isSearch )
	for _, record in ipairs( orderedProviders() ) do
		local ok, replacement = pcall( record.provider, key, normalizeList( stacks, isSearch ) )
		if not ok then
			if ErrorNoHalt then
				ErrorNoHalt( "[MCGame] creative stack provider '" .. record.id .. "' failed: " .. tostring( replacement ) .. "\n" )
			end
		elseif replacement ~= nil then
			stacks = normalizeList( replacement, isSearch )
		end
	end
	return stacks
end

local function stackKey( stack )
	stack = normalizeStack( stack )
	if not stack then return nil end
	-- This key gates a client-authored creative request. Do not use util.CRC:
	-- collisions are acceptable for UI cache hints, not for an allow-list.
	return normalizedStackKey( stack )
end

local function creativeAllowSet()
	local revision = MC.CreativeStackProviderRevision or 0
	local creative = MC.API and MC.API.Creative
	local registryFrozen = not ( creative and creative.IsFrozen ) or creative.IsFrozen() == true
	local cached = MC.CreativeStackAllowCache
	if registryFrozen and cached and cached.revision == revision then return cached.stacks end
	local allowed = {}
	for _, tab in ipairs( MC.GetCreativeTabCatalog and MC.GetCreativeTabCatalog() or MC.GeneratedCreativeTabs or {} ) do
		if type( tab ) == "table" and tab.key ~= "inventory" and tab.key ~= "hotbar" then
			for _, stack in ipairs( MC.BuildCreativeTabStacks( tab.key, tab.items ) ) do
				local key = stackKey( stack )
				if key then allowed[key] = true end
			end
		end
	end
	-- Before the neutral registry freezes, external addons may still append a
	-- category or entry. Do not retain a server allow-list that was observed
	-- halfway through bootstrap; after freeze the content set is immutable.
	MC.CreativeStackAllowCache = registryFrozen and { revision = revision, stacks = allowed } or nil
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
