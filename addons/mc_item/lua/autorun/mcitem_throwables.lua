-- Canonical loader for the modular Minecraft Java 26.2 throwable runtime.

if SERVER then AddCSLuaFile() end

local sharedModules = {
    "mcitem/throwables/sh_data.lua",
    "mcitem/throwables/sh_contract.lua",
    "mcitem/throwables/sh_collision.lua",
    "mcitem/throwables/sh_audio_data.lua",
    "mcitem/throwables/sh_audio.lua",
}

local clientModules = {
    "mcitem/throwables/particles/cl_core.lua",
    "mcitem/throwables/particles/cl_impact.lua",
    "mcitem/throwables/particles/cl_trails.lua",
}

local serverModules = {
    "mcitem/explosions/sv_core.lua",
    "mcitem/throwables/sv_damage.lua",
    "mcitem/throwables/sv_experience.lua",
    "mcitem/throwables/sv_fx.lua",
    "mcitem/throwables/behaviors/sv_wind_charge.lua",
    "mcitem/throwables/behaviors/sv_ender_pearl.lua",
    "mcitem/throwables/behaviors/sv_snowball.lua",
    "mcitem/throwables/behaviors/sv_egg.lua",
    "mcitem/throwables/behaviors/sv_experience_bottle.lua",
    "mcitem/throwables/sv_throw.lua",
}

if SERVER then
    for _, path in ipairs(sharedModules) do AddCSLuaFile(path) end
    for _, path in ipairs(clientModules) do AddCSLuaFile(path) end
    AddCSLuaFile("mcitem/throwables/sh_registry.lua")
end

for _, path in ipairs(sharedModules) do include(path) end
if SERVER then
    for _, path in ipairs(serverModules) do include(path) end
else
    for _, path in ipairs(clientModules) do include(path) end
end
include("mcitem/throwables/sh_registry.lua")
