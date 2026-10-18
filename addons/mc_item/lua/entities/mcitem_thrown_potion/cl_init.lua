include("shared.lua")

function ENT:Draw()
    -- ThrownItemRenderer：始终正对**本客户端**相机的物品精灵（见 cl_billboard.lua）。
    if isfunction(MCITEM.DrawBillboardModel) then
        MCITEM.DrawBillboardModel(self)
    else
        self:DrawModel()
    end
end
