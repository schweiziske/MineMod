AddCSLuaFile()
AddCSLuaFile("mcitem/fishing/sh_generated_data.lua")
AddCSLuaFile("mcitem/fishing/sh_core.lua")

include("mcitem/fishing/sh_core.lua")

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Minecraft Fishing Bobber"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT
ENT.MCProjectile = true

function ENT:SetupDataTables()
    self:NetworkVar("Entity", 0, "HookedEntity")
    self:NetworkVar("Vector", 0, "MCVelocity")
    self:NetworkVar("Bool", 0, "Biting")
    self:NetworkVar("Bool", 1, "MCOnGround")
    self:NetworkVar("Bool", 2, "OpenWater")
    self:NetworkVar("Int", 0, "HookState")
end

function ENT:GetRodWeapon()
    local weapon = self:GetNW2Entity("MCITEM_FishingRod")
    if IsValid(weapon) then return weapon end
    local owner = self:GetOwner()
    weapon = IsValid(owner) and owner:GetActiveWeapon() or nil
    return IsValid(weapon) and weapon:GetClass() == "weapon_mcitem_fishing_rod" and weapon or nil
end
