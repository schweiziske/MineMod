-- Spawn-menu registration kept separate from behavior/runtime modules.

for _, definition in ipairs(MCITEM.Throwables.Definitions) do
    if definition.registerWeapon ~= false then
        local itemId = definition.id
        weapons.Register({
            Base = "weapon_mcitem_throwable_base",
            PrintName = "#item.minecraft." .. definition.id,
            Category = "#mcitem.category.throwables",
            MCInstructionsKey = "mcitem.instructions.use",
            Spawnable = true,
            AdminOnly = false,
            WorldModel = "models/mcgm/" .. definition.modelId .. "/" .. definition.modelId .. ".mdl",

            MCItemID = itemId,
            MCThrowableID = itemId,
            MCThrowableDefinition = definition,
            MCAttackDamage = 1,
            MCAttackSpeed = 4,
            MCAttackKnockback = 0,
            MCIsSword = false,
            MCSwingDurationTicks = 6,
        }, "weapon_mcitem_" .. itemId)
    end
end
