-- Standalone MobEffectInstance runtime with Java 26.2 amplifier/hidden-effect
-- merge semantics and a fixed 20 Hz status clock.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local STATUS_KEY = "MCITEMPotionEffects"
local STATUS_REVISION_KEY = STATUS_KEY .. "Revision"
local STATUS_CHUNK_KEY_PREFIX = STATUS_KEY .. "Chunk"
-- NW/NW2 strings have a small per-value payload ceiling.  Keep every piece
-- below it; a four-effect snapshot is already large enough to cross the
-- legacy single-string limit on common GMod builds.
local STATUS_CHUNK_BYTES = 450
local STATUS_MAX_CHUNKS = 64
local STATUS_REVISION_WRAP = 2147483000
local MAX_CATCHUP_TICKS = 8

Potions.Tracked = Potions.Tracked or {}
-- Expose the wire constants so another MCITEM-aware UI can consume the same
-- snapshot without duplicating magic key names or limits.
Potions.StatusSnapshotProtocol = Potions.StatusSnapshotProtocol or {
    key = STATUS_KEY,
    revisionKey = STATUS_REVISION_KEY,
    chunkKeyPrefix = STATUS_CHUNK_KEY_PREFIX,
    chunkBytes = STATUS_CHUNK_BYTES,
    maxChunks = STATUS_MAX_CHUNKS,
}

local function updateAbsorption(target, amplifier)
    if not IsValid(target) then return false end
    local amount = math.max(0, tonumber(target.MCITEMAbsorptionAmount) or 0)
    local wanted = 4 * (math.max(0, math.floor(tonumber(amplifier) or 0)) + 1)
    if amount >= wanted then return false end
    target.MCITEMAbsorptionAmount = wanted
    if target.SetNW2Float then target:SetNW2Float("MCITEMAbsorptionAmount", wanted) end
    hook.Run("MCITEM.AbsorptionChanged", target, wanted, "effect_started")
    return true
end

function Potions.GetAbsorptionAmount(target)
    if not IsValid(target) then return 0 end
    return math.max(0, tonumber(target.MCITEMAbsorptionAmount) or 0)
end

function Potions.SetAbsorptionAmount(target, amount, reason)
    if not IsValid(target) then return false end
    amount = math.max(0, tonumber(amount) or 0)
    target.MCITEMAbsorptionAmount = amount
    if target.SetNW2Float then target:SetNW2Float("MCITEMAbsorptionAmount", amount) end
    hook.Run("MCITEM.AbsorptionChanged", target, amount, reason or "set")
    return true
end

local function effectsFor(target, create)
    if not IsValid(target) then return nil end
    if create and not target.MCITEMPotionEffects then target.MCITEMPotionEffects = {} end
    return target.MCITEMPotionEffects
end

function Potions.GetEffect(target, effectId)
    local effects = effectsFor(target, false)
    return effects and effects[Potions.NormalizeID(effectId) or ""] or nil
end

function Potions.HasEffect(target, effectId)
    local normalized = Potions.NormalizeID(effectId)
    if not normalized then return false end

    -- Some living targets intentionally keep their authoritative effect state
    -- outside MCITEM. BMB mobs, for example, store movement and periodic
    -- effects in BMB.Status so their AI fields remain in BMB units. Returning
    -- nil from the adapter means "not handled here" and preserves MCITEM's
    -- native MCITEMPotionEffects fallback.
    if IsValid(target) and isfunction(target.HasMCPotionEffect) then
        local handled = target:HasMCPotionEffect(normalized)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.TargetHasPotionEffect", target, normalized)
    if handled ~= nil then return handled ~= false end

    return Potions.GetEffect(target, normalized) ~= nil
end

local function copyInstance(instance)
    if not instance then return nil end
    return {
        id = instance.id,
        durationTicks = instance.durationTicks,
        amplifier = instance.amplifier,
        ambient = instance.ambient,
        visible = instance.visible,
        showIcon = instance.showIcon,
        source = instance.source,
        context = instance.context,
        hidden = copyInstance(instance.hidden),
    }
end

local function isInfinite(instance)
    return instance and (instance.durationTicks == -1 or instance.infinite == true)
end

local function assignCurrent(target, source)
    target.id = source.id
    target.durationTicks = source.durationTicks
    target.amplifier = source.amplifier
    target.ambient = source.ambient
    target.visible = source.visible
    target.showIcon = source.showIcon
    target.source = source.source
    target.context = source.context
end

local function mergeInstance(existing, incoming)
    local changed = false
    if incoming.amplifier > existing.amplifier then
        local old = copyInstance(existing)
        local oldHidden = existing.hidden
        assignCurrent(existing, incoming)
        if not isInfinite(incoming) and (isInfinite(old) or incoming.durationTicks < old.durationTicks) then
            old.hidden = oldHidden
            existing.hidden = old
        else
            existing.hidden = oldHidden
        end
        changed = true
    elseif incoming.amplifier == existing.amplifier then
        if isInfinite(incoming) or (not isInfinite(existing) and incoming.durationTicks > existing.durationTicks) then
            existing.durationTicks = incoming.durationTicks
            existing.source = incoming.source
            existing.context = incoming.context
            changed = true
        end
    elseif incoming.durationTicks > existing.durationTicks then
        if existing.hidden then
            changed = mergeInstance(existing.hidden, incoming) or changed
        else
            existing.hidden = copyInstance(incoming)
            changed = true
        end
    end

    if not incoming.ambient and existing.ambient then
        existing.ambient = false
        changed = true
    end
    if incoming.visible ~= existing.visible then
        existing.visible = incoming.visible
        changed = true
    end
    if incoming.showIcon ~= existing.showIcon then
        existing.showIcon = incoming.showIcon
        changed = true
    end
    return changed
end

local function statusChunkKey(index)
    return STATUS_CHUNK_KEY_PREFIX .. tostring(index)
end

local function nextStatusRevision(target)
    local networkRevision = target.GetNW2Int
        and target:GetNW2Int(STATUS_REVISION_KEY, 0) or 0
    local revision = math.max(
        tonumber(target.MCITEMPotionEffectRevision) or 0,
        networkRevision
    )
    revision = revision >= STATUS_REVISION_WRAP and 1 or revision + 1
    target.MCITEMPotionEffectRevision = revision
    return revision
end

local function publishStatusSnapshot(target, raw)
    raw = tostring(raw or "")
    local revision = nextStatusRevision(target)
    -- The header lets clients reject a partially delivered or mixed revision.
    -- CRC is inexpensive here because snapshots only change when effects do.
    local chunkCount = math.max(1, math.ceil((#raw + 32) / STATUS_CHUNK_BYTES))
    local chunks
    while true do
        local payload = tostring(revision) .. ":" .. tostring(chunkCount)
            .. ":" .. util.CRC(raw) .. "\n" .. raw
        chunks = {}
        for offset = 1, #payload, STATUS_CHUNK_BYTES do
            chunks[#chunks + 1] = string.sub(payload, offset, offset + STATUS_CHUNK_BYTES - 1)
        end
        if #chunks == chunkCount then break end
        chunkCount = #chunks
    end

    if #chunks > STATUS_MAX_CHUNKS then
        ErrorNoHalt("[MCITEM] potion effect snapshot exceeded the chunk budget\n")
        return false
    end

    local previousCount = math.Clamp(
        math.floor(tonumber(target.MCITEMPotionEffectChunkCount) or 0),
        0,
        STATUS_MAX_CHUNKS
    )
    for index, chunk in ipairs(chunks) do
        target:SetNW2String(statusChunkKey(index), chunk)
    end
    for index = #chunks + 1, previousCount do
        target:SetNW2String(statusChunkKey(index), "")
    end
    target.MCITEMPotionEffectChunkCount = #chunks

    -- Keep the original key for older clients while the snapshot still fits.
    -- Long snapshots intentionally use the chunk protocol instead of letting
    -- the engine truncate malformed JSON into the compatibility field.
    target:SetNW2String(STATUS_KEY, #raw <= STATUS_CHUNK_BYTES and raw or "")
    -- Publish the revision last.  Clients discover the count from the header
    -- in chunk 1 and validate every piece before accepting the new snapshot.
    if target.SetNW2Int then target:SetNW2Int(STATUS_REVISION_KEY, revision) end
    return true
end

local function syncTarget(target)
    if not IsValid(target) then return end
    local serialized = {}
    for effectId, effect in pairs(effectsFor(target, false) or {}) do
        local definition = Potions.EffectDefinition(effectId) or {}
        local duration = tonumber(effect.durationTicks) or 0
        serialized[#serialized + 1] = {
            id = effectId,
            amplifier = effect.amplifier,
            durationTicks = duration == -1 and -1 or math.max(0, math.floor(duration)),
            -- Clients render a local countdown from this absolute server
            -- clock value.  The status list is therefore networked only
            -- when the effect changes, not once per tick.
            expiresAt = duration == -1 and nil
                or CurTime() + math.max(0, duration) * Potions.TickSeconds,
            ambient = effect.ambient == true,
            visible = effect.visible ~= false,
            showIcon = effect.showIcon ~= false,
            category = definition.category or "neutral",
            color = tonumber(definition.color) or 0,
            infinite = duration == -1,
        }
    end
    table.sort(serialized, function(a, b) return a.id < b.id end)
    publishStatusSnapshot(
        target,
        #serialized > 0 and util.TableToJSON(serialized, false) or ""
    )
    target:SetNW2Bool("MCITEMPotionInvisible", Potions.HasEffect(target, "invisibility"))
end

function Potions.SyncEffects(target)
    syncTarget(target)
end

local function notifyApplied(target, effect, source, context, updated)
    if isfunction(target.OnMCPotionEffectApplied) then
        target:OnMCPotionEffectApplied(effect, source, context, updated)
    end
    hook.Run("MCITEM.PotionEffectApplied", target, effect, source, context, updated)
end

local function notifyRemoved(target, effect, reason)
    if isfunction(target.OnMCPotionEffectRemoved) then
        target:OnMCPotionEffectRemoved(effect, reason)
    end
    hook.Run("MCITEM.PotionEffectRemoved", target, effect, reason)
end

function Potions.ApplyEffect(target, rawEffect, source, context)
    local effect = Potions.CopyEffectSpec(rawEffect)
    if not effect or effect.durationTicks == 0 then return false end
    if not Potions.CanReceiveEffect(target, effect.id, source, context) then return false end
    if (effect.id == "poison" or effect.id == "regeneration")
        and Potions.HasEntityTag(target, Potions.EntityTags.IGNORES_POISON_AND_REGEN, context)
    then
        return false
    end

    if isfunction(target.ApplyMCPotionEffect) then
        local handled = target:ApplyMCPotionEffect(effect, source, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.ApplyPotionEffectToTarget", target, effect, source, context)
    if handled ~= nil then return handled ~= false end

    effect.source = source
    effect.context = context
    local effects = effectsFor(target, true)
    local existing = effects[effect.id]
    local changed
    if existing then
        changed = mergeInstance(existing, effect)
    else
        effects[effect.id] = effect
        changed = true
    end
    if not changed then return false end

    if effect.id == "absorption" then
        updateAbsorption(target, effects[effect.id].amplifier)
    end

    Potions.Tracked[target] = true
    syncTarget(target)
    notifyApplied(target, effects[effect.id], source, context, existing ~= nil)
    return true
end

function Potions.RemoveEffect(target, effectId, reason)
    local effects = effectsFor(target, false)
    effectId = Potions.NormalizeID(effectId)
    local effect = effects and effects[effectId or ""]
    if not effect then return false end
    effects[effectId] = nil
    if effectId == "absorption" then
        Potions.SetAbsorptionAmount(target, 0, reason or "effect_removed")
    end
    notifyRemoved(target, effect, reason or "removed")
    if not next(effects) then
        target.MCITEMPotionEffects = nil
        Potions.Tracked[target] = nil
    end
    syncTarget(target)
    return true
end

function Potions.ClearEffects(target, reason)
    local effects = effectsFor(target, false)
    if not effects then return false end
    for _, effect in pairs(effects) do notifyRemoved(target, effect, reason or "cleared") end
    if Potions.GetAbsorptionAmount(target) > 0 then
        Potions.SetAbsorptionAmount(target, 0, reason or "cleared")
    end
    target.MCITEMPotionEffects = nil
    Potions.Tracked[target] = nil
    syncTarget(target)
    return true
end

local function tickHidden(effect)
    if not effect then return nil end
    effect.hidden = tickHidden(effect.hidden)
    if isInfinite(effect) then return effect end
    effect.durationTicks = effect.durationTicks - 1
    if effect.durationTicks <= 0 then return effect.hidden end
    return effect
end

local function applyPeriodicEffect(target, effect)
    local amplifier = effect.amplifier or 0
    if effect.id == "poison" then
        local interval = math.max(bit.rshift(25, amplifier), 1)
        if effect.durationTicks % interval == 0 then
            local health = tonumber(target:Health()) or 0
            if health > 1 then
                Potions.DamageMagic(target, math.min(1, health - 1), effect.source, {
                    delivery = "status_tick",
                    effect = effect,
                    nonlethal = true,
                })
            end
        end
    elseif effect.id == "wither" then
        -- Java 26.2 WitherMobEffect: lethal 1-point damage every
        -- max(40 >> amplifier, 1) ticks.  Unlike poison there is no
        -- one-health floor.
        local interval = math.max(bit.rshift(40, amplifier), 1)
        if effect.durationTicks % interval == 0 then
            Potions.DamageMagic(target, 1, effect.source, {
                delivery = "status_tick",
                effect = effect,
                lethal = true,
            })
        end
    elseif effect.id == "regeneration" then
        local interval = math.max(bit.rshift(50, amplifier), 1)
        if effect.durationTicks % interval == 0 then
            Potions.Heal(target, 1, { delivery = "status_tick", effect = effect })
        end
    elseif effect.id == "hunger" then
        local food = MCITEM.Food
        if food and isfunction(food.ApplyExhaustion) and target:IsPlayer() then
            food.ApplyExhaustion(target, 0.005 * ((effect.amplifier or 0) + 1), {
                delivery = "status_tick",
                effect = effect,
            })
        end
    elseif effect.id == "saturation" then
        local food = MCITEM.Food
        if food and isfunction(food.ApplySaturation) and target:IsPlayer() then
            food.ApplySaturation(target, 1 + (effect.amplifier or 0), {
                delivery = "status_tick",
                effect = effect,
            })
        end
    elseif effect.id == "fire_resistance" and target:IsOnFire() then
        target:Extinguish()
    end

    if isfunction(target.OnMCPotionEffectTick) then
        target:OnMCPotionEffectTick(effect)
    end
    hook.Run("MCITEM.PotionEffectTick", target, effect)
end

local function tickTarget(target)
    if not Potions.IsLivingTarget(target) then
        Potions.ClearEffects(target, "invalid_or_dead")
        return
    end
    local effects = effectsFor(target, false)
    if not effects then
        Potions.Tracked[target] = nil
        return
    end

    local changed = false
    for effectId, effect in pairs(effects) do
        applyPeriodicEffect(target, effect)
        effect.hidden = tickHidden(effect.hidden)
        if not isInfinite(effect) then effect.durationTicks = effect.durationTicks - 1 end
        if not isInfinite(effect) and effect.durationTicks <= 0 then
            if effect.hidden then
                local promoted = effect.hidden
                promoted.hidden = promoted.hidden
                effects[effectId] = promoted
                notifyApplied(target, promoted, promoted.source, promoted.context, true)
            else
                effects[effectId] = nil
                if effectId == "absorption" then
                    Potions.SetAbsorptionAmount(target, 0, "expired")
                end
                notifyRemoved(target, effect, "expired")
            end
            changed = true
        end
    end

    if not next(effects) then
        target.MCITEMPotionEffects = nil
        Potions.Tracked[target] = nil
        changed = true
    end
    if changed then syncTarget(target) end
end

local nextStatusTick = CurTime() + Potions.TickSeconds
hook.Remove("Think", "MCITEM.Potions.StatusTick")
hook.Add("Think", "MCITEM.Potions.StatusTick", function()
    local now = CurTime()
    local steps = 0
    while now >= nextStatusTick and steps < MAX_CATCHUP_TICKS do
        for target in pairs(Potions.Tracked) do tickTarget(target) end
        nextStatusTick = nextStatusTick + Potions.TickSeconds
        steps = steps + 1
    end
    if steps >= MAX_CATCHUP_TICKS and now >= nextStatusTick then
        nextStatusTick = now + Potions.TickSeconds
    end
end)

hook.Remove("EntityRemoved", "MCITEM.Potions.StatusEntityRemoved")
hook.Add("EntityRemoved", "MCITEM.Potions.StatusEntityRemoved", function(entity)
    if entity and entity.MCITEMPotionEffects then
        entity.MCITEMPotionEffects = nil
        Potions.Tracked[entity] = nil
    end
end)
