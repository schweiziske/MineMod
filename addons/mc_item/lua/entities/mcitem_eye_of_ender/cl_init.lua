include("shared.lua")

include("mcitem/throwables/particles/cl_core.lua")
include("mcitem/throwables/particles/cl_trails.lua")

function ENT:Initialize()
    self.MCLastEyeTrailTick = self:GetMCEyeTick()
end

function ENT:Think()
    MCITEM.Throwables.UpdateEnderEyeTrail(self)
    self:SetNextClientThink(CurTime())
    return true
end

function ENT:Draw()
    -- ThrownItemRenderer：始终正对**本客户端**相机的物品精灵（见 cl_billboard.lua）。
    if isfunction(MCITEM.DrawBillboardModel) then
        MCITEM.DrawBillboardModel(self)
    else
        self:DrawModel()
    end
end
