-- Pure selected-stack -> MCITEM SWEP resolution for the generic MineMod bridge.

MCITEM = MCITEM or {}
MCITEM.MCSWEP = MCITEM.MCSWEP or {}

local Integration = MCITEM.MCSWEP

local POTION_BOTTLES = {
    ["minecraft:potion"] = "drinkable",
    ["minecraft:splash_potion"] = "splash",
    ["minecraft:lingering_potion"] = "lingering",
}

local POTION_CONTENT_FIELDS = {
    potion = true,
    custom_color = true,
    custom_effects = true,
    custom_name = true,
}

local function minecraftPath(identifier)
    if not isstring(identifier) or identifier == "" then return nil end
    local namespace, path = string.match(identifier, "^([^:]+):(.+)$")
    if namespace and namespace ~= "minecraft" then return nil end
    path = path or identifier
    if not string.match(path, "^[a-z0-9_]+$") then return nil end
    return path
end

local function component(components, key)
    if not istable(components) then return nil end
    local value = components["minecraft:" .. key]
    if value == nil then value = components[key] end
    return value
end

local function hasUnsupportedPotionContents(contents)
    if not istable(contents) then return false end
    for key in pairs(contents) do
        if not POTION_CONTENT_FIELDS[key] then return true end
    end
    if contents.custom_color ~= nil or contents.custom_name ~= nil then return true end
    if contents.custom_effects ~= nil then
        if not istable(contents.custom_effects) or next(contents.custom_effects) ~= nil then return true end
    end
    return false
end

function Integration.BasePotionID(stack)
    if not istable(stack) then return nil end
    local contents = component(stack.components, "potion_contents")
    -- PotionItem#getDefaultInstance installs Potions.WATER. MineMod's compact
    -- generated registry does not serialize default components, so absence is
    -- the default water bottle; an explicitly present empty component is not.
    if contents == nil then return "water" end
    if isstring(contents) then return minecraftPath(contents) end
    if not istable(contents) or hasUnsupportedPotionContents(contents) then return nil end
    return minecraftPath(contents.potion)
end

local function storedWeapon(className)
    return weapons and weapons.GetStored and weapons.GetStored(className) or nil
end

local function potionWeaponClass(stack, bottleType)
    local potionId = Integration.BasePotionID(stack)
    local potions = MCITEM.Potions
    local definition = potionId and potions and potions.Get and potions.Get(potionId) or nil
    local className = definition and potions.WeaponClass and potions.WeaponClass(bottleType, definition.id) or nil
    local stored = className and storedWeapon(className) or nil
    if not stored or stored.MCPotionID ~= definition.id or stored.MCPotionBottleType ~= bottleType then return nil end
    return className
end

function Integration.ResolveWeaponClass(stack)
    if not istable(stack) or not isstring(stack.item) then return nil end
    local bottleType = POTION_BOTTLES[stack.item]
    if bottleType then return potionWeaponClass(stack, bottleType) end

    local itemId = minecraftPath(stack.item)
    if not itemId then return nil end
    local className = "weapon_mcitem_" .. itemId
    local stored = storedWeapon(className)
    if not stored or stored.MCItemID ~= itemId then return nil end
    return className
end
