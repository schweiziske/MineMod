-- Shared extension points and exact constants for throwable items.

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
Throwables.PlayerCooldowns = Throwables.PlayerCooldowns or setmetatable({}, { __mode = "k" })

function Throwables.IsOnCooldown(owner, definition)
    local cooldowns = Throwables.PlayerCooldowns[owner]
    local group = definition.cooldownGroup or definition.id
    return cooldowns ~= nil and (cooldowns[group] or 0) > CurTime()
end

function Throwables.StartCooldown(owner, definition)
    local cooldowns = Throwables.PlayerCooldowns[owner]
    if not cooldowns then cooldowns = {} Throwables.PlayerCooldowns[owner] = cooldowns end
    local group = definition.cooldownGroup or definition.id
    cooldowns[group] = CurTime() + math.max(Throwables.RightClickDelayTicks,
        definition.cooldownTicks or 0) * Throwables.TickSeconds
end

Throwables.TickSeconds = 1 / 20
Throwables.RightClickDelayTicks = 4
Throwables.EnderEyeLifetimeTicks = 80
Throwables.EnderEyeFarDistance = 12
Throwables.EnderEyeFarHeight = 8
Throwables.EnderEyeReturnChance = 0.8
-- ThrownEnderpearl.onHit: 5 Java health points = 2.5 hearts. ScaleDamage
-- converts these once to Source HP (25 at the default 20 -> 100 scale).
Throwables.EnderPearlDamage = 5
Throwables.EndermiteChance = 0.05
Throwables.ExperienceOrbLifetimeTicks = 6000
Throwables.ExperienceOrbFollowRange = 8
Throwables.ExperiencePickupDelayTicks = 2
Throwables.ExperienceBottleColor = bit.band(-13083194, 0xFFFFFF)
Throwables.ExperienceValues = { 2477, 1237, 617, 307, 149, 73, 37, 17, 7, 3, 1 }

Throwables.FX = {
    SNOWBALL = 1,
    EGG = 2,
    ENDER_PEARL = 3,
    EXPERIENCE_BOTTLE = 4,
    WIND_CHARGE = 5,
    ENDER_EYE_DEATH = 6,
    WIND_BURST = 7,
}

function Throwables.DefinitionForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if istable(weapon.MCThrowableDefinition) then return weapon.MCThrowableDefinition end
    return Throwables.Get(weapon.MCThrowableID or weapon.MCItemID)
end

function Throwables.IsLivingTarget(target)
    if not IsValid(target) or target:IsWorld() then return false end
    if target:IsPlayer() then return target:Alive() end
    if target:IsNPC() or target:IsNextBot() or target.IsBMBMob == true then
        return target.BMBDead ~= true
    end
    if isfunction(target.IsMCLivingTarget) then
        local result = target:IsMCLivingTarget()
        if result ~= nil then return result ~= false end
    end
    local result = hook.Run("MCITEM.IsLivingTarget", target)
    return result ~= nil and result ~= false or false
end

function Throwables.IsBlazeTarget(target, context)
    if not IsValid(target) then return false end
    if isfunction(target.IsMCBlaze) then
        local result = target:IsMCBlaze(context)
        if result ~= nil then return result ~= false end
    end
    local result = hook.Run("MCITEM.IsBlazeTarget", target, context)
    return result ~= nil and result ~= false or false
end

function Throwables.CanUse(weapon, owner, definition)
    if not IsValid(weapon) or not IsValid(owner) or not istable(definition) then return false end
    if Throwables.IsOnCooldown(owner, definition) then return false end
    if isfunction(weapon.CanMCUseThrowable) then
        local result = weapon:CanMCUseThrowable(owner, definition)
        if result ~= nil then return result ~= false end
    end
    local result = hook.Run("MCITEM.CanUseThrowable", owner, weapon, definition)
    if result ~= nil then return result ~= false end
    return true
end

-- Entity-side ProjectileDeflection bridge.  Java asks the hit entity for a
-- deflection before it runs the projectile's normal on-hit path.  Keeping that
-- decision here lets BMB mobs (notably Breeze) reuse MCITEM arrows, tridents
-- and generic throwables without either addon depending on the other's class
-- internals.
function Throwables.ProjectileVelocity(projectile)
    if not IsValid(projectile) then return nil end
    if isvector(projectile.MCProjectileVelocity) then
        return projectile.MCProjectileVelocity
    end
    if isfunction(projectile.GetMCVelocity) then
        local velocity = projectile:GetMCVelocity()
        if isvector(velocity) then return velocity end
    end
    return nil
end

function Throwables.SetProjectileVelocity(projectile, velocity)
    if not IsValid(projectile) or not isvector(velocity) then return false end
    -- The manual throwable base integrates this server-only field, while the
    -- arrow/trident family integrates its networked MCVelocity.  Keep both in
    -- sync so a deflector never needs to know which implementation it hit.
    projectile.MCProjectileVelocity = velocity
    if isfunction(projectile.SetMCVelocity) then projectile:SetMCVelocity(velocity) end
    return true
end

function Throwables.ReverseProjectile(projectile, trace, scale)
    local velocity = Throwables.ProjectileVelocity(projectile)
    if not isvector(velocity) or velocity:LengthSqr() <= 1e-8 then return false end

    local reversed = velocity * -math.max(0, tonumber(scale) or 0.5)
    if not Throwables.SetProjectileVelocity(projectile, reversed) then return false end

    -- Minecraft leaves the projectile on the entity-hit location.  Source
    -- traces can report that boundary as StartSolid on the following tick, so
    -- move it a tiny distance along the new vector without changing gameplay
    -- range or speed.  MCLastDeflectedBy below still mirrors Java's permanent
    -- lastDeflectedBy guard if it meets the same entity again later.
    local hitPosition = trace and trace.HitPos
    if isvector(hitPosition) and isfunction(projectile.SetPos) then
        local blockSize = isfunction(MCITEM.BlockSize) and MCITEM.BlockSize() or 36.5
        projectile:SetPos(hitPosition + reversed:GetNormalized() * (0.01 * blockSize))
    end
    return true, reversed
end

function Throwables.TryEntityDeflection(projectile, target, trace, context)
    if not SERVER or not IsValid(projectile) or not IsValid(target) then return false end
    if isfunction(projectile.CanMCBeDeflected) and projectile:CanMCBeDeflected() ~= true then
        return false
    end

    -- Projectile.hitTargetOrDeflectSelf returns the target's deflection even
    -- when lastDeflectedBy is the same entity, but deliberately skips applying
    -- REVERSE (and its sound callback) a second time.
    if projectile.MCLastDeflectedBy == target then return true end

    context = context or {}
    context.projectile = projectile
    context.target = target
    context.trace = trace

    local result
    if isfunction(target.DeflectMCProjectile) then
        result = target:DeflectMCProjectile(projectile, trace, context)
    end
    if result == nil then
        result = hook.Run("MCITEM.DeflectProjectile", target, projectile, trace, context)
    end
    if result ~= true then return false end

    projectile.MCLastDeflectedBy = target
    hook.Run("MCITEM.ProjectileDeflected", target, projectile, trace, context)
    return true
end

function Throwables.ProjectileOrigin(owner, definition)
    local feet = owner:GetPos()
    return Vector(
        feet.x,
        feet.y,
        owner:EyePos().z + (tonumber(definition.originEyeOffset) or 0) * MCITEM.BlockSize()
    )
end

function Throwables.ProjectileDirection(owner, definition)
    local angles = owner:EyeAngles()
    angles = Angle(angles.p + (tonumber(definition.pitchOffset) or 0), angles.y, 0)
    return angles:Forward()
end

function Throwables.ResolveEnderEyeTarget(owner, weapon)
    if IsValid(weapon) and isfunction(weapon.ResolveMCEnderEyeTarget) then
        local target = weapon:ResolveMCEnderEyeTarget(owner)
        if isvector(target) then return target end
    end
    local target = hook.Run("MCITEM.ResolveEnderEyeTarget", owner, weapon)
    if isvector(target) then return target end

    -- The user-requested fallback for maps without structure positions:
    -- choose a uniform random horizontal direction, then let EyeOfEnder.signalTo
    -- apply vanilla's 12-block horizontal / 8-block vertical far-target clamp.
    local yaw = math.Rand(0, 360)
    local direction = Angle(0, yaw, 0):Forward()
    return owner:GetPos() + direction * (100 * MCITEM.BlockSize())
end

function Throwables.CanTeleportPearlOwner(owner, context)
    if not IsValid(owner) then return false end
    if owner:IsPlayer() and not owner:Alive() then return false end
    if owner.BMBDead then return false end
    if isfunction(owner.IsMCSleeping) and owner:IsMCSleeping(context) then return false end
    if hook.Run("MCITEM.IsEntitySleeping", owner, context) == true then return false end
    local result = hook.Run("MCITEM.CanEnderPearlTeleport", owner, context)
    if result ~= nil then return result ~= false end
    return true
end

function Throwables.Consume(owner, weapon, definition, context)
    if not IsValid(owner) or not istable(definition) then return false end
    if IsValid(weapon) and isfunction(weapon.ConsumeMCThrowableItem) then
        local handled = weapon:ConsumeMCThrowableItem(owner, definition, 1, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.ConsumeThrowableItem", owner, weapon, definition, 1, context)
    -- Standalone preview SWEPs have no inventory provider; an explicit false
    -- from a provider must still cancel the prepared projectile.
    return handled ~= false
end

-- EyeOfEnder.tick 的返还分支是 `spawnAtLocation(Items.ENDER_EYE)` —— 生成一个**掉落物**，
-- 不是把一把武器扔在地上。装了 MineMod 就用它自己的 `mc_item_drop`（和方块掉落、玩家
-- 丢东西是同一种实体，能正常吸取、合并、计时消失）；没有 provider 时保持失败并发出接口事件，
-- 绝不伪造会变成 ragdoll/物理武器的 SWEP。
function Throwables.ReturnEnderEye(position, owner, context)
    local returned = hook.Run("MCITEM.ReturnEnderEye", position, owner, context)
    if returned ~= nil then return returned ~= false end
    if not SERVER or not isvector(position) then return false end

    if isfunction(MCITEM.SpawnItemDrop)
        and MCITEM.SpawnItemDrop(position, "minecraft:ender_eye", 1, owner) then
        return true
    end

    -- A returned Eye is an ItemEntity in Java.  If no inventory/drop provider
    -- is installed, do not fabricate a weapon entity (Source turns dropped
    -- SWEPs into ragdoll-like physics objects, which is the exact wrong visual
    -- and pickup contract).  Standalone integrations can provide the canonical
    -- drop through MCITEM.SpawnItemDrop or MCITEM.ReturnEnderEye.
    hook.Run("MCITEM.EnderEyeDropUnavailable", position, owner, context)
    return false
end

function Throwables.GiveExperience(player, value, context)
    value = math.max(0, math.floor(tonumber(value) or 0))
    if not IsValid(player) or value <= 0 then return false end
    if isfunction(player.AddMCExperience) then
        local handled = player:AddMCExperience(value, context)
        if handled ~= nil then return handled ~= false end
    end
    local handled = hook.Run("MCITEM.GiveExperience", player, value, context)
    if handled ~= nil then return handled ~= false end
    -- Without an authoritative XP provider the orb must remain available.
    return false
end

function Throwables.NotifyExperienceLevelChanged(player, oldLevel, newLevel, context)
    -- Deliberately no default sound.  The user requested an interface for the
    -- later level-up system without guessing its thresholds or persistence.
    hook.Run("MCITEM.ExperienceLevelChanged", player, oldLevel, newLevel, context)
end

function Throwables.RepairWithExperience(player, value, context)
    value = math.max(0, math.floor(tonumber(value) or 0))
    if not IsValid(player) or value <= 0 then return value end
    if isfunction(player.RepairMCItemsWithExperience) then
        local remaining = player:RepairMCItemsWithExperience(value, context)
        if isnumber(remaining) then return math.Clamp(math.floor(remaining), 0, value) end
    end
    local remaining = hook.Run("MCITEM.RepairWithExperience", player, value, context)
    if isnumber(remaining) then return math.Clamp(math.floor(remaining), 0, value) end
    return value
end
