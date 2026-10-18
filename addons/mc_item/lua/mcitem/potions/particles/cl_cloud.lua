-- Standard AreaEffectCloud ENTITY_EFFECT emission.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

function Potions.SpawnCloudParticles(cloud)
    if not IsValid(cloud) then return end
    local waiting = cloud:GetWaiting()
    local radius = math.max(0, cloud:GetCloudRadius())
    if waiting and math.random(0, 1) == 1 then return end

    local count = waiting and 2 or math.ceil(math.pi * radius * radius)
    local samplingRadius = waiting and 0.2 or radius
    local colorR, colorG, colorB = Potions.ColorRGB(cloud:GetPotionColor())
    for _ = 1, count do
        local theta = math.Rand(0, 1) * math.pi * 2
        local distance = math.sqrt(math.Rand(0, 1)) * samplingRadius
        local r, g, b = colorR, colorG, colorB
        if waiting and math.random(0, 1) == 1 then r, g, b = 1, 1, 1 end
        Potions.SpawnSpellParticle(
            cloud:GetPos() + Vector(math.cos(theta) * distance, math.sin(theta) * distance, 0) * MCITEM.BlockSize(),
            -- AreaEffectCloud.clientTick 用 addAlwaysVisibleParticle，是唯一绕开
            -- 32 格距离剔除的药水粒子来源。
            { family = "effect", inputX = 0, inputY = 0, inputZ = 0, r = r, g = g, b = b, alwaysVisible = true }
        )
    end
end
