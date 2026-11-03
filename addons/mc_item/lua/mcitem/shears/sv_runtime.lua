-- Server-authoritative ShearsItem entity/block interaction.
--
-- Entity shearing commits the selected ItemStack durability before changing
-- the BMB state. GrowingPlantHeadBlock uses the MineMod transaction bridge so
-- its age=25 world write and selected durability publish atomically.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Shears = MCITEM.Shears or {}

local Shears = MCITEM.Shears
local SURVIVAL_REACH_BLOCKS = 3
local CREATIVE_REACH_BONUS_BLOCKS = 2
local BLOCK_INFRASTRUCTURE = {
    mc_chunk = true,
    mc_chunk_phys = true,
    mc_collision_carrier = true,
    mc_item_drop = true,
}

local function apiParts()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    local stackApi = api and api.ItemStack
    if not api or not inventory then return nil end
    return api, inventory, stackApi
end

local function interactionReach(owner, api, inventory)
    local blockSize = MCITEM.BlockSize()
    local infinite = inventory and isfunction(inventory.HasInfiniteMaterials)
        and inventory.HasInfiniteMaterials(owner) == true
    return blockSize * (SURVIVAL_REACH_BLOCKS + (infinite and CREATIVE_REACH_BONUS_BLOCKS or 0))
end

local function aabbDistanceSqr(position, mins, maxs)
    local x = math.Clamp(position.x, mins.x, maxs.x)
    local y = math.Clamp(position.y, mins.y, maxs.y)
    local z = math.Clamp(position.z, mins.z, maxs.z)
    local dx, dy, dz = position.x - x, position.y - y, position.z - z
    return dx * dx + dy * dy + dz * dz
end

function Shears.TraceEntityTarget(owner, weapon, api, inventory)
    local reach = interactionReach(owner, api, inventory)
    local eye = owner:EyePos()
    local trace = util.TraceLine({
        start = eye,
        endpos = eye + owner:GetAimVector() * reach,
        filter = { owner, weapon },
        mask = MASK_SHOT or MASK_SOLID,
    })
    local target = trace and trace.Entity or nil
    if not IsValid(target) then return nil, nil, false end

    local className = target.GetClass and target:GetClass() or ""
    local infrastructure = BLOCK_INFRASTRUCTURE[className]
        or (MCITEM.CombatInfrastructureClasses and MCITEM.CombatInfrastructureClasses[className])
    if infrastructure then return nil, nil, false end

    if not Shears.IsShearableTarget(target) then return nil, "entity_not_shearable", true end
    local mins, maxs = target:WorldSpaceAABB()
    if not mins or not maxs or aabbDistanceSqr(eye, mins, maxs) >= reach * reach then
        return nil, "target_out_of_range", true
    end
    return target, nil, true
end

local function selectedDurabilityCommit(owner, weapon, inventory, stackApi, context)
    if not context and not MCITEM.Utility.IsInventoryProxy(weapon) then
        return true, false, false
    end
    if not isfunction(inventory.GetSelected) or not isfunction(inventory.DamageSelected)
        or not stackApi or not isfunction(stackApi.Hash) then
        return false, false, false, "shears_inventory_api_unavailable"
    end

    local stack = context and context.useStack.stack or inventory.GetSelected(owner)
    if not istable(stack) or stack.item ~= "minecraft:shears" then
        return false, false, false, "selected_shears_missing"
    end
    local stackHash, hashError = stackApi.Hash(stack)
    if not stackHash then return false, false, false, hashError or "shears_hash_failed" end
    local result, broken, err = inventory.DamageSelected(owner, 1, {
        hand = context and context.hand,
        expectedItem = "minecraft:shears",
        expectedClass = context and context.hand == "offhand" and weapon:GetClass() or nil,
        expectedStackHash = stackHash,
        expectedSlot = context and context.useStack.expectedSlot,
        reason = "mcitem_shears_entity",
    })
    if result then return true, broken == true, false, nil, stack end
    if err == "infinite_materials" then return true, false, true, nil, stack end
    return false, false, false, err or "shears_durability_failed"
end

local function playShearSound(api, target, eventName)
    local soundApi = api and api.Sound
    if soundApi and isfunction(soundApi.Play) then
        local played = soundApi.Play(eventName, target:WorldSpaceCenter(), {
            volume = 1,
            pitch = 1,
            soundLevel = 72,
        })
        if played == true then return end
    end
    if isfunction(target.GetBMBShearingSoundFile) then
        local path, pitch, volume = target:GetBMBShearingSoundFile(eventName)
        if isstring(path) and path ~= "" and target.EmitSound then
            target:EmitSound(
                path,
                72,
                math.Clamp(math.floor((tonumber(pitch) or 1) * 100 + 0.5), 1, 255),
                tonumber(volume) or 1
            )
            return
        end
    end
    if target.EmitSound then target:EmitSound("mc/mob/sheep/shear.ogg", 72, 100, 1) end
end

local function spawnDrops(api, inventory, owner, target, drops)
    local blockSize = api and api.Coords and isfunction(api.Coords.BlockSize)
        and tonumber(api.Coords.BlockSize()) or 36.5
    local position = target:GetBMBShearingDropOrigin(blockSize)
    for _, drop in ipairs(drops) do
        local velocity = target.GetBMBShearingDropVelocity
            and target:GetBMBShearingDropVelocity(blockSize) or nil
        local entity, err = inventory.SpawnDrop(position, drop.item, drop.count or 1, owner, {
            pickupDelay = 0.5,
            noMerge = true,
            velocity = velocity,
        })
        if not IsValid(entity) and ErrorNoHalt then
            ErrorNoHalt("[MCITEM] shearing drop failed: " .. tostring(err or drop.item) .. "\n")
        end
    end
end

function Shears.UseEntity(owner, weapon, target, context)
    if not Shears.IsShearableTarget(target) then return false, "target_not_ready" end
    if not isfunction(target.RollBMBShearingDrops)
        or not isfunction(target.SetBMBSheared)
        or not isfunction(target.GetBMBShearingDropOrigin)
        or not isfunction(target.GetBMBShearingSoundEvent) then
        return false, "incomplete_shearable_contract"
    end

    local api, inventory, stackApi = apiParts()
    if not api or not isfunction(inventory.SpawnDrop) then
        return false, "inventory_drop_api_unavailable"
    end

    local okDrops, drops = pcall(target.RollBMBShearingDrops, target)
    if not okDrops or not istable(drops) or #drops == 0 then return false, "invalid_shearing_drops" end
    local committed, broken, infinite, durabilityError, stack = selectedDurabilityCommit(
        owner,
        weapon,
        inventory,
        stackApi,
        context
    )
    if not committed then return false, durabilityError end

    -- No yield occurs between the final readiness check and this setter. BMB's
    -- state write is deliberately infallible after the inventory commit.
    if not Shears.IsShearableTarget(target) or target:SetBMBSheared(true) ~= true then
        return false, "shearing_target_changed"
    end
    playShearSound(api, target, target:GetBMBShearingSoundEvent())
    spawnDrops(api, inventory, owner, target, drops)
    hook.Run("MCITEM.EntitySheared", owner, target, drops, stack, broken, infinite)
    return true, {
        target = target,
        drops = drops,
        broken = broken == true,
        infinite = infinite == true,
    }
end

function Shears.UseBlock(owner, weapon, api, context)
    local shearsApi = api and api.Shears
    if not shearsApi then return false, "shears_block_api_unavailable" end
    local proxy = MCITEM.Utility and MCITEM.Utility.IsInventoryProxy
        and MCITEM.Utility.IsInventoryProxy(weapon)
    if (proxy or context) and isfunction(shearsApi.UseSelectedOnBlock) then
        return shearsApi.UseSelectedOnBlock(owner, {
            hand = context and context.hand,
            expectedClass = context and context.hand == "offhand" and weapon:GetClass() or nil,
            expectedStackHash = context and context.useStack.expectedStackHash,
            expectedSlot = context and context.useStack.expectedSlot,
            reason = "mcitem_shears_growing_plant",
        })
    end
    if isfunction(shearsApi.MaxAgePlant) then
        return shearsApi.MaxAgePlant(owner, { reason = "mcitem_shears_growing_plant" })
    end
    return false, "shears_block_api_unavailable"
end

function Shears.Use(owner, weapon, context)
    if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then
        return false, "invalid_owner"
    end
    if not IsValid(weapon) or owner:GetActiveWeapon() ~= weapon then
        return false, "inactive_weapon"
    end

    local api, inventory = apiParts()
    if not api then return false, "mcswep_api_unavailable" end
    local target, targetError, entityHit = Shears.TraceEntityTarget(owner, weapon, api, inventory)
    if target then return Shears.UseEntity(owner, weapon, target, context) end
    if entityHit then return false, targetError end
    return Shears.UseBlock(owner, weapon, api, context)
end

return Shears
