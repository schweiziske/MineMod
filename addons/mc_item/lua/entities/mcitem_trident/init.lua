AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    self.BaseClass.Initialize(self)
    self:SetModel("models/mcgm/trident_3d/trident_3d.mdl")
    self.MCDealtDamage = false
    self.MCReturning = false
end

function ENT:MCArrowDamage()
    return 8
end

function ENT:HitEntity(target, trace)
    local owner = self:GetOwner()
    -- ThrownTrident marks dealtDamage before hurtOrSimulate.  A rejected hit
    -- therefore still makes Loyalty return and prevents a second living hit.
    self.MCDealtDamage = true
    self.MCIgnoreAllEntities = true
    local runtime = MCITEM.EnchantmentRuntime
    local stack = runtime and isfunction(runtime.ProjectileStack)
        and runtime.ProjectileStack(self) or nil
    local enchantmentBonus = runtime and isfunction(runtime.GetTridentDamageBonus)
        and runtime.GetTridentDamageBonus(stack, target) or 0
    local damageInfo = DamageInfo()
    damageInfo:SetAttacker(IsValid(owner) and owner or self)
    -- DamageSources.trident uses the thrown trident as its direct entity.  The
    -- firing weapon may already have left the player's inventory and is not
    -- the projectile that shields/other damage hooks should observe.
    damageInfo:SetInflictor(self)
    damageInfo:SetDamage(MCITEM.ScaleDamage(8 + enchantmentBonus))
    damageInfo:SetDamageType(DMG_SLASH)
    damageInfo:SetDamagePosition(trace.HitPos)
    damageInfo:SetDamageForce(self:GetMCVelocity():GetNormalized() * MCITEM.BlockSize() * 20)
    local accepted, actualDamage = MCITEM.TakeDamage(target, damageInfo)
    self.MCLastHitAccepted = accepted
    if accepted and runtime and isfunction(runtime.ApplyDirectPostAttack) then
        runtime.ApplyDirectPostAttack(
            stack, IsValid(owner) and owner or self, target, self, actualDamage, accepted)
    end

    -- ThrownTrident.onHitEntity 的收尾是**两步**，我们原来只抄了第二步：
    --     this.deflect(ProjectileDeflection.REVERSE, entity, this.owner, false);
    --     this.setDeltaMovement(this.getDeltaMovement().multiply(0.02, 0.2, 0.02));
    -- REVERSE 里那句是 `setDeltaMovement(getDeltaMovement().scale(-0.5))`（外加一个
    -- 170~190° 的偏航踢，我们的朝向本来就从速度算，所以不用单独做）。
    -- 少了那个 **-0.5**，三叉戟命中之后是继续往前钻、而不是往回弹 —— 于是它会顺着原来的
    -- 方向扎进目标脚下的地面里。MC 的 Y 是竖直轴，所以 0.2 落在 Source 的 z 上。
    local velocity = self:GetMCVelocity() * -0.5
    self:SetPos(trace.HitPos)
    self:SetMCVelocity(Vector(velocity.x * 0.02, velocity.y * 0.02, velocity.z * 0.2))
    -- ThrownTrident.findHitEntity：dealtDamage 之后不再判定**生物**（方块照撞）。
    MCITEM.PlayRangedSound(self, "trident_hit", 1, 100)
    -- Tell the inherited projectile loop to finish this tick through its
    -- deflected path.  Returning nil would stop scheduling Think immediately,
    -- so Loyalty could never observe MCDealtDamage and begin its return.
    return true, "deflected"
end

function ENT:HitWorld(trace)
    local velocity = self:GetMCVelocity()
    local direction = velocity:LengthSqr() > 0 and velocity:GetNormalized() or vector_origin
    self:MCUpdateFlightRotation(velocity, true)
    local rest = self:MCRestPosition(trace.HitPos, direction)
    self:SetPos(rest)
    self:SetStickOrigin(rest)
    self:SetMCVelocity(vector_origin)
    self:SetInGround(true)
    self:SetStickNormal(isvector(trace.HitNormal) and trace.HitNormal or Vector(0, 0, 1))
    self.MCShakeTime = 7
    -- AbstractArrow.onHitBlock supplies the same randomized 1.2/(r*0.2+0.9)
    -- pitch to the trident's overridden TRIDENT_HIT_GROUND event.
    MCITEM.PlayRangedSound(self, "trident_ground", 1, self:MCHitSoundPitch())
    self:NextThink(CurTime() + MCITEM.TickSeconds)
end

-- ThrownTrident.playerTouch：`if (ownedBy(player) || getOwner() == null) super.playerTouch(...)`
-- —— 三叉戟**只有投掷者本人**能捡回来（射手已经不在了才对所有人开放）。箭没有这条，
-- 玩家之间可以互相捡。
function ENT:MCCanPlayerTouch(ply)
    local owner = self:GetOwner()
    return not IsValid(owner) or owner == ply
end

local function loyaltyLevel(projectile)
    local runtime = MCITEM.EnchantmentRuntime
    if not runtime then return 0 end
    local stack = isfunction(runtime.ProjectileStack) and runtime.ProjectileStack(projectile) or nil
    local getter = isfunction(runtime.GetLoyaltyAcceleration)
        and runtime.GetLoyaltyAcceleration or runtime.GetLoyaltyLevel
    if not isfunction(getter) then return 0 end
    return math.max(0, math.floor(tonumber(getter(stack)) or 0))
end

local function acceptableReturnOwner(owner)
    if not IsValid(owner) then return false end
    if isfunction(owner.Alive) and not owner:Alive() then return false end
    if owner:IsPlayer() and isfunction(owner.GetObserverMode)
        and OBS_MODE_NONE ~= nil and owner:GetObserverMode() ~= OBS_MODE_NONE then
        return false
    end
    return true
end

local function nonPlayerReturnDistance(owner)
    local width = 0
    if isfunction(owner.WorldSpaceAABB) then
        local minimum, maximum = owner:WorldSpaceAABB()
        if isvector(minimum) and isvector(maximum) then
            width = math.max(maximum.x - minimum.x, maximum.y - minimum.y)
        end
    end
    return width + MCITEM.BlockSize()
end

function ENT:MCStartLoyaltyReturn()
    if self.MCReturning then return true end
    local level = loyaltyLevel(self)
    if level <= 0 then return false end

    self.MCReturning = true
    self:SetInGround(false)
    self.MCInGroundTime = 0
    self.MCShakeTime = 0
    self:SetNW2Bool("MCITEM_LoyaltyReturning", true)
    MCITEM.PlayRangedSound(self, "trident_return", 1, 100)
    return true
end

function ENT:MCLoyaltyDropAndRemove()
    local owner = self:GetOwner()
    if self.MCPickup == MCITEM.Pickup.ALLOWED
        and isfunction(MCITEM.SpawnItemDrop) then
        local pickup = istable(self.MCPickupStack)
            and self.MCPickupStack or (self.MCPickupItemID or "minecraft:trident")
        if not MCITEM.SpawnItemDrop(self:GetPos(), pickup, 1, IsValid(owner) and owner or nil) then
            self:SetMCVelocity(vector_origin)
            self:NextThink(CurTime() + 1)
            return true
        end
    end
    self:Remove()
    return false
end

function ENT:MCLoyaltyTryPickup(owner)
    if not IsValid(owner) or not owner:IsPlayer() then return false end
    if self:MCTryPickup(owner) then
        MCITEM.SendProjectilePickup(self, owner)
        self:Remove()
        return true
    end
    return false
end

function ENT:MCTickLoyaltyReturn()
    local owner = self:GetOwner()
    if not acceptableReturnOwner(owner) then
        return self:MCLoyaltyDropAndRemove()
    end

    local level = loyaltyLevel(self)
    if level <= 0 then return self.BaseClass.Think(self) end

    local ownerEye = isfunction(owner.EyePos) and owner:EyePos() or owner:GetPos()
    local delta = ownerEye - self:GetPos()
    if owner:IsPlayer() then
        local origin = owner:GetPos()
        local margin = MCITEM.BlockSize()
        if self:GetPos():WithinAABox(
            origin + owner:OBBMins() - Vector(margin, margin, margin * 0.5),
            origin + owner:OBBMaxs() + Vector(margin, margin, margin * 0.5)
        ) and self:MCLoyaltyTryPickup(owner) then
            return false
        end
    elseif delta:LengthSqr() <= nonPlayerReturnDistance(owner) ^ 2 then
        return self:MCLoyaltyDropAndRemove()
    end

    if delta:LengthSqr() <= 1e-8 then
        return self:MCLoyaltyDropAndRemove()
    end

    -- ThrownTrident.tick's noPhysics return branch: move the origin toward the
    -- owner's eye before damping, then add 0.05 × Loyalty toward that eye.
    self:SetPos(self:GetPos() + Vector(0, 0, delta.z * 0.015 * level))
    -- Java deliberately normalizes the delta captured before the vertical raw
    -- position correction; do not recompute it from the adjusted position.
    local direction = delta:GetNormalized()
    local velocity = self:GetMCVelocity() * 0.95 + direction * (0.05 * level)
    self:SetMCVelocity(velocity)
    self:MCUpdateFlightRotation(velocity)
    self:SetPos(self:GetPos() + velocity * MCITEM.BlockSize())
    self:SetMCVelocity(velocity * 0.99)
    self:NextThink(CurTime() + 1 / 20)
    return true
end

function ENT:Think()
    local level = loyaltyLevel(self)
    if level > 0 then
        if not self.MCReturning and self:GetInGround()
            and (self.MCInGroundTime or 0) > 4 then
            self.MCDealtDamage = true
        end
        if self.MCDealtDamage or self.MCReturning then
            self:MCStartLoyaltyReturn()
            return self:MCTickLoyaltyReturn()
        end
    end
    return self.BaseClass.Think(self)
end

