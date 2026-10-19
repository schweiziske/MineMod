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

-- Alpha blending is ordered across both potion and throwable pools. Batch
-- only adjacent compatible entries after sorting, rather than regrouping by
-- material and destroying depth order. Queue/vertex storage survives frames.
MCITEM.AlphaParticlePools = MCITEM.AlphaParticlePools or {}
local alphaPools = MCITEM.AlphaParticlePools
local drawQueue, previousCount = {}, 0
MCITEM.AlphaParticleSerial = MCITEM.AlphaParticleSerial or 0
local vertexPosition = Vector()
-- Keep each dynamic DX9 submission comfortably inside Source's vertex limit,
-- including the triangle expansion of quads, even with an unlimited budget.
local MAX_BATCH_QUADS = 4096

local function farther(left, right)
    if left.depth == right.depth then return left.serial < right.serial end
    return left.depth > right.depth
end

local function alphaVertex(x, y, z, u, v, r, g, b, alpha)
    vertexPosition.x, vertexPosition.y, vertexPosition.z = x, y, z
    mesh.Position(vertexPosition)
    mesh.TexCoord(0, u, v)
    mesh.Color(r, g, b, alpha)
    mesh.AdvanceVertex()
end

hook.Add("PostDrawTranslucentRenderables", "MCITEM.AlphaParticles", function(depth, skybox)
    if depth or skybox then return end
    local now, eye, angles = CurTime(), EyePos(), EyeAngles()
    local forward, right, up = angles:Forward(), angles:Right(), angles:Up()
    local count = 0
    for _, pool in pairs(alphaPools) do
        for _, particle in ipairs(pool.particles) do
            local entry = particle.mcDrawEntry
            if not entry then
                MCITEM.AlphaParticleSerial = MCITEM.AlphaParticleSerial + 1
                entry = { serial = MCITEM.AlphaParticleSerial, particle = particle }
                particle.mcDrawEntry = entry
            end
            local partial = math.Clamp((now - particle.lastTickAt) / pool.interval, 0, 1)
            local old, position = particle.oldPosition, particle.position
            entry.x = Lerp(partial, old.x, position.x)
            entry.y = Lerp(partial, old.y, position.y)
            entry.z = Lerp(partial, old.z, position.z)
            entry.depth = (entry.x - eye.x) * forward.x + (entry.y - eye.y) * forward.y
                + (entry.z - eye.z) * forward.z
            entry.material, entry.frame, entry.size = particle.material, -1, particle.quadSize
            if particle.kind == "spell" then
                entry.material = particle.family == "spell" and pool.spellMaterial or pool.effectMaterial
                entry.frame = 7 - math.floor(particle.age * 7 / particle.lifetime)
            elseif particle.kind == "effect" then
                entry.frame = 7 - math.floor(particle.age * 7 / particle.lifetime)
            elseif particle.kind == "gust" then
                entry.frame = math.floor(particle.age * (particle.frameCount - 1) / particle.lifetime)
            elseif particle.kind == "portal" then
                local progress = math.Clamp((particle.age + partial) / particle.lifetime, 0, 1)
                entry.size = entry.size * (2 * progress - progress * progress)
            end
            count = count + 1
            drawQueue[count] = entry
        end
    end
    for index = count + 1, previousCount do drawQueue[index] = nil end
    previousCount = count
    if count == 0 then return end
    table.sort(drawQueue, farther)
    local blockSize, index = MCITEM.BlockSize(), 1
    while index <= count do
        local first = drawQueue[index]
        local last = index
        while last < count and last - index + 1 < MAX_BATCH_QUADS
            and drawQueue[last + 1].material == first.material
            and drawQueue[last + 1].frame == first.frame do last = last + 1 end
        render.SetMaterial(first.material)
        if first.frame >= 0 then first.material:SetInt("$frame", first.frame) end
        mesh.Begin(MATERIAL_QUADS, last - index + 1)
        for item = index, last do
            local entry = drawQueue[item]
            local particle, radius = entry.particle, entry.size * blockSize
            local rx, ry, rz = right.x * radius, right.y * radius, right.z * radius
            local ux, uy, uz = up.x * radius, up.y * radius, up.z * radius
            local u0, u1, v0, v1 = 0, 1, 0, 1
            if particle.kind == "fragment" then
                u0, u1 = (particle.uo + 1) / 4, particle.uo / 4
                v0, v1 = particle.vo / 4, (particle.vo + 1) / 4
            end
            local r, g, b = particle.r * particle.litR * 255,
                particle.g * particle.litG * 255, particle.b * particle.litB * 255
            local alpha = particle.alpha * 255
            alphaVertex(entry.x-rx-ux, entry.y-ry-uy, entry.z-rz-uz, u1,v1,r,g,b,alpha)
            alphaVertex(entry.x+rx-ux, entry.y+ry-uy, entry.z+rz-uz, u0,v1,r,g,b,alpha)
            alphaVertex(entry.x+rx+ux, entry.y+ry+uy, entry.z+rz+uz, u0,v0,r,g,b,alpha)
            alphaVertex(entry.x-rx+ux, entry.y-ry+uy, entry.z-rz+uz, u1,v0,r,g,b,alpha)
        end
        mesh.End()
        index = last + 1
    end
end)

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
