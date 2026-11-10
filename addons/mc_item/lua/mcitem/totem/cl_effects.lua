-- Java 26.2: TrackingEmitter / TotemParticle / SimpleAnimatedParticle /
-- SingleQuadParticle / ParticleResources.MutableSpriteSet. Event 35 emits for
-- 30 ticks and starts the local player's 40-tick item activation.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Totem = MCITEM.Totem or {}
if not MCITEM.BlockSize then include("mcitem/sh_item_state.lua") end

local Totem = MCITEM.Totem
local NET_TRIGGER = "MCITEM_TotemTriggered"
local TICK_SECONDS = 1 / 20
local PARTICLE_EMITTER_TICKS = 30
local HUD_TICKS = 40
-- Eight unmodified 8x8 Java sprites, glitter_7 through glitter_0, left to right.
-- POINTSAMPLE / NOMIP / NOLOD are VTF flags, not just VMT shader parameters.
local PARTICLE_MATERIAL = Material("mcitem/totem/particles")
local ACTIVATION_MATERIAL = Material("mcitem/totem/activation")

-- A Lua refresh discards transient effects with the old particle state layout.
Totem.Emitters = {}
Totem.Particles = {}
Totem.HUD = Totem.HUD or nil
if IsValid(Totem.HUDModel) then Totem.HUDModel:Remove() end
Totem.HUDModel = nil

local function spawnParticle(origin, width, height, blockSize, now)
    local dx, dy, dz = math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(-1, 1)
    if dx * dx + dy * dy + dz * dz > 1 then return end
    local yellow = math.random(4) == 1
    local color
    if yellow then
        color = Color(
            math.floor((0.6 + math.Rand(0, 0.2)) * 255),
            math.floor((0.6 + math.Rand(0, 0.3)) * 255),
            math.floor(math.Rand(0, 0.2) * 255)
        )
    else
        color = Color(
            math.floor((0.1 + math.Rand(0, 0.2)) * 255),
            math.floor((0.4 + math.Rand(0, 0.3)) * 255),
            math.floor(math.Rand(0, 0.2) * 255)
        )
    end
    -- This is an isotropic world-space sample around an engine-space entity,
    -- not a ModelPart/renderer transform. Source Z is the vertical component.
    local position = Vector(origin.x + dx * width / 4, origin.y + dz * width / 4,
        origin.z + height * (0.5 + dy / 4))
    Totem.Particles[#Totem.Particles + 1] = {
        position = position,
        oldPosition = Vector(position.x, position.y, position.z),
        -- Source units per Minecraft tick; world block size is applied once.
        velocity = Vector(dx * blockSize, dz * blockSize, (dy + 0.2) * blockSize),
        blockSize = blockSize,
        bornAt = now,
        lastAt = now,
        age = 0,
        lifetime = 60 + math.random(0, 11),
        -- Java quadSize is a HALF extent: 0.1*(random*0.5+0.5)*2*0.75 blocks.
        size = blockSize * math.Rand(0.075, 0.15),
        color = color,
    }
end

local function emitParticles(entity, now)
    local mins, maxs = entity:WorldSpaceAABB()
    local origin = entity:GetPos()
    origin = Vector(origin.x, origin.y, mins.z)
    local height = maxs.z - mins.z
    local width = math.max(maxs.x - mins.x, maxs.y - mins.y)
    local blockSize = MCITEM.BlockSize()
    -- TrackingEmitter attempts 16 samples, rejecting points outside the unit
    -- sphere. Do not retry rejections: the expected count is 16*pi/6 per tick.
    for _ = 1, 16 do spawnParticle(origin, width, height, blockSize, now) end
end

local function startEffect(entity)
    if not IsValid(entity) then return end
    local now = CurTime()
    -- TrackingEmitter's constructor calls tick immediately (the first of 30).
    emitParticles(entity, now)
    Totem.Emitters[#Totem.Emitters + 1] = {
        entity = entity, ticks = 1, startedAt = now, nextTickAt = now + TICK_SECONDS,
    }
    local api = MC and MC.API and MC.API.Sound
    if api and isfunction(api.Play) then api.Play("item.totem.use", entity:GetPos(), { volume = 1, pitch = 1 }) end
    if entity == LocalPlayer() then
        Totem.HUD = {
            startedAt = now,
            offX = math.Rand(-1, 1),
            offY = math.Rand(-1, 1),
        }
    end
end

net.Receive(NET_TRIGGER, function()
    startEffect(net.ReadEntity())
    net.ReadString()
end)

-- Native traces see Source world brushes and installed client MC collision.
-- Carriers cover only the local prediction/aim bubble; distant visible MC
-- blocks and moving clusters without a prediction mirror may not collide.
-- mc_chunk_phys is normally server-only (TRANSMIT_NEVER), not a dependency.
local BLOCK_COLLISION_CLASSES = {
    mc_chunk = true, mc_chunk_phys = true, mc_collision_carrier = true, mc_block_cluster = true,
}
local function particleCollisionFilter(entity)
    -- Particle.move collides with blocks only, not the emitting entity/props.
    return entity:IsWorld() or BLOCK_COLLISION_CLASSES[entity:GetClass()] == true
end
local traceData = {
    start = Vector(), endpos = Vector(), mins = Vector(), maxs = Vector(),
    mask = MASK_SOLID, filter = particleCollisionFilter,
}

local function moveAxis(particle, axis, amount)
    if amount == 0 then return 0 end
    local position = particle.position
    traceData.start:Set(position)
    traceData.endpos:Set(position)
    traceData.endpos[axis] = traceData.endpos[axis] + amount
    local trace = util.TraceHull(traceData)
    local resolved = trace.HitPos[axis] - position[axis]
    position[axis] = trace.HitPos[axis]
    return resolved
end

local function moveParticle(particle)
    if particle.stoppedByCollision then return end
    local velocity = particle.velocity
    local dx, dy, dz = velocity.x, velocity.y, velocity.z
    -- Particle.setSize(0.2, 0.2): the box is feet-anchored, in block units.
    -- Totem changes quadSize only; it does not scale this collision box.
    local half = 0.1 * particle.blockSize
    traceData.mins:SetUnpacked(-half, -half, 0)
    traceData.maxs:SetUnpacked(half, half, half * 2)
    local rz = moveAxis(particle, "z", dz)
    local rx, ry
    -- Direction.axisStepOrder: vertical, then the LARGER horizontal motion.
    if math.abs(dx) < math.abs(dy) then
        ry = moveAxis(particle, "y", dy)
        rx = moveAxis(particle, "x", dx)
    else
        rx = moveAxis(particle, "x", dx)
        ry = moveAxis(particle, "y", dy)
    end
    -- Engine-space floats require a tolerance; Java's stop threshold is 1e-5 blocks.
    local epsilon = 0.00001 * particle.blockSize
    if math.abs(rx - dx) > epsilon then velocity.x = 0 end
    if math.abs(ry - dy) > epsilon then velocity.y = 0 end
    particle.onGround = dz < 0 and math.abs(rz - dz) > epsilon
    if math.abs(dz) >= epsilon and math.abs(rz) < epsilon then particle.stoppedByCollision = true end
end

hook.Remove("Think", "MCITEM.Totem.Tick")
hook.Add("Think", "MCITEM.Totem.Tick", function()
    local now = CurTime()
    for index = #Totem.Emitters, 1, -1 do
        local emitter = Totem.Emitters[index]
        if IsValid(emitter.entity) then
            -- The total is bounded by 30 ticks; a render hitch must not stretch
            -- the emission window or leave an artificial four-tick backlog.
            while now + 1e-7 >= emitter.nextTickAt and emitter.ticks < PARTICLE_EMITTER_TICKS do
                emitParticles(emitter.entity, emitter.nextTickAt)
                emitter.ticks = emitter.ticks + 1
                emitter.nextTickAt = emitter.startedAt + emitter.ticks * TICK_SECONDS
            end
        end
        if not IsValid(emitter.entity) or emitter.ticks >= PARTICLE_EMITTER_TICKS then
            table.remove(Totem.Emitters, index)
        end
    end

    for index = #Totem.Particles, 1, -1 do
        local particle = Totem.Particles[index]
        local age = math.floor((now - particle.bornAt) / TICK_SECONDS + 1e-6)
        -- Particle.tick uses age++ >= lifetime: age == lifetime still renders
        -- the final sprite, then the following tick removes the particle.
        if age > particle.lifetime then
            table.remove(Totem.Particles, index)
        else
            while particle.age < age do
                particle.oldPosition:Set(particle.position)
                particle.velocity.z = particle.velocity.z - 0.04 * 1.25 * particle.blockSize
                moveParticle(particle)
                particle.velocity:Mul(0.6)
                if particle.onGround then
                    particle.velocity.x = particle.velocity.x * 0.7
                    particle.velocity.y = particle.velocity.y * 0.7
                end
                particle.age = particle.age + 1
            end
            particle.lastAt = particle.bornAt + particle.age * TICK_SECONDS
        end
    end
end)

local vertexPosition = Vector()
local function particleVertex(x, y, z, u, v, color, alpha)
    vertexPosition:SetUnpacked(x, y, z)
    mesh.Position(vertexPosition)
    mesh.TexCoord(0, u, v)
    mesh.Color(color.r, color.g, color.b, alpha)
    mesh.AdvanceVertex()
end

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.Totem.DrawParticles")
hook.Add("PostDrawTranslucentRenderables", "MCITEM.Totem.DrawParticles", function(depth, drawingSkybox)
    if depth or drawingSkybox or #Totem.Particles == 0 then return end
    local now, angles = CurTime(), EyeAngles()
    local right, up = angles:Right(), angles:Up()
    render.SetMaterial(PARTICLE_MATERIAL)
    render.PushFilterMag(TEXFILTER.POINT)
    render.PushFilterMin(TEXFILTER.POINT)
    -- One atlas avoids changing a shared animated material's $frame per quad.
    -- Bound each DX9 mesh submission, including simultaneous totem activations.
    for first = 1, #Totem.Particles, 4096 do
        local last = math.min(first + 4095, #Totem.Particles)
        mesh.Begin(MATERIAL_QUADS, last - first + 1)
        for index = first, last do
            local particle = Totem.Particles[index]
            local partial = math.Clamp((now - particle.lastAt) / TICK_SECONDS, 0, 1)
            local old, position = particle.oldPosition, particle.position
            local x, y, z = Lerp(partial, old.x, position.x), Lerp(partial, old.y, position.y),
                Lerp(partial, old.z, position.z)
            local radius = particle.size
            local rx, ry, rz = right.x * radius, right.y * radius, right.z * radius
            local ux, uy, uz = up.x * radius, up.y * radius, up.z * radius
            local frame = math.floor(particle.age * 7 / particle.lifetime)
            local u0, u1 = frame / 8, (frame + 1) / 8
            local halfLife = math.floor(particle.lifetime / 2)
            local alpha = particle.age > halfLife and 1 - (particle.age - halfLife) / particle.lifetime or 1
            alpha = math.floor(alpha * 255)
            local color = particle.color
            particleVertex(x-rx-ux, y-ry-uy, z-rz-uz, u1, 1, color, alpha)
            particleVertex(x+rx-ux, y+ry-uy, z+rz-uz, u0, 1, color, alpha)
            particleVertex(x+rx+ux, y+ry+uy, z+rz+uz, u0, 0, color, alpha)
            particleVertex(x-rx+ux, y-ry+uy, z-rz+uz, u1, 0, color, alpha)
        end
        mesh.End()
    end
    render.PopFilterMin()
    render.PopFilterMag()
end)

local function hudTransform(state, now)
    local elapsedTicks = (now - state.startedAt) / TICK_SECONDS
    local t = math.Clamp(elapsedTicks / HUD_TICKS, 0, 1)
    local t2, t3 = t * t, t * t * t
    local phase = (10.25 * t3 * t2 - 24.95 * t2 * t2 + 25.5 * t3 - 13.8 * t2 + 4 * t) * math.pi
    local shake = math.abs(math.sin(phase * 2))
    return t, phase, state.offX * 0.3 * (ScrW() / math.max(1, ScrH())) * shake,
        state.offY * 0.3 * shake
end

local function rotateZ(x, y, z, angle)
    local cosine, sine = math.cos(angle), math.sin(angle)
    return x * cosine - y * sine, x * sine + y * cosine, z
end

local function rotateX(x, y, z, angle)
    local cosine, sine = math.cos(angle), math.sin(angle)
    return x, y * cosine - z * sine, y * sine + z * cosine
end

local function rotateY(x, y, z, angle)
    local cosine, sine = math.cos(angle), math.sin(angle)
    return x * cosine + z * sine, y, -x * sine + z * cosine
end

local function activationVertex(center, x, y, yaw, tilt)
    -- PoseStack receives T * S * Ry * Rx * Rz, so a vertex is transformed in
    -- the reverse call order: Z, then X, then Y.  Java screen X/Y/-Z map to
    -- Source camera right/up/forward as -Y/+Z/+X.
    local z = 0
    x, y, z = rotateZ(x, y, z, tilt)
    x, y, z = rotateX(x, y, z, tilt)
    x, y, z = rotateY(x, y, z, yaw)
    return center + Vector(-z, -x, y)
end

local function meshVertex(position, u, v)
    mesh.Position(position)
    mesh.TexCoord(0, u, v)
    mesh.Color(255, 255, 255, 255)
    mesh.AdvanceVertex()
end

local function drawActivationItem(center, yawDegrees, tiltDegrees)
    local halfSize = 0.4 -- Java's uniform 0.8 item-activation scale.
    local yaw, tilt = math.rad(yawDegrees), math.rad(tiltDegrees)
    local topLeft = activationVertex(center, -halfSize, halfSize, yaw, tilt)
    local topRight = activationVertex(center, halfSize, halfSize, yaw, tilt)
    local bottomRight = activationVertex(center, halfSize, -halfSize, yaw, tilt)
    local bottomLeft = activationVertex(center, -halfSize, -halfSize, yaw, tilt)

    render.SetMaterial(ACTIVATION_MATERIAL)
    mesh.Begin(MATERIAL_QUADS, 1)
        meshVertex(topLeft, 0, 0)
        meshVertex(topRight, 1, 0)
        meshVertex(bottomRight, 1, 1)
        meshVertex(bottomLeft, 0, 1)
    mesh.End()
end

-- ScreenEffectRenderer submits the activation before Minecraft draws its GUI.
-- HUDPaintBackground gives Source the same ordering, so hotbar/status text is
-- not covered by the item as it grows toward the camera.
hook.Remove("PostDrawHUD", "MCITEM.Totem.ItemActivation")
hook.Remove("HUDPaintBackground", "MCITEM.Totem.ItemActivation")
hook.Add("HUDPaintBackground", "MCITEM.Totem.ItemActivation", function()
    local state = Totem.HUD
    if not state then return end
    local now = CurTime()
    local t, phase, offX, offY = hudTransform(state, now)
    if t >= 1 then Totem.HUD = nil return end

    -- Camera.calculateHudFov / GameRenderer use 70 degrees VERTICAL (near 0.05, far
    -- 100) before ScreenEffectRenderer submits this item.  Keep the Java
    -- translation in Minecraft units instead of feeding a one-block/36.5-unit
    -- Source model into a cropped square viewport.
    local distance = 10 - 9 * math.sin(phase)
    local center = Vector(distance, -offX, offY)
    local yaw = 900 * math.abs(math.sin(phase))
    local tilt = 6 * math.cos(t * 8)
    local sourceFov = math.deg(2 * math.atan(math.tan(math.rad(70) / 2) * (4 / 3)))
    cam.Start3D(Vector(0, 0, 0), Angle(0, 0, 0), sourceFov,
        0, 0, ScrW(), ScrH(), 0.05, 100)
        cam.IgnoreZ(true)
        drawActivationItem(center, yaw, tilt)
        cam.IgnoreZ(false)
    cam.End3D()
end)
