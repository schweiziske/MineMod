-- Client visuals for special server-side potion events.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local NET_SPECIAL = "MCITEM_PotionSpecialFX"
local emitters = {}

local function spawnLargeEmitter(position)
    emitters[#emitters + 1] = {
        position = Vector(position.x, position.y, position.z),
        age = 0,
        nextTickAt = CurTime() + Potions.TickSeconds,
    }
end

net.Receive(NET_SPECIAL, function()
    local kind = net.ReadUInt(3)
    local position = net.ReadVector()
    if kind ~= 1 then return end
    spawnLargeEmitter(position)
end)

hook.Remove("Think", "MCITEM.Potions.SpecialEmitterThink")
hook.Add("Think", "MCITEM.Potions.SpecialEmitterThink", function()
    local now = CurTime()
    for index = #emitters, 1, -1 do
        local emitter = emitters[index]
        local catchup = 0
        -- ParticleTypes.GUST_EMITTER_LARGE = Provider(3.0, 7, 0): on every
        -- one of seven ticks it creates exactly three GUST particles.
        while emitter.age < 7 and now >= emitter.nextTickAt and catchup < 8 do
            for _ = 1, 3 do
                local offset = Vector(
                    math.Rand(0, 1) - math.Rand(0, 1),
                    math.Rand(0, 1) - math.Rand(0, 1),
                    math.Rand(0, 1) - math.Rand(0, 1)
                ) * (3 * MCITEM.BlockSize())
                Potions.SpawnGust(emitter.position + offset)
            end
            emitter.age = emitter.age + 1
            emitter.nextTickAt = emitter.nextTickAt + Potions.TickSeconds
            catchup = catchup + 1
        end
        if emitter.age >= 7 then table.remove(emitters, index) end
    end
end)
