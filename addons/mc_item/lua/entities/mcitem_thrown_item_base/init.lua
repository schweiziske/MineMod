AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/throwables/sh_collision.lua")

local TICK_SECONDS = MCITEM.Throwables.TickSeconds or 1 / 20

local function boxesIntersect(minA, maxA, minB, maxB)
    return minA.x <= maxB.x and maxA.x >= minB.x
        and minA.y <= maxB.y and maxA.y >= minB.y
        and minA.z <= maxB.z and maxA.z >= minB.z
end

function ENT:Initialize()
    local modelId = self:GetItemModelID()
    if modelId ~= "" then self:SetModel("models/mcgm/" .. modelId .. "/" .. modelId .. ".mdl") end
    self:SetModelScale(0.55, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
    self:DrawShadow(false)
    self.MCProjectileVelocity = self.MCProjectileVelocity or vector_origin
    self.MCProjectileAge = 0
    self.MCLeftOwner = false
    self.MCNextProjectileTick = CurTime() + TICK_SECONDS
    self:SetMCVelocity(self.MCProjectileVelocity)
    self:SetMCProjectileTick(0)
    self:NextThink(self.MCNextProjectileTick)
end

function ENT:StartMCFlight(owner, direction, power, uncertainty, options)
    options = istable(options) and options or {}
    if IsValid(owner) then self:SetOwner(owner) end
    local velocity = MCITEM.Throwables.LaunchVelocity(direction, power, uncertainty)
    if IsValid(owner) and options.inheritOwnerVelocity ~= false then
        local inherited = owner:GetVelocity() * TICK_SECONDS / MCITEM.BlockSize()
        velocity.x = velocity.x + inherited.x
        velocity.y = velocity.y + inherited.y
        if not owner:IsOnGround() then velocity.z = velocity.z + inherited.z end
    end
    self.MCProjectileVelocity = velocity
    self:SetMCVelocity(velocity)
    return velocity
end

function ENT:UpdateMCLeftOwner()
    if self.MCLeftOwner then return end
    local owner = self:GetOwner()
    if not IsValid(owner) then
        self.MCLeftOwner = true
        return
    end

    -- Projectile.isOutsideOwnerCollisionRange uses the projectile AABB swept
    -- along its current delta movement, then inflates that box by one block.
    -- Checking only the tiny AABB at the current position clears owner
    -- immunity too early while the thrower is moving, allowing a snowball or
    -- Wind Charge to collide with the player during its first tick.
    local radius = self:GetMCCollisionRadius() * MCITEM.BlockSize()
    local position = self:GetPos()
    local radiusVector = Vector(radius, radius, radius)
    local minimum = position - radiusVector
    local maximum = position + radiusVector
    local displacement = (self.MCProjectileVelocity or vector_origin) * MCITEM.BlockSize()
    minimum = Vector(
        math.min(minimum.x, minimum.x + displacement.x),
        math.min(minimum.y, minimum.y + displacement.y),
        math.min(minimum.z, minimum.z + displacement.z)
    )
    maximum = Vector(
        math.max(maximum.x, maximum.x + displacement.x),
        math.max(maximum.y, maximum.y + displacement.y),
        math.max(maximum.z, maximum.z + displacement.z)
    )
    local margin = MCITEM.BlockSize()
    local expand = Vector(margin, margin, margin)
    minimum = minimum - expand
    maximum = maximum + expand
    local ownerMin, ownerMax = owner:WorldSpaceAABB()
    if not boxesIntersect(minimum, maximum, ownerMin, ownerMax) then self.MCLeftOwner = true end
end

function ENT:MCProjectileTrace(destination)
    return MCITEM.Throwables.TraceProjectile(self, self:GetPos(), destination)
end

function ENT:MCProjectileStep()
    self.MCProjectileAge = (self.MCProjectileAge or 0) + 1
    self.MCTickStartPosition = self:GetPos()
    self:UpdateMCLeftOwner()

    local velocity = self.MCProjectileVelocity or vector_origin
    -- ThrowableProjectile.tick: gravity, inertia, then Projectile movement/collision.
    velocity.z = velocity.z - self:GetMCGravity()
    local inWater = MCITEM.Throwables.FluidKindAt(self.MCTickStartPosition, self) == "water"
    self:SetMCInWater(inWater)
    self:SetMCProjectileTick(self.MCProjectileAge)
    if inWater then
        self:SetMCBubblePosition(
            self.MCTickStartPosition - velocity * (0.25 * MCITEM.BlockSize())
        )
        self:SetMCBubbleVelocity(velocity)
    end
    velocity = velocity * (inWater and 0.8 or self:GetMCInertia())
    self.MCProjectileVelocity = velocity
    self:SetMCVelocity(velocity)

    local destination = self.MCTickStartPosition + velocity * MCITEM.BlockSize()
    local trace = self:MCProjectileTrace(destination)
    if trace.Hit then
        self:SetPos(trace.HitPos)
        local behavior = self.MCThrowableBehavior
        if not isstring(behavior) and isfunction(self.GetThrowableBehavior) then
            behavior = self:GetThrowableBehavior()
        end
        if IsValid(trace.Entity)
            and MCITEM.Throwables
            and isfunction(MCITEM.Throwables.TryEntityDeflection)
            and MCITEM.Throwables.TryEntityDeflection(self, trace.Entity, trace, {
                behavior = behavior,
            }) then
            return
        end
        if self:OnMCProjectileHit(trace) ~= false then self:Remove() end
        return
    end

    self:SetPos(destination)
    if velocity:LengthSqr() > 0 then self:SetAngles(velocity:Angle()) end
    if self.MCProjectileAge > 1200 or math.abs(destination.x) > 1000000
        or math.abs(destination.y) > 1000000 or math.abs(destination.z) > 1000000
    then
        self:Remove()
    end
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextProjectileTick or now) and steps < 8 do
        self:MCProjectileStep()
        if not IsValid(self) then return false end
        self.MCNextProjectileTick = self.MCNextProjectileTick + TICK_SECONDS
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextProjectileTick then
        self.MCNextProjectileTick = now + TICK_SECONDS
    end
    self:NextThink(self.MCNextProjectileTick)
    return true
end
