include("shared.lua")

include("mcitem/potions/particles/cl_core.lua")
include("mcitem/potions/particles/cl_cloud.lua")

function ENT:Initialize()
    self.MCNextClientCloudTick = CurTime() + MCITEM.Potions.TickSeconds
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextClientCloudTick or now) and steps < 8 do
        MCITEM.Potions.SpawnCloudParticles(self)
        self.MCNextClientCloudTick = self.MCNextClientCloudTick + MCITEM.Potions.TickSeconds
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextClientCloudTick then
        self.MCNextClientCloudTick = now + MCITEM.Potions.TickSeconds
    end
    self:SetNextClientThink(self.MCNextClientCloudTick)
    return true
end

function ENT:Draw()
end
