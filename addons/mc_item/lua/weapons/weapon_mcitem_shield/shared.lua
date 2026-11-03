AddCSLuaFile()
AddCSLuaFile("mcitem/utility/sh_use.lua")

include("mcitem/utility/sh_use.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Shield"
SWEP.Category = "Minecraft in GMod - Utility"
SWEP.Instructions = "Hold right click to block attacks after the vanilla 0.25 second raise delay. Axes disable blocking for 5 seconds. Left click attacks or mines while lowered."
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/shield/shield.mdl"
SWEP.MCItemID = "shield"
SWEP.MCGlintProfile = "entity"
SWEP.MCAnchorName = "shield"
SWEP.MCExactShieldFirstPerson = true
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil
SWEP.HoldType = "normal"
SWEP.MCThirdPersonProfile = "shield"
SWEP.MCThirdPersonSwingGesture = "item_attack"

local PREDICTION_GRACE_SECONDS = 0.75
local IDLE_DISPLAY = {
    rotation = { 0, 180, 5 },
    translation = { -10, 1.75, -10 },
    scale = { 1.25, 1.25, 1.25 },
}
local BLOCK_DISPLAY = {
    rotation = { 0, 180, -5 },
    translation = { -15, 3.25, -11 },
    scale = { 1.25, 1.25, 1.25 },
}

local function inventoryApi()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    return istable(inventory) and inventory or nil
end

local function useContext(weapon, reason)
    return {
        expectedClass = weapon:GetClass(),
        expectedItem = "minecraft:shield",
        reason = reason or "mcitem_shield",
    }
end

function SWEP:IsMCInventoryShield()
    return MCITEM.Utility.IsInventoryProxy(self)
end

function SWEP:IsMCShieldDisabled()
    local owner = self:GetOwner()
    return IsValid(owner)
        and owner.GetNWFloat
        and owner:GetNWFloat("mc_shield_disabled_until", 0) > CurTime()
        or false
end

function SWEP:SetMCShieldUsing(active, startedAt)
    active = active == true
    self.MCShieldUsing = active
    self.MCShieldUseStartedAt = active and (startedAt or CurTime()) or nil
    if not SERVER then return end
    self:SetNW2Bool("MCITEM_ShieldUsing", active)
    self:SetNW2Float("MCITEM_ShieldUseStartedAt", active and self.MCShieldUseStartedAt or 0)
    self:SetMCThirdPersonUseState(active, self.MCShieldUseStartedAt)
end

function SWEP:SetMCPredictedShieldUsing(active)
    if not CLIENT then return end
    self.MCPredictedShieldUsing = active == true
    self.MCPredictedShieldStartedAt = self.MCPredictedShieldUsing and CurTime() or nil
end

function SWEP:IsMCShieldRaised()
    if SERVER then return self.MCShieldUsing == true end
    if self.MCPredictedShieldUsing then return true end
    return self:GetNW2Bool("MCITEM_ShieldUsing", false)
end

function SWEP:GetMCShieldUseTicks()
    local startedAt
    if SERVER then
        startedAt = self.MCShieldUseStartedAt
    elseif self.MCPredictedShieldUsing then
        startedAt = self.MCPredictedShieldStartedAt
    else
        startedAt = self:GetNW2Float("MCITEM_ShieldUseStartedAt", 0)
    end
    if not self:IsMCShieldRaised() or not startedAt or startedAt <= 0 then return 0 end
    return math.max((CurTime() - startedAt) / MCITEM.TickSeconds, 0)
end

function SWEP:IsMCUsingItem()
    return self:IsMCShieldRaised()
end

function SWEP:GetMCHoldTypeKey()
    return (self:IsMCShieldRaised() or self:IsMCThirdPersonUsing())
        and "shield_block"
        or "shield"
end

function SWEP:GetMCThirdPersonBaseState()
    return (self:IsMCShieldRaised() or self:IsMCThirdPersonUsing()) and "block" or "idle"
end

function SWEP:GetMCFirstPersonModel()
    return self.WorldModel
end

function SWEP:GetMCFirstPersonDisplay()
    return self:IsMCShieldRaised() and BLOCK_DISPLAY or IDLE_DISPLAY
end

function SWEP:GetMCUseRenderState()
    if not self:IsMCShieldRaised() then return nil end
    return "block", self:GetMCShieldUseTicks(), 72000
end

-- Read-only duck-typed combat contract consumed by MineMod. Inventory proxies
-- keep using the selected-stack state machine and real durability; a directly
-- spawned SWEP exposes the same raised timing as an infinite-durability test
-- shield without pretending that it belongs to mc_inventory.
function SWEP:GetMCShieldCombatState()
    if self:IsMCInventoryShield() or not self:IsMCShieldRaised() then return nil end
    return {
        item = "minecraft:shield",
        startedAt = self.MCShieldUseStartedAt or CurTime(),
        infiniteDurability = true,
    }
end

function SWEP:Deploy()
    local result = self.BaseClass.Deploy(self)
    self.MCShieldUsing = false
    self.MCShieldUseStartedAt = nil
    self.MCShieldInventoryUse = false
    if CLIENT then self:SetMCPredictedShieldUsing(false) end
    if SERVER then
        self:SetNW2Bool("MCITEM_ShieldUsing", false)
        self:SetNW2Float("MCITEM_ShieldUseStartedAt", 0)
        self:SetMCThirdPersonUseState(false)
        self:SetModel(self.WorldModel)
    end
    return result
end

function SWEP:BeginMCShieldUse()
    if self:IsMCShieldRaised() or self:IsMCShieldDisabled() then return false end

    if CLIENT then
        -- Switch to the blocking model immediately, without waiting for the
        -- server, while preserving ItemInHandRenderer.itemUsed's local
        -- dip-and-lift (handHeight rises by 0.4 per Minecraft tick).
        MCITEM.ItemUsed(self:GetMCItemState())
        self:SetMCPredictedShieldUsing(true)
        return true
    end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() then return false end
    local inventoryUse = self:IsMCInventoryShield()
    if inventoryUse then
        local inventory = inventoryApi()
        if not inventory or not isfunction(inventory.BeginSelectedUse) then return false end
        local ok = inventory.BeginSelectedUse(owner, useContext(self, "mcitem_shield_begin"))
        if not ok then
            self:SetMCShieldUsing(false)
            return false
        end
    end

    self:CancelMCMining("shield_begin")
    self.MCShieldInventoryUse = inventoryUse
    self:SetMCShieldUsing(true, CurTime())
    return true
end

function SWEP:ReleaseMCShieldUse(reason)
    if CLIENT then
        self:SetMCPredictedShieldUsing(false)
        return
    end
    if not self.MCShieldUsing then return end

    local owner = self:GetOwner()
    local inventory = self.MCShieldInventoryUse and inventoryApi() or nil
    if IsValid(owner) and inventory and isfunction(inventory.ReleaseSelectedUse) then
        local ok = inventory.ReleaseSelectedUse(owner, useContext(self, reason or "mcitem_shield_release"))
        if not ok and isfunction(inventory.CancelSelectedUse) then
            inventory.CancelSelectedUse(owner, reason or "mcitem_shield_release_failed")
        end
    end
    self.MCShieldInventoryUse = false
    self:SetMCShieldUsing(false)
end

function SWEP:CancelMCShieldUse(reason)
    if CLIENT then
        self:SetMCPredictedShieldUsing(false)
        return
    end

    local owner = self:GetOwner()
    local inventory = self.MCShieldInventoryUse and inventoryApi() or nil
    if self.MCShieldUsing and IsValid(owner)
        and inventory and isfunction(inventory.CancelSelectedUse) then
        inventory.CancelSelectedUse(owner, reason or "mcitem_shield_cancel")
    end
    self.MCShieldInventoryUse = false
    self:SetMCShieldUsing(false)
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() then return end
    if not self:BeginMCShieldUse() then self:MCTryOffhandUse() end
end

function SWEP:Think()
    self.BaseClass.Think(self)
    local owner = self:GetOwner()

    if SERVER then
        if not self.MCShieldUsing then return end
        if not IsValid(owner) or not owner:Alive() then
            self:CancelMCShieldUse("mcitem_shield_invalid_owner")
            return
        end
        if not owner:KeyDown(IN_ATTACK2) then
            self:ReleaseMCShieldUse("mcitem_shield_release")
            return
        end

        if not self.MCShieldInventoryUse then return end
        local inventory = inventoryApi()
        local ok = inventory and isfunction(inventory.TickSelectedUse)
            and inventory.TickSelectedUse(owner, useContext(self, "mcitem_shield_tick"))
        if ok ~= true then
            self.MCShieldInventoryUse = false
            self:SetMCShieldUsing(false)
        end
        return
    end

    if self.MCPredictedShieldUsing then
        if not IsValid(owner) or not owner:KeyDown(IN_ATTACK2) or self:IsMCShieldDisabled() then
            self:SetMCPredictedShieldUsing(false)
        elseif self:GetNW2Bool("MCITEM_ShieldUsing", false) then
            self:SetMCPredictedShieldUsing(false)
        elseif CurTime() - (self.MCPredictedShieldStartedAt or CurTime()) > PREDICTION_GRACE_SECONDS then
            self:SetMCPredictedShieldUsing(false)
        end
    end
end

function SWEP:Holster()
    self:CancelMCShieldUse("mcitem_shield_holster")
    if self.BaseClass.Holster then return self.BaseClass.Holster(self) end
    return true
end

function SWEP:OnRemove()
    self:CancelMCShieldUse("mcitem_shield_removed")
    if self.BaseClass.OnRemove then self.BaseClass.OnRemove(self) end
end
