AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/potions/sv_apply.lua")

function ENT:SetupPotion(owner, bottleType, potionId)
    local definition = MCITEM.Potions.Get(potionId)
    local modelId = definition and MCITEM.Potions.ModelID(bottleType, definition.id) or nil
    if not definition or not modelId then return false end
    self:SetOwner(owner)
    self:SetPotionID(definition.id)
    self:SetBottleType(bottleType)
    self:SetItemModelID(modelId)
    self:SetModel("models/mcgm/" .. modelId .. "/" .. modelId .. ".mdl")
    return true
end

local function spawnCloud(projectile, definition)
    local cloud = ents.Create("mcitem_potion_cloud")
    if not IsValid(cloud) then return nil end
    cloud:SetPos(projectile:GetPos())
    cloud:Spawn()
    cloud:Activate()
    cloud:SetupPotionCloud(projectile:GetOwner(), definition.id)
    hook.Run("MCITEM.PotionCloudSpawned", projectile:GetOwner(), projectile, cloud, definition)
    return cloud
end

function ENT:OnMCProjectileHit(trace)
    local definition = MCITEM.Potions.Get(self:GetPotionID())
    if not definition then return true end
    local owner = self:GetOwner()
    local bottleType = self:GetBottleType()
    local position = trace.HitPos or self:GetPos()

    if MCITEM.Potions.IsWaterPotion(definition) then
        MCITEM.Potions.ApplyWaterSplash(position, owner, self)
    elseif bottleType == "lingering" then
        spawnCloud(self, definition)
    else
        MCITEM.Potions.ApplySplash(position, definition, owner, self)
    end

    MCITEM.Potions.BroadcastBreak(position, definition)
    MCITEM.Potions.PlayBreakSound(position)
    hook.Run("MCITEM.PotionProjectileBroken", owner, self, definition, bottleType, trace)
    return true
end
