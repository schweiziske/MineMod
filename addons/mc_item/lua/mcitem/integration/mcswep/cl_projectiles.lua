-- Client-only visual parity for MCSWEP's built-in mc_projectile entity.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.MCSWEP = MCITEM.MCSWEP or {}

local TICK_SECONDS = 1 / 20

local function emitSpectralParticle(position)
    local potions = MCITEM.Potions
    if not potions or not isfunction(potions.SpawnSpellParticle) then return end
    potions.SpawnSpellParticle(position, {
        family = "effect",
        inputX = 0,
        inputY = 0,
        inputZ = 0,
        power = 1,
        r = 1,
        g = 1,
        b = 1,
        alpha = 1,
    })
end

local nextTrailTick = CurTime() + TICK_SECONDS

hook.Remove("Think", "MCITEM.MCSWEP.SpectralArrowTrail")
hook.Add("Think", "MCITEM.MCSWEP.SpectralArrowTrail", function()
    local now = CurTime()
    if now < nextTrailTick then return end
    nextTrailTick = math.max(nextTrailTick + TICK_SECONDS, now)
    for _, projectile in ipairs(ents.FindByClass("mc_projectile")) do
        if projectile:GetProjectileItemName() == "minecraft:spectral_arrow" then
            emitSpectralParticle(projectile:GetPos())
        end
    end
end)
