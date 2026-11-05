AddCSLuaFile()

SWEP.Base = "weapon_bmb_item_model_test"
SWEP.PrintName = "#item.minecraft.name_tag"
SWEP.Category = "#mcitem.category.utility"
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.WorldModel = "models/mcgm/name_tag/name_tag.mdl"
SWEP.MCItemID = "name_tag"
SWEP.MCAnchorName = "item"
SWEP.MCThirdPersonProfile = "name_tag"
SWEP.MCThirdPersonSwingGesture = "item_attack"
SWEP.MCAttackDamage = 1
SWEP.MCAttackSpeed = 4
SWEP.MCWeaponDamagePerAttack = 0
SWEP.MCIsSword = false
SWEP.MCUseAction = nil

SWEP.MCInstructionsKey = "mcitem.instructions.name_tag"

function SWEP:SecondaryAttack()
    if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(self) then return end
    local now = CurTime()
    self:SetNextSecondaryFire(now + self.MCRightClickDelayTicks * MCITEM.TickSeconds)
    if not IsFirstTimePredicted() or not SERVER then return end

    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() then return end
    self:CancelMCMining("name_tag_use")
    local nameTags = MCITEM.NameTags
    local handled = nameTags and isfunction(nameTags.Use) and nameTags.Use(owner, self)
    if not handled then self:MCTryOffhandUse() end
    -- NameTagItem returns SUCCESS without swingHand; the user explicitly wants
    -- no right-click animation, so this path never calls Utility.ConfirmSwing.
end
