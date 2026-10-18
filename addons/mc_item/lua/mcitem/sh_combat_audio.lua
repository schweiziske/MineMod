-- Shared registration for Minecraft 26.2 player attack sound events.
-- sound.Add is intentionally run in both realms so multiplayer clients resolve the same
-- script names that the server passes to Entity:EmitSound.

MCITEM = MCITEM or {}

-- Every entry mirrors its sounds.json volume. Minecraft chooses uniformly from the
-- entries (rather than only from unique files), so keep this as an entry list even
-- when future events contain the same wave more than once with different settings.
MCITEM.AttackSoundEvents = {
    weak = {
        { file = "weak1.ogg", volume = 0.7 },
        { file = "weak2.ogg", volume = 0.7 },
        { file = "weak3.ogg", volume = 0.7 },
        { file = "weak4.ogg", volume = 0.7 },
    },
    strong = {
        { file = "strong1.ogg", volume = 0.6 },
        { file = "strong2.ogg", volume = 0.6 },
        { file = "strong3.ogg", volume = 0.6 },
        { file = "strong4.ogg", volume = 0.6 },
        { file = "strong5.ogg", volume = 0.7 },
        { file = "strong6.ogg", volume = 0.7 },
    },
    crit = {
        { file = "crit1.ogg", volume = 0.7 },
        { file = "crit2.ogg", volume = 0.7 },
        { file = "crit3.ogg", volume = 0.7 },
    },
    knockback = {
        { file = "knockback1.ogg", volume = 0.7 },
        { file = "knockback2.ogg", volume = 0.7 },
        { file = "knockback3.ogg", volume = 0.7 },
        { file = "knockback4.ogg", volume = 0.7 },
    },
    sweep = {
        { file = "sweep1.ogg", volume = 0.7 },
        { file = "sweep2.ogg", volume = 0.7 },
        { file = "sweep3.ogg", volume = 0.7 },
        { file = "sweep4.ogg", volume = 0.7 },
        { file = "sweep5.ogg", volume = 0.7 },
        { file = "sweep6.ogg", volume = 0.7 },
        { file = "sweep7.ogg", volume = 0.7 },
    },
}

MCITEM.AttackSoundFiles = {}
for key, variants in pairs(MCITEM.AttackSoundEvents) do
    local files = {}
    for _, variant in ipairs(variants) do files[#files + 1] = variant.file end
    MCITEM.AttackSoundFiles[key] = files
end

MCITEM.AttackSoundNames = MCITEM.AttackSoundNames or {}

for key, files in pairs(MCITEM.AttackSoundFiles) do
    local waves = {}
    for _, filename in ipairs(files) do
        local path = "mcitem/attack/" .. filename
        waves[#waves + 1] = path
        if SERVER then resource.AddFile("sound/" .. path) end
    end

    local soundName = "MCITEM.Attack." .. key
    MCITEM.AttackSoundNames[key] = soundName
    sound.Add({
        name = soundName,
        channel = CHAN_AUTO,
        volume = 1,
        level = 75,
        pitch = 100,
        sound = waves,
    })
end

function MCITEM.PlayAttackSound(entity, key, volume, pitch)
    if not IsValid(entity) then return end

    local variants = MCITEM.AttackSoundEvents[key]
    if not variants or #variants == 0 then return end

    local variant = variants[math.random(1, #variants)]
    local finalVolume = math.Clamp((volume or 1) * (variant.volume or 1), 0, 1)
    local finalPitch = math.Clamp(math.floor((pitch or 100) * (variant.pitch or 1) + 0.5), 0, 255)
    entity:EmitSound("mcitem/attack/" .. variant.file, 75, finalPitch, finalVolume, CHAN_AUTO)
end
