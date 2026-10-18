-- Client rendering for Java 26.2 fishing wake, bubble and splash particles.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Fishing = MCITEM.Fishing or {}

local Fishing = MCITEM.Fishing
if (tonumber(Fishing.ClientEffectsVersion) or 0) >= 2 then return Fishing end
Fishing.ClientEffectsVersion = 2

local NET_EFFECT = "MCITEM_FishingFX"
local wakeMaterials = {}
for index = 0, 3 do
    -- On current x86-64 GMod builds Material() may return the IMaterial plus
    -- PNG metadata values.  A call in the final slot of a table constructor
    -- expands every return value, which appended numbers to the animation and
    -- eventually fed render.SetMaterial(number), leaving purple/black error
    -- sprites on the fishing wake.  Assignment first deliberately keeps only
    -- the actual material value.
    local material = Material("mcitem/fishing/splash_" .. index .. ".png", "noclamp")
    wakeMaterials[#wakeMaterials + 1] = material
end
local bubbleMaterial = Material("mcitem/fishing/bubble.png", "noclamp")
local activeWakes = {}

local function spawnWake(position, velocity)
    local lifetime = math.floor(8 / (math.Rand(0, 1) * 0.8 + 0.2))
    activeWakes[#activeWakes + 1] = {
        position = Vector(position.x, position.y, position.z),
        velocity = Vector(velocity.x, velocity.y, velocity.z),
        remaining = lifetime,
        life = 60 - lifetime,
        quadSize = 0.1 * (math.Rand(0, 1) * 0.5 + 0.5) * 2,
        nextTick = CurTime() + Fishing.TickSeconds,
    }
end

local function spawnEmitterParticle(material, position, velocity, lifetime, startSize, endSize, gravity)
    local emitter = ParticleEmitter(position, false)
    if not emitter then return end
    local particle = emitter:Add(material, position)
    if particle then
        particle:SetVelocity(velocity)
        particle:SetDieTime(lifetime)
        particle:SetStartAlpha(235)
        particle:SetEndAlpha(0)
        particle:SetStartSize(startSize)
        particle:SetEndSize(endSize)
        particle:SetGravity(gravity or vector_origin)
        particle:SetAirResistance(4)
        particle:SetCollide(false)
        particle:SetLighting(false)
    end
    emitter:Finish()
end

local function spawnBubble(position, velocity)
    local size = Fishing.BlockSize()
    spawnEmitterParticle(
        bubbleMaterial,
        position,
        velocity,
        math.Rand(0.35, 0.8),
        size * 0.06,
        size * 0.02,
        Vector(0, 0, size * 0.22)
    )
end

local function spawnSplash(position)
    local size = Fishing.BlockSize()
    local material = wakeMaterials[math.random(1, #wakeMaterials)]
    local velocity = Vector(math.Rand(-0.03, 0.03), math.Rand(-0.03, 0.03), math.Rand(0.08, 0.18))
        * size * 20
    spawnEmitterParticle(material, position, velocity, math.Rand(0.2, 0.45), size * 0.05, size * 0.015,
        Vector(0, 0, -size * 4.8))
end

net.Receive(NET_EFFECT, function()
    local kind = net.ReadUInt(2)
    local position = net.ReadVector()
    local velocity = net.ReadVector()
    local count = net.ReadUInt(5)
    local bubble = net.ReadBool()
    local size = Fishing.BlockSize()

    if kind == Fishing.FX.APPROACH then
        spawnWake(position, velocity)
        spawnWake(position, -velocity + Vector(0, 0, 0.02))
        if bubble then
            spawnBubble(position - Vector(0, 0, size * 0.1), VectorRand() * size * 0.5)
        end
        return
    end

    if kind == Fishing.FX.TEASE_SPLASH then
        for _ = 1, count do
            spawnSplash(position + Vector(math.Rand(-0.1, 0.1), math.Rand(-0.1, 0.1), 0) * size)
        end
        return
    end

    if kind == Fishing.FX.BITE then
        for _ = 1, count do
            local offset = Vector(math.Rand(-Fishing.HookWidth, Fishing.HookWidth),
                math.Rand(-Fishing.HookWidth, Fishing.HookWidth), 0) * size
            spawnBubble(position + offset, VectorRand() * size * 4)
            spawnWake(position + offset, Vector(math.Rand(-0.2, 0.2), math.Rand(-0.2, 0.2), 0.01))
        end
    end
end)

hook.Remove("Think", "MCITEM.Fishing.WakeTick")
hook.Add("Think", "MCITEM.Fishing.WakeTick", function()
    local now = CurTime()
    local size = Fishing.BlockSize()
    for index = #activeWakes, 1, -1 do
        local particle = activeWakes[index]
        local steps = 0
        while now >= particle.nextTick and steps < 4 do
            if particle.remaining <= 0 then break end
            particle.life = 60 - particle.remaining
            particle.remaining = particle.remaining - 1
            particle.position = particle.position + particle.velocity * size
            particle.velocity = particle.velocity * 0.98
            particle.nextTick = particle.nextTick + Fishing.TickSeconds
            steps = steps + 1
        end
        if particle.remaining <= 0 then table.remove(activeWakes, index) end
    end
end)

hook.Remove("PostDrawTranslucentRenderables", "MCITEM.Fishing.DrawWake")
hook.Add("PostDrawTranslucentRenderables", "MCITEM.Fishing.DrawWake", function(_, skybox)
    if skybox then return end
    local size = Fishing.BlockSize()
    for _, particle in ipairs(activeWakes) do
        local material = wakeMaterials[particle.life % #wakeMaterials + 1]
        local width = particle.quadSize * 2 * size
        render.SetMaterial(material)
        render.DrawSprite(particle.position, width, width, color_white)
    end
end)

return Fishing
