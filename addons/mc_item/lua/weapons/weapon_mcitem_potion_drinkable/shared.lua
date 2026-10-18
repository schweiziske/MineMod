AddCSLuaFile()
AddCSLuaFile("mcitem/potions/sh_data.lua")
AddCSLuaFile("mcitem/potions/sh_contract.lua")
AddCSLuaFile("mcitem/potions/sh_drink_state.lua")

include("mcitem/potions/sh_data.lua")
include("mcitem/potions/sh_contract.lua")
include("mcitem/potions/sh_drink_state.lua")

if SERVER then include("mcitem/potions/sv_apply.lua") end

SWEP.Base = "weapon_mcitem_potion_base"
SWEP.PrintName = "Minecraft Drinkable Potion Base"
SWEP.Category = "Minecraft in GMod - Potions"
SWEP.Spawnable = false
SWEP.AdminOnly = false

-- 喝药姿势的位置微调：`mcitem_use_potion_*`（举到嘴边那段），静止是 `mcitem_fp_potion_*`。
SWEP.MCAnchorName = "potion"

function SWEP:ResetMCState()
    self:RunMCItemBase("ResetMCState")
    MCITEM.Potions.ResetDrink(self)
end

function SWEP:IsMCUsingItem()
    return MCITEM.Potions.IsDrinking(self)
end

function SWEP:GetMCHoldTypeKey()
    return self:IsMCUsingItem() and "eat" or "item"
end

function SWEP:GetMCUseRenderState()
    if not self:IsMCUsingItem() then return nil end
    return "drink", MCITEM.Potions.DrinkElapsedTicks(self), MCITEM.Potions.DrinkDurationTicks
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() or self:IsMCUsingItem() then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    if SERVER then self:CancelMCMining("potion_drink") end
    MCITEM.Potions.StartDrink(self, now)
end

function SWEP:Think()
    self:RunMCItemBase("Think")
    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    if self:IsMCUsingItem() and not owner:KeyDown(IN_ATTACK2) then
        MCITEM.Potions.CancelDrink(self, "released")
        return
    end

    if SERVER then
        MCITEM.Potions.ServerDrinkTick(self, CurTime())
    else
        MCITEM.Potions.AdvanceClientDrink(self, CurTime())
    end
end

function SWEP:Holster()
    MCITEM.Potions.CancelDrink(self, "holster")
    local result = self:RunMCItemBase("Holster")
    if result ~= nil then return result end
    return true
end

function SWEP:OnRemove()
    MCITEM.Potions.CancelDrink(self, "weapon_removed")
    self:RunMCItemBase("OnRemove")
end
