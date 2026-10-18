-- Minecraft Java 26.2 bucket definitions.

MCITEM = MCITEM or {}
MCITEM.Buckets = MCITEM.Buckets or {}

local Buckets = MCITEM.Buckets

Buckets.RightClickDelayTicks = 4
Buckets.Definitions = {
    bucket = {
        id = "bucket",
        name = "Bucket",
        maxStack = 16,
        pickup = true,
        model = "models/mcgm/bucket/bucket.mdl",
    },
    water_bucket = {
        id = "water_bucket",
        name = "Water Bucket",
        maxStack = 1,
        liquid = "water",
        replacement = "bucket",
        model = "models/mcgm/water_bucket/water_bucket.mdl",
    },
    lava_bucket = {
        id = "lava_bucket",
        name = "Lava Bucket",
        maxStack = 1,
        liquid = "lava",
        replacement = "bucket",
        model = "models/mcgm/lava_bucket/lava_bucket.mdl",
    },
    milk_bucket = {
        id = "milk_bucket",
        name = "Milk Bucket",
        maxStack = 1,
        replacement = "bucket",
        model = "models/mcgm/milk_bucket/milk_bucket.mdl",
        consumable = true,
    },
}

function Buckets.Get(itemId)
    if not isstring(itemId) then return nil end
    return Buckets.Definitions[string.gsub(itemId, "^minecraft:", "")]
end

function Buckets.ItemForLiquid(kind)
    kind = string.gsub(string.lower(tostring(kind or "")), "^minecraft:", "")
    if kind == "water" then return "water_bucket" end
    if kind == "lava" then return "lava_bucket" end
    return nil
end

function Buckets.DefinitionForWeapon(weapon)
    if not IsValid(weapon) then return nil end
    if istable(weapon.MCBucketDefinition) then return weapon.MCBucketDefinition end
    return Buckets.Get(weapon.MCBucketID or weapon.MCItemID)
end

-- External cow/mooshroom addons call this after their own age/cooldown/entity
-- checks.  Returning true means MCITEM replaced one selected empty bucket with
-- milk (or applied Java's creative keep-one-filled-bucket rule).
function Buckets.TryMilkEntity(player, target, context)
    if not IsValid(player) or not IsValid(target) then return false, "invalid_entity" end
    local allowed = hook.Run("MCITEM.CanMilkEntity", player, target, context)
    if allowed ~= true then return false, allowed == false and "rejected" or "unhandled" end
    if not isfunction(Buckets.FillMilkBucket) then return false, "server_api_unavailable" end
    return Buckets.FillMilkBucket(player, target, context)
end
