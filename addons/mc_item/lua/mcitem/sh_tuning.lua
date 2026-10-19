-- MCITEM 玩法调参：伤害倍率、攻击距离、粒子预算、拉弓抖动幅度。
--
-- 这里放的是**故意偏离 MC 原版**的那几个数（GMod 的血量刻度、Source 的重力、
-- 客户端粒子预算），全部出成 convar，改数不用改代码。原版公式仍然在各自的模块里，
-- 本文件只提供最后那一次乘法。
--
-- 击退倍率 `mcitem_knockback_scale` 在 `sh_use_effects.lua`（和 USE_EFFECTS 一起），
-- 不重复注册；两边都会被 `sh_config_menu.lua` 收进 MCSWEP 的设置面板。

MCITEM = MCITEM or {}

--------------------------------------------------------------------------------
-- 统一时钟
--------------------------------------------------------------------------------
--
-- ⚠ 客户端有两套 `CurTime()`：预测上下文（Think / PrimaryAttack）领先渲染上下文，
-- 两者相差一个不固定的偏移。任何"按 tick 收敛"的状态机（拉弓的 FOV 平滑、弓/弩/
-- 三叉戟的使用计时）如果被这两套时钟**交替**推进，`steps = floor((now-last)/tick)`
-- 会一帧巨大、一帧为负，值就在新旧之间来回跳 —— 表现就是"拉弓的时候整把弓在抖，
-- 蓄满之后反而不抖了"（蓄满后目标值不变，两套时钟收敛到同一个数）。
--
-- 所以凡是这类状态机一律走本函数：客户端用 `SysTime()`（全局单调、和预测/渲染
-- 上下文都无关），服务端只有一个时钟，用 `CurTime()`。
function MCITEM.UseClock()
    if CLIENT then return SysTime() end
    return CurTime()
end

--------------------------------------------------------------------------------
-- 伤害倍率
--------------------------------------------------------------------------------
--
-- MC 的一颗心 = 2 点，玩家满血 20；GMod 玩家满血 100 且没有护甲减伤曲线，直接照抄
-- MC 的伤害数字打起来像挠痒。默认 ×5 正好把 MC 的 20 血刻度映射到 GMod 的 100。
-- 作用范围是**武器伤害**：近战（含横扫 / 长矛 / 重锤加成）、箭、三叉戟、投掷物直伤。
-- 药水的瞬间伤害 / 中毒等状态效果**不乘**，那是效果系统自己的刻度。
MCITEM.DamageScaleConVar = MCITEM.DamageScaleConVar or CreateConVar(
    "mcitem_damage_scale", "5", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED,
    "Multiplier applied to every MCITEM weapon damage value (melee, sweep, spear, mace, "
        .. "arrow, trident, thrown projectiles). 1 = literal Minecraft numbers."
)

function MCITEM.DamageScale()
    local cvar = MCITEM.DamageScaleConVar
    if not cvar then return 1 end
    return math.max(cvar:GetFloat(), 0)
end

function MCITEM.ScaleDamage(amount)
    return (tonumber(amount) or 0) * MCITEM.DamageScale()
end

-- 把 GMod 实际扣掉的血量还原到 Minecraft 的伤害刻度。伤害心粒子等视觉反馈
-- 必须按这个刻度计算，否则默认 x5 映射会把一颗原版黑心错误放大成五颗。
-- scale == 0 时没有可逆映射（而且本来也不该造成武器伤害），返回 0 避免除零。
function MCITEM.UnscaleDamage(amount)
    local scale = MCITEM.DamageScale()
    if scale <= 0 then return 0 end
    return math.max((tonumber(amount) or 0) / scale, 0)
end

-- Player.damageStatsAndHearts：实际伤害严格大于 2 才生成，数量为 floor(damage / 2)。
-- `actualDamage` 是 Source 实际扣血，因此先通过当前武器倍率还原；上限对应网络字段。
function MCITEM.DamageHeartParticleCount(actualDamage)
    local minecraftDamage = MCITEM.UnscaleDamage(actualDamage)
    if minecraftDamage <= 2 then return 0 end
    return math.Clamp(math.floor(minecraftDamage * 0.5), 0, 1023)
end

--------------------------------------------------------------------------------
-- 攻击距离
--------------------------------------------------------------------------------
--
-- MC 的 `AttackRange.defaultFor(player)` = ENTITY_INTERACTION_RANGE = 3 格。Source 的
-- 玩家碰撞盒比 MC 宽、视角也更贴脸，3 格实机偏短，所以默认放宽一点并出成 convar。
-- 长矛不吃这个值：它自带 `AttackRange(2, 4.5, ...)`，在 spear base 里单独实现。
MCITEM.AttackRangeConVar = MCITEM.AttackRangeConVar or CreateConVar(
    "mcitem_attack_range", "4.5", FCVAR_ARCHIVE + FCVAR_NOTIFY + FCVAR_REPLICATED,
    "Melee attack range in Minecraft blocks (vanilla ENTITY_INTERACTION_RANGE is 3)."
)

function MCITEM.AttackRangeBlocks()
    local cvar = MCITEM.AttackRangeConVar
    if not cvar then return MCITEM.PlayerEntityInteractionRange or 3 end
    return math.Clamp(cvar:GetFloat(), 0.5, 16)
end

--------------------------------------------------------------------------------
-- 客户端粒子预算
--------------------------------------------------------------------------------
--
-- 一次重锤砸地是 750 个粒子，喷溅药水 / 破瓶 / 食物碎屑还会叠在上面。粒子本身是
-- 批量 mesh 绘制的（见 cl_combat_particles.lua 的注释），但活的粒子越多、每帧的
-- 20Hz 推进和顶点填充就越贵。这里给**全部 MCITEM 客户端粒子**一个统一的活跃数上限：
-- 超了就按"先来先淘汰"丢掉最老的，而不是拒绝新效果（新效果才是玩家正在看的那个）。
MCITEM.ParticleLimitConVar = MCITEM.ParticleLimitConVar or (CLIENT and CreateClientConVar(
    "mcitem_particle_limit", "1200", true, false,
    "Maximum number of live MCITEM particles (combat, potions, throwables, food). 0 = unlimited."
) or nil)

function MCITEM.ParticleLimit()
    local cvar = MCITEM.ParticleLimitConVar
    if not cvar then return 0 end
    return math.max(math.floor(cvar:GetInt()), 0)
end

-- 共享的活跃粒子计数：各个粒子系统注册自己的表，预算按总数分摊。
MCITEM.ParticlePools = MCITEM.ParticlePools or {}

function MCITEM.RegisterParticlePool(name, list)
    if not isstring(name) or not istable(list) then return false end
    MCITEM.ParticlePools[name] = list
    return true
end

function MCITEM.LiveParticleCount()
    local total = 0
    for _, list in pairs(MCITEM.ParticlePools) do total = total + #list end
    return total
end

-- 生成 `incoming` 个新粒子之前调用：返回**本次真正允许生成**的个数，并在需要时
-- 从最老的粒子里腾出位置。一次请求最多占掉预算的一半，避免单个大效果（重锤）
-- 把别的系统全部挤掉。
function MCITEM.ReserveParticles(incoming)
    incoming = math.max(math.floor(tonumber(incoming) or 0), 0)
    if incoming <= 0 then return 0 end

    local limit = MCITEM.ParticleLimit()
    if limit <= 0 then return incoming end

    local allowed = math.min(incoming, math.max(math.floor(limit * 0.5), 1))
    local live = MCITEM.LiveParticleCount()
    local overflow = live + allowed - limit
    if overflow <= 0 then return allowed end

    -- 先从最大的池子里丢最老的，直到腾出位置。
    while overflow > 0 do
        local biggest, biggestCount = nil, 0
        for _, list in pairs(MCITEM.ParticlePools) do
            if #list > biggestCount then biggest, biggestCount = list, #list end
        end
        if not biggest or biggestCount <= 0 then break end

        local remove = math.min(overflow, biggestCount)
        local remaining = biggestCount - remove
        for index = 1, remaining do biggest[index] = biggest[index + remove] end
        for index = remaining + 1, biggestCount do biggest[index] = nil end
        overflow = overflow - remove
    end

    return allowed
end

--------------------------------------------------------------------------------
-- 拉弓抖动
--------------------------------------------------------------------------------
--
-- ItemInHandRenderer 的弓 / 弩 / 三叉戟分支都有这一段：
--     if (f10 > 0.1F) { translate(0, sin((f9 - 0.1F) * 1.3F) * (f10 - 0.1F) * 0.004F, 0); }
-- 幅度只有 0.0036 格，原版几乎看不出来；蓄满之后 f10 不再变化，剩下的就只有这一下
-- 微抖 —— 这才是"MC 里只有蓄满之后才抖"的来源。留一个倍率给手动微调，1 = 原版。
MCITEM.BowShakeConVar = MCITEM.BowShakeConVar or (CLIENT and CreateClientConVar(
    "mcitem_draw_shake", "1", true, false,
    "Amplitude multiplier for Minecraft's tiny bow/crossbow/trident draw shake. 0 = off."
) or nil)

function MCITEM.DrawShakeScale()
    local cvar = MCITEM.BowShakeConVar
    if not cvar then return 1 end
    return math.max(cvar:GetFloat(), 0)
end
