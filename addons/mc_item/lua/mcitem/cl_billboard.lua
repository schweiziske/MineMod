-- 投掷物的公告板绘制（ThrownItemRenderer / EyeOfEnderRenderer）。
--
-- MC 里飞在空中的雪球、鸡蛋、末影珍珠、附魔之瓶、药水和末影之眼**不是 3D 模型**，
-- 而是一张始终正对相机的物品精灵：
--     poseStack.mulPose(entityRenderDispatcher.cameraOrientation());
--     poseStack.mulPose(Axis.YP.rotationDegrees(180.0F));
-- 注意它用的是**相机朝向**而不是"看向相机"，所以同一时刻所有投掷物都和屏幕平行；
-- 而且每个玩家的客户端各自算自己那一份 —— 两个玩家看同一颗末影珍珠，各自看到的
-- 都是正面。
--
-- 我们的物品模型是 item/generated 的挤出件：模型局部 X = 厚度、Y = 水平、Z = 竖直
-- （见 STATE_MCITEM 的 display.scale 那一条）。实体的 Forward 就是局部 +X，所以把
-- 视角朝向绕 Up 转 180° 之后 Forward 正好指向相机，精灵面与屏幕平行；Right 同时翻转，
-- 对应源码那句 `Axis.YP.rotationDegrees(180)`。
--
-- 箭和三叉戟**不走这里**：MC 给它们的是真正的 3D 模型（TridentModel / ArrowRenderer），
-- 朝向由飞行方向决定。

if not CLIENT then return end

MCITEM = MCITEM or {}

local cvBillboard = CreateClientConVar("mcitem_projectile_billboard", "1", true, false,
    "Draw thrown items (snowballs, eggs, pearls, potions, ender eyes) as camera-facing sprites like Minecraft. 0 = draw the raw model.")

function MCITEM.BillboardAngles()
    local angles = EyeAngles()
    angles:RotateAroundAxis(angles:Up(), 180)
    return angles
end

function MCITEM.DrawBillboardModel(entity)
    if not IsValid(entity) then return end

    if not cvBillboard:GetBool() then
        if isfunction(MCITEM.DrawModelWithMCLight) then
            MCITEM.DrawModelWithMCLight(entity)
        else
            entity:DrawModel()
        end
        return
    end

    entity:SetRenderAngles(MCITEM.BillboardAngles())
    if isfunction(MCITEM.DrawModelWithMCLight) then
        MCITEM.DrawModelWithMCLight(entity)
    else
        entity:DrawModel()
    end
    entity:SetRenderAngles()
end
