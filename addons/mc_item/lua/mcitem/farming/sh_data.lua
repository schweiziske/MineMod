-- Minecraft Java 26.2 crop-item definitions. The eight registered model
-- families use *_item names so MCITEM never overwrites BMB's models/mcgm tree.

MCITEM = MCITEM or {}
MCITEM.Farming = MCITEM.Farming or {}

local Farming = MCITEM.Farming

Farming.RightClickDelayTicks = 4
Farming.GrowthParticleCount = 15
Farming.UseAnimation = "none" -- ItemUseAnimation.NONE for BlockItem/useOn.

Farming.RegisteredItemOrder = {
    "wheat",
    "wheat_seeds",
    "beetroot_seeds",
    "melon_seeds",
    "pumpkin_seeds",
    "bone_meal",
    "torchflower_seeds",
    "pitcher_pod",
}

Farming.Definitions = {
    wheat = {
        id = "wheat", name = "Wheat", maxStack = 64,
        model = "models/mcgm/wheat_item/wheat_item.mdl",
    },
    wheat_seeds = {
        id = "wheat_seeds", name = "Wheat Seeds", maxStack = 64,
        action = "plant", crop = "minecraft:wheat", support = "farmland",
        model = "models/mcgm/wheat_seeds_item/wheat_seeds_item.mdl",
    },
    beetroot_seeds = {
        id = "beetroot_seeds", name = "Beetroot Seeds", maxStack = 64,
        action = "plant", crop = "minecraft:beetroots", support = "farmland",
        model = "models/mcgm/beetroot_seeds_item/beetroot_seeds_item.mdl",
    },
    melon_seeds = {
        id = "melon_seeds", name = "Melon Seeds", maxStack = 64,
        action = "plant", crop = "minecraft:melon_stem", support = "farmland",
        model = "models/mcgm/melon_seeds_item/melon_seeds_item.mdl",
    },
    pumpkin_seeds = {
        id = "pumpkin_seeds", name = "Pumpkin Seeds", maxStack = 64,
        action = "plant", crop = "minecraft:pumpkin_stem", support = "farmland",
        model = "models/mcgm/pumpkin_seeds_item/pumpkin_seeds_item.mdl",
    },
    bone_meal = {
        id = "bone_meal", name = "Bone Meal", maxStack = 64,
        action = "bonemeal",
        model = "models/mcgm/bone_meal_item/bone_meal_item.mdl",
    },
    torchflower_seeds = {
        id = "torchflower_seeds", name = "Torchflower Seeds", maxStack = 64,
        action = "plant", crop = "minecraft:torchflower_crop", support = "farmland",
        model = "models/mcgm/torchflower_seeds_item/torchflower_seeds_item.mdl",
    },
    pitcher_pod = {
        id = "pitcher_pod", name = "Pitcher Pod", maxStack = 64,
        action = "plant", crop = "minecraft:pitcher_crop", support = "farmland",
        model = "models/mcgm/pitcher_pod_item/pitcher_pod_item.mdl",
    },

    -- These already exist in the food registry. weapon_mcitem_food_base gives
    -- their block-use path priority, then falls back to eating on PASS.
    carrot = {
        id = "carrot", action = "plant", crop = "minecraft:carrots", support = "farmland",
        existingWeapon = true,
    },
    potato = {
        id = "potato", action = "plant", crop = "minecraft:potatoes", support = "farmland",
        existingWeapon = true,
    },
    sweet_berries = {
        id = "sweet_berries", action = "plant", crop = "minecraft:sweet_berry_bush",
        support = "vegetation", existingWeapon = true,
    },
}

function Farming.Get(itemId)
    if not isstring(itemId) then return nil end
    return Farming.Definitions[string.gsub(itemId, "^minecraft:", "")]
end

function Farming.DefinitionForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if istable(weapon.MCFarmingDefinition) then return weapon.MCFarmingDefinition end
    return Farming.Get(weapon.MCFarmingID or weapon.MCItemID)
end

