-- Public, read-only ItemStack helpers for separately shipped addons.
--
-- The game layer owns the normalized ItemStack representation.  External
-- addons must not call MC.GetItemCustomName / MC.ItemStackHash directly because
-- those are internal symbols with no compatibility guarantee.  These wrappers
-- deliberately return scalars only, so no live inventory/component table can
-- escape through the public API.

MC = MC or {}
MC.API = MC.API or {}
MC.API.ItemStack = MC.API.ItemStack or {}

local ItemStack = MC.API.ItemStack

-- Returns name, present, err.  An explicitly empty custom name is still
-- present, matching DataComponents.CUSTOM_NAME semantics.
function ItemStack.GetCustomName(stack)
	if not istable( stack ) then return nil, false, "invalid_stack" end
	if not isfunction( MC.GetItemCustomName ) then
		return nil, false, "item_stack_api_unavailable"
	end
	local value, present = MC.GetItemCustomName( stack )
	if present ~= true then return nil, false end
	return tostring( value or "" ), true
end

-- Stable hash of item id, count, damage and canonical components.  Consumers
-- use this as an optimistic-concurrency token in selected/held transactions.
function ItemStack.Hash(stack)
	if not istable( stack ) then return nil, "invalid_stack" end
	if not isfunction( MC.ItemStackHash ) then return nil, "item_stack_api_unavailable" end
	return tostring( MC.ItemStackHash( stack ) )
end

-- Returns the exact non-negative level stored in the normalized enchantments
-- component. This scalar wrapper keeps external addons away from the live
-- component representation while still allowing source-accurate behavior such
-- as Piercing arrows bypassing shields.
function ItemStack.GetEnchantmentLevel(stack, enchantment)
	if not istable( stack ) then return 0, "invalid_stack" end
	if not isstring( enchantment ) or enchantment == "" then return 0, "invalid_enchantment" end
	if not isfunction( MC.GetEnchantmentLevel ) then return 0, "item_stack_api_unavailable" end
	return math.max( 0, math.floor( tonumber( MC.GetEnchantmentLevel( stack, enchantment ) ) or 0 ) )
end

--------------------------------------------------------------------------- Items
-- Game-layer adapter for the neutral engine contract.  The engine owns the
-- namespace/freeze vocabulary; this file is the only place that turns a public
-- definition into the game registry's ItemStack-capable record.
MC.API.Items = MC.API.Items or {}
local Items = MC.API.Items

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do out[copyValue( key, seen )] = copyValue( child, seen ) end
	return out
end

local function itemName( value )
	if MC.ValidateModContentIdentifier then return MC.ValidateModContentIdentifier( value ) end
	if MC.NormalizeResourceLocation then return MC.NormalizeResourceLocation( value ) end
	return MC.NormalizeItemName and MC.NormalizeItemName( value ) or nil
end

function Items.Register( definition )
	if type( definition ) ~= "table" then return nil, "invalid_definition" end
	local creativeFrozen = MC.API.Creative and MC.API.Creative.IsFrozen
		and MC.API.Creative.IsFrozen() == true
	if creativeFrozen or MC.ItemRegistryFrozen or MC.API._freezeStarted or MC.API._ready then
		return nil, "registry_frozen"
	end
	local name, err = itemName( definition.id or definition.name )
	if not name then return nil, err or "invalid_identifier" end
	local copy = copyValue( definition )
	copy.name, copy.id = name, nil
	if copy.block ~= nil then
		local blockName = itemName( copy.block )
		if not blockName then return nil, "invalid_block_item" end
		if MC.ResolveBlock and not MC.ResolveBlock( blockName ) then
			return nil, "unknown_block"
		end
		copy.block = blockName
	end
	local registered, registerError = MC.RegisterItem( copy )
	if not registered then return nil, registerError or "register_failed" end
	return true, {
		name = name,
		runtimeId = registered.runtimeId,
		pending = MC.ItemRegistryFrozen ~= true,
	}
end

function Items.Resolve( value )
	local name = type( value ) == "table" and value.name or value
	local normalized = itemName( name )
	local definition = normalized and MC.GetItem and MC.GetItem( normalized ) or nil
	if not definition then return nil, "unknown_item" end
	return {
		name = definition.name,
		runtimeId = definition.runtimeId,
		blockName = definition.blockName,
		maxStack = definition.maxStack,
		maxDamage = definition.maxDamage,
	}
end

-- Key and vars of the item's name, as stored in the registry (a BlockItem
-- answers with its block's key).
function Items.TranslationKey( value )
	local normalized = itemName( type( value ) == "table" and value.name or value )
	if not normalized or not ( MC.GetItem and MC.GetItem( normalized ) ) then return nil, "unknown_item" end
	local key, vars = MC.ItemTranslationKey( normalized )
	return key, copyValue( vars )
end

-- The item's name in locale (default: the realm's language).
function Items.DisplayName( value, locale )
	if locale ~= nil and not isstring( locale ) then return nil, "invalid_locale" end
	local key, err = Items.TranslationKey( value )
	if not key then return nil, err end
	return MC.ItemDisplayName( type( value ) == "table" and value.name or value, locale )
end

function Items.RuntimeId( value )
	local resolved, err = Items.Resolve( value )
	return resolved and resolved.runtimeId or nil, err
end

-- FOOD component of an item name or ItemStack (stack components override the
-- definition): owned { nutrition, saturation, alwaysEdible, consumable } or
-- nil, "not_food" | "unknown_item". consumable reports the CONSUMABLE component.
function Items.FoodProperties( value )
	local subject = value
	if type( value ) ~= "table" or value.item == nil then
		local normalized = itemName( type( value ) == "table" and value.name or value )
		subject = normalized and MC.GetItem and MC.GetItem( normalized ) or nil
		if not subject then return nil, "unknown_item" end
	elseif not ( MC.GetItem and MC.GetItem( value.item ) ) then
		return nil, "unknown_item"
	end
	local food = MC.ItemFoodData and MC.ItemFoodData( subject ) or nil
	if not food then return nil, "not_food" end
	return {
		nutrition = food.nutrition,
		saturation = food.saturation,
		alwaysEdible = food.alwaysEdible == true,
		consumable = MC.ItemIsConsumable and MC.ItemIsConsumable( subject ) == true or false,
	}
end

function Items.NameForRuntimeId( runtimeId )
	local definition = MC.GetItem and MC.GetItem( tonumber( runtimeId ) ) or nil
	if not definition then return nil, "unknown_item" end
	return definition.name
end

function Items.ListNames()
	local names = {}
	for name in pairs( MC.Items or {} ) do names[#names + 1] = name end
	table.sort( names )
	return names
end

function Items.RegistrySnapshot()
	local entries = {}
	for _, name in ipairs( Items.ListNames() ) do
		local definition = MC.Items and MC.Items[name]
		if definition then
			entries[#entries + 1] = {
				name = name,
				runtimeId = definition.runtimeId,
				blockName = definition.blockName,
			}
		end
	end
	return { version = "mod-registry-1", items = entries }
end

------------------------------------------------------------------------ BlockLoot
-- Game-owned adapter for vanilla BlockLootSubProvider#dropSelf semantics. The
-- public surface intentionally registers only the ordinary bound BlockItem
-- drop; arbitrary loot-table metadata remains unsupported until it has an
-- equally explicit schema and evaluator contract.
MC.API.BlockLoot = MC.API.BlockLoot or {}
local BlockLoot = MC.API.BlockLoot
MC.ModBlockLootDefinitions = MC.ModBlockLootDefinitions or {}
MC.ModBlockLootRegistryFrozen = MC.ModBlockLootRegistryFrozen == true

local function registerDefaultBlockItem( blockValue, itemValue )
	local creativeFrozen = MC.API.Creative and MC.API.Creative.IsFrozen
		and MC.API.Creative.IsFrozen() == true
	if creativeFrozen or MC.ItemRegistryFrozen or MC.ModBlockLootRegistryFrozen
	or MC.API._freezeStarted or MC.API._ready then
		return nil, "registry_frozen"
	end
	local blockName, err = itemName( blockValue )
	if not blockName then return nil, err or "invalid_identifier" end
	if not ( MC.ResolveBlock and MC.ResolveBlock( blockName ) ) then return nil, "unknown_block" end
	local requestedItem
	if itemValue ~= nil then
		requestedItem, err = itemName( itemValue )
		if not requestedItem then return nil, err or "invalid_identifier" end
	end
	if MC.ModBlockLootDefinitions[blockName] then return nil, "duplicate_block_loot" end
	MC.ModBlockLootDefinitions[blockName] = {
		block = blockName,
		requestedItem = requestedItem,
	}
	return true, {
		block = blockName,
		item = requestedItem,
		pending = true,
	}
end

function BlockLoot.RegisterDefaultBlockItem( blockName, itemNameValue )
	return registerDefaultBlockItem( blockName, itemNameValue )
end

local queuedLoot = MC.ModPendingBlockLootDefinitions or {}
local queuedLootNames, lootReplayErrors = {}, {}
for blockName in pairs( queuedLoot ) do queuedLootNames[#queuedLootNames + 1] = blockName end
table.sort( queuedLootNames )
for _, blockName in ipairs( queuedLootNames ) do
	local definition = queuedLoot[blockName]
	local registered, registerError = registerDefaultBlockItem(
		blockName, type( definition ) == "table" and definition.item or nil )
	if not registered then
		lootReplayErrors[#lootReplayErrors + 1] = {
			block = blockName,
			error = registerError or "register_failed",
		}
		if ErrorNoHalt then
			ErrorNoHalt( "[MC] queued public block loot '" .. blockName .. "' failed: "
				.. tostring( registerError ) .. "\n" )
		end
	end
	queuedLoot[blockName] = nil
end
MC.ModBlockLootReplayErrors = lootReplayErrors

local function validatePublicBlockLoot()
	if #lootReplayErrors > 0 then
		local first = lootReplayErrors[1]
		return false, "block_loot_replay_failed:" .. tostring( first.block ) .. ":" .. tostring( first.error )
	end
	if not MC.ItemRegistryFrozen then return false, "block_loot_item_registry_not_frozen" end
	local names = {}
	for blockName in pairs( MC.ModBlockLootDefinitions ) do names[#names + 1] = blockName end
	table.sort( names )
	for _, blockName in ipairs( names ) do
		local definition = MC.ModBlockLootDefinitions[blockName]
		local block = MC.ResolveBlock and MC.ResolveBlock( blockName ) or nil
		if not block then return false, "block_loot_unknown_block:" .. tostring( blockName ) end
		local item = definition.requestedItem and MC.GetItem and MC.GetItem( definition.requestedItem ) or nil
		if not item and definition.requestedItem == nil and MC.ItemForBlock then item = MC.ItemForBlock( block.id ) end
		if not item then return false, "block_loot_missing_block_item:" .. tostring( blockName ) end
		if item.blockId ~= block.id then
			return false, "block_loot_item_not_block_item:" .. tostring( blockName ) .. ":" .. tostring( item.name )
		end
		definition.item = item.name
		definition.lootTable = {
			type = "minecraft:block",
			pools = { {
				conditions = { { condition = "minecraft:survives_explosion" } },
				entries = { { type = "minecraft:item", name = item.name } },
				rolls = 1,
			} },
		}
	end
	MC.ModBlockLootRegistryFrozen = true
	return true
end

-- Definitions submitted before the game adapter was included are replayed in
-- their deterministic name order, still inside the open bootstrap phase.
local queued = MC.ModPendingItemDefinitions or {}
local queuedNames = {}
local replayErrors = {}
for name in pairs( queued ) do queuedNames[#queuedNames + 1] = name end
table.sort( queuedNames )
for _, name in ipairs( queuedNames ) do
	local definition = queued[name]
	if definition then
		definition.name = name
		local registered, registerError = MC.RegisterItem( definition )
		if not registered then
			replayErrors[#replayErrors + 1] = { name = name, error = registerError or "register_failed" }
			if ErrorNoHalt then
				ErrorNoHalt( "[MC] queued public item '" .. name .. "' failed: " .. tostring( registerError ) .. "\n" )
			end
		end
	end
	queued[name] = nil
end
MC.ModItemRegistryReplayErrors = replayErrors

-- MappedRegistry.freeze rejects unbound references.  Do the same for the
-- neutral creative metadata after the item registry callback has assigned all
-- runtime ids: a forward reference is allowed during bootstrap, but a missing
-- icon/item/stack must stop APIReady instead of becoming an empty tab later.
local function publicCreativeEntryStack( entry )
	if type( entry ) ~= "table" or not MC.NormalizeItemStack then
		return nil, "item_stack_api_unavailable"
	end
	if entry.kind == "stack" then
		return MC.NormalizeItemStack( entry.stack )
	end
	if entry.kind == "item" then
		if not ( MC.GetItem and MC.GetItem( entry.name ) ) then return nil, "unknown_item" end
		return MC.NormalizeItemStack( { item = entry.name, count = 1 } )
	end
	if entry.kind == "block" then
		local block = MC.ResolveBlock and MC.ResolveBlock( entry.name ) or nil
		if not block then return nil, "unknown_block" end
		-- Match sh_creative_stacks.lua: prefer the conventional same-name
		-- BlockItem, then fall back to the item bound to the resolved block id.
		local item = MC.GetItem and MC.GetItem( entry.name ) or nil
		if not item and MC.ItemForBlock then item = MC.ItemForBlock( block.id ) end
		if not item then return nil, "missing_block_item" end
		return MC.NormalizeItemStack( { item = item.name, count = 1 } )
	end
	return nil, "invalid_entry"
end

local function publicCreativeStackKey( stack )
	if type( stack ) ~= "table" or type( stack.item ) ~= "string" then return nil end
	local components = MC.CanonicalItemComponents and MC.CanonicalItemComponents( stack.components ) or nil
	if components == nil then return nil end
	return table.concat( { stack.item, tostring( stack.damage or 0 ), components }, "\0" )
end

local function validatePublicCreativeReferences()
	if not MC.ItemRegistryFrozen then return true end
	local creative = MC.API and MC.API.Creative
	if not creative or not creative.ListCategories then return true end
	for _, category in ipairs( creative.ListCategories() or {} ) do
		if category.icon ~= nil and not ( MC.GetItem and MC.GetItem( category.icon ) ) then
			return false, "creative_icon_unknown_item:" .. tostring( category.id ) .. ":" .. tostring( category.icon )
		end
		local seenStacks = {}
		for _, entry in ipairs( category.entries or {} ) do
			local stack, stackError = publicCreativeEntryStack( entry )
			if not stack or stack.count ~= 1 then
				local prefix = "creative_entry_invalid_stack"
				if stackError == "unknown_item" then prefix = "creative_entry_unknown_item"
				elseif stackError == "unknown_block" then prefix = "creative_entry_unknown_block"
				elseif stackError == "missing_block_item" then prefix = "creative_entry_missing_block_item" end
				return false, prefix .. ":" .. tostring( category.id ) .. ":"
					.. tostring( entry.name or stackError or "invalid_stack" )
			end
			local key = publicCreativeStackKey( stack )
			if not key then
				return false, "creative_entry_invalid_stack:" .. tostring( category.id ) .. ":component_encode_failed"
			end
			if seenStacks[key] then
				return false, "creative_entry_duplicate_stack:" .. tostring( category.id ) .. ":" .. tostring( stack.item )
			end
			seenStacks[key] = true
		end
	end
	return true
end

if MC.API and MC.API._RegisterFreezeCallback and not MC.API._freezeStarted then
	MC.API._RegisterFreezeCallback( "mc.game.block_loot", validatePublicBlockLoot )
	MC.API._RegisterFreezeCallback( "mc.game.mod_content_links", validatePublicCreativeReferences )
end

MC.API.ItemsAPIReady = true
if MC.RunEvent then MC.RunEvent( "MC.ItemsAPIReady", MC.API.Items ) end
