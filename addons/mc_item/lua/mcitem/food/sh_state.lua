-- Realm-shared 20 Hz food-use state.  Rendering reads continuous elapsed time;
-- the server advances authoritative ItemStack.onUseTick boundaries.

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food

local function stateFor(weapon)
    weapon.MCFoodUseState = weapon.MCFoodUseState or {
        using = false,
        startedAt = 0,
        processedTicks = 0,
        generation = 0,
    }
    return weapon.MCFoodUseState
end

function Food.ResetUse(weapon)
    if not IsValid(weapon) then return end
    local state = stateFor(weapon)
    state.using = false
    state.startedAt = 0
    state.processedTicks = 0
    state.generation = (state.generation or 0) + 1
end

function Food.StartUse(weapon, now)
    if not IsValid(weapon) then return false end
    local definition = Food.DefinitionForWeapon(weapon)
    local owner = weapon:GetOwner()
    if not Food.CanConsume(weapon, owner, definition) then return false end

    local state = stateFor(weapon)
    if state.using then return false end
    state.using = true
    state.startedAt = tonumber(now) or CurTime()
    state.processedTicks = 0
    state.generation = (state.generation or 0) + 1
    if SERVER then state.useStack = hook.Run("MCITEM.CaptureUseStack", owner, weapon) end
    return true
end

function Food.CancelUse(weapon, reason)
    if not IsValid(weapon) then return false end
    local state = stateFor(weapon)
    if not state.using then return false end
    state.using = false
    state.cancelReason = reason or "cancelled"
    state.generation = (state.generation or 0) + 1
    return true
end

function Food.IsUsing(weapon)
    return IsValid(weapon) and stateFor(weapon).using == true
end

function Food.ElapsedTicks(weapon, now)
    if not Food.IsUsing(weapon) then return 0 end
    local state = stateFor(weapon)
    return math.max(0, ((tonumber(now) or CurTime()) - state.startedAt) / Food.TickSeconds)
end

-- Advances exact Minecraft ticks.  onEffects receives the vanilla count (5);
-- onComplete is invoked after the final remaining tick decrements to zero.
function Food.AdvanceServerUse(weapon, now, onEffects, onComplete)
    if not SERVER or not Food.IsUsing(weapon) then return false end
    local definition = Food.DefinitionForWeapon(weapon)
    if not definition then return Food.CancelUse(weapon, "missing_definition") end

    local state = stateFor(weapon)
    local duration = math.max(1, math.floor(tonumber(definition.consumeTicks) or 1))
    local elapsed = math.floor(Food.ElapsedTicks(weapon, now) + 1e-6)
    local targetTick = math.min(elapsed, duration)

    while state.using and state.processedTicks < targetTick do
        state.processedTicks = state.processedTicks + 1
        local remainingBeforeTick = duration - (state.processedTicks - 1)

        if Food.ShouldEmitUseEffects(duration, remainingBeforeTick) and isfunction(onEffects) then
            onEffects(weapon, definition, Food.UseParticleCount, remainingBeforeTick)
        end

        if state.processedTicks >= duration then
            state.using = false
            if isfunction(onComplete) then onComplete(weapon, definition) end
            return true
        end
    end

    return false
end

function Food.AdvanceClientUse(weapon, now)
    if SERVER or not Food.IsUsing(weapon) then return false end
    local definition = Food.DefinitionForWeapon(weapon)
    if not definition then return Food.CancelUse(weapon, "missing_definition") end
    if Food.ElapsedTicks(weapon, now) < definition.consumeTicks then return false end
    stateFor(weapon).using = false
    return true
end
