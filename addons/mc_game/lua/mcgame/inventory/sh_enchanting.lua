--[[----------------------------------------------------------------------------
	Minecraft Java 26.2 enchanting-table rules.

	All option costs, candidates, weights, compatibility checks and clues are
	pure functions of the authoritative player seed, item stack and bookshelf
	count. The server recomputes them for every button transaction.
------------------------------------------------------------------------------]]

MC = MC or {}

local API = MC.API or {}
local World = API.World or {}
local DATA = MC.GeneratedEnchanting or {}
local DEFINITIONS = DATA.enchantments or {}
local IN_TABLE = DATA.inTable or {}
local ITEM_ENCHANTABILITY = DATA.itemEnchantability or {}
local INT_MAX = 2147483647
local UINT_32 = 4294967296
local INT_31 = 2147483648

local function identifier( value )
	value = string.lower( tostring( value or "" ) )
	if value == "" then return nil end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	return value
end

local function listSet( values )
	local result = {}
	for _, value in ipairs( values or {} ) do
		local name = identifier( value )
		if name then result[name] = true end
	end
	return result
end

local PRIMARY_ITEMS = {}
local EXCLUSIVE = {}
for enchantmentId, definition in pairs( DEFINITIONS ) do
	PRIMARY_ITEMS[enchantmentId] = listSet( definition.primaryItems )
	EXCLUSIVE[enchantmentId] = listSet( definition.exclusive )
end

local POWER_PROVIDERS = listSet( DATA.powerProviders )
local POWER_TRANSMITTERS = listSet( DATA.powerTransmitters )

local BOOKSHELF_OFFSETS = {}
for x = -2, 2 do
	for vertical = 0, 1 do
		for horizontalZ = -2, 2 do
			if math.abs( x ) == 2 or math.abs( horizontalZ ) == 2 then
				BOOKSHELF_OFFSETS[#BOOKSHELF_OFFSETS + 1] = {
					x = x,
					y = vertical,
					z = horizontalZ,
				}
			end
		end
	end
end
MC.EnchantingBookshelfOffsets = BOOKSHELF_OFFSETS

local function finiteNumber( value )
	value = tonumber( value )
	if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
	return value
end

local function signed32( value )
	value = math.floor( finiteNumber( value ) or 0 ) % UINT_32
	return value >= INT_31 and value - UINT_32 or value
end

-- Java performs the enchantment-span expression as float, not double. This
-- rounds a finite Lua number to IEEE-754 binary32 using ties-to-even, so the
-- subsequent Math.round call stays deterministic at half-integer boundaries.
local function float32( value )
	value = finiteNumber( value ) or 0
	if value == 0 then return value end
	local sign = value < 0 and -1 or 1
	value = math.abs( value )
	local exponent = math.floor( math.log( value ) / math.log( 2 ) ) + 1
	local mantissa = value / 2 ^ exponent
	while mantissa < 0.5 do exponent = exponent - 1 mantissa = mantissa * 2 end
	while mantissa >= 1 do exponent = exponent + 1 mantissa = mantissa / 2 end
	local scaled = mantissa * 16777216 -- 2^24 significant integer
	local lower = math.floor( scaled )
	local fraction = scaled - lower
	if fraction > 0.5 or fraction == 0.5 and lower % 2 == 1 then lower = lower + 1 end
	if lower >= 16777216 then
		lower = lower / 2
		exponent = exponent + 1
	end
	return sign * lower * 2 ^ ( exponent - 24 )
end

MC.EnchantingFloat32 = float32

local function component( stack, key )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil, false end
	local namespaced = string.find( key, ":", 1, true ) and key or "minecraft:" .. key
	if components[namespaced] ~= nil then return components[namespaced], true end
	local short = string.match( namespaced, "^[^:]+:(.+)$" ) or namespaced
	if components[short] ~= nil then return components[short], true end
	return nil, false
end

function MC.EnchantingItemEnchantability( stackOrItem )
	local stack = type( stackOrItem ) == "table" and stackOrItem or nil
	local item = identifier( stack and stack.item or stackOrItem )
	if not item then return nil end
	if stack then
		local override, present = component( stack, "enchantable" )
		if present then
			local value = finiteNumber( type( override ) == "table" and override.value or override )
			value = value and math.floor( value ) or 0
			return value > 0 and value or nil
		end
	end
	return ITEM_ENCHANTABILITY[item]
end

function MC.EnchantingIsItemEnchantable( stack )
	if MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) or type( stack ) ~= "table" then return false end
	if not MC.EnchantingItemEnchantability( stack ) then return false end
	local levels = MC.GetItemEnchantments and MC.GetItemEnchantments( stack, false ) or {}
	for _, level in pairs( levels or {} ) do
		if math.floor( tonumber( level ) or 0 ) > 0 then return false end
	end
	return true
end

function MC.EnchantingPrimarySupportsItem( enchantmentId, stackOrItem )
	enchantmentId = identifier( enchantmentId )
	local item = identifier( type( stackOrItem ) == "table" and stackOrItem.item or stackOrItem )
	return enchantmentId ~= nil and item ~= nil
		and PRIMARY_ITEMS[enchantmentId] ~= nil and PRIMARY_ITEMS[enchantmentId][item] == true or false
end

function MC.EnchantingEnchantmentsCompatible( leftId, rightId )
	leftId, rightId = identifier( leftId ), identifier( rightId )
	if not leftId or not rightId or leftId == rightId then return false end
	if not DEFINITIONS[leftId] or not DEFINITIONS[rightId] then return false end
	return not ( EXCLUSIVE[leftId] and EXCLUSIVE[leftId][rightId]
		or EXCLUSIVE[rightId] and EXCLUSIVE[rightId][leftId] )
end

function MC.EnchantingTruncTowardZero( value )
	value = finiteNumber( value ) or 0
	return value < 0 and math.ceil( value ) or math.floor( value )
end

local function defaultBlockNameAt( bx, by, bz )
	if type( World.GetBlockInfo ) ~= "function" then return "minecraft:air" end
	local info = World.GetBlockInfo( bx, by, bz )
	return identifier( info and ( info.mcid or info.name ) or "minecraft:air" )
end

function MC.EnchantingBlockIsPowerProvider( blockName )
	return POWER_PROVIDERS[identifier( blockName ) or ""] == true
end

function MC.EnchantingBlockIsPowerTransmitter( blockName )
	return POWER_TRANSMITTERS[identifier( blockName ) or ""] == true
end

-- Project voxel coordinates use bx/by as the horizontal plane and bz as the
-- vertical axis. Java BlockPos x/y/z therefore maps to bx/bz/by here.
function MC.EnchantingCountBookshelves( bx, by, bz, blockNameAt )
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	blockNameAt = type( blockNameAt ) == "function" and blockNameAt or defaultBlockNameAt
	local count = 0
	for _, offset in ipairs( BOOKSHELF_OFFSETS ) do
		local provider = blockNameAt( bx + offset.x, by + offset.z, bz + offset.y )
		if MC.EnchantingBlockIsPowerProvider( provider ) then
			local middleX = MC.EnchantingTruncTowardZero( offset.x / 2 )
			local middleZ = MC.EnchantingTruncTowardZero( offset.z / 2 )
			local transmitter = blockNameAt( bx + middleX, by + middleZ, bz + offset.y )
			if MC.EnchantingBlockIsPowerTransmitter( transmitter ) then count = count + 1 end
		end
	end
	return math.min( count, 15 ), count
end

function MC.EnchantingCostForOption( random, optionIndex, bookshelfCount, stack )
	if type( random ) ~= "table" or type( random.NextInt ) ~= "function" then return 0, "invalid_random" end
	optionIndex = math.floor( tonumber( optionIndex ) or -1 )
	if optionIndex < 0 or optionIndex > 2 then return 0, "invalid_enchantment_option" end
	if not MC.EnchantingItemEnchantability( stack ) then return 0 end
	bookshelfCount = math.Clamp( math.floor( tonumber( bookshelfCount ) or 0 ), 0, 15 )
	local selected = random:NextInt( 8 ) + 1 + math.floor( bookshelfCount / 2 ) + random:NextInt( bookshelfCount + 1 )
	if optionIndex == 0 then return math.max( math.floor( selected / 3 ), 1 ) end
	if optionIndex == 1 then return math.floor( selected * 2 / 3 ) + 1 end
	return math.max( selected, bookshelfCount * 2 )
end

function MC.EnchantingCalculateCosts( seed, bookshelfCount, stack )
	if not MC.NewLegacyRandom then return { 0, 0, 0 }, "legacy_random_unavailable" end
	local random = MC.NewLegacyRandom( signed32( seed ) )
	local costs = {}
	for optionIndex = 0, 2 do
		local cost = MC.EnchantingCostForOption( random, optionIndex, bookshelfCount, stack )
		if cost < optionIndex + 1 then cost = 0 end
		costs[optionIndex + 1] = cost
	end
	return costs
end

local function levelCost( definition, level, maximum )
	local rule = maximum and definition.maxCost or definition.minCost
	return math.floor( tonumber( rule and rule.base ) or 0 )
		+ math.max( 0, level - 1 ) * math.floor( tonumber( rule and rule.perLevel ) or 0 )
end

local function availableEnchantments( adjustedCost, stack )
	local item = identifier( stack and stack.item )
	local isBook = item == "minecraft:book"
	local candidates = {}
	for _, enchantmentId in ipairs( IN_TABLE ) do
		local definition = DEFINITIONS[enchantmentId]
		if definition and ( isBook or MC.EnchantingPrimarySupportsItem( enchantmentId, item ) ) then
			for level = math.max( 1, math.floor( tonumber( definition.maxLevel ) or 1 ) ), 1, -1 do
				if adjustedCost >= levelCost( definition, level, false )
				and adjustedCost <= levelCost( definition, level, true ) then
					candidates[#candidates + 1] = {
						id = enchantmentId,
						level = level,
						weight = math.max( 0, math.floor( tonumber( definition.weight ) or 0 ) ),
					}
					break
				end
			end
		end
	end
	return candidates
end

local function weightedPick( random, candidates )
	local total = 0
	for _, candidate in ipairs( candidates ) do total = total + candidate.weight end
	if total <= 0 then return nil end
	local selection = random:NextInt( total )
	for _, candidate in ipairs( candidates ) do
		selection = selection - candidate.weight
		if selection < 0 then
			return { id = candidate.id, level = candidate.level }
		end
	end
	return nil
end

local function filterCompatible( candidates, selected )
	local filtered = {}
	for _, candidate in ipairs( candidates ) do
		if MC.EnchantingEnchantmentsCompatible( selected.id, candidate.id ) then
			filtered[#filtered + 1] = candidate
		end
	end
	return filtered
end

local function adjustedEnchantmentCost( random, displayCost, enchantability )
	local quarter = math.floor( enchantability / 4 ) + 1
	local cost = math.max( 0, math.floor( tonumber( displayCost ) or 0 ) )
	cost = cost + 1 + random:NextInt( quarter ) + random:NextInt( quarter )
	local first = random:NextFloat()
	local second = random:NextFloat()
	local span = float32( float32( float32( first + second ) - 1 ) * float32( 0.15 ) )
	local floatCost = float32( cost )
	local adjusted = float32( floatCost + float32( floatCost * span ) )
	return math.Clamp( math.floor( adjusted + 0.5 ), 1, INT_MAX )
end

function MC.EnchantingSelectEnchantments( random, stack, displayCost )
	if type( random ) ~= "table" or type( random.NextInt ) ~= "function" then return {}, "invalid_random" end
	local enchantability = MC.EnchantingItemEnchantability( stack )
	if not enchantability then return {} end
	local adjustedCost = adjustedEnchantmentCost( random, displayCost, enchantability )
	local candidates = availableEnchantments( adjustedCost, stack )
	local results = {}
	if #candidates > 0 then
		local selected = weightedPick( random, candidates )
		if selected then results[#results + 1] = selected end
		while #results > 0 and random:NextInt( 50 ) <= adjustedCost do
			candidates = filterCompatible( candidates, results[#results] )
			if #candidates == 0 then break end
			selected = weightedPick( random, candidates )
			if not selected then break end
			results[#results + 1] = selected
			adjustedCost = math.floor( adjustedCost / 2 )
		end
	end
	return results, nil, adjustedCost
end

function MC.EnchantingRollOption( seed, optionIndex, stack, displayCost )
	optionIndex = math.floor( tonumber( optionIndex ) or -1 )
	if optionIndex < 0 or optionIndex > 2 then return nil, "invalid_enchantment_option" end
	if not MC.NewLegacyRandom then return nil, "legacy_random_unavailable" end
	local random = MC.NewLegacyRandom( signed32( signed32( seed ) + optionIndex ) )
	local results, err = MC.EnchantingSelectEnchantments( random, stack, displayCost )
	if err then return nil, err end
	if stack and stack.item == "minecraft:book" and #results > 1 then
		table.remove( results, random:NextInt( #results ) + 1 )
	end
	local clue
	if #results > 0 then
		local selected = results[random:NextInt( #results ) + 1]
		clue = { id = selected.id, level = selected.level }
	end
	return results, clue
end

function MC.EnchantingBuildOptions( seed, bookshelfCount, stack )
	local costs, costError = MC.EnchantingCalculateCosts( seed, bookshelfCount, stack )
	if costError then return nil, costError end
	local options = {}
	for optionIndex = 0, 2 do
		local cost = costs[optionIndex + 1] or 0
		local enchantments, clue = {}, nil
		if cost > 0 then
			enchantments, clue = MC.EnchantingRollOption( seed, optionIndex, stack, cost )
			if not enchantments then return nil, clue end
		end
		options[optionIndex + 1] = {
			index = optionIndex,
			cost = cost,
			lapisCost = optionIndex + 1,
			enchantments = enchantments,
			clue = clue and clue.id or nil,
			clueLevel = clue and clue.level or 0,
		}
	end
	return options
end

function MC.EnchantingOptionAvailable( option, experienceLevel, lapisCount, infiniteMaterials )
	if type( option ) ~= "table" or math.floor( tonumber( option.cost ) or 0 ) <= 0
	or type( option.enchantments ) ~= "table" or #option.enchantments == 0 then
		return false, "enchantment_unavailable"
	end
	if infiniteMaterials == true then return true end
	local payment = math.max( 1, math.floor( tonumber( option.lapisCost ) or ( tonumber( option.index ) or 0 ) + 1 ) )
	if math.floor( tonumber( lapisCount ) or 0 ) < payment then return false, "not_enough_lapis" end
	experienceLevel = math.max( 0, math.floor( tonumber( experienceLevel ) or 0 ) )
	if experienceLevel < payment or experienceLevel < math.floor( tonumber( option.cost ) or 0 ) then
		return false, "not_enough_experience"
	end
	return true
end

function MC.EnchantingApplyResult( stack, enchantments )
	if MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) or type( stack ) ~= "table" then return nil, "empty_stack" end
	local output = MC.CopyItemStack and MC.CopyItemStack( stack ) or nil
	if not output then return nil, "item_stack_copy_failed" end
	local stored = output.item == "minecraft:book"
	if stored then output.item = "minecraft:enchanted_book" end
	local levels = {}
	for _, enchantment in ipairs( enchantments or {} ) do
		local enchantmentId = identifier( enchantment and ( enchantment.id or enchantment.enchantment ) )
		local level = math.floor( tonumber( enchantment and enchantment.level ) or 0 )
		if enchantmentId and level > 0 then
			levels[enchantmentId] = math.max( levels[enchantmentId] or 0, level )
		end
	end
	if not next( levels ) then return nil, "empty_enchantment_result" end
	if not MC.SetItemEnchantments then return nil, "item_enchantment_api_unavailable" end
	return MC.SetItemEnchantments( output, levels, stored )
end

MC.EnchantingDataVersion = DATA.version
MC.EnchantingDataSourceHash = DATA.sourceHash
