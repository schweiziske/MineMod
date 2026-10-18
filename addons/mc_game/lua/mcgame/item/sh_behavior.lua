-- Minecraft item behavior classification shared by the server and renderer.
-- The names and timings are derived from the Item subclasses in out/; custom
-- items may override them with definition.useKind/useDuration.

MC = MC or {}

local KINDS = {
	bow = { duration = 72000, animation = "bow" },
	-- Crossbows finish loading after 1.25 seconds (25 game ticks).  The
	-- item's general use duration is still effectively indefinite; this is
	-- the charge duration used by the right-click state machine.
	crossbow = { duration = 25, animation = "crossbow" },
	trident = { duration = 72000, animation = "spear" },
	shield = { duration = 72000, animation = "block" },
	spyglass = { duration = 72000, animation = "spyglass" },
	brush = { duration = 200, animation = "brush" },
	food = { duration = 32, animation = "eat" },
	drink = { duration = 32, animation = "drink" },
	projectile = { duration = 0, animation = "none" },
	bucket = { duration = 0, animation = "none" },
}

local PROJECTILES = {
	["minecraft:egg"] = true, ["minecraft:snowball"] = true,
	["minecraft:ender_pearl"] = true, ["minecraft:experience_bottle"] = true,
	["minecraft:splash_potion"] = true, ["minecraft:lingering_potion"] = true,
	["minecraft:wind_charge"] = true, ["minecraft:firework_rocket"] = true,
}

local function definitionFor( stackOrDefinition )
	if type( stackOrDefinition ) == "table" and stackOrDefinition.name and not stackOrDefinition.item then
		return stackOrDefinition
	end
	local item = type( stackOrDefinition ) == "table" and stackOrDefinition.item or stackOrDefinition
	return MC.GetItem and MC.GetItem( item ) or nil
end

function MC.ItemBehavior( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	if not definition then return nil end
	if definition.useKind and KINDS[definition.useKind] then return definition.useKind end
	local name = definition.name
	if name == "minecraft:milk_bucket" or name == "minecraft:potion" then return "drink" end
	if name == "minecraft:bucket" or name == "minecraft:water_bucket" or name == "minecraft:lava_bucket" then return "bucket" end
	if name == "minecraft:bow" then return "bow" end
	if name == "minecraft:crossbow" then return "crossbow" end
	if name == "minecraft:trident" then return "trident" end
	if name == "minecraft:shield" then return "shield" end
	if name == "minecraft:spyglass" then return "spyglass" end
	if name == "minecraft:brush" then return "brush" end
	if PROJECTILES[name] then return "projectile" end
	if MC.ItemFoodData and MC.ItemFoodData( stackOrDefinition ) then return "food" end
	return nil
end

function MC.ItemBehaviorSpec( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	local kind = MC.ItemBehavior( stackOrDefinition )
	local spec = kind and KINDS[kind] or nil
	if not spec and definition and ( tonumber( definition.useDuration ) or 0 ) > 0 then
		spec = { duration = definition.useDuration, animation = definition.useAnimation or "none" }
	end
	if not spec then return nil end
	local configuredDuration = MC.ItemUseDuration( stackOrDefinition )
	local food = MCITEM and MCITEM.Food and MCITEM.Food.Get( definition and definition.name )
	if configuredDuration <= 0 and food then configuredDuration = food.consumeTicks end
	if configuredDuration <= 0 then configuredDuration = spec.duration or 0 end
	return {
		kind = kind,
		duration = math.floor( configuredDuration ),
		animation = food and food.animation or ( definition and definition.useAnimation ~= "none" and definition.useAnimation ) or spec.animation,
	}
end

function MC.ItemIsUsingCharge( stackOrDefinition )
	local definition = definitionFor( stackOrDefinition )
	return MC.ItemBehavior( stackOrDefinition ) == "bow"
		or MC.ItemBehavior( stackOrDefinition ) == "crossbow"
		or MC.ItemBehavior( stackOrDefinition ) == "trident"
		or definition and definition.useKind == "charge" or false
end

function MC.ItemCrossbowCharged( stack )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return false end
	local value = stack.components["minecraft:charged_projectiles"] or stack.components.charged_projectiles
	return type( value ) == "table" and next( value ) ~= nil or value == true
end

function MC.ItemCrossbowChargeType( stack )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return "none" end
	local value = stack.components["minecraft:charged_projectiles"] or stack.components.charged_projectiles
	if type( value ) ~= "table" then return value == true and "arrow" or "none" end
	for _, projectile in ipairs( value ) do
		local item = type( projectile ) == "table" and projectile.item or projectile
		if item == "minecraft:firework_rocket" then return "rocket" end
		if item == "minecraft:arrow" or item == "minecraft:spectral_arrow" then return "arrow" end
	end
	return next( value ) ~= nil and "arrow" or "none"
end

function MC.ItemUseProgress( startedAt, duration, now )
	startedAt, duration, now = tonumber( startedAt ), tonumber( duration ), tonumber( now ) or CurTime and CurTime() or 0
	if not startedAt or not duration or duration <= 0 then return 1 end
	local progress = math.Clamp( ( now - startedAt ) * 20 / duration, 0, 1 )
	return progress >= 0.999999 and 1 or progress
end
