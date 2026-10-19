-- Server-side passive and transaction-adjacent enchantment effects for
-- Minecraft Java 26.2.  Inventory mutations go through MCSWEP's public API or
-- generic hooks so the complete ItemStack remains authoritative.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.EnchantmentRuntime = MCITEM.EnchantmentRuntime or {}

local Runtime = MCITEM.EnchantmentRuntime
local TICK_SECONDS = 1 / 20
local ARMOR_SLOTS = { "head", "chest", "legs", "feet" }
local SOUL_BLOCKS = {
    ["minecraft:soul_sand"] = true,
    ["minecraft:soul_soil"] = true,
}
local FROST_DIRECTIONS = {
    { 1, 0, 0 }, { -1, 0, 0 },
    { 0, 1, 0 }, { 0, -1, 0 },
    { 0, 0, 1 }, { 0, 0, -1 },
}
local FROSTED_ICE_LIGHT_DAMPENING = 1
local BURN_FROM_STEPPING = {
    ["minecraft:campfire"] = true,
    ["minecraft:hot_floor"] = true,
    ["minecraft:sulfur_cube_hot"] = true,
}

Runtime.ThornsGuard = Runtime.ThornsGuard or setmetatable({}, { __mode = "k" })
Runtime.PlayerLocationState = Runtime.PlayerLocationState or setmetatable({}, { __mode = "k" })
Runtime.FrostedIceTimers = Runtime.FrostedIceTimers or {}
Runtime.FrostedIceInternalWrites = Runtime.FrostedIceInternalWrites or {}
Runtime.RiptideStates = Runtime.RiptideStates or setmetatable({}, { __mode = "k" })

local function level(stack, enchantmentId)
    return math.max(0, math.floor(tonumber(Runtime.GetEnchantmentLevel(stack, enchantmentId)) or 0))
end

local function inventoryApi()
    return MC and MC.API and MC.API.Inventory or nil
end

local function blockSize()
    return isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
end

local function damageType(damageInfo, flag)
    return flag ~= nil and damageInfo and isfunction(damageInfo.IsDamageType)
        and damageInfo:IsDamageType(flag) == true
end

local function living(entity)
    return IsValid(entity) and not entity:IsWorld()
        and (entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true)
end

local function damageEquipment(playerEntity, slot, amount, context)
    local inventory = inventoryApi()
    if inventory and isfunction(inventory.DamageEquipment) then
        local result, broken = inventory.DamageEquipment(playerEntity, slot, amount, context or {})
        return result ~= nil, broken == true
    end
    local handled, broken = hook.Run(
        "MCITEM.DamageEquipmentDurability", playerEntity, slot, amount, context or {})
    if handled ~= nil then return handled ~= false, broken == true end
    return false, false
end

local function equipmentStacks(playerEntity)
    local stacks = {}
    for _, slot in ipairs(ARMOR_SLOTS) do
        local stack = Runtime.GetEquipmentStack(playerEntity, slot)
        if stack then stacks[#stacks + 1] = { slot = slot, stack = stack } end
    end
    return stacks
end

local function isProjectileDamage(damageInfo)
    if damageType(damageInfo, DMG_BULLET) or damageType(damageInfo, DMG_BUCKSHOT) then return true end
    local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
    return IsValid(inflictor) and (inflictor.MCProjectile == true or inflictor.MCShieldProjectile == true)
end

local function protectionPoints(playerEntity, damageInfo)
    local points = Runtime.GetArmorEnchantmentTotal(playerEntity, "protection")
    if damageType(damageInfo, DMG_FALL) then
        points = points + Runtime.GetArmorEnchantmentTotal(playerEntity, "feather_falling") * 3
    elseif damageType(damageInfo, DMG_BURN) or damageType(damageInfo, DMG_SLOWBURN) then
        points = points + Runtime.GetArmorEnchantmentTotal(playerEntity, "fire_protection") * 2
    elseif isProjectileDamage(damageInfo) then
        points = points + Runtime.GetArmorEnchantmentTotal(playerEntity, "projectile_protection") * 2
    end
    return math.Clamp(points, 0, 20)
end

-- Java 26.2 LivingEntity.igniteForTicks first applies the BURNING_TIME
-- attribute, then ceils the scaled tick count. Entity.igniteForTicks only
-- extends an existing fire, so callers must apply this modifier before their
-- normal Source/BMB ignition write instead of trying to rewrite an active
-- Source fire clock afterwards.
local function fireProtectionBurningTime(target, seconds, context)
    if not IsValid(target) or not target:IsPlayer() then return end
    if istable(context) and context.mcitemFireProtectionBurningTimeApplied == true then return end
    local fireProtection = Runtime.GetArmorEnchantmentTotal(target, "fire_protection")
    if fireProtection <= 0 then return end
    if istable(context) then context.mcitemFireProtectionBurningTimeApplied = true end
    local requestedTicks = math.max(0, math.floor((tonumber(seconds) or 0) * 20))
    local multiplier = math.max(0, 1 - 0.15 * fireProtection)
    return math.ceil(requestedTicks * multiplier) / 20
end

hook.Remove("MC.ModifyEntityIgnitionDuration", "MCITEM.Enchantments.FireProtectionBurningTime")
hook.Add("MC.ModifyEntityIgnitionDuration", "MCITEM.Enchantments.FireProtectionBurningTime",
    fireProtectionBurningTime)

-- MCSWEP's public ignition event is also used by projectiles and block contact
-- for ordinary Source entities.  Consume that boundary here so an already
-- burning entity can use the readable entityflame deadline instead of falling
-- back to Source's CBaseAnimating::Ignite no-op.  BMB owns its own fire clock;
-- leave those entities to the BMB listener and never compose two clocks.
hook.Remove("MC.IgniteEntity", "MCITEM.Enchantments.SourceIgnition")
hook.Add("MC.IgniteEntity", "MCITEM.Enchantments.SourceIgnition",
    function(target, seconds)
        if not IsValid(target) or target.IsBMBMob == true then return end
        if not isfunction(target.Ignite) then return end
        return Runtime.ApplySourceIgnition(target, seconds) == true
    end)

local function triggerThorns(victim, attacker)
    if not living(victim) or not living(attacker) or victim == attacker or Runtime.ThornsGuard[victim] then return end
    for _, entry in ipairs(equipmentStacks(victim)) do
        local thorns = level(entry.stack, "thorns")
        if thorns > 0 and math.Rand(0, 1) < math.min(1, 0.15 * thorns) then
            local damageInfo = DamageInfo()
            damageInfo:SetAttacker(victim)
            damageInfo:SetInflictor(victim)
            damageInfo:SetDamage(isfunction(MCITEM.ScaleDamage)
                and MCITEM.ScaleDamage(math.random(1, 5)) or math.random(1, 5))
            damageInfo:SetDamageType(DMG_SLASH)
            damageInfo:SetDamagePosition(attacker:WorldSpaceCenter())
            local previousGuard = Runtime.ThornsGuard[attacker]
            Runtime.ThornsGuard[attacker] = true
            local ok, err = pcall(attacker.TakeDamageInfo, attacker, damageInfo)
            Runtime.ThornsGuard[attacker] = previousGuard
            if not ok then error(err, 0) end
            damageEquipment(victim, entry.slot, 2, {
                reason = "thorns",
                attacker = attacker,
                enchantment = "minecraft:thorns",
            })
        end
    end
end

local function applyFrostWalkerSteppingImmunity(target, damageInfo, metadata)
    if not IsValid(target) or not target:IsPlayer() or not damageInfo then return false end
    if Runtime.GetEquipmentLevel(target, "feet", "frost_walker") <= 0 then return false end
    if not istable(metadata) or metadata.bypassesInvulnerability == true then return false end
    local sourceId = tostring(metadata.damageTypeId or metadata.MCDamageTypeID or "")
    if BURN_FROM_STEPPING[sourceId] ~= true then return false end
    damageInfo:SetDamage(0)
    metadata.enchantmentImmunity = "minecraft:frost_walker"
    return true
end

hook.Remove("MCITEM.DamageBeforeEquipmentMitigation", "MCITEM.Enchantments.FrostWalkerImmunity")
hook.Add("MCITEM.DamageBeforeEquipmentMitigation", "MCITEM.Enchantments.FrostWalkerImmunity",
    function(target, damageInfo, metadata)
        -- hook.Run stops on false too. Non-applicable immunity must let the
        -- other before-armor listeners (including Strength/Weakness) run.
        if applyFrostWalkerSteppingImmunity(target, damageInfo, metadata) then return true end
    end)

hook.Remove("MCITEM.DamageAfterEquipmentMitigation", "MCITEM.Enchantments.PassiveProtection")
hook.Add("MCITEM.DamageAfterEquipmentMitigation", "MCITEM.Enchantments.PassiveProtection",
    function(target, damageInfo, metadata)
        if not IsValid(target) or not target:IsPlayer() or not damageInfo then return end
        -- Compatibility fallback for older mc_game builds without the early
        -- mitigation hook.  Current builds stop this damage before armor wear.
        if applyFrostWalkerSteppingImmunity(target, damageInfo, metadata) then return end

        -- The mc_game explosion adapter already combines Protection and Blast
        -- Protection at this exact post-armor boundary.  Do not apply it twice.
        if not damageType(damageInfo, DMG_BLAST) then
            local points = protectionPoints(target, damageInfo)
            if points > 0 then
                damageInfo:SetDamage(math.max(0, damageInfo:GetDamage()) * (1 - points / 25))
            end
        end

        if damageInfo:GetDamage() <= 0 then return end
        local attacker = damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
        if living(attacker) and attacker ~= target and not Runtime.ThornsGuard[target] then
            timer.Simple(0, function()
                if IsValid(target) and IsValid(attacker) then triggerThorns(target, attacker) end
            end)
        end
    end)

hook.Remove("MC.ModifyItemDurabilityDamage", "MCITEM.Enchantments.Unbreaking")
hook.Add("MC.ModifyItemDurabilityDamage", "MCITEM.Enchantments.Unbreaking",
    function(_playerEntity, stack, amount, context)
        amount = math.max(0, math.floor(tonumber(amount) or 0))
        local unbreaking = level(stack, "unbreaking")
        if amount <= 0 or unbreaking <= 0 then return amount end
        local armor = istable(context) and context.isArmor == true
        if not armor and MC and isfunction(MC.ItemEquipmentSlot) then
            local slot = MC.ItemEquipmentSlot(stack)
            armor = slot ~= nil and slot ~= "offhand"
        end
        local ignoreChance = armor
            and (0.4 * unbreaking / (unbreaking + 1))
            or (unbreaking / (unbreaking + 1))
        local applied = 0
        for _ = 1, amount do
            if math.Rand(0, 1) >= ignoreChance then applied = applied + 1 end
        end
        return applied
    end)

hook.Remove("MC.CanTakeEquipmentStack", "MCITEM.Enchantments.BindingCurse")
hook.Add("MC.CanTakeEquipmentStack", "MCITEM.Enchantments.BindingCurse",
    function(playerEntity, _slot, stack)
        if not IsValid(playerEntity) then return end
        if level(stack, "binding_curse") <= 0 then return end
        if MCITEM.HasInfiniteMaterials and MCITEM.HasInfiniteMaterials(playerEntity) then return true end
        return false
    end)

hook.Remove("MC.ShouldDropItemStackOnDeath", "MCITEM.Enchantments.VanishingCurse")
hook.Add("MC.ShouldDropItemStackOnDeath", "MCITEM.Enchantments.VanishingCurse",
    function(_playerEntity, stack)
        if level(stack, "vanishing_curse") > 0 then return false end
    end)

local function engineToCell(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if not coords or not isfunction(coords.EngineToCell) then return nil end
    local ok, bx, by, bz = pcall(coords.EngineToCell, position, context)
    if not ok then return nil end
    return bx, by, bz
end

local function blockName(info)
    if not istable(info) then return "minecraft:air" end
    local value = tostring(info.name or info.mcid or "minecraft:air")
    return string.find(value, ":", 1, true) and value or "minecraft:" .. value
end

local function blockAt(bx, by, bz)
    local world = MC and MC.API and MC.API.World
    return world and isfunction(world.GetBlockInfo) and world.GetBlockInfo(bx, by, bz) or nil
end

local function cellKey(bx, by, bz)
    return tostring(bx) .. ":" .. tostring(by) .. ":" .. tostring(bz)
end

local function blockStateName(stateId)
    local blocks = MC and MC.API and MC.API.Blocks
    if not blocks or not isfunction(blocks.Name) then return nil end
    local name = blocks.Name(math.floor(tonumber(stateId) or 0))
    return name and blockName({ name = name }) or nil
end

local function frostedAge(info)
    if blockName(info) ~= "minecraft:frosted_ice" then return nil end
    local blocks = MC and MC.API and MC.API.Blocks
    local ageValue
    if istable(info) and info.stateId and blocks and isfunction(blocks.GetProperty) then
        ageValue = blocks.GetProperty(info.stateId, "age")
    end
    if ageValue == nil and istable(info) then ageValue = info.age end
    if ageValue == nil and istable(info) then
        ageValue = tostring(info.spec or ""):match("age=(%d+)")
    end
    return math.Clamp(math.floor(tonumber(ageValue) or 0), 0, 3)
end

local function frostedNeighborCount(bx, by, bz)
    local count = 0
    for _, offset in ipairs(FROST_DIRECTIONS) do
        if blockName(blockAt(bx + offset[1], by + offset[2], bz + offset[3]))
            == "minecraft:frosted_ice" then
            count = count + 1
        end
    end
    return count
end

local function localRawBrightness(bx, by, bz)
    local light = MC and MC.API and MC.API.Light
    if not light or not isfunction(light.SampleCell) then return 15 end
    local _, sampledLevel, blockLight, skyLight = light.SampleCell(bx, by, bz, 0)
    if sampledLevel == nil then return 15 end
    blockLight = math.Clamp(math.floor(tonumber(blockLight) or 0), 0, 15)
    skyLight = math.Clamp(math.floor(tonumber(skyLight) or 0), 0, 15)
    local dayCycle = MC and MC.API and MC.API.DayCycle
    if dayCycle and isfunction(dayCycle.SkyLevel) then
        skyLight = math.min(skyLight,
            math.Clamp(math.floor(tonumber(dayCycle.SkyLevel()) or 15), 0, 15))
    end
    return math.max(blockLight, skyLight)
end

local function setFrostedRuntimeBlock(bx, by, bz, state, options)
    local world = MC and MC.API and MC.API.World
    if not world or not isfunction(world.SetBlock) then return false end
    local key = cellKey(bx, by, bz)
    Runtime.FrostedIceInternalWrites[key] = (Runtime.FrostedIceInternalWrites[key] or 0) + 1
    local ok, changed = pcall(world.SetBlock, bx, by, bz, state, options or {})
    local remaining = (Runtime.FrostedIceInternalWrites[key] or 1) - 1
    Runtime.FrostedIceInternalWrites[key] = remaining > 0 and remaining or nil
    return ok and changed == true
end

local function playerGroundCell(playerEntity)
    return engineToCell(playerEntity:GetPos() - Vector(0, 0, 1), playerEntity)
end

local function playerInWater(playerEntity)
    local api = MC and MC.API or nil
    local coords = api and api.Coords or nil
    local liquid = api and api.Liquid or nil
    if coords and isfunction(coords.EntityWorldPos)
        and liquid and isfunction(liquid.AtPos) then
        local positionOK, position = pcall(coords.EntityWorldPos, playerEntity)
        if positionOK and isvector(position) then
            local liquidOK, contact = pcall(liquid.AtPos, position)
            local kind = liquidOK and istable(contact) and tostring(contact.kind or "") or ""
            if kind == "water" or kind == "minecraft:water" then return true end
        end
    end
    return isfunction(playerEntity.WaterLevel) and playerEntity:WaterLevel() >= 2
end

local tickFrostedIce
local meltFrostedIce

local function scheduleFrostedIce(bx, by, bz, firstTick)
    local key = cellKey(bx, by, bz)
    if Runtime.FrostedIceTimers[key] then return false end
    local token = {}
    Runtime.FrostedIceTimers[key] = token
    local minimum, maximum = firstTick and 60 or 20, firstTick and 120 or 40
    timer.Simple(math.Rand(minimum, maximum) * TICK_SECONDS, function()
        if Runtime.FrostedIceTimers[key] ~= token then return end
        Runtime.FrostedIceTimers[key] = nil
        tickFrostedIce(bx, by, bz)
    end)
    return true
end

local function meltSparseFrostedNeighbours(bx, by, bz, visited)
    for _, offset in ipairs(FROST_DIRECTIONS) do
        local x, y, z = bx + offset[1], by + offset[2], bz + offset[3]
        if blockName(blockAt(x, y, z)) == "minecraft:frosted_ice"
            and frostedNeighborCount(x, y, z) < 2 then
            meltFrostedIce(x, y, z, visited)
        end
    end
end

meltFrostedIce = function(bx, by, bz, visited)
    visited = visited or {}
    local key = cellKey(bx, by, bz)
    if visited[key] then return false end
    visited[key] = true
    Runtime.FrostedIceTimers[key] = nil
    if blockName(blockAt(bx, by, bz)) ~= "minecraft:frosted_ice" then return false end
    local changed = setFrostedRuntimeBlock(bx, by, bz, "minecraft:water[level=0]", {
        fx = true,
        blockUpdates = true,
    })
    if changed then meltSparseFrostedNeighbours(bx, by, bz, visited) end
    return changed
end

local function slightlyMeltFrostedIce(bx, by, bz, info)
    info = info or blockAt(bx, by, bz)
    local ageValue = frostedAge(info)
    if ageValue == nil then return false, false end
    if ageValue >= 3 then return meltFrostedIce(bx, by, bz), true end
    local changed = setFrostedRuntimeBlock(bx, by, bz,
        "minecraft:frosted_ice[age=" .. (ageValue + 1) .. "]", {
            fx = true,
            blockUpdates = false,
        })
    return changed, false
end

tickFrostedIce = function(bx, by, bz)
    local info = blockAt(bx, by, bz)
    local ageValue = frostedAge(info)
    if ageValue == nil then return end

    local canAge = (math.random(0, 2) == 0 or frostedNeighborCount(bx, by, bz) < 4)
        and localRawBrightness(bx, by, bz)
            > 11 - ageValue - FROSTED_ICE_LIGHT_DAMPENING
    if not canAge then
        scheduleFrostedIce(bx, by, bz, false)
        return
    end

    local _, melted = slightlyMeltFrostedIce(bx, by, bz, info)
    if not melted then
        scheduleFrostedIce(bx, by, bz, false)
        return
    end

    -- FrostedIceBlock.tick pushes all six surviving neighbours forward after
    -- an age-3 block melts.  Neighbours that merely age receive their own
    -- Java 20-40 tick follow-up; neighbours that melt can cascade sparsity.
    for _, offset in ipairs(FROST_DIRECTIONS) do
        local x, y, z = bx + offset[1], by + offset[2], bz + offset[3]
        local neighbour = blockAt(x, y, z)
        if frostedAge(neighbour) ~= nil then
            local _, neighbourMelted = slightlyMeltFrostedIce(x, y, z, neighbour)
            if not neighbourMelted then scheduleFrostedIce(x, y, z, false) end
        end
    end
end

hook.Remove("MC.BlocksChanged", "MCITEM.Enchantments.FrostedIceNeighbours")
hook.Add("MC.BlocksChanged", "MCITEM.Enchantments.FrostedIceNeighbours", function(changes)
    local blocks = MC and MC.API and MC.API.Blocks
    if not istable(changes) or not blocks or not isfunction(blocks.Name) then return end
    for _, change in ipairs(changes) do
        local bx = math.floor(tonumber(change.bx or change[1]) or 0)
        local by = math.floor(tonumber(change.by or change[2]) or 0)
        local bz = math.floor(tonumber(change.bz or change[3]) or 0)
        local key = cellKey(bx, by, bz)
        if not Runtime.FrostedIceInternalWrites[key] then
            local nextName = blockStateName(change.stateId or change[4])
            local oldName = blockStateName(change.oldStateId or change[5])
            if oldName == "minecraft:frosted_ice" and nextName ~= oldName then
                Runtime.FrostedIceTimers[key] = nil
                meltSparseFrostedNeighbours(bx, by, bz, {})
            elseif nextName == "minecraft:frosted_ice" and oldName ~= nextName then
                scheduleFrostedIce(bx, by, bz, true)
            elseif nextName ~= "minecraft:frosted_ice" then
                Runtime.FrostedIceTimers[key] = nil
            end
        end
    end
end)

local function clearFrostedIceRuntime()
    Runtime.FrostedIceTimers = {}
    Runtime.FrostedIceInternalWrites = {}
end
hook.Remove("MC.WorldCleared", "MCITEM.Enchantments.FrostedIceReset")
hook.Add("MC.WorldCleared", "MCITEM.Enchantments.FrostedIceReset", clearFrostedIceRuntime)
hook.Remove("MC.PreWorldLoad", "MCITEM.Enchantments.FrostedIceReset")
hook.Add("MC.PreWorldLoad", "MCITEM.Enchantments.FrostedIceReset", clearFrostedIceRuntime)

local function applyFrostWalker(playerEntity, levelValue, bx, by, bz)
    if levelValue <= 0 or playerEntity:InVehicle() or not playerEntity:IsOnGround() then return end
    local world = MC and MC.API and MC.API.World
    if not world or not isfunction(world.SetBlock) then return end
    local radius = math.min(16, 2 + levelValue)
    for dx = -radius, radius do
        for dy = -radius, radius do
            if dx * dx + dy * dy <= radius * radius then
                local x, y, z = bx + dx, by + dy, bz - 1
                if blockName(blockAt(x, y, z)) == "minecraft:water"
                    and blockName(blockAt(x, y, z + 1)) == "minecraft:air" then
                    local changed = setFrostedRuntimeBlock(x, y, z,
                        "minecraft:frosted_ice[age=0]", {
                        actor = playerEntity,
                        fx = true,
                        blockUpdates = true,
                        preventPlayerOverlap = true,
                    })
                    if changed == true then scheduleFrostedIce(x, y, z, true) end
                end
            end
        end
    end
end

local function updateLocationEffects(playerEntity, now)
    local state = Runtime.PlayerLocationState[playerEntity] or {}
    if state.nextAt and now < state.nextAt then return state end
    state.nextAt = now + 0.1
    local bx, by, bz = playerGroundCell(playerEntity)
    if bx == nil then
        Runtime.PlayerLocationState[playerEntity] = state
        return state
    end
    local key = tostring(bx) .. ":" .. tostring(by) .. ":" .. tostring(bz)
    local below = blockName(blockAt(bx, by, bz - 1))
    state.soulBlock = SOUL_BLOCKS[below] == true
    local soulSpeed = Runtime.GetEquipmentLevel(playerEntity, "feet", "soul_speed")
    local fallFlying = isfunction(Runtime.IsFallFlying) and Runtime.IsFallFlying(playerEntity) == true
    -- Java's location_changed effect stays active while the entity is in the
    -- air, but drops when it lands on a non-soul block (and never applies in a
    -- vehicle or while fall-flying).  Keep that state separate from the block
    -- currently under the player so a jump does not lose the modifier.
    if soulSpeed <= 0 or playerEntity:InVehicle() or fallFlying then
        state.soulSpeedActive = false
    elseif state.soulBlock then
        state.soulSpeedActive = true
    elseif playerEntity:IsOnGround() then
        state.soulSpeedActive = false
    end

    local soulEffectPeriod = math.floor(now / (5 * TICK_SECONDS))
    if state.soulEffectPeriod ~= soulEffectPeriod then
        state.soulEffectPeriod = soulEffectPeriod
        local velocity = isfunction(playerEntity.GetVelocity)
            and playerEntity:GetVelocity() or vector_origin
        local horizontalThreshold = blockSize() * 20 * 0.00001
        local moving = velocity.x * velocity.x + velocity.y * velocity.y
            >= horizontalThreshold * horizontalThreshold
        if soulSpeed > 0 and state.soulBlock and playerEntity:IsOnGround()
            and not playerEntity:InVehicle() and not fallFlying and moving then
            if isfunction(Runtime.EmitSoulSpeedParticle) then
                Runtime.EmitSoulSpeedParticle(playerEntity)
            end
            if math.Rand(0, 1) < 0.35 and isfunction(Runtime.PlaySoulSpeedSound) then
                Runtime.PlaySoulSpeedSound(playerEntity)
            end
        end
    end
    if key ~= state.cellKey then
        state.cellKey = key
        local frost = Runtime.GetEquipmentLevel(playerEntity, "feet", "frost_walker")
        applyFrostWalker(playerEntity, frost, bx, by, bz)
        if state.soulBlock and soulSpeed > 0 and playerEntity:IsOnGround()
            and math.Rand(0, 1) < 0.04 * soulSpeed then
            damageEquipment(playerEntity, "feet", 1, {
                reason = "soul_speed",
                enchantment = "minecraft:soul_speed",
            })
        end
    end
    Runtime.PlayerLocationState[playerEntity] = state
    return state
end

hook.Add("MCITEM.EnchantmentMovementParameters", "MCITEM.Enchantments.Movement", function(playerEntity)
    local depth = Runtime.GetEquipmentLevel(playerEntity, "feet", "depth_strider")
    local swift = Runtime.GetEquipmentLevel(playerEntity, "legs", "swift_sneak")
    local location = updateLocationEffects(playerEntity, CurTime())
    local soul = Runtime.GetEquipmentLevel(playerEntity, "feet", "soul_speed")
    if not location.soulSpeedActive or playerEntity:InVehicle()
        or (isfunction(Runtime.IsFallFlying) and Runtime.IsFallFlying(playerEntity)) then soul = 0 end
    local values = location.movementParameters
    if not values then values = Vector() location.movementParameters = values end
    if values.x ~= depth or values.y ~= swift or values.z ~= soul then
        values.x, values.y, values.z = depth, swift, soul
        playerEntity:SetNW2Vector("MCITEMMovementEnchantments", values)
    end
    return values
end)

local function clearRiptide(owner)
    if IsValid(owner) and isfunction(owner.SetNW2Bool) then
        owner:SetNW2Bool("MCITEM_RiptideActive", false)
    end
    Runtime.RiptideStates[owner] = nil
end

local function setAbsoluteVelocity(entity, desired)
    if not IsValid(entity) or not isvector(desired) then return false end
    local current = isfunction(entity.GetVelocity) and entity:GetVelocity() or vector_origin
    if entity:IsPlayer() and isfunction(entity.SetVelocity) then
        -- Player:SetVelocity is additive, unlike NPC/local movement setters.
        entity:SetVelocity(desired - current)
        return true
    end
    if isfunction(entity.SetLocalVelocity) then
        entity:SetLocalVelocity(desired)
        return true
    end
    if isfunction(entity.SetVelocity) then
        entity:SetVelocity(desired)
        return true
    end
    return false
end

local function findRiptideTargets(owner, state, currentPosition)
    local candidates = {}
    local previous = state.lastPosition or currentPosition
    local radius = blockSize() * 0.75
    if ents.FindAlongRay then
        candidates = ents.FindAlongRay(previous, currentPosition,
            Vector(-radius, -radius, -radius), Vector(radius, radius, radius)) or {}
    else
        candidates = ents.FindInSphere(currentPosition, blockSize() * 1.25) or {}
    end

    local hits = {}
    for _, target in ipairs(candidates) do
        if target ~= owner and living(target) and not state.hit[target] then
            local position = isfunction(target.WorldSpaceCenter)
                and target:WorldSpaceCenter() or target:GetPos()
            hits[#hits + 1] = {
                entity = target,
                distance = (position - previous):LengthSqr(),
            }
        end
    end
    table.sort(hits, function(left, right)
        return left.distance < right.distance
    end)
    local result = {}
    for _, hit in ipairs(hits) do result[#result + 1] = hit.entity end
    return result
end

hook.Remove("Think", "MCITEM.Enchantments.LocationAndRiptide")
hook.Add("Think", "MCITEM.Enchantments.LocationAndRiptide", function()
    local now = CurTime()
    for _, playerEntity in ipairs(player.GetAll()) do
        if IsValid(playerEntity) and playerEntity:Alive() then updateLocationEffects(playerEntity, now) end
    end
    for owner, state in pairs(Runtime.RiptideStates) do
        if not IsValid(owner) or not owner:Alive() or now >= (state.endsAt or 0) then
            clearRiptide(owner)
        elseif now >= (state.nextAt or 0) then
            state.nextAt = now + TICK_SECONDS
            local currentPosition = owner:WorldSpaceCenter()
            local targets = findRiptideTargets(owner, state, currentPosition)
            state.lastPosition = currentPosition
            state.ticks = (state.ticks or 0) + 1
            if #targets > 0 then
                -- LivingEntity.checkAutoSpinAttack iterates every LivingEntity
                -- in the swept AABB before clearing the 20-tick spin state. It
                -- also applies the -0.2 velocity reversal for every touched
                -- entity, so tightly stacked targets intentionally compound it.
                local reversedVelocity = owner:GetVelocity()
                for _, target in ipairs(targets) do
                    if IsValid(target) then
                        state.hit[target] = true
                        local oldHealth = tonumber(target:Health()) or nil
                        local damage = 8
                            + (isfunction(Runtime.GetTridentDamageBonus)
                                and Runtime.GetTridentDamageBonus(state.stack, target)
                                or Runtime.GetMeleeDamageBonus(state.stack, target))
                        local damageInfo = DamageInfo()
                        damageInfo:SetAttacker(owner)
                        damageInfo:SetInflictor(owner)
                        damageInfo:SetDamage(isfunction(MCITEM.ScaleDamage)
                            and MCITEM.ScaleDamage(damage) or damage)
                        damageInfo:SetDamageType(DMG_SLASH)
                        damageInfo:SetDamagePosition(target:WorldSpaceCenter())
                        target:TakeDamageInfo(damageInfo)
                        local newHealth = IsValid(target) and tonumber(target:Health()) or nil
                        local actualDamage = oldHealth ~= nil and newHealth ~= nil
                            and math.max(oldHealth - newHealth, 0) or 0
                        if actualDamage > 0 and isfunction(Runtime.ApplyDirectPostAttack) then
                            Runtime.ApplyDirectPostAttack(state.stack, owner, target,
                                state.weapon or owner, actualDamage)
                        end
                        reversedVelocity = reversedVelocity * -0.2
                    end
                end
                setAbsoluteVelocity(owner, reversedVelocity)
                clearRiptide(owner)
            elseif state.ticks > 1 and owner:IsOnGround()
                and owner:GetVelocity():LengthSqr() < (blockSize() * 2) ^ 2 then
                clearRiptide(owner)
            end
        end
    end
end)

function Runtime.StartRiptide(playerEntity, weapon, stack, commit)
    if not IsValid(playerEntity) or not playerEntity:IsPlayer()
        or playerEntity:InVehicle()
        or not Runtime.CanUseRiptide(playerEntity) then return false end
    local riptide = Runtime.GetRiptideLevel(stack)
    if riptide <= 0 or Runtime.RiptideStates[playerEntity] then return false end
    local direction = playerEntity:GetAimVector()
    if direction:LengthSqr() <= 1e-8 then return false end
    direction:Normalize()

    -- The Java all_of effect changes durability before applying the impulse.
    -- Keep the callback ahead of any movement/position mutation so a failed
    -- authoritative inventory transaction leaves the player untouched.
    if isfunction(commit) and commit() == false then return false end

    -- TridentItem moves a grounded player up by 1.2 blocks before starting the
    -- spin. Resolve that small lift against the Source player hull when the
    -- collision API is available.
    if playerEntity:IsOnGround() and isfunction(util.TraceHull) then
        local lift = blockSize() * 1.2
        local start = playerEntity:GetPos()
        local trace = util.TraceHull({
            start = start,
            endpos = start + Vector(0, 0, lift),
            mins = playerEntity:OBBMins(),
            maxs = playerEntity:OBBMaxs(),
            filter = playerEntity,
            mask = MASK_PLAYERSOLID or MASK_SOLID,
        })
        playerEntity:SetPos(trace.Hit and trace.HitPos or start + Vector(0, 0, lift))
    end
    if isfunction(playerEntity.SetGroundEntity) then playerEntity:SetGroundEntity(NULL) end

    local strength = Runtime.GetRiptideStrength(stack)
    playerEntity:SetVelocity(direction * strength * blockSize() * 20)
    Runtime.RiptideStates[playerEntity] = {
        weapon = weapon,
        stack = istable(stack) and table.Copy(stack) or nil,
        endsAt = CurTime() + 20 * TICK_SECONDS,
        nextAt = CurTime(),
        lastPosition = playerEntity:WorldSpaceCenter(),
        hit = setmetatable({}, { __mode = "k" }),
        ticks = 0,
    }
    if isfunction(playerEntity.SetNW2Bool) then
        playerEntity:SetNW2Bool("MCITEM_RiptideActive", true)
    end
    if isfunction(MCITEM.PlayRangedSound) then
        MCITEM.PlayRangedSound(playerEntity,
            "trident_riptide_" .. math.Clamp(riptide, 1, 3), 1, 100)
    end
    return true
end
function Runtime.ApplySpearLunge(playerEntity, weapon, stack)
    if not IsValid(playerEntity) or playerEntity:InVehicle()
        or Runtime.IsFallFlying(playerEntity) or Runtime.IsInWater(playerEntity) then return false end
    local lunge = Runtime.GetLungeLevel(stack)
    if lunge <= 0 then return false end
    local creative = MCITEM.HasInfiniteMaterials and MCITEM.HasInfiniteMaterials(playerEntity)
    local foodLevel = playerEntity:GetNWInt("mc_food_level", 20)
    if not creative and foodLevel < 7 then return false end
    local direction = playerEntity:GetAimVector()
    direction.z = 0
    if direction:LengthSqr() <= 1e-8 then return false end
    direction:Normalize()

    -- AllOf applies ChangeItemDamage before exhaustion, impulse and sound.  A
    -- failed authoritative inventory mutation must therefore leave the later
    -- effects untouched; a successful break still counts as a successful use.
    if IsValid(weapon) and isfunction(weapon.ApplyMCDurabilityDamage) then
        local durabilityResult = weapon:ApplyMCDurabilityDamage(1, {
            reason = "lunge",
            enchantment = "minecraft:lunge",
        })
        if durabilityResult == false then return false end
    end
    if MCITEM.Food and isfunction(MCITEM.Food.ApplyExhaustion) then
        MCITEM.Food.ApplyExhaustion(playerEntity, 4 * lunge, {
            reason = "lunge",
            weapon = weapon,
        })
    end
    playerEntity:SetVelocity(direction * (0.458 * lunge * blockSize() * 20))
    if isfunction(MCITEM.PlayRangedSound) then
        MCITEM.PlayRangedSound(playerEntity, "spear_lunge", 1, 100)
    end
    return true
end

-- MCSWEP owns the authoritative block-break transaction.  It publishes this
-- event only after the voxel write succeeds; MCITEM supplies the existing
-- experience-orb implementation without creating a second XP store.  Convert
-- the MC world-space cell center to the caller's engine space so InfMap origins
-- remain correct for players far from (0,0,0).
hook.Remove("MC.BlockExperienceAwarded", "MCITEM.Enchantments.BlockExperience")
hook.Add("MC.BlockExperienceAwarded", "MCITEM.Enchantments.BlockExperience",
    function(playerEntity, bx, by, bz, value, context)
        if not SERVER or not isfunction(MCITEM.Throwables and MCITEM.Throwables.AwardExperience)
            or not isnumber(value) or value <= 0 then return end
        local api = MC and MC.API or nil
        local coords = api and api.Coords or nil
        local position
        if coords and isfunction(coords.CellCenter) then
            local ok, worldCenter = pcall(coords.CellCenter, bx, by, bz)
            if ok and isvector(worldCenter) then
                position = worldCenter
                if IsValid(playerEntity) and isfunction(coords.EntityWorldPos)
                    and isfunction(playerEntity.GetPos) then
                    local posOK, playerWorld = pcall(coords.EntityWorldPos, playerEntity)
                    if posOK and isvector(playerWorld) then
                        position = playerEntity:GetPos() + (worldCenter - playerWorld)
                    end
                end
            end
        end
        if not isvector(position) and IsValid(playerEntity) and isfunction(playerEntity.GetPos) then
            position = playerEntity:GetPos()
        end
        if not isvector(position) then return end
        local direction = Vector(0, 0, 1)
        local awardContext = istable(context) and table.Copy(context) or {}
        awardContext.player = playerEntity
        awardContext.bx, awardContext.by, awardContext.bz = bx, by, bz
        awardContext.reason = awardContext.reason or "block_mined"
        MCITEM.Throwables.AwardExperience(position, direction, math.floor(value), awardContext)
    end)
