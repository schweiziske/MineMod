-- Persistent brewing-stand block entities and Java 26.2 brewing helpers.

MC = MC or {}

local Blocks = MC.API and MC.API.Blocks

local BREWING_TYPE = "minecraft:brewing_stand"
local BREWING_CODEC_VERSION = 1
local BREWING_SLOTS = 5
local BOTTLE_ITEMS = {
	["minecraft:potion"] = true,
	["minecraft:splash_potion"] = true,
	["minecraft:lingering_potion"] = true,
}

local function normalizeData( data )
	data = data == nil and {} or data
	if type( data ) ~= "table" then return nil, "invalid_brewing_data" end
	if data.items ~= nil and type( data.items ) ~= "table" then return nil, "invalid_brewing_items" end
	local items, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		if type( entry ) ~= "table" then return nil, "invalid_brewing_item" end
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot < 0 or slot >= BREWING_SLOTS or seen[slot] then return nil, "invalid_brewing_slot" end
		seen[slot] = true
		local stack, stackError = MC.NormalizeItemStack( entry.stack )
		if stackError then return nil, stackError end
		if stack then items[#items + 1] = { slot = slot, stack = stack } end
	end
	table.sort( items, function( left, right ) return left.slot < right.slot end )
	local function bounded( value, minimum, maximum )
		return math.Clamp( math.floor( tonumber( value ) or 0 ), minimum, maximum )
	end
	return {
		items = items,
		brewTime = bounded( data.brewTime, 0, 400 ),
		fuel = bounded( data.fuel, 0, 20 ),
	}
end

local function encodeData( data ) return normalizeData( data ) end
local function decodeData( data ) return normalizeData( data ) end
local function validateData( data ) return normalizeData( data ) ~= nil end

if Blocks and not Blocks.IsBlockEntityTypeRegistered( BREWING_TYPE ) then
	Blocks.RegisterBlockEntityType( {
		name = BREWING_TYPE,
		codecVersion = BREWING_CODEC_VERSION,
		serverOnly = true,
		Validate = validateData,
		Encode = encodeData,
		Decode = decodeData,
		CreateDefault = function()
			return {
				type = BREWING_TYPE,
				codecVersion = BREWING_CODEC_VERSION,
				data = { items = {}, brewTime = 0, fuel = 0 },
			}
		end,
	} )
end

if Blocks then Blocks.BindBlockEntityType( BREWING_TYPE, BREWING_TYPE ) end

function MC.IsBrewingStandState( stateId )
	return Blocks and Blocks.Name( stateId ) == BREWING_TYPE or false
end

local function storageFromData( data )
	local storage = {}
	for _, entry in ipairs( data and data.items or {} ) do
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot >= 0 and slot < BREWING_SLOTS then storage[slot + 1] = MC.CopyItemStack( entry.stack ) end
	end
	return storage
end

function MC.BrewingStorageFromRecord( record ) return storageFromData( record and record.data ) end

function MC.BrewingRecordFromStorage( storage, state )
	local items = {}
	for slot = 0, BREWING_SLOTS - 1 do
		local stack = storage and storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) then items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack ) } end
	end
	state = state or {}
	return {
		type = BREWING_TYPE,
		codecVersion = BREWING_CODEC_VERSION,
		data = {
			items = items,
			brewTime = math.Clamp( math.floor( tonumber( state.brewTime ) or 0 ), 0, 400 ),
			fuel = math.Clamp( math.floor( tonumber( state.fuel ) or 0 ), 0, 20 ),
		},
	}
end

function MC.BrewingSlotCount() return BREWING_SLOTS end
function MC.BrewingFuelUses() return 20 end
function MC.BrewingTime() return 400 end

function MC.BrewingIsBottle( stack )
	if MC.IsEmptyItemStack( stack ) then return false end
	return BOTTLE_ITEMS[stack.item] == true or stack.item == "minecraft:glass_bottle"
end

function MC.BrewingIsPotionBottle( stack )
	return not MC.IsEmptyItemStack( stack ) and BOTTLE_ITEMS[stack.item] == true
end

function MC.BrewingIsFuel( stack )
	return not MC.IsEmptyItemStack( stack ) and stack.item == "minecraft:blaze_powder"
end

local POTION_MIXES = {}

local function addMix( from, ingredient, to )
	POTION_MIXES[from] = POTION_MIXES[from] or {}
	POTION_MIXES[from][ingredient] = to
end

local function addStartMix( ingredient, potion )
	addMix( "water", ingredient, "mundane" )
	addMix( "awkward", ingredient, potion )
end

addMix( "water", "minecraft:glowstone_dust", "thick" )
addMix( "water", "minecraft:redstone", "mundane" )
addMix( "water", "minecraft:nether_wart", "awkward" )
addStartMix( "minecraft:breeze_rod", "wind_charged" )
addStartMix( "minecraft:slime_block", "oozing" )
addStartMix( "minecraft:stone", "infested" )
addStartMix( "minecraft:cobweb", "weaving" )
addMix( "awkward", "minecraft:golden_carrot", "night_vision" )
addMix( "night_vision", "minecraft:redstone", "long_night_vision" )
addMix( "night_vision", "minecraft:fermented_spider_eye", "invisibility" )
addMix( "long_night_vision", "minecraft:fermented_spider_eye", "long_invisibility" )
addMix( "invisibility", "minecraft:redstone", "long_invisibility" )
addStartMix( "minecraft:magma_cream", "fire_resistance" )
addMix( "fire_resistance", "minecraft:redstone", "long_fire_resistance" )
addStartMix( "minecraft:rabbit_foot", "leaping" )
addMix( "leaping", "minecraft:redstone", "long_leaping" )
addMix( "leaping", "minecraft:glowstone_dust", "strong_leaping" )
addMix( "leaping", "minecraft:fermented_spider_eye", "slowness" )
addMix( "long_leaping", "minecraft:fermented_spider_eye", "long_slowness" )
addMix( "slowness", "minecraft:redstone", "long_slowness" )
addMix( "slowness", "minecraft:glowstone_dust", "strong_slowness" )
addMix( "awkward", "minecraft:turtle_helmet", "turtle_master" )
addMix( "turtle_master", "minecraft:redstone", "long_turtle_master" )
addMix( "turtle_master", "minecraft:glowstone_dust", "strong_turtle_master" )
addMix( "swiftness", "minecraft:fermented_spider_eye", "slowness" )
addMix( "long_swiftness", "minecraft:fermented_spider_eye", "long_slowness" )
addStartMix( "minecraft:sugar", "swiftness" )
addMix( "swiftness", "minecraft:redstone", "long_swiftness" )
addMix( "swiftness", "minecraft:glowstone_dust", "strong_swiftness" )
addMix( "awkward", "minecraft:pufferfish", "water_breathing" )
addMix( "water_breathing", "minecraft:redstone", "long_water_breathing" )
addStartMix( "minecraft:glistering_melon_slice", "healing" )
addMix( "healing", "minecraft:glowstone_dust", "strong_healing" )
addMix( "healing", "minecraft:fermented_spider_eye", "harming" )
addMix( "strong_healing", "minecraft:fermented_spider_eye", "strong_harming" )
addMix( "harming", "minecraft:glowstone_dust", "strong_harming" )
addMix( "poison", "minecraft:fermented_spider_eye", "harming" )
addMix( "long_poison", "minecraft:fermented_spider_eye", "harming" )
addMix( "strong_poison", "minecraft:fermented_spider_eye", "strong_harming" )
addStartMix( "minecraft:spider_eye", "poison" )
addMix( "poison", "minecraft:redstone", "long_poison" )
addMix( "poison", "minecraft:glowstone_dust", "strong_poison" )
addStartMix( "minecraft:ghast_tear", "regeneration" )
addMix( "regeneration", "minecraft:redstone", "long_regeneration" )
addMix( "regeneration", "minecraft:glowstone_dust", "strong_regeneration" )
addStartMix( "minecraft:blaze_powder", "strength" )
addMix( "strength", "minecraft:redstone", "long_strength" )
addMix( "strength", "minecraft:glowstone_dust", "strong_strength" )
addMix( "water", "minecraft:fermented_spider_eye", "weakness" )
addMix( "weakness", "minecraft:redstone", "long_weakness" )
addMix( "awkward", "minecraft:phantom_membrane", "slow_falling" )
addMix( "slow_falling", "minecraft:redstone", "long_slow_falling" )

MC.BrewingPotionMixes = POTION_MIXES

local INGREDIENTS = {
	["minecraft:gunpowder"] = true,
	["minecraft:dragon_breath"] = true,
}
for _, mixes in pairs( POTION_MIXES ) do
	for ingredient in pairs( mixes ) do INGREDIENTS[ingredient] = true end
end

function MC.BrewingIsIngredient( stack )
	return not MC.IsEmptyItemStack( stack ) and INGREDIENTS[stack.item] == true
end

function MC.BrewingPotionID( stack )
	if not MC.BrewingIsPotionBottle( stack ) then return nil end
	if MC.PotionContents and MC.PotionContents.PotionID then
		return MC.PotionContents.PotionID( stack ) or "water"
	end
	local components = type( stack.components ) == "table" and stack.components or nil
	local contents = components and ( components["minecraft:potion_contents"] or components.potion_contents ) or nil
	local potion = type( contents ) == "table" and contents.potion or type( contents ) == "string" and contents or nil
	if type( potion ) ~= "string" or potion == "" then return "water" end
	return string.gsub( potion, "^minecraft:", "" )
end

function MC.BrewingMixResult( source, ingredient )
	if not MC.BrewingIsPotionBottle( source ) or not MC.BrewingIsIngredient( ingredient ) then return nil end
	if source.item == "minecraft:potion" and ingredient.item == "minecraft:gunpowder" then
		local output = MC.CopyItemStack( source, 1 )
		output.item = "minecraft:splash_potion"
		return output
	end
	if source.item == "minecraft:splash_potion" and ingredient.item == "minecraft:dragon_breath" then
		local output = MC.CopyItemStack( source, 1 )
		output.item = "minecraft:lingering_potion"
		return output
	end
	local potion = MC.BrewingPotionID( source )
	local target = potion and POTION_MIXES[potion] and POTION_MIXES[potion][ingredient.item] or nil
	if not target then return nil end
	local output = MC.CopyItemStack( source, 1 )
	output.components = MC.CopyItemComponents( source.components ) or {}
	local key
	if output.components["minecraft:potion_contents"] ~= nil then key = "minecraft:potion_contents"
	elseif output.components.potion_contents ~= nil then key = "potion_contents"
	else key = "minecraft:potion_contents" end
	local contents = output.components[key]
	if type( contents ) ~= "table" then contents = {} else contents = MC.CopyItemComponents( contents ) or {} end
	contents.potion = "minecraft:" .. target
	output.components[key] = contents
	return output
end

function MC.BrewingHasMix( source, ingredient )
	return MC.BrewingMixResult( source, ingredient ) ~= nil
end

function MC.BrewingCanBrew( storage )
	local ingredient = storage and storage[4] or nil
	if not MC.BrewingIsIngredient( ingredient ) then return false end
	for slot = 1, 3 do
		if MC.BrewingHasMix( storage[slot], ingredient ) then return true end
	end
	return false
end

function MC.BrewingIngredientRemainder( stack )
	if not MC.IsEmptyItemStack( stack ) and stack.item == "minecraft:dragon_breath" then
		return MC.NewItemStack( "minecraft:glass_bottle", 1 )
	end
end

local function copyStorage( storage )
	local copied = {}
	for slot = 1, BREWING_SLOTS do copied[slot] = MC.CopyItemStack( storage and storage[slot] ) end
	return copied
end

-- One Java serverTick expressed as a pure value transition. The server owns
-- persistence/network/sound/drop side effects; this helper owns only brewing
-- rules so executable fixtures and both realms can verify the same semantics.
function MC.BrewingAdvance( storage, state )
	local output = copyStorage( storage )
	state = state or {}
	local brewingTime = MC.BrewingTime and MC.BrewingTime() or 400
	local fuelUses = MC.BrewingFuelUses and MC.BrewingFuelUses() or 20
	local result = {
		storage = output,
		brewTime = math.Clamp( math.floor( tonumber( state.brewTime ) or 0 ), 0, brewingTime ),
		fuel = math.Clamp( math.floor( tonumber( state.fuel ) or 0 ), 0, fuelUses ),
		ingredientItem = state.ingredientItem,
		drops = {},
		brewed = false,
	}

	local fuelStack = output[5]
	if result.fuel <= 0 and MC.BrewingIsFuel( fuelStack ) then
		result.fuel = fuelUses
		output[5] = fuelStack.count > 1 and MC.CopyItemStack( fuelStack, fuelStack.count - 1 ) or nil
	end

	local brewable = MC.BrewingCanBrew( output )
	local ingredient = output[4]
	if result.brewTime > 0 then
		result.brewTime = result.brewTime - 1
		if result.brewTime == 0 and brewable then
			for slot = 1, 3 do
				local mixed = MC.BrewingMixResult( output[slot], ingredient )
				if mixed then output[slot] = mixed end
			end
			local remainder = MC.BrewingIngredientRemainder( ingredient )
			if ingredient.count > 1 then
				output[4] = MC.CopyItemStack( ingredient, ingredient.count - 1 )
				if remainder then result.drops[#result.drops + 1] = remainder end
			else
				output[4] = remainder
			end
			result.brewed = true
		elseif not brewable or MC.IsEmptyItemStack( ingredient ) or ingredient.item ~= result.ingredientItem then
			result.brewTime = 0
		end
	elseif brewable and result.fuel > 0 then
		result.fuel = result.fuel - 1
		result.brewTime = brewingTime
		result.ingredientItem = ingredient.item
	end
	if result.brewTime <= 0 then result.ingredientItem = nil end
	return result
end
