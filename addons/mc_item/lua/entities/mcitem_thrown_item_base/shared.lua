-- Reusable manual 20 Hz ThrowableProjectile base for potions, snowballs,
-- eggs, ender pearls and experience bottles.

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "MCITEM Thrown Item Base"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "ItemModelID")
    self:NetworkVar("Vector", 0, "MCVelocity")
    self:NetworkVar("Vector", 1, "MCBubblePosition")
    self:NetworkVar("Vector", 2, "MCBubbleVelocity")
    self:NetworkVar("Bool", 0, "MCInWater")
    self:NetworkVar("Int", 0, "MCProjectileTick")
end

function Throwables.Triangle(mode, deviation)
    return (tonumber(mode) or 0) + (tonumber(deviation) or 0) * (math.Rand(0, 1) - math.Rand(0, 1))
end

function Throwables.LaunchVelocity(direction, power, uncertainty)
    direction = isvector(direction) and direction:GetNormalized() or vector_origin
    local deviation = 0.0172275 * (tonumber(uncertainty) or 0)
    return Vector(
        direction.x + Throwables.Triangle(0, deviation),
        direction.y + Throwables.Triangle(0, deviation),
        direction.z + Throwables.Triangle(0, deviation)
    ) * (tonumber(power) or 1)
end

function ENT:GetMCGravity()
    return tonumber(self.MCGravity) or 0.03
end

function ENT:GetMCInertia()
    return tonumber(self.MCInertia) or 0.99
end

function ENT:GetMCCollisionRadius()
    return tonumber(self.MCCollisionRadius) or 0.125
end

function ENT:OnMCProjectileHit(_trace)
    return true
end

function ENT:CanMCBeDeflected()
    return true
end
