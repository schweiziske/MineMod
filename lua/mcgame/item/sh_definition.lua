-- Normalized item behavior helpers shared by inventory, world interaction and UI.

MC = MC or {}
MC.ItemUseAnimations = MC.ItemUseAnimations or {
	none = true, eat = true, drink = true, block = true, bow = true,
	crossbow = true, spear = true, spyglass = true, brush = true,
}

local function definitionFor( stackOrDefinition )
	if type( stackOrDefinition ) == "table" and stackOrDefinition.name and not stackOrDefinition.item then
		return stackOrDefinition
	end
	local item = type( stackOrDefinition ) == "table" and stackOrDefinition.item or stackOrDefinition
	return MC.GetItem and MC.GetItem( item ) or nil
end

local function component( stack, key )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return nil end
	local value = stack.components[key]
	if value == nil and string.find( key, ":", 1, true ) == nil then value = stack.components["minecraft:" .. key] end
	return value
end

local function numberField( value, minimum, maximum, fallback )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return fallback end
	return math.max( minimum, math.min( maximum, value ) )
end

-- Values mirror out/net/minecraft/world/food/Foods.java.  Keeping this small
-- immutable table in the shared definition layer lets the first consumable
-- path work even before every Item.Properties component is serialized into
-- the generated registry.
local VANILLA_FOOD = {
	["minecraft:apple"] = { 4, 0.3 }, ["minecraft:baked_potato"] = { 5, 0.6 },
	["minecraft:beef"] = { 3, 0.3 }, ["minecraft:beetroot"] = { 1, 0.6 },
	["minecraft:beetroot_soup"] = { 6, 0.6 }, ["minecraft:bread"] = { 5, 0.6 },
	["minecraft:carrot"] = { 3, 0.6 }, ["minecraft:chicken"] = { 2, 0.3 },
	["minecraft:chorus_fruit"] = { 4, 0.3, true }, ["minecraft:cod"] = { 2, 0.1 },
	["minecraft:cooked_beef"] = { 8, 0.8 }, ["minecraft:cooked_chicken"] = { 6, 0.6 },
	["minecraft:cooked_cod"] = { 5, 0.6 }, ["minecraft:cooked_mutton"] = { 6, 0.8 },
	["minecraft:cooked_porkchop"] = { 8, 0.8 }, ["minecraft:cooked_rabbit"] = { 5, 0.6 },
	["minecraft:cooked_salmon"] = { 6, 0.8 }, ["minecraft:cookie"] = { 2, 0.1 },
	["minecraft:dried_kelp"] = { 1, 0.3 }, ["minecraft:enchanted_golden_apple"] = { 4, 1.2, true },
	["minecraft:golden_apple"] = { 4, 1.2, true }, ["minecraft:golden_carrot"] = { 6, 1.2 },
	["minecraft:honey_bottle"] = { 6, 0.1, true }, ["minecraft:melon_slice"] = { 2, 0.3 },
	["minecraft:mushroom_stew"] = { 6, 0.6 }, ["minecraft:mutton"] = { 2, 0.3 },
	["minecraft:poisonous_potato"] = { 2, 0.3 }, ["minecraft:porkchop"] = { 3, 0.3 },
	["minecraft:potato"] = { 1, 0.3 }, ["minecraft:pufferfish"] = { 1, 0.1 },
	["minecraft:pumpkin_pie"] = { 8, 0.3 }, ["minecraft:rabbit"] = { 3, 0.3 },
	["minecraft:rabbit_stew"] = { 10, 0.6 }, ["minecraft:rotten_flesh"] = { 4, 0.1 },
	["minecraft:salmon"] = { 2, 0.1 }, ["minecraft:spider_eye"] = { 2, 0.8 },
	["minecraft:suspicious_stew"] = { 6, 0.6, true }, ["minecraft:sweet_berries"] = { 2, 0.1 },
	["minecraft:glow_berries"] = { 2, 0.1 }, ["minecraft:tropical_fish"] = { 1, 0.1 },
}

function MC.ItemUseDuration( stackOrDefinition, user )
	local definition = definitionFor( stackOrDefinition )
	local consumable = component( stackOrDefinition, "minecraft:consumable" )
	if type( consumable ) == "table" then
		return math.floor( numberField( consumable.consume_ticks or consumable.consumeTicks, 0, 72000, 32 ) )
	end
	return math.floor( numberField( definition and definition.useDuration, 0, 72000, 0 ) )
end

function MC.ItemUseAnimation( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local consumable = component( stackOrDefinition, "minecraft:consumable" )
	local value = type( consumable ) == "table" and consumable.animation or definition and definition.useAnimation or "none"
	value = string.lower( tostring( value or "none" ) )
	return MC.ItemUseAnimations[value] and value or "none"
end

function MC.ItemIsUnbreakable( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local value = component( stackOrDefinition, "minecraft:unbreakable" )
	return definition and definition.unbreakable == true or value == true or type( value ) == "table"
end

function MC.ItemToolDamagePerBlock( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local value = component( stackOrDefinition, "minecraft:tool" )
	if type( value ) == "table" and value.damage_per_block ~= nil then
		return math.floor( numberField( value.damage_per_block, 0, 255, 1 ) )
	end
	return math.floor( numberField( definition and definition.toolDamagePerBlock, 0, 255, 0 ) )
end

function MC.ItemFoodData( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local food = component( stackOrDefinition, "minecraft:food" )
	if type( food ) == "table" then
		return {
			nutrition = math.floor( numberField( food.nutrition, 0, 255, 0 ) ),
			saturation = numberField( food.saturation, 0, 255, 0 ),
			alwaysEdible = food.can_always_eat == true or food.alwaysEdible == true,
		}
	end
	if not definition then return nil end
	local vanilla = VANILLA_FOOD[definition.name]
	if ( definition.foodNutrition or 0 ) <= 0 and not vanilla then return nil end
	return {
		nutrition = ( definition.foodNutrition or 0 ) > 0 and definition.foodNutrition or vanilla[1],
		saturation = ( definition.foodSaturation or 0 ) > 0 and definition.foodSaturation or vanilla[2],
		alwaysEdible = definition.foodAlwaysEdible == true or vanilla and vanilla[3] == true or false,
	}
end

function MC.ItemIsConsumable( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	return component( stackOrDefinition, "minecraft:consumable" ) ~= nil
		or MC.ItemFoodData( stackOrDefinition ) ~= nil
		or definition and definition.consumable == true or false
end

function MC.ItemDurabilityInfo( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local maxDamage = tonumber( definition and definition.maxDamage ) or 0
	if maxDamage <= 0 then return nil end
	local stack = type( stackOrDefinition ) == "table" and stackOrDefinition.item and stackOrDefinition or nil
	local damage = math.max( 0, math.min( maxDamage, math.floor( tonumber( stack and stack.damage ) or 0 ) ) )
	local remaining = 1 - damage / maxDamage
	local hue = remaining / 3
	local saturation, value = 1, 1
	local i = math.floor( hue * 6 )
	local f = hue * 6 - i
	local p, q, t = value * ( 1 - saturation ), value * ( 1 - f * saturation ), value * ( 1 - ( 1 - f ) * saturation )
	local r, g, b
	if i % 6 == 0 then r, g, b = value, t, p
	elseif i == 1 then r, g, b = q, value, p
	elseif i == 2 then r, g, b = p, value, t
	elseif i == 3 then r, g, b = p, q, value
	elseif i == 4 then r, g, b = t, p, value
	else r, g, b = value, p, q end
	return {
		visible = damage > 0,
		width = math.Clamp( math.floor( 13 * remaining + 0.5 ), 0, 13 ),
		remaining = remaining,
		color = { r = math.floor( r * 255 + 0.5 ), g = math.floor( g * 255 + 0.5 ), b = math.floor( b * 255 + 0.5 ) },
	}
end
