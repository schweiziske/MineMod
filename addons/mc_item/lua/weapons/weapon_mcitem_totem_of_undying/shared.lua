AddCSLuaFile()

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Totem of Undying"
SWEP.Category = "Minecraft in GMod - Utility"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/totem_of_undying/totem_of_undying.mdl"
SWEP.MCItemID = "totem_of_undying"
SWEP.MCAnchorName = "item"
SWEP.MCThirdPersonProfile = "totem_of_undying"
SWEP.MCThirdPersonSwingGesture = "item_attack"
SWEP.MCDeathProtectionItem = "minecraft:totem_of_undying"
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil

SWEP.Instructions = "Hold it in the selected inventory hand or offhand to survive lethal damage."

function SWEP:IsMCDeathProtectionAvailable(owner)
    if not SERVER or not IsValid(owner) or owner:GetActiveWeapon() ~= self then return false end
    if self.GetNW2Bool and self:GetNW2Bool("MCITEM_InventoryProxy", false) then return false end
    return self.MCDeathProtectionItem == "minecraft:totem_of_undying"
end

function SWEP:ConsumeMCDeathProtection(owner)
    if not self:IsMCDeathProtectionAvailable(owner) then return false, "totem_not_held" end
    local stack = istable(self.MCITEMEnchantmentStack)
        and table.Copy(self.MCITEMEnchantmentStack)
        or { item = "minecraft:totem_of_undying", count = 1 }
    stack.item = "minecraft:totem_of_undying"
    stack.count = 1
    if owner.StripWeapon then owner:StripWeapon(self:GetClass()) else self:Remove() end
    return true, stack
end
