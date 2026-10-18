AddCSLuaFile()
AddCSLuaFile("mcitem/utility/sh_use.lua")

include("mcitem/utility/sh_use.lua")

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "Minecraft Flint and Steel"
SWEP.Category = "Minecraft in GMod - Utility"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/flint_and_steel/flint_and_steel.mdl"
SWEP.MCItemID = "flint_and_steel"
SWEP.MCAnchorName = "item"
SWEP.MCThirdPersonProfile = "flint_and_steel"
SWEP.MCThirdPersonSwingGesture = "item_attack"
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil

SWEP.Instructions = "Left click: attack or mine. Right click: ignite a block face; soul sand and soul soil create soul fire."

local function playStandaloneSound(api, result)
    local soundApi = api and api.Sound
    local position = MCITEM.Utility.CellCenter(api, result)
    if not soundApi or not isfunction(soundApi.Play) or not position then return end
    soundApi.Play("item.flintandsteel.use", position, {
        volume = 1,
        pitch = 0.8 + math.Rand(0, 1) * 0.4,
        soundLevel = 72,
    })
end

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() then return end
    if not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() then return end
    self:CancelMCMining("flint_and_steel_use")

    local api = MC and MC.API
    local fire = api and api.Fire
    if not fire then return end

    local ok, resultOrError
    if MCITEM.Utility.IsInventoryProxy(self) and isfunction(fire.UseFlintAndSteel) then
        ok, resultOrError = fire.UseFlintAndSteel(owner, {
            expectedClass = self:GetClass(),
            reason = "mcitem_flint_and_steel_use",
        })
    elseif isfunction(fire.Ignite) then
        ok, resultOrError = fire.Ignite(owner, {
            reason = "mcitem_flint_and_steel_use",
        })
        if ok then playStandaloneSound(api, resultOrError) end
    end

    if ok then MCITEM.Utility.ConfirmSwing(self, "flint_and_steel_use")
    elseif resultOrError == "no_block_target" then self:MCTryOffhandUse() end
end
