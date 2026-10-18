-- MC 物品测试 SWEP：钻石剑。
--
-- 四件事按 MC 26.2 的源码移植（解包在 D:\BMBTools\26.2\nnnewest）：
--   ① 挥动动画  ItemInHandRenderer.swingArm + LivingEntity 的 swingTime 状态机
--   ② 手部升降  ItemInHandRenderer.tick 的 mainHandHeight（"剑沉下去再举起来"）
--   ③ 攻击结算  Player.attack（蓄力缩放 / 暴击 / 横扫 / 击退）
--   ④ 准星冷却条 Hud.extractCrosshair
--
-- 通用逻辑全在 `lua/mcitem/`（命名空间 `MCITEM`），**不依赖 BMB**，整目录可以单独
-- 拷给别人做生存模式；本文件只是它的第一个使用者。
--
-- ⚠ 关于"挖掘和攻击是不是同一个动作"：在 26.2 里**第一人称挥动是同一段动画**。
-- 26.2 新增的 `SwingAnimationType` 是**按物品**分的（none / whack / stab），不是按
-- 动作分的：剑、斧、镐拿到的都是 SwingAnimation.DEFAULT = (WHACK, 6 tick)，
-- Minecraft.startAttack 不论打生物、打方块还是打空，最后都统一 `player.swing()`。
-- 长矛才是另一条（STAB → SpearAnimations.firstPersonAttack）。
--
-- 两者的差别来自两处，都不是"另一段动画"：
--   · 重启门：LivingEntity.swing 只在 swingTime >= duration/2 时才准重来。挖掘每
--     tick 请求一次 → 6 tick 的剑每 4 tick 重启 → 只播得到曲线前半段（0 → 0.5）在
--     那循环；单次攻击没人打断 → 完整播完 0 → 1。
--   · 手部升降：攻击（打空**和**打中都算）以及换物品会把 ticker 清零，手沉下去再按
--     `(ticker / 攻击冷却)^3` 抬起来——**和准星那个冷却图标是同一条时间轴**。
--     挖掘不清 ticker，所以挖的时候手一直是举着的。
--
-- 复用给斧 / 镐等物品：改下面 MC 参数区的字段，或直接 SWEP.Base 继承本武器。

AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_tuning.lua")
AddCSLuaFile("mcitem/sh_holdtypes.lua")
AddCSLuaFile("mcitem/sh_combat_audio.lua")
AddCSLuaFile("mcitem/sh_block_interact.lua")
AddCSLuaFile("mcitem/sh_use_effects.lua")
AddCSLuaFile("mcitem/sh_enchantments.lua")
AddCSLuaFile("mcitem/sh_inventory_input_guard.lua")
AddCSLuaFile("mcitem/mining/sh_contract.lua")
AddCSLuaFile("mcitem/mining/sv_adapter.lua")
AddCSLuaFile("mcitem/cl_model_lighting.lua")
AddCSLuaFile("mcitem/cl_item_render.lua")
AddCSLuaFile("mcitem/cl_crosshair.lua")
AddCSLuaFile("mcitem/cl_combat_particles.lua")
AddCSLuaFile("mcitem/cl_enchantment_glint.lua")
AddCSLuaFile("cl_view.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_tuning.lua")
include("mcitem/sh_holdtypes.lua")
include("mcitem/sh_combat_audio.lua")
include("mcitem/sh_block_interact.lua")
include("mcitem/sh_use_effects.lua")
include("mcitem/sh_enchantments.lua")
include("mcitem/sh_inventory_input_guard.lua")
include("mcitem/mining/sh_contract.lua")

local THIRD_PERSON_GESTURE_NET = "MCITEM_ThirdPersonGesture"
if SERVER then util.AddNetworkString(THIRD_PERSON_GESTURE_NET) end

SWEP.Base = "weapon_base"
SWEP.PrintName = "BMB Item Model Test"
SWEP.Author = "BMB"
SWEP.Instructions = "Left click: attack in the air / on a mob, mining swing on a block or wall."
SWEP.Category = "Minecraft in GMod - Testing"
-- This file is the shared implementation inherited by every public MCITEM
-- weapon.  Keep the base class registered, but do not expose its old test entry
-- (or the otherwise-empty Testing category) in the spawn menu.
SWEP.Spawnable = false
SWEP.AdminOnly = false

SWEP.ViewModel = "models/weapons/c_arms_citizen.mdl"
SWEP.WorldModel = "models/mcgm/diamond_sword/diamond_sword.mdl"
SWEP.UseHands = false
SWEP.ViewModelFOV = 80
SWEP.DrawAmmo = false
-- Public MC.API.HandWeapon presentation capability. Inventory proxies based on
-- MCITEM keep their native ViewModelDrawn path because it owns swing/use/equip
-- animation as well as the model; the inventory renderer must not draw a
-- second static copy over it.
SWEP.MCHandWeaponOwnsFirstPerson = true
-- Opt every descendant into the shared inventory mouse-input guard.  The
-- StartCommand filter is intentionally keyed by this inherited marker so
-- derived SWEPs that replace PrimaryAttack/SecondaryAttack are covered too.
SWEP.MCITEMInventoryInputGuard = true
-- 自己画 MC 准星（cl_view.lua 的 DrawHUD），不要 GMod 那个。
SWEP.DrawCrosshair = false
SWEP.HoldType = "normal"
SWEP.Primary = {
    ClipSize = -1,
    DefaultClip = -1,
    -- 左键要同时表达 startAttack（按下一次）和 continueAttack（按住挖掘），所以引擎层
    -- 开自动、由 MCAttackLatched 把"起手那一次"闩住，挖掘循环走 Think。
    Automatic = true,
    Ammo = "none",
}
SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    -- Minecraft.handleKeybinds 的 use 那一半：consumeClick 之外还有
    -- `keyUse.isDown() && rightClickDelay == 0 && !isUsingItem` 的按住重复。
    Automatic = true,
    Ammo = "none",
}

--------------------------------------------------------------------------------
-- MC 物品参数（换成斧 / 镐只需要改这一段）
--------------------------------------------------------------------------------

-- ItemStack.getSwingAnimation()：SwingAnimation.DEFAULT = (WHACK, 6)。
SWEP.MCSwingType = MCITEM.SwingAnimationType.WHACK
SWEP.MCSwingDurationTicks = 6

-- Attributes 的**合计值**（玩家基值 + 物品修饰符），不是物品那一半：
--   ATTACK_DAMAGE = 1(玩家) + 3(Items.DIAMOND_SWORD) + 3(ToolMaterial.DIAMOND) = 7
--   ATTACK_SPEED  = 4(玩家) + (-2.4)(钻石剑) = 1.6 → 冷却 12.5 tick = 0.625s
-- 冷却这一个数同时决定三件事：伤害缩放、准星冷却条、手部抬起来的时长。
SWEP.MCAttackDamage = 7
SWEP.MCAttackSpeed = 1.6
SWEP.MCAttackKnockback = 0 -- Attributes.ATTACK_KNOCKBACK 的物品加成
-- DataComponents.WEAPON.itemDamagePerAttack。剑为 1；普通工具由注册表覆写为 2。
-- 没有 WEAPON 组件的普通物品（食物、药水、弓弩的左键敲击等）必须保持 nil/0。
SWEP.MCWeaponDamagePerAttack = 1

-- ItemTags.SWORDS 成员才有横扫（Player.isSweepAttack）。
SWEP.MCIsSword = true

-- HoeItem / ShovelItem / AxeItem 的 useOn。nil = 这件物品右键没有功能（剑、镐）。
SWEP.MCUseAction = nil

-- DataComponents.USE_EFFECTS，默认 UseEffects.DEFAULT。长矛覆写成 (true, 1.0)。
SWEP.MCUseSpeedMultiplier = MCITEM.DefaultUseSpeedMultiplier
SWEP.MCUseCanSprint = MCITEM.DefaultUseCanSprint

-- Minecraft.startUseItem 一律先 `this.rightClickDelay = 4`。
SWEP.MCRightClickDelayTicks = 4

if SERVER then
    include("mcitem/mining/sv_adapter.lua")
    include("sv_attack.lua")
else
	include("mcitem/cl_model_lighting.lua")
	include("mcitem/cl_combat_particles.lua")
	include("mcitem/cl_enchantment_glint.lua")
	include("cl_view.lua")
end

--------------------------------------------------------------------------------
-- 生命周期
--------------------------------------------------------------------------------

function SWEP:Initialize()
    self:UpdateMCHoldType()
    self:SetModelScale(0.55, 0)
    self:ResetMCState()
end

function SWEP:Deploy()
    self:UpdateMCHoldType()
    self:ResetMCState()
    return true
end

--------------------------------------------------------------------------------
-- 第三人称 holdtype（sh_holdtypes.lua 的 convar 映射）
--------------------------------------------------------------------------------
--
-- Source 只有一组玩家动画集可选，所以第三人称是"每个状态挑一套 HL2 动作"。
-- 状态键由各武器覆写 `GetMCHoldTypeKey`（弓拉没拉、弩上没上弦…），投掷 / 开火
-- 这类一次性动作走 `PlayMCGesture`：临时换 holdtype + 播一次 PLAYER_ATTACK1。
--
-- 手势要**两端一致**才不会出现"服务端在丢手雷、客户端还举着剑"，所以服务端把
-- 手势和截止时间写进 NW2，客户端优先读它。

function SWEP:GetMCHoldTypeKey()
    return self.MCHoldTypeName or "item"
end

-- 弓 / 弩 / 长矛 / 三叉戟的连续使用态必须让旁观客户端也能看到。开始时间使用
-- 服务端 CurTime，客户端只做 `(CurTime() - startedAt)` 推算，不逐 tick 发网络消息。
function SWEP:SetMCThirdPersonUseState(active, startedAt)
    if not SERVER then return end
    active = active == true
    self:SetNW2Bool("MCITEM_ThirdPersonUsing", active)
    self:SetNW2Float("MCITEM_ThirdPersonUseStartedAt", active and (startedAt or CurTime()) or 0)
end

function SWEP:IsMCThirdPersonUsing()
    return self:GetNW2Bool("MCITEM_ThirdPersonUsing", false)
end

function SWEP:GetMCThirdPersonUseTicks()
    if not self:IsMCThirdPersonUsing() then return 0 end
    local startedAt = self:GetNW2Float("MCITEM_ThirdPersonUseStartedAt", CurTime())
    return math.max((CurTime() - startedAt) / MCITEM.TickSeconds, 0)
end

-- 武器只声明 profile 和基础状态；模型表、手势→状态映射、ConVar 与绘制都集中在
-- sh_holdtypes.lua / cl_view.lua，避免把第三人称判断散落到每个 shared.lua。
function SWEP:GetMCThirdPersonState()
    local profile = self.MCThirdPersonProfile
    if not profile then return nil end

    local gesture = self:ActiveMCGestureKey()
    local state = MCITEM.ThirdPerson
        and MCITEM.ThirdPerson.GestureState(profile, gesture)
    if state then return state end

    if self.GetMCThirdPersonBaseState then
        state = self:GetMCThirdPersonBaseState()
        if state then return state end
    end
    return "idle"
end

function SWEP:GetMCThirdPersonRenderState()
    if CLIENT then
        local code = self:GetNW2Int("MCITEM_ThirdPersonState", -1)
        local state = MCITEM.ThirdPerson and MCITEM.ThirdPerson.StateSyncReverse[code]
        if state then return state end
    end
    return self:GetMCThirdPersonState()
end

function SWEP:SyncMCThirdPersonState()
    if not SERVER or not MCITEM.ThirdPerson then return end
    local state = self:GetMCThirdPersonState() or "idle"
    local code = MCITEM.ThirdPerson.StateSync[state] or 0
    if self:GetNW2Int("MCITEM_ThirdPersonState", -1) ~= code then
        self:SetNW2Int("MCITEM_ThirdPersonState", code)
    end
end

function SWEP:GetMCThirdPersonModel()
    local profile = self.MCThirdPersonProfile
    local state = self:GetMCThirdPersonRenderState()
    if not profile or not state or not MCITEM.ThirdPerson then return self.WorldModel end
    return MCITEM.ThirdPerson.ResolveModel(profile, state, self.WorldModel)
end

function SWEP:ActiveMCGestureKey()
    local key, expiresAt = self.MCGestureKey, self.MCGestureUntil

    if CLIENT then
        local networkedKey = self:GetNW2String("MCITEM_Gesture", "")
        local networkedUntil = self:GetNW2Float("MCITEM_GestureUntil", 0)
        if networkedKey ~= "" and networkedUntil > CurTime() then
            key, expiresAt = networkedKey, networkedUntil
        end
    end

    if key and expiresAt and CurTime() < expiresAt then return key end
    return nil
end

function SWEP:TriggerMCGestureAnimation()
    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    -- TranslateActivity reads the weapon's current holdtype table. Apply the
    -- temporary gesture holdtype first, then dispatch GMod's standard primary
    -- attack event so melee / crossbow / grenade each select their own ACT.
    self:UpdateMCHoldType()
    owner:SetAnimation(PLAYER_ATTACK1)
end

function SWEP:PlayMCGesture(key, duration)
    if not key then return end
    local now = CurTime()
    local gestureDuration = tonumber(duration) or MCITEM.GestureSeconds or 0.6
    local expiresAt = now + gestureDuration
    self.MCGestureKey = key
    self.MCGestureUntil = expiresAt

    -- GMod 的 weapon_base 在共享预测攻击路径里直接 SetAnimation。预测客户端先
    -- 立即播放；服务端不再额外发引擎动画事件，而是广播下面的可靠消息，让每个
    -- 客户端先装好临时 holdtype 再播放。这样既不会让本地 thirdperson 漏动作，
    -- 也不会让远端因 NW2 和动画事件的同帧竞态选到上一套 ACT。
    if CLIENT then
        self.MCLocalGestureKey = key
        self.MCLocalGestureAt = now
        self:TriggerMCGestureAnimation()
    end

    if SERVER then
        self:SetNW2String("MCITEM_Gesture", key)
        self:SetNW2Float("MCITEM_GestureUntil", expiresAt)

        net.Start(THIRD_PERSON_GESTURE_NET)
        net.WriteEntity(self)
        net.WriteString(key)
        net.WriteFloat(gestureDuration)
        net.Broadcast()
    end
end

if CLIENT then
    net.Receive(THIRD_PERSON_GESTURE_NET, function()
        local weapon = net.ReadEntity()
        local key = net.ReadString()
        local duration = math.max(net.ReadFloat(), 0)
        if not IsValid(weapon) or not key or key == "" then return end

        local now = CurTime()
        weapon.MCGestureKey = key
        weapon.MCGestureUntil = math.max(weapon.MCGestureUntil or 0, now + duration)

        -- The owning client normally played shared predicted actions already.
        -- Do not restart that same gesture when its server confirmation arrives;
        -- server-only actions (notably successful bow/crossbow fire) have no such
        -- prediction marker and therefore play here immediately.
        local owner = weapon:GetOwner()
        local predictedLocally = IsValid(owner)
            and owner == LocalPlayer()
            and weapon.MCLocalGestureKey == key
            and weapon.MCLocalGestureAt
            and now - weapon.MCLocalGestureAt <= math.max(duration, 0.25)
        if predictedLocally then
            weapon.MCLocalGestureKey = nil
            weapon.MCLocalGestureAt = nil
            return
        end

        -- An entity net message can arrive before the derived SWEP table has
        -- finished attaching its methods on a joining client. Retry briefly so
        -- the server-confirmed fire/throw gesture is not lost during that race.
        local function triggerWhenReady(attemptsLeft)
            if not IsValid(weapon) then return end
            if weapon.TriggerMCGestureAnimation then
                weapon:TriggerMCGestureAnimation()
                return
            end
            if attemptsLeft <= 0 then return end
            timer.Simple(0, function() triggerWhenReady(attemptsLeft - 1) end)
        end
        triggerWhenReady(2)
    end)
end

function SWEP:UpdateMCHoldType()
    local key = self:ActiveMCGestureKey() or self:GetMCHoldTypeKey()
    local holdType = isfunction(MCITEM.HoldType) and MCITEM.HoldType(key) or self.HoldType
    if not holdType or holdType == self.MCAppliedHoldType then return end
    self.MCAppliedHoldType = holdType
    self:SetHoldType(holdType)
end

function SWEP:ResetMCState()
    local now = CurTime()
    self.MCItemState = MCITEM.NewItemState()
    -- Player.resetAttackStrengthTicker()：**两个 ticker 一起清**（attackStrengthTicker
    -- 管伤害/冷却条，itemSwapTicker 管手部高度）。换物品、挥空、打中生物三种情况都会
    -- 走到它，所以本 SWEP 只留一个时间戳。
    --   · 换物品   Player.tick 发现主手变了 → resetAttackStrengthTicker()
    --   · 挥空     Minecraft.startAttack 的 MISS 分支 → resetAttackStrengthTicker()
    --   · 打中生物 MultiPlayerGameMode.attack：player.attack(target) 之后**紧接着**
    --              又调了一次 resetAttackStrengthTicker()。（Player.attack 内部的
    --              onAttack() 只清攻击 ticker，那是服务端路径，服务端不渲染手。）
    self.MCAttackResetAt = now
    -- 普通攻击的客户端路径会同时清 attackStrengthTicker / itemSwapTicker，故默认
    -- 两者共用一个时间点。26.2 的 PiercingWeapon（长矛）是例外：它只调用
    -- LivingEntity.onAttack()，因此长矛突刺只清攻击蓄力、不会让手部重新下沉。
    -- 单独保留这条时间轴，默认武器的行为完全不变。
    self.MCItemSwapResetAt = now
    self.MCThirdPersonSwingAt = nil
    self.MCAttackLatched = false
    self.MCMissUntil = nil
    self.MCNextMineRequestAt = nil
end

--------------------------------------------------------------------------------
-- 逐 tick 状态（共享；客户端拿来渲染，服务端拿来决定第三人称动作）
--------------------------------------------------------------------------------

function SWEP:GetMCItemState()
    if not self.MCItemState then self.MCItemState = MCITEM.NewItemState() end
    return self.MCItemState
end

-- 把 20Hz 时钟推到 now，返回 partialTick（tick 内的插值比例）。同一帧调用任意多次都安全。
--
-- ⚠ **客户端只能从渲染上下文调它**（ViewModelDrawn / DrawHUD），不能从 Think 或
-- PrimaryAttack 调。SWEP:Think 和 PrimaryAttack 跑在**预测**上下文里，那里的
-- CurTime() 领先渲染时钟；让它去推 tickAt 的话，渲染侧每帧都会看到 now < tickAt，
-- 于是 partialTick 恒为 0 —— 挥动 / 手部升降 / 晃动全部退化成 20Hz 阶梯，
-- 在 100+ fps 下看起来就是"掉帧"。服务端没有这个问题（只有一个时钟，从 Think 推）。
function SWEP:AdvanceMCItem(now)
    now = now or CurTime()

    local state = self:GetMCItemState()
    local owner = self:GetOwner()

    local params = {
        swingTicks = self.MCSwingDurationTicks,
        -- ItemInHandRenderer.tick 用的是 getItemSwapScale(1.0)：看前一个 tick。
        itemSwapScale = MCITEM.ScaleFromTicker(
            MCITEM.Ticker(self.MCItemSwapResetAt or self.MCAttackResetAt, now),
            1,
            self:GetMCAttackStrengthDelay()
        ),
        handsBusy = false,
        movedBlocks = 0,
        onGround = true,
        pitch = 0,
        yaw = 0,
    }

    if IsValid(owner) then
        local position = owner:GetPos()
        if state.lastPos then
            local delta = position - state.lastPos
            params.movedBlocks = math.sqrt(delta.x * delta.x + delta.y * delta.y) / MCITEM.BlockSize()
        else
            state.lastPos = position
        end

        params.onGround = owner:IsOnGround()

        local eyeAngles = owner:EyeAngles()
        params.pitch = eyeAngles.p
        params.yaw = eyeAngles.y
    end

    local partialTick, steps = MCITEM.Advance(state, now, params)

    -- movedBlocks 是"距上一 tick"的量，所以只在真的走了 tick 之后才挪基准点。
    if steps and steps > 0 and IsValid(owner) then
        state.lastPos = owner:GetPos()
    end

    self.MCLastPartialTick = partialTick
    return partialTick
end

-- LivingEntity.swing(MAIN_HAND)
function SWEP:MCSwing(now)
    return MCITEM.Swing(self:GetMCItemState(), self.MCSwingDurationTicks, now)
end

--------------------------------------------------------------------------------
-- 攻击蓄力 / 换手计时
--------------------------------------------------------------------------------

function SWEP:GetMCAttackStrengthDelay()
    return MCITEM.AttackStrengthDelay(self.MCAttackSpeed)
end

-- Player.getAttackStrengthScale(partialTick)
function SWEP:GetMCAttackStrengthScale(now, partialTick)
    return (MCITEM.ChargeFrom(self.MCAttackResetAt, now or CurTime(), self.MCAttackSpeed, partialTick))
end

-- Player.resetAttackStrengthTicker()：伤害缩放、准星冷却条、手部升降三者共用这一个时间戳。
function SWEP:ResetMCAttackStrength(now)
    local resetAt = now or CurTime()
    self.MCAttackResetAt = resetAt
    self.MCItemSwapResetAt = resetAt
end

-- LivingEntity.onAttack / resetOnlyAttackStrengthTicker：只清伤害蓄力，不动
-- ItemInHandRenderer 的 itemSwapTicker。PiercingWeapon 的左键突刺走这一条。
function SWEP:ResetMCOnlyAttackStrength(now)
    self.MCAttackResetAt = now or CurTime()
end

--------------------------------------------------------------------------------
-- 准星命中解析（Minecraft.hitResult：ENTITY / BLOCK / MISS 三选一）
--------------------------------------------------------------------------------

-- MCSWEP 的世界基建实体：区块、碰撞承载体、掉落物、它自己的弹丸。这些是"方块"，
-- 不是可攻击目标（打它们等于对着方块挥空手）。名字来自 MCSWEP 的
-- `mc_item_hand/shared.lua` 的 COMBAT_INFRASTRUCTURE，语义保持一致。
MCITEM.CombatInfrastructureClasses = {
    mc_chunk = true,
    mc_chunk_phys = true,
    mc_block_cluster = true,
    mc_collision_carrier = true,
    mc_item_drop = true,
    mc_projectile = true,
}

-- MC 的 `Player.attack` 只要求目标 `isAttackable()`，不要求它是生物：船、矿车、
-- 盔甲架、画都能打。原来这里只认玩家 / NPC / NextBot，所以以后加载具类实体会打不动。
-- 现在的判据：排除 MCSWEP 基建 → 玩家 / NPC / NextBot / BMB 生物 → 其余任何**有血量**
-- 的实体（载具、船、矿车这类自定义 SENT 都满足）。纯装饰 prop 的 Health() 是 0，
-- 仍然落在外面，所以左键打 prop 照旧走"挖掘挥动"分支。
local function isAttackTarget(owner, target)
    if not IsValid(target) or target == owner or target == game.GetWorld() then return false end
    if target:IsWorld() then return false end
    -- BMBDead / IsBMBMob 是 BMB mob 插件的可选互操作字段：装了就别打尸体，没装
    -- 这两个读都是 nil，不构成依赖。
    if target.BMBDead then return false end

    local className = target.GetClass and target:GetClass() or ""
    if MCITEM.CombatInfrastructureClasses[className] then return false end

    if target:IsPlayer() or target:IsNPC() or target:IsNextBot() or target.IsBMBMob == true then
        return true
    end

    -- 船 / 矿车这类将来要加的实体：有血量就能打。
    local health = target.Health and tonumber(target:Health()) or nil
    return health ~= nil and health > 0
end

MCITEM.IsAttackTarget = isAttackTarget

-- AttackRange.defaultFor(player) = (0, ENTITY_INTERACTION_RANGE, ...)，原版 3 格。
-- 实际距离走 `mcitem_attack_range`（默认 4.5 格，见 sh_tuning.lua）：Source 的视角
-- 更贴脸、玩家碰撞盒也更宽，照抄 3 格实机偏短。
function SWEP:MCAttackRangeBlocks()
    if isfunction(MCITEM.AttackRangeBlocks) then return MCITEM.AttackRangeBlocks() end
    return MCITEM.PlayerEntityInteractionRange
end

function SWEP:MCResolveAttackTarget(owner)
    if not IsValid(owner) then return nil, nil end

    local startPosition = owner:GetShootPos()
    local trace = util.TraceLine({
        start = startPosition,
        endpos = startPosition + owner:GetAimVector()
            * (MCITEM.BlockSize() * self:MCAttackRangeBlocks()),
        filter = owner,
        mask = MASK_SHOT,
    })

    local tracedEntity = trace.Entity
    local target = MC and isfunction(MC.ResolveMinecraftVehicle)
        and MC.ResolveMinecraftVehicle(tracedEntity) or tracedEntity
    if isAttackTarget(owner, target) then
        return target, trace
    end
    return nil, trace
end

-- Player.blockInteractionRange()。MCSWEP 方块走它自己的 reach（PlayerAim 传 nil），
-- Source 世界（地图墙 / prop）用这个距离。
MCITEM.PlayerBlockInteractionRange = 4.5

-- HitResult.Type.BLOCK：先问 MCSWEP 有没有体素方块，再退回 Source 世界表面。
-- 用户要求的"左键墙壁也是挖掘"就在第二条上：gm_flatgrass 的地面 / 玩家 prop 都算。
--
-- Minecraft 的 hitResult 会在 ENTITY / BLOCK 中选择更近的一项。MCSWEP 的体素 DDA
-- 只看方块，所以这里必须补一次实体遮挡；否则生物、船、矿车或普通 Source 实体站在
-- 方块前时，左键仍会穿过去启动后方方块的挖掘。
function SWEP:MCEntityOccludesBlockHit(owner, hit)
    if not IsValid(owner) or not hit then return false end
    if MC and isfunction(MC.TraceEntityBeforeBlock) then
        local target, trace = MC.TraceEntityBeforeBlock(owner, hit)
        return IsValid(target), target, trace
    end

    local startPosition = owner:GetShootPos()
    local direction = owner:GetAimVector()
    local hitPosition = hit.HitPos
    if not hitPosition or not direction or direction:LengthSqr() <= 0 then return false end
    direction = Vector(direction.x, direction.y, direction.z)
    direction:Normalize()
    local distance = math.max(0, (hitPosition - startPosition):Dot(direction))
    local trace = util.TraceLine({
        start = startPosition,
        endpos = startPosition + direction * (distance + math.max(MCITEM.BlockSize() * 0.001, 0.01)),
        filter = function(entity)
            if entity == owner or entity == self then return false end
            local className = IsValid(entity) and entity.GetClass and entity:GetClass() or ""
            return MCITEM.CombatInfrastructureClasses[className] ~= true
        end,
        mask = MASK_SHOT,
    })
    local tracedEntity = trace.Entity
    local target = MC and isfunction(MC.ResolveMinecraftVehicle)
        and MC.ResolveMinecraftVehicle(tracedEntity) or tracedEntity
    if not IsValid(target) or target == owner or target:IsWorld() then return false, nil, trace end
    return true, target, trace
end

function SWEP:MCResolveBlockHit(owner)
    if not IsValid(owner) then return nil end

    local voxel = MCITEM.BlockInteract.AimBlock(owner)
    if voxel then
        if self:MCEntityOccludesBlockHit(owner, voxel) then return nil end
        return voxel
    end

    local startPosition = owner:GetShootPos()
    local trace = util.TraceLine({
        start = startPosition,
        endpos = startPosition + owner:GetAimVector()
            * (MCITEM.BlockSize() * MCITEM.PlayerBlockInteractionRange),
        filter = function(entity)
            if entity == owner or entity == self then return false end
            local className = IsValid(entity) and entity.GetClass and entity:GetClass() or ""
            return MCITEM.CombatInfrastructureClasses[className] ~= true
        end,
        mask = MASK_SOLID,
    })

    if trace.Hit then
        if IsValid(trace.Entity) and not trace.Entity:IsWorld() then return nil end
        return trace
    end
    return nil
end

--------------------------------------------------------------------------------
-- 输入（Minecraft.startAttack / continueAttack / startUseItem）
--------------------------------------------------------------------------------

function SWEP:MCInventoryInputBlocked(owner)
    local guard = MCITEM.InventorySWEPInputGuard
    return guard and isfunction(guard.BlocksWeapon)
        and guard.BlocksWeapon(self, owner) == true or false
end

-- Player.cannotAttackWithItem：MINIMUM_ATTACK_CHARGE 没满时**整个 startAttack 提前
-- 返回**——不挥动、不挖掘、不清 ticker。只有长矛设了这个组件。
function SWEP:MCCannotAttackWithItem(now)
    local required = self.MCMinimumAttackCharge
    if not required or required <= 0 then return false end
    return self:GetMCAttackStrengthScale(now, 0) < required
end

-- LivingEntity.isUsingItem()。拉弓 / 装填 / 三叉戟蓄力 / 长矛冲刺时为真。
function SWEP:IsMCUsingItem()
    return false
end

-- DataComponents.USE_EFFECTS，交给 sh_use_effects.lua 的 SetupMove 钩子消费。
function SWEP:GetMCUseEffects()
    if not self:IsMCUsingItem() then return nil end
    return self.MCUseSpeedMultiplier, self.MCUseCanSprint
end

-- ItemStack durability bridge. MCITEM deliberately does not invent a second
-- inventory: survival/backpack addons can implement MCITEM.SWEPDurabilityDamage
-- or one of the optional instance callbacks below. `amount` is already the exact
-- component value (Tool.damagePerBlock / Weapon.itemDamagePerAttack).
function SWEP:ApplyMCDurabilityDamage(amount, context)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return false end
    local owner = self:GetOwner()
    local handled = hook.Run("MCITEM.SWEPDurabilityDamage", self, owner, amount, context)
    if handled ~= nil then return handled end

    if isfunction(self.OnMCDurabilityDamage) then
        local result = self:OnMCDurabilityDamage(amount, context)
        if result ~= nil then return result end
    end

    local reason = istable(context) and context.reason or nil
    if reason == "mine" and isfunction(self.OnMCMineDurabilityDamage) then
        return self:OnMCMineDurabilityDamage(amount, context)
    end
    if reason == "attack" and isfunction(self.OnMCAttackDurabilityDamage) then
        return self:OnMCAttackDurabilityDamage(amount, context)
    end
    return false
end

local function durabilityContext(context, reason)
    local result = istable(context) and table.Copy(context) or {}
    result.reason = result.reason or reason
    return result
end

function SWEP:ApplyMCMineDurabilityDamage(amount, context)
    return self:ApplyMCDurabilityDamage(amount, durabilityContext(context, "mine"))
end

function SWEP:ApplyMCAttackDurabilityDamage(amount, context)
    return self:ApplyMCDurabilityDamage(amount, durabilityContext(context, "attack"))
end

function SWEP:StartMCMining(hit, context)
    if not SERVER or not MCITEM.Mining or not MCITEM.Mining.Start then return false end
    return MCITEM.Mining.Start(self, hit, context)
end

function SWEP:CancelMCMining(reason)
    if not SERVER or not MCITEM.Mining or not MCITEM.Mining.Cancel then return false end
    return MCITEM.Mining.Cancel(self, reason)
end

-- AbstractClientPlayer.getFieldOfViewModifier 的物品那一支（只有弓有）。
function SWEP:GetMCFovModifier()
    return nil
end

-- Camera.setup 的一阶平滑（每 tick 收敛一半）。TranslateFOV 和第一人称的"手不跟着
-- 缩放"补偿必须用**同一个**值，否则两边会互相拉扯。
function SWEP:GetMCSmoothedFovModifier(now)
    local target = self:GetMCFovModifier()
    if not target then
        self.MCFovModifierAt = nil
        self.MCFovModifierValue = nil
        return nil
    end
    return MCITEM.AdvanceFovModifier(self, target, now)
end

function SWEP:TranslateFOV(fov)
    local modifier = self:GetMCSmoothedFovModifier()
    if not modifier then return fov end
    return fov * modifier
end

-- ENTITY 分支：MultiPlayerGameMode.attack = player.attack(target) + resetAttackStrengthTicker()。
function SWEP:MCStartAttackEntity(now, owner, target, trace)
    if SERVER then self:CancelMCMining("combat_target") end
    if SERVER then self:MCPerformAttack(now, target, trace) end
    self:ResetMCAttackStrength(now)
end

function SWEP:MCCanAttackBlockInCurrentGameMode(owner)
    if not MCITEM.Mining or not MCITEM.Mining.PlayerIsCreative
        or not MCITEM.Mining.PlayerIsCreative(owner)
    then
        return true
    end
    return not MCITEM.Mining.CanDestroyBlocksInCreative
        or MCITEM.Mining.CanDestroyBlocksInCreative(self) == true
end

-- BLOCK 分支：startDestroyBlock。**两个 ticker 都不动**（所以挖矿时手一直举着），
-- 真正的破坏进度、裂纹、掉落与工具判定交给 MC.API.Mining。
function SWEP:MCStartAttackBlock(now, owner, hit)
    if not self:MCCanAttackBlockInCurrentGameMode(owner) then
        if SERVER then self:CancelMCMining("creative_item_cannot_destroy") end
        return false
    end
    if SERVER then self:StartMCMining(hit, { initialPress = true }) end
    return true
end

-- MISS 分支：missTime = 10 tick + resetAttackStrengthTicker()。
function SWEP:MCStartAttackMiss(now, owner)
    if SERVER then self:CancelMCMining("miss") end
    self.MCMissUntil = now + MCITEM.MissTimeTicks * MCITEM.TickSeconds
    self:SetNextPrimaryFire(self.MCMissUntil)
    self:ResetMCAttackStrength(now)
end

function SWEP:PrimaryAttack()
    if self:MCInventoryInputBlocked() then return end
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end

    -- 这里是**预测**上下文：不要碰视觉时钟（见 AdvanceMCItem 的注释）。
    -- 状态由渲染路径（客户端）/ Think（服务端）保持新鲜，起挥只要挂请求就行。
    local now = CurTime()

    self:SetNextPrimaryFire(now + MCITEM.TickSeconds)

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    -- Minecraft.handleKeybinds 是 `while (keyAttack.consumeClick())`：**按下才算一次**。
    -- 按住不会连击——按住走的是 continueAttack（下面 Think 里的挖掘循环）。
    -- SWEP.Primary.Automatic 在不同 GMod 分支上表现不一致，所以自己闩一道。
    if self.MCAttackLatched then return end
    if not IsFirstTimePredicted() then return end
    self.MCAttackLatched = true

    -- Minecraft.handleKeybinds 的第一个分支：
    --     if (player.isUsingItem()) { ...consumeClick 全部丢掉... } else { startAttack / startUseItem }
    -- 也就是**正在使用物品时左键整个被吞掉**：拉弓 / 装填弩 / 三叉戟蓄力 / 长矛冲刺
    -- 期间点左键既不攻击也不挖掘。continueAttack 同样有 `|| isUsingItem()` 的早退。
    if self:IsMCUsingItem() then return end

    -- startAttack 开头：missTime > 0 直接 return false。
    if self.MCMissUntil and now < self.MCMissUntil then return end
    if self:MCCannotAttackWithItem(now) then return end

    local target, trace = self:MCResolveAttackTarget(owner)

    if IsValid(target) then
        self:MCStartAttackEntity(now, owner, target, trace)
    else
        local blockHit = self:MCResolveBlockHit(owner)
        if blockHit then
            self:MCStartAttackBlock(now, owner, blockHit)
        else
            self:MCStartAttackMiss(now, owner)
        end
    end

    -- 三条分支出来统一 player.swing(MAIN_HAND)。
    self:MCSwing(now)

    self:PlayMCThirdPersonSwing(now, owner)
end

-- Minecraft.continueAttack(down)：按住左键且准星停在方块上时每 tick 请求一次挥动。
--   · missTime > 0 或 isUsingItem() 直接 return
--   · 带 PIERCING_WEAPON 的物品（长矛）**完全不走这条**
--   · 到底重不重启由 LivingEntity.swing 的 duration/2 门决定，别在这里写死间隔
-- 请求频率故意高于 20Hz（半个 MC tick）：Source 的 66Hz 栅格没法精确落在 MC 的 tick
-- 边界上，请求稀了会错过门刚打开的那一 tick，把 0.2s 的节奏拖成 0.25s。
function SWEP:MCContinueAttack(now, owner)
    if self:MCInventoryInputBlocked(owner) then return end
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    if self.MCNoContinueAttack then return end
    if self.MCMissUntil and now < self.MCMissUntil then return end
    if self:IsMCUsingItem() then return end

    if self.MCNextMineRequestAt and now < self.MCNextMineRequestAt then return end
    self.MCNextMineRequestAt = now + MCITEM.TickSeconds * 0.5

    local hit = self:MCResolveBlockHit(owner)
    if not hit then
        if SERVER then self:CancelMCMining("aim_lost") end
        return
    end

    -- continueDestroyBlock runs every tick even when LivingEntity.swing's
    -- duration/2 gate refuses to restart the visible swing. Starting again on
    -- the same cell is idempotent; moving to another cell cancels/restarts.
    if SERVER then
        if self:MCCanAttackBlockInCurrentGameMode(owner) then
            self:StartMCMining(hit, { initialPress = false })
        else
            self:CancelMCMining("creative_item_cannot_destroy")
        end
    end

    if self:MCSwing(now) then
        self:PlayMCThirdPersonSwing(now, owner)
    end
end

-- Minecraft.startUseItem：一进来就 rightClickDelay = 4，然后按 hitResult 分派。
-- 目前只实现了 useOn(方块) 的三件工具；剑 / 镐右键在原版也没有功能。
-- Minecraft.startUseItem advances to OFF_HAND after the main item passes.
-- The inventory bridge validates ownership; standalone weapons simply pass.
function SWEP:MCTryOffhandUse()
    return MC and MC.TryInventoryOffhandInteraction
        and MC.TryInventoryOffhandInteraction(self) == true or false
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    if self:MCInventoryInputBlocked() then return end

    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)

    if not IsFirstTimePredicted() then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    -- Entity interaction runs before the MCUseAction gate, the same order
    -- mc_item_hand uses. It used to sit after it, so every weapon without a use
    -- action -- mace, bow, wind charge, food -- returned here and right click
    -- never reached MC.UseItemOnEntity at all: no villager trade, no swing.
    if SERVER and MCITEM.TryEntityInteract and MCITEM.TryEntityInteract(owner) then
        self:CancelMCMining("secondary_attack")
        return
    end

    if not self.MCUseAction then self:MCTryOffhandUse() return end
    if SERVER then self:CancelMCMining("secondary_attack") end

    -- InteractionResult.SUCCESS 会 swingHand，PASS 不挥。服务端拿真实结果；客户端
    -- 只能预判，判据是同一张表、同一个 mcid，所以两端结论一致。
    -- ⚠ 服务端必须用 UseToolOnBlock 的返回值：方块已经被改过了，这时候再跑一次预判
    --   会看到新方块（土径不能再压成土径）而误判成 PASS，第三人称就不挥手了。
    local handled
    if SERVER then
        handled = MCITEM.BlockInteract.UseToolOnBlock(owner, self, self.MCUseAction)
    else
        handled = self:MCPredictToolUseHits(owner)
    end

    if handled then
        self:MCSwing(now)
        self:PlayMCThirdPersonSwing(now, owner)
    else
        self:MCTryOffhandUse()
    end
end

-- 两端共用的 useOn 预判（纯查表，不写世界）。
function SWEP:MCPredictToolUseHits(owner)
    if not self.MCUseAction then return false end

    local api = MCITEM.BlockInteract.Api()
    if not api then return false end

    local hit = MCITEM.BlockInteract.AimBlock(owner)
    if not hit then return false end

    local info = api.World.GetBlockInfo(hit.bx, hit.by, hit.bz)
    local normal = hit.HitNormal
    local target = MCITEM.BlockInteract.ResolveToolUse(
        self.MCUseAction,
        MCITEM.BlockInteract.LookupKey(info),
        isvector(normal) and normal.z < -0.5,
        api.World.GetBlockState(hit.bx, hit.by, hit.bz + 1) == 0
    )
    return target ~= nil
end

-- 第三人称只有一个 PLAYER_ATTACK1，没法表达 swingTime，所以用同一条 duration/2
-- 门来节流，至少节奏对得上。
function SWEP:PlayMCThirdPersonSwing(now, owner, requestedGesture)
    if not IsValid(owner) then return end

    local duration = self.MCSwingDurationTicks * MCITEM.TickSeconds
    if self.MCThirdPersonSwingAt and now - self.MCThirdPersonSwingAt < duration * 0.5 then
        return
    end

    self.MCThirdPersonSwingAt = now
    local gesture = requestedGesture or self.MCThirdPersonSwingGesture
        or (MCITEM.ThirdPerson and MCITEM.ThirdPerson.DefaultAttackGesture)
        or "item_attack"
    self:PlayMCGesture(gesture, duration)
end

function SWEP:Think()
    -- 服务端只有一个时钟，从这里推。客户端**不能**在这里推：Think 跑在预测上下文，
    -- 会把 tickAt 顶到渲染时钟前面，partialTick 恒 0 = 动画退化成 20Hz 阶梯。
    if SERVER then self:AdvanceMCItem(CurTime()) end

    -- 第三人称姿势跟着武器状态走（拉弓 / 装填 / 上弦 / 投掷手势）。
    self:UpdateMCHoldType()
    self:SyncMCThirdPersonState()

    local now = CurTime()
    local owner = self:GetOwner()
    local inputBlocked = self:MCInventoryInputBlocked(owner)

    -- consumeClick 的另一半：松开左键才允许下一次 startAttack。
    if IsValid(owner) and (inputBlocked or not owner:KeyDown(IN_ATTACK)) then
        self.MCAttackLatched = false
        -- continueAttack(false) 的第一行就是 missTime = 0。
        self.MCMissUntil = nil
        if SERVER then self:CancelMCMining("released") end
    end

    -- Minecraft.tick 每 tick 调一次 continueAttack(keyAttack.isDown())。
    if IsValid(owner) and not inputBlocked
        and owner:KeyDown(IN_ATTACK) and IsFirstTimePredicted()
    then
        self:MCContinueAttack(now, owner)
    end

    if CLIENT and self.UpdateMCViewModelFOV then
        self:UpdateMCViewModelFOV()
    end
end

if SERVER then
    function SWEP:Holster()
        self:CancelMCMining("holster")
        return true
    end

    function SWEP:OnRemove()
        self:CancelMCMining("weapon_removed")
    end
end
