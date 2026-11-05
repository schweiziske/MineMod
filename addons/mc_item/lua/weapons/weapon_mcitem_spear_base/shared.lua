AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Spear Base"
SWEP.Category = "#mcitem.category.items"
SWEP.Instructions = "Left click: fully charged piercing stab. Hold right click: kinetic spear attack."
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.HoldType = "melee2"
-- 第三人称：静止手臂下垂（`mcitem_holdtype_spear`），右键冲刺和左键突刺都套
-- 半条命弩那一套（`mcitem_holdtype_spear_use`），突刺时再补一次开火手势。
SWEP.MCHoldTypeName = "spear"
SWEP.MCThirdPersonProfile = "spear"
-- Java 26.2's in-hand spear sprites are the item atlas's seven 32x32 entries.
SWEP.MCGlintProfile = "item_32"

-- 逐武器手感微调 convar：mcitem_fp_spear_* / mcitem_use_spear_* / mcitem_swing_spear_*。
-- 七种材质的矛共用一组（几何完全一样，只有贴图不同）。
SWEP.MCAnchorName = "spear"

SWEP.MCSwingType = MCITEM.SwingAnimationType.STAB
SWEP.MCIsSword = false
SWEP.MCAttackKnockback = 0

-- DataComponents.MINIMUM_ATTACK_CHARGE = 1.0f（Item.Properties.spear）。
-- Player.cannotAttackWithItem 没满就让整个 startAttack 提前返回。
SWEP.MCMinimumAttackCharge = 1

-- Minecraft.continueAttack：`if (heldItem.has(DataComponents.PIERCING_WEAPON)) return;`
-- 带穿刺组件的物品**永远不挖方块**，按住左键也只有起手那一下。
SWEP.MCNoContinueAttack = true

-- Item.Properties.spear 装的是 UseEffects(canSprint=true, interactVibrations=false,
-- speedMultiplier=1.0f)：右键冲刺攻击靠冲刺速度吃伤害档位，绝不能按默认 0.2 减速。
SWEP.MCUseSpeedMultiplier = 1
SWEP.MCUseCanSprint = true

SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = true,
    Ammo = "none",
}

-- Item.Properties.spear installs AttackRange(2, 4.5, 2, 6.5, 0.125, 0.5).
-- Survival players use the first pair; creative reach is intentionally not emulated yet.
local MIN_REACH_BLOCKS = 2
local MAX_REACH_BLOCKS = 4.5
local HITBOX_MARGIN_BLOCKS = 0.125
-- KineticWeapon(10, ...) 的第一个参数就是 contactCooldownTicks。
local CONTACT_COOLDOWN_TICKS = 10

local function mcSpeedAlong(entity, direction)
    if not IsValid(entity) then return 0 end
    -- Physical velocity in Source units/s, converted once to blocks/s. Fast
    -- falls, mounts and external impulses must remain above the action gates.
    return entity:GetVelocity():Dot(direction) / MCITEM.BlockSize()
end

local SPEAR_DISPLAY = {
    -- assets/minecraft/models/item/spear_in_hand.json, firstperson_righthand.
    translation = { 3.13, 2.0, 0.13 },
    rotation = { -20, 90, -35 },
    scale = { 1.36, 1.36, 0.68 },
}

local function rootBase()
    return weapons.GetStored("weapon_bmb_item_model_test")
end

local function callRootBase(self, method, ...)
    local base = rootBase()
    local fn = base and base[method]
    if not fn then return nil end
    return fn(self, ...)
end

local function useClock()
    return CLIENT and SysTime() or CurTime()
end

local function isSpearTarget(owner, target)
    if not IsValid(target) or target == owner or target == game.GetWorld() then return false end
    if target.BMBDead then return false end
    if target:IsPlayer() and not target:Alive() then return false end
    if target.Health and target:Health() <= 0 then return false end
    return target:IsPlayer() or target:IsNPC() or target:IsNextBot() or target.IsBMBMob == true
end

local function segmentAABB(startPosition, endPosition, mins, maxs)
    local delta = endPosition - startPosition
    local tMin = 0
    local tMax = 1

    local function clipAxis(origin, movement, minimum, maximum)
        if math.abs(movement) < 1e-8 then
            return origin >= minimum and origin <= maximum
        end

        local inverse = 1 / movement
        local first = (minimum - origin) * inverse
        local second = (maximum - origin) * inverse
        if first > second then first, second = second, first end

        tMin = math.max(tMin, first)
        tMax = math.min(tMax, second)
        return tMin <= tMax
    end

    if not clipAxis(startPosition.x, delta.x, mins.x, maxs.x) then return nil end
    if not clipAxis(startPosition.y, delta.y, mins.y, maxs.y) then return nil end
    if not clipAxis(startPosition.z, delta.z, mins.z, maxs.z) then return nil end
    return tMin, startPosition + delta * tMin
end

function SWEP:GetMCFirstPersonDisplay()
    return SPEAR_DISPLAY
end

-- ProjectileUtil.getHitEntitiesAlong：从最短触及距离开始，沿视线收集全部实体；
-- 最大距离会额外加上玩家朝视线方向的单 tick 位移，并在第一个实体外的实体/世界
-- 碰撞处截断。返回顺序按射线命中距离排列。
function SWEP:MCFindSpearTargets(owner)
    if not IsValid(owner) then return {} end

    local blockSize = MCITEM.BlockSize()
    local origin = owner:GetShootPos()
    local direction = owner:GetAimVector()
    if direction:LengthSqr() <= 1e-8 then return {} end
    direction:Normalize()

    local forwardBlocksPerTick = owner:GetVelocity():Dot(direction) / blockSize / 20
    local maxReach = MAX_REACH_BLOCKS + math.max(forwardBlocksPerTick, 0)
    local intendedEnd = origin + direction * (maxReach * blockSize)

    local obstruction = util.TraceLine({
        start = origin,
        endpos = intendedEnd,
        filter = function(entity)
            if entity == owner or isSpearTarget(owner, entity) then return false end
            return true
        end,
        mask = MASK_SHOT,
    })

    local rayEnd = obstruction.Hit and obstruction.HitPos or intendedEnd
    local minimumDistance = MIN_REACH_BLOCKS * blockSize
    if origin:DistToSqr(rayEnd) < minimumDistance * minimumDistance then return {} end

    local rayStart = origin + direction * minimumDistance
    local margin = HITBOX_MARGIN_BLOCKS * blockSize
    local expansion = Vector(margin, margin, margin)
    local searchMins = Vector(
        math.min(rayStart.x, rayEnd.x),
        math.min(rayStart.y, rayEnd.y),
        math.min(rayStart.z, rayEnd.z)
    ) - expansion
    local searchMaxs = Vector(
        math.max(rayStart.x, rayEnd.x),
        math.max(rayStart.y, rayEnd.y),
        math.max(rayStart.z, rayEnd.z)
    ) + expansion

    local hits = {}
    for _, target in ipairs(ents.FindInBox(searchMins, searchMaxs)) do
        if isSpearTarget(owner, target) then
            local mins, maxs = target:WorldSpaceAABB()
            local fraction, position = segmentAABB(rayStart, rayEnd, mins - expansion, maxs + expansion)
            if fraction then
                hits[#hits + 1] = {
                    entity = target,
                    fraction = fraction,
                    HitPos = position,
                }
            end
        end
    end

    table.sort(hits, function(first, second)
        return first.fraction < second.fraction
    end)
    return hits
end

function SWEP:MCResolveAttackTarget(owner)
    local hits = self:MCFindSpearTargets(owner)
    local first = hits[1]
    if not first then return nil, nil end
    return first.entity, first
end

function SWEP:Initialize()
    callRootBase(self, "Initialize")
    self.MCSpearUsing = false
    self.MCSpearUseStartedAt = nil
    self.MCSpearLastUseTick = -1
    self.MCSpearContacts = setmetatable({}, { __mode = "k" })
    if SERVER then
        self:SetNW2Int("MCITEM_SpearHitFeedback", 0)
        self:SetMCThirdPersonUseState(false)
    end
end

function SWEP:Deploy()
    local result = callRootBase(self, "Deploy")
    self:MCEndSpearUse()
    self.MCSpearFeedbackSequence = nil
    self.MCSpearFeedbackAt = nil
    return result ~= false
end

function SWEP:GetMCSpearUseTicks()
    if not self.MCSpearUsing or not self.MCSpearUseStartedAt then return 0 end
    return math.max((useClock() - self.MCSpearUseStartedAt) / MCITEM.TickSeconds, 0)
end

function SWEP:MCEndSpearUse()
    self.MCSpearUsing = false
    self.MCSpearUseStartedAt = nil
    self.MCSpearLastUseTick = -1
    -- ⚠ 不清 MCSpearContacts：MC 的 recentKineticEnemies 挂在 LivingEntity 上、按绝对
    -- 游戏时间比较，松手再按不会重置接触冷却。清掉等于把冷却送人。
    self.MCSpearLastFeedbackTick = nil
    if SERVER then self:SetMCThirdPersonUseState(false) end
end

function SWEP:MCPlaySpearSound(owner, action)
    if not IsValid(owner) then return end
    local soundKey = (self.MCSpearWood and "spear_wood_" or "spear_") .. action
    MCITEM.PlayRangedSound(owner, soundKey, 1, 100)
end

-- Minecraft.startAttack 在 switch **之前**就分流了：
--   `PiercingWeapon piercingWeapon = heldItem.get(DataComponents.PIERCING_WEAPON);
--    if (piercingWeapon != null) { gameMode.piercingAttack(...); player.swing(); return true; }`
-- 所以长矛的左键不看准星命中的是实体、方块还是空气，一律是穿刺攻击，也不挖方块。
function SWEP:PrimaryAttack()
    local now = CurTime()
    self:SetNextPrimaryFire(now + MCITEM.TickSeconds)

    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    if self.MCAttackLatched or not IsFirstTimePredicted() then return end
    self.MCAttackLatched = true

    -- Player.cannotAttackWithItem：MINIMUM_ATTACK_CHARGE = 1.0，没满蓄力时点击会被
    -- 吃掉，但既不挥动也不清 ticker。
    if self:MCCannotAttackWithItem(now) then return end

    self:MCSwing(now)
    self:ResetMCOnlyAttackStrength(now)
    -- 左键突刺的第三人称也走 HL2 弩的开火动作。
    self:PlayMCGesture("spear_attack")

    if SERVER then
        self:MCPerformSpearPiercingAttack(owner)
    end
end

function SWEP:IsMCUsingItem()
    return self.MCSpearUsing == true
end

function SWEP:GetMCHoldTypeKey()
    return (self.MCSpearUsing or self:IsMCThirdPersonUsing()) and "spear_use" or "spear"
end

function SWEP:GetMCThirdPersonBaseState()
    return (self.MCSpearUsing or self:IsMCThirdPersonUsing()) and "use" or "idle"
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + MCITEM.TickSeconds)
    if self.MCSpearUsing or not IsFirstTimePredicted() then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    if SERVER then self:CancelMCMining("secondary_attack") end

    self.MCSpearUsing = true
    self.MCSpearUseStartedAt = useClock()
    if SERVER then self:SetMCThirdPersonUseState(true, self.MCSpearUseStartedAt) end
    self.MCSpearLastUseTick = -1
    -- 同 MCEndSpearUse：接触冷却跨使用保留，这里也不能重置。
    self.MCSpearLastFeedbackTick = nil

    if SERVER then self:MCPlaySpearSound(owner, "use") end
end

function SWEP:MCPerformSpearPiercingAttack(owner)
    local hits = self:MCFindSpearTargets(owner)
    local breakRevision = self.MCInventoryBreakRevision
    local hitSomething = false
    local damage = self.MCAttackDamage or MCITEM.PlayerBaseAttackDamage
    if MCITEM.Potions then
        damage = math.max(0, damage + MCITEM.Potions.GetAttackDamageBonus(owner))
    end

    for _, hit in ipairs(hits) do
        if not IsValid(self) or owner:GetActiveWeapon() ~= self
            or self.MCInventoryBreakRevision ~= breakRevision then break end
        if self:MCApplySpearHit(
            owner,
            hit.entity,
            damage,
            true,
            true,
            false,
            hit.HitPos
        ) then
            hitSomething = true
        end
    end

    if not IsValid(self) then return end
    if hitSomething then self:MCPlaySpearSound(owner, "hit") end
    self:MCPlaySpearSound(owner, "attack")
    if self.MCInventoryBreakRevision ~= breakRevision or owner:GetActiveWeapon() ~= self then return end

    local runtime = MCITEM.EnchantmentRuntime
    if runtime and isfunction(runtime.StackForWeapon)
        and isfunction(runtime.ApplySpearLunge) then
        runtime.ApplySpearLunge(owner, self, runtime.StackForWeapon(self, owner))
    end
end

-- 击退统一由 base 的 MCApplyMinecraftKnockback 负责（它已经区分玩家 / 普通 NPC /
-- 自带击退的 BMB 生物）。这里以前额外补一份"没造成伤害时的直接击退"，现在会重复施加。
function SWEP:MCApplySpearHit(owner, target, damage, dealsDamage, dealsKnockback, dismounts, hitPosition)
    if not IsValid(owner) or not isSpearTarget(owner, target) then return false, 0 end

    local direction = owner:GetAimVector()
    direction.z = 0
    if direction:LengthSqr() <= 1e-8 then direction = owner:GetForward() end
    direction:Normalize()

    local accepted, actualDamage = false, 0
    local runtime = MCITEM.EnchantmentRuntime
    local enchantmentStack = runtime and isfunction(runtime.StackForWeapon)
        and runtime.StackForWeapon(self, owner) or nil
    if dealsDamage then
        if runtime and isfunction(runtime.GetMeleeDamageBonus) then
            damage = math.max(0, tonumber(damage) or 0)
                + runtime.GetMeleeDamageBonus(enchantmentStack, target)
        end
        accepted, actualDamage = MCITEM.TakeDamage(target, self:MCBuildDamageInfo(
            owner,
            damage,
            hitPosition or target:WorldSpaceCenter(),
            direction,
            dealsKnockback and 0.4 or 0,
            target
        ))
    end

    -- Player.stabAttack applies its requested knockback independently of
    -- wasHurt; post-attack enchantments still require accepted damage.
    if IsValid(target) and dealsKnockback then
        self:MCApplyMinecraftKnockback(target, direction, 0.4)
    end

    local dismounted = false
    if IsValid(target) and dismounts and target:IsPlayer() and target.InVehicle and target:InVehicle() then
        target:ExitVehicle()
        dismounted = true
    end

    if actualDamage > 0 and IsValid(target) and MCITEM.SendDamageParticles then
        MCITEM.SendDamageParticles(target, actualDamage)
    end

    if dealsDamage and runtime and isfunction(runtime.ApplyDirectPostAttack) then
        runtime.ApplyDirectPostAttack(
            enchantmentStack, owner, target, self, actualDamage, accepted)
    end

    local interacted = dealsKnockback or accepted or dismounted
    if interacted then
        self:ApplyMCAttackDurabilityDamage(self.MCWeaponDamagePerAttack or 1, {
            reason = "attack", target = target, actualDamage = actualDamage,
        })
    end
    return interacted, actualDamage
end

function SWEP:MCSignalSpearHitFeedback(useTick, owner)
    if self.MCSpearLastFeedbackTick
        and useTick - self.MCSpearLastFeedbackTick <= CONTACT_COOLDOWN_TICKS then
        return
    end

    self.MCSpearLastFeedbackTick = useTick
    self:SetNW2Int(
        "MCITEM_SpearHitFeedback",
        self:GetNW2Int("MCITEM_SpearHitFeedback", 0) + 1
    )
    self:MCPlaySpearSound(owner, "hit")
end

function SWEP:MCProcessSpearKineticTick(owner, useTick)
    local breakRevision = self.MCInventoryBreakRevision
    local delayTicks = self.MCSpearDelayTicks or 0
    if useTick < delayTicks then return end

    local ticksUsed = useTick - delayTicks
    local direction = owner:GetAimVector()
    if direction:LengthSqr() <= 1e-8 then return end
    direction:Normalize()

    -- KineticWeapon.getMotion = getKnownSpeed() * 20（格/秒）。
    local attackerSpeed = mcSpeedAlong(owner, direction)
    local hitSomething = false

    -- LivingEntity.wasRecentlyStabbed 比的是 **level.getGameTime()**：接触冷却记在
    -- 玩家身上、按绝对游戏时间算，**不随一次使用的开始/结束重置**。
    -- 早先按"本次使用内的 tick 序号"记、并在 MCEndSpearUse 里清空，于是松开右键再按、
    -- 或者 W/S 来回蹭，都能绕过 10 tick 冷却反复满伤命中。
    local now = CurTime()
    local cooldownSeconds = CONTACT_COOLDOWN_TICKS * MCITEM.TickSeconds

    for _, hit in ipairs(self:MCFindSpearTargets(owner)) do
        if not IsValid(self) or owner:GetActiveWeapon() ~= self
            or self.MCInventoryBreakRevision ~= breakRevision then break end
        local target = hit.entity
        local lastContact = self.MCSpearContacts[target]
        if lastContact == nil or now - lastContact >= cooldownSeconds then
            -- 原版先 rememberStabbedEntity，再看三条 condition；速度不够也会进入
            -- 10 tick 接触冷却。
            self.MCSpearContacts[target] = now

            local targetSpeed = mcSpeedAlong(target, direction)
            local relativeSpeed = math.max(0, attackerSpeed - targetSpeed)
            local dismounts = ticksUsed <= (self.MCSpearDismountDurationTicks or 0)
                and attackerSpeed >= (self.MCSpearDismountThreshold or math.huge)
            local dealsKnockback = ticksUsed <= (self.MCSpearKnockbackDurationTicks or 0)
                and attackerSpeed >= (self.MCSpearKnockbackThreshold or math.huge)
            local dealsDamage = ticksUsed <= (self.MCSpearDamageDurationTicks or 0)
                and relativeSpeed >= (self.MCSpearDamageThreshold or math.huge)

            if dismounts or dealsKnockback or dealsDamage then
                -- KineticWeapon 用 Attributes.ATTACK_DAMAGE 的 base value（玩家为 1），
                -- 而不是手中材质加成后的总攻击力。
                local damage = MCITEM.PlayerBaseAttackDamage
                    + math.floor(relativeSpeed * (self.MCSpearDamageMultiplier or 1))
                if self:MCApplySpearHit(
                    owner,
                    target,
                    damage,
                    dealsDamage,
                    dealsKnockback,
                    dismounts,
                    hit.HitPos
                ) then
                    hitSomething = true
                end
            end
        end
    end

    if hitSomething and IsValid(self) then self:MCSignalSpearHitFeedback(useTick, owner) end
    if IsValid(self) and self.MCInventoryBreakRevision ~= breakRevision then self:MCEndSpearUse() end
end

function SWEP:Think()
    callRootBase(self, "Think")

    local owner = self:GetOwner()
    if not self.MCSpearUsing then return end

    if not IsValid(owner) or not owner:KeyDown(IN_ATTACK2) then
        self:MCEndSpearUse()
        return
    end

    if SERVER then
        local currentTick = math.floor(self:GetMCSpearUseTicks() + 1e-6)
        local lastTick = self.MCSpearLastUseTick or -1
        for useTick = lastTick + 1, currentTick do
            self:MCProcessSpearKineticTick(owner, useTick)
            if not IsValid(self) or owner:GetActiveWeapon() ~= self or not self.MCSpearUsing then return end
        end
        self.MCSpearLastUseTick = currentTick
    end
end

function SWEP:GetMCSpearHitFeedbackTicks()
    if not CLIENT then return 1000 end

    local sequence = self:GetNW2Int("MCITEM_SpearHitFeedback", 0)
    if sequence ~= (self.MCSpearFeedbackSequence or 0) then
        self.MCSpearFeedbackSequence = sequence
        self.MCSpearFeedbackAt = SysTime()
    end
    if not self.MCSpearFeedbackAt then return 1000 end
    return math.max((SysTime() - self.MCSpearFeedbackAt) / MCITEM.TickSeconds, 0)
end

function SWEP:GetMCUseRenderState()
    if not self.MCSpearUsing then return nil end
    return "spear", self:GetMCSpearUseTicks(), nil, {
        delayTicks = self.MCSpearDelayTicks,
        dismountDurationTicks = self.MCSpearDismountDurationTicks,
        knockbackDurationTicks = self.MCSpearKnockbackDurationTicks,
        damageDurationTicks = self.MCSpearDamageDurationTicks,
        hitFeedbackTicks = self:GetMCSpearHitFeedbackTicks(),
    }
end
