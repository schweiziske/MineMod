-- Server-authoritative NameTagItem#interactLivingEntity bridge.
--
-- Java sets the custom name, marks Mob persistence, then shrinks the stack.
-- Across two addons we cannot make the entity and container one transaction,
-- so every fallible validation is completed first and the authoritative held
-- stack is committed before the infallible NW2/name write.  This prevents a
-- failed inventory commit from creating a free permanent name.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.NameTags = MCITEM.NameTags or {}

local NameTags = MCITEM.NameTags
local SURVIVAL_REACH_BLOCKS = 3
local CREATIVE_REACH_BONUS_BLOCKS = 2

local function apiParts()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    local stackApi = api and api.ItemStack
    if not api or not inventory or not stackApi then return nil end
    return api, inventory, stackApi
end

function NameTags.EntityInteractionReach(owner, api, inventory)
    local blockSize = MCITEM.BlockSize()
    local infinite = inventory and isfunction(inventory.HasInfiniteMaterials)
        and inventory.HasInfiniteMaterials(owner) == true
    return blockSize * (SURVIVAL_REACH_BLOCKS + (infinite and CREATIVE_REACH_BONUS_BLOCKS or 0))
end

function NameTags.TraceTarget(owner, weapon, api, inventory)
    if not IsValid(owner) or not owner:Alive() then return nil, "invalid_owner" end
    local reach = NameTags.EntityInteractionReach(owner, api, inventory)
    return NameTags.FindAimTarget(owner, weapon, reach, true)
end

function NameTags.Use(owner, weapon, context)
    if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then
        return false, "invalid_owner"
    end
    if not IsValid(weapon) or owner:GetActiveWeapon() ~= weapon then
        return false, "inactive_weapon"
    end
    if not context and not MCITEM.Utility.IsInventoryProxy(weapon) then
        return false, "inventory_name_tag_required"
    end

    local api, inventory, stackApi = apiParts()
    if not api then return false, "inventory_api_unavailable" end
    if not isfunction(inventory.GetSelected) or not isfunction(inventory.ConsumeSelected)
        or not isfunction(inventory.HasInfiniteMaterials)
        or not isfunction(stackApi.GetCustomName) then
        return false, "name_tag_api_unavailable"
    end

    local stack = context and context.useStack.stack or inventory.GetSelected(owner)
    if not istable(stack) or stack.item ~= "minecraft:name_tag" then
        return false, "selected_name_tag_missing"
    end
    local customName, present, nameError = stackApi.GetCustomName(stack)
    if nameError then return false, nameError end
    if present ~= true or customName == nil or customName == "" then
        return false, "name_tag_has_no_custom_name"
    end
    if not isfunction(stackApi.Hash) then return false, "name_tag_api_unavailable" end
    local stackHash, hashError = stackApi.Hash(stack)
    if not stackHash then return false, hashError or "name_tag_hash_failed" end

    local target, targetError = NameTags.TraceTarget(owner, weapon, api, inventory)
    if not target then return false, targetError end

    -- ConsumeSelected validates identity before its creative exemption, so a
    -- stale creative snapshot cannot apply a name from an item no longer held.
    local result, consumed, _, _, consumeError = inventory.ConsumeSelected(owner, 1, nil, {
        hand = context and context.hand or "mainhand", expectedItem = "minecraft:name_tag",
        expectedStackHash = stackHash, expectedSlot = context and context.useStack.expectedSlot,
        reason = "mcitem_name_tag_use",
    })
    if not result or consumed ~= 1 then return false, consumeError or "name_tag_consume_failed" end

    if not NameTags.SetEntityCustomName(target, customName) then
        return false, "name_tag_target_changed"
    end
    hook.Run("MCITEM.NameTagApplied", owner, target, customName, stack)
    return true, target, customName
end

return NameTags
