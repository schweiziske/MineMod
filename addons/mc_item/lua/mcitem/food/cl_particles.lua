-- Minecraft Java 26.2 item fragments emitted while eating.
-- Sources: LivingEntity.spawnItemParticles, BreakingItemParticle, Particle.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food
local NET_PARTICLES = "MCITEM_FoodParticles"
local MAX_CATCHUP_TICKS = 8

Food.Particles = Food.Particles or {}
if isfunction(MCITEM.RegisterParticlePool) then
    MCITEM.RegisterParticlePool("food", Food.Particles)
end
Food.ParticleMaterials = Food.ParticleMaterials or {}

-- "<dir>/<texture>" under models/mcgm for the eat particles.  Defaults to
-- "<id>/<id>"; raw chicken overrides it because its texture had to move out of
-- the path it shared with BMB's chicken mob skin (docs/STATE_MCITEM.md).
local function particleAsset(itemId)
    local definition = isfunction(MCITEM.Food.Get) and MCITEM.Food.Get(itemId) or nil
    local asset = definition and definition.particleAsset
    if isstring(asset) and asset ~= "" then return asset end
    return itemId .. "/" .. itemId
end

local function particleMaterial(itemId)
    local cached = Food.ParticleMaterials[itemId]
    if cached then return cached end
    local material = CreateMaterial("mcitem_food_particle_" .. itemId, "UnlitGeneric", {
        ["$basetexture"] = "models/mcgm/" .. particleAsset(itemId),
        ["$translucent"] = "1",
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1",
        ["$nocull"] = "1",
        ["$nolod"] = "1",
        ["$pointsample"] = "1",
    })
    Food.ParticleMaterials[itemId] = material
    return material
end

local function sampleLight(position)
    if isfunction(MCITEM.SampleParticleLightRGB) then
        return MCITEM.SampleParticleLightRGB(position, 0)
    end
    local light = MC and MC.API and MC.API.Light
    if istable(light) and isfunction(light.SampleRGB) then
        local ok, r, g, b = pcall(light.SampleRGB, position, 0)
        if ok then return r or 1, g or 1, b or 1 end
    end
    return 1, 1, 1
end

local function localVector(angles, x, y, z)
    return angles:Right() * x + angles:Up() * y + angles:Forward() * z
end

local function spawnOne(owner, definition, now)
    local eyeAngles = owner:EyeAngles()
    local blockSize = MCITEM.BlockSize()

    -- LivingEntity.spawnItemParticles: both vectors are rotated by -pitch/-yaw;
    -- Source's eye basis is the equivalent already-rotated local frame.
    local velocity = localVector(
        eyeAngles,
        (math.Rand(0, 1) - 0.5) * 0.1,
        math.Rand(0, 1) * 0.1 + 0.1,
        0
    )
    local positionOffset = localVector(
        eyeAngles,
        (math.Rand(0, 1) - 0.5) * 0.3,
        -math.Rand(0, 1) * 0.6 - 0.3,
        0.6
    )
    local position = owner:EyePos() + positionOffset * blockSize
    local r, g, b = sampleLight(position)

    local particle = {
        itemId = definition.id,
        material = particleMaterial(definition.id),
        -- position/oldPosition are distinct Vectors updated in place by ticks.
        position = position,
        oldPosition = Vector(position),
        velocity = velocity,
        age = 0,
        lifetime = math.floor(4 / (math.Rand(0, 1) * 0.9 + 0.1)),
        gravity = 1,
        friction = 0.98,
        quadSize = 0.1 * (math.Rand(0, 1) * 0.5 + 0.5),
        uo = math.Rand(0, 1) * 3,
        vo = math.Rand(0, 1) * 3,
        litR = math.Clamp(tonumber(r) or 1, 0, 1),
        litG = math.Clamp(tonumber(g) or 1, 0, 1),
        litB = math.Clamp(tonumber(b) or 1, 0, 1),
        lastTickAt = now,
        nextTickAt = now + Food.TickSeconds,
        removed = false,
        owner = owner,
    }
    if isfunction(MCITEM.ReserveParticles) and MCITEM.ReserveParticles(1) <= 0 then return end
    Food.Particles[#Food.Particles + 1] = particle
end

function Food.SpawnItemParticles(owner, itemId, count)
    if not IsValid(owner) or not Food.Get then return end
    local definition = Food.Get(itemId)
    if not definition or not definition.hasConsumeParticles then return end
    local now = CurTime()
    for _ = 1, math.Clamp(math.floor(tonumber(count) or 0), 0, 63) do
        spawnOne(owner, definition, now)
    end
end

net.Receive(NET_PARTICLES, function()
    Food.SpawnItemParticles(net.ReadEntity(), net.ReadString(), net.ReadUInt(6))
end)

-- Reused trace scratch: tickParticle copies what it needs before the next trace.
local traceInput = { mask = MASK_SOLID }
local traceOutput = {}
local traceDestination = Vector(0, 0, 0)

local function tickParticle(particle)
    local position, oldPosition = particle.position, particle.oldPosition
    if rawequal(position, oldPosition) then
        -- Particles created before a hot reload still alias these Vectors.
        oldPosition = Vector(position)
        particle.oldPosition = oldPosition
    end
    oldPosition:Set(position)
    particle.age = particle.age + 1
    if particle.age >= particle.lifetime then
        particle.removed = true
        return
    end

    local velocity = particle.velocity
    velocity.z = velocity.z - 0.04 * particle.gravity
    local blockSize = MCITEM.BlockSize()
    traceDestination.x = position.x + velocity.x * blockSize
    traceDestination.y = position.y + velocity.y * blockSize
    traceDestination.z = position.z + velocity.z * blockSize
    traceInput.start = position
    traceInput.endpos = traceDestination
    traceInput.filter = particle.owner
    traceInput.output = traceOutput
    util.TraceLine(traceInput)
    traceInput.filter = nil
    local trace = traceOutput
    if trace.Hit then
        position:Set(trace.HitPos)
        local hitNormal = trace.HitNormal
        local normalSpeed = velocity:Dot(hitNormal)
        if normalSpeed < 0 then
            velocity.x = velocity.x - hitNormal.x * normalSpeed
            velocity.y = velocity.y - hitNormal.y * normalSpeed
            velocity.z = velocity.z - hitNormal.z * normalSpeed
        end
    else
        position:Set(traceDestination)
    end
    local friction = particle.friction
    velocity.x, velocity.y, velocity.z = velocity.x * friction, velocity.y * friction, velocity.z * friction
end

local function advanceParticle(particle, now)
    local steps = 0
    while not particle.removed and now >= particle.nextTickAt and steps < MAX_CATCHUP_TICKS do
        particle.lastTickAt = particle.nextTickAt
        particle.nextTickAt = particle.nextTickAt + Food.TickSeconds
        tickParticle(particle)
        steps = steps + 1
    end
    if steps >= MAX_CATCHUP_TICKS and now >= particle.nextTickAt then
        particle.lastTickAt = now
        particle.nextTickAt = now + Food.TickSeconds
    end
end

hook.Remove("Think", "MCITEM_FoodParticlesThink")
hook.Add("Think", "MCITEM_FoodParticlesThink", function()
    local now = CurTime()
    -- Stable in-place compaction instead of O(n^2) table.remove shifting.
    local particles = Food.Particles
    local count, kept = #particles, 0
    for index = 1, count do
        local particle = particles[index]
        advanceParticle(particle, now)
        if not particle.removed then
            kept = kept + 1
            particles[kept] = particle
        end
    end
    for index = kept + 1, count do particles[index] = nil end
end)

local vertexPosition = Vector(0, 0, 0)

local function vertex(x, y, z, u, v, r, g, b)
    vertexPosition.x, vertexPosition.y, vertexPosition.z = x, y, z
    mesh.Position(vertexPosition)
    mesh.TexCoord(0, u, v)
    mesh.Color(r * 255, g * 255, b * 255, 255)
    mesh.AdvanceVertex()
end

-- Persistent per-material buckets: flat arrays of
-- (particle, x, y, z) with a per-frame count; reset each frame without
-- reallocating.
local BUCKET_STRIDE = 4
local drawBuckets = {}
local drawCounts = {}
local drawOrder = {}

hook.Remove("PostDrawTranslucentRenderables", "MCITEM_FoodParticlesDraw")
hook.Add("PostDrawTranslucentRenderables", "MCITEM_FoodParticlesDraw", function(_, drawingSkybox)
    if drawingSkybox or #Food.Particles == 0 then return end
    local now = CurTime()
    local angles = EyeAngles()
    local right, up = angles:Right(), angles:Up()
    local rightX, rightY, rightZ = right.x, right.y, right.z
    local upX, upY, upZ = up.x, up.y, up.z
    local orderCount = 0

    local particles = Food.Particles
    for index = 1, #particles do
        local particle = particles[index]
        local partialTick = math.Clamp(
            (now - particle.lastTickAt) / Food.TickSeconds,
            0,
            1
        )
        local material = particle.material
        local bucket = drawBuckets[material]
        if not bucket then
            bucket = {}
            drawBuckets[material] = bucket
        end
        local count = drawCounts[material]
        if not count then
            count = 0
            orderCount = orderCount + 1
            drawOrder[orderCount] = material
        end
        local oldPosition, position = particle.oldPosition, particle.position
        local base = count * BUCKET_STRIDE
        bucket[base + 1] = particle
        bucket[base + 2] = oldPosition.x + (position.x - oldPosition.x) * partialTick
        bucket[base + 3] = oldPosition.y + (position.y - oldPosition.y) * partialTick
        bucket[base + 4] = oldPosition.z + (position.z - oldPosition.z) * partialTick
        drawCounts[material] = count + 1
    end

    local blockSize = MCITEM.BlockSize()
    for orderIndex = 1, orderCount do
        local material = drawOrder[orderIndex]
        local bucket = drawBuckets[material]
        local count = drawCounts[material]
        render.SetMaterial(material)
        mesh.Begin(MATERIAL_QUADS, count)
        for entryIndex = 0, count - 1 do
            local base = entryIndex * BUCKET_STRIDE
            local particle = bucket[base + 1]
            local px, py, pz = bucket[base + 2], bucket[base + 3], bucket[base + 4]
            bucket[base + 1] = nil
            local radius = particle.quadSize * blockSize
            local rx, ry, rz = rightX * radius, rightY * radius, rightZ * radius
            local ux, uy, uz = upX * radius, upY * radius, upZ * radius
            local u0, u1 = (particle.uo + 1) / 4, particle.uo / 4
            local v0, v1 = particle.vo / 4, (particle.vo + 1) / 4
            local r, g, b = particle.litR, particle.litG, particle.litB
            vertex(px - rx - ux, py - ry - uy, pz - rz - uz, u1, v1, r, g, b)
            vertex(px + rx - ux, py + ry - uy, pz + rz - uz, u0, v1, r, g, b)
            vertex(px + rx + ux, py + ry + uy, pz + rz + uz, u0, v0, r, g, b)
            vertex(px - rx + ux, py - ry + uy, pz - rz + uz, u1, v0, r, g, b)
        end
        mesh.End()
        drawCounts[material] = nil
        drawOrder[orderIndex] = nil
    end
end)
