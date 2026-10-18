if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("wind_charge", {
    CanDeflect = function(projectile)
        return (tonumber(projectile.MCProjectileAge) or 0) > 5
    end,

    OnHit = function(projectile, trace)
        local runtime = projectile.MCThrowableRuntime or {}
        local target = trace.Entity
        if Throwables.IsProjectileTarget(target) then
            Throwables.ApplyProjectileDamage(
                projectile,
                target,
                tonumber(runtime.directDamage) or 1,
                runtime.directDamageSource or "minecraft:wind_charge_direct",
                { trace = trace }
            )
        end
        local position = trace.HitPos or projectile:GetPos()
        if trace.HitWorld and isvector(trace.HitNormal) then
            position = position + trace.HitNormal * (0.25 * MCITEM.BlockSize())
        end
        Throwables.ExplodeWindCharge(position, projectile, {
            trace = trace,
            kind = runtime.kind,
            explosionStrength = runtime.explosionStrength,
            blockStrength = runtime.blockStrength,
            knockbackMultiplier = runtime.knockbackMultiplier,
        })
        if isstring(runtime.burstSound) and runtime.burstSound ~= "" then
            sound.Play(
                runtime.burstSound,
                position,
                tonumber(runtime.burstSoundLevel) or 75,
                tonumber(runtime.burstSoundPitch) or 100,
                tonumber(runtime.burstSoundVolume) or 1
            )
        elseif runtime.suppressDefaultBurstSound ~= true then
            Throwables.PlayWindBurst(position)
        end
        Throwables.BroadcastFX(Throwables.FX.WIND_CHARGE, position)
        return true
    end,
})
