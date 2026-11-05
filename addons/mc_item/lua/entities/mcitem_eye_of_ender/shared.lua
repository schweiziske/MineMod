ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "#mcitem.entity.eye_of_ender"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

AddCSLuaFile("mcitem/throwables/sh_contract.lua")
AddCSLuaFile("mcitem/throwables/sh_collision.lua")

include("mcitem/throwables/sh_contract.lua")
include("mcitem/throwables/sh_collision.lua")

function ENT:SetupDataTables()
    self:NetworkVar("Vector", 0, "MCEyeVelocity")
    self:NetworkVar("Bool", 0, "MCEyeInWater")
    self:NetworkVar("Bool", 1, "MCEyeSurvives")
    self:NetworkVar("Int", 0, "MCEyeTick")
end
