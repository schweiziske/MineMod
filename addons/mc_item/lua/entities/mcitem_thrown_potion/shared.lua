ENT.Type = "anim"
ENT.Base = "mcitem_thrown_item_base"
ENT.PrintName = "Minecraft Thrown Potion"
ENT.Spawnable = false

AddCSLuaFile("mcitem/potions/sh_data.lua")
AddCSLuaFile("mcitem/potions/sh_contract.lua")
AddCSLuaFile("mcitem/potions/sh_audio.lua")

include("mcitem/potions/sh_data.lua")
include("mcitem/potions/sh_contract.lua")
include("mcitem/potions/sh_audio.lua")

function ENT:SetupDataTables()
    self.BaseClass.SetupDataTables(self)
    self:NetworkVar("String", 1, "PotionID")
    self:NetworkVar("String", 2, "BottleType")
end

function ENT:GetMCGravity()
    return MCITEM.Potions.ProjectileGravity
end

function ENT:GetMCInertia()
    return MCITEM.Potions.ProjectileInertia
end
