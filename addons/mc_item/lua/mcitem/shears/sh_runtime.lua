-- Shared target contract for the Java 26.2 Shearable interaction.

MCITEM = MCITEM or {}
MCITEM.Shears = MCITEM.Shears or {}

local Shears = MCITEM.Shears

function Shears.IsAliveTarget(target)
    if not IsValid(target) then return false end
    if target.BMBDead == true or (target.GetNW2Bool and target:GetNW2Bool("BMBDead", false)) then
        return false
    end
    if target.Health and tonumber(target:Health()) and target:Health() <= 0 then return false end
    return true
end

function Shears.IsShearableTarget(target)
    return Shears.IsAliveTarget(target)
        and isfunction(target.CanBMBShear)
        and target:CanBMBShear() == true
end

return Shears
