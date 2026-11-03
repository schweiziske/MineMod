-- Shared Minecraft Java 26.2 ServerExplosion entity/exposure port.
--
-- This module is intentionally independent from potions and throwable items:
-- Wind Charged deaths and Wind Charge projectiles use the same vanilla damage,
-- visibility and knockback rules, while callers provide their own particles,
-- sounds, block-trigger behavior and compatibility hooks.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Explosions = MCITEM.Explosions or {}

local Explosions = MCITEM.Explosions
if Explosions.CoreVersion == 2 then return end
Explosions.CoreVersion = 2
Explosions.CoreLoaded = true

local TRACE_EPSILON = 1e-7

local function rayBoxDistance(startPosition, direction, maximumDistance, minimum, maximum)
    local lower, upper = 0, maximumDistance
    local function clipAxis(origin, delta, low, high)
        if math.abs(delta) <= TRACE_EPSILON then
            return origin >= low and origin <= high
        end
        local first = (low - origin) / delta
        local second = (high - origin) / delta
        if first > second then first, second = second, first end
        lower = math.max(lower, first)
        upper = math.min(upper, second)
        return upper >= lower
    end

    if not clipAxis(startPosition.x, direction.x, minimum.x, maximum.x) then return nil end
    if not clipAxis(startPosition.y, direction.y, minimum.y, maximum.y) then return nil end
    if not clipAxis(startPosition.z, direction.z, minimum.z, maximum.z) then return nil end
    return lower
end

local function axisStep(origin, direction, cellMinimum, blockSize)
    if direction > TRACE_EPSILON then
        return 1, (cellMinimum + blockSize - origin) / direction, blockSize / direction
    end
    if direction < -TRACE_EPSILON then
        return -1, (cellMinimum - origin) / direction, -blockSize / direction
    end
    return 0, math.huge, math.huge
end

local function apiMinecraftTrace(startPosition, direction, maximumDistance)
    local world = MC and MC.API and MC.API.World
    if world and isfunction(world.TraceRay) then
        local hit = world.TraceRay(startPosition, direction, maximumDistance)
        if hit and hit.Hit == true then return true end
    end
    if MC and isfunction(MC.TraceBlockRay) then
        local hit = MC.TraceBlockRay(startPosition, direction, maximumDistance)
        if hit and hit.Hit == true then return true end
    end
    if MC and isfunction(MC.TraceBlockCollisionRay) then
        local hit = MC.TraceBlockCollisionRay(startPosition, direction, maximumDistance)
        if hit and hit.Hit == true then return true end
    end
    return false
end

local function hitsMinecraftCollision(startPosition, endPosition)
    if not MC or not isfunction(MC.WorldToCell) or not isfunction(MC.CellWorldMin)
        or not isfunction(MC.GetBlockState)
    then
        return false
    end

    local displacement = endPosition - startPosition
    local maximumDistance = displacement:Length()
    if maximumDistance <= TRACE_EPSILON then return false end
    local direction = displacement / maximumDistance

    if apiMinecraftTrace(startPosition, direction, maximumDistance) then return true end

    -- Compatibility fallback for older MineMod builds without TraceBlockRay.
    local bx, by, bz = MC.WorldToCell(startPosition)
    if bx == nil then return false end
    local blockSize = MCITEM.BlockSize()
    local cellMinimum = MC.CellWorldMin(bx, by, bz)
    local stepX, nextX, deltaX = axisStep(startPosition.x, direction.x, cellMinimum.x, blockSize)
    local stepY, nextY, deltaY = axisStep(startPosition.y, direction.y, cellMinimum.y, blockSize)
    local stepZ, nextZ, deltaZ = axisStep(startPosition.z, direction.z, cellMinimum.z, blockSize)
    local maximumSteps = math.ceil(maximumDistance / blockSize) * 3 + 8

    for _ = 1, maximumSteps do
        local stateId = MC.GetBlockState(bx, by, bz) or 0
        if stateId ~= 0 then
            local hasCollision = not isfunction(MC.BlockHasCollisionForState)
                or MC.BlockHasCollisionForState(stateId, bx, by, bz) == true
            if hasCollision then
                local boxes = isfunction(MC.GetCellCollisionBoxes)
                    and MC.GetCellCollisionBoxes(bx, by, bz) or nil
                if boxes and boxes[1] then
                    local base = MC.CellWorldMin(bx, by, bz)
                    for _, box in ipairs(boxes) do
                        local minimum = base + Vector(box[1], box[2], box[3]) * blockSize
                        local maximum = base + Vector(box[4], box[5], box[6]) * blockSize
                        if rayBoxDistance(startPosition, direction, maximumDistance, minimum, maximum) then
                            return true
                        end
                    end
                elseif isfunction(MC.BlockIsFullCubeForState)
                    and MC.BlockIsFullCubeForState(stateId, bx, by, bz) == true
                then
                    local minimum = MC.CellWorldMin(bx, by, bz)
                    local maximum = minimum + Vector(blockSize, blockSize, blockSize)
                    if rayBoxDistance(startPosition, direction, maximumDistance, minimum, maximum) then
                        return true
                    end
                end
            end
        end

        if nextX <= nextY and nextX <= nextZ then
            if nextX > maximumDistance then break end
            bx = bx + stepX
            nextX = nextX + deltaX
        elseif nextY <= nextZ then
            if nextY > maximumDistance then break end
            by = by + stepY
            nextY = nextY + deltaY
        else
            if nextZ > maximumDistance then break end
            bz = bz + stepZ
            nextZ = nextZ + deltaZ
        end
    end
    return false
end

local function segmentBlocked(startPosition, endPosition, context)
    local brush = util.TraceLine({
        start = startPosition,
        endpos = endPosition,
        mask = MASK_SOLID_BRUSHONLY,
    })
    if brush.Hit then return true end
    local coords = MC and MC.API and MC.API.Coords
    if coords then
        startPosition = coords.EngineToWorld(startPosition, context)
        endPosition = coords.EngineToWorld(endPosition, context)
    end
    return hitsMinecraftCollision(startPosition, endPosition)
end

function Explosions.Exposure(origin, target, context)
    if not isvector(origin) or not IsValid(target) then return 0 end

    if isfunction(target.GetMCExplosionExposure) then
        local value = target:GetMCExplosionExposure(origin, context)
        if isnumber(value) then return math.Clamp(value, 0, 1) end
    end
    local overridden = hook.Run("MCITEM.ExplosionExposure", origin, target, context)
    if isnumber(overridden) then return math.Clamp(overridden, 0, 1) end

    local minimum, maximum = target:WorldSpaceAABB()
    local size = maximum - minimum
    local blockSize = MCITEM.BlockSize()

    -- ServerExplosion.getSeenPercent samples 1 / (extent * 2 + 1).
    -- Minecraft X/Z are Source X/Y, so both horizontal axes receive the
    -- centering offset while Source Z (Minecraft Y) deliberately does not.
    local stepX = 1 / (size.x / blockSize * 2 + 1)
    local stepY = 1 / (size.y / blockSize * 2 + 1)
    local stepZ = 1 / (size.z / blockSize * 2 + 1)
    if stepX < 0 or stepY < 0 or stepZ < 0 then return 0 end
    local offsetX = (1 - math.floor(1 / stepX) * stepX) / 2
    local offsetY = (1 - math.floor(1 / stepY) * stepY) / 2

    local visible, total = 0, 0
    local x = 0
    while x <= 1 do
        local y = 0
        while y <= 1 do
            local z = 0
            while z <= 1 do
                local sample = Vector(
                    Lerp(x, minimum.x, maximum.x) + offsetX * blockSize,
                    Lerp(y, minimum.y, maximum.y) + offsetY * blockSize,
                    Lerp(z, minimum.z, maximum.z)
                )
                if not segmentBlocked(sample, origin, target) then visible = visible + 1 end
                total = total + 1
                z = z + stepZ
            end
            y = y + stepY
        end
        x = x + stepX
    end
    return total > 0 and visible / total or 0
end

function Explosions.GetKnockbackResistance(target, context)
    if not IsValid(target) then return 0 end
    local value
    if isfunction(target.GetMCExplosionKnockbackResistance) then
        value = target:GetMCExplosionKnockbackResistance(context)
    end
    if value == nil then
        value = hook.Run("MCITEM.GetExplosionKnockbackResistance", target, context)
    end
    if value == nil then
        value = tonumber(target.ExplosionKnockbackResistance)
            or tonumber(target.KnockbackResistance)
    end
    return math.Clamp(tonumber(value) or 0, 0, 1)
end

function Explosions.ApplyDamage(target, amount, attacker, inflictor, origin, context)
    if not IsValid(target) or amount <= 0 then return false end
    if isfunction(target.ApplyMCExplosionDamage) then
        local handled = target:ApplyMCExplosionDamage(amount, attacker, origin, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.ExplosionDamage", target, amount, attacker, origin, context)
    if handled ~= nil then return handled ~= false end
    if isstring(context and context.damageHook) then
        handled = hook.Run(context.damageHook, target, amount, attacker, origin, context)
        if handled ~= nil then return handled ~= false end
    end

    attacker = IsValid(attacker) and attacker or game.GetWorld()
    inflictor = IsValid(inflictor) and inflictor or attacker
    local damage = DamageInfo()
    damage:SetDamage(amount)
    damage:SetDamageType(context and context.damageType or bit.bor(DMG_BLAST, DMG_PREVENT_PHYSICS_FORCE or 0))
    damage:SetAttacker(attacker)
    damage:SetInflictor(inflictor)
    damage:SetDamagePosition(origin)
    damage:SetDamageForce(vector_origin)
    target:TakeDamageInfo(damage)
    return true
end

function Explosions.ApplyKnockback(target, velocity, context)
    if not IsValid(target) or velocity:LengthSqr() <= 0 then return false end
    if isfunction(target.ApplyMCExplosionKnockback) then
        local handled = target:ApplyMCExplosionKnockback(velocity, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.ExplosionKnockback", target, velocity, context)
    if handled ~= nil then return handled ~= false end
    if isstring(context and context.knockbackHook) then
        handled = hook.Run(context.knockbackHook, target, velocity, context)
        if handled ~= nil then return handled ~= false end
    end

    local scale = tonumber(context and context.velocityScale)
    if scale == nil then
        scale = isfunction(MCITEM.KnockbackScale) and MCITEM.KnockbackScale() or 1
    end
    scale = math.max(0, tonumber(scale) or 0)
    velocity = velocity * scale
    if isfunction(target.StartBMBExternalImpulse)
        and target:StartBMBExternalImpulse(velocity, {
            reason = context and context.kind or "explosion",
            duration = tonumber(context and context.externalImpulseDuration) or 0.12,
            useJump = context == nil or context.externalImpulseUseJump ~= false,
        }) then
        -- BMB movement coroutines overwrite one-frame loco velocity writes.
        -- Its external-impulse boundary keeps this additive force authoritative.
    elseif target:IsPlayer() then
        target:SetVelocity(velocity) -- Player SetVelocity is additive.
    elseif target.loco and isfunction(target.loco.SetVelocity) then
        target.loco:SetVelocity(target:GetVelocity() + velocity)
    elseif isfunction(target.SetVelocity) then
        target:SetVelocity(target:GetVelocity() + velocity)
    else
        return false
    end
    return true
end

local function entityEyePosition(target)
    if isfunction(target.EyePos) then return target:EyePos() end
    return target:WorldSpaceCenter()
end

local function copyContext(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

function Explosions.Explode(configuration)
    configuration = configuration or {}
    local position = configuration.position
    local strength = math.max(0, tonumber(configuration.strength) or 0)
    if not isvector(position) or strength <= 0 then return {} end

    local context = copyContext(configuration.context)
    context.position = position
    context.strength = strength
    context.diameter = strength * 2
    context.source = configuration.source
    context.attacker = configuration.attacker
    context.inflictor = configuration.inflictor
    context.damageEntities = configuration.damageEntities ~= false
    context.knockbackMultiplier = configuration.knockbackMultiplier

    local diameter = context.diameter
    local radius = diameter * MCITEM.BlockSize()
    local extent = Vector(radius, radius, radius)
    local affected = {}

    for _, target in ipairs(ents.FindInBox(position - extent, position + extent)) do
        local ignored = not IsValid(target) or target:IsWorld()
            or target == configuration.ignoreEntity
            or target == configuration.projectile
        if not ignored and isfunction(configuration.ignore) then
            ignored = configuration.ignore(target, context) == true
        end
        if not ignored then
            local distance = target:GetPos():Distance(position) / MCITEM.BlockSize()
            if distance <= diameter then
                local direction = entityEyePosition(target) - position
                if direction:LengthSqr() > 0 then direction:Normalize() end
                local exposure = isfunction(configuration.exposure)
                    and configuration.exposure(position, target, context)
                    or Explosions.Exposure(position, target, context)
                exposure = math.Clamp(tonumber(exposure) or 0, 0, 1)
                local impact = (1 - distance / diameter) * exposure
                if impact > 0 then
                    -- ServerExplosion.hurtEntities: no floor/round operation.
                    local computedDamage = ((impact * impact + impact) / 2) * 7 * diameter + 1
                    local targetContext = copyContext(context)
                    targetContext.target = target
                    targetContext.distance = distance
                    targetContext.exposure = exposure
                    targetContext.impact = impact
                    targetContext.computedDamage = computedDamage
                    targetContext.damage = context.damageEntities and computedDamage or 0

                    if context.damageEntities then
                        Explosions.ApplyDamage(
                            target,
                            computedDamage,
                            configuration.attacker or configuration.source,
                            configuration.inflictor or configuration.projectile or configuration.source,
                            position,
                            targetContext
                        )
                    end

                    local knockbackMultiplier = configuration.knockbackMultiplier
                    if isfunction(knockbackMultiplier) then
                        knockbackMultiplier = knockbackMultiplier(target, targetContext)
                    end
                    knockbackMultiplier = math.max(0, tonumber(knockbackMultiplier) or 1)
                    targetContext.knockbackMultiplier = knockbackMultiplier
                    local resistance = Explosions.GetKnockbackResistance(target, targetContext)
                    local velocity = direction * (
                        impact * knockbackMultiplier * (1 - resistance)
                            * MCITEM.BlockSize() / (1 / 20)
                    )
                    Explosions.ApplyKnockback(target, velocity, targetContext)
                    affected[#affected + 1] = targetContext
                end
            end
        end
    end

    hook.Run("MCITEM.ExplosionFinished", context, affected)
    return affected, context
end
