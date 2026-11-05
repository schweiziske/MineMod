-- Four Java 26.2 buckets: empty, water, lava, and milk.

if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("mcitem/buckets/sh_data.lua")
    AddCSLuaFile("mcitem/buckets/sh_audio.lua")
    AddCSLuaFile("weapons/weapon_mcitem_bucket_base/shared.lua")
end

include("mcitem/buckets/sh_data.lua")
include("mcitem/buckets/sh_audio.lua")
if SERVER then include("mcitem/buckets/sv_use.lua") end

for _, itemId in ipairs({ "bucket", "water_bucket", "lava_bucket" }) do
    local definition = MCITEM.Buckets.Get(itemId)
    weapons.Register({
        Base = "weapon_mcitem_bucket_base",
        PrintName = "#item.minecraft." .. definition.id,
        Category = "#mcitem.category.items",
        MCInstructionsKey = definition.pickup and "mcitem.instructions.bucket_pickup" or "mcitem.instructions.bucket_place",
        Spawnable = true,
        AdminOnly = false,
        WorldModel = definition.model,
        MCItemID = definition.id,
        MCBucketID = definition.id,
        MCBucketDefinition = definition,
        MCMaxStack = definition.maxStack,
    }, "weapon_mcitem_" .. definition.id)
end
