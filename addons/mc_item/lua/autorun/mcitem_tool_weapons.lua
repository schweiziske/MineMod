-- Data-driven registration for the 35 vanilla tool weapons in Minecraft Java 26.2.
--
-- Source of every number:
--   Items.java registrations (attack damage/speed baselines)
--   ToolMaterial.java (material attackDamageBonus)
-- Player base attributes are ATTACK_DAMAGE 1 and ATTACK_SPEED 4, so the values stored on
-- each SWEP below are the final totals used by Player.attack, not only the item modifiers.

if SERVER then AddCSLuaFile() end

local MATERIALS = {
    {
        id = "wooden", name = "Wooden", damageBonus = 0,
        axeDamage = 6, axeSpeed = -3.2,
        hoeDamage = 0, hoeSpeed = -3.0,
    },
    {
        id = "stone", name = "Stone", damageBonus = 1,
        axeDamage = 7, axeSpeed = -3.2,
        hoeDamage = -1, hoeSpeed = -2.0,
    },
    {
        id = "copper", name = "Copper", damageBonus = 1,
        axeDamage = 7, axeSpeed = -3.2,
        hoeDamage = -1, hoeSpeed = -2.0,
    },
    {
        id = "iron", name = "Iron", damageBonus = 2,
        axeDamage = 6, axeSpeed = -3.1,
        hoeDamage = -2, hoeSpeed = -1.0,
    },
    {
        id = "golden", name = "Golden", damageBonus = 0,
        axeDamage = 6, axeSpeed = -3.0,
        hoeDamage = 0, hoeSpeed = -3.0,
    },
    {
        id = "diamond", name = "Diamond", damageBonus = 3,
        axeDamage = 5, axeSpeed = -3.0,
        hoeDamage = -3, hoeSpeed = 0.0,
    },
    {
        id = "netherite", name = "Netherite", damageBonus = 4,
        axeDamage = 5, axeSpeed = -3.0,
        hoeDamage = -4, hoeSpeed = 0.0,
    },
}

local TOOLS = {
    { id = "sword", name = "Sword", damage = 3.0, speed = -2.4, sword = true },
    { id = "pickaxe", name = "Pickaxe", damage = 1.0, speed = -2.8 },
    -- AxeItem/ShovelItem/HoeItem override useOn; the other two have no right-click.
    { id = "axe", name = "Axe", damageKey = "axeDamage", speedKey = "axeSpeed",
      useAction = "axe", useOn = "strip a log / scrape or de-wax copper" },
    { id = "shovel", name = "Shovel", damage = 1.5, speed = -3.0,
      useAction = "shovel", useOn = "flatten dirt into a path" },
    { id = "hoe", name = "Hoe", damageKey = "hoeDamage", speedKey = "hoeSpeed",
      useAction = "hoe", useOn = "till soil into farmland" },
}

-- These historical collisions keep their stable *_item package paths. MCITEM owns
-- them and remains standalone; BMB mounts MCITEM and consumes the same models, with
-- mob-specific seven-axis attachment profiles absorbing any pose differences.
local SHARED_ITEM_MODEL_ALIASES = {
    golden_sword = "golden_sword_item",
    stone_sword = "stone_sword_item",
    bow = "bow_item",
    bow_pulling_0 = "bow_pulling_0_item",
    bow_pulling_1 = "bow_pulling_1_item",
    bow_pulling_2 = "bow_pulling_2_item",
    golden_spear = "golden_spear_item",
}

local function itemModelPath(itemId)
    local modelId = SHARED_ITEM_MODEL_ALIASES[itemId] or itemId
    return "models/mcgm/" .. modelId .. "/" .. modelId .. ".mdl"
end

for _, material in ipairs(MATERIALS) do
    for _, tool in ipairs(TOOLS) do
        local itemId = material.id .. "_" .. tool.id
        local damageBaseline = tool.damage or material[tool.damageKey]
        local speedBaseline = tool.speed or material[tool.speedKey]

        local definition = {
            Base = "weapon_bmb_item_model_test",
            PrintName = "Minecraft " .. material.name .. " " .. tool.name,
            Category = "Minecraft in GMod - Items",
            Instructions = "Left click: attack in the air / on a mob, mining swing on a block."
                .. (tool.useOn and " Right click: " .. tool.useOn .. "." or ""),
            Spawnable = true,
            AdminOnly = false,
            WorldModel = itemModelPath(itemId),

            MCItemID = itemId,
            MCMaterial = material.id,
            MCToolType = tool.id,
            MCThirdPersonProfile = tool.id,
            -- HoeItem/ShovelItem/AxeItem useOn (sh_block_interact.lua). nil = no right click.
            MCUseAction = tool.useAction,
            MCAttackDamage = 1 + damageBaseline + material.damageBonus,
            MCAttackSpeed = 4 + speedBaseline,
            MCAttackKnockback = 0,
            MCIsSword = tool.sword == true,
            -- ToolMaterial.applySwordProperties -> Weapon(1); applyToolProperties
            -- (镐/斧/铲/锄) -> Weapon(2, axeDisableSeconds).
            MCWeaponDamagePerAttack = tool.sword == true and 1 or 2,
            MCDisableBlockingSeconds = tool.id == "axe" and 5 or 0,
        }

        weapons.Register(definition, "weapon_mcitem_" .. itemId)
    end
end

-- Item.Properties.spear(...) registrations from Items.java 1198-1204. These are
-- intentionally separate from the five classic tools: they use STAB, a full-charge-only
-- piercing primary attack, and KineticWeapon while secondary is held.
local SPEARS = {
    {
        id = "wooden", name = "Wooden", damageBonus = 0, attackDuration = 0.65,
        damageMultiplier = 0.7, delayTicks = 15,
        dismountDurationTicks = 100, dismountThreshold = 14,
        knockbackDurationTicks = 200, knockbackThreshold = 5.1,
        damageDurationTicks = 300, damageThreshold = 4.6,
        wood = true,
    },
    {
        id = "stone", name = "Stone", damageBonus = 1, attackDuration = 0.75,
        damageMultiplier = 0.82, delayTicks = 14,
        dismountDurationTicks = 90, dismountThreshold = 13,
        knockbackDurationTicks = 180, knockbackThreshold = 5.1,
        damageDurationTicks = 275, damageThreshold = 4.6,
    },
    {
        id = "copper", name = "Copper", damageBonus = 1, attackDuration = 0.85,
        damageMultiplier = 0.82, delayTicks = 13,
        dismountDurationTicks = 80, dismountThreshold = 12,
        knockbackDurationTicks = 165, knockbackThreshold = 5.1,
        damageDurationTicks = 250, damageThreshold = 4.6,
    },
    {
        id = "iron", name = "Iron", damageBonus = 2, attackDuration = 0.95,
        damageMultiplier = 0.95, delayTicks = 12,
        dismountDurationTicks = 50, dismountThreshold = 11,
        knockbackDurationTicks = 135, knockbackThreshold = 5.1,
        damageDurationTicks = 225, damageThreshold = 4.6,
    },
    {
        id = "golden", name = "Golden", damageBonus = 0, attackDuration = 0.95,
        damageMultiplier = 0.7, delayTicks = 14,
        dismountDurationTicks = 70, dismountThreshold = 13,
        knockbackDurationTicks = 170, knockbackThreshold = 5.1,
        damageDurationTicks = 275, damageThreshold = 4.6,
    },
    {
        id = "diamond", name = "Diamond", damageBonus = 3, attackDuration = 1.05,
        damageMultiplier = 1.075, delayTicks = 10,
        dismountDurationTicks = 60, dismountThreshold = 10,
        knockbackDurationTicks = 130, knockbackThreshold = 5.1,
        damageDurationTicks = 200, damageThreshold = 4.6,
    },
    {
        id = "netherite", name = "Netherite", damageBonus = 4, attackDuration = 1.15,
        damageMultiplier = 1.2, delayTicks = 8,
        dismountDurationTicks = 50, dismountThreshold = 9,
        knockbackDurationTicks = 110, knockbackThreshold = 5.1,
        damageDurationTicks = 175, damageThreshold = 4.6,
    },
}

for _, spear in ipairs(SPEARS) do
    local itemId = spear.id .. "_spear"
    weapons.Register({
        Base = "weapon_mcitem_spear_base",
        PrintName = "Minecraft " .. spear.name .. " Spear",
        Category = "Minecraft in GMod - Items",
        Instructions = "Left click: fully charged piercing stab. Hold right click: kinetic spear attack.",
        Spawnable = true,
        AdminOnly = false,
        WorldModel = itemModelPath(itemId),

        MCItemID = itemId,
        MCMaterial = spear.id,
        MCToolType = "spear",
        MCSwingType = "stab",
        MCSwingDurationTicks = math.floor(spear.attackDuration * 20),
        MCAttackDamage = 1 + spear.damageBonus,
        MCAttackSpeed = 1 / spear.attackDuration,
        MCAttackKnockback = 0,
        MCIsSword = false,
        -- Player.stabAttack -> itemAttackInteraction -> postHurtEnemy.
        MCWeaponDamagePerAttack = 1,

        MCSpearWood = spear.wood == true,
        MCSpearDamageMultiplier = spear.damageMultiplier,
        MCSpearDelayTicks = spear.delayTicks,
        MCSpearDismountDurationTicks = spear.dismountDurationTicks,
        MCSpearDismountThreshold = spear.dismountThreshold,
        MCSpearKnockbackDurationTicks = spear.knockbackDurationTicks,
        MCSpearKnockbackThreshold = spear.knockbackThreshold,
        MCSpearDamageDurationTicks = spear.damageDurationTicks,
        MCSpearDamageThreshold = spear.damageThreshold,
    }, "weapon_mcitem_" .. itemId)
end
