-- Realm-shared 20 Hz drink-use state for PotionItem/Consumable.DEFAULT_DRINK.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

local EFFECTS_START_FRACTION = 0.21875
local EFFECTS_INTERVAL_TICKS = 4

local function stateFor(weapon)
    weapon.MCPotionDrinkState = weapon.MCPotionDrinkState or {
        using = false,
        startedAt = 0,
        processedTicks = 0,
        generation = 0,
    }
    return weapon.MCPotionDrinkState
end

function Potions.CanDrink(weapon, owner, definition)
    if not IsValid(weapon) or not IsValid(owner) or not istable(definition) then return false end
    if isfunction(weapon.CanMCDrinkPotion) then
        local result = weapon:CanMCDrinkPotion(owner, definition)
        if result ~= nil then return result ~= false end
    end
    local result = hook.Run("MCITEM.CanDrinkPotion", owner, weapon, definition)
    if result ~= nil then return result ~= false end
    return true
end

function Potions.ResetDrink(weapon)
    if not IsValid(weapon) then return end
    local state = stateFor(weapon)
    state.using = false
    state.startedAt = 0
    state.processedTicks = 0
    state.generation = (state.generation or 0) + 1
end

function Potions.StartDrink(weapon, now)
    if not IsValid(weapon) then return false end
    local owner = weapon:GetOwner()
    local definition = Potions.DefinitionForWeapon(weapon)
    if not Potions.CanDrink(weapon, owner, definition) then return false end
    local state = stateFor(weapon)
    if state.using then return false end
    state.using = true
    state.startedAt = tonumber(now) or CurTime()
    state.processedTicks = 0
    state.generation = (state.generation or 0) + 1
    return true
end

function Potions.CancelDrink(weapon, reason)
    if not IsValid(weapon) then return false end
    local state = stateFor(weapon)
    if not state.using then return false end
    state.using = false
    state.cancelReason = reason or "cancelled"
    state.generation = (state.generation or 0) + 1
    return true
end

function Potions.IsDrinking(weapon)
    return IsValid(weapon) and stateFor(weapon).using == true
end

function Potions.DrinkElapsedTicks(weapon, now)
    if not Potions.IsDrinking(weapon) then return 0 end
    return math.max(0, ((tonumber(now) or CurTime()) - stateFor(weapon).startedAt) / Potions.TickSeconds)
end

function Potions.ShouldEmitDrinkSound(remainingTicks)
    remainingTicks = math.max(0, math.floor(tonumber(remainingTicks) or 0))
    local consumedTicks = Potions.DrinkDurationTicks - remainingTicks
    local threshold = math.floor(Potions.DrinkDurationTicks * EFFECTS_START_FRACTION)
    return consumedTicks > threshold and remainingTicks % EFFECTS_INTERVAL_TICKS == 0
end

function Potions.AdvanceServerDrink(weapon, now, onSound, onComplete)
    if not SERVER or not Potions.IsDrinking(weapon) then return false end
    local definition = Potions.DefinitionForWeapon(weapon)
    if not definition then return Potions.CancelDrink(weapon, "missing_definition") end

    local state = stateFor(weapon)
    local elapsed = math.floor(Potions.DrinkElapsedTicks(weapon, now) + 1e-6)
    local targetTick = math.min(elapsed, Potions.DrinkDurationTicks)
    while state.using and state.processedTicks < targetTick do
        state.processedTicks = state.processedTicks + 1
        local remainingBeforeTick = Potions.DrinkDurationTicks - (state.processedTicks - 1)
        if Potions.ShouldEmitDrinkSound(remainingBeforeTick) and isfunction(onSound) then
            onSound(weapon, definition, remainingBeforeTick)
        end
        if state.processedTicks >= Potions.DrinkDurationTicks then
            state.using = false
            if isfunction(onComplete) then onComplete(weapon, definition) end
            return true
        end
    end
    return false
end

function Potions.AdvanceClientDrink(weapon, now)
    if SERVER or not Potions.IsDrinking(weapon) then return false end
    if Potions.DrinkElapsedTicks(weapon, now) < Potions.DrinkDurationTicks then return false end
    stateFor(weapon).using = false
    return true
end
