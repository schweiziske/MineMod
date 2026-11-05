-- Data-driven SWEP registration for every Java 26.2 potion and bottle form.
-- Behaviour stays in the three weapon base classes; this file only maps data
-- to public spawn-menu entries.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

Potions.WeaponCategory = "#mcitem.category.potions"

local BOTTLES = {
    drinkable = {
        classPrefix = "weapon_mcitem_potion_",
        base = "weapon_mcitem_potion_drinkable",
        instructionKey = "mcitem.instructions.potion_drink",
        item = "potion",
    },
    splash = {
        classPrefix = "weapon_mcitem_splash_potion_",
        base = "weapon_mcitem_potion_throwable",
        instructionKey = "mcitem.instructions.potion_throw",
        item = "splash_potion",
    },
    lingering = {
        classPrefix = "weapon_mcitem_lingering_potion_",
        base = "weapon_mcitem_potion_throwable",
        instructionKey = "mcitem.instructions.potion_throw",
        item = "lingering_potion",
    },
}

local function bottleDisplayName(bottleType, definition, locale)
    return MC.T("item.minecraft." .. BOTTLES[bottleType].item .. ".effect." .. definition.baseName, nil, locale)
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

local function effectDescription(effect, locale)
    local definition = Potions.EffectDefinition and Potions.EffectDefinition(effect.id) or nil
    local name = MC.T("effect.minecraft." .. effect.id:gsub("^minecraft:", ""), nil, locale)
    local amplifier = math.max(0, math.floor(tonumber(effect.amplifier) or 0))
    if amplifier >= 1 then
        name = MC.T("potion.withAmplifier", { name, MC.T("enchantment.level." .. (amplifier + 1), nil, locale) }, locale)
    end
    if definition and definition.instant == true then return MC.T("mcitem.potion.instant", { effect = name }, locale) end
    local duration = tonumber(effect.durationTicks) or 0
    if duration == -1 then return MC.T("potion.withDuration", { name, MC.T("effect.duration.infinite", nil, locale) }, locale) end
    -- Java PotionContents.addPotionTooltip omits a duration when the effect
    -- ends within 20 ticks; instant effects therefore never become "00:00".
    if duration <= 20 then return name end
    return MC.T("potion.withDuration", { name, formatTickDuration(duration) }, locale)
end

function Potions.FormatEffectSummary(definition, locale)
    if not istable(definition) or not istable(definition.effects) or #definition.effects == 0 then
        return MC.T("effect.none", nil, locale)
    end
    local summaries = {}
    for _, effect in ipairs(definition.effects) do summaries[#summaries + 1] = effectDescription(effect, locale) end
    return table.concat(summaries, MC.T("mcitem.potion.separator", nil, locale))
end

function Potions.WeaponDisplayName(bottleType, definition, locale)
    if not BOTTLES[bottleType] or not istable(definition) then return nil end
    local name = bottleDisplayName(bottleType, definition, locale)
    if istable(definition.effects) and #definition.effects > 0 then
        name = MC.T("mcitem.potion.name_with_effects", { name = name, effects = Potions.FormatEffectSummary(definition, locale) }, locale)
    end
    return name
end

function Potions.WeaponInstructions(bottleType, definition, locale)
    local bottle = BOTTLES[bottleType]
    if not bottle or not istable(definition) then return nil end
    return MC.T("mcitem.potion.instructions", {
        action = MC.T(bottle.instructionKey, nil, locale),
        effects = Potions.FormatEffectSummary(definition, locale),
    }, locale)
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
                PrintName = "#mcitem.potion." .. bottleType .. "." .. definition.id,
                Category = Potions.WeaponCategory,
                MCInstructionsKey = bottle.instructionKey,
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
