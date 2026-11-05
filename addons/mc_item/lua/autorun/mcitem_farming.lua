-- Java 26.2 seeds, wheat and bone meal. Carrot/potato/sweet-berry planting is
-- attached to their existing food SWEPs by weapon_mcitem_food_base.

if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("mcitem/farming/sh_data.lua")
    AddCSLuaFile("mcitem/farming/sh_contract.lua")
    AddCSLuaFile("mcitem/farming/cl_particles.lua")
    AddCSLuaFile("weapons/weapon_mcitem_farming_base/shared.lua")
    if resource and resource.AddFile then
        resource.AddFile("materials/mcitem/farming/happy_villager.vmt")
        resource.AddFile("materials/mcitem/farming/happy_villager.vtf")
        resource.AddFile("sound/mcitem/farming/bonemeal1.ogg")
        resource.AddFile("sound/mcitem/farming/bonemeal2.ogg")
        resource.AddFile("sound/mcitem/farming/bonemeal3.ogg")
        resource.AddFile("sound/mcitem/farming/bonemeal4.ogg")
        resource.AddFile("sound/mcitem/farming/bonemeal5.ogg")
    end
end

include("mcitem/farming/sh_data.lua")
include("mcitem/farming/sh_contract.lua")
if SERVER then
    include("mcitem/farming/sv_use.lua")
else
    include("mcitem/farming/cl_particles.lua")
end

for _, itemId in ipairs(MCITEM.Farming.RegisteredItemOrder) do
    local definition = MCITEM.Farming.Get(itemId)
    weapons.Register({
        Base = "weapon_mcitem_farming_base",
        PrintName = "#item.minecraft." .. definition.id,
        Category = "#mcitem.category.farming",
        MCInstructionsKey = definition.action == "plant" and "mcitem.instructions.plant"
            or definition.action == "bonemeal" and "mcitem.instructions.bonemeal" or "mcitem.instructions.attack",
        Spawnable = true,
        AdminOnly = false,
        WorldModel = definition.model,

        MCItemID = definition.id,
        MCFarmingID = definition.id,
        MCFarmingDefinition = definition,
        MCMaxStack = definition.maxStack,
        MCAttackDamage = 1,
        MCAttackSpeed = 4,
        MCAttackKnockback = 0,
        MCIsSword = false,
        MCWeaponDamagePerAttack = 0,
        MCSwingDurationTicks = 6,
    }, "weapon_mcitem_" .. definition.id)
end
