AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")

ENT.Type = "anim"
ENT.Base = "base_anim"
-- Public combat code may use this marker to distinguish a direct projectile
-- source from the firing SWEP without depending on this addon's entity class.
ENT.MCProjectile = true
ENT.MCShieldProjectile = true
ENT.PrintName = "#mcitem.entity.arrow"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
    self:NetworkVar("Vector", 0, "MCVelocity")
    -- 插住时的命中面法线 + 最终落点：客户端拿法线把**采光取样点**推到表面外面，
    -- 拿落点直接定位（绕开实体插值，否则会看到"先陷进去再被拉出来"）。
    self:NetworkVar("Vector", 1, "StickNormal")
    self:NetworkVar("Vector", 2, "StickOrigin")
    self:NetworkVar("Bool", 0, "Critical")
    self:NetworkVar("Bool", 1, "InGround")
    self:NetworkVar("Bool", 2, "CrossbowArrow")
    self:NetworkVar("Bool", 3, "SpectralArrow")
end

--------------------------------------------------------------------------------
-- 飞行朝向
--------------------------------------------------------------------------------
--
-- `velocity:Angle()` 让实体的 **+X（Forward）** 指向飞行方向。模型长轴不在 +X 上就会
-- 看着"横着飞"，得按模型自己的轴补一次旋转：
--   · 箭 models/mcmodelpack/entities/arrow：长轴 +X（hull 36.75 × 11.9 × 11.9）→ 偏移 0
--   · 三叉戟 models/mcgm/trident_3d：长轴 +Z（hull 2.83 × 11.91 × 71.26）→ 绕 Right 转 90°，
--     把 Up 摆到飞行方向上（对应 MC 的 Axis.ZP.rotationDegrees(xRot + 90)）
-- 每个弹丸一组服务端 convar，实机对着看着调，调好抄回默认值。
ENT.MCModelAngleOffset = Angle(0, 0, 0)
ENT.MCAngleConVarName = "arrow"

local angleConVars = {}

local function angleConVarSet(name, default)
    local existing = angleConVars[name]
    if existing then return existing end

    local flags = FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED
    local created = {
        pitch = CreateConVar("mcitem_" .. name .. "_model_pitch", tostring(default.p), flags,
            "Model-axis correction applied on top of the flight direction."),
        yaw = CreateConVar("mcitem_" .. name .. "_model_yaw", tostring(default.y), flags, ""),
        roll = CreateConVar("mcitem_" .. name .. "_model_roll", tostring(default.r), flags, ""),
    }
    angleConVars[name] = created
    return created
end

function ENT:MCModelAngle(base)
    local angles = Angle(base.p, base.y, base.r)
    local set = angleConVarSet(self.MCAngleConVarName, self.MCModelAngleOffset)

    local pitch, yaw, roll = set.pitch:GetFloat(), set.yaw:GetFloat(), set.roll:GetFloat()
    if yaw ~= 0 then angles:RotateAroundAxis(angles:Up(), yaw) end
    if pitch ~= 0 then angles:RotateAroundAxis(angles:Right(), pitch) end
    if roll ~= 0 then angles:RotateAroundAxis(angles:Forward(), roll) end

    return angles
end

function ENT:MCFlightAngle(velocity)
    if not velocity or velocity:LengthSqr() <= 1e-8 then return self:GetAngles() end
    return self:MCModelAngle(velocity:Angle())
end

--------------------------------------------------------------------------------
-- 朝向跟随速度的**平滑**（Projectile.lerpRotation）
--------------------------------------------------------------------------------
--
--     protected static float lerpRotation(float rotO, float rot) {
--         while (rot - rotO < -180.0f) rotO -= 360.0f;
--         while (rot - rotO >= 180.0f)  rotO += 360.0f;
--         return Mth.lerp(0.2f, rotO, rot);
--     }
--
-- 每 tick 只往目标角度**走 20%**。我们原来是每 tick 直接 `SetAngles(velocity:Angle())`
-- 硬对齐，所以三叉戟命中生物后速度被 deflect 成近乎垂直的一瞬间，模型会"啪"地立起来；
-- 原版是用大约 5 tick 转过去的。
local ROTATION_LERP = 0.2

local function lerpRotation(from, to)
    while to - from < -180 do from = from - 360 end
    while to - from >= 180 do from = from + 360 end
    return from + (to - from) * ROTATION_LERP
end

-- `snap` 为真时直接对齐（发射那一刻 Projectile.shoot 就是直接设的，没有平滑）。
function ENT:MCUpdateFlightRotation(velocity, snap)
    if not velocity or velocity:LengthSqr() <= 1e-8 then return end

    local target = velocity:Angle()
    if snap or not self.MCRotPitch then
        self.MCRotPitch, self.MCRotYaw = target.p, target.y
    else
        self.MCRotPitch = lerpRotation(self.MCRotPitch, target.p)
        self.MCRotYaw = lerpRotation(self.MCRotYaw, target.y)
    end

    self:SetAngles(self:MCModelAngle(Angle(self.MCRotPitch, self.MCRotYaw, 0)))
end

--------------------------------------------------------------------------------
-- 插进方块里的深度
--------------------------------------------------------------------------------
--
-- MC 的 `AbstractArrow.onHitBlock` 是 `setPos(position - signum(delta) * 0.05)`：把
-- **实体原点**收回 0.05 格。那是 MC 自己的几何——箭的原点几乎就在箭头上，所以看起来
-- 只有箭头扎进去。我们的模型不是：arrow.mdl 长 36.75u、trident_3d 长 71.26u，原点都在
-- 几何中心，照抄 0.05 格会让半根矛没入墙里（用户看到的"插得比较深"）。
--
-- 所以这里按语义等价的方式实现：先算出模型在飞行方向上的**最前端**（尖端）离原点多远，
-- 让尖端正好越过命中面 stickDepth 格，其余部分留在外面。stickDepth 默认取 MC 那个
-- 0.05 格（≈1.8u），需要再调用 mcitem_projectile_stick_depth。
local cvStickDepth = CreateConVar(
    "mcitem_projectile_stick_depth", "0.05",
    FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED,
    "How far past the hit surface a stuck arrow/trident tip sits, in Minecraft blocks."
)

local BOX_SIGNS = { -1, 1 }

-- 模型包围盒 8 个角在 `direction` 上的最大投影 = 尖端离原点的距离。
-- 用 LocalToWorld 而不是手推 Forward/Right/Up，免得踩 Source 局部 y 轴的符号约定。
function ENT:MCTipDistance(direction)
    local mins, maxs = self:OBBMins(), self:OBBMaxs()
    if not mins or not maxs then return 0 end

    local origin = self:GetPos()
    local best = 0
    for _, sx in ipairs(BOX_SIGNS) do
        for _, sy in ipairs(BOX_SIGNS) do
            for _, sz in ipairs(BOX_SIGNS) do
                local corner = Vector(
                    sx < 0 and mins.x or maxs.x,
                    sy < 0 and mins.y or maxs.y,
                    sz < 0 and mins.z or maxs.z
                )
                local projection = (self:LocalToWorld(corner) - origin):Dot(direction)
                if projection > best then best = projection end
            end
        end
    end
    return best
end

-- 命中面 → 实体原点该放哪。调用前 **必须**已经把角度设成 MCFlightAngle 的结果，
-- 因为尖端方向是从当前角度算出来的。
function ENT:MCRestPosition(hitPos, direction)
    if not isvector(direction) or direction:LengthSqr() <= 1e-8 then return hitPos end

    local penetration = math.max(cvStickDepth:GetFloat(), 0) * MCITEM.BlockSize()
    return hitPos - direction * math.max(self:MCTipDistance(direction) - penetration, 0)
end

--------------------------------------------------------------------------------
-- 拾取（AbstractArrow.Pickup）
--------------------------------------------------------------------------------
MCITEM.Pickup = MCITEM.Pickup or {
    DISALLOWED = 0,
    ALLOWED = 1,
    CREATIVE_ONLY = 2,
}

-- AbstractArrow 的默认值就是 DISALLOWED；`setOwner` 只在射手是**玩家**时提到 ALLOWED
-- （OminousItemSpawner 强制 DISALLOWED，怪物落到 default 分支保持原值）。
-- 这一条就是"玩家捡不到 mob 射出来的箭"的出处，不需要额外规则。
ENT.MCPickup = MCITEM.Pickup.DISALLOWED

-- `AbstractArrow.getPickupItem()`：捡起来放进背包的是哪一件物品。
-- MCPickupWeaponClass 只在没有背包系统时用（把 SWEP 直接还回去）。
ENT.MCPickupItemID = "minecraft:arrow"
ENT.MCPickupWeaponClass = nil


