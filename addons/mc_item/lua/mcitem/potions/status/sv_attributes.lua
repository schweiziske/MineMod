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
    return sv and isfunction(sv.GetCombatDamageContext)
end

local function applyGenericMeleeBonus(target, damageInfo)
    local attacker, inflictor = damageInfo:GetAttacker(), damageInfo:GetInflictor()
    if not IsValid(attacker) or bit.band(damageInfo:GetDamageType(), MELEE_MASK) == 0
        or not IsValid(inflictor) or not inflictor:IsWeapon() or isMCItemWeapon(inflictor) then return end
    local bonus = Potions.GetAttackDamageBonus(attacker)
    if bonus ~= 0 then
        damageInfo:SetDamage(math.max(0, damageInfo:GetDamage()
            + bonus * Potions.GetMinecraftHealthScale(target, damageInfo)))
    end
end

hook.Add("MCITEM.DamageBeforeEquipmentMitigation", "MCITEM.Potions.MeleeAttributes", function(target, damageInfo)
    -- Preserve an earlier immunity listener's zero-damage result.
    if damageInfo:GetDamage() > 0 then applyGenericMeleeBonus(target, damageInfo) end
end)

local function applyPostMitigation(target, damageInfo)
    if not IsValid(target) or not damageInfo then return end
    -- CTakeDamageInfo is engine userdata; arbitrary Lua fields are not a stable
    -- contract. Track each target separately: area damage may reuse one info
    -- object across entities. Neither removed targets nor finished events are
    -- retained, and duplicate adapters for the same hit still apply only once.
    local targetDamage = mitigatedDamage[target]
    if not targetDamage then
        targetDamage = setmetatable({}, { __mode = "k" })
        mitigatedDamage[target] = targetDamage
    end
    if targetDamage[damageInfo] then return end
    targetDamage[damageInfo] = true

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
hook.Add("MCITEM.DamageAfterProtectionMitigation", "MCITEM.Potions.PostMitigation", function(target, damageInfo)
    return applyPostMitigation(target, damageInfo)
end)

hook.Remove("GetFallDamage", "MCITEM.Potions.SlowFallingDamage")
hook.Add("GetFallDamage", "MCITEM.Potions.SlowFallingDamage", function(player)
    if Potions.HasEffect(player, "slow_falling") or Potions.HasEffect(player, "levitation") then return 0 end
end)

hook.Remove("EntityTakeDamage", "MCITEM.Potions.DamageAttributes")
hook.Add("EntityTakeDamage", "MCITEM.Potions.DamageAttributes", function(target, damageInfo)
    if not IsValid(target) then return end
    -- MCSWEP invokes the same status boundary after its shield/armor pass.
    -- Skip the early path for those players so absorption is not consumed
    -- before armor mitigation.
    if hasMCSWEPCombatPipeline(target) then
        return
    end
    applyGenericMeleeBonus(target, damageInfo)
    return applyPostMitigation(target, damageInfo)
end)
