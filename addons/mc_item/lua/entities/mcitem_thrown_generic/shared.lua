ENT.Type = "anim"
ENT.Base = "mcitem_thrown_item_base"
ENT.PrintName = "Minecraft Thrown Item"
ENT.Spawnable = false

AddCSLuaFile("mcitem/throwables/sh_data.lua")
AddCSLuaFile("mcitem/throwables/sh_contract.lua")
AddCSLuaFile("mcitem/throwables/sh_collision.lua")

include("mcitem/throwables/sh_data.lua")
include("mcitem/throwables/sh_contract.lua")
include("mcitem/throwables/sh_collision.lua")

function ENT:SetupDataTables()
    self.BaseClass.SetupDataTables(self)
    self:NetworkVar("String", 1, "ThrowableID")
    self:NetworkVar("String", 2, "ThrowableBehavior")
end

function ENT:SetupThrowable(owner, identifier)
    local definition = MCITEM.Throwables.Get(identifier)
    if not definition or definition.id == "ender_eye" then return false end
    if IsValid(owner) then self:SetOwner(owner) end
    self:SetThrowableID(definition.id)
    self:SetThrowableBehavior(definition.behavior)
    self:SetItemModelID(definition.modelId)
    self.MCThrowableDefinition = definition
    self.MCThrowableBehavior = definition.behavior
    self.MCGravity = definition.gravity
    self.MCInertia = definition.inertia
    self.MCCollisionRadius = definition.collisionRadius
    self:SetModel("models/mcgm/" .. definition.modelId .. "/" .. definition.modelId .. ".mdl")
    return true
end

function ENT:CanMCBeDeflected()
    local behavior = MCITEM.Throwables.Behavior and MCITEM.Throwables.Behavior(
        self.MCThrowableBehavior or self:GetThrowableBehavior()
    ) or nil
    if behavior and isfunction(behavior.CanDeflect) then return behavior.CanDeflect(self) == true end
    return true
end

-- AbstractWindCharge entities never collide with one another, including the
-- player Wind Charge and the Breeze-specific Wind Charge entity type.
function ENT:ShouldMCProjectileHitEntity(entity)
    if not IsValid(entity) or entity:GetClass() ~= "mcitem_thrown_generic" then return nil end
    local ours = self.MCThrowableBehavior or self:GetThrowableBehavior()
    local theirs = entity.MCThrowableBehavior or entity:GetThrowableBehavior()
    if ours == "wind_charge" and theirs == "wind_charge" then return false end
    return nil
end
