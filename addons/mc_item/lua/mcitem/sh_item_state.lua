-- Minecraft 手持物品的逐 tick 状态模型（挥动 / 手部升降 / 视角晃动 / 攻击蓄力），
-- 从 26.2 解包逐条移植。
--
-- **本库刻意独立**：只依赖 MineMod 的 `MC.BS`（方块尺寸，而且是软依赖），
-- 不引用 BMB 的任何东西，可以整个 `lua/mcitem/` 目录单独拷走给别人做生存模式。
-- 命名空间是 `MCITEM`，和 MineMod 的 `MC`、BMB 的 `BMB` 都不冲突。
--
-- 这里只放**与具体物品无关**的那一层，剑 / 斧 / 镐共用；单个 SWEP 只提供参数
-- （swing 动画类型和时长、攻击力、攻击速度）。渲染在 cl_item_render.lua，
-- 准星 / 冷却条在 cl_crosshair.lua。
--
-- 对应的 MC 源（26.2，`D:\BMBTools\26.2\nnnewest`）：
--   LivingEntity.swing / updateSwingTime / getCurrentSwingDuration / getAttackAnim
--   ItemInHandRenderer.tick                      （mainHandHeight = 手往下沉再抬起来）
--   Player.getCurrentItemAttackStrengthDelay / getAttackStrengthScale / getItemSwapScale
--        / resetAttackStrengthTicker / resetOnlyAttackStrengthTicker / baseDamageScaleFactor
--   AbstractClientPlayer.updateBob / LocalPlayer.move（walkDist）/ LocalPlayer.aiStep（xBob）
--   ItemStack.getSwingAnimation -> SwingAnimation(type, duration)

MCITEM = MCITEM or {}

-- MC 逻辑帧率。所有 tick 语义的量（swingTime / attackStrengthTicker / missTime）
-- 都在这个时基上，不要按 Source 的 66Hz 折算。
MCITEM.TickSeconds = 1 / 20

-- SwingAnimationType（26.2 新增的按物品分类）：
--   none  = 不播挥动（例如地图）
--   whack = 经典横挥，剑 / 斧 / 镐 / 空手都是它，也是 SwingAnimation.DEFAULT
--   stab  = 长矛的突刺，走 SpearAnimations.firstPersonAttack（已在 cl_item_render 实现）
MCITEM.SwingAnimationType = {
    NONE = "none",
    WHACK = "whack",
    STAB = "stab",
}

-- SwingAnimation.DEFAULT = new SwingAnimation(WHACK, 6)。
-- 全仓 grep 过：没有任何物品覆写 SWING_ANIMATION，剑 / 斧 / 镐拿到的都是这一份。
MCITEM.DefaultSwingType = MCITEM.SwingAnimationType.WHACK
MCITEM.DefaultSwingDurationTicks = 6

-- 玩家属性基值（Attributes 默认，不含物品修饰符）。
MCITEM.PlayerBaseAttackDamage = 1.0
MCITEM.PlayerBaseAttackSpeed = 4.0
MCITEM.PlayerEntityInteractionRange = 3.0 -- 格

-- Minecraft.startAttack：打空（且非创造）时 missTime = 10 tick，期间左键完全无效。
MCITEM.MissTimeTicks = 10

-- ItemInHandRenderer.tick：手部高度每 tick 最多变化 0.4，且低于 0.1 时才换渲染的物品。
MCITEM.HandHeightRate = 0.4

-- walkDist 的每 tick 增量上限（格）。MC 冲刺 5.612 格/秒 = 0.2806 格/tick，而 GMod
-- 默认奔跑 400u/s ≈ 10.96 格/秒，正好是 MC 冲刺的两倍——bobView 的振幅被 min(0.1,...)
-- 夹死了，频率却会跟着翻倍，跑起来就变成鬼畜抖动。这里把**步频**封顶在 MC 冲刺的
-- 节奏上：走路（GMod 200u/s ≈ 0.274 格/tick）几乎不受影响，奔跑回到 MC 的观感。
MCITEM.MaxWalkBlocksPerTick = 5.612 / 20

-- 一格的 Source 尺寸。MineMod 在场就以它为准，否则退回它当前用的 36.5。
-- 别在业务代码里写裸的 36/18/72，一律 `MCITEM.BlockSize() * n`。
function MCITEM.BlockSize()
    return (MC and MC.BS) or 36.5
end

local function lerp(fraction, from, to)
    return from + (to - from) * fraction
end

--------------------------------------------------------------------------------
-- 状态表：一件手持物品在 20Hz 上的全部状态
--------------------------------------------------------------------------------

function MCITEM.NewItemState()
    return {
        tickAt = nil, -- 上一次 20Hz 步进的绝对时间，nil = 还没起步

        -- LivingEntity 的挥动
        swinging = false,
        swingTime = 0,
        attackAnim = 0,
        oAttackAnim = 0,

        -- ItemInHandRenderer 的手部高度（1 = 完全举起，0 = 沉到最低）。
        -- 新状态 = 刚换到这件物品，所以从最低处开始抬。
        handHeight = 0,
        oHandHeight = 0,

        -- GameRenderer.bobView 的走路晃动
        walkDist = 0,
        walkDistO = 0,
        bob = 0,
        bobO = 0,

        -- submitHandsWithItems 的转头滞后
        xBob = 0,
        xBobO = 0,
        yBob = 0,
        yBobO = 0,

        lastPos = nil,

        -- 诊断（mcitem_debug）：实测 tick 频率 / 起挥间隔 / 整弧时长
        tickSteps = 0,
        tickClockStart = nil,
        lastSwingAt = nil,
        lastSwingGap = nil,
        arcStartAt = nil,
        arcEndAt = nil,
    }
end

function MCITEM.ResolveSwingDuration(durationTicks)
    -- LivingEntity.getCurrentSwingDuration()：基础时长取自物品的 SwingAnimation，
    -- 急迫 / 挖掘疲劳会再修正（本库没有药水效果，只保留基础时长）。
    return math.max(math.floor(tonumber(durationTicks) or MCITEM.DefaultSwingDurationTicks), 1)
end

--------------------------------------------------------------------------------
-- 挥动状态机（LivingEntity 那一半）
--------------------------------------------------------------------------------

-- LivingEntity.updateSwingTime()。每个 MC tick 调用一次。
function MCITEM.UpdateSwingTime(state, durationTicks)
    local duration = MCITEM.ResolveSwingDuration(durationTicks)

    if state.swinging then
        state.swingTime = state.swingTime + 1
        if state.swingTime >= duration then
            state.swingTime = 0
            state.swinging = false
        end
    else
        state.swingTime = 0
    end

    -- LivingEntity.baseTick() 在同一 tick 更早的位置做 oAttackAnim = attackAnim，
    -- 等价于在重算 attackAnim 之前存一份旧值。
    state.oAttackAnim = state.attackAnim
    state.attackAnim = state.swingTime / duration
end

-- LivingEntity.swing(InteractionHand)。
-- 返回是否真的重新起了一次挥动——**这个门就是"挖掘和攻击看起来不一样"的全部原因**：
-- 挖掘时每 tick 都请求一次，但只有 swingTime >= duration/2 才准重启，于是动画永远
-- 在前半段循环（6 tick 的剑 → 每 4 tick 重来一次，只播到 0.5）；单次攻击没人打断，
-- 完整播完 0 → 1。两者共用同一条曲线。completeCycle 让本地挖掘改用完整周期。
function MCITEM.Swing(state, durationTicks, now, completeCycle)
    local duration = MCITEM.ResolveSwingDuration(durationTicks)

    -- swingTime < 0 = 这一 tick 已经排过一次重启了。MC 一个 tick 只会调一次 swing()，
    -- 所以原文那条 `swingTime < 0` 分支是留给"同 tick 换手"的；我们按 Source 的
    -- 66Hz 请求，不吃掉重复请求的话一个 tick 能重启三次（实测 16 次/秒）。
    if state.swinging and state.swingTime < 0 then return false end

    -- Continuous mining opts into a complete arc instead of Java's half-arc
    -- restart. Combat and item-use callers retain the original gate.
    local restartTick = completeCycle and duration or math.floor(duration / 2)
    if state.swinging and state.swingTime < restartTick then
        return false
    end

    local wasSwinging = state.swinging

    state.swingTime = -1
    state.swinging = true

    -- 从静止起挥要把 20Hz 相位对齐到当前时刻并立刻走一步（-1 → 0）：MC 的输入本来就
    -- 落在 tick 边界上，不这么做点击到起挥会白等最多 50ms。
    --
    -- 但**这里不能自己动 tickAt**：Swing 是从预测上下文调用的（PrimaryAttack），
    -- 而 tickAt 必须只属于渲染时钟，否则渲染侧算出来的 partialTick 会恒为 0。
    -- 所以只挂一个标记，交给下一次 Advance（渲染上下文）去锚。
    --
    -- **已经在挥的时候绝不重锚**：挖掘是"每次重启都对一次相位"的话，20Hz 时钟会被
    -- Source 的 66Hz 输入栅格带着走，重启间隔在 3~4 tick 之间拍频（实测 5.8 次/秒，
    -- 而 MC 是稳定的 5 次/秒）。让时钟自由跑、只由 duration/2 门决定重启，节奏才准。
    if not wasSwinging then
        state.swingAnchorPending = true
    end

    -- 诊断用：实际起挥间隔和整弧起点。
    if now then
        state.lastSwingGap = state.lastSwingAt and (now - state.lastSwingAt) or nil
        state.lastSwingAt = now
        state.arcStartAt = now
    end

    return true
end

-- LivingEntity.getAttackAnim(partialTick)。
-- f < 0 时 +1 是为了处理"挥到一半被重启"的回绕（attackAnim 从 0.5 跳回 0），
-- 挖掘的循环全靠它才不会每 4 tick 抽一下。
function MCITEM.GetAttackAnim(state, partialTick)
    local f = state.attackAnim - state.oAttackAnim
    if f < 0 then f = f + 1 end
    return state.oAttackAnim + f * (partialTick or 0)
end

--------------------------------------------------------------------------------
-- 手部升降（ItemInHandRenderer.tick）
--------------------------------------------------------------------------------

-- **这就是"剑会先沉下去再重新拿出来"那个动画。** 26.2 里目标高度是
-- `getItemSwapScale(1.0)^3`，而 getItemSwapScale 用的分母就是
-- getCurrentItemAttackStrengthDelay()——**和准星那个冷却图标是同一条时间轴**。
-- 三次方让它前段几乎不动、末尾猛地抬起来，所以钻石剑（12.5 tick）看着是
-- "沉下去 → 憋一会 → 0.65s 时啪地举起来"。
--
-- 什么时候会沉下去，26.2 分得很细：
--   · 换物品        Player.tick 发现主手物品变了 → resetAttackStrengthTicker() → 两个 ticker 都清零 → 沉
--   · 挥空          Minecraft.startAttack 的 MISS 分支 → resetAttackStrengthTicker() → 沉
--   · 打中生物      Player.attack → onAttack() → resetOnlyAttackStrengthTicker() → **只清攻击 ticker，不沉**
-- （1.21 及以前这里用的是 getAttackStrengthScale，所以打中生物也会沉。
--   `legacyDipOnHit` 就是切回旧行为用的。）
--
-- 第四种情况是**同一件物品的组件变了**，源码里表达成"可见物品 ≠ 手里的物品"：
--     if (this.shouldInstantlyReplaceVisibleItem(this.mainHandItem, nextMainHand)) this.mainHandItem = nextMainHand;
--     ...
--     float target = this.mainHandItem != nextMainHand ? 0.0f : attackAnim³;
--     ...
--     if (this.mainHandHeight < 0.1f) this.mainHandItem = nextMainHand;
-- `shouldInstantlyReplaceVisibleItem` 用 `matchesIgnoringComponents(..., DataComponentType::ignoreSwapAnimation)`
-- 比较，而 `CHARGED_PROJECTILES` 注册时**没有** `.ignoreSwapAnimation()`（`DAMAGE` 有）。
-- 所以弩上好弦的那一刻组件变了 → 两把弩不算同一件 → 手沉到 0.1 以下再抬起来，
-- 也就是玩家看到的"拉满后沉下去再拿出来"。`state.swapPending` 就是那个
-- `mainHandItem != nextMainHand`。
function MCITEM.UpdateHandHeight(state, itemSwapScale, handsBusy)
    state.oHandHeight = state.handHeight

    if handsBusy then
        state.handHeight = math.Clamp(state.handHeight - MCITEM.HandHeightRate, 0, 1)
        return
    end

    local target = itemSwapScale * itemSwapScale * itemSwapScale
    if state.swapPending then target = 0 end

    state.handHeight = state.handHeight
        + math.Clamp(target - state.handHeight, -MCITEM.HandHeightRate, MCITEM.HandHeightRate)

    -- `if (this.mainHandHeight < 0.1f) this.mainHandItem = nextMainHand;`
    if state.swapPending and state.handHeight < 0.1 then state.swapPending = nil end
end

-- 同一件物品的组件变了（弩上弦、耐久以外的任何非 ignoreSwapAnimation 组件）。
function MCITEM.BeginItemSwapDip(state)
    if not state then return end
    state.swapPending = true
end

-- Minecraft.ItemInHandRenderer.itemUsed(hand): every successful client-side
-- use resets only the current hand height. The renderer then raises it by
-- HandHeightRate (0.4) per tick, producing the short vanilla dip-and-lift.
-- Keep oHandHeight untouched because Java preserves the previous tick value.
function MCITEM.ItemUsed(state)
    if not state then return end
    state.handHeight = 0
end

-- applyItemArmTransform 吃的是 equippedProgress = 1 - 插值后的手部高度。
function MCITEM.GetEquippedProgress(state, partialTick)
    return 1 - lerp(partialTick or 0, state.oHandHeight, state.handHeight)
end

--------------------------------------------------------------------------------
-- 视角晃动（GameRenderer.bobView + submitHandsWithItems 的转头滞后）
--------------------------------------------------------------------------------

-- AbstractClientPlayer.updateBob()：离地 / 死亡 / 游泳时目标是 0，否则是每 tick
-- 水平位移（格）夹在 0.1。走和跑的**振幅一样**，只有频率不同——频率来自 walkDist。
-- LocalPlayer.move()：walkDist += 本 tick 水平位移(格) * 0.6
function MCITEM.UpdateViewBob(state, movedBlocks, onGround)
    -- 频率封顶，见 MaxWalkBlocksPerTick 的注释。振幅那一半是 MC 自己的 min(0.1,...)。
    local walkStep = math.min(movedBlocks, MCITEM.MaxWalkBlocksPerTick)

    state.walkDistO = state.walkDist
    state.walkDist = state.walkDist + walkStep * 0.6

    local target = onGround and math.min(0.1, movedBlocks) or 0
    state.bobO = state.bob
    state.bob = state.bob + (target - state.bob) * 0.4
end

-- LocalPlayer.aiStep()：xBob/yBob 是视角的一阶低通（每 tick 追 50%），
-- 渲染时用"当前视角 - 平滑视角"的差 × 0.1 度当作手部滞后。
-- MC 的 yRot 是不归一化的浮点，GMod 的 EyeAngles 会绕回 ±180，所以取最短角差。
function MCITEM.UpdateViewSway(state, pitch, yaw)
    state.xBobO = state.xBob
    state.yBobO = state.yBob
    state.xBob = state.xBob + (pitch - state.xBob) * 0.5
    state.yBob = state.yBob + math.AngleDifference(yaw, state.yBob) * 0.5
end

function MCITEM.GetViewBob(state, partialTick)
    -- getBackwardsInterpolatedWalkDistance：注意是**取负**的。
    local delta = state.walkDist - state.walkDistO
    return -(state.walkDist + delta * (partialTick or 0)), lerp(partialTick or 0, state.bobO, state.bob)
end

function MCITEM.GetViewSway(state, pitch, yaw, partialTick)
    partialTick = partialTick or 0
    local smoothPitch = lerp(partialTick, state.xBobO, state.xBob)
    local smoothYaw = state.yBobO + math.AngleDifference(state.yBob, state.yBobO) * partialTick
    return (pitch - smoothPitch) * 0.1, math.AngleDifference(yaw, smoothYaw) * 0.1
end

--------------------------------------------------------------------------------
-- 20Hz 驱动
--------------------------------------------------------------------------------

-- 把 20Hz 时钟推进到 now，顺带把所有子模型各走一步，返回渲染用的 partialTick。
-- 幂等：同一帧调用多次不会多走 tick。
--
-- params：
--   swingTicks       物品的 SwingAnimation.duration
--   itemSwapScale    Player.getItemSwapScale(1.0)，手部高度的目标（会取三次方）
--   handsBusy        LocalPlayer.isHandsBusy()
--   movedBlocks      距上一 tick 的水平位移（格），用于 walkDist / bob
--   onGround / pitch / yaw
function MCITEM.Advance(state, now, params)
    local tick = MCITEM.TickSeconds

    if not state.tickAt or math.abs(now - state.tickAt) > 1 then
        -- 首次使用 / 换图 / 长时间卡顿：重新对相位，不要补跑几十个 tick。
        state.tickAt = now
        state.tickSteps = 0
        state.tickClockStart = now
        state.swingAnchorPending = nil
        return 0, 0
    end

    -- 刚从静止起挥：把相位锚到现在并立刻走一步（见 MCITEM.Swing 的注释）。
    if state.swingAnchorPending then
        state.swingAnchorPending = nil
        state.tickAt = now
        MCITEM.UpdateSwingTime(state, params.swingTicks)
        state.tickSteps = (state.tickSteps or 0) + 1
        return 0, 1
    end

    -- **时钟只许前进。** 以前遇到"时间倒流"会 `tickAt = now` 重锚，等于把调用点之间
    -- 的时钟偏移每帧当成一段新时间重走一遍 tick——整套动画会按偏移量成比例变快
    -- （沙箱实测 60ms 偏移 = 3.3 倍速）。现在遇到倒流就原地不动，等它追上来。
    if now < state.tickAt then
        return 0, 0
    end

    -- 门限要留一点余量：tickAt 是一路 += 0.05 累加出来的，和 CurTime() 之间的浮点
    -- 残差会让"正好一个 tick"变成 0.049999...，于是这一轮不走、下一轮连走两步，
    -- 表现就是挥动偶尔卡一帧再跳一下。
    local steps = math.min(math.floor((now - state.tickAt) / tick + 1e-3), 20)

    if steps > 0 then
        -- 低帧率下一帧要补多个 tick：位移按步数摊开，否则 walkDist 会把同一段路
        -- 重复计好几次，晃动频率跟着掉帧翻倍。
        local movedPerStep = (params.movedBlocks or 0) / steps

        for _ = 1, steps do
            state.tickAt = state.tickAt + tick

            local wasSwinging = state.swinging
            MCITEM.UpdateSwingTime(state, params.swingTicks)
            if wasSwinging and not state.swinging then
                state.arcEndAt = state.tickAt -- 诊断用：整弧实际走了多久
            end

            MCITEM.UpdateHandHeight(state, params.itemSwapScale or 1, params.handsBusy)
            MCITEM.UpdateViewBob(state, movedPerStep, params.onGround ~= false)
            MCITEM.UpdateViewSway(state, params.pitch or 0, params.yaw or 0)
        end

        state.tickSteps = (state.tickSteps or 0) + steps
    end

    return math.Clamp((now - state.tickAt) / tick, 0, 1), steps
end

-- 诊断：实测的 tick 频率。应该恒等于 20.0——偏了就说明时钟被谁多推了。
function MCITEM.MeasuredTickRate(state, now)
    if not state.tickClockStart then return 0 end
    local elapsed = now - state.tickClockStart
    if elapsed <= 0.25 then return 0 end
    return (state.tickSteps or 0) / elapsed
end

--------------------------------------------------------------------------------
-- 攻击蓄力（Player 那一半，1.9 的攻击冷却）
--------------------------------------------------------------------------------

-- Player.getCurrentItemAttackStrengthDelay() = (1 / ATTACK_SPEED) * 20，单位 tick。
-- 钻石剑 ATTACK_SPEED = 4.0 + (-2.4) = 1.6 → 12.5 tick = 0.625s。
function MCITEM.AttackStrengthDelay(attackSpeed)
    return (1 / math.max(tonumber(attackSpeed) or MCITEM.PlayerBaseAttackSpeed, 0.05)) * 20
end

-- attackStrengthTicker / itemSwapTicker 都是整数 tick 计数。这里由"上一次重置的
-- 绝对时间"推出来，保持整数量化——MC 的冷却条本来就是一格一格跳的。
-- 加 epsilon 是因为 0.3 / 0.05 在浮点里是 5.999999...，直接 floor 会把整 6 tick
-- 数成 5，冷却条和"满蓄力"判定都会晚一格。
function MCITEM.Ticker(resetAt, now)
    if not resetAt then return math.huge end
    return math.floor(math.max(now - resetAt, 0) / MCITEM.TickSeconds + 1e-6)
end

MCITEM.AttackStrengthTicker = MCITEM.Ticker

-- Player.getAttackStrengthScale(partialTick) / getItemSwapScale(partialTick)：
-- 两个用的是**同一个分母**（getCurrentItemAttackStrengthDelay），只是 ticker 不同。
function MCITEM.ScaleFromTicker(ticker, partialTick, delayTicks)
    if ticker == math.huge then return 1 end
    return math.Clamp((ticker + (partialTick or 0)) / math.max(delayTicks, 0.05), 0, 1)
end

MCITEM.AttackStrengthScale = MCITEM.ScaleFromTicker

-- 便捷入口：直接从重置时间算比例，同时把冷却时长（tick）一并返回。
function MCITEM.ChargeFrom(resetAt, now, attackSpeed, partialTick)
    local delay = MCITEM.AttackStrengthDelay(attackSpeed)
    return MCITEM.ScaleFromTicker(MCITEM.Ticker(resetAt, now), partialTick, delay), delay
end

-- Player.baseDamageScaleFactor() = 0.2 + charge^2 * 0.8
function MCITEM.BaseDamageScaleFactor(charge)
    return 0.2 + charge * charge * 0.8
end

return MCITEM
