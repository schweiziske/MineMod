-- Server-authoritative liquid interaction + selected-slot transaction bridge.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Buckets = MCITEM.Buckets or {}

local Buckets = MCITEM.Buckets

-- A successful survival bucket mutation replaces the selected ItemStack and
-- therefore swaps weapon_mcitem_bucket <-> weapon_mcitem_*_bucket.  A cooldown
-- stored on the old SWEP cannot survive that class change: weapon_base may see
-- the still-held IN_ATTACK2 on the new instance and immediately perform the
-- inverse action.  Keep the use edge and delay on the player instead.
Buckets.PlayerUseStates = Buckets.PlayerUseStates or setmetatable({}, { __mode = "k" })

local function bucketUseDelay()
    return math.max(0, tonumber(Buckets.RightClickDelayTicks) or 4)
        * math.max(0, tonumber(MCITEM.TickSeconds) or 0.05)
end

function Buckets.TryBeginPlayerUse(owner)
    if not IsValid(owner) or not owner:IsPlayer() then return false, "invalid_owner" end

    local now = CurTime()
    local state = Buckets.PlayerUseStates[owner]
    if not state then
        state = { latched = false, nextUseAt = 0 }
        Buckets.PlayerUseStates[owner] = state
    end

    local pressed = owner.KeyPressed and owner:KeyPressed(IN_ATTACK2) == true
    local held = owner.KeyDown and owner:KeyDown(IN_ATTACK2) == true

    -- KeyPressed proves that this is a new physical press even if a very short
    -- release happened between two server Think passes.  Merely inheriting the
    -- held key on a newly selected bucket class never clears the latch.
    if state.latched and not pressed then
        return false, held and "button_held" or "button_not_released", state.nextUseAt
    end
    if pressed then state.latched = false end

    state.latched = true
    if now < (state.nextUseAt or 0) then
        return false, "use_cooldown", state.nextUseAt
    end

    state.nextUseAt = now + bucketUseDelay()
    return true, nil, state.nextUseAt
end

hook.Add("Think", "mcitem_bucket_release_player_use", function()
    for owner, state in pairs(Buckets.PlayerUseStates) do
        if not IsValid(owner) then
            Buckets.PlayerUseStates[owner] = nil
        elseif not owner:KeyDown(IN_ATTACK2) then
            state.latched = false
        end
    end
end)

hook.Add("PlayerDisconnected", "mcitem_bucket_clear_player_use", function(owner)
    Buckets.PlayerUseStates[owner] = nil
end)

local function namespaced(itemId)
    if not isstring(itemId) or itemId == "" then return nil end
    return string.find(itemId, ":", 1, true) and itemId or "minecraft:" .. itemId
end

local function apiParts()
    local api = MC and MC.API
    return api, api and api.Inventory, api and api.Liquid
end

local function stackMatches(stack, itemId)
    return istable(stack) and stack.item == namespaced(itemId) and (tonumber(stack.count) or 0) >= 1
end

local function selectedReady(owner, weapon, itemId, context)
    if not IsValid(owner) or not IsValid(weapon) or owner:GetActiveWeapon() ~= weapon then
        return nil, nil, "inactive_weapon"
    end
    local _, inventory = apiParts()
    if not inventory or not isfunction(inventory.GetSelected)
    or not isfunction(inventory.ConsumeSelected) then return nil, nil, "inventory_api_unavailable" end
    local stack, err
    if context and context.hand == "offhand" and MC.SV and MC.SV.GetPlayerHandStack then
        stack = MC.SV.GetPlayerHandStack(owner, "offhand")
    else
        local selectedStack, _, selectedError = inventory.GetSelected(owner)
        stack, err = selectedStack, selectedError
    end
    if not stackMatches(stack, itemId) then return nil, nil, err or "selected_item_mismatch" end
    return inventory, stack
end

local function rollback(liquid, method, owner, worldResult, reason)
    local callback = liquid and liquid[method]
    local ok, err
    if isfunction(callback) then
        ok, err = callback(owner, worldResult)
    else
        ok, err = false, "rollback_unavailable"
    end
    if ok ~= true and ErrorNoHalt then
        ErrorNoHalt("[MCITEM] bucket " .. tostring(reason) .. " rollback failed: " .. tostring(err) .. "\n")
    end
    return false, reason
end

local function hasItem(inventory, owner, itemId)
    local snapshot = inventory.Get(owner)
    if not istable(snapshot) or not istable(snapshot.slots) then return false end
    local expected = namespaced(itemId)
    for _, stack in pairs(snapshot.slots) do
        if istable(stack) and stack.item == expected and (tonumber(stack.count) or 0) > 0 then return true end
    end
    return false
end

local function giveCreativeFilledBucket(inventory, owner, itemId)
    -- ItemUtils.createFilledResult(..., true): keep the empty bucket and add one
    -- filled result only if the creative inventory does not already contain it.
    if hasItem(inventory, owner, itemId) then return true end
    local _, _, err = inventory.Give(owner, namespaced(itemId), 1)
    -- ItemUtils ignores Inventory.add's false result in this creative branch:
    -- a completely full inventory can therefore lose the newly filled result.
    if err then return false, err end
    return true
end

local function consumeSelected(inventory, owner, weapon, itemId, replacement, reason, context)
    local expectedClass = weapon:GetClass()
    if context then expectedClass = context.expectedClass end
    local result, consumed, overflow, infinite, err = inventory.ConsumeSelected(
        owner, 1, namespaced(replacement), {
            hand = context and context.hand,
            expectedItem = namespaced(itemId),
            expectedClass = expectedClass,
            reason = reason,
            dropOverflow = true,
        })
    if result or infinite then return true, infinite == true end
    return false, false, err or (overflow and "replacement_overflow") or "consume_failed"
end

function Buckets.FindMilkTarget(owner)
    if not IsValid(owner) then return nil end
    local blockSize = MCITEM.BlockSize and MCITEM.BlockSize() or 36.5
    -- Player.DEFAULT_ENTITY_INTERACTION_RANGE is 3 blocks.  Creative mode's
    -- block/entity interaction range attribute adds 2 more; infinite materials
    -- by itself does not.  Keep this identical to mc_item_hand's entity trace.
    local creative = MC and MC.SV and isfunction(MC.SV.PlayerIsCreative)
        and MC.SV.PlayerIsCreative(owner) == true
    local reachBlocks = 3 + (creative and 2 or 0)
    local trace = util.TraceLine({
        start = owner:GetShootPos(),
        endpos = owner:GetShootPos() + owner:GetAimVector() * (blockSize * reachBlocks),
        filter = owner,
        mask = MASK_SHOT,
    })
    return IsValid(trace.Entity) and trace.Entity or nil
end

function Buckets.UseLiquidBucket(weapon, definition, context)
    if not IsValid(weapon) or not istable(definition) then return false, "invalid_bucket" end
    local owner = weapon:GetOwner()
    local inventory, _, readyError = selectedReady(owner, weapon, definition.id, context)
    if not inventory then return false, readyError end
    local _, _, liquid = apiParts()
    if not liquid then return false, "liquid_api_unavailable" end

    if definition.pickup == true then
        if not isfunction(liquid.PickupSource) then return false, "pickup_api_unavailable" end
        local worldResult, worldError = liquid.PickupSource(owner)
        if not worldResult then return false, worldError end
        local filledItem = Buckets.ItemForLiquid(worldResult.kind)
        if not filledItem then return rollback(liquid, "RollbackPickup", owner, worldResult, "unknown_liquid") end

        local infinite = isfunction(inventory.HasInfiniteMaterials)
            and inventory.HasInfiniteMaterials(owner) == true
        local itemOK, itemError
        if infinite then
            itemOK, itemError = giveCreativeFilledBucket(inventory, owner, filledItem)
        else
            itemOK, _, itemError = consumeSelected(
                inventory, owner, weapon, definition.id, filledItem, "mcitem_bucket_pickup", context)
        end
        if itemOK ~= true then
            return rollback(liquid, "RollbackPickup", owner, worldResult, itemError or "inventory_failed")
        end
        if isfunction(liquid.CommitPickup) then liquid.CommitPickup(owner, worldResult) end
        Buckets.PlaySound(owner, worldResult.kind == "lava" and "fill_lava" or "fill")
        hook.Run("MCITEM.BucketPickedUpFluid", owner, weapon, definition, worldResult, filledItem)
        return true, worldResult
    end

    if not definition.liquid or not isfunction(liquid.PlaceSource) then
        return false, "placement_api_unavailable"
    end
    local worldResult, worldError = liquid.PlaceSource(owner, definition.liquid)
    if not worldResult then return false, worldError end
    local itemOK, _, itemError = consumeSelected(
        inventory, owner, weapon, definition.id, definition.replacement, "mcitem_bucket_place", context)
    if itemOK ~= true then
        return rollback(liquid, "RollbackPlacement", owner, worldResult, itemError or "inventory_failed")
    end
    if isfunction(liquid.CommitPlacement) then liquid.CommitPlacement(owner, worldResult) end
    Buckets.PlaySound(owner, definition.liquid == "lava" and "empty_lava" or "empty")
    hook.Run("MCITEM.BucketPlacedFluid", owner, weapon, definition, worldResult)
    return true, worldResult
end

function Buckets.FillMilkBucket(player, target, context)
    local weapon = IsValid(player) and player:GetActiveWeapon() or nil
    if not IsValid(weapon) then return nil end
    if not (context and context.hand == "offhand") and weapon.MCBucketID ~= "bucket" then return nil end
    local inventory, _, err = selectedReady(player, weapon, "bucket", context)
    if not inventory then return false, err end
    local infinite = isfunction(inventory.HasInfiniteMaterials)
        and inventory.HasInfiniteMaterials(player) == true
    local ok, mutationError
    if infinite then
        ok, mutationError = giveCreativeFilledBucket(inventory, player, "milk_bucket")
    else
        ok, _, mutationError = consumeSelected(
            inventory, player, weapon, "bucket", "milk_bucket", "mcitem_bucket_milk", context)
    end
    if ok ~= true then return false, mutationError end
    hook.Run("MCITEM.EntityMilked", player, target, context)
    return true
end
