-- Client-only visuals for the enchantment runtime.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.EnchantmentRuntime = MCITEM.EnchantmentRuntime or {}

local Runtime = MCITEM.EnchantmentRuntime

local NET_EVENT = "MCITEM_EnchantmentRuntimeFX"
local FX_LIGHTNING = 0
local FX_SOUL_SPEED = 1
local fire0 = Material("mcitem/enchantments/fire_0")
local fire1 = Material("mcitem/enchantments/fire_1")
local soulMaterial = Material("mcitem/enchantments/soul")
local lightningMaterial = CreateMaterial("mcitem_enchantment_lightning_26_2", "UnlitGeneric", {
    ["$basetexture"] = "color/white",
    ["$vertexcolor"] = "1",
    ["$vertexalpha"] = "1",
    ["$additive"] = "1",
    ["$nocull"] = "1",
})
local effects = {}
local soulParticles = {}
local LIGHTNING_EFFECT_TIMEOUT = 4
local FIRE_FRAME_COUNT = 32
local FIRE_DEPTH_BIAS = 0.10
local SOUL_FRAME_COUNT = 11
local TICK_SECONDS = 1 / 20
local SOUL_COLLISION_EPSILON_BLOCKS = 0.00001
local SOUL_BLOCK_COLLISION_CLASSES = {
    mc_chunk = true,
    mc_chunk_phys = true,
    mc_collision_carrier = true,
    mc_block_cluster = true,
}

-- RandomSource.createThreadLocalInstance(long) is backed by
-- SingleThreadedRandomSource in Java 26.2.  It is the old 48-bit Java LCG,
-- not a 32-bit float LCG. BitRandomSource.nextInt(bound) consumes 31 high
-- bits and uses java.util.Random's power-of-two/rejection algorithm. Keep the
-- state in two 24-bit halves so LuaJIT's 53-bit number mantissa never rounds
-- the 48-bit product.
local RANDOM_MODULUS = 16777216 -- 2^24
local RANDOM_MULTIPLIER_LOW = 15525485 -- 25214903917 % 2^24
local RANDOM_MULTIPLIER_HIGH = 1502 -- floor(25214903917 / 2^24)
local RANDOM_INCREMENT = 11
local RANDOM_SEED_MODULUS = 281474976710656 -- 2^48
local RANDOM_INT31 = 2147483648
local RANDOM_HIGH31_DIVISOR = 131072 -- 2^(48 - 31)

local function newJavaRandom(seed)
    local original = (tonumber(seed) or 0) % RANDOM_SEED_MODULUS
    local lowInput = original % RANDOM_MODULUS
    local highInput = math.floor(original / RANDOM_MODULUS)
    -- LightningBoltRenderer consumes only the low 48 bits of its long seed.
    -- The network preserves both 24-bit halves exactly before Java's
    -- (seed ^ multiplier) initialization.
    return {
        low = bit.bxor(lowInput, RANDOM_MULTIPLIER_LOW),
        high = bit.bxor(highInput, RANDOM_MULTIPLIER_HIGH),
    }
end

local function nextJava31(state)
    local lowProduct = state.low * RANDOM_MULTIPLIER_LOW + RANDOM_INCREMENT
    local nextLow = lowProduct % RANDOM_MODULUS
    local carry = math.floor(lowProduct / RANDOM_MODULUS)
    local nextHigh = (
        state.low * RANDOM_MULTIPLIER_HIGH
        + state.high * RANDOM_MULTIPLIER_LOW
        + carry
    ) % RANDOM_MODULUS
    state.low, state.high = nextLow, nextHigh
    return math.floor((nextHigh * RANDOM_MODULUS + nextLow) / RANDOM_HIGH31_DIVISOR)
end

local function nextInteger(state, bound)
    bound = math.max(1, math.floor(tonumber(bound) or 1))
    if bit.band(bound, bound - 1) == 0 then
        return math.floor(bound * nextJava31(state) / RANDOM_INT31)
    end
    while true do
        local bits = nextJava31(state)
        local value = bits % bound
        -- Java evaluates this expression as a signed 32-bit int and retries
        -- only when it overflows negative.
        if bits - value + (bound - 1) < RANDOM_INT31 then return value end
    end
end

local function nextJavaFloat(state)
    return math.floor(nextJava31(state) / 128) / RANDOM_MODULUS
end

local function updateEffect(kind, effectId, position, seed, phaseDuration)
    if phaseDuration <= 0 then
        effects[effectId] = nil
        return
    end

    local now = CurTime()
    local effect = effects[effectId]
    if not effect then
        effect = { id = effectId, kind = kind }
        effects[effectId] = effect
    end
    effect.kind = kind
    effect.position = Vector(position.x, position.y, position.z)
    if effect.seed ~= seed then effect.lightningSegments = nil end
    effect.seed = seed
    effect.startedAt = now
    effect.flashEndsAt = now + phaseDuration
    -- Removal is explicit and reliable. This deadline is only a safety net for
    -- clients that leave the PVS before the server sends the final removal.
    effect.endsAt = now + LIGHTNING_EFFECT_TIMEOUT
end

local function spawnSoulParticle(effectId, position, seed, blockSize, baseVelocity)
    blockSize = math.max(tonumber(blockSize) or 36.5, 0.001)
    baseVelocity = isvector(baseVelocity) and baseVelocity or Vector(0, 0, 0.1)
    local random = newJavaRandom(seed)

    -- Particle's base constructor consumes a random lifetime before
    -- RisingParticle replaces it. Preserve the complete Java random order so
    -- size, position jitter and final lifetime stay deterministic.
    nextJavaFloat(random)
    -- Particle uses Minecraft X/Y/Z, where Y is vertical.  Source uses Z as
    -- vertical, so preserve Java's random-consumption order first and only map
    -- the finished values back to Source axes afterward.
    local javaVelocityX = baseVelocity.x + (nextJavaFloat(random) * 2 - 1) * 0.4
    local javaVelocityY = baseVelocity.z + (nextJavaFloat(random) * 2 - 1) * 0.4
    local javaVelocityZ = baseVelocity.y + (nextJavaFloat(random) * 2 - 1) * 0.4
    local power = (nextJavaFloat(random) + nextJavaFloat(random) + 1) * 0.15
    local velocityLength = math.sqrt(
        javaVelocityX * javaVelocityX
        + javaVelocityY * javaVelocityY
        + javaVelocityZ * javaVelocityZ)
    if velocityLength > 1e-8 then
        javaVelocityX = javaVelocityX / velocityLength * power * 0.4
        javaVelocityY = javaVelocityY / velocityLength * power * 0.4 + 0.1
        javaVelocityZ = javaVelocityZ / velocityLength * power * 0.4
    else
        javaVelocityX, javaVelocityY, javaVelocityZ = 0, 0.1, 0
    end

    local size = (0.15 + nextJavaFloat(random) * 0.15) * blockSize * 2
    javaVelocityX = javaVelocityX * 0.01 + baseVelocity.x
    javaVelocityY = javaVelocityY * 0.01 + baseVelocity.z
    javaVelocityZ = javaVelocityZ * 0.01 + baseVelocity.y
    local javaJitterX = (nextJavaFloat(random) - nextJavaFloat(random)) * 0.05
    local javaJitterY = (nextJavaFloat(random) - nextJavaFloat(random)) * 0.05
    local javaJitterZ = (nextJavaFloat(random) - nextJavaFloat(random)) * 0.05
    local jitteredPosition = Vector(position.x, position.y, position.z)
        + Vector(javaJitterX, javaJitterZ, javaJitterY) * blockSize
    local lifetime = math.floor(8 / (nextJavaFloat(random) * 0.8 + 0.2)) + 4
    local now = CurTime()
    soulParticles[#soulParticles + 1] = {
        id = effectId,
        position = jitteredPosition,
        previousPosition = Vector(jitteredPosition.x, jitteredPosition.y, jitteredPosition.z),
        velocity = Vector(javaVelocityX, javaVelocityZ, javaVelocityY) * blockSize,
        size = size,
        blockSize = blockSize,
        age = 0,
        lifetime = lifetime,
        nextTickAt = now + TICK_SECONDS,
        stoppedByCollision = false,
        onGround = false,
    }
end

local function soulParticleCollisionFilter(entity)
    if not IsValid(entity) or entity:IsWorld() then return true end
    return SOUL_BLOCK_COLLISION_CLASSES[entity:GetClass()] == true
end

local function traceSoulParticleAxis(particle, startPosition, displacement)
    if displacement:LengthSqr() <= 0 then return startPosition end
    if not util or not isfunction(util.TraceHull) then return startPosition + displacement end

    -- SoulParticle scales Particle's 0.2 x 0.2 box by 1.5. Minecraft anchors
    -- that 0.3-block box at the particle's feet instead of centring it on Y.
    local half = 0.15 * particle.blockSize
    local trace = util.TraceHull({
        start = startPosition,
        endpos = startPosition + displacement,
        mins = Vector(-half, -half, 0),
        maxs = Vector(half, half, half * 2),
        mask = MASK_SOLID,
        -- Particle.move asks Level only for block collisions. Ignore players,
        -- NPCs and ordinary Source props while retaining map brushes and the
        -- MCSWEP entities that own voxel collision on each realm.
        filter = soulParticleCollisionFilter,
    })
    return trace and trace.HitPos or (startPosition + displacement)
end

local function moveSoulParticle(particle)
    if particle.stoppedByCollision then return end

    local displacement = particle.velocity
    local originalX, originalY, originalZ = displacement.x, displacement.y, displacement.z
    local position = particle.position

    -- Entity.collideWithShapes uses Direction.axisStepOrder: Java Y first,
    -- then the smaller horizontal component. Java X/Z map to Source X/Y.
    local afterVertical = traceSoulParticleAxis(
        particle, position, Vector(0, 0, originalZ))
    local resolvedZ = afterVertical.z - position.z
    local afterFirstHorizontal, finalPosition
    local resolvedX, resolvedY
    if math.abs(originalX) < math.abs(originalY) then
        afterFirstHorizontal = traceSoulParticleAxis(
            particle, afterVertical, Vector(0, originalY, 0))
        resolvedY = afterFirstHorizontal.y - afterVertical.y
        finalPosition = traceSoulParticleAxis(
            particle, afterFirstHorizontal, Vector(originalX, 0, 0))
        resolvedX = finalPosition.x - afterFirstHorizontal.x
    else
        afterFirstHorizontal = traceSoulParticleAxis(
            particle, afterVertical, Vector(originalX, 0, 0))
        resolvedX = afterFirstHorizontal.x - afterVertical.x
        finalPosition = traceSoulParticleAxis(
            particle, afterFirstHorizontal, Vector(0, originalY, 0))
        resolvedY = finalPosition.y - afterFirstHorizontal.y
    end

    local epsilon = SOUL_COLLISION_EPSILON_BLOCKS * particle.blockSize
    particle.position = finalPosition
    if math.abs(resolvedX - originalX) > epsilon then particle.velocity.x = 0 end
    if math.abs(resolvedY - originalY) > epsilon then particle.velocity.y = 0 end
    particle.onGround = originalZ < 0 and math.abs(resolvedZ - originalZ) > epsilon
    -- Particle.move deliberately does not zero vertical velocity. Once a
    -- non-trivial vertical request is reduced to zero it instead freezes all
    -- later movement through stoppedByCollision.
    if math.abs(originalZ) >= epsilon and math.abs(resolvedZ) <= epsilon then
        particle.stoppedByCollision = true
    end
end

net.Receive(NET_EVENT, function()
    local kind = net.ReadUInt(2)
    local effectId = net.ReadUInt(32)
    local position = net.ReadVector()
    local seed = net.ReadUInt(24) + net.ReadUInt(24) * RANDOM_MODULUS
    local phaseDuration = net.ReadFloat()
    if kind == FX_SOUL_SPEED then
        spawnSoulParticle(effectId, position, seed, phaseDuration, net.ReadVector())
    else
        updateEffect(kind, effectId, position, seed, phaseDuration)
    end
end)

local fireVertex = Vector(0, 0, 0)

local function addFireVertex(x, y, z, u, v)
    fireVertex.x, fireVertex.y, fireVertex.z = x, y, z
    mesh.Position(fireVertex)
    mesh.TexCoord(0, u, v)
    mesh.Color(255, 255, 255, 255)
    mesh.AdvanceVertex()
end

-- Position/right/up are passed as scalar components so the per-layer quad
-- does not allocate Vectors.  `up` is always world +Z for flame layers.
local function drawFireLayer(px, py, pz, rightX, rightY, rightZ, upX, upY, upZ,
        width, height, material, flip, frame)
    material:SetInt("$frame", frame)
    render.SetMaterial(material)
    local u0, u1 = 0, 1
    if flip then u0, u1 = u1, u0 end
    local rx, ry, rz = rightX * width, rightY * width, rightZ * width
    local ux, uy, uz = upX * height, upY * height, upZ * height
    mesh.Begin(MATERIAL_QUADS, 1)
    addFireVertex(px - rx - ux, py - ry - uy, pz - rz - uz, u1, 1)
    addFireVertex(px - rx + ux, py - ry + uy, pz - rz + uz, u1, 0)
    addFireVertex(px + rx + ux, py + ry + uy, pz + rz + uz, u0, 0)
    addFireVertex(px + rx - ux, py + ry - uy, pz + rz - uz, u0, 1)
    mesh.End()
end

local function drawFlameArrow(arrow)
    if not IsValid(arrow) or not arrow:GetNW2Bool("MCITEM_FlameArrow", false) then return end
    local flameUntil = arrow:GetNW2Float("MCITEM_FlameArrowUntil", 0)
    if flameUntil > 0 and CurTime() >= flameUntil then return end
    Runtime.DrawFlameEntity(arrow)
    local light = DynamicLight(arrow:EntIndex())
    if light then
        light.pos = arrow:WorldSpaceCenter()
        light.r, light.g, light.b = 255, 148, 64
        light.brightness = 2
        light.decay = 600
        light.size = (isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5) * 3
        light.dietime = CurTime() + 0.1
    end
end

function Runtime.DrawFlameEntity(entity)
    if not IsValid(entity) then return false end
    local mins, maxs
    if entity.GetCollisionBounds then mins, maxs = entity:GetCollisionBounds() end
    if not mins or not maxs or maxs.z - mins.z <= 0.01 then mins, maxs = entity:OBBMins(), entity:OBBMaxs() end
    local width = math.max(maxs.x - mins.x, maxs.y - mins.y)
    local height = maxs.z - mins.z
    if width <= 0.01 or height <= 0.01 then return false end
    local scale = width * 1.4
    local remaining = height / scale
    local base = entity:LocalToWorld(vector_origin)
    -- Angle(0, yaw, 0): Forward = (cos, sin, 0), Right = (sin, -cos, 0); both
    -- are already horizontal unit vectors.
    local yawRadians = math.rad(EyeAngles().y)
    local yawCos, yawSin = math.cos(yawRadians), math.sin(yawRadians)
    local normalX, normalY = -yawCos, -yawSin
    local rightX, rightY = yawSin, -yawCos
    local baseX, baseY, baseZ = base.x, base.y, base.z
    local frame = math.floor(CurTime() / 0.05) % FIRE_FRAME_COUNT
    local halfWidth, verticalOffset = 0.5, 0
    local depthOffset = 0.3 - math.floor(remaining) * 0.02
    local layer = 0
    while remaining > 0 and layer < 64 do
        local material = layer % 2 == 0 and fire0 or fire1
        local depth = (depthOffset + FIRE_DEPTH_BIAS) * scale
        drawFireLayer(baseX + normalX * depth, baseY + normalY * depth,
            baseZ + (verticalOffset + 0.7) * scale,
            rightX, rightY, 0, 0, 0, 1,
            halfWidth * scale, 0.7 * scale, material,
            math.floor(layer / 2) % 2 == 0, frame)
        remaining = remaining - 0.45
        verticalOffset = verticalOffset + 0.45
        depthOffset = depthOffset - 0.03
        halfWidth = halfWidth * 0.9
        layer = layer + 1
    end
    return true
end

local function lightningPoint(origin, x, horizontalZ, verticalY, blockSize)
    -- Minecraft uses Y as its vertical axis; Source uses Z.
    return origin + Vector(x, horizontalZ, verticalY) * blockSize
end

local function appendLightningQuad(quads, origin, blockSize, currentX, currentZ, segment,
        previousX, previousZ, upperWidth, lowerWidth,
        lowerPositiveX, lowerPositiveZ, upperPositiveX, upperPositiveZ)
    local lowerX = currentX + (lowerPositiveX and lowerWidth or -lowerWidth)
    local lowerZ = currentZ + (lowerPositiveZ and lowerWidth or -lowerWidth)
    quads[#quads + 1] = {
        lightningPoint(origin, lowerX, lowerZ, segment * 16, blockSize),
        lightningPoint(origin,
            previousX + (lowerPositiveX and upperWidth or -upperWidth),
            previousZ + (lowerPositiveZ and upperWidth or -upperWidth),
            (segment + 1) * 16,
            blockSize),
        lightningPoint(origin,
            previousX + (upperPositiveX and upperWidth or -upperWidth),
            previousZ + (upperPositiveZ and upperWidth or -upperWidth),
            (segment + 1) * 16,
            blockSize),
        lightningPoint(origin,
            currentX + (upperPositiveX and lowerWidth or -lowerWidth),
            currentZ + (upperPositiveZ and lowerWidth or -lowerWidth),
            segment * 16,
            blockSize),
    }
end

local function lightningSegments(effect)
    local blockSize = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
    local baseState = newJavaRandom(effect.seed)
    local xOffsets, zOffsets = {}, {}
    local baseX, baseZ = 0, 0

    -- LightningBoltRenderer builds eight 16-block-high sections from the top
    -- down.  These numbers are Minecraft blocks, so the full block scale is
    -- intentional: a vanilla bolt is roughly 128 blocks tall.
    for index = 7, 0, -1 do
        xOffsets[index] = baseX
        zOffsets[index] = baseZ
        baseX = baseX + nextInteger(baseState, 11) - 5
        baseZ = baseZ + nextInteger(baseState, 11) - 5
    end

    local quads = {}
    for pass = 0, 3 do
        -- Java recreates RandomSource from the same seed for every pass.  The
        -- four passes therefore share a path and differ only in tube width.
        local state = newJavaRandom(effect.seed)
        for branch = 0, 2 do
            local fromIndex = branch == 0 and 7 or 7 - branch
            local toIndex = branch == 0 and 0 or fromIndex - 2
            local x = xOffsets[fromIndex] - baseX
            local z = zOffsets[fromIndex] - baseZ

            for index = fromIndex, toIndex, -1 do
                local previousX, previousZ = x, z
                local randomBound, randomCenter = branch == 0 and 11 or 31, branch == 0 and 5 or 15
                x = x + nextInteger(state, randomBound) - randomCenter
                z = z + nextInteger(state, randomBound) - randomCenter

                local upperWidth = 0.1 + pass * 0.2
                local lowerWidth = upperWidth
                if branch == 0 then
                    upperWidth = upperWidth * (1 + index * 0.1)
                    lowerWidth = lowerWidth * (1 + (index - 1) * 0.1)
                end

                -- LightningBoltRenderer.quad is called four times to form a
                -- square tube around each section.  Vertex alpha is always
                -- 0.3 in Java; visibility is switched by bolt lifetime rather
                -- than faded over time.
                appendLightningQuad(quads, effect.position, blockSize, x, z, index,
                    previousX, previousZ, upperWidth, lowerWidth, false, false, true, false)
                appendLightningQuad(quads, effect.position, blockSize, x, z, index,
                    previousX, previousZ, upperWidth, lowerWidth, true, false, true, true)
                appendLightningQuad(quads, effect.position, blockSize, x, z, index,
                    previousX, previousZ, upperWidth, lowerWidth, true, true, false, true)
                appendLightningQuad(quads, effect.position, blockSize, x, z, index,
                    previousX, previousZ, upperWidth, lowerWidth, false, true, false, false)
            end
        end
    end
    return quads
end

local function addLightningVertex(position)
    mesh.Position(position)
    mesh.TexCoord(0, 0, 0)
    mesh.Color(115, 115, 128, 77)
    mesh.AdvanceVertex()
end

local function drawLightning(effect, flashActive)
    effect.lightningSegments = effect.lightningSegments or lightningSegments(effect)
    render.SetMaterial(lightningMaterial)
    mesh.Begin(MATERIAL_QUADS, #effect.lightningSegments)
    for _, quad in ipairs(effect.lightningSegments) do
        addLightningVertex(quad[1])
        addLightningVertex(quad[2])
        addLightningVertex(quad[3])
        addLightningVertex(quad[4])
    end
    mesh.End()

    local light = flashActive and DynamicLight(30000 + effect.id % 10000) or nil
    if light then
        light.pos = effect.position
        light.r, light.g, light.b = 150, 160, 255
        light.brightness = 5
        light.decay = 1500
        light.size = (isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5) * 12
        light.dietime = CurTime() + 0.1
    end
end

local function drawSoulParticles(now)
    for index = #soulParticles, 1, -1 do
        local particle = soulParticles[index]
        local alive = true
        while alive and now >= particle.nextTickAt do
            particle.previousPosition = Vector(
                particle.position.x, particle.position.y, particle.position.z)
            local oldAge = particle.age
            particle.age = oldAge + 1
            particle.nextTickAt = particle.nextTickAt + TICK_SECONDS
            -- Particle.tick uses age++ >= lifetime, so age == lifetime still
            -- moves and renders the final sprite for one complete tick.
            if oldAge >= particle.lifetime then
                alive = false
            else
                moveSoulParticle(particle)
                particle.velocity = particle.velocity * 0.96
                if particle.onGround then
                    particle.velocity.x = particle.velocity.x * 0.7
                    particle.velocity.y = particle.velocity.y * 0.7
                end
            end
        end
        if not alive then
            table.remove(soulParticles, index)
        else
            local frame = math.Clamp(
                math.floor(particle.age * (SOUL_FRAME_COUNT - 1) / particle.lifetime),
                0,
                SOUL_FRAME_COUNT - 1
            )
            soulMaterial:SetInt("$frame", frame)
            render.SetMaterial(soulMaterial)
            local previous = particle.previousPosition or particle.position
            local partialTick = math.Clamp(
                1 - (particle.nextTickAt - now) / TICK_SECONDS, 0, 1)
            local renderPosition = previous
                + (particle.position - previous) * partialTick
            local sampled = render.GetLightColor and render.GetLightColor(renderPosition)
                or Vector(1, 1, 1)
            if not isvector(sampled) then sampled = Vector(1, 1, 1) end
            render.DrawSprite(renderPosition, particle.size, particle.size, Color(
                math.Clamp(math.floor((tonumber(sampled.x) or 1) * 255 + 0.5), 0, 255),
                math.Clamp(math.floor((tonumber(sampled.y) or 1) * 255 + 0.5), 0, 255),
                math.Clamp(math.floor((tonumber(sampled.z) or 1) * 255 + 0.5), 0, 255),
                255
            ))
        end
    end
end

-- Track mcitem_arrow entities by creation/removal instead of scanning every
-- entity with ents.FindByClass each frame.  drawFlameArrow still checks the
-- NW2 flame state, so non-burning arrows are skipped cheaply.
local ARROW_CLASS = "mcitem_arrow"
Runtime.TrackedArrows = Runtime.TrackedArrows or {}
local trackedArrows = Runtime.TrackedArrows
for arrow in pairs(trackedArrows) do
    if not IsValid(arrow) then trackedArrows[arrow] = nil end
end
for _, arrow in ipairs(ents.FindByClass(ARROW_CLASS)) do trackedArrows[arrow] = true end

hook.Add("OnEntityCreated", "MCITEM.EnchantmentRuntime.TrackArrows", function(entity)
    if IsValid(entity) and entity:GetClass() == ARROW_CLASS then trackedArrows[entity] = true end
end)
hook.Add("EntityRemoved", "MCITEM.EnchantmentRuntime.TrackArrows", function(entity, fullUpdate)
    -- A full update keeps the same client entity alive.
    if fullUpdate then return end
    trackedArrows[entity] = nil
end)

hook.Remove("PostDrawOpaqueRenderables", "MCITEM.EnchantmentRuntime.DrawFlame")
hook.Add("PostDrawOpaqueRenderables", "MCITEM.EnchantmentRuntime.DrawFlame", function(drawingDepth, drawingSkybox, draw3DSkybox)
    if drawingDepth or drawingSkybox or draw3DSkybox then return end
    for arrow in pairs(trackedArrows) do drawFlameArrow(arrow) end
end)

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.EnchantmentRuntime.DrawFX")
hook.Add("PostDrawTranslucentRenderables", "MCITEM.EnchantmentRuntime.DrawFX", function(_, drawingSkybox)
    if drawingSkybox then return end
    local now = CurTime()
    for effectId, effect in pairs(effects) do
        if now >= effect.endsAt then
            effects[effectId] = nil
        else
            if effect.kind == FX_LIGHTNING then
                -- The bolt entity remains rendered during negative-life waits;
                -- only the sky-flash light turns off until the seed changes.
                drawLightning(effect, now < (effect.flashEndsAt or 0))
            end
        end
    end
    drawSoulParticles(now)
end)
