-- DataComponents.USE_EFFECTS + AbstractClientPlayer.getFieldOfViewModifier（MC 26.2）。
--
-- 两件"拉弓/装填时的手感"，源码位置：
--   ① 移动减速  LocalPlayer.modifyInput：
--        newInput = input.scale(0.98f)
--        if (isUsingItem() && !isPassenger()) newInput = newInput.scale(itemUseSpeedMultiplier())
--      itemUseSpeedMultiplier() = USE_EFFECTS.speedMultiplier()，
--      UseEffects.DEFAULT = (canSprint=false, interactVibrations=true, speedMultiplier=0.2f)。
--      冲刺由 isSlowDueToUsingItem()（= isUsingItem && !canSprint）掐断。
--      **长矛是唯一的例外**：Item.Properties.spear 装的是 UseEffects(true, false, 1.0f)，
--      右键冲刺攻击靠的就是它，别把长矛也减速了。
--   ② 弓的视角放大  AbstractClientPlayer.getFieldOfViewModifier：
--        if (getUseItem().is(Items.BOW)) {
--            float scale = min(getTicksUsingItem() / 20f, 1f);
--            modifier *= 1f - square(scale) * 0.15f;
--        }
--      满弓 = 0.85 倍 FOV。只有**弓**有，弩 / 三叉戟没有。
--
-- 减速走 SetupMove（预测上下文，客户端和服务端跑同一段），FOV 走 SWEP:TranslateFOV。

MCITEM = MCITEM or {}

-- UseEffects.DEFAULT
MCITEM.DefaultUseSpeedMultiplier = 0.2
MCITEM.DefaultUseCanSprint = false

-- BowItem.MAX_DRAW_DURATION
MCITEM.BowMaxDrawTicks = 20
MCITEM.BowFovShrink = 0.15

-- getFieldOfViewModifier 的弓那一支。timeHeld 单位是 MC tick。
--
-- 结尾那句 `return Mth.lerp(effectScale, 1.0f, modifier)` 是 options.fovEffectScale
-- （原版默认 1.0）：设 0 就完全不缩。
MCITEM.FovEffectScale = CreateConVar(
    "mcitem_fov_effect_scale", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
    "Minecraft's fovEffectScale option: 0 = no bow zoom at all, 1 = vanilla."
)

function MCITEM.BowFovModifier(timeHeld)
    local scale = math.Clamp((tonumber(timeHeld) or 0) / MCITEM.BowMaxDrawTicks, 0, 1)
    local modifier = 1 - scale * scale * MCITEM.BowFovShrink
    return Lerp(math.Clamp(MCITEM.FovEffectScale:GetFloat(), 0, 1), 1, modifier)
end

-- Camera.setup：`fovModifier += (target - fovModifier) * 0.5` **每 tick**一次，再 clamp
-- 到 [0.1, 1.5]；`calculateFov` 再按 **partialTick** 在 `oldFovModifier` 和 `fovModifier`
-- 之间插值：
--     float fov = options.fov() * Mth.lerp(partialTicks, this.oldFovModifier, this.fovModifier);
--
-- ⚠ 那句 `Mth.lerp(partialTicks, ...)` 不能省。只做 20Hz 的那一步、每帧读同一个值，
-- FOV 就变成一秒 20 级的阶梯；在 100+ fps 下看起来正是"明明没掉帧却一顿一顿"。
-- 这和 3.1 那个 partialTick 坑是同一类问题，只是换到了 FOV 上。
--
-- ⚠⚠ 时钟必须**只有一套**（2026-08-12 修）。这个函数原来是
-- `now = now or (CLIENT and SysTime() or CurTime())`：`SWEP:TranslateFOV` 不传参数
-- 走 SysTime，而 `cl_view.lua` 的手部补偿传的是渲染上下文的 `CurTime()`。两套时钟
-- 相差一个不固定的大偏移，于是同一帧里
--   · 一路算出 `steps` 巨大 → 一次性收敛到目标值；
--   · 另一路算出 `now - last` 为负 → `steps <= 0`、partialTick = 0 → 返回**旧值**。
-- 值就在新旧之间逐帧来回跳，世界 FOV 和手部补偿一起抖 —— 这正是用户报的
-- "拉弓过程太抖，蓄满之后反而不抖了"（蓄满后目标值恒定，两路收敛到同一个数）。
-- 现在一律用 `MCITEM.UseClock()`（客户端 SysTime，服务端 CurTime），传进来的 now
-- 只在没有统一时钟时兜底。
function MCITEM.AdvanceFovModifier(weapon, target, now)
    now = isfunction(MCITEM.UseClock) and MCITEM.UseClock()
        or now or (CLIENT and SysTime() or CurTime())
    target = tonumber(target) or 1

    local last = weapon.MCFovModifierAt
    if not last then
        weapon.MCFovModifierAt = now
        weapon.MCFovModifierOld = target
        weapon.MCFovModifierValue = target
        return target
    end

    local value = weapon.MCFovModifierValue or 1
    local old = weapon.MCFovModifierOld or value
    local steps = math.floor((now - last) / MCITEM.TickSeconds)

    if steps > 0 then
        -- 掉帧 / 切武器回来时不要补上百步：0.5 的收敛速度 12 步就已经到 1e-4 了。
        for _ = 1, math.min(steps, 12) do
            old = value
            value = math.Clamp(value + (target - value) * 0.5, 0.1, 1.5)
        end
        weapon.MCFovModifierOld = old
        weapon.MCFovModifierValue = value
        last = last + steps * MCITEM.TickSeconds
        weapon.MCFovModifierAt = last
    end

    local partialTick = math.Clamp((now - last) / MCITEM.TickSeconds, 0, 1)
    return Lerp(partialTick, weapon.MCFovModifierOld or value, value)
end

--------------------------------------------------------------------------------
-- 击退缩放（MC → Source 的重力差修正）
--------------------------------------------------------------------------------
--
-- MC 的重力是 0.08 格/tick² = 32 格/秒² ≈ 1168 u/s²，Source 默认 sv_gravity 是 600 u/s²
-- —— **差了将近一倍**。LivingEntity.knockback 的 0.4 格/tick 竖直冲量在 MC 里把人抬约
-- 1 格，同一个速度照抄到 Source 会抬约 1.95 格，水平方向还因为 Source 空气控制更强而
-- 飘得更远。这就是"武器打玩家击���太高"的来源，不是公式抄错了。
-- 对齐顶点高度需要 sqrt(600/1168) ≈ 0.72；实机试下来还是偏飘，按用户实测定在 0.3。
-- 设成 1 = 字面照抄 MC。
local cvKnockbackScale = CreateConVar(
    "mcitem_knockback_scale", "0.3", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED,
    "Scales Minecraft's knockback velocity into Source. 1 = literal MC value "
        .. "(too strong: Source gravity is about half of Minecraft's)."
)

function MCITEM.KnockbackScale()
    return math.max(cvKnockbackScale:GetFloat(), 0)
end

if not MCITEM.UseEffectsHookInstalled then
    MCITEM.UseEffectsHookInstalled = true

    hook.Add("SetupMove", "MCITEM.UseEffects", function(ply, mv, cmd)
        if not IsValid(ply) then return end

        local weapon = ply:GetActiveWeapon()
        if not IsValid(weapon) or not weapon.GetMCUseEffects then return end

        local multiplier, canSprint = weapon:GetMCUseEffects()
        if multiplier == nil then return end

        -- isPassenger() 的等价物：坐在载具里不减速。
        if ply:InVehicle() then return end

        if not canSprint then
            -- isSlowDueToUsingItem()：冲刺直接掐断。
            mv:SetButtons(bit.band(mv:GetButtons(), bit.bnot(IN_SPEED)))
        end

        if multiplier >= 1 then return end

        -- 两条一起压：
        --   ① forward/side 是 modifyInput 的直译（MC 缩的就是移动输入）；
        --   ② MaxClientSpeed 是 Source 侧的硬上限。只做 ① 的话，玩家已经在跑时
        --      引擎按 maxspeed 归一化速度向量，缩小的输入会被重新放大回满速，
        --      看起来就是"减速没生效"。两条都写才在起步和续跑两种情况下都成立。
        mv:SetForwardSpeed(mv:GetForwardSpeed() * multiplier)
        mv:SetSideSpeed(mv:GetSideSpeed() * multiplier)
        mv:SetMaxClientSpeed(mv:GetMaxClientSpeed() * multiplier)
        mv:SetMaxSpeed(mv:GetMaxSpeed() * multiplier)
    end)
end
