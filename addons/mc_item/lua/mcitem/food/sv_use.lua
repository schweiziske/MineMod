-- Server-authoritative food completion, audiovisual events and extension hooks.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food
local NET_PARTICLES = "MCITEM_FoodParticles"

util.AddNetworkString(NET_PARTICLES)

function Food.BroadcastParticles(owner, definition, count)
    if not IsValid(owner) or not istable(definition) or not definition.hasConsumeParticles then return end
    count = math.Clamp(math.floor(tonumber(count) or 0), 0, 63)
    if count <= 0 then return end

    net.Start(NET_PARTICLES)
    net.WriteEntity(owner)
    net.WriteString(definition.id)
    net.WriteUInt(count, 6)
    net.Broadcast()
end

function Food.EmitUseEffects(weapon, definition, count)
    if not IsValid(weapon) then return end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return end
    Food.BroadcastParticles(owner, definition, count)
    Food.PlayUseSound(owner, definition)
end

function Food.CompleteUse(weapon, definition)
    if not IsValid(weapon) then return end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return end

    local context = {
        useStack = weapon.MCFoodUseState and weapon.MCFoodUseState.useStack,
        itemId = definition.id,
        nutrition = definition.nutrition,
        saturation = definition.saturation,
        saturationModifier = definition.saturationModifier,
        alwaysEdible = definition.alwaysEdible,
        specialEffect = definition.specialEffect,
        remainder = definition.remainder,
        consumeTicks = definition.consumeTicks,
        isFood = definition.isFood ~= false,
    }

    -- Separate inventory/stack bridge.  A backpack implementation may remove one
    -- item and grant the bowl/bottle remainder; the standalone test SWEP stays.
    local consumed = hook.Run(
        "MCITEM.ConsumeFoodItem",
        owner,
        weapon,
        definition.id,
        1,
        definition.remainder,
        context
    )
    if consumed == false then return false end
    Food.BroadcastParticles(owner, definition, Food.FinishParticleCount)
    Food.PlayUseSound(owner, definition)
    if definition.isFood ~= false then Food.PlayFoodCompletionSounds(owner, definition) end
    if IsValid(weapon) and isfunction(weapon.OnMCFoodConsumed) then
        weapon:OnMCFoodConsumed(owner, definition, context)
    end

    -- Vanilla applies Consumable.onConsume after the stack transaction.  Keep
    -- nutrition as an extension point, but make the status effects authoritative
    -- here so MCITEM SWEPs and the MCSWEP hand path share one implementation.
    if consumed ~= false and isfunction(Food.ApplyConsumableEffects) then
        Food.ApplyConsumableEffects(owner, definition, context)
    end
    hook.Run("MCITEM.FoodConsumed", owner, weapon, definition, context)
    return true
end

function Food.ServerTick(weapon, now)
    return Food.AdvanceServerUse(
        weapon,
        now,
        function(activeWeapon, definition, count)
            Food.EmitUseEffects(activeWeapon, definition, count)
        end,
        function(activeWeapon, definition)
            Food.CompleteUse(activeWeapon, definition)
        end
    )
end
