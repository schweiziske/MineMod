-- Batched Minecraft Java 26.2 potion particle runtime.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local MAX_CATCHUP_TICKS = 8
local MAX_PARTICLES = 12000

Potions.ClientParticles = Potions.ClientParticles or {}
if isfunction(MCITEM.RegisterParticlePool) then
    MCITEM.RegisterParticlePool("potions", Potions.ClientParticles)
end
Potions.ClientFragmentMaterials = Potions.ClientFragmentMaterials or {}

local effectMaterial = Material("mcitem/particles/potion_effect")
local spellMaterial = Material("mcitem/particles/potion_spell")
local gustMaterial = Material("mcitem/particles/potion_small_gust")
local largeGustMaterial = Material("mcitem/particles/potion_gust")
local infestedMaterial = Material("mcitem/particles/potion_infested")
local cobwebMaterial = Material("mcitem/particles/potion_item_cobweb")
local slimeMaterial = Material("mcitem/particles/potion_item_slime")

local function randomSigned(scale)
    return (math.Rand(0, 1) * 2 - 1) * scale
end

-- ClientLevel.doAddParticle 的准入测试。Java 在**生成那一刻**就按相机距离把粒子
-- 丢掉：非 alwaysVisible 的粒子只要离相机超过 32 格（distanceToSqr > 1024.0）就
-- 根本不会被创建。
--
-- 这条规则和"限制总数"不是一回事，也正是之前对不齐的地方：全局上限是在粒子已经
-- 生成之后淘汰最老的，各处密度照旧、开销照付；Java 是压根不生成远处的，所以远处
-- 一群带效果的生物在原版里是零成本，在这里却要付采样光照 + 每 tick 推进 + 每帧
-- 拼 quad 的钱。只有 AreaEffectCloud 用 addAlwaysVisibleParticle 绕开这条。
local CULL_DISTANCE_BLOCKS = 32

function Potions.ParticleAdmitted(position, alwaysVisible)
    if alwaysVisible == true then return true end
    if not isvector(position) then return false end
    local limit = CULL_DISTANCE_BLOCKS * MCITEM.BlockSize()
    return position:DistToSqr(EyePos()) <= limit * limit
end

local function sampleLight(position, emission)
    if isfunction(MCITEM.SampleParticleLightRGB) then
        return MCITEM.SampleParticleLightRGB(position, emission or 0)
    end
    local light = MC and MC.API and MC.API.Light
    if istable(light) and isfunction(light.SampleRGB) then
        local ok, r, g, b = pcall(light.SampleRGB, position, emission or 0)
        if ok then return r or 1, g or 1, b or 1 end
    end
    local source = render.GetLightColor(position)
    if isvector(source) then return source.x, source.y, source.z end
    return 1, 1, 1
end

-- 全局粒子预算（`mcitem_particle_limit`）：各系统各自的 MAX_PARTICLES 仍然在，
-- 但总量由 sh_tuning.lua 的共享预算统一压住，超了先丢最老的。
local function trimToGlobalBudget(particles)
    local limit = isfunction(MCITEM.ParticleLimit) and MCITEM.ParticleLimit() or 0
    if limit <= 0 or not isfunction(MCITEM.LiveParticleCount) then return end
    while #particles > 0 and MCITEM.LiveParticleCount() >= limit do
        table.remove(particles, 1)
    end
end

local function append(particle)
    local particles = Potions.ClientParticles
    trimToGlobalBudget(particles)
    if #particles >= MAX_PARTICLES then table.remove(particles, 1) end
    particles[#particles + 1] = particle
end

local function particleBase(position, emission, fullbright)
    local now = CurTime()
    local r, g, b = 1, 1, 1
    if not fullbright then r, g, b = sampleLight(position, emission) end
    return {
        position = Vector(position.x, position.y, position.z),
        oldPosition = Vector(position.x, position.y, position.z),
        age = 0,
        lastTickAt = now,
        nextTickAt = now + Potions.TickSeconds,
        litR = math.Clamp(tonumber(r) or 1, 0, 1),
        litG = math.Clamp(tonumber(g) or 1, 0, 1),
        litB = math.Clamp(tonumber(b) or 1, 0, 1),
    }
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

function Potions.SpawnSpellParticle(position, options)
    if not isvector(position) then return end
    options = options or {}
    if not Potions.ParticleAdmitted(position, options.alwaysVisible) then return end
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

    local particle = particleBase(position, 0)
    particle.kind = options.staticMaterial and "static_spell" or "spell"
    particle.family = options.family == "spell" and "spell" or "effect"
    particle.material = options.staticMaterial
    particle.velocity = velocity
    particle.friction = 0.96
    particle.lifetime = math.floor(8 / (math.Rand(0, 1) * 0.8 + 0.2))
    particle.quadSize = math.Rand(0.075, 0.15)
    particle.r = math.Clamp(tonumber(options.r) or 1, 0, 1)
    particle.g = math.Clamp(tonumber(options.g) or 1, 0, 1)
    particle.b = math.Clamp(tonumber(options.b) or 1, 0, 1)
    particle.alpha = math.Clamp(tonumber(options.alpha) or 1, 0, 1)
    append(particle)
end

local function fragmentMaterial(modelId)
    if modelId == "__cobweb" then return cobwebMaterial end
    if modelId == "__slime" then return slimeMaterial end
    local cached = Potions.ClientFragmentMaterials[modelId]
    if cached then return cached end
    cached = CreateMaterial("mcitem_potion_fragment_" .. modelId, "UnlitGeneric", {
        ["$basetexture"] = "models/mcgm/" .. modelId .. "/" .. modelId,
        ["$translucent"] = "1",
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1",
        ["$nocull"] = "1",
        ["$pointsample"] = "1",
    })
    Potions.ClientFragmentMaterials[modelId] = cached
    return cached
end

function Potions.SpawnItemFragment(position, modelId, suppliedVelocity)
    if not isvector(position) or not isstring(modelId) then return end
    if not Potions.ParticleAdmitted(position) then return end
    suppliedVelocity = isvector(suppliedVelocity) and suppliedVelocity or vector_origin
    local velocity = vanillaParticleVelocity(0) * 0.1 + suppliedVelocity
    local particle = particleBase(position, 0)
    particle.kind = "fragment"
    particle.material = fragmentMaterial(modelId)
    particle.velocity = velocity
    particle.friction = 0.98
    particle.lifetime = math.floor(4 / (math.Rand(0, 1) * 0.9 + 0.1))
    particle.quadSize = math.Rand(0.05, 0.1)
    particle.uo = math.Rand(0, 1) * 3
    particle.vo = math.Rand(0, 1) * 3
    append(particle)
end

function Potions.SpawnInfestedParticle(position)
    Potions.SpawnSpellParticle(position, {
        inputX = 1,
        inputY = 1,
        inputZ = 1,
        staticMaterial = infestedMaterial,
    })
end

function Potions.SpawnSmallGust(position)
    if not isvector(position) then return end
    if not Potions.ParticleAdmitted(position) then return end
    -- GustParticle#getLightCoords returns 0xF000F0: both gust families are
    -- deliberately fullbright even though ordinary potion particles use MCSWEP light.
    local particle = particleBase(position, 0, true)
    particle.kind = "gust"
    particle.material = gustMaterial
    particle.frameCount = 7
    particle.lifetime = 12 + math.random(0, 3)
    particle.quadSize = 0.15
    particle.r, particle.g, particle.b, particle.alpha = 1, 1, 1, 1
    append(particle)
end

function Potions.SpawnGust(position)
    if not isvector(position) then return end
    if not Potions.ParticleAdmitted(position) then return end
    local particle = particleBase(position, 0, true)
    particle.kind = "gust"
    particle.material = largeGustMaterial
    particle.frameCount = 12
    particle.lifetime = 12 + math.random(0, 3)
    particle.quadSize = 1
    particle.r, particle.g, particle.b, particle.alpha = 1, 1, 1, 1
    append(particle)
end

local function moveFragment(particle)
    particle.velocity.z = particle.velocity.z - 0.04
    local destination = particle.position + particle.velocity * MCITEM.BlockSize()
    local trace = util.TraceLine({
        start = particle.position,
        endpos = destination,
        mask = MASK_SOLID,
    })
    if trace.Hit then
        particle.position = trace.HitPos
        local normalSpeed = particle.velocity:Dot(trace.HitNormal)
        if normalSpeed < 0 then particle.velocity = particle.velocity - trace.HitNormal * normalSpeed end
    else
        particle.position = destination
    end
    particle.velocity = particle.velocity * particle.friction
end

local function tickParticle(particle)
    particle.oldPosition = particle.position
    particle.age = particle.age + 1
    if particle.age >= particle.lifetime then
        particle.removed = true
        return
    end
    if particle.kind == "spell" or particle.kind == "static_spell" then
        particle.velocity.z = particle.velocity.z + 0.004
        particle.position = particle.position + particle.velocity * MCITEM.BlockSize()
        particle.velocity = particle.velocity * particle.friction
    elseif particle.kind == "fragment" then
        moveFragment(particle)
    end
end

local function advanceParticle(particle, now)
    local steps = 0
    while not particle.removed and now >= particle.nextTickAt and steps < MAX_CATCHUP_TICKS do
        particle.lastTickAt = particle.nextTickAt
        particle.nextTickAt = particle.nextTickAt + Potions.TickSeconds
        tickParticle(particle)
        steps = steps + 1
    end
    if steps >= MAX_CATCHUP_TICKS and now >= particle.nextTickAt then
        particle.lastTickAt = now
        particle.nextTickAt = now + Potions.TickSeconds
    end
end

hook.Remove("Think", "MCITEM.Potions.ParticleThink")
hook.Add("Think", "MCITEM.Potions.ParticleThink", function()
    local now = CurTime()
    for index = #Potions.ClientParticles, 1, -1 do
        local particle = Potions.ClientParticles[index]
        advanceParticle(particle, now)
        if particle.removed then table.remove(Potions.ClientParticles, index) end
    end
end)

local function vertex(position, u, v, r, g, b, alpha)
    mesh.Position(position)
    mesh.TexCoord(0, u, v)
    mesh.Color(r * 255, g * 255, b * 255, alpha * 255)
    mesh.AdvanceVertex()
end

local function bucketFor(buckets, material, frame)
    local byFrame = buckets[material]
    if not byFrame then
        byFrame = {}
        buckets[material] = byFrame
    end
    frame = frame or -1
    byFrame[frame] = byFrame[frame] or {}
    return byFrame[frame]
end

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.Potions.ParticleDraw")
hook.Add("PostDrawTranslucentRenderables", "MCITEM.Potions.ParticleDraw", function(_, drawingSkybox)
    if drawingSkybox or #Potions.ClientParticles == 0 then return end
    local now = CurTime()
    local eyeAngles = EyeAngles()
    local right, up = eyeAngles:Right(), eyeAngles:Up()
    local buckets = {}

    for _, particle in ipairs(Potions.ClientParticles) do
        local partial = math.Clamp((now - particle.lastTickAt) / Potions.TickSeconds, 0, 1)
        local position = LerpVector(partial, particle.oldPosition, particle.position)
        local material, frame
        if particle.kind == "spell" then
            material = particle.family == "spell" and spellMaterial or effectMaterial
            frame = 7 - math.floor(particle.age * 7 / particle.lifetime)
        elseif particle.kind == "gust" then
            material = particle.material
            frame = math.floor(particle.age * ((particle.frameCount or 1) - 1) / particle.lifetime)
        else
            material = particle.material
        end
        local bucket = bucketFor(buckets, material, frame)
        bucket[#bucket + 1] = { particle = particle, position = position }
    end

    for material, byFrame in pairs(buckets) do
        render.SetMaterial(material)
        for frame, bucket in pairs(byFrame) do
            if frame >= 0 then material:SetInt("$frame", frame) end
            mesh.Begin(MATERIAL_QUADS, #bucket)
            for _, entry in ipairs(bucket) do
                local particle = entry.particle
                local radius = particle.quadSize * MCITEM.BlockSize()
                local rightOffset, upOffset = right * radius, up * radius
                local u0, u1, v0, v1 = 0, 1, 0, 1
                if particle.kind == "fragment" then
                    u0, u1 = (particle.uo + 1) / 4, particle.uo / 4
                    v0, v1 = particle.vo / 4, (particle.vo + 1) / 4
                end
                local r = (particle.r or 1) * particle.litR
                local g = (particle.g or 1) * particle.litG
                local b = (particle.b or 1) * particle.litB
                local alpha = particle.alpha or 1
                vertex(entry.position - rightOffset - upOffset, u1, v1, r, g, b, alpha)
                vertex(entry.position + rightOffset - upOffset, u0, v1, r, g, b, alpha)
                vertex(entry.position + rightOffset + upOffset, u0, v0, r, g, b, alpha)
                vertex(entry.position - rightOffset + upOffset, u1, v0, r, g, b, alpha)
            end
            mesh.End()
        end
    end
end)
