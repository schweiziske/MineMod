AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")
AddCSLuaFile("mcitem/sh_ammo.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")
include("mcitem/sh_ammo.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.bow"
SWEP.Category = "#mcitem.category.items"
SWEP.MCInstructionsKey = "mcitem.instructions.bow"
SWEP.Spawnable = true
SWEP.AdminOnly = false
-- MCITEM owns the stable *_item family and can ship standalone. BMB's skeleton mounts
-- MCITEM and consumes this same model; its attachment ConVars own the mob-specific pose.
SWEP.WorldModel = "models/mcgm/bow_item/bow_item.mdl"
SWEP.MCItemID = "bow"
-- Bows have no WEAPON data component in Java.  Their fallback hand attack is
-- the player's bare-hand 1 damage at 4 attack speed, not this base SWEP's
-- diamond-sword profile.
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCIsSword = false
-- Bow has durability but no WEAPON component; left-click melee does not damage it.
SWEP.MCWeaponDamagePerAttack = 0
SWEP.HoldType = "crossbow"
SWEP.MCThirdPersonProfile = "bow"
SWEP.MCThirdPersonSwingGesture = "bow_attack"

-- 逐武器手持锚点微调 convar：mcitem_fp_bow_x/_y/_z/_pitch/_yaw/_roll/_scale
SWEP.MCAnchorName = "bow"

SWEP.Primary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = true,
    Ammo = "none",
}
SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = true,
    Ammo = "none",
}

local function useClock()
    return CLIENT and SysTime() or CurTime()
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    self.MCUsing = false
    self.MCUseStartedAt = nil
    if SERVER then
        self:SetMCThirdPersonUseState(false)
        self:SetModel(self.WorldModel)
    end
    return result
end

function SWEP:GetMCUseTicks()
    if not self.MCUsing or not self.MCUseStartedAt then return 0 end
    return math.max((useClock() - self.MCUseStartedAt) / MCITEM.TickSeconds, 0)
end

function SWEP:IsMCUsingItem()
    return self.MCUsing == true
end

-- 第三人称：拿着时手臂下垂，拉弓套左轮（`mcitem_holdtype_bow` / `_bow_draw`）。
function SWEP:GetMCHoldTypeKey()
    return (self.MCUsing or self:IsMCThirdPersonUsing()) and "bow_draw" or "bow"
end

function SWEP:GetMCThirdPersonBaseState()
    local using = self.MCUsing or self:IsMCThirdPersonUsing()
    if not using then return "idle" end

    local ticks = self.MCUsing and self:GetMCUseTicks() or self:GetMCThirdPersonUseTicks()
    return MCITEM.ThirdPerson.BowDrawState(ticks * 0.05)
end

--------------------------------------------------------------------------------
-- 箭矢（生存模式）
--------------------------------------------------------------------------------
--
-- `BowItem.use`：`if (!player.hasInfiniteMaterials() && player.getProjectile(stack).isEmpty())
-- return InteractionResult.FAIL;` —— **没箭连拉弓的动作都不会开始**。
-- 背包是服务端权威的，客户端看不到；所以服务端每 5 tick 把结论写进 NW2，两端读同一个
-- 值，预测不会分叉。创造模式和没装 MineMod 时恒为真。
local AMMO_REFRESH_SECONDS = 0.25

function SWEP:MCHasAmmo()
    return self:GetNW2Bool("MCITEM_HasAmmo", true)
end

function SWEP:MCRefreshAmmo(now)
    if not SERVER then return end
    if self.MCNextAmmoCheck and now < self.MCNextAmmoCheck then return end
    self.MCNextAmmoCheck = now + AMMO_REFRESH_SECONDS

    local owner = self:GetOwner()
    local has = IsValid(owner) and MCITEM.HasProjectileAmmo(owner, self, "bow") or false
    if self:GetNW2Bool("MCITEM_HasAmmo", true) ~= has then
        self:SetNW2Bool("MCITEM_HasAmmo", has)
    end
end

-- AbstractClientPlayer.getFieldOfViewModifier：拉弓时 FOV 缩到 1 - (t/20)^2 * 0.15，
-- 满弓 0.85 倍。**只有弓有**，弩 / 三叉戟走的是 isScoping 那一支（望远镜专用）。
function SWEP:GetMCFovModifier()
    if not self.MCUsing then return nil end
    return MCITEM.BowFovModifier(self:GetMCUseTicks())
end

-- BowItem.use → player.startUsingItem(hand)。MC 里弓是**右键**物品，左键仍然是
-- 普通的攻击 / 挖掘（由 base 的 PrimaryAttack 提供），所以这里只覆写 SecondaryAttack。
function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if self.MCUsing or not IsFirstTimePredicted() then return end
    -- BowItem.use 的 FAIL 分支：没箭不开始拉弓。
    if not self:MCHasAmmo() then self:MCTryOffhandUse() return end
    if SERVER then self:CancelMCMining("secondary_attack") end

    self.MCUsing = true
    self.MCUseStartedAt = useClock()
    if SERVER then self:SetMCThirdPersonUseState(true, self.MCUseStartedAt) end
end

function SWEP:ReleaseMCBow()
    if not self.MCUsing then return end

    local timeHeld = math.floor(self:GetMCUseTicks() + 1e-6)
    local power = MCITEM.BowPowerForTicks(timeHeld)
    self.MCUsing = false
    self.MCUseStartedAt = nil
    if SERVER then self:SetMCThirdPersonUseState(false) end
    self:SetNextSecondaryFire(CurTime() + MCITEM.TickSeconds)
    if SERVER then self:SetModel(self.WorldModel) end

    if SERVER and power >= 0.1 then
        local owner = self:GetOwner()
        if IsValid(owner) then
            -- ProjectileWeaponItem.draw/useAmmo 先选中完整箭栈，再让 AMMO_USE 决定
            -- 实际扣除数。Infinity 对普通箭返回 0，并把复制出的箭标成不可回收；
            -- 光灵箭仍扣 1。背包里完全没箭时两者都不能凭空发射。
            local ammoStack, infiniteAmmo = MCITEM.TakeProjectileAmmo(owner, self, "bow", 1)
            if not istable(ammoStack) then
                self.MCNextAmmoCheck = nil
                return
            end

            local arrow = MCITEM.SpawnArrow(
                owner, self, power * 3, 1, power == 1, false, ammoStack, infiniteAmmo)
            if not IsValid(arrow) then
                if not infiniteAmmo
                    and MCITEM.GiveItemToPlayer(owner, ammoStack, 1, owner:GetPos()) then
                    self.MCNextAmmoCheck = nil
                end
                return
            end
            self:ApplyMCDurabilityDamage(1, {
                reason = "bow_shot",
                projectile = arrow,
                ranged = true,
            })

            -- BowItem.releaseUsing: 1/(random*0.4+1.2) + power*0.5.
            local pitch = 100 * (1 / (math.Rand(0, 1) * 0.4 + 1.2) + power * 0.5)
            MCITEM.PlayRangedSound(owner, "bow_shoot", 1, pitch)
            self.MCNextAmmoCheck = nil
        end
    end
end

function SWEP:Think()
    self.BaseClass.Think(self)

    local owner = self:GetOwner()
    if SERVER then
        self:MCRefreshAmmo(CurTime())
        if self.MCUsing then self:SetModel(self:GetMCFirstPersonModel()) end
    end
    if self.MCUsing and (not IsValid(owner) or not owner:KeyDown(IN_ATTACK2)) then
        self:ReleaseMCBow()
    end
end

function SWEP:GetMCFirstPersonModel()
    if not self.MCUsing then return self.WorldModel end

    -- assets/minecraft/items/bow.json: use_duration * 0.05, thresholds 0.65 / 0.9.
    local progress = self:GetMCUseTicks() * 0.05
    if progress >= 0.9 then
        return "models/mcgm/bow_pulling_2_item/bow_pulling_2_item.mdl"
    elseif progress >= 0.65 then
        return "models/mcgm/bow_pulling_1_item/bow_pulling_1_item.mdl"
    end
    return "models/mcgm/bow_pulling_0_item/bow_pulling_0_item.mdl"
end

function SWEP:GetMCUseRenderState()
    if not self.MCUsing then return nil end
    return "bow", self:GetMCUseTicks(), 20
end
