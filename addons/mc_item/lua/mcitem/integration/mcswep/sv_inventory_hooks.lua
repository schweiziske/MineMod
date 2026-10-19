-- Selected-slot durability and consumption hooks for MCSWEP inventories.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.MCSWEP = MCITEM.MCSWEP or {}

local Integration = MCITEM.MCSWEP

hook.Add("MC.HandWeaponStackBound", "MCITEM.MCSWEP.StackLifecycle", function(owner, weapon, stack)
    local record = MC.SV.GetPlayerInventoryRecord(owner, false)
    if not record then return end
    local slot, hash = record.selected, MC.ItemStackHash(stack)
    if weapon.MCInventoryBoundSlot == slot and weapon.MCInventoryBoundHash == hash then return end
    local changedSlot = weapon.MCInventoryBoundSlot ~= slot
    weapon.MCInventoryBoundSlot, weapon.MCInventoryBoundHash = slot, hash
    if changedSlot then
        weapon:SetNW2Int("MCITEM_StackBindingRevision", weapon:GetNW2Int("MCITEM_StackBindingRevision", 0) + 1)
        if MCITEM.Food then MCITEM.Food.CancelUse(weapon, "selected_slot_changed") end
        if MCITEM.Potions then MCITEM.Potions.CancelDrink(weapon, "selected_slot_changed") end
        if weapon.FinishMCCrossbowUse then weapon:FinishMCCrossbowUse() end
        if weapon.MCEndSpearUse then weapon:MCEndSpearUse() end
        if weapon.SetMCThirdPersonUseState then weapon:SetMCThirdPersonUseState(false) end
        weapon.MCUsing = false
        weapon.MCUseStartedAt = nil
    end
    if weapon.RefreshMCChargedProjectile then weapon:RefreshMCChargedProjectile() end
end)

local POTION_ITEMS = {
    drinkable = "minecraft:potion",
    splash = "minecraft:splash_potion",
    lingering = "minecraft:lingering_potion",
}

local function namespaced(identifier)
    if not isstring(identifier) or identifier == "" then return nil end
    return string.find(identifier, ":", 1, true) and identifier or "minecraft:" .. identifier
end

local function apiParts()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    local handWeapon = api and api.HandWeapon
    if not inventory or not handWeapon then return nil end
    return inventory, handWeapon
end

hook.Add("MCITEM.UseHeldStack", "MCITEM.MCSWEP.UseHeldStack", function(owner, stack, hand)
    if not istable(stack) then return nil end
    local weapon = owner:GetActiveWeapon()
    local record = MC.SV.GetPlayerInventoryRecord(owner, false)
    if not record or not IsValid(weapon) then return false, "inventory_unavailable" end
    local context = { hand = hand, useStack = {
        stack = table.Copy(stack), expectedStackHash = MC.ItemStackHash(stack),
        expectedSlot = hand == "offhand" and 40 or record.selected,
    } }
    local throwable = MCITEM.Throwables and MCITEM.Throwables.Get(stack.item)
    if throwable then
        context.definition = throwable
        return IsValid(MCITEM.Throwables.Use(weapon, context)), "throwable"
    end
    if stack.item == "minecraft:splash_potion" or stack.item == "minecraft:lingering_potion" then
        local potionId = Integration.BasePotionID(stack)
        context.definition = potionId and MCITEM.Potions.Get(potionId)
        if not context.definition then return false, "potion_contents_unsupported" end
        context.bottleType = stack.item == "minecraft:splash_potion" and "splash" or "lingering"
        return IsValid(MCITEM.Potions.Throw(weapon, context)), "potion_throw"
    end
    local farming = MCITEM.Farming and MCITEM.Farming.Get(stack.item)
    if farming then
        local used, result = MCITEM.Farming.TryUse(weapon, farming, context)
        -- Plantable food still runs Item.use when useOn has no target (PASS).
        -- Keep genuine transaction/permission failures as explicit rejections.
        if not used and result == "not_applicable" then return nil end
        return used, result
    end
    local action = string.match(stack.item, "_(hoe)$") or string.match(stack.item, "_(shovel)$")
        or string.match(stack.item, "_(axe)$")
    if action then return MCITEM.BlockInteract.UseToolOnBlock(owner, weapon, action, context) end
    if stack.item == "minecraft:shears" then return MCITEM.Shears.Use(owner, weapon, context) end
    if stack.item == "minecraft:name_tag" then return MCITEM.NameTags.Use(owner, weapon, context) end
end)

local function selectedMatchesWeapon(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) or owner:GetActiveWeapon() ~= weapon then return false end
    if not weapon.GetNW2Bool or not weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then return false end
    local inventory, handWeapon = apiParts()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(handWeapon.Resolve) then return false end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) then return false end
    return handWeapon.Resolve(stack, owner) == weapon:GetClass()
end

local function reportMutationError(kind, err)
    local message = tostring(kind) .. ":" .. tostring(err or "unknown")
    if Integration.LastInventoryMutationError == message then return end
    Integration.LastInventoryMutationError = message
    if MC and MC.Fault then return MC.Fault("mcitem_inventory_mutation", "%s", message) end
    if ErrorNoHalt then ErrorNoHalt("[MCITEM] MCSWEP inventory bridge failed: " .. message .. "\n") end
end

hook.Add("MCITEM.CaptureUseStack", "MCITEM.MCSWEP.CaptureUseStack", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = apiParts()
    local stack = inventory.GetSelected(owner)
    local record = MC.SV.GetPlayerInventoryRecord(owner, false)
    return { stack = table.Copy(stack), expectedStackHash = MC.ItemStackHash(stack),
        expectedSlot = record.selected }
end)

local function consumeSelected(kind, owner, weapon, expectedItem, amount, replacement, context)
    local explicitHand = context and context.useStack
    if not explicitHand and not selectedMatchesWeapon(owner, weapon) then
        if IsValid(weapon) and weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then return false end
        return nil
    end
    local inventory = apiParts()
    if not inventory or not isfunction(inventory.ConsumeSelected) then
        reportMutationError(kind, "consume_api_unavailable")
        return false
    end
    context = context or {}
    local captured = context.useStack or hook.Run("MCITEM.CaptureUseStack", owner, weapon)
    if captured then context.stack = captured.stack end
    local result, _, _, infinite, err = inventory.ConsumeSelected(owner, amount, namespaced(replacement), {
        expectedItem = expectedItem,
        expectedClass = (context.hand == "offhand" or selectedMatchesWeapon(owner, weapon)) and weapon:GetClass() or nil,
        reason = "mcitem_" .. kind,
        dropOverflow = true,
        expectedStackHash = captured and captured.expectedStackHash,
        expectedSlot = captured and captured.expectedSlot,
        hand = context.hand,
    })
    if result or infinite then return true end
    reportMutationError(kind, err)
    return false
end

local function canConsumeSelected(owner, weapon, expectedItem, amount, context)
    if context and context.useStack then
        local record = MC.SV.SelectedStackMatches(owner, {
            hand = context.hand, expectedItem = expectedItem,
            expectedStackHash = context.useStack.expectedStackHash,
            expectedSlot = context.useStack.expectedSlot,
            expectedClass = context.hand == "offhand" and weapon:GetClass() or nil,
        })
        return record ~= nil
    end
    if not IsValid(owner) or not IsValid(weapon) or not weapon.GetNW2Bool
        or not weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then return nil end
    if not selectedMatchesWeapon(owner, weapon) then return false end
    local inventory = apiParts()
    if not inventory or not isfunction(inventory.GetSelected) then return false end
    local stack = inventory.GetSelected(owner)
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    if not istable(stack) or stack.item ~= expectedItem or (tonumber(stack.count) or 0) < amount then
        return false
    end
    return true
end

hook.Remove("MCITEM.SWEPDurabilityDamage", "MCITEM.MCSWEP.DamageSelected")
hook.Add("MCITEM.SWEPDurabilityDamage", "MCITEM.MCSWEP.DamageSelected", function(weapon, owner, amount, context)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = apiParts()
    if not inventory or not isfunction(inventory.DamageSelected) then return nil end
    local reason = istable(context) and tostring(context.reason or "") or ""
    if reason == "" then reason = "durability" end
    if string.sub(reason, 1, 7) ~= "mcitem_" then reason = "mcitem_" .. reason end

    local result, broken, err = inventory.DamageSelected(owner, amount, {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        reason = reason,
        actionId = istable(context) and context.actionId or nil,
    })
    if result or err == "infinite_materials" then
        if broken and IsValid(weapon) then
            weapon.MCInventoryBreakRevision = (weapon.MCInventoryBreakRevision or 0) + 1
        end
        return true
    end
    reportMutationError("durability", err)
    return false
end)

hook.Remove("MCITEM.ConsumeFoodItem", "MCITEM.MCSWEP.ConsumeFood")
hook.Add("MCITEM.ConsumeFoodItem", "MCITEM.MCSWEP.ConsumeFood", function(owner, weapon, itemId, amount, replacement, context)
    return consumeSelected("food", owner, weapon, namespaced(itemId), amount, replacement, context)
end)

hook.Remove("MCITEM.ConsumeFarmingItem", "MCITEM.MCSWEP.ConsumeFarming")
hook.Add("MCITEM.ConsumeFarmingItem", "MCITEM.MCSWEP.ConsumeFarming", function(owner, weapon, itemId, amount, context)
    return consumeSelected("farming", owner, weapon, namespaced(itemId), amount, nil, context)
end)

hook.Remove("MCITEM.CanConsumeFarmingItem", "MCITEM.MCSWEP.CanConsumeFarming")
hook.Add("MCITEM.CanConsumeFarmingItem", "MCITEM.MCSWEP.CanConsumeFarming", function(owner, weapon, itemId, amount, context)
    return canConsumeSelected(owner, weapon, namespaced(itemId), amount, context)
end)

hook.Remove("MCITEM.ConsumePotionItem", "MCITEM.MCSWEP.ConsumePotion")
hook.Add("MCITEM.ConsumePotionItem", "MCITEM.MCSWEP.ConsumePotion", function(owner, weapon, bottleType, _, amount, replacement, context)
    local expectedItem = POTION_ITEMS[bottleType]
    if not expectedItem then return nil end
    return consumeSelected("potion", owner, weapon, expectedItem, amount, replacement, context)
end)

hook.Remove("MCITEM.ConsumeThrowableItem", "MCITEM.MCSWEP.ConsumeThrowable")
hook.Add("MCITEM.ConsumeThrowableItem", "MCITEM.MCSWEP.ConsumeThrowable", function(owner, weapon, definition, amount, context)
    local itemId = istable(definition) and definition.id or nil
    if not itemId then return nil end
    return consumeSelected("throwable", owner, weapon, namespaced(itemId), amount, nil, context)
end)

--------------------------------------------------------------------------------
-- 弓 / 弩的箭矢，三叉戟的投出与拾回
--------------------------------------------------------------------------------
--
-- 弹药走 MCSWEP 新增的 `MC.API.Inventory.HasAmmo / ConsumeAmmo`（见交接说明）：
-- 它复用 MCSWEP 自己那张 allowedAmmo 表、创造模式的 infinite materials 规则和
-- 同一套容器事务，所以外部 SWEP 不会长出第二套"什么算箭"的判断。

local function inventoryApi()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    if not istable(inventory) then return nil end
    if isfunction(api.IsReady) and not api.IsReady() then return nil end
    return inventory
end

hook.Remove("MCITEM.HasInventorySystem", "MCITEM.MCSWEP.HasInventory")
hook.Add("MCITEM.HasInventorySystem", "MCITEM.MCSWEP.HasInventory", function()
    if inventoryApi() then return true end
    return nil
end)

hook.Remove("MCITEM.HasInfiniteMaterials", "MCITEM.MCSWEP.HasInfiniteMaterials")
hook.Add("MCITEM.HasInfiniteMaterials", "MCITEM.MCSWEP.HasInfiniteMaterials", function(ply)
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.HasInfiniteMaterials) then return nil end
    local infinite, err = inventory.HasInfiniteMaterials(ply)
    if err and err ~= "invalid_player" then reportMutationError("infinite_materials", err) end
    return infinite == true
end)

hook.Remove("MCITEM.HasProjectileAmmo", "MCITEM.MCSWEP.HasAmmo")
hook.Add("MCITEM.HasProjectileAmmo", "MCITEM.MCSWEP.HasAmmo", function(owner, _weapon, kind)
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.HasAmmo) then return nil end
    return inventory.HasAmmo(owner, kind) == true
end)

hook.Remove("MCITEM.ConsumeProjectileAmmo", "MCITEM.MCSWEP.ConsumeAmmo")
hook.Add("MCITEM.ConsumeProjectileAmmo", "MCITEM.MCSWEP.ConsumeAmmo", function(owner, _weapon, kind, amount)
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.ConsumeAmmo) then return nil end
    local consumed, _, err, infinite = inventory.ConsumeAmmo(owner, kind, amount or 1, {
        reason = "mcitem_" .. tostring(kind),
    })
    if infinite then return true, true end
    if (consumed or 0) > 0 then return true, false end
    reportMutationError("ammo", err)
    return false, false
end)

hook.Remove("MCITEM.TakeProjectileAmmo", "MCITEM.MCSWEP.TakeAmmo")
hook.Add("MCITEM.TakeProjectileAmmo", "MCITEM.MCSWEP.TakeAmmo", function(owner, weapon, kind, amount)
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.TakeAmmo) then return nil end

    -- MCITEM does not implement firework projectiles. Its crossbow therefore
    -- uses the Java arrow predicate (normal + spectral) rather than MCSWEP's
    -- broader built-in crossbow predicate, which also includes rockets.
    local apiKind = kind == "crossbow" and "bow" or kind

    -- ProjectileWeaponItem.useAmmo first selects a real projectile stack, then
    -- applies the held weapon's AMMO_USE effects. Infinity sets the use count
    -- to zero only for a normal minecraft:arrow. Preserve that exact selected
    -- stack, skip the mutation, and mark the spawned arrow intangible. Empty
    -- survival inventories still fail, spectral arrows still reach TakeAmmo,
    -- and crossbows never enter this bow-only branch.
    local runtime = MCITEM.EnchantmentRuntime
    if kind == "bow" and selectedMatchesWeapon(owner, weapon)
        and runtime and isfunction(runtime.GetProjectileAmmoUse)
        and isfunction(inventory.GetSelected) and isfunction(inventory.SelectAmmo) then
        local weaponStack = inventory.GetSelected(owner)
        local projectileStack, _, _, generated = inventory.SelectAmmo(owner, apiKind)
        if istable(weaponStack) and istable(projectileStack)
            and runtime.GetProjectileAmmoUse(weaponStack, projectileStack, kind, amount or 1) <= 0 then
            return projectileStack, true, generated == true
        end
    end

    local stack, consumed, infinite, generated, err = inventory.TakeAmmo(
        owner, apiKind, amount or 1, { reason = "mcitem_" .. tostring(kind) })
    if istable(stack) and (consumed or 0) > 0 then
        return stack, infinite == true, generated == true
    end
    reportMutationError("ammo_stack", err)
    return false, false, false
end)

local function copyProjectileStacks(projectileStacks)
    if not istable(projectileStacks) then return nil end
    local copied = {}
    for _, projectileStack in ipairs(projectileStacks) do
        if istable(projectileStack) then
            local copy = table.Copy(projectileStack)
            copy.count = 1
            copied[#copied + 1] = copy
        end
    end
    return #copied > 0 and copied or nil
end

local function chargedComponents(stack, projectileStacks)
    local replacement = table.Copy(stack)
    replacement.components = istable(replacement.components) and table.Copy(replacement.components) or {}
    replacement.components["minecraft:charged_projectiles"] = copyProjectileStacks(projectileStacks)
    if next(replacement.components) == nil then replacement.components = nil end
    return replacement
end

hook.Remove("MCITEM.StoreChargedProjectiles", "MCITEM.MCSWEP.StoreChargedProjectiles")
hook.Add("MCITEM.StoreChargedProjectiles", "MCITEM.MCSWEP.StoreChargedProjectiles", function(
    owner, weapon, projectileStacks)
    if not selectedMatchesWeapon(owner, weapon) or not copyProjectileStacks(projectileStacks) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(inventory.ReplaceSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) then return false end
    local result, _, err = inventory.ReplaceSelected(owner, chargedComponents(stack, projectileStacks), {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(stack) or nil,
        mutateInInfinite = true,
        reason = "mcitem_crossbow_charge",
    })
    if result then return true end
    reportMutationError("crossbow_charge", err)
    return false
end)

hook.Remove("MCITEM.GetChargedProjectiles", "MCITEM.MCSWEP.GetChargedProjectiles")
hook.Add("MCITEM.GetChargedProjectiles", "MCITEM.MCSWEP.GetChargedProjectiles", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    local components = istable(stack) and stack.components or nil
    local charged = components and (components["minecraft:charged_projectiles"] or components.charged_projectiles) or nil
    return copyProjectileStacks(charged) or false
end)

hook.Remove("MCITEM.ClearChargedProjectiles", "MCITEM.MCSWEP.ClearChargedProjectiles")
hook.Add("MCITEM.ClearChargedProjectiles", "MCITEM.MCSWEP.ClearChargedProjectiles", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(inventory.ReplaceSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) then return false end
    local result, _, err = inventory.ReplaceSelected(owner, chargedComponents(stack, nil), {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(stack) or nil,
        mutateInInfinite = true,
        reason = "mcitem_crossbow_fire",
    })
    if result then return true end
    reportMutationError("crossbow_fire", err)
    return false
end)

hook.Remove("MCITEM.StoreChargedProjectile", "MCITEM.MCSWEP.StoreChargedProjectile")
hook.Add("MCITEM.StoreChargedProjectile", "MCITEM.MCSWEP.StoreChargedProjectile", function(owner, weapon, projectileStack)
    if not selectedMatchesWeapon(owner, weapon) or not istable(projectileStack) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(inventory.ReplaceSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) then return false end
    local result, _, err = inventory.ReplaceSelected(owner, chargedComponents(stack, { projectileStack }), {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(stack) or nil,
        mutateInInfinite = true,
        reason = "mcitem_crossbow_charge",
    })
    if result then return true end
    reportMutationError("crossbow_charge", err)
    return false
end)

hook.Remove("MCITEM.GetChargedProjectile", "MCITEM.MCSWEP.GetChargedProjectile")
hook.Add("MCITEM.GetChargedProjectile", "MCITEM.MCSWEP.GetChargedProjectile", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    local components = istable(stack) and stack.components or nil
    local charged = components and (components["minecraft:charged_projectiles"] or components.charged_projectiles) or nil
    local projectile = istable(charged) and charged[1] or nil
    return istable(projectile) and table.Copy(projectile) or false
end)

hook.Remove("MCITEM.ClearChargedProjectile", "MCITEM.MCSWEP.ClearChargedProjectile")
hook.Add("MCITEM.ClearChargedProjectile", "MCITEM.MCSWEP.ClearChargedProjectile", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(inventory.ReplaceSelected) then return nil end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) then return false end
    local result, _, err = inventory.ReplaceSelected(owner, chargedComponents(stack, nil), {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(stack) or nil,
        mutateInInfinite = true,
        reason = "mcitem_crossbow_fire",
    })
    if result then return true end
    reportMutationError("crossbow_fire", err)
    return false
end)

hook.Remove("MCITEM.LoadCrossbowProjectiles", "MCITEM.MCSWEP.LoadCrossbowProjectiles")
hook.Add("MCITEM.LoadCrossbowProjectiles", "MCITEM.MCSWEP.LoadCrossbowProjectiles", function(
    owner, weapon, projectileCount)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.LoadCrossbowProjectiles) then return nil end

    -- MCITEM still has no firework projectile entity, so its external crossbow
    -- intentionally selects only normal/spectral arrows. MCSWEP's generic API
    -- retains full rocket support for its own projectile path.
    local stacks, infinite, generated, _, err = inventory.LoadCrossbowProjectiles(
        owner,
        "bow",
        projectileCount,
        {
            expectedItem = namespaced(weapon.MCItemID),
            expectedClass = weapon:GetClass(),
            reason = "mcitem_crossbow_charge",
        })
    if copyProjectileStacks(stacks) then
        return stacks, infinite == true, generated == true
    end
    reportMutationError("crossbow_charge", err)
    return false, false, false
end)

hook.Remove("MCITEM.LoadCrossbowProjectile", "MCITEM.MCSWEP.LoadCrossbowProjectile")
hook.Add("MCITEM.LoadCrossbowProjectile", "MCITEM.MCSWEP.LoadCrossbowProjectile", function(owner, weapon)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.LoadCrossbowProjectile) then return nil end

    -- MCITEM has no firework projectile implementation, so use the bow ammo
    -- predicate (normal + spectral arrows) for its external crossbow.
    local stack, infinite, generated, _, err = inventory.LoadCrossbowProjectile(owner, "bow", {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        reason = "mcitem_crossbow_charge",
    })
    if istable(stack) then return stack, infinite == true, generated == true end
    reportMutationError("crossbow_charge", err)
    return false, false, false
end)

local function projectileHashes(projectileStacks)
    if not MC or not isfunction(MC.ItemStackHash) then return nil end
    local hashes = {}
    for _, projectileStack in ipairs(projectileStacks or {}) do
        hashes[#hashes + 1] = MC.ItemStackHash(projectileStack)
    end
    return hashes
end

hook.Remove("MCITEM.CommitCrossbowProjectilesShot", "MCITEM.MCSWEP.CommitCrossbowProjectilesShot")
hook.Add("MCITEM.CommitCrossbowProjectilesShot", "MCITEM.MCSWEP.CommitCrossbowProjectilesShot", function(
    owner, weapon, projectileStacks, context)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected)
        or not isfunction(inventory.CommitCrossbowProjectilesShot) then return nil end

    local selected = inventory.GetSelected(owner)
    if not istable(selected) or not copyProjectileStacks(projectileStacks) then return false, false end
    local result, broken, _, _, err = inventory.CommitCrossbowProjectilesShot(owner, {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(selected) or nil,
        expectedProjectileHashes = projectileHashes(projectileStacks),
        reason = "mcitem_" .. tostring(istable(context) and context.reason or "crossbow_shot"),
        actionId = istable(context) and context.actionId or nil,
    })
    if result then return true, broken == true end
    reportMutationError("crossbow_shot", err)
    return false, false
end)

hook.Remove("MCITEM.CommitCrossbowShot", "MCITEM.MCSWEP.CommitCrossbowShot")
hook.Add("MCITEM.CommitCrossbowShot", "MCITEM.MCSWEP.CommitCrossbowShot", function(
    owner, weapon, projectileStack, durabilityAmount, context)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.GetSelected)
        or not isfunction(inventory.CommitCrossbowShot) then return nil end

    local selected = inventory.GetSelected(owner)
    if not istable(selected) or not istable(projectileStack) then return false, false end
    local result, broken, _, _, err = inventory.CommitCrossbowShot(owner, durabilityAmount or 1, {
        expectedItem = namespaced(weapon.MCItemID),
        expectedClass = weapon:GetClass(),
        expectedStackHash = MC and MC.ItemStackHash and MC.ItemStackHash(selected) or nil,
        expectedProjectileHash = MC and MC.ItemStackHash and MC.ItemStackHash(projectileStack) or nil,
        reason = "mcitem_" .. tostring(istable(context) and context.reason or "crossbow_shot"),
        actionId = istable(context) and context.actionId or nil,
    })
    if result then return true, broken == true end
    reportMutationError("crossbow_shot", err)
    return false, false
end)

-- MCSWEP's built-in bow/crossbow entity fires MC.ProjectileImpact after its
-- own damage transaction. Add SpectralArrow#doPostHurtEffects here so both the
-- built-in projectile and MCITEM's 3D arrow grant Glowing I for 200 ticks.
hook.Remove("MC.ProjectileImpact", "MCITEM.MCSWEP.SpectralArrowEffect")
hook.Add("MC.ProjectileImpact", "MCITEM.MCSWEP.SpectralArrowEffect", function(projectile, _, target)
    if not IsValid(projectile) or not IsValid(target) then return end
    if not projectile.GetProjectileItemName
        or projectile:GetProjectileItemName() ~= "minecraft:spectral_arrow" then return end
    local potions = MCITEM.Potions
    if not potions or not isfunction(potions.ApplyEffect) then return end
    local owner = projectile:GetOwner()
    potions.ApplyEffect(target, {
        id = "glowing",
        durationTicks = 200,
        amplifier = 0,
        ambient = false,
        visible = true,
        showIcon = true,
    }, IsValid(owner) and owner or projectile, {
        reason = "spectral_arrow",
        projectile = projectile,
    })
end)

-- 投出去的三叉戟：把选中槽那一件拿走（不留 replacement）。
hook.Remove("MCITEM.ConsumeThrownWeapon", "MCITEM.MCSWEP.ConsumeThrownWeapon")

hook.Remove("MCITEM.CanThrowWeaponStack", "MCITEM.MCSWEP.CanThrowWeaponStack")
hook.Add("MCITEM.CanThrowWeaponStack", "MCITEM.MCSWEP.CanThrowWeaponStack", function(owner, weapon, itemId, durabilityAmount)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.CanTakeSelectedWithDurability) then return nil end
    local allowed, infinite, _, err = inventory.CanTakeSelectedWithDurability(owner, durabilityAmount or 1, {
        expectedItem = namespaced(itemId),
        expectedClass = weapon:GetClass(),
    })
    if allowed then return true, infinite == true end
    if err ~= "selected_item_would_break" then reportMutationError("thrown_weapon_preflight", err) end
    return false, false
end)

hook.Remove("MCITEM.TakeThrownWeaponStack", "MCITEM.MCSWEP.TakeThrownWeaponStack")
hook.Add("MCITEM.TakeThrownWeaponStack", "MCITEM.MCSWEP.TakeThrownWeaponStack", function(owner, weapon, itemId, durabilityAmount)
    if not selectedMatchesWeapon(owner, weapon) then return nil end
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.TakeSelectedWithDurability) then return nil end
    local stack, infinite, _, err = inventory.TakeSelectedWithDurability(owner, durabilityAmount or 1, {
        expectedItem = namespaced(itemId),
        expectedClass = weapon:GetClass(),
        reason = "mcitem_thrown_weapon",
    })
    if istable(stack) then return stack, infinite == true end
    reportMutationError("thrown_weapon", err)
    return false, false
end)

-- 捡回来的箭 / 三叉戟进背包；塞不下就按 MCSWEP 的掉落物落地（不是变成一个模型）。
hook.Remove("MCITEM.GiveItemToPlayer", "MCITEM.MCSWEP.GiveItem")
hook.Add("MCITEM.GiveItemToPlayer", "MCITEM.MCSWEP.GiveItem", function(ply, stackOrItemId, count, position)
    local inventory = inventoryApi()
    if not inventory or not isfunction(inventory.Give) then return nil end

    local stack = istable(stackOrItemId) and stackOrItemId or nil
    local itemId = stack and namespaced(stack.item) or namespaced(stackOrItemId)
    if not itemId then return false end
    local given, remainder, err = inventory.Give(
        ply,
        itemId,
        stack and stack.count or count or 1,
        stack and stack.components or nil,
        stack and stack.damage or nil
    )
    if (given or 0) > 0 and not istable(remainder) then return true end

    local requested = stack and stack.count or count or 1
    local leftover = istable(remainder) and remainder.count or (requested - (given or 0))
    if leftover and leftover > 0 and isvector(position) then
        local dropped, dropError
        if istable(remainder) and isfunction(inventory.SpawnDropStack) then
            dropped, dropError = inventory.SpawnDropStack(position, remainder, ply, { pickupDelay = 0.5 })
        elseif isfunction(inventory.SpawnDrop) then
            dropped, dropError = inventory.SpawnDrop(position, itemId, leftover, ply, { pickupDelay = 0.5 })
        end
        if IsValid(dropped) then return true end
        reportMutationError("pickup_overflow", dropError or "drop_unavailable")
        local pending = istable(remainder) and table.Copy(remainder)
            or { item = itemId, count = leftover, components = stack and stack.components, damage = stack and stack.damage }
        return false, pending
    end

    if leftover <= 0 then return true end
    reportMutationError("give", err)
    return false, remainder
end)

hook.Remove("MCITEM.SpawnItemDrop", "MCITEM.MCSWEP.SpawnItemDrop")
hook.Add("MCITEM.SpawnItemDrop", "MCITEM.MCSWEP.SpawnItemDrop", function(position, stackOrItemId, count, actor)
    local inventory = inventoryApi()
    if not inventory then return nil end
    local ent, err
    if istable(stackOrItemId) and isfunction(inventory.SpawnDropStack) then
        ent, err = inventory.SpawnDropStack(position, stackOrItemId, actor, { pickupDelay = 0.5 })
    elseif isfunction(inventory.SpawnDrop) then
        ent, err = inventory.SpawnDrop(position, namespaced(stackOrItemId), count or 1, actor, {
            pickupDelay = 0.5,
        })
    else
        return nil
    end
    if IsValid(ent) then return true end
    reportMutationError("drop", err)
    return false
end)
