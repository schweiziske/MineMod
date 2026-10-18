-- Minecraft Java 26.2 potion sound rules.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

Potions.SoundVariants = Potions.SoundVariants or {
    drink = { "drink.ogg" },
    throw = { "throw.ogg" },
    break_bottle = { "break1.ogg", "break2.ogg", "break3.ogg" },
}

for _, variants in pairs(Potions.SoundVariants) do
    for _, filename in ipairs(variants) do
        if SERVER then resource.AddFile("sound/mcitem/potions/" .. filename) end
    end
end

local function randomVariant(key)
    local variants = Potions.SoundVariants[key]
    if not variants or #variants == 0 then return nil end
    return variants[math.random(1, #variants)]
end

local function pitchValue(multiplier)
    return math.Clamp(math.floor((tonumber(multiplier) or 1) * 100 + 0.5), 1, 255)
end

function Potions.PlayDrinkSound(entity)
    if not IsValid(entity) then return end
    local filename = randomVariant("drink")
    if not filename then return end
    entity:EmitSound("mcitem/potions/" .. filename, 75, pitchValue(math.Rand(0.9, 1)), 0.5, CHAN_AUTO)
end

function Potions.PlayThrowSound(entity)
    if not IsValid(entity) then return end
    local filename = randomVariant("throw")
    if not filename then return end
    -- SplashPotionItem/LingeringPotionItem:
    -- pitch = 0.4 / (random * 0.4 + 0.8), volume = 0.5.
    local pitch = 0.4 / (math.Rand(0, 1) * 0.4 + 0.8)
    entity:EmitSound("mcitem/potions/" .. filename, 75, pitchValue(pitch), 0.5, CHAN_AUTO)
end

function Potions.PlayBreakSound(position)
    if not isvector(position) then return end
    local filename = randomVariant("break_bottle")
    if not filename then return end
    sound.Play("mcitem/potions/" .. filename, position, 75, pitchValue(math.Rand(0.9, 1)), 1)
end
