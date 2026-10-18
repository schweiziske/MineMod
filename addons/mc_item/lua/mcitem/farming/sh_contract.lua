-- Shared MCITEM farming targeting/prediction contract. This layer performs no
-- authoritative writes; server mutation is exclusively MC.API.Farming.

MCITEM = MCITEM or {}
MCITEM.Farming = MCITEM.Farming or {}

local Farming = MCITEM.Farming

local VEGETATION_SUPPORT = {
    ["minecraft:dirt"] = true,
    ["minecraft:coarse_dirt"] = true,
    ["minecraft:rooted_dirt"] = true,
    ["minecraft:mud"] = true,
    ["minecraft:muddy_mangrove_roots"] = true,
    ["minecraft:moss_block"] = true,
    ["minecraft:pale_moss_block"] = true,
    ["minecraft:grass_block"] = true,
    ["minecraft:podzol"] = true,
    ["minecraft:mycelium"] = true,
    ["minecraft:farmland"] = true,
}

local BONEMEAL_MAX_AGE = {
    ["minecraft:wheat"] = 7,
    ["minecraft:carrots"] = 7,
    ["minecraft:potatoes"] = 7,
    ["minecraft:beetroots"] = 3,
    ["minecraft:melon_stem"] = 7,
    ["minecraft:pumpkin_stem"] = 7,
    ["minecraft:sweet_berry_bush"] = 3,
    -- Torchflower age 1 is still a bonemeal target: the next virtual stage
    -- replaces the crop with minecraft:torchflower.
    ["minecraft:torchflower_crop"] = 2,
    ["minecraft:pitcher_crop"] = 4,
}

function Farming.Api()
    local api = MC and MC.API or nil
    if not api or not istable(api.World) or not istable(api.Blocks) then return nil end
    if isfunction(api.IsReady) and not api.IsReady() then return nil end
    return api
end

local function blockName(api, stateId)
    if not api or not istable(api.Blocks) or not isfunction(api.Blocks.Name) then return nil end
    local name = api.Blocks.Name(stateId)
    return isstring(name) and name or nil
end

local function faceAxis(value)
    value = tonumber(value) or 0
    if value > 0.5 then return 1 end
    if value < -0.5 then return -1 end
    return 0
end

function Farming.TargetCellFromHit(hit)
    if not istable(hit) then return nil end
    local bx, by, bz = tonumber(hit.bx), tonumber(hit.by), tonumber(hit.bz)
    local normal = hit.HitNormal
    if not bx or not by or not bz or not normal then return nil end
    local nx, ny, nz = faceAxis(normal.x), faceAxis(normal.y), faceAxis(normal.z)
    if nx == 0 and ny == 0 and nz == 0 then return nil end
    return math.floor(bx) + nx, math.floor(by) + ny, math.floor(bz) + nz
end

local function aimBlock(owner)
    local interact = MCITEM.BlockInteract
    if not interact or not isfunction(interact.AimBlock) then return nil end
    return interact.AimBlock(owner)
end

function Farming.ResolvePlantContext(owner, definition)
    if not IsValid(owner) or not istable(definition) or definition.action ~= "plant" then return nil end
    local api = Farming.Api()
    if not api or not isfunction(api.World.GetBlockState) then return nil end
    local hit = aimBlock(owner)
    local bx, by, bz = Farming.TargetCellFromHit(hit)
    if not bx or api.World.GetBlockState(bx, by, bz) ~= 0 then return nil end

    local supportState = api.World.GetBlockState(bx, by, bz - 1)
    local supportName = blockName(api, supportState)
    if definition.support == "farmland" and supportName ~= "minecraft:farmland" then return nil end
    if definition.support == "vegetation" and VEGETATION_SUPPORT[supportName] ~= true then return nil end

    return {
        action = "plant",
        bx = bx, by = by, bz = bz,
        crop = definition.crop,
        hit = hit,
    }
end

function Farming.ResolveBonemealContext(owner, definition)
    if not IsValid(owner) or not istable(definition) or definition.action ~= "bonemeal" then return nil end
    local api = Farming.Api()
    if not api or not isfunction(api.World.GetBlockState) then return nil end
    local hit = aimBlock(owner)
    if not istable(hit) then return nil end
    local bx, by, bz = math.floor(tonumber(hit.bx) or 0), math.floor(tonumber(hit.by) or 0),
        math.floor(tonumber(hit.bz) or 0)
    local stateId = api.World.GetBlockState(bx, by, bz)
    local name = blockName(api, stateId)
    local maxAge = BONEMEAL_MAX_AGE[name]
    if maxAge then
        local age = isfunction(api.Blocks.GetProperty) and api.Blocks.GetProperty(stateId, "age") or nil
        if (tonumber(age) or 0) < maxAge then
            return { action = "bonemeal", bx = bx, by = by, bz = bz, stateId = stateId, hit = hit }
        end
        return nil
    end

    -- Extension point for saplings/flowers supplied by another addon. The
    -- authoritative server twin is MCITEM.ApplyBonemealTarget in sv_use.lua.
    if hook.Run("MCITEM.CanApplyBonemealTarget", owner, bx, by, bz, stateId, definition) == true then
        return {
            action = "bonemeal_extension",
            bx = bx, by = by, bz = bz, stateId = stateId, hit = hit,
        }
    end
    return nil
end

function Farming.ResolveUseContext(owner, definition)
    if not istable(definition) then return nil end
    if definition.action == "plant" then return Farming.ResolvePlantContext(owner, definition) end
    if definition.action == "bonemeal" then return Farming.ResolveBonemealContext(owner, definition) end
    return nil
end

function Farming.PredictUse(owner, definition)
    local context = Farming.ResolveUseContext(owner, definition)
    return context ~= nil, context
end

