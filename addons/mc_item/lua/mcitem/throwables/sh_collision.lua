-- Shared collision/fluid helpers for Minecraft Java 26.2 throwable entities.
-- Projectile block hits are centre rays in vanilla. Entity hits use the ray
-- against the target AABB inflated by ProjectileUtil's age-dependent margin.

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
local COLLISION_VERSION = 4
if (tonumber(Throwables.CollisionVersion) or 0) >= COLLISION_VERSION then return end
Throwables.CollisionVersion = COLLISION_VERSION
Throwables.CollisionLoaded = true

local EPSILON = 1e-7

local function worldPosition(position, context)
    local coords = MC and MC.API and MC.API.Coords
    if coords then return coords.EngineToWorld(position, context or (CLIENT and LocalPlayer() or nil)) end
    return position
end

-- MineMod exposes its Minecraft world collision through large Source entities
-- (`mc_chunk`, `mc_chunk_phys` and the client prediction carrier).  Those
-- entities are only an engine-side broad-phase proxy; their AABB can cover an
-- entire chunk/subchunk and therefore must never be considered a projectile
-- entity target.  Java's ProjectileUtil queries entities and blocks as two
-- separate paths, so MCITEM does the same: voxel blocks are resolved by the
-- exact Minecraft ray below, while only real gameplay entities reach
-- `entityTrace`.
local WORLD_COLLISION_PROXY_CLASSES = {
    mc_chunk = true,
    mc_chunk_phys = true,
    mc_collision_carrier = true,
}

local function isWorldCollisionProxy(entity)
    if not IsValid(entity) then return false end
    return WORLD_COLLISION_PROXY_CLASSES[entity:GetClass()] == true
        or entity.MCWorldCollisionProxy == true
        or entity.MCIsWorldCollisionProxy == true
end

local function axisValues(vector, axis)
    if axis == 1 then return vector.x end
    if axis == 2 then return vector.y end
    return vector.z
end

local function axisNormal(axis, sign)
    if axis == 1 then return Vector(sign, 0, 0) end
    if axis == 2 then return Vector(0, sign, 0) end
    return Vector(0, 0, sign)
end

function Throwables.RayAABB(startPosition, direction, maximumDistance, minimum, maximum)
    if not isvector(startPosition) or not isvector(direction)
        or not isvector(minimum) or not isvector(maximum)
    then
        return nil
    end
    maximumDistance = math.max(0, tonumber(maximumDistance) or 0)
    local nearDistance, farDistance = -math.huge, maximumDistance
    local hitNormal = vector_origin

    for axis = 1, 3 do
        local origin = axisValues(startPosition, axis)
        local delta = axisValues(direction, axis)
        local low = axisValues(minimum, axis)
        local high = axisValues(maximum, axis)
        if math.abs(delta) <= EPSILON then
            if origin < low or origin > high then return nil end
        else
            local first = (low - origin) / delta
            local second = (high - origin) / delta
            local firstNormal = axisNormal(axis, delta > 0 and -1 or 1)
            if first > second then
                first, second = second, first
            end
            if first > nearDistance then
                nearDistance = first
                hitNormal = firstNormal
            end
            farDistance = math.min(farDistance, second)
            if nearDistance > farDistance then return nil end
        end
    end

    if farDistance < 0 or nearDistance > maximumDistance then return nil end
    if nearDistance < 0 then return 0, -direction end
    return nearDistance, hitNormal
end

local function traceDistance(trace, startPosition, maximumDistance)
    if not trace then return nil end
    if isnumber(trace.Distance) then return trace.Distance end
    if isnumber(trace.Fraction) then return trace.Fraction * maximumDistance end
    if isvector(trace.HitPos) then return trace.HitPos:Distance(startPosition) end
    return nil
end

local function closestTrace(current, candidate, startPosition, maximumDistance)
    if not candidate or candidate.Hit ~= true then return current end
    candidate.Distance = traceDistance(candidate, startPosition, maximumDistance)
    if not candidate.Distance then return current end
    if not current or candidate.Distance < current.Distance - EPSILON then return candidate end
    return current
end

local function sourceWorldTrace(startPosition, destination)
    local trace = util.TraceLine({
        start = startPosition,
        endpos = destination,
        mask = MASK_SOLID_BRUSHONLY,
    })
    if not trace.Hit then return nil end
    trace.HitWorld = true
    return trace
end

local function minecraftBlockTrace(startPosition, direction, maximumDistance, context)
    local world = MC and MC.API and MC.API.World
    local worldStart = worldPosition(startPosition, context)
    local trace
    if world and isfunction(world.TraceRay) then
        trace = world.TraceRay(worldStart, direction, maximumDistance)
    elseif MC and isfunction(MC.TraceBlockRay) then
        trace = MC.TraceBlockRay(worldStart, direction, maximumDistance)
    end
    if not trace or trace.Hit ~= true then return nil end
    trace.HitPos = trace.HitPos - (worldStart - startPosition)
    trace.HitWorld = true
    trace.Entity = game.GetWorld()
    return trace
end

-- Shared duck-typed query used by both generic throwables and the separate
-- AbstractArrow/ThrownTrident trace path. nil means "no opinion"; true/false is
-- an explicit decision. Keeping this separate from Source solidity checks lets
-- an entity such as an Enderman veto a projectile hit without making ordinary
-- props or MineMod chunk collision disappear from arrow traces.
function Throwables.QueryProjectileEntityHit(projectile, entity)
    if not IsValid(projectile) or not IsValid(entity) then return nil end
    if isfunction(projectile.ShouldMCProjectileHitEntity) then
        local result = projectile:ShouldMCProjectileHitEntity(entity)
        if result ~= nil then return result ~= false end
    end
    if isfunction(entity.CanBeHitByMCProjectile) then
        local result = entity:CanBeHitByMCProjectile(projectile)
        if result ~= nil then return result ~= false end
    end
    local result = hook.Run("MCITEM.ShouldProjectileHitEntity", projectile, entity)
    if result ~= nil then return result ~= false end
    return nil
end

local function entityCanBeHit(projectile, entity)
    if not IsValid(entity) or entity:IsWorld() or entity == projectile then return false end
    if isWorldCollisionProxy(entity) then return false end
    local owner = projectile:GetOwner()
    if entity == owner and projectile.MCLeftOwner ~= true then return false end
    if entity.MCProjectilePassThrough == true then return false end
    local queried = Throwables.QueryProjectileEntityHit(projectile, entity)
    if queried ~= nil then return queried ~= false end
    if entity:IsPlayer() then return entity:Alive() and not entity:IsFlagSet(FL_NOTARGET) end
    if entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true then
        return entity.BMBDead ~= true
    end
    return entity:GetSolid() ~= SOLID_NONE
end

local function boxesOverlap(minimumA, maximumA, minimumB, maximumB)
    return minimumA.x <= maximumB.x and maximumA.x >= minimumB.x
        and minimumA.y <= maximumB.y and maximumA.y >= minimumB.y
        and minimumA.z <= maximumB.z and maximumA.z >= minimumB.z
end

local function projectileTargetBounds(entity)
    -- BMB's CollisionMins/CollisionMaxs are its Minecraft-sized gameplay box.
    -- Prefer them over render/model bounds, which can be stale for animated
    -- NextBots and are not guaranteed to participate in ents.FindInBox.
    if entity.IsBMBMob == true
        and isvector(entity.CollisionMins)
        and isvector(entity.CollisionMaxs) then
        local origin = entity:GetPos()
        return origin + entity.CollisionMins, origin + entity.CollisionMaxs
    end
    return entity:WorldSpaceAABB()
end

local function sourceEntityTrace(projectile, startPosition, destination)
    local trace = util.TraceLine({
        start = startPosition,
        endpos = destination,
        mask = MASK_SHOT,
        filter = function(entity)
            return entityCanBeHit(projectile, entity)
        end,
    })
    if not trace.Hit or trace.HitWorld or not IsValid(trace.Entity) then return nil end
    return trace
end

local function entityTrace(projectile, startPosition, direction, maximumDistance, destination)
    -- ProjectileUtil.getEntityHitResult expands target AABBs by this exact
    -- margin: max(0, min(0.3, (tickCount - 2) / 20)).
    local age = tonumber(projectile.MCProjectileAge) or 0
    local margin = math.max(0, math.min(0.3, (age - 2) / 20)) * MCITEM.BlockSize()
    local padding = Vector(margin, margin, margin)
    local sweepMinimum = Vector(
        math.min(startPosition.x, destination.x),
        math.min(startPosition.y, destination.y),
        math.min(startPosition.z, destination.z)
    ) - padding
    local sweepMaximum = Vector(
        math.max(startPosition.x, destination.x),
        math.max(startPosition.y, destination.y),
        math.max(startPosition.z, destination.z)
    ) + padding
    local best
    local candidates = {}
    local seen = {}

    local function addCandidate(entity)
        if not IsValid(entity) or seen[entity] then return end
        seen[entity] = true
        candidates[#candidates + 1] = entity
    end

    for _, entity in ipairs(ents.FindInBox(sweepMinimum, sweepMaximum)) do
        addCandidate(entity)
    end

    -- Some Source builds omit SOLID_BBOX NextBots from a very thin
    -- ents.FindInBox sweep. BMB already maintains a compact registry, so use
    -- it as an optional broad-phase fallback without introducing a dependency.
    if BMB and isfunction(BMB.ForEachMob) then
        BMB.ForEachMob(function(entity)
            if not IsValid(entity) then return end
            local minimum, maximum = projectileTargetBounds(entity)
            if boxesOverlap(sweepMinimum, sweepMaximum, minimum, maximum) then
                addCandidate(entity)
            end
        end)
    end

    for _, entity in ipairs(candidates) do
        if entityCanBeHit(projectile, entity) then
            local minimum, maximum = projectileTargetBounds(entity)
            minimum, maximum = minimum - padding, maximum + padding
            local distance, normal = Throwables.RayAABB(
                startPosition,
                direction,
                maximumDistance,
                minimum,
                maximum
            )
            if distance and (not best or distance < best.Distance) then
                best = {
                    Hit = true,
                    HitWorld = false,
                    Entity = entity,
                    HitPos = startPosition + direction * distance,
                    HitNormal = normal,
                    Distance = distance,
                    Fraction = maximumDistance > 0 and distance / maximumDistance or 0,
                }
            end
        end
    end
    return best
end

function Throwables.TraceProjectile(projectile, startPosition, destination)
    if not IsValid(projectile) or not isvector(startPosition) or not isvector(destination) then
        return { Hit = false, HitPos = destination }
    end
    local displacement = destination - startPosition
    local maximumDistance = displacement:Length()
    if maximumDistance <= EPSILON then return { Hit = false, HitPos = destination } end
    local direction = displacement / maximumDistance
    local best
    best = closestTrace(best, sourceWorldTrace(startPosition, destination), startPosition, maximumDistance)
    best = closestTrace(best, minecraftBlockTrace(startPosition, direction, maximumDistance, projectile), startPosition, maximumDistance)
    best = closestTrace(best, sourceEntityTrace(projectile, startPosition, destination), startPosition, maximumDistance)
    best = closestTrace(best, entityTrace(projectile, startPosition, direction, maximumDistance, destination), startPosition, maximumDistance)
    if best then return best end
    return {
        Hit = false,
        HitPos = destination,
        HitNormal = vector_origin,
        Fraction = 1,
        Distance = maximumDistance,
    }
end

local function cellCollisionBoxes(bx, by, bz)
    if not MC or not isfunction(MC.GetBlockState) or not isfunction(MC.CellWorldMin) then return nil end
    local stateId = MC.GetBlockState(bx, by, bz) or 0
    if stateId == 0 then return nil end
    if isfunction(MC.BlockHasCollisionForState)
        and MC.BlockHasCollisionForState(stateId, bx, by, bz) ~= true
    then
        return nil
    end
    local boxes = isfunction(MC.GetCellCollisionBoxes) and MC.GetCellCollisionBoxes(bx, by, bz) or nil
    if boxes and boxes[1] then return boxes end
    if not isfunction(MC.BlockIsFullCubeForState)
        or MC.BlockIsFullCubeForState(stateId, bx, by, bz) == true
    then
        return { { 0, 0, 0, 1, 1, 1 } }
    end
    return nil
end

local function minecraftHullTrace(startPosition, destination, minimumHull, maximumHull, context)
    if not MC or not isfunction(MC.WorldToCell) or not isfunction(MC.CellWorldMin) then return nil end
    local sourceStart = startPosition
    local worldStart = worldPosition(startPosition, context)
    local offset = worldStart - startPosition
    startPosition, destination = worldStart, destination + offset
    local displacement = destination - startPosition
    local maximumDistance = displacement:Length()
    if maximumDistance <= EPSILON then return nil end
    local direction = displacement / maximumDistance
    local sweptMinimum = Vector(
        math.min(startPosition.x + minimumHull.x, destination.x + minimumHull.x),
        math.min(startPosition.y + minimumHull.y, destination.y + minimumHull.y),
        math.min(startPosition.z + minimumHull.z, destination.z + minimumHull.z)
    )
    local sweptMaximum = Vector(
        math.max(startPosition.x + maximumHull.x, destination.x + maximumHull.x),
        math.max(startPosition.y + maximumHull.y, destination.y + maximumHull.y),
        math.max(startPosition.z + maximumHull.z, destination.z + maximumHull.z)
    )
    local minX, minY, minZ = MC.WorldToCell(sweptMinimum)
    local maxX, maxY, maxZ = MC.WorldToCell(sweptMaximum)
    if minX == nil or maxX == nil then return nil end
    local blockSize = MCITEM.BlockSize()
    local best

    for bx = minX, maxX do
        for by = minY, maxY do
            for bz = minZ, maxZ do
                local boxes = cellCollisionBoxes(bx, by, bz)
                if boxes then
                    local base = MC.CellWorldMin(bx, by, bz)
                    for _, box in ipairs(boxes) do
                        local boxMinimum = base + Vector(box[1], box[2], box[3]) * blockSize
                        local boxMaximum = base + Vector(box[4], box[5], box[6]) * blockSize
                        local originMinimum = boxMinimum - maximumHull
                        local originMaximum = boxMaximum - minimumHull
                        local distance, normal = Throwables.RayAABB(
                            startPosition,
                            direction,
                            maximumDistance,
                            originMinimum,
                            originMaximum
                        )
                        if distance and (not best or distance < best.Distance) then
                            best = {
                                Hit = true,
                                HitWorld = true,
                                HitMCBlock = true,
                                bx = bx,
                                by = by,
                                bz = bz,
                                StateId = MC.GetBlockState(bx, by, bz),
                                Entity = game.GetWorld(),
                                HitPos = sourceStart + direction * distance,
                                HitNormal = normal,
                                Distance = distance,
                                Fraction = distance / maximumDistance,
                            }
                        end
                    end
                end
            end
        end
    end
    return best
end

function Throwables.TraceMovementHull(startPosition, destination, minimumHull, maximumHull, filter, context)
    local displacement = destination - startPosition
    local maximumDistance = displacement:Length()
    if maximumDistance <= EPSILON then return { Hit = false, HitPos = destination } end
    -- GMod trace filter callbacks return true when the entity is eligible to
    -- be hit and false to skip it (the same convention used by MineMod's own
    -- projectile filter and BMB's safety traces).  The Minecraft voxel path
    -- is the authoritative block query, so Source broad-phase proxies are
    -- always skipped.  A single entity passed by callers (the XP orb is one
    -- example) means "ignore this entity", like util.TraceHull's native
    -- entity filter form.
    local sourceFilter
    if isfunction(filter) then
        sourceFilter = function(entity)
            if isWorldCollisionProxy(entity) then return false end
            return filter(entity)
        end
    elseif IsValid(filter) then
        sourceFilter = function(entity)
            return not isWorldCollisionProxy(entity) and entity ~= filter
        end
    elseif istable(filter) then
        sourceFilter = function(entity)
            if isWorldCollisionProxy(entity) then return false end
            for _, ignored in ipairs(filter) do
                if entity == ignored then return false end
            end
            return true
        end
    else
        sourceFilter = function(entity)
            return not isWorldCollisionProxy(entity)
        end
    end
    local source = util.TraceHull({
        start = startPosition,
        endpos = destination,
        mins = minimumHull,
        maxs = maximumHull,
        mask = MASK_SOLID_BRUSHONLY,
        filter = sourceFilter,
    })
    local best
    best = closestTrace(best, source.Hit and source or nil, startPosition, maximumDistance)
    best = closestTrace(
        best,
        minecraftHullTrace(startPosition, destination, minimumHull, maximumHull, context or (IsValid(filter) and filter or nil)),
        startPosition,
        maximumDistance
    )
    return best or { Hit = false, HitPos = destination, Fraction = 1, Distance = maximumDistance }
end

function Throwables.HullCollidesAt(position, minimumHull, maximumHull, context)
    local source = util.TraceHull({
        start = position,
        endpos = position,
        mins = minimumHull,
        maxs = maximumHull,
        mask = MASK_SOLID_BRUSHONLY,
        -- See TraceMovementHull above: false skips the collision proxies.
        filter = function(entity)
            return not isWorldCollisionProxy(entity)
        end,
    })
    if source.StartSolid or source.AllSolid then return true end
    if not MC or not isfunction(MC.WorldToCell) or not isfunction(MC.CellWorldMin) then return false end

    local world = worldPosition(position, context)
    local hullMinimum, hullMaximum = world + minimumHull, world + maximumHull
    local minX, minY, minZ = MC.WorldToCell(hullMinimum)
    local maxX, maxY, maxZ = MC.WorldToCell(hullMaximum)
    if minX == nil or maxX == nil then return false end
    local blockSize = MCITEM.BlockSize()
    for bx = minX, maxX do
        for by = minY, maxY do
            for bz = minZ, maxZ do
                local boxes = cellCollisionBoxes(bx, by, bz)
                if boxes then
                    local base = MC.CellWorldMin(bx, by, bz)
                    for _, box in ipairs(boxes) do
                        local blockMinimum = base + Vector(box[1], box[2], box[3]) * blockSize
                        local blockMaximum = base + Vector(box[4], box[5], box[6]) * blockSize
                        if boxesOverlap(hullMinimum, hullMaximum, blockMinimum, blockMaximum) then return true end
                    end
                end
            end
        end
    end
    return false
end

function Throwables.FluidKindAt(position, context)
    if not isvector(position) then return nil end
    if MC and isfunction(MC.WorldToCell) and isfunction(MC.GetBlockState)
        and isfunction(MC.LiquidStateMetrics)
    then
        local bx, by, bz = MC.WorldToCell(worldPosition(position, context))
        if bx ~= nil then
            local stateId = MC.GetBlockState(bx, by, bz) or 0
            local kind = MC.LiquidStateMetrics(stateId)
            if kind == "water" or kind == "lava" then return kind end
        end
    end
    if util and isfunction(util.PointContents) then
        local contents = util.PointContents(position)
        if CONTENTS_WATER and bit.band(contents, CONTENTS_WATER) ~= 0 then return "water" end
        if CONTENTS_SLIME and bit.band(contents, CONTENTS_SLIME) ~= 0 then return "water" end
        if CONTENTS_LAVA and bit.band(contents, CONTENTS_LAVA) ~= 0 then return "lava" end
    end
    return nil
end

function Throwables.LevelEventPosition(position, context)
    if not isvector(position) then return position end
    if MC and isfunction(MC.WorldToCell) and isfunction(MC.CellWorldMin) then
        local world = worldPosition(position, context)
        local bx, by, bz = MC.WorldToCell(world)
        if bx ~= nil then
            return MC.CellWorldMin(bx, by, bz) + Vector(0.5, 0.5, 0) * MCITEM.BlockSize() - (world - position)
        end
    end
    local blockSize = MCITEM.BlockSize()
    return Vector(
        (math.floor(position.x / blockSize) + 0.5) * blockSize,
        (math.floor(position.y / blockSize) + 0.5) * blockSize,
        math.floor(position.z / blockSize) * blockSize
    )
end
