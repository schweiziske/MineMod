-- Entity-driven per-tick Bubble and Eye-of-Ender Portal trails.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

function Throwables.UpdateProjectileTrail(projectile)
    if not IsValid(projectile) then return end
    local tick = projectile:GetMCProjectileTick()
    local previous = tonumber(projectile.MCLastTrailTick) or tick
    if tick <= previous then return end
    projectile.MCLastTrailTick = tick
    if not projectile:GetMCInWater() then return end
    local repetitions = math.min(8, tick - previous)
    for _ = 1, repetitions do
        for _ = 1, 4 do
            Throwables.SpawnBubble(projectile:GetMCBubblePosition(), projectile:GetMCBubbleVelocity())
        end
    end
end

function Throwables.UpdateEnderEyeTrail(eye)
    if not IsValid(eye) then return end
    local tick = eye:GetMCEyeTick()
    local previous = tonumber(eye.MCLastEyeTrailTick) or tick
    if tick <= previous then return end
    eye.MCLastEyeTrailTick = tick
    local repetitions = math.min(8, tick - previous)
    local velocity = eye:GetMCEyeVelocity()
    local position = eye:GetPos() - velocity * (0.25 * MCITEM.BlockSize())
    for _ = 1, repetitions do
        if eye:GetMCEyeInWater() then
            for _ = 1, 4 do Throwables.SpawnBubble(position, velocity) end
        else
            Throwables.SpawnPortal(
                position + Vector(
                    math.Rand(0, 1) * 0.6 - 0.3,
                    math.Rand(0, 1) * 0.6 - 0.3,
                    -0.5
                ) * MCITEM.BlockSize(),
                velocity
            )
        end
    end
end
