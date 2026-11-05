AddCSLuaFile()
AddCSLuaFile("mcitem/food/sh_data.lua")
AddCSLuaFile("mcitem/food/sh_contract.lua")
AddCSLuaFile("mcitem/food/sh_state.lua")
AddCSLuaFile("mcitem/food/sh_audio.lua")
AddCSLuaFile("mcitem/food/cl_particles.lua")

include("mcitem/food/sh_data.lua")
include("mcitem/food/sh_contract.lua")
include("mcitem/food/sh_state.lua")
include("mcitem/food/sh_audio.lua")

if SERVER then
    include("mcitem/food/sv_use.lua")
else
    include("mcitem/food/cl_particles.lua")
end

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Food Base"
SWEP.Category = "#mcitem.category.food"
SWEP.Spawnable = false
SWEP.AdminOnly = false

-- Ordinary items have no attack modifiers: Player base attributes remain 1 damage / 4 speed.
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCSwingDurationTicks = 6
SWEP.MCToolType = nil
SWEP.MCMaterial = nil
SWEP.MCUseAction = nil

-- 进食姿势的位置微调：`mcitem_use_food_x/_y/_z/_pitch/_yaw/_roll`（只在举到嘴边
-- 那段期间叠加），静止手持则是 `mcitem_fp_food_*`。用户报"进食时有点偏左"就调
-- `mcitem_use_food_y`（Source 的 Right 轴）。
SWEP.MCAnchorName = "food"
SWEP.MCThirdPersonProfile = "food"

function SWEP:GetMCThirdPersonBaseState()
    return self:IsMCUsingItem() and "use" or "idle"
end

local function callItemBase(self, method, ...)
    local base = weapons.GetStored("weapon_bmb_item_model_test")
    if not base or not isfunction(base[method]) then return end
    return base[method](self, ...)
end

function SWEP:GetMCFoodDefinition()
    return MCITEM.Food.DefinitionForWeapon(self)
end

function SWEP:ResetMCState()
    callItemBase(self, "ResetMCState")
    MCITEM.Food.ResetUse(self)
end

function SWEP:IsMCUsingItem()
    return MCITEM.Food.IsUsing(self)
end

-- 第三人称：吃东西时换成 `mcitem_holdtype_eat` 那一套（默认举到脸前）。
function SWEP:GetMCHoldTypeKey()
    return self:IsMCUsingItem() and "eat" or "item"
end

function SWEP:GetMCUseRenderState()
    if not self:IsMCUsingItem() then return nil end
    local definition = self:GetMCFoodDefinition()
    if not definition then return nil end
    return definition.animation, MCITEM.Food.ElapsedTicks(self), definition.consumeTicks
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() or self:IsMCUsingItem() then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    -- ItemNameBlockItem food (carrot, potato, sweet berries) runs useOn before
    -- the edible fallback. Planting is ItemUseAnimation.NONE: reuse this flat
    -- item/food presentation base, but play only the normal success swing.
    local farming = MCITEM.Farming
    local foodDefinition = self:GetMCFoodDefinition()
    local farmingDefinition = farming and farming.Get and foodDefinition
        and farming.Get(foodDefinition.id) or nil
    local predictsPlant = farmingDefinition and farming.PredictUse
        and farming.PredictUse(owner, farmingDefinition) == true
    if predictsPlant then
        local handled = true
        if SERVER then
            local allowed, _, playerNextUseAt = farming.TryBeginPlayerUse(owner)
            if playerNextUseAt then self:SetNextSecondaryFire(playerNextUseAt) end
            if not allowed then return end
            self:CancelMCMining("farming_use")
            handled = farming.TryUse(self, farmingDefinition) == true
        end
        if handled and IsValid(self) then
            self:MCSwing(now)
            self:PlayMCThirdPersonSwing(now, owner)
        end
        return
    end

    if SERVER then self:CancelMCMining("food_use") end
    if not MCITEM.Food.StartUse(self, now) then self:MCTryOffhandUse() end
end

function SWEP:Think()
    callItemBase(self, "Think")
    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    if self:IsMCUsingItem() and not owner:KeyDown(IN_ATTACK2) then
        MCITEM.Food.CancelUse(self, "released")
        return
    end

    if SERVER then
        MCITEM.Food.ServerTick(self, CurTime())
    else
        MCITEM.Food.AdvanceClientUse(self, CurTime())
    end
end

function SWEP:Holster()
    MCITEM.Food.CancelUse(self, "holster")
    local result = callItemBase(self, "Holster")
    if result ~= nil then return result end
    return true
end

function SWEP:OnRemove()
    MCITEM.Food.CancelUse(self, "weapon_removed")
    callItemBase(self, "OnRemove")
end
