if not SERVER then return end

local Throwables = MCITEM.Throwables

Throwables.RegisterBehavior("ender_pearl", {
    OnHit = function(projectile, trace)
        local target = trace.Entity
        if Throwables.IsProjectileTarget(target) then
            -- onHitEntity uses DamageSources.thrown(...), not enderPearl().
            -- LivingEntity accepts hurt(0); Player.hurtServer rejects it.
            Throwables.ApplyProjectileDamage(projectile, target, 0,
                "minecraft:thrown", { trace = trace, zeroDamageImpact = not target:IsPlayer() })
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
        if owner:IsPlayer() and math.Rand(0, 1) < Throwables.EndermiteChance then
            Throwables.SpawnMCEndermite(oldPosition, oldAngles, owner, context)
        end
        if Throwables.TeleportEnderPearlOwner(owner, destination, context) then
            Throwables.PlayPearlTeleport(destination)
            -- Java's non-player branch only teleports and resets fall state.
            if owner:IsPlayer() then
                Throwables.ApplyProjectileDamage(
                    projectile,
                    owner,
                    Throwables.EnderPearlDamage,
                    "minecraft:ender_pearl",
                    context
                )
            end
        end
        return true
    end,
})
