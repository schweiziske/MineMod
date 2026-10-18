-- Official Java 26.2 sounds.json bucket variants.

MCITEM = MCITEM or {}
MCITEM.Buckets = MCITEM.Buckets or {}

local Buckets = MCITEM.Buckets

Buckets.SoundVariants = {
    fill = {
        { file = "fill1.ogg", pitch = 1 },
        { file = "fill2.ogg", pitch = 1 },
        { file = "fill3.ogg", pitch = 1 },
    },
    fill_lava = {
        { file = "fill_lava1.ogg", pitch = 1 },
        { file = "fill_lava2.ogg", pitch = 1 },
        { file = "fill_lava3.ogg", pitch = 1 },
    },
    empty = {
        { file = "empty1.ogg", pitch = 1 },
        { file = "empty1.ogg", pitch = 0.9 },
        { file = "empty2.ogg", pitch = 1 },
        { file = "empty3.ogg", pitch = 1 },
    },
    empty_lava = {
        { file = "empty_lava1.ogg", pitch = 1 },
        { file = "empty_lava2.ogg", pitch = 1 },
        { file = "empty_lava3.ogg", pitch = 1 },
    },
}

for _, variants in pairs(Buckets.SoundVariants) do
    for _, variant in ipairs(variants) do
        if SERVER then resource.AddFile("sound/mcitem/bucket/" .. variant.file) end
    end
end

function Buckets.PlaySound(entity, key)
    if not IsValid(entity) then return false end
    local variants = Buckets.SoundVariants[key]
    if not variants or #variants == 0 then return false end
    local variant = variants[math.random(1, #variants)]
    entity:EmitSound(
        "mcitem/bucket/" .. variant.file,
        75,
        math.Clamp(math.floor((variant.pitch or 1) * 100 + 0.5), 1, 255),
        1,
        CHAN_AUTO
    )
    return true
end
