AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/potions/sv_apply.lua")

function ENT:Initialize()
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:DrawShadow(false)
    self:SetNoDraw(true)
    self:SetCloudRadius(MCITEM.Potions.CloudRadius)
    self:SetWaiting(true)
    self.MCCloudAge = 0
    self.MCCloudVictims = {}
    self.MCNextCloudTick = CurTime() + MCITEM.Potions.TickSeconds
    self:NextThink(self.MCNextCloudTick)
end

function ENT:SetupPotionCloud(owner, potionId)
    local definition = MCITEM.Potions.Get(potionId)
    if not definition then return false end
    self:SetPotionID(definition.id)
    self:SetPotionColor(definition.color or MCITEM.Potions.EmptyColor)
    self:SetCloudOwner(owner)
    return true
end

local function cleanVictims(cloud)
    for target, retryTick in pairs(cloud.MCCloudVictims) do
        if not IsValid(target) or cloud.MCCloudAge >= retryTick then
            cloud.MCCloudVictims[target] = nil
        end
    end
end

function ENT:ApplyCloudEffects()
    local definition = MCITEM.Potions.Get(self:GetPotionID())
    if not definition or #(definition.effects or {}) == 0 then
        self.MCCloudVictims = {}
        return
    end

    cleanVictims(self)
    local radius = self:GetCloudRadius()
    local blockSize = MCITEM.BlockSize()
    local extent = Vector(radius * blockSize, radius * blockSize, 0.25 * blockSize)
    for _, target in ipairs(ents.FindInBox(self:GetPos() - extent, self:GetPos() + extent)) do
        if MCITEM.Potions.IsLivingTarget(target) and not self.MCCloudVictims[target] then
            local delta = target:GetPos() - self:GetPos()
            local horizontalDistanceSquared = (delta.x * delta.x + delta.y * delta.y) / (blockSize * blockSize)
            if horizontalDistanceSquared <= radius * radius then
                local eligible = false
                for _, effect in ipairs(definition.effects) do
                    if MCITEM.Potions.CanReceiveEffect(target, effect.id, self:GetCloudOwner(), {
                        delivery = "cloud", cloud = self,
                    }) then eligible = true break end
                end
                if eligible then
                    self.MCCloudVictims[target] = self.MCCloudAge
                        + MCITEM.Potions.CloudReapplicationDelayTicks
                    MCITEM.Potions.ApplyPotion(target, definition, self:GetCloudOwner(), {
                        bottleType = "lingering",
                        delivery = "cloud",
                        durationScale = MCITEM.Potions.CloudDurationScale,
                        instantPotency = MCITEM.Potions.CloudInstantPotency,
                        cloud = self,
                    })
                    radius = radius + MCITEM.Potions.CloudRadiusOnUse
                    self:SetCloudRadius(radius)
                    if radius < 0.5 then
                        self:Remove()
                        return
                    end
                end
            end
        end
    end
end

function ENT:CloudStep()
    self.MCCloudAge = self.MCCloudAge + 1
    if self.MCCloudAge - MCITEM.Potions.CloudWaitTicks >= MCITEM.Potions.CloudDurationTicks then
        self:Remove()
        return
    end

    local waiting = self.MCCloudAge < MCITEM.Potions.CloudWaitTicks
    self:SetWaiting(waiting)
    if waiting then return end

    local radius = self:GetCloudRadius() + MCITEM.Potions.CloudRadiusPerTick
    if radius < 0.5 then
        self:Remove()
        return
    end
    self:SetCloudRadius(radius)
    if self.MCCloudAge % MCITEM.Potions.CloudApplyIntervalTicks == 0 then
        self:ApplyCloudEffects()
    end
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextCloudTick or now) and steps < 8 do
        self:CloudStep()
        if not IsValid(self) then return false end
        self.MCNextCloudTick = self.MCNextCloudTick + MCITEM.Potions.TickSeconds
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextCloudTick then
        self.MCNextCloudTick = now + MCITEM.Potions.TickSeconds
    end
    self:NextThink(self.MCNextCloudTick)
    return true
end
