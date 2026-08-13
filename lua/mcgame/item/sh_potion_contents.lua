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

local EN_US = {
	water = "Water Bottle", mundane = "Mundane Potion", thick = "Thick Potion", awkward = "Awkward Potion",
	night_vision = "Potion of Night Vision", invisibility = "Potion of Invisibility",
	leaping = "Potion of Leaping", fire_resistance = "Potion of Fire Resistance",
	swiftness = "Potion of Swiftness", slowness = "Potion of Slowness",
	turtle_master = "Potion of the Turtle Master", water_breathing = "Potion of Water Breathing",
	healing = "Potion of Healing", harming = "Potion of Harming", poison = "Potion of Poison",
	regeneration = "Potion of Regeneration", strength = "Potion of Strength",
	weakness = "Potion of Weakness", luck = "Potion of Luck", slow_falling = "Potion of Slow Falling",
	wind_charged = "Potion of Wind Charging", weaving = "Potion of Weaving",
	oozing = "Potion of Oozing", infested = "Potion of Infestation",
}

local ZH_CN = {
	water = "水瓶", mundane = "平凡的药水", thick = "浓稠的药水", awkward = "粗制的药水",
	night_vision = "夜视药水", invisibility = "隐身药水", leaping = "跳跃药水", fire_resistance = "抗火药水",
	swiftness = "迅捷药水", slowness = "迟缓药水", turtle_master = "神龟药水", water_breathing = "水肺药水",
	healing = "治疗药水", harming = "伤害药水", poison = "剧毒药水", regeneration = "再生药水",
	strength = "力量药水", weakness = "虚弱药水", luck = "幸运药水", slow_falling = "缓降药水",
	wind_charged = "蓄风药水", weaving = "盘丝药水", oozing = "渗浆药水", infested = "虫蚀药水",
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

local function englishBottleName( item, base, fallback )
	if item == "minecraft:potion" then return fallback end
	local kind = item == "minecraft:splash_potion" and "Splash" or "Lingering"
	if base == "water" then return kind .. " Water Bottle" end
	if base == "mundane" or base == "thick" or base == "awkward" then
		return string.gsub( fallback, " Potion$", " " .. kind .. " Potion" )
	end
	return kind .. " " .. fallback
end

local function chineseBottleName( item, fallback )
	if item == "minecraft:potion" then return fallback end
	local prefix = item == "minecraft:splash_potion" and "喷溅型" or "滞留型"
	return prefix .. fallback
end

function PotionContents.DisplayName( stack, lang )
	if not PotionContents.IsBottle( stack ) then return nil end
	local contents = PotionContents.Value( stack )
	local definition = PotionContents.Definition( stack )
	if not contents or not definition then return nil end
	local customName = type( contents.custom_name ) == "string" and contents.custom_name or nil
	local base = customName or definition.base
	lang = tostring( lang or ( MC.Language and MC.Language() ) or "en_us" )
	if lang == "zh_cn" then
		local fallback = ZH_CN[base]
		return fallback and chineseBottleName( stack.item, fallback ) or nil
	end
	local fallback = EN_US[base]
	return fallback and englishBottleName( stack.item, base, fallback ) or nil
end

function PotionContents.TranslationKey( stack )
	local contents = PotionContents.Value( stack )
	local definition = PotionContents.Definition( stack )
	if not contents or not definition then return nil end
	local suffix = type( contents.custom_name ) == "string" and contents.custom_name or definition.base
	return BOTTLE_PREFIX[stack.item] .. suffix
end
