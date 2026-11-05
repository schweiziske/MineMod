-- Small data-driven registry for model-backed ordinary items that need no
-- bespoke use runtime.  Registering them lets the MineMod selected-stack bridge
-- render the real 3D item instead of falling back to its flat sprite hand.

if SERVER then AddCSLuaFile() end

local ITEMS = {
    { id = "bowl", maxStack = 64 },
}

for _, item in ipairs(ITEMS) do
    weapons.Register({
        Base = "weapon_bmb_item_model_test",
        PrintName = "#item.minecraft." .. item.id,
        Category = "#mcitem.category.items",
        MCInstructionsKey = "mcitem.instructions.interact",
        Spawnable = true,
        AdminOnly = false,
        WorldModel = "models/mcgm/" .. item.id .. "/" .. item.id .. ".mdl",

        MCItemID = item.id,
        MCMaxStack = item.maxStack,
        MCHoldTypeName = "item",
        MCAttackDamage = 1,
        MCAttackSpeed = 4,
        MCAttackKnockback = 0,
        MCIsSword = false,
        MCWeaponDamagePerAttack = 0,
        MCSwingDurationTicks = 6,
    }, "weapon_mcitem_" .. item.id)
end
