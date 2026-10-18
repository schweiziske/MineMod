ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Potion Cloud"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

AddCSLuaFile("mcitem/potions/sh_data.lua")
AddCSLuaFile("mcitem/potions/sh_contract.lua")

include("mcitem/potions/sh_data.lua")
include("mcitem/potions/sh_contract.lua")

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "PotionID")
    self:NetworkVar("Int", 0, "PotionColor")
    self:NetworkVar("Float", 0, "CloudRadius")
    self:NetworkVar("Bool", 0, "Waiting")
    self:NetworkVar("Entity", 0, "CloudOwner")
end
