-- Client-only visual parity for MineMod's built-in mc_projectile entity.

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

-- Track mc_projectile entities by creation/removal instead of scanning every
-- entity with ents.FindByClass at 20 Hz.
local PROJECTILE_CLASS = "mc_projectile"
MCITEM.MCSWEP.TrackedProjectiles = MCITEM.MCSWEP.TrackedProjectiles or {}
local trackedProjectiles = MCITEM.MCSWEP.TrackedProjectiles
for projectile in pairs(trackedProjectiles) do
    if not IsValid(projectile) then trackedProjectiles[projectile] = nil end
end
for _, projectile in ipairs(ents.FindByClass(PROJECTILE_CLASS)) do trackedProjectiles[projectile] = true end

hook.Add("OnEntityCreated", "MCITEM.MCSWEP.TrackProjectiles", function(entity)
    if IsValid(entity) and entity:GetClass() == PROJECTILE_CLASS then trackedProjectiles[entity] = true end
end)
hook.Add("EntityRemoved", "MCITEM.MCSWEP.TrackProjectiles", function(entity, fullUpdate)
    -- A full update keeps the same client entity alive.
    if fullUpdate then return end
    trackedProjectiles[entity] = nil
end)

hook.Remove("Think", "MCITEM.MCSWEP.SpectralArrowTrail")
hook.Add("Think", "MCITEM.MCSWEP.SpectralArrowTrail", function()
    local now = CurTime()
    if now < nextTrailTick then return end
    nextTrailTick = math.max(nextTrailTick + TICK_SECONDS, now)
    for projectile in pairs(trackedProjectiles) do
        if IsValid(projectile) and projectile.GetProjectileItemName
            and projectile:GetProjectileItemName() == "minecraft:spectral_arrow" then
            emitSpectralParticle(projectile:GetPos())
        end
    end
end)
