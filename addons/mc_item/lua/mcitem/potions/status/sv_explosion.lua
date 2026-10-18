-- Wind Charged death adapter for the shared Java 26.2 explosion core.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local Explosions = MCITEM.Explosions
local NET_SPECIAL = "MCITEM_PotionSpecialFX"

util.AddNetworkString(NET_SPECIAL)

-- Compatibility names kept for integrations written against the first potion
-- implementation.  New code should call MCITEM.Explosions directly.
function Potions.ExplosionExposure(origin, target, context)
    local overridden = hook.Run("MCITEM.PotionExplosionExposure", origin, target, context)
    if isnumber(overridden) then return math.Clamp(overridden, 0, 1) end
    return Explosions.Exposure(origin, target, context)
end

function Potions.GetExplosionKnockbackResistance(target, context)
    return Explosions.GetKnockbackResistance(target, context)
end

local function broadcastWindFX(position)
    net.Start(NET_SPECIAL)
    net.WriteUInt(1, 3)
    net.WriteVector(position)
    net.SendPVS(position)
end

function Potions.TriggerWindChargedDeath(source)
    if not IsValid(source) then return false end
    local sourcePosition = source:GetPos()
    local minimum, maximum = source:WorldSpaceAABB()
    -- WindChargedMobEffect uses getX(), getY() + getBbHeight()/2, getZ().
    local position = Vector(sourcePosition.x, sourcePosition.y, (minimum.z + maximum.z) * 0.5)
    local strength = 3 + math.Rand(0, 1) * 2
    local context = {
        delivery = "wind_charged_death",
        source = source,
        position = position,
        strength = strength,
        damageHook = "MCITEM.PotionExplosionDamage",
        knockbackHook = "MCITEM.PotionExplosionKnockback",
    }

    if hook.Run("MCITEM.WindChargedExplosion", source, position, strength, context) ~= true then
        Explosions.Explode({
            position = position,
            strength = strength,
            source = source,
            attacker = source,
            inflictor = source,
            ignoreEntity = source,
            context = context,
            exposure = Potions.ExplosionExposure,
            ignore = function(target, explosionContext)
                return hook.Run("MCITEM.IgnorePotionExplosion", target, explosionContext) == true
            end,
        })
        broadcastWindFX(position)
        Potions.PlayWindChargedBurst(position)
    end
    return true
end
