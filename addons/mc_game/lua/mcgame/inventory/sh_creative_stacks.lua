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
		-- Slopes remain available in their own tab, but do not enter search.
		if category.id ~= "mcswep:slopes" then
			for _, entry in ipairs( dynamicCategoryEntries( category ) ) do result[#result + 1] = entry end
		end
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
	local cached = MC.CreativeOrderedProviders
	if cached and cached.revision == MC.CreativeStackProviderRevision then return cached.entries end
	local providers = {}
	for _, record in pairs( MC.CreativeStackProviders or {} ) do providers[#providers + 1] = record end
	table.sort( providers, function( left, right )
		if left.priority ~= right.priority then return left.priority < right.priority end
		return left.id < right.id
	end )
	MC.CreativeOrderedProviders = { revision = MC.CreativeStackProviderRevision, entries = providers }
	return providers
end

-- Compiled at registration, consumed only when a catalog is rebuilt. Unlike a
-- general provider, contributions cannot mutate another mod's input stacks.
MC.CreativeEntryContributions = MC.CreativeEntryContributions or {}
MC.CreativeEntryContributionOrder = MC.CreativeEntryContributionOrder or {}
local contributions = MC.CreativeEntryContributions
local contributionOrder = MC.CreativeEntryContributionOrder

local function contributionChanged( id )
	table.sort( contributionOrder, function( a, b )
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.id < b.id
	end )
	MC.CreativeStackProviderRevision = MC.CreativeStackProviderRevision + 1
	MC.CreativeStackAllowCache = nil
	if MC.RunEvent then MC.RunEvent( "MC.CreativeStackProvidersChanged", id ) end
end

local function applyContributions( key, stacks )
	if #contributionOrder == 0 then return stacks end
	local search = key == "search"
	local available
	if search then
		available = {}
		for _, tab in ipairs( MC.GetCreativeTabCatalog() ) do available[tab.key] = true end
	end
	for _, record in ipairs( contributionOrder ) do
		if record.tab == key or ( search and available[record.tab] ) then
			for _, operation in ipairs( record.operations ) do
				if ( search and operation.visibility ~= "tab" ) or ( not search and operation.visibility ~= "search" ) then
					local position = #stacks + 1
					if operation.action == "prepend" then position = 1
					elseif operation.anchor then
						-- Fabric: before the first match, after the last; absent anchors append.
						for index = 1, #stacks do
							if stacks[index].item == operation.anchor then
								position = index
								if operation.action == "before" then break end
								position = index + 1
							end
						end
					end
					local additions = operation.stacks
					for index = #stacks, position, -1 do stacks[index + #additions] = stacks[index] end
					for index = 1, #additions do stacks[position + index - 1] = MC.CopyItemStack( additions[index], 1 ) end
				end
			end
		end
	end
	-- Stack identity includes components: two potion variants remain distinct.
	local seen, count = {}, 0
	for index = 1, #stacks do
		local stack = stacks[index]
		local identity = normalizedStackKey( stack )
		if not seen[identity] then
			seen[identity], count = true, count + 1
			stacks[count] = stack
		end
	end
	for index = #stacks, count + 1, -1 do stacks[index] = nil end
	return stacks
end

function MC.BuildCreativeTabStacks( tabKey, entries )
	local key = tostring( tabKey or "" )
	local isSearch = key == "search"
	if isSearch then
		-- Generated search contents only know vanilla bootstrap items. Vanilla's
		-- search set also receives category entries. Merge searchable registered
		-- tabs here and deduplicate by the same item+components identity.
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
			MC.Fault( "creative_stack_provider_failed", "provider %s: %s", record.id, tostring( replacement ) )
		elseif replacement ~= nil then
			stacks = normalizeList( replacement, isSearch )
		end
	end
	return applyContributions( key, stacks )
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

local function nonemptyArray( value )
	if type( value ) ~= "table" or #value == 0 then return false end
	local count = 0
	for key in pairs( value ) do
		if type( key ) ~= "number" or key < 1 or key > #value or key ~= math.floor( key ) then return false end
		count = count + 1
	end
	return count == #value
end

-- Declarative counterpart to Fabric's modifyEntriesEvent + FabricItemGroupEntries.
-- Install after item registry readiness, on BOTH realms; same id replaces atomically.
function MC.API.CreativeStacks.RegisterEntries( tab, id, operations, priority )
	if type( tab ) ~= "string" or tab == "search" or tab == "inventory" or tab == "hotbar" then
		return false, "invalid_creative_target"
	end
	local validTarget = false
	for _, row in ipairs( MC.GeneratedCreativeTabs or {} ) do if row.key == tab then validTarget = true; break end end
	if not validTarget and not MC.ValidateModContentIdentifier( tab ) then return false, "invalid_creative_target" end
	local canonical = MC.ValidateModContentIdentifier( id )
	if not canonical then return false, "invalid_identifier" end
	priority = priority == nil and 0 or priority
	if type( priority ) ~= "number" or priority ~= priority or math.abs( priority ) == math.huge or priority ~= math.floor( priority ) then
		return false, "invalid_priority"
	end
	if not nonemptyArray( operations ) then return false, "invalid_creative_operations" end
	local compiled = {}
	for _, operation in ipairs( operations ) do
		if type( operation ) ~= "table" then return false, "invalid_creative_operation" end
		local action = operation.action
		if action == nil then action = "append" end
		if action ~= "append" and action ~= "prepend" and action ~= "before" and action ~= "after" then return false, "invalid_creative_action" end
		local visibility = operation.visibility
		if visibility == nil then visibility = "both" end
		if visibility ~= "both" and visibility ~= "tab" and visibility ~= "search" then return false, "invalid_creative_visibility" end
		local anchor
		if action == "before" or action == "after" then
			anchor = MC.ValidateModContentIdentifier( operation.anchor )
			if not anchor then return false, "invalid_creative_anchor" end
		end
		if not nonemptyArray( operation.items ) then return false, "invalid_creative_items" end
		local stacks = {}
		for _, value in ipairs( operation.items ) do
			if type( value ) == "table" and value.count ~= nil and value.count ~= 1 then return false, "invalid_creative_count" end
			local stack = normalizeStack( value )
			if not stack then return false, "invalid_creative_stack" end
			stacks[#stacks + 1] = stack
		end
		compiled[#compiled + 1] = { action = action, anchor = anchor, visibility = visibility, stacks = stacks }
	end
	local record = { id = canonical, tab = tab, operations = compiled, priority = priority }
	local old = contributions[canonical]
	if old then
		for index = 1, #contributionOrder do if contributionOrder[index] == old then contributionOrder[index] = record; break end end
	else contributionOrder[#contributionOrder + 1] = record end
	contributions[canonical] = record
	contributionChanged( canonical )
	return true
end

function MC.API.CreativeStacks.UnregisterEntries( id )
	local canonical = MC.ValidateModContentIdentifier( id )
	local old = canonical and contributions[canonical]
	if not old then return false end
	contributions[canonical] = nil
	for index = 1, #contributionOrder do if contributionOrder[index] == old then table.remove( contributionOrder, index ); break end end
	contributionChanged( canonical )
	return true
end

function MC.API.CreativeStacks.RegisterProvider( id, provider, priority )
	return MC.RegisterCreativeStackProvider( id, provider, priority )
end

function MC.API.CreativeStacks.UnregisterProvider( id )
	return MC.UnregisterCreativeStackProvider( id )
end

-- Providers depending on external state must explicitly invalidate after that
-- state changes, on both realms. No polling and no changes to global GC/JIT.
function MC.API.CreativeStacks.Invalidate()
	MC.CreativeStackProviderRevision = MC.CreativeStackProviderRevision + 1
	MC.CreativeStackAllowCache = nil
	if MC.RunEvent then MC.RunEvent( "MC.CreativeStackProvidersChanged" ) end
	return true
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
