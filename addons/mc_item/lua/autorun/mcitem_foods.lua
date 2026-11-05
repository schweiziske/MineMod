-- Data-driven registration for every Item.Properties.food registration in Java 26.2.

if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("mcitem/food/sh_data.lua")
    AddCSLuaFile("mcitem/food/sh_contract.lua")
    AddCSLuaFile("mcitem/food/sh_state.lua")
    AddCSLuaFile("mcitem/food/sh_audio.lua")
    AddCSLuaFile("mcitem/food/cl_particles.lua")
end

include("mcitem/food/sh_data.lua")
include("mcitem/food/sh_contract.lua")
include("mcitem/food/sh_state.lua")
include("mcitem/food/sh_audio.lua")

if SERVER then
    include("mcitem/food/sv_effects.lua")
    include("mcitem/food/sv_use.lua")
else
    include("mcitem/food/cl_particles.lua")
end

for _, definition in ipairs(MCITEM.Food.Definitions) do
    local itemId = definition.id
    -- `modelId` is the compiled-asset name under models/mcgm and defaults to
    -- the item id.  It exists because a few MC item ids collide with entity
    -- ids (raw chicken / raw rabbit), and because it is a useful extension
    -- point: an addon can point any item at any compiled model.  The same
    -- field name is already used by the thrown-item entities.
    local modelId = definition.modelId or itemId
    weapons.Register({
        Base = "weapon_mcitem_food_base",
        PrintName = "#item.minecraft." .. definition.id,
        Category = "#mcitem.category.food",
        MCInstructionsKey = definition.id == "milk_bucket" and "mcitem.instructions.milk" or "mcitem.instructions.food",
        Spawnable = true,
        AdminOnly = false,
        WorldModel = "models/mcgm/" .. modelId .. "/" .. modelId .. ".mdl",

        MCItemID = itemId,
        MCFoodID = itemId,
        MCFoodDefinition = definition,
        MCMaxStack = definition.maxStack,
        MCAttackDamage = 1,
        MCAttackSpeed = 4,
        MCAttackKnockback = 0,
        MCIsSword = false,
        MCSwingDurationTicks = 6,
    }, "weapon_mcitem_" .. itemId)
end
