-- The inventory VGUI owns both mouse buttons while it is open.  Most SWEPs
-- naturally stop receiving those buttons through the popup, but MCITEM also
-- polls held input for Minecraft-style continuous actions.  Filter the usercmd
-- before any MCITEM attack/use path (including derived SWEP overrides) sees it.

MCITEM = MCITEM or {}
MCITEM.InventorySWEPInputGuard = MCITEM.InventorySWEPInputGuard or {}

local Guard = MCITEM.InventorySWEPInputGuard
local INVENTORY_UI_CAPABILITY = "mc.game.inventory_ui"

function Guard.IsInventoryOpen()
    if not CLIENT then return false end

    local api = MC and MC.API or nil
    if not api or not isfunction(api.GetCapability) then return false end

    -- This public capability uses the same semantic as mc_item_hand's UI gate:
    -- the inventory screen panel exists.  Do not reach into MC.InventoryUI.
    local inventoryUI = api.GetCapability(INVENTORY_UI_CAPABILITY, 1)
    if not inventoryUI or not isfunction(inventoryUI.IsOpen) then return false end

    local ok, open = pcall(inventoryUI.IsOpen)
    return ok and open == true
end

function Guard.BlocksWeapon(weapon, owner)
    if not CLIENT or not IsValid(weapon)
        or weapon.MCITEMInventoryInputGuard ~= true
    then
        return false
    end

    owner = owner or (weapon.GetOwner and weapon:GetOwner() or nil)
    if not IsValid(owner) or owner ~= LocalPlayer() then return false end

    return Guard.IsInventoryOpen()
end

function Guard.FilterCommand(playerEntity, command)
    if not CLIENT or playerEntity ~= LocalPlayer()
        or not command or not command.RemoveKey
    then
        return
    end

    local weapon = IsValid(playerEntity) and playerEntity.GetActiveWeapon
        and playerEntity:GetActiveWeapon() or nil
    if not Guard.BlocksWeapon(weapon, playerEntity) then return end

    command:RemoveKey(IN_ATTACK)
    command:RemoveKey(IN_ATTACK2)
end

function Guard.FilterLocalCommand(command)
    Guard.FilterCommand(LocalPlayer(), command)
end

if CLIENT then
    -- CreateMove covers the local/single-player command path; StartCommand is
    -- the shared-command safety net. Removing the same bits twice is harmless.
    hook.Add("CreateMove", "MCITEM.InventorySWEPInputGuard", Guard.FilterLocalCommand)
    hook.Add("StartCommand", "MCITEM.InventorySWEPInputGuard", Guard.FilterCommand)
end
