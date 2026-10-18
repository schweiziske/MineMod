ENT.Type = "anim"
ENT.Base = "mcitem_thrown_item_base"
ENT.PrintName = "Minecraft Shulker Bullet"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

AddCSLuaFile("mcitem/throwables/sh_data.lua")
AddCSLuaFile("mcitem/throwables/sh_collision.lua")

include("mcitem/throwables/sh_data.lua")
include("mcitem/throwables/sh_collision.lua")

function ENT:SetupDataTables()
    self.BaseClass.SetupDataTables(self)
    self:NetworkVar("Entity", 0, "MCTarget")
    self:NetworkVar("String", 1, "MCMovementAxis")
    self:NetworkVar("Vector", 3, "MCTargetDelta")
    self:NetworkVar("Int", 1, "MCFlightSteps")
end

function ENT:SetupThrowable(owner, identifier)
    local definition = MCITEM.Throwables.Get(identifier)
    if not definition or definition.id ~= "shulker_bullet" then return false end
    if IsValid(owner) then self:SetOwner(owner) end
    self:SetItemModelID("shulker_bullet")
    self.MCThrowableDefinition = definition
    self.MCThrowableBehavior = "shulker_bullet"
    self.MCCollisionRadius = definition.collisionRadius or 0.15625
    self:SetModel("models/mcgm/shulker_bullet/shulker_bullet.mdl")
    return true
end

function ENT:GetMCCollisionRadius()
    return tonumber(self.MCCollisionRadius) or 0.15625
end

function ENT:CanMCBeDeflected()
    return true
end

function ENT:ShouldMCProjectileHitEntity(entity)
    if IsValid(entity) and entity:GetClass() == "mcitem_shulker_bullet" then return false end
    return nil
end
