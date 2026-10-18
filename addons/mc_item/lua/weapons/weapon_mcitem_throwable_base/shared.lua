AddCSLuaFile()
AddCSLuaFile("mcitem/throwables/sh_data.lua")
AddCSLuaFile("mcitem/throwables/sh_contract.lua")
AddCSLuaFile("mcitem/throwables/sh_collision.lua")
AddCSLuaFile("mcitem/throwables/sh_audio_data.lua")
AddCSLuaFile("mcitem/throwables/sh_audio.lua")

include("mcitem/throwables/sh_data.lua")
include("mcitem/throwables/sh_contract.lua")
include("mcitem/throwables/sh_collision.lua")
include("mcitem/throwables/sh_audio_data.lua")
include("mcitem/throwables/sh_audio.lua")
if SERVER then include("mcitem/throwables/sv_throw.lua") end

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Throwable Base"
SWEP.Category = "Minecraft in GMod - Throwables"
SWEP.Spawnable = false
SWEP.AdminOnly = false

SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCAttackKnockback = 0
SWEP.MCIsSword = false
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCSwingDurationTicks = 6
SWEP.MCToolType = nil
SWEP.MCMaterial = nil
SWEP.MCUseAction = nil
SWEP.MCThirdPersonProfile = "throwable"

function SWEP:GetMCThrowableDefinition()
    return MCITEM.Throwables.DefinitionForWeapon(self)
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    local definition = self:GetMCThrowableDefinition()
    local delayTicks = math.max(
        MCITEM.Throwables.RightClickDelayTicks,
        tonumber(definition and definition.cooldownTicks) or 0
    )
    self:SetNextSecondaryFire(now + delayTicks * MCITEM.Throwables.TickSeconds)
    if not IsFirstTimePredicted() then return end
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    if SERVER then
        self:CancelMCMining("throwable_use")
        if not IsValid(MCITEM.Throwables.Use(self)) then return end
    end

    -- 第一人称：`Item.use` 返回 SUCCESS 会 `player.swing(hand)`，也就是和挖方块
    -- 同一段 WHACK 动画。第三人称另外播丢手雷的手势（`mcitem_holdtype_throw`）。
    self:MCSwing(now)
    self:PlayMCGesture("throw")
end
