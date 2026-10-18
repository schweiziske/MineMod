AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

include("mcitem/explosions/sv_core.lua")
include("mcitem/throwables/sv_fx.lua")
include("mcitem/throwables/sv_damage.lua")
include("mcitem/throwables/sv_experience.lua")
include("mcitem/throwables/behaviors/sv_wind_charge.lua")
include("mcitem/throwables/behaviors/sv_ender_pearl.lua")
include("mcitem/throwables/behaviors/sv_snowball.lua")
include("mcitem/throwables/behaviors/sv_egg.lua")
include("mcitem/throwables/behaviors/sv_experience_bottle.lua")
include("mcitem/throwables/behaviors/sv_llama_spit.lua")

function ENT:OnMCProjectileHit(trace)
    local target = trace and trace.Entity or nil
    if MCITEM.Throwables.NotifyProjectileLanded
        and not MCITEM.Throwables.IsProjectileTarget(target) then
        MCITEM.Throwables.NotifyProjectileLanded(self, trace, {
            throwableBehavior = self.MCThrowableBehavior or self:GetThrowableBehavior(),
        })
    end
    return MCITEM.Throwables.HandleProjectileHit(self, trace)
end
