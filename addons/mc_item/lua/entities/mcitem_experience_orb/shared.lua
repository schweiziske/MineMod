ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "#mcitem.entity.experience_orb"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

AddCSLuaFile("mcitem/throwables/sh_contract.lua")
AddCSLuaFile("mcitem/throwables/sh_collision.lua")

include("mcitem/throwables/sh_contract.lua")
include("mcitem/throwables/sh_collision.lua")

function ENT:SetupDataTables()
    self:NetworkVar("Int", 0, "ExperienceValue")
    self:NetworkVar("Int", 1, "OrbCount")
    self:NetworkVar("Int", 2, "OrbAge")
end
