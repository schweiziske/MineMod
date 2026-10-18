-- Minecraft Java 26.2 ItemStack.hasFoil semantics shared by standalone MCITEM
-- SWEPs and the optional MCSWEP inventory bridge.

MCITEM = MCITEM or {}

local DEFAULT_FOIL_ITEMS = {
    enchanted_golden_apple = true,
    experience_bottle = true,
    written_book = true,
    nether_star = true,
    enchanted_book = true,
    end_crystal = true,
    debug_stick = true,
}

local function minecraftPath(identifier)
    identifier = tostring(identifier or "")
    local namespace, path = string.match(identifier, "^([^:]+):(.+)$")
    if namespace and namespace ~= "minecraft" then return nil end
    return path or identifier
end

local function componentPresence(stack, key)
    local components = istable(stack) and stack.components or nil
    if not istable(components) then return nil, false end
    if components[key] ~= nil then return components[key], true end
    local namespaced = "minecraft:" .. key
    if components[namespaced] ~= nil then return components[namespaced], true end
    return nil, false
end

local function containsPositiveEnchantment(value)
    if isnumber(value) then return value > 0 end
    if not istable(value) then return false end
    local direct = tonumber(value.level or value.lvl)
    if direct then return direct > 0 end
    for key, entry in pairs(value) do
        if key ~= "show_in_tooltip" and key ~= "showInTooltip" and containsPositiveEnchantment(entry) then
            return true
        end
    end
    return false
end

function MCITEM.ItemStackHasFoil(stack)
    if not istable(stack) then return false end
    local override, hasOverride = componentPresence(stack, "enchantment_glint_override")
    if hasOverride and isbool(override) then return override end

    local enchantments = select(1, componentPresence(stack, "enchantments"))
    if istable(enchantments) then
        local levels = istable(enchantments.levels) and enchantments.levels or enchantments
        if containsPositiveEnchantment(levels) then return true end
    end

    local itemId = minecraftPath(stack.item or stack.id)
    if DEFAULT_FOIL_ITEMS[itemId] then return true end
    if itemId == "compass" then
        local _, hasLodestoneTracker = componentPresence(stack, "lodestone_tracker")
        if hasLodestoneTracker then return true end
    end
    return false
end

function MCITEM.StackForWeaponFoil(weapon)
    if not IsValid(weapon) and not istable(weapon) then return nil end
    local owner = weapon.GetOwner and weapon:GetOwner() or nil
    local inventoryProxy = weapon.MCHandWeaponBridgeProxy == true
    if weapon.GetNW2Bool and weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then inventoryProxy = true end
    if CLIENT and inventoryProxy and IsValid(owner) and owner == LocalPlayer() and MC and MC.ClientInventory then
        local selected = math.Clamp(math.floor(tonumber(MC.ClientInventory.selected) or 0), 0, 8)
        local stack = MC.ClientInventory.slots and MC.ClientInventory.slots[selected + 1] or nil
        if istable(stack) then return stack end
    end
    local itemId = weapon.MCItemID
    if not isstring(itemId) or itemId == "" then return nil end
    local foil = inventoryProxy and weapon.GetNW2Bool and weapon:GetNW2Bool("MCITEM_ItemFoil", false) or nil
    return {
        item = "minecraft:" .. itemId,
        count = 1,
        -- A proxy weapon is backed by one authoritative MCSWEP ItemStack.  Its
        -- explicit false must suppress MCITEM's item-ID fallback just like the
        -- Java component would.  Spawnmenu SWEPs have no proxy flag and keep
        -- the vanilla defaults (notably the enchanted golden apple/bottle o'
        -- enchanting).
        components = foil ~= nil and { ["minecraft:enchantment_glint_override"] = foil } or nil,
    }
end

function MCITEM.WeaponHasFoil(weapon)
    return MCITEM.ItemStackHasFoil(MCITEM.StackForWeaponFoil(weapon))
end
