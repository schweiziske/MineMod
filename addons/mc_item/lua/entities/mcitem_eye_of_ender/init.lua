AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/throwables/sh_audio_data.lua")
include("mcitem/throwables/sh_audio.lua")
include("mcitem/throwables/sv_fx.lua")

local Throwables = MCITEM.Throwables

function ENT:Initialize()
    self:SetModel("models/mcgm/ender_eye/ender_eye.mdl")
    self:SetModelScale(0.55, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
    self:DrawShadow(false)
    self.MCEyeTarget = nil
    self.MCEyeVelocityValue = vector_origin
    self.MCEyeLife = 0
    self:SetMCEyeVelocity(vector_origin)
    self:SetMCEyeTick(0)
    self.MCNextEyeTick = CurTime() + Throwables.TickSeconds
    self:NextThink(self.MCNextEyeTick)
end

function ENT:SetupEnderEye(owner, target)
    if IsValid(owner) then self:SetOwner(owner) end
    if not isvector(target) then return false end
    local position = self:GetPos()
    local horizontal = Vector(target.x - position.x, target.y - position.y, 0)
    local distance = horizontal:Length() / MCITEM.BlockSize()
    if distance > Throwables.EnderEyeFarDistance then
        horizontal:Normalize()
        self.MCEyeTarget = position
            + horizontal * (Throwables.EnderEyeFarDistance * MCITEM.BlockSize())
            + Vector(0, 0, Throwables.EnderEyeFarHeight * MCITEM.BlockSize())
    else
        self.MCEyeTarget = target
    end
    self.MCEyeLife = 0
    self:SetMCEyeSurvives(math.random(1, 5) > 1)
    return true
end

local function updatedVelocity(current, nextPosition, target)
    local horizontal = Vector(target.x - nextPosition.x, target.y - nextPosition.y, 0)
    local distance = horizontal:Length() / MCITEM.BlockSize()
    local horizontalSpeed = Lerp(0.0025, Vector(current.x, current.y, 0):Length(), distance)
    local verticalSpeed = current.z
    if distance < 1 then
        horizontalSpeed = horizontalSpeed * 0.8
        verticalSpeed = verticalSpeed * 0.8
    end
    local verticalTarget = nextPosition.z < target.z and 1 or -1
    verticalSpeed = verticalSpeed + (verticalTarget - verticalSpeed) * 0.015
    if distance <= 1e-7 then return Vector(0, 0, verticalSpeed) end
    horizontal:Normalize()
    return Vector(horizontal.x * horizontalSpeed, horizontal.y * horizontalSpeed, verticalSpeed)
end

function ENT:FinishEnderEye()
    local position = self:GetPos()
    if self:GetMCEyeSurvives() then
        if not Throwables.ReturnEnderEye(position, self:GetOwner(), { projectile = self }) then
            self.MCEyeVelocityValue = vector_origin
            return false
        end
    else
        Throwables.BroadcastFX(
            Throwables.FX.ENDER_EYE_DEATH,
            Throwables.LevelEventPosition(position, self)
        )
    end
    Throwables.PlayEnderEyeDeath(self)
    hook.Run("MCITEM.EnderEyeFinished", self:GetOwner(), self, self:GetMCEyeSurvives(), position)
    self:Remove()
end

function ENT:EnderEyeStep()
    if self.MCEyeLife > Throwables.EnderEyeLifetimeTicks then
        if CurTime() >= (self.MCNextReturnAttempt or 0) then
            self.MCNextReturnAttempt = CurTime() + 1
            self:FinishEnderEye()
        end
        return
    end
    local oldPosition = self:GetPos()
    local current = self.MCEyeVelocityValue or vector_origin
    local nextPosition = oldPosition + current * MCITEM.BlockSize()
    local nextVelocity = self.MCEyeTarget
        and updatedVelocity(current, nextPosition, self.MCEyeTarget) or current
    self.MCEyeVelocityValue = nextVelocity
    self:SetMCEyeVelocity(nextVelocity)
    self:SetMCEyeInWater(Throwables.FluidKindAt(oldPosition, self) == "water")
    self.MCEyeLife = self.MCEyeLife + 1
    self:SetMCEyeTick(self.MCEyeLife)
    self:SetPos(nextPosition)
    if nextVelocity:LengthSqr() > 0 then self:SetAngles(nextVelocity:Angle()) end
    if self.MCEyeLife > Throwables.EnderEyeLifetimeTicks then self:FinishEnderEye() end
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextEyeTick or now) and steps < 8 do
        self:EnderEyeStep()
        if not IsValid(self) then return false end
        self.MCNextEyeTick = self.MCNextEyeTick + Throwables.TickSeconds
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextEyeTick then self.MCNextEyeTick = now + Throwables.TickSeconds end
    self:NextThink(self.MCNextEyeTick)
    return true
end
