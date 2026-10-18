if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("ender_pearl", {
    OnHit = function(projectile, trace)
        local target = trace.Entity
        if Throwables.IsProjectileTarget(target) then
            -- Java's ender_pearl damage type is explicitly tagged
            -- no_knockback; a pearl striking a living entity must not invoke
            -- the snowball/egg zero-damage feedback path.
            Throwables.ApplyProjectileDamage(projectile, target, 0,
                "minecraft:ender_pearl", { trace = trace, applyKnockback = false })
        end

        local particlePosition = trace.HitPos or projectile:GetPos()
        Throwables.BroadcastFX(Throwables.FX.ENDER_PEARL, particlePosition)
        local owner = projectile:GetOwner()
        local destination = projectile.MCTickStartPosition or particlePosition
        local context = {
            projectile = projectile,
            trace = trace,
            destination = destination,
        }
        if not Throwables.CanTeleportPearlOwner(owner, context) then return true end

        local oldPosition = owner:GetPos()
        local oldAngles = owner:GetAngles()
        if math.Rand(0, 1) < Throwables.EndermiteChance then
            Throwables.SpawnMCEndermite(oldPosition, oldAngles, owner, context)
        end
        if Throwables.TeleportEnderPearlOwner(owner, destination, context) then
            Throwables.PlayPearlTeleport(destination)
            Throwables.ApplyProjectileDamage(
                projectile,
                owner,
                Throwables.EnderPearlDamage,
                "minecraft:ender_pearl",
                context
            )
        end
        return true
    end,
})
