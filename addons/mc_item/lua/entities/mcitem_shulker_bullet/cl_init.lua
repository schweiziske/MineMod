include("shared.lua")

local trailMaterial = Material("particle/particle_glow_05_addnofog")
local critMaterial = Material("effects/yellowflare")
local glowMaterial = Material("models/mcgm/shulker_bullet/glow")

local function emitParticle(position, material, velocity, lifetime, startSize, endSize, color)
    local emitter = ParticleEmitter(position)
    if not emitter then return end
    local particle = emitter:Add(material, position)
    if particle then
        particle:SetVelocity(velocity or vector_origin)
        particle:SetDieTime(lifetime or 0.35)
        particle:SetStartAlpha(230)
        particle:SetEndAlpha(0)
        particle:SetStartSize(startSize or 2)
        particle:SetEndSize(endSize or 0)
        particle:SetColor(color.r, color.g, color.b)
        particle:SetAirResistance(25)
        particle:SetGravity(Vector(0, 0, -18))
    end
    emitter:Finish()
end

net.Receive("mcitem_shulker_bullet_fx", function()
    local kind = net.ReadString()
    local position = net.ReadVector()
    local count = net.ReadUInt(5)
    for _ = 1, count do
        if kind == "crit" then
            emitParticle(
                position,
                critMaterial,
                VectorRand() * math.Rand(18, 54),
                math.Rand(0.25, 0.5),
                math.Rand(1.5, 3),
                0,
                Color(255, 235, 120)
            )
        else
            emitParticle(
                position,
                trailMaterial,
                VectorRand() * math.Rand(8, 24),
                math.Rand(0.2, 0.35),
                math.Rand(3, 5),
                0,
                Color(240, 225, 255)
            )
        end
    end
end)

function ENT:Think()
    local now = CurTime()
    if now >= (self.MCNextEndRodAt or 0) then
        self.MCNextEndRodAt = now + 1 / 20
        emitParticle(
            self:GetPos(),
            trailMaterial,
            -self:GetMCVelocity() * MCITEM.BlockSize() * 2,
            0.45,
            2.5,
            0,
            Color(236, 220, 255)
        )
    end
end

function ENT:Draw()
    local age = self:GetMCProjectileTick()
    local javaY = math.sin(age * 0.1) * 180
    local javaX = math.cos(age * 0.1) * 180
    local javaZ = math.sin(age * 0.15) * 360
    local origin = self:GetPos() + Vector(0, 0, 0.15 * MCITEM.BlockSize())
    local oldOrigin = self:GetRenderOrigin()
    self:SetRenderOrigin(origin)

    -- ShulkerBulletRenderer#submit applies Y, X, then Z rotations.  Keep the
    -- multiplication order instead of collapsing the non-commuting rotations
    -- into one Euler Angle.  Java XYZ maps to Source (-roll, -pitch, -yaw);
    -- the extra Java Z 180 degrees is scale(-x,-y,+z) with positive scale.
    local function renderMatrix(scale)
        local matrix = Matrix()
        matrix:Rotate(Angle(-javaY, 0, 0))
        matrix:Rotate(Angle(0, 0, -javaX))
        matrix:Rotate(Angle(0, -(javaZ + 180), 0))
        matrix:Scale(Vector(scale, scale, scale))
        return matrix
    end

    -- Initialize keeps the Java renderer's 0.5 model scale on the entity.
    self:EnableMatrix("RenderMultiply", renderMatrix(1))
    self:DrawModel()

    self:EnableMatrix("RenderMultiply", renderMatrix(1.5))
    render.MaterialOverride(glowMaterial)
    render.SetBlend(38 / 255)
    self:DrawModel()
    render.SetBlend(1)
    render.MaterialOverride(nil)
    self:DisableMatrix("RenderMultiply")
    self:SetRenderOrigin(oldOrigin)
end

ENT.DrawTranslucent = ENT.Draw
