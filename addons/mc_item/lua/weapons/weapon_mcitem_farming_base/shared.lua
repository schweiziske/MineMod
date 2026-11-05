AddCSLuaFile()
AddCSLuaFile("mcitem/farming/sh_data.lua")
AddCSLuaFile("mcitem/farming/sh_contract.lua")
AddCSLuaFile("mcitem/farming/cl_particles.lua")

include("mcitem/farming/sh_data.lua")
include("mcitem/farming/sh_contract.lua")
if SERVER then
    include("mcitem/farming/sv_use.lua")
else
    include("mcitem/farming/cl_particles.lua")
end

-- Reuse the food/item hand presentation stack for flat generated items. Java
-- planting itself is ItemUseAnimation.NONE, so success plays only normal swing.
SWEP.Base = "weapon_mcitem_food_base"
SWEP.PrintName = "Minecraft Farming Item Base"
SWEP.Category = "#mcitem.category.farming"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCSwingDurationTicks = 6
SWEP.MCHoldTypeName = "item"
SWEP.MCAnchorName = "food"
SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = false,
    Ammo = "none",
}

function SWEP:GetMCFarmingDefinition()
    return MCITEM.Farming.DefinitionForWeapon(self)
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(
        now + MCITEM.Farming.RightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() then return end

    local owner = self:GetOwner()
    local definition = self:GetMCFarmingDefinition()
    if not IsValid(owner) or not definition then return end
    local predicted = MCITEM.Farming.PredictUse(owner, definition)
    if not predicted then self:MCTryOffhandUse() return end

    local handled = true
    if SERVER then
        local allowed, _, playerNextUseAt = MCITEM.Farming.TryBeginPlayerUse(owner)
        if playerNextUseAt then self:SetNextSecondaryFire(playerNextUseAt) end
        if not allowed then return end
        self:CancelMCMining("farming_use")
        handled = MCITEM.Farming.TryUse(self, definition) == true
    end

    if handled and IsValid(self) then
        self:MCSwing(now)
        self:PlayMCThirdPersonSwing(now, owner)
    end
end

