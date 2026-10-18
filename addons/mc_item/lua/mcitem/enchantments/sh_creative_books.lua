-- Java 26.2 creative inventory enchanted-book variants.
--
-- The Ingredients tab exposes one book at each enchantment's maximum level,
-- while Search exposes every level from I through the maximum.  The anvil
-- owns the enchantment registry and rules; this module deliberately reads
-- MC.EnchantmentOrder / MC.Enchantments instead of maintaining a second table.

MCITEM = MCITEM or {}
MCITEM.CreativeEnchantedBooks = MCITEM.CreativeEnchantedBooks or {}

local Books = MCITEM.CreativeEnchantedBooks
local BOOK_ITEM = "minecraft:enchanted_book"
local PROVIDER_ID = "mcitem:java_26_2_enchanted_books"

-- Official Java 26.2 en_us / zh_cn display strings.  This is presentation
-- metadata only; levels and every gameplay rule still come from MC.Enchantments.
local ENCHANTMENT_NAMES = {
    ["minecraft:aqua_affinity"] = { en_us = "Aqua Affinity", zh_cn = "水下速掘" },
    ["minecraft:bane_of_arthropods"] = { en_us = "Bane of Arthropods", zh_cn = "节肢杀手" },
    ["minecraft:binding_curse"] = { en_us = "Curse of Binding", zh_cn = "绑定诅咒" },
    ["minecraft:blast_protection"] = { en_us = "Blast Protection", zh_cn = "爆炸保护" },
    ["minecraft:breach"] = { en_us = "Breach", zh_cn = "破甲" },
    ["minecraft:channeling"] = { en_us = "Channeling", zh_cn = "引雷" },
    ["minecraft:density"] = { en_us = "Density", zh_cn = "致密" },
    ["minecraft:depth_strider"] = { en_us = "Depth Strider", zh_cn = "深海探索者" },
    ["minecraft:efficiency"] = { en_us = "Efficiency", zh_cn = "效率" },
    ["minecraft:feather_falling"] = { en_us = "Feather Falling", zh_cn = "摔落缓冲" },
    ["minecraft:fire_aspect"] = { en_us = "Fire Aspect", zh_cn = "火焰附加" },
    ["minecraft:fire_protection"] = { en_us = "Fire Protection", zh_cn = "火焰保护" },
    ["minecraft:flame"] = { en_us = "Flame", zh_cn = "火矢" },
    ["minecraft:fortune"] = { en_us = "Fortune", zh_cn = "时运" },
    ["minecraft:frost_walker"] = { en_us = "Frost Walker", zh_cn = "冰霜行者" },
    ["minecraft:impaling"] = { en_us = "Impaling", zh_cn = "穿刺" },
    ["minecraft:infinity"] = { en_us = "Infinity", zh_cn = "无限" },
    ["minecraft:knockback"] = { en_us = "Knockback", zh_cn = "击退" },
    ["minecraft:looting"] = { en_us = "Looting", zh_cn = "抢夺" },
    ["minecraft:loyalty"] = { en_us = "Loyalty", zh_cn = "忠诚" },
    ["minecraft:luck_of_the_sea"] = { en_us = "Luck of the Sea", zh_cn = "海之眷顾" },
    ["minecraft:lunge"] = { en_us = "Lunge", zh_cn = "突进" },
    ["minecraft:lure"] = { en_us = "Lure", zh_cn = "饵钓" },
    ["minecraft:mending"] = { en_us = "Mending", zh_cn = "经验修补" },
    ["minecraft:multishot"] = { en_us = "Multishot", zh_cn = "多重射击" },
    ["minecraft:piercing"] = { en_us = "Piercing", zh_cn = "穿透" },
    ["minecraft:power"] = { en_us = "Power", zh_cn = "力量" },
    ["minecraft:projectile_protection"] = { en_us = "Projectile Protection", zh_cn = "弹射物保护" },
    ["minecraft:protection"] = { en_us = "Protection", zh_cn = "保护" },
    ["minecraft:punch"] = { en_us = "Punch", zh_cn = "冲击" },
    ["minecraft:quick_charge"] = { en_us = "Quick Charge", zh_cn = "快速装填" },
    ["minecraft:respiration"] = { en_us = "Respiration", zh_cn = "水下呼吸" },
    ["minecraft:riptide"] = { en_us = "Riptide", zh_cn = "激流" },
    ["minecraft:sharpness"] = { en_us = "Sharpness", zh_cn = "锋利" },
    ["minecraft:silk_touch"] = { en_us = "Silk Touch", zh_cn = "精准采集" },
    ["minecraft:smite"] = { en_us = "Smite", zh_cn = "亡灵杀手" },
    ["minecraft:soul_speed"] = { en_us = "Soul Speed", zh_cn = "灵魂疾行" },
    ["minecraft:sweeping_edge"] = { en_us = "Sweeping Edge", zh_cn = "横扫之刃" },
    ["minecraft:swift_sneak"] = { en_us = "Swift Sneak", zh_cn = "迅捷潜行" },
    ["minecraft:thorns"] = { en_us = "Thorns", zh_cn = "荆棘" },
    ["minecraft:unbreaking"] = { en_us = "Unbreaking", zh_cn = "耐久" },
    ["minecraft:vanishing_curse"] = { en_us = "Curse of Vanishing", zh_cn = "消失诅咒" },
    ["minecraft:wind_burst"] = { en_us = "Wind Burst", zh_cn = "风爆" },
}

local CURSES = {
    ["minecraft:binding_curse"] = true,
    ["minecraft:vanishing_curse"] = true,
}

local function storedComponent( stack )
    local components = type( stack ) == "table" and stack.components or nil
    if type( components ) ~= "table" then return nil, false end
    if components["minecraft:stored_enchantments"] ~= nil then
        return components["minecraft:stored_enchantments"], true
    end
    if components.stored_enchantments ~= nil then return components.stored_enchantments, true end
    return nil, false
end

local function storedLevels( stack )
    local value = storedComponent( stack )
    local source = type( value ) == "table" and type( value.levels ) == "table" and value.levels or value
    local levels = {}
    if type( source ) ~= "table" then return levels end
    for rawId, rawLevel in pairs( source ) do
        local id = tostring( rawId or "")
        if id ~= "" then
            if not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
            local level = type( rawLevel ) == "table" and tonumber( rawLevel.level or rawLevel.lvl)
                or tonumber( rawLevel )
            if level and level > 0 then levels[id] = math.floor( level ) end
        end
    end
    return levels
end

local function romanLevel( value )
    local level = math.max( 1, math.floor( tonumber( value ) or 1 ) )
    local values = {
        { 1000, "M" }, { 900, "CM" }, { 500, "D" }, { 400, "CD" },
        { 100, "C" }, { 90, "XC" }, { 50, "L" }, { 40, "XL" },
        { 10, "X" }, { 9, "IX" }, { 5, "V" }, { 4, "IV" }, { 1, "I" },
    }
    local result = {}
    for _, entry in ipairs( values ) do
        while level >= entry[1] do
            result[#result + 1] = entry[2]
            level = level - entry[1]
        end
    end
    return table.concat( result )
end

local function orderedLevelIds( levels )
    local result, seen = {}, {}
    local order = MC and ( MC.EnchantmentTooltipOrder or MC.EnchantmentOrder ) or {}
    for _, id in ipairs( order ) do
        if levels[id] then
            result[#result + 1] = id
            seen[id] = true
        end
    end
    local remainder = {}
    for id in pairs( levels ) do
        if not seen[id] then remainder[#remainder + 1] = id end
    end
    table.sort( remainder )
    for _, id in ipairs( remainder ) do result[#result + 1] = id end
    return result
end

local function fallbackName( id )
    local path = string.match( tostring( id or "" ), "^[^:]+:(.+)$" ) or tostring( id or "")
    path = string.gsub( path, "_", " " )
    return string.gsub( path, "(%a)([%w']*)", function( first, rest )
        return string.upper( first ) .. string.lower( rest )
    end )
end

function MCITEM.EnchantmentDisplayName( enchantmentId, lang )
    local id = tostring( enchantmentId or "")
    if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
    lang = tostring( lang or ( MC and MC.Language and MC.Language() ) or "en_us" )
    local names = ENCHANTMENT_NAMES[id]
    return names and ( names[lang] or names.en_us ) or fallbackName( id )
end

function MCITEM.EnchantmentLevelName( enchantmentId, level, lang )
    local id = tostring( enchantmentId or "")
    if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
    local name = MCITEM.EnchantmentDisplayName( id, lang )
    local definition = MC and MC.Enchantments and MC.Enchantments[id] or nil
    level = math.max( 1, math.floor( tonumber( level ) or 1 ) )
    -- Enchantment.getFullname omits "I" only when level == 1 and the
    -- enchantment itself has a single maximum level.
    if level == 1 and tonumber( definition and definition.maxLevel ) == 1 then return name end
    return name .. " " .. romanLevel( level )
end

function MCITEM.IsCurseEnchantment( enchantmentId )
    local id = tostring( enchantmentId or "")
    if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
    return CURSES[id] == true
end

function MCITEM.OrderedEnchantmentIds( levels )
    return orderedLevelIds( type( levels ) == "table" and levels or {} )
end

function MCITEM.EnchantedBookDisplayName( stack, lang )
    if type( stack ) ~= "table" or stack.item ~= BOOK_ITEM then return nil end
    local levels = storedLevels( stack )
    if next( levels ) == nil then return nil end
    lang = tostring( lang or ( MC and MC.Language and MC.Language() ) or "en_us" )
    local base = MC and MC.ItemDisplayName and MC.ItemDisplayName( BOOK_ITEM, lang )
        or ( lang == "zh_cn" and "附魔书" or "Enchanted Book" )
    local descriptions = {}
    for _, id in ipairs( orderedLevelIds( levels ) ) do
        descriptions[#descriptions + 1] = MCITEM.EnchantmentLevelName( id, levels[id], lang )
    end
    return tostring( base ) .. " — " .. table.concat( descriptions, ", " )
end

local function createBook( enchantmentId, level )
    return {
        item = BOOK_ITEM,
        count = 1,
        components = {
            ["minecraft:stored_enchantments"] = {
                levels = { [enchantmentId] = level },
                show_in_tooltip = true,
            },
        },
    }
end

function Books.BuildStacks( allLevels )
    local result = {}
    for _, enchantmentId in ipairs( MC and MC.EnchantmentOrder or {} ) do
        local definition = MC and MC.Enchantments and MC.Enchantments[enchantmentId] or nil
        local maximum = math.max( 0, math.floor( tonumber( definition and definition.maxLevel ) or 0 ) )
        local minimum = allLevels and 1 or maximum
        for level = minimum, maximum do
            result[#result + 1] = createBook( enchantmentId, level )
        end
    end
    return result
end

local function isPlainBook( stack )
    if type( stack ) ~= "table" or stack.item ~= BOOK_ITEM then return false end
    local components = stack.components
    return type( components ) ~= "table" or next( components ) == nil
end

function Books.ProvideCreativeStacks( tabKey, stacks )
    tabKey = tostring( tabKey or "")
    if tabKey ~= "ingredients" and tabKey ~= "search" then return stacks end
    local variants = Books.BuildStacks( tabKey == "search" )
    local result = {}
    if tabKey == "ingredients" then
        for _, stack in ipairs( stacks or {} ) do result[#result + 1] = stack end
        for _, stack in ipairs( variants ) do result[#result + 1] = stack end
        return result
    end

    -- The generated Search data contains one component-free placeholder. Put
    -- the complete variants at that exact location and discard any duplicate
    -- plain placeholders. If upstream data ever omits it, append as a fallback.
    local inserted = false
    for _, stack in ipairs( stacks or {} ) do
        if isPlainBook( stack ) then
            if not inserted then
                for _, variant in ipairs( variants ) do result[#result + 1] = variant end
                inserted = true
            end
        else
            result[#result + 1] = stack
        end
    end
    if not inserted then
        for _, variant in ipairs( variants ) do result[#result + 1] = variant end
    end
    return result
end

function Books.RegisterProvider()
    local creative = MC and MC.API and MC.API.CreativeStacks or nil
    if not creative or type( creative.RegisterProvider ) ~= "function" then return false end
    local ok = creative.RegisterProvider( PROVIDER_ID, Books.ProvideCreativeStacks, 110 )
    Books.Registered = ok == true
    return Books.Registered
end

Books.ProviderId = PROVIDER_ID

if hook and hook.Add then
    hook.Add( "MC.CreativeStacksAPIReady", "MCITEM.CreativeEnchantedBooks.Ready", Books.RegisterProvider )
    hook.Add( "MC.APIReady", "MCITEM.CreativeEnchantedBooks.APIReady", Books.RegisterProvider )
    hook.Add( "InitPostEntity", "MCITEM.CreativeEnchantedBooks.Init", Books.RegisterProvider )
    hook.Add( "OnReloaded", "MCITEM.CreativeEnchantedBooks.Reload", Books.RegisterProvider )
end

if timer and timer.Simple then timer.Simple( 0, Books.RegisterProvider ) end
if MC and ( MC.CreativeStacksAPIReady == true
    or MC.API and MC.API.CreativeStacks and type( MC.API.CreativeStacks.RegisterProvider ) == "function" ) then
    Books.RegisterProvider()
end
