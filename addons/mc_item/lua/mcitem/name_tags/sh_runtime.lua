-- Shared Minecraft name-tag entity contract.  The actual inventory mutation is
-- server-only; these scalar helpers are shared so the client renderer and the
-- server use the same target/name semantics.

MCITEM = MCITEM or {}
MCITEM.NameTags = MCITEM.NameTags or {}

local NameTags = MCITEM.NameTags

NameTags.GenericNameKey = "MCITEM_CustomName"
NameTags.GenericPersistenceKey = "MCITEM_NameTagPersistent"
NameTags.BMBNameKey = "BMBCustomName"

function NameTags.IsSupportedTarget(target)
    if not IsValid(target) or target:IsPlayer() then return false end
    if target.IsBMBMob == true then return true end
    if target.IsNPC and target:IsNPC() then return true end
    return target.IsNextBot and target:IsNextBot() == true or false
end

function NameTags.IsAliveTarget(target)
    if not NameTags.IsSupportedTarget(target) then return false end
    if target.BMBDead == true or (target.GetNW2Bool and target:GetNW2Bool("BMBDead", false)) then
        return false
    end
    if target.Health and tonumber(target:Health()) and target:Health() <= 0 then return false end
    return true
end

local function segmentAxisFraction(origin, delta, low, high, entry, exit)
    if math.abs(delta) <= 1e-9 then
        if origin < low or origin > high then return nil end
        return entry, exit
    end
    local first, second = (low - origin) / delta, (high - origin) / delta
    if first > second then first, second = second, first end
    entry, exit = math.max(entry, first), math.min(exit, second)
    if entry > exit then return nil end
    return entry, exit
end

local function segmentAABBFraction(startPosition, endPosition, minimum, maximum)
    local entry, exit = 0, 1
    entry, exit = segmentAxisFraction(startPosition.x, endPosition.x - startPosition.x,
        minimum.x, maximum.x, entry, exit)
    if entry == nil then return nil end
    entry, exit = segmentAxisFraction(startPosition.y, endPosition.y - startPosition.y,
        minimum.y, maximum.y, entry, exit)
    if entry == nil then return nil end
    entry, exit = segmentAxisFraction(startPosition.z, endPosition.z - startPosition.z,
        minimum.z, maximum.z, entry, exit)
    if entry == nil then return nil end
    if exit < 0 or entry > 1 then return nil end
    return math.Clamp(entry, 0, 1)
end

local function segmentCollisionFraction(target, startPosition, endPosition)
    -- OBBMins/OBBMaxs are the entity's local collision bounds.  Transforming
    -- the ray into that space avoids the false positives produced by the
    -- larger WorldSpaceAABB when a mob is yawed.
    if isfunction(target.WorldToLocal) and isfunction(target.OBBMins) and isfunction(target.OBBMaxs) then
        local localStart = target:WorldToLocal(startPosition)
        local localEnd = target:WorldToLocal(endPosition)
        local minimum, maximum = target:OBBMins(), target:OBBMaxs()
        if isvector(localStart) and isvector(localEnd) and isvector(minimum) and isvector(maximum) then
            return segmentAABBFraction(localStart, localEnd, minimum, maximum)
        end
    end

    local minimum, maximum = target:WorldSpaceAABB()
    if not isvector(minimum) or not isvector(maximum) then return nil end
    return segmentAABBFraction(startPosition, endPosition, minimum, maximum)
end

-- Scratch state reused by FindAimTarget.  The function is not re-entrant and
-- never hands these tables to callers.
local aimCandidates, aimSeen, aimCandidateCount = {}, {}, 0
local aimDirectFilter, aimObstructionFilter = {}, {}
local aimTraceInput, aimTraceOutput = {}, {}

local function addAimCandidate(entity)
    if aimSeen[entity] or not NameTags.IsAliveTarget(entity) then return end
    aimSeen[entity] = true
    aimCandidateCount = aimCandidateCount + 1
    aimCandidates[aimCandidateCount] = entity
end

local function clearAimCandidates()
    for index = 1, aimCandidateCount do
        aimSeen[aimCandidates[index]] = nil
        aimCandidates[index] = nil
    end
    aimCandidateCount = 0
end

local function runAimTrace(startPosition, endPosition, filter)
    aimTraceInput.start = startPosition
    aimTraceInput.endpos = endPosition
    aimTraceInput.filter = filter
    aimTraceInput.mask = MASK_SHOT or MASK_SOLID
    aimTraceInput.output = aimTraceOutput
    util.TraceLine(aimTraceInput)
    return aimTraceOutput
end

function NameTags.FindAimTarget(owner, weapon, reach, includeEntitySearch)
    if not IsValid(owner) then return nil, "invalid_owner" end
    reach = math.max(tonumber(reach) or 0, 0)
    if reach <= 0 then return nil, "invalid_reach" end

    local startPosition = owner:EyePos()
    local endPosition = startPosition + owner:GetAimVector() * reach
    clearAimCandidates()

    aimDirectFilter[1], aimDirectFilter[2] = owner, weapon
    local directTrace = runAimTrace(startPosition, endPosition, aimDirectFilter)
    addAimCandidate(directTrace.Entity)

    if includeEntitySearch ~= false and ents and ents.FindAlongRay then
        for _, entity in ipairs(ents.FindAlongRay(startPosition, endPosition)) do addAimCandidate(entity) end
    end
    if BMB and isfunction(BMB.ForEachMob) then BMB.ForEachMob(addAimCandidate) end

    local target, hitPosition, bestFraction
    for index = 1, aimCandidateCount do
        local candidate = aimCandidates[index]
        local fraction = segmentCollisionFraction(candidate, startPosition, endPosition)
        if fraction and (bestFraction == nil or fraction < bestFraction) then
            target = candidate
            bestFraction = fraction
        end
    end
    clearAimCandidates()
    if bestFraction then
        hitPosition = startPosition + (endPosition - startPosition) * bestFraction
    end
    if not IsValid(target) or not isvector(hitPosition) then return nil, "invalid_target" end

    aimObstructionFilter[1], aimObstructionFilter[2], aimObstructionFilter[3] = owner, weapon, target
    local obstruction = runAimTrace(startPosition, hitPosition, aimObstructionFilter)
    aimObstructionFilter[1], aimObstructionFilter[2], aimObstructionFilter[3] = nil, nil, nil
    aimDirectFilter[1], aimDirectFilter[2] = nil, nil
    if obstruction.StartSolid == true
        or obstruction.Hit == true and (tonumber(obstruction.Fraction) or 0) < 0.999 then
        return nil, "target_occluded"
    end
    return target, nil, hitPosition
end

function NameTags.GetEntityCustomName(target)
    if not IsValid(target) then return nil, false end
    if target.GetBMBCustomName then
        local value = target:GetBMBCustomName()
        if isstring(value) and value ~= "" then return value, true end
    end
    if not target.GetNW2String then return nil, false end
    local value = target:GetNW2String(NameTags.GenericNameKey, "")
    if value == "" then return nil, false end
    return value, true
end

function NameTags.SetEntityCustomName(target, value)
    if not SERVER or not NameTags.IsAliveTarget(target) then return false end
    value = tostring(value or "")
    if value == "" then return false end
    if target.SetBMBCustomName then return target:SetBMBCustomName(value) == true end
    if not target.SetNW2String or not target.SetNW2Bool then return false end
    target:SetNW2String(NameTags.GenericNameKey, value)
    target:SetNW2Bool(NameTags.GenericPersistenceKey, true)
    return true
end

function NameTags.IsUpsideDownName(value)
    return value == "Dinnerbone" or value == "Grumm"
end

return NameTags
