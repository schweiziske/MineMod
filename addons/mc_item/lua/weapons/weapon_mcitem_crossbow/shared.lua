AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")
AddCSLuaFile("mcitem/sh_ammo.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")
include("mcitem/sh_ammo.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.crossbow"
SWEP.Category = "#mcitem.category.items"
SWEP.MCInstructionsKey = "mcitem.instructions.crossbow"
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.WorldModel = "models/mcgm/crossbow/crossbow.mdl"
SWEP.MCItemID = "crossbow"
-- Crossbows have no WEAPON data component in Java.  Keep their fallback hand
-- attack on the player's bare-hand values instead of inheriting the diamond
-- sword profile from the generic model-test base.
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCIsSword = false
-- Crossbow has durability but no WEAPON component; left-click melee does not damage it.
SWEP.MCWeaponDamagePerAttack = 0
SWEP.HoldType = "crossbow"
SWEP.MCThirdPersonProfile = "crossbow"
SWEP.MCThirdPersonSwingGesture = "crossbow_attack"

-- 逐武器手持锚点微调 convar：mcitem_fp_crossbow_*
SWEP.MCAnchorName = "crossbow"

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

-- CrossbowItem.getChargeDuration starts at 1.25s * 20 = 25 tick. Quick Charge
-- applies -0.25s per level before Java floors the result: 20 / 15 / 10 tick.
local DEFAULT_CHARGE_TICKS = 25

local function useClock()
    return CLIENT and SysTime() or CurTime()
end

local function crossbowShotPitch(index)
    local zeroIndex = math.max(0, math.floor(tonumber(index) or 1) - 1)
    if zeroIndex == 0 then return 100 end
    local base = zeroIndex % 2 == 1 and 0.63 or 0.43
    return 100 * (1 / (math.Rand(0, 1) * 0.5 + 1.8) + base)
end

local function removeProjectiles(projectiles)
    for _, projectile in ipairs(projectiles or {}) do
        if IsValid(projectile) then projectile:Remove() end
    end
end

function SWEP:Initialize()
    self.BaseClass.Initialize(self)
    if SERVER then
        self:SetNW2Bool("MCITEM_CrossbowCharged", false)
        self:SetNW2Int("MCITEM_CrossbowChargeTicks", DEFAULT_CHARGE_TICKS)
        self:SetModel(self.WorldModel)
    end
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    self.MCUsing = false
    self.MCUseStartedAt = nil
    self.MCStartSoundPlayed = false
    self.MCMiddleSoundPlayed = false
    self.MCChargeTicks = nil
    if SERVER then
        self:RefreshMCChargeTicks()
        self:RefreshMCChargedProjectile()
        self:SetMCThirdPersonUseState(false)
        self:SetModel(self:IsMCCharged()
            and "models/mcgm/crossbow_arrow/crossbow_arrow.mdl"
            or self.WorldModel)
    end
    return result
end

function SWEP:IsMCCharged()
    if CLIENT and self.MCPredictedCharged ~= nil then return self.MCPredictedCharged end
    return self:GetNW2Bool("MCITEM_CrossbowCharged", false)
end

function SWEP:SetMCLocalCharged(charged)
    if CLIENT then
        self.MCPredictedCharged = charged
    else
        self:SetNW2Bool("MCITEM_CrossbowCharged", charged)
        self:SetModel(charged
            and "models/mcgm/crossbow_arrow/crossbow_arrow.mdl"
            or self.WorldModel)
    end
end

function SWEP:SetMCChargedProjectiles(stacks, infinite)
    if not SERVER then return end
    self.MCChargedProjectileStacks = MCITEM.CopyProjectileStacks(stacks)
    self.MCChargedProjectileStack = self.MCChargedProjectileStacks
        and self.MCChargedProjectileStacks[1] or nil
    self.MCChargedProjectileInfinite = infinite == true
    self:SetNW2String(
        "MCITEM_CrossbowProjectile",
        self.MCChargedProjectileStack and tostring(self.MCChargedProjectileStack.item or "") or "")
end

function SWEP:SetMCChargedProjectile(stack, infinite)
    return self:SetMCChargedProjectiles(istable(stack) and { stack } or nil, infinite)
end

function SWEP:RefreshMCChargedProjectile()
    if not SERVER then return end
    local owner = self:GetOwner()
    local stacks = IsValid(owner) and MCITEM.GetChargedProjectiles(owner, self) or nil
    self.MCChargedProjectileStacks = MCITEM.CopyProjectileStacks(stacks)
    self.MCChargedProjectileStack = self.MCChargedProjectileStacks
        and self.MCChargedProjectileStacks[1] or nil
    self.MCChargedProjectileInfinite = false
    self:SetMCLocalCharged(self.MCChargedProjectileStacks ~= nil)
    self:SetNW2String(
        "MCITEM_CrossbowProjectile",
        self.MCChargedProjectileStack and tostring(self.MCChargedProjectileStack.item or "") or "")
end

function SWEP:GetMCUseTicks()
    if not self.MCUsing or not self.MCUseStartedAt then return 0 end
    return math.max((useClock() - self.MCUseStartedAt) / MCITEM.TickSeconds, 0)
end

function SWEP:ResolveMCChargeTicks()
    local runtime = MCITEM.EnchantmentRuntime
    if not runtime or not isfunction(runtime.StackForWeapon)
        or not isfunction(runtime.GetCrossbowChargeTicks) then return DEFAULT_CHARGE_TICKS end
    local owner = self:GetOwner()
    local inventoryProxy = self.MCHandWeaponBridgeProxy == true
        or self:GetNW2Bool("MCITEM_InventoryProxy", false)
    local stack
    if CLIENT and inventoryProxy and IsValid(owner) and owner == LocalPlayer() then
        if not isfunction(runtime.GetSelectedStack) then return nil end
        stack = runtime.GetSelectedStack(owner)
        if not istable(stack) then return nil end
    else
        stack = runtime.StackForWeapon(self, owner)
    end
    return math.Clamp(math.floor(tonumber(runtime.GetCrossbowChargeTicks(stack))
        or DEFAULT_CHARGE_TICKS), 1, DEFAULT_CHARGE_TICKS)
end

function SWEP:RefreshMCChargeTicks()
    local ticks = self:ResolveMCChargeTicks()
        or self:GetNW2Int("MCITEM_CrossbowChargeTicks", DEFAULT_CHARGE_TICKS)
    self.MCChargeTicks = ticks
    if SERVER then self:SetNW2Int("MCITEM_CrossbowChargeTicks", ticks) end
    return ticks
end

function SWEP:GetMCChargeTicks()
    if CLIENT and IsValid(self:GetOwner()) and self:GetOwner() == LocalPlayer() then
        local predicted = self:ResolveMCChargeTicks()
        if predicted then return predicted end
    end
    local cached = math.floor(tonumber(self.MCChargeTicks) or 0)
    if cached > 0 then return math.Clamp(cached, 1, DEFAULT_CHARGE_TICKS) end
    return math.Clamp(self:GetNW2Int(
        "MCITEM_CrossbowChargeTicks", DEFAULT_CHARGE_TICKS), 1, DEFAULT_CHARGE_TICKS)
end

function SWEP:GetMCCrossbowShotProfile()
    local runtime = MCITEM.EnchantmentRuntime
    if not runtime or not isfunction(runtime.StackForWeapon) then return 1, 0 end
    local stack = runtime.StackForWeapon(self, self:GetOwner())
    local projectileCount = isfunction(runtime.GetCrossbowProjectileCount)
        and runtime.GetCrossbowProjectileCount(stack) or 1
    local spread = isfunction(runtime.GetCrossbowProjectileSpread)
        and runtime.GetCrossbowProjectileSpread(stack) or 0
    return math.Clamp(math.floor(tonumber(projectileCount) or 1), 1, 16),
        math.max(0, tonumber(spread) or 0)
end

function SWEP:GetMCChargingSoundKeys()
    local runtime = MCITEM.EnchantmentRuntime
    if runtime and isfunction(runtime.StackForWeapon)
        and isfunction(runtime.GetCrossbowChargingSoundKeys) then
        local stack = runtime.StackForWeapon(self, self:GetOwner())
        return runtime.GetCrossbowChargingSoundKeys(stack)
    end
    return "crossbow_loading_start", "crossbow_loading_middle", "crossbow_loading_end"
end

-- 第三人称三态：静止手臂下垂 / 装填套霰弹枪 / 上好弦套左轮。
function SWEP:GetMCHoldTypeKey()
    if self:IsMCCharged() then return "crossbow_charged" end
    if self.MCUsing or self:IsMCThirdPersonUsing() then return "crossbow_load" end
    return "crossbow"
end

function SWEP:GetMCThirdPersonBaseState()
    if self:IsMCCharged() then
        return self:GetNW2String("MCITEM_CrossbowChargeType", "arrow") == "rocket"
            and "charged_firework"
            or "charged_arrow"
    end

    local using = self.MCUsing or self:IsMCThirdPersonUsing()
    if not using then return "idle" end
    local ticks = self.MCUsing and self:GetMCUseTicks() or self:GetMCThirdPersonUseTicks()
    return MCITEM.ThirdPerson.CrossbowLoadState(ticks / self:GetMCChargeTicks())
end

--------------------------------------------------------------------------------
-- 箭矢（生存模式）
--------------------------------------------------------------------------------
--
-- `CrossbowItem.use` 没箭时返回 FAIL（不开始装填）；真正扣箭的是 `onUseTick` 里
-- 装填完成那一刻的 `tryLoadProjectiles`，之后发射用的是 CHARGED_PROJECTILES 组件，
-- **不再扣第二次**。所以这里也是"开始装填前查、装填完成时扣、发射不扣"。
local AMMO_REFRESH_SECONDS = 0.25

function SWEP:MCHasAmmo()
    return self:GetNW2Bool("MCITEM_HasAmmo", true)
end

function SWEP:MCRefreshAmmo(now)
    if not SERVER then return end
    if self.MCNextAmmoCheck and now < self.MCNextAmmoCheck then return end
    self.MCNextAmmoCheck = now + AMMO_REFRESH_SECONDS

    local owner = self:GetOwner()
    local has = IsValid(owner) and MCITEM.HasProjectileAmmo(owner, self, "crossbow") or false
    if self:GetNW2Bool("MCITEM_HasAmmo", true) ~= has then
        self:SetNW2Bool("MCITEM_HasAmmo", has)
    end
end

function SWEP:IsMCUsingItem()
    -- CrossbowItem.getUseDuration() = 72000（和弓一样，等于"按住就一直在用"）。
    -- 装填**不是**由 releaseUsing 完成的，而是 onUseTick 里 tickPercent >= 1.0 时
    -- tryLoadProjectiles —— 所以上好弦之后 isUsingItem() **依然为真**，直到松开右键。
    -- 这一条决定了下面整套手感，别改成"装填完就结束使用"。
    return self.MCUsing == true
end

-- CrossbowItem.use（**右键**物品）：
--   已装填 → performShooting（发射），InteractionResult.CONSUME
--   没装填 → startUsingItem，开始装填
--
-- Minecraft.handleKeybinds 的两条触发路径都被 isUsingItem 挡住：
--   · `if (player.isUsingItem()) { while (keyUse.consumeClick()) {} }` —— 使用中点击被丢弃
--   · `if (keyUse.isDown() && rightClickDelay == 0 && !player.isUsingItem()) startUseItem()`
-- 所以**按住右键永远不会自己把箭射出去**：装填完成后必须松开右键（结束使用）、
-- 再按一次，才走到 use() 的"已装填 → 发射"分支。
-- 早先的实现在装填完成时就结束了使用状态，于是按住右键会 4 tick 后自动发射再重装。
function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() then return end
    if SERVER then self:CancelMCMining("secondary_attack") end

    -- `!player.isUsingItem()`：使用中（含已上弦但仍按着右键）不接受新的 use。
    if self.MCUsing then return end

    if self:IsMCCharged() then
        if CLIENT then self:SetMCLocalCharged(false) end
        if SERVER then
            local owner = self:GetOwner()
            if IsValid(owner) then
                local projectileStacks = MCITEM.GetChargedProjectiles(owner, self)
                    or self.MCChargedProjectileStacks
                    or { { item = "minecraft:arrow", count = 1 } }
                projectileStacks = MCITEM.CopyProjectileStacks(projectileStacks)
                if not projectileStacks then return end

                local _, spread = self:GetMCCrossbowShotProfile()
                local shotAngles = MCITEM.CrossbowShotAngles(#projectileStacks, spread)
                local aim = owner:GetAimVector()
                local up = owner:EyeAngles():Up()
                local infiniteMaterials = MCITEM.HasInfiniteMaterials(owner)
                local projectiles = {}
                for index, projectileStack in ipairs(projectileStacks) do
                    local direction = MCITEM.RotateProjectileDirection(
                        aim, up, shotAngles[index])
                    local intangible = infiniteMaterials
                        or MCITEM.ProjectileStackIsIntangible(projectileStack)
                    local arrow = MCITEM.SpawnArrow(
                        owner,
                        self,
                        3.15,
                        1,
                        true,
                        true,
                        projectileStack,
                        intangible,
                        { direction = direction })
                    if not IsValid(arrow) then
                        removeProjectiles(projectiles)
                        return
                    end
                    projectiles[#projectiles + 1] = arrow
                end

                local committed = MCITEM.CommitCrossbowProjectilesShot(
                    owner,
                    self,
                    projectileStacks,
                    {
                        reason = "crossbow_shot",
                        projectiles = projectiles,
                        ranged = true,
                    })
                if not committed then
                    removeProjectiles(projectiles)
                    return
                end
                self:SetMCChargedProjectiles(nil, false)
                self:SetMCLocalCharged(false)
                for index = 1, #projectiles do
                    MCITEM.PlayRangedSound(
                        owner, "crossbow_shoot", 1, crossbowShotPitch(index))
                end
            end
        end
        return
    end

    -- CrossbowItem.use 的 FAIL 分支：没箭不开始装填。
    if not self:MCHasAmmo() then self:MCTryOffhandUse() return end

    self:RefreshMCChargeTicks()
    self.MCUsing = true
    self.MCUseStartedAt = useClock()
    self.MCStartSoundPlayed = false
    self.MCMiddleSoundPlayed = false
    if SERVER then self:SetMCThirdPersonUseState(true, self.MCUseStartedAt) end
end

function SWEP:FinishMCCrossbowUse()
    self.MCUsing = false
    self.MCUseStartedAt = nil
    self.MCStartSoundPlayed = false
    self.MCMiddleSoundPlayed = false
    if SERVER then self:SetMCThirdPersonUseState(false) end
end

function SWEP:Think()
    self.BaseClass.Think(self)

    if SERVER then self:MCRefreshAmmo(CurTime()) end

    if CLIENT and self.MCPredictedCharged ~= nil
        and self:GetNW2Bool("MCITEM_CrossbowCharged", false) == self.MCPredictedCharged then
        self.MCPredictedCharged = nil
    end

    if not self.MCUsing then return end

    local owner = self:GetOwner()
    local timeHeld = self:GetMCUseTicks()
    local progress = timeHeld / self:GetMCChargeTicks()

    if SERVER and not self:IsMCCharged() then self:SetModel(self:GetMCFirstPersonModel()) end

    if SERVER and IsValid(owner) then
        -- CrossbowItem.onUseTick: start at 20%, middle at 50%, load/end at 100%.
        -- Quick Charge supplies a level-specific start event and no middle event.
        local startSound, middleSound = self:GetMCChargingSoundKeys()
        if progress >= 0.2 and not self.MCStartSoundPlayed then
            self.MCStartSoundPlayed = true
            if startSound then MCITEM.PlayRangedSound(owner, startSound, 0.5, 100) end
        end
        if progress >= 0.5 and not self.MCMiddleSoundPlayed then
            self.MCMiddleSoundPlayed = true
            if middleSound then MCITEM.PlayRangedSound(owner, middleSound, 0.5, 100) end
        end
    end

    if progress >= 1 and not self:IsMCCharged() then
        -- tryLoadProjectiles：装填完成那一刻只扣一支箭，再把 Java draw()
        -- 生成的完整 projectile list 原子写入弩。Multishot 的另外两支只是
        -- intangible 副本；扣不到源箭就把这次装填作废。
        if SERVER then
            local projectileCount = self:GetMCCrossbowShotProfile()
            local projectileStacks, infiniteAmmo = MCITEM.LoadCrossbowProjectiles(
                self:GetOwner(), self, projectileCount)
            if not MCITEM.CopyProjectileStacks(projectileStacks) then
                self.MCNextAmmoCheck = nil
                self:FinishMCCrossbowUse()
                return
            end
            self:SetMCChargedProjectiles(projectileStacks, infiniteAmmo)
        end

        self:SetMCLocalCharged(true)
        -- `DataComponents.CHARGED_PROJECTILES` 注册时没带 `.ignoreSwapAnimation()`，
        -- 所以上弦那一刻 ItemInHandRenderer 认为"可见的弩 ≠ 手里的弩"，手会沉到底再抬
        -- 起来 —— 玩家描述的"拉满后沉下去再拿出来，拿出来就是上弦状态"。姿势也在同一刻
        -- 从装填分支切回 swingArm（渲染条件带 `&& !charged`）。
        MCITEM.BeginItemSwapDip(self:GetMCItemState())
        if SERVER and IsValid(owner) then
            local pitch = 100 * (1 / (math.Rand(0, 1) * 0.5 + 1) + 0.2)
            local _, _, endSound = self:GetMCChargingSoundKeys()
            if endSound then MCITEM.PlayRangedSound(owner, endSound, 1, pitch) end
        end
        -- ⚠ 这里**不能**结束使用状态：onUseTick 装填完，玩家仍在 isUsingItem。
        -- 松手才结束（下面那一段），松手之后再按右键才发射。
    end

    -- 松开右键 = releaseUsing。已上弦的保持上弦（下次右键发射）；没到 100% 的进度作废。
    if not IsValid(owner) or not owner:KeyDown(IN_ATTACK2) then
        self:FinishMCCrossbowUse()
    end
end

function SWEP:GetMCFirstPersonModel()
    if self:IsMCCharged() then
        return "models/mcgm/crossbow_arrow/crossbow_arrow.mdl"
    end
    if not self.MCUsing then return self.WorldModel end

    -- assets/minecraft/items/crossbow.json: pull thresholds 0.58 / 1.0.
    local progress = math.Clamp(self:GetMCUseTicks() / self:GetMCChargeTicks(), 0, 1)
    if progress >= 1 then
        return "models/mcgm/crossbow_pulling_2/crossbow_pulling_2.mdl"
    elseif progress >= 0.58 then
        return "models/mcgm/crossbow_pulling_1/crossbow_pulling_1.mdl"
    end
    return "models/mcgm/crossbow_pulling_0/crossbow_pulling_0.mdl"
end

function SWEP:GetMCFirstPersonDisplay()
    -- assets/minecraft/models/item/crossbow.json, firstperson_righthand.
    return {
        translation = { 1.13, 3.2, 1.13 },
        rotation = { -90, 0, -55 },
        scale = { 0.68, 0.68, 0.68 },
    }
end

-- ItemInHandRenderer 的弩分支只有**装填中**才是独立姿势：
--     if (isUsingItem && useTicks > 0 && hand matches && !charged) { ...装填姿势... }
--     else { swingArm(attack); if (charged && attack < 0.001 && mainHand) { 静止偏移 } }
-- 所以"上好弦"不是一个会吞掉挥动的姿势——上弦的弩照样挥手、照样挖方块。
-- 早先这里在 charged 时返回 "crossbow_charged"，等于把整段挥动换掉了，表现就是
-- "弩拉满之后没有挖方块的动作"。
function SWEP:GetMCUseRenderState()
    if self.MCUsing and not self:IsMCCharged() then
        return "crossbow", self:GetMCUseTicks(), self:GetMCChargeTicks()
    end
    return nil
end

-- `if (charged && attack < 0.001f && isMainHand)` 那两行，接在 swingArm 之后。
function SWEP:GetMCSwingExtra(translate, rotate, swing, side)
    if not CLIENT or not MCITEM.Render then return end
    if not self:IsMCCharged() then return end
    MCITEM.Render.ApplyCrossbowChargedIdle(translate, rotate, side, swing)
end

-- "已上弦"是和"装填中"**并列**的第三种静止态（源码里前者走 swingArm + 静止偏移，
-- 后者走装填分支），几何差一支箭，所以它有自己的一组 `mcitem_charged_crossbow_*`。
--
-- ⚠ 判据只看 charged，**不能**再加"没按着右键"：渲染分支的条件是
-- `isUsingItem && useTicks > 0 && hand匹配 && !charged`，一旦 charged 就落到 else 分支，
-- 和右键按没按着无关。早先多加了一道 `if self.MCUsing then return nil end`，于是按住
-- 右键上弦之后拿到的是"fp 锚点 + 上弦模型"、没有 charged 偏移，松手才跳到正确姿势。
function SWEP:GetMCAnchorExtraState()
    if self:IsMCCharged() then return "charged" end
    return nil
end
