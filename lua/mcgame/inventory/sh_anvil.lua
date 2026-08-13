--[[----------------------------------------------------------------------------
	Shared Java 26.2 anvil rules.

	The result stack is a pure function of the two authoritative input stacks,
	the filtered rename text and the player's infinite-materials status. The
	server calls this before every commit; clients never submit a result stack.
------------------------------------------------------------------------------]]

MC = MC or {}

local INT_MAX = 2147483647

local function identifier( value )
	value = string.lower( tostring( value or "" ) )
	if value == "" then return nil end
	if string.sub( value, 1, 1 ) == "#" then
		local nested = identifier( string.sub( value, 2 ) )
		return nested and "#" .. nested or nil
	end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	return value
end

local ENCHANTMENT_ROWS = {
	{ "aqua_affinity", "head_armor", 1, 4 },
	{ "bane_of_arthropods", "weapon", 5, 2, "damage" },
	{ "binding_curse", "equippable", 1, 8 },
	{ "blast_protection", "armor", 4, 4, "armor" },
	{ "breach", "mace", 4, 4, "damage" },
	{ "channeling", "trident", 1, 8 },
	{ "density", "mace", 5, 2, "damage" },
	{ "depth_strider", "foot_armor", 3, 4, "boots" },
	{ "efficiency", "mining", 5, 1 },
	{ "feather_falling", "foot_armor", 4, 2 },
	{ "fire_aspect", "fire_aspect", 2, 4 },
	{ "fire_protection", "armor", 4, 2, "armor" },
	{ "flame", "bow", 1, 4 },
	{ "fortune", "mining_loot", 3, 4, "mining" },
	{ "frost_walker", "foot_armor", 2, 4, "boots" },
	{ "impaling", "trident", 5, 4, "damage" },
	{ "infinity", "bow", 1, 8, "bow" },
	{ "knockback", "melee_weapon", 2, 2 },
	{ "looting", "melee_weapon", 3, 4 },
	{ "loyalty", "trident", 3, 2, "riptide" },
	{ "luck_of_the_sea", "fishing", 3, 4 },
	{ "lunge", "lunge", 3, 2 },
	{ "lure", "fishing", 3, 4 },
	{ "mending", "durability", 1, 4, "bow" },
	{ "multishot", "crossbow", 1, 4, "crossbow" },
	{ "piercing", "crossbow", 4, 1, "crossbow" },
	{ "power", "bow", 5, 1 },
	{ "projectile_protection", "armor", 4, 2, "armor" },
	{ "protection", "armor", 4, 1, "armor" },
	{ "punch", "bow", 2, 4 },
	{ "quick_charge", "crossbow", 3, 2 },
	{ "respiration", "head_armor", 3, 4 },
	{ "riptide", "trident", 3, 4, "riptide" },
	{ "sharpness", "sharp_weapon", 5, 1, "damage" },
	{ "silk_touch", "mining_loot", 1, 8, "mining" },
	{ "smite", "weapon", 5, 2, "damage" },
	{ "soul_speed", "foot_armor", 3, 8 },
	{ "sweeping_edge", "sweeping", 3, 4 },
	{ "swift_sneak", "leg_armor", 3, 8 },
	{ "thorns", "armor", 3, 8 },
	{ "unbreaking", "durability", 3, 2 },
	{ "vanishing_curse", "vanishing", 1, 8 },
	{ "wind_burst", "mace", 3, 4 },
}

-- Java 26.2 data/minecraft/tags/enchantment/tooltip_order.json.  Tooltip
-- presentation is deliberately separate from registry construction order:
-- ItemEnchantments.addToTooltip emits this tag first, then any modded entries
-- that are absent from it.
local ENCHANTMENT_TOOLTIP_ORDER = {
	"binding_curse", "vanishing_curse", "riptide", "channeling", "wind_burst",
	"frost_walker", "lunge", "sharpness", "smite", "bane_of_arthropods",
	"impaling", "power", "density", "breach", "piercing", "sweeping_edge",
	"multishot", "fire_aspect", "flame", "knockback", "punch", "protection",
	"blast_protection", "fire_protection", "projectile_protection", "feather_falling",
	"fortune", "looting", "silk_touch", "luck_of_the_sea", "efficiency",
	"quick_charge", "lure", "respiration", "aqua_affinity", "soul_speed",
	"swift_sneak", "depth_strider", "thorns", "loyalty", "unbreaking",
	"infinity", "mending",
}

MC.Enchantments = MC.Enchantments or {}
MC.EnchantmentOrder = {}
for _, row in ipairs( ENCHANTMENT_ROWS ) do
	local id = "minecraft:" .. row[1]
	MC.EnchantmentOrder[#MC.EnchantmentOrder + 1] = id
	MC.Enchantments[id] = {
		id = id,
		supportedTag = "minecraft:enchantable/" .. row[2],
		maxLevel = row[3],
		anvilCost = row[4],
	}
end
MC.EnchantmentTooltipOrder = {}
for _, path in ipairs( ENCHANTMENT_TOOLTIP_ORDER ) do
	MC.EnchantmentTooltipOrder[#MC.EnchantmentTooltipOrder + 1] = "minecraft:" .. path
end

-- Java 26.2 enchantment/exclusive_set tags are not all equivalence classes.
-- In particular, loyalty and channeling are compatible with each other while
-- riptide conflicts with both, so a single string on each enchantment cannot
-- represent the registry data faithfully. Keep the exact symmetric pairs.
local INCOMPATIBLE_ENCHANTMENTS = {}
local function addExclusiveGroup( ids )
	for leftIndex = 1, #ids do
		local left = "minecraft:" .. ids[leftIndex]
		INCOMPATIBLE_ENCHANTMENTS[left] = INCOMPATIBLE_ENCHANTMENTS[left] or {}
		for rightIndex = leftIndex + 1, #ids do
			local right = "minecraft:" .. ids[rightIndex]
			INCOMPATIBLE_ENCHANTMENTS[right] = INCOMPATIBLE_ENCHANTMENTS[right] or {}
			INCOMPATIBLE_ENCHANTMENTS[left][right] = true
			INCOMPATIBLE_ENCHANTMENTS[right][left] = true
		end
	end
end

addExclusiveGroup( { "protection", "fire_protection", "blast_protection", "projectile_protection" } )
addExclusiveGroup( { "depth_strider", "frost_walker" } )
addExclusiveGroup( { "infinity", "mending" } )
addExclusiveGroup( { "multishot", "piercing" } )
addExclusiveGroup( { "sharpness", "smite", "bane_of_arthropods", "impaling", "density", "breach" } )
addExclusiveGroup( { "fortune", "silk_touch" } )
addExclusiveGroup( { "riptide", "loyalty" } )
addExclusiveGroup( { "riptide", "channeling" } )

-- Java 26.2 data/minecraft/tags/item/enchantable/*.json. These tags are not
-- in the generated crafting payload, so keep this small relationship graph
-- here and delegate ordinary item tags to MC.ItemInTag.
local ENCHANTABLE_TAGS = {
	armor = { "#minecraft:enchantable/foot_armor", "#minecraft:enchantable/leg_armor", "#minecraft:enchantable/chest_armor", "#minecraft:enchantable/head_armor" },
	bow = { "minecraft:bow" },
	chest_armor = { "#minecraft:chest_armor" },
	crossbow = { "minecraft:crossbow" },
	durability = { "#minecraft:foot_armor", "#minecraft:leg_armor", "#minecraft:chest_armor", "#minecraft:head_armor", "minecraft:elytra", "minecraft:shield", "#minecraft:swords", "#minecraft:axes", "#minecraft:pickaxes", "#minecraft:shovels", "#minecraft:hoes", "minecraft:bow", "minecraft:crossbow", "minecraft:trident", "minecraft:flint_and_steel", "minecraft:shears", "minecraft:brush", "minecraft:fishing_rod", "minecraft:carrot_on_a_stick", "minecraft:warped_fungus_on_a_stick", "minecraft:mace", "#minecraft:spears" },
	equippable = { "#minecraft:foot_armor", "#minecraft:leg_armor", "#minecraft:chest_armor", "#minecraft:head_armor", "minecraft:elytra", "#minecraft:skulls", "minecraft:carved_pumpkin" },
	fire_aspect = { "#minecraft:enchantable/melee_weapon", "minecraft:mace" },
	fishing = { "minecraft:fishing_rod" },
	foot_armor = { "#minecraft:foot_armor" },
	head_armor = { "#minecraft:head_armor" },
	leg_armor = { "#minecraft:leg_armor" },
	lunge = { "#minecraft:spears" },
	mace = { "minecraft:mace" },
	melee_weapon = { "#minecraft:swords", "#minecraft:spears" },
	mining = { "#minecraft:axes", "#minecraft:pickaxes", "#minecraft:shovels", "#minecraft:hoes", "minecraft:shears" },
	mining_loot = { "#minecraft:axes", "#minecraft:pickaxes", "#minecraft:shovels", "#minecraft:hoes" },
	sharp_weapon = { "#minecraft:enchantable/melee_weapon", "#minecraft:axes" },
	sweeping = { "#minecraft:swords" },
	trident = { "minecraft:trident" },
	vanishing = { "#minecraft:enchantable/durability", "minecraft:compass", "minecraft:carved_pumpkin", "#minecraft:skulls" },
	weapon = { "#minecraft:enchantable/sharp_weapon", "minecraft:mace" },
}

local function component( stack, key )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil, false end
	if components[key] ~= nil then return components[key], true end
	local namespaced = string.find( key, ":", 1, true ) and key or "minecraft:" .. key
	if components[namespaced] ~= nil then return components[namespaced], true end
	return nil, false
end

local function withComponent( stack, key, value )
	local output = MC.CopyItemStack( stack )
	if not output then return nil end
	output.components = output.components or {}
	local short = string.match( key, "^[^:]+:(.+)$" ) or key
	local namespaced = string.find( key, ":", 1, true ) and key or "minecraft:" .. key
	output.components[short] = nil
	output.components[namespaced] = value
	if next( output.components ) == nil then output.components = nil end
	return output
end

local function levelsFromComponent( value )
	local source = type( value ) == "table" and type( value.levels ) == "table" and value.levels or value
	local levels = {}
	if type( source ) ~= "table" then return levels end
	for key, entry in pairs( source ) do
		local enchantmentId, level
		if type( key ) == "string" then
			enchantmentId = identifier( key )
			level = type( entry ) == "table" and tonumber( entry.level or entry.lvl ) or tonumber( entry )
		elseif type( entry ) == "table" then
			enchantmentId = identifier( entry.id or entry.enchantment )
			level = tonumber( entry.level or entry.lvl or entry[2] )
		end
		if enchantmentId and level and level > 0 then levels[enchantmentId] = math.floor( level ) end
	end
	return levels
end

function MC.GetItemEnchantments( stack, stored )
	if MC.IsEmptyItemStack( stack ) then return {}, false end
	if stored == nil then stored = stack.item == "minecraft:enchanted_book" end
	local value, present = component( stack, stored and "stored_enchantments" or "enchantments" )
	return levelsFromComponent( value ), present
end

function MC.GetEnchantmentLevel( stack, enchantmentId )
	enchantmentId = identifier( enchantmentId )
	if not enchantmentId then return 0 end
	local levels = MC.GetItemEnchantments( stack, false )
	local level = tonumber( levels[enchantmentId] ) or 0
	if level > 0 then return math.floor( level ) end
	levels = MC.GetItemEnchantments( stack, true )
	return math.max( 0, math.floor( tonumber( levels[enchantmentId] ) or 0 ) )
end

function MC.SetItemEnchantments( stack, levels, stored )
	if MC.IsEmptyItemStack( stack ) then return nil, "empty_stack" end
	if stored == nil then stored = stack.item == "minecraft:enchanted_book" end
	local componentKey = stored and "minecraft:stored_enchantments" or "minecraft:enchantments"
	local previous = select( 1, component( stack, componentKey ) )
	local showInTooltip = true
	if type( previous ) == "table" then
		if previous.show_in_tooltip ~= nil then
			showInTooltip = previous.show_in_tooltip == true
		elseif previous.showInTooltip ~= nil then
			showInTooltip = previous.showInTooltip == true
		end
	end
	local normalized = {}
	for rawId, rawLevel in pairs( type( levels ) == "table" and levels or {} ) do
		local enchantmentId = identifier( rawId )
		local level = math.floor( tonumber( rawLevel ) or 0 )
		if enchantmentId and level > 0 then normalized[enchantmentId] = level end
	end
	local value = next( normalized ) and { levels = normalized, show_in_tooltip = showInTooltip } or nil
	return withComponent( stack, componentKey, value )
end

function MC.AnvilEnchantmentsCompatible( leftId, rightId )
	leftId, rightId = identifier( leftId ), identifier( rightId )
	if not leftId or not rightId or leftId == rightId then return true end
	local left, right = MC.Enchantments[leftId], MC.Enchantments[rightId]
	if not left or not right then return false end
	return not ( INCOMPATIBLE_ENCHANTMENTS[leftId] and INCOMPATIBLE_ENCHANTMENTS[leftId][rightId] )
end

local function matchesEnchantableValue( item, value, resolving )
	value = tostring( value or "" )
	if string.sub( value, 1, 1 ) ~= "#" then return identifier( item ) == identifier( value ) end
	local tag = identifier( string.sub( value, 2 ) )
	local enchantable = tag and string.match( tag, "^minecraft:enchantable/(.+)$" ) or nil
	if not enchantable then return MC.ItemInTag and MC.ItemInTag( item, tag ) == true or false end
	if resolving[enchantable] then return false end
	resolving[enchantable] = true
	for _, nested in ipairs( ENCHANTABLE_TAGS[enchantable] or {} ) do
		if matchesEnchantableValue( item, nested, resolving ) then resolving[enchantable] = nil return true end
	end
	resolving[enchantable] = nil
	return false
end

function MC.AnvilEnchantmentSupportsItem( enchantmentId, stackOrItem )
	local definition = MC.Enchantments[identifier( enchantmentId )]
	local item = type( stackOrItem ) == "table" and stackOrItem.item or stackOrItem
	return definition ~= nil and item ~= nil
		and matchesEnchantableValue( item, "#" .. definition.supportedTag, {} ) or false
end

local TOOL_TAGS = { "minecraft:swords", "minecraft:axes", "minecraft:pickaxes", "minecraft:shovels", "minecraft:hoes", "minecraft:spears" }
local DURABLE_WITHOUT_REPAIRABLE = {
	["minecraft:bow"] = true,
	["minecraft:crossbow"] = true,
	["minecraft:fishing_rod"] = true,
	["minecraft:trident"] = true,
	["minecraft:shears"] = true,
	["minecraft:brush"] = true,
	["minecraft:flint_and_steel"] = true,
}
local TOOL_MATERIALS = {
	{ prefix = "wooden_", tag = "minecraft:wooden_tool_materials" },
	{ prefix = "stone_", tag = "minecraft:stone_tool_materials" },
	{ prefix = "copper_", tag = "minecraft:copper_tool_materials" },
	{ prefix = "iron_", tag = "minecraft:iron_tool_materials" },
	{ prefix = "diamond_", tag = "minecraft:diamond_tool_materials" },
	{ prefix = "golden_", tag = "minecraft:gold_tool_materials" },
	{ prefix = "netherite_", tag = "minecraft:netherite_tool_materials" },
}
local ARMOR_MATERIALS = {
	{ prefix = "leather_", tag = "minecraft:repairs_leather_armor" },
	{ prefix = "copper_", tag = "minecraft:repairs_copper_armor" },
	{ prefix = "chainmail_", tag = "minecraft:repairs_chain_armor" },
	{ prefix = "iron_", tag = "minecraft:repairs_iron_armor" },
	{ prefix = "golden_", tag = "minecraft:repairs_gold_armor" },
	{ prefix = "diamond_", tag = "minecraft:repairs_diamond_armor" },
	{ prefix = "netherite_", tag = "minecraft:repairs_netherite_armor" },
}

local function itemPath( item ) return string.match( identifier( item ) or "", "^[^:]+:(.+)$" ) or "" end
local function inAnyTag( item, tags )
	for _, tag in ipairs( tags ) do if MC.ItemInTag and MC.ItemInTag( item, tag ) then return true end end
	return false
end

function MC.AnvilIsRepairMaterial( stack, material )
	if MC.IsEmptyItemStack( stack ) or MC.IsEmptyItemStack( material ) or MC.ItemStackMaxDamage( stack ) <= 0 then return false end
	local item, path = stack.item, itemPath( stack.item )
	-- These Java 26.2 items have durability but no REPAIRABLE component. They
	-- can still use the same-item combination branch below, never a raw material.
	if DURABLE_WITHOUT_REPAIRABLE[item] then return false end
	if item == "minecraft:elytra" then return material.item == "minecraft:phantom_membrane" end
	if item == "minecraft:mace" then return material.item == "minecraft:breeze_rod" end
	if item == "minecraft:shield" then return MC.ItemInTag and MC.ItemInTag( material, "minecraft:wooden_tool_materials" ) == true end
	if item == "minecraft:turtle_helmet" then return MC.ItemInTag and MC.ItemInTag( material, "minecraft:repairs_turtle_helmet" ) == true end
	if item == "minecraft:wolf_armor" then return MC.ItemInTag and MC.ItemInTag( material, "minecraft:repairs_wolf_armor" ) == true end
	if inAnyTag( item, TOOL_TAGS ) then
		for _, row in ipairs( TOOL_MATERIALS ) do
			if string.sub( path, 1, #row.prefix ) == row.prefix then
				return MC.ItemInTag and MC.ItemInTag( material, row.tag ) == true or false
			end
		end
	end
	if inAnyTag( item, { "minecraft:head_armor", "minecraft:chest_armor", "minecraft:leg_armor", "minecraft:foot_armor" } ) then
		for _, row in ipairs( ARMOR_MATERIALS ) do
			if string.sub( path, 1, #row.prefix ) == row.prefix then
				return MC.ItemInTag and MC.ItemInTag( material, row.tag ) == true or false
			end
		end
	end
	return false
end

function MC.AnvilCalculateIncreasedRepairCost( cost )
	cost = math.max( 0, math.floor( tonumber( cost ) or 0 ) )
	return math.min( cost * 2 + 1, INT_MAX )
end

local function repairCost( stack )
	local value = select( 1, component( stack, "repair_cost" ) )
	return math.Clamp( math.floor( tonumber( value ) or 0 ), 0, INT_MAX )
end

function MC.GetItemCustomName( stack )
	local value, present = component( stack, "custom_name" )
	if not present then return nil, false end
	if type( value ) == "string" then return value, true end
	if type( value ) == "table" then
		local text = value.text or value.literal or value.string or value.value
		if text ~= nil then return tostring( text ), true end
	end
	return tostring( value or "" ), true
end

function MC.AnvilStackDisplayName( stack )
	if MC.IsEmptyItemStack( stack ) then return "" end
	local name, present = MC.GetItemCustomName( stack )
	if present then return name end
	return MC.ItemDisplayName and MC.ItemDisplayName( stack.item ) or itemPath( stack.item )
end

local function nextUTF8Codepoint( value, offset )
	local first = string.byte( value, offset )
	if not first then return nil, offset end
	if first < 0x80 then return first, offset + 1 end
	local length = first < 0xE0 and 2 or first < 0xF0 and 3 or first < 0xF8 and 4 or 1
	local codepoint = first % ( 2 ^ ( 8 - length - 1 ) )
	for index = 2, length do
		local byte = string.byte( value, offset + index - 1 )
		if not byte or byte < 0x80 or byte >= 0xC0 then return first, offset + 1 end
		codepoint = codepoint * 0x40 + byte - 0x80
	end
	return codepoint, offset + length
end

local function filterAnvilName( value )
	value = tostring( value or "" )
	local filtered, utf16Length, offset = {}, 0, 1
	while offset <= #value do
		local start = offset
		local codepoint
		codepoint, offset = nextUTF8Codepoint( value, offset )
		if codepoint ~= 0x00A7 and codepoint >= 32 and codepoint ~= 127 then
			filtered[#filtered + 1] = string.sub( value, start, offset - 1 )
			utf16Length = utf16Length + ( codepoint > 0xFFFF and 2 or 1 )
		end
	end
	return table.concat( filtered ), utf16Length
end

local function anvilNameIsBlank( value )
	if value == "" then return true end
	local offset = 1
	while offset <= #value do
		local codepoint
		codepoint, offset = nextUTF8Codepoint( value, offset )
		local blank = codepoint == 0x20 or codepoint == 0x85 or codepoint == 0xA0 or codepoint == 0x1680
			or codepoint >= 0x2000 and codepoint <= 0x200A
			or codepoint == 0x2028 or codepoint == 0x2029 or codepoint == 0x202F
			or codepoint == 0x205F or codepoint == 0x3000
		if not blank then return false end
	end
	return true
end

function MC.AnvilValidateName( value )
	local filtered, length = filterAnvilName( value )
	if length > 50 then return nil, "name_too_long" end
	return filtered
end

function MC.AnvilFilterName( value )
	return MC.AnvilValidateName( value )
end

local function setRepairCost( stack, cost )
	cost = math.Clamp( math.floor( tonumber( cost ) or 0 ), 0, INT_MAX )
	return withComponent( stack, "minecraft:repair_cost", cost > 0 and cost or nil )
end

local function invalidResult( info, code )
	info.error = code
	info.resultAvailable = false
	return nil, info
end

function MC.AnvilCreateResult( left, right, requestedName, options )
	options = type( options ) == "table" and options or {}
	local info = {
		cost = 0,
		operationCost = 0,
		baseCost = repairCost( left ) + repairCost( right ),
		materialCost = 0,
		renameCost = 0,
		onlyRenaming = false,
		tooExpensive = false,
		acceptedEnchantments = 0,
		rejectedEnchantments = 0,
		resultAvailable = false,
	}
	if MC.IsEmptyItemStack( left ) then return invalidResult( info, "left_input_missing" ) end

	local output = MC.CopyItemStack( left )
	local outputLevels = MC.GetItemEnchantments( output, output.item == "minecraft:enchanted_book" )
	local operationCost = 0
	local rightPresent = not MC.IsEmptyItemStack( right )
	local rightStoredLevels, rightHasStored = MC.GetItemEnchantments( right, true )

	if rightPresent then
		local maxDamage = MC.ItemStackMaxDamage( output )
		if maxDamage > 0 and MC.AnvilIsRepairMaterial( left, right ) then
			local repair = math.min( math.floor( tonumber( output.damage ) or 0 ), math.floor( maxDamage / 4 ) )
			if repair <= 0 then return invalidResult( info, "repair_not_needed" ) end
			local used = 0
			while repair > 0 and used < right.count do
				output.damage = math.max( 0, math.floor( tonumber( output.damage ) or 0 ) - repair )
				if output.damage <= 0 then output.damage = nil end
				operationCost = operationCost + 1
				used = used + 1
				repair = math.min( math.floor( tonumber( output.damage ) or 0 ), math.floor( maxDamage / 4 ) )
			end
			info.materialCost = used
		else
			if not rightHasStored and ( left.item ~= right.item or maxDamage <= 0 ) then
				return invalidResult( info, "incompatible_inputs" )
			end
			if maxDamage > 0 and not rightHasStored then
				local leftRemaining = maxDamage - math.floor( tonumber( left.damage ) or 0 )
				local rightRemaining = maxDamage - math.floor( tonumber( right.damage ) or 0 )
				local combined = leftRemaining + rightRemaining + math.floor( maxDamage * 12 / 100 )
				local nextDamage = math.max( 0, maxDamage - combined )
				if nextDamage < math.floor( tonumber( output.damage ) or 0 ) then
					output.damage = nextDamage > 0 and nextDamage or nil
					operationCost = operationCost + 2
				end
			end

			local incoming = rightHasStored and rightStoredLevels or MC.GetItemEnchantments( right, false )
			local accepted, rejected = false, false
			for _, enchantmentId in ipairs( MC.EnchantmentOrder ) do
				local rightLevel = math.floor( tonumber( incoming[enchantmentId] ) or 0 )
				if rightLevel > 0 then
					local definition = MC.Enchantments[enchantmentId]
					local leftLevel = math.floor( tonumber( outputLevels[enchantmentId] ) or 0 )
					local nextLevel = leftLevel == rightLevel and rightLevel + 1 or math.max( leftLevel, rightLevel )
					local supported = options.creative == true or left.item == "minecraft:enchanted_book"
						or MC.AnvilEnchantmentSupportsItem( enchantmentId, left )
					for existingId, existingLevel in pairs( outputLevels ) do
						if existingId ~= enchantmentId and tonumber( existingLevel ) and existingLevel > 0
						and not MC.AnvilEnchantmentsCompatible( enchantmentId, existingId ) then
							supported = false
							operationCost = operationCost + 1
						end
					end
					if not supported then
						rejected = true
						info.rejectedEnchantments = info.rejectedEnchantments + 1
					else
						accepted = true
						info.acceptedEnchantments = info.acceptedEnchantments + 1
						nextLevel = math.min( nextLevel, definition.maxLevel )
						outputLevels[enchantmentId] = nextLevel
						local cost = definition.anvilCost
						if rightHasStored then cost = math.max( 1, math.floor( cost / 2 ) ) end
						operationCost = operationCost + cost * nextLevel
						if left.count > 1 then operationCost = 40 end
					end
				end
			end
			if rejected and not accepted then return invalidResult( info, "all_enchantments_incompatible" ) end
		end
	end

	local renameExplicit = options.renameExplicit
	if renameExplicit == nil then renameExplicit = requestedName ~= nil end
	local filteredName, nameError = MC.AnvilValidateName( requestedName )
	if not filteredName then return invalidResult( info, nameError or "invalid_name" ) end
	local existingCustom, hasCustom = MC.GetItemCustomName( left )
	local hoverName = MC.AnvilStackDisplayName( left )
	if renameExplicit then
		if anvilNameIsBlank( filteredName ) then
			if hasCustom then
				info.renameCost = 1
				operationCost = operationCost + 1
				output = withComponent( output, "minecraft:custom_name", nil )
			end
		elseif filteredName ~= hoverName then
			info.renameCost = 1
			operationCost = operationCost + 1
			output = withComponent( output, "minecraft:custom_name", filteredName )
		elseif hasCustom and filteredName == existingCustom then
			-- Leaving the pre-filled custom name untouched is not a rename.
		end
	end

	info.operationCost = operationCost
	if operationCost <= 0 then return invalidResult( info, "no_operation" ) end
	info.cost = math.min( info.baseCost + operationCost, INT_MAX )
	info.onlyRenaming = info.renameCost > 0 and info.renameCost == operationCost
	if info.onlyRenaming and info.cost >= 40 then info.cost = 39 end
	info.tooExpensive = info.cost >= 40
	if info.tooExpensive and options.creative ~= true then return invalidResult( info, "too_expensive" ) end

	local prior = math.max( repairCost( left ), repairCost( right ) )
	if not info.onlyRenaming then prior = MC.AnvilCalculateIncreasedRepairCost( prior ) end
	output = setRepairCost( output, prior )
	output = MC.SetItemEnchantments( output, outputLevels, output.item == "minecraft:enchanted_book" )
	info.resultAvailable = output ~= nil
	return output, info
end
