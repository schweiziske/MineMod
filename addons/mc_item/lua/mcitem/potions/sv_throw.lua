-- Server-authoritative ThrowablePotionItem.use adapter.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local Potions = MCITEM.Potions

function Potions.CanThrow(weapon, owner, definition, bottleType)
    if not IsValid(weapon) or not IsValid(owner) or not istable(definition) then return false end
    if bottleType ~= "splash" and bottleType ~= "lingering" then return false end

    if isfunction(weapon.CanMCThrowPotion) then
        local result = weapon:CanMCThrowPotion(owner, definition, bottleType)
        if result ~= nil then return result ~= false end
    end

    local result = hook.Run("MCITEM.CanThrowPotion", owner, weapon, definition, bottleType)
    if result ~= nil then return result ~= false end
    return true
end

local function projectileOrigin(owner)
    -- ThrowableItemProjectile(LivingEntity): (getX, getEyeY - 0.1, getZ).
    local feet = owner:GetPos()
    return Vector(feet.x, feet.y, owner:EyePos().z - 0.1 * MCITEM.BlockSize())
end

local function projectileDirection(owner)
    -- Projectile.shootFromRotation receives xRot, yRot and -20 degrees.
    local angles = owner:EyeAngles()
    angles = Angle(angles.p + Potions.ProjectilePitchOffset, angles.y, 0)
    return angles:Forward()
end

-- Public server-side projectile bridge for mobs and other non-SWEP callers.
--
-- The caller chooses the Java launch vector while MCITEM remains responsible
-- for the canonical potion model, manual 20 Hz flight, collision, splash/cloud
-- application, particles and break audio.  In particular, BMB witches must use
-- this instead of maintaining a second thrown-potion implementation.
function Potions.SpawnThrown(owner, bottleType, potionId, options)
    if not IsValid(owner) then return nil end
    if bottleType ~= "splash" and bottleType ~= "lingering" then return nil end

    local definition = Potions.Get(potionId)
    if not definition then return nil end

    options = istable(options) and options or {}
    local origin = isvector(options.position) and options.position
        or (isvector(options.origin) and options.origin or projectileOrigin(owner))
    local direction = isvector(options.direction) and options.direction or projectileDirection(owner)
    if direction:LengthSqr() <= 0 then return nil end

    local power = tonumber(options.power) or Potions.ProjectilePower
    local uncertainty = math.max(0, tonumber(options.uncertainty) or Potions.ProjectileUncertainty)
    if power <= 0 then return nil end

    local projectile = ents.Create("mcitem_thrown_potion")
    if not IsValid(projectile) then return nil end

    projectile:SetPos(origin)
    if not projectile:SetupPotion(owner, bottleType, definition.id) then
        projectile:Remove()
        return nil
    end
    projectile:Spawn()
    projectile:Activate()
    projectile:StartMCFlight(owner, direction, power, uncertainty, {
        inheritOwnerVelocity = options.inheritOwnerVelocity ~= false,
    })

    if options.playSound ~= false then
        local soundEntity = IsValid(options.soundEntity) and options.soundEntity or owner
        Potions.PlayThrowSound(soundEntity)
    end

    local context = istable(options.context) and options.context or {}
    context.potion = definition
    context.potionId = definition.id
    context.bottleType = bottleType
    context.projectile = projectile
    if not options.prepare then
        hook.Run("MCITEM.PotionProjectileSpawned", owner, projectile, definition, bottleType, context)
    end
    return projectile, context
end

-- Descriptive alias retained as the documented adapter name.  SpawnThrown is
-- kept for callers that integrated against the first public revision.
Potions.SpawnThrownPotion = Potions.SpawnThrown

function Potions.Throw(weapon, useContext)
    if not IsValid(weapon) then return nil end
    local owner = weapon:GetOwner()
    local definition = useContext and useContext.definition or Potions.DefinitionForWeapon(weapon)
    local bottleType = useContext and useContext.bottleType or Potions.BottleTypeForWeapon(weapon)
    if not Potions.CanThrow(weapon, owner, definition, bottleType) then return nil end

    local projectile, context = Potions.SpawnThrown(owner, bottleType, definition.id, {
        origin = projectileOrigin(owner),
        direction = projectileDirection(owner),
        power = Potions.ProjectilePower,
        uncertainty = Potions.ProjectileUncertainty,
        -- SplashPotionItem/LingeringPotionItem play before the shared use
        -- method; EmitSound broadcasts the server event to nearby clients.
        playSound = false,
        prepare = true,
        context = {
            useStack = useContext and useContext.useStack or hook.Run("MCITEM.CaptureUseStack", owner, weapon),
            hand = useContext and useContext.hand,
            weapon = weapon,
            delivery = "weapon_throw",
        },
    })
    if not IsValid(projectile) then return nil end

    if hook.Run("MCITEM.ConsumePotionItem", owner, weapon, bottleType, definition.id,
        1, nil, context) == false then
        projectile:Remove()
        return nil
    end
    Potions.PlayThrowSound(owner)
    hook.Run("MCITEM.PotionProjectileSpawned", owner, projectile, definition, bottleType, context)

    if IsValid(weapon) and isfunction(weapon.OnMCPotionThrown) then
        weapon:OnMCPotionThrown(owner, projectile, definition, bottleType, context)
    end
    hook.Run("MCITEM.PotionThrown", owner, weapon, projectile, definition, bottleType, context)
    return projectile
end
