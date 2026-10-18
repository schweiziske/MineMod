-- LevelEvent 2002/2007: 8 splash-potion item fragments and 100 effect particles.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local NET_BREAK = "MCITEM_PotionBreak"

local function gaussian()
    local u1 = math.max(math.Rand(0, 1), 1e-9)
    local u2 = math.Rand(0, 1)
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

function Potions.SpawnPotionBreak(position, potionId, color, instant)
    if not isvector(position) then return end
    local modelId = Potions.ModelID("splash", potionId)
    if not modelId then return end

    for _ = 1, 8 do
        Potions.SpawnItemFragment(position, modelId, Vector(
            gaussian() * 0.15,
            gaussian() * 0.15,
            math.Rand(0, 1) * 0.2
        ))
    end

    local baseR, baseG, baseB = Potions.ColorRGB(color)
    for _ = 1, 100 do
        local radius = math.Rand(0, 1) * 4
        local theta = math.Rand(0, 1) * math.pi * 2
        local cosTheta, sinTheta = math.cos(theta), math.sin(theta)
        local brightness = 0.75 + math.Rand(0, 1) * 0.25
        Potions.SpawnSpellParticle(
            position + Vector(cosTheta * radius * 0.1, sinTheta * radius * 0.1, 0.3) * MCITEM.BlockSize(),
            {
                family = instant and "spell" or "effect",
                inputX = cosTheta * radius,
                inputY = 0.01 + math.Rand(0, 1) * 0.5,
                inputZ = sinTheta * radius,
                power = radius,
                r = baseR * brightness,
                g = baseG * brightness,
                b = baseB * brightness,
            }
        )
    end
end

net.Receive(NET_BREAK, function()
    Potions.SpawnPotionBreak(
        net.ReadVector(),
        net.ReadString(),
        net.ReadUInt(24),
        net.ReadBool()
    )
end)
