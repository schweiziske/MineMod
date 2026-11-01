-- Minecraft 26.2 melee combat particles.
--
-- This deliberately does not use Source's continuous particle physics. Minecraft advances
-- these particles at 20 Hz, so every particle keeps its own MC-tick clock and interpolates
-- only while drawing. The constants and update order come from:
--   TrackingEmitter / CritParticle / AttackSweepParticle / SingleQuadParticle.

MCITEM = MCITEM or {}

local Combat = MCITEM.CombatParticles or {}
MCITEM.CombatParticles = Combat

local TICK_SECONDS = 1 / 20
local CRIT_FRICTION = 0.7
local CRIT_GRAVITY = 0.5
local SWEEP_LIFETIME = 4
local MAX_CATCHUP_TICKS = 8

local FX_CRIT = 0
local FX_DAMAGE = 1
local FX_SWEEP = 2
local FX_ARROW_CRIT = 3

Combat.Particles = Combat.Particles or {}
Combat.Emitters = Combat.Emitters or {}

-- 全局粒子预算（`mcitem_particle_limit`，见 sh_tuning.lua）。一次重锤是 750 个粒子，
-- 叠上药水 / 食物 / 投掷物就能把低配机拖垮。超预算时**丢最老的**而不是拒绝新效果：
-- 玩家正在看的是新那一个。
if isfunction(MCITEM.RegisterParticlePool) then
    MCITEM.RegisterParticlePool("combat", Combat.Particles)
end

local function reserveParticles(count)
    if isfunction(MCITEM.ReserveParticles) then return MCITEM.ReserveParticles(count) end
    return count
end

local function particleMaterial(name, texture)
    return CreateMaterial("mcitem_particle_" .. name, "UnlitGeneric", {
        ["$basetexture"] = texture,
        ["$translucent"] = "1",
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1",
        ["$nocull"] = "1",
        ["$nolod"] = "1",
    })
end

Combat.Materials = Combat.Materials or {
    crit = particleMaterial("critical_hit", "mcitem/particles/critical_hit"),
    damage = particleMaterial("damage", "mcitem/particles/damage"),
    sweep = {
        particleMaterial("sweep_0", "mcitem/particles/sweep_0"),
        particleMaterial("sweep_1", "mcitem/particles/sweep_1"),
        particleMaterial("sweep_2", "mcitem/particles/sweep_2"),
        particleMaterial("sweep_3", "mcitem/particles/sweep_3"),
        particleMaterial("sweep_4", "mcitem/particles/sweep_4"),
        particleMaterial("sweep_5", "mcitem/particles/sweep_5"),
        particleMaterial("sweep_6", "mcitem/particles/sweep_6"),
        -- ⚠ Material() 返回 **两个** 值（IMaterial, 载入耗时）。写在表构造式最后一项
        -- 会把那个数字一起展开进表里；`maceDust` 以前就是这么多出一个 number 元素，
        -- 随机抽到它就是 `SetMaterial (IMaterial expected, got number)`。
        -- 所有 Material() 调用一律用括号截断成单值。
        (particleMaterial("sweep_7", "mcitem/particles/sweep_7")),
    },
}

--------------------------------------------------------------------------------
-- MCSWEP 体素采光（MC.API.Light.SampleRGB）
--------------------------------------------------------------------------------
--
-- 以前用的是 render.GetLightColor：那是 **Source 地图的 lightmap**，跟 MCSWEP 的方块
-- 世界毫无关系，在 gm_flatgrass 这种图上大约只有 0.3~0.5，于是暴击星/箭尾迹再叠上
-- CritParticle 自己的 0.6~0.9 随机灰度就变成暗灰色 —— 这就是"射出来的粒子偏暗"。
-- 贴图本身没问题（10 张战斗粒子 VTF 与 Mojang PNG 逐像素一致，本轮复核过）。
--
-- 采光走 v1 的 `MC.API.Light.SampleRGB(pos, emission)`（display 空间 RGB，直接当顶点色
-- 乘数，和 MCSWEP 自己的方块簇 / 手持方块同约定，**不叠实体模型那档 0.48 曝光**）。
-- MCSWEP 不在场时退回 1,1,1（全亮），比 Source lightmap 更接近 MC 的观感。
-- 按"格 + emission"缓存一小段时间：一次重锤是 750 个粒子，逐粒子直调采样器太贵。

local LIGHT_CACHE_SECONDS = 0.15
-- lightCache[cellX][cellY][cellZ * 16 + emission] = { r, g, b, expires }.
-- Numeric nested keys avoid a string.format per lookup; expired entries are
-- overwritten in place.
local lightCache = {}
local lightCacheCount = 0

local function mcSampleRGB()
    if not MC or not istable(MC.API) then return nil end
    local light = MC.API.Light
    if istable(light) and isfunction(light.SampleRGB) then return light.SampleRGB end
    return nil
end

function MCITEM.SampleParticleLightRGB(position, emission)
    local sample = mcSampleRGB()
    if not sample then return 1, 1, 1 end

    emission = math.Clamp(math.floor(tonumber(emission) or 0), 0, 15)
    local blockSize = MCITEM.BlockSize()
    local cellX = math.floor(position.x / blockSize)
    local cellY = math.floor(position.y / blockSize)
    local key = math.floor(position.z / blockSize) * 16 + emission

    local now = CurTime()
    local column = lightCache[cellX]
    local row = column and column[cellY]
    local hit = row and row[key]
    if hit and hit.expires > now then return hit.r, hit.g, hit.b end

    local ok, r, g, b = pcall(sample, position, emission)
    if not ok or r == nil or g == nil or b == nil then
        r, g, b = 1, 1, 1
    end
    r = math.Clamp(tonumber(r) or 1, 0, 1)
    g = math.Clamp(tonumber(g) or 1, 0, 1)
    b = math.Clamp(tonumber(b) or 1, 0, 1)

    if hit then
        hit.r, hit.g, hit.b, hit.expires = r, g, b, now + LIGHT_CACHE_SECONDS
        return r, g, b
    end

    if lightCacheCount > 512 then
        lightCache = {}
        lightCacheCount = 0
        column, row = nil, nil
    end
    if not column then
        column = {}
        lightCache[cellX] = column
    end
    if not row then
        row = {}
        column[cellY] = row
    end
    lightCacheCount = lightCacheCount + 1
    row[key] = { r = r, g = g, b = b, expires = now + LIGHT_CACHE_SECONDS }

    return r, g, b
end

-- SingleQuadParticle 的顶点色 = 粒子自己的 rgb × getLightColor()。世界光走上面的
-- MCSWEP 体素采样器。
--
-- ⚠ 采光**每个粒子只在生成时算一次**。一次重锤是 750 个粒子、每个活 1~2 秒，逐帧
-- 逐粒子采样即使有按格缓存也要付 750 次字符串拼接 + table 查询，实测就是掉帧的大头。
-- 尘柱只飞不到两格、暴击星只活几 tick，期间光照几乎不变，缓在粒子上完全够用。
local function cacheParticleLight(particle)
    local r, g, b = MCITEM.SampleParticleLightRGB(particle.position, 0)
    particle.litR = math.Clamp(particle.red * r, 0, 1)
    particle.litG = math.Clamp(particle.green * g, 0, 1)
    particle.litB = math.Clamp(particle.blue * b, 0, 1)
end

--------------------------------------------------------------------------------
-- 重锤尘柱的方块贴图（TerrainParticle）
--------------------------------------------------------------------------------
--
-- MC 的 `levelEvent(2013, pos, 750)` 发的是 TerrainParticle.DustPillarProvider，贴图取
-- **被砸那一格方块的 particle sprite**，而且每个粒子只采该 sprite 的一个 1/4 × 1/4 子块：
--     getU0 = sprite.getU((uo+1)/4)   getU1 = sprite.getU(uo/4)     -- uo,vo ∈ [0,3)
--     getV0 = sprite.getV(vo/4)       getV1 = sprite.getV((vo+1)/4)
-- MCSWEP 的图集里已经有等价物：`MC.GetBlockParticleMaterial(id, col, row)` 返回一张带
-- `$basetexturetransform` 的代理材质，正好把 0..1 的 UV 映射到那 1/4 子块，可以直接喂
-- render.DrawSprite。这是内部符号（v1 的 API.Render 只有 MarkCellDirty，见
-- docs/MCSWEP_API_V1_GAP.md 第七节），所以逐个探测、拿不到就退回自带贴图。
--
-- 落点不在 MCSWEP 方块上时（站在 gm_flatgrass 的地面、prop 上等）用**泥土**粒子兜底，
-- 这是本轮拍板的行为：泥土贴图自带在 materials/mcitem/particles/dirt，所以 MCSWEP
-- 完全缺席也有正确观感。

local DUST_UV_STEPS = 4

local dirtDustMaterials = {}

-- 自带泥土贴图的 16 张 1/4 子块材质，和 MCSWEP 代理材质同样的 basetexturetransform 算法。
local function dirtDustMaterial(col, row)
    local key = col .. "," .. row
    local cached = dirtDustMaterials[key]
    if cached then return cached end

    local scale = 1 / DUST_UV_STEPS
    local material = CreateMaterial("mcitem_particle_dirt_" .. col .. "_" .. row, "UnlitGeneric", {
        ["$basetexture"] = "mcitem/particles/dirt",
        ["$translucent"] = "1",
        ["$vertexcolor"] = "1",
        ["$vertexalpha"] = "1",
        ["$nocull"] = "1",
        ["$nolod"] = "1",
        ["$pointsample"] = "1",
        ["$basetexturetransform"] = string.format(
            "center 0 0 scale %.9f %.9f rotate 0 translate %.9f %.9f",
            scale, scale, col * scale, row * scale
        ),
    })

    dirtDustMaterials[key] = material
    return material
end

-- 被砸那一格的方块 id（脚下一格）。MCSWEP 不在场 / 那格是空气时返回 nil。
local function smashBlockId(position)
    if not MC or not istable(MC.API) then return nil end
    if isfunction(MC.API.IsReady) and not MC.API.IsReady() then return nil end

    local coords, world = MC.API.Coords, MC.API.World
    if not istable(coords) or not istable(world) then return nil end
    if not isfunction(coords.WorldToCell) or not isfunction(world.GetBlockInfo) then return nil end

    -- levelEvent 用的是 target.getOnPos()：脚底**下面**那一格，不是脚所在的格。
    local bx, by, bz = coords.WorldToCell(position - Vector(0, 0, MCITEM.BlockSize() * 0.25))
    if bx == nil then return nil end

    local info = world.GetBlockInfo(bx, by, bz)
    return info and info.id or nil
end

local function dustMaterialFor(blockId, col, row)
    if blockId and isfunction(MC and MC.GetBlockParticleMaterial) then
        local material = MC.GetBlockParticleMaterial(blockId, col, row)
        if material and not material:IsError() then return material end
    end
    return dirtDustMaterial(col, row)
end

local function randomSigned()
    return math.Rand(-1, 1)
end

-- ServerLevel.sendParticles uses a Gaussian for both position spread and velocity.
local function randomGaussian()
    local u1 = math.max(math.Rand(0, 1), 1e-7)
    local u2 = math.Rand(0, 1)
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Particle(x,y,z,0,0,0) still creates a small randomized base velocity. CritParticle then
-- multiplies that result by 0.1 before adding the caller-supplied velocity * 0.4.
local function particleBaseVelocity()
    local x = math.Rand(-0.4, 0.4)
    local y = math.Rand(-0.4, 0.4)
    local z = math.Rand(-0.4, 0.4)
    local length = math.sqrt(x * x + y * y + z * z)

    if length <= 1e-7 then
        x, y, z, length = 1, 0, 0, 1
    end

    local speed = (math.Rand(0, 1) + math.Rand(0, 1) + 1) * 0.15
    return Vector(
        x / length * speed * 0.4,
        y / length * speed * 0.4,
        z / length * speed * 0.4 + 0.1
    )
end

-- Crit and mace-dust particles own distinct position/oldPosition/velocity
-- Vectors (created in their spawn functions), so ticks update them in place.
local function tickCritParticle(particle)
    local position, oldPosition = particle.position, particle.oldPosition
    oldPosition.x, oldPosition.y, oldPosition.z = position.x, position.y, position.z

    -- Particle.tick uses post-increment: remove only when the old age is already lifetime.
    if particle.age >= particle.lifetime then
        particle.age = particle.age + 1
        particle.removed = true
        return
    end

    particle.age = particle.age + 1
    local velocity = particle.velocity
    velocity.z = velocity.z - 0.04 * CRIT_GRAVITY
    local blockSize = MCITEM.BlockSize()
    position.x = position.x + velocity.x * blockSize
    position.y = position.y + velocity.y * blockSize
    position.z = position.z + velocity.z * blockSize
    velocity.x, velocity.y, velocity.z = velocity.x * CRIT_FRICTION,
        velocity.y * CRIT_FRICTION, velocity.z * CRIT_FRICTION
    particle.green = particle.green * 0.96
    particle.blue = particle.blue * 0.9
end

local function spawnCritParticle(material, position, auxiliaryVelocity, forcedLifetime)
    local now = CurTime()
    local velocity = particleBaseVelocity() * 0.1 + auxiliaryVelocity * 0.4
    local shade = math.Rand(0.6, 0.9)

    local particle = {
        kind = "crit",
        material = material,
        position = Vector(position.x, position.y, position.z),
        oldPosition = Vector(position.x, position.y, position.z),
        velocity = velocity,
        red = shade,
        green = shade,
        blue = shade,
        -- SingleQuadParticle random 0.1..0.2 half-size, then CritParticle * 0.75.
        quadSize = 0.1 * math.Rand(0.5, 1.0) * 2 * 0.75,
        lifetime = math.max(math.floor(6 / math.Rand(0.6, 1.4)), 1),
        age = 0,
        lastTickAt = now,
        nextTickAt = now + TICK_SECONDS,
    }

    -- CritParticle's constructor immediately calls tick(), then the damage-indicator provider
    -- overwrites lifetime with 20.
    tickCritParticle(particle)
    if forcedLifetime then particle.lifetime = forcedLifetime end

    cacheParticleLight(particle)
    table.insert(Combat.Particles, particle)
end

local function entityParticleBounds(emitter)
    local target = emitter.entity
    if IsValid(target) then
        local mins, maxs = target:WorldSpaceAABB()
        return (mins + maxs) * 0.5, maxs - mins, mins.z
    end

    local size = emitter.fallbackSize
    return emitter.fallbackCenter, size, emitter.fallbackCenter.z - size.z * 0.5
end

local function emitCritRound(emitter)
    local center, size, feetZ = entityParticleBounds(emitter)
    local budget = reserveParticles(16)

    -- TrackingEmitter attempts exactly 16 samples and discards points outside the unit sphere.
    for _ = 1, 16 do
        if budget <= 0 then break end

        local xa = randomSigned()
        local ya = randomSigned()
        local za = randomSigned()

        if xa * xa + ya * ya + za * za <= 1 then
            local position = Vector(
                center.x + xa * size.x * 0.25,
                center.y + za * size.y * 0.25,
                feetZ + size.z * (0.5 + ya * 0.25)
            )
            -- Minecraft axes: X/Z horizontal, Y vertical. Source uses Z vertically.
            local velocity = Vector(xa, za, ya + 0.2)
            spawnCritParticle(Combat.Materials.crit, position, velocity)
            budget = budget - 1
        end
    end
end

function Combat.EmitCritical(target, fallbackCenter, fallbackSize)
    local now = CurTime()
    local emitter = {
        entity = target,
        fallbackCenter = fallbackCenter,
        fallbackSize = fallbackSize,
        life = 0,
        nextTickAt = now + TICK_SECONDS,
    }

    -- TrackingEmitter constructor calls tick immediately, then repeats for two more ticks.
    emitCritRound(emitter)
    emitter.life = 1
    table.insert(Combat.Emitters, emitter)
end

function Combat.EmitDamage(center, count)
    count = reserveParticles(count)
    for _ = 1, count do
        local position = center + Vector(
            randomGaussian() * 0.1 * MCITEM.BlockSize(),
            randomGaussian() * 0.1 * MCITEM.BlockSize(),
            0
        )
        local velocity = Vector(
            randomGaussian() * 0.2,
            randomGaussian() * 0.2,
            randomGaussian() * 0.2 + 1.0
        )
        spawnCritParticle(Combat.Materials.damage, position, velocity, 20)
    end
end

-- Small public bridge for entity effects that need Java's CRIT particle but
-- do not have a LivingEntity TrackingEmitter.  Distances and auxiliary
-- velocities are expressed in Minecraft cells so callers remain independent
-- of the active MCSWEP block scale.
function Combat.EmitCriticalBurst(position, count, options)
    if not isvector(position) then return end
    options = istable(options) and options or {}

    count = math.max(0, math.floor(tonumber(count) or 0))
    count = reserveParticles(count)
    local blockSize = MCITEM.BlockSize()
    local horizontalSpread = math.max(0, tonumber(options.horizontalSpreadCells) or 0)
    local verticalMin = tonumber(options.verticalOffsetMinCells) or 0
    local verticalMax = tonumber(options.verticalOffsetMaxCells) or verticalMin
    local horizontalSpeed = math.max(0, tonumber(options.horizontalSpeedCells) or 0)
    local verticalSpeedMin = tonumber(options.verticalSpeedMinCells) or 0
    local verticalSpeedMax = tonumber(options.verticalSpeedMaxCells) or verticalSpeedMin
    if verticalMax < verticalMin then verticalMin, verticalMax = verticalMax, verticalMin end
    if verticalSpeedMax < verticalSpeedMin then
        verticalSpeedMin, verticalSpeedMax = verticalSpeedMax, verticalSpeedMin
    end

    for _ = 1, count do
        local spawnPosition = position + Vector(
            math.Rand(-horizontalSpread, horizontalSpread) * blockSize,
            math.Rand(-horizontalSpread, horizontalSpread) * blockSize,
            math.Rand(verticalMin, verticalMax) * blockSize
        )
        local auxiliaryVelocity = Vector(
            math.Rand(-horizontalSpeed, horizontalSpeed),
            math.Rand(-horizontalSpeed, horizontalSpeed),
            math.Rand(verticalSpeedMin, verticalSpeedMax)
        )
        spawnCritParticle(Combat.Materials.crit, spawnPosition, auxiliaryVelocity)
    end
end

function Combat.EmitSweep(position)
    local now = CurTime()
    local shade = math.Rand(0.4, 1.0)

    local particle = {
        kind = "sweep",
        position = position,
        oldPosition = position,
        red = shade,
        green = shade,
        blue = shade,
        quadSize = 1,
        lifetime = SWEEP_LIFETIME,
        age = 0,
        frame = 0,
        lastTickAt = now,
        nextTickAt = now + TICK_SECONDS,
    }
    cacheParticleLight(particle)
    table.insert(Combat.Particles, particle)
end

function Combat.EmitArrowCritical(position, movement)
    -- AbstractArrow.tick emits four CRIT particles along the current movement segment.
    local budget = reserveParticles(4)
    for index = 0, budget - 1 do
        spawnCritParticle(
            Combat.Materials.crit,
            position + movement * (index / 4) * MCITEM.BlockSize(),
            -movement + Vector(0, 0, 0.2)
        )
    end
end

local function spawnMaceDust(blockId, position, verticalAux)
    local now = CurTime()
    local particle = {
        kind = "mace_dust",
        -- TerrainParticle 的 uo/vo 是每个粒子各自随机的 1/4 子块。
        material = dustMaterialFor(
            blockId,
            math.random(0, DUST_UV_STEPS - 1),
            math.random(0, DUST_UV_STEPS - 1)
        ),
        position = Vector(position.x, position.y, position.z),
        oldPosition = Vector(position.x, position.y, position.z),
        -- TerrainParticle.DustPillarProvider replaces horizontal speed with
        -- gaussian/30 and adds gaussian/2 to the event-provided vertical speed.
        velocity = Vector(
            randomGaussian() / 30,
            randomGaussian() / 30,
            verticalAux + randomGaussian() / 2
        ),
        -- TerrainParticle 构造式：rCol = gCol = bCol = 0.6（再乘方块 tint，
        -- MCSWEP 的图集贴图已经是最终颜色，不另外乘 tint）。
        red = 0.6,
        green = 0.6,
        blue = 0.6,
        -- SingleQuadParticle 的 0.1 * rand(0.5,1) * 2，TerrainParticle 再 /2。
        quadSize = math.Rand(0.05, 0.1),
        lifetime = math.random(20, 39),
        age = 0,
        lastTickAt = now,
        nextTickAt = now + TICK_SECONDS,
    }
    cacheParticleLight(particle)
    table.insert(Combat.Particles, particle)
end

function Combat.EmitMaceSmash(position)
    local blockSize = MCITEM.BlockSize()
    -- 整柱共用一格方块（levelEvent 只带一个 BlockPos），逐粒子只随机 UV 子块。
    local blockId = smashBlockId(position)

    -- ParticleUtils.spawnSmashAttackParticles(level, pos, 750): count/3 central
    -- dust pillars, then count/1.5 samples around a 3.5-block ring.
    -- 预算不够时按同一比例缩两个循环（中心柱和外圈同时变稀，而不是砍掉一整圈）。
    local ratio = reserveParticles(750) / 750
    local centreCount = math.floor(250 * ratio)
    local ringCount = math.floor(500 * ratio)

    for _ = 1, centreCount do
        spawnMaceDust(blockId, position + Vector(
            randomGaussian() * 0.5 * blockSize,
            randomGaussian() * 0.5 * blockSize,
            0
        ), randomGaussian() * 0.2)
    end

    -- 环上的采样点在 MC 里是 `index` 直接当弧度用的（cos(i)/sin(i)），粒子变稀时
    -- 仍然要覆盖整圈，所以步长按缩放比例拉开。
    local step = ringCount > 0 and (500 / ringCount) or 1
    for index = 0, ringCount - 1 do
        local angle = index * step
        spawnMaceDust(blockId, position + Vector(
            (3.5 * math.cos(angle) + randomGaussian() * 0.5) * blockSize,
            (3.5 * math.sin(angle) + randomGaussian() * 0.5) * blockSize,
            0
        ), randomGaussian() * 0.05)
    end
end

local function advanceEmitter(emitter, now)
    local steps = 0
    while emitter.life < 3 and now >= emitter.nextTickAt and steps < MAX_CATCHUP_TICKS do
        emitCritRound(emitter)
        emitter.life = emitter.life + 1
        emitter.nextTickAt = emitter.nextTickAt + TICK_SECONDS
        steps = steps + 1
    end
end

local function advanceParticle(particle, now)
    local steps = 0
    while not particle.removed and now >= particle.nextTickAt and steps < MAX_CATCHUP_TICKS do
        particle.lastTickAt = particle.nextTickAt
        particle.nextTickAt = particle.nextTickAt + TICK_SECONDS

        if particle.kind == "crit" then
            tickCritParticle(particle)
        elseif particle.kind == "mace_dust" then
            local position, oldPosition = particle.position, particle.oldPosition
            oldPosition.x, oldPosition.y, oldPosition.z = position.x, position.y, position.z
            if particle.age >= particle.lifetime then
                particle.age = particle.age + 1
                particle.removed = true
            else
                particle.age = particle.age + 1
                local velocity = particle.velocity
                velocity.z = velocity.z - 0.04
                local blockSize = MCITEM.BlockSize()
                position.x = position.x + velocity.x * blockSize
                position.y = position.y + velocity.y * blockSize
                position.z = position.z + velocity.z * blockSize
                velocity.x, velocity.y, velocity.z = velocity.x * 0.98, velocity.y * 0.98, velocity.z * 0.98
            end
        else
            particle.oldPosition = particle.position
            if particle.age >= particle.lifetime then
                particle.age = particle.age + 1
                particle.removed = true
            else
                particle.age = particle.age + 1
                -- MutableSpriteSet.get(age,lifetime) = age * (count - 1) / lifetime.
                particle.frame = math.floor(particle.age * 7 / particle.lifetime)
            end
        end

        steps = steps + 1
    end

    -- Do not replay hundreds of stale ticks after a pause or map transition.
    if steps >= MAX_CATCHUP_TICKS and now >= particle.nextTickAt then
        particle.lastTickAt = now
        particle.nextTickAt = now + TICK_SECONDS
    end
end

hook.Add("Think", "MCITEM.CombatParticles.Tick", function()
    local now = CurTime()

    -- Stable in-place compaction instead of O(n^2) table.remove shifting.
    local emitters = Combat.Emitters
    local emitterCount, keptEmitters = #emitters, 0
    for index = 1, emitterCount do
        local emitter = emitters[index]
        advanceEmitter(emitter, now)
        if emitter.life < 3 then
            keptEmitters = keptEmitters + 1
            emitters[keptEmitters] = emitter
        end
    end
    for index = keptEmitters + 1, emitterCount do emitters[index] = nil end

    local particles = Combat.Particles
    local particleCount, keptParticles = #particles, 0
    for index = 1, particleCount do
        local particle = particles[index]
        advanceParticle(particle, now)
        if not particle.removed then
            keptParticles = keptParticles + 1
            particles[keptParticles] = particle
        end
    end
    for index = keptParticles + 1, particleCount do particles[index] = nil end
end)

-- SingleQuadParticle 的顶点色 = 粒子自己的 rgb × getLightColor()。世界光走 MCSWEP 的
-- 体素采样器（见文件上半部分的注释：render.GetLightColor 是 Source lightmap，会偏暗）。
--
--------------------------------------------------------------------------------
-- 绘制：按材质分组，一次 mesh 发一批
--------------------------------------------------------------------------------
--
-- render.DrawSprite 是一次一个 draw call。750 个尘柱粒子 = 750 次 SetMaterial +
-- 750 次 draw call，每帧如此，服务器 tick 再低也救不回来 —— 掉帧在客户端渲染这边。
-- 改成按材质桶收集，每个桶用一次 mesh.Begin(MATERIAL_QUADS) 发出去：尘柱只有
-- 4×4 = 16 种子块材质（× 方块种类），所以是 750 → ≤16 次 draw call。

-- Buckets persist across frames as flat arrays (stride QUAD_STRIDE) with an
-- explicit count; only the per-frame order list and counts are reset.
local QUAD_STRIDE = 7
local batchBuckets = {}
local batchCounts = {}
local batchOrder = {}
local batchOrderCount = 0
local vertexPosition = Vector(0, 0, 0)

local function pushQuad(material, px, py, pz, radius, r, g, b)
    local bucket = batchBuckets[material]
    if not bucket then
        bucket = {}
        batchBuckets[material] = bucket
    end
    local count = batchCounts[material]
    if not count then
        count = 0
        batchOrderCount = batchOrderCount + 1
        batchOrder[batchOrderCount] = material
    end
    local base = count * QUAD_STRIDE
    bucket[base + 1], bucket[base + 2], bucket[base + 3] = px, py, pz
    bucket[base + 4], bucket[base + 5], bucket[base + 6], bucket[base + 7] = radius, r, g, b
    batchCounts[material] = count + 1
end

local function emitVertex(x, y, z, u, v, r, g, b)
    vertexPosition.x, vertexPosition.y, vertexPosition.z = x, y, z
    mesh.Position(vertexPosition)
    mesh.TexCoord(0, u, v) mesh.Color(r, g, b, 255) mesh.AdvanceVertex()
end

local function flushBatches()
    local viewAngles = EyeAngles()
    local right = viewAngles:Right()
    local up = viewAngles:Up()
    local rightX, rightY, rightZ = right.x, right.y, right.z
    local upX, upY, upZ = up.x, up.y, up.z

    for index = 1, batchOrderCount do
        local material = batchOrder[index]
        local bucket = batchBuckets[material]
        local count = batchCounts[material]

        render.SetMaterial(material)
        mesh.Begin(MATERIAL_QUADS, count)
        for quadIndex = 0, count - 1 do
            local base = quadIndex * QUAD_STRIDE
            local px, py, pz = bucket[base + 1], bucket[base + 2], bucket[base + 3]
            local radius = bucket[base + 4]
            local r, g, b = bucket[base + 5] * 255, bucket[base + 6] * 255, bucket[base + 7] * 255
            local rx, ry, rz = rightX * radius, rightY * radius, rightZ * radius
            local ux, uy, uz = upX * radius, upY * radius, upZ * radius

            emitVertex(px - rx + ux, py - ry + uy, pz - rz + uz, 0, 0, r, g, b)
            emitVertex(px + rx + ux, py + ry + uy, pz + rz + uz, 1, 0, r, g, b)
            emitVertex(px + rx - ux, py + ry - uy, pz + rz - uz, 1, 1, r, g, b)
            emitVertex(px - rx - ux, py - ry - uy, pz - rz - uz, 0, 1, r, g, b)
        end
        mesh.End()

        batchCounts[material] = nil
        batchOrder[index] = nil
    end
    batchOrderCount = 0
end

hook.Add("PostDrawTranslucentRenderables", "MCITEM.CombatParticles.Draw", function(drawingDepth, drawingSkybox)
    if drawingDepth or drawingSkybox then return end
    if #Combat.Particles == 0 then return end

    local now = CurTime()
    local blockSize = MCITEM.BlockSize()

    for index = 1, #Combat.Particles do
        local particle = Combat.Particles[index]
        local partialTick = math.Clamp((now - particle.lastTickAt) / TICK_SECONDS, 0, 1)
        local oldPosition, position = particle.oldPosition, particle.position
        local px = oldPosition.x + (position.x - oldPosition.x) * partialTick
        local py = oldPosition.y + (position.y - oldPosition.y) * partialTick
        local pz = oldPosition.z + (position.z - oldPosition.z) * partialTick

        local material, radius
        if particle.kind == "sweep" then
            material = Combat.Materials.sweep[math.Clamp(particle.frame, 0, 7) + 1]
            radius = particle.quadSize * blockSize
        elseif particle.kind == "mace_dust" then
            material = particle.material
            radius = particle.quadSize * blockSize
        else
            -- SingleQuadParticle.getQuadSize：出生瞬间从 0 长到满。
            local appearance = math.Clamp((particle.age + partialTick) / particle.lifetime * 32, 0, 1)
            material = particle.material
            radius = particle.quadSize * appearance * blockSize
        end

        if radius > 0 then
            pushQuad(material, px, py, pz, radius, particle.litR, particle.litG, particle.litB)
        end
    end

    flushBatches()
end)

net.Receive("MCITEM_MaceSmashParticle", function()
    Combat.EmitMaceSmash(net.ReadVector())
end)

net.Receive("MCITEM_CombatParticle", function()
    local kind = net.ReadUInt(2)

    if kind == FX_CRIT then
        Combat.EmitCritical(net.ReadEntity(), net.ReadVector(), net.ReadVector())
    elseif kind == FX_DAMAGE then
        Combat.EmitDamage(net.ReadVector(), net.ReadUInt(10))
    elseif kind == FX_SWEEP then
        Combat.EmitSweep(net.ReadVector())
    elseif kind == FX_ARROW_CRIT then
        Combat.EmitArrowCritical(net.ReadVector(), net.ReadVector())
    end
end)
