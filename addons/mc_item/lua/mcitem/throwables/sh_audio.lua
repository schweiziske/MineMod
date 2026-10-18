-- Runtime player for generated Minecraft 26.2 throwable sound variants.

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

for _, variants in pairs(Throwables.SoundEvents or {}) do
    for _, variant in ipairs(variants) do
        if SERVER then resource.AddFile("sound/mcitem/throwables/" .. variant.file) end
    end
end

local function weightedVariant(eventId)
    local variants = Throwables.SoundEvents and Throwables.SoundEvents[eventId]
    if not variants or #variants == 0 then return nil end
    local total = 0
    for _, variant in ipairs(variants) do total = total + math.max(1, variant.weight or 1) end
    local selected = math.random(1, total)
    for _, variant in ipairs(variants) do
        selected = selected - math.max(1, variant.weight or 1)
        if selected <= 0 then return variant end
    end
    return variants[#variants]
end

local function sourcePitch(multiplier)
    return math.Clamp(math.floor((tonumber(multiplier) or 1) * 100 + 0.5), 1, 255)
end

function Throwables.PlaySound(eventId, position, minecraftVolume, minecraftPitch, soundLevel, entity)
    if not isvector(position) then return false end
    local variant = weightedVariant(eventId)
    if not variant then return false end
    local parameters = {
        event = eventId,
        path = "mcitem/throwables/" .. variant.file,
        minecraftVolume = tonumber(minecraftVolume) or 1,
        minecraftPitch = tonumber(minecraftPitch) or 1,
        resourceVolume = tonumber(variant.volume) or 1,
        resourcePitch = tonumber(variant.pitch) or 1,
        sourceSoundLevel = tonumber(soundLevel) or 75,
    }
    parameters.finalVolume = parameters.minecraftVolume * parameters.resourceVolume
    parameters.finalPitch = parameters.minecraftPitch * parameters.resourcePitch

    if hook.Run("MCITEM.PlayThrowableSound", position, parameters, entity) == true then return true end
    if IsValid(entity) then
        entity:EmitSound(
            parameters.path,
            parameters.sourceSoundLevel,
            sourcePitch(parameters.finalPitch),
            math.Clamp(parameters.finalVolume, 0, 1),
            CHAN_AUTO
        )
    else
        sound.Play(
            parameters.path,
            position,
            parameters.sourceSoundLevel,
            sourcePitch(parameters.finalPitch),
            math.Clamp(parameters.finalVolume, 0, 1)
        )
    end
    return true
end

function Throwables.PlayStandardThrow(entity, eventId)
    if not IsValid(entity) then return false end
    -- WindChargeItem, EnderpearlItem, SnowballItem, EggItem and
    -- ExperienceBottleItem all use this exact expression in 26.2.
    local pitch = 0.4 / (math.Rand(0, 1) * 0.4 + 0.8)
    return Throwables.PlaySound(eventId, entity:GetPos(), 0.5, pitch, 75, entity)
end

function Throwables.PlayEnderEyeLaunch(entity)
    if not IsValid(entity) then return false end
    return Throwables.PlaySound(
        "ender_eye_launch",
        entity:GetPos(),
        1,
        Lerp(math.Rand(0, 1), 0.33, 0.5),
        75,
        entity
    )
end

function Throwables.PlayEnderEyeDeath(entity)
    if not IsValid(entity) then return false end
    return Throwables.PlaySound("ender_eye_death", entity:GetPos(), 1, 1, 75, entity)
end

function Throwables.PlayPearlTeleport(position)
    return Throwables.PlaySound("player_teleport", position, 1, 1, 75)
end

function Throwables.PlayChorusFruitTeleport(position, entity)
    return Throwables.PlaySound("chorus_fruit_teleport", position, 1, 1, 75, entity)
end

function Throwables.PlayExperiencePickup(position)
    local pitch = (math.Rand(0, 1) - math.Rand(0, 1)) * 0.35 + 0.9
    return Throwables.PlaySound("experience_orb_pickup", position, 0.1, pitch, 75)
end

function Throwables.PlayExperienceBottleBreak(position)
    return Throwables.PlaySound(
        "splash_potion_break",
        position,
        1,
        math.Rand(0, 1) * 0.1 + 0.9,
        75
    )
end

function Throwables.PlayWindBurst(position)
    local pitch = (1 + (math.Rand(0, 1) - math.Rand(0, 1)) * 0.2) * 0.7
    return Throwables.PlaySound("wind_burst", position, 4, pitch, 80)
end
