-- Java 26.2 special potion effects: wind charged, weaving, oozing and infested.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

local function spawnClass(className, position, beforeSpawn)
    local entity = ents.Create(className)
    if not IsValid(entity) then return nil end
    entity:SetPos(position)
    entity:SetAngles(Angle(0, math.Rand(0, 360), 0))
    if isfunction(beforeSpawn) then beforeSpawn(entity) end
    entity:Spawn()
    entity:Activate()
    return entity
end

local function weavingDeath(target)
    local api = MC and MC.API
    local coords = api and api.Coords
    local world = api and api.World
    if not coords or not world or not isfunction(coords.EngineToCell)
        or not isfunction(world.GetBlockState) or not isfunction(world.SetBlock)
    then
        hook.Run("MCITEM.WeavingCobwebsUnavailable", target)
        return
    end

    local bx, by, bz = coords.EngineToCell(target:GetPos(), target)
    if not bx then return end
    local maximum = math.random(2, 3)
    local selected = {}
    local order = {}
    for _ = 1, 15 do
        local x = bx + math.random(-1, 1)
        local y = by + math.random(-1, 1)
        local z = bz + math.random(-1, 1)
        local key = x .. ":" .. y .. ":" .. z
        if not selected[key] and world.GetBlockState(x, y, z) == 0
            and world.GetBlockState(x, y, z - 1) ~= 0
        then
            selected[key] = true
            order[#order + 1] = { x, y, z }
            if #order >= maximum then break end
        end
    end
    for _, cell in ipairs(order) do
        world.SetBlock(cell[1], cell[2], cell[3], "minecraft:cobweb", {
            actor = target,
            source = "mcitem_weaving",
        })
    end
end

local function oozingDeath(target)
    if Potions.HasEntityTag(target, Potions.EntityTags.IMMUNE_TO_OOZING, { delivery = "death" }) then return end
    local desired = 2
    local nearby = 0
    for _, entity in ipairs(ents.FindInSphere(target:GetPos(), 2 * MCITEM.BlockSize())) do
        if IsValid(entity) and entity:GetClass() == "bmb_slime" then nearby = nearby + 1 end
    end
    local maximum = GetConVar("mcitem_potion_max_entity_cramming")
    maximum = maximum and maximum:GetInt() or 24
    local count = maximum < 1 and desired or math.Clamp(maximum - nearby, 0, desired)
    for _ = 1, count do
        spawnClass("bmb_slime", target:GetPos() + Vector(0, 0, 0.5 * MCITEM.BlockSize()), function(slime)
            slime.SlimeSize = 2
            slime.BMBInitialSlimeSize = 2
        end)
    end
    hook.Run("MCITEM.OozingSpawned", target, count)
end

local function infestedHurt(target)
    if not Potions.HasEffect(target, "infested") then return end
    if Potions.HasEntityTag(target, Potions.EntityTags.IMMUNE_TO_INFESTED, { delivery = "hurt" }) then return end
    if math.Rand(0, 1) > 0.1 then return end

    local count = math.random(1, 2)
    local look = target:GetForward()
    if target:IsPlayer() then look = target:GetAimVector() end
    for _ = 1, count do
        local direction = Vector(look.x, look.y, look.z)
        direction:Rotate(Angle(0, math.Rand(-90, 90), 0))
        direction.x = direction.x * 0.3
        direction.y = direction.y * 0.3
        direction.z = direction.z * 0.45
        local silverfish = spawnClass("bmb_silverfish", target:WorldSpaceCenter())
        if IsValid(silverfish) then
            silverfish:SetVelocity(direction * MCITEM.BlockSize() / Potions.TickSeconds)
            Potions.PlayInfestedSilverfishHurt(silverfish)
        end
    end
    hook.Run("MCITEM.InfestedSpawned", target, count)
end

local function handleKilled(target)
    if not IsValid(target) or target.MCITEMPotionSpecialDeathHandled then return end
    target.MCITEMPotionSpecialDeathHandled = true
    if Potions.HasEffect(target, "wind_charged") then Potions.TriggerWindChargedDeath(target) end
    if Potions.HasEffect(target, "weaving") then weavingDeath(target) end
    if Potions.HasEffect(target, "oozing") then oozingDeath(target) end
    hook.Run("MCITEM.PotionEntityKilled", target)
    Potions.ClearEffects(target, "killed")
end

CreateConVar(
    "mcitem_potion_max_entity_cramming",
    "24",
    bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "Vanilla maxEntityCramming adapter used by the Oozing effect; 0 disables the cap.",
    0,
    256
)

hook.Remove("PostEntityTakeDamage", "MCITEM.Potions.SpecialOnHurt")
hook.Add("PostEntityTakeDamage", "MCITEM.Potions.SpecialOnHurt", function(target, _damageInfo, tookDamage)
    if not tookDamage or not IsValid(target) then return end
    infestedHurt(target)
    if (tonumber(target:Health()) or 1) <= 0 or target.BMBDead then handleKilled(target) end
end)

hook.Remove("OnNPCKilled", "MCITEM.Potions.SpecialNPCKilled")
hook.Add("OnNPCKilled", "MCITEM.Potions.SpecialNPCKilled", function(npc)
    handleKilled(npc)
end)

hook.Remove("PlayerDeath", "MCITEM.Potions.SpecialPlayerKilled")
hook.Add("PlayerDeath", "MCITEM.Potions.SpecialPlayerKilled", function(player)
    handleKilled(player)
end)

hook.Remove("PlayerSpawn", "MCITEM.Potions.ClearPlayerOnSpawn")
hook.Add("PlayerSpawn", "MCITEM.Potions.ClearPlayerOnSpawn", function(player)
    player.MCITEMPotionSpecialDeathHandled = nil
    Potions.ClearEffects(player, "respawn")
end)
