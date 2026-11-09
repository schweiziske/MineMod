-- MineMod voxel lighting bridge for MCITEM StudioModels.
--
-- Held weapons, food, potions and throwable items all end up as Source
-- StudioModels.  MineMod's block-mesh shade pipeline cannot light those models,
-- so use the same prop-style path as mc/render/cl_entity_lighting.lua:
-- sample dynamic voxel RGB, suppress Source model lighting for one bounded draw,
-- modulate the model, then immediately restore global render state.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.ModelLighting = MCITEM.ModelLighting or {}

local Lighting = MCITEM.ModelLighting
Lighting.States = istable(Lighting.States)
    and Lighting.States
    or setmetatable({}, { __mode = "k" })

local lightStates = Lighting.States
local cvEnabled = GetConVar("mcitem_mcswep_lighting") or CreateClientConVar(
    "mcitem_mcswep_lighting", "1", true, false,
    "Apply MineMod voxel lighting to MCITEM held, dropped and thrown item models."
)

local function clamp01(value)
    return math.Clamp(tonumber(value) or 1, 0, 1)
end

-- Resolve at sample time rather than file load time: autorun/SWEP ordering may
-- load MCITEM before MineMod, and either addon can be Lua-refreshed independently.
local function mcLightFn(name, fallbackName)
    if not MC then return nil end
    if istable(MC.API) and istable(MC.API.Light)
    and isfunction(MC.API.Light[name]) then
        return MC.API.Light[name]
    end
    return isfunction(MC[fallbackName]) and MC[fallbackName] or nil
end

local function sampleInterval(entity)
    local interval = tonumber(entity and entity.MCLightSampleInterval)
    if interval == nil and MC and MC.EntityLightingInterval then
        interval = MC.EntityLightingInterval:GetFloat()
    end
    return math.Clamp(interval or 0.10, 0, 2)
end

-- [BMB 2026-11-09] Under mc_light_entity_unit_tonemap the draw runs at tone
-- scale 1, so the exposure-tuned legacy gain is replaced by the unit gain.
local function exposureGain(legacyGain)
    if MC and isfunction(MC.EntityExposureGain) then return MC.EntityExposureGain(legacyGain) end
    return legacyGain
end

local function entityGain(entity)
    local gain = tonumber(entity and entity.MCLightGain)
    if gain == nil and MC and MC.EntityLightingGain then
        gain = MC.EntityLightingGain:GetFloat()
    end
    return math.Clamp(exposureGain(gain or 0.48), 0, 1)
end

function Lighting.SamplePosition(entity)
    if not IsValid(entity) then return nil end

    local mins, maxs = entity:OBBMins(), entity:OBBMaxs()
    local height = math.Clamp(tonumber(entity.MCLightSampleHeightFrac) or 0.65, 0, 1)
    return entity:LocalToWorld(Vector(
        (mins.x + maxs.x) * 0.5,
        (mins.y + maxs.y) * 0.5,
        Lerp(height, mins.z, maxs.z)
    ))
end

local function sampleLight(sampleRGB, position, emission)
    local ok, r, g, b = pcall(sampleRGB, position, emission)
    if not ok or r == nil or g == nil or b == nil then return nil end
    return clamp01(r), clamp01(g), clamp01(b)
end

function Lighting.GetRGB(entity, samplePosition, emission)
    if not IsValid(entity) or not cvEnabled:GetBool() then return nil end

    local sampleRGB = mcLightFn("SampleRGB", "SampleDynamicLightingRGB")
    if not sampleRGB then
        lightStates[entity] = nil
        return nil
    end

    samplePosition = isvector(samplePosition)
        and samplePosition
        or Lighting.SamplePosition(entity)
    if not isvector(samplePosition) then return nil end

    emission = math.Clamp(
        tonumber(emission)
            or tonumber(entity.MCLightEmission)
            or tonumber(entity.MCItemLightEmission)
            or 0,
        0,
        15
    )

    local now = CurTime()
    local interval = sampleInterval(entity)
    local state = lightStates[entity]

    if not state then
        local r, g, b = sampleLight(sampleRGB, samplePosition, emission)
        if r == nil then return nil end

        local entIndex = entity.EntIndex and entity:EntIndex() or 0
        local phase = interval > 0
            and ((math.abs(tonumber(entIndex) or 0) % 7) / 7) * interval
            or 0
        state = {
            r = r,
            g = g,
            b = b,
            targetR = r,
            targetG = g,
            targetB = b,
            nextSample = now + interval + phase,
            lastUpdate = now,
        }
        lightStates[entity] = state
    elseif interval <= 0 or now >= (state.nextSample or 0) then
        local r, g, b = sampleLight(sampleRGB, samplePosition, emission)
        if r ~= nil then
            state.targetR, state.targetG, state.targetB = r, g, b
        end
        state.nextSample = now + interval
    end

    local dt = math.Clamp(now - (state.lastUpdate or now), 0, 0.1)
    state.lastUpdate = now
    local blend = 1 - math.exp(-dt * 12)
    state.r = Lerp(blend, state.r, state.targetR or state.r)
    state.g = Lerp(blend, state.g, state.targetG or state.g)
    state.b = Lerp(blend, state.b, state.targetB or state.b)

    local rawR, rawG, rawB = clamp01(state.r), clamp01(state.g), clamp01(state.b)
    local gain = entityGain(entity)
    local scaleRGB = mcLightFn("ScaleRGB", "ScaleDynamicLightingRGB")
    if scaleRGB then
        local ok, r, g, b = pcall(scaleRGB, rawR, rawG, rawB, gain)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            return clamp01(r), clamp01(g), clamp01(b), rawR, rawG, rawB
        end
    end

    return clamp01(rawR * gain), clamp01(rawG * gain), clamp01(rawB * gain),
        rawR, rawG, rawB
end

local function reportDrawError(entity, err)
    local className = IsValid(entity) and entity:GetClass() or "invalid_entity"
    ErrorNoHalt(string.format(
        "[MCITEM] MineMod-lit model draw failed (%s): %s\n",
        tostring(className), tostring(err)
    ))
end

function Lighting.Draw(entity, samplePosition, drawCallback, emission)
    if not IsValid(entity) then return false end
    drawCallback = isfunction(drawCallback) and drawCallback or function()
        entity:DrawModel()
    end

    local r, g, b, glintR, glintG, glintB = Lighting.GetRGB(entity, samplePosition, emission)
    local sampled = r ~= nil
    local drawR, drawG, drawB = sampled and r or 1, sampled and g or 1, sampled and b or 1
    glintR, glintG, glintB = sampled and (glintR or r) or 1,
        sampled and (glintG or g) or 1, sampled and (glintB or b) or 1
    if sampled then
        render.SuppressEngineLighting(true)
        render.SetColorModulation(r, g, b)
    end

    -- Pass the active modulation into nested passes. In particular, the
    -- enchantment glint temporarily changes color modulation and must restore
    -- this sampled RGB instead of forcing the remainder of the scope white.
    if sampled and MC and MC.BeginEntityUnitExposure then MC.BeginEntityUnitExposure() end -- [BMB 2026-11-09]
    local ok, err = pcall(drawCallback, drawR, drawG, drawB, sampled,
        glintR, glintG, glintB)

    if sampled and MC and MC.EndEntityUnitExposure then MC.EndEntityUnitExposure() end
    if sampled then
        render.SetColorModulation(1, 1, 1)
        render.SuppressEngineLighting(false)
    end

    if not ok then reportDrawError(entity, err) end
    return ok
end

-- Public convenience name used by the shared SWEP and projectile billboard
-- renderers.  The callback form keeps the base model and enchantment glint in
-- one lighting/state-restoration scope.
function MCITEM.DrawModelWithMCLight(entity, samplePosition, drawCallback, emission)
    return Lighting.Draw(entity, samplePosition, drawCallback, emission)
end
