-- Pure attribute queries derived from active Java 26.2 MobEffectInstances.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

local function amplifier(entity, effectId)
    if not isfunction(Potions.GetEffect) then return nil end
    local effect = Potions.GetEffect(entity, effectId)
    return effect and math.max(0, math.floor(tonumber(effect.amplifier) or 0)) or nil
end

function Potions.GetMovementMultiplier(entity)
    -- Both modifiers are ADD_MULTIPLIED_TOTAL on MOVEMENT_SPEED, so they add
    -- against the base value rather than multiplying each other.
    local total = 1
    local speed = amplifier(entity, "speed")
    local slowness = amplifier(entity, "slowness")
    if speed then total = total + 0.2 * (speed + 1) end
    if slowness then total = total - 0.15 * (slowness + 1) end
    return math.max(0, total)
end

function Potions.GetAttackDamageBonus(entity)
    local total = 0
    local strength = amplifier(entity, "strength")
    local weakness = amplifier(entity, "weakness")
    if strength then total = total + 3 * (strength + 1) end
    if weakness then total = total - 4 * (weakness + 1) end
    return total
end

function Potions.GetResistanceMultiplier(entity)
    local resistance = amplifier(entity, "resistance")
    if not resistance then return 1 end
    return math.max(0, (25 - 5 * (resistance + 1)) / 25)
end

function Potions.GetJumpBoostPower(entity)
    local jumpBoost = amplifier(entity, "jump_boost")
    if not jumpBoost then return 0 end
    return 0.1 * (jumpBoost + 1)
end
