AddCSLuaFile()
AddCSLuaFile("mcitem/utility/sh_use.lua")
AddCSLuaFile("mcitem/fishing/sh_generated_data.lua")
AddCSLuaFile("mcitem/fishing/sh_core.lua")

include("mcitem/utility/sh_use.lua")
include("mcitem/fishing/sh_core.lua")

local Fishing = MCITEM.Fishing

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.fishing_rod"
SWEP.Category = "#mcitem.category.utility"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/fishing_rod/fishing_rod.mdl"
SWEP.MCCastModel = "models/mcgm/fishing_rod_cast/fishing_rod_cast.mdl"
SWEP.MCItemID = "fishing_rod"
SWEP.MCAnchorName = "fishing_rod"
SWEP.MCThirdPersonProfile = "fishing_rod"
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil
SWEP.MCThirdPersonSwingGesture = "item_attack"

SWEP.MCInstructionsKey = "mcitem.instructions.fishing_rod"

local FIRST_PERSON_DISPLAY = {
    rotation = { 0, 90, 25 },
    translation = { 0, 1.6, 0.8 },
    scale = { 0.68, 0.68, 0.68 },
}

local function retrievalPitch()
    return 0.4 / (math.Rand(0, 1) * 0.4 + 0.8)
end

local function validFishingHook(entity, owner, weapon)
    return IsValid(entity)
        and entity:GetClass() == "mcitem_fishing_hook"
        and (not IsValid(owner) or entity:GetOwner() == owner)
        and (not IsValid(weapon) or entity:GetRodWeapon() == weapon)
end

function SWEP:GetMCFishingHook()
    local owner = self:GetOwner()
    if SERVER and validFishingHook(self.MCFishingHook, owner, self) then
        return self.MCFishingHook
    end
    local entity = self:GetNW2Entity("MCITEM_FishingHook")
    return validFishingHook(entity, owner, self) and entity or nil
end

function SWEP:SetMCFishingHook(entity)
    if not SERVER then return false end
    entity = validFishingHook(entity, self:GetOwner(), self) and entity or nil
    self.MCFishingHook = entity
    self:SetNW2Entity("MCITEM_FishingHook", entity or NULL)
    if IsValid(self) then self:SetModel(entity and self.MCCastModel or self.WorldModel) end
    return true
end

function SWEP:HasMCFishingHook()
    return IsValid(self:GetMCFishingHook())
end

function SWEP:GetMCFirstPersonModel()
    return self:HasMCFishingHook() and self.MCCastModel or self.WorldModel
end

function SWEP:GetMCThirdPersonModel()
    return self:GetMCFirstPersonModel()
end

function SWEP:GetMCFirstPersonDisplay()
    return FIRST_PERSON_DISPLAY
end

function SWEP:CleanupMCFishingHook(reason)
    if not SERVER then return end
    local entity = self:GetMCFishingHook()
    self.MCFishingHook = nil
    self:SetNW2Entity("MCITEM_FishingHook", NULL)
    if IsValid(self) then self:SetModel(self.WorldModel) end
    if IsValid(entity) and entity.MCRetrieving ~= true then
        entity.MCCleanupReason = reason
        entity:Remove()
    end
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    if SERVER then self:CleanupMCFishingHook("deploy") end
    return result
end

function SWEP:CastMCFishingHook(owner)
    if not SERVER or self:HasMCFishingHook() then return false end
    local stack = MCITEM.Fishing.SelectedStack(owner, self)
    if not istable(stack) or stack.item ~= "minecraft:fishing_rod" then return false end

    local position = MCITEM.Fishing.LaunchOrigin(owner)
    if not isvector(position) then return false end
    local entity = ents.Create("mcitem_fishing_hook")
    if not IsValid(entity) then return false end

    entity:SetOwner(owner)
    entity:SetPos(position)
    entity:SetAngles(owner:EyeAngles())
    entity:Spawn()
    entity:Activate()
    entity:Launch(owner, self, stack)
    self:SetMCFishingHook(entity)

    MCITEM.Fishing.PlaySound(
        "entity.fishing_bobber.throw",
        owner:GetPos(),
        0.5,
        0.5, -- Cast resource pitch is 1; Java clamps the throw to 0.5.
        72
    )
    hook.Run("MCITEM.FishingCast", owner, self, entity, table.Copy(stack))
    return true
end

function SWEP:RetrieveMCFishingHook(owner, entity)
    if not SERVER or not validFishingHook(entity, owner, self) then return false end
    local ok, damage = entity:Retrieve()
    if not ok then return false end
    MCITEM.Fishing.PlaySound(
        "entity.fishing_bobber.retrieve",
        owner:GetPos(),
        1,
        retrievalPitch(),
        72
    )
    hook.Run("MCITEM.FishingRetrieved", owner, self, damage)
    return true
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() or not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() then return end
    self:CancelMCMining("fishing_rod_use")

    local entity = self:GetMCFishingHook()
    local ok = IsValid(entity)
        and self:RetrieveMCFishingHook(owner, entity)
        or self:CastMCFishingHook(owner)
    if ok and IsValid(self) then MCITEM.Utility.ConfirmSwing(self, "fishing_rod_use") end
end

if CLIENT then
    local function modelTip(model, position, angles, scale)
        if not IsValid(model) or not isvector(position) or not isangle(angles) then return nil end
        local minimum, maximum = model:OBBMins(), model:OBBMaxs()
        if not isvector(minimum) or not isvector(maximum) then return nil end
        local localTip = Vector((minimum.x + maximum.x) * 0.5, maximum.y, maximum.z)
            * math.max(tonumber(scale) or 1, 0.001)
        local worldPosition = LocalToWorld(localTip, angle_zero, position, angles)
        return isvector(worldPosition) and worldPosition or nil
    end

    local function fallbackLineOrigin(owner, weapon)
        local eye = owner:EyePos()
        local angles = owner:EyeAngles()
        local firstPerson = owner == LocalPlayer()
            and (not owner.ShouldDrawLocalPlayer or not owner:ShouldDrawLocalPlayer())
        if firstPerson then
            local swing = weapon.GetMCRenderSwing and weapon:GetMCRenderSwing(0) or 0
            local swingCurve = math.sin(math.sqrt(math.max(swing, 0)) * math.pi)
            local adjusted = Angle(angles.p, angles.y, angles.r)
            adjusted:RotateAroundAxis(adjusted:Up(), math.deg(swingCurve * 0.5))
            adjusted:RotateAroundAxis(adjusted:Right(), math.deg(-swingCurve * 0.7))
            local fov = math.max(owner:GetFOV(), 1)
            local scale = Fishing.BlockSize() * 70 / fov
            return eye + adjusted:Forward() * (0.65 * scale)
                + adjusted:Right() * (0.35 * scale)
                - adjusted:Up() * (0.1 * scale)
        end

        local bodyAngles = Angle(0, owner:GetAngles().y, 0)
        local crouch = owner.Crouching and owner:Crouching() and -0.1875 or 0
        return eye + bodyAngles:Forward() * (0.8 * Fishing.BlockSize())
            + bodyAngles:Right() * (0.35 * Fishing.BlockSize())
            + Vector(0, 0, (crouch - 0.45) * Fishing.BlockSize())
    end

    function SWEP:GetMCFishingLineOrigin(owner)
        if not IsValid(owner) then return nil end
        local firstPerson = owner == LocalPlayer()
            and (not owner.ShouldDrawLocalPlayer or not owner:ShouldDrawLocalPlayer())
        if firstPerson and IsValid(self.MCItemPreview) then
            local position = modelTip(
                self.MCItemPreview,
                self.MCItemPreview:GetPos(),
                self.MCItemPreview:GetAngles(),
                self.MCItemPreview:GetModelScale()
            )
            if position then return position end
        elseif IsValid(self.MCItemWorldModel)
        and self.MCItemWorldRenderPosition and self.MCItemWorldRenderAngles then
            local position = modelTip(
                self.MCItemWorldModel,
                self.MCItemWorldRenderPosition,
                self.MCItemWorldRenderAngles,
                self.MCItemWorldRenderScale
            )
            if position then return position end
        end
        return fallbackLineOrigin(owner, self)
    end
end

function SWEP:Holster()
    if SERVER then self:CleanupMCFishingHook("holster") end
    if self.BaseClass.Holster then return self.BaseClass.Holster(self) end
    return true
end

function SWEP:OnRemove()
    if SERVER then self:CleanupMCFishingHook("weapon_removed") end
    if self.BaseClass.OnRemove then self.BaseClass.OnRemove(self) end
end
