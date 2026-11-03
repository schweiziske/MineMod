-- Java 26.2 Totem of Undying result application. MineMod owns the lethal damage
-- boundary and atomic hand consumption; MCITEM owns potion/status semantics and
-- the client effect packet.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Totem = MCITEM.Totem or {}

local Totem = MCITEM.Totem
local NET_TRIGGER = "MCITEM_TotemTriggered"

util.AddNetworkString(NET_TRIGGER)

local function applyEffect(target, id, durationTicks, amplifier)
    local potions = MCITEM.Potions
    return potions and isfunction(potions.ApplyEffect) and potions.ApplyEffect(target, {
        id = id,
        durationTicks = durationTicks,
        amplifier = amplifier,
        ambient = false,
        visible = true,
        showIcon = true,
    }, target, { delivery = "totem_of_undying" }) == true
end

function Totem.ApplyDeathProtection(target, hand, stack)
    if not IsValid(target) or not target:IsPlayer() then return false, "invalid_target" end
    local potions = MCITEM.Potions
    if not potions or not isfunction(potions.ClearEffects) or not isfunction(potions.ApplyEffect) then
        return false, "potion_runtime_unavailable"
    end

    target:SetHealth(1)
    potions.ClearEffects(target, "totem_of_undying")
    applyEffect(target, "regeneration", 900, 1)
    applyEffect(target, "absorption", 100, 1)
    applyEffect(target, "fire_resistance", 800, 0)

    net.Start(NET_TRIGGER)
        net.WriteEntity(target)
        net.WriteString(tostring(hand or "mainhand"))
    net.Broadcast()
    hook.Run("MCITEM.TotemTriggered", target, hand, stack)
    return true
end

hook.Remove("MC.DeathProtectionTriggered", "MCITEM.Totem.Apply")
hook.Add("MC.DeathProtectionTriggered", "MCITEM.Totem.Apply", function(target, hand, stack)
    Totem.ApplyDeathProtection(target, hand, stack)
end)
