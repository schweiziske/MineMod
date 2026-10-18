-- Load-order-safe registration with MC.API.HandWeapon.
--
-- MCITEM ships separately from MCSWEP, so neither autorun order is guaranteed.
-- MC.API.OnRegister replays for late subscribers, which covers "engine already
-- loaded"; the hook covers "engine loads after us". Registration must happen in
-- the register phase, before the block/state registries freeze.

MCITEM = MCITEM or {}
MCITEM.MCSWEP = MCITEM.MCSWEP or {}

local Integration = MCITEM.MCSWEP
local RESOLVER_ID = "mcitem"
local REQUIRED_API_VERSION = 1

function Integration.RegisterHandWeaponResolver()
    local api = MC and MC.API
    if not api then return false end
    if api.Require and not api.Require( REQUIRED_API_VERSION, "MCITEM" ) then return false end
    local handWeapon = api.HandWeapon
    if not handWeapon or not isfunction(handWeapon.RegisterResolver) then return false end
    local ok = handWeapon.RegisterResolver(RESOLVER_ID, Integration.ResolveWeaponClass, 100)
    Integration.HandWeaponResolverRegistered = ok == true
    return ok == true
end

if MC and MC.API and MC.API.OnRegister then
    MC.API.OnRegister(Integration.RegisterHandWeaponResolver)
else
    hook.Add("MC.APIAvailable", "MCITEM.MCSWEP.RegisterHandWeaponResolver", Integration.RegisterHandWeaponResolver)
end
-- Autorefresh re-runs this file without re-firing the engine lifecycle.
hook.Add("OnReloaded", "MCITEM.MCSWEP.RegisterHandWeaponResolverReload", Integration.RegisterHandWeaponResolver)
