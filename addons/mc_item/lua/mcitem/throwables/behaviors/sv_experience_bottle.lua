if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("experience_bottle", {
    OnHit = function(projectile, trace)
        local target = trace.Entity
        -- ThrownExperienceBottle.onHit never calls hurt on the entity it
        -- intersects.  It only creates experience orbs at the event
        -- position; keep this branch entirely free of damage hooks so a
        -- compatibility addon cannot accidentally turn the bottle into a
        -- zero-damage attack.

        local position = Throwables.LevelEventPosition(trace.HitPos or projectile:GetPos())
        local direction
        if Throwables.IsProjectileTarget(target) then
            direction = -(projectile.MCProjectileVelocity or vector_origin)
        else
            direction = trace.HitNormal or vector_origin
        end
        if direction:LengthSqr() > 0 then direction:Normalize() end
        local value = 3 + math.random(0, 4) + math.random(0, 4)
        Throwables.AwardExperience(position, direction, value, {
            projectile = projectile,
            owner = projectile:GetOwner(),
            trace = trace,
            total = value,
        })
        Throwables.PlayExperienceBottleBreak(position)
        Throwables.BroadcastFX(Throwables.FX.EXPERIENCE_BOTTLE, position, direction)
        return true
    end,
})
