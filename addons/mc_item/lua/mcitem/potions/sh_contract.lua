-- Shared contract for Minecraft Java 26.2 potion items and effects.
-- Runtime mutation stays in the server modules; this file only provides
-- identifiers, exact constants and extension-point dispatch.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

Potions.TickSeconds = 1 / 20
Potions.DrinkDurationTicks = 32
Potions.SplashHorizontalRange = 4
Potions.SplashVerticalRange = 2
Potions.SplashMinimumDurationTicks = 20
Potions.CloudRadius = 3
Potions.CloudWaitTicks = 10
Potions.CloudDurationTicks = 600
Potions.CloudRadiusOnUse = -0.5
Potions.CloudRadiusPerTick = -3 / 600
Potions.CloudApplyIntervalTicks = 5
Potions.CloudReapplicationDelayTicks = 20
Potions.CloudDurationScale = 0.25
Potions.CloudInstantPotency = 0.5
Potions.ProjectilePitchOffset = -20
Potions.ProjectilePower = 0.5
Potions.ProjectileUncertainty = 1
Potions.ProjectileGravity = 0.05
Potions.ProjectileInertia = 0.99

Potions.EntityTags = {
    INVERTED_HEALING_AND_HARM = "inverted_healing_and_harm",
    IGNORES_POISON_AND_REGEN = "ignores_poison_and_regen",
    IMMUNE_TO_INFESTED = "immune_to_infested",
    IMMUNE_TO_OOZING = "immune_to_oozing",
}

local function stripNamespace(identifier)
    if not isstring(identifier) then return nil end
    return string.gsub(identifier, "^minecraft:", "")
end

function Potions.NormalizeID(identifier)
    return stripNamespace(identifier)
end

function Potions.IsLivingTarget(entity)
    if not IsValid(entity) or entity == game.GetWorld() then return false end
    if entity.BMBDead then return false end
    if entity:IsPlayer() then return entity:Alive() end
    return entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true
end

function Potions.DefinitionForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if istable(weapon.MCPotionDefinition) then return weapon.MCPotionDefinition end
    local potionId = weapon.MCPotionID
    return Potions.Get and Potions.Get(potionId) or nil
end

function Potions.BottleTypeForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    local bottleType = weapon.MCPotionBottleType
    if not isstring(bottleType) or not Potions.BottleTypes[bottleType] then return nil end
    return bottleType
end

function Potions.ModelIDForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if isstring(weapon.MCPotionModelID) then return weapon.MCPotionModelID end
    local definition = Potions.DefinitionForWeapon(weapon)
    local bottleType = Potions.BottleTypeForWeapon(weapon)
    return definition and Potions.ModelID(bottleType, definition.id) or nil
end

function Potions.ColorRGB(color)
    color = math.max(0, math.floor(tonumber(color) or Potions.EmptyColor or 0))
    return bit.band(bit.rshift(color, 16), 255) / 255,
        bit.band(bit.rshift(color, 8), 255) / 255,
        bit.band(color, 255) / 255
end

function Potions.EffectDefinition(effectId)
    return Potions.Effects[stripNamespace(effectId) or ""]
end

local function methodDecision(entity, methodName, ...)
    if not IsValid(entity) or not isfunction(entity[methodName]) then return nil end
    return entity[methodName](entity, ...)
end

function Potions.CanReceiveEffect(target, effectId, source, context)
    if not Potions.IsLivingTarget(target) then return false end
    effectId = stripNamespace(effectId)
    if not Potions.EffectDefinition(effectId) then return false end

    local result = methodDecision(target, "CanReceiveMCPotionEffect", effectId, source, context)
    if result ~= nil then return result ~= false end

    result = hook.Run("MCITEM.CanReceivePotionEffect", target, effectId, source, context)
    if result ~= nil then return result ~= false end
    return true
end

function Potions.HasEntityTag(target, tag, context)
    if not IsValid(target) then return false end
    local result = methodDecision(target, "HasMCPotionEntityTag", tag, context)
    if result ~= nil then return result == true end

    result = hook.Run("MCITEM.HasPotionEntityTag", target, tag, context)
    if result ~= nil then return result == true end

    -- BMB's broad undead flag is the closest optional adapter to both vanilla
    -- entity tags.  No concrete NPC class names are guessed here.
    if target.IsUndead == true then
        return tag == Potions.EntityTags.INVERTED_HEALING_AND_HARM
            or tag == Potions.EntityTags.IGNORES_POISON_AND_REGEN
    end
    return false
end

function Potions.IsWaterSensitive(target, context)
    if not IsValid(target) then return false end
    local result = methodDecision(target, "IsMCPotionWaterSensitive", context)
    if result ~= nil then return result == true end
    result = hook.Run("MCITEM.IsWaterSensitive", target, context)
    return result == true
end

function Potions.CopyEffectSpec(effect)
    if not istable(effect) then return nil end
    local rawDuration = tonumber(effect.durationTicks) or 0
    local duration = rawDuration == -1 and -1 or math.max(0, math.floor(rawDuration))
    return {
        id = stripNamespace(effect.id),
        durationTicks = duration,
        amplifier = math.max(0, math.floor(tonumber(effect.amplifier) or 0)),
        ambient = effect.ambient == true,
        visible = effect.visible ~= false,
        showIcon = effect.showIcon ~= false,
    }
end

function Potions.IsInstantEffect(effectId)
    local definition = Potions.EffectDefinition(effectId)
    return definition and definition.instant == true or false
end

function Potions.IsWaterPotion(definition)
    return istable(definition) and definition.id == "water"
end
