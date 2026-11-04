-- 把 MCITEM 的 convar 挂进 MineMod 的游戏内设置面板（"设置"那一栏）。
--
-- 面板数据走 `MC.API.Config.RegisterGroup / RegisterCategory`（见
-- `lua/mc/api/sh_api.lua`），注册两次同一个 id 是幂等的。这里只写 id：标签、说明
-- 的翻译 key 由 id 推导（config.group.<id>、config.category.<id>.label|.description、
-- config.setting.<convar>.label|.help），译文在本 addon 的
-- data_static/mc/i18n/config/ 下；第三人称位姿的文字在 data_static/mc/i18n/mcitem/thirdperson/。

MCITEM = MCITEM or {}

if MCITEM.ConfigMenuInstalled then return end
MCITEM.ConfigMenuInstalled = true

local function item(name, kind, extra)
    local entry = {
        name = name,
        kind = kind or "number",
    }
    for key, value in pairs(extra or {}) do entry[key] = value end
    return entry
end

local GROUPS = {
    client = { id = "mcitem" },
    server = { id = "mcitem" },
}

local CATEGORIES = {
    server = {
        {
            id = "mcitem_combat",
            group = "mcitem",
            items = {
                item("mcitem_damage_scale", "number"),
                item("mcitem_knockback_scale", "number"),
                item("mcitem_attack_range", "number", { unit = "blocks" }),
                item("mcitem_fov_effect_scale", "number"),
            },
        },
        {
            id = "mcitem_holdtypes",
            group = "mcitem",
            items = {
                item("mcitem_holdtype_item", "string"),
                item("mcitem_holdtype_item_attack", "string"),
                item("mcitem_holdtype_bow", "string"),
                item("mcitem_holdtype_bow_draw", "string"),
                item("mcitem_holdtype_bow_attack", "string"),
                item("mcitem_holdtype_crossbow", "string"),
                item("mcitem_holdtype_crossbow_load", "string"),
                item("mcitem_holdtype_crossbow_charged", "string"),
                item("mcitem_holdtype_crossbow_attack", "string"),
                item("mcitem_holdtype_mace", "string"),
                item("mcitem_holdtype_spear", "string"),
                item("mcitem_holdtype_spear_use", "string"),
                item("mcitem_holdtype_spear_attack", "string"),
                item("mcitem_holdtype_trident", "string"),
                item("mcitem_holdtype_trident_melee", "string"),
                item("mcitem_holdtype_trident_charge", "string"),
                item("mcitem_holdtype_throw", "string"),
                item("mcitem_holdtype_bucket_use", "string"),
                item("mcitem_holdtype_fishing_rod_use", "string"),
                item("mcitem_holdtype_flint_and_steel_use", "string"),
                item("mcitem_holdtype_shears_use", "string"),
                item("mcitem_holdtype_shield", "string"),
                item("mcitem_holdtype_shield_block", "string"),
                item("mcitem_holdtype_eat", "string"),
            },
        },
    },
    client = {
        {
            id = "mcitem_view",
            group = "mcitem",
            items = {
                item("mcitem_hand_lower", "bool"),
                item("mcitem_view_bob", "number"),
                item("mcitem_view_sway", "number"),
                item("mcitem_hand_fov_lock", "bool"),
                item("mcitem_hand_aspect_lock", "bool"),
                item("mcitem_draw_stretch", "bool"),
                item("mcitem_draw_shake", "number"),
                item("mcitem_block_outline", "bool"),
            },
        },
        {
            id = "mcitem_hud_particles",
            group = "mcitem",
            items = {
                item("mcitem_crosshair", "bool"),
                item("mcitem_attack_indicator", "bool"),
                item("mcitem_hud_scale", "number"),
                item("mcitem_particle_limit", "number"),
            },
        },
    },
}

local thirdPerson = MCITEM.ThirdPerson
if thirdPerson then
    table.insert(CATEGORIES.server, {
        id = "mcitem_thirdperson_models",
        group = "mcitem",
        items = {
            item("mcitem_tp_bow_state_models", "bool"),
            item("mcitem_tp_bow_pull_1_threshold", "number"),
            item("mcitem_tp_bow_pull_2_threshold", "number"),
            item("mcitem_tp_crossbow_state_models", "bool"),
            item("mcitem_tp_crossbow_pull_1_threshold", "number"),
            item("mcitem_tp_crossbow_pull_2_threshold", "number"),
        },
    })

    -- 位姿分量的标签是"状态 - 分量"模板，状态与分量各自是一条译文。
    local function textSpec(key) return { key = "mcitem.thirdperson." .. key } end

    for profileName, profile in pairs(thirdPerson.Profiles or {}) do
        local entries = {}
        local profileText = textSpec("profile." .. profileName)
        for _, state in ipairs(profile.states or {}) do
            local stateText = textSpec("state." .. ((profile.stateLabels and profile.stateLabels[state]) or state))
            for _, field in ipairs(thirdPerson.TransformFields or {}) do
                table.insert(entries, item(
                    thirdPerson.TransformConVarName(profileName, state, field.key),
                    "number",
                    {
                        labelKey = "mcitem.thirdperson.transform_label",
                        labelVars = { state = stateText, field = textSpec("field." .. field.key) },
                        helpKey = "mcitem.thirdperson.transform_help",
                    }
                ))
            end
        end
        table.insert(CATEGORIES.client, {
            id = "mcitem_thirdperson_" .. profileName,
            group = "mcitem",
            labelKey = "mcitem.thirdperson.category_label",
            labelVars = { profile = profileText },
            descriptionKey = "mcitem.thirdperson.category_description",
            descriptionVars = { profile = profileText },
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
