-- Minecraft Java 26.2 experience award, denomination, merge and pickup core.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

function Throwables.ExperienceValue(total)
    total = math.max(0, math.floor(tonumber(total) or 0))
    for _, value in ipairs(Throwables.ExperienceValues) do
        if total >= value then return value end
    end
    return 1
end

local function mergeSpawn(position, value)
    local half = Vector(0.5, 0.5, 0.5) * MCITEM.BlockSize()
    local randomGroup = math.random(0, 39)
    for _, orb in ipairs(ents.FindInBox(position - half, position + half)) do
        if IsValid(orb) and orb:GetClass() == "mcitem_experience_orb"
            and orb.MCPendingExperience == nil
            and orb:GetExperienceValue() == value
            and (orb:EntIndex() - randomGroup) % 40 == 0
        then
            orb:SetOrbCount(orb:GetOrbCount() + 1)
            orb.MCOrbAge = 0
            return orb
        end
    end
    return nil
end

function Throwables.SpawnExperienceOrb(position, direction, value, context)
    if not isvector(position) or value <= 0 then return nil end
    local merged = mergeSpawn(position, value)
    if IsValid(merged) then return merged end
    local orb = ents.Create("mcitem_experience_orb")
    if not IsValid(orb) then return nil end
    orb:SetPos(position)
    orb:Spawn()
    orb:Activate()
    orb:SetupExperience(value, direction, context)
    return orb
end

function Throwables.AwardExperience(position, direction, total, context)
    total = math.max(0, math.floor(tonumber(total) or 0))
    local spawned = {}
    while total > 0 do
        local value = Throwables.ExperienceValue(total)
        total = total - value
        local orb = Throwables.SpawnExperienceOrb(position, direction, value, context)
        if IsValid(orb) then spawned[#spawned + 1] = orb end
    end
    hook.Run("MCITEM.ExperienceAwarded", position, direction, spawned, context)
    return spawned
end

function Throwables.NearestExperiencePlayer(position, current)
    local range = Throwables.ExperienceOrbFollowRange * MCITEM.BlockSize()
    if IsValid(current) and current:IsPlayer() and current:Alive()
        and current:GetPos():DistToSqr(position) <= range * range
        and current:GetObserverMode() == OBS_MODE_NONE
    then
        return current
    end
    local best, bestDistance
    for _, playerEntity in ipairs(player.GetAll()) do
        if playerEntity:Alive() and playerEntity:GetObserverMode() == OBS_MODE_NONE then
            local distance = playerEntity:GetPos():DistToSqr(position)
            if distance <= range * range and (not bestDistance or distance < bestDistance) then
                best, bestDistance = playerEntity, distance
            end
        end
    end
    return best
end

local function experienceLevel(playerEntity)
    if IsValid(playerEntity) and isfunction(playerEntity.GetMCExperienceLevel) then
        local level = playerEntity:GetMCExperienceLevel()
        if isnumber(level) then return math.floor(level) end
    end
    return nil
end

function Throwables.CollectExperienceOrb(orb, playerEntity)
    if not IsValid(orb) or not IsValid(playerEntity) or not playerEntity:IsPlayer()
        or not playerEntity:Alive()
    then
        return false
    end
    local now = CurTime()
    if now < (playerEntity.MCITEMNextExperiencePickup or 0) then return false end
    local context = {
        orb = orb,
        value = orb:GetExperienceValue(),
        count = orb:GetOrbCount(),
    }
    local allowed = hook.Run("MCITEM.CanPickupExperienceOrb", playerEntity, orb, context)
    if allowed == false then return false end
    playerEntity.MCITEMNextExperiencePickup = now
        + Throwables.ExperiencePickupDelayTicks * Throwables.TickSeconds

    local oldLevel = experienceLevel(playerEntity)
    local remaining = orb.MCPendingExperience
    if remaining == nil then
        remaining = Throwables.RepairWithExperience(playerEntity, context.value, context)
        -- Repair may already have committed. Never repair the same orb unit a
        -- second time if the subsequent XP provider refuses the remainder.
        orb.MCPendingExperience = remaining
    end
    local granted = true
    if remaining > 0 then granted = Throwables.GiveExperience(playerEntity, remaining, context) end
    if not granted then return false end
    orb.MCPendingExperience = nil
    local newLevel = experienceLevel(playerEntity)
    if oldLevel ~= nil and newLevel ~= nil and oldLevel ~= newLevel then
        Throwables.NotifyExperienceLevelChanged(playerEntity, oldLevel, newLevel, context)
    end
    Throwables.PlayExperiencePickup(orb:GetPos())
    hook.Run("MCITEM.ExperienceOrbPickedUp", playerEntity, orb, context.value, remaining, granted, context)
    return true
end
