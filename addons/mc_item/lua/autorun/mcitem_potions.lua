-- Canonical loader for the modular Minecraft Java 26.2 potion runtime.

if SERVER then AddCSLuaFile() end

local sharedModules = {
    "mcitem/potions/sh_data.lua",
    "mcitem/potions/sh_contract.lua",
    "mcitem/potions/sh_audio.lua",
    "mcitem/potions/status/sh_special_audio.lua",
    "mcitem/potions/sh_drink_state.lua",
    "mcitem/potions/sh_attributes.lua",
}

local clientModules = {
    "mcitem/potions/particles/cl_core.lua",
    "mcitem/potions/particles/cl_break.lua",
    "mcitem/potions/particles/cl_status.lua",
    "mcitem/potions/particles/cl_cloud.lua",
    "mcitem/potions/particles/cl_special.lua",
    "mcitem/potions/cl_visuals.lua",
}

local serverModules = {
    "mcitem/explosions/sv_core.lua",
    "mcitem/potions/status/sv_runtime.lua",
    "mcitem/potions/status/sv_attributes.lua",
    "mcitem/potions/status/sv_explosion.lua",
    "mcitem/potions/status/sv_special.lua",
    "mcitem/potions/sv_apply.lua",
    "mcitem/potions/sv_throw.lua",
}

if SERVER then
    for _, path in ipairs(sharedModules) do AddCSLuaFile(path) end
    for _, path in ipairs(clientModules) do AddCSLuaFile(path) end
    AddCSLuaFile("mcitem/potions/sh_registry.lua")
end

for _, path in ipairs(sharedModules) do include(path) end

if SERVER then
    for _, path in ipairs(serverModules) do include(path) end
else
    for _, path in ipairs(clientModules) do include(path) end
end

include("mcitem/potions/sh_registry.lua")
