-- Server adapter for MC.API.Mining. MineMod owns progress, crack stages, reach,
-- vanilla tool rules, loot and block transactions; MCITEM only identifies the
-- active SWEP and exposes durability/completion callbacks.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Mining = MCITEM.Mining or {}

local Mining = MCITEM.Mining

local function callWeapon(weapon, method, ...)
    if not IsValid(weapon) or not isfunction(weapon[method]) then return end
    return weapon[method](weapon, ...)
end

function Mining.Start(weapon, hit, context)
    if not IsValid(weapon) then return false, "invalid_weapon" end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return false, "invalid_owner" end
    local bx, by, bz = Mining.CellFromHit(hit)
    if not bx then return false, "not_voxel_block" end

    local api = Mining.Api()
    if not api or not isfunction(api.Mining.Start) then return false, "mcswep_mining_api_unavailable" end

    if isfunction(api.Mining.IsCreative) and api.Mining.IsCreative(owner) then
		if not Mining.CanDestroyBlocksInCreative(weapon) then
			if isfunction(api.Mining.Cancel) then api.Mining.Cancel(owner, "creative_item_cannot_destroy") end
			return false, "creative_item_cannot_destroy"
		end
        local broke, result = api.Mining.BreakCreative(owner, bx, by, bz, {
            initialPress = istable(context) and context.initialPress == true,
			item = Mining.ItemIdentifier(weapon),
        })
        if broke then
            callWeapon(weapon, "OnMCCreativeBlockMined", bx, by, bz, result)
            hook.Run("MCITEM.SWEPCreativeBlockMined", weapon, owner, bx, by, bz, result)
        end
        return broke, result
    end

    local item = Mining.ItemIdentifier(weapon)
    return api.Mining.Start(owner, bx, by, bz, {
        item = item,
        weapon = weapon,
        sourceId = "mcitem_swep",
        sourceToken = weapon:GetClass() .. ":" .. weapon:EntIndex(),
        validate = function(ply, session)
            if not IsValid(weapon) or weapon:GetOwner() ~= ply then return false, "weapon_changed" end
            if isfunction(weapon.IsMCUsingItem) and weapon:IsMCUsingItem() then return false, "using_item" end
            return true
        end,
        onDurabilityDamage = function(ply, amount, context)
            callWeapon(weapon, "ApplyMCMineDurabilityDamage", amount, context)
        end,
        onComplete = function(ply, session, completion)
            callWeapon(weapon, "OnMCBlockMined", session, completion)
            hook.Run("MCITEM.SWEPBlockMined", weapon, ply, session, completion)
        end,
        onCancel = function(ply, session, reason)
            callWeapon(weapon, "OnMCMiningCancelled", session, reason)
            hook.Run("MCITEM.SWEPMiningCancelled", weapon, ply, session, reason)
        end,
    })
end

function Mining.Cancel(weapon, reason)
    if not IsValid(weapon) then return false, "invalid_weapon" end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return false, "invalid_owner" end
    local api = Mining.Api()
    if not api or not isfunction(api.Mining.Cancel) then return false, "mcswep_mining_api_unavailable" end

    if isfunction(api.Mining.Get) then
        local session = api.Mining.Get(owner)
        if not session or session.sourceId ~= "mcitem_swep" or session.weapon ~= weapon then return false, "not_owner" end
    end
    return api.Mining.Cancel(owner, reason or "mcitem_cancel")
end
