-- Source-engine adapters for Java potion attributes and damage gates.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

local FIRE_MASK = bit.bor(DMG_BURN or 0, DMG_SLOWBURN or 0)
local MELEE_MASK = bit.bor(DMG_CLUB or 0, DMG_SLASH or 0)
local mitigatedDamage = setmetatable({}, { __mode = "k" })
local DEFAULT_PLAYER_HEALTH_SCALE = 5

local function positiveScale(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge or value <= 0 then return nil end
    return value
end

-- Minecraft absorption is stored in native health points (4 = two hearts),
-- while CTakeDamageInfo is in Source HP. Ask the target for its explicit
-- health-unit contract first, then accept the shared BMB/MCSWEP fields or hook.
-- A normal Source player is 100 HP versus Minecraft's 20, so the standalone
-- fallback is 5 Source HP per Minecraft health point.
function Potions.GetMinecraftHealthScale(target, context)
    if not IsValid(target) then return 1 end
    for _, methodName in ipairs({ "GetMCMinecraftHealthScale", "GetMinecraftHealthScale" }) do
        local method = target[methodName]
        if isfunction(method) then
            local called, value = pcall(method, target, context)
            local scale = called and positiveScale(value) or nil
            if scale then return scale end
        end
    end
    local scale = positiveScale(target.BMBMinecraftHealthScale)
        or positiveScale(target.MCMinecraftHealthScale)
    if scale then return scale end
    local hooked = hook.Run("MCITEM.MinecraftHealthScale", target, context)
    scale = positiveScale(hooked)
    if scale then return scale end
    if target.IsPlayer and target:IsPlayer() then return DEFAULT_PLAYER_HEALTH_SCALE end
    return 1
end

local function isMCItemWeapon(entity)
    if not IsValid(entity) or not entity:IsWeapon() then return false end
    local className = entity:GetClass()
    return string.StartWith(className, "weapon_mcitem_")
        or className == "weapon_bmb_item_model_test"
end

local function hasMCSWEPCombatPipeline(target)
    if not IsValid(target) or not target:IsPlayer() then return false end
    local sv = MC and MC.SV
    return sv and isfunction(sv.GetPlayerInventoryRecord)
        and sv.GetPlayerInventoryRecord(target, false) ~= nil
end

local function applyPostMitigation(target, damageInfo)
    if not IsValid(target) or not damageInfo then return end
    -- CTakeDamageInfo is engine userdata; arbitrary Lua fields are not a stable
    -- contract.  A weak-key table gives the same one-pass guarantee without
    -- retaining finished damage events.
    if mitigatedDamage[damageInfo] then return end
    mitigatedDamage[damageInfo] = true

    local damageType = damageInfo:GetDamageType()
    if Potions.HasEffect(target, "fire_resistance") and bit.band(damageType, FIRE_MASK) ~= 0 then
        damageInfo:SetDamage(0)
        return true
    end
    if Potions.HasEffect(target, "water_breathing") and bit.band(damageType, DMG_DROWN or 0) ~= 0 then
        damageInfo:SetDamage(0)
        return true
    end

    local bypass = hook.Run("MCITEM.PotionBypassesResistance", target, damageInfo)
    if bypass ~= true then
        local resistance = Potions.GetResistanceMultiplier(target)
        if resistance < 1 then damageInfo:ScaleDamage(resistance) end
    end

    -- LivingEntity.actuallyHurt applies armor first, magic/effect resistance
    -- second, and subtracts absorption last.
    local absorption = Potions.GetAbsorptionAmount(target)
    local incoming = math.max(0, damageInfo:GetDamage())
    if absorption > 0 and incoming > 0 then
        local healthScale = Potions.GetMinecraftHealthScale(target, damageInfo)
        local absorbedSource = math.min(absorption * healthScale, incoming)
        local absorbedMinecraft = absorbedSource / healthScale
        local remainingAbsorption = math.max(0, absorption - absorbedMinecraft)
        if remainingAbsorption < 0.000001 then remainingAbsorption = 0 end
        Potions.SetAbsorptionAmount(target, remainingAbsorption, "damage")
        damageInfo:SetDamage(math.max(0, incoming - absorbedSource))
        if damageInfo:GetDamage() <= 0 then return true end
    end
end

hook.Remove("MCITEM.DamageAfterEquipmentMitigation", "MCITEM.Potions.PostMitigation")
hook.Add("MCITEM.DamageAfterEquipmentMitigation", "MCITEM.Potions.PostMitigation", function(target, damageInfo)
    return applyPostMitigation(target, damageInfo)
end)

hook.Remove("SetupMove", "MCITEM.Potions.PlayerAttributes")
hook.Add("SetupMove", "MCITEM.Potions.PlayerAttributes", function(player, move)
    if not IsValid(player) then return end
    local multiplier = Potions.GetMovementMultiplier(player)
    if multiplier ~= 1 then
        move:SetForwardSpeed(move:GetForwardSpeed() * multiplier)
        move:SetSideSpeed(move:GetSideSpeed() * multiplier)
        move:SetMaxSpeed(move:GetMaxSpeed() * multiplier)
        move:SetMaxClientSpeed(move:GetMaxClientSpeed() * multiplier)
    end

    local velocity = move:GetVelocity()
    if Potions.HasEffect(player, "slow_falling") and velocity.z < 0 then
        -- LivingEntity.getEffectiveGravity while falling: min(normal, 0.01)
        -- block/tick^2. Convert the target acceleration into Source units/s^2.
        local sourceGravity = GetConVar("sv_gravity") and GetConVar("sv_gravity"):GetFloat() or 600
        local targetGravity = 0.01 * MCITEM.BlockSize() / (Potions.TickSeconds * Potions.TickSeconds)
        velocity.z = velocity.z + math.max(0, sourceGravity - targetGravity) * engine.TickInterval()
        move:SetVelocity(velocity)
    end

    if player:IsOnGround() and move:KeyPressed(IN_JUMP) then
        player.MCITEMPotionJumpPending = Potions.GetJumpBoostPower(player)
    end
end)

hook.Remove("FinishMove", "MCITEM.Potions.PlayerJumpBoost")
hook.Add("FinishMove", "MCITEM.Potions.PlayerJumpBoost", function(player, move)
    local boost = tonumber(player.MCITEMPotionJumpPending) or 0
    player.MCITEMPotionJumpPending = nil
    if boost <= 0 then return end
    local velocity = move:GetVelocity()
    if velocity.z <= 0 then return end
    velocity.z = velocity.z + boost * MCITEM.BlockSize() / Potions.TickSeconds
    move:SetVelocity(velocity)
end)

hook.Remove("GetFallDamage", "MCITEM.Potions.SlowFallingDamage")
hook.Add("GetFallDamage", "MCITEM.Potions.SlowFallingDamage", function(player)
    if Potions.HasEffect(player, "slow_falling") then return 0 end
end)

hook.Remove("EntityTakeDamage", "MCITEM.Potions.DamageAttributes")
hook.Add("EntityTakeDamage", "MCITEM.Potions.DamageAttributes", function(target, damageInfo)
    if not IsValid(target) then return end
    -- MCSWEP invokes the same status boundary after its shield/armor pass.
    -- Skip the early path for those players so absorption is not consumed
    -- before armor mitigation.
    if hasMCSWEPCombatPipeline(target) then
        local attacker = damageInfo:GetAttacker()
        local inflictor = damageInfo:GetInflictor()
        if IsValid(attacker) and bit.band(damageInfo:GetDamageType(), MELEE_MASK) ~= 0 and not isMCItemWeapon(inflictor) then
            local bonus = Potions.GetAttackDamageBonus(attacker)
            if bonus ~= 0 then damageInfo:SetDamage(math.max(0, damageInfo:GetDamage() + bonus)) end
        end
        return
    end

    local damageType = damageInfo:GetDamageType()

    applyPostMitigation(target, damageInfo)

    local attacker = damageInfo:GetAttacker()
    local inflictor = damageInfo:GetInflictor()
    if IsValid(attacker) and bit.band(damageType, MELEE_MASK) ~= 0 and not isMCItemWeapon(inflictor) then
        local bonus = Potions.GetAttackDamageBonus(attacker)
        if bonus ~= 0 then damageInfo:SetDamage(math.max(0, damageInfo:GetDamage() + bonus)) end
    end
end)
