-- Optional MCSWEP integration. MCITEM remains standalone when MC.API is absent.

if SERVER then AddCSLuaFile() end

local sharedModules = {
    "mcitem/integration/mcswep/sh_resolver.lua",
    "mcitem/integration/mcswep/sh_registration.lua",
    "mcitem/integration/mcswep/sh_creative_stacks.lua",
}

local clientModules = {
    "mcitem/integration/mcswep/cl_projectiles.lua",
}

if SERVER then
    for _, path in ipairs(sharedModules) do AddCSLuaFile(path) end
    for _, path in ipairs(clientModules) do AddCSLuaFile(path) end
end
for _, path in ipairs(sharedModules) do include(path) end

if SERVER then
    include("mcitem/integration/mcswep/sv_inventory_hooks.lua")
else
    for _, path in ipairs(clientModules) do include(path) end
end
