-- 第三人称手持 / 动作（HoldType）、状态模型与世界模型锚点映射。
--
-- MC 的第一人称是逐帧曲线（cl_item_render.lua 已经逐条移植），第三人称在 Source 里
-- 只有一组玩家动画集可选，所以这一层是**近似**：每件武器的每个状态挑一个 GMod
-- holdtype，攻击 / 投掷再叠一次 `PLAYER_ATTACK1` 手势。
--
-- 全部出成 convar（`mcitem_holdtype_*`）而不是写死：哪个 HL2 动作"看起来对"是纯手感
-- 问题，改 convar 立刻生效，不用改代码重启。想看有哪些可选值：下面的 VALID 表。

MCITEM = MCITEM or {}

-- SetHoldType 认识的全部值。convar 填了表外的字符串就退回该键的默认值，
-- 否则 GMod 会静默套用一个空动画集，玩家看到的是"武器不见了"。
local VALID = {
    normal = true, fist = true, melee = true, melee2 = true, knife = true,
    smg = true, ar2 = true, pistol = true, revolver = true, shotgun = true,
    rpg = true, physgun = true, grenade = true, slam = true, passive = true,
    magic = true, crossbow = true, camera = true, duel = true,
}

MCITEM.HoldTypeValues = VALID

-- key -> { default, 说明 }
local DEFAULTS = {
    -- 剑 / 镐 / 斧 / 铲 / 锄 / 食物 / 药水 / 投掷物静止时自然下垂；
    -- 左键攻击 / 持续挖掘是独立的一次性 melee gesture，不能把静止 pose 也设成撬棍。
    item = "normal",
    item_attack = "melee",

    -- 弓：拿着时手臂下垂，拉弓套左轮。
    bow = "normal",
    bow_draw = "revolver",
    bow_attack = "melee",

    -- 弩：拿着时手臂下垂，装填套霰弹枪，上好弦之后是左轮。
    crossbow = "normal",
    crossbow_load = "shotgun",
    crossbow_charged = "revolver",
    crossbow_attack = "melee",

    -- 用户指定重锤与三叉戟都沿用 GMod melee 的持握 / 攻击动画。
    mace = "melee",

    -- 长矛：静止下垂，右键冲刺 / 左键突刺都套 HL2 弩；左键单独登记，
    -- 这样动作和第三人称锚点可以分别调。
    spear = "normal",
    spear_use = "crossbow",
    spear_attack = "crossbow",

    -- 三叉戟：静止 / 近战 / 蓄力都是 melee，真正投出的瞬间走 throw。
    trident = "melee",
    trident_melee = "melee",
    trident_charge = "melee",

    -- 投掷手势：三叉戟投掷、喷溅 / 滞留药水、雪球 / 鸡蛋 / 末影珍珠等。
    throw = "grenade",

    -- 桶取液 / 放液的短右键动作集中登记，避免各桶 SWEP 散写 holdtype。
    bucket_use = "melee",
    fishing_rod_use = "melee",
    flint_and_steel_use = "melee",
    shears_use = "melee",
    shield = "normal",
    shield_block = "slam",

    -- 进食 / 喝药：把物品举到脸前的那一套（2026-08-13 用户确认沿用）。
    eat = "camera",
}

MCITEM.HoldTypeConVars = MCITEM.HoldTypeConVars or {}

for key, default in pairs(DEFAULTS) do
    if not MCITEM.HoldTypeConVars[key] then
        MCITEM.HoldTypeConVars[key] = CreateConVar(
            "mcitem_holdtype_" .. key, default,
            FCVAR_ARCHIVE + FCVAR_REPLICATED,
            "Third-person GMod hold type used for the MCITEM '" .. key .. "' state."
        )
    end
end

-- 旧版把普通物品的静止值默认存成了 melee。FCVAR_ARCHIVE 会继续加载旧值，
-- 单改 CreateConVar 默认值无法修正用户机器；只迁移这一版的旧默认，不覆盖手调值。
if SERVER then
    local IDLE_MIGRATION_CVAR = "mcitem_holdtype_item_idle_migration"
    local idleMigration = CreateConVar(
        IDLE_MIGRATION_CVAR, "0", FCVAR_ARCHIVE,
        "MCITEM internal version for the ordinary-item idle holdtype migration."
    )
    if idleMigration:GetInt() < 1 then
        local itemHoldType = MCITEM.HoldTypeConVars.item
        if itemHoldType and string.lower(string.Trim(itemHoldType:GetString() or "")) == "melee" then
            RunConsoleCommand("mcitem_holdtype_item", "normal")
        end
        RunConsoleCommand(IDLE_MIGRATION_CVAR, "1")
    end

    -- bow_attack / crossbow_attack used their idle/fire families in the previous
    -- revision. Migrate only those exact legacy defaults so user-tuned values are
    -- preserved while existing installs receive the new melee attack animation.
    local RANGED_ATTACK_MIGRATION_CVAR = "mcitem_holdtype_ranged_attack_migration"
    local rangedAttackMigration = CreateConVar(
        RANGED_ATTACK_MIGRATION_CVAR, "0", FCVAR_ARCHIVE,
        "MCITEM internal version for bow/crossbow left-attack holdtype migration."
    )
    if rangedAttackMigration:GetInt() < 1 then
        local legacyDefaults = {
            bow_attack = "normal",
            crossbow_attack = "crossbow",
        }
        for key, legacyDefault in pairs(legacyDefaults) do
            local cvar = MCITEM.HoldTypeConVars[key]
            if cvar and string.lower(string.Trim(cvar:GetString() or "")) == legacyDefault then
                RunConsoleCommand("mcitem_holdtype_" .. key, "melee")
            end
        end
        RunConsoleCommand(RANGED_ATTACK_MIGRATION_CVAR, "1")
    end
end

function MCITEM.HoldType(key)
    local cvar = MCITEM.HoldTypeConVars[key]
    if not cvar then return DEFAULTS[key] or DEFAULTS.item end
    local value = string.lower(string.Trim(cvar:GetString() or ""))
    if VALID[value] then return value end
    return DEFAULTS[key] or DEFAULTS.item
end

-- 投掷 / 开火手势的持续时间（秒）。手势结束后回到该武器的静止 holdtype。
MCITEM.GestureSeconds = 0.6

--------------------------------------------------------------------------------
-- 第三人称状态模型与七轴锚点
--------------------------------------------------------------------------------
--
-- 第一人称的 mcitem_fp_* / mcitem_use_* 在 cl_view.lua 里，第三人称绝不复用它们：
-- 两套渲染的骨骼原点、模型尺度和 MC display 坐标完全不同。这里的 convar 命名是：
--
--   mcitem_tp_<weapon>_<state>_x/y/z/pitch/yaw/roll/scale
--
-- x/y/z 分别沿玩家右手骨骼的 Forward/Right/Up；pitch/yaw/roll 分别绕
-- Right/Up/Forward；scale 是该状态的世界模型倍率。每次 DrawWorldModel 都实时读取，
-- 控制台或设置页热改立即生效。

local TP = MCITEM.ThirdPerson or {}
MCITEM.ThirdPerson = TP

-- 这里只放 id，显示文字在 mc_item 的词典 data_static/mc/i18n/mcitem/thirdperson/：
-- field.<key>、profile.<name>、state.<state>。profile 的 stateLabels 给某个状态
-- 换一个更具体的状态文字 id（食物的 use 显示成 consume“食用”）。
TP.TransformFields = {
    { key = "x", default = "0" },
    { key = "y", default = "0" },
    { key = "z", default = "0" },
    { key = "pitch", default = "0" },
    { key = "yaw", default = "0" },
    { key = "roll", default = "0" },
    { key = "scale", default = "1" },
}

local function transform(x, y, z, pitch, yaw, roll, scale)
    return {
        x = tostring(x or 0), y = tostring(y or 0), z = tostring(z or 0),
        pitch = tostring(pitch or 0), yaw = tostring(yaw or 0), roll = tostring(roll or 0),
        scale = tostring(scale or 1),
    }
end

-- Heart 实机调出的第三人称默认锚点（2026-08-13）。同组状态复制同一组默认值，
-- 但仍注册成独立 ConVar，后续可以按状态继续单独微调。
local BOW_IDLE = transform(0, 6, -9, 0, 0, 180, 1.3)
local BOW_DRAW = transform(0, 8, -5, 6, -25, 220, 1.3)
local CROSSBOW_IDLE = transform(0, 5, -9, 10, -25, 190, 1.3)
local CROSSBOW_LOAD = transform(0, 0, -5, -270, 0, 200, 1.3)
local CROSSBOW_CHARGED = transform(0, 9, -6.5, 90, 10, 195, 1.3)
local SPEAR_IDLE = transform(0, 7, -1, -5, 150, 50, 2)
local SPEAR_ACTIVE = transform(7, -3, -10, 15, -35, 205, 2)
local TRIDENT_IDLE = transform(0, 15, -20, 0, 0, -30, 1.3)
local TRIDENT_CHARGE = transform(20, 7, -7, 90, -15, 0, 1.3)
local SWORD_HELD = transform(2, 7, 3, -15, -35, 48, 1.3)
local TOOL_HELD = transform(1.5, 5, -1, -10, -200, 50, 1.3)
local MACE_HELD = transform(-0.8, 2, -2, 5, 2, 0, 1.4)
local ITEM_HELD = transform(1, 5, -5, 0, -20, 0, 0.6)
local CONSUME_HELD = transform(-3, 5, -9, 30, 60, 20, 0.6)
local FLINT_AND_STEEL_HELD = transform(1, 5, -4, 0, -20, -45, 0.6)
local SHIELD_IDLE = transform(2, 12, -4, 180, 30, 5, 1.3)
local SHIELD_BLOCK = transform(0, 0, -6, 165, -90, 170, 1.3)

TP.Profiles = {
    bow = {
        states = { "idle", "attack", "draw_0", "draw_1", "draw_2" },
        defaults = {
            idle = BOW_IDLE,
            draw_0 = BOW_DRAW,
            draw_1 = BOW_DRAW,
            draw_2 = BOW_DRAW,
        },
        models = {
            idle = "models/mcgm/bow_item/bow_item.mdl",
            attack = "models/mcgm/bow_item/bow_item.mdl",
            draw_0 = "models/mcgm/bow_pulling_0_item/bow_pulling_0_item.mdl",
            draw_1 = "models/mcgm/bow_pulling_1_item/bow_pulling_1_item.mdl",
            draw_2 = "models/mcgm/bow_pulling_2_item/bow_pulling_2_item.mdl",
        },
    },
    crossbow = {
        states = {
            "idle", "attack", "load_0", "load_1", "load_2",
            "charged_arrow", "charged_firework",
        },
        defaults = {
            idle = CROSSBOW_IDLE,
            load_0 = CROSSBOW_LOAD,
            load_1 = CROSSBOW_LOAD,
            load_2 = CROSSBOW_LOAD,
            charged_arrow = CROSSBOW_CHARGED,
            charged_firework = CROSSBOW_CHARGED,
        },
        models = {
            idle = "models/mcgm/crossbow/crossbow.mdl",
            attack = "models/mcgm/crossbow/crossbow.mdl",
            load_0 = "models/mcgm/crossbow_pulling_0/crossbow_pulling_0.mdl",
            load_1 = "models/mcgm/crossbow_pulling_1/crossbow_pulling_1.mdl",
            load_2 = "models/mcgm/crossbow_pulling_2/crossbow_pulling_2.mdl",
            charged_arrow = "models/mcgm/crossbow_arrow/crossbow_arrow.mdl",
            charged_firework = "models/mcgm/crossbow_firework/crossbow_firework.mdl",
        },
    },
    spear = {
        states = { "idle", "attack", "use" },
        defaults = { idle = SPEAR_IDLE, attack = SPEAR_ACTIVE, use = SPEAR_ACTIVE },
    },
    trident = {
        states = { "idle", "melee", "charge", "throw" },
        defaults = {
            idle = TRIDENT_IDLE,
            melee = TRIDENT_IDLE,
            charge = TRIDENT_CHARGE,
        },
    },
    sword = {
        states = { "idle", "attack" },
        defaults = { idle = SWORD_HELD, attack = SWORD_HELD },
    },
    axe = {
        states = { "idle", "attack" },
        defaults = { idle = TOOL_HELD, attack = TOOL_HELD },
    },
    pickaxe = {
        states = { "idle", "attack" },
        defaults = { idle = TOOL_HELD, attack = TOOL_HELD },
    },
    shovel = {
        states = { "idle", "attack" },
        defaults = { idle = TOOL_HELD, attack = TOOL_HELD },
    },
    hoe = {
        states = { "idle", "attack" },
        defaults = { idle = TOOL_HELD, attack = TOOL_HELD },
    },
    mace = {
        states = { "idle", "attack" },
        defaults = { idle = MACE_HELD, attack = MACE_HELD },
    },
    food = {
        states = { "idle", "attack", "use" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD, use = CONSUME_HELD },
        stateLabels = { use = "consume" },
    },
    potion = {
        states = { "idle", "attack", "use", "throw" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD, use = CONSUME_HELD },
        stateLabels = { use = "drink" },
    },
    totem_of_undying = {
        states = { "idle", "attack" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD },
    },
    fishing_rod = {
        states = { "idle", "attack", "use" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD, use = ITEM_HELD },
        stateLabels = { use = "cast" },
    },
    flint_and_steel = {
        states = { "idle", "attack", "use" },
        defaults = {
            idle = FLINT_AND_STEEL_HELD,
            attack = FLINT_AND_STEEL_HELD,
            use = FLINT_AND_STEEL_HELD,
        },
        stateLabels = { use = "ignite" },
    },
    name_tag = {
        states = { "idle", "attack" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD },
    },
    shears = {
        states = { "idle", "attack", "use" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD, use = ITEM_HELD },
        stateLabels = { use = "shear" },
    },
    shield = {
        states = { "idle", "attack", "block" },
        defaults = { idle = SHIELD_IDLE, attack = SHIELD_IDLE, block = SHIELD_BLOCK },
    },
    throwable = {
        states = { "idle", "attack", "throw" },
        defaults = { idle = ITEM_HELD, attack = ITEM_HELD, throw = ITEM_HELD },
    },
}


-- 手势键既决定 holdtype，也决定该短动作使用哪一组第三人称锚点。
TP.GestureStates = {
    shield = { item_attack = "attack" },
    totem_of_undying = { item_attack = "attack" },
    fishing_rod = { item_attack = "attack", fishing_rod_use = "use" },
    flint_and_steel = { item_attack = "attack", flint_and_steel_use = "use" },
    name_tag = { item_attack = "attack" },
    shears = { item_attack = "attack", shears_use = "use" },
    -- 弓松弦 / 弩射出没有额外的一次性 gesture，直接回到各自基础 idle 状态。
    bow = { bow_attack = "attack" },
    crossbow = { crossbow_attack = "attack" },
    spear = { spear_attack = "attack" },
    trident = { trident_melee = "melee", throw = "throw" },
    sword = { item_attack = "attack" },
    axe = { item_attack = "attack" },
    pickaxe = { item_attack = "attack" },
    shovel = { item_attack = "attack" },
    hoe = { item_attack = "attack" },
    mace = { item_attack = "attack" },
    food = { item_attack = "attack" },
    potion = { item_attack = "attack", throw = "throw" },
    throwable = { item_attack = "attack", throw = "throw" },
}

-- 普通物品没有单独的 profile/state 模型，但攻击动作仍必须有独立 gesture 键；
-- `item` 只决定静止持握，`item_attack` 才决定剑 / 工具 / 食物等左键挥动。
TP.DefaultAttackGesture = "item_attack"

TP.ModelControls = {
    bow = {
        enabled = { name = "mcitem_tp_bow_state_models", default = "1" },
        threshold1 = { name = "mcitem_tp_bow_pull_1_threshold", default = "0.65" },
        threshold2 = { name = "mcitem_tp_bow_pull_2_threshold", default = "0.9" },
    },
    crossbow = {
        enabled = { name = "mcitem_tp_crossbow_state_models", default = "1" },
        threshold1 = { name = "mcitem_tp_crossbow_pull_1_threshold", default = "0.58" },
        threshold2 = { name = "mcitem_tp_crossbow_pull_2_threshold", default = "1" },
    },
}

TP.StateSync = {
    block = 15,
    idle = 0,
    attack = 1,
    draw_0 = 2,
    draw_1 = 3,
    draw_2 = 4,
    load_0 = 6,
    load_1 = 7,
    load_2 = 8,
    charged_arrow = 9,
    charged_firework = 10,
    use = 11,
    melee = 12,
    charge = 13,
    throw = 14,
}
TP.StateSyncReverse = {}
for state, code in pairs(TP.StateSync) do TP.StateSyncReverse[code] = state end

TP.TransformConVars = TP.TransformConVars or {}
TP.ModelConVars = TP.ModelConVars or {}

function TP.TransformConVarName(profile, state, field)
    return "mcitem_tp_" .. profile .. "_" .. state .. "_" .. field
end

if CLIENT then
    for profileName, profile in pairs(TP.Profiles) do
        TP.TransformConVars[profileName] = TP.TransformConVars[profileName] or {}
        for _, state in ipairs(profile.states) do
            local stateSet = TP.TransformConVars[profileName][state] or {}
            TP.TransformConVars[profileName][state] = stateSet
            for _, field in ipairs(TP.TransformFields) do
                if not stateSet[field.key] then
                    local stateDefaults = profile.defaults and profile.defaults[state]
                    local default = stateDefaults and stateDefaults[field.key] or field.default
                    stateSet[field.key] = CreateClientConVar(
                        TP.TransformConVarName(profileName, state, field.key),
                        default, true, false,
                        "Hot-reloadable third-person " .. field.key .. " offset for "
                            .. profileName .. " / " .. state .. "."
                    )
                end
            end
        end
    end

    -- These ConVars existed before the tuned defaults were known, so archived
    -- zero/one values would otherwise mask the new defaults forever. Migrate only
    -- fields still equal to the old generic default; any non-default hand tuning
    -- is left untouched.
    local TUNED_DEFAULTS_MIGRATION = "mcitem_tp_tuned_defaults_migration"
    local tunedDefaultsMigration = CreateClientConVar(
        TUNED_DEFAULTS_MIGRATION, "0", true, false,
        "MCITEM internal version for tuned third-person transform defaults."
    )
    if tunedDefaultsMigration:GetInt() < 2 then
        for profileName, profile in pairs(TP.Profiles) do
            for state, defaults in pairs(profile.defaults or {}) do
                local stateSet = TP.TransformConVars[profileName]
                    and TP.TransformConVars[profileName][state]
                for _, field in ipairs(TP.TransformFields) do
                    local cvar = stateSet and stateSet[field.key]
                    local oldDefault = tonumber(field.default)
                    local tunedDefault = tonumber(defaults[field.key])
                    if cvar and oldDefault and tunedDefault
                    and math.abs(cvar:GetFloat() - oldDefault) < 0.0001
                    and math.abs(tunedDefault - oldDefault) >= 0.0001 then
                        RunConsoleCommand(cvar:GetName(), defaults[field.key])
                    end
                end
            end
        end
        RunConsoleCommand(TUNED_DEFAULTS_MIGRATION, "2")
    end

end

-- 阈值 / 开关影响的是“当前处于哪个网络状态”，所以必须是服务端权威的 replicated
-- ConVar；不能做成每个客户端各算各的，否则同一把弓在不同玩家眼里会处于不同阶段。
for profileName, controls in pairs(TP.ModelControls) do
    local created = TP.ModelConVars[profileName] or {}
    TP.ModelConVars[profileName] = created
    for key, definition in pairs(controls) do
        if not created[key] then
            local description = "Server-authoritative third-person state-model control for " .. profileName .. "."
            if SERVER then
                created[key] = CreateConVar(
                    definition.name, definition.default,
                    FCVAR_ARCHIVE + FCVAR_REPLICATED, description
                )
            else
                -- The server owns the value; the client mirror is still read live by the
                -- renderer when the replicated ConVar update arrives.
                created[key] = CreateClientConVar(
                    definition.name, definition.default, true, false, description
                )
            end
        end
    end
end

local function modelControlValue(profile, key)
    local controls = TP.ModelControls[profile]
    local definition = controls and controls[key]
    if not definition then return nil end
    local created = TP.ModelConVars[profile]
    local cvar = created and created[key]
    if cvar then return cvar:GetFloat() end
    return tonumber(definition.default)
end

function TP.GetTransform(profile, state)
    local profileDefinition = TP.Profiles[profile]
    if not profileDefinition then return 0, 0, 0, 0, 0, 0, 1 end
    if not table.HasValue(profileDefinition.states, state) then state = "idle" end

    local stateSet = TP.TransformConVars[profile] and TP.TransformConVars[profile][state]
    if not stateSet then return 0, 0, 0, 0, 0, 0, 1 end
    return stateSet.x:GetFloat(), stateSet.y:GetFloat(), stateSet.z:GetFloat(),
        stateSet.pitch:GetFloat(), stateSet.yaw:GetFloat(), stateSet.roll:GetFloat(),
        math.max(stateSet.scale:GetFloat(), 0.01)
end

function TP.GestureState(profile, gesture)
    local mapping = TP.GestureStates[profile]
    return mapping and mapping[gesture] or nil
end

function TP.BowDrawState(progress)
    local first = math.Clamp(modelControlValue("bow", "threshold1") or 0.65, 0, 1)
    local second = math.Clamp(modelControlValue("bow", "threshold2") or 0.9, first, 1)
    progress = math.max(tonumber(progress) or 0, 0)
    if progress >= second then return "draw_2" end
    if progress >= first then return "draw_1" end
    return "draw_0"
end

function TP.CrossbowLoadState(progress)
    local first = math.Clamp(modelControlValue("crossbow", "threshold1") or 0.58, 0, 1)
    local second = math.Clamp(modelControlValue("crossbow", "threshold2") or 1, first, 1)
    progress = math.Clamp(tonumber(progress) or 0, 0, 1)
    if progress >= second then return "load_2" end
    if progress >= first then return "load_1" end
    return "load_0"
end

function TP.ResolveModel(profile, state, fallback)
    local definition = TP.Profiles[profile]
    if not definition or not definition.models then return fallback end
    local enabled = modelControlValue(profile, "enabled")
    if enabled ~= nil and enabled <= 0 then return fallback end
    return definition.models[state] or definition.models.idle or fallback
end
