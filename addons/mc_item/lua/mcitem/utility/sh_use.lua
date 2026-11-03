-- Shared confirmation bridge for short, server-authoritative utility uses.
-- Flint-and-steel and shears only swing after the server confirms SUCCESS;
-- name tags intentionally do not call this bridge because the user requested
-- no right-click animation for them.

MCITEM = MCITEM or {}
MCITEM.Utility = MCITEM.Utility or {}

local Utility = MCITEM.Utility
local NET_CONFIRMED_SWING = "MCITEM_UtilityConfirmedSwing"

if SERVER then
    util.AddNetworkString(NET_CONFIRMED_SWING)

    function Utility.ConfirmSwing(weapon, gesture)
        if not IsValid(weapon) or not weapon.MCSwing then return false end
        local owner = weapon:GetOwner()
        if not IsValid(owner) or not owner:IsPlayer() then return false end

        local now = CurTime()
        weapon:MCSwing(now)
        if weapon.PlayMCThirdPersonSwing then
            weapon:PlayMCThirdPersonSwing(now, owner, gesture)
        elseif gesture and weapon.PlayMCGesture then
            weapon:PlayMCGesture(gesture)
        end

        net.Start(NET_CONFIRMED_SWING)
            net.WriteEntity(weapon)
        net.Send(owner)
        return true
    end
else
    net.Receive(NET_CONFIRMED_SWING, function()
        local weapon = net.ReadEntity()
        local owner = LocalPlayer()
        if not IsValid(weapon) or not IsValid(owner) or weapon:GetOwner() ~= owner then return end
        if owner:GetActiveWeapon() ~= weapon or not weapon.MCSwing then return end
        weapon:MCSwing(CurTime())
    end)
end

-- MineMod resolves "use item on block" itself when the aimed block has an OnUse
-- handler that accepts the held item (flint and steel on TNT). That path runs
-- entirely server-side inside MC.SV.Use, so this weapon's own SecondaryAttack --
-- and therefore its ConfirmSwing -- never runs, and lighting TNT looked frozen
-- while lighting the ground swung normally.
--
-- MC.PlayerUsedBlock fires only after a successful interaction, which is
-- exactly Minecraft's "useOn returned SUCCESS -> swing the arm". Restricted to
-- weapons that apply themselves to the block, so operating a chest or a door
-- while holding one still does not swing.
if SERVER then
    local SWING_ON_BLOCK_USE = {
        weapon_mcitem_flint_and_steel = true,
    }

    hook.Add("MC.PlayerUsedBlock", "MCITEM_UtilityBlockUseSwing", function(ply)
        if not IsValid(ply) or not ply:IsPlayer() then return end
        local weapon = ply:GetActiveWeapon()
        if not IsValid(weapon) or not SWING_ON_BLOCK_USE[weapon:GetClass()] then return end
        Utility.ConfirmSwing(weapon, "flint_and_steel_use")
    end)
end

function Utility.IsInventoryProxy(weapon)
    return IsValid(weapon) and weapon.GetNW2Bool
        and weapon:GetNW2Bool("MCITEM_InventoryProxy", false) == true
end

function Utility.CellCenter(api, result)
    local coords = api and api.Coords
    if not result or not coords or not isfunction(coords.CellCenter) then return nil end
    return coords.CellCenter(result.bx, result.by, result.bz)
end

return Utility
