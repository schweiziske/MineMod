if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("llama_spit", {
    OnHit = function(projectile, trace)
        local target = trace and trace.Entity
        local runtime = projectile.MCThrowableRuntime or {}
        if Throwables.IsLivingTarget(target) then
            Throwables.ApplyProjectileDamage(
                projectile,
                target,
                tonumber(runtime.damage) or 1,
                runtime.damageSource or "minecraft:spit",
                { trace = trace }
            )
        end
        return true
    end,
})
