--[[----------------------------------------------------------------------------
	Vanilla PotionContents helpers used by the creative catalog and item renderer.

	The generated item registry contains only the three bottle item definitions;
	the actual potion variant lives in minecraft:potion_contents on ItemStack.
	This table follows the Java 26.2 potion registry order/data used by
	PotionContents#getColor and PotionContents#getName. External addons may
	register matching variants without replacing the renderer or creative UI.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.PotionContents = MC.PotionContents or {}

local PotionContents = MC.PotionContents

PotionContents.BASE_COLOR = 3694022 -- PotionContents.BASE_POTION_COLOR (#385dc6)
PotionContents.Definitions = PotionContents.Definitions or {
	["water"] = { base = "water", color = 3694022 },
	["mundane"] = { base = "mundane", color = 3694022 },
	["thick"] = { base = "thick", color = 3694022 },
	["awkward"] = { base = "awkward", color = 3694022 },
	["night_vision"] = { base = "night_vision", color = 12779366 },
	["long_night_vision"] = { base = "night_vision", color = 12779366 },
	["invisibility"] = { base = "invisibility", color = 16185078 },
	["long_invisibility"] = { base = "invisibility", color = 16185078 },
	["leaping"] = { base = "leaping", color = 16646020 },
	["long_leaping"] = { base = "leaping", color = 16646020 },
	["strong_leaping"] = { base = "leaping", color = 16646020 },
	["fire_resistance"] = { base = "fire_resistance", color = 16750848 },
	["long_fire_resistance"] = { base = "fire_resistance", color = 16750848 },
	["swiftness"] = { base = "swiftness", color = 3402751 },
	["long_swiftness"] = { base = "swiftness", color = 3402751 },
	["strong_swiftness"] = { base = "swiftness", color = 3402751 },
	["slowness"] = { base = "slowness", color = 9154528 },
	["long_slowness"] = { base = "slowness", color = 9154528 },
	["strong_slowness"] = { base = "slowness", color = 9154528 },
	["turtle_master"] = { base = "turtle_master", color = 9274086 },
	["long_turtle_master"] = { base = "turtle_master", color = 9274086 },
	["strong_turtle_master"] = { base = "turtle_master", color = 9274854 },
	["water_breathing"] = { base = "water_breathing", color = 10017472 },
	["long_water_breathing"] = { base = "water_breathing", color = 10017472 },
	["healing"] = { base = "healing", color = 16262179 },
	["strong_healing"] = { base = "healing", color = 16262179 },
	["harming"] = { base = "harming", color = 11101546 },
	["strong_harming"] = { base = "harming", color = 11101546 },
	["poison"] = { base = "poison", color = 8889187 },
	["long_poison"] = { base = "poison", color = 8889187 },
	["strong_poison"] = { base = "poison", color = 8889187 },
	["regeneration"] = { base = "regeneration", color = 13458603 },
	["long_regeneration"] = { base = "regeneration", color = 13458603 },
	["strong_regeneration"] = { base = "regeneration", color = 13458603 },
	["strength"] = { base = "strength", color = 16762624 },
	["long_strength"] = { base = "strength", color = 16762624 },
	["strong_strength"] = { base = "strength", color = 16762624 },
	["weakness"] = { base = "weakness", color = 4738376 },
	["long_weakness"] = { base = "weakness", color = 4738376 },
	["luck"] = { base = "luck", color = 5882118 },
	["slow_falling"] = { base = "slow_falling", color = 15978425 },
	["long_slow_falling"] = { base = "slow_falling", color = 15978425 },
	["wind_charged"] = { base = "wind_charged", color = 12438015 },
	["weaving"] = { base = "weaving", color = 7891290 },
	["oozing"] = { base = "oozing", color = 10092451 },
	["infested"] = { base = "infested", color = 9214860 },
}

local BOTTLE_PREFIX = {
	["minecraft:potion"] = "item.minecraft.potion.effect.",
	["minecraft:splash_potion"] = "item.minecraft.splash_potion.effect.",
	["minecraft:lingering_potion"] = "item.minecraft.lingering_potion.effect.",
}

local function component( stack, key )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return nil end
	local value = stack.components[key]
	if value == nil and string.find( key, ":", 1, true ) == nil then value = stack.components["minecraft:" .. key] end
	return value
end

local function minecraftPath( identifier )
	if type( identifier ) ~= "string" or identifier == "" then return nil end
	local namespace, path = string.match( identifier, "^([^:]+):(.+)$" )
	if namespace and namespace ~= "minecraft" then return nil end
	path = path or identifier
	return string.match( path, "^[a-z0-9_]+$" ) and path or nil
end

function PotionContents.IsBottle( stack )
	return type( stack ) == "table" and BOTTLE_PREFIX[stack.item] ~= nil
end

function PotionContents.Value( stack )
	if not PotionContents.IsBottle( stack ) then return nil end
	local value = component( stack, "potion_contents" )
	if value == nil then return { potion = "minecraft:water" } end
	if type( value ) == "string" then return { potion = value } end
	return type( value ) == "table" and value or nil
end

function PotionContents.PotionID( stack )
	local contents = PotionContents.Value( stack )
	return contents and minecraftPath( contents.potion ) or nil
end

function PotionContents.Definition( stack )
	local id = PotionContents.PotionID( stack )
	return id and PotionContents.Definitions[id] or nil
end

function PotionContents.ColorInt( stack )
	local contents = PotionContents.Value( stack )
	local custom = contents and tonumber( contents.custom_color ) or nil
	if custom ~= nil then return math.floor( custom ) % 16777216 end
	local definition = PotionContents.Definition( stack )
	return definition and definition.color or PotionContents.BASE_COLOR
end

function PotionContents.Color( stack, alpha )
	local value = PotionContents.ColorInt( stack )
	local r = math.floor( value / 65536 ) % 256
	local g = math.floor( value / 256 ) % 256
	local b = value % 256
	return Color and Color( r, g, b, tonumber( alpha ) or 255 ) or { r = r, g = g, b = b, a = tonumber( alpha ) or 255 }
end

-- Minecraft's own key (item.minecraft.<bottle>.effect.<name>); a
-- potion_contents custom_name replaces the potion's name part, as in Java.
function PotionContents.TranslationKey( stack )
	local contents = PotionContents.Value( stack )
	local definition = PotionContents.Definition( stack )
	if not contents or not definition then return nil end
	local suffix = type( contents.custom_name ) == "string" and contents.custom_name or definition.base
	local key = BOTTLE_PREFIX[stack.item] .. suffix
	return MC.I18n.ValidKey( key ) and key or nil
end

-- The bottle's name in locale (default: this realm's language).
function PotionContents.DisplayName( stack, locale )
	local key = PotionContents.TranslationKey( stack )
	return key and MC.I18n.Resolve( key, nil, locale ) or nil
end
