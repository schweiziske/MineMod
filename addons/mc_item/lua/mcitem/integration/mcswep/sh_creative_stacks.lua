-- Java 26.2 dynamically appends one complete ItemStack per registered potion
-- to Food & Drinks, in drinkable -> splash -> lingering order.  Search receives
-- those same PARENT_AND_SEARCH_TABS entries.  The generated MCSWEP tab file can
-- only carry plain item IDs, so MCITEM supplies the missing component-bearing
-- stacks through the public creative-stack provider API.

MCITEM = MCITEM or {}
MCITEM.MCSWEP = MCITEM.MCSWEP or {}

local Integration = MCITEM.MCSWEP
local PROVIDER_ID = "mcitem:java_26_2_potions"
local POTION_ITEMS = {
    "minecraft:potion",
    "minecraft:splash_potion",
    "minecraft:lingering_potion",
}

local function isPotionBottle(stack)
    if not istable(stack) then return false end
    for _, itemId in ipairs(POTION_ITEMS) do
        if stack.item == itemId then return true end
    end
    return false
end

local function potionStacks()
    local result = {}
    local definitions = MCITEM.Potions and MCITEM.Potions.Definitions or nil
    if not istable(definitions) then return result end
    for _, itemId in ipairs(POTION_ITEMS) do
        for _, definition in ipairs(definitions) do
            if istable(definition) and isstring(definition.id) and definition.id ~= "" then
                result[#result + 1] = {
                    item = itemId,
                    count = 1,
                    components = {
                        ["minecraft:potion_contents"] = {
                            potion = "minecraft:" .. definition.id,
                        },
                    },
                }
            end
        end
    end
    return result
end

function Integration.ProvideCreativeStacks(tabKey, stacks)
    if tabKey ~= "food_and_drinks" and tabKey ~= "search" then return stacks end
    local result = {}
    for _, stack in ipairs(stacks or {}) do
        -- Java's generated potion stacks replace the three generic no-component
        -- placeholders in the Search tab.  Keeping both would duplicate water.
        if not isPotionBottle(stack) then result[#result + 1] = stack end
    end
    for _, stack in ipairs(potionStacks()) do result[#result + 1] = stack end
    return result
end

function Integration.RegisterCreativeStackProvider()
    local creative = MC and MC.API and MC.API.CreativeStacks
    if not creative or not isfunction(creative.RegisterProvider) then return false end
    local ok = creative.RegisterProvider(PROVIDER_ID, Integration.ProvideCreativeStacks, 100)
    Integration.CreativeStackProviderRegistered = ok == true
    return ok == true
end

hook.Add("MC.CreativeStacksAPIReady", "MCITEM.MCSWEP.RegisterCreativeStacks", function()
    Integration.RegisterCreativeStackProvider()
end)

-- Replay the game-layer readiness marker when MCSWEP loaded before MCITEM.
if MC and MC.CreativeStacksAPIReady == true then Integration.RegisterCreativeStackProvider() end

-- Autorefresh does not replay either addon's loader lifecycle.
hook.Add("OnReloaded", "MCITEM.MCSWEP.RegisterCreativeStacksReload", function()
    Integration.RegisterCreativeStackProvider()
end)
