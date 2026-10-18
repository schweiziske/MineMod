-- Java 26.2 event 35: 30-tick TrackingEmitter, local totem sound, and a
-- 40-tick item-activation HUD animation only for the local player.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Totem = MCITEM.Totem or {}

local Totem = MCITEM.Totem
local NET_TRIGGER = "MCITEM_TotemTriggered"
local TICK_SECONDS = 1 / 20
local PARTICLE_EMITTER_TICKS = 30
local HUD_TICKS = 40
local BLOCK_SIZE = 36.5
local PARTICLE_MATERIALS = {}
for index = 0, 7 do
    PARTICLE_MATERIALS[index] = Material("mcitem/particle/glitter_" .. index .. ".png", "smooth")
end
local ACTIVATION_MATERIAL = Material("mcitem/totem/activation")

Totem.Emitters = Totem.Emitters or {}
Totem.Particles = Totem.Particles or {}
Totem.HUD = Totem.HUD or nil
if IsValid(Totem.HUDModel) then Totem.HUDModel:Remove() end
Totem.HUDModel = nil

local function entityCenter(entity)
    if not IsValid(entity) then return nil end
    return entity.WorldSpaceCenter and entity:WorldSpaceCenter() or entity:GetPos()
end

local function spawnParticle(entity, now)
    local dx, dy, dz = math.Rand(-1, 1), math.Rand(-1, 1), math.Rand(-1, 1)
    if dx * dx + dy * dy + dz * dz > 1 then return end
    local mins, maxs = entity:WorldSpaceAABB()
    local height = math.max(1, maxs.z - mins.z)
    local width = math.max(1, math.max(maxs.x - mins.x, maxs.y - mins.y))
    local yellow = math.random(4) == 1
    local color
    if yellow then
        color = Color(
            math.floor((0.6 + math.Rand(0, 0.2)) * 255 + 0.5),
            math.floor((0.6 + math.Rand(0, 0.3)) * 255 + 0.5),
            math.floor(math.Rand(0, 0.2) * 255 + 0.5)
        )
    else
        color = Color(
            math.floor((0.1 + math.Rand(0, 0.2)) * 255 + 0.5),
            math.floor((0.4 + math.Rand(0, 0.3)) * 255 + 0.5),
            math.floor(math.Rand(0, 0.2) * 255 + 0.5)
        )
    end
    Totem.Particles[#Totem.Particles + 1] = {
        -- Entity.getX/Z(offset) use full width * offset; getY(offset) uses
        -- full height * offset. TrackingEmitter supplies dx/dy/dz divided by 4.
        position = Vector(
            entity:GetPos().x + dx * width / 4,
            entity:GetPos().y + dz * width / 4,
            mins.z + height * (0.5 + dy / 4)
        ),
        -- Minecraft velocity is blocks per tick. Store Source units per tick
        -- and execute the exact gravity -> move -> friction order below.
        velocity = Vector(dx, dz, dy + 0.2) * BLOCK_SIZE,
        bornAt = now,
        lastAt = now,
        lifetime = (60 + math.random(0, 11)) * TICK_SECONDS,
        -- SingleQuadParticle: 0.1*(random*0.5+0.5)*2, then Totem *0.75.
        size = BLOCK_SIZE * math.Rand(0.075, 0.15) * 2,
        color = color,
    }
end

local function startEffect(entity)
    if not IsValid(entity) then return end
    local now = CurTime()
    Totem.Emitters[#Totem.Emitters + 1] = { entity = entity, ticks = 0, nextTickAt = now }
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

hook.Remove("Think", "MCITEM.Totem.Tick")
hook.Add("Think", "MCITEM.Totem.Tick", function()
    local now = CurTime()
    for index = #Totem.Emitters, 1, -1 do
        local emitter = Totem.Emitters[index]
        if not IsValid(emitter.entity) or emitter.ticks >= PARTICLE_EMITTER_TICKS then
            table.remove(Totem.Emitters, index)
        else
            local steps = 0
            while now >= emitter.nextTickAt and emitter.ticks < PARTICLE_EMITTER_TICKS and steps < 4 do
                for _ = 1, 16 do spawnParticle(emitter.entity, emitter.nextTickAt) end
                emitter.ticks = emitter.ticks + 1
                emitter.nextTickAt = emitter.nextTickAt + TICK_SECONDS
                steps = steps + 1
            end
        end
    end

    for index = #Totem.Particles, 1, -1 do
        local particle = Totem.Particles[index]
        local age = now - particle.bornAt
        if age >= particle.lifetime then
            table.remove(Totem.Particles, index)
        else
            local elapsedTicks = math.min(4, math.max(0, (now - particle.lastAt) / TICK_SECONDS))
            local wholeTicks = math.floor(elapsedTicks)
            for _ = 1, wholeTicks do
                particle.velocity.z = particle.velocity.z - 0.04 * 1.25 * BLOCK_SIZE
                particle.position = particle.position + particle.velocity
                particle.velocity = particle.velocity * 0.6
                particle.lastAt = particle.lastAt + TICK_SECONDS
            end
        end
    end
end)

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.Totem.DrawParticles")
hook.Add("PostDrawTranslucentRenderables", "MCITEM.Totem.DrawParticles", function(_, drawingSkybox)
    if drawingSkybox or #Totem.Particles == 0 then return end
    local now = CurTime()
    for _, particle in ipairs(Totem.Particles) do
        local ageTicks = (now - particle.bornAt) / TICK_SECONDS
        local frame = math.Clamp(math.floor(ageTicks / math.max(1, particle.lifetime / TICK_SECONDS) * 8), 0, 7)
        render.SetMaterial(PARTICLE_MATERIALS[7 - frame])
        local halfLife = particle.lifetime * 0.5
        local alpha = now - particle.bornAt > halfLife
            and math.Clamp(1 - ((now - particle.bornAt) - halfLife) / particle.lifetime, 0, 1)
            or 1
        local color = Color(particle.color.r, particle.color.g, particle.color.b, math.floor(alpha * 255 + 0.5))
        render.DrawSprite(particle.position, particle.size, particle.size, color)
    end
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

    -- GameRenderer sets a full-window 70-degree perspective (near 0.05, far
    -- 100) before ScreenEffectRenderer submits this item.  Keep the Java
    -- translation in Minecraft units instead of feeding a one-block/36.5-unit
    -- Source model into a cropped square viewport.
    local distance = 10 - 9 * math.sin(phase)
    local center = Vector(distance, -offX, offY)
    local yaw = 900 * math.abs(math.sin(phase))
    local tilt = 6 * math.cos(t * 8)
    cam.Start3D(Vector(0, 0, 0), Angle(0, 0, 0), 70,
        0, 0, ScrW(), ScrH(), 0.05, 100)
        cam.IgnoreZ(true)
        drawActivationItem(center, yaw, tilt)
        cam.IgnoreZ(false)
    cam.End3D()
end)
