-- 弹药与"投出去的武器"的背包语义（MC 26.2）。
--
-- MCITEM 自己**没有背包模型**，所以这一层只定义契约，真正的加减由 MCSWEP 背包桥
-- （`integration/mcswep/sv_inventory_hooks.lua`）实现。没装 MCSWEP 时全部退化成
-- "无限弹药、投出去不扣物品"，addon 仍然能单独跑。
--
-- 源码依据：
--   BowItem.use          `if (!hasInfiniteMaterials && getProjectile(stack).isEmpty()) return FAIL`
--                        —— 没箭连拉弓都拉不了，不是"能拉但射不出去"。
--   CrossbowItem.onUseTick → tryLoadProjectiles：**装填完成**那一刻才扣箭，
--                        发射用的是 CHARGED_PROJECTILES 组件里那一支。
--   TridentItem.releaseUsing：投出去 = 这一件物品离开背包（ThrownTrident 带着它飞）。
--   ThrownTrident.playerTouch → tryPickup → inventory.add()：捡回来进背包。

MCITEM = MCITEM or {}

-- CrossbowItem 还接受烟花火箭，但 MCITEM 尚无烟花弹实体，所以这里仍只报箭；
-- MCSWEP 的通用 charged_projectiles API 会保留火箭的 3 点/发耐久语义。
MCITEM.AmmoItems = {
    bow = "minecraft:arrow",
    crossbow = "minecraft:arrow",
}

local function copyStack(stack, count)
    if not istable(stack) then return nil end
    local copied = table.Copy and table.Copy(stack) or {
        item = stack.item,
        count = stack.count,
        damage = stack.damage,
        components = istable(stack.components) and table.Copy(stack.components) or stack.components,
    }
    copied.count = math.max(1, math.floor(tonumber(count) or tonumber(copied.count) or 1))
    return copied
end

function MCITEM.CopyProjectileStack(stack, count)
    return copyStack(stack, count)
end

local function copyStacks(stacks)
    if not istable(stacks) then return nil end
    local copied = {}
    for _, stack in ipairs(stacks) do
        local value = copyStack(stack, 1)
        if value then copied[#copied + 1] = value end
    end
    return #copied > 0 and copied or nil
end

function MCITEM.CopyProjectileStacks(stacks)
    return copyStacks(stacks)
end

local function stackComponents(stack)
    local components = istable(stack) and stack.components or nil
    return istable(components) and components or nil
end

function MCITEM.ProjectileStackIsIntangible(stack)
    local components = stackComponents(stack)
    return components ~= nil
        and (components["minecraft:intangible_projectile"] ~= nil
            or components.intangible_projectile ~= nil)
end

local function intangibleProjectile(stack)
    local copied = copyStack(stack, 1)
    copied.components = istable(copied.components) and copied.components or {}
    copied.components["minecraft:intangible_projectile"] = true
    return copied
end

-- ProjectileWeaponItem.draw: only index 0 consumes the selected ammunition;
-- every later projectile is a one-count copy carrying INTANGIBLE_PROJECTILE.
-- Infinite-material mode also makes index 0 intangible.
function MCITEM.BuildCrossbowChargedProjectiles(stack, projectileCount, intangibleFirst)
    if not istable(stack) then return nil end
    projectileCount = math.Clamp(math.floor(tonumber(projectileCount) or 1), 1, 16)
    local projectiles = {}
    for index = 1, projectileCount do
        local projectile = copyStack(stack, 1)
        if intangibleFirst == true or index > 1 then
            projectile = intangibleProjectile(projectile)
        end
        projectiles[#projectiles + 1] = projectile
    end
    return projectiles
end

-- ProjectileWeaponItem.shoot alternates out from the centre. For Multishot's
-- three entries this is 0, -10, +10 degrees (centre, left, right).
function MCITEM.CrossbowShotAngles(projectileCount, spread)
    projectileCount = math.max(1, math.floor(tonumber(projectileCount) or 1))
    spread = tonumber(spread) or 0
    local step = projectileCount == 1 and 0 or 2 * spread / (projectileCount - 1)
    local offset = ((projectileCount - 1) % 2) * step / 2
    local sign, angles = 1, {}
    for zeroIndex = 0, projectileCount - 1 do
        angles[#angles + 1] = offset
            + sign * math.floor((zeroIndex + 1) / 2) * step
        sign = -sign
    end
    return angles
end

function MCITEM.RotateProjectileDirection(direction, axis, degrees)
    if not isvector(direction) or not isvector(axis) then return direction end
    local radians = math.rad(tonumber(degrees) or 0)
    if math.abs(radians) < 0.000001 then return direction end
    axis = axis:GetNormalized()
    local cosine, sine = math.cos(radians), math.sin(radians)
    return direction * cosine + axis:Cross(direction) * sine
        + axis * axis:Dot(direction) * (1 - cosine)
end

function MCITEM.CrossbowProjectileDurabilityUse(stack)
    return istable(stack) and stack.item == "minecraft:firework_rocket" and 3 or 1
end

function MCITEM.CrossbowProjectilesDurabilityUse(stacks)
    local amount = 0
    for _, stack in ipairs(stacks or {}) do
        amount = amount + MCITEM.CrossbowProjectileDurabilityUse(stack)
    end
    return math.Clamp(amount, 1, 255)
end

-- 有没有可用弹药。创造模式 / 没有背包系统时恒真。
function MCITEM.HasProjectileAmmo(owner, weapon, kind)
    if not IsValid(owner) then return false end
    local handled = hook.Run("MCITEM.HasProjectileAmmo", owner, weapon, kind)
    if handled ~= nil then return handled ~= false end
    return true
end

-- 扣一发弹药。返回 false = 没扣成（调用方必须**不要**发射）。第二返回值表示
-- Java hasInfiniteMaterials：成功但库存没有变化，失败回滚时也不能凭空“返还”一支箭。
function MCITEM.ConsumeProjectileAmmo(owner, weapon, kind, amount)
    if not IsValid(owner) then return false, false end
    local handled, infinite = hook.Run("MCITEM.ConsumeProjectileAmmo", owner, weapon, kind, amount or 1)
    if handled ~= nil then return handled ~= false, infinite == true end
    return true, true
end

-- Atomically selects and (outside infinite-material mode) takes the complete
-- projectile ItemStack.  This is the authoritative path for arrow variants:
-- item id, damage and components must survive loading, flight and pickup.
--
-- Returns stack, intangible, generated. `intangible` is true when Java would
-- leave inventory unchanged (creative materials or an AMMO_USE result of 0),
-- which also makes the spawned arrow CREATIVE_ONLY for pickup. `generated` is
-- true only for the creative empty-inventory fallback normal arrow.
function MCITEM.TakeProjectileAmmo(owner, weapon, kind, amount)
    if not IsValid(owner) then return nil, false, false end
    local stack, infinite, generated = hook.Run(
        "MCITEM.TakeProjectileAmmo", owner, weapon, kind, amount or 1)
    if stack ~= nil then
        return istable(stack) and copyStack(stack, amount or 1) or nil,
            infinite == true,
            generated == true
    end

    -- Standalone MCITEM has no inventory authority. Match the old unlimited
    -- ammo fallback, but still hand the projectile a complete vanilla stack.
    return {
        item = MCITEM.AmmoItems[kind] or "minecraft:arrow",
        count = math.max(1, math.floor(tonumber(amount) or 1)),
    }, true, true
end

function MCITEM.StoreChargedProjectiles(owner, weapon, projectileStacks)
    if not IsValid(owner) or not IsValid(weapon) or not copyStacks(projectileStacks) then return false end
    local handled = hook.Run("MCITEM.StoreChargedProjectiles", owner, weapon, projectileStacks)
    if handled ~= nil then return handled ~= false end
    weapon.MCChargedProjectileStacks = copyStacks(projectileStacks)
    weapon.MCChargedProjectileStack = weapon.MCChargedProjectileStacks[1]
    return true
end

function MCITEM.GetChargedProjectiles(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return nil end
    local stacks = hook.Run("MCITEM.GetChargedProjectiles", owner, weapon)
    if stacks ~= nil then return copyStacks(stacks) end
    if istable(weapon.MCChargedProjectileStacks) then
        return copyStacks(weapon.MCChargedProjectileStacks)
    end
    if istable(weapon.MCChargedProjectileStack) then
        return { copyStack(weapon.MCChargedProjectileStack, 1) }
    end
    return nil
end

function MCITEM.ClearChargedProjectiles(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return false end
    local handled = hook.Run("MCITEM.ClearChargedProjectiles", owner, weapon)
    if handled ~= nil then return handled ~= false end
    weapon.MCChargedProjectileStacks = nil
    weapon.MCChargedProjectileStack = nil
    return true
end

function MCITEM.StoreChargedProjectile(owner, weapon, projectileStack)
    if not IsValid(owner) or not IsValid(weapon) then return false end
    local handled = hook.Run("MCITEM.StoreChargedProjectile", owner, weapon, projectileStack)
    if handled ~= nil then return handled ~= false end
    return true
end

function MCITEM.GetChargedProjectile(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return nil end
    local stack = hook.Run("MCITEM.GetChargedProjectile", owner, weapon)
    if stack ~= nil then return istable(stack) and copyStack(stack, 1) or nil end
    return istable(weapon.MCChargedProjectileStack)
        and copyStack(weapon.MCChargedProjectileStack, 1) or nil
end

function MCITEM.ClearChargedProjectile(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return false end
    local handled = hook.Run("MCITEM.ClearChargedProjectile", owner, weapon)
    if handled ~= nil then return handled ~= false end
    return true
end

-- Plural form of CrossbowItem#tryLoadProjectiles. Integrations must consume
-- one source item and store the complete list in one inventory transaction.
function MCITEM.LoadCrossbowProjectiles(owner, weapon, projectileCount)
    if not IsValid(owner) or not IsValid(weapon) then return nil, false, false end
    projectileCount = math.Clamp(math.floor(tonumber(projectileCount) or 1), 1, 16)
    local stacks, infinite, generated = hook.Run(
        "MCITEM.LoadCrossbowProjectiles", owner, weapon, projectileCount)
    if stacks ~= nil then
        return copyStacks(stacks), infinite == true, generated == true
    end

    local fallback, fallbackInfinite, fallbackGenerated =
        MCITEM.TakeProjectileAmmo(owner, weapon, "crossbow", 1)
    if not istable(fallback) then return nil, false, false end
    local projectiles = MCITEM.BuildCrossbowChargedProjectiles(
        fallback, projectileCount, fallbackInfinite)
    weapon.MCChargedProjectileStacks = copyStacks(projectiles)
    weapon.MCChargedProjectileStack = weapon.MCChargedProjectileStacks[1]
    return projectiles, fallbackInfinite == true, fallbackGenerated == true
end

-- CrossbowItem#tryLoadProjectiles is one inventory transition: choose the
-- complete arrow stack, consume it outside infinite-material mode, then store
-- that same stack in charged_projectiles. Integrations should implement the
-- hook atomically; standalone MCITEM keeps its unlimited-ammo fallback.
function MCITEM.LoadCrossbowProjectile(owner, weapon)
    if not IsValid(owner) or not IsValid(weapon) then return nil, false, false end
    local stack, infinite, generated = hook.Run(
        "MCITEM.LoadCrossbowProjectile", owner, weapon)
    if stack ~= nil then
        return istable(stack) and copyStack(stack, 1) or nil,
            infinite == true,
            generated == true
    end

    local fallback, fallbackInfinite, fallbackGenerated =
        MCITEM.TakeProjectileAmmo(owner, weapon, "crossbow", 1)
    if not istable(fallback) then return nil, false, false end
    weapon.MCChargedProjectileStack = copyStack(fallback, 1)
    return fallback, fallbackInfinite == true, fallbackGenerated == true
end

-- Plural charged-shot commit. Every entity must already exist; the caller
-- removes all of them if the integration rejects or fails the atomic commit.
function MCITEM.CommitCrossbowProjectilesShot(owner, weapon, projectileStacks, context)
    if not IsValid(owner) or not IsValid(weapon) or not copyStacks(projectileStacks) then
        return false, false
    end
    local handled, broken = hook.Run(
        "MCITEM.CommitCrossbowProjectilesShot",
        owner,
        weapon,
        projectileStacks,
        context)
    if handled ~= nil then return handled ~= false, broken == true end

    weapon.MCChargedProjectileStacks = nil
    weapon.MCChargedProjectileStack = nil
    if isfunction(weapon.ApplyMCDurabilityDamage) then
        weapon:ApplyMCDurabilityDamage(
            MCITEM.CrossbowProjectilesDurabilityUse(projectileStacks), context)
    end
    return true, false
end

-- Completes a charged shot. Inventory integrations atomically clear
-- charged_projectiles and apply durability; standalone operation clears the
-- transient stack and delegates durability to the SWEP's optional bridge.
function MCITEM.CommitCrossbowShot(owner, weapon, projectileStack, durabilityAmount, context)
    if not IsValid(owner) or not IsValid(weapon) then return false, false end
    local handled, broken = hook.Run(
        "MCITEM.CommitCrossbowShot",
        owner,
        weapon,
        projectileStack,
        durabilityAmount or 1,
        context)
    if handled ~= nil then return handled ~= false, broken == true end

    weapon.MCChargedProjectileStack = nil
    if isfunction(weapon.ApplyMCDurabilityDamage) then
        weapon:ApplyMCDurabilityDamage(durabilityAmount or 1, context)
    end
    return true, false
end

-- 投出去的武器本体（三叉戟）。预检与提交分开暴露，但提交本身必须是单次原子事务：
-- `nextDamageWillBreak()` → `hurtWithoutBreaking(1)` → `consumeAndReturn(1)`。
-- 返回的 stack 是弹丸真正携带、拾取时必须原样返还的完整 ItemStack。
function MCITEM.CanThrowWeaponStack(owner, weapon, itemId, durabilityAmount)
    if not IsValid(owner) then return false, false end
    local allowed, infinite = hook.Run(
        "MCITEM.CanThrowWeaponStack", owner, weapon, itemId, durabilityAmount or 1)
    if allowed ~= nil then return allowed ~= false, infinite == true end
    -- 独立运行时没有 ItemStack inventory，也没有耐久可校验；允许 SWEP 自己生成弹丸。
    return true, false
end

-- Client-side twin of the trident `nextDamageWillBreak()` preflight.  The
-- authoritative decision still belongs to CanThrowWeaponStack on the server;
-- this helper only prevents a known-invalid selected ItemStack from entering
-- the predicted use pose while the rejection travels back over the network.
--
-- nil means "no complete client inventory evidence" (standalone MCITEM or an
-- inventory snapshot that has not arrived yet), so callers must let the server
-- decide.  false is only returned when the synced complete stack proves that
-- this durability use would break the item.
function MCITEM.CanPredictThrowWeaponStack(owner, itemId, durabilityAmount)
    if not CLIENT or not IsValid(owner) then return nil end
    if not MC or not isfunction(MC.GetClientSelectedStack) or not isfunction(MC.GetItem) then return nil end

    local stack = MC.GetClientSelectedStack()
    if not istable(stack) then return nil end

    local expected = tostring(itemId or "")
    if expected ~= "" and not string.find(expected, ":", 1, true) then expected = "minecraft:" .. expected end
    if expected ~= "" and stack.item ~= expected then return nil end

    local definition = MC.GetItem(stack.item)
    if not definition then return nil end
    if isfunction(MC.ItemIsUnbreakable) and MC.ItemIsUnbreakable(stack) then return true end

    local maximum = math.max(0, math.floor(tonumber(definition.maxDamage) or 0))
    if maximum <= 0 then return true end

    local amount = math.Clamp(math.floor(tonumber(durabilityAmount) or 0), 0, 255)
    local currentDamage = math.max(0, math.floor(tonumber(stack.damage) or 0))
    return amount <= 0 or currentDamage + amount < maximum
end

function MCITEM.TakeThrownWeaponStack(owner, weapon, itemId, durabilityAmount)
    if not IsValid(owner) then return nil, false end
    local stack, infinite = hook.Run(
        "MCITEM.TakeThrownWeaponStack", owner, weapon, itemId, durabilityAmount or 1)
    if stack ~= nil then return stack, infinite == true end
    -- 没装 MCSWEP 时仍保持 MCITEM 可独立使用；实体只按 ID 做 SWEP 回退。
    return nil, false
end

-- 捡回来的物品进背包。stackOrItemId 可以是完整 ItemStack，也可以是旧式 ID。
-- 返回 false = 没有背包系统或塞不下。
function MCITEM.GiveItemToPlayer(ply, stackOrItemId, count, position)
    if not IsValid(ply) then return false end
    local handled, remainder = hook.Run("MCITEM.GiveItemToPlayer", ply, stackOrItemId, count or 1, position)
    if handled ~= nil then return handled ~= false, remainder end
    return false
end

-- 背包系统在不在场（决定"捡回来"要不要退回给 SWEP）。
function MCITEM.HasInventorySystem(ply)
    local handled = hook.Run("MCITEM.HasInventorySystem", ply)
    if handled ~= nil then return handled ~= false end
    return false
end

-- Java Player.hasInfiniteMaterials() query used by CREATIVE_ONLY projectile
-- pickup.  Inventory integrations should answer authoritatively; standalone
-- MCITEM keeps the old admin fallback because it has no Minecraft gamemode.
function MCITEM.HasInfiniteMaterials(ply)
    if not IsValid(ply) then return false end
    local handled = hook.Run("MCITEM.HasInfiniteMaterials", ply)
    if handled ~= nil then return handled ~= false end
    return ply:IsAdmin()
end

-- 在世界里生成一个掉落物（MCSWEP 的 `mc_item_drop`）。末影之眼返还、背包满了的
-- 溢出都走这一条。返回 false = 没有背包系统，调用方自己兜底。
function MCITEM.SpawnItemDrop(position, stackOrItemId, count, actor)
    if not isvector(position) then return false end
    local handled = hook.Run("MCITEM.SpawnItemDrop", position, stackOrItemId, count or 1, actor)
    if handled ~= nil then return handled ~= false end
    return false
end
