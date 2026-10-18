AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/throwables/sv_damage.lua")

util.AddNetworkString("mcitem_shulker_bullet_fx")

local TICK_SECONDS = MCITEM.Throwables.TickSeconds or 1 / 20
local MAX_LIFETIME_TICKS = 1200
local TARGET_SPEED = 0.15
local NO_TARGET_GRAVITY = 0.04
local AXIS_GROWTH = 1.025
local VELOCITY_APPROACH = 0.2

local axisDirections = {
    x = { Vector(1, 0, 0), Vector(-1, 0, 0) },
    y = { Vector(0, 1, 0), Vector(0, -1, 0) },
    z = { Vector(0, 0, 1), Vector(0, 0, -1) },
}
local axisNames = { "x", "y", "z" }
local allDirections = {
    Vector(1, 0, 0), Vector(-1, 0, 0),
    Vector(0, 1, 0), Vector(0, -1, 0),
    Vector(0, 0, 1), Vector(0, 0, -1),
}

local bulletHitSounds = {
    "bmb/java/entity/shulker_bullet/hit1.ogg",
    "bmb/java/entity/shulker_bullet/hit2.ogg",
    "bmb/java/entity/shulker_bullet/hit3.ogg",
    "bmb/java/entity/shulker_bullet/hit4.ogg",
}

local function vectorAxis(direction)
    if math.abs(direction.x) > 0.5 then return "x" end
    if math.abs(direction.y) > 0.5 then return "y" end
    return "z"
end

local function targetPoint(target)
    if not IsValid(target) then return nil end
    local minimum, maximum = target:WorldSpaceAABB()
    return Vector(
        (minimum.x + maximum.x) * 0.5,
        (minimum.y + maximum.y) * 0.5,
        minimum.z + (maximum.z - minimum.z) * 0.5
    )
end

local function targetIsAlive(target)
    if not IsValid(target) or target:IsWorld() or target.BMBDead == true then return false end
    if target:IsPlayer() then return target:Alive() end
    return not target.Health or target:Health() > 0
end

local function clampDelta(value)
    return math.Clamp(value * AXIS_GROWTH, -1, 1)
end

local function broadcastFX(kind, position, count)
    net.Start("mcitem_shulker_bullet_fx")
    net.WriteString(kind)
    net.WriteVector(position)
    net.WriteUInt(math.Clamp(math.floor(tonumber(count) or 1), 1, 31), 5)
    net.Broadcast()
end

function ENT:Initialize()
    self.BaseClass.Initialize(self)
    self:SetModel("models/mcgm/shulker_bullet/shulker_bullet.mdl")
    self:SetModelScale(0.5, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
    self:DrawShadow(false)
    self.MCProjectileVelocity = vector_origin
    self.MCShulkerTargetDelta = vector_origin
    self:SetMCVelocity(vector_origin)
    self:SetMCTargetDelta(vector_origin)
    self:SetMCMovementAxis("")
    self:SetMCFlightSteps(0)
    self.BMBMinecraftDamageTags = {
        ["minecraft:is_projectile"] = true,
        is_projectile = true,
    }
end

function ENT:StartMCFlight(owner, _direction, _power, _uncertainty, _options)
    if IsValid(owner) then self:SetOwner(owner) end
    local runtime = istable(self.MCThrowableRuntime) and self.MCThrowableRuntime or {}
    local target = IsValid(runtime.target) and runtime.target or nil
    self:SetMCTarget(target or NULL)
    self.MCShulkerTarget = target
    self.MCShulkerExcludedAxis = isstring(runtime.axis) and runtime.axis or nil
    self:SelectMCShulkerDirection(self.MCShulkerExcludedAxis)
    return self.MCProjectileVelocity
end

function ENT:IsMCShulkerDirectionClear(direction)
    local radius = self:GetMCCollisionRadius() * MCITEM.BlockSize()
    local extent = Vector(radius, radius, radius)
    return not MCITEM.Throwables.HullCollidesAt(
        self:GetPos() + direction * MCITEM.BlockSize(),
        -extent,
        extent
    )
end

function ENT:SelectMCShulkerDirection(excludedAxis)
    local target = self.MCShulkerTarget
    if not targetIsAlive(target) then target = self:GetMCTarget() end
    local destination = targetPoint(target)
    if destination then
        local delta = destination - self:GetPos()
        if delta:LengthSqr() <= (2 * MCITEM.BlockSize()) ^ 2 then
            if delta:LengthSqr() > 0.000001 then delta:Normalize() end
            self.MCShulkerTargetDelta = delta * TARGET_SPEED
            self:SetMCTargetDelta(self.MCShulkerTargetDelta)
            self:SetMCMovementAxis("")
            self:SetMCFlightSteps(10)
            return
        end

        local candidates = {}
        for _, axis in ipairs(axisNames) do
            if axis ~= excludedAxis then
                local component = axis == "x" and delta.x or (axis == "y" and delta.y or delta.z)
                if math.abs(component) > 0.0001 then
                    local direction = axisDirections[axis][component > 0 and 1 or 2]
                    if self:IsMCShulkerDirectionClear(direction) then
                        candidates[#candidates + 1] = direction
                    end
                end
            end
        end
        if #candidates > 0 then
            local direction = candidates[math.random(1, #candidates)]
            self.MCShulkerTargetDelta = direction * TARGET_SPEED
            local axis = vectorAxis(direction)
            self:SetMCMovementAxis(axis)
            self:SetMCTargetDelta(self.MCShulkerTargetDelta)
            self:SetMCFlightSteps(10 + math.random(0, 4) * 10)
            return
        end
    end

    local direction
    for _ = 1, 5 do
        local candidate = allDirections[math.random(1, #allDirections)]
        if vectorAxis(candidate) ~= excludedAxis and self:IsMCShulkerDirectionClear(candidate) then
            direction = candidate
            break
        end
    end
    direction = direction or allDirections[math.random(1, #allDirections)]
    self.MCShulkerTargetDelta = direction * TARGET_SPEED
    self:SetMCMovementAxis(vectorAxis(direction))
    self:SetMCTargetDelta(self.MCShulkerTargetDelta)
    self:SetMCFlightSteps(10 + math.random(0, 4) * 10)
end

function ENT:ApplyMCShulkerDamage(target)
    if not targetIsAlive(target) then return false end
    local before = target.Health and target:Health() or nil
    local scale
    if target.IsBMBMob == true and isfunction(target.GetMCMinecraftHealthScale) then
        scale = target:GetMCMinecraftHealthScale()
    else
        scale = isfunction(MCITEM.ScaleDamage) and MCITEM.ScaleDamage(1) or 5
    end

    local damage = DamageInfo()
    damage:SetDamage(4 * math.max(0.01, tonumber(scale) or 1))
    damage:SetDamageType(DMG_GENERIC)
    damage:SetAttacker(IsValid(self:GetOwner()) and self:GetOwner() or game.GetWorld())
    damage:SetInflictor(self)
    damage:SetDamagePosition(self:GetPos())
    damage:SetDamageForce(vector_origin)
    target:TakeDamageInfo(damage)

    local accepted = before == nil or not target.Health or target:Health() < before
    if accepted then
        hook.Run("MCITEM.ShulkerBulletDamagedEntity", self, target, self:GetOwner(), damage)
    end
    return accepted
end

function ENT:OnMCShulkerHit(trace)
    if IsValid(trace.Entity) and not trace.HitWorld then
        self:ApplyMCShulkerDamage(trace.Entity)
    else
        broadcastFX("explosion", trace.HitPos or self:GetPos(), 2)
        self:EmitSound(bulletHitSounds[math.random(1, #bulletHitSounds)], 75, 100, 1)
    end
    self:Remove()
end

function ENT:MCProjectileStep()
    self.MCProjectileAge = (self.MCProjectileAge or 0) + 1
    self:SetMCProjectileTick(self.MCProjectileAge)
    self:UpdateMCLeftOwner()

    local target = self.MCShulkerTarget
    if not targetIsAlive(target) then target = self:GetMCTarget() end
    if targetIsAlive(target) then
        self.MCShulkerTarget = target
        local delta = self.MCShulkerTargetDelta or self:GetMCTargetDelta()
        delta = Vector(clampDelta(delta.x), clampDelta(delta.y), clampDelta(delta.z))
        self.MCShulkerTargetDelta = delta
        self:SetMCTargetDelta(delta)
        local velocity = self.MCProjectileVelocity or vector_origin
        velocity = velocity + (delta - velocity) * VELOCITY_APPROACH
        self.MCProjectileVelocity = velocity
    else
        local velocity = self.MCProjectileVelocity or vector_origin
        velocity.z = velocity.z - NO_TARGET_GRAVITY
        self.MCProjectileVelocity = velocity
    end

    local velocity = self.MCProjectileVelocity or vector_origin
    self:SetMCVelocity(velocity)
    local destination = self:GetPos() + velocity * MCITEM.BlockSize()
    local trace = MCITEM.Throwables.TraceProjectile(self, self:GetPos(), destination)
    if trace.Hit then
        self:SetPos(trace.HitPos)
        self:OnMCShulkerHit(trace)
        return
    end
    self:SetPos(destination)

    local steps = self:GetMCFlightSteps() - 1
    self:SetMCFlightSteps(steps)
    local targetPos = targetPoint(target)
    local axis = self:GetMCMovementAxis()
    local aligned = false
    if targetPos and axis ~= "" then
        local tolerance = 0.5 * MCITEM.BlockSize()
        if axis == "x" then aligned = math.abs(targetPos.x - destination.x) <= tolerance
        elseif axis == "y" then aligned = math.abs(targetPos.y - destination.y) <= tolerance
        else aligned = math.abs(targetPos.z - destination.z) <= tolerance end
    end
    if steps <= 0 or aligned or not self:IsMCShulkerDirectionClear(
        velocity:LengthSqr() > 0.000001 and velocity:GetNormalized() or Vector(0, 0, -1)
    ) then
        self:SelectMCShulkerDirection(axis ~= "" and axis or nil)
    end

    if self.MCProjectileAge >= MAX_LIFETIME_TICKS then self:Remove() end
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

function ENT:OnTakeDamage(_damageInfo)
    if self.MCShulkerDestroyed then return 0 end
    self.MCShulkerDestroyed = true
    broadcastFX("crit", self:GetPos(), 15)
    self:EmitSound(bulletHitSounds[math.random(1, #bulletHitSounds)], 75, 100, 1)
    self:Remove()
    return 1
end
