-- Authoritative potion application: drinking, splash falloff, lingering scale
-- and water-potion behavior.  Effect lifetime ownership lives in sv_status.lua.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local NET_BREAK = "MCITEM_PotionBreak"

util.AddNetworkString(NET_BREAK)

local function callTarget(target, method, ...)
    if not IsValid(target) or not isfunction(target[method]) then return nil end
    return target[method](target, ...)
end

function Potions.Heal(target, amount, context)
    if not IsValid(target) then return false end
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 then return false end

    local handled = callTarget(target, "ApplyMCPotionHealing", amount, context)
    if handled ~= nil then return handled ~= false end
    handled = hook.Run("MCITEM.PotionHealing", target, amount, context)
    if handled ~= nil then return handled ~= false end

    local health = tonumber(target:Health()) or 0
    local maximum = tonumber(target:GetMaxHealth()) or health
    if maximum <= 0 or health >= maximum then return false end
    target:SetHealth(math.min(maximum, health + amount))
    return true
end

function Potions.DamageMagic(target, amount, source, context)
    if not IsValid(target) then return false end
    amount = math.max(0, tonumber(amount) or 0)
    if amount <= 0 then return false end

    local handled = callTarget(target, "ApplyMCPotionDamage", amount, source, context)
    if handled ~= nil then return handled ~= false end
    handled = hook.Run("MCITEM.PotionDamage", target, amount, source, context)
    if handled ~= nil then return handled ~= false end

    local attacker = IsValid(source) and source or game.GetWorld()
    local damage = DamageInfo()
    damage:SetDamage(amount)
    damage:SetDamageType(bit.bor(DMG_POISON or DMG_GENERIC, DMG_PREVENT_PHYSICS_FORCE or 0))
    damage:SetAttacker(attacker)
    damage:SetInflictor(attacker)
    damage:SetDamagePosition(target:WorldSpaceCenter())
    damage:SetDamageForce(vector_origin)
    target:TakeDamageInfo(damage)
    return true
end

function Potions.ApplyInstantEffect(target, effect, source, potency, context)
    if not Potions.CanReceiveEffect(target, effect.id, source, context) then return false end
    potency = math.max(0, tonumber(potency) or 1)
    local amplifier = math.max(0, math.floor(tonumber(effect.amplifier) or 0))
    local inverted = Potions.HasEntityTag(
        target,
        Potions.EntityTags.INVERTED_HEALING_AND_HARM,
        context
    )

    local heals = effect.id == "instant_health"
    local harms = effect.id == "instant_damage"
    if not heals and not harms then
        local handled = callTarget(target, "ApplyMCInstantPotionEffect", effect, source, potency, context)
        if handled ~= nil then return handled ~= false end
        handled = hook.Run("MCITEM.InstantPotionEffect", target, effect, source, potency, context)
        return handled == true
    end

    if inverted then heals, harms = harms, heals end
    if heals then
        local amount = math.floor((bit.lshift(4, amplifier)) * potency + 0.5)
        return Potions.Heal(target, amount, context)
    end

    local amount = math.floor((bit.lshift(6, amplifier)) * potency + 0.5)
    return Potions.DamageMagic(target, amount, source, context)
end

local function durationFor(effect, options)
    if isfunction(options.durationForEffect) then
        local duration = math.floor(tonumber(options.durationForEffect(effect)) or 0)
        return duration == -1 and -1 or math.max(0, duration)
    end
    local rawDuration = math.floor(tonumber(effect.durationTicks) or 0)
    local duration = rawDuration == -1 and -1 or math.max(0, rawDuration)
    local scale = math.max(0, tonumber(options.durationScale) or 1)
    if scale == 1 then return duration end
    if duration == -1 then return -1 end
    local scaled = duration * scale
    if options.roundDuration then return math.max(0, math.floor(scaled + 0.5)) end
    return math.max(1, math.floor(scaled))
end

function Potions.ApplyPotion(target, definition, source, options)
    if not istable(definition) or not Potions.IsLivingTarget(target) then return false end
    options = options or {}
    local applied = false
    for _, rawEffect in ipairs(definition.effects or {}) do
        local effect = Potions.CopyEffectSpec(rawEffect)
        if effect then
            local context = {
                potion = definition,
                bottleType = options.bottleType,
                delivery = options.delivery or "unknown",
                factor = tonumber(options.factor) or 1,
                cloud = options.cloud,
                projectile = options.projectile,
                weapon = options.weapon,
            }
            if Potions.IsInstantEffect(effect.id) then
                if Potions.ApplyInstantEffect(
                    target,
                    effect,
                    source,
                    tonumber(options.instantPotency) or 1,
                    context
                ) then
                    applied = true
                end
            else
                effect.durationTicks = durationFor(effect, options)
                if (effect.durationTicks == -1
                    or effect.durationTicks > (tonumber(options.minimumDurationTicks) or 0))
                    and isfunction(Potions.ApplyEffect)
                    and Potions.ApplyEffect(target, effect, source, context)
                then
                    applied = true
                end
            end
        end
    end
    return applied
end

local function nearestPointDistanceBlocks(target, position)
    local minimum, maximum = target:WorldSpaceAABB()
    local nearest = Vector(
        math.Clamp(position.x, minimum.x, maximum.x),
        math.Clamp(position.y, minimum.y, maximum.y),
        math.Clamp(position.z, minimum.z, maximum.z)
    )
    return nearest:Distance(position) / MCITEM.BlockSize()
end

function Potions.ApplySplash(position, definition, owner, projectile)
    if not isvector(position) or not istable(definition) then return 0 end
    local blockSize = MCITEM.BlockSize()
    local extent = Vector(
        Potions.SplashHorizontalRange * blockSize,
        Potions.SplashHorizontalRange * blockSize,
        Potions.SplashVerticalRange * blockSize
    )
    local affected = 0
    for _, target in ipairs(ents.FindInBox(position - extent, position + extent)) do
        if Potions.IsLivingTarget(target) then
            local distance = nearestPointDistanceBlocks(target, position)
            if distance < Potions.SplashHorizontalRange then
                local factor = 1 - distance / Potions.SplashHorizontalRange
                local applied = Potions.ApplyPotion(target, definition, owner, {
                    bottleType = "splash",
                    delivery = "splash",
                    factor = factor,
                    instantPotency = factor,
                    roundDuration = true,
                    minimumDurationTicks = Potions.SplashMinimumDurationTicks,
                    durationForEffect = function(effect)
                        return math.floor(effect.durationTicks * factor + 0.5)
                    end,
                    projectile = projectile,
                })
                if applied then affected = affected + 1 end
            end
        end
    end
    hook.Run("MCITEM.PotionSplashed", owner, projectile, definition, position, affected)
    return affected
end

function Potions.ApplyWaterSplash(position, owner, projectile)
    if not isvector(position) then return 0 end
    local blockSize = MCITEM.BlockSize()
    local extent = Vector(4 * blockSize, 4 * blockSize, 2 * blockSize)
    local affected = 0
    local context = { delivery = "water_splash", projectile = projectile, position = position }
    for _, target in ipairs(ents.FindInBox(position - extent, position + extent)) do
        if Potions.IsLivingTarget(target) and nearestPointDistanceBlocks(target, position) < 4 then
            local changed = false
            if Potions.IsWaterSensitive(target, context) then
                changed = Potions.DamageMagic(target, 1, owner, context) or changed
            end
            if target:IsOnFire() then
                target:Extinguish()
                changed = true
            end
            local rehydrated = callTarget(target, "OnMCPotionWaterSplash", owner, context)
            if rehydrated == nil then
                rehydrated = hook.Run("MCITEM.PotionWaterSplashed", target, owner, context)
            end
            if rehydrated == true then changed = true end
            if changed then affected = affected + 1 end
        end
    end
    hook.Run("MCITEM.PotionWaterHitBlock", owner, projectile, position, context)
    return affected
end

function Potions.BroadcastBreak(position, definition)
    if not isvector(position) or not istable(definition) then return end
    net.Start(NET_BREAK)
    net.WriteVector(position)
    net.WriteString(definition.id)
    net.WriteUInt(math.Clamp(math.floor(definition.color or Potions.EmptyColor), 0, 16777215), 24)
    net.WriteBool(definition.hasInstantEffects == true)
    net.Broadcast()
end

function Potions.CompleteDrink(weapon, definition)
    if not IsValid(weapon) or not istable(definition) then return false end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return false end

    -- Consumable.onConsume emits the normal consume event with count=16.  The
    -- default drink has no item particles, but it still plays this final sound.
    Potions.PlayDrinkSound(owner)
    Potions.ApplyPotion(owner, definition, owner, {
        bottleType = "drinkable",
        delivery = "drink",
        weapon = weapon,
    })

    local context = { potion = definition, bottleType = "drinkable", remainder = "glass_bottle" }
    if isfunction(weapon.OnMCPotionConsumed) then
        weapon:OnMCPotionConsumed(owner, definition, context)
    end
    hook.Run("MCITEM.PotionConsumed", owner, weapon, definition, context)
    hook.Run("MCITEM.ConsumePotionItem", owner, weapon, "drinkable", definition.id, 1, "glass_bottle", context)
    return true
end

function Potions.ServerDrinkTick(weapon, now)
    return Potions.AdvanceServerDrink(
        weapon,
        now,
        function(activeWeapon)
            local owner = activeWeapon:GetOwner()
            if IsValid(owner) then Potions.PlayDrinkSound(owner) end
        end,
        function(activeWeapon, definition)
            Potions.CompleteDrink(activeWeapon, definition)
        end
    )
end
