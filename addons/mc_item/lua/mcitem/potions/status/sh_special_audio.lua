-- Minecraft Java 26.2 sound events used by the four special potion effects.

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

Potions.SpecialSoundVariants = Potions.SpecialSoundVariants or {
    -- sounds.json: entity.breeze.wind_burst; every wave has pitch 1.2.
    wind_burst = {
        { file = "wind_burst1.ogg", resourcePitch = 1.2 },
        { file = "wind_burst2.ogg", resourcePitch = 1.2 },
        { file = "wind_burst3.ogg", resourcePitch = 1.2 },
    },
    -- SoundEvents.SILVERFISH_HURT has three equally weighted waves and no
    -- per-wave volume/pitch override.
    silverfish_hurt = {
        { file = "silverfish_hurt1.ogg", resourcePitch = 1 },
        { file = "silverfish_hurt2.ogg", resourcePitch = 1 },
        { file = "silverfish_hurt3.ogg", resourcePitch = 1 },
    },
}

if SERVER then
    for _, variants in pairs(Potions.SpecialSoundVariants) do
        for _, variant in ipairs(variants) do
            resource.AddFile("sound/mcitem/potions/" .. variant.file)
        end
    end
end

local function randomVariant(eventId)
    local variants = Potions.SpecialSoundVariants[eventId]
    if not variants or #variants == 0 then return nil end
    return variants[math.random(1, #variants)]
end

local function sourcePitch(multiplier)
    return math.Clamp(math.floor((tonumber(multiplier) or 1) * 100 + 0.5), 1, 255)
end

local function playAt(eventId, position, minecraftVolume, minecraftPitch, soundLevel)
    if not isvector(position) then return false end
    local variant = randomVariant(eventId)
    if not variant then return false end

    local parameters = {
        event = eventId,
        path = "mcitem/potions/" .. variant.file,
        minecraftVolume = minecraftVolume,
        minecraftPitch = minecraftPitch,
        resourcePitch = variant.resourcePitch or 1,
        sourceSoundLevel = soundLevel,
    }
    parameters.finalPitch = parameters.minecraftPitch * parameters.resourcePitch

    -- Exact Minecraft values are exposed before Source's 0..1 volume adapter.
    -- Integrations that own a Minecraft sound mixer can consume them directly.
    if hook.Run("MCITEM.PlayPotionSound", position, parameters) == true then return true end

    sound.Play(
        parameters.path,
        position,
        soundLevel,
        sourcePitch(parameters.finalPitch),
        math.Clamp(minecraftVolume, 0, 1)
    )
    return true
end

function Potions.PlayWindChargedBurst(position)
    -- ServerExplosion packet pitch:
    -- (1 + (random - random) * 0.2) * 0.7, then sounds.json multiplies 1.2.
    local pitch = (1 + (math.Rand(0, 1) - math.Rand(0, 1)) * 0.2) * 0.7
    return playAt("wind_burst", position, 4.0, pitch, 80)
end

function Potions.PlayInfestedSilverfishHurt(silverfish)
    if not IsValid(silverfish) then return false end
    -- Entity.playSound(SILVERFISH_HURT): volume 1, pitch 1.
    return playAt("silverfish_hurt", silverfish:WorldSpaceCenter(), 1.0, 1.0, 75)
end
