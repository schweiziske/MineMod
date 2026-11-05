AddCSLuaFile()
AddCSLuaFile("mcitem/potions/sh_data.lua")
AddCSLuaFile("mcitem/potions/sh_contract.lua")
AddCSLuaFile("mcitem/potions/sh_audio.lua")

include("mcitem/potions/sh_data.lua")
include("mcitem/potions/sh_contract.lua")
include("mcitem/potions/sh_audio.lua")

if SERVER then include("mcitem/potions/sv_throw.lua") end

SWEP.Base = "weapon_mcitem_potion_base"
SWEP.PrintName = "Minecraft Throwable Potion Base"
SWEP.Category = "#mcitem.category.potions"
SWEP.Spawnable = false
SWEP.AdminOnly = false

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    if SERVER then
        self:CancelMCMining("potion_throw")
        if not IsValid(MCITEM.Potions.Throw(self)) then return end
    end

    -- 用户要的"投掷药水要加动画"：第一人称用挖方块那段挥动，第三人称用丢手雷。
    self:MCSwing(now)
    self:PlayMCGesture("throw")
end
