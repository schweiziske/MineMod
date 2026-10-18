-- Minecraft Java 26.2 Consumable/FoodProperties sound rules.

MCITEM = MCITEM or {}
MCITEM.Food = MCITEM.Food or {}

local Food = MCITEM.Food

Food.SoundVariants = Food.SoundVariants or {
    generic_eat = { "eat1.ogg", "eat2.ogg", "eat3.ogg" },
    generic_drink = { "drink.ogg" },
    honey_drink = { "drink_honey1.ogg", "drink_honey2.ogg", "drink_honey3.ogg" },
    player_burp = { "burp.ogg" },
}

for _, variants in pairs(Food.SoundVariants) do
    for _, filename in ipairs(variants) do
        if SERVER then resource.AddFile("sound/mcitem/food/" .. filename) end
    end
end

local function triangle(mode, deviation)
    -- RandomSource.triangle(mode, deviation) = mode + deviation * (u - v).
    return mode + deviation * (math.Rand(0, 1) - math.Rand(0, 1))
end

local function randomVariant(soundKey)
    local variants = Food.SoundVariants[soundKey]
    if not variants or #variants == 0 then return nil end
    return variants[math.random(1, #variants)]
end

local function emit(entity, soundKey, volume, pitchMultiplier)
    if not IsValid(entity) then return end
    local filename = randomVariant(soundKey)
    if not filename then return end
    entity:EmitSound(
        "mcitem/food/" .. filename,
        75,
        math.Clamp(math.floor((pitchMultiplier or 1) * 100 + 0.5), 1, 255),
        math.Clamp(volume or 1, 0, 1),
        CHAN_AUTO
    )
end

-- Consumable.emitParticlesAndSounds.
function Food.PlayUseSound(entity, definition)
    if not istable(definition) then return end
    if definition.animation == "drink" then
        emit(entity, definition.sound, 0.5, math.Rand(0.9, 1.0))
    else
        emit(entity, definition.sound, math.random(0, 1) == 1 and 0.5 or 1.0, triangle(1, 0.2))
    end
end

-- FoodProperties.onConsume: a second consume sound, then PLAYER_BURP.  Hunger
-- mutation itself is deliberately left to MCITEM.FoodConsumed.
function Food.PlayFoodCompletionSounds(entity, definition)
    if not istable(definition) then return end
    emit(entity, definition.sound, 1.0, triangle(1, 0.4))
    emit(entity, "player_burp", 0.5, math.Rand(0.9, 1.0))
end
