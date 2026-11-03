-- Player.attack(Entity) 的服务端移植（MC 26.2）。
--
-- 原文顺序（javap 出来的字节码，offset 见注释）：
--   f      = getAttributeValue(ATTACK_DAMAGE)
--   charge = getAttackStrengthScale(0.5)            -- 采样提前半 tick
--   f      = f * baseDamageScaleFactor()            -- 0.2 + charge^2 * 0.8
--   onAttack()                                      -- 清零 attackStrengthTicker
--   strong          = charge > 0.9
--   knockbackAttack = isSprinting() && strong       -- 冲刺击退
--   crit            = strong && canCriticalAttack() -> f *= 1.5
--   sweep           = isSweepAttack(strong, crit, knockbackAttack)
--   hurt -> causeExtraKnockback -> doSweepAttack -> attackVisualEffects
--
-- 没有附魔系统，所以 enchantBonus / getAttackDamageBonus 恒 0，magicCrit 也省了。

local KNOCKBACK_BASE = 0.4 -- LivingEntity.hurt 里的基础击退，单位：格/tick
local SPRINT_KNOCKBACK_BONUS = 0.5 -- causeExtraKnockback 的冲刺加成
local CRIT_MULTIPLIER = 1.5
local SWEEP_BASE_DAMAGE = 1.0 -- 1.0 + SWEEPING_DAMAGE_RATIO * f，没有横扫之刃时比率为 0
local SWEEP_RANGE_BLOCKS = 3 -- distanceToSqr(e) < 9.0

local FX_CRIT = 0
local FX_DAMAGE = 1
local FX_SWEEP = 2

util.AddNetworkString("MCITEM_CombatParticle")

-- DamageForce 是 Source 的力，和 MC 的"格/tick"没有换算关系，只是让 prop /
-- HL2 NPC 有反应。BMB mob 有自己的一套击退（按攻击者方向），不吃这个值。
SWEP.MCKnockbackForceScale = 5

-- 击退缩放（`mcitem_knockback_scale`，默认 0.6）在 sh_use_effects.lua 里，那边写了
-- 为什么不能字面照抄 MC 的速度：Source 重力只有 MC 的一半左右。

-- 非 BMB 的 NPC / NextBot 没有自己的击退实现，只吃 DamageForce（很多 NPC 干脆不理）。
-- 给它们补一份显式击退；BMB 生物**不在此列**——它们在 sv_damage_death 里按
-- DamageInfo 自己起 BMBKnockback，再叠一次会打架。
local function hasOwnKnockback(target)
    return target.IsBMBMob == true
        or target.StartBMBKnockback ~= nil
        or target.BMBKnockbackUntil ~= nil
end

local function getKnockbackResistance(target, context)
    local runtime = MCITEM and MCITEM.EnchantmentRuntime
    if not runtime or not isfunction(runtime.GetKnockbackResistance) then return 0 end
    return math.Clamp(tonumber(runtime.GetKnockbackResistance(target, context)) or 0, 0, 1)
end

-- Breach is scoped to the concrete DamageInfo created by this mace attack.
-- Source can expose a different Lua userdata wrapper for that same native
-- object while EntityTakeDamage is running, so the runtime keeps both the
-- direct object binding and a source fingerprint.  Always unbind in the same
-- call frame; the armor hook must never see a stale "last mace" attack.
local function takeDamageInfoForAttack(self, owner, target, damageInfo, attackContext)
    local runtime = MCITEM and MCITEM.EnchantmentRuntime
    local transaction = runtime and isfunction(runtime.BindMaceDamageTransaction)
        and runtime.BindMaceDamageTransaction(owner, self, target, damageInfo, attackContext)
        or nil
    local ok, accepted, actualDamage = pcall(MCITEM.TakeDamage, target, damageInfo)
    if transaction and runtime and isfunction(runtime.UnbindMaceDamageTransaction) then
        runtime.UnbindMaceDamageTransaction(transaction)
    end
    if not ok then error(accepted, 0) end
    return accepted, actualDamage
end

-- sounds.json 的每个事件都有多条原版变体；共享模块让两端注册同一组 sound script。
-- 原文件是 48 kHz，随 addon 分发的是 44.1 kHz 转码（Source 会静默拒绝 48 kHz OGG）。
local ATTACK_SOUNDS = MCITEM.AttackSoundNames

for _, filename in ipairs({
    "critical_hit.vtf", "damage.vtf",
    "sweep_0.vtf", "sweep_1.vtf", "sweep_2.vtf", "sweep_3.vtf",
    "sweep_4.vtf", "sweep_5.vtf", "sweep_6.vtf", "sweep_7.vtf",
    -- 重锤尘柱在 MineMod 方块上采图集贴图；踩不到方块（Source 地面 / prop）时的兜底。
    "dirt.vtf",
}) do
    resource.AddFile("materials/mcitem/particles/" .. filename)
end

local function playAttackSound(owner, key)
    if not ATTACK_SOUNDS[key] then return end

    -- Player.playServerSideSound：事件音量/音调为 1；每个 wave 自己的
    -- sounds.json volume 由共享音频模块逐条应用。
    MCITEM.PlayAttackSound(owner, key, 1, 100)
end

local function targetParticleBounds(target)
    local mins, maxs = target:WorldSpaceAABB()
    return (mins + maxs) * 0.5, maxs - mins
end

local function sendCritParticles(target)
    local center, size = targetParticleBounds(target)
    net.Start("MCITEM_CombatParticle")
    net.WriteUInt(FX_CRIT, 2)
    net.WriteEntity(target)
    net.WriteVector(center)
    net.WriteVector(size)
    net.SendPVS(center)
end

function MCITEM.SendDamageParticles(target, actualDamage)
    local count = MCITEM.DamageHeartParticleCount(actualDamage)
    if count <= 0 then return end

    local center = targetParticleBounds(target)
    net.Start("MCITEM_CombatParticle")
    net.WriteUInt(FX_DAMAGE, 2)
    net.WriteVector(center)
    net.WriteUInt(count, 10)
    net.SendPVS(center)
end

local function sendSweepParticle(owner, direction)
    local mins, maxs = owner:WorldSpaceAABB()
    local position = Vector(owner:GetPos().x, owner:GetPos().y, (mins.z + maxs.z) * 0.5)
        + direction * MCITEM.BlockSize()

    net.Start("MCITEM_CombatParticle")
    net.WriteUInt(FX_SWEEP, 2)
    net.WriteVector(position)
    net.SendPVS(position)
end

local function isLivingTarget(target)
    return IsValid(target)
        and (target:IsPlayer() or target:IsNPC() or target:IsNextBot() or target.IsBMBMob == true)
end

-- Player.canCriticalAttack(Entity)
local function canCriticalAttack(owner, target)
    if owner:IsOnGround() then return false end
    if owner:GetMoveType() == MOVETYPE_LADDER then return false end -- onClimbable
    if owner:WaterLevel() >= 2 then return false end -- isInWater
    if owner:InVehicle() then return false end -- isPassenger
    if owner:IsSprinting() then return false end
    -- fallDistance > 0：必须是正在往下掉，起跳上升段不算暴击。
    if owner:GetVelocity().z >= 0 then return false end
    return isLivingTarget(target)
end

-- Player.isSweepAttack(strong, crit, knockbackAttack)
function SWEP:MCIsSweepAttack(owner, strong, crit, knockbackAttack)
    if not strong or crit or knockbackAttack then return false end
    if not owner:IsOnGround() then return false end

    -- MC：getKnownMovement().horizontalDistanceSqr() < square(getSpeed() * 2.5)。
    -- getSpeed() 是"每 tick 位移"的移动速度属性，Source 侧对应每秒走路速度。
    local velocity = owner:GetVelocity()
    local horizontal = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    if horizontal >= owner:GetWalkSpeed() * 2.5 then return false end

    return self.MCIsSword == true
end

-- LivingEntity.knockback(strength, x, z)：
--   水平速度先减半，再沿 -(x,z) 推 strength；着地时竖直取 min(0.4, vy/2 + strength)。
-- 玩家和"没有自己击退实现的 NPC"都在这里显式施加；BMB mob 走它自己那套，不重复。
function SWEP:MCApplyMinecraftKnockback(target, direction, strength)
    if strength <= 0 then return end
    if not IsValid(target) then return end

    -- LivingEntity.causeExtraKnockback 同时把攻击者水平速度乘 0.6。普通攻击只命中
    -- 一个目标；PiercingWeapon 沿路径命中多个目标时，原版也会逐个重复乘 0.6。
    local owner = self:GetOwner()
    if IsValid(owner) then
        local ownerVelocity = owner:GetVelocity()
        owner:SetVelocity(Vector(-ownerVelocity.x * 0.4, -ownerVelocity.y * 0.4, 0))
    end

    if hasOwnKnockback(target) then return end

    -- LivingEntity.knockback scales the requested strength by the target's
    -- KNOCKBACK_RESISTANCE attribute before halving existing velocity.  Keep
    -- this separate from BMB's own knockback path (which is excluded above),
    -- and use the shared equipment/provider view for players and integrations.
    local resistance = getKnockbackResistance(target, {
        kind = "melee_knockback",
        attacker = owner,
        weapon = self,
    })
    strength = strength * (1 - resistance)
    if strength <= 0 then return end

    local isPlayer = target:IsPlayer()
    if not isPlayer and not target.SetVelocity then return end

    local scale = MCITEM.KnockbackScale()
    if scale <= 0 then return end

    local blocksPerSecond = MCITEM.BlockSize() * 20 * scale
    local velocity = target:GetVelocity()
    local grounded = target.IsOnGround and target:IsOnGround()

    local horizontal = Vector(direction.x, direction.y, 0)
    if horizontal:LengthSqr() <= 0 then return end
    horizontal:Normalize()

    local result = Vector(
        velocity.x / 2 + horizontal.x * strength * blocksPerSecond,
        velocity.y / 2 + horizontal.y * strength * blocksPerSecond,
        grounded
            and math.min(0.4 * blocksPerSecond, velocity.z / 2 + strength * blocksPerSecond)
            or velocity.z
    )

    if isPlayer then
        -- 玩家的 SetVelocity 是叠加不是设置：先抵消残留，再一次性写入。
        if grounded then target:SetGroundEntity(NULL) end
        target:SetVelocity(-velocity)
        target:SetVelocity(result)
    else
        -- NPC / NextBot：SetVelocity 是设置语义，直接写最终速度。
        if grounded and target.SetGroundEntity then target:SetGroundEntity(NULL) end
        target:SetVelocity(result)
    end
end

function SWEP:MCBuildDamageInfo(owner, damage, position, direction, knockback, target)
    local damageInfo = DamageInfo()
    damageInfo:SetAttacker(owner)
    damageInfo:SetInflictor(self)
    -- ⚠ MC 的一颗心是 2 点、玩家满血 20；GMod 玩家满血 100。伤害倍率
    -- （`mcitem_damage_scale`，默认 5）就是这一层换算，公式本身仍然是 MC 原版的
    -- `ATTACK_DAMAGE * baseDamageScaleFactor()`，只在最后乘一次。
    damageInfo:SetDamage(MCITEM.ScaleDamage(damage))
    damageInfo:SetDamageType(DMG_SLASH)
    damageInfo:SetDamagePosition(position)
    -- Source applies DamageInfo's force while processing TakeDamageInfo, before
    -- the Java-style hurtServer acceptance gate is observable to this Lua
    -- wrapper.  Scale that implicit force with the same KNOCKBACK_RESISTANCE
    -- attribute used by MCApplyMinecraftKnockback; otherwise a fully resistant
    -- target still slides from Source's damage force even though the explicit
    -- Minecraft knockback path correctly returns early.
    local resistance = getKnockbackResistance(target, {
        kind = "melee_damage_force",
        attacker = owner,
        weapon = self,
    })
    local forceKnockback = (tonumber(knockback) or 0) * (1 - resistance)
    damageInfo:SetDamageForce(
        direction * (forceKnockback * MCITEM.BlockSize() * 20
            * (self.MCKnockbackForceScale or 5))
    )
    return damageInfo
end

-- Player.doSweepAttack(target, f, source, charge)
function SWEP:MCDoSweepAttack(owner, mainTarget, attackStrengthScale, directDamage, enchantmentStack)
    playAttackSound(owner, "sweep")

    local blockSize = MCITEM.BlockSize()
    local rangeSqr = (SWEEP_RANGE_BLOCKS * blockSize) ^ 2

    -- AABB.inflate(1.0, 0.25, 1.0)：MC 的 (x,y,z) 是 (水平, 竖直, 水平)，
    -- Source 是 (水平, 水平, 竖直)，别把 0.25 放错轴。
    local mins, maxs = mainTarget:WorldSpaceAABB()
    local inflate = Vector(blockSize, blockSize, blockSize * 0.25)

    -- 横扫朝的是攻击者的朝向（sin(yRot), -cos(yRot)），不是"从被击者往外"。
    local sweepDirection = owner:GetAimVector()
    sweepDirection.z = 0
    if sweepDirection:LengthSqr() > 0 then sweepDirection:Normalize() end

    for _, entity in ipairs(ents.FindInBox(mins - inflate, maxs + inflate)) do
        if entity ~= owner
            and entity ~= mainTarget
            and isLivingTarget(entity)
            and not entity.BMBDead
            and owner:GetPos():DistToSqr(entity:GetPos()) < rangeSqr then

            -- Java 26.2: (1 + sweeping_damage_ratio * direct attack damage
            -- + the side target's enchantment damage bonus) * charge.
            local runtime = MCITEM.EnchantmentRuntime
            local sweepDamage = runtime and isfunction(runtime.GetSweepDamage)
                and runtime.GetSweepDamage(
                    enchantmentStack, entity, directDamage, attackStrengthScale)
                or SWEEP_BASE_DAMAGE * attackStrengthScale
            local accepted, actualDamage = takeDamageInfoForAttack(self, owner, entity, self:MCBuildDamageInfo(
                owner, sweepDamage, entity:WorldSpaceCenter(), sweepDirection,
                KNOCKBACK_BASE, entity
            ), nil)
            -- Java only calls LivingEntity.knockback and post_attack effects
            -- when hurtServer returned true.  TakeDamageInfo has no boolean
            -- result in Source; the shared adapter also observes absorption.
            if accepted then
                self:MCApplyMinecraftKnockback(entity, sweepDirection, KNOCKBACK_BASE)
                if runtime and isfunction(runtime.ApplyDirectPostAttack) then
                    runtime.ApplyDirectPostAttack(
                        enchantmentStack, owner, entity, self, actualDamage, accepted)
                end
            end
        end
    end

    sendSweepParticle(owner, sweepDirection)
end

function SWEP:MCPerformAttack(now, target, trace)
    local owner = self:GetOwner()
    if not IsValid(owner) or not IsValid(target) then return end
    local livingTarget = isLivingTarget(target)

    -- 蓄力必须在清零 ticker **之前**取（shared.lua 保证了调用顺序）。
    local charge = self:GetMCAttackStrengthScale(now, 0.5)
    -- Strength/Weakness modify ATTACK_DAMAGE before Player.attack applies its
    -- charge curve and critical multiplier.  Keeping this here avoids the
    -- common but incorrect "add the potion bonus to final DamageInfo" order.
    local attackDamage = self.MCAttackDamage
    if MCITEM.Potions and isfunction(MCITEM.Potions.GetAttackDamageBonus) then
        attackDamage = math.max(0, attackDamage + MCITEM.Potions.GetAttackDamageBonus(owner))
    end
    local chargedDamage = attackDamage * MCITEM.BaseDamageScaleFactor(charge)

    local strong = charge > 0.9
    local knockbackAttack = strong and owner:IsSprinting()
    if knockbackAttack then playAttackSound(owner, "knockback") end

    local attackContext
    local itemBonus = 0
    if self.MCGetAttackDamageBonus then
        itemBonus, attackContext = self:MCGetAttackDamageBonus(
            owner, target, chargedDamage, charge)
        itemBonus = tonumber(itemBonus) or 0
    end

    local crit = strong and canCriticalAttack(owner, target)
    local directDamage = chargedDamage + itemBonus
    if crit then directDamage = directDamage * CRIT_MULTIPLIER end

    -- Damage enchantments are evaluated after the charged/critical direct
    -- attack damage.  Keeping this term separate prevents critical hits from
    -- incorrectly multiplying Sharpness/Smite/Bane/Impaling.
    local runtime = MCITEM.EnchantmentRuntime
    local enchantmentStack = runtime and isfunction(runtime.StackForWeapon)
        and runtime.StackForWeapon(self, owner) or nil
    -- Player.attack computes this as
    -- `attackStrengthScale * (getEnchantedDamage - baseDamage)` and adds it
    -- after the critical multiplier.  Keeping the multiplier here is
    -- important for partially charged hits: Sharpness/Smite/Bane must not
    -- become a full-strength flat bonus while the direct attack is cooling.
    local enchantmentBonus = runtime and isfunction(runtime.GetMeleeDamageBonus)
        and runtime.GetMeleeDamageBonus(enchantmentStack, target) * math.Clamp(charge, 0, 1)
        or 0
    local damage = directDamage + enchantmentBonus

    local sweep = self:MCIsSweepAttack(owner, strong, crit, knockbackAttack)

    local direction = owner:GetAimVector()
    direction.z = 0
    if direction:LengthSqr() <= 0 then direction = owner:GetForward() end
    direction:Normalize()

    local knockback = KNOCKBACK_BASE
        + (self.MCAttackKnockback or 0)
        + (runtime and isfunction(runtime.GetKnockbackBonus)
            and runtime.GetKnockbackBonus(enchantmentStack) or 0)
        + (knockbackAttack and SPRINT_KNOCKBACK_BONUS or 0)

    local hitPosition = (trace and trace.HitPos) or target:WorldSpaceCenter()

    local accepted, actualDamage = takeDamageInfoForAttack(self, owner, target, self:MCBuildDamageInfo(
        owner, damage, hitPosition, direction, knockback, target), attackContext)
    if accepted then
        self:MCApplyMinecraftKnockback(target, direction, knockback)
    end

    if sweep and accepted then
        self:MCDoSweepAttack(owner, target, charge, directDamage, enchantmentStack)
    end

    if runtime and isfunction(runtime.ApplyDirectPostAttack) then
        runtime.ApplyDirectPostAttack(
            enchantmentStack, owner, target, self, actualDamage, accepted)
    end

    -- Damage acceptance includes absorption; health delta is only a statistic.
    if accepted and crit then
        playAttackSound(owner, "crit")
        if IsValid(target) then sendCritParticles(target) end
    elseif accepted and not sweep then
        playAttackSound(owner, strong and "strong" or "weak")
    end

    if accepted and self.MCPostAttack then
        self:MCPostAttack(owner, target, attackContext, actualDamage, accepted)
    end

    -- Player.damageStatsAndHearts runs after attackVisualEffects. Source 实际扣血已经乘过
    -- mcitem_damage_scale；SendDamageParticles 会先反算回 MC 刻度，再执行原版阈值/数量。
    if IsValid(target) then MCITEM.SendDamageParticles(target, actualDamage) end

    -- Player.itemAttackInteraction -> ItemStack.hurtEnemy -> postHurtEnemy：只有攻击被
    -- 接受、目标是 LivingEntity 且物品带 WEAPON 组件时，才按 itemDamagePerAttack
    -- 消耗耐久。横扫的旁目标不额外扣；挥空/无敌帧吃掉的 0 实伤也不扣。
    local durability = math.max(0, math.floor(tonumber(self.MCWeaponDamagePerAttack) or 0))
    if accepted and durability > 0 and livingTarget then
        self:ApplyMCAttackDurabilityDamage(durability, {
            reason = "attack",
            target = target,
            actualDamage = actualDamage,
        })
    end
end
