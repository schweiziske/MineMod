-- Pure attribute queries derived from active Java 26.2 MobEffectInstances.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

if CLIENT then
    function Potions.GetEffect(entity, effectId)
        if not Potions.ClientEffects then return nil end
        effectId = Potions.NormalizeID(effectId)
        for _, effect in ipairs(Potions.ClientEffects(entity)) do
            if effect.id == effectId and (effect.infinite or not effect.expiresAt or effect.expiresAt > CurTime()) then
                return effect
            end
        end
    end

    function Potions.HasEffect(entity, effectId)
        return Potions.GetEffect(entity, effectId) ~= nil
    end
end

local function amplifier(entity, effectId)
    if not isfunction(Potions.GetEffect) then return nil end
    local effect = Potions.GetEffect(entity, effectId)
    return effect and math.max(0, math.floor(tonumber(effect.amplifier) or 0)) or nil
end

function Potions.GetMovementMultiplier(entity)
    -- Both modifiers are ADD_MULTIPLIED_TOTAL on MOVEMENT_SPEED, so they add
    -- against the base value rather than multiplying each other.
    local total = 1
    local speed = amplifier(entity, "speed")
    local slowness = amplifier(entity, "slowness")
    if speed then total = total + 0.2 * (speed + 1) end
    if slowness then total = total - 0.15 * (slowness + 1) end
    return math.max(0, total)
end

function Potions.GetAttackDamageBonus(entity)
    local total = 0
    local strength = amplifier(entity, "strength")
    local weakness = amplifier(entity, "weakness")
    if strength then total = total + 3 * (strength + 1) end
    if weakness then total = total - 4 * (weakness + 1) end
    return total
end

function Potions.GetResistanceMultiplier(entity)
    local resistance = amplifier(entity, "resistance")
    if not resistance then return 1 end
    return math.max(0, (25 - 5 * (resistance + 1)) / 25)
end

function Potions.GetJumpBoostPower(entity)
    local jumpBoost = amplifier(entity, "jump_boost")
    if not jumpBoost then return 0 end
    return 0.1 * (jumpBoost + 1)
end

-- The same usercmd must run the same movement formulas on both realms.
hook.Add("SetupMove", "MCITEM.Potions.PlayerAttributes", function(player, move)
    if not IsValid(player) then return end
    player.MCITEMPotionJumpPending = nil
    if not player:Alive() then return end
    local multiplier = Potions.GetMovementMultiplier(player)
    if multiplier ~= 1 then
        move:SetForwardSpeed(move:GetForwardSpeed() * multiplier)
        move:SetSideSpeed(move:GetSideSpeed() * multiplier)
        move:SetMaxSpeed(move:GetMaxSpeed() * multiplier)
        move:SetMaxClientSpeed(move:GetMaxClientSpeed() * multiplier)
    end

    local velocity = move:GetVelocity()
    local levitation = amplifier(player, "levitation")
    local gravityMultiplier = player:GetGravity()
    if gravityMultiplier == 0 then gravityMultiplier = 1 end
    local gravity = GetConVar("sv_gravity"):GetFloat() * gravityMultiplier
    local dt = engine.TickInterval()
    local walking = player:GetMoveType() == MOVETYPE_WALK and not player:InVehicle() and player:WaterLevel() < 2
    if walking and levitation then
        local target = 0.05 * (levitation + 1) * MCITEM.BlockSize() / Potions.TickSeconds
        velocity.z = Lerp(1 - 0.8 ^ (dt / Potions.TickSeconds), velocity.z, target) + gravity * dt
        move:SetVelocity(velocity)
    elseif walking and Potions.HasEffect(player, "slow_falling") and velocity.z < 0 then
        local targetGravity = 0.01 * MCITEM.BlockSize() / (Potions.TickSeconds * Potions.TickSeconds)
        velocity.z = velocity.z + math.max(0, gravity - targetGravity) * dt
        move:SetVelocity(velocity)
    end

    if walking and player:IsOnGround() and move:KeyPressed(IN_JUMP) then
        player.MCITEMPotionJumpPending = Potions.GetJumpBoostPower(player)
    end
    Potions.ApplyEnchantmentMovement(player, move)
end)

hook.Add("FinishMove", "MCITEM.Potions.PlayerJumpBoost", function(player, move)
    local boost = player.MCITEMPotionJumpPending or 0
    player.MCITEMPotionJumpPending = nil
    if boost <= 0 or not IsValid(player) or not player:Alive()
        or player:GetMoveType() ~= MOVETYPE_WALK or player:InVehicle() or player:WaterLevel() >= 2 then return end
    local velocity = move:GetVelocity()
    if velocity.z <= 0 then return end
    velocity.z = velocity.z + boost * MCITEM.BlockSize() / Potions.TickSeconds
    move:SetVelocity(velocity)
end)

hook.Remove("SetupMove", "MCITEM.Enchantments.Movement")
function Potions.ApplyEnchantmentMovement(player, move)
    if not IsValid(player) or not player:Alive() then return end
    local parameters
    if SERVER then parameters = hook.Run("MCITEM.EnchantmentMovementParameters", player) end
    parameters = parameters or player:GetNW2Vector("MCITEMMovementEnchantments", vector_origin)
    local maximum, clientMaximum = move:GetMaxSpeed(), move:GetMaxClientSpeed()
    local desired = maximum
    if parameters.x > 0 and player:WaterLevel() > 0 then
        local land = move:KeyDown(IN_SPEED) and player:GetRunSpeed() or player:GetWalkSpeed()
        desired = Lerp(math.min(parameters.x / 3, 1), desired, math.max(desired, land))
    end
    if parameters.y > 0 and (player:Crouching() or move:KeyDown(IN_DUCK)) then
        desired = math.max(desired, player:GetWalkSpeed() * math.min(1, 0.3 + 0.15 * parameters.y))
    end
    if parameters.z > 0 then
        desired = desired * (1 + (0.0405 + 0.0105 * (parameters.z - 1)) / 0.1)
    end
    if desired ~= maximum then
        move:SetMaxSpeed(desired)
        move:SetMaxClientSpeed(math.max(clientMaximum, desired))
    end
end
