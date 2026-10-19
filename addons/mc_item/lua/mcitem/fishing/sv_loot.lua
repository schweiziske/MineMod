-- Server-side evaluator for the exact Java 26.2 gameplay/fishing loot tables.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Fishing = MCITEM.Fishing or {}

local Fishing = MCITEM.Fishing
if (tonumber(Fishing.LootVersion) or 0) >= 2 then return Fishing end
Fishing.LootVersion = 2

local Generated = Fishing.Generated or include("mcitem/fishing/sh_generated_data.lua")

local function randomFloat(minimum, maximum)
    minimum, maximum = tonumber(minimum) or 0, tonumber(maximum) or 0
    if minimum == maximum then return minimum end
    return math.Rand(minimum, maximum)
end

local function weightedChoice(entries, weightFunction)
    local weighted, total = {}, 0
    for _, entry in ipairs(entries or {}) do
        local weight = math.max(0, math.floor(tonumber(weightFunction(entry)) or 0))
        if weight > 0 then
            total = total + weight
            weighted[#weighted + 1] = { entry = entry, ceiling = total }
        end
    end
    if total <= 0 then return nil end
    local roll = math.random(1, total)
    for _, candidate in ipairs(weighted) do
        if roll <= candidate.ceiling then return candidate.entry end
    end
    return weighted[#weighted] and weighted[#weighted].entry or nil
end

local function itemAllowedInBiome(entry, position, hookEntity)
    if not istable(entry.biomes) or #entry.biomes == 0 then return true end
    local biome = Fishing.IsJungleBiome(position, hookEntity)
    if not biome then return false end
    for _, allowed in ipairs(entry.biomes) do
        if biome == allowed then return true end
    end
    return false
end

local function enchantmentCost(cost, level)
    return math.floor((tonumber(cost.base) or 0) + (tonumber(cost.perLevel) or 0) * (level - 1))
end

local function availableEnchantments(stack, cost)
    local results = {}
    for identifier, definition in pairs(Generated.enchantments or {}) do
        if Fishing.EnchantmentSupportsItem(definition, stack.item) then
            for level = definition.maxLevel, 1, -1 do
                if cost >= enchantmentCost(definition.minCost, level)
                    and cost <= enchantmentCost(definition.maxCost, level)
                then
                    results[#results + 1] = {
                        id = identifier,
                        level = level,
                        weight = definition.weight,
                    }
                    break
                end
            end
        end
    end
    return results
end

local function filterCompatible(candidates, selected)
    local incompatible = Generated.incompatible[selected.id] or {}
    local output = {}
    for _, candidate in ipairs(candidates) do
        if candidate.id ~= selected.id and incompatible[candidate.id] ~= true then
            output[#output + 1] = candidate
        end
    end
    return output
end

local function selectEnchantments(stack, baseCost)
    local enchantability = math.max(0, math.floor(Generated.enchantability[stack.item] or 0))
    if enchantability <= 0 then return {} end

    local quarter = math.floor(enchantability / 4)
    local cost = math.floor(baseCost)
        + 1 + math.random(0, quarter) + math.random(0, quarter)
    local span = (math.Rand(0, 1) + math.Rand(0, 1) - 1) * 0.15
    cost = math.max(1, math.floor(cost + cost * span + 0.5))

    local candidates = availableEnchantments(stack, cost)
    local results = {}
    if #candidates == 0 then return results end

    local first = weightedChoice(candidates, function(entry) return entry.weight end)
    if not first then return results end
    results[#results + 1] = first

    while math.random(0, 49) <= cost do
        candidates = filterCompatible(candidates, results[#results])
        if #candidates == 0 then break end
        local selected = weightedChoice(candidates, function(entry) return entry.weight end)
        if not selected then break end
        results[#results + 1] = selected
        cost = math.floor(cost / 2)
    end
    return results
end

local function applyEnchantments(stack, cost)
    local selected = selectEnchantments(stack, cost)
    if #selected == 0 then return stack end
    local stored = stack.item == "minecraft:book"
    if stored then stack.item = "minecraft:enchanted_book" end
    local levels = {}
    for _, enchantment in ipairs(selected) do
        levels[enchantment.id] = enchantment.level
    end
    stack.components = istable(stack.components) and stack.components or {}
    stack.components[stored and "minecraft:stored_enchantments" or "minecraft:enchantments"] = {
        levels = levels,
        show_in_tooltip = true,
    }
    return stack
end

local function applyFunction(stack, definition)
    if definition.kind == "set_count" then
        stack.count = math.random(math.floor(definition.min), math.floor(definition.max))
        return stack
    end
    if definition.kind == "set_damage" then
        local maximum = Generated.maxDamage[stack.item]
        if not maximum or maximum <= 0 then return stack end
        local remainingFraction = 1 - math.Clamp(
            randomFloat(definition.min, definition.max), 0, 1)
        stack.damage = math.floor(remainingFraction * maximum)
        if stack.damage <= 0 then stack.damage = nil end
        return stack
    end
    if definition.kind == "set_potion" then
        stack.components = istable(stack.components) and stack.components or {}
        stack.components["minecraft:potion_contents"] = { potion = definition.id }
        return stack
    end
    if definition.kind == "enchant_with_levels" then
        return applyEnchantments(stack, randomFloat(definition.min, definition.max))
    end
    return stack
end

function Fishing.GenerateLoot(luck, openWater, position, hookEntity)
    -- Preserve provider luck fractions until each weighted entry is scored.
    -- The vanilla table rounds `weight + quality * luck` per entry, rather
    -- than rounding the aggregate luck attribute at the call boundary.
    luck = tonumber(luck) or 0
    local category = weightedChoice(Generated.main, function(entry)
        if entry.requiresOpenWater and openWater ~= true then return 0 end
        return math.max(math.floor(entry.weight + entry.quality * luck), 0)
    end)
    if not category then return {} end

    local entry = weightedChoice(Generated.tables[category.table], function(candidate)
        return itemAllowedInBiome(candidate, position, hookEntity) and candidate.weight or 0
    end)
    if not entry then return {} end
    local stack = { item = entry.item, count = 1 }
    for _, definition in ipairs(entry.functions or {}) do
        stack = applyFunction(stack, definition)
    end
    return { stack }
end

Fishing.SelectEnchantmentsForTest = selectEnchantments
Fishing.ApplyLootFunctionForTest = applyFunction

return Fishing
