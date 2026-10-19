-- Java 26.2 Consumable.onConsume adapters for MCITEM food.
--
-- MCSWEP's native hand path owns the mc_food_level/mc_food_saturation
-- mutation.  MCITEM SWEPs use this module so the same public fields and
-- potion runtime are available when the item is held as an external weapon.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food

local HUNGER_MAX = Food.HungerMax or 20
local HUNGER_DEFAULT = Food.HungerDefault or 20
local SATURATION_DEFAULT = 5
local EXHAUSTION_DEFAULT = 0

local function livingPlayer(entity)
    return IsValid(entity) and entity:IsPlayer() and entity:Alive()
end

local function hungerState(player)
    return math.Clamp(player:GetNWInt("mc_food_level", HUNGER_DEFAULT), 0, HUNGER_MAX),
        math.max(0, player:GetNWFloat("mc_food_saturation", SATURATION_DEFAULT))
end

function Food.ResetHungerState(player, reason)
    if not IsValid(player) or not player:IsPlayer() then return false end
    player:SetNWInt("mc_food_level", HUNGER_DEFAULT)
    player:SetNWFloat("mc_food_saturation", SATURATION_DEFAULT)
    player:SetNWFloat("mc_food_exhaustion", EXHAUSTION_DEFAULT)
    player:SetNWBool("MCITEMFoodStateInitialized", true)
    hook.Run(
        "MCITEM.FoodStateReset",
        player,
        HUNGER_DEFAULT,
        SATURATION_DEFAULT,
        EXHAUSTION_DEFAULT,
        reason or "reset"
    )
    return true
end

function Food.GetHungerState(player)
    if not livingPlayer(player) then return 0, 0 end
    return hungerState(player)
end

function Food.ApplyNutrition(player, definition)
    if not livingPlayer(player) or not istable(definition) then return false end
    local hunger, saturation = hungerState(player)
    local nutrition = math.max(0, math.floor(tonumber(definition.nutrition) or 0))
    local newHunger = math.Clamp(hunger + nutrition, 0, HUNGER_MAX)
    -- FoodProperties.getSaturationModifier() is multiplied by nutrition and
    -- then by two by FoodData.eat.  Generated data stores that final product
    -- as `saturation` (e.g. apple = 2.4).
    local addedSaturation = math.max(0, tonumber(definition.saturation) or 0)
    local newSaturation = math.max(
        saturation,
        math.min(newHunger, saturation + addedSaturation)
    )
    player:SetNWInt("mc_food_level", newHunger)
    player:SetNWFloat("mc_food_saturation", newSaturation)
    hook.Run("MCITEM.FoodNutritionApplied", player, definition, hunger, newHunger, saturation, newSaturation)
    return true
end

function Food.ApplyExhaustion(player, amount, context)
    if not livingPlayer(player) then return false end
    amount = math.max(0, tonumber(amount) or 0)
    local handled = hook.Run("MCITEM.FoodExhaustion", player, amount, context)
    if handled ~= nil then return handled ~= false end

    local exhaustion = math.max(0, player:GetNWFloat("mc_food_exhaustion", EXHAUSTION_DEFAULT) + amount)
    local hunger = math.Clamp(player:GetNWInt("mc_food_level", HUNGER_DEFAULT), 0, HUNGER_MAX)
    local saturation = math.max(0, player:GetNWFloat("mc_food_saturation", SATURATION_DEFAULT))
    while exhaustion >= 4 do
        exhaustion = exhaustion - 4
        if saturation > 0 then
            saturation = math.max(0, saturation - 1)
        else
            hunger = math.max(0, hunger - 1)
        end
    end
    player:SetNWFloat("mc_food_exhaustion", exhaustion)
    player:SetNWFloat("mc_food_saturation", saturation)
    player:SetNWInt("mc_food_level", hunger)
    return true
end

function Food.ApplySaturation(player, amount, context)
    if not livingPlayer(player) then return false end
    amount = math.max(0, tonumber(amount) or 0)
    local handled = hook.Run("MCITEM.FoodSaturation", player, amount, context)
    if handled ~= nil then return handled ~= false end
    local hunger = math.Clamp(player:GetNWInt("mc_food_level", HUNGER_DEFAULT), 0, HUNGER_MAX)
    local saturation = math.max(0, player:GetNWFloat("mc_food_saturation", SATURATION_DEFAULT))
    local newHunger = math.min(HUNGER_MAX, hunger + amount)
    player:SetNWInt("mc_food_level", newHunger)
    player:SetNWFloat("mc_food_saturation", math.min(newHunger, saturation + amount * 2))
    return true
end

local function applyEffect(player, id, durationTicks, amplifier, chance, context)
    if not livingPlayer(player) then return false end
    if chance and math.Rand(0, 1) > chance then return false end
    local potions = MCITEM.Potions
    if not potions or not isfunction(potions.ApplyEffect) then return false end
    return potions.ApplyEffect(player, {
        id = id,
        durationTicks = durationTicks,
        amplifier = amplifier or 0,
        ambient = false,
        visible = true,
        showIcon = true,
    }, player, context) == true
end

local function applyEffectList(player, list, context)
    local changed = false
    for _, spec in ipairs(list or {}) do
        if applyEffect(player, spec.id, spec.durationTicks, spec.amplifier, spec.chance, context) then
            changed = true
        end
    end
    return changed
end

local function removeEffect(player, id, context)
    local potions = MCITEM.Potions
    if not potions then return false end
    if isfunction(potions.RemoveEffect) then
        return potions.RemoveEffect(player, id, "food_consume")
    end
    return false
end

local function clearEffects(player, context)
    local potions = MCITEM.Potions
    if potions and isfunction(potions.ClearEffects) then
        return potions.ClearEffects(player, "milk_consume")
    end
    return false
end

function Food.ClearConsumableEffects(player, reason)
    if not livingPlayer(player) then return false end
    return clearEffects(player, { reason = reason or "consumable" })
end

local function safeHullFor(entity)
    if not IsValid(entity) then return Vector(-16, -16, 0), Vector(16, 16, 72) end
    local mins, maxs = entity:GetHull()
    if not isvector(mins) or not isvector(maxs) then
        mins, maxs = entity:OBBMins(), entity:OBBMaxs()
    end
    return mins or Vector(-16, -16, 0), maxs or Vector(16, 16, 72)
end

local function safeChorusDestination(player)
    local origin = player:GetPos()
    local blockSize = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
    local mins, maxs = safeHullFor(player)

    for _ = 1, 16 do
        local candidate = origin + Vector(
            (math.Rand(-0.5, 0.5) * 16) * blockSize,
            (math.Rand(-0.5, 0.5) * 16) * blockSize,
            (math.Rand(-0.5, 0.5) * 16) * blockSize
        )

        -- Trace the entity hull through the candidate and settle it on the
        -- first solid surface below.  This mirrors LivingEntity.randomTeleport
        -- while remaining safe for ordinary Source maps and custom MC voxel
        -- adapters (which can override the public veto hook below).
        local downStart = candidate + Vector(0, 0, 8 * blockSize)
        local downEnd = candidate - Vector(0, 0, 16 * blockSize)
        local ground = util.TraceHull({
            start = downStart,
            endpos = downEnd,
            mins = mins,
            maxs = maxs,
            filter = player,
            mask = MASK_PLAYERSOLID,
        })
        if ground.Hit and not ground.StartSolid then
            local destination = ground.HitPos - Vector(0, 0, mins.z)
            local room = util.TraceHull({
                start = destination,
                endpos = destination,
                mins = mins,
                maxs = maxs,
                filter = player,
                mask = MASK_PLAYERSOLID,
            })
            if not room.StartSolid and not room.AllSolid then return destination end
        end
    end
    return nil
end

function Food.ApplyChorusFruit(player, context)
    if not livingPlayer(player) then return false end
    local veto = hook.Run("MCITEM.CanTeleportChorusFruit", player, context)
    if veto == false then return false end

    local destination = safeChorusDestination(player)
    if not destination then return false end
    if player:IsPlayer() and player:InVehicle() then player:ExitVehicle() end
    player:SetPos(destination)
    -- TeleportRandomlyConsumeEffect preserves delta movement.  Its successful
    -- branch only calls LivingEntity.resetFallDistance() and
    -- resetCurrentImpulseContext(), so do not cancel the player's velocity.
    if player.SetSaveValue then player:SetSaveValue("m_flFallVelocity", 0) end
    hook.Run("MCITEM.ChorusFruitTeleported", player, destination, context)
    if MCITEM.Throwables and isfunction(MCITEM.Throwables.PlayChorusFruitTeleport) then
        MCITEM.Throwables.PlayChorusFruitTeleport(destination, player)
    end
    return true
end

local function suspiciousStewComponent(stack)
    if not istable(stack) or not istable(stack.components) then return nil end
    return stack.components["minecraft:suspicious_stew_effects"]
        or stack.components.suspicious_stew_effects
end

function Food.SuspiciousStewEffects(stack)
    local component = suspiciousStewComponent(stack)
    if istable(component) and istable(component.effects) then component = component.effects end
    if not istable(component) then return {} end

    local effects = {}
    for _, entry in ipairs(component) do
        if istable(entry) and isstring(entry.id) then
            effects[#effects + 1] = {
                id = string.gsub(entry.id, "^minecraft:", ""),
                -- SuspiciousStewEffects.Entry.CODEC defaults duration to 160.
                durationTicks = math.max(0, math.floor(tonumber(entry.duration) or 160)),
                amplifier = math.max(0, math.floor(tonumber(entry.amplifier) or 0)),
            }
        end
    end
    return effects
end

function Food.ApplyConsumableEffects(player, definition, context)
    if not livingPlayer(player) or not istable(definition) then return false end
    context = context or {}
    context.itemId = definition.id
    context.delivery = "food"

    local id = definition.id
    local changed = false
    -- MCITEM's standalone SWEP does not pass through MCSWEP's native hand
    -- nutrition transaction, so apply FoodProperties here.  The native hand
    -- bridge calls this function with nutritionAlreadyApplied=true.
    if definition.isFood ~= false and context.nutritionAlreadyApplied ~= true then
        Food.ApplyNutrition(player, definition)
    end
    if id == "chicken" then
        changed = applyEffect(player, "hunger", 600, 0, 0.3, context) or changed
    elseif id == "enchanted_golden_apple" then
        changed = applyEffectList(player, {
            { id = "regeneration", durationTicks = 400, amplifier = 1 },
            { id = "resistance", durationTicks = 6000, amplifier = 0 },
            { id = "fire_resistance", durationTicks = 6000, amplifier = 0 },
            { id = "absorption", durationTicks = 2400, amplifier = 3 },
        }, context) or changed
    elseif id == "golden_apple" then
        changed = applyEffectList(player, {
            { id = "regeneration", durationTicks = 100, amplifier = 1 },
            { id = "absorption", durationTicks = 2400, amplifier = 0 },
        }, context) or changed
    elseif id == "poisonous_potato" then
        changed = applyEffect(player, "poison", 100, 0, 0.6, context) or changed
    elseif id == "pufferfish" then
        changed = applyEffectList(player, {
            { id = "poison", durationTicks = 1200, amplifier = 1 },
            { id = "hunger", durationTicks = 300, amplifier = 2 },
            { id = "nausea", durationTicks = 300, amplifier = 0 },
        }, context) or changed
    elseif id == "rotten_flesh" then
        changed = applyEffect(player, "hunger", 600, 0, 0.8, context) or changed
    elseif id == "spider_eye" then
        changed = applyEffect(player, "poison", 100, 0, nil, context) or changed
    elseif id == "honey_bottle" then
        changed = removeEffect(player, "poison", context) or changed
    elseif id == "milk_bucket" then
        changed = Food.ClearConsumableEffects(player, "milk_consume") or changed
    elseif id == "chorus_fruit" then
        changed = Food.ApplyChorusFruit(player, context) or changed
    end

    -- Java stores the effects on the consumed ItemStack as
    -- minecraft:suspicious_stew_effects.  An explicit integration override is
    -- still accepted, but the native MCSWEP path needs no special caller data.
    if id == "suspicious_stew" then
        local stewEffects = istable(context.suspiciousEffects)
            and context.suspiciousEffects or Food.SuspiciousStewEffects(context.stack)
        changed = applyEffectList(player, stewEffects, context) or changed
    end
    return changed
end

hook.Remove("MC.ItemConsumed", "MCITEM.FoodNativeHandEffects")
hook.Add("MC.ItemConsumed", "MCITEM.FoodNativeHandEffects", function(player, stack, foodData, infinite)
    if not livingPlayer(player) or not istable(stack) then return end
    local itemId = tostring(stack.item or "")
    itemId = string.gsub(itemId, "^minecraft:", "")
    local definition = Food.Get and Food.Get(itemId) or nil
    if not definition then return end
    Food.ApplyConsumableEffects(player, definition, {
        stack = stack,
        infinite = infinite == true,
        nutritionAlreadyApplied = true,
        source = "mcswep_hand",
    })
end)

hook.Remove("PlayerInitialSpawn", "MCITEM.FoodInitializeState")
hook.Add("PlayerInitialSpawn", "MCITEM.FoodInitializeState", function(player)
    timer.Simple(0, function()
        if IsValid(player) and not player:GetNWBool("MCITEMFoodStateInitialized", false) then
            Food.ResetHungerState(player, "initial_spawn")
        end
    end)
end)

hook.Remove("PlayerSpawn", "MCITEM.FoodResetStateOnRespawn")
hook.Add("PlayerSpawn", "MCITEM.FoodResetStateOnRespawn", function(player)
    Food.ResetHungerState(player, "respawn")
end)
