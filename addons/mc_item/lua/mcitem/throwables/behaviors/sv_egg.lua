if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("egg", {
    OnHit = function(projectile, trace)
        local target = trace.Entity
        if Throwables.IsProjectileTarget(target) then
            Throwables.ApplyProjectileDamage(
                projectile,
                target,
                0,
                "minecraft:thrown_egg",
                { trace = trace, zeroDamageImpact = true }
            )
        end

        local position = trace.HitPos or projectile:GetPos()
        if math.random(1, 8) == 1 then
            local count = math.random(1, 32) == 1 and 4 or 1
            for index = 1, count do
                Throwables.SpawnMCChicken(position, projectile:GetOwner(), {
                    projectile = projectile,
                    trace = trace,
                    index = index,
                    count = count,
                    age = -24000,
                })
            end
        end
        Throwables.BroadcastFX(Throwables.FX.EGG, position)
        return true
    end,
})
