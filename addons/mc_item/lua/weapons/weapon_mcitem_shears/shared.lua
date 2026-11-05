AddCSLuaFile()
AddCSLuaFile("mcitem/utility/sh_use.lua")

include("mcitem/utility/sh_use.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.shears"
SWEP.Category = "#mcitem.category.utility"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/shears/shears.mdl"
SWEP.MCItemID = "shears"
SWEP.MCAnchorName = "item"
SWEP.MCThirdPersonProfile = "shears"
SWEP.MCThirdPersonSwingGesture = "item_attack"
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil

SWEP.MCInstructionsKey = "mcitem.instructions.shears"

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() or not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() then return end
    self:CancelMCMining("shears_use")
    local shears = MCITEM.Shears
    local ok = shears and isfunction(shears.Use) and shears.Use(owner, self)
    if ok then MCITEM.Utility.ConfirmSwing(self, "shears_use")
    else self:MCTryOffhandUse() end
end
