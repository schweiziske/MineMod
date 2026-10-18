-- 把 MCITEM 的 convar 挂进 MCSWEP 的游戏内设置面板（"设置"那一栏）。
--
-- MCSWEP 侧新增了 `MC.API.Config.RegisterGroup / RegisterCategory`（见
-- `lua/mc/api/sh_api.lua`），本文件只是它的第一个使用者：面板数据是纯元数据，
-- 注册两次同一个 id 是幂等的。MCSWEP 不在场（或版本没有这个 API）时整段静默跳过，
-- convar 本身照样能在控制台用 —— MCITEM 仍然是可独立安装的 addon。

MCITEM = MCITEM or {}

if MCITEM.ConfigMenuInstalled then return end
MCITEM.ConfigMenuInstalled = true

local function item(name, label, labelZH, kind, help, helpZH, extra)
    local entry = {
        name = name,
        label = label,
        labelZH = labelZH,
        kind = kind or "number",
        help = help or "",
        helpZH = helpZH or "",
    }
    for key, value in pairs(extra or {}) do entry[key] = value end
    return entry
end

local GROUPS = {
    client = { id = "mcitem", label = "MC Weapons", zhLabel = "MC 武器" },
    server = { id = "mcitem", label = "MC Weapons", zhLabel = "MC 武器" },
}

local CATEGORIES = {
    server = {
        {
            id = "mcitem_combat",
            group = "mcitem",
            label = "Weapon balance",
            zhLabel = "武器数值",
            description = "Damage, knockback and reach for every Minecraft weapon.",
            descriptionZH = "所有 Minecraft 武器的伤害、击退与攻击距离。",
            items = {
                item("mcitem_damage_scale", "Damage multiplier", "伤害倍率", "number",
                    "Multiplies every weapon damage value (melee, sweep, spear, mace, arrow, trident, thrown items). 1 = literal Minecraft numbers.",
                    "所有武器伤害的倍率（近战、横扫、长矛、重锤、箭、三叉戟、投掷物）。1 = 照抄 Minecraft 数值。"),
                item("mcitem_knockback_scale", "Knockback multiplier", "击退倍率", "number",
                    "Scales Minecraft knockback velocity into Source. Enchantment-style tweaks go here.",
                    "把 Minecraft 的击退速度换算进 Source 的倍率；后续附魔类调整也走这一个。"),
                item("mcitem_attack_range", "Melee reach", "近战攻击距离", "number",
                    "Melee attack range in blocks (vanilla ENTITY_INTERACTION_RANGE is 3).",
                    "近战攻击距离，单位为格（原版 ENTITY_INTERACTION_RANGE 是 3 格）。",
                    { unit = "blocks" }),
                item("mcitem_fov_effect_scale", "Bow zoom amount", "拉弓缩放强度", "number",
                    "Minecraft's fovEffectScale option: 0 = no bow zoom at all, 1 = vanilla.",
                    "对应 Minecraft 的 fovEffectScale：0 = 拉弓完全不缩视角，1 = 原版。"),
            },
        },
        {
            id = "mcitem_holdtypes",
            group = "mcitem",
            label = "Third-person poses",
            zhLabel = "第三人称动作",
            description = "Which Half-Life hold animation each weapon state uses.",
            descriptionZH = "每种武器状态使用哪一套半条命手持动画。",
            items = {
                item("mcitem_holdtype_item", "Tools and items", "工具 / 物品", "string",
                    "Idle pose for swords, tools, food, potions and throwables.",
                    "剑、工具、食物、药水、投掷物的静止手持动作。"),
                item("mcitem_holdtype_item_attack", "Tools and items (attack)", "工具 / 物品（攻击）", "string",
                    "One-shot melee-family gesture for left attacks and continuous mining.",
                    "左键攻击与持续挖掘时的一次性 melee 动作。"),
                item("mcitem_holdtype_bow", "Bow (idle)", "弓（静止）", "string",
                    "Bow hold pose while not drawing.", "没有拉弓时的手持动作。"),
                item("mcitem_holdtype_bow_draw", "Bow (drawing)", "弓（拉弓）", "string",
                    "Bow hold pose while drawing.", "拉弓时的手持动作。"),
                item("mcitem_holdtype_bow_attack", "Bow (left attack)", "弓（左键攻击）", "string",
                    "One-shot melee-family pose used for bow melee/mining.", "弓左键攻击 / 挖掘时的一次性 melee 动作。"),
                item("mcitem_holdtype_crossbow", "Crossbow (idle)", "弩（静止）", "string",
                    "Crossbow hold pose while unloaded and idle.", "未装填、静止时的手持动作。"),
                item("mcitem_holdtype_crossbow_load", "Crossbow (loading)", "弩（装填）", "string",
                    "Crossbow hold pose while loading.", "装填过程中的手持动作。"),
                item("mcitem_holdtype_crossbow_charged", "Crossbow (loaded)", "弩（已上弦）", "string",
                    "Crossbow hold pose once charged.", "上好弦之后的手持动作。"),
                item("mcitem_holdtype_crossbow_attack", "Crossbow (left attack)", "弩（左键攻击）", "string",
                    "One-shot melee-family pose for left attack/mining.", "弩左键攻击 / 挖掘时的一次性 melee 动作。"),
                item("mcitem_holdtype_mace", "Mace", "重锤", "string",
                    "Mace hold pose.", "重锤的手持动作。"),
                item("mcitem_holdtype_spear", "Spear (idle)", "长矛（静止）", "string",
                    "Spear hold pose while not attacking.", "长矛静止时的手持动作。"),
                item("mcitem_holdtype_spear_use", "Spear (attacking)", "长矛（攻击）", "string",
                    "Spear hold pose while stabbing or charging.", "长矛突刺 / 冲刺时的手持动作。"),
                item("mcitem_holdtype_spear_attack", "Spear (left attack)", "长矛（左键突刺）", "string",
                    "One-shot crossbow firing-family pose for the piercing stab.", "左键穿刺时的一次性弩箭发射动作。"),
                item("mcitem_holdtype_trident", "Trident", "三叉戟", "string",
                    "Trident hold pose for idle and melee.", "三叉戟静止与近战的手持动作。"),
                item("mcitem_holdtype_trident_melee", "Trident (melee)", "三叉戟（近战）", "string",
                    "One-shot melee pose for left attack/mining.", "三叉戟左键攻击 / 挖掘的一次性 melee 动作。"),
                item("mcitem_holdtype_trident_charge", "Trident (charging)", "三叉戟（蓄力）", "string",
                    "Hold pose while charging a throw.", "右键蓄力投掷时的手持动作。"),
                item("mcitem_holdtype_throw", "Throwing", "投掷", "string",
                    "Gesture used when throwing a trident, potion, snowball or similar.",
                    "投掷三叉戟、药水、雪球等物品时的动作。"),
                item("mcitem_holdtype_bucket_use", "Bucket use", "桶右键", "string",
                    "One-shot pose used after a successful fluid pickup, placement, or milking.",
                    "成功取液、放液或接奶之后的一次性右键动作。"),
                item("mcitem_holdtype_fishing_rod_use", "Fishing rod use", "钓鱼竿右键", "string",
                    "One-shot pose used when casting or retrieving the hook.",
                    "抛竿或收竿时的一次性动作。"),
                item("mcitem_holdtype_flint_and_steel_use", "Flint and steel use", "打火石右键", "string",
                    "One-shot pose used after a successful ignition.",
                    "成功点火之后的一次性动作。"),
                item("mcitem_holdtype_shears_use", "Shears use", "剪刀右键", "string",
                    "One-shot pose used after a successful shearing action.",
                    "成功剪切之后的一次性动作。"),
                item("mcitem_holdtype_shield", "Shield (lowered)", "盾牌（放下）", "string",
                    "Hold pose while the shield is lowered.", "盾牌未举起时的手持动作。"),
                item("mcitem_holdtype_shield_block", "Shield (blocking)", "盾牌（格挡）", "string",
                    "Hold pose while actively blocking.", "右键持续格挡时的手持动作。"),
                item("mcitem_holdtype_eat", "Eating and drinking", "进食 / 喝药", "string",
                    "Hold pose while eating food or drinking a potion.", "吃东西 / 喝药水时的手持动作。"),
            },
        },
    },
    client = {
        {
            id = "mcitem_view",
            group = "mcitem",
            label = "Held item view",
            zhLabel = "手持物品视角",
            description = "First-person hand animation switches ported from ItemInHandRenderer.",
            descriptionZH = "从 ItemInHandRenderer 移植过来的第一人称手部动画开关。",
            items = {
                item("mcitem_hand_lower", "Cooldown hand lower", "冷却沉手", "bool",
                    "Minecraft's cooldown-driven hand lower/raise.", "Minecraft 按攻击冷却让手沉下去再抬起来。"),
                item("mcitem_view_bob", "Walk bob", "走路晃动", "number",
                    "Scale for Minecraft's walking view bob on the held item.", "走路时手持物品晃动的幅度倍率。"),
                item("mcitem_view_sway", "Turn lag", "转头滞后", "number",
                    "Scale for Minecraft's turn lag on the held item.", "转头时手持物品滞后的幅度倍率。"),
                item("mcitem_hand_fov_lock", "Lock hand FOV", "手部 FOV 锁定", "bool",
                    "Keep the held item the same on-screen size while the bow zoom shrinks the world FOV.",
                    "拉弓缩小世界 FOV 时，让手里的物品屏幕大小保持不变。"),
                item("mcitem_hand_aspect_lock", "Lock 4:3 hand position", "锁定 4:3 手持位置", "bool",
                    "Keep the 4:3-tuned horizontal hand placement at widescreen and ultrawide aspect ratios.",
                    "在宽屏和超宽屏分辨率下动态保持按 4:3 调好的手持物品水平位置。"),
                item("mcitem_draw_stretch", "Draw stretch", "拉弓拉伸", "bool",
                    "Minecraft's 1 + power*0.2 depth stretch while drawing.", "拉弓 / 装填时 1 + power*0.2 的深度拉伸。"),
                item("mcitem_draw_shake", "Draw shake", "拉弓抖动", "number",
                    "Amplitude multiplier for Minecraft's tiny draw shake. 0 = off.",
                    "Minecraft 拉弓微抖的幅度倍率，0 = 关闭。"),
                item("mcitem_block_outline", "Block outline", "方块描边", "bool",
                    "Draw the MCSWEP block outline while a Minecraft weapon or item is aimed at a block.",
                    "手持 Minecraft 武器 / 物品瞄准方块时显示 MCSWEP 的方块描边。"),
            },
        },
        {
            id = "mcitem_hud_particles",
            group = "mcitem",
            label = "Crosshair and particles",
            zhLabel = "准星与粒子",
            description = "Minecraft crosshair, attack indicator and the client particle budget.",
            descriptionZH = "Minecraft 准星、攻击指示器和客户端粒子预算。",
            items = {
                item("mcitem_crosshair", "Minecraft crosshair", "Minecraft 准星", "bool",
                    "Draw the Minecraft crosshair instead of the GMod one.", "画 Minecraft 准星，而不是 GMod 自带的。"),
                item("mcitem_attack_indicator", "Attack indicator", "攻击指示器", "bool",
                    "Minecraft's attackIndicator option: 0 = off, 1 = crosshair.",
                    "对应 Minecraft 的 attackIndicator 选项：0 = 关闭，1 = 准星下方。"),
                item("mcitem_hud_scale", "HUD scale", "HUD 缩放", "number",
                    "Screen pixels per Minecraft GUI pixel; 0 uses Minecraft's Auto rule.",
                    "每个 Minecraft GUI 像素占几个屏幕像素；0 = Minecraft 的 Auto 规则。"),
                item("mcitem_particle_limit", "Particle limit", "粒子数量上限", "number",
                    "Maximum number of live MCITEM particles; the oldest are dropped first. 0 = unlimited.",
                    "MCITEM 同时存在的粒子数上限，超出时先丢最老的。0 = 不限制。"),
            },
        },
    },
}

local thirdPerson = MCITEM.ThirdPerson
if thirdPerson then
    table.insert(CATEGORIES.server, {
        id = "mcitem_thirdperson_models",
        group = "mcitem",
        label = "Third-person state models",
        zhLabel = "第三人称状态模型",
        description = "Server-authoritative bow/crossbow model switching and Java predicate thresholds.",
        descriptionZH = "服务端权威的弓弩状态模型切换与 Java predicate 阈值。",
        items = {
            item("mcitem_tp_bow_state_models", "Bow state models", "弓状态模型", "bool",
                "Switch bow_pulling_0/1/2_item in third person.", "第三人称切换 bow_pulling_0/1/2_item。"),
            item("mcitem_tp_bow_pull_1_threshold", "Bow stage 1 threshold", "弓阶段 1 阈值", "number",
                "Java 26.2 default is 0.65 use_duration progress.", "Java 26.2 默认是 use_duration 进度 0.65。"),
            item("mcitem_tp_bow_pull_2_threshold", "Bow stage 2 threshold", "弓阶段 2 阈值", "number",
                "Java 26.2 default is 0.9 use_duration progress.", "Java 26.2 默认是 use_duration 进度 0.9。"),
            item("mcitem_tp_crossbow_state_models", "Crossbow state models", "弩状态模型", "bool",
                "Switch loading and charged crossbow models in third person.", "第三人称切换弩装填与已装箭模型。"),
            item("mcitem_tp_crossbow_pull_1_threshold", "Crossbow stage 1 threshold", "弩阶段 1 阈值", "number",
                "Java 26.2 default is 0.58 pull progress.", "Java 26.2 默认是 pull 进度 0.58。"),
            item("mcitem_tp_crossbow_pull_2_threshold", "Crossbow stage 2 threshold", "弩阶段 2 阈值", "number",
                "Java 26.2 default is 1.0 pull progress.", "Java 26.2 默认是 pull 进度 1.0。"),
        },
    })

    local fieldLabels = {}
    for _, field in ipairs(thirdPerson.TransformFields or {}) do
        fieldLabels[field.key] = field
    end

    for profileName, profile in pairs(thirdPerson.Profiles or {}) do
        local entries = {}
        for _, state in ipairs(profile.states or {}) do
            local stateLabel = (profile.stateLabels and profile.stateLabels[state])
                or thirdPerson.StateLabels[state]
                or { state, state }
            for _, field in ipairs(thirdPerson.TransformFields or {}) do
                table.insert(entries, item(
                    thirdPerson.TransformConVarName(profileName, state, field.key),
                    stateLabel[1] .. " - " .. field.label,
                    stateLabel[2] .. " - " .. field.labelZH,
                    "number",
                    "Hot-reloadable third-person transform component.",
                    "可热改、立即生效的第三人称位姿分量。"
                ))
            end
        end
        table.insert(CATEGORIES.client, {
            id = "mcitem_thirdperson_" .. profileName,
            group = "mcitem",
            label = "Third-person: " .. (profile.label or profileName),
            zhLabel = "第三人称：" .. (profile.labelZH or profileName),
            description = "Per-state position, angle and scale for " .. profileName .. ".",
            descriptionZH = (profile.labelZH or profileName) .. "每个动作状态的位置、角度与大小。",
            items = entries,
        })
    end
end

local function register()
    local api = MC and MC.API
    if not api then return false end
    if api.Require and not api.Require(1, "MCITEM") then return false end

    local config = api.Config
    if not config or not isfunction(config.RegisterCategory) then return false end

    for scope, group in pairs(GROUPS) do
        config.RegisterGroup(scope, group)
    end
    for scope, categories in pairs(CATEGORIES) do
        for _, category in ipairs(categories) do
            config.RegisterCategory(scope, category)
        end
    end
    return true
end

MCITEM.RegisterConfigMenu = register

-- 和 `integration/mcswep/sh_registration.lua` 同一套引导：新架构下
-- `MC.API.OnRegister` 会对迟到的订阅者补跑（覆盖"引擎已经加载完"），旧架构 /
-- 引擎后加载时由 `MC.APIAvailable` 覆盖。
if MC and MC.API and MC.API.OnRegister then
    MC.API.OnRegister(register)
else
    hook.Add("MC.APIAvailable", "MCITEM.RegisterConfigMenu", register)
    -- 旧架构没有 OnRegister 的补跑语义，引擎先加载完时只能靠这一发。
    timer.Simple(0, register)
end
-- autorefresh 重跑本文件时引擎生命周期不会再触发一次。
hook.Add("OnReloaded", "MCITEM.RegisterConfigMenuReload", register)
