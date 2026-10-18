AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
AddCSLuaFile("mcitem/fishing/cl_effects.lua")

include("shared.lua")
include("mcitem/fishing/sv_loot.lua")
include("mcitem/fishing/sv_effects.lua")
include("mcitem/throwables/sh_collision.lua")

local Fishing = MCITEM.Fishing
local TICK_SECONDS = Fishing.TickSeconds

local OPEN_INVALID = 0
local OPEN_ABOVE_WATER = 1
local OPEN_INSIDE_WATER = 2

local function living(entity)
    return IsValid(entity) and (entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot()
        or entity.IsBMBMob == true)
end

-- MCSWEP's block world is made of entities. They are scenery, not catchable
-- targets, so they are rejected by class before anything else looks at them.
local WORLD_COLLISION_CLASSES = {
    mc_chunk = true,
    mc_chunk_phys = true,
    mc_collision_carrier = true,
    mc_block_cluster = true,
}

-- FishingHook.pullEntity works on whatever the hook collided with, not just
-- living targets, which is why vanilla lets you reel in primed TNT. Duck-typed:
-- an entity that exposes Minecraft's manual movement impulse is one this pull
-- can actually move, so no hard dependency on any particular addon is taken.
local function manualMovementEntity(entity)
    return isfunction(entity.MCAddExplosionVelocity)
end

local function validHookedEntity(entity)
    if not IsValid(entity) then return false end
    if WORLD_COLLISION_CLASSES[entity:GetClass()] then return false end
    if Fishing.IsItemEntity(entity) then return true end
    if manualMovementEntity(entity) then return true end
    if not living(entity) then return false end
    if entity:IsPlayer() and not entity:Alive() then return false end
    if entity.BMBDead == true then return false end
    if entity.Health and tonumber(entity:Health()) and entity:Health() <= 0 then return false end
    return true
end

local function entityPositionAt(entity, fraction)
    local minimum, maximum = entity:WorldSpaceAABB()
    local origin = entity:GetPos()
    return Vector(origin.x, origin.y, Lerp(fraction, minimum.z, maximum.z))
end

local function activeFishingRod(owner, expected)
    if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then return false end
    if owner.GetObserverMode and owner:GetObserverMode() ~= OBS_MODE_NONE then return false end
    local weapon = owner:GetActiveWeapon()
    if not IsValid(weapon) or weapon:GetClass() ~= "weapon_mcitem_fishing_rod" then return false end
    if IsValid(expected) and weapon ~= expected then return false end
    return true
end

function ENT:Initialize()
    self:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
    local radius = Fishing.HookWidth * 0.5 * Fishing.BlockSize()
    self:SetCollisionBounds(Vector(-radius, -radius, -radius), Vector(radius, radius, radius))
    self:DrawShadow(false)
    self:SetHookedEntity(NULL)
    self:SetMCVelocity(vector_origin)
    self:SetBiting(false)
    self:SetMCOnGround(false)
    self:SetOpenWater(true)
    self:SetHookState(Fishing.State.FLYING)
    self.MCLife = 0
    self.MCOutOfWaterTime = 0
    self.MCNibble = 0
    self.MCTimeUntilLured = 0
    self.MCTimeUntilHooked = 0
    self.MCFishAngle = 0
    self.MCProjectileAge = 0
    self.MCNextTick = CurTime() + TICK_SECONDS
    self:NextThink(self.MCNextTick)
end

function ENT:Launch(owner, weapon, rodStack)
    if IsValid(owner) then self:SetOwner(owner) end
    if IsValid(weapon) then
        self.MCWeapon = weapon
        self:SetNW2Entity("MCITEM_FishingRod", weapon)
    end
    self.MCRodStack = istable(rodStack) and table.Copy(rodStack)
        or { item = "minecraft:fishing_rod", count = 1 }
    self.MCLuck = Fishing.Luck(self.MCRodStack, owner)
    self.MCLureSpeed = Fishing.LureSpeed(self.MCRodStack)
    local velocity = Fishing.LaunchVelocity(owner)
    self:SetMCVelocity(velocity)
    return velocity
end

function ENT:ShouldStopFishing(owner)
    local weapon = self:GetRodWeapon()
    if not activeFishingRod(owner, weapon) then return true end
    local maximum = Fishing.MaxOwnerDistance * Fishing.BlockSize()
    return self:GetPos():DistToSqr(owner:GetPos()) > maximum * maximum
end

function ENT:ShouldMCProjectileHitEntity(entity)
    if entity == self.MCWeapon then return false end
    -- 钓钩永远不勾自己的主人。
    --
    -- 注意这里是**故意偏离原版**的：Java 的 Projectile.canHitEntity 只用 leftOwner
    -- 挡住"刚出手那几 tick"，一旦浮标离开主人的碰撞盒，canHitEntity(owner) 就返回
    -- true，所以原版理论上能把自己勾住（往上抛再站到落点下面）。那在原版几乎碰不到，
    -- 在 GMod 里第三人称加上这边的抛物线很容易复现，而且 pullEntity 会拿"自己指向
    -- 自己"的零向量去拉，行为没有意义。箭和投掷物仍然保留原版的 leftOwner 语义。
    if entity == self:GetOwner() then return false end
    return true
end

function ENT:SetMCHookedEntity(entity)
    self:SetHookedEntity(IsValid(entity) and entity or NULL)
    if IsValid(entity) then
        self:SetHookState(Fishing.State.HOOKED_IN_ENTITY)
        self:SetMCVelocity(vector_origin)
    end
end

function ENT:OpenWaterBlockType(bx, by, bz)
    local world = MC and MC.API and MC.API.World
    if not world or not isfunction(world.GetBlockInfo) then return OPEN_INVALID end
    if isfunction(world.IsCellLoaded) and world.IsCellLoaded(bx, by, bz) ~= true then
        return OPEN_INVALID
    end
    local info = world.GetBlockInfo(bx, by, bz)
    local identifier = info and tostring(info.name or info.mcid or "") or ""
    if identifier ~= "" and not string.find(identifier, ":", 1, true) then
        identifier = "minecraft:" .. identifier
    end
    if not info or identifier == "minecraft:lily_pad" then return OPEN_ABOVE_WATER end

    local fluid = Fishing.FluidAtCell(bx, by, bz)
    if not fluid or fluid.kind ~= "water"
        or math.floor(tonumber(fluid.level) or -1) ~= 0
        or fluid.falling == true
    then
        return OPEN_INVALID
    end
    local shape = isfunction(world.GetCellShape) and world.GetCellShape(bx, by, bz) or nil
    if shape and shape.hasCollision == true then return OPEN_INVALID end
    return OPEN_INSIDE_WATER
end

function ENT:OpenWaterLayerType(fromX, fromY, fromZ, toX, toY, toZ)
    local expected
    for bx = fromX, toX do
        for by = fromY, toY do
            for bz = fromZ, toZ do
                local value = self:OpenWaterBlockType(bx, by, bz)
                if not expected then expected = value elseif expected ~= value then return OPEN_INVALID end
            end
        end
    end
    return expected or OPEN_INVALID
end

function ENT:CalculateOpenWater(bx, by, bz, fluid)
    if fluid and fluid.source == true then
        local surface = Fishing.WaterSurfacePosition(self:GetPos(), self)
        return isvector(surface) and Fishing.CalculateSourceOpenWater(surface)
    end
    local previous = OPEN_INVALID
    for zOffset = Fishing.OpenWaterMinY, Fishing.OpenWaterMaxY do
        local layer = self:OpenWaterLayerType(
            bx - Fishing.OpenWaterRadius,
            by - Fishing.OpenWaterRadius,
            bz + zOffset,
            bx + Fishing.OpenWaterRadius,
            by + Fishing.OpenWaterRadius,
            bz + zOffset
        )
        if layer == OPEN_INVALID then return false end
        if layer == OPEN_ABOVE_WATER and previous == OPEN_INVALID then return false end
        if layer == OPEN_INSIDE_WATER and previous == OPEN_ABOVE_WATER then return false end
        previous = layer
    end
    return true
end

function ENT:WaterSurfacePosition(position)
    return Fishing.WaterSurfacePosition(position, self)
end

function ENT:CatchingFish(bx, by, bz, fluid)
    local fishingSpeed = 1
    if math.Rand(0, 1) < 0.25 and Fishing.IsRainingAt(bx, by, bz + 1, self) then
        fishingSpeed = fishingSpeed + 1
    end
    local canSeeSky
    if fluid and fluid.source == true then
        local surface = Fishing.WaterSurfacePosition(self:GetPos(), self)
        canSeeSky = isvector(surface) and Fishing.CanSeeSourceSky(surface, self)
    else
        canSeeSky = Fishing.CanSeeSky(bx, by, bz + 1, self)
    end
    if math.Rand(0, 1) < 0.5 and not canSeeSky then
        fishingSpeed = fishingSpeed - 1
    end

    if self.MCNibble > 0 then
        self.MCNibble = self.MCNibble - 1
        if self.MCNibble <= 0 then
            self.MCTimeUntilLured = 0
            self.MCTimeUntilHooked = 0
            self:SetBiting(false)
        end
        return
    end

    if self.MCTimeUntilHooked > 0 then
        self.MCTimeUntilHooked = self.MCTimeUntilHooked - fishingSpeed
        if self.MCTimeUntilHooked > 0 then
            self.MCFishAngle = self.MCFishAngle + Fishing.Triangle(0, 9.188)
            local angle = math.rad(self.MCFishAngle)
            local angleSin, angleCos = math.sin(angle), math.cos(angle)
            local fishPosition = self:GetPos()
                + Vector(angleSin, angleCos, 0)
                * (self.MCTimeUntilHooked * 0.1 * Fishing.BlockSize())
            local surface, waterX, waterY, waterZ, waterFluid = self:WaterSurfacePosition(fishPosition)
            if isvector(surface) and Fishing.IsFishingWaterFluid(waterFluid, waterX, waterY, waterZ) then
                local velocity = Vector(angleCos * 0.04, -angleSin * 0.04, 0.01)
                Fishing.SendEffect(
                    Fishing.FX.APPROACH,
                    surface,
                    velocity,
                    2,
                    math.Rand(0, 1) < 0.15
                )
            end
        else
            Fishing.PlaySound(
                "entity.fishing_bobber.splash",
                self:GetPos(),
                0.25,
                1 + (math.Rand(0, 1) - math.Rand(0, 1)) * 0.4,
                72
            )
            local count = math.floor(1 + Fishing.HookWidth * 20)
            Fishing.SendEffect(
                Fishing.FX.BITE,
                self:GetPos() + Vector(0, 0, 0.5 * Fishing.BlockSize()),
                vector_origin,
                count,
                true
            )
            self.MCNibble = math.random(Fishing.BiteMinTicks, Fishing.BiteMaxTicks)
            self:SetBiting(true)
            self.MCBiteVelocityZ = -0.4 * math.Rand(0.6, 1)
        end
        return
    end

    if self.MCTimeUntilLured > 0 then
        self.MCTimeUntilLured = self.MCTimeUntilLured - fishingSpeed
        local chance = 0.15
        if self.MCTimeUntilLured < 20 then
            chance = chance + (20 - self.MCTimeUntilLured) * 0.05
        elseif self.MCTimeUntilLured < 40 then
            chance = chance + (40 - self.MCTimeUntilLured) * 0.02
        elseif self.MCTimeUntilLured < 60 then
            chance = chance + (60 - self.MCTimeUntilLured) * 0.01
        end
        if math.Rand(0, 1) < chance then
            local angle = math.rad(math.Rand(0, 360))
            local distance = math.Rand(25, 60)
            local fishPosition = self:GetPos()
                + Vector(math.sin(angle), math.cos(angle), 0)
                * (distance * 0.1 * Fishing.BlockSize())
            local surface, waterX, waterY, waterZ, waterFluid = self:WaterSurfacePosition(fishPosition)
            if isvector(surface) and Fishing.IsFishingWaterFluid(waterFluid, waterX, waterY, waterZ) then
                Fishing.SendEffect(Fishing.FX.TEASE_SPLASH, surface, vector_origin, 2 + math.random(0, 1), false)
            end
        end
        if self.MCTimeUntilLured <= 0 then
            self.MCFishAngle = math.Rand(0, 360)
            self.MCTimeUntilHooked = math.random(Fishing.ApproachMinTicks, Fishing.ApproachMaxTicks)
        end
        return
    end

    self.MCTimeUntilLured = math.random(Fishing.WaitMinTicks, Fishing.WaitMaxTicks)
        - math.max(0, math.floor(self.MCLureSpeed or 0))
end

function ENT:FollowHookedEntity()
    local target = self:GetHookedEntity()
    if validHookedEntity(target) then
        self:SetPos(entityPositionAt(target, 0.8))
        return true
    end
    self:SetHookedEntity(NULL)
    self:SetHookState(Fishing.State.FLYING)
    return false
end

function ENT:TraceFlight(destination)
    local throwables = MCITEM.Throwables
    if throwables and isfunction(throwables.TraceProjectile) then
        local trace = throwables.TraceProjectile(self, self:GetPos(), destination)
        -- MC.API.World.TraceRay deliberately follows Minecraft's OUTLINE
        -- targeting geometry.  Standalone liquid states have no authored
        -- outline, so MCSWEP's generic trace falls back to the whole cell and
        -- reports water as a block hit.  A FishingHook collision clip uses
        -- Block.COLLIDER + Fluid.NONE instead: pure water must not stop the
        -- projectile before its next tick can observe the water FluidState and
        -- enter BOBBING.  Keep this exception local to fishing so arrows and
        -- every other throwable retain their existing block-targeting contract.
        if trace and trace.Hit == true and trace.HitMCBlock == true
            and trace.bx ~= nil and trace.by ~= nil and trace.bz ~= nil
        then
            local fluid = Fishing.FluidAtCell(trace.bx, trace.by, trace.bz)
            local world = MC and MC.API and MC.API.World
            local shape = world and isfunction(world.GetCellShape)
                and world.GetCellShape(trace.bx, trace.by, trace.bz) or nil
            if fluid and fluid.waterlogged ~= true
                and shape and shape.hasCollision == false
            then
                local entryPosition = destination
                if fluid.kind == "water" and isvector(trace.HitPos) then
                    local direction = destination - self:GetPos()
                    if direction:LengthSqr() > 1e-9 then
                        direction = direction / direction:Length()
                        entryPosition = trace.HitPos + direction
                            * math.max(Fishing.BlockSize() / 4096, 0.01)
                    end
                end
                return {
                    Hit = false,
                    HitPos = destination,
                    HitNormal = vector_origin,
                    Fraction = 1,
                    Distance = destination:Distance(self:GetPos()),
                    MCIgnoredFluidHit = true,
                    MCFluidEntryPos = entryPosition,
                }
            end
        end
        return trace
    end
    return util.TraceLine({
        start = self:GetPos(),
        endpos = destination,
        -- 主人一直在过滤名单里：浮标从自己身上穿过去，既不会勾住自己，也不会被
        -- 自己的身体挡下来。
        filter = { self, self:GetOwner() },
        mask = MASK_SHOT,
    })
end

function ENT:RestOnTraceSurface(trace)
    local normal = isvector(trace and trace.HitNormal) and trace.HitNormal or vector_origin
    local clearance = math.max(0.1, Fishing.SurfaceClearanceBlocks * Fishing.BlockSize())
    self:SetPos((trace and trace.HitPos or self:GetPos()) + normal * clearance)
    self:SetMCVelocity(vector_origin)
    self:SetMCOnGround(normal.z > 0.5)
end

function ENT:MovementStep()
    local owner = self:GetOwner()
    if not IsValid(owner) or self:ShouldStopFishing(owner) then
        self:Remove()
        return false
    end

    self.MCProjectileAge = self.MCProjectileAge + 1
    if self:GetMCOnGround() then
        self.MCLife = self.MCLife + 1
        if self.MCLife >= Fishing.GroundLifetimeTicks then
            self:Remove()
            return false
        end
    else
        self.MCLife = 0
    end

    local fluid, bx, by, bz = Fishing.FluidAtPosition(self:GetPos(), self)
    local inWater = fluid and fluid.kind == "water" and (tonumber(fluid.height) or 0) > 0
    local state = self:GetHookState()

    if state == Fishing.State.HOOKED_IN_ENTITY then
        self:FollowHookedEntity()
        return true
    end

    local velocity = self:GetMCVelocity()
    if state == Fishing.State.FLYING and inWater then
        self:SetMCVelocity(Vector(velocity.x * 0.3, velocity.y * 0.3, velocity.z * 0.2))
        self:SetHookState(Fishing.State.BOBBING)
        self:SetMCOnGround(false)
        return true
    end

    if state == Fishing.State.BOBBING then
        if inWater then
            local surfaceZ = Fishing.FluidSurfaceZ(self:GetPos(), fluid, bx, by, bz)
            local force = velocity.z
            if isnumber(surfaceZ) then
                force = force + (self:GetPos().z - surfaceZ) / Fishing.BlockSize()
            end
            if math.abs(force) < 0.01 and force ~= 0 then
                force = force + (force > 0 and 0.1 or -0.1)
            end
            velocity = Vector(velocity.x * 0.9, velocity.y * 0.9, velocity.z - force * math.Rand(0, 1) * 0.2)

            if self.MCNibble <= 0 and self.MCTimeUntilHooked <= 0 then
                self:SetOpenWater(true)
            else
                self:SetOpenWater(self:GetOpenWater()
                    and self.MCOutOfWaterTime < Fishing.MaxOutOfWaterTicks
                    and self:CalculateOpenWater(bx, by, bz, fluid))
            end

            self.MCOutOfWaterTime = math.max(0, self.MCOutOfWaterTime - 1)
            if self:GetBiting() then
                velocity.z = velocity.z - 0.1 * math.Rand(0, 1) * math.Rand(0, 1)
            end
            self:CatchingFish(bx, by, bz, fluid)
            if self.MCBiteVelocityZ then
                velocity.z = self.MCBiteVelocityZ
                self.MCBiteVelocityZ = nil
            end
        else
            self.MCOutOfWaterTime = math.min(Fishing.MaxOutOfWaterTicks, self.MCOutOfWaterTime + 1)
        end
    end

    if not inWater and not self:GetMCOnGround() then velocity.z = velocity.z - 0.03 end
    local destination = self:GetPos() + velocity * Fishing.BlockSize()

    if state == Fishing.State.FLYING then
        local trace = self:TraceFlight(destination)
        if trace.Hit then
            if IsValid(trace.Entity) and not trace.HitWorld and not trace.Entity:IsWorld()
                and validHookedEntity(trace.Entity) then
                self:SetPos(trace.HitPos)
                self:SetMCHookedEntity(trace.Entity)
                return true
            end
            -- Source traces report fraction=0 again when the next tick starts
            -- exactly on a wall plane.  Nudge the hook a hundredth of a block
            -- along the hit normal so Java's following gravity tick can move it
            -- downward instead of being reset to zero forever.
            self:RestOnTraceSurface(trace)
            return true
        end
        -- MOVETYPE_NONE makes this entity fully manual.  A clear projectile
        -- trace therefore still has to commit the Java movement destination;
        -- updating only the stored velocity leaves the bobber suspended at its
        -- spawn point even though gravity continues to accumulate numerically.
        self:SetPos(isvector(trace.MCFluidEntryPos) and trace.MCFluidEntryPos or destination)
        self:SetMCOnGround(false)
    else
        local trace = MCITEM.Throwables and MCITEM.Throwables.TraceMovementHull
            and MCITEM.Throwables.TraceMovementHull(
                self:GetPos(), destination,
                Vector(-0.125, -0.125, -0.125) * Fishing.BlockSize(),
                Vector(0.125, 0.125, 0.125) * Fishing.BlockSize(),
                self
            ) or nil
        if trace and trace.Hit then
            self:SetPos(trace.HitPos)
            velocity = vector_origin
            self:SetMCOnGround(isvector(trace.HitNormal) and trace.HitNormal.z > 0.5)
        else
            self:SetPos(destination)
            self:SetMCOnGround(false)
        end
    end

    velocity = velocity * 0.92
    self:SetMCVelocity(velocity)
    return true
end

function ENT:Think()
    local now = CurTime()
    local steps = 0
    while now >= (self.MCNextTick or now) and steps < 8 do
        if not self:MovementStep() or not IsValid(self) then return false end
        self.MCNextTick = self.MCNextTick + TICK_SECONDS
        steps = steps + 1
    end
    if steps >= 8 and now >= self.MCNextTick then self.MCNextTick = now + TICK_SECONDS end
    self:NextThink(self.MCNextTick)
    return true
end

function ENT:CommitRodDurability(amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return true end
    local owner = self:GetOwner()
    local weapon = self:GetRodWeapon()
    if not IsValid(owner) or not IsValid(weapon) then return false end

    if not weapon:GetNW2Bool("MCITEM_InventoryProxy", false) then
        if isfunction(weapon.ApplyMCDurabilityDamage) then
            weapon:ApplyMCDurabilityDamage(amount, { reason = "fishing_retrieve", hook = self })
        end
        return true
    end

    local inventory = Fishing.InventoryAPI()
    if not inventory or not isfunction(inventory.GetSelected) or not isfunction(inventory.DamageSelected) then
        return false
    end
    local stack = inventory.GetSelected(owner)
    if not istable(stack) or stack.item ~= "minecraft:fishing_rod" then return false end
    local result, _, err = inventory.DamageSelected(owner, amount, {
        expectedClass = weapon:GetClass(),
        expectedItem = "minecraft:fishing_rod",
        expectedStackHash = Fishing.StackHash(stack),
        reason = "mcitem_fishing_retrieve",
    })
    return result and true or err == "infinite_materials"
end

function ENT:CalculatePullVelocity(entity)
    local owner = self:GetOwner()
    if not IsValid(owner) then return nil end

    -- FishingHook.pullEntity adds (owner - hook) * 0.1 blocks/tick to the
    -- target's existing movement. Convert that tick velocity to Source units/s.
    local delta = (owner:GetPos() - self:GetPos()) / Fishing.BlockSize()
    local vertical = delta.z * 0.1

    -- A grounded VPhysics pickup aimed straight at the player's feet catches
    -- the lip of a Source ledge and loses the vertical part of the impulse. MC's
    -- freshly caught ItemEntity uses this exact +sqrt(distance)*0.08 arc. Reuse
    -- it only when an already-hooked pickup has to travel upward; downward pulls
    -- remain the unmodified pullEntity vector.
    if Fishing.IsItemEntity(entity) and delta.z > 0 then
        vertical = vertical + math.sqrt(delta:Length()) * 0.08
    end

    return Vector(delta.x * 0.1, delta.y * 0.1, vertical)
        * Fishing.BlockSize() / TICK_SECONDS
end

function ENT:PullEntity(entity)
    if not IsValid(entity) then return false end
    local owner = self:GetOwner()
    if not IsValid(owner) then return false end
    local velocity = self:CalculatePullVelocity(entity)
    if not isvector(velocity) then return false end

    -- BMB has an authoritative locomotion/knockback state. A raw Entity velocity
    -- is overwritten by its behaviour coroutine on the next frame, so hand the
    -- impulse to that state machine when the current BMB addon exposes it.
    if isfunction(entity.StartBMBExternalImpulse) and entity:StartBMBExternalImpulse(velocity, {
        reason = "fishing_rod",
        duration = 0.12,
    }) then
        return true
    end

    -- Entities that integrate their own Java-style movement (MCSWEP's primed
    -- TNT is MOVETYPE_NONE) ignore Entity:SetVelocity entirely. Hand them the
    -- impulse in the units their integrator uses: CalculatePullVelocity returns
    -- Source units/s, their delta movement is blocks per tick.
    if manualMovementEntity(entity) then
        local blocks = Fishing.BlockSize()
        if blocks > 0 and entity:MCAddExplosionVelocity(velocity * TICK_SECONDS / blocks) then
            return true
        end
    end

    -- Player SetVelocity is additive, matching Entity.setDeltaMovement(old +
    -- delta). Detaching first prevents a positive Z impulse being eaten by the
    -- Source ground categorisation pass.
    if entity:IsPlayer() and isfunction(entity.SetVelocity) then
        if velocity.z > 0 and isfunction(entity.SetGroundEntity) then entity:SetGroundEntity(NULL) end
        entity:SetVelocity(velocity)
        return true
    end

    -- mc_item_drop is VPhysics. Set the complete accumulated velocity and wake
    -- it explicitly; AddVelocity alone can leave a sleeping grounded pickup
    -- sliding along the floor without accepting the upward component.
    if Fishing.IsItemEntity(entity) then
        local physics = entity.GetPhysicsObject and entity:GetPhysicsObject() or nil
        if IsValid(physics) then
            local current = isfunction(physics.GetVelocity) and physics:GetVelocity() or vector_origin
            if isfunction(physics.SetVelocity) then
                physics:SetVelocity(current + velocity)
            elseif isfunction(physics.AddVelocity) then
                physics:AddVelocity(velocity)
            else
                return false
            end
            if isfunction(physics.Wake) then physics:Wake() end
            return true
        end
    end

    -- NextBots use their locomotion object, not Entity:SetVelocity. Jump opens
    -- the grounded vertical solver; Approach wakes stationary locomotion just as
    -- BMB's existing knockback launch path does.
    if entity:IsNextBot() and entity.loco and isfunction(entity.loco.SetVelocity) then
        local current = isfunction(entity.GetVelocity) and entity:GetVelocity() or vector_origin
        if velocity.z > 0 and isfunction(entity.loco.Jump)
            and (not isfunction(entity.loco.IsOnGround) or entity.loco:IsOnGround())
        then
            entity.loco:Jump()
        end
        entity.loco:SetVelocity(current + velocity)
        local flat = Vector(velocity.x, velocity.y, 0)
        if isfunction(entity.loco.Approach) and flat:LengthSqr() > 1 then
            entity.loco:Approach(entity:GetPos() + flat, math.max(flat:Length(), 1))
        end
        return true
    end

    -- Source NPC movement is absolute through SetLocalVelocity. Preserve its
    -- current velocity before adding the vanilla fishing impulse.
    if entity:IsNPC() then
        local current = isfunction(entity.GetVelocity) and entity:GetVelocity() or vector_origin
        if velocity.z > 0 and isfunction(entity.SetGroundEntity) then entity:SetGroundEntity(NULL) end
        if isfunction(entity.SetLocalVelocity) then
            entity:SetLocalVelocity(current + velocity)
            return true
        end
        if isfunction(entity.SetVelocity) then
            entity:SetVelocity(current + velocity)
            return true
        end
    end

    if isfunction(entity.SetVelocity) then
        entity:SetVelocity(velocity)
        return true
    end
    return false
end

function ENT:LootVelocity(owner)
    local delta = (owner:GetPos() - self:GetPos()) / Fishing.BlockSize()
    local distance = math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    local vertical = delta.z * 0.1 + math.sqrt(math.sqrt(distance * distance)) * 0.08
    return Vector(delta.x * 0.1, delta.y * 0.1, vertical) * Fishing.BlockSize() * 20
end

function ENT:SpawnFishingLoot(stacks)
    local owner = self:GetOwner()
    local inventory = Fishing.InventoryAPI()
    if not IsValid(owner) or not inventory or not isfunction(inventory.SpawnDropStack) then return false end
    local velocity = self:LootVelocity(owner)
    local spawned = false
    for _, stack in ipairs(stacks or {}) do
        local entity = inventory.SpawnDropStack(self:GetPos(), stack, owner, {
            velocity = velocity,
            pickupDelay = 0,
            positionJitter = false,
        })
        if IsValid(entity) then
            spawned = true
            local throwables = MCITEM.Throwables
            if throwables and isfunction(throwables.SpawnExperienceOrb) then
                throwables.SpawnExperienceOrb(
                    owner:GetPos() + Vector(0, 0.5, 0.5) * Fishing.BlockSize(),
                    vector_origin,
                    math.random(1, 6),
                    { reason = "fishing", owner = owner, hook = self, stack = table.Copy(stack) }
                )
            end
            hook.Run("MCITEM.FishCaught", owner, stack, self)
        end
    end
    return spawned
end

function ENT:Retrieve()
    local owner = self:GetOwner()
    if not IsValid(owner) or self:ShouldStopFishing(owner) then return false, 0 end

    local hooked = self:GetHookedEntity()
    local damage = 0
    local loot
    if IsValid(hooked) then
        damage = Fishing.IsItemEntity(hooked) and 3 or 5
    elseif self.MCNibble > 0 then
        loot = Fishing.GenerateLoot(self.MCLuck or 0, self:GetOpenWater(), self:GetPos(), self)
        damage = 1
    end
    if self:GetMCOnGround() then damage = 2 end
    -- Inventory durability commits can synchronously remove a proxy SWEP when
    -- the rod breaks.  Mark this retrieval so the weapon's cleanup path leaves
    -- the hook alive until the already-authoritative pull/loot side effect is
    -- complete; otherwise the final durability point can silently eat a catch.
    self.MCRetrieving = true
    if not self:CommitRodDurability(damage) then
        self.MCRetrieving = false
        return false, damage
    end

    if IsValid(hooked) then
        self:PullEntity(hooked)
        hook.Run("MCITEM.FishingEntityHooked", owner, hooked, self)
    elseif loot and #loot > 0 then
        self:SpawnFishingLoot(loot)
    end

    self:Remove()
    return true, damage
end

function ENT:OnRemove()
    local weapon = self:GetRodWeapon()
    if IsValid(weapon) and isfunction(weapon.SetMCFishingHook)
        and weapon:GetNW2Entity("MCITEM_FishingHook") == self
    then
        weapon:SetMCFishingHook(nil)
    end
end
