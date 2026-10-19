AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/throwables/sh_audio_data.lua")
include("mcitem/throwables/sh_audio.lua")
include("mcitem/throwables/sv_experience.lua")

local Throwables = MCITEM.Throwables

local function bounds()
    local blockSize = MCITEM.BlockSize()
    return Vector(-0.25, -0.25, 0) * blockSize, Vector(0.25, 0.25, 0.5) * blockSize
end

local function boxesIntersect(minimumA, maximumA, minimumB, maximumB)
    return minimumA.x <= maximumB.x and maximumA.x >= minimumB.x
        and minimumA.y <= maximumB.y and maximumA.y >= minimumB.y
        and minimumA.z <= maximumB.z and maximumA.z >= minimumB.z
end

function ENT:Initialize()
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    self:SetNoDraw(false)
    self:DrawShadow(false)
    local minimum, maximum = bounds()
    self:SetCollisionBounds(minimum, maximum)
    self.MCOrbVelocity = vector_origin
    self.MCOrbAge = 0
    self.MCFollowingPlayer = nil
    self:SetOrbCount(math.max(1, self:GetOrbCount()))
    self:SetOrbAge(0)
    self.MCNextOrbTick = CurTime() + Throwables.TickSeconds
    self:NextThink(self.MCNextOrbTick)
end

function ENT:SetupExperience(value, direction, context)
    value = math.max(1, math.floor(tonumber(value) or 1))
    direction = isvector(direction) and Vector(direction.x, direction.y, direction.z) or vector_origin
    if direction:LengthSqr() > 0 then direction:Normalize() end
    if direction:LengthSqr() > 0 then
        self:SetPos(self:GetPos() + direction * (0.25 * MCITEM.BlockSize()))
    end
    local velocity = Vector(math.Rand(-0.2, 0.2), math.Rand(-0.2, 0.2), math.Rand(0, 0.4))
    if direction:LengthSqr() > 0 and direction:Dot(velocity) < 0 then velocity = -velocity end
    self:SetExperienceValue(value)
    self:SetOrbCount(1)
    self.MCOrbVelocity = velocity
    self.MCExperienceContext = context
    return true
end

function ENT:MergeNearbyOrbs()
    if self.MCPendingExperience ~= nil then return end
    local half = Vector(0.75, 0.75, 0.75) * MCITEM.BlockSize()
    for _, other in ipairs(ents.FindInBox(self:GetPos() - half, self:GetPos() + half)) do
        if IsValid(other) and other ~= self and other:GetClass() == self:GetClass()
            and other.MCPendingExperience == nil
            and other:GetExperienceValue() == self:GetExperienceValue()
            and (other:EntIndex() - self:EntIndex()) % 40 == 0
        then
            self:SetOrbCount(self:GetOrbCount() + other:GetOrbCount())
            self.MCOrbAge = math.min(self.MCOrbAge, other.MCOrbAge or 0)
            other:Remove()
        end
    end
end

function ENT:FollowNearbyPlayer()
    self.MCFollowingPlayer = Throwables.NearestExperiencePlayer(self:GetPos(), self.MCFollowingPlayer)
    local target = self.MCFollowingPlayer
    if not IsValid(target) then return end
    local targetPosition = target:GetPos()
    targetPosition = Vector(
        targetPosition.x,
        targetPosition.y,
        targetPosition.z + (target:EyePos().z - targetPosition.z) * 0.5
    )
    local delta = targetPosition - self:GetPos()
    local distance = delta:Length() / MCITEM.BlockSize()
    if distance <= 0 or distance > Throwables.ExperienceOrbFollowRange then return end
    local factor = 1 - distance / Throwables.ExperienceOrbFollowRange
    self.MCOrbVelocity = self.MCOrbVelocity + delta:GetNormalized() * (factor * factor * 0.1)
end

function ENT:TryPlayerPickup()
    local minimumHull, maximumHull = bounds()
    local orbMinimum, orbMaximum = self:GetPos() + minimumHull, self:GetPos() + maximumHull
    for _, playerEntity in ipairs(player.GetAll()) do
        local playerMinimum, playerMaximum = playerEntity:WorldSpaceAABB()
        if boxesIntersect(orbMinimum, orbMaximum, playerMinimum, playerMaximum)
            and Throwables.CollectExperienceOrb(self, playerEntity)
        then
            self:SetOrbCount(self:GetOrbCount() - 1)
            if self:GetOrbCount() <= 0 then self:Remove() end
            return
        end
    end
end

local function groundFriction(orb, trace)
    if isfunction(orb.GetMCExperienceOrbGroundFriction) then
        local value = orb:GetMCExperienceOrbGroundFriction(trace)
        if isnumber(value) then return math.max(0, value) end
    end
    local value = hook.Run("MCITEM.GetExperienceOrbGroundFriction", orb, trace)
    if isnumber(value) then return math.max(0, value) end
    -- Block#getFriction default in Java is 0.6. Ice/slime integrations can
    -- return their registered block value through the method/hook above.
    return 0.6
end

function ENT:OrbStep()
    self.MCOrbAge = self.MCOrbAge + 1
    self:SetOrbAge(self.MCOrbAge)
    if self.MCOrbAge % 20 == 1 then self:MergeNearbyOrbs() end
    if not IsValid(self) then return end

    local minimumHull, maximumHull = bounds()
    local velocity = self.MCOrbVelocity or vector_origin
    local eyePosition = self:GetPos() + Vector(0, 0, 0.25 * MCITEM.BlockSize())
    local fluid = Throwables.FluidKindAt(eyePosition, self)
    local insideBlock = Throwables.HullCollidesAt(self:GetPos(), minimumHull, maximumHull, self)
    if fluid == "water" then
        velocity.x = velocity.x * 0.99
        velocity.y = velocity.y * 0.99
        velocity.z = math.min(velocity.z + 0.0005, 0.06)
    elseif not insideBlock then
        velocity.z = velocity.z - 0.03
    end
    if fluid == "lava" then
        velocity = Vector(
            (math.Rand(0, 1) - math.Rand(0, 1)) * 0.2,
            (math.Rand(0, 1) - math.Rand(0, 1)) * 0.2,
            0.2
        )
    end
    self.MCOrbVelocity = velocity
    self:FollowNearbyPlayer()
    velocity = self.MCOrbVelocity

    local oldVertical = velocity.z
    local destination = self:GetPos() + velocity * MCITEM.BlockSize()
    local trace = Throwables.TraceMovementHull(self:GetPos(), destination, minimumHull, maximumHull, self)
    if trace.Hit then
        self:SetPos(trace.HitPos)
        local normalSpeed = velocity:Dot(trace.HitNormal or vector_origin)
        if normalSpeed < 0 then velocity = velocity - trace.HitNormal * normalSpeed end
    else
        self:SetPos(destination)
    end

    local drag = 0.98
    local onGround = trace.Hit and isvector(trace.HitNormal) and trace.HitNormal.z > 0.5
    if onGround then drag = drag * groundFriction(self, trace) end
    velocity = velocity * drag
    if onGround and oldVertical < -0.03 then velocity.z = -oldVertical * 0.4 end
    self.MCOrbVelocity = velocity

    self:TryPlayerPickup()
    if IsValid(self) and self.MCOrbAge >= Throwables.ExperienceOrbLifetimeTicks then self:Remove() end
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextOrbTick or now) and steps < 8 do
        self:OrbStep()
        if not IsValid(self) then return false end
        self.MCNextOrbTick = self.MCNextOrbTick + Throwables.TickSeconds
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextOrbTick then self.MCNextOrbTick = now + Throwables.TickSeconds end
    self:NextThink(self.MCNextOrbTick)
    return true
end
