-- Shared Minecraft Java 26.2 fishing-rod constants and integration helpers.

MCITEM = MCITEM or {}
MCITEM.Fishing = MCITEM.Fishing or {}

local Fishing = MCITEM.Fishing
if (tonumber(Fishing.CoreVersion) or 0) >= 2 then return Fishing end
Fishing.CoreVersion = 2

include("mcitem/fishing/sh_generated_data.lua")

Fishing.TickSeconds = 1 / 20
Fishing.MaxOwnerDistance = 32
Fishing.GroundLifetimeTicks = 1200
Fishing.MaxOutOfWaterTicks = 10
Fishing.HookWidth = 0.25
Fishing.SurfaceClearanceBlocks = 0.01
Fishing.WaitMinTicks = 100
Fishing.WaitMaxTicks = 600
Fishing.ApproachMinTicks = 20
Fishing.ApproachMaxTicks = 80
Fishing.BiteMinTicks = 20
Fishing.BiteMaxTicks = 40
Fishing.OpenWaterRadius = 2
Fishing.OpenWaterMinY = -1
Fishing.OpenWaterMaxY = 2

Fishing.State = {
    FLYING = 0,
    HOOKED_IN_ENTITY = 1,
    BOBBING = 2,
}

Fishing.FX = {
    APPROACH = 1,
    TEASE_SPLASH = 2,
    BITE = 3,
}

local FALLBACK_SOUNDS = {
    ["entity.fishing_bobber.throw"] = {
        { path = "mcitem/fishing/castfast.ogg", pitch = 1 },
    },
    ["entity.fishing_bobber.retrieve"] = {
        { path = "mcitem/fishing/retrieve1.ogg", pitch = 2.4 },
        { path = "mcitem/fishing/retrieve2.ogg", pitch = 2.4 },
    },
    ["entity.fishing_bobber.splash"] = {
        { path = "mcitem/fishing/splash.ogg", pitch = 1 },
    },
}

local function namespaced(identifier)
    identifier = tostring(identifier or "")
    if identifier == "" then return nil end
    return string.find(identifier, ":", 1, true) and identifier or "minecraft:" .. identifier
end

local function contains(list, wanted)
    for _, value in ipairs(istable(list) and list or {}) do
        if value == wanted then return true end
    end
    return false
end

function Fishing.BlockSize()
    return isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
end

function Fishing.Triangle(mode, deviation)
    return (tonumber(mode) or 0)
        + (tonumber(deviation) or 0) * (math.Rand(0, 1) - math.Rand(0, 1))
end

local function hullExitDistance(position, direction, minimum, maximum)
    local distance = math.huge
    local function axis(origin, delta, low, high)
        if math.abs(delta) <= 1e-9 then return end
        local value = ((delta > 0 and high or low) - origin) / delta
        if value >= 0 then distance = math.min(distance, value) end
    end
    axis(position.x, direction.x, minimum.x, maximum.x)
    axis(position.y, direction.y, minimum.y, maximum.y)
    return distance < math.huge and distance or 0
end

function Fishing.LaunchOrigin(owner)
    if not IsValid(owner) then return nil end
    local flat = Angle(0, owner:EyeAngles().y, 0):Forward()
    local eye = owner:EyePos()
    local blockSize = Fishing.BlockSize()
    local distance = 0.3 * blockSize
    if owner.WorldSpaceAABB then
        local minimum, maximum = owner:WorldSpaceAABB()
        if isvector(minimum) and isvector(maximum) then
            local hookRadius = Fishing.HookWidth * 0.5 * blockSize
            distance = math.max(distance, hullExitDistance(eye, flat, minimum, maximum) + hookRadius + 1)
        end
    end
    return eye + flat * distance
end

function Fishing.LaunchVelocity(owner)
    if not IsValid(owner) then return vector_origin end
    local eye = owner:EyeAngles()
    local flat = Angle(0, eye.y, 0):Forward()
    local slope = math.Clamp(-math.tan(math.rad(eye.p)), -5, 5)
    local direction = Vector(flat.x, flat.y, slope)
    local distance = math.max(direction:Length(), 1e-9)
    return Vector(
        direction.x * (0.6 / distance + Fishing.Triangle(0.5, 0.0103365)),
        direction.y * (0.6 / distance + Fishing.Triangle(0.5, 0.0103365)),
        direction.z * (0.6 / distance + Fishing.Triangle(0.5, 0.0103365))
    )
end

function Fishing.InventoryAPI()
    local api = MC and MC.API
    local inventory = api and api.Inventory
    return istable(inventory) and inventory or nil
end

function Fishing.ItemStackAPI()
    local api = MC and MC.API
    local itemStack = api and api.ItemStack
    return istable(itemStack) and itemStack or nil
end

function Fishing.SelectedStack(owner, weapon)
    local inventoryProxy = IsValid(weapon) and weapon.GetNW2Bool
        and weapon:GetNW2Bool("MCITEM_InventoryProxy", false)
    if inventoryProxy then
        local inventory = Fishing.InventoryAPI()
        if not inventory or not isfunction(inventory.GetSelected) then
            return nil, "inventory_api_unavailable"
        end
        local stack = inventory.GetSelected(owner)
        if not istable(stack) then return nil, "selected_stack_unavailable" end
        return stack
    end
    if IsValid(weapon) and istable(weapon.MCITEMEnchantmentStack) then
        return table.Copy(weapon.MCITEMEnchantmentStack)
    end
    return { item = "minecraft:fishing_rod", count = 1 }
end

function Fishing.StackHash(stack)
    local itemStack = Fishing.ItemStackAPI()
    if itemStack and isfunction(itemStack.Hash) then
        local hash = itemStack.Hash(stack)
        if isstring(hash) and hash ~= "" then return hash end
    end
    return MC and isfunction(MC.ItemStackHash) and MC.ItemStackHash(stack) or nil
end

function Fishing.EnchantmentLevel(stack, enchantmentId)
    enchantmentId = namespaced(enchantmentId)
    -- Fishing is a runtime item-use effect.  Prefer the shared MCITEM reader,
    -- which explicitly asks MineMod for the ordinary `enchantments` component.
    -- The public scalar ItemStack API intentionally accepts enchanted-book
    -- `stored_enchantments` too, so using it first would let a malformed book
    -- stack activate Lure/Luck of the Sea.
    local runtime = MCITEM.EnchantmentRuntime
    if runtime and isfunction(runtime.GetEnchantmentLevel) then
        return math.max(0, math.floor(runtime.GetEnchantmentLevel(stack, enchantmentId)))
    end
    local itemStack = Fishing.ItemStackAPI()
    if itemStack and isfunction(itemStack.GetEnchantmentLevel) then
        local level = itemStack.GetEnchantmentLevel(stack, enchantmentId)
        if isnumber(level) then return math.max(0, math.floor(level)) end
    end
    return 0
end

function Fishing.LureSpeed(stack)
    -- Java 26.2 lure.json adds five seconds per level; FishingRodItem converts
    -- that reduction back to ticks before constructing FishingHook.
    return Fishing.EnchantmentLevel(stack, "minecraft:lure") * 100
end

function Fishing.PlayerLuck(owner, stack)
    local value = 0
    local potions = MCITEM.Potions
    if IsValid(owner) and potions and potions.GetEffect then
        local luck = potions.GetEffect(owner, "luck")
        local unluck = potions.GetEffect(owner, "unluck")
        if luck then value = value + luck.amplifier + 1 end
        if unluck then value = value - unluck.amplifier - 1 end
    end
    local extra = hook.Run("MCITEM.FishingPlayerLuck", owner, stack)
    if isnumber(extra) then value = value + extra end
    -- Luck is an additive floating-point attribute.  Java keeps the raw
    -- value until LootTable#getRandomItems applies each entry's integer
    -- weight formula; flooring here silently discards mod/provider bonuses.
    return tonumber(value) or 0
end

function Fishing.Luck(stack, owner)
    return Fishing.EnchantmentLevel(stack, "minecraft:luck_of_the_sea") + Fishing.PlayerLuck(owner, stack)
end

local function engineToWorld(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if coords and coords.EngineToWorld then return coords.EngineToWorld(position, context) end
    if MC and MC.EngineToWorldPos then return MC.EngineToWorldPos(position, context) end
    return position
end

local function worldToEngine(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if coords and coords.WorldToEngine then return coords.WorldToEngine(position, context) end
    return position - engineToWorld(vector_origin, context)
end

function Fishing.EngineToCell(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if coords and isfunction(coords.EngineToCell) then
        local bx, by, bz = coords.EngineToCell(position, context)
        if bx ~= nil then return bx, by, bz end
    end
    if MC and isfunction(MC.WorldToCell) then return MC.WorldToCell(position) end
    local size = Fishing.BlockSize()
    return math.floor(position.x / size), math.floor(position.y / size), math.floor(position.z / size)
end

function Fishing.CellMin(bx, by, bz)
    local coords = MC and MC.API and MC.API.Coords
    if coords and isfunction(coords.CellMin) then return coords.CellMin(bx, by, bz) end
    if MC and isfunction(MC.CellWorldMin) then return MC.CellWorldMin(bx, by, bz) end
    return Vector(bx, by, bz) * Fishing.BlockSize()
end

local function shallowCopy(value)
    local output = {}
    for key, entry in pairs(istable(value) and value or {}) do output[key] = entry end
    return output
end

local function hasContentsFlag(contents, flag)
    return isnumber(contents) and isnumber(flag)
        and bit and isfunction(bit.band) and bit.band(contents, flag) ~= 0
end

function Fishing.SourceFluidKindAt(position)
    if not isvector(position) or not util or not isfunction(util.PointContents) then return nil end
    local contents = util.PointContents(position)
    if hasContentsFlag(contents, CONTENTS_WATER)
        or hasContentsFlag(contents, CONTENTS_SLIME)
    then
        return "water"
    end
    if hasContentsFlag(contents, CONTENTS_LAVA) then return "lava" end
    return nil
end

function Fishing.SourceFluidSurfaceZ(position, kind)
    kind = tostring(kind or "")
    if not isvector(position) or kind == ""
        or Fishing.SourceFluidKindAt(position) ~= kind
    then
        return nil
    end

    -- Source exposes brush-liquid membership but not the surface height. Find
    -- the first dry point above the hook, then binary-search the boundary. This
    -- keeps bobbing aligned to arbitrary map-water heights instead of snapping
    -- Source water to Minecraft's block grid.
    local wetZ = position.z
    local dryZ
    local step = math.max(Fishing.BlockSize() * 0.5, 8)
    local maximumRise = math.max(32768, Fishing.BlockSize() * 512)
    for _ = 1, 16 do
        local candidateZ = wetZ + step
        if candidateZ - position.z > maximumRise then break end
        local candidate = Vector(position.x, position.y, candidateZ)
        if Fishing.SourceFluidKindAt(candidate) == kind then
            wetZ = candidateZ
            step = step * 2
        else
            dryZ = candidateZ
            break
        end
    end
    if not dryZ then return nil end

    for _ = 1, 14 do
        local middle = (wetZ + dryZ) * 0.5
        if Fishing.SourceFluidKindAt(Vector(position.x, position.y, middle)) == kind then
            wetZ = middle
        else
            dryZ = middle
        end
    end
    return (wetZ + dryZ) * 0.5
end

function Fishing.FluidAtCell(bx, by, bz)
    local liquid = MC and MC.API and MC.API.Liquid
    if liquid and isfunction(liquid.GetAt) then return liquid.GetAt(bx, by, bz) end
    return nil
end

function Fishing.FluidAtPosition(position, context)
    local bx, by, bz = Fishing.EngineToCell(position, context)
    local worldPosition = engineToWorld(position, context)
    local originZ = worldPosition.z - position.z
    local liquid = MC and MC.API and MC.API.Liquid
    local exactQueryAvailable = false
    local aboveKnownCellFluid = false
    if liquid and isfunction(liquid.AtPos) then
        local ok, contact = pcall(liquid.AtPos, worldPosition)
        exactQueryAvailable = ok
        if ok and istable(contact) and contact.kind then
            local fluid = shallowCopy(contact)
            fluid.source = false
            local surfaceZ = tonumber(fluid.surfaceZ)
            fluid.surfaceZ = surfaceZ and surfaceZ - originZ or nil
            return fluid, fluid.bx or bx, fluid.by or by, fluid.bz or bz
        end
    end

    -- Older mc_engine builds only expose a cell query. Respect the authored
    -- FluidState height so a hook above a flowing surface is not considered
    -- submerged merely because it shares the same block cell.
    if not exactQueryAvailable then
        local fluid = Fishing.FluidAtCell(bx, by, bz)
        if fluid then
            fluid = shallowCopy(fluid)
            local cellMinimum = worldToEngine(Fishing.CellMin(bx, by, bz), context)
            local surfaceZ = cellMinimum.z
                + math.Clamp(tonumber(fluid.height) or 0, 0, 1) * Fishing.BlockSize()
            if position.z < surfaceZ then
                fluid.source = false
                fluid.surfaceZ = surfaceZ
                return fluid, bx, by, bz
            end
            aboveKnownCellFluid = true
        end
    end

    local sourceKind = Fishing.SourceFluidKindAt(position)
    if sourceKind then
        return {
            kind = sourceKind,
            height = 1,
            level = 0,
            falling = false,
            waterlogged = false,
            source = true,
            surfaceZ = Fishing.SourceFluidSurfaceZ(position, sourceKind),
        }, bx, by, bz
    end

    -- Legacy Minecraft builds can still expose liquid through the throwable
    -- compatibility layer even when API.Liquid is absent. Source water has
    -- already been handled above, so this fallback remains unambiguous.
    local throwables = MCITEM.Throwables
    local kind = throwables and isfunction(throwables.FluidKindAt)
        and throwables.FluidKindAt(position, context) or nil
    if kind and not aboveKnownCellFluid then
        return {
            kind = kind,
            height = 1,
            level = 0,
            falling = false,
            waterlogged = false,
            source = false,
            surfaceZ = worldToEngine(Fishing.CellMin(bx, by, bz), context).z + Fishing.BlockSize(),
        }, bx, by, bz
    end
    return nil, bx, by, bz
end

function Fishing.FluidSurfaceZ(position, fluid, bx, by, bz, context)
    if not istable(fluid) then return nil end
    if isnumber(fluid.surfaceZ) then return fluid.surfaceZ end
    if fluid.source == true then
        return Fishing.SourceFluidSurfaceZ(position, fluid.kind)
    end
    local cellMinimum = worldToEngine(Fishing.CellMin(bx, by, bz), context)
    return cellMinimum.z
        + math.Clamp(tonumber(fluid.height) or 0, 0, 1) * Fishing.BlockSize()
end

function Fishing.WaterSurfacePosition(position, context)
    local fluid, bx, by, bz = Fishing.FluidAtPosition(position, context)
    if not fluid or fluid.kind ~= "water" then return nil, bx, by, bz, fluid end
    local surfaceZ = Fishing.FluidSurfaceZ(position, fluid, bx, by, bz, context)
    if not isnumber(surfaceZ) then return nil, bx, by, bz, fluid end
    if fluid.source == true then
        return Vector(position.x, position.y, surfaceZ), bx, by, bz, fluid
    end
    local cellMinimum = worldToEngine(Fishing.CellMin(bx, by, bz), context)
    return Vector(
        cellMinimum.x + Fishing.BlockSize() * 0.5,
        cellMinimum.y + Fishing.BlockSize() * 0.5,
        surfaceZ
    ), bx, by, bz, fluid
end

function Fishing.IsExactWaterBlock(bx, by, bz)
    local world = MC and MC.API and MC.API.World
    local info = world and isfunction(world.GetBlockInfo) and world.GetBlockInfo(bx, by, bz) or nil
    local identifier = info and namespaced(info.name or info.mcid) or nil
    return identifier == "minecraft:water"
end

function Fishing.IsFishingWaterFluid(fluid, bx, by, bz)
    if not fluid or fluid.kind ~= "water" then return false end
    if fluid.source == true then return true end
    local world = MC and MC.API and MC.API.World
    if world and isfunction(world.GetBlockInfo) then
        return Fishing.IsExactWaterBlock(bx, by, bz)
    end
    return fluid.waterlogged ~= true
end

local function sourcePointBlocked(position)
    if not util or not isfunction(util.PointContents) then return false end
    local contents = util.PointContents(position)
    return hasContentsFlag(contents, CONTENTS_SOLID)
        or hasContentsFlag(contents, CONTENTS_MOVEABLE)
        or hasContentsFlag(contents, CONTENTS_WINDOW)
        or hasContentsFlag(contents, CONTENTS_GRATE)
        or hasContentsFlag(contents, CONTENTS_PLAYERCLIP)
        or hasContentsFlag(contents, CONTENTS_MONSTERCLIP)
end

function Fishing.CalculateSourceOpenWater(surfacePosition)
    if not isvector(surfacePosition) then return false end
    local blockSize = Fishing.BlockSize()
    for xOffset = -Fishing.OpenWaterRadius, Fishing.OpenWaterRadius do
        for yOffset = -Fishing.OpenWaterRadius, Fishing.OpenWaterRadius do
            local x = surfacePosition.x + xOffset * blockSize
            local y = surfacePosition.y + yOffset * blockSize
            for _, depth in ipairs({ 0.5, 1.5 }) do
                if Fishing.SourceFluidKindAt(Vector(x, y, surfacePosition.z - depth * blockSize)) ~= "water" then
                    return false
                end
            end
            for _, height in ipairs({ 0.5, 1.5 }) do
                local position = Vector(x, y, surfacePosition.z + height * blockSize)
                if Fishing.SourceFluidKindAt(position) ~= nil or sourcePointBlocked(position) then
                    return false
                end
            end
        end
    end
    return true
end

function Fishing.CanSeeSourceSky(position, context)
    if not isvector(position) then return false end
    local trace = util.TraceLine({
        start = position + Vector(0, 0, 1),
        endpos = position + Vector(0, 0, math.max(32768, Fishing.BlockSize() * 512)),
        filter = context,
        mask = MASK_SOLID_BRUSHONLY or MASK_SOLID,
    })
    return not trace.Hit or trace.HitSky == true
end

function Fishing.CanSeeSky(bx, by, bz, context)
    local world = MC and MC.API and MC.API.World
    if world and isfunction(world.CanSeeSky) then
        local visible = world.CanSeeSky(bx, by, bz)
        if visible ~= nil then return visible == true end
    end
    local position = worldToEngine(Fishing.CellMin(bx, by, bz), context)
        + Vector(0.5, 0.5, 1) * Fishing.BlockSize()
    local trace = util.TraceLine({
        start = position,
        endpos = position + Vector(0, 0, math.max(32768, Fishing.BlockSize() * 512)),
        filter = context,
        mask = MASK_SOLID_BRUSHONLY or MASK_SOLID,
    })
    return not trace.Hit or trace.HitSky == true
end

function Fishing.IsRainingAt(bx, by, bz, hookEntity)
    local weather = MC and MC.API and MC.API.Weather
    if weather and isfunction(weather.IsRainingAt) then
        local result = weather.IsRainingAt(bx, by, bz)
        if result ~= nil then return result == true end
    end
    local result = hook.Run("MCITEM.FishingIsRainingAt", bx, by, bz, hookEntity)
    return result == true
end

function Fishing.IsJungleBiome(position, hookEntity)
    local result = hook.Run("MCITEM.FishingBiome", position, hookEntity)
    if isstring(result) then result = namespaced(result) end
    return result
end

function Fishing.PlaySound(eventName, position, volume, pitch, soundLevel)
    if not isvector(position) then return false end
    local apiSound = MC and MC.API and MC.API.Sound
    if apiSound and isfunction(apiSound.Play) then
        local ok = apiSound.Play(eventName, position, {
            volume = volume,
            pitch = pitch,
            soundLevel = soundLevel or 72,
        })
        if ok then return true end
    end

    local candidates = FALLBACK_SOUNDS[eventName]
    if not candidates or #candidates == 0 then return false end
    local candidate = candidates[math.random(1, #candidates)]
    sound.Play(
        candidate.path,
        position,
        soundLevel or 72,
        math.Clamp(math.floor((tonumber(pitch) or 1) * candidate.pitch * 100 + 0.5), 1, 255),
        math.Clamp(tonumber(volume) or 1, 0, 1)
    )
    return true
end

function Fishing.IsItemEntity(entity)
    if not IsValid(entity) then return false end
    if entity:GetClass() == "mc_item_drop" then return true end
    local result = hook.Run("MCITEM.IsFishingItemEntity", entity)
    return result == true
end

function Fishing.EnchantmentSupportsItem(definition, itemId)
    if itemId == "minecraft:book" then return true end
    return contains(definition and definition.primaryItems, itemId)
end

return Fishing
