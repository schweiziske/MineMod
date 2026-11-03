-- Public Food contract shared by the generated registrations and the use state machine.
-- Constants and cadence come from Minecraft Java 26.2 Consumable/ItemStack.

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food

Food.TickSeconds = 1 / 20
Food.EffectsStartFraction = 0.21875
Food.EffectsIntervalTicks = 4
Food.UseParticleCount = 5
Food.FinishParticleCount = 16
Food.HungerMax = 20
Food.HungerDefault = 20

-- Consumable.shouldEmitParticlesAndSounds(remainingTicks):
--   consumed > floor(duration * 0.21875) && remaining % 4 == 0
function Food.ShouldEmitUseEffects(durationTicks, remainingTicks)
    durationTicks = math.max(0, math.floor(tonumber(durationTicks) or 0))
    remainingTicks = math.max(0, math.floor(tonumber(remainingTicks) or 0))
    local consumedTicks = durationTicks - remainingTicks
    local threshold = math.floor(durationTicks * Food.EffectsStartFraction)
    return consumedTicks > threshold
        and remainingTicks % Food.EffectsIntervalTicks == 0
end

function Food.DefinitionForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if istable(weapon.MCFoodDefinition) then return weapon.MCFoodDefinition end
    local itemId = weapon.MCFoodID or weapon.MCItemID
    return Food.Get and Food.Get(itemId) or nil
end

-- Shared so predicted standalone/proxy SWEP use makes the same decision as
-- the authoritative server.  Without this client-side gate, a full player
-- could see the eating pose even though the server correctly rejected use,
-- which looked like missing sounds and item-fragment particles.
function Food.PlayerCanAlwaysEat(player)
    if not IsValid(player) or not player:IsPlayer() then return false end
    if MC and isfunction(MC.PlayerIsCreative) then
        return MC.PlayerIsCreative(player) == true
    end

    -- MineMod replicates the normalized mode as creative/survival.  Accept the
    -- numeric aliases as a fallback so this contract also behaves correctly
    -- during client prediction while the shared game-mode helper is loading.
    local mode = string.lower(string.Trim(player:GetNWString("mc_gamemode", "survival")))
    return mode == "creative" or mode == "1"
end

function Food.CanEat(player, definition)
    if not IsValid(player) or not player:IsPlayer() or not player:Alive()
        or not istable(definition)
    then
        return false
    end
    if Food.PlayerCanAlwaysEat(player) then return true end
    local level = math.Clamp(
        player:GetNWInt("mc_food_level", Food.HungerDefault),
        0,
        Food.HungerMax
    )
    return definition.alwaysEdible == true or level < Food.HungerMax
end

-- Hunger/inventory systems may veto use without MCITEM needing to own those systems.
-- Method result takes precedence; returning nil means "no opinion".
function Food.CanConsume(weapon, owner, definition)
    if not IsValid(weapon) or not IsValid(owner) or not istable(definition) then return false end

    if isfunction(weapon.CanMCConsumeFood) then
        local result = weapon:CanMCConsumeFood(owner, definition)
        if result ~= nil then return result ~= false end
    end

    local result = hook.Run("MCITEM.CanConsumeFood", owner, weapon, definition)
    if result ~= nil then return result ~= false end

    if isfunction(Food.CanEat) then
        return Food.CanEat(owner, definition)
    end

    return true
end
