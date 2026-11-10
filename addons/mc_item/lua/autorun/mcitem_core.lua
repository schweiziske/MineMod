-- MCITEM 通用模块装载器：调参 convar、第三人称 holdtype 映射、设置面板注册、
-- 方块描边。这些都不属于某一件武器，所以从 autorun 装一次，而不是让每个 SWEP
-- 各自 include。武器基类仍然会再 include 一次（幂等），保证加载顺序怎么排都不缺。

if SERVER then AddCSLuaFile() end

local sharedModules = {
    "mcitem/sh_tuning.lua",
    "mcitem/sh_holdtypes.lua",
    "mcitem/sh_ammo.lua",
    "mcitem/sh_ranged.lua",
    "mcitem/sh_enchantments.lua",
    "mcitem/utility/sh_use.lua",
    "mcitem/fishing/sh_generated_data.lua",
    "mcitem/fishing/sh_core.lua",
    "mcitem/shears/sh_runtime.lua",
    "mcitem/name_tags/sh_runtime.lua",
    "mcitem/sh_config_menu.lua",
    "mcitem/enchantments/sh_creative_books.lua",
    "mcitem/enchantments/sh_runtime.lua",
    "mcitem/enchantments/sh_gameplay.lua",
}

local clientModules = {
    "mcitem/cl_block_outline.lua",
    "mcitem/cl_model_lighting.lua",
    "mcitem/cl_billboard.lua",
    "mcitem/cl_enchantment_glint.lua",
    "mcitem/enchantments/cl_effects.lua",
    "mcitem/name_tags/cl_render.lua",
    "mcitem/totem/cl_effects.lua",
    "mcitem/fishing/cl_effects.lua",
}

local serverModules = {
    "mcitem/enchantments/sv_gameplay.lua",
    "mcitem/shears/sv_runtime.lua",
    "mcitem/name_tags/sv_runtime.lua",
    "mcitem/totem/sv_runtime.lua",
    "mcitem/fishing/sv_loot.lua",
    "mcitem/fishing/sv_effects.lua",
}

if SERVER and resource and resource.AddFile then
    resource.AddFile("materials/mcitem/misc/enchanted_glint_item.png")
    resource.AddFile("materials/mcitem/misc/enchanted_glint_item.vtf")
    resource.AddFile("materials/mcitem/misc/enchanted_glint_model.vmt")
    resource.AddFile("materials/mcitem/enchantments/fire_0.vtf")
    resource.AddFile("materials/mcitem/enchantments/fire_0.vmt")
    resource.AddFile("materials/mcitem/enchantments/fire_1.vtf")
    resource.AddFile("materials/mcitem/enchantments/fire_1.vmt")
    resource.AddFile("materials/mcitem/enchantments/soul.vtf")
    resource.AddFile("materials/mcitem/enchantments/soul.vmt")
    resource.AddFile("materials/models/mcmodelpack/arrow_spectral.vtf")
    resource.AddFile("materials/models/mcmodelpack/arrow_spectral.vmt")
    resource.AddFile("materials/mcitem/fishing/fishing_hook.png")
    resource.AddFile("materials/mcitem/fishing/bubble.png")
    for index = 0, 3 do
        resource.AddFile("materials/mcitem/fishing/splash_" .. index .. ".png")
    end
    resource.AddFile("sound/mcitem/fishing/castfast.ogg")
    resource.AddFile("sound/mcitem/fishing/retrieve1.ogg")
    resource.AddFile("sound/mcitem/fishing/retrieve2.ogg")
    resource.AddFile("sound/mcitem/fishing/splash.ogg")
    for index = 0, 7 do
        resource.AddFile("materials/mcitem/particle/glitter_" .. index .. ".png")
    end
    resource.AddFile("materials/mcitem/totem/particles.vmt")
    resource.AddFile("materials/mcitem/totem/particles.vtf")
end

if SERVER then
    for _, path in ipairs(sharedModules) do AddCSLuaFile(path) end
    for _, path in ipairs(clientModules) do AddCSLuaFile(path) end
end

for _, path in ipairs(sharedModules) do include(path) end

if SERVER then
    for _, path in ipairs(serverModules) do include(path) end
else
    for _, path in ipairs(clientModules) do include(path) end
end
