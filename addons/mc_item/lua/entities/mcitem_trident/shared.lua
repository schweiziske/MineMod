AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "mcitem_arrow"
ENT.PrintName = "#mcitem.entity.trident"
ENT.Spawnable = false
ENT.RenderGroup = RENDERGROUP_OPAQUE

-- trident_3d 的长轴不在 +X（`velocity:Angle()` 对齐的是 +X），所以要按模型自己的轴补一次
-- 旋转，对应 ThrownTridentRenderer 里那句 `Axis.ZP.rotationDegrees(xRot + 90)`。
-- 补偿顺序是 yaw(Up) → pitch(Right) → roll(Forward)，实机对着调出来的是 (0, 90, 90)。
-- convar：mcitem_trident_model_pitch / _yaw / _roll。
ENT.MCModelAngleOffset = Angle(0, 90, 90)
ENT.MCAngleConVarName = "trident"

-- ThrownTrident.getPickupItem() 返回它带着飞的那一份 ItemStack。
ENT.MCPickupItemID = "minecraft:trident"
ENT.MCPickupWeaponClass = "weapon_mcitem_trident"

function ENT:SetMCPickupStack(stack, infinite)
    self.MCPickupStack = istable(stack) and table.Copy(stack) or nil
    -- The authoritative consume-and-return transaction yields the exact stack
    -- that is now flying.  Prefer that copy over the pre-transaction snapshot,
    -- but do not erase the snapshot in standalone mode where no inventory
    -- stack is returned.
    if istable(self.MCPickupStack) then
        self.MCEnchantmentStack = table.Copy(self.MCPickupStack)
    end
    self.MCThrownInfinite = infinite == true
    self.MCPickup = self.MCThrownInfinite and MCITEM.Pickup.CREATIVE_ONLY or MCITEM.Pickup.ALLOWED
end
