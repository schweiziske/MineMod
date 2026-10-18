-- Server-authoritative planting/bonemeal transactions and selected-item bridge.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Farming = MCITEM.Farming or {}

local Farming = MCITEM.Farming
local NET_GROWTH = "MCITEM_FarmingGrowthParticles"
local NET_USE_SWING = "MCITEM_FarmingUseSwing"

util.AddNetworkString(NET_GROWTH)
util.AddNetworkString(NET_USE_SWING)

Farming.PlayerUseStates = Farming.PlayerUseStates or setmetatable({}, { __mode = "k" })

local function useDelay()
    return math.max(0, tonumber(Farming.RightClickDelayTicks) or 4)
        * math.max(0, tonumber(MCITEM.TickSeconds) or 0.05)
end

function Farming.TryBeginPlayerUse(owner)
    if not IsValid(owner) or not owner:IsPlayer() then return false, "invalid_owner" end
    local now = CurTime()
    local state = Farming.PlayerUseStates[owner]
    if not state then
        state = { latched = false, nextUseAt = 0 }
        Farming.PlayerUseStates[owner] = state
    end
    local pressed = owner.KeyPressed and owner:KeyPressed(IN_ATTACK2) == true
    local held = owner.KeyDown and owner:KeyDown(IN_ATTACK2) == true
    if state.latched and not pressed then
        return false, held and "button_held" or "button_not_released", state.nextUseAt
    end
    if pressed then state.latched = false end
    state.latched = true
    if now < (state.nextUseAt or 0) then return false, "use_cooldown", state.nextUseAt end
    state.nextUseAt = now + useDelay()
    return true, nil, state.nextUseAt
end

hook.Remove("Think", "mcitem_farming_release_player_use")
hook.Add("Think", "mcitem_farming_release_player_use", function()
    for owner, state in pairs(Farming.PlayerUseStates) do
        if not IsValid(owner) then
            Farming.PlayerUseStates[owner] = nil
        elseif not owner:KeyDown(IN_ATTACK2) then
            state.latched = false
        end
    end
end)

hook.Remove("PlayerDisconnected", "mcitem_farming_clear_player_use")
hook.Add("PlayerDisconnected", "mcitem_farming_clear_player_use", function(owner)
    Farming.PlayerUseStates[owner] = nil
end)

local function consumeItem(owner, weapon, definition, context)
    local handled = hook.Run(
        "MCITEM.ConsumeFarmingItem", owner, weapon, definition.id, 1, context)
    if handled == false then
        if ErrorNoHalt then
            ErrorNoHalt("[MCITEM] farming world transaction committed but item consumption failed\n")
        end
        return false
    end
    return true
end

local function canConsumeItem(owner, weapon, definition, context)
    return hook.Run(
        "MCITEM.CanConsumeFarmingItem", owner, weapon, definition.id, 1, context) ~= false
end

function Farming.BroadcastGrowthParticles(bx, by, bz, count)
    count = math.Clamp(math.floor(tonumber(count) or Farming.GrowthParticleCount or 15), 0, 63)
    if count <= 0 then return end
    net.Start(NET_GROWTH)
    net.WriteInt(math.floor(bx), 32)
    net.WriteInt(math.floor(by), 32)
    net.WriteInt(math.floor(bz), 32)
    net.WriteUInt(count, 6)
    net.Broadcast()
end

local function confirmUseSwing(owner)
    if not IsValid(owner) or not owner:IsPlayer() then return end
    net.Start(NET_USE_SWING)
    net.Send(owner)
end

function Farming.TryUse(weapon, definition)
    if not IsValid(weapon) or not istable(definition) then return false, "invalid_item" end
    local owner = weapon:GetOwner()
    if not IsValid(owner) or not owner:IsPlayer() then return false, "invalid_owner" end
    local context = Farming.ResolveUseContext(owner, definition)
    if not context then return false, "not_applicable" end
    if not canConsumeItem(owner, weapon, definition, context) then return false, "item_unavailable" end

    local api = MC and MC.API or nil
    local farmingApi = api and api.Farming or nil
    local ok, result
    if context.action == "plant" then
        if not farmingApi or not isfunction(farmingApi.Plant) then return false, "farming_api_unavailable" end
        ok, result = farmingApi.Plant(owner, context.bx, context.by, context.bz, context.crop, {
            source = "mcitem",
        })
        if ok ~= true then return false, result or "placement_rejected" end
        context.result = result
        consumeItem(owner, weapon, definition, context)
        confirmUseSwing(owner)
        hook.Run("MCITEM.CropPlanted", owner, weapon, definition, context)
        return true, result
    end

    if context.action == "bonemeal" then
        if not farmingApi or not isfunction(farmingApi.ApplyBonemeal) then
            return false, "farming_api_unavailable"
        end
        ok, result = farmingApi.ApplyBonemeal(owner, context.bx, context.by, context.bz, {
            source = "mcitem",
        })
    else
        ok, result = hook.Run(
            "MCITEM.ApplyBonemealTarget", owner, weapon,
            context.bx, context.by, context.bz, context.stateId, definition)
    end
    if ok ~= true then return false, result or "bonemeal_rejected" end
    context.result = result
    consumeItem(owner, weapon, definition, context)
    Farming.BroadcastGrowthParticles(
        context.bx, context.by, context.bz, Farming.GrowthParticleCount)
    confirmUseSwing(owner)
    hook.Run("MCITEM.CropBonemealed", owner, weapon, definition, context)
    return true, result
end
