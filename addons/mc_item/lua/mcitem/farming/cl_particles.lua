-- Minecraft Java 26.2 BoneMealItem level event 1505.
--
-- HAPPY_VILLAGER is a single opaque glint sprite. SuspendedTownParticle does
-- not fade, spin, shrink, accelerate upward, or animate through texture frames:
-- it advances at 20 Hz, moves by its tiny initial velocity, applies 0.99 drag,
-- and lives for floor(20 / (random * 0.8 + 0.2)) ticks.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Farming = MCITEM.Farming or {}

local Farming = MCITEM.Farming
local NET_GROWTH = "MCITEM_FarmingGrowthParticles"
local NET_USE_SWING = "MCITEM_FarmingUseSwing"
local MATERIAL_NAME = "mcitem/farming/happy_villager"
local MATERIAL = nil
local NEXT_MATERIAL_RETRY = 0
local TICK_SECONDS = 1 / 20
local DRAG = 0.99
local MAX_CATCHUP_TICKS = 8
local LIGHT_GAIN = 0.60
local BONEMEAL_SOUND_LEVEL = 75
local BONEMEAL_SOUND_VOLUME = 1
local BONEMEAL_SOUNDS = {
    "mcitem/farming/bonemeal1.ogg",
    "mcitem/farming/bonemeal2.ogg",
    "mcitem/farming/bonemeal3.ogg",
    "mcitem/farming/bonemeal4.ogg",
    "mcitem/farming/bonemeal5.ogg",
}
local BONEMEAL_PITCHES = { 90, 100, 110 }

Farming.GrowthParticles = Farming.GrowthParticles or {}

if isfunction(MCITEM.RegisterParticlePool) then
    MCITEM.RegisterParticlePool("farming_growth", Farming.GrowthParticles)
end

local BONEMEAL_PARTICLE_BLOCKS = {
    ["minecraft:wheat"] = true,
    ["minecraft:carrots"] = true,
    ["minecraft:potatoes"] = true,
    ["minecraft:beetroots"] = true,
    ["minecraft:melon_stem"] = true,
    ["minecraft:pumpkin_stem"] = true,
    ["minecraft:sweet_berry_bush"] = true,
    ["minecraft:torchflower_crop"] = true,
    ["minecraft:pitcher_crop"] = true,
}

local SIMPLE_AGE_HEIGHT_BLOCKS = {
    ["minecraft:wheat"] = true,
    ["minecraft:carrots"] = true,
    ["minecraft:potatoes"] = true,
    ["minecraft:beetroots"] = true,
    ["minecraft:melon_stem"] = true,
    ["minecraft:pumpkin_stem"] = true,
}

local function reserveParticles(count)
    if isfunction(MCITEM.ReserveParticles) then
        return math.max(0, math.floor(tonumber(MCITEM.ReserveParticles(count)) or 0))
    end
    return count
end

local function randomGaussian()
    local u1 = math.max(math.Rand(0, 1), 1e-7)
    local u2 = math.Rand(0, 1)
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

local function blockName(info)
    if not istable(info) then return nil end
    local name = info.mcid or info.spec or info.name
    if not isstring(name) then return nil end
    if not string.find(name, ":", 1, true) then name = "minecraft:" .. name end
    return name
end

local function cellWorldMin(coords, bx, by, bz, blockSize)
    if coords and isfunction(coords.CellMin) then
        local minimum = coords.CellMin(bx, by, bz)
        if isvector(minimum) then return minimum end
    end
    if not isnumber(blockSize) or blockSize <= 0 then return nil end
    return Vector(bx * blockSize, by * blockSize, bz * blockSize)
end

local function growthMaterial()
    if MATERIAL and not MATERIAL:IsError() then return MATERIAL end

    local now = isfunction(RealTime) and RealTime() or CurTime()
    if now < NEXT_MATERIAL_RETRY then return nil end
    NEXT_MATERIAL_RETRY = now + 0.25

    MATERIAL = Material(MATERIAL_NAME)
    if not MATERIAL or MATERIAL:IsError() then return nil end
    return MATERIAL
end

-- ParticleUtils.spawnParticleInBlock samples Y from zero to
-- BlockState#getShape(...).max(Axis.Y). These fractions mirror the shape
-- constructors in CropBlock, BeetrootBlock, StemBlock, SweetBerryBushBlock,
-- TorchflowerCropBlock, and PitcherCropBlock.
local function shapeHeightFraction(name, stateId)
    local api = MC and MC.API or nil
    local blocks = api and api.Blocks or nil
    local age = blocks and isfunction(blocks.GetProperty)
        and tonumber(blocks.GetProperty(stateId, "age")) or nil

    if SIMPLE_AGE_HEIGHT_BLOCKS[name] and age ~= nil then
        return math.Clamp((2 + 2 * age) / 16, 0, 1)
    end
    if name == "minecraft:sweet_berry_bush" and age ~= nil then
        return age == 0 and 8 / 16 or 1
    end
    if name == "minecraft:torchflower_crop" and age ~= nil then
        return math.Clamp((6 + 4 * age) / 16, 0, 1)
    end
    if name == "minecraft:pitcher_crop" and age ~= nil then
        local totalHeight = ({ 4, 15, 17, 28, 32 })[math.Clamp(math.floor(age), 0, 4) + 1]
        local half = blocks and isfunction(blocks.GetProperty)
            and blocks.GetProperty(stateId, "half") or "lower"
        if half == "upper" then
            return math.Clamp((totalHeight - 17) / 16, 0, 1)
        end
        return math.Clamp((totalHeight - 1) / 16, 0, 1)
    end
    return 1
end

local function spawnVolume(bx, by, bz)
    local api = MC and MC.API or nil
    local coords = api and api.Coords or nil
    if not coords then return nil end

    local blockSize = isfunction(coords.BlockSize) and coords.BlockSize() or 36.5
    local minimum = cellWorldMin(coords, bx, by, bz, blockSize)
    if not isvector(minimum) or not isnumber(blockSize) or blockSize <= 0 then return nil end

    local world = api.World
    local info = world and isfunction(world.GetBlockInfo) and world.GetBlockInfo(bx, by, bz) or nil
    local name = blockName(info)
    if name and not BONEMEAL_PARTICLE_BLOCKS[name] then
        -- Java re-reads the post-growth block before spawning. A stem that
        -- became attached, or a torchflower crop that became a flower, is no
        -- longer BonemealableBlock and therefore emits no happy villagers.
        return nil
    end
    local height = name and shapeHeightFraction(name, info.stateId) or 1
    return minimum, blockSize, math.max(0, height)
end

-- Particle's velocity constructor first mixes the event's Gaussian 0.02
-- velocity with a random direction/speed, then SuspendedTownParticle scales
-- the result by another 0.02. Stored here in Source units per Minecraft tick.
local function initialVelocity(blockSize)
    local x = randomGaussian() * 0.02 + math.Rand(-0.4, 0.4)
    local vertical = randomGaussian() * 0.02 + math.Rand(-0.4, 0.4)
    local y = randomGaussian() * 0.02 + math.Rand(-0.4, 0.4)
    local length = math.sqrt(x * x + vertical * vertical + y * y)
    if length <= 1e-7 then
        x, vertical, y, length = 1, 0, 0, 1
    end

    local speed = (math.Rand(0, 1) + math.Rand(0, 1) + 1) * 0.15
    x = x / length * speed * 0.4
    vertical = vertical / length * speed * 0.4 + 0.1
    y = y / length * speed * 0.4
    return Vector(x, y, vertical) * (0.02 * blockSize)
end

local function scaleParticleLight(r, g, b)
    r = math.Clamp(tonumber(r) or 1, 0, 1)
    g = math.Clamp(tonumber(g) or r, 0, 1)
    b = math.Clamp(tonumber(b) or r, 0, 1)

    local api = MC and MC.API or nil
    local light = api and api.Light or nil
    if light and isfunction(light.ScaleRGB) then
        local ok, scaledR, scaledG, scaledB = pcall(light.ScaleRGB, r, g, b, LIGHT_GAIN)
        if ok and scaledR ~= nil and scaledG ~= nil and scaledB ~= nil then
            return math.Clamp(scaledR, 0, 1),
                math.Clamp(scaledG, 0, 1),
                math.Clamp(scaledB, 0, 1)
        end
    end
    return r * LIGHT_GAIN, g * LIGHT_GAIN, b * LIGHT_GAIN
end

local function sampleParticleLight(position)
    if isfunction(MCITEM.SampleParticleLightRGB) then
        local ok, r, g, b = pcall(MCITEM.SampleParticleLightRGB, position, 0)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            return scaleParticleLight(r, g, b)
        end
    end

    local api = MC and MC.API or nil
    local light = api and api.Light or nil
    if light and isfunction(light.SampleRGB) then
        local ok, r, g, b = pcall(light.SampleRGB, position, 0)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            return scaleParticleLight(r, g, b)
        end
    end
    return scaleParticleLight(1, 1, 1)
end

-- Level event 1505 plays item.bone_meal.use locally at the fertilized block
-- after spawning its particles. sounds.json contains all five samples once at
-- each resource pitch (0.9, 1.0 and 1.1), so two uniform choices reproduce the
-- same 15 equally weighted combinations.
function Farming.PlayBoneMealUseSound(bx, by, bz)
    if not sound or not isfunction(sound.Play) then return false end
    local api = MC and MC.API or nil
    local coords = api and api.Coords or nil
    if not coords then return false end

    local blockSize = isfunction(coords.BlockSize) and coords.BlockSize() or 36.5
    if not isnumber(blockSize) or blockSize <= 0 then return false end
    local minimum = isfunction(coords.CellRenderMin)
        and coords.CellRenderMin(bx, by, bz) or nil
    if not isvector(minimum) then
        minimum = cellWorldMin(coords, bx, by, bz, blockSize)
    end
    if not isvector(minimum) then return false end

    sound.Play(
        BONEMEAL_SOUNDS[math.random(1, #BONEMEAL_SOUNDS)],
        minimum + Vector(blockSize * 0.5, blockSize * 0.5, blockSize * 0.5),
        BONEMEAL_SOUND_LEVEL,
        BONEMEAL_PITCHES[math.random(1, #BONEMEAL_PITCHES)],
        BONEMEAL_SOUND_VOLUME
    )
    return true
end

function Farming.SpawnGrowthParticles(bx, by, bz, count)
    local minimum, blockSize, height = spawnVolume(bx, by, bz)
    if not minimum or height <= 0 then return false end

    count = math.Clamp(math.floor(tonumber(count) or 15), 0, 63)
    count = reserveParticles(count)
    local now = CurTime()
    -- Particle#getLightCoords samples the BlockPos containing the particle.
    -- MC.API.Light.SampleRGB is intentionally trilinear for moving entities,
    -- so feeding it a crop particle near the cell floor blends in the opaque
    -- farmland below and can make the happy-villager sprite effectively black.
    -- Sampling the crop cell centre selects that voxel's exact propagated light.
    local lightPosition = minimum + Vector(blockSize * 0.5, blockSize * 0.5, blockSize * 0.5)
    for _ = 1, count do
        local position = minimum + Vector(
            math.Rand(0, 1) * blockSize,
            math.Rand(0, 1) * blockSize,
            math.Rand(0, 1) * height * blockSize
        )
        local r, g, b = sampleParticleLight(lightPosition)
        local radius = 0.1 * (math.Rand(0, 1) * 0.5 + 0.5) * 2
        radius = radius * (math.Rand(0, 1) * 0.6 + 0.5) * blockSize
        Farming.GrowthParticles[#Farming.GrowthParticles + 1] = {
            position = position,
            oldPosition = Vector(position.x, position.y, position.z),
            velocity = initialVelocity(blockSize),
            radius = radius,
            remainingTicks = math.floor(20 / (math.Rand(0, 1) * 0.8 + 0.2)),
            litR = r,
            litG = g,
            litB = b,
            bx = bx,
            by = by,
            bz = bz,
            lastTickAt = now,
            nextTickAt = now + TICK_SECONDS,
        }
    end
    return count > 0
end

local function advanceParticle(particle, now)
    local steps = 0
    while not particle.removed and now >= particle.nextTickAt and steps < MAX_CATCHUP_TICKS do
        particle.lastTickAt = particle.nextTickAt
        particle.nextTickAt = particle.nextTickAt + TICK_SECONDS
        particle.oldPosition = particle.position

        local oldLifetime = particle.remainingTicks
        particle.remainingTicks = oldLifetime - 1
        if oldLifetime <= 0 then
            particle.removed = true
        else
            particle.position = particle.position + particle.velocity
            particle.velocity = particle.velocity * DRAG
        end
        steps = steps + 1
    end

    if steps >= MAX_CATCHUP_TICKS and now >= particle.nextTickAt then
        particle.lastTickAt = now
        particle.nextTickAt = now + TICK_SECONDS
    end
end

hook.Remove("Think", "MCITEM.FarmingGrowthParticles.Tick")
hook.Add("Think", "MCITEM.FarmingGrowthParticles.Tick", function()
    local now = CurTime()
    for index = #Farming.GrowthParticles, 1, -1 do
        local particle = Farming.GrowthParticles[index]
        advanceParticle(particle, now)
        if particle.removed then table.remove(Farming.GrowthParticles, index) end
    end
end)

local function addVertex(position, u, v, r, g, b)
    mesh.Position(position)
    mesh.TexCoord(0, u, v)
    mesh.Color(r * 255, g * 255, b * 255, 255)
    mesh.AdvanceVertex()
end

local function particleRenderPosition(particle, worldPosition, offsetCache)
    local api = MC and MC.API or nil
    local coords = api and api.Coords or nil
    if not coords or not isfunction(coords.CellRenderMin) then return worldPosition end
    if particle.bx == nil or particle.by == nil or particle.bz == nil then return worldPosition end

    local key = particle.bx .. ":" .. particle.by .. ":" .. particle.bz
    local offset = offsetCache[key]
    if offset == false then return nil end
    if not offset then
        local blockSize = isfunction(coords.BlockSize) and coords.BlockSize() or 36.5
        local worldMinimum = cellWorldMin(
            coords, particle.bx, particle.by, particle.bz, blockSize)
        local renderMinimum = coords.CellRenderMin(particle.bx, particle.by, particle.bz)
        if not isvector(worldMinimum) or not isvector(renderMinimum) then
            offsetCache[key] = false
            return nil
        end
        offset = renderMinimum - worldMinimum
        offsetCache[key] = offset
    end
    return worldPosition + offset
end

-- SuspendedTownParticle uses SingleQuadParticle.Layer.OPAQUE and the default
-- LOOKAT_XYZ camera mode. Keep the alpha-tested (non-blended) VMT, but do not
-- draw from PostDrawOpaqueRenderables: MCSWEP also submits its custom chunk
-- meshes there and GMod does not guarantee hook ordering, so a later chunk
-- submission can overwrite every particle inside a real crop. The boundary
-- immediately before the translucent pass is after all opaque hooks have
-- completed while the opaque depth buffer is still available.
local DRAW_HOOK = "MCITEM.FarmingGrowthParticles.Draw"
hook.Remove("PostDrawOpaqueRenderables", DRAW_HOOK) -- remove pre-fix autorefresh hook
hook.Remove("PreDrawTranslucentRenderables", DRAW_HOOK)
hook.Add("PreDrawTranslucentRenderables", DRAW_HOOK, function(drawingDepth, drawingSkybox, drawing3DSkybox)
    if drawingDepth or drawingSkybox or drawing3DSkybox
        or #Farming.GrowthParticles == 0 then return end
    local material = growthMaterial()
    if not material then return end

    local now = CurTime()
    local angles = EyeAngles()
    local right, up = angles:Right(), angles:Up()
    local offsetCache = {}
    local drawParticles = {}
    for index = 1, #Farming.GrowthParticles do
        local particle = Farming.GrowthParticles[index]
        local partialTick = math.Clamp((now - particle.lastTickAt) / TICK_SECONDS, 0, 1)
        local worldPosition = LerpVector(partialTick, particle.oldPosition, particle.position)
        local position = particleRenderPosition(particle, worldPosition, offsetCache)
        if position then
            drawParticles[#drawParticles + 1] = { particle = particle, position = position }
        end
    end
    if #drawParticles == 0 then return end

    render.SetMaterial(material)
    mesh.Begin(MATERIAL_QUADS, #drawParticles)
    for index = 1, #drawParticles do
        local draw = drawParticles[index]
        local particle, position = draw.particle, draw.position
        local side = right * particle.radius
        local top = up * particle.radius
        addVertex(position - side + top, 0, 0, particle.litR, particle.litG, particle.litB)
        addVertex(position + side + top, 1, 0, particle.litR, particle.litG, particle.litB)
        addVertex(position + side - top, 1, 1, particle.litR, particle.litG, particle.litB)
        addVertex(position - side - top, 0, 1, particle.litR, particle.litG, particle.litB)
    end
    mesh.End()
end)

hook.Remove("InitPostEntity", "MCITEM.FarmingGrowthParticles.Clear")
hook.Add("InitPostEntity", "MCITEM.FarmingGrowthParticles.Clear", function()
    MATERIAL = nil
    NEXT_MATERIAL_RETRY = 0
    for index = #Farming.GrowthParticles, 1, -1 do
        Farming.GrowthParticles[index] = nil
    end
end)

net.Receive(NET_GROWTH, function()
    local bx, by, bz = net.ReadInt(32), net.ReadInt(32), net.ReadInt(32)
    local count = net.ReadUInt(6)
    Farming.SpawnGrowthParticles(bx, by, bz, count)
    Farming.PlayBoneMealUseSound(bx, by, bz)
end)

-- The client prediction can legitimately miss a planting use while its chunk
-- state is still catching up. Mirror InteractionResult.SUCCESS from the
-- authoritative server so a successful ItemUseAnimation.NONE action still
-- produces Minecraft's ordinary hand swing.
net.Receive(NET_USE_SWING, function()
    local owner = LocalPlayer()
    if not IsValid(owner) then return end
    local weapon = owner:GetActiveWeapon()
    if not IsValid(weapon) or not isfunction(weapon.MCSwing) then return end
    weapon:MCSwing(CurTime())
end)
