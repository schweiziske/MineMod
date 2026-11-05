AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")
AddCSLuaFile("mcitem/sh_ammo.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")
include("mcitem/sh_ammo.lua")

local TRIDENT_USE_REJECTED = "mcitem_trident_use_rejected"
if SERVER then
    util.AddNetworkString(TRIDENT_USE_REJECTED)
else
    net.Receive(TRIDENT_USE_REJECTED, function()
        local weapon = net.ReadEntity()
        if not IsValid(weapon) or weapon:GetClass() ~= "weapon_mcitem_trident" then return end
        if weapon:GetOwner() ~= LocalPlayer() then return end
        weapon.MCTridentUsing = false
        weapon.MCTridentUseStartedAt = nil
    end)
end

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.trident"
SWEP.Category = "#mcitem.category.items"
SWEP.MCInstructionsKey = "mcitem.instructions.trident"
SWEP.Spawnable = true
SWEP.AdminOnly = false
-- ThrownTridentRenderer / 手持都用 **TridentModel**（真 3D 模型，贴图
-- textures/entity/trident/trident.png），不是 item/trident.png 那张 GUI 精灵。
-- trident_3d 是拿 Bedrock 的 trident.geo.json + Java 的 entity 贴图重烘的：
-- 长轴在模型 **+Z**（hull 2.83 × 11.91 × 71.26 ≈ 1.95 格），和 MC 的 31px 一致。
SWEP.WorldModel = "models/mcgm/trident_3d/trident_3d.mdl"
SWEP.MCItemID = "trident"
SWEP.MCGlintProfile = "entity"

-- 逐武器手持锚点微调 convar：mcitem_fp_trident_*
SWEP.MCAnchorName = "trident"
SWEP.HoldType = "melee"
SWEP.MCHoldTypeName = "trident"
SWEP.MCThirdPersonProfile = "trident"
SWEP.MCThirdPersonSwingGesture = "trident_melee"

-- TridentItem.createAttributes: player base 1 + item modifier 8 = 9 damage;
-- player base 4 + item modifier -2.9 = 1.1 attack speed.
SWEP.MCAttackDamage = 9
SWEP.MCAttackSpeed = 1.1
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 1

SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = true,
    Ammo = "none",
}

local function useClock()
    return CLIENT and SysTime() or CurTime()
end

local function tridentRuntimeStack(weapon, owner)
    local runtime = MCITEM.EnchantmentRuntime
    if runtime and isfunction(runtime.StackForWeapon) then
        return runtime.StackForWeapon(weapon, owner)
    end
    return nil
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    self.MCTridentUsing = false
    self.MCTridentUseStartedAt = nil
    if SERVER then self:SetMCThirdPersonUseState(false) end
    return result
end

function SWEP:GetMCTridentUseTicks()
    if not self.MCTridentUsing or not self.MCTridentUseStartedAt then return 0 end
    return math.max((useClock() - self.MCTridentUseStartedAt) / MCITEM.TickSeconds, 0)
end

-- TridentItem.use → startUsingItem。三叉戟没有覆写 USE_EFFECTS，所以吃
-- UseEffects.DEFAULT 的 0.2 倍移动 + 禁止冲刺（sh_use_effects.lua 的 SetupMove）。
-- getFieldOfViewModifier 只对 Items.BOW 缩 FOV，三叉戟**不放大视角**。
function SWEP:IsMCUsingItem()
    return self.MCTridentUsing == true
end

-- 第三人称：静止和近战一套（`mcitem_holdtype_trident`），右键投出去的那一下
-- 走 `mcitem_holdtype_throw`（默认丢手雷）。
function SWEP:GetMCHoldTypeKey()
    return (self.MCTridentUsing or self:IsMCThirdPersonUsing()) and "trident_charge" or "trident"
end

function SWEP:GetMCThirdPersonBaseState()
    return (self.MCTridentUsing or self:IsMCThirdPersonUsing()) and "charge" or "idle"
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if self.MCTridentUsing or not IsFirstTimePredicted() then return end
    if CLIENT and MCITEM.CanPredictThrowWeaponStack(
        self:GetOwner(), "minecraft:trident", 1) == false then self:MCTryOffhandUse() return end
    if SERVER then
        local owner = self:GetOwner()
        if not IsValid(owner) then return end
        local allowed = MCITEM.CanThrowWeaponStack(owner, self, "minecraft:trident", 1)
        if not allowed then
            net.Start(TRIDENT_USE_REJECTED)
                net.WriteEntity(self)
            net.Send(owner)
            self:MCTryOffhandUse()
            return
        end
    end
    local owner = self:GetOwner()
    local runtime = MCITEM.EnchantmentRuntime
    local stack = tridentRuntimeStack(self, owner)
    if runtime and isfunction(runtime.GetRiptideLevel)
        and runtime.GetRiptideLevel(stack) > 0
        and isfunction(runtime.CanUseRiptide)
        and not runtime.CanUseRiptide(owner) then
        self:MCTryOffhandUse()
        return
    end
    if SERVER then self:CancelMCMining("secondary_attack") end

    self.MCTridentUsing = true
    self.MCTridentUseStartedAt = useClock()
    if SERVER then self:SetMCThirdPersonUseState(true, self.MCTridentUseStartedAt) end
end

-- TridentItem.releaseUsing：投出去 = **这一件物品离开玩家**。ThrownTrident 带着那份
-- ItemStack 飞出去，捡回来才还给背包。所以这里三件事一起做：
--   ① 生成弹丸；② 从 MineMod 背包的选中槽扣掉这一件；③ 收掉手上的 SWEP。
-- 没装 MineMod（= 没有背包）时 ② 是 no-op，但 ③ 照做：手上那一把已经飞出去了，
-- 这一点和背包在不在场无关。
function SWEP:ReleaseMCTrident()
    if not self.MCTridentUsing then return end

    local timeHeld = math.floor(self:GetMCTridentUseTicks() + 1e-6)
    self.MCTridentUsing = false
    self.MCTridentUseStartedAt = nil
    if SERVER then self:SetMCThirdPersonUseState(false) end
    if timeHeld < 10 then return end

    if not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    local runtime = MCITEM.EnchantmentRuntime
    local stack = tridentRuntimeStack(self, owner)
    local riptide = runtime and isfunction(runtime.GetRiptideLevel)
        and runtime.GetRiptideLevel(stack) or 0
    if riptide > 0 and runtime and isfunction(runtime.StartRiptide) then
        local allowed = MCITEM.CanThrowWeaponStack(owner, self, "minecraft:trident", 1)
        if not allowed then return end
        local started = runtime.StartRiptide(owner, self, stack, function()
            local hasInventory = MCITEM.HasInventorySystem(owner)
            if not isfunction(self.ApplyMCDurabilityDamage) then
                return not hasInventory
            end
            local result = self:ApplyMCDurabilityDamage(1, {
                reason = "trident_riptide",
                enchantment = "minecraft:riptide",
            })
            return not hasInventory or result ~= false
        end)
        if started then self:PlayMCGesture("throw") end
        return
    end

    local allowed = MCITEM.CanThrowWeaponStack(owner, self, "minecraft:trident", 1)
    if not allowed then return end

    local projectile = MCITEM.SpawnTrident(owner, self)
    if not IsValid(projectile) then return end

    local thrownStack, infinite = MCITEM.TakeThrownWeaponStack(owner, self, "minecraft:trident", 1)
    if thrownStack == false or (MCITEM.HasInventorySystem(owner) and not istable(thrownStack)) then
        projectile:Remove()
        return
    end
    projectile:SetMCPickupStack(thrownStack, infinite)

    -- 只有服务端确认弹丸与 inventory 事务都成功后才广播投掷动作/声音。
    self:PlayMCGesture("throw")
    MCITEM.PlayRangedSound(owner, "trident_throw", 1, 100)

    -- 背包桥扣掉选中槽之后 MC Hands 会重新解析并切走，但从生成菜单直接拿的那一把
    -- 没有背包栈可扣，必须自己收掉，否则玩家手里会凭空多出一把三叉戟。
    -- 创造模式的 consumeAndReturn 不移除原栈，因此也绝不能 StripWeapon。
    if infinite then return end
    local weapon = self
    timer.Simple(0, function()
        if IsValid(weapon) and IsValid(owner) and owner:HasWeapon(weapon:GetClass()) then
            owner:StripWeapon(weapon:GetClass())
        end
    end)
end

function SWEP:Think()
    self.BaseClass.Think(self)

    local owner = self:GetOwner()
    if self.MCTridentUsing and (not IsValid(owner) or not owner:KeyDown(IN_ATTACK2)) then
        self:ReleaseMCTrident()
    end
end

function SWEP:GetMCFirstPersonModel()
    return self.WorldModel
end

-- assets/minecraft/items/trident.json 的 `scale: [1,-1,-1]` 写在 **condition 节点本身**。
-- `ConditionalItemModel.Unbaked.bake` 会先 compose 这份 transformation，再用同一个
-- childTransform 烘 on_true / on_false 两支，所以它不是“仅 using_item 时多转 180°”。
-- 两个 base 的 firstperson_righthand display 又完全相同；开始使用后的相对位姿只来自
-- ItemInHandRenderer 的 TRIDENT 分支（-0.5/0.7/0.1、-55°/35.3°/-9.785°，随后 10 tick
-- 后拉 0.2 格）。之前把 180° 只加在使用态，才会让三叉戟按下右键直接翻到头顶。
-- 当前 Source 模型的静止锚点已经按实际闲置朝向校准，因此这里必须保持两种状态同 display。
function SWEP:GetMCFirstPersonDisplay()
    -- assets/minecraft/models/item/trident_in_hand.json / trident_throwing.json,
    -- firstperson_righthand.
    return {
        translation = { -3, 17, 1 },
        rotation = { 0, -90, 25 },
        scale = { 1, 1, 1 },
    }
end

function SWEP:GetMCUseRenderState()
    if not self.MCTridentUsing then return nil end
    return "trident", self:GetMCTridentUseTicks(), 10
end
