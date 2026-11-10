-- Wind movement is committed through MoveData. Weapon callbacks can run while
-- Source already has a movement snapshot, which would overwrite SetAbsVelocity.
if not SERVER then return end

MCITEM.WindImpulse = MCITEM.WindImpulse or {}
local Wind = MCITEM.WindImpulse
Wind.Pending = Wind.Pending or setmetatable({}, { __mode = "k" })
Wind.FallOrigins = Wind.FallOrigins or setmetatable({}, { __mode = "k" })

local function feetZ(player, position)
    position = position or player:GetPos()
    local coords = MC and MC.API and MC.API.Coords
    if coords and coords.EngineToWorld then position = coords.EngineToWorld(position, player) end
    return position.z -- Stable MC world coordinates, in Source units.
end

function Wind.ArmFallProtection(player, preserveLowerOrigin)
    if not IsValid(player) or not player:IsPlayer() then return end
    local previous = Wind.FallOrigins[player]
    local z = feetZ(player)
    local origin = z
    if preserveLowerOrigin and previous then origin = math.min(origin, previous.originZ) end
    Wind.FallOrigins[player] = {
        originZ = origin,
        apexZ = z,
        graceUntil = math.max(previous and previous.graceUntil or 0, CurTime() + 2),
        airborne = not player:IsOnGround(),
    }
end

function Wind.Gravity(target)
    local multiplier = target.GetGravity and target:GetGravity() or 1
    if multiplier == 0 then multiplier = 1 end
    return math.max(0, GetConVar("sv_gravity"):GetFloat() * multiplier)
end

-- Java LivingEntity: move by delta, then (deltaY - 0.08) * 0.98 each tick.
-- Input is blocks/tick; output is blocks. Only evaluated at an impulse.
function Wind.JavaRise(velocity)
    if velocity <= 0 then return 0 end
    local ticks = math.ceil(math.log(3.92 / (velocity + 3.92)) / math.log(0.98))
    return math.max(0, (velocity + 3.92) * (1 - 0.98 ^ ticks) / 0.02 - 3.92 * ticks)
end

function Wind.ConvertVelocity(target, velocity, scale)
    if scale ~= nil then return velocity * math.max(0, scale) end
    local blockSize = MCITEM.BlockSize()
    local gravity = Wind.Gravity(target)
    if gravity <= 0 then return velocity end
    local horizontalScale = math.sqrt(gravity / (32 * blockSize))
    local vertical = velocity.z / (20 * blockSize)
    local sign = vertical < 0 and -1 or 1
    return Vector(velocity.x * horizontalScale, velocity.y * horizontalScale,
        sign * math.sqrt(2 * gravity * blockSize * Wind.JavaRise(math.abs(vertical))))
end

function Wind.ResetPlayerVertical(player, velocityZ)
    if not IsValid(player) or not player:IsPlayer() then return false end
    -- Keep a smash reset and its enchantment impulse in the same transaction.
    local pending = Wind.Pending[player]
    Wind.Pending[player] = {
        x = pending and pending.x or 0, y = pending and pending.y or 0,
        z = velocityZ, replaceZ = true,
    }
    return true
end

function Wind.QueuePlayerImpulse(player, velocity, replaceZ)
    if not IsValid(player) or not player:IsPlayer() then return false end
    local pending = Wind.Pending[player]
    if not pending then
        pending = { x = 0, y = 0, z = 0 }
        Wind.Pending[player] = pending
    end
    pending.x = pending.x + velocity.x
    pending.y = pending.y + velocity.y
    if replaceZ then
        pending.z = velocity.z
        pending.replaceZ = true
    else
        pending.z = pending.z + velocity.z
    end
    return true
end

local function applyPending(player, move)
    local pending = Wind.Pending[player]
    if not pending then return end
    Wind.Pending[player] = nil
    if not player:Alive() or player:GetMoveType() ~= MOVETYPE_WALK or player:InVehicle() then return end
    local current = move:GetVelocity()
    local z = pending.replaceZ and pending.z or current.z + pending.z
    if z > 0 then player:SetGroundEntity(NULL) end
    move:SetVelocity(Vector(current.x + pending.x, current.y + pending.y, z))
    local state = Wind.FallOrigins[player]
    if state then state.launchSerial = (state.launchSerial or 0) + 1 end
end

-- Consume once: SetupMove for projectile Think, FinishMove for weapon attacks
-- that occur after SetupMove. Never write the impulse into Source basevelocity.
hook.Add("SetupMove", "MCITEM.WindImpulse.Apply", applyPending)
hook.Add("FinishMove", "MCITEM.WindImpulse.Apply", applyPending)

function Wind.Clear(player)
    Wind.Pending[player] = nil
    Wind.FallOrigins[player] = nil
end

hook.Add("PlayerSpawn", "MCITEM.WindImpulse.Clear", Wind.Clear)
hook.Add("PlayerDeath", "MCITEM.WindImpulse.Clear", Wind.Clear)
hook.Add("PlayerDisconnected", "MCITEM.WindImpulse.Clear", Wind.Clear)

local function clearFallAfterLanding(player, state)
    if state.clearScheduled then return end
    state.clearScheduled = true
    local serial = state.launchSerial or 0
    timer.Simple(0, function()
        -- A later charge/smash in this same frame owns a different context.
        if Wind.FallOrigins[player] ~= state then return end
        -- Source can report contact before FinishMove consumes a smash launch.
        if (state.launchSerial or 0) ~= serial and IsValid(player) and not player:IsOnGround() then
            state.clearScheduled = nil
            return
        end
        Wind.FallOrigins[player] = nil
    end)
end

local function currentFallDistance(player, state)
    if state.landedAt == CurTime() then return state.landedDistance end
    local z = feetZ(player)
    return math.max(0, math.min(state.apexZ - z, state.originZ - z)) / MCITEM.BlockSize()
end

local function damageForDistance(player, distance)
    local potions = MCITEM.Potions
    if potions and potions.HasEffect
        and (potions.HasEffect(player, "slow_falling") or potions.HasEffect(player, "levitation")) then
        return 0
    end
    if player:WaterLevel() > 0 or (MC and MC.LiquidMoveContacts and MC.LiquidMoveContacts[player])
        or (MC and MC.PlayerLiquidContact and MC.PlayerLiquidContact(player)) then return 0 end
    local modifier = 1
    local physics = MC and MC.BlockPhysics
    if physics and physics.Enabled() then
        local sample = physics.SampleEntity(player)
        if sample and sample.onName == "minecraft:slime_block" then return 0 end
        if sample and sample.onName == "minecraft:honey_block" then
            modifier = physics.Constants.honeyFallDamageModifier
        end
    end
    local jumpBoost = potions and potions.GetEffect and potions.GetEffect(player, "jump_boost")
    local safeDistance = 3 + (jumpBoost and ((jumpBoost.amplifier or 0) + 1) or 0)
    -- Java 26.2 calculateFallPower/calculateFallDamage use epsilon then floor.
    return MCITEM.ScaleDamage(math.max(0, math.floor((distance + 1e-6 - safeDistance) * modifier)))
end

function Wind.FallDamage(player)
    local state = Wind.FallOrigins[player]
    if not state then return nil end
    local distance = currentFallDistance(player, state)
    local damage = damageForDistance(player, distance)
    if distance <= 0 or damage > 0 or CurTime() >= state.graceUntil then
        clearFallAfterLanding(player, state)
    end
    return damage
end

hook.Add("GetFallDamage", "MCITEM.WindImpulse.Fall", function(player)
    return Wind.FallDamage(player)
end)

-- Some gamemodes construct DMG_FALL without calling GetFallDamage. Bound the
-- damage there too, while preserving earlier mitigation and non-fall damage.
hook.Add("EntityTakeDamage", "MCITEM.WindImpulse.Fall", function(player, damage)
    if not Wind.FallOrigins[player] or not damage:IsDamageType(DMG_FALL) then return end
    local value = Wind.FallDamage(player)
    damage:SetDamage(math.min(damage:GetDamage(), value))
    if value == 0 then
        damage:SetDamageForce(vector_origin)
        return true
    end
end)

hook.Add("SetupMove", "MCITEM.WindImpulse.TrackFall", function(player, move)
    local state = Wind.FallOrigins[player]
    if not state then return end
    if not player:Alive() then Wind.Clear(player) return end
    local z = feetZ(player, move:GetOrigin())
    state.apexZ = math.max(state.apexZ, z)
    if not player:IsOnGround() then state.airborne = true end
    if Wind.Pending[player] then return end
    local resting = player:IsOnGround()
        or (player:WaterLevel() >= 2 and move:GetVelocity().z <= 0)
        or player:GetMoveType() ~= MOVETYPE_WALK or player:InVehicle()
    if resting and CurTime() >= state.graceUntil then clearFallAfterLanding(player, state) end
end)

hook.Add("OnPlayerHitGround", "MCITEM.WindImpulse.Fall", function(player)
    -- Also consume protection for gentle landings that produce no damage call.
    local state = Wind.FallOrigins[player]
    if not state then return end
    state.landedDistance = currentFallDistance(player, state)
    state.landedAt = CurTime()
    Wind.FallDamage(player)
    -- Grace can preserve the impulse origin across a harmless short landing,
    -- but the next descent has its own fall distance. Keep this landing cached
    -- for GetFallDamage/EntityTakeDamage callbacks later in the same tick.
    state.apexZ = feetZ(player)
end)
