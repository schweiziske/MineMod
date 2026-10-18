-- Minecraft Java 26.2 enchantment gameplay helpers shared by MCITEM weapons,
-- projectiles and the MCSWEP inventory bridge.  The authoritative enchantment
-- levels always come from the complete ItemStack components; this file never
-- invents a second weapon-local enchantment store.

MCITEM = MCITEM or {}
MCITEM.EnchantmentRuntime = MCITEM.EnchantmentRuntime or {}

local Runtime = MCITEM.EnchantmentRuntime

local ARMOR_SLOTS = { "head", "chest", "legs", "feet" }

local TAG_MEMBERS = {
    undead = {
        ["minecraft:skeleton"] = true,
        ["minecraft:stray"] = true,
        ["minecraft:wither_skeleton"] = true,
        ["minecraft:skeleton_horse"] = true,
        ["minecraft:bogged"] = true,
        ["minecraft:parched"] = true,
        ["minecraft:zombie_horse"] = true,
        ["minecraft:camel_husk"] = true,
        ["minecraft:zombie"] = true,
        ["minecraft:zombie_villager"] = true,
        ["minecraft:zombified_piglin"] = true,
        ["minecraft:zoglin"] = true,
        ["minecraft:drowned"] = true,
        ["minecraft:husk"] = true,
        ["minecraft:zombie_nautilus"] = true,
        ["minecraft:wither"] = true,
        ["minecraft:phantom"] = true,
    },
    arthropod = {
        ["minecraft:bee"] = true,
        ["minecraft:endermite"] = true,
        ["minecraft:silverfish"] = true,
        ["minecraft:spider"] = true,
        ["minecraft:cave_spider"] = true,
    },
    aquatic = {
        ["minecraft:turtle"] = true,
        ["minecraft:axolotl"] = true,
        ["minecraft:guardian"] = true,
        ["minecraft:elder_guardian"] = true,
        ["minecraft:cod"] = true,
        ["minecraft:pufferfish"] = true,
        ["minecraft:salmon"] = true,
        ["minecraft:tropical_fish"] = true,
        ["minecraft:dolphin"] = true,
        ["minecraft:squid"] = true,
        ["minecraft:glow_squid"] = true,
        ["minecraft:tadpole"] = true,
        ["minecraft:nautilus"] = true,
        ["minecraft:zombie_nautilus"] = true,
    },
}

local function namespaced(identifier)
    identifier = tostring(identifier or "")
    if identifier == "" then return "" end
    return string.find(identifier, ":", 1, true) and identifier or "minecraft:" .. identifier
end

local function level(stack, enchantmentId)
    if not isfunction(Runtime.GetEnchantmentLevel) then return 0 end
    return math.max(0, math.floor(tonumber(Runtime.GetEnchantmentLevel(stack, enchantmentId)) or 0))
end

local function minecraftEntityId(entity)
    if not IsValid(entity) then return "" end
    -- Only an explicit Minecraft identity is authoritative here. Source class
    -- names such as npc_zombie or npc_antlion do not map one-to-one to Java
    -- entity types; integrations must opt them in through the public tag hook.
    return namespaced(entity.BMBMinecraftEntityID or entity.MinecraftEntityID or "")
end

function Runtime.EntityMatchesEnchantmentTag(entity, tag)
    if not IsValid(entity) then return false end
    tag = tostring(tag or "")
    local overridden = hook.Run("MCITEM.EntityMatchesEnchantmentTag", entity, tag)
    if overridden ~= nil then return overridden == true end
    -- IsUndead is likewise an explicit entity capability used by BMB, never a
    -- class-name inference for ordinary Source NPCs.
    if tag == "undead" and entity.IsUndead == true then return true end
    local members = TAG_MEMBERS[tag]
    return members ~= nil and members[minecraftEntityId(entity)] == true or false
end

function Runtime.GetEquipmentStack(playerEntity, slot)
    if not IsValid(playerEntity) or not playerEntity:IsPlayer() then return nil end
    if SERVER then
        local inventory = MC and MC.API and MC.API.Inventory
        if inventory and isfunction(inventory.GetEquipmentSlot) then
            local stack = inventory.GetEquipmentSlot(playerEntity, slot)
            return istable(stack) and stack or nil
        end
        return nil
    end
    if playerEntity == LocalPlayer() and MC and isfunction(MC.GetClientEquipmentStack) then
        local stack = MC.GetClientEquipmentStack(slot)
        return istable(stack) and stack or nil
    end
    return nil
end

function Runtime.GetEquipmentLevel(playerEntity, slot, enchantmentId)
    return level(Runtime.GetEquipmentStack(playerEntity, slot), enchantmentId)
end

function Runtime.GetArmorEnchantmentTotal(playerEntity, enchantmentId)
    local total = 0
    for _, slot in ipairs(ARMOR_SLOTS) do
        total = total + Runtime.GetEquipmentLevel(playerEntity, slot, enchantmentId)
    end
    return total
end

function Runtime.GetMeleeDamageBonus(stack, target)
    local sharpness = level(stack, "sharpness")
    local bonus = sharpness > 0 and (1 + 0.5 * (sharpness - 1)) or 0
    local smite = level(stack, "smite")
    if smite > 0 and Runtime.EntityMatchesEnchantmentTag(target, "undead") then
        bonus = bonus + 2.5 * smite
    end
    local bane = level(stack, "bane_of_arthropods")
    if bane > 0 and Runtime.EntityMatchesEnchantmentTag(target, "arthropod") then
        bonus = bonus + 2.5 * bane
    end
    local impaling = level(stack, "impaling")
    if impaling > 0 and Runtime.EntityMatchesEnchantmentTag(target, "aquatic") then
        bonus = bonus + 2.5 * impaling
    end
    return bonus
end

-- ThrownTrident.onHitEntity runs EnchantmentHelper.modifyDamage against the
-- complete ItemStack carried by that projectile before hurtOrSimulate.  The
-- same DAMAGE component powers Sharpness/Smite/Bane/Impaling, so command-made
-- combinations intentionally share the direct-attack calculation instead of
-- implementing a trident-only Impaling shortcut.
function Runtime.GetTridentDamageBonus(stack, target)
    return Runtime.GetMeleeDamageBonus(stack, target)
end

function Runtime.GetSweepDamage(stack, target, directDamage, charge)
    local sweeping = level(stack, "sweeping_edge")
    local ratio = sweeping > 0 and sweeping / (sweeping + 1) or 0
    local enchantmentBonus = Runtime.GetMeleeDamageBonus(stack, target)
    return (1 + ratio * math.max(0, tonumber(directDamage) or 0) + enchantmentBonus)
        * math.Clamp(tonumber(charge) or 0, 0, 1)
end

function Runtime.GetKnockbackBonus(stack)
    return level(stack, "knockback")
end

function Runtime.GetArrowBaseDamageBonus(stack)
    local power = level(stack, "power")
    return power > 0 and (1 + 0.5 * (power - 1)) or 0
end

-- ProjectileWeaponItem.useAmmo asks the held weapon's AMMO_USE effects how
-- many items to split from the selected projectile stack. Infinity's Java
-- 26.2 data sets that value to zero only when the projectile item is exactly
-- minecraft:arrow. The zero-use copy becomes an intangible projectile, so it
-- is not consumed and cannot be recovered as a survival pickup.
function Runtime.GetProjectileAmmoUse(weaponStack, projectileStack, kind, amount)
    amount = math.max(0, math.floor(tonumber(amount) or 1))
    if amount <= 0 or kind ~= "bow" or not istable(projectileStack) then return amount end
    if namespaced(projectileStack.item) ~= "minecraft:arrow" then return amount end
    return level(weaponStack, "infinity") > 0 and 0 or amount
end

function Runtime.GetPunchLevel(stack)
    return level(stack, "punch")
end

-- LivingEntity's ordinary knockback-resistance attribute is shared by melee,
-- projectile and mob forces.  MCSWEP exposes Netherite's equipment total on
-- players as a networked attribute, while BMB/other integrations may expose a
-- method, hook or entity field.  Take the strongest view instead of summing
-- them: integrations often mirror the same underlying attribute in more than
-- one place.
function Runtime.GetKnockbackResistance(target, context)
    if not IsValid(target) then return 0 end

    local value
    if isfunction(target.GetMCKnockbackResistance) then
        value = target:GetMCKnockbackResistance(context)
    end
    if value == nil then value = hook.Run("MCITEM.GetKnockbackResistance", target, context) end
    if value == nil then value = target.KnockbackResistance end

    local resistance = math.Clamp(tonumber(value) or 0, 0, 1)
    if target:IsPlayer() then
        local equipmentResistance = 0
        if isfunction(target.GetNWFloat) then
            equipmentResistance = math.max(equipmentResistance,
                tonumber(target:GetNWFloat("mc_armor_knockback_resistance", 0)) or 0)
        end
        if isfunction(target.GetNW2Float) then
            equipmentResistance = math.max(equipmentResistance,
                tonumber(target:GetNW2Float("mc_armor_knockback_resistance", 0)) or 0)
        end
        resistance = math.max(resistance, math.Clamp(equipmentResistance, 0, 1))
    end
    return resistance
end

-- Source movement APIs disagree about whether a velocity write is additive or
-- absolute.  Keep that conversion at one projectile boundary so Punch is not
-- overwritten by BMB behaviour loops and ordinary NPC/NextBot motion is not
-- accidentally replaced with only the new impulse.
function Runtime.ApplyProjectilePush(target, impulse, context)
    if not SERVER or not IsValid(target) or not isvector(impulse)
        or impulse:LengthSqr() <= 0 then return false end
    context = istable(context) and context or {}

    if isfunction(target.StartBMBExternalImpulse)
        and target:StartBMBExternalImpulse(impulse, {
            reason = context.kind or "projectile_knockback",
            duration = tonumber(context.duration) or 0.12,
            useJump = context.useJump ~= false,
        }) then
        return true
    end

    if target:IsPlayer() and isfunction(target.SetVelocity) then
        if impulse.z > 0 and isfunction(target.SetGroundEntity) then target:SetGroundEntity(NULL) end
        target:SetVelocity(impulse) -- Player SetVelocity is additive.
        return true
    end

    local current = isfunction(target.GetVelocity) and target:GetVelocity() or vector_origin
    if target:IsNextBot() and target.loco and isfunction(target.loco.SetVelocity) then
        if impulse.z > 0 and isfunction(target.loco.Jump)
            and (not isfunction(target.loco.IsOnGround) or target.loco:IsOnGround()) then
            target.loco:Jump()
        end
        target.loco:SetVelocity(current + impulse)
        local horizontal = Vector(impulse.x, impulse.y, 0)
        if isfunction(target.loco.Approach) and isfunction(target.GetPos)
            and horizontal:LengthSqr() > 1 then
            target.loco:Approach(target:GetPos() + horizontal, math.max(horizontal:Length(), 1))
        end
        return true
    end

    if target:IsNPC() and isfunction(target.SetLocalVelocity) then
        if impulse.z > 0 and isfunction(target.SetGroundEntity) then target:SetGroundEntity(NULL) end
        target:SetLocalVelocity(current + impulse)
        return true
    end

    if isfunction(target.SetVelocity) then
        target:SetVelocity(current + impulse)
        return true
    end
    return false
end

function Runtime.GetPiercingLevel(stack)
    return level(stack, "piercing")
end

function Runtime.GetCrossbowChargeTicks(stack)
    return math.max(1, 25 - 5 * level(stack, "quick_charge"))
end

function Runtime.GetCrossbowChargingSoundKeys(stack)
    local quickCharge = math.Clamp(level(stack, "quick_charge"), 0, 3)
    if quickCharge > 0 then
        return "crossbow_quick_charge_" .. quickCharge, nil, "crossbow_loading_end"
    end
    return "crossbow_loading_start", "crossbow_loading_middle", "crossbow_loading_end"
end

function Runtime.GetCrossbowProjectileCount(stack)
    return level(stack, "multishot") > 0 and 3 or 1
end

function Runtime.GetCrossbowProjectileSpread(stack)
    return level(stack, "multishot") > 0 and 10 or 0
end

function Runtime.GetLoyaltyLevel(stack)
    return level(stack, "loyalty")
end

function Runtime.GetLoyaltyAcceleration(stack)
    -- EnchantmentHelper.getTridentReturnToOwnerAcceleration starts at zero
    -- and applies Loyalty's add(base=1, per-level=1) effect.
    return Runtime.GetLoyaltyLevel(stack)
end

function Runtime.GetRiptideLevel(stack)
    return level(stack, "riptide")
end

function Runtime.GetRiptideStrength(stack)
    local riptide = Runtime.GetRiptideLevel(stack)
    return riptide > 0 and (1.5 + 0.75 * (riptide - 1)) or 0
end

function Runtime.IsFallFlying(playerEntity)
    if not IsValid(playerEntity) then return false end
    local overridden = hook.Run("MCITEM.IsFallFlying", playerEntity)
    if overridden ~= nil then return overridden == true end
    if isfunction(playerEntity.IsMCFallFlying) then
        local result = playerEntity:IsMCFallFlying()
        if result ~= nil then return result == true end
    end
    if isfunction(playerEntity.GetNW2Bool)
        and playerEntity:GetNW2Bool("MCITEM_FallFlying", false) then
        return true
    end
    return false
end

local function waterContact(contact)
    if not istable(contact) then return false end
    local kind = string.lower(tostring(contact.kind or ""))
    return kind == "water" or kind == "minecraft:water"
end

function Runtime.IsInWater(playerEntity)
    if not IsValid(playerEntity) then return false end
    local overridden = hook.Run("MCITEM.IsInWater", playerEntity)
    if overridden ~= nil then return overridden == true end

    -- Minecraft block water is not a Source brush volume, so WaterLevel() stays
    -- zero in the MC world.  Reuse mc_engine's authoritative player-AABB fluid
    -- contact -- the same result its swimming Move hook consumes -- before the
    -- ordinary Source-water fallback.
    local moveContacts = MC and MC.LiquidMoveContacts
    if istable(moveContacts) and waterContact(moveContacts[playerEntity]) then return true end
    if MC and isfunction(MC.PlayerLiquidContact) then
        local ok, contact = pcall(MC.PlayerLiquidContact, playerEntity)
        if ok and waterContact(contact) then return true end
    end

    -- Older/public API-only mc_engine builds may not expose PlayerLiquidContact.
    -- Probe the entity's InfMap-safe feet position so those builds still agree
    -- with their voxel liquid state rather than relying on Source WaterLevel().
    local api = MC and MC.API
    local coords = api and api.Coords
    local liquid = api and api.Liquid
    if coords and isfunction(coords.EntityWorldPos)
        and liquid and isfunction(liquid.AtPos) then
        local positionOK, position = pcall(coords.EntityWorldPos, playerEntity)
        if positionOK and isvector(position) then
            local liquidOK, contact = pcall(liquid.AtPos, position)
            if liquidOK and waterContact(contact) then return true end
        end
    end

    return isfunction(playerEntity.WaterLevel) and playerEntity:WaterLevel() > 0
end

function Runtime.IsRainingAt(playerEntity)
    if not IsValid(playerEntity) then return false end
    local position = isfunction(playerEntity.WorldSpaceCenter)
        and playerEntity:WorldSpaceCenter() or playerEntity:GetPos()
    local converter = Runtime.EnginePositionToCell
    local bx, by, bz
    if converter then bx, by, bz = converter(position, playerEntity) end

    local weather = MC and MC.API and MC.API.Weather
    if weather and isfunction(weather.IsRainingAt) and bx ~= nil then
        local result = weather.IsRainingAt(bx, by, bz)
        if result ~= nil then return result == true end
    end

    local hooked = hook.Run("MCITEM.IsRainingAt", playerEntity, position, bx, by, bz)
    if hooked ~= nil then return hooked == true end

    -- Fishing's public helper intentionally folds "no weather provider" into
    -- false for its ordinary bite-speed boolean.  Calling that helper here
    -- would hide the unknown state and prevent the explicit Channeling weather
    -- substitute below from running.  Query the optional hook directly so nil
    -- remains a real third state while existing fishing integrations still
    -- participate.
    if bx ~= nil then
        local fishingHooked = hook.Run(
            "MCITEM.FishingIsRainingAt", bx, by, bz, playerEntity)
        if fishingHooked ~= nil then return fishingHooked == true end
    end

    -- Source has no vanilla rain state. Open sky alone is not rain: it is only
    -- consulted after the existing Channeling weather substitute explicitly
    -- opts the world into the thunderstorm approximation.
    if not Runtime.ChannelingEnabled() then return false end
    return not isfunction(Runtime.VisibleToSky)
        or Runtime.VisibleToSky(position, playerEntity, playerEntity)
end

function Runtime.CanUseRiptide(playerEntity)
    if not IsValid(playerEntity) or not playerEntity:IsPlayer() or playerEntity:InVehicle() then return false end
    if Runtime.IsInWater(playerEntity) then return true end
    -- TridentItem checks only isInWaterOrRain() and isPassenger().  Fall flying
    -- is a Lunge restriction, not a Riptide restriction.
    return Runtime.IsRainingAt(playerEntity)
end

function Runtime.GetLungeLevel(stack)
    return level(stack, "lunge")
end

function Runtime.ApplyPunch(target, projectile, punchLevel)
    punchLevel = math.max(0, tonumber(punchLevel) or 0)
    if not SERVER or not IsValid(target) or punchLevel <= 0 then return false end
    local velocity = IsValid(projectile) and isfunction(projectile.GetMCVelocity)
        and projectile:GetMCVelocity() or vector_origin
    local horizontal = Vector(velocity.x, velocity.y, 0)
    if horizontal:LengthSqr() <= 1e-8 then return false end
    horizontal:Normalize()

    local context = {
        kind = "arrow_punch",
        projectile = projectile,
        attacker = IsValid(projectile) and projectile:GetOwner() or nil,
        punchLevel = punchLevel,
    }
    local resistance = Runtime.GetKnockbackResistance(target, context)
    local horizontalStrength = 0.6 * punchLevel * (1 - resistance)
    -- AbstractArrow checks the resistance-scaled horizontal vector before it
    -- calls LivingEntity.push(x, 0.1, z).  Full resistance therefore suppresses
    -- the entire push, while partial resistance leaves the 0.1 vertical term
    -- untouched.
    if horizontalStrength <= 0 then return false end

    local scale = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() * 20 or 730
    local impulse = horizontal * (horizontalStrength * scale) + Vector(0, 0, 0.1 * scale)
    context.knockbackResistance = resistance
    return Runtime.ApplyProjectilePush(target, impulse, context)
end

function Runtime.ApplyDirectPostAttack(stack, attacker, target, weapon, actualDamage)
    if not SERVER or not IsValid(target) or (tonumber(actualDamage) or 0) <= 0 then return end
    local fireAspect = level(stack, "fire_aspect")
    if fireAspect > 0 and isfunction(Runtime.IgniteEntity) then
        Runtime.IgniteEntity(target, 4 * fireAspect, "fire_aspect")
    end
    local bane = level(stack, "bane_of_arthropods")
    if bane > 0 and Runtime.EntityMatchesEnchantmentTag(target, "arthropod") then
        local maximum = 1.5 + 0.5 * (bane - 1)
        local duration = math.Rand(1.5, maximum)
        local potions = MCITEM.Potions
        if potions and isfunction(potions.ApplyEffect) then
            potions.ApplyEffect(target, {
                id = "slowness",
                durationTicks = math.max(1, math.floor(duration * 20 + 0.5)),
                amplifier = 3,
                ambient = false,
                visible = true,
                showIcon = true,
            }, IsValid(attacker) and attacker or weapon, {
                reason = "bane_of_arthropods",
                weapon = weapon,
            })
        end
    end
    hook.Run("MCITEM.EnchantmentPostAttack", attacker, target, weapon, stack, actualDamage)
end

-- One compact audit table keeps all 43 Java 26.2 enchantments visible to the
-- static checker and to future context handoffs.  Values identify the owning
-- subsystem, not a second implementation registry.
Runtime.EffectCoverage = {
    aqua_affinity = "passive_mining",
    bane_of_arthropods = "direct_damage_post_attack",
    binding_curse = "inventory_equipment_take",
    blast_protection = "mcgame_explosion",
    breach = "mace_runtime",
    channeling = "trident_runtime",
    density = "mace_runtime",
    depth_strider = "passive_movement",
    efficiency = "mcgame_mining",
    feather_falling = "passive_protection",
    fire_aspect = "direct_post_attack",
    fire_protection = "passive_protection_burning_time",
    flame = "arrow_runtime",
    fortune = "mcgame_loot",
    frost_walker = "passive_location",
    impaling = "direct_damage",
    infinity = "inventory_ammo_bridge",
    knockback = "direct_attack",
    looting = "mcgame_loot",
    loyalty = "trident_return",
    luck_of_the_sea = "fishing_loot",
    lunge = "spear_post_piercing",
    lure = "fishing_time",
    mending = "inventory_experience",
    multishot = "crossbow_runtime",
    piercing = "arrow_runtime",
    power = "arrow_damage",
    projectile_protection = "passive_protection",
    protection = "passive_protection",
    punch = "arrow_knockback",
    quick_charge = "crossbow_runtime",
    respiration = "deferred_user_request",
    riptide = "trident_runtime",
    sharpness = "direct_damage",
    silk_touch = "mcgame_loot",
    smite = "direct_damage",
    soul_speed = "passive_location_movement",
    sweeping_edge = "direct_sweep",
    swift_sneak = "passive_movement",
    thorns = "passive_post_attack",
    unbreaking = "inventory_durability",
    vanishing_curse = "inventory_death_drop",
    wind_burst = "mace_runtime",
}
