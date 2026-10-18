-- Minecraft Java 26.2 throwable item constants.
-- Sources: the six Item.use methods, ThrowableProjectile, WindCharge,
-- ThrownExperienceBottle and EyeOfEnder (verified with javap -p -c).

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables

-- Keep the definition array stable across entity-level re-includes.  The old
-- unconditional assignment silently deleted definitions registered by other
-- addons as soon as mcitem_thrown_generic loaded its shared file again.
Throwables.Definitions = Throwables.Definitions or {
    {
        id = "wind_charge",
        name = "Wind Charge",
        modelId = "wind_charge",
        entityClass = "mcitem_thrown_generic",
        behavior = "wind_charge",
        pitchOffset = 0,
        power = 1.5,
        uncertainty = 1,
        gravity = 0,
        inertia = 1,
        -- GMod's held-item origin sits lower than Minecraft's WindChargeItem
        -- spawn point, so apply a 0.2-block visual compensation here.
        originEyeOffset = 0.2,
        -- EntityTypes.WIND_CHARGE is sized(0.3125F, 0.3125F).
        collisionRadius = 0.15625,
        soundEvent = "wind_throw",
        cooldownTicks = 10,
    },
    {
        id = "ender_pearl",
        name = "Ender Pearl",
        modelId = "ender_pearl",
        entityClass = "mcitem_thrown_generic",
        behavior = "ender_pearl",
        pitchOffset = 0,
        power = 1.5,
        uncertainty = 1,
        gravity = 0.03,
        inertia = 0.99,
        originEyeOffset = -0.1,
        collisionRadius = 0.125,
        soundEvent = "ender_pearl_throw",
        cooldownTicks = 20,
    },
    {
        id = "snowball",
        name = "Snowball",
        modelId = "snowball",
        entityClass = "mcitem_thrown_generic",
        behavior = "snowball",
        pitchOffset = 0,
        power = 1.5,
        uncertainty = 1,
        gravity = 0.03,
        inertia = 0.99,
        originEyeOffset = -0.1,
        collisionRadius = 0.125,
        soundEvent = "snowball_throw",
    },
    {
        id = "egg",
        name = "Egg",
        modelId = "egg",
        entityClass = "mcitem_thrown_generic",
        behavior = "egg",
        pitchOffset = 0,
        power = 1.5,
        uncertainty = 1,
        gravity = 0.03,
        inertia = 0.99,
        originEyeOffset = -0.1,
        collisionRadius = 0.125,
        soundEvent = "egg_throw",
    },
    {
        id = "experience_bottle",
        name = "Bottle o' Enchanting",
        modelId = "experience_bottle",
        entityClass = "mcitem_thrown_generic",
        behavior = "experience_bottle",
        pitchOffset = -20,
        power = 0.7,
        uncertainty = 1,
        gravity = 0.07,
        inertia = 0.99,
        originEyeOffset = -0.1,
        collisionRadius = 0.125,
        soundEvent = "experience_bottle_throw",
    },
    {
        id = "ender_eye",
        name = "Eye of Ender",
        modelId = "ender_eye",
        entityClass = "mcitem_eye_of_ender",
        behavior = "ender_eye",
        soundEvent = "ender_eye_launch",
    },
}

Throwables.ByID = {}
for _, definition in ipairs(Throwables.Definitions) do
    Throwables.ByID[definition.id] = definition
end

function Throwables.Get(identifier)
    if not isstring(identifier) then return nil end
    identifier = string.gsub(identifier, "^minecraft:", "")
    return Throwables.ByID[identifier]
end

-- Backward-compatible external extension point.  Registrations are idempotent
-- by canonical id; callers may opt out of the MCITEM player SWEP/spawn-menu
-- surface while still reusing SpawnConfigured and the shared projectile stack.
function Throwables.RegisterDefinition(definition, options)
    if not istable(definition) or not isstring(definition.id) then
        return nil, false, "invalid_definition"
    end
    local identifier = string.gsub(string.lower(definition.id), "^minecraft:", "")
    if identifier == "" then return nil, false, "invalid_id" end

    local existing = Throwables.ByID[identifier]
    if existing then return existing, false end

    options = istable(options) and options or {}
    local stored = table.Copy(definition)
    stored.id = identifier
    if options.registerWeapon == false then stored.registerWeapon = false end
    Throwables.Definitions[#Throwables.Definitions + 1] = stored
    Throwables.ByID[identifier] = stored
    return stored, true
end

Throwables.RegisterDefinition({
    id = "llama_spit",
    name = "Llama Spit",
    modelId = "llama_spit",
    entityClass = "mcitem_thrown_generic",
    behavior = "llama_spit",
    power = 1.5,
    uncertainty = 10,
    gravity = 0.06,
    inertia = 0.99,
    collisionRadius = 0.125,
    registerWeapon = false,
}, {
    registerWeapon = false,
})
