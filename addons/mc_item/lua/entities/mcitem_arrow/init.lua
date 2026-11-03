AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
AddCSLuaFile("mcitem/cl_combat_particles.lua")
include("shared.lua")

local TICK_SECONDS = 1 / 20
local AIR_DRAG = 0.99
local GRAVITY = 0.05
local BASE_DAMAGE = 2
local DESPAWN_TICKS = 1200

local function applyAirDragAndGravity(arrow)
    local velocity = arrow:GetMCVelocity() * AIR_DRAG
    velocity.z = velocity.z - GRAVITY
    arrow:SetMCVelocity(velocity)
    return velocity
end

-- Projectile.isOutsideOwnerCollisionRange 用的是 `boundingBox.expandTowards(delta).inflate(1.0)`
-- 与射手（及其载具/乘客）的碰撞盒求交。这里没有箭的碰撞盒，用"离射手中心一格"近似。
local LEFT_OWNER_BLOCKS = 1.0

function ENT:Initialize()
    self:SetModel(MCITEM.ArrowModel)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_NONE)
    self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
    self:SetInGround(false)
    self:SetCritical(false)
    self:SetCrossbowArrow(false)
	self:SetSpectralArrow(false)
	self.MCShieldBypass = false
    self.MCPierceLevel = nil
    self:SetMCVelocity(vector_origin)
    self.MCAge = 0
    self.MCLeftOwner = false
    self.MCPiercedEntities = setmetatable({}, { __mode = "k" })
    self.MCPiercedCount = 0
end

function ENT:Launch(owner, weapon, direction, power, uncertainty, critical, crossbow, projectileStack, options)
    options = istable(options) and options or {}
    self:SetOwner(owner)
    self.MCWeapon = weapon
    self:SetCritical(critical == true)
    self:SetCrossbowArrow(crossbow == true)

    local stack = MCITEM.CopyProjectileStack and MCITEM.CopyProjectileStack(projectileStack, 1) or nil
    if not stack then stack = { item = "minecraft:arrow", count = 1 } end
    self.MCPickupStack = stack
    self.MCPickupItemID = stack.item or "minecraft:arrow"
    self:SetSpectralArrow(self.MCPickupItemID == "minecraft:spectral_arrow")

    -- AbstractArrow.setOwner：射手是玩家才把 pickup 从 DISALLOWED 提到 ALLOWED。
    -- 怪物射的箭走 default 分支，保持 DISALLOWED = 谁都捡不起来。
    if IsValid(owner) and owner:IsPlayer() and self.MCPickup == MCITEM.Pickup.DISALLOWED then
        self.MCPickup = MCITEM.Pickup.ALLOWED
    end

    local shot = direction:GetNormalized() + Vector(
        MCITEM.TriangleRandom(0.0172275 * uncertainty),
        MCITEM.TriangleRandom(0.0172275 * uncertainty),
        MCITEM.TriangleRandom(0.0172275 * uncertainty)
    )
    local velocity = shot * power

    -- BowItem uses shootFromRotation and inherits the shooter's known movement (vertical
    -- only while airborne). CrossbowItem calls Projectile.shoot directly and does not.
    if IsValid(owner)
        and not crossbow
        and options.inheritOwnerVelocity ~= false then
        local inherited = owner:GetVelocity() / (MCITEM.BlockSize() * 20)
        if owner:IsOnGround() then inherited.z = 0 end
        velocity = velocity + inherited
    end

    self:SetMCVelocity(velocity)
    -- Projectile.shoot 直接设朝向，不走 lerpRotation 的平滑。
    self:MCUpdateFlightRotation(velocity, true)
    self:NextThink(CurTime() + TICK_SECONDS)
end

function ENT:MCHitSoundPitch()
    return 100 * (1.2 / (math.Rand(0, 1) * 0.2 + 0.9))
end

function ENT:MCArrowDamage(speed)
    local runtime = MCITEM.EnchantmentRuntime
    local stack = runtime and isfunction(runtime.ProjectileStack)
        and runtime.ProjectileStack(self) or nil
    local powerBonus = runtime and isfunction(runtime.GetArrowBaseDamageBonus)
        and runtime.GetArrowBaseDamageBonus(stack) or 0
    local damage = math.ceil(math.max(speed * (BASE_DAMAGE + powerBonus), 0))
    if self:GetCritical() then
        damage = damage + math.random(0, math.floor(damage / 2) + 1)
    end
    return damage
end

function ENT:HitEntity(target, trace, speed)
    local owner = self:GetOwner()
    local runtime = MCITEM.EnchantmentRuntime
    local stack = runtime and isfunction(runtime.ProjectileStack)
        and runtime.ProjectileStack(self) or nil
    local piercing = tonumber(self.MCPierceLevel)
    if piercing == nil and runtime and isfunction(runtime.GetPiercingLevel) then
        piercing = runtime.GetPiercingLevel(stack)
    end
    piercing = math.max(0, math.floor(tonumber(piercing) or 0))
    local maximumPierced = piercing + 1
    if piercing > 0 then
        local piercedCount = math.max(0, math.floor(tonumber(self.MCPiercedCount) or 0))
        -- AbstractArrow adds the entity id before hurtOrSimulate.  A rejected
        -- hit therefore still consumes one Piercing slot and cannot be hit a
        -- second time after the arrow reverses.
        if piercedCount >= maximumPierced then
            self:Remove()
            return false, "piercing_limit"
        end
        self.MCPiercedEntities = self.MCPiercedEntities
            or setmetatable({}, { __mode = "k" })
        if not self.MCPiercedEntities[target] then
            self.MCPiercedEntities[target] = true
            self.MCPiercedCount = piercedCount + 1
        end
    end

    local incomingVelocity = self:GetMCVelocity()
    local damageInfo = DamageInfo()
    damageInfo:SetAttacker(IsValid(owner) and owner or self)
	-- DamageSource.getDirectEntity is the arrow, not the firing weapon. Keeping
	-- the projectile as inflictor gives shields its real source position and lets
	-- Piercing expose the exact bypass bit.
	damageInfo:SetInflictor(self)
    damageInfo:SetDamage(MCITEM.ScaleDamage(self:MCArrowDamage(speed)))
    -- DMG_BULLET 会让 Source 给玩家播自己那套子弹入肉音（用户听到的"枪击"声）。
    -- MC 的箭伤是 DamageTypes.ARROW，听觉上只有 entity.arrow.hit + 受伤音。
    damageInfo:SetDamageType(DMG_SLASH)
    damageInfo:SetDamagePosition(trace.HitPos)
    damageInfo:SetDamageForce(incomingVelocity:GetNormalized() * speed * MCITEM.BlockSize() * 20)
    local accepted = MCITEM.TakeDamage(target, damageInfo)
    self.MCLastHitAccepted = accepted

    local position = trace.HitPos
    self:SetPos(position)

    if not accepted then
        -- ProjectileDeflection.REVERSE first multiplies velocity by -0.5;
        -- AbstractArrow then scales that result by 0.2.  The final physical
        -- velocity is therefore exactly -0.1 of the incoming velocity.
        local reflected = incomingVelocity * -0.1
        self:SetMCVelocity(reflected)

        -- Java drops an ALLOWED pickup and discards the arrow when the final
        -- reflected speed is below 1e-7 squared blocks/tick.  The public drop
        -- bridge preserves the complete projectile ItemStack when MineMod is
        -- present; standalone MCITEM has no item-entity backend.
        if reflected:LengthSqr() < 1e-7 then
            if self.MCPickup == MCITEM.Pickup.ALLOWED
                and isfunction(MCITEM.SpawnItemDrop) then
                local pickup = istable(self.MCPickupStack)
                    and self.MCPickupStack or (self.MCPickupItemID or "minecraft:arrow")
                if not MCITEM.SpawnItemDrop(position, pickup, 1, owner) then
                    self:SetMCVelocity(vector_origin)
                    self:SetInGround(true)
                    return true, "deflected"
                end
            end
            self:Remove()
            return false, "rejected_stop"
        end

        -- Source traces start exactly on the previous collision plane.  Move
        -- the origin the same semantic 0.05 block away in the new direction
        -- so the next trace cannot remain StartSolid in the rejected target.
        self:SetPos(position + reflected:GetNormalized() * MCITEM.BlockSize() * 0.05)
        self:MCUpdateFlightRotation(reflected, true)
        return true, "deflected"
    end

    -- SpectralArrow#doPostHurtEffects: Glowing I for 200 ticks.  The potion
    -- runtime owns Java effect merging and client synchronization.
    if IsValid(target) and self:GetSpectralArrow()
        and MCITEM.Potions and isfunction(MCITEM.Potions.ApplyEffect) then
        MCITEM.Potions.ApplyEffect(target, {
            id = "glowing",
            durationTicks = 200,
            amplifier = 0,
            ambient = false,
            visible = true,
            showIcon = true,
        }, IsValid(owner) and owner or self, {
            reason = "spectral_arrow",
            projectile = self,
        })
    end

    -- AbstractArrow only plays entity.arrow.hit after hurtOrSimulate accepts
    -- the damage.  Rejected hits take the reverse-deflection branch silently.
    MCITEM.PlayRangedSoundAt(position, "arrow_hit", 1, self:MCHitSoundPitch())

    if IsValid(target) and runtime and isfunction(runtime.ApplyPunch) then
        runtime.ApplyPunch(target, self,
            isfunction(runtime.GetPunchLevel) and runtime.GetPunchLevel(stack) or 0)
    end

    if piercing > 0 then
        return true, "pierced"
    end
    self:Remove()
    return false, "discarded"
end

function ENT:HitWorld(trace)
    local velocity = self:GetMCVelocity()
    local direction = velocity:LengthSqr() > 0 and velocity:GetNormalized() or vector_origin
    -- 落点朝向直接对齐（MC 的 onHitBlock 之后 inGround 就不再更新朝向了）。
    self:MCUpdateFlightRotation(velocity, true)
    local rest = self:MCRestPosition(trace.HitPos, direction)
    self:SetPos(rest)
    self:SetStickOrigin(rest)
    self:SetMCVelocity(vector_origin)
    self:SetInGround(true)
    self:SetStickNormal(isvector(trace.HitNormal) and trace.HitNormal or Vector(0, 0, 1))
    -- AbstractArrow.onHitBlock 末尾：shakeTime = 7（= 0.35s）。playerTouch 在这段窗口里
    -- 一律拒绝，所以擦着自己脚边插地的箭不会同一瞬间又被自己吸回去。
    self.MCShakeTime = 7
    MCITEM.PlayRangedSound(self, "arrow_hit", 1, self:MCHitSoundPitch())
    self:NextThink(CurTime() + TICK_SECONDS)
end

--------------------------------------------------------------------------------
-- 拾取（AbstractArrow.playerTouch / tryPickup + Player.aiStep 的接触盒）
--------------------------------------------------------------------------------

-- ThrownTrident 覆写成"只有投掷者（或者射手已经没了）才能捡"。箭**没有**这条限制：
-- 玩家 A 射出去的箭，玩家 B 走过去照样能捡（tryPickup 只看 pickup 枚举）。
function ENT:MCCanPlayerTouch(ply)
    return true
end

-- tryPickup：ALLOWED → getInventory().add()；CREATIVE_ONLY → hasInfiniteMaterials()。
-- MCITEM 没有背包模型（投三叉戟 / 射箭都**不消耗** SWEP），真发一件物品就是凭空复制，
-- 所以这里只做"被吸走"这件事本身。接生存背包的人覆写 MCITEM.OnProjectilePickedUp
-- 返回 false 即可表达"背包满了，捡不起来"。
function ENT:MCTryPickup(ply)
    if self.MCPickup == MCITEM.Pickup.DISALLOWED then return false end
    if self.MCPickup == MCITEM.Pickup.CREATIVE_ONLY then
        -- AbstractArrow.tryPickup(CREATIVE_ONLY) checks hasInfiniteMaterials and
        -- does not add getPickupItem() to the inventory.  It merely permits the
        -- playerTouch path to play the take animation and discard the projectile.
        return MCITEM.HasInfiniteMaterials(ply)
    end

    local callback = MCITEM.OnProjectilePickedUp
    if isfunction(callback) and callback(ply, self) == false then return false end
    return self:MCGivePickupItem(ply)
end

-- `tryPickup` 的 ALLOWED 分支是 `player.getInventory().add(getPickupItem())`：
-- 捡起来是真的往背包里放一件东西，放不下就捡不起来（实体留在原地）。
-- 装了 MineMod 走它的背包；没装就退回"把 SWEP 还给玩家"（只有三叉戟这类本身是
-- 一件武器的弹丸有意义，箭没有对应 SWEP，直接算捡到）。
function ENT:MCGivePickupItem(ply)
    local itemId = self.MCPickupItemID
    if not itemId then return true end

    local stack = istable(self.MCPickupStack) and self.MCPickupStack or itemId
    local given, remainder = MCITEM.GiveItemToPlayer(ply, stack, 1, self:GetPos())
    if given then return true end
    if istable(remainder) then self.MCPickupStack = remainder end
    if MCITEM.HasInventorySystem(ply) then return false end

    local className = self.MCPickupWeaponClass
    if className and not ply:HasWeapon(className) then ply:Give(className) end
    return true
end

function ENT:MCPlayerTouch()
    -- playerTouch 的三道门：服务端、已经插住（或无碰撞飞行中）、shakeTime 归零。
    if self.MCPickup == MCITEM.Pickup.DISALLOWED then return end
    if not self:GetInGround() then return end
    if (self.MCShakeTime or 0) > 0 then return end

    local position = self:GetPos()
    -- Player.aiStep 的接触盒：getBoundingBox().inflate(1.0, 0.5, 1.0)。
    -- MC 的 Y 是竖直轴，所以那个 0.5 落在 Source 的 z 上。
    local blockSize = MCITEM.BlockSize()
    local margin = Vector(blockSize, blockSize, blockSize * 0.5)

    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() and self:MCCanPlayerTouch(ply) then
            local origin = ply:GetPos()
            if position:WithinAABox(origin + ply:OBBMins() - margin, origin + ply:OBBMaxs() + margin)
                and self:MCTryPickup(ply) then
                -- player.take(this, 1) → ClientboundTakeItemEntityPacket，然后 discard()。
                MCITEM.SendProjectilePickup(self, ply)
                self:Remove()
                return
            end
        end
    end
end


-- Projectile.checkLeftOwner / isOutsideOwnerCollisionRange：箭一旦离开射手的碰撞范围，
-- `leftOwner` 置真且**再也不会变回去**，此后 canHitEntity 允许命中射手自己。
-- 所以朝天上射、箭落回来是会打到自己的。原来把 owner 永久写进 trace filter，
-- 等于给射手开了永久免疫。
function ENT:MCUpdateLeftOwner()
    if self.MCLeftOwner then return end

    local owner = self:GetOwner()
    if not IsValid(owner) then
        self.MCLeftOwner = true
        return
    end

    local mins, maxs = owner:WorldSpaceAABB()
    local margin = LEFT_OWNER_BLOCKS * MCITEM.BlockSize()
    local expand = Vector(margin, margin, margin)
    local position = self:GetPos()

    if not position:WithinAABox(mins - expand, maxs + expand) then
        self.MCLeftOwner = true
    end
end

function ENT:Think()
    self.MCAge = (self.MCAge or 0) + 1
    if self.MCAge >= DESPAWN_TICKS then
        self:Remove()
        return false
    end

    -- AbstractArrow.tick：shakeTime 每 tick 减一，和 inGround 与否无关。
    if (self.MCShakeTime or 0) > 0 then self.MCShakeTime = self.MCShakeTime - 1 end

    if self:GetInGround() then
        self.MCInGroundTime = (self.MCInGroundTime or 0) + 1
        self:MCPlayerTouch()
        if not IsValid(self) then return false end
        self:NextThink(CurTime() + TICK_SECONDS)
        return true
    end

    self.MCInGroundTime = 0

    local velocity = self:GetMCVelocity()
    local speed = velocity:Length()
    if speed <= 1e-7 then
        self:Remove()
        return false
    end

    local startPosition = self:GetPos()
    local endPosition = startPosition + velocity * MCITEM.BlockSize()

    -- 暴击尾迹改由客户端从**插值过的**箭身上发（见 cl_init.lua 的注释）：服务端
    -- 按真实位置发会让粒子恒定领先渲染出来的箭约 cl_interp 那么久。

    -- AbstractArrow.tick 顺序：先 checkLeftOwner()，再 super.tick() 做移动和碰撞。
    self:MCUpdateLeftOwner()

    local owner = self:GetOwner()
    -- ThrownTrident 命中生物之后 `findHitEntity` 返回 null：**只是不再判定生物**，
    -- 方块照撞。原来这一支换成了 MASK_SOLID_BRUSHONLY，而 MineMod 的方块是
    -- `mc_chunk` **实体**、不是 brush —— 于是弹开之后的三叉戟直接穿过方块掉下去。
    -- 正确做法是保持 MASK_SHOT，只在过滤器里把生物排掉。
    local ignoreLiving = self.MCIgnoreAllEntities == true
    local traceStart = startPosition
    local traceDirection = velocity:GetNormalized()
    local traceEpsilon = MCITEM.BlockSize() * 0.001
    -- Piercing IV can accept five entities and discard on the sixth.  Leave a
    -- little headroom for command-created higher levels while still bounding
    -- malformed trace providers that repeatedly report the same hit.
    local maximumTracePasses = math.max(8, math.floor(tonumber(self.MCPierceLevel) or 0) + 3)

    for _ = 1, maximumTracePasses do
        local trace = util.TraceLine({
            start = traceStart,
            endpos = endPosition,
            filter = function(entity)
                if entity == self then return false end
                -- 还没离开射手 = canHitEntity 为假，只有这段时间才过滤射手。
                if not self.MCLeftOwner and entity == owner then return false end
                if entity == self.MCIgnoreEntity then return false end
                if self.MCPiercedEntities and self.MCPiercedEntities[entity] then return false end
                if ignoreLiving and MCITEM.IsProjectileTarget(entity) then return false end
                local query = MCITEM.Throwables and MCITEM.Throwables.QueryProjectileEntityHit
                if isfunction(query) then
                    local result = query(self, entity)
                    if result ~= nil then return result ~= false end
                end
                return true
            end,
            mask = MASK_SHOT,
        })

        if not trace.Hit then break end

        -- AbstractArrow.canHitEntity → Entity.canBeHitByProjectile()
        --   = isAlive() && isPickable() && !isSpectator()
        -- 也就是**只有活着的生物**算 onHitEntity，其余一律走 onHitBlock 插上去。
        -- Source 这边把 MineMod 的 mc_chunk / 地图刷子 / prop 全部当成"方块"。
        if MCITEM.IsProjectileTarget(trace.Entity)
            and MCITEM.Throwables
            and isfunction(MCITEM.Throwables.TryEntityDeflection)
            and MCITEM.Throwables.TryEntityDeflection(self, trace.Entity, trace, {
                behavior = "arrow",
            }) then
            applyAirDragAndGravity(self)
            self:NextThink(CurTime() + TICK_SECONDS)
            return true
        end

        if MCITEM.IsProjectileTarget(trace.Entity) then
            local continues, result = self:HitEntity(trace.Entity, trace, speed)
            if not continues or not IsValid(self) then return false end
            if result == "deflected" then
                applyAirDragAndGravity(self)
                self:NextThink(CurTime() + TICK_SECONDS)
                return true
            end

            traceStart = trace.HitPos + traceDirection * traceEpsilon
            if (endPosition - traceStart):Dot(traceDirection) <= 0 then break end
        else
            self:HitWorld(trace)
            return true
        end
    end

    self:SetPos(endPosition)
    self:MCUpdateFlightRotation(velocity)

    -- AbstractArrow.tick: move first, then air drag, then gravity.
    applyAirDragAndGravity(self)

    self:NextThink(CurTime() + TICK_SECONDS)
    return true
end
