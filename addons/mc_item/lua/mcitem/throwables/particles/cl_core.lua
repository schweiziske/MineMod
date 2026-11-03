-- Batched Minecraft Java 26.2 throwable particles with MineMod voxel lighting.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
local PARTICLE_CORE_VERSION = 6
if (tonumber(Throwables.ParticleCoreVersion) or 0) >= PARTICLE_CORE_VERSION then return end
Throwables.ParticleCoreVersion = PARTICLE_CORE_VERSION
Throwables.ParticleCoreLoaded = true
if not MCITEM.AlphaParticlePools then include("mcitem/cl_billboard.lua") end

local MAX_PARTICLES = 12000
local MAX_CATCHUP_TICKS = 8

Throwables.ClientParticles = Throwables.ClientParticles or {}
Throwables.WindChargeEmitters = Throwables.WindChargeEmitters or {}
if isfunction(MCITEM.RegisterParticlePool) then
    MCITEM.RegisterParticlePool("throwables", Throwables.ClientParticles)
end
Throwables.ClientFragmentMaterials = Throwables.ClientFragmentMaterials or {}

local portalMaterial = Material("mcitem/particles/throwable_portal")
local effectMaterial = Material("mcitem/particles/throwable_effect")
local bubbleMaterial = Material("mcitem/particles/throwable_bubble")
local smallGustMaterial = Material("mcitem/particles/throwable_small_gust")
local gustMaterial = Material("mcitem/particles/throwable_gust")

local function sampleLight(position, emission)
    if isfunction(MCITEM.SampleParticleLightRGB) then
        return MCITEM.SampleParticleLightRGB(position, emission or 0)
    end
    local light = MC and MC.API and MC.API.Light
    if light and isfunction(light.SampleRGB) then
        local ok, r, g, b = pcall(light.SampleRGB, position, emission or 0)
        if ok then return r or 1, g or 1, b or 1 end
    end
    local source = render.GetLightColor(position)
    if isvector(source) then return source.x, source.y, source.z end
    return 1, 1, 1
end

local function updateLight(particle, emission)
    if particle.fullbright then
        particle.litR, particle.litG, particle.litB = 1, 1, 1
        return
    end
    local r, g, b = sampleLight(particle.position, emission or 0)
    particle.litR = math.Clamp(tonumber(r) or 1, 0, 1)
    particle.litG = math.Clamp(tonumber(g) or 1, 0, 1)
    particle.litB = math.Clamp(tonumber(b) or 1, 0, 1)
end

local function particleBase(position, fullbright)
    local now = CurTime()
    local particle = {
        position = Vector(position.x, position.y, position.z),
        oldPosition = Vector(position.x, position.y, position.z),
        age = 0,
        lastTickAt = now,
        nextTickAt = now + Throwables.TickSeconds,
        fullbright = fullbright == true,
        r = 1,
        g = 1,
        b = 1,
        alpha = 1,
    }
    updateLight(particle, 0)
    return particle
end

local function append(particle)
    local particles = Throwables.ClientParticles
    if MCITEM.ReserveParticles and MCITEM.ReserveParticles(1) == 0 then return nil end
    if #particles >= MAX_PARTICLES then table.remove(particles, 1) end
    particles[#particles + 1] = particle
    return particle
end

local function fragmentMaterial(modelId)
    local cached = Throwables.ClientFragmentMaterials[modelId]
    if cached then return cached end
    local materialId = string.gsub(modelId, "[^%w_]", "_")
    cached = CreateMaterial("mcitem_throwable_fragment_" .. materialId, "UnlitGeneric", {
        ["$basetexture"] = "models/mcgm/" .. modelId .. "/" .. modelId,
        ["$translucent"] = "1",
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1",
        ["$nocull"] = "1",
        ["$pointsample"] = "1",
        ["$no_fullbright"] = "1",
    })
    Throwables.ClientFragmentMaterials[modelId] = cached
    return cached
end

function Throwables.SpawnItemFragment(position, modelId, velocity)
    if not isvector(position) or not isstring(modelId) then return nil end
    local particle = particleBase(position, false)
    particle.kind = "fragment"
    particle.material = fragmentMaterial(modelId)
    particle.velocity = isvector(velocity) and Vector(velocity.x, velocity.y, velocity.z) or vector_origin
    particle.friction = 0.98
    particle.lifetime = math.floor(4 / (math.Rand(0, 1) * 0.9 + 0.1))
    particle.quadSize = math.Rand(0.05, 0.1)
    particle.uo = math.Rand(0, 1) * 3
    particle.vo = math.Rand(0, 1) * 3
    return append(particle)
end

function Throwables.SpawnPortal(position, velocity)
    if not isvector(position) then return nil end
    local particle = particleBase(position, false)
    particle.kind = "portal"
    particle.material = portalMaterial
    particle.startPosition = Vector(position.x, position.y, position.z)
    particle.velocity = isvector(velocity) and Vector(velocity.x, velocity.y, velocity.z) or vector_origin
    particle.lifetime = 40 + math.random(0, 9)
    particle.quadSize = 0.1 * (math.Rand(0, 1) * 0.2 + 0.5)
    local color = math.Rand(0, 1) * 0.6 + 0.4
    particle.r, particle.g, particle.b = color * 0.9, color * 0.3, color
    return append(particle)
end

function Throwables.SpawnBubble(position, velocity)
    if not isvector(position) then return nil end
    velocity = isvector(velocity) and velocity or vector_origin
    local particle = particleBase(position, false)
    particle.kind = "bubble"
    particle.material = bubbleMaterial
    particle.velocity = velocity * 0.2 + Vector(
        math.Rand(-0.02, 0.02),
        math.Rand(-0.02, 0.02),
        math.Rand(-0.02, 0.02)
    )
    particle.lifetime = math.floor(8 / (math.Rand(0, 1) * 0.8 + 0.2))
    particle.quadSize = math.Rand(0.04, 0.16)
    return append(particle)
end

local function randomSigned(scale)
    return (math.Rand(0, 1) * 2 - 1) * scale
end

local function vanillaParticleVelocity(inputY)
    local velocity = Vector(
        (0.5 - math.Rand(0, 1)) + randomSigned(0.4),
        (0.5 - math.Rand(0, 1)) + randomSigned(0.4),
        (tonumber(inputY) or 0) + randomSigned(0.4)
    )
    local length = velocity:Length()
    local scale = (math.Rand(0, 1) + math.Rand(0, 1) + 1) * 0.15 * 0.4
    if length > 0 then velocity = velocity / length * scale end
    velocity.z = velocity.z + 0.1
    return velocity
end

function Throwables.SpawnEffect(position, options)
    if not isvector(position) then return nil end
    options = options or {}
    local inputX = tonumber(options.inputX) or 0
    local inputZ = tonumber(options.inputZ) or 0
    local velocity = vanillaParticleVelocity(options.inputY)
    velocity.z = velocity.z * 0.2
    if inputX == 0 and inputZ == 0 then
        velocity.x = velocity.x * 0.1
        velocity.y = velocity.y * 0.1
    end
    local power = tonumber(options.power)
    if power then
        velocity.x = velocity.x * power
        velocity.y = velocity.y * power
        velocity.z = (velocity.z - 0.1) * power + 0.1
    end
    local particle = particleBase(position, false)
    particle.kind = "effect"
    particle.material = effectMaterial
    particle.velocity = velocity
    particle.friction = 0.96
    particle.lifetime = math.floor(8 / (math.Rand(0, 1) * 0.8 + 0.2))
    particle.quadSize = math.Rand(0.075, 0.15)
    particle.r = math.Clamp(tonumber(options.r) or 1, 0, 1)
    particle.g = math.Clamp(tonumber(options.g) or 1, 0, 1)
    particle.b = math.Clamp(tonumber(options.b) or 1, 0, 1)
    return append(particle)
end

function Throwables.SpawnSmallGust(position)
    if not isvector(position) then return nil end
    local particle = particleBase(position, true)
    particle.kind = "gust"
    particle.material = smallGustMaterial
    particle.frameCount = 7
    particle.lifetime = 12 + math.random(0, 3)
    particle.quadSize = 0.15
    return append(particle)
end

function Throwables.SpawnGust(position)
    if not isvector(position) then return nil end
    local particle = particleBase(position, true)
    particle.kind = "gust"
    particle.material = gustMaterial
    particle.frameCount = 12
    particle.lifetime = 12 + math.random(0, 3)
    particle.quadSize = 1
    return append(particle)
end

function Throwables.SpawnGustEmitter(position, radiusBlocks, lifetimeTicks, intervalTicks)
    if not isvector(position) then return nil end
    local now = CurTime()
    local emitter = {
        position = Vector(position.x, position.y, position.z),
        age = 0,
        nextTickAt = now,
        radiusBlocks = math.max(0, tonumber(radiusBlocks) or 1),
        lifetimeTicks = math.max(1, math.floor(tonumber(lifetimeTicks) or 3)),
        intervalTicks = math.max(1, math.floor(tonumber(intervalTicks) or 3)),
    }
    Throwables.WindChargeEmitters[#Throwables.WindChargeEmitters + 1] = emitter
    return emitter
end

function Throwables.SpawnWindChargeEmitter(position)
    -- ParticleTypes.GUST_EMITTER_SMALL = Provider(1.0, 3, 2).
    -- GustSeedParticle emits regular GUST (not SMALL_GUST) when
    -- age % (delay + 1) == 0.
    return Throwables.SpawnGustEmitter(position, 1, 3, 3)
end

function Throwables.SpawnWindBurstEmitter(position)
    -- ExplodeEffect supplies both packet alternatives, but ServerExplosion
    -- selects exactly one. Radius 3.5 with TRIGGER_BLOCK is not small, so the
    -- wind-burst packet carries GUST_EMITTER_LARGE = Provider(3.0, 7, 0).
    return Throwables.SpawnGustEmitter(position, 3, 7, 1)
end

local function moveFragment(particle)
    particle.velocity.z = particle.velocity.z - 0.04
    local destination = particle.position + particle.velocity * MCITEM.BlockSize()
    local trace = util.TraceLine({ start = particle.position, endpos = destination, mask = MASK_SOLID })
    if trace.Hit then
        particle.position = trace.HitPos
        local normalSpeed = particle.velocity:Dot(trace.HitNormal)
        if normalSpeed < 0 then particle.velocity = particle.velocity - trace.HitNormal * normalSpeed end
    else
        particle.position = destination
    end
    particle.velocity = particle.velocity * particle.friction
end

local function tickPortal(particle)
    local progress = particle.age / particle.lifetime
    local path = 1 + progress - 2 * progress * progress
    particle.position = particle.startPosition + Vector(
        particle.velocity.x * path,
        particle.velocity.y * path,
        particle.velocity.z * path + (1 - progress)
    ) * MCITEM.BlockSize()
    updateLight(particle, 15 * progress ^ 4)
end

local function tickBubble(particle)
    particle.velocity.z = particle.velocity.z + 0.002
    particle.position = particle.position + particle.velocity * MCITEM.BlockSize()
    particle.velocity = particle.velocity * 0.85
    if Throwables.FluidKindAt(particle.position) ~= "water" then particle.removed = true end
end

local function tickParticle(particle)
    particle.oldPosition = particle.position
    particle.age = particle.age + 1
    if particle.age >= particle.lifetime then
        particle.removed = true
        return
    end
    if particle.kind == "fragment" then
        moveFragment(particle)
    elseif particle.kind == "portal" then
        tickPortal(particle)
    elseif particle.kind == "bubble" then
        tickBubble(particle)
    elseif particle.kind == "effect" then
        particle.velocity.z = particle.velocity.z + 0.004
        particle.position = particle.position + particle.velocity * MCITEM.BlockSize()
        particle.velocity = particle.velocity * particle.friction
    end
end

local function advanceParticle(particle, now)
    local steps = 0
    while not particle.removed and now >= particle.nextTickAt and steps < MAX_CATCHUP_TICKS do
        particle.lastTickAt = particle.nextTickAt
        particle.nextTickAt = particle.nextTickAt + Throwables.TickSeconds
        tickParticle(particle)
        steps = steps + 1
    end
    if steps >= MAX_CATCHUP_TICKS and now >= particle.nextTickAt then
        particle.lastTickAt = now
        particle.nextTickAt = now + Throwables.TickSeconds
    end
end

hook.Remove("Think", "MCITEM.Throwables.ParticleThink")
hook.Add("Think", "MCITEM.Throwables.ParticleThink", function()
    local now = CurTime()
    for index = #Throwables.WindChargeEmitters, 1, -1 do
        local emitter = Throwables.WindChargeEmitters[index]
        local catchup = 0
        local lifetimeTicks = emitter.lifetimeTicks or 3
        local intervalTicks = emitter.intervalTicks or 3
        local radiusBlocks = emitter.radiusBlocks or 1
        while emitter.age < lifetimeTicks and now >= emitter.nextTickAt and catchup < MAX_CATCHUP_TICKS do
            if emitter.age % intervalTicks == 0 then
                for _ = 1, 3 do
                    local offset = Vector(
                        math.Rand(0, 1) - math.Rand(0, 1),
                        math.Rand(0, 1) - math.Rand(0, 1),
                        math.Rand(0, 1) - math.Rand(0, 1)
                    ) * (radiusBlocks * MCITEM.BlockSize())
                    Throwables.SpawnGust(emitter.position + offset)
                end
            end
            emitter.age = emitter.age + 1
            emitter.nextTickAt = emitter.nextTickAt + Throwables.TickSeconds
            catchup = catchup + 1
        end
        if emitter.age >= lifetimeTicks then table.remove(Throwables.WindChargeEmitters, index) end
    end
    local particles = Throwables.ClientParticles
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

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.Throwables.ParticleDraw")
MCITEM.AlphaParticlePools.throwables = {
    particles = Throwables.ClientParticles, interval = Throwables.TickSeconds,
}
