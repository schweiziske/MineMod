-- Minecraft Java 26.2 enchantment runtime for MCITEM projectiles and mace.
--
-- This module deliberately installs wrappers around the existing extension
-- points instead of spreading enchantment code through every SWEP/projectile.
-- The original functions and wrappers live in one global table so GMod
-- autorefresh cannot create an ever-growing wrapper chain.

MCITEM = MCITEM or {}
MCITEM.EnchantmentRuntime = MCITEM.EnchantmentRuntime or {}

local Runtime = MCITEM.EnchantmentRuntime
local TICK_SECONDS = 1 / 20
local NET_EVENT = "MCITEM_EnchantmentRuntimeFX"
local FX_LIGHTNING = 0
local FX_SOUL_SPEED = 1
local LIGHTNING_DAMAGE = 5
local LIGHTNING_HORIZONTAL_RADIUS = 3
local LIGHTNING_BELOW = 3
local LIGHTNING_ABOVE = 9
local LIGHTNING_SEED_PART = 16777216 -- 2^24; two parts preserve Java's 48-bit renderer seed.
local MINECRAFT_GRAVITY_BLOCKS_PER_SECOND_SQR = 32

Runtime.Originals = Runtime.Originals or {}
Runtime.Wrappers = Runtime.Wrappers or {}
Runtime.WrapperGenerations = Runtime.WrapperGenerations or {}
Runtime.LoadGeneration = (Runtime.LoadGeneration or 0) + 1
-- A mace bonus belongs to one target/attack transaction.  A singleton lets a
-- nested hit on another entity accidentally consume Breach from the outer
-- smash, so production resolution uses weak per-target stacks.
Runtime.ActiveMaceContexts = Runtime.ActiveMaceContexts
    or setmetatable({}, { __mode = "k" })
-- A bound DamageInfo is a narrower transaction than the attack context above.
-- Keep it separately so armor resolution never has to guess from a merely
-- recent MCGetAttackDamageBonus call (nested damage hooks are common in GMod).
Runtime.MaceDamageTransactions = Runtime.MaceDamageTransactions
    or setmetatable({}, { __mode = "k" })
Runtime.MaceDamageByInfo = Runtime.MaceDamageByInfo
    or setmetatable({}, { __mode = "k" })
-- Compatibility only for older diagnostics; do not use this as the source of
-- truth for armor calculation.
Runtime.ActiveMaceContext = Runtime.ActiveMaceContext or nil
Runtime.NextLightningEffectId = Runtime.NextLightningEffectId or 0
Runtime.NextSoulSpeedEffectId = Runtime.NextSoulSpeedEffectId or 0
Runtime.WindBurstImpulseStates = Runtime.WindBurstImpulseStates
    or setmetatable({}, { __mode = "k" })

local LOAD_GENERATION = Runtime.LoadGeneration

if SERVER then
    util.AddNetworkString(NET_EVENT)
end

local channelingFlags = FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED
Runtime.ChannelingThunderConVar = Runtime.ChannelingThunderConVar or CreateConVar(
    "mcitem_channeling_thunderstorm",
    "0",
    channelingFlags,
    "Treat the current GMod world as a Minecraft thunderstorm for Channeling tridents."
)

local function namespaced(identifier)
    identifier = tostring(identifier or "")
    if identifier == "" then return "" end
    return string.find(identifier, ":", 1, true) and identifier or "minecraft:" .. identifier
end

local function positiveLevel(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

-- Private key used to carry the exact attack context through the existing
-- MCGetAttackDamageBonus -> DamageInfo -> MCPostAttack call chain.  A table key
-- avoids colliding with addon-visible fields on the public context table.
local MACE_CONTEXT_KEY = Runtime.MaceContextKey or {}
Runtime.MaceContextKey = MACE_CONTEXT_KEY

local function damageInfoMethodValue(damageInfo, method)
    if not damageInfo then return nil end
    local getter = damageInfo[method]
    if not isfunction(getter) then return nil end
    local ok, value = pcall(getter, damageInfo)
    return ok and value or nil
end

local function vectorFingerprint(value)
    if not isvector(value) then return nil end
    return { x = tonumber(value.x) or 0, y = tonumber(value.y) or 0, z = tonumber(value.z) or 0 }
end

local function damageFingerprint(damageInfo)
    if not damageInfo then return nil end
    return {
        attacker = damageInfoMethodValue(damageInfo, "GetAttacker"),
        inflictor = damageInfoMethodValue(damageInfo, "GetInflictor"),
        damage = tonumber(damageInfoMethodValue(damageInfo, "GetDamage")),
        damageType = tonumber(damageInfoMethodValue(damageInfo, "GetDamageType")),
        position = vectorFingerprint(damageInfoMethodValue(damageInfo, "GetDamagePosition")),
        reportedPosition = vectorFingerprint(damageInfoMethodValue(damageInfo, "GetReportedPosition")),
    }
end

local function sameFingerprintVector(left, right)
    if left == nil or right == nil then return left == right end
    return math.abs(left.x - right.x) < 0.0001
        and math.abs(left.y - right.y) < 0.0001
        and math.abs(left.z - right.z) < 0.0001
end

local function maceTransactionMatches(transaction, target, damageInfo)
    if not transaction or transaction.target ~= target or not damageInfo then return false end
    local fingerprint = damageFingerprint(damageInfo)
    if not fingerprint then return false end

    -- Both source ends are authoritative.  An OR here is unsafe: a nested
    -- thorns/projectile hit can share an attacker or an inflictor with the
    -- outer attack and would incorrectly inherit Breach.
    if fingerprint.attacker ~= transaction.owner
        or fingerprint.inflictor ~= transaction.weapon then
        return false
    end

    local expected = transaction.fingerprint
    if not expected then return true end
    if expected.damage ~= nil and fingerprint.damage ~= nil
        and math.abs(expected.damage - fingerprint.damage) > 0.0001 then return false end
    if expected.damageType ~= nil and fingerprint.damageType ~= nil
        and expected.damageType ~= fingerprint.damageType then return false end
    if expected.position and fingerprint.position
        and not sameFingerprintVector(expected.position, fingerprint.position) then return false end
    if expected.reportedPosition and fingerprint.reportedPosition
        and not sameFingerprintVector(expected.reportedPosition, fingerprint.reportedPosition) then return false end
    return true
end

local function removeMaceDamageTransaction(transaction)
    if not transaction or transaction.removed then return end
    transaction.removed = true
    if transaction.damageInfo and Runtime.MaceDamageByInfo[transaction.damageInfo] == transaction then
        Runtime.MaceDamageByInfo[transaction.damageInfo] = nil
    end
    local target = transaction.target
    local list = target and Runtime.MaceDamageTransactions[target] or nil
    if list then
        for index = #list, 1, -1 do
            if list[index] == transaction then
                table.remove(list, index)
                break
            end
        end
        if #list == 0 then Runtime.MaceDamageTransactions[target] = nil end
    end
    if transaction.active and transaction.active.damageTransaction == transaction then
        transaction.active.damageTransaction = nil
    end
end

function Runtime.BindMaceDamageTransaction(owner, weapon, target, damageInfo, attackContext)
    if not SERVER or not damageInfo or not IsValid(target) then return nil end
    local active
    local explicit = istable(attackContext) and attackContext[MACE_CONTEXT_KEY] or nil
    if explicit and explicit.target == target and explicit.owner == owner
        and explicit.weapon == weapon and not explicit.bound then
        active = explicit
    end
    if not active then
        local list = Runtime.ActiveMaceContexts[target]
        for index = list and #list or 0, 1, -1 do
            local candidate = list[index]
            if candidate.owner == owner and candidate.weapon == weapon and not candidate.bound then
                active = candidate
                break
            end
        end
    end
    if not active then return nil end

    local transaction = {
        owner = owner,
        weapon = weapon,
        target = target,
        damageInfo = damageInfo,
        fingerprint = damageFingerprint(damageInfo),
        active = active,
    }
    active.bound = true
    active.damageTransaction = transaction
    local list = Runtime.MaceDamageTransactions[target]
    if not list then
        list = {}
        Runtime.MaceDamageTransactions[target] = list
    end
    list[#list + 1] = transaction
    Runtime.MaceDamageByInfo[damageInfo] = transaction
    return transaction
end

function Runtime.UnbindMaceDamageTransaction(transaction)
    removeMaceDamageTransaction(transaction)
end

function Runtime.ResolveMaceDamageTransaction(target, damageInfo)
    if not IsValid(target) or not damageInfo then return nil end
    local direct = Runtime.MaceDamageByInfo[damageInfo]
    if direct and maceTransactionMatches(direct, target, damageInfo) then return direct end
    local list = Runtime.MaceDamageTransactions[target]
    for index = list and #list or 0, 1, -1 do
        local candidate = list[index]
        if maceTransactionMatches(candidate, target, damageInfo) then return candidate end
    end
    return nil
end

local function componentValue(stack, key)
    if not istable(stack) or not istable(stack.components) then return nil end
    if stack.components[key] ~= nil then return stack.components[key] end
    return stack.components[namespaced(key)]
end

local function readLevelTable(value, wanted)
    if not istable(value) then return 0 end
    local levels = istable(value.levels) and value.levels or value
    local maximum = 0
    for identifier, entry in pairs(levels) do
        if namespaced(identifier) == wanted then
            if istable(entry) then
                maximum = math.max(maximum, positiveLevel(entry.level or entry.lvl or entry[1]))
            else
                maximum = math.max(maximum, positiveLevel(entry))
            end
        elseif isnumber(identifier) and istable(entry) then
            local entryId = entry.id or entry.enchantment or entry.name
            if namespaced(entryId) == wanted then
                maximum = math.max(maximum, positiveLevel(entry.level or entry.lvl or entry[2]))
            end
        end
    end
    return maximum
end

function Runtime.GetEnchantmentLevel(stack, enchantmentId)
    if not istable(stack) then return 0 end
    local wanted = namespaced(enchantmentId)
    if MC and isfunction(MC.GetItemEnchantments) then
        -- Runtime effects only read the equipped `enchantments` component.
        -- MC.GetEnchantmentLevel also falls back to `stored_enchantments` for
        -- enchanted books, which must never activate an item-use effect.
        local ok, levels = pcall(MC.GetItemEnchantments, stack, false)
        if ok and istable(levels) then return readLevelTable(levels, wanted) end
    end
    return readLevelTable(componentValue(stack, "enchantments"), wanted)
end

function Runtime.GetSelectedStack(playerEntity)
    if not IsValid(playerEntity) or not playerEntity:IsPlayer() then return nil end
    if SERVER then
        local inventory = MC and MC.API and MC.API.Inventory
        if not inventory or not isfunction(inventory.GetSelected) then return nil end
        local stack = inventory.GetSelected(playerEntity)
        return istable(stack) and stack or nil
    end
    if playerEntity == LocalPlayer() and MC and isfunction(MC.GetClientSelectedStack) then
        local stack = MC.GetClientSelectedStack()
        return istable(stack) and stack or nil
    end
    return nil
end

function Runtime.StackForWeapon(weapon, owner)
    local inventoryProxy = IsValid(weapon) and weapon.MCHandWeaponBridgeProxy == true
    if IsValid(weapon) and weapon.GetNW2Bool
        and weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then inventoryProxy = true end
    if inventoryProxy and IsValid(owner) then
        local selected = Runtime.GetSelectedStack(owner)
        if selected then return selected end
    end
    if IsValid(weapon) and istable(weapon.MCITEMEnchantmentStack) then
        return weapon.MCITEMEnchantmentStack
    end
    local itemId = IsValid(weapon) and weapon.MCItemID or nil
    if not isstring(itemId) or itemId == "" then return nil end
    return { item = namespaced(itemId), count = 1 }
end

function Runtime.ChannelingEnabled()
    local cvar = Runtime.ChannelingThunderConVar
    return cvar and cvar:GetBool() or false
end

local function projectileStack(projectile)
    if not IsValid(projectile) then return nil end
    if istable(projectile.MCEnchantmentStack) then return projectile.MCEnchantmentStack end
    if istable(projectile.MCPickupStack) then return projectile.MCPickupStack end
    return nil
end

Runtime.ProjectileStack = projectileStack

local function living(entity)
    return IsValid(entity) and not entity:IsWorld()
        and (entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true)
end

local function ignitionContext(reason)
    if istable(reason) then
        reason.source = reason.source or "enchantment"
        return reason
    end
    return { source = reason or "enchantment" }
end

local function modifyIgnitionDuration(entity, seconds, context)
    if not SERVER or not hook or not isfunction(hook.Run)
        or context.ignitionDurationModified == true then return seconds end
    local modified = hook.Run("MC.ModifyEntityIgnitionDuration", entity, seconds, context)
    context.ignitionDurationModified = true
    if modified ~= nil then seconds = math.max(0, tonumber(modified) or seconds) end
    context.modifiedIgnitionSeconds = seconds
    return seconds
end

local function sourceFlameCandidate(value)
    return IsValid(value) and isfunction(value.GetClass)
        and value:GetClass() == "entityflame" and value or nil
end

local function sourceFlameEntity(entity)
    if not IsValid(entity) then return nil end

    if isfunction(entity.GetInternalVariable) then
        local ok, effect = pcall(entity.GetInternalVariable, entity, "m_hEffectEntity")
        effect = ok and sourceFlameCandidate(effect) or nil
        if effect then return effect end
    end

    if isfunction(entity.GetSaveTable) then
        local ok, saveTable = pcall(entity.GetSaveTable, entity)
        local effect = ok and istable(saveTable)
            and sourceFlameCandidate(saveTable.m_hEffectEntity) or nil
        if effect then return effect end
    end

    if isfunction(entity.GetEffectEntity) then
        local ok, effect = pcall(entity.GetEffectEntity, entity)
        effect = ok and sourceFlameCandidate(effect) or nil
        if effect then return effect end
    end

    if isfunction(entity.GetChildren) then
        local ok, children = pcall(entity.GetChildren, entity)
        if ok and istable(children) then
            for _, child in ipairs(children) do
                child = sourceFlameCandidate(child)
                if child then return child end
            end
        end
    end
    return nil
end

local function sourceFlameEndsAt(entity)
    local flame = sourceFlameEntity(entity)
    if not flame then return nil, nil end

    if isfunction(flame.GetInternalVariable) then
        for _, key in ipairs({ "lifetime", "m_flLifetime" }) do
            local ok, value = pcall(flame.GetInternalVariable, flame, key)
            value = ok and tonumber(value) or nil
            if value and value == value then return value, flame end
        end
    end

    if isfunction(flame.GetSaveTable) then
        local ok, saveTable = pcall(flame.GetSaveTable, flame)
        if ok and istable(saveTable) then
            local value = tonumber(saveTable.lifetime or saveTable.m_flLifetime)
            if value and value == value then return value, flame end
        end
    end
    return nil, flame
end

local function sourceIgnitionDeadlineApplied(entity, requestedEnd)
    local endsAt = sourceFlameEndsAt(entity)
    -- Entity:Fire accepts the duration at a slightly later CurTime than the
    -- caller sampled.  A one-tick tolerance still proves the old deadline was
    -- replaced while avoiding false negatives from Source float/tick timing.
    return endsAt ~= nil and endsAt + TICK_SECONDS >= requestedEnd
end

function Runtime.GetSourceIgnitionState(entity, now)
    now = tonumber(now) or CurTime()
    local burning = IsValid(entity) and isfunction(entity.IsOnFire)
        and entity:IsOnFire() == true or false
    local endsAt, flame
    if burning then endsAt, flame = sourceFlameEndsAt(entity) end
    return {
        burning = burning,
        flame = flame,
        endsAt = endsAt,
        remaining = endsAt and math.max(0, endsAt - now) or nil,
    }
end

function Runtime.ApplySourceIgnition(entity, seconds, now)
    if not SERVER or not IsValid(entity) or not isfunction(entity.Ignite) then return false end
    seconds = math.max(0, tonumber(seconds) or 0)
    if seconds <= 0 then return true end
    now = tonumber(now) or CurTime()

    local state = Runtime.GetSourceIgnitionState(entity, now)
    if not state.burning then
        entity:Ignite(seconds, 0)
        return true
    end

    local requestedEnd = now + seconds
    if not state.endsAt or requestedEnd <= state.endsAt + 0.001 then
        -- With an unknown clock, preserve Source's legacy no-op instead of
        -- risking shortening an existing fire. A readable clock follows
        -- Entity.igniteForTicks and only extends the later deadline.
        return true
    end

    if isfunction(entity.Fire) then
        local ok = pcall(entity.Fire, entity, "IgniteLifetime", tostring(seconds), 0)
        if ok and sourceIgnitionDeadlineApplied(entity, requestedEnd) then return true end
    end
    if IsValid(state.flame) and isfunction(state.flame.SetSaveValue) then
        for _, key in ipairs({ "lifetime", "m_flLifetime" }) do
            local ok = pcall(state.flame.SetSaveValue, state.flame, key, requestedEnd)
            if ok and sourceIgnitionDeadlineApplied(entity, requestedEnd) then return true end
        end
    end
    return false
end

local function igniteEntity(entity, seconds, reason)
    if not IsValid(entity) then return false end
    seconds = math.max(0, tonumber(seconds) or 0)
    local context = ignitionContext(reason)
    context.requestedIgnitionSeconds = context.requestedIgnitionSeconds or seconds
    seconds = modifyIgnitionDuration(entity, seconds, context)
    if seconds <= 0 then return true end
    local handled = hook.Run("MCITEM.IgniteEntity", entity, seconds, context.source, context)
    if handled ~= nil then return handled ~= false end
    return Runtime.ApplySourceIgnition(entity, seconds)
end

Runtime.IgniteEntity = igniteEntity

local function enginePositionToCell(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if coords and isfunction(coords.EngineToCell) then
        local ok, bx, by, bz = pcall(coords.EngineToCell, position, context)
        if ok and bx ~= nil then return bx, by, bz end
    end
    return nil
end

-- Shared gameplay modules (including Riptide's rain gate) need the same
-- coordinate conversion without duplicating the MC/MineMod adapter lookup.
Runtime.EnginePositionToCell = enginePositionToCell

local function visibleToSky(position, coordinateContext, traceFilter)
    if not isvector(position) then return false end
    local bx, by, bz = enginePositionToCell(position, coordinateContext)
    local world = MC and MC.API and MC.API.World
    if bx ~= nil and world and isfunction(world.CanSeeSky) then
        local visible = world.CanSeeSky(bx, by, bz)
        if visible ~= nil then return visible == true end
    end
    local height = math.max(32768, (isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5) * 512)
    local trace = util.TraceLine({
        start = position + Vector(0, 0, 1),
        endpos = position + Vector(0, 0, height),
        filter = traceFilter,
        mask = MASK_SOLID,
    })
    return not trace.Hit or trace.HitSky == true
end

Runtime.VisibleToSky = visibleToSky

local function blockInfoAtTrace(trace, context)
    if not istable(trace) or not isvector(trace.HitPos) then return nil end
    local normal = isvector(trace.HitNormal) and trace.HitNormal or Vector(0, 0, 1)
    local bx, by, bz = enginePositionToCell(trace.HitPos - normal * 0.5, context)
    if bx == nil then return nil end
    local world = MC and MC.API and MC.API.World
    local info = world and isfunction(world.GetBlockInfo) and world.GetBlockInfo(bx, by, bz) or nil
    return info, bx, by, bz
end

local function isLightningRod(info)
    if not istable(info) then return false end
    local name = namespaced(info.name or info.mcid or "")
    return name == "minecraft:lightning_rod"
        or string.match(name, "^minecraft:.-_lightning_rod$") ~= nil
end

local function trySetStrikeFire(position, cause, coordinateContext)
    local bx, by, bz = enginePositionToCell(position - Vector(0, 0, 0.001), coordinateContext)
    if bx == nil then return false end
    local world = MC and MC.API and MC.API.World
    if not world or not isfunction(world.SetBlock) then return false end
    local isAir = not isfunction(world.IsAir) or world.IsAir(bx, by, bz)
    if not isAir then return false end
    return world.SetBlock(bx, by, bz, "minecraft:fire", {
        actor = cause,
        fx = true,
        blockUpdates = true,
        preventPlayerOverlap = true,
    }) == true
end

local function pulseLightningRod(bx, by, bz)
    local redstone = MC and MC.API and MC.API.Redstone
    if not redstone or not isfunction(redstone.Pulse) then return false end
    return redstone.Pulse(bx, by, bz, 15, 8) == true
end

local function randomLightningSeed()
    return math.random(0, LIGHTNING_SEED_PART - 1)
        + math.random(0, LIGHTNING_SEED_PART - 1) * LIGHTNING_SEED_PART
end

local function nextLightningEffectId()
    Runtime.NextLightningEffectId = Runtime.NextLightningEffectId % 4294967295 + 1
    return Runtime.NextLightningEffectId
end

local function sendEffect(kind, effectId, position, seed, phaseDuration, velocity)
    if not SERVER or not isvector(position) then return end
    seed = math.floor(tonumber(seed) or 0)
    net.Start(NET_EVENT)
    net.WriteUInt(kind, 2)
    net.WriteUInt(math.floor(tonumber(effectId) or 0) % 4294967296, 32)
    net.WriteVector(position)
    net.WriteUInt(seed % LIGHTNING_SEED_PART, 24)
    net.WriteUInt(math.floor(seed / LIGHTNING_SEED_PART) % LIGHTNING_SEED_PART, 24)
    net.WriteFloat(math.max(0, tonumber(phaseDuration) or 0))
    if kind == FX_SOUL_SPEED then
        net.WriteVector(isvector(velocity) and velocity or vector_origin)
    end
    net.SendPVS(position)
end

local function playOfficialAt(position, variants, volume, pitch, soundLevel)
    if not isvector(position) or not istable(variants) or #variants == 0 then return end
    sound.Play(
        variants[math.random(1, #variants)],
        position,
        soundLevel or 100,
        math.Clamp(math.floor((tonumber(pitch) or 1) * 100 + 0.5), 1, 255),
        math.Clamp(tonumber(volume) or 1, 0, 1)
    )
end

local LIGHTNING_THUNDER = {
    "mcitem/enchantments/thunder1.ogg",
    "mcitem/enchantments/thunder2.ogg",
    "mcitem/enchantments/thunder3.ogg",
}
local LIGHTNING_IMPACT = {
    "mcitem/enchantments/impact1.ogg",
    "mcitem/enchantments/impact2.ogg",
    "mcitem/enchantments/impact3.ogg",
    "mcitem/enchantments/impact4.ogg",
}
local TRIDENT_THUNDER = {
    "mcitem/enchantments/trident_thunder1.ogg",
    "mcitem/enchantments/trident_thunder2.ogg",
}
local SOUL_SPEED_ESCAPE = {
    "mcitem/enchantments/soul_speed1.ogg",
    "mcitem/enchantments/soul_speed2.ogg",
    "mcitem/enchantments/soul_speed3.ogg",
    "mcitem/enchantments/soul_speed4.ogg",
    "mcitem/enchantments/soul_speed5.ogg",
    "mcitem/enchantments/soul_speed6.ogg",
    "mcitem/enchantments/soul_speed7.ogg",
    "mcitem/enchantments/soul_speed8.ogg",
    "mcitem/enchantments/soul_speed9.ogg",
    "mcitem/enchantments/soul_speed10.ogg",
    "mcitem/enchantments/soul_speed11.ogg",
    "mcitem/enchantments/soul_speed12.ogg",
    "mcitem/enchantments/soul_speed13.ogg",
}

local function nextSoulSpeedEffectId()
    Runtime.NextSoulSpeedEffectId = Runtime.NextSoulSpeedEffectId % 4294967295 + 1
    return Runtime.NextSoulSpeedEffectId
end

function Runtime.EmitSoulSpeedParticle(playerEntity)
    if not SERVER or not IsValid(playerEntity) then return false end
    local size = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
    local minimum, maximum
    if isfunction(playerEntity.WorldSpaceAABB) then
        minimum, maximum = playerEntity:WorldSpaceAABB()
    end
    local origin = isfunction(playerEntity.GetPos) and playerEntity:GetPos() or vector_origin
    minimum = isvector(minimum) and minimum or origin - Vector(size * 0.3, size * 0.3, 0)
    maximum = isvector(maximum) and maximum or origin + Vector(size * 0.3, size * 0.3, size * 1.8)
    local position = Vector(
        math.Rand(minimum.x, maximum.x),
        math.Rand(minimum.y, maximum.y),
        origin.z + size * 0.1
    )
    local movement = isfunction(playerEntity.GetVelocity)
        and playerEntity:GetVelocity() or vector_origin
    local blocksPerTick = math.max(size * 20, 0.001)
    local particleVelocity = Vector(
        movement.x / blocksPerTick * -0.2,
        movement.y / blocksPerTick * -0.2,
        0.1
    )
    sendEffect(FX_SOUL_SPEED, nextSoulSpeedEffectId(), position,
        randomLightningSeed(), size, particleVelocity)
    hook.Run("MCITEM.SoulSpeedParticle", playerEntity, position, particleVelocity)
    return true
end

function Runtime.PlaySoulSpeedSound(playerEntity)
    if not SERVER or not IsValid(playerEntity) then return false end
    local position = isfunction(playerEntity.GetPos)
        and playerEntity:GetPos() or playerEntity:WorldSpaceCenter()
    playOfficialAt(position, SOUL_SPEED_ESCAPE, 0.6, 0.6 + math.Rand(0, 1) * 0.4, 75)
    hook.Run("MCITEM.SoulSpeedSound", playerEntity, position)
    return true
end

local function lightningDamageTick(position, cause, inflictor, hitEntities)
    local blockSize = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
    local horizontal = LIGHTNING_HORIZONTAL_RADIUS * blockSize
    local mins = position + Vector(-horizontal, -horizontal, -LIGHTNING_BELOW * blockSize)
    local maxs = position + Vector(horizontal, horizontal, LIGHTNING_ABOVE * blockSize)
    for _, target in ipairs(ents.FindInBox(mins, maxs)) do
        if living(target) and not hitEntities[target] then
            -- LightningBolt keeps one hitEntities set for its complete lifetime,
            -- including every re-flash.  Mark before damage so hooks that cause
            -- nested traces cannot apply thunderHit twice to the same entity.
            hitEntities[target] = true
            local oldHealth = tonumber(target:Health())
            local damageInfo = DamageInfo()
            damageInfo:SetAttacker(IsValid(cause) and cause or game.GetWorld())
            damageInfo:SetInflictor(IsValid(inflictor) and inflictor or (IsValid(cause) and cause or game.GetWorld()))
            damageInfo:SetDamage(isfunction(MCITEM.ScaleDamage) and MCITEM.ScaleDamage(LIGHTNING_DAMAGE) or LIGHTNING_DAMAGE)
            damageInfo:SetDamageType(DMG_SHOCK)
            damageInfo:SetDamagePosition(position)
            target:TakeDamageInfo(damageInfo)
            local newHealth = IsValid(target) and tonumber(target:Health()) or nil
            local accepted = oldHealth == nil or not IsValid(target)
                or (newHealth ~= nil and newHealth < oldHealth)
            if accepted then
                -- Entity.thunderHit increments remaining fire ticks and may
                -- begin an eight-second burn. Source exposes only Ignite, so
                -- apply that public approximation after the hit is accepted.
                igniteEntity(target, 8, "channeling_lightning")
            end
        end
    end
end

function Runtime.StrikeLightning(position, cause, inflictor, options)
    if not SERVER or not isvector(position) then return false end
    options = options or {}
    local state = {
        life = 2,
        seed = randomLightningSeed(),
        flashes = math.random(1, 3),
        hitEntities = {},
        effectId = nextLightningEffectId(),
    }
    local totalFlashes = state.flashes + 1
    local coordinateContext = options.coordinateContext or inflictor or cause

    -- LightningBolt.tick runs this life/flashes state machine every game tick.
    -- Each active phase scans twice (life 1 then 0), but LightningBolt's shared
    -- hitEntities set makes thunderHit at most once per entity across all
    -- flashes. LightningBoltRenderer ignores life and renders the same entity
    -- throughout the negative-life wait; a re-flash only replaces its seed.
    -- While life is negative Java rerolls nextInt(10) every tick.
    local function lightningTick()
        if state.life == 2 then
            trySetStrikeFire(position, cause, coordinateContext)
            sendEffect(FX_LIGHTNING, state.effectId, position, state.seed, 3 * TICK_SECONDS)
            hook.Run("MCITEM.LightningFlash", position, state.seed, true)
            playOfficialAt(position, LIGHTNING_THUNDER, 1, 0.8 + math.Rand(0, 1) * 0.2, 140)
            playOfficialAt(position, LIGHTNING_IMPACT, 1, 0.5 + math.Rand(0, 1) * 0.2, 100)
            if options.channeling then
                -- channeling.json requests volume 5. Source caps gain at 1, so
                -- map the extra Minecraft volume to propagation distance.
                playOfficialAt(position, TRIDENT_THUNDER, 1, 1, 120)
            end
        end

        state.life = state.life - 1
        if state.life < 0 then
            if state.flashes <= 0 then
                sendEffect(FX_LIGHTNING, state.effectId, position, state.seed, 0)
                hook.Run("MCITEM.LightningEnded", position, state.effectId)
                return
            end
            if state.life < -math.random(0, 9) then
                state.flashes = state.flashes - 1
                state.life = 1
                state.seed = randomLightningSeed()
                trySetStrikeFire(position, cause, coordinateContext)
                sendEffect(FX_LIGHTNING, state.effectId, position, state.seed, 2 * TICK_SECONDS)
                hook.Run("MCITEM.LightningFlash", position, state.seed, false)
            end
        end

        if state.life >= 0 then
            lightningDamageTick(position, cause, inflictor, state.hitEntities)
        end
        timer.Simple(TICK_SECONDS, lightningTick)
    end

    lightningTick()
    hook.Run("MCITEM.ChannelingLightning", position, cause, inflictor, totalFlashes)
    return true
end

local function channelingStack(projectile)
    return projectileStack(projectile)
end

local function tryChannelEntity(projectile, target, trace)
    if not Runtime.ChannelingEnabled() or not IsValid(projectile) or not IsValid(target) then return end
    if Runtime.GetEnchantmentLevel(channelingStack(projectile), "channeling") <= 0 then return end
    local strikePosition = istable(trace) and isvector(trace.HitPos) and trace.HitPos or nil
    if not isvector(strikePosition) and isfunction(target.WorldSpaceCenter) then
        strikePosition = target:WorldSpaceCenter()
    end
    if not isvector(strikePosition) then strikePosition = target:GetPos() end
    if not visibleToSky(strikePosition, target, { projectile, target }) then return end
    Runtime.StrikeLightning(strikePosition, projectile:GetOwner(), projectile, {
        channeling = true,
        coordinateContext = target,
    })
end

local function tryChannelWorld(projectile, trace)
    if not Runtime.ChannelingEnabled() or not IsValid(projectile) then return end
    if Runtime.GetEnchantmentLevel(channelingStack(projectile), "channeling") <= 0 then return end
    local info, bx, by, bz = blockInfoAtTrace(trace, projectile)
    if not isLightningRod(info) then return end
    local strikePosition = trace.HitPos
    if not visibleToSky(strikePosition + Vector(0, 0, 1), projectile, projectile) then return end
    pulseLightningRod(bx, by, bz)
    Runtime.StrikeLightning(strikePosition, projectile:GetOwner(), projectile, {
        channeling = true,
        coordinateContext = projectile,
    })
end

local function armWindBurstFallImmunity(owner, position)
    if not IsValid(owner) or not owner:IsPlayer() or not isvector(position) then return nil end
    local previous = Runtime.WindBurstImpulseStates[owner]
    local impactZ = position.z
    -- MaceItem.calculateImpactPosition preserves an earlier, lower impulse
    -- origin while chaining Wind Burst bounces.
    if previous and tonumber(previous.impactZ) and previous.impactZ <= impactZ then
        impactZ = previous.impactZ
    end
    local state = {
        impactZ = impactZ,
        armedAt = CurTime(),
        airborne = true,
    }
    Runtime.WindBurstImpulseStates[owner] = state
    return state
end

local function windBurstLaunchVelocityScale()
    local blockSize = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
    local minecraftGravity = MINECRAFT_GRAVITY_BLOCKS_PER_SECOND_SQR * blockSize
    local sourceGravity = 600
    local gravityConVar = isfunction(GetConVar) and GetConVar("sv_gravity") or nil
    if gravityConVar and isfunction(gravityConVar.GetFloat) then
        sourceGravity = math.abs(tonumber(gravityConVar:GetFloat()) or sourceGravity)
    end
    if minecraftGravity <= 0 or sourceGravity <= 0 then return 1 end

    -- The data-pack multipliers are still the exact Java 1.2 / 1.75 / 2.2.
    -- This factor only converts their ballistic apex to Source gravity. Reusing
    -- mcitem_knockback_scale (default 0.3) made Wind Burst III rise only about
    -- five blocks instead of the roughly thirty-block Java trajectory.
    return math.sqrt(sourceGravity / minecraftGravity)
end

Runtime.WindBurstLaunchVelocityScale = windBurstLaunchVelocityScale

local function launchWindBurstOwner(position, owner, level, multiplier)
    if not IsValid(owner) or not isvector(position) then return vector_origin end
    armWindBurstFallImmunity(owner, position)

    local launchScale = windBurstLaunchVelocityScale()
    local context = {
        kind = "mace_wind_burst",
        enchantmentLevel = level,
        position = position,
        strength = 3.5,
        diameter = 7,
        source = nil,
        attacker = owner,
        target = owner,
        distance = 0,
        exposure = 1,
        impact = 1,
        knockbackMultiplier = multiplier,
        velocityScale = launchScale,
    }
    local explosions = MCITEM.Explosions
    local resistance = explosions and isfunction(explosions.GetKnockbackResistance)
        and explosions.GetKnockbackResistance(owner, context) or 0
    local rawVelocity = Vector(0, 0,
        multiplier * (1 - math.Clamp(tonumber(resistance) or 0, 0, 1))
            * (isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5) / TICK_SECONDS)
    local appliedVelocity = rawVelocity * launchScale

    if isfunction(owner.SetGroundEntity) then owner:SetGroundEntity(NULL) end
    if explosions and isfunction(explosions.ApplyKnockback) then
        explosions.ApplyKnockback(owner, rawVelocity, context)
    elseif isfunction(owner.StartBMBExternalImpulse)
        and owner:StartBMBExternalImpulse(appliedVelocity, {
            reason = "mace_wind_burst",
            duration = 0.12,
        }) then
        -- BMB owns its locomotion state and has accepted the additive impulse.
    elseif owner:IsPlayer() and isfunction(owner.SetVelocity) then
        owner:SetVelocity(appliedVelocity)
    elseif isfunction(owner.SetVelocity) then
        owner:SetVelocity(owner:GetVelocity() + appliedVelocity)
    end
    return appliedVelocity
end

local function windBurst(position, owner, target, level)
    if level <= 0 or not isvector(position) then return end
    local multipliers = { 1.2, 1.75, 2.2 }
    local multiplier = multipliers[math.Clamp(level, 1, #multipliers)]
    local world = MC and MC.API and MC.API.World
    if world and isfunction(world.TriggerExplosion) then
        world.TriggerExplosion(position, 3.5, {
            actor = owner,
            source = owner,
            interaction = "trigger_block",
            immuneBlocks = {
                ["minecraft:barrier"] = true,
                ["minecraft:bedrock"] = true,
            },
        })
    end
    if MCITEM.Explosions and isfunction(MCITEM.Explosions.Explode) then
        MCITEM.Explosions.Explode({
            position = position,
            strength = 3.5,
            source = owner,
            attacker = owner,
            damageEntities = false,
            -- Java's ExplodeEffect is unattributed here, so the attacker is in
            -- the entity query. Apply that exact center-point vertical impulse
            -- explicitly and keep the generic pass for every other entity.
            ignoreEntity = owner,
            knockbackMultiplier = multiplier,
            context = { kind = "mace_wind_burst", enchantmentLevel = level },
        })
    end
    local ownerVelocity = launchWindBurstOwner(position, owner, level, multiplier)
    if MCITEM.Throwables and isfunction(MCITEM.Throwables.PlayWindBurst) then
        MCITEM.Throwables.PlayWindBurst(position)
    end
    if MCITEM.Throwables and MCITEM.Throwables.FX
        and isfunction(MCITEM.Throwables.BroadcastFX) then
        MCITEM.Throwables.BroadcastFX(MCITEM.Throwables.FX.WIND_BURST, position)
    end
    hook.Run("MCITEM.MaceWindBurst", owner, target, position, level, multiplier, ownerVelocity)
end

local function installTableFunction(tableValue, key, token, wrapperFactory)
    if not istable(tableValue) or not isfunction(tableValue[key]) then return false end
    local current = tableValue[key]
    local savedWrapper = Runtime.Wrappers[token]
    if current == savedWrapper then
        if Runtime.WrapperGenerations[token] == LOAD_GENERATION then return true end
        current = Runtime.Originals[token]
        if not isfunction(current) then return false end
    end
    Runtime.Originals[token] = current
    savedWrapper = wrapperFactory(token)
    Runtime.Wrappers[token] = savedWrapper
    Runtime.WrapperGenerations[token] = LOAD_GENERATION
    tableValue[key] = savedWrapper
    return true
end

local function storedEntity(className)
    local value = scripted_ents.GetStored(className)
    return value and value.t or nil
end

local function storedWeapon(className)
    return weapons and weapons.GetStored and weapons.GetStored(className) or nil
end

local function entityIsFlying(entity)
    if not IsValid(entity) then return true end
    local overridden = hook.Run("MCITEM.IsEntityFlying", entity, "wind_burst")
    if overridden ~= nil then return overridden == true end
    if isfunction(entity.IsMCFlying) then
        local result = entity:IsMCFlying()
        if result ~= nil then return result == true end
    end
    local moveType = isfunction(entity.GetMoveType) and entity:GetMoveType() or nil
    return moveType == MOVETYPE_FLY
        or moveType == MOVETYPE_FLYGRAVITY
        or moveType == MOVETYPE_NOCLIP
end

Runtime.IsFlyingForWindBurst = entityIsFlying

local function installSpawnArrow()
    if not MCITEM or not isfunction(MCITEM.SpawnArrow) then return false end
    local token = "MCITEM.SpawnArrow"
    local current = MCITEM.SpawnArrow
    if current == Runtime.Wrappers[token] then
        if Runtime.WrapperGenerations[token] == LOAD_GENERATION then return true end
        current = Runtime.Originals[token]
        if not isfunction(current) then return false end
    end
    Runtime.Originals[token] = current
    local wrapper = function(owner, weapon, ...)
        local stack = Runtime.StackForWeapon(weapon, owner)
        local arrow = Runtime.Originals[token](owner, weapon, ...)
        if IsValid(arrow) then
            local carriedStack = projectileStack(arrow)
            -- The concrete SpawnArrow boundary may already have frozen an
            -- explicit pre-commit firing stack (for example a charged
            -- crossbow or a mob bridge).  Never replace that exact snapshot
            -- with a later selected-slot read from this compatibility wrapper.
            if not istable(carriedStack) and istable(stack) then
                arrow.MCEnchantmentStack = table.Copy(stack)
                carriedStack = arrow.MCEnchantmentStack
            end
            local piercing = isfunction(Runtime.GetPiercingLevel)
                and Runtime.GetPiercingLevel(carriedStack) or 0
            arrow.MCPierceLevel = math.max(0, math.floor(tonumber(piercing) or 0))
            arrow.MCShieldBypass = arrow.MCPierceLevel > 0
            if Runtime.GetEnchantmentLevel(carriedStack, "flame") > 0 then
                arrow.MCFlameArrow = true
                arrow.MCFlameArrowUntil = CurTime() + 100
                arrow:SetNW2Bool("MCITEM_FlameArrow", true)
                arrow:SetNW2Float("MCITEM_FlameArrowUntil", arrow.MCFlameArrowUntil)
            end
        end
        return arrow
    end
    Runtime.Wrappers[token] = wrapper
    Runtime.WrapperGenerations[token] = LOAD_GENERATION
    MCITEM.SpawnArrow = wrapper
    return true
end

local function installArrow()
    local arrow = storedEntity("mcitem_arrow")
    return installTableFunction(arrow, "HitEntity", "mcitem_arrow.HitEntity", function(token)
        return function(self, target, ...)
            local flameUntil = tonumber(self.MCFlameArrowUntil) or
                (self.GetNW2Float and self:GetNW2Float("MCITEM_FlameArrowUntil", 0) or 0)
            local flameActive = flameUntil > CurTime()
                or (flameUntil <= 0 and (self.MCFlameArrow
                    or (self.GetNW2Bool and self:GetNW2Bool("MCITEM_FlameArrow", false))))
            self.MCLastHitAccepted = false
            local results = { Runtime.Originals[token](self, target, ...) }
            local accepted = self.MCLastHitAccepted == true
            -- Java saves and restores the exact remaining fire ticks when hurt
            -- rejects the hit. Source exposes no remaining-fire timer, so the
            -- transaction-safe adaptation is to ignite only after acceptance.
            if flameActive and accepted then igniteEntity(target, 5) end
            return unpack(results)
        end
    end)
end

local function installTrident()
    local trident = storedEntity("mcitem_trident")
    local hitEntity = installTableFunction(trident, "HitEntity", "mcitem_trident.HitEntity", function(token)
        return function(self, target, trace, ...)
            self.MCLastHitAccepted = false
            local results = { Runtime.Originals[token](self, target, trace, ...) }
            if self.MCLastHitAccepted == true then
                tryChannelEntity(self, target, trace)
            end
            return unpack(results)
        end
    end)
    local hitWorld = installTableFunction(trident, "HitWorld", "mcitem_trident.HitWorld", function(token)
        return function(self, trace, ...)
            local results = { Runtime.Originals[token](self, trace, ...) }
            tryChannelWorld(self, trace)
            return unpack(results)
        end
    end)
    return hitEntity and hitWorld
end

local function installMace()
    local mace = storedWeapon("weapon_mcitem_mace")
    if not mace then return false end
    local bonusInstalled = installTableFunction(mace, "MCGetAttackDamageBonus",
        "weapon_mcitem_mace.MCGetAttackDamageBonus", function(token)
        return function(self, owner, target, damage, charge, ...)
            local baseBonus, context = Runtime.Originals[token](self, owner, target, damage, charge, ...)
            context = istable(context) and context or nil
            local fallDistance = context and tonumber(context.fallDistance)
                or tonumber(self.MCFallDistance) or 0
            local stack = Runtime.StackForWeapon(self, owner)
            local density = Runtime.GetEnchantmentLevel(stack, "density")
            if context and fallDistance > 1.5 and density > 0 then
                baseBonus = (tonumber(baseBonus) or 0) + fallDistance * 0.5 * density
            end
            if SERVER then
                local active = {
                    weapon = self,
                    owner = owner,
                    target = target,
                    stack = stack,
                    breach = Runtime.GetEnchantmentLevel(stack, "breach"),
                    density = density,
                    windBurst = Runtime.GetEnchantmentLevel(stack, "wind_burst"),
                    fallDistance = fallDistance,
                    flying = entityIsFlying(owner),
                    smash = fallDistance >= 1.5,
                }
                active.attackContext = context
                if istable(context) then context[MACE_CONTEXT_KEY] = active end
                local contexts = Runtime.ActiveMaceContexts[target]
                if not contexts then
                    contexts = {}
                    Runtime.ActiveMaceContexts[target] = contexts
                end
                contexts[#contexts + 1] = active
                Runtime.ActiveMaceContext = active
                timer.Simple(0, function()
                    if active.damageTransaction then
                        removeMaceDamageTransaction(active.damageTransaction)
                    end
                    local current = Runtime.ActiveMaceContexts[target]
                    if not current then return end
                    for index = #current, 1, -1 do
                        if current[index] == active then
                            table.remove(current, index)
                            break
                        end
                    end
                    if #current == 0 then Runtime.ActiveMaceContexts[target] = nil end
                    if Runtime.ActiveMaceContext == active then Runtime.ActiveMaceContext = nil end
                end)
            end
            return baseBonus, context
        end
    end)
    local postInstalled = installTableFunction(mace, "MCPostAttack", "weapon_mcitem_mace.MCPostAttack", function(token)
        return function(self, owner, target, context, actualDamage, accepted, ...)
            local active
            if SERVER then
                local explicit = istable(context) and context[MACE_CONTEXT_KEY] or nil
                if explicit and explicit.target == target and explicit.owner == owner
                    and explicit.weapon == self then
                    active = explicit
                end
                local contexts = Runtime.ActiveMaceContexts[target]
                if not active then
                    for index = contexts and #contexts or 0, 1, -1 do
                        local candidate = contexts[index]
                        if candidate.weapon == self and candidate.owner == owner then
                            active = candidate
                            break
                        end
                    end
                end
                if active and contexts then
                    for index = #contexts, 1, -1 do
                        if contexts[index] == active then
                            table.remove(contexts, index)
                            break
                        end
                    end
                end
                if contexts and #contexts == 0 then Runtime.ActiveMaceContexts[target] = nil end
            end
            local results = { Runtime.Originals[token](self, owner, target, context, actualDamage, accepted, ...) }
            if active and active.weapon == self and active.smash and not active.flying
                and active.windBurst > 0
                and (accepted == true or (tonumber(actualDamage) or 0) > 0) and IsValid(owner) then
                windBurst(owner:GetPos(), owner, target, active.windBurst)
            end
            if active and active.damageTransaction then
                removeMaceDamageTransaction(active.damageTransaction)
            end
            if Runtime.ActiveMaceContext == active then Runtime.ActiveMaceContext = nil end
            return unpack(results)
        end
    end)
    return bonusInstalled and postInstalled
end

local function installArmor()
    if not SERVER then return false end
    if not MC or not isfunction(MC.ArmorDamageAfterAbsorb) then return false end
    local token = "MC.ArmorDamageAfterAbsorb"
    local current = MC.ArmorDamageAfterAbsorb
    if current == Runtime.Wrappers[token] then
        if Runtime.WrapperGenerations[token] == LOAD_GENERATION then return true end
        current = Runtime.Originals[token]
        if not isfunction(current) then return false end
    end
    Runtime.Originals[token] = current
    local wrapper = function(damage, armor, toughness, target, damageInfo, metadata, ...)
        local originalResult = Runtime.Originals[token](damage, armor, toughness, target, damageInfo, metadata, ...)
        local transaction = Runtime.ResolveMaceDamageTransaction(target, damageInfo)
        if not transaction then return originalResult end
        local breach = transaction and positiveLevel(transaction.active and transaction.active.breach) or 0
        -- CombatRules computes an armor-effectiveness fraction, lets Breach
        -- subtract 0.15 per level from that fraction, clamps it, then applies
        -- the remaining fraction to the incoming damage. Every bound MCITEM
        -- mace hit (including level-zero Breach) reaches this function with
        -- Source-scaled damage, so do the whole vanilla armor calculation in
        -- MC units before applying the optional enchantment modifier.
        local minecraftDamage = isfunction(MCITEM.UnscaleDamage) and MCITEM.UnscaleDamage(damage) or damage
        if minecraftDamage <= 0 then return originalResult end
        local minecraftArmor = math.Clamp(tonumber(armor) or 0, 0, 20)
        local minecraftToughness = math.max(0, tonumber(toughness) or 0)
        local toughnessScale = 2 + minecraftToughness / 4
        local effectiveArmor = math.Clamp(
            minecraftArmor - minecraftDamage / toughnessScale,
            minecraftArmor * 0.2,
            20
        )
        local baseEffectiveness = effectiveArmor / 25
        local modifiedEffectiveness = math.Clamp(baseEffectiveness - 0.15 * math.min(breach, 4), 0, 1)
        local breached = minecraftDamage * (1 - modifiedEffectiveness)
        return isfunction(MCITEM.ScaleDamage) and MCITEM.ScaleDamage(breached) or breached
    end
    Runtime.Wrappers[token] = wrapper
    Runtime.WrapperGenerations[token] = LOAD_GENERATION
    MC.ArmorDamageAfterAbsorb = wrapper
    return true
end

function Runtime.Install()
    local installed = installSpawnArrow()
    installed = installArrow() or installed
    installed = installTrident() or installed
    installed = installMace() or installed
    installed = installArmor() or installed
    return installed
end

timer.Simple(0, Runtime.Install)
hook.Remove("InitPostEntity", "MCITEM.EnchantmentRuntime.Install")
hook.Add("InitPostEntity", "MCITEM.EnchantmentRuntime.Install", Runtime.Install)
hook.Remove("OnReloaded", "MCITEM.EnchantmentRuntime.Install")
hook.Add("OnReloaded", "MCITEM.EnchantmentRuntime.Install", Runtime.Install)
hook.Remove("MC.APIReady", "MCITEM.EnchantmentRuntime.Install")
hook.Add("MC.APIReady", "MCITEM.EnchantmentRuntime.Install", Runtime.Install)

if SERVER then
    local function windBurstImpulseState(playerEntity)
        if not IsValid(playerEntity) or not playerEntity:IsPlayer() then return nil end
        return Runtime.WindBurstImpulseStates[playerEntity]
    end

    local function clearWindBurstImpulse(playerEntity, expected)
        if Runtime.WindBurstImpulseStates[playerEntity] == expected then
            Runtime.WindBurstImpulseStates[playerEntity] = nil
        end
    end

    local function clearWindBurstImpulseAfterLanding(playerEntity)
        local state = windBurstImpulseState(playerEntity)
        if not state or state.clearScheduled then return end
        state.clearScheduled = true
        timer.Simple(0, function()
            if Runtime.WindBurstImpulseStates[playerEntity] ~= state then return end
            -- A smash can touch a collision surface in the same tick that the
            -- upward impulse is applied. Only consume the protection once the
            -- player is still grounded on the following server frame.
            if IsValid(playerEntity) and not playerEntity:IsOnGround() then
                state.clearScheduled = nil
                return
            end
            clearWindBurstImpulse(playerEntity, state)
        end)
    end

    hook.Remove("GetFallDamage", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("GetFallDamage", "MCITEM.Enchantments.WindBurstImpulse", function(playerEntity)
        if not windBurstImpulseState(playerEntity) then return end
        clearWindBurstImpulseAfterLanding(playerEntity)
        return 0
    end)

    hook.Remove("OnPlayerHitGround", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("OnPlayerHitGround", "MCITEM.Enchantments.WindBurstImpulse", function(playerEntity)
        clearWindBurstImpulseAfterLanding(playerEntity)
    end)

    hook.Remove("SetupMove", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("SetupMove", "MCITEM.Enchantments.WindBurstImpulse", function(playerEntity)
        local state = windBurstImpulseState(playerEntity)
        if not state then return end
        if not playerEntity:IsOnGround() then
            state.airborne = true
        elseif state.airborne then
            clearWindBurstImpulseAfterLanding(playerEntity)
        end
    end)

    -- GetFallDamage is the normal Source path. Keep this defensive boundary for
    -- gamemodes/addons that construct DMG_FALL directly.
    hook.Remove("EntityTakeDamage", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("EntityTakeDamage", "MCITEM.Enchantments.WindBurstImpulse", function(target, damageInfo)
        if not windBurstImpulseState(target) or not damageInfo
            or not damageInfo.IsDamageType or not damageInfo:IsDamageType(DMG_FALL) then return end
        damageInfo:SetDamage(0)
        if damageInfo.SetDamageForce then damageInfo:SetDamageForce(vector_origin) end
        clearWindBurstImpulseAfterLanding(target)
        return true
    end)

    local function forgetWindBurstImpulse(playerEntity)
        Runtime.WindBurstImpulseStates[playerEntity] = nil
    end
    hook.Remove("PlayerSpawn", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("PlayerSpawn", "MCITEM.Enchantments.WindBurstImpulse", forgetWindBurstImpulse)
    hook.Remove("PlayerDeath", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("PlayerDeath", "MCITEM.Enchantments.WindBurstImpulse", forgetWindBurstImpulse)
    hook.Remove("PlayerDisconnected", "MCITEM.Enchantments.WindBurstImpulse")
    hook.Add("PlayerDisconnected", "MCITEM.Enchantments.WindBurstImpulse", forgetWindBurstImpulse)

    -- MineMod already owns the vanilla 0.2 submerged-mining attribute. Aqua
    -- Affinity sets that attribute to 1.0; it does not remove the airborne /5.
    hook.Remove("MC.PlayerMiningModifiers", "MCITEM.Enchantments.AquaAffinity")
    hook.Add("MC.PlayerMiningModifiers", "MCITEM.Enchantments.AquaAffinity",
        function(playerEntity)
            if isfunction(Runtime.GetEquipmentLevel)
                and Runtime.GetEquipmentLevel(playerEntity, "head", "aqua_affinity") > 0 then
                return { submergedMiningSpeed = 1 }
            end
        end)

    for _, path in ipairs(LIGHTNING_THUNDER) do resource.AddFile("sound/" .. path) end
    for _, path in ipairs(LIGHTNING_IMPACT) do resource.AddFile("sound/" .. path) end
    for _, path in ipairs(TRIDENT_THUNDER) do resource.AddFile("sound/" .. path) end
    for _, path in ipairs(SOUL_SPEED_ESCAPE) do resource.AddFile("sound/" .. path) end
end
