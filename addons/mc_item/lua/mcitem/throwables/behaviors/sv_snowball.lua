if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("snowball", {
    OnHit = function(projectile, trace)
        local target = trace.Entity
        if Throwables.IsProjectileTarget(target) then
            -- Snowball.onHitEntity calls LivingEntity.hurt even when the
            -- computed damage is zero (the Blaze branch is the only 3-damage
            -- exception).  The explicit flag prevents other zero-damage
            -- projectiles from inheriting that feedback accidentally.
            local context = { trace = trace }
            local damage = Throwables.IsBlazeTarget(target, context) and 3 or 0
            context.zeroDamageImpact = damage == 0
            Throwables.ApplyProjectileDamage(
                projectile,
                target,
                damage,
                "minecraft:thrown_snowball",
                context
            )
        end
        Throwables.BroadcastFX(Throwables.FX.SNOWBALL, trace.HitPos or projectile:GetPos())
        return true
    end,
})
