-- Shared Minecraft 26.2 bow/crossbow helpers and sound events.

MCITEM = MCITEM or {}

-- 箭的世界模型。用 minecraft_swep 的 mcmodelpack 那支：它的长轴在**模型 +X**上
-- （hull 36.75 × 11.9 × 11.9），所以 `SetAngles(velocity:Angle())` 直接就是正确朝向，
-- 不需要任何角度补偿。旧的 models/mcgm/arrow 长轴在 +Y（11.9 × 37 × 11.9），
-- 照着速度设角度会让箭**横着飞**——这就是"箭矢朝向不对"的成因。
-- 文件按原路径整份拷进来（models/mcmodelpack/entities/arrow.*），因为 .mdl 里嵌着
-- `MCModelPack\entities\arrow.mdl` 这个名字，改路径会对不上。
MCITEM.ArrowModel = "models/mcmodelpack/entities/arrow.mdl"

if SERVER then
    util.AddNetworkString("MCITEM_CombatParticle")
    util.AddNetworkString("MCITEM_ProjectilePickup")
end

--------------------------------------------------------------------------------
-- 弹丸命中目标的判据
--------------------------------------------------------------------------------
-- AbstractArrow.canHitEntity → Entity.canBeHitByProjectile() = 活着 + 可选中 + 非旁观。
-- 方块、掉落物、载具、装饰实体都不满足，所以在 MC 里箭是**插上去**而不是打伤它们。
-- Source 侧没有这套语义，按"有生命的生物"判：玩家 / NPC / NextBot。MCSWEP 的
-- mc_chunk、地图刷子、玩家 prop 全部落在外面 = 当方块处理。
function MCITEM.IsProjectileTarget(entity)
    if not IsValid(entity) or entity == game.GetWorld() then return false end
    -- BMB 的可选互操作字段：装了 BMB 就别打尸体，没装读到 nil。
    if entity.BMBDead then return false end
    if not (entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot() or entity.IsBMBMob == true) then
        return false
    end
    return entity:Health() > 0
end


-- sounds.json is an entry list, not merely a list of unique wave files. Crossbow
-- middle/load sounds deliberately repeat a wave at different pitch/volume values.
MCITEM.RangedSoundEvents = {
    bow_shoot = { { file = "bow.ogg" } },
    arrow_hit = {
        { file = "bowhit1.ogg" }, { file = "bowhit2.ogg" },
        { file = "bowhit3.ogg" }, { file = "bowhit4.ogg" },
    },
    crossbow_loading_start = {
        { file = "crossbow_loading_start.ogg", volume = 0.3 },
    },
    crossbow_loading_middle = {
        { file = "crossbow_loading_middle1.ogg", volume = 0.65 },
        { file = "crossbow_loading_middle1.ogg", volume = 0.65, pitch = 0.95 },
        { file = "crossbow_loading_middle1.ogg", volume = 0.65, pitch = 1.2 },
        { file = "crossbow_loading_middle2.ogg", volume = 0.65 },
        { file = "crossbow_loading_middle2.ogg", volume = 0.65, pitch = 0.9 },
        { file = "crossbow_loading_middle2.ogg", volume = 0.65, pitch = 1.05 },
        { file = "crossbow_loading_middle3.ogg", volume = 0.65 },
        { file = "crossbow_loading_middle3.ogg", volume = 0.65, pitch = 0.9 },
        { file = "crossbow_loading_middle3.ogg", volume = 0.65, pitch = 1.05 },
        { file = "crossbow_loading_middle4.ogg", volume = 0.65 },
    },
    crossbow_loading_end = { { file = "crossbow_loading_end.ogg" } },
    crossbow_quick_charge_1 = {
        { file = "crossbow_quick1_1.ogg", volume = 0.65 },
        { file = "crossbow_quick1_1.ogg", volume = 0.5, pitch = 0.9 },
        { file = "crossbow_quick1_2.ogg", volume = 0.65 },
        { file = "crossbow_quick1_2.ogg", volume = 0.65, pitch = 0.95 },
        { file = "crossbow_quick1_3.ogg", volume = 0.65 },
    },
    crossbow_quick_charge_2 = {
        { file = "crossbow_quick2_1.ogg", volume = 0.65 },
        { file = "crossbow_quick2_1.ogg", volume = 0.5, pitch = 0.95 },
        { file = "crossbow_quick2_2.ogg", volume = 0.65 },
        { file = "crossbow_quick2_2.ogg", volume = 0.65, pitch = 0.95 },
        { file = "crossbow_quick2_2.ogg", volume = 0.65, pitch = 1.05 },
        { file = "crossbow_quick2_3.ogg", volume = 0.65 },
        { file = "crossbow_quick2_3.ogg", volume = 0.65, pitch = 0.9 },
        { file = "crossbow_quick2_3.ogg", volume = 0.65, pitch = 1.05 },
    },
    crossbow_quick_charge_3 = {
        { file = "crossbow_quick3_1.ogg", volume = 0.65 },
        { file = "crossbow_quick3_1.ogg", volume = 0.5, pitch = 0.95 },
        { file = "crossbow_quick3_2.ogg", volume = 0.65 },
        { file = "crossbow_quick3_2.ogg", volume = 0.65, pitch = 0.95 },
        { file = "crossbow_quick3_2.ogg", volume = 0.65, pitch = 1.05 },
        { file = "crossbow_quick3_3.ogg", volume = 0.65 },
        { file = "crossbow_quick3_3.ogg", volume = 0.65, pitch = 0.9 },
        { file = "crossbow_quick3_3.ogg", volume = 0.65, pitch = 1.05 },
    },
    crossbow_shoot = {
        { file = "crossbow_shoot1.ogg", volume = 0.8 },
        { file = "crossbow_shoot1.ogg", volume = 0.9 },
        { file = "crossbow_shoot1.ogg", volume = 0.9, pitch = 0.9 },
        { file = "crossbow_shoot2.ogg", volume = 0.8 },
        { file = "crossbow_shoot2.ogg", volume = 0.9 },
        { file = "crossbow_shoot2.ogg", volume = 0.9, pitch = 0.9 },
        { file = "crossbow_shoot3.ogg", volume = 0.8 },
        { file = "crossbow_shoot3.ogg", volume = 0.9 },
        { file = "crossbow_shoot3.ogg", volume = 0.9, pitch = 0.9 },
    },
    trident_throw = {
        { file = "trident_throw1.ogg" }, { file = "trident_throw2.ogg" },
    },
    trident_hit = {
        { file = "trident_pierce1.ogg" }, { file = "trident_pierce2.ogg" },
        { file = "trident_pierce3.ogg" },
    },
    trident_ground = {
        { file = "trident_ground1.ogg", volume = 0.9 },
        { file = "trident_ground2.ogg", volume = 0.9 },
        { file = "trident_ground3.ogg", volume = 0.9 },
        { file = "trident_ground4.ogg", volume = 0.9 },
    },
    trident_return = {
        { file = "trident_return1.ogg" }, { file = "trident_return2.ogg" },
        { file = "trident_return3.ogg" },
    },
    -- EnchantmentHelper.pickHighestLevel indexes this list by enchantment
    -- level; these are not random variants of one event.
    trident_riptide_1 = { { file = "trident_riptide1.ogg" } },
    trident_riptide_2 = { { file = "trident_riptide2.ogg" } },
    trident_riptide_3 = { { file = "trident_riptide3.ogg" } },
    mace_smash_air = {
        { file = "mace_smash_air1.ogg" }, { file = "mace_smash_air2.ogg" },
        { file = "mace_smash_air3.ogg" },
    },
    mace_smash_ground = {
        { file = "mace_smash_ground1.ogg" }, { file = "mace_smash_ground2.ogg" },
        { file = "mace_smash_ground3.ogg" }, { file = "mace_smash_ground4.ogg" },
    },
    mace_smash_ground_heavy = { { file = "mace_smash_ground_heavy.ogg" } },
    spear_attack = {
        { file = "spear_attack1.ogg" }, { file = "spear_attack2.ogg" },
        { file = "spear_attack3.ogg" },
    },
    spear_hit = {
        { file = "spear_hit1.ogg" }, { file = "spear_hit2.ogg" },
        { file = "spear_hit3.ogg" },
    },
    spear_use = { { file = "spear_use.ogg" } },
    spear_wood_attack = {
        { file = "spear_wood_attack1.ogg" }, { file = "spear_wood_attack2.ogg" },
        { file = "spear_wood_attack3.ogg" },
    },
    spear_wood_hit = {
        { file = "spear_wood_hit1.ogg" }, { file = "spear_wood_hit2.ogg" },
        { file = "spear_wood_hit3.ogg" },
    },
    spear_wood_use = { { file = "spear_wood_use.ogg" } },
    spear_lunge = {
        { file = "spear_lunge1.ogg" }, { file = "spear_lunge2.ogg" },
        { file = "spear_lunge3.ogg" },
    },
    -- SoundEvents.ITEM_PICKUP：ClientPacketListener.handleTakeItemEntity 里以
    -- volume 0.2、pitch (rand-rand)*1.4 + 2.0 播的那一下（原版 random/pop.ogg）。
    item_pickup = { { file = "pop.ogg", volume = 0.2 } },
}

MCITEM.RangedSoundFiles = {}
for key, variants in pairs(MCITEM.RangedSoundEvents) do
    local files = {}
    for _, variant in ipairs(variants) do files[#files + 1] = variant.file end
    MCITEM.RangedSoundFiles[key] = files
end

MCITEM.RangedSoundNames = MCITEM.RangedSoundNames or {}

for key, files in pairs(MCITEM.RangedSoundFiles) do
    local waves = {}
    for _, filename in ipairs(files) do
        local path = "mcitem/ranged/" .. filename
        waves[#waves + 1] = path
        if SERVER then resource.AddFile("sound/" .. path) end
    end

    local soundName = "MCITEM.Ranged." .. key
    MCITEM.RangedSoundNames[key] = soundName
    sound.Add({
        name = soundName,
        channel = CHAN_AUTO,
        volume = 1,
        level = 75,
        pitch = 100,
        sound = waves,
    })
end

function MCITEM.PlayRangedSound(entity, key, volume, pitch)
    if not IsValid(entity) then return end

    local file, finalVolume, finalPitch = MCITEM.ResolveRangedSound(key, volume, pitch)
    if not file then return end
    entity:EmitSound("mcitem/ranged/" .. file, 75, finalPitch, finalVolume, CHAN_AUTO)
end

-- 给"发完声音马上要被移除的实体"用：挂在实体上会被 Remove 截断。
function MCITEM.PlayRangedSoundAt(position, key, volume, pitch)
    if not isvector(position) then return end

    local file, finalVolume, finalPitch = MCITEM.ResolveRangedSound(key, volume, pitch)
    if not file then return end
    sound.Play("mcitem/ranged/" .. file, position, 75, finalPitch, finalVolume)
end

function MCITEM.ResolveRangedSound(key, volume, pitch)
    local variants = MCITEM.RangedSoundEvents[key]
    if not variants or #variants == 0 then return nil end

    local variant = variants[math.random(1, #variants)]
    return variant.file,
        math.Clamp((volume or 1) * (variant.volume or 1), 0, 1),
        math.Clamp(math.floor((pitch or 100) * (variant.pitch or 1) + 0.5), 0, 255)
end

-- BowItem.getPowerForTime.
function MCITEM.BowPowerForTicks(timeHeld)
    local power = math.max(timeHeld or 0, 0) / 20
    power = (power * power + power * 2) / 3
    return math.min(power, 1)
end

--------------------------------------------------------------------------------
-- 拾取动画（ClientboundTakeItemEntityPacket → ItemPickupParticle）
--------------------------------------------------------------------------------
-- 服务端 `player.take(entity, 1)` 只是广播一个包，实体紧接着 discard()。真正的"被吸
-- 走"是**客户端粒子**：ItemPickupParticle 存下实体当时的位置，ItemPickupParticleGroup
-- 每帧算 `time = (life + partialTick) / 3; time *= time`，从那个位置插值到
-- `(target.x, (target.y + target.eyeY) / 2, target.z)`——目标点每 tick 重取，所以玩家
-- 边走边捡也会追着人飞。life 到 3 tick（0.15s）就结束。
MCITEM.PickupTicks = 3

if SERVER then
    function MCITEM.SendProjectilePickup(entity, ply)
        if not IsValid(entity) or not IsValid(ply) then return end

        local position = entity:GetPos()
        net.Start("MCITEM_ProjectilePickup")
        net.WriteString(entity:GetModel() or "")
        net.WriteVector(position)
        net.WriteAngle(entity:GetAngles())
        net.WriteFloat(entity:GetModelScale() or 1)
        net.WriteEntity(ply)
        net.SendPVS(position)
    end
elseif not MCITEM.PickupAnimationInstalled then
    MCITEM.PickupAnimationInstalled = true

    local animations = {}

    -- ItemPickupParticle.updatePosition
    local function pickupTarget(entity)
        local origin = entity:GetPos()
        return Vector(origin.x, origin.y, (origin.z + entity:EyePos().z) / 2)
    end

    net.Receive("MCITEM_ProjectilePickup", function()
        local model = net.ReadString()
        local origin = net.ReadVector()
        local angles = net.ReadAngle()
        local scale = net.ReadFloat()
        local target = net.ReadEntity()

        -- handleTakeItemEntity：volume 0.2、pitch (rand - rand) * 1.4 + 2.0。
        MCITEM.PlayRangedSoundAt(origin, "item_pickup", 1,
            ((math.Rand(0, 1) - math.Rand(0, 1)) * 1.4 + 2) * 100)

        if model == "" or not IsValid(target) then return end

        local clientModel = ClientsideModel(model, RENDERGROUP_OPAQUE)
        if not IsValid(clientModel) then return end

        clientModel:SetPos(origin)
        clientModel:SetAngles(angles)
        clientModel:SetModelScale(scale > 0 and scale or 1, 0)

        animations[#animations + 1] = {
            model = clientModel,
            origin = origin,
            target = target,
            startAt = CurTime(),
        }
    end)

    hook.Add("Think", "MCITEM.ProjectilePickup", function()
        if #animations == 0 then return end

        local now = CurTime()
        local duration = MCITEM.PickupTicks * MCITEM.TickSeconds

        for index = #animations, 1, -1 do
            local animation = animations[index]
            local elapsed = (now - animation.startAt) / duration
            local finished = elapsed >= 1 or not IsValid(animation.target)

            if finished or not IsValid(animation.model) then
                if IsValid(animation.model) then animation.model:Remove() end
                table.remove(animations, index)
            else
                -- `time *= time`：前段慢、末段猛地被吸进去。
                local blend = math.Clamp(elapsed, 0, 1)
                blend = blend * blend
                animation.model:SetPos(LerpVector(blend, animation.origin, pickupTarget(animation.target)))
            end
        end
    end)
end

-- RandomSource.triangle(mode=0, deviation): deviation * (uniform - uniform).
function MCITEM.TriangleRandom(deviation)
    return (math.Rand(0, 1) - math.Rand(0, 1)) * deviation
end

if SERVER then
    function MCITEM.SendArrowCritParticles(position, movement)
        net.Start("MCITEM_CombatParticle")
        net.WriteUInt(3, 2)
        net.WriteVector(position)
        net.WriteVector(movement)
        net.SendPVS(position)
    end

    -- Optional mob/projectile bridge. Existing player callers omit `options`
    -- and keep the exact historical eye-origin / aim-vector path. Mobs may
    -- provide an authoritative Java launch origin and direction without
    -- impersonating a player view angle or creating a second arrow entity.
    function MCITEM.SpawnArrow(owner, weapon, power, uncertainty, critical, crossbow, projectileStack, infiniteAmmo, options)
        if not IsValid(owner) then return nil end
        options = istable(options) and options or {}

        local arrow = ents.Create("mcitem_arrow")
        if not IsValid(arrow) then return nil end

        local aim = isvector(options.direction)
            and options.direction:GetNormalized()
            or owner:GetAimVector()
        if aim:LengthSqr() <= 0 then aim = owner:GetAimVector() end
        local origin = isvector(options.origin)
            and options.origin
            or owner:GetShootPos() - Vector(0, 0, MCITEM.BlockSize() * 0.1)
        arrow:SetPos(origin)
        -- ⚠ 生成时就得用**模型修正过**的角度：客户端在收到第一次角度更新之前渲染的是这一
        -- 帧的值，写裸 aim 角度会让长轴不在 +X 的模型（三叉戟）出生瞬间直立一下。
        arrow:SetAngles(arrow:MCFlightAngle(aim))
        arrow:Spawn()
        arrow:Activate()
        arrow:Launch(owner, weapon, aim, power, uncertainty, critical, crossbow, projectileStack, options)

        -- Freeze the complete firing-weapon stack on the projectile.  This is
        -- the Java firedFromWeapon boundary used by Power/Flame/Punch/Piercing;
        -- reading the selected slot again after the atomic shot commit would
        -- lose charged-projectile/enchantment state or observe another item.
        local runtime = MCITEM.EnchantmentRuntime
        local weaponStack = istable(options.enchantmentStack) and options.enchantmentStack or nil
        if not weaponStack and runtime and isfunction(runtime.StackForWeapon) then
            weaponStack = runtime.StackForWeapon(weapon, owner)
        end
        if istable(weaponStack) then
            arrow.MCEnchantmentStack = table.Copy(weaponStack)
        end

        local piercing = runtime and isfunction(runtime.GetPiercingLevel)
            and runtime.GetPiercingLevel(arrow.MCEnchantmentStack) or 0
        arrow.MCPierceLevel = math.max(0, math.floor(tonumber(piercing) or 0))
        -- AbstractArrow#getPierceLevel > 0 bypasses BlocksAttacks before angle
        -- or shield durability resolution.  The bit comes from the same frozen
        -- full ItemStack carried by this exact projectile.
        arrow.MCShieldBypass = arrow.MCPierceLevel > 0
        if infiniteAmmo == true then arrow.MCPickup = MCITEM.Pickup.CREATIVE_ONLY end
        return arrow
    end

    -- Optional mob/projectile bridge. Omitting `options` preserves the player
    -- TridentItem path exactly: eye origin, aim direction, power 2.5,
    -- uncertainty 1, and shooter-motion inheritance.
    function MCITEM.SpawnTrident(owner, weapon, options)
        if not IsValid(owner) then return nil end
        options = istable(options) and options or {}

        local trident = ents.Create("mcitem_trident")
        if not IsValid(trident) then return nil end

        local direction = isvector(options.direction)
            and options.direction:GetNormalized()
            or owner:GetAimVector()
        if direction:LengthSqr() <= 0 then direction = owner:GetAimVector() end

        local origin = isvector(options.origin)
            and options.origin
            or owner:GetShootPos() - Vector(0, 0, MCITEM.BlockSize() * 0.1)
        local power = tonumber(options.power) or 2.5
        local uncertainty = tonumber(options.uncertainty) or 1
        local projectileStack = istable(options.projectileStack)
            and options.projectileStack
            or { item = "minecraft:trident", count = 1 }

        trident:SetPos(origin)
        trident:SetAngles(trident:MCFlightAngle(direction))
        trident:Spawn()
        trident:Activate()
        trident:Launch(
            owner,
            weapon,
            direction,
            power,
            uncertainty,
            false,
            false,
            projectileStack,
            options
        )

        -- ThrownTrident#getWeaponItem returns the exact ItemStack that left
        -- the hand.  Freeze it before the inventory transaction can clear or
        -- replace the selected slot; Impaling, Channeling and Loyalty all read
        -- this projectile-owned snapshot for their full lifetime.
        local runtime = MCITEM.EnchantmentRuntime
        local weaponStack = istable(options.enchantmentStack) and options.enchantmentStack or nil
        if not weaponStack and runtime and isfunction(runtime.StackForWeapon) then
            weaponStack = runtime.StackForWeapon(weapon, owner)
        end
        if istable(weaponStack) then
            trident.MCEnchantmentStack = table.Copy(weaponStack)
        end
        return trident
    end
end
