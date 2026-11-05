AddCSLuaFile()
AddCSLuaFile("mcitem/potions/sh_data.lua")
AddCSLuaFile("mcitem/potions/sh_contract.lua")
AddCSLuaFile("mcitem/potions/sh_audio.lua")

include("mcitem/potions/sh_data.lua")
include("mcitem/potions/sh_contract.lua")
include("mcitem/potions/sh_audio.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Potion Base"
SWEP.Category = "#mcitem.category.potions"
SWEP.Spawnable = false
SWEP.AdminOnly = false

-- Potion bottles are ordinary items for attack/mining purposes.
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCSwingDurationTicks = 6
SWEP.MCToolType = nil
SWEP.MCMaterial = nil
SWEP.MCUseAction = nil

SWEP.MCThirdPersonProfile = "potion"

function SWEP:GetMCThirdPersonBaseState()
    return self.IsMCUsingItem and self:IsMCUsingItem() and "use" or "idle"
end

function SWEP:GetMCPotionDefinition()
    return MCITEM.Potions.DefinitionForWeapon(self)
end

function SWEP:GetMCPotionBottleType()
    return MCITEM.Potions.BottleTypeForWeapon(self)
end

function SWEP:GetMCPotionModelID()
    return MCITEM.Potions.ModelIDForWeapon(self)
end

function SWEP:RunMCItemBase(method, ...)
    local base = weapons.GetStored("weapon_bmb_item_model_test")
    if not base or not isfunction(base[method]) then return end
    return base[method](self, ...)
end
