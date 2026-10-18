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
        position = position,
        oldPosition = position,
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

local function tickParticle(particle)
    particle.oldPosition = particle.position
    particle.age = particle.age + 1
    if particle.age >= particle.lifetime then
        particle.removed = true
        return
    end

    particle.velocity.z = particle.velocity.z - 0.04 * particle.gravity
    local destination = particle.position + particle.velocity * MCITEM.BlockSize()
    local trace = util.TraceLine({
        start = particle.position,
        endpos = destination,
        filter = particle.owner,
        mask = MASK_SOLID,
    })
    if trace.Hit then
        particle.position = trace.HitPos
        local normalSpeed = particle.velocity:Dot(trace.HitNormal)
        if normalSpeed < 0 then
            particle.velocity = particle.velocity - trace.HitNormal * normalSpeed
        end
    else
        particle.position = destination
    end
    particle.velocity = particle.velocity * particle.friction
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
    for index = #Food.Particles, 1, -1 do
        local particle = Food.Particles[index]
        advanceParticle(particle, now)
        if particle.removed then table.remove(Food.Particles, index) end
    end
end)

local function vertex(position, u, v, r, g, b)
    mesh.Position(position)
    mesh.TexCoord(0, u, v)
    mesh.Color(r * 255, g * 255, b * 255, 255)
    mesh.AdvanceVertex()
end

hook.Remove("PostDrawTranslucentRenderables", "MCITEM_FoodParticlesDraw")
hook.Add("PostDrawTranslucentRenderables", "MCITEM_FoodParticlesDraw", function(_, drawingSkybox)
    if drawingSkybox or #Food.Particles == 0 then return end
    local now = CurTime()
    local angles = EyeAngles()
    local right, up = angles:Right(), angles:Up()
    local buckets = {}

    for _, particle in ipairs(Food.Particles) do
        local partialTick = math.Clamp(
            (now - particle.lastTickAt) / Food.TickSeconds,
            0,
            1
        )
        local bucket = buckets[particle.material]
        if not bucket then
            bucket = {}
            buckets[particle.material] = bucket
        end
        bucket[#bucket + 1] = {
            particle = particle,
            position = LerpVector(partialTick, particle.oldPosition, particle.position),
        }
    end

    for material, bucket in pairs(buckets) do
        render.SetMaterial(material)
        mesh.Begin(MATERIAL_QUADS, #bucket)
        for _, entry in ipairs(bucket) do
            local particle = entry.particle
            local radius = particle.quadSize * MCITEM.BlockSize()
            local rightOffset, upOffset = right * radius, up * radius
            local u0, u1 = (particle.uo + 1) / 4, particle.uo / 4
            local v0, v1 = particle.vo / 4, (particle.vo + 1) / 4
            local r, g, b = particle.litR, particle.litG, particle.litB
            vertex(entry.position - rightOffset - upOffset, u1, v1, r, g, b)
            vertex(entry.position + rightOffset - upOffset, u0, v1, r, g, b)
            vertex(entry.position + rightOffset + upOffset, u0, v0, r, g, b)
            vertex(entry.position - rightOffset + upOffset, u1, v0, r, g, b)
        end
        mesh.End()
    end
end)
