AddCSLuaFile()
AddCSLuaFile("mcitem/buckets/sh_data.lua")
AddCSLuaFile("mcitem/buckets/sh_audio.lua")

include("mcitem/buckets/sh_data.lua")
include("mcitem/buckets/sh_audio.lua")
if SERVER then include("mcitem/buckets/sv_use.lua") end

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Bucket Base"
SWEP.Category = "Minecraft in GMod - Items"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCSwingDurationTicks = 6
SWEP.MCHoldTypeName = "item"
SWEP.MCAnchorName = "bucket"
-- Bucket use is a click action.  The server also keeps a player-scoped latch so
-- a selected-stack class swap cannot turn one held click into pickup + place.
SWEP.Secondary = {
    ClipSize = -1,
    DefaultClip = -1,
    Automatic = false,
    Ammo = "none",
}

function SWEP:GetMCBucketDefinition()
    return MCITEM.Buckets.DefinitionForWeapon(self)
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    local nextUseAt = now + MCITEM.Buckets.RightClickDelayTicks * MCITEM.TickSeconds
    self:SetNextSecondaryFire(nextUseAt)
    if not IsFirstTimePredicted() then return end
    if SERVER then
        local allowed, _, playerNextUseAt = MCITEM.Buckets.TryBeginPlayerUse(self:GetOwner())
        if playerNextUseAt then self:SetNextSecondaryFire(playerNextUseAt) end
        if not allowed then return end
        self:CancelMCMining("bucket_use")
        local definition = self:GetMCBucketDefinition()
        if definition and definition.pickup then
            local target = MCITEM.Buckets.FindMilkTarget(self:GetOwner())
            if IsValid(target) then
                local milked, milkError = MCITEM.Buckets.TryMilkEntity(
                    self:GetOwner(), target, { weapon = self, source = "bucket_secondary" })
                if milked then self:PlayMCGesture("bucket_use") return end
                if milkError ~= "unhandled" and milkError ~= "rejected" then return end
            end
        end
        local success = MCITEM.Buckets.UseLiquidBucket(self, definition)
        if success then self:PlayMCGesture("bucket_use")
        else self:MCTryOffhandUse() end
    end
end
