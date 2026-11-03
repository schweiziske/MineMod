-- Shared MCITEM <-> MineMod mining contract. This file contains no world writes;
-- the server adapter owns all authoritative calls.

MCITEM = MCITEM or {}
MCITEM.Mining = MCITEM.Mining or {}

local Mining = MCITEM.Mining

function Mining.Api()
    local api = MC and MC.API or nil
    if not api or not istable(api.Mining) then return nil end
    return api
end

function Mining.ItemIdentifier(weapon)
    if not IsValid(weapon) then return nil end
    local item = weapon.MCMiningItemID or weapon.MCItemID
    if not isstring(item) or item == "" then return nil end
    if string.find(item, ":", 1, true) then return item end
    return "minecraft:" .. item
end

function Mining.PlayerIsCreative(player)
    if not IsValid(player) or not player:IsPlayer() then return false end
    if MC and isfunction(MC.PlayerIsCreative) then return MC.PlayerIsCreative(player) == true end
    local mode = string.lower(string.Trim(player:GetNWString("mc_gamemode", "survival")))
    return mode == "creative" or mode == "1"
end

-- Tool#canDestroyBlocksInCreative. Keep this shared so standalone MCITEM
-- weapons, inventory proxy instances and MineMod's selected-stack hand predict
-- the same result before the authoritative creative-break request is sent.
function Mining.CanDestroyBlocksInCreative(weapon)
    if not IsValid(weapon) then return true end
    if isbool(weapon.MCCanDestroyBlocksInCreative) then
        return weapon.MCCanDestroyBlocksInCreative
    end

    local item = Mining.ItemIdentifier(weapon)
    if MC and isfunction(MC.ItemCanDestroyBlocksInCreative) and item then
        return MC.ItemCanDestroyBlocksInCreative({ item = item }) == true
    end

    local path = isstring(item) and string.match(item, "^[^:]+:(.+)$") or item
    if weapon.MCIsSword == true or weapon.MCToolType == "sword" then return false end
    return path ~= "mace" and path ~= "trident"
end

function Mining.CellFromHit(hit)
    if not istable(hit) then return nil end
    local bx = tonumber(hit.bx)
    local by = tonumber(hit.by)
    local bz = tonumber(hit.bz)
    if not bx or not by or not bz then return nil end
    return math.floor(bx), math.floor(by), math.floor(bz)
end

function Mining.IsVoxelHit(hit)
    return Mining.CellFromHit(hit) ~= nil
end
