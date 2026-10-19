-- Server-authoritative use adapter for the six Java 26.2 throwable items.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
if (Throwables.ThrowAdapterVersion or 0) >= 3 then return end
Throwables.ThrowAdapterVersion = 3
Throwables.ThrowAdapterLoaded = true

local function enderEyeOrigin(owner)
    local position = owner:GetPos()
    local minimum, maximum = owner:WorldSpaceAABB()
    return Vector(position.x, position.y, (minimum.z + maximum.z) * 0.5)
end

function Throwables.SpawnConfigured(owner, identifier, options)
    options = options or {}
    local definition = Throwables.Get(istable(identifier) and identifier.id or identifier)
    if not istable(definition) or definition.id == "ender_eye" then return nil end
    if not isstring(definition.entityClass) or definition.entityClass == "" then return nil end
    if not isvector(options.position) and not IsValid(owner) then return nil end
    if not isvector(options.direction) and not IsValid(owner) then return nil end

    local projectile = ents.Create(definition.entityClass)
    if not IsValid(projectile) then return nil end
    local position = isvector(options.position)
        and options.position or Throwables.ProjectileOrigin(owner, definition)
    projectile:SetPos(position)
    if not projectile:SetupThrowable(owner, definition.id) then
        projectile:Remove()
        return nil
    end

    -- Server-only runtime values deliberately do not mutate the shared item
    -- definition.  A mob may therefore reuse the exact Wind Charge entity and
    -- renderer while supplying its Java entity-type constants.
    projectile.MCThrowableRuntime = istable(options.runtime)
        and table.Copy(options.runtime) or {}
    projectile:Spawn()
    projectile:Activate()
    local direction = isvector(options.direction)
        and options.direction or Throwables.ProjectileDirection(owner, definition)
    projectile:StartMCFlight(
        owner,
        direction,
        tonumber(options.power) or definition.power,
        options.uncertainty ~= nil and tonumber(options.uncertainty) or definition.uncertainty
    )
    return projectile
end

local function spawnGeneric(owner, definition)
    return Throwables.SpawnConfigured(owner, definition)
end

local function spawnEnderEye(owner, weapon, definition)
    local projectile = ents.Create(definition.entityClass)
    if not IsValid(projectile) then return nil end
    projectile:SetPos(enderEyeOrigin(owner))
    projectile:Spawn()
    projectile:Activate()
    projectile:SetupEnderEye(owner, Throwables.ResolveEnderEyeTarget(owner, weapon))
    return projectile
end

function Throwables.Use(weapon, useContext)
    if not IsValid(weapon) then return nil end
    local owner = weapon:GetOwner()
    local definition = useContext and useContext.definition or Throwables.DefinitionForWeapon(weapon)
    if not Throwables.CanUse(weapon, owner, definition) then return nil end
    local useStack = useContext and useContext.useStack or hook.Run("MCITEM.CaptureUseStack", owner, weapon)

    local projectile
    if definition.id == "ender_eye" then
        projectile = spawnEnderEye(owner, weapon, definition)
    else
        projectile = spawnGeneric(owner, definition)
    end
    if not IsValid(projectile) then return nil end

    local context = {
        definition = definition,
        projectile = projectile,
        weapon = weapon,
        useStack = useStack,
        hand = useContext and useContext.hand,
    }
    if not Throwables.Consume(owner, weapon, definition, context) then
        projectile:Remove()
        return nil
    end
    Throwables.StartCooldown(owner, definition)
    if definition.id == "ender_eye" then Throwables.PlayEnderEyeLaunch(owner)
    else Throwables.PlayStandardThrow(owner, definition.soundEvent) end
    if IsValid(weapon) and isfunction(weapon.OnMCThrowableUsed) then
        weapon:OnMCThrowableUsed(owner, projectile, definition, context)
    end
    hook.Run("MCITEM.ThrowableUsed", owner, weapon, projectile, definition, context)
    return projectile
end
