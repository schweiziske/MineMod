--[[----------------------------------------------------------------------------
	MC item registry.

	Minecraft keeps blocks and items in separate registries.  A BlockItem points
	at a block, but an ItemStack always stores the item identity.  Keeping that
	boundary here prevents inventory data from inheriting legacy block IDs.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ItemAbsoluteMaxStack = 99
MC.PendingItems = MC.PendingItems or {}
MC.Items = MC.Items or {}
MC.ItemsByRuntimeId = MC.ItemsByRuntimeId or {}
MC.ItemsByBlockId = MC.ItemsByBlockId or {}
MC.ItemRegistryFrozen = MC.ItemRegistryFrozen or false
MC.ItemRegistryHash = MC.ItemRegistryHash or nil

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizeName( value )
	local name = string.lower( trim( value ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	if not string.match( name, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return name
end

local function copyList( source )
	local result = {}
	for index, value in ipairs( source or {} ) do result[index] = tostring( value ) end
	return result
end

local function normalizedInteger( value, minimum, maximum, fallback )
	value = tonumber( value )
	if value == nil then return fallback end
	-- Lua's comparisons with NaN are all false, so checking only the range
	-- would accidentally admit NaN as a runtime stack/damage/count value.
	-- Keep the registry's numeric fields finite before flooring them.
	if value ~= value or value == math.huge or value == -math.huge then return nil end
	value = math.floor( value )
	if value < minimum or value > maximum then return nil end
	return value
end

function MC.NormalizeItemName( value )
	return normalizeName( value )
end

-- Item names are translation keys. A definition may name its key (the
-- generated vanilla rows do, following Minecraft's lang files); otherwise a
-- BlockItem takes its block's key and vars when the registry freezes, and any
-- other item uses item.<namespace>.<path>.
local function itemTranslation( definition, name )
	if definition.displayName ~= nil or definition.displayNameZH ~= nil then return nil, "inline_name_unsupported" end
	local key = definition.translationKey
	if key ~= nil and not ( type( key ) == "string" and MC.I18n.ValidKey( key ) ) then return nil, "invalid_translation_key" end
	if definition.translationVars ~= nil and type( definition.translationVars ) ~= "table" then
		return nil, "invalid_translation_vars"
	end
	if key == nil and definition.block == nil then key = MC.I18n.ContentKey( "item", name ) end
	return key or false, definition.translationVars
end

function MC.RegisterItem( definition )
	if MC.ItemRegistryFrozen then return nil, "registry_frozen" end
	if type( definition ) ~= "table" then return nil, "invalid_definition" end

	local name = normalizeName( definition.name or definition.id )
	if not name then return nil, "invalid_item_name" end
	if #name > 128 then return nil, "item_name_too_long" end
	if MC.PendingItems[name] then return nil, "duplicate_item" end
	local translationKey, translationVars = itemTranslation( definition, name )
	if translationKey == nil then return nil, translationVars end

	local maxStack = normalizedInteger( definition.maxStack, 1, MC.ItemAbsoluteMaxStack, 64 )
	if not maxStack then return nil, "invalid_max_stack" end
	local maxDamage = normalizedInteger( definition.maxDamage, 0, 16777215, 0 )
	if not maxDamage then return nil, "invalid_max_damage" end
	if maxDamage > 0 then maxStack = 1 end
	local useDuration = normalizedInteger( definition.useDuration, 0, 72000, 0 )
	if useDuration == nil then return nil, "invalid_use_duration" end
	local toolDamagePerBlock = normalizedInteger( definition.toolDamagePerBlock, 0, 255, maxDamage > 0 and 1 or 0 )
	if toolDamagePerBlock == nil then return nil, "invalid_tool_damage" end
	local foodNutrition = normalizedInteger( definition.foodNutrition, 0, 255, 0 )
	if foodNutrition == nil then return nil, "invalid_food_nutrition" end
	local foodSaturation = tonumber( definition.foodSaturation )
	if foodSaturation == nil or foodSaturation ~= foodSaturation or foodSaturation == math.huge or foodSaturation == -math.huge
		or foodSaturation < 0 or foodSaturation > 255 then
		foodSaturation = 0
	end

	local blockName = definition.block ~= nil and normalizeName( definition.block ) or nil
	if definition.block ~= nil and not blockName then return nil, "invalid_block_item" end
	local texture = trim( definition.texture )
	if texture == "" then texture = nil end
	if texture and not string.match( texture, "^[a-zA-Z0-9_./-]+$" ) then return nil, "invalid_item_texture" end

	local registered = {
		name = name,
		maxStack = maxStack,
		maxDamage = maxDamage,
		blockName = blockName,
		texture = texture,
		model = trim( definition.model ) ~= "" and trim( definition.model ) or nil,
		-- false until a BlockItem inherits its block's key at the freeze.
		translationKey = translationKey,
		translationVars = translationVars,
		rarity = string.lower( trim( definition.rarity ~= nil and definition.rarity or "common" ) ),
		kind = string.lower( trim( definition.kind ~= nil and definition.kind or ( blockName and "block" or "item" ) ) ),
		tags = copyList( definition.tags ),
		source = trim( definition.source ) ~= "" and trim( definition.source ) or nil,
		useDuration = useDuration,
		useAnimation = trim( definition.useAnimation ) ~= "" and string.lower( trim( definition.useAnimation ) ) or "none",
		useKind = trim( definition.useKind ) ~= "" and string.lower( trim( definition.useKind ) ) or nil,
		consumable = definition.consumable == true,
		foodNutrition = foodNutrition,
		foodSaturation = foodSaturation,
		foodAlwaysEdible = definition.foodAlwaysEdible == true,
		toolDamagePerBlock = toolDamagePerBlock,
		unbreakable = definition.unbreakable == true,
		useHandler = isfunction and isfunction( definition.useHandler ) and definition.useHandler or nil,
	}

	if registered.rarity ~= "common" and registered.rarity ~= "uncommon"
	and registered.rarity ~= "rare" and registered.rarity ~= "epic" then
		return nil, "invalid_rarity"
	end

	MC.PendingItems[name] = registered
	return registered
end

local function resolveBlockItem( definition )
	local target = definition.blockName or definition.name
	local resolved = MC.ResolveBlock and MC.ResolveBlock( target ) or nil
	if not resolved or resolved.id == 0 then return end
	definition.blockName = resolved.mcid
	definition.blockId = resolved.id
	definition.kind = "block"
	MC.ItemsByBlockId[resolved.id] = definition
	if not definition.translationKey and resolved.block then
		definition.translationKey = resolved.block.translationKey
		definition.translationVars = resolved.block.translationVars
	end
end

function MC.FinalizeItemRegistry()
	if MC.ItemRegistryFrozen then return #MC.ItemsByRuntimeId end

	if not MC.PendingItems["minecraft:air"] then
		MC.PendingItems["minecraft:air"] = {
			name = "minecraft:air", maxStack = 64, maxDamage = 0,
			kind = "item", rarity = "common", tags = {}, translationKey = "block.minecraft.air",
		}
	end

	local names = {}
	for name in pairs( MC.PendingItems ) do
		if name ~= "minecraft:air" then names[#names + 1] = name end
	end
	table.sort( names )

	local ordered = { "minecraft:air" }
	for _, name in ipairs( names ) do ordered[#ordered + 1] = name end
	if #ordered > 65535 then return nil, "too_many_items" end

	local byName, byRuntime, byBlock = {}, {}, {}
	MC.ItemsByBlockId = byBlock
	for arrayIndex, name in ipairs( ordered ) do
		local definition = MC.PendingItems[name]
		local runtimeId = arrayIndex - 1
		definition.runtimeId = runtimeId
		byName[name] = definition
		byRuntime[runtimeId] = definition
		if name ~= "minecraft:air" then resolveBlockItem( definition ) end
	end

	MC.Items = byName
	MC.ItemsByRuntimeId = byRuntime
	MC.ItemsByBlockId = byBlock

	MC.RefreshItemRegistryHash()
	MC.ItemRegistryFrozen = true
	return #ordered
end

function MC.RefreshItemRegistryHash()
	local ordered = MC.ItemsByRuntimeId or {}
	local canonical = { "mc-item-registry-v2\n" }
	for runtimeId = 0, #ordered - 1 do
		local definition = ordered[runtimeId]
		if definition then
			canonical[#canonical + 1] = table.concat( {
				definition.name,
				tostring( definition.maxStack ),
				tostring( definition.maxDamage ),
				tostring( definition.blockName or "" ),
				tostring( definition.texture or "" ),
				tostring( definition.model or "" ),
				tostring( definition.kind or "item" ),
				tostring( definition.useDuration or 0 ),
				tostring( definition.useAnimation or "none" ),
				tostring( definition.useKind or "" ),
				tostring( definition.consumable == true ),
			tostring( definition.foodNutrition or 0 ),
			tostring( definition.foodSaturation or 0 ),
			tostring( definition.toolDamagePerBlock or 0 ),
			tostring( definition.unbreakable == true ),
			}, "\0" ) .. "\n"
		end
	end
	canonical[#canonical + 1] = "item-model-catalog\0" .. tostring( MC.ItemModelRegistryHash or "" ) .. "\n"
	canonical = table.concat( canonical )
	MC.ItemRegistryHash = util and util.SHA256 and util.SHA256( canonical )
		or util and util.CRC and util.CRC( canonical ) or canonical
	return MC.ItemRegistryHash
end

function MC.GetItem( value )
	if type( value ) == "table" and value.name then
		local name = normalizeName( value.name )
		return name and ( MC.Items[name] or MC.PendingItems[name] ) or nil
	end
	if type( value ) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return nil end
		return MC.ItemsByRuntimeId[math.floor( value )]
	end
	local name = normalizeName( value )
	return name and ( MC.Items[name] or MC.PendingItems[name] ) or nil
end

function MC.ResolveItem( value )
	local definition = MC.GetItem( value )
	if not definition then return nil end
	return {
		name = definition.name,
		runtimeId = definition.runtimeId,
		item = definition,
		blockId = definition.blockId,
	}
end

function MC.ItemForBlock( blockId )
	return MC.ItemsByBlockId[math.floor( tonumber( blockId ) or -1 )]
end

function MC.ItemForBlockState( stateId )
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	return blockId and MC.ItemForBlock( blockId ) or nil
end

-- Key and vars of an item name. A BlockItem that has not been bound to its
-- block yet (before the freeze) answers with its block's key.
function MC.ItemTranslationKey( value )
	local definition = MC.GetItem( value )
	if not definition then return nil end
	if definition.translationKey then return definition.translationKey, definition.translationVars end
	local resolved = definition.blockName and MC.ResolveBlock and MC.ResolveBlock( definition.blockName ) or nil
	if resolved and resolved.block then return resolved.block.translationKey, resolved.block.translationVars end
	return MC.I18n.ContentKey( "item", definition.name )
end

-- The item's name in locale (default: this realm's language). Names are
-- never stored, so the registry keeps no language of its own.
function MC.ItemDisplayName( value, locale )
	local key, vars = MC.ItemTranslationKey( value )
	if not key then return tostring( value or "" ) end
	return MC.I18n.Resolve( key, vars, locale )
end

function MC.ItemMaxStack( value )
	local definition = MC.GetItem( value )
	return definition and definition.maxStack or 0
end

function MC.ItemMaxDamage( value )
	local definition = MC.GetItem( value )
	return definition and definition.maxDamage or 0
end

local function finalizeItemsAtBootstrapBoundary()
	if MC.ItemRegistryFrozen then return true end
	local replayErrors = MC.ModItemRegistryReplayErrors
	if type( replayErrors ) == "table" and #replayErrors > 0 then
		local first = replayErrors[1]
		local detail = type( first ) == "table"
			and ( tostring( first.name or "?" ) .. ":" .. tostring( first.error or "register_failed" ) )
			or tostring( first )
		return false, "item_registry_replay_failed:" .. detail
	end
	local count, err = MC.FinalizeItemRegistry()
	if not count then
		local message = "[MC] item registry finalize failed: " .. tostring( err or "unknown" ) .. "\n"
		if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		return false, err or "item_registry_finalize_failed"
	end
	return true
end

if MC.API and MC.API._RegisterFreezeCallback then
	if MC.API._freezeStarted then
		finalizeItemsAtBootstrapBoundary()
	else
		MC.API._RegisterFreezeCallback( "mc.game.items", finalizeItemsAtBootstrapBoundary )
	end
elseif timer and timer.Simple then
	-- Standalone test harnesses may include the game registry without the engine
	-- facade; preserve their historical self-finalizing behavior.
	timer.Simple( 0, finalizeItemsAtBootstrapBoundary )
else
	finalizeItemsAtBootstrapBoundary()
end
