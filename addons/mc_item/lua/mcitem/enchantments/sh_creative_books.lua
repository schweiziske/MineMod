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

local function enchantmentId( value )
    local id = tostring( value or "" )
    if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
    return id
end

-- Names follow Minecraft's keys (enchantment.<namespace>.<path>,
-- enchantment.level.<n>); locale defaults to this realm's language.
function MCITEM.EnchantmentDisplayName( id, locale )
    id = enchantmentId( id )
    local key = MC.I18n.ContentKey( "enchantment", id )
    return key and MC.I18n.Resolve( key, nil, locale ) or id
end

function MCITEM.EnchantmentLevelName( id, level, locale )
    id = enchantmentId( id )
    local name = MCITEM.EnchantmentDisplayName( id, locale )
    local definition = MC.Enchantments and MC.Enchantments[id] or nil
    level = math.max( 1, math.floor( tonumber( level ) or 1 ) )
    -- Enchantment.getFullname omits "I" only when level == 1 and the
    -- enchantment itself has a single maximum level.
    if level == 1 and tonumber( definition and definition.maxLevel ) == 1 then return name end
    -- Minecraft only names levels 1-10; higher levels use plain numerals.
    local levelText = level <= 10 and MC.I18n.Resolve( "enchantment.level." .. level, nil, locale ) or romanLevel( level )
    return name .. " " .. levelText
end

function MCITEM.IsCurseEnchantment( enchantmentId )
    local id = tostring( enchantmentId or "")
    if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
    return CURSES[id] == true
end

function MCITEM.OrderedEnchantmentIds( levels )
    return orderedLevelIds( type( levels ) == "table" and levels or {} )
end

function MCITEM.EnchantedBookDisplayName( stack, locale )
    if type( stack ) ~= "table" or stack.item ~= BOOK_ITEM then return nil end
    local levels = storedLevels( stack )
    if next( levels ) == nil then return nil end
    local descriptions = {}
    for _, id in ipairs( orderedLevelIds( levels ) ) do
        descriptions[#descriptions + 1] = MCITEM.EnchantmentLevelName( id, levels[id], locale )
    end
    return MC.I18n.Resolve( "mcitem.enchanted_book.name", {
        book = MC.ItemDisplayName( BOOK_ITEM, locale ),
        enchantments = table.concat( descriptions, MC.I18n.Resolve( "mcitem.list_separator", nil, locale ) ),
    }, locale )
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
