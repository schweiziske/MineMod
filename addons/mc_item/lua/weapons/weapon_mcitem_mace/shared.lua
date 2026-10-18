AddCSLuaFile()
AddCSLuaFile("mcitem/sh_item_state.lua")
AddCSLuaFile("mcitem/sh_ranged.lua")

include("mcitem/sh_item_state.lua")
include("mcitem/sh_ranged.lua")

if SERVER then util.AddNetworkString("MCITEM_MaceSmashParticle") end

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Mace"
SWEP.Category = "Minecraft in GMod - Items"
SWEP.Instructions = "Primary: attack. Falling more than 1.5 blocks performs a smash attack."
SWEP.Spawnable = true
SWEP.AdminOnly = false
SWEP.WorldModel = "models/mcgm/mace/mace.mdl"
SWEP.MCItemID = "mace"
SWEP.HoldType = "melee"
-- 第三人称：`mcitem_holdtype_mace`（默认 melee2 的双手重武器）。
SWEP.MCHoldTypeName = "mace"
SWEP.MCThirdPersonProfile = "mace"

-- MaceItem.createAttributes: player base 1 + item modifier 5 = 6 damage;
-- player base 4 + item modifier -3.4 = 0.6 attack speed.
SWEP.MCAttackDamage = 6
SWEP.MCAttackSpeed = 0.6
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 1

function SWEP:GetMCFirstPersonDisplay()
    -- assets/minecraft/models/item/handheld_mace.json, firstperson_righthand.
    return {
        translation = { 0, 3, 0.8 },
        rotation = { 0, -90, 25 },
        scale = { 0.9, 0.9, 0.9 },
    }
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    self.MCFallDistance = 0
    self.MCLastFallZ = nil
    return result
end

function SWEP:Think()
    self.BaseClass.Think(self)
    if not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    local z = owner:GetPos().z
    if owner:IsOnGround() then
        self.MCFallDistance = 0
    elseif self.MCLastFallZ and z < self.MCLastFallZ then
        self.MCFallDistance = (self.MCFallDistance or 0)
            + (self.MCLastFallZ - z) / MCITEM.BlockSize()
    end
    self.MCLastFallZ = z
end

function SWEP:MCGetAttackDamageBonus()
    local fallDistance = self.MCFallDistance or 0
    if fallDistance <= 1.5 then return 0, nil end

    local bonus
    if fallDistance <= 3 then
        bonus = 4 * fallDistance
    elseif fallDistance <= 8 then
        bonus = 12 + 2 * (fallDistance - 3)
    else
        bonus = 22 + fallDistance - 8
    end

    return bonus, { fallDistance = fallDistance }
end

local function isLiving(entity)
    return IsValid(entity)
        and (entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true)
end

local function isSpectator(entity)
    if not entity:IsPlayer() then return false end
    if isfunction(entity.IsObserver) and entity:IsObserver() then return true end
    return isfunction(entity.GetObserverMode)
        and (tonumber(entity:GetObserverMode()) or 0) ~= 0
end

local function isCreativeFlying(entity)
    if not entity:IsPlayer() then return false end
    local creative = MC and MC.SV and isfunction(MC.SV.PlayerIsCreative)
        and MC.SV.PlayerIsCreative(entity) == true
    if not creative and MC and isfunction(MC.PlayerIsCreative) then
        creative = MC.PlayerIsCreative(entity) == true
    end
    if not creative then return false end
    local moveType = isfunction(entity.GetMoveType) and entity:GetMoveType() or nil
    return moveType == MOVETYPE_FLY
        or moveType == MOVETYPE_FLYGRAVITY
        or moveType == MOVETYPE_NOCLIP
end

local function isAlliedToAttacker(owner, entity)
    local overridden = hook.Run("MCITEM.MaceSmashAllied", owner, entity)
    if overridden ~= nil then return overridden == true end
    return isfunction(owner.IsAlliedTo) and owner:IsAlliedTo(entity) == true
end

local function isTamedByTarget(entity, target)
    if isfunction(entity.IsBMBTamed) and entity:IsBMBTamed()
        and isfunction(entity.GetBMBPetOwner) then
        return entity:GetBMBPetOwner() == target
    end
    if isfunction(entity.IsTamed) and entity:IsTamed()
        and isfunction(entity.GetOwner) then
        return entity:GetOwner() == target
    end
    return false
end

local function isMarkerArmorStand(entity)
    local overridden = hook.Run("MCITEM.IsMarkerArmorStand", entity)
    if overridden ~= nil then return overridden == true end
    if isfunction(entity.IsMCArmorStandMarker) then
        return entity:IsMCArmorStandMarker() == true
    end
    return entity.MCArmorStandMarker == true
        or entity.BMBArmorStandMarker == true
end

local function maceKnockbackResistance(entity, context)
    local value
    if isfunction(entity.GetMCKnockbackResistance) then
        value = entity:GetMCKnockbackResistance(context)
    end
    if value == nil then value = hook.Run("MCITEM.GetKnockbackResistance", entity, context) end
    if value == nil then value = entity.KnockbackResistance end
    return math.Clamp(tonumber(value) or 0, 0, 1)
end

local function canReceiveMaceSmash(owner, target, entity)
    if entity == owner or entity == target or not isLiving(entity) or entity.BMBDead then return false end
    if isSpectator(entity) or isCreativeFlying(entity) or isAlliedToAttacker(owner, entity)
        or isTamedByTarget(entity, target) or isMarkerArmorStand(entity) then return false end
    local overridden = hook.Run("MCITEM.CanMaceSmashKnockback", owner, target, entity)
    return overridden ~= false
end

local function applyMaceSmashImpulse(entity, impulse, context)
    if impulse:LengthSqr() <= 0 then return false end
    if isfunction(entity.StartBMBExternalImpulse)
        and entity:StartBMBExternalImpulse(impulse, {
            reason = "mace_smash",
            duration = 0.18,
        }) then
        return true
    end
    if entity:IsPlayer() and isfunction(entity.SetVelocity) then
        if impulse.z > 0 and isfunction(entity.SetGroundEntity) then entity:SetGroundEntity(NULL) end
        entity:SetVelocity(impulse)
        return true
    end
    local current = isfunction(entity.GetVelocity) and entity:GetVelocity() or vector_origin
    if entity:IsNextBot() and entity.loco and isfunction(entity.loco.SetVelocity) then
        if impulse.z > 0 and isfunction(entity.loco.Jump)
            and (not isfunction(entity.loco.IsOnGround) or entity.loco:IsOnGround()) then
            entity.loco:Jump()
        end
        entity.loco:SetVelocity(current + impulse)
        local horizontal = Vector(impulse.x, impulse.y, 0)
        if isfunction(entity.loco.Approach) and horizontal:LengthSqr() > 1 then
            entity.loco:Approach(entity:GetPos() + horizontal, math.max(horizontal:Length(), 1))
        end
        return true
    end
    if entity:IsNPC() and isfunction(entity.SetLocalVelocity) then
        if impulse.z > 0 and isfunction(entity.SetGroundEntity) then entity:SetGroundEntity(NULL) end
        entity:SetLocalVelocity(current + impulse)
        return true
    end
    if isfunction(entity.SetVelocity) then
        entity:SetVelocity(current + impulse)
        return true
    end
    return false
end

function SWEP:MCPostAttack(owner, target, context)
    if not context or not IsValid(owner) or not IsValid(target) then return end

    local fallDistance = context.fallDistance
    local heavy = fallDistance > 5
    local targetOnGround = target.IsOnGround and target:IsOnGround()
    local soundKey = targetOnGround
        and (heavy and "mace_smash_ground_heavy" or "mace_smash_ground")
        or "mace_smash_air"
    MCITEM.PlayRangedSound(owner, soundKey, 1, 100)

    -- MaceItem.knockback -> levelEvent(2013, target.getOnPos(), 750).
    local mins = target:WorldSpaceAABB()
    local particlePosition = Vector(target:GetPos().x, target:GetPos().y, mins.z)
    net.Start("MCITEM_MaceSmashParticle")
    net.WriteVector(particlePosition)
    net.SendPVS(particlePosition)

    -- MaceItem.knockback(level, attacker, entity)：
    --   level.levelEvent(2013, entity.getOnPos(), 750)                    ← 尘柱
    --   getEntitiesOfClass(LivingEntity, entity.getBoundingBox().inflate(3.5), predicate)
    --       direction      = nearby.position() - entity.position()        （**不归一化**再取长度）
    --       knockbackPower = (3.5 - direction.length()) * 0.7 * (attacker.fallDistance > 5 ? 2 : 1)
    --                        * (1 - nearby.KNOCKBACK_RESISTANCE)
    --       if (power > 0) nearby.push(dir.normalize().scale(power).x, 0.7f, ...z)
    -- push() 是**加到现有速度上**，不是覆盖；竖直恒定 0.7 格/tick。
    -- predicate 排除：观察者 / 攻击者本人 / 被砸的目标 / 盟友 / 目标驯服的宠物 /
    -- 标记盔甲架 / 距离平方 > 3.5² / 创造飞行的玩家。
    local blockSize = MCITEM.BlockSize()
    local radius = 3.5 * blockSize
    local center = target:GetPos()
    local scale = MCITEM.KnockbackScale and MCITEM.KnockbackScale() or 1

    for _, nearby in ipairs(ents.FindInSphere(center, radius)) do
        if canReceiveMaceSmash(owner, target, nearby) then
            local offset = nearby:GetPos() - center
            local distanceBlocks = offset:Length() / blockSize
            local knockbackContext = {
                kind = "mace_smash",
                attacker = owner,
                target = target,
                affected = nearby,
                fallDistance = fallDistance,
                distance = distanceBlocks,
            }
            local resistance = maceKnockbackResistance(nearby, knockbackContext)
            local power = math.max(3.5 - distanceBlocks, 0) * 0.7
                * (heavy and 2 or 1) * (1 - resistance)

            if power > 0 and offset:LengthSqr() > 1e-7 then
                offset:Normalize()
                local push = Vector(
                    offset.x * power * blockSize * 20 * scale,
                    offset.y * power * blockSize * 20 * scale,
                    0.7 * blockSize * 20 * scale
                )
                applyMaceSmashImpulse(nearby, push, knockbackContext)
            end
        end
    end

    -- hurtEnemy sets vertical motion to 0.01 block/tick, then postHurtEnemy resets fallDistance.
    local velocity = owner:GetVelocity()
    owner:SetVelocity(Vector(0, 0, -velocity.z + 0.01 * blockSize * 20))
    self.MCFallDistance = 0
    self.MCLastFallZ = owner:GetPos().z
end
