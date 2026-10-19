-- LivingEntity.updateSynchronizedMobEffectParticles at 20 Hz.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions
local STATUS_KEY = "MCITEMPotionEffects"
local STATUS_REVISION_KEY = STATUS_KEY .. "Revision"
local STATUS_CHUNK_KEY_PREFIX = STATUS_KEY .. "Chunk"
local STATUS_MAX_CHUNKS = 64

Potions.ClientEffectCache = Potions.ClientEffectCache or setmetatable({}, { __mode = "k" })
Potions.StatusEntities = Potions.StatusEntities or setmetatable({}, { __mode = "k" })
local statusEntities = Potions.StatusEntities
-- Reconcile once at load (including Lua refresh); creation/removal keeps the
-- registry current without allocating ents.GetAll() every status tick.
for _, entity in ipairs(ents.GetAll()) do statusEntities[entity] = true end
hook.Add("OnEntityCreated", "MCITEM.Potions.TrackStatusEntity", function(entity)
    statusEntities[entity] = true
end)
hook.Add("EntityRemoved", "MCITEM.Potions.TrackStatusEntity", function(entity)
    statusEntities[entity] = nil
    Potions.ClientEffectCache[entity] = nil
end)
-- 每 tick 刷新一次的"当前带效果的实体"列表，由下面的状态粒子 tick 产出，
-- 供 cl_visuals.lua 的发光/隐身复用，避免它们各自每帧全量扫实体。
Potions.AffectedEntities = Potions.AffectedEntities or {}
Potions.StatusSnapshotProtocol = Potions.StatusSnapshotProtocol or {
    key = STATUS_KEY,
    revisionKey = STATUS_REVISION_KEY,
    chunkKeyPrefix = STATUS_CHUNK_KEY_PREFIX,
    maxChunks = STATUS_MAX_CHUNKS,
}

local function statusChunkKey(index)
    return STATUS_CHUNK_KEY_PREFIX .. tostring(index)
end

local function decodeSnapshot(raw)
    if raw == "" then return {} end
    local decoded = util.JSONToTable(raw)
    return istable(decoded) and decoded or nil
end

local function chunkedSnapshot(entity)
    local revision = math.max(0, entity:GetNW2Int(STATUS_REVISION_KEY, 0))
    if revision <= 0 then return nil, revision, false end

    local first = entity:GetNW2String(statusChunkKey(1), "")
    if first == "" then return nil, revision, true end
    local newline = string.find(first, "\n", 1, true)
    if not newline then return nil, revision, true end
    local header = string.sub(first, 1, newline - 1)
    local firstSeparator = string.find(header, ":", 1, true)
    local secondSeparator = firstSeparator
        and string.find(header, ":", firstSeparator + 1, true) or nil
    if not firstSeparator or not secondSeparator then return nil, revision, true end
    local payloadRevision = tonumber(string.sub(header, 1, firstSeparator - 1))
    local count = math.Clamp(
        math.floor(tonumber(string.sub(header, firstSeparator + 1, secondSeparator - 1)) or 0),
        0,
        STATUS_MAX_CHUNKS
    )
    local expectedCRC = string.sub(header, secondSeparator + 1)
    if payloadRevision ~= revision or count <= 0 or expectedCRC == "" then
        return nil, revision, true
    end

    local pieces = { first }
    for index = 2, count do
        local piece = entity:GetNW2String(statusChunkKey(index), "")
        if piece == "" then return nil, revision, true end
        pieces[index] = piece
    end

    local payload = table.concat(pieces)
    local newline = string.find(payload, "\n", 1, true)
    if not newline then return nil, revision, true end
    local raw = string.sub(payload, newline + 1)
    if payloadRevision ~= revision or expectedCRC == "" or util.CRC(raw) ~= expectedCRC then
        return nil, revision, true
    end
    return raw, revision, true
end

function Potions.ClientEffects(entity)
    if not IsValid(entity) then return {} end
    local cached = Potions.ClientEffectCache[entity]
    local currentRevision = entity:GetNW2Int(STATUS_REVISION_KEY, 0)
    if cached and currentRevision > 0 and cached.revision == currentRevision then
        return cached.effects
    end
    local raw, revision, chunked = chunkedSnapshot(entity)
    if chunked then
        if not raw then return cached and cached.effects or {} end
        if cached and cached.revision == revision and cached.raw == raw then return cached.effects end
        local decoded = decodeSnapshot(raw)
        if not decoded then return cached and cached.effects or {} end
        Potions.ClientEffectCache[entity] = {
            revision = revision,
            raw = raw,
            effects = decoded,
        }
        return decoded
    end

    -- Compatibility with servers that still publish one short NW2 string.
    raw = entity:GetNW2String(STATUS_KEY, "")
    if cached and cached.revision == 0 and cached.raw == raw then return cached.effects end
    local decoded = decodeSnapshot(raw)
    if not decoded then return cached and cached.effects or {} end
    Potions.ClientEffectCache[entity] = { revision = 0, raw = raw, effects = decoded }
    return decoded
end

local function randomPoint(entity)
    local minimum, maximum = entity:WorldSpaceAABB()
    return Vector(
        math.Rand(minimum.x, maximum.x),
        math.Rand(minimum.y, maximum.y),
        math.Rand(minimum.z, maximum.z)
    )
end

local function spawnForEffect(entity, effect)
    local definition = Potions.EffectDefinition(effect.id)
    if not definition then return end
    local position = randomPoint(entity)
    if effect.id == "wind_charged" then
        Potions.SpawnSmallGust(position)
    elseif effect.id == "weaving" then
        Potions.SpawnItemFragment(position, "__cobweb", vector_origin)
    elseif effect.id == "oozing" then
        Potions.SpawnItemFragment(position, "__slime", vector_origin)
    elseif effect.id == "infested" then
        Potions.SpawnInfestedParticle(position)
    else
        local r, g, b = Potions.ColorRGB(definition.color)
        Potions.SpawnSpellParticle(position, {
            family = "effect",
            inputX = 1,
            inputY = 1,
            inputZ = 1,
            r = r,
            g = g,
            b = b,
            alpha = effect.ambient == true and 38 / 255 or 1,
        })
    end
end

local nextTick = CurTime() + Potions.TickSeconds
hook.Remove("Think", "MCITEM.Potions.EntityStatusParticles")
hook.Add("Think", "MCITEM.Potions.EntityStatusParticles", function()
    local now = CurTime()
    if now < nextTick then return end
    nextTick = now + Potions.TickSeconds

    -- 这一轮顺便产出"当前带效果的实体"列表。发光光环和隐身以前各自**每帧**扫一遍
    -- ents.GetAll() 并对每个实体解码一次效果快照，纯属重复劳动；它们改成读这份
    -- 20Hz 的结果。
    local affected = Potions.AffectedEntities
    for index = #affected, 1, -1 do affected[index] = nil end

    for entity in pairs(statusEntities) do
        local effects = Potions.ClientEffects(entity)
        -- 没有效果的实体直接跳过：之前每个实体每 tick 都要分配一张 visibleEffects
        -- 空表，世界里绝大多数实体都走这条路。
        if #effects > 0 then
            affected[#affected + 1] = entity
            local visibleCount, chosen, allAmbient = 0, nil, true
            for _, effect in ipairs(effects) do
                if effect.visible ~= false
                    and (effect.infinite or not effect.expiresAt or effect.expiresAt > now) then
                    visibleCount = visibleCount + 1
                    if math.random(visibleCount) == 1 then chosen = effect end
                    if effect.ambient ~= true then allAmbient = false end
                end
            end
            if chosen then
                local invisible = entity:GetNW2Bool("MCITEMPotionInvisible", false)
                local divisor
                if invisible then divisor = allAmbient and 75 or 15
                else divisor = allAmbient and 20 or 4 end
                if math.random(1, divisor) == 1 then
                    spawnForEffect(entity, chosen)
                end
            end
        end
    end
end)
