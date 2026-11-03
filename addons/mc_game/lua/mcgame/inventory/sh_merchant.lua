--[[----------------------------------------------------------------------------
	Shared Minecraft Java 26.2 merchant rules.

	The game layer accepts an external merchant snapshot through a deliberately
	small entity contract.  It normalizes that snapshot into ordinary MineMod
	ItemStacks, evaluates the data-driven trade result modifiers once from the
	offer seed, and exposes the pure matching/price helpers used by both realms.

	Authoritative sources:
	- MerchantOffer#getModifiedCostCount/satisfiedBy
	- MerchantContainer#updateSellItem
	- VillagerTrade#getOffer
	- EnchantRandomlyFunction / EnchantWithLevelsFunction
	- SetRandomDyesFunction / DyedItemColor#applyDyes
	- SetRandomPotionFunction / SetStewEffectFunction
	- data/minecraft/tags/{enchantment,potion}/*.json (26.2)
------------------------------------------------------------------------------]]

MC = MC or {}

local MAX_OFFERS = 64
local MAX_IDENTIFIER_BYTES = 192
local INT_MAX = 2147483647

local NON_TREASURE_ENCHANTMENTS = {
	"minecraft:protection", "minecraft:fire_protection", "minecraft:feather_falling",
	"minecraft:blast_protection", "minecraft:projectile_protection", "minecraft:respiration",
	"minecraft:aqua_affinity", "minecraft:thorns", "minecraft:depth_strider",
	"minecraft:sharpness", "minecraft:smite", "minecraft:bane_of_arthropods",
	"minecraft:knockback", "minecraft:fire_aspect", "minecraft:looting",
	"minecraft:sweeping_edge", "minecraft:efficiency", "minecraft:silk_touch",
	"minecraft:unbreaking", "minecraft:fortune", "minecraft:power", "minecraft:punch",
	"minecraft:flame", "minecraft:infinity", "minecraft:luck_of_the_sea", "minecraft:lure",
	"minecraft:loyalty", "minecraft:impaling", "minecraft:riptide", "minecraft:channeling",
	"minecraft:multishot", "minecraft:quick_charge", "minecraft:piercing",
	"minecraft:density", "minecraft:breach", "minecraft:lunge",
}

local TRADEABLE_ENCHANTMENTS = {}
for _, id in ipairs( NON_TREASURE_ENCHANTMENTS ) do TRADEABLE_ENCHANTMENTS[#TRADEABLE_ENCHANTMENTS + 1] = id end
for _, id in ipairs( {
	"minecraft:binding_curse", "minecraft:vanishing_curse",
	"minecraft:frost_walker", "minecraft:mending",
} ) do TRADEABLE_ENCHANTMENTS[#TRADEABLE_ENCHANTMENTS + 1] = id end

local TREASURE_ENCHANTMENTS = {
	["minecraft:binding_curse"] = true,
	["minecraft:vanishing_curse"] = true,
	["minecraft:swift_sneak"] = true,
	["minecraft:soul_speed"] = true,
	["minecraft:frost_walker"] = true,
	["minecraft:mending"] = true,
	["minecraft:wind_burst"] = true,
}

local TRADEABLE_POTIONS = {
	"minecraft:wind_charged", "minecraft:oozing", "minecraft:infested", "minecraft:weaving",
	"minecraft:night_vision", "minecraft:long_night_vision",
	"minecraft:invisibility", "minecraft:long_invisibility",
	"minecraft:fire_resistance", "minecraft:long_fire_resistance",
	"minecraft:leaping", "minecraft:long_leaping", "minecraft:strong_leaping",
	"minecraft:slowness", "minecraft:long_slowness", "minecraft:strong_slowness",
	"minecraft:turtle_master", "minecraft:long_turtle_master", "minecraft:strong_turtle_master",
	"minecraft:swiftness", "minecraft:long_swiftness", "minecraft:strong_swiftness",
	"minecraft:water_breathing", "minecraft:long_water_breathing",
	"minecraft:healing", "minecraft:strong_healing",
	"minecraft:harming", "minecraft:strong_harming",
	"minecraft:poison", "minecraft:long_poison", "minecraft:strong_poison",
	"minecraft:regeneration", "minecraft:long_regeneration", "minecraft:strong_regeneration",
	"minecraft:strength", "minecraft:long_strength", "minecraft:strong_strength",
	"minecraft:weakness", "minecraft:long_weakness",
	"minecraft:slow_falling", "minecraft:long_slow_falling",
}

-- DyeColor#getTextureDiffuseColor, read from DyeColor.<clinit> in Java 26.2.
local DYE_COLORS = {
	16383998, 16351261, 13061821, 3847130,
	16701501, 8439583, 15961002, 4673362,
	10329495, 1481884, 8991416, 3949738,
	8606770, 6192150, 11546150, 1908001,
}

local INSTANT_STEW_EFFECTS = {
	["minecraft:saturation"] = true,
	["minecraft:instant_health"] = true,
	["minecraft:instant_damage"] = true,
}

local function integer( value, fallback, minimum, maximum )
	value = math.floor( tonumber( value ) or tonumber( fallback ) or 0 )
	if minimum ~= nil then value = math.max( minimum, value ) end
	if maximum ~= nil then value = math.min( maximum, value ) end
	return value
end

local function identifier( value )
	value = string.lower( tostring( value or "" ) )
	if value == "" or #value > MAX_IDENTIFIER_BYTES then return nil end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	if not string.match( value, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return value
end

local function copyPlain( value )
	if type( value ) ~= "table" then return value end
	local copied = MC.CopyItemComponents and MC.CopyItemComponents( value ) or nil
	if copied ~= nil then return copied end
	local output = {}
	for key, child in pairs( value ) do output[key] = copyPlain( child ) end
	return output
end

local function component( stack, name )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil, false end
	local namespaced = string.find( name, ":", 1, true ) and name or "minecraft:" .. name
	local short = string.match( namespaced, "^[^:]+:(.+)$" ) or namespaced
	if components[namespaced] ~= nil then return components[namespaced], true end
	if components[short] ~= nil then return components[short], true end
	return nil, false
end

local function withComponent( stack, name, value )
	local output = MC.CopyItemStack and MC.CopyItemStack( stack ) or nil
	if not output then return nil, "item_stack_copy_failed" end
	output.components = output.components or {}
	local namespaced = string.find( name, ":", 1, true ) and name or "minecraft:" .. name
	local short = string.match( namespaced, "^[^:]+:(.+)$" ) or namespaced
	output.components[short] = nil
	output.components[namespaced] = copyPlain( value )
	if next( output.components ) == nil then output.components = nil end
	return MC.NormalizeItemStack and MC.NormalizeItemStack( output ) or output
end

local function normalizedStack( source, countOverride )
	if type( source ) ~= "table" then return nil, "invalid_item_spec" end
	local item = identifier( source.item or source.id or source.name )
	if not item then return nil, "invalid_item_id" end
	local count = countOverride ~= nil and countOverride or source.count
	count = integer( count, 1, 0, INT_MAX )
	if count <= 0 then return nil, "empty_item_count" end
	return MC.NewItemStack( item, count, source.components, source.damage )
end

local function randomFromSeed( seed )
	if type( MC.NewLegacyRandom ) ~= "function" then return nil, "legacy_random_unavailable" end
	return MC.NewLegacyRandom( integer( seed, 0, -2147483648, 2147483647 ) )
end

local function uniformInt( random, source, fallbackMinimum, fallbackMaximum )
	if type( source ) == "number" then return integer( source, fallbackMinimum ) end
	if type( source ) ~= "table" then return integer( fallbackMinimum, 0 ) end
	local minimum = integer( source.min, fallbackMinimum or 0 )
	local maximum = integer( source.max, fallbackMaximum or minimum )
	if maximum < minimum then minimum, maximum = maximum, minimum end
	return minimum + random:NextInt( maximum - minimum + 1 )
end

local function enchantmentLevels( stack, stored )
	if type( MC.GetItemEnchantments ) ~= "function" then return {} end
	return MC.GetItemEnchantments( stack, stored ) or {}
end

local function applyEnchantRandomly( stack, modifier, random )
	local options = modifier.options == "#minecraft:tradeable" and TRADEABLE_ENCHANTMENTS
		or modifier.options == "#minecraft:on_traded_equipment" and NON_TREASURE_ENCHANTMENTS or nil
	if not options or #options == 0 then return nil, 0, "unsupported_enchantment_options" end
	local candidates = {}
	for _, enchantmentId in ipairs( options ) do
		if modifier.only_compatible ~= true
		or type( MC.AnvilEnchantmentSupportsItem ) ~= "function"
		or MC.AnvilEnchantmentSupportsItem( enchantmentId, stack ) then
			candidates[#candidates + 1] = enchantmentId
		end
	end
	if #candidates == 0 then return stack, 0 end
	local enchantmentId = candidates[random:NextInt( #candidates ) + 1]
	local definition = MC.Enchantments and MC.Enchantments[enchantmentId] or nil
	if not definition then return nil, 0, "unknown_enchantment" end
	local level = 1 + random:NextInt( math.max( 1, integer( definition.maxLevel, 1, 1 ) ) )
	local levels = enchantmentLevels( stack, stack.item == "minecraft:enchanted_book" )
	levels[enchantmentId] = level
	local output, err = MC.SetItemEnchantments( stack, levels, stack.item == "minecraft:enchanted_book" )
	if not output then return nil, 0, err or "enchantment_apply_failed" end
	local additional = 0
	if modifier.include_additional_cost_component == true then
		additional = 2 + random:NextInt( 5 + level * 10 ) + 3 * level
	end
	return output, additional
end

local function applyEnchantWithLevels( stack, modifier, random )
	if modifier.options ~= "#minecraft:on_traded_equipment" then
		return nil, 0, "unsupported_enchantment_options"
	end
	if type( MC.EnchantingSelectEnchantments ) ~= "function" then
		return nil, 0, "enchanting_rules_unavailable"
	end
	local level = uniformInt( random, modifier.levels, 1, 1 )
	local selected, err = MC.EnchantingSelectEnchantments( random, stack, level )
	if err then return nil, 0, err end
	if type( selected ) ~= "table" or #selected == 0 then return stack, 0 end
	local output, applyError = MC.EnchantingApplyResult( stack, selected )
	if not output then return nil, 0, applyError or "enchantment_apply_failed" end
	return output, modifier.include_additional_cost_component == true and math.max( 0, level ) or 0
end

local function rgbChannels( rgb )
	rgb = integer( rgb, 0, 0, 16777215 )
	return math.floor( rgb / 65536 ) % 256, math.floor( rgb / 256 ) % 256, rgb % 256
end

local function blendDyes( previous, dyes )
	local red, green, blue, brightness, count = 0, 0, 0, 0, 0
	local function addColor( rgb )
		local r, g, b = rgbChannels( rgb )
		red, green, blue = red + r, green + g, blue + b
		brightness = brightness + math.max( r, g, b )
		count = count + 1
	end
	if previous ~= nil then
		if type( previous ) == "table" then previous = previous.rgb or previous.value end
		if tonumber( previous ) then addColor( previous ) end
	end
	for _, rgb in ipairs( dyes ) do addColor( rgb ) end
	if count <= 0 then return nil end
	local r = math.floor( red / count )
	local g = math.floor( green / count )
	local b = math.floor( blue / count )
	local averageBrightness = brightness / count
	local maximum = math.max( r, g, b )
	if maximum <= 0 then return 0 end
	r = math.floor( r * averageBrightness / maximum )
	g = math.floor( g * averageBrightness / maximum )
	b = math.floor( b * averageBrightness / maximum )
	return r * 65536 + g * 256 + b
end

local function applyRandomDyes( stack, modifier, random )
	local provider = modifier.number_of_dyes
	local count = 0
	if type( provider ) == "table" and provider.type == "minecraft:sum" then
		for _, summand in ipairs( provider.summands or {} ) do
			if type( summand ) == "number" then
				count = count + integer( summand, 0 )
			elseif type( summand ) == "table" and summand.type == "minecraft:binomial" then
				local n = integer( summand.n, 0, 0 )
				local probability = math.max( 0, math.min( 1, tonumber( summand.p ) or 0 ) )
				for _ = 1, n do if random:NextFloat() < probability then count = count + 1 end end
			else
				return nil, "unsupported_dye_count_provider"
			end
		end
	else
		return nil, "unsupported_dye_count_provider"
	end
	if count <= 0 then return stack end
	local dyes = {}
	for index = 1, count do dyes[index] = DYE_COLORS[random:NextInt( #DYE_COLORS ) + 1] end
	local previous = select( 1, component( stack, "dyed_color" ) )
	local rgb = blendDyes( previous, dyes )
	if rgb == nil then return nil, "dye_blend_failed" end
	return withComponent( stack, "minecraft:dyed_color", rgb )
end

local function applyPotion( stack, potionId )
	potionId = identifier( potionId )
	if not potionId then return nil, "invalid_potion_id" end
	local contents = select( 1, component( stack, "potion_contents" ) )
	contents = type( contents ) == "table" and copyPlain( contents ) or {}
	contents.potion = potionId
	return withComponent( stack, "minecraft:potion_contents", contents )
end

local function applyStewEffect( stack, modifier, random )
	if stack.item ~= "minecraft:suspicious_stew" then return stack end
	local effects = modifier.effects
	if type( effects ) ~= "table" or #effects == 0 then return stack end
	local chosen = effects[random:NextInt( #effects ) + 1]
	local effectId = identifier( chosen and ( chosen.type or chosen.id ) )
	if not effectId then return nil, "invalid_stew_effect" end
	local duration = integer( chosen.duration, 0, 0 )
	if not INSTANT_STEW_EFFECTS[effectId] then duration = duration * 20 end
	local entries = select( 1, component( stack, "suspicious_stew_effects" ) )
	entries = type( entries ) == "table" and copyPlain( entries ) or {}
	entries[#entries + 1] = { id = effectId, duration = duration }
	return withComponent( stack, "minecraft:suspicious_stew_effects", entries )
end

local function predicateComponentPresent( stack, predicateName )
	local value, present = component( stack, predicateName )
	if not present then return false end
	if predicateName == "minecraft:enchantments" or predicateName == "minecraft:stored_enchantments" then
		local levels = type( value ) == "table" and ( value.levels or value ) or nil
		return type( levels ) == "table" and next( levels ) ~= nil
	end
	return true
end

local function filteredItemPasses( stack, modifier )
	local filter = modifier.item_filter
	if type( filter ) ~= "table" then return false end
	local expected = identifier( filter.items )
	if not expected or stack.item ~= expected then return false end
	for predicateName in pairs( type( filter.predicates ) == "table" and filter.predicates or {} ) do
		if not predicateComponentPresent( stack, predicateName ) then return false end
	end
	return true
end

function MC.MerchantApplyModifiers( resultSpec, modifiers, seed )
	local stack, stackError = normalizedStack( resultSpec )
	if not stack then return nil, 0, stackError or "invalid_trade_result" end
	local random, randomError = randomFromSeed( seed )
	if not random then return nil, 0, randomError end
	local additionalCost = 0
	for _, modifier in ipairs( type( modifiers ) == "table" and modifiers or {} ) do
		local functionId = identifier( modifier and modifier["function"] )
		if functionId == "minecraft:enchant_randomly" then
			local nextStack, cost, err = applyEnchantRandomly( stack, modifier, random )
			if not nextStack then return nil, 0, err end
			stack, additionalCost = nextStack, additionalCost + ( cost or 0 )
		elseif functionId == "minecraft:enchant_with_levels" then
			local nextStack, cost, err = applyEnchantWithLevels( stack, modifier, random )
			if not nextStack then return nil, 0, err end
			stack, additionalCost = nextStack, additionalCost + ( cost or 0 )
		elseif functionId == "minecraft:set_potion" then
			local nextStack, err = applyPotion( stack, modifier.id )
			if not nextStack then return nil, 0, err end
			stack = nextStack
		elseif functionId == "minecraft:set_random_potion" then
			if modifier.options ~= "#minecraft:tradeable" then return nil, 0, "unsupported_potion_options" end
			local nextStack, err = applyPotion( stack, TRADEABLE_POTIONS[random:NextInt( #TRADEABLE_POTIONS ) + 1] )
			if not nextStack then return nil, 0, err end
			stack = nextStack
		elseif functionId == "minecraft:set_random_dyes" then
			local nextStack, err = applyRandomDyes( stack, modifier, random )
			if not nextStack then return nil, 0, err end
			stack = nextStack
		elseif functionId == "minecraft:set_stew_effect" then
			local nextStack, err = applyStewEffect( stack, modifier, random )
			if not nextStack then return nil, 0, err end
			stack = nextStack
		elseif functionId == "minecraft:set_name" then
			local nextStack, err = withComponent( stack,
				modifier.target == "item_name" and "minecraft:item_name" or "minecraft:custom_name",
				modifier.name )
			if not nextStack then return nil, 0, err end
			stack = nextStack
		elseif functionId == "minecraft:filtered" then
			if not filteredItemPasses( stack, modifier ) then return nil, 0, "modifier_filtered_out" end
		elseif functionId == "minecraft:exploration_map" then
			-- A real exploration map requires the Java structure-tag search and map
			-- saved-data allocation.  Never substitute an ordinary map.
			return nil, 0, "exploration_map_pending"
		else
			return nil, 0, "unsupported_trade_modifier"
		end
	end
	return stack, math.max( 0, integer( additionalCost, 0 ) )
end

local function containsTreasureStoredEnchantment( stack )
	local levels = enchantmentLevels( stack, true )
	for enchantmentId, level in pairs( levels ) do
		if ( tonumber( level ) or 0 ) > 0 and TREASURE_ENCHANTMENTS[enchantmentId] then return true end
	end
	return false
end

local function normalizedOffer( source, position )
	if type( source ) ~= "table" then return nil, "invalid_offer" end
	local result, additionalCost, modifierError = MC.MerchantApplyModifiers(
		source.gives, source.modifiers, source.modifierSeed )
	local unavailable = source.unavailable == true or not result
	local unavailableReason = source.unavailableReason or modifierError
	if source.doubleTradePriceEnchantments == "#minecraft:double_trade_price"
	and result and containsTreasureStoredEnchantment( result ) then
		additionalCost = additionalCost * 2
	end
	local baseCount = integer( source.wants and source.wants.count, 1, 0 ) + integer( additionalCost, 0, 0 )
	local baseCostA, costError
	if baseCount > 0 then baseCostA, costError = normalizedStack( source.wants, baseCount ) end
	if not baseCostA then
		unavailable = true
		unavailableReason = unavailableReason or costError or "invalid_primary_cost"
	end
	local costB
	if source.additionalWants then
		costB, costError = normalizedStack( source.additionalWants )
		if not costB then
			unavailable = true
			unavailableReason = unavailableReason or costError or "invalid_secondary_cost"
		end
	end
	local maxUses = integer( source.maxUses, 4, 1, 65535 )
	local uses = integer( source.uses, 0, 0, maxUses )
	local availableUses = integer( source.availableUses, maxUses - uses, 0, maxUses )
	local specialPriceDiff = integer( source.specialPriceDiff, 0, -INT_MAX, INT_MAX )
		+ integer( source.extensionSpecialPrice, 0, -INT_MAX, INT_MAX )
	local reputation = integer( source.reputation, 0, -INT_MAX, INT_MAX )
	local priceMultiplier = math.max( 0, tonumber( source.priceMultiplier ) or 0 )
	specialPriceDiff = specialPriceDiff - math.floor( reputation * priceMultiplier )
	if source.heroAmplifier ~= nil and baseCostA then
		local amplifier = integer( source.heroAmplifier, 0, 0, 255 )
		specialPriceDiff = specialPriceDiff - math.max( math.floor(
			( 0.3 + 0.0625 * amplifier ) * baseCostA.count ), 1 )
	end
	local offer = {
		index = integer( source.index, position, 1, MAX_OFFERS ),
		id = identifier( source.id ) or "minecraft:unknown",
		level = integer( source.level, 1, 1, 5 ),
		baseCostA = baseCostA,
		costB = costB,
		result = result,
		uses = uses,
		maxUses = maxUses,
		availableUses = availableUses,
		demand = integer( source.demand, 0, -INT_MAX, INT_MAX ),
		specialPriceDiff = specialPriceDiff,
		priceMultiplier = priceMultiplier,
		xp = integer( source.xp, 0, 0, 65535 ),
		unavailable = unavailable,
		unavailableReason = unavailableReason and tostring( unavailableReason ) or nil,
	}
	if offer.baseCostA then
		local demandIncrease = math.max( 0, math.floor(
			offer.baseCostA.count * offer.demand * offer.priceMultiplier ) )
		local maximum = MC.ItemStackMaxCount( offer.baseCostA )
		local modifiedCount = math.max( 1, math.min( maximum,
			offer.baseCostA.count + demandIncrease + offer.specialPriceDiff ) )
		offer.costA = MC.CopyItemStack( offer.baseCostA, modifiedCount )
	end
	offer.outOfStock = offer.unavailable or offer.uses >= offer.maxUses or offer.availableUses <= 0
	return offer
end

function MC.MerchantNormalizeSnapshot( snapshot )
	if type( snapshot ) ~= "table" or integer( snapshot.version, -1 ) ~= 1 then
		return nil, "invalid_merchant_snapshot"
	end
	local rawOffers = snapshot.offers
	if type( rawOffers ) ~= "table" or #rawOffers > MAX_OFFERS then return nil, "invalid_merchant_offers" end
	local output = {
		version = 1,
		entityIndex = integer( snapshot.entityIndex, 0, 0, 65535 ),
		entityClass = tostring( snapshot.entityClass or "" ),
		revision = integer( snapshot.revision, 0, 0, 4294967295 ),
		profession = tostring( snapshot.profession or "none" ),
		villagerType = tostring( snapshot.villagerType or "plains" ),
		level = integer( snapshot.level, 0, 0, 5 ),
		experience = integer( snapshot.experience, 0, 0, INT_MAX ),
		nextLevelExperience = integer( snapshot.nextLevelExperience, 0, 0, INT_MAX ),
		showProgressBar = snapshot.showProgressBar ~= false and integer( snapshot.level, 0 ) > 0,
		canRestock = snapshot.canRestock ~= false,
		offers = {},
	}
	for position, source in ipairs( rawOffers ) do
		local offer, err = normalizedOffer( source, position )
		if not offer then return nil, err or "offer_normalize_failed" end
		output.offers[position] = offer
	end
	return output
end

local function subsetEqual( expected, actual )
	if type( expected ) ~= "table" then return expected == actual end
	if type( actual ) ~= "table" then return false end
	for key, expectedValue in pairs( expected ) do
		if not subsetEqual( expectedValue, actual[key] ) then return false end
	end
	return true
end

function MC.MerchantItemCostMatches( stack, cost )
	if MC.IsEmptyItemStack( stack ) or MC.IsEmptyItemStack( cost ) or stack.item ~= cost.item then return false end
	if type( cost.components ) == "table" and not subsetEqual( cost.components, stack.components or {} ) then return false end
	return true
end

function MC.MerchantOfferSatisfied( offer, paymentA, paymentB )
	if type( offer ) ~= "table" or offer.outOfStock == true or offer.unavailable == true
	or MC.IsEmptyItemStack( offer.costA ) or MC.IsEmptyItemStack( offer.result ) then return false end
	if not MC.MerchantItemCostMatches( paymentA, offer.costA )
	or ( tonumber( paymentA and paymentA.count ) or 0 ) < offer.costA.count then return false end
	if MC.IsEmptyItemStack( offer.costB ) then return MC.IsEmptyItemStack( paymentB ) end
	return MC.MerchantItemCostMatches( paymentB, offer.costB )
		and ( tonumber( paymentB and paymentB.count ) or 0 ) >= offer.costB.count
end

function MC.MerchantFindActiveOffer( snapshot, selection, paymentA, paymentB )
	local offers = type( snapshot ) == "table" and snapshot.offers or nil
	if type( offers ) ~= "table" or #offers == 0 then return nil end
	selection = integer( selection, 0, 0, math.max( 0, #offers - 1 ) )
	local candidates = {}
	if selection > 0 then candidates[1] = offers[selection + 1]
	else for _, offer in ipairs( offers ) do candidates[#candidates + 1] = offer end end
	for _, offer in ipairs( candidates ) do
		if MC.MerchantOfferSatisfied( offer, paymentA, paymentB ) then return offer, false end
		if MC.MerchantOfferSatisfied( offer, paymentB, paymentA ) then return offer, true end
	end
	return nil
end

local function merchantSetCount( stack, count )
	count = math.max( 0, math.floor( tonumber( count ) or 0 ) )
	return count > 0 and MC.CopyItemStack( stack, count ) or nil
end

local function merchantReturnPayment( container, slotIndex, targets, context )
	local stack = MC.ContainerGetStack( container, slotIndex )
	if MC.IsEmptyItemStack( stack ) then return true, false end
	local remaining, moved = MC.ContainerMoveStackTo( container, stack, targets, context )
	local ok, err = MC.ContainerSetStack( container, slotIndex, remaining )
	if not ok then return false, err or "merchant_payment_return_failed" end
	return true, moved == true
end

local function merchantFillPayment( container, slotIndex, cost, targets, context )
	if MC.IsEmptyItemStack( cost ) then return true, false end
	local paymentSlot = MC.ContainerGetSlot( container, slotIndex )
	if not paymentSlot then return false, "merchant_payment_slot_missing" end
	local changed = false
	for _, sourceIndex in ipairs( targets or {} ) do
		local sourceSlot = MC.ContainerGetSlot( container, sourceIndex )
		local source = sourceSlot and MC.InventorySlotGet( sourceSlot ) or nil
		if not MC.IsEmptyItemStack( source ) and MC.MerchantItemCostMatches( source, cost ) then
			local payment = MC.ContainerGetStack( container, slotIndex )
			if MC.IsEmptyItemStack( payment ) or MC.ItemStacksCanMerge( payment, source ) then
				local limit = MC.InventorySlotLimit( paymentSlot, source )
				local room = limit - ( payment and payment.count or 0 )
				local moved = math.min( math.max( 0, room ), source.count )
				if moved > 0 then
					local nextPayment = payment and MC.CopyItemStack( payment, payment.count + moved )
						or MC.CopyItemStack( source, moved )
					local ok, err = MC.ContainerSetStack( container, slotIndex, nextPayment )
					if not ok then return false, err or "merchant_payment_fill_failed" end
					ok, err = MC.InventorySlotSet( sourceSlot, merchantSetCount( source, source.count - moved ) )
					if not ok then return false, err or "merchant_inventory_take_failed" end
					changed = true
					if nextPayment.count >= limit then break end
				end
			end
		end
	end
	return true, changed
end

-- MerchantMenu#tryMoveItems / moveFromInventoryToPaymentSlot.  Payment stacks
-- are returned first (reverse player-slot order supplied by the caller).  Only
-- when both slots are empty does the selected offer refill them, scanning the
-- Java player-menu order and filling to the item's maximum stack size.
function MC.MerchantTryMoveItems( container, snapshot, selection, paymentAIndex, paymentBIndex,
	autofillTargets, returnTargets, context )
	if type( container ) ~= "table" or type( snapshot ) ~= "table"
	or type( snapshot.offers ) ~= "table" then return false, "merchant_data_missing" end
	selection = integer( selection, -1 )
	local offer = snapshot.offers[selection + 1]
	if not offer then return false, "invalid_offer" end

	local ok, err = merchantReturnPayment( container, paymentAIndex, returnTargets, context )
	if not ok then return false, err end
	ok, err = merchantReturnPayment( container, paymentBIndex, returnTargets, context )
	if not ok then return false, err end
	if not MC.IsEmptyItemStack( MC.ContainerGetStack( container, paymentAIndex ) )
	or not MC.IsEmptyItemStack( MC.ContainerGetStack( container, paymentBIndex ) ) then
		return true, { offer = offer, autofilled = false }
	end
	-- Unsupported data-driven results (currently exploration maps) are a
	-- permanent capability failure, not an exhausted offer.  Selection may
	-- still return the previous payment stacks, but must never pull fresh items
	-- into the payment slots for a result the server cannot produce.
	if offer.unavailable == true then
		return true, { offer = offer, autofilled = false, unavailable = true }
	end

	ok, err = merchantFillPayment( container, paymentAIndex, offer.costA, autofillTargets, context )
	if not ok then return false, err end
	ok, err = merchantFillPayment( container, paymentBIndex, offer.costB, autofillTargets, context )
	if not ok then return false, err end
	return true, { offer = offer, autofilled = true }
end

MC.MerchantMaxOffers = MAX_OFFERS
MC.MerchantTradeableEnchantments = TRADEABLE_ENCHANTMENTS
MC.MerchantTradeablePotions = TRADEABLE_POTIONS

-- Entity implementations opt in with one shared, data-only flag.  Client
-- preview only claims the interaction; the server opens the authoritative
-- transient menu after sv_merchant.lua has validated the full method contract.
hook.Add( "MC.UseItemOnEntity", "mcgame_external_merchant_interaction", function( ply, target, _, context )
	if not IsValid( target ) or target.BMBMerchantContract ~= true then return nil end
	if CLIENT or context and context.preview == true then return true end
	local opener = MC.SV and MC.SV.OpenExternalMerchant
	if type( opener ) ~= "function" then return false end
	local opened = opener( ply, target, context and context.source or "minecraft_hand" )
	return opened == true
end )
