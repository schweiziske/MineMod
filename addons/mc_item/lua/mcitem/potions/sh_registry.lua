-- Data-driven SWEP registration for every Java 26.2 potion and bottle form.
-- Behaviour stays in the three weapon base classes; this file only maps data
-- to public spawn-menu entries.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

Potions.WeaponCategory = "Minecraft in GMod - Potions"

local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

local BOTTLES = {
    drinkable = {
        classPrefix = "weapon_mcitem_potion_",
        base = "weapon_mcitem_potion_drinkable",
        instruction = "Left click: attack or mine. Hold right click: drink.",
    },
    splash = {
        classPrefix = "weapon_mcitem_splash_potion_",
        base = "weapon_mcitem_potion_throwable",
        instruction = "Left click: attack or mine. Right click: throw.",
    },
    lingering = {
        classPrefix = "weapon_mcitem_lingering_potion_",
        base = "weapon_mcitem_potion_throwable",
        instruction = "Left click: attack or mine. Right click: throw.",
    },
}

local function bottleDisplayName(bottleType, definition)
    local name = definition.name or definition.id
    if bottleType == "drinkable" then return name end

    local prefix = bottleType == "splash" and "Splash" or "Lingering"
    if definition.id == "water" then return prefix .. " Water Bottle" end

    -- en_us.json uses "Awkward Splash Potion" / "Awkward Lingering
    -- Potion" (and the same ordering for Mundane/Thick), while effect-bearing
    -- bottles use "Splash/Lingering Potion of ...".
    if definition.id == "awkward" or definition.id == "mundane" or definition.id == "thick" then
        return string.gsub(name, " Potion$", " " .. prefix .. " Potion")
    end
    if string.StartWith(name, "Potion ") then
        return prefix .. " " .. name
    end
    return prefix .. " " .. name
end

local function formatTickDuration(ticks)
    ticks = math.max(0, math.floor(tonumber(ticks) or 0))
    local seconds = math.floor(ticks / 20)
    local minutes = math.floor(seconds / 60)
    seconds = seconds % 60
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if hours > 0 then return string.format("%02d:%02d:%02d", hours, minutes, seconds) end
    return string.format("%02d:%02d", minutes, seconds)
end

local function effectDescription(effect)
    local definition = Potions.EffectDefinition and Potions.EffectDefinition(effect.id) or nil
    local name = definition and definition.name or tostring(effect.id or "Unknown Effect")
    local amplifier = math.max(0, math.floor(tonumber(effect.amplifier) or 0))
    if amplifier >= 1 and amplifier <= 9 then name = name .. " " .. ROMAN[amplifier + 1] end
    if definition and definition.instant == true then return name .. " (Instant)" end
    local duration = tonumber(effect.durationTicks) or 0
    if duration == -1 then return name .. " (Infinite)" end
    -- Java PotionContents.addPotionTooltip omits a duration when the effect
    -- ends within 20 ticks; instant effects therefore never become "00:00".
    if duration <= 20 then return name end
    return name .. " (" .. formatTickDuration(duration) .. ")"
end

function Potions.FormatEffectSummary(definition)
    if not istable(definition) or not istable(definition.effects) or #definition.effects == 0 then
        return "No Effects"
    end
    local summaries = {}
    for _, effect in ipairs(definition.effects) do summaries[#summaries + 1] = effectDescription(effect) end
    return table.concat(summaries, "; ")
end

function Potions.WeaponDisplayName(bottleType, definition)
    if not BOTTLES[bottleType] or not istable(definition) then return nil end
    local name = "Minecraft " .. bottleDisplayName(bottleType, definition)
    if istable(definition.effects) and #definition.effects > 0 then
        name = name .. " | " .. Potions.FormatEffectSummary(definition)
    end
    return name
end

function Potions.WeaponInstructions(bottleType, definition)
    local bottle = BOTTLES[bottleType]
    if not bottle or not istable(definition) then return nil end
    return bottle.instruction .. " Effects: " .. Potions.FormatEffectSummary(definition)
end

function Potions.WeaponClass(bottleType, potionId)
    local bottle = BOTTLES[bottleType]
    local definition = Potions.Get(potionId)
    if not bottle or not definition then return nil end
    return bottle.classPrefix .. definition.id
end

function Potions.RegisterWeapons()
    if not istable(Potions.Definitions) then return 0 end

    local count = 0
    for bottleType, bottle in pairs(BOTTLES) do
        for _, definition in ipairs(Potions.Definitions) do
            local modelId = Potions.ModelID(bottleType, definition.id)
            local className = Potions.WeaponClass(bottleType, definition.id)
            weapons.Register({
                Base = bottle.base,
                PrintName = Potions.WeaponDisplayName(bottleType, definition),
                Category = Potions.WeaponCategory,
                Instructions = Potions.WeaponInstructions(bottleType, definition),
                Spawnable = true,
                AdminOnly = false,
                WorldModel = "models/mcgm/" .. modelId .. "/" .. modelId .. ".mdl",

                MCItemID = modelId,
                MCPotionID = definition.id,
                MCPotionBottleType = bottleType,
                MCPotionDefinition = definition,
                MCPotionModelID = modelId,
                MCAttackDamage = 1,
                MCAttackSpeed = 4,
                MCAttackKnockback = 0,
                MCIsSword = false,
                MCSwingDurationTicks = 6,
            }, className)
            count = count + 1
        end
    end
    return count
end

Potions.RegisteredWeaponCount = Potions.RegisterWeapons()
