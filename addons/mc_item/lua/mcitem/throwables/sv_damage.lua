-- Server damage, compatibility-spawn and Wind Charge explosion adapters.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

Throwables.Behaviors = Throwables.Behaviors or {}

function Throwables.RegisterBehavior(identifier, behavior)
    if not isstring(identifier) or not istable(behavior) then return false end
    Throwables.Behaviors[identifier] = behavior
    return true
end

function Throwables.Behavior(identifier)
    return isstring(identifier) and Throwables.Behaviors[identifier] or nil
end

function Throwables.HandleProjectileHit(projectile, trace)
    if not IsValid(projectile) then return true end
    local behavior = Throwables.Behavior(projectile.MCThrowableBehavior or projectile:GetThrowableBehavior())
    if not behavior or not isfunction(behavior.OnHit) then return true end
    return behavior.OnHit(projectile, trace) ~= false
end

-- Projectile.canHitEntity ultimately delegates to Entity.canBeHitByProjectile:
-- alive, pickable and non-spectating. Source props and MineMod chunk entities do
-- not represent living Minecraft entities, so they must follow the block-hit
-- path and must never receive the Wind Charge's direct one-point damage.
function Throwables.IsProjectileTarget(target)
    if isfunction(MCITEM.IsProjectileTarget) then
        return MCITEM.IsProjectileTarget(target)
    end
    if not IsValid(target) or target == game.GetWorld() or target.BMBDead then return false end
    if not (target:IsPlayer() or target:IsNPC() or target:IsNextBot() or target.IsBMBMob == true) then
        return false
    end
    return target:Health() > 0
end

-- LivingEntity.hurtServer establishes a 20-tick damage cooldown even when the
-- incoming amount is zero.  GMod has no equivalent field on players/NPCs, so
-- keep a projectile-only cooldown on the target.  BMB already owns its normal
-- damage cooldown; its field is consulted as well instead of creating a second
-- incompatible timer.
local THROWABLE_INVULNERABILITY_TICKS = 20
local THROWABLE_INVULNERABILITY_SECONDS = THROWABLE_INVULNERABILITY_TICKS * Throwables.TickSeconds

function Throwables.IsThrowableInvulnerable(target, context)
    if not IsValid(target) then return true end
    if context and context.ignoreInvulnerability == true then return false end
    local ignoreBMBInvulnerability = context
        and context.ignoreBMBDamageInvulnerability == true
    if not ignoreBMBInvulnerability
        and isfunction(target.IsBMBInDamageInvulnerability)
        and target:IsBMBInDamageInvulnerability() then
        return true
    end
    return CurTime() < (tonumber(target.MCITEMThrowableInvulnerableUntil) or 0)
end

function Throwables.MarkThrowableInvulnerability(target, context)
    if not IsValid(target) then return false end
    local untilTime = CurTime() + THROWABLE_INVULNERABILITY_SECONDS
    target.MCITEMThrowableInvulnerableUntil = untilTime
    if isfunction(target.SetNWFloat) then
        target:SetNWFloat("MCITEMThrowableInvulnerableUntil", untilTime)
    end
    hook.Run("MCITEM.ThrowableInvulnerabilityStarted", target, untilTime, context)
    return true
end

local function projectileHorizontalDirection(projectile, target)
    local velocity = IsValid(projectile) and projectile.MCProjectileVelocity or vector_origin
    -- GMod and the Minecraft adapter both use x/y as the horizontal plane and
    -- z as vertical.  Do not swap y/z here: that would turn a forward throw
    -- into a sideways push on one axis.
    local direction = isvector(velocity) and Vector(velocity.x, velocity.y, 0) or vector_origin
    if direction:LengthSqr() <= 1e-8 and IsValid(projectile) and IsValid(target) then
        direction = target:WorldSpaceCenter() - projectile:GetPos()
        direction.z = 0
    end
    if direction:LengthSqr() <= 1e-8 then return nil end
    direction:Normalize()
    return direction
end

local function projectileImpactDamageInfo(projectile, target)
    local direction = projectileHorizontalDirection(projectile, target)
    local damage = DamageInfo()
    damage:SetDamage(0)
    damage:SetDamageType(DMG_GENERIC)
    damage:SetAttacker(IsValid(projectile:GetOwner()) and projectile:GetOwner() or game.GetWorld())
    damage:SetInflictor(projectile)
    damage:SetDamagePosition(projectile:GetPos())
    damage:SetDamageForce(direction and direction * MCITEM.BlockSize() * 20 or vector_origin)
    return damage, direction
end

-- Java's LivingEntity.dealDefaultKnockback is also reached by hurt(0): the
-- strength is the fixed 0.4 value, while the projectile's horizontal movement
-- supplies the push direction.  BMB mobs have their own movement/knockback
-- state machine, so feed them a zero-damage DamageInfo and let that state
-- machine perform the same transition rather than stacking Source velocity.
function Throwables.ApplyProjectileKnockback(projectile, target, context)
    if not IsValid(projectile) or not IsValid(target) then return false end
    if context and context.applyKnockback == false then return false end
    local damageInfo, direction = projectileImpactDamageInfo(projectile, target)
    if not direction then return false end

    if target.IsBMBMob == true or isfunction(target.StartBMBKnockback) then
        if isfunction(target.StartBMBKnockback) then
            return target:StartBMBKnockback(damageInfo) ~= false
        end
        return false
    end

    local scale = isfunction(MCITEM.KnockbackScale) and MCITEM.KnockbackScale() or 1
    if scale <= 0 or not isfunction(target.SetVelocity) then return false end
    local strength = 0.4
    local blocksPerSecond = MCITEM.BlockSize() * 20 * scale
    local current = target.GetVelocity and target:GetVelocity() or vector_origin
    local grounded = target.IsOnGround and target:IsOnGround() or false
    local result = Vector(
        current.x / 2 + direction.x * strength * blocksPerSecond,
        current.y / 2 + direction.y * strength * blocksPerSecond,
        grounded
            and math.min(0.4 * blocksPerSecond, current.z / 2 + strength * blocksPerSecond)
            or current.z
    )
    if target:IsPlayer() then
        if grounded and target.SetGroundEntity then target:SetGroundEntity(NULL) end
        target:SetVelocity(-current)
        target:SetVelocity(result)
    else
        if grounded and target.SetGroundEntity then target:SetGroundEntity(NULL) end
        target:SetVelocity(result)
    end
    return true
end

local function applyBuiltInProjectileImpactFeedback(projectile, target, context)
    Throwables.MarkThrowableInvulnerability(target, context)
    -- Java clients show the hurt flash for mobs, but not for players hit by a
    -- zero-damage throwable. BMB exposes the corresponding visual entry points.
    if not target:IsPlayer() and isfunction(target.StartBMBHurtFlash) then
        target:StartBMBHurtFlash()
    end
    if target.IsBMBMob == true and isfunction(target.OnBMBHurtSound) then
        local damageInfo = projectileImpactDamageInfo(projectile, target)
        target:OnBMBHurtSound(damageInfo)
    end
    Throwables.ApplyProjectileKnockback(projectile, target, context)
    if target.IsBMBMob == true and isfunction(target.PlayBMBAnimation) then
        target:PlayBMBAnimation("hurt")
    end
    hook.Run("MCITEM.ThrowableZeroDamageHit", target, projectile, context.damageSource, context)
    return true
end

function Throwables.ApplyProjectileImpactFeedback(projectile, target, context)
    if not IsValid(target) then return false end
    context = context or {}
    if Throwables.IsThrowableInvulnerable(target, context) then return false end
    local custom = isfunction(target.ApplyMCThrowableImpact)
        and target:ApplyMCThrowableImpact(projectile, context)
    if custom ~= nil then return custom ~= false end
    local hooked = hook.Run("MCITEM.ThrowableImpact", target, projectile, context)
    if hooked ~= nil then return hooked ~= false end
    return applyBuiltInProjectileImpactFeedback(projectile, target, context)
end

function Throwables.ApplyBMBZeroDamageImpact(projectile, target, context)
    if not IsValid(projectile) or not IsValid(target) or target.IsBMBMob ~= true then return false end
    context = context or {}
    -- BMB's normal damage iframe belongs to positive damage. Snowballs and
    -- eggs still need their zero-damage entity event, but retain MCITEM's own
    -- 20-tick projectile cooldown so rapid impacts cannot spam the state.
    context.ignoreBMBDamageInvulnerability = true
    if Throwables.IsThrowableInvulnerable(target, context) then return false end
    return applyBuiltInProjectileImpactFeedback(projectile, target, context)
end

-- Notification only: it never consumes or changes the ordinary damage path.
-- Integrations use this for Java's zero-damage projectile contacts, where a
-- neutral mob must still remember the real thrower even though Source has no
-- positive DamageInfo to deliver. Positive hits remain owned by OnTakeDamage so
-- BMB does not retaliate twice.
function Throwables.NotifyProjectileEntityHit(projectile, target, amount, damageSource, context)
    if not IsValid(projectile) or not IsValid(target) then return false end
    context = context or {}
    if context.projectileEntityHitNotified == true then return false end
    context.projectileEntityHitNotified = true

    local owner = context.owner
    if isfunction(target.OnMCProjectileHit) then
        target:OnMCProjectileHit(owner, projectile, damageSource, amount, context)
    end
    hook.Run("MCITEM.ProjectileHitEntity", target, projectile, owner, damageSource, amount, context)
    return true
end

-- Notification-only world/non-living impact boundary.  The generic projectile
-- still delegates all behavior/removal decisions to HandleProjectileHit; this
-- hook only exposes the Java game-event-style landing point to integrations.
function Throwables.NotifyProjectileLanded(projectile, trace, context)
    if not IsValid(projectile) or not istable(trace) then return false end
    context = context or {}
    if context.projectileLandedNotified == true
        or projectile.MCITEMProjectileLandedNotified == true then return false end
    context.projectileLandedNotified = true
    projectile.MCITEMProjectileLandedNotified = true
    context.owner = context.owner or projectile:GetOwner()
    context.position = trace.HitPos or projectile:GetPos()
    context.normal = trace.HitNormal
    context.entity = trace.Entity
    hook.Run("MCITEM.ProjectileLanded", projectile, trace, context.owner, context)
    return true
end

function Throwables.ApplyProjectileDamage(projectile, target, amount, damageSource, context)
    if not IsValid(projectile) or not IsValid(target) or target:IsWorld() then return false end
    amount = math.max(0, tonumber(amount) or 0)
    context = context or {}
    context.projectile = projectile
    context.owner = projectile:GetOwner()
    context.target = target
    context.damageSource = damageSource
    context.amount = amount

    -- This must precede every early return below, including BMB's specialized
    -- zero-damage feedback and the throwable invulnerability window.
    Throwables.NotifyProjectileEntityHit(projectile, target, amount, damageSource, context)

    -- Snowballs and eggs still enter LivingEntity.hurt with zero damage in
    -- Java. BMB's normal damage iframe would otherwise discard that visual and
    -- knockback-only hit, so bypass only that iframe while retaining MCITEM's
    -- own 20-tick throwable cooldown below.
    if amount <= 0 and context.zeroDamageImpact == true and target.IsBMBMob == true then
        return Throwables.ApplyBMBZeroDamageImpact(projectile, target, context)
    end

    if Throwables.IsThrowableInvulnerable(target, context) then return false end

    if isfunction(target.ApplyMCThrowableDamage) then
        local handled = target:ApplyMCThrowableDamage(amount, context.owner, projectile, damageSource, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run(
        "MCITEM.ThrowableDamage",
        target,
        amount,
        context.owner,
        projectile,
        damageSource,
        context
    )
    if handled ~= nil then return handled ~= false end

    if amount <= 0 then
        -- Java's zero-damage LivingEntity.hurt path is intentionally used only
        -- by snowballs and eggs.  Ender pearls carry the no_knockback damage
        -- type, and experience bottles do not call hurt on an entity at all;
        -- their hit merely spawns XP.  Callers opt in explicitly so future
        -- projectile types cannot accidentally inherit the feedback.
        if context.zeroDamageImpact == true then
            return Throwables.ApplyProjectileImpactFeedback(projectile, target, context)
        end
        return true
    end

    local attacker = IsValid(context.owner) and context.owner or game.GetWorld()
    local damage = DamageInfo()
    -- 武器伤害倍率（`mcitem_damage_scale`）：MC 的 20 血刻度 → GMod 的 100。
    damage:SetDamage(MCITEM.ScaleDamage(amount))
    -- Source has no one-to-one DamageSource equivalent. Integrations receive
    -- the exact Java source string above; DMG_GENERIC avoids inventing physics.
    damage:SetDamageType(DMG_GENERIC)
    damage:SetAttacker(attacker)
    damage:SetInflictor(projectile)
    damage:SetDamagePosition(projectile:GetPos())
    damage:SetDamageForce(vector_origin)
    target:TakeDamageInfo(damage)
    return true
end

local function storedEntityClass(className)
    return scripted_ents and isfunction(scripted_ents.GetStored)
        and scripted_ents.GetStored(className) ~= nil
end

function Throwables.SpawnMCChicken(position, owner, context)
    context = context or {}
    context.age = -24000
    if IsValid(owner) and isfunction(owner.SpawnMCChicken) then
        local result = owner:SpawnMCChicken(position, context)
        if result ~= nil then return result end
    end
    local result = hook.Run("MCITEM.SpawnChicken", position, owner, context)
    if result ~= nil then return result end
    -- No chicken ships with the current independent addon. A future compatible
    -- class may opt in under this canonical name; Source birds are not substitutes.
    if not storedEntityClass("bmb_chicken") then return nil end
    local chicken = ents.Create("bmb_chicken")
    if not IsValid(chicken) then return nil end
    chicken:SetPos(position)
    chicken:SetAngles(Angle(0, math.Rand(0, 360), 0))
    chicken:Spawn()
    chicken:Activate()
    if isfunction(chicken.SetMCBabyAge) then chicken:SetMCBabyAge(-24000) end
    return chicken
end

function Throwables.SpawnMCEndermite(position, angles, owner, context)
    context = context or {}
    if IsValid(owner) and isfunction(owner.SpawnMCEndermite) then
        local result = owner:SpawnMCEndermite(position, angles, context)
        if result ~= nil then return result end
    end
    local result = hook.Run("MCITEM.SpawnEndermite", position, angles, owner, context)
    if result ~= nil then return result end
    if not storedEntityClass("bmb_endermite") then return nil end
    local endermite = ents.Create("bmb_endermite")
    if not IsValid(endermite) then return nil end
    endermite:SetPos(position)
    endermite:SetAngles(angles or angle_zero)
    endermite:Spawn()
    endermite:Activate()
    return endermite
end

function Throwables.TeleportEnderPearlOwner(owner, destination, context)
    if not IsValid(owner) or not isvector(destination) then return false end
    if isfunction(owner.TeleportFromMCEnderPearl) then
        local handled = owner:TeleportFromMCEnderPearl(destination, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.TeleportEnderPearlOwner", owner, destination, context)
    if handled ~= nil then return handled ~= false end
    if owner:IsPlayer() and owner:InVehicle() then owner:ExitVehicle() end
    owner:SetPos(destination)
    return true
end

function Throwables.TriggerWindChargeBlocks(position, projectile, context)
    context = context or {}
    local runtime = IsValid(projectile) and projectile.MCThrowableRuntime or nil
    local strength = math.max(0, tonumber(context.blockStrength)
        or tonumber(runtime and runtime.blockStrength) or 1.2)
    local world = MC and MC.API and MC.API.World
    if world and isfunction(world.TriggerExplosion) then
        return world.TriggerExplosion(position, strength, {
            actor = IsValid(projectile) and projectile:GetOwner() or nil,
            source = projectile,
            interaction = "trigger_block",
            immuneBlocks = {
                ["minecraft:barrier"] = true,
                ["minecraft:bedrock"] = true,
            },
        })
    end
    local handled = hook.Run("MCITEM.TriggerBlockExplosion", position, strength, projectile, context)
    if handled ~= nil then return handled ~= false end
    -- Deliberately do not fall back to World.Explode: TRIGGER_BLOCK leaves a
    -- normal block unchanged unless that block overrides onExplosionHit.
    return false, "trigger_explosion_api_unavailable"
end

function Throwables.ExplodeWindCharge(position, projectile, context)
    context = context or {}
    local runtime = IsValid(projectile) and projectile.MCThrowableRuntime or {}
    local strength = math.max(0, tonumber(context.explosionStrength)
        or tonumber(runtime.explosionStrength) or 1.2)
    local knockbackMultiplier = math.max(0, tonumber(context.knockbackMultiplier)
        or tonumber(runtime.knockbackMultiplier) or 1.22)
    context.kind = runtime.kind or context.kind or "wind_charge"
    context.blockInteraction = "trigger_block"
    context.blockStrength = tonumber(context.blockStrength)
        or tonumber(runtime.blockStrength) or strength
    Throwables.TriggerWindChargeBlocks(position, projectile, context)

    local affected = {}
    if MCITEM.Explosions and isfunction(MCITEM.Explosions.Explode) then
        affected = MCITEM.Explosions.Explode({
            position = position,
            strength = strength,
            source = projectile,
            projectile = projectile,
            attacker = IsValid(projectile) and projectile:GetOwner() or nil,
            inflictor = projectile,
            ignoreEntity = projectile,
            damageEntities = false,
            knockbackMultiplier = knockbackMultiplier,
            context = {
                kind = context.kind,
                damageSource = runtime.damageSource or "minecraft:wind_charge",
                damageHook = "MCITEM.WindChargeExplosionDamage",
                knockbackHook = "MCITEM.WindChargeExplosionKnockback",
            },
        })
    end
    hook.Run("MCITEM.WindChargeExploded", position, projectile, affected, context)
    return affected
end
