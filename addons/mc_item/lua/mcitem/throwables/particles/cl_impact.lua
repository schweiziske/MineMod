-- One-shot impact and LevelEvent 2002/2003 particle ports.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
local NET_FX = "MCITEM_ThrowableFX"

local function gaussian()
    local first = math.max(math.Rand(0, 1), 1e-9)
    local second = math.Rand(0, 1)
    return math.sqrt(-2 * math.log(first)) * math.cos(2 * math.pi * second)
end

local function spawnSnowball(position)
    for _ = 1, 8 do Throwables.SpawnItemFragment(position, "snowball", vector_origin) end
end

local function spawnEgg(position)
    for _ = 1, 8 do
        Throwables.SpawnItemFragment(position, "egg", Vector(
            (math.Rand(0, 1) - 0.5) * 0.08,
            (math.Rand(0, 1) - 0.5) * 0.08,
            (math.Rand(0, 1) - 0.5) * 0.08
        ))
    end
end

local function spawnPearl(position)
    for _ = 1, 32 do
        Throwables.SpawnPortal(
            position + Vector(0, 0, math.Rand(0, 1) * 2 * MCITEM.BlockSize()),
            Vector(gaussian(), gaussian(), 0)
        )
    end
end

local function spawnExperienceBottle(position)
    for _ = 1, 8 do
        Throwables.SpawnItemFragment(position, "splash_potion_water", Vector(
            gaussian() * 0.15,
            gaussian() * 0.15,
            math.Rand(0, 1) * 0.2
        ))
    end

    local color = Throwables.ExperienceBottleColor
    local red = bit.band(bit.rshift(color, 16), 0xFF) / 255
    local green = bit.band(bit.rshift(color, 8), 0xFF) / 255
    local blue = bit.band(color, 0xFF) / 255
    for _ = 1, 100 do
        local radius = math.Rand(0, 1) * 4
        local angle = math.Rand(0, 1) * math.pi * 2
        local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
        local brightness = 0.75 + math.Rand(0, 1) * 0.25
        Throwables.SpawnEffect(
            position + Vector(cosAngle * radius * 0.1, sinAngle * radius * 0.1, 0.3) * MCITEM.BlockSize(),
            {
                inputX = cosAngle * radius,
                inputY = 0.01 + math.Rand(0, 1) * 0.5,
                inputZ = sinAngle * radius,
                power = radius,
                r = red * brightness,
                g = green * brightness,
                b = blue * brightness,
            }
        )
    end
end

local function spawnWindCharge(position)
    if isfunction(Throwables.SpawnWindChargeEmitter) then
        Throwables.SpawnWindChargeEmitter(position)
        return
    end

    -- Auto-refresh can load this receiver one frame before the versioned
    -- particle core.  Preserve the impact instead of calling a missing API.
    local spawnGust = isfunction(Throwables.SpawnGust)
        and Throwables.SpawnGust
        or Throwables.SpawnSmallGust
    if not isfunction(spawnGust) then return end
    for _ = 1, 3 do
        local offset = Vector(
            math.Rand(0, 1) - math.Rand(0, 1),
            math.Rand(0, 1) - math.Rand(0, 1),
            math.Rand(0, 1) - math.Rand(0, 1)
        ) * MCITEM.BlockSize()
        spawnGust(position + offset)
    end
end

local function spawnWindBurst(position)
    if isfunction(Throwables.SpawnWindBurstEmitter) then
        Throwables.SpawnWindBurstEmitter(position)
        return
    end
    if not isfunction(Throwables.SpawnGust) then return end
    -- Auto-refresh fallback for the packet-selected large provider:
    -- Provider(3.0, 7, 0) creates 21 regular, full-size GUST particles.
    for _ = 1, 21 do
        local offset = Vector(
            math.Rand(0, 1) - math.Rand(0, 1),
            math.Rand(0, 1) - math.Rand(0, 1),
            math.Rand(0, 1) - math.Rand(0, 1)
        ) * (3 * MCITEM.BlockSize())
        Throwables.SpawnGust(position + offset)
    end
end

local function spawnEnderEyeDeath(position)
    for _ = 1, 8 do
        Throwables.SpawnItemFragment(position, "ender_eye", Vector(
            gaussian() * 0.15,
            gaussian() * 0.15,
            math.Rand(0, 1) * 0.2
        ))
    end
    local angle = 0
    while angle < math.pi * 2 do
        local cosAngle, sinAngle = math.cos(angle), math.sin(angle)
        local origin = position + Vector(cosAngle * 5, sinAngle * 5, -0.4) * MCITEM.BlockSize()
        Throwables.SpawnPortal(origin, Vector(cosAngle * -5, sinAngle * -5, 0))
        Throwables.SpawnPortal(origin, Vector(cosAngle * -7, sinAngle * -7, 0))
        angle = angle + math.pi / 20
    end
end

net.Receive(NET_FX, function()
    local kind = net.ReadUInt(4)
    local position = net.ReadVector()
    net.ReadVector() -- reserved for impact-direction extensions
    if kind == Throwables.FX.SNOWBALL then
        spawnSnowball(position)
    elseif kind == Throwables.FX.EGG then
        spawnEgg(position)
    elseif kind == Throwables.FX.ENDER_PEARL then
        spawnPearl(position)
    elseif kind == Throwables.FX.EXPERIENCE_BOTTLE then
        spawnExperienceBottle(position)
    elseif kind == Throwables.FX.WIND_CHARGE then
        spawnWindCharge(position)
    elseif kind == Throwables.FX.WIND_BURST then
        spawnWindBurst(position)
    elseif kind == Throwables.FX.ENDER_EYE_DEATH then
        spawnEnderEyeDeath(position)
    end
end)
