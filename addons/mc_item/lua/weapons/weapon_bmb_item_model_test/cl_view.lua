-- 第一人称 / 世界模型渲染 + MC 准星 HUD（客户端）。
--
-- 手持锚点（fp_x/y/z、fp_yaw/pitch/roll、fp_mc_scale）是 Source 侧手调出来的，
-- **不是** MC 的 0.56/-0.52/-0.72：MC 用 OpenGL 的 -Z 视线方向和自己的投影单位，
-- 直接照抄会歪。挥动 / 手部升降 / 走路晃动全部走 MCITEM 的原版公式。

local fpScale = CreateClientConVar("bmb_item_test_fp_scale", "0.5", true, false)
local fpX = CreateClientConVar("bmb_item_test_fp_x", "19.5", true, false)
local fpY = CreateClientConVar("bmb_item_test_fp_y", "10.3", true, false)
local fpZ = CreateClientConVar("bmb_item_test_fp_z", "-7", true, false)
local fpPitch = CreateClientConVar("bmb_item_test_fp_pitch", "-3", true, false)
local fpYaw = CreateClientConVar("bmb_item_test_fp_yaw", "110", true, false)
local fpRoll = CreateClientConVar("bmb_item_test_fp_roll", "20", true, false)
local fpFov = CreateClientConVar("bmb_item_test_fp_fov", "80", true, false)
local fpMinecraft = CreateClientConVar("bmb_item_test_fp_minecraft", "1", true, false)
local fpMinecraftScale = CreateClientConVar("bmb_item_test_fp_mc_scale", "0.68", true, false)
local fpMinecraftFov = CreateClientConVar("bmb_item_test_fp_mc_fov", "70", true, false)
-- >= 0 时把挥动冻结在这个相位上，方便对着看某一帧（-1 = 正常播放）。
local fpMinecraftPreview = CreateClientConVar("bmb_item_test_fp_mc_preview", "-1", true, false)
local fpMinecraftPosX = CreateClientConVar("bmb_item_test_fp_mc_pos_x", "1", true, false)
local fpMinecraftPosY = CreateClientConVar("bmb_item_test_fp_mc_pos_y", "1", true, false)
local fpMinecraftPosZ = CreateClientConVar("bmb_item_test_fp_mc_pos_z", "1", true, false)
local fpMinecraftRotPitch = CreateClientConVar("bmb_item_test_fp_mc_rot_pitch", "1", true, false)
local fpMinecraftRotYaw = CreateClientConVar("bmb_item_test_fp_mc_rot_yaw", "1", true, false)
local fpMinecraftRotRoll = CreateClientConVar("bmb_item_test_fp_mc_rot_roll", "1", true, false)
local fpMinecraftPivot = CreateClientConVar("bmb_item_test_fp_mc_pivot", "1", true, false)

-- MCITEM 通用观感开关（不属于某一件物品，所以用 mcitem_ 前缀）。
local cvHandLower = CreateClientConVar("mcitem_hand_lower", "1", true, false,
    "Minecraft's cooldown-driven hand lower/raise (ItemInHandRenderer.mainHandHeight). 0 = always raised.")
local cvViewBob = CreateClientConVar("mcitem_view_bob", "1", true, false,
    "Scale for Minecraft's walking view bob on the held item (GameRenderer.bobView). 0 = off.")
local cvViewSway = CreateClientConVar("mcitem_view_sway", "1", true, false,
    "Scale for Minecraft's turn lag on the held item (xBob/yBob). 0 = off.")
local cvDebug = CreateClientConVar("mcitem_debug", "0", false, false,
    "Show the measured MC tick rate / swing timings next to the Minecraft reference values.")
-- MC 用写死 70° 的 hudFov 画手（Camera.calculateHudFov），所以拉弓那 0.85 只缩世界、
-- 不缩手里的弓。见 Render.LockHandFov。
local cvHandFovLock = CreateClientConVar("mcitem_hand_fov_lock", "1", true, false,
    "Keep the held item the same on-screen size while the bow zoom shrinks the world FOV (Minecraft renders the hand at a fixed 70 degrees).")
local cvHandAspectLock = CreateClientConVar("mcitem_hand_aspect_lock", "1", true, false,
    "Keep the 4:3-tuned held-item horizontal position at widescreen resolutions. 1 = dynamically compensate from the current viewport aspect ratio.")
-- ItemInHandRenderer 的 `poseStack.scale(1, 1, 1 + power * 0.2)`（弓 / 弩 / 三叉戟都有）。
local cvDrawStretch = CreateClientConVar("mcitem_draw_stretch", "1", true, false,
    "Minecraft's 1 + power*0.2 depth stretch while drawing a bow / loading a crossbow / charging a trident. 0 = off.")
-- >= 0 时把**使用姿势**冻结在这个 tick 上（和 fp_mc_preview 冻结挥动是一回事），
-- 用来逐帧看长矛举起来那 15 tick 和三叉戟的蓄力姿势。
local cvUsePreview = CreateClientConVar("mcitem_use_preview", "-1", true, false,
    "Freeze the use/charge animation at this many MC ticks (-1 = play normally).")

include("mcitem/cl_item_render.lua")
include("mcitem/cl_crosshair.lua")

--------------------------------------------------------------------------------
-- 逐武器手感微调 convar
--------------------------------------------------------------------------------
--
-- 上面那组 `bmb_item_test_fp_*` 是**对着钻石剑**调出来的，剑 / 镐 / 斧这类
-- item/generated 挤出件共用一个几何（一格见方的薄片）所以都对得上。弓、弩、三叉戟、
-- 长矛不是：弩的 display 旋转是 (-90, 0, -55)、三叉戟是真正的 3D 模型且长轴在模型 +Z，
-- 几何中心和剑差得远，套同一个锚点必然歪。
--
-- 每件武器**四组**增量 convar，全部叠在共享锚点之上：
--   mcitem_fp_<w>_x/_y/_z/_pitch/_yaw/_roll/_scale   静止手持锚点
--   mcitem_use_<w>_x/_y/_z/_pitch/_yaw/_roll         只在蓄力 / 装填姿势期间额外叠加
--   mcitem_charged_<w>_x/_y/_z/_pitch/_yaw/_roll     只在"已上弦"这类静止特殊态额外叠加
--   mcitem_swing_<w>_pos_x/_pos_y/_pos_z/_rot_pitch/_rot_yaw/_rot_roll
--                                                    左键挥动各分量的幅度倍率
-- 武器侧只要设 `SWEP.MCAnchorName`。调好之后把值抄回下面的默认值表即可。
--
-- ⚠ 这些 convar 必须**在加载时就全部建好**：以前是第一次画到那件武器才懒建，结果
-- 拿着三叉戟时 `mcitem_fp_bow_x` 根本不存在，控制台补全里也搜不到（"弓和弩的 convar
-- 我都没看到"）。所以下面按名字表一次性注册。

local ANCHOR_FIELDS = {
    { key = "x", default = "0" },
    { key = "y", default = "0" },
    { key = "z", default = "0" },
    { key = "pitch", default = "0" },
    { key = "yaw", default = "0" },
    { key = "roll", default = "0" },
    { key = "scale", default = "1" },
}

local USE_FIELDS = { "x", "y", "z", "pitch", "yaw", "roll" }
local SWING_FIELDS = {
    { key = "posX", suffix = "pos_x" },
    { key = "posY", suffix = "pos_y" },
    { key = "posZ", suffix = "pos_z" },
    { key = "rotPitch", suffix = "rot_pitch" },
    { key = "rotYaw", suffix = "rot_yaw" },
    { key = "rotRoll", suffix = "rot_roll" },
}

-- 实机调出来的默认值（Heart，2026-08-11/12）。写在这里，玩家不用每次再设 convar。
local ANCHOR_DEFAULTS = {
    bow = { x = "-1", pitch = "5", yaw = "-5" },
    crossbow = { x = "-1", y = "0.6", pitch = "5", yaw = "-100", roll = "-244" },
    trident = { x = "-2", y = "19.3", z = "-57", scale = "1.5" },
    spear = { x = "2", z = "-0.7", pitch = "17", yaw = "-4", roll = "-20", scale = "1.3" },
    fishing_rod = { x = "0", y = "1", z = "1", pitch = "0", yaw = "-10", roll = "5", scale = "1" },
    shield = { x = "-10", y = "16", z = "-20", pitch = "190", yaw = "-15", roll = "-185", scale = "1.5" },
}

-- 实机调出来的默认值（Heart，2026-08-11/12/13）。写在这里，玩家不用每次再设 convar。
local USE_DEFAULTS = {
    bow = { x = "-3", y = "1", pitch = "-5" },
    crossbow = { x = "-2", y = "-2", pitch = "-5" },
    -- 三叉戟的后举（2026-08-13 实测）。draw 拆出去之后才调得动，见 DRAW_DEFAULTS。
    trident = { x = "-15", y = "3", z = "58", pitch = "-12", yaw = "-12", roll = "1" },
    fishing_rod = { x = "0", y = "1", z = "1", pitch = "0", yaw = "-10", roll = "5" },
    shield = { x = "-2", y = "7", z = "2", pitch = "-8", yaw = "0", roll = "20" },
    -- 举到嘴边的位置（2026-08-13 实测）。食物和药水只差一个 yaw。
    food = { x = "-9", y = "3", pitch = "10", yaw = "-5", roll = "3" },
    potion = { x = "-9", y = "3", pitch = "10", yaw = "-10", roll = "3" },
}

-- 已上弦的弩：`mcitem_charged_crossbow_*`。它和装填姿势是**两个**状态（源码里一个走
-- 装填分支、一个走 swingArm 之后的静止偏移），模型还从 `crossbow` 换成 `crossbow_arrow`，
-- 共用一组 convar 必然对不上。
local CHARGED_DEFAULTS = {
    crossbow = { x = "-2", y = "1", pitch = "-2", roll = "9" },
}

local SWING_DEFAULTS = {}

-- 使用姿势里"随蓄力**后拉**"那一段位移的倍率。MC 原值：弓 / 弩 0.04 格、三叉戟 0.2 格。
-- 三叉戟按实测放大到 3 倍才看得出后举（0.2 格在这套锚点下只有几个 Source 单位）。
-- ⚠ 它**不再**影响 `1 + power*0.2` 的深度拉伸，那个归 STRETCH_DEFAULTS —— 两件事以前
-- 是同一个 convar，调大 draw 会把模型沿深度轴拽长（"三叉戟被拉扁了"）。
local DRAW_DEFAULTS = {
    trident = "3",
    shield = "1",
}
-- 深度拉伸倍率，全部保持源码的 1（0 = 完全不形变）。
local STRETCH_DEFAULTS = {
    shield = "1",
}

local anchorConVars = {}
local useConVars = {}
local chargedConVars = {}
local swingConVars = {}
local drawConVars = {}
local stretchConVars = {}

local function anchorConVarSet(name)
    local existing = anchorConVars[name]
    if existing then return existing end

    local defaults = ANCHOR_DEFAULTS[name] or {}
    local created = {}
    for _, field in ipairs(ANCHOR_FIELDS) do
        created[field.key] = CreateClientConVar(
            "mcitem_fp_" .. name .. "_" .. field.key,
            defaults[field.key] or field.default, true, false,
            "Per-weapon offset added on top of the shared bmb_item_test_fp_* hand anchor."
        )
    end

    anchorConVars[name] = created
    return created
end

local function offsetConVarSet(store, prefix, defaultsByName, name, help)
    local existing = store[name]
    if existing then return existing end

    local defaults = defaultsByName[name] or {}
    local created = {}
    for _, key in ipairs(USE_FIELDS) do
        created[key] = CreateClientConVar(
            prefix .. name .. "_" .. key, defaults[key] or "0", true, false, help
        )
    end

    store[name] = created
    return created
end

local function useConVarSet(name)
    return offsetConVarSet(useConVars, "mcitem_use_", USE_DEFAULTS, name,
        "Extra hand offset applied only while this weapon is being used (drawing / loading / charging).")
end

local function chargedConVarSet(name)
    return offsetConVarSet(chargedConVars, "mcitem_charged_", CHARGED_DEFAULTS, name,
        "Extra hand offset applied only in this weapon's loaded/charged idle state.")
end

local function swingConVarSet(name)
    local existing = swingConVars[name]
    if existing then return existing end

    local defaults = SWING_DEFAULTS[name] or {}
    local created = {}
    for _, field in ipairs(SWING_FIELDS) do
        created[field.key] = CreateClientConVar(
            "mcitem_swing_" .. name .. "_" .. field.suffix,
            defaults[field.key] or "1", true, false,
            "Per-weapon multiplier for one component of the left-click swing (ItemInHandRenderer.swingArm)."
        )
    end

    swingConVars[name] = created
    return created
end

local function drawConVar(name)
    local existing = drawConVars[name]
    if existing then return existing end

    local created = CreateClientConVar(
        "mcitem_use_" .. name .. "_draw", DRAW_DEFAULTS[name] or "1", true, false,
        "Amplitude multiplier for the charge-driven draw-back of this weapon's use pose (Minecraft's power*0.04 for bow/crossbow, power*0.2 for the trident). Does not deform the model."
    )
    drawConVars[name] = created
    return created
end

-- 深度拉伸单独一个倍率。⚠ 别再把它和 draw 合并：draw 调大是"往后拉得更明显"，
-- stretch 调大是"模型沿深度轴被拉长"，用户之前把三叉戟调扁就是这两件事混在一起。
local function stretchConVar(name)
    local existing = stretchConVars[name]
    if existing then return existing end

    local created = CreateClientConVar(
        "mcitem_use_" .. name .. "_stretch", STRETCH_DEFAULTS[name] or "1", true, false,
        "Multiplier for Minecraft's 1 + power*0.2 depth stretch while this weapon is drawn. 0 = no deformation."
    )
    stretchConVars[name] = created
    return created
end

-- 见上面那条 ⚠：加载时就把每件武器的几组 convar 建全。
-- food / potion 没有"武器"意义上的锚点，但**进食 / 喝药的姿势**需要一组自己的偏移：
-- ApplyConsumeTransform 是先做 MC 的吃喝变换、再叠校准过的 Source 锚点，所以这一组
-- （`mcitem_use_food_*` / `mcitem_use_potion_*`）就是"东西举到嘴边的位置"。
for _, name in ipairs({ "bow", "crossbow", "trident", "spear", "shield", "fishing_rod", "food", "potion" }) do
    anchorConVarSet(name)
    useConVarSet(name)
    chargedConVarSet(name)
    swingConVarSet(name)
    drawConVar(name)
    stretchConVar(name)
end

-- 三叉戟蓄力姿势的 archive convar 迁移。
--
-- rev 1（第五轮）：旧版把 trident.json condition 节点上的公共 180° 误当成"using_item
--        独有"，又用一组很大的 mcitem_use_trident_* 去补那个错误 —— 把它们清回 0。
-- rev 2（第七轮）：draw 和 stretch 拆开之后三叉戟的后举才调得动，用户实测出了一组
--        真正对得上的值。archive convar 只改默认值不会影响已经跑过旧版的客户端，
--        而且 rev 1 那次迁移会把它们写成 0，所以必须再走一次迁移把新值推下去。
--
-- ⚠ 迁移只认 `USE_DEFAULTS.trident` / `DRAW_DEFAULTS.trident`，不要在这里再抄一份
--   数字：两处不同步的话，改了默认值的人会发现"重进游戏又变回去了"。
local POSE_REVISION = 2

local tridentPoseRevision = CreateClientConVar(
    "mcitem_trident_pose_revision", "0", true, false,
    "Internal migration revision for the corrected Minecraft trident use transform."
)

timer.Simple(0, function()
    if not tridentPoseRevision or tridentPoseRevision:GetInt() >= POSE_REVISION then return end

    local defaults = USE_DEFAULTS.trident or {}
    for _, key in ipairs(USE_FIELDS) do
        RunConsoleCommand("mcitem_use_trident_" .. key, defaults[key] or "0")
    end
    RunConsoleCommand("mcitem_use_trident_draw", DRAW_DEFAULTS.trident or "1")
    RunConsoleCommand("mcitem_use_trident_stretch", STRETCH_DEFAULTS.trident or "1")
    RunConsoleCommand("mcitem_trident_pose_revision", tostring(POSE_REVISION))
end)

-- 返回 位移增量(x,y,z), 角度增量(pitch,yaw,roll), 缩放倍率。
-- `using` 为真时叠 mcitem_use_<w>_*；武器报出额外静止态（弩的 "charged"）时叠
-- mcitem_charged_<w>_*。三组同一套坐标，所以调起来是一个心智模型。
local function weaponAnchorOffsets(weapon, using)
    local name = weapon.MCAnchorName
    if not name then return 0, 0, 0, 0, 0, 0, 1 end

    local set = anchorConVarSet(name)
    local x, y, z = set.x:GetFloat(), set.y:GetFloat(), set.z:GetFloat()
    local pitch, yaw, roll = set.pitch:GetFloat(), set.yaw:GetFloat(), set.roll:GetFloat()

    local function add(extra)
        x, y, z = x + extra.x:GetFloat(), y + extra.y:GetFloat(), z + extra.z:GetFloat()
        pitch = pitch + extra.pitch:GetFloat()
        yaw = yaw + extra.yaw:GetFloat()
        roll = roll + extra.roll:GetFloat()
    end

    if using then add(useConVarSet(name)) end

    if weapon.GetMCAnchorExtraState then
        local state = weapon:GetMCAnchorExtraState()
        if state == "charged" then add(chargedConVarSet(name)) end
    end

    return x, y, z, pitch, yaw, roll, math.max(set.scale:GetFloat(), 0.001)
end

local Render = MCITEM.Render
local DEFAULT_DISPLAY = Render.DefaultFirstPersonDisplay

-- Every public MCITEM SWEP inherits this file, so one wrapper covers tools,
-- weapons, food, potions, buckets, shields, totems and throwable items in both
-- first and third person.  Keep foil passes inside the same bounded lighting
-- scope because Glint.DrawModel performs additional DrawModel calls.
local function drawMCItemModel(weapon, model, samplePosition)
    local function drawPasses(lightR, lightG, lightB, _, glintR, glintG, glintB)
        model:DrawModel()
        if MCITEM.WeaponHasFoil and MCITEM.WeaponHasFoil(weapon)
        and MCITEM.Glint and MCITEM.Glint.DrawModel then
            MCITEM.Glint.DrawModel(model, weapon.MCGlintProfile,
                glintR or lightR, glintG or lightG, glintB or lightB,
                lightR, lightG, lightB)
        end
    end

    if isfunction(MCITEM.DrawModelWithMCLight) then
        MCITEM.DrawModelWithMCLight(
            model,
            samplePosition,
            drawPasses,
            tonumber(weapon.MCLightEmission) or tonumber(weapon.MCItemLightEmission) or 0
        )
    else
        drawPasses()
    end
end

local function firstPersonDisplay(weapon)
    if weapon.GetMCFirstPersonDisplay then
        local display = weapon:GetMCFirstPersonDisplay()
        if istable(display) then return display end
    end
    return DEFAULT_DISPLAY
end

local function displayComponent(display, key, index)
    local values = display and display[key]
    local fallback = DEFAULT_DISPLAY[key]
    return values and tonumber(values[index]) or fallback[index]
end

-- 转换器把一个 MC 模型单位导成 36.5 Source 单位（$scale 36.5）。这是**模型导出
-- 常量**，和世界的方块尺寸是两码事，MC.BS 变了它也不变。fp_scale 作用在模型实体
-- 上，所以相机空间里的每个 MC 位移也要跟着缩。
local function mcToSource()
    return 36.5 * math.max(fpScale:GetFloat(), 0.001)
end

-- 共享权重 × 本武器权重。三叉戟和剑在 MC 里挥的是**同一段** WHACK/6 动画
-- （Items.TRIDENT 没装 SWING_ANIMATION 组件，吃 SwingAnimation.DEFAULT），差别只可能
-- 来自 Source 侧的锚点 / pivot，所以幅度对不上时调这一组，不要去改 MC 的公式。
local function swingWeights(weapon)
    local weights = {
        posX = fpMinecraftPosX:GetFloat(),
        posY = fpMinecraftPosY:GetFloat(),
        posZ = fpMinecraftPosZ:GetFloat(),
        rotPitch = fpMinecraftRotPitch:GetFloat(),
        rotYaw = fpMinecraftRotYaw:GetFloat(),
        rotRoll = fpMinecraftRotRoll:GetFloat(),
    }

    local name = weapon and weapon.MCAnchorName
    if not name then return weights end

    local set = swingConVarSet(name)
    for _, field in ipairs(SWING_FIELDS) do
        weights[field.key] = weights[field.key] * set[field.key]:GetFloat()
    end
    return weights
end

function SWEP:UpdateMCViewModelFOV()
    local fov = fpMinecraft:GetBool() and fpMinecraftFov:GetFloat() or fpFov:GetFloat()
    if fpMinecraft:GetBool() and self.MCExactShieldFirstPerson == true then
        -- Minecraft feeds 70 degrees to Matrix4f.setPerspective as a vertical
        -- FOV. Source's viewmodel FOV is horizontal at the reference 4:3 aspect.
        -- Do not inherit an archived tuning value on the source-exact path.
        fov = math.deg(2 * math.atan(math.tan(math.rad(70) * 0.5) * (4 / 3)))
    end
    self.ViewModelFOV = math.Clamp(fov, 20, 120)
end

-- 隐藏原 ViewModel 的像素，只把它留着当渲染回调。
-- ⚠ 绝对不要用 viewModel:SetMaterial() 来藏：那是写在 viewmodel **实体** 上的
-- 持久覆盖，而 viewmodel 实体是所有武器共用的（切武器只 SetModel，不清材质）。
-- 任何一条没走到还原的路径——derived SWEP 用 `if SERVER` 吞掉客户端 Holster、
-- 死亡 strip 时 owner 已 NULL、武器实体出 PVS 被删——都会把覆盖永久钉在上面，
-- 之后拿物理枪/撬棍全隐形，只剩 bonemerge 上去的 gmod_hands。
-- render.SetBlend 是渲染栈状态，逐帧自愈、不写实体，没有这个泄漏面。
-- 直接 return true 在部分 GMod 分支上会连 ViewModelDrawn 一起吞掉，也不能用。
function SWEP:PreDrawViewModel(viewModel)
    render.SetBlend(0)

    -- 自愈：清掉旧版本钉在共用 viewmodel 上的持久覆盖。只认自己设过的
    -- 那个值，不碰第三方 addon 的材质覆盖。
    if IsValid(viewModel) and viewModel:GetMaterial() == "engine/occlusionproxy" then
        viewModel:SetMaterial("")
    end
end

-- ViewModelDrawn 之外的兜底：万一某帧 ViewModelDrawn 没被调到，blend 也必须还原，
-- 否则 render.SetBlend(0) 会漏给同一帧后续的模型绘制。
function SWEP:PostDrawViewModel(viewModel)
    render.SetBlend(1)
end

function SWEP:CreatePreviewModel()
    if IsValid(self.MCItemPreview) then
        local desiredModel = self.GetMCFirstPersonModel and self:GetMCFirstPersonModel() or self.WorldModel
        if desiredModel and self.MCItemPreview:GetModel() ~= desiredModel then
            self.MCItemPreview:SetModel(desiredModel)
        end
        return self.MCItemPreview
    end

    local desiredModel = self.GetMCFirstPersonModel and self:GetMCFirstPersonModel() or self.WorldModel
    local model = ClientsideModel(desiredModel, RENDERGROUP_VIEWMODEL)
    if not IsValid(model) then return nil end

    model:SetNoDraw(true)
    self.MCItemPreview = model
    return model
end

-- LivingEntity.getAttackAnim(partialTick)：挖掘的循环和攻击的整弧都从这里出。
function SWEP:GetMCRenderSwing(partialTick)
    local preview = fpMinecraftPreview:GetFloat()
    if preview >= 0 then return math.Clamp(preview, 0, 1) end

    return math.Clamp(MCITEM.GetAttackAnim(self:GetMCItemState(), partialTick), 0, 1)
end

function SWEP:ViewModelDrawn()
    -- PreDrawViewModel 把 blend 压成 0 藏原 vm；原 vm 到这里已经画完，所以第一件事
    -- 就是还原，保证下面任何 early return 都不会把 blend=0 漏给后续绘制。
    render.SetBlend(1)

    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    local viewModel = owner:GetViewModel()
    local model = self:CreatePreviewModel()
    if not IsValid(viewModel) or not IsValid(model) then return end

    local now = CurTime()
    local partialTick = self:AdvanceMCItem(now)
    local state = self:GetMCItemState()

    local useMinecraft = fpMinecraft:GetBool()
    local exactShield = useMinecraft
        and self.MCExactShieldFirstPerson == true
        and isfunction(Render.ApplyExactShieldTransform)
    local eyePosition = owner:EyePos()
    local eyeAngles = owner:EyeAngles()
    if exactShield then
        -- CalcView, vehicles and view punch may move the rendered camera away
        -- from the player's logical eye transform. Java starts at the active
        -- camera, so use this render pass's final origin and angles.
        local view = render and render.GetViewSetup and render.GetViewSetup() or nil
        eyePosition = view and view.origin or EyePos()
        eyeAngles = view and view.angles or EyeAngles()
    end
    local position
    local angles
    if exactShield then
        -- The Java hand PoseStack begins at the camera. The Source viewmodel
        -- entity can already contain engine bob/lag, which would be applied a
        -- second time below alongside Minecraft's own bob and turn sway.
        position = eyePosition
        angles = Angle(eyeAngles.p, eyeAngles.y, eyeAngles.r)
    else
        position = viewModel:GetPos()
        local sourceAngles = viewModel:GetAngles()
        angles = Angle(sourceAngles.p, sourceAngles.y, sourceAngles.r)
    end
    local unitScale = mcToSource()
    local display = firstPersonDisplay(self)

    -- ① bobView / ② 转头滞后：都是绕相机原点转的，必须在加锚点偏移之前做，
    -- 否则手会绕着自己转而不是跟着视角甩。
    local walkPhase, bobAmount = MCITEM.GetViewBob(state, partialTick)
    position, angles = Render.ApplyViewBob(
        position, angles, walkPhase, bobAmount, unitScale, cvViewBob:GetFloat()
    )

    local swayPitch, swayYaw = MCITEM.GetViewSway(state, eyeAngles.p, eyeAngles.y, partialTick)
    angles = Render.ApplyViewSway(angles, swayPitch, swayYaw, cvViewSway:GetFloat())

    -- ③ 手持锚点（共享值 + 本武器的增量）。use 姿势的增量要在这里就算进去，所以
    -- 先把使用状态解出来。
    local useKind, timeHeld, chargeTicks, useData
    if self.GetMCUseRenderState then
        useKind, timeHeld, chargeTicks, useData = self:GetMCUseRenderState(partialTick)
    end

    local preview = cvUsePreview:GetFloat()
    if useKind and preview >= 0 then timeHeld = preview end

    local anchorX, anchorY, anchorZ, anchorPitch, anchorYaw, anchorRoll, anchorScale
    if exactShield then
        anchorX, anchorY, anchorZ = 0, 0, 0
        anchorPitch, anchorYaw, anchorRoll, anchorScale = 0, 0, 0, 1
    else
        anchorX, anchorY, anchorZ,
            anchorPitch, anchorYaw, anchorRoll, anchorScale = weaponAnchorOffsets(self, useKind ~= nil)
    end

    local anchorForward = fpX:GetFloat() + anchorX
    local anchorRight = fpY:GetFloat() + anchorY
    local anchorUp = fpZ:GetFloat() + anchorZ
    local consumeUse = useKind == "eat" or useKind == "drink"

    -- EAT/DRINK apply their transform before applyItemArmTransform; all existing
    -- weapon branches apply the calibrated anchor before their attack/use pose.
    if not exactShield and not (useMinecraft and consumeUse) then
        position = position
            + angles:Forward() * anchorForward
            + angles:Right() * anchorRight
            + angles:Up() * anchorUp
    end

    local stretch, stretchAxis = 1, nil
    local exactShieldScale

    if useMinecraft then
        local pivotScale = fpMinecraftPivot:GetFloat()
        local swing = self:GetMCRenderSwing(partialTick)
        local equip = cvHandLower:GetBool()
            and MCITEM.GetEquippedProgress(state, partialTick)
            or 0

        if exactShield then
            position, angles, exactShieldScale = Render.ApplyExactShieldTransform(
                position, angles, swing, equip, useKind == "block", unitScale, display
            )
        elseif consumeUse then
            position, angles = Render.ApplyConsumeTransform(
                position,
                angles,
                timeHeld or 0,
                chargeTicks or 32,
                equip,
                1,
                unitScale,
                anchorForward,
                anchorRight,
                anchorUp
            )
        else
            -- 上面那三个 convar 描述的是**静止时想要的位置**。先把 idle 的 display
            -- 偏移减掉还原出 MC 的手部旋转轴心，ApplyWhackTransform 旋转完再加回去。
            position = position - Render.HandPivotOffset(angles, unitScale, pivotScale)
        end

        if exactShield then
            -- The exact helper already applied the complete Java pose.
        elseif consumeUse then
            -- ApplyConsumeTransform already includes the hand anchor/equip branch.
        elseif useKind == "block" then
            position, angles = Render.ApplyShieldBlockTransform(
                position, angles, equip, unitScale, pivotScale, display
            )
        elseif useKind == "spear" then
            position, angles = Render.ApplySpearUseTransform(
                position, angles, timeHeld or 0, 1, unitScale, pivotScale, display, useData
            )
        elseif useKind then
            position, angles, stretch, stretchAxis = Render.ApplyRangedUseTransform(
                position, angles, useKind, timeHeld or 0, chargeTicks, equip, 1,
                unitScale, pivotScale, display,
                self.MCAnchorName and drawConVar(self.MCAnchorName):GetFloat() or 1,
                self.MCAnchorName and stretchConVar(self.MCAnchorName):GetFloat() or 1
            )
        elseif self.MCSwingType == MCITEM.SwingAnimationType.STAB then
            position, angles = Render.ApplyStabTransform(
                position, angles, swing, equip, 1, unitScale, pivotScale, display
            )
        else
            -- 挥动之后的追加位姿（弩上好弦的静止偏移就在这一条上）。
            local extra = self.GetMCSwingExtra and function(translate, rotate, value)
                self:GetMCSwingExtra(translate, rotate, value, 1)
            end or nil

            position, angles = Render.ApplyWhackTransform(
                position, angles, swing, equip, 1, unitScale, swingWeights(self),
                pivotScale, display, extra
            )
        end

        if not cvDrawStretch:GetBool() then stretch, stretchAxis = 1, nil end
    end

    -- convar 是 item/generated 第一人称 display（0,-90,25）手调后的 Source 锚点。
    -- 其他物品只叠加它与默认 display 的源码差值；长矛因此使用
    -- (-20,90,-35)，而不是继续套剑的朝向。
    if not exactShield then
        local displayPitch = displayComponent(display, "rotation", 1)
        local displayYaw = displayComponent(display, "rotation", 2)
        local displayRoll = displayComponent(display, "rotation", 3)
        angles:RotateAroundAxis(
            angles:Up(),
            fpYaw:GetFloat() + anchorYaw + displayYaw - DEFAULT_DISPLAY.rotation[2]
        )
        angles:RotateAroundAxis(
            angles:Right(),
            fpPitch:GetFloat() + anchorPitch + displayPitch - DEFAULT_DISPLAY.rotation[1]
        )
        angles:RotateAroundAxis(
            angles:Forward(),
            fpRoll:GetFloat() + anchorRoll + displayRoll - DEFAULT_DISPLAY.rotation[3]
        )
    end

    local value = math.max(fpScale:GetFloat(), 0.001) * anchorScale
    if useMinecraft and not exactShield then
        value = value * math.max(fpMinecraftScale:GetFloat(), 0.001)
    end

    -- The shared hand anchor was tuned at 1280x960 (4:3). Source widens the
    -- viewmodel projection at 16:9, which otherwise pulls every held item toward
    -- screen centre. Apply this after all pose translations so idle/use/swing
    -- positions share the same dynamic correction without rewriting any saved
    -- bmb_item_test_fp_* or per-weapon convars.
    if not exactShield and cvHandAspectLock:GetBool() and Render.LockHandAspect then
        position = Render.LockHandAspect(
            position, eyePosition, eyeAngles, ScrW(), ScrH(), 4 / 3
        )
    end

    -- MC 用写死 70° 的 hudFov 画手，拉弓那 0.85 只缩世界。我们的物品是世界坐标里的
    -- 一个模型，不补偿就会跟着世界一起放大（见 Render.LockHandFov）。
    if not exactShield and cvHandFovLock:GetBool() then
        local modifier = self.GetMCSmoothedFovModifier and self:GetMCSmoothedFovModifier(now)
        if modifier and modifier ~= 1 then
            -- `Player:GetFOV()` 取的是本帧生效的视角 FOV（TranslateFOV 之后），所以除回
            -- modifier 得到未缩放的基准。就算某个分支上 GetFOV 返回的是缩放**前**的值，
            -- 也只是让基准偏 ≤17%，而 r = tan(a/2)/tan(b/2) 对基准并不敏感
            -- （基准 75° 与 90° 算出来的 r 只差约 3%），不会翻车。
            local baseFov = owner:GetFOV() / modifier
            local sizeRatio
            position, sizeRatio = Render.LockHandFov(
                position, eyePosition, eyeAngles, baseFov, baseFov * modifier
            )
            value = value * sizeRatio
        end
    end

    -- ⚠ display.scale 是 **MC 物品模型空间**的 (x=右, y=上, z=厚度)，
    -- RenderMultiply 却作用在**编译后的 Source 模型局部轴**上。转换器把 item/generated
    -- 的精灵面导成 X=厚度 / Y=水平 / Z=竖直（`$sequence rotate 0` 在 studiomdl 里是
    -- +90° yaw，把 SMD 的 X 转到模型 Y；实测 hull 也是 2.78 × 37 × 37），
    -- 所以映射是 model(X,Y,Z) = mc(z, x, y)，**不是**逐分量照抄。
    -- 照抄的后果：长矛的 [1.36, 1.36, 0.68] 会把厚度放大到 2 倍、竖直压到一半 ——
    -- 就是"矛看起来非常厚、像素被拉长"的成因。
    local relativeScale
    if exactShield then
        relativeScale = exactShieldScale or Vector(1, 1, 1)
    else
        relativeScale = Vector(
            displayComponent(display, "scale", 3) / DEFAULT_DISPLAY.scale[3],
            displayComponent(display, "scale", 1) / DEFAULT_DISPLAY.scale[1],
            displayComponent(display, "scale", 2) / DEFAULT_DISPLAY.scale[2]
        )
    end
    local renderMatrix = Matrix()
    renderMatrix:Scale(relativeScale)
    -- 拉弓 / 装填 / 蓄力的深度拉伸在 display 之外：世界 = 实体变换 · 拉伸 · display。
    if stretchAxis then
        renderMatrix = Render.WorldStretchMatrix(angles, stretchAxis, stretch) * renderMatrix
    end
    model:EnableMatrix("RenderMultiply", renderMatrix)

    model:SetPos(position)
    model:SetAngles(angles)
    model:SetModelScale(value, 0)
    model:SetupBones()
    -- 部分 GMod 分支会在 SetupBones 里重建 clientside model 的变换。
    model:SetModelScale(value, 0)
    drawMCItemModel(self, model, position)
end

--------------------------------------------------------------------------------
-- HUD：准星 + 攻击冷却条（Hud.extractCrosshair）
--------------------------------------------------------------------------------

function SWEP:DrawHUD()
    local owner = self:GetOwner()
    if not IsValid(owner) then return end

    local now = CurTime()

    -- DrawHUD 是渲染上下文里**每帧都会跑**的那个入口，所以视觉时钟挂在这里：
    -- 第三人称 / 没画 viewmodel 的帧也照样推进（放在下面那个 return 之前）。
    self:AdvanceMCItem(now)

    if owner:ShouldDrawLocalPlayer() then return end -- 准星只在第一人称画，同 MC

    -- MC 的 Hud 用 getAttackStrengthScale(0)：整数 tick，条是一格一格跳的。
    local charge = self:GetMCAttackStrengthScale(now, 0)

    -- crosshairPickEntity：满蓄力 + 准星停在活着的生物上 + 冷却本身够长（> 5 tick）
    -- 才显示那个"满格"图标，否则画进度条。
    local showFull = false
    if charge >= 1 and self:GetMCAttackStrengthDelay() > 5 then
        local target = self:MCResolveAttackTarget(owner)
        showFull = IsValid(target) and target:Health() > 0
    end

    MCITEM.Crosshair.Draw(charge, showFull)

    if cvDebug:GetBool() then self:DrawMCDebug(now, owner) end
end

--------------------------------------------------------------------------------
-- 诊断（mcitem_debug 1）：把实测值和 MC 的参考值并排放，别再靠肉眼猜快慢
--------------------------------------------------------------------------------

local DEBUG_FONT = "DermaDefault"

function SWEP:DrawMCDebug(now, owner)
    local state = self:GetMCItemState()
    local tickRate = MCITEM.MeasuredTickRate(state, now)

    local arc = (state.arcStartAt and state.arcEndAt and state.arcEndAt > state.arcStartAt)
        and (state.arcEndAt - state.arcStartAt) * 1000 or nil
    local gap = state.lastSwingGap and state.lastSwingGap * 1000 or nil

    local speed = owner:GetVelocity():Length2D()
    local blocksPerTick = speed / 20 / MCITEM.BlockSize()

    local lines = {
        string.format("tick rate    %6.2f /s   (MC 20.00)", tickRate),
        string.format("swing arc    %6s ms   (MC 300 = 6 tick)", arc and string.format("%.0f", arc) or "-"),
        string.format("swing gap    %6s ms   (MC 200 = 4 tick, 挖掘时)", gap and string.format("%.0f", gap) or "-"),
        string.format("cooldown     %6.0f ms   (MC %.0f = %.1f tick)",
            (1 - self:GetMCAttackStrengthScale(now, 0)) * self:GetMCAttackStrengthDelay() * 50,
            self:GetMCAttackStrengthDelay() * 50, self:GetMCAttackStrengthDelay()),
        string.format("partialTick  %6.3f      (>0 才有插值; 恒 0 = 20Hz 阶梯)", self.MCLastPartialTick or 0),
        string.format("swingTime %2d  anim %.3f  hand %.3f", state.swingTime, state.attackAnim, state.handHeight),
        string.format("speed %5.0f u/s = %.3f blk/tick  (bob cap %.3f)",
            speed, blocksPerTick, MCITEM.MaxWalkBlocksPerTick),
        string.format("bob %.4f  walkDist %.2f", state.bob, state.walkDist),
    }

    surface.SetFont(DEBUG_FONT)
    local _, lineHeight = surface.GetTextSize("W")
    local y = 120

    for _, line in ipairs(lines) do
        draw.SimpleText(line, DEBUG_FONT, 21, y + 1, color_black)
        draw.SimpleText(line, DEBUG_FONT, 20, y, color_white)
        y = y + lineHeight + 2
    end
end

--------------------------------------------------------------------------------

function SWEP:DrawWorldModel()
    local owner = self:GetOwner()
    if not IsValid(owner) then
        -- A per-state third-person scale may have been applied while equipped.
        -- Restore the base world scale before drawing a dropped/unowned weapon.
        self:SetModelScale(0.55, 0)
        drawMCItemModel(self, self)
        return
    end

    -- The hand matrix must come from a bone cache that was built this frame.
    -- If it was not, GetBoneMatrix hands back the previous frame's pose -- or the
    -- reference pose -- and the item renders somewhere around the torso instead
    -- of in the hand.
    --
    -- This used to force a rebuild only for the local player, on the assumption
    -- that "remote players are drawn before their weapon". That ordering is not
    -- guaranteed, and in multiplayer it visibly does not hold: other players'
    -- items sat inside their bodies while your own looked correct (user report
    -- 2026-08-28, screenshots of the mace). Refresh for whoever owns it.
    --
    -- Once per player per frame: SetupBones is idempotent within a frame, and a
    -- player carrying this SWEP would otherwise pay for it on every draw pass.
    local frame = FrameNumber()
    if owner.MCItemBoneSetupFrame ~= frame then
        owner.MCItemBoneSetupFrame = frame
        owner:SetupBones()
    end

    local bone = owner:LookupBone("ValveBiped.Bip01_R_Hand")
    local matrix = bone and owner:GetBoneMatrix(bone)
    if not matrix then
        self:SetModelScale(0.55, 0)
        drawMCItemModel(self, self)
        return
    end

    local position = matrix:GetTranslation()
    local angles = matrix:GetAngles()
    position = position
        + angles:Forward() * 7
        + angles:Right() * 4
        + angles:Up() * -10
    angles:RotateAroundAxis(angles:Up(), 60)
    angles:RotateAroundAxis(angles:Forward(), -160)

    local profile = self.MCThirdPersonProfile
    local state = self.GetMCThirdPersonRenderState and self:GetMCThirdPersonRenderState() or "idle"
    local stateScale = 1
    if profile and MCITEM.ThirdPerson then
        local x, y, z, pitch, yaw, roll, scale = MCITEM.ThirdPerson.GetTransform(profile, state)
        stateScale = scale or 1
        position = position
            + angles:Forward() * x
            + angles:Right() * y
            + angles:Up() * z
        angles:RotateAroundAxis(angles:Right(), pitch)
        angles:RotateAroundAxis(angles:Up(), yaw)
        angles:RotateAroundAxis(angles:Forward(), roll)
    end

    local desiredModel = self.GetMCThirdPersonModel
        and self:GetMCThirdPersonModel()
        or self.WorldModel
    if desiredModel and self:GetModel() ~= desiredModel then self:SetModel(desiredModel) end

    self:SetRenderOrigin(position)
    self:SetRenderAngles(angles)
    local worldScale = 0.55 * stateScale
    -- Keep the transform from the most recent world-model pass available to
    -- attachments such as the fishing line.  A one-frame-old value is still a
    -- better match than rebuilding this hand/profile transform independently.
    self.MCItemWorldRenderPosition = Vector(position.x, position.y, position.z)
    self.MCItemWorldRenderAngles = Angle(angles.p, angles.y, angles.r)
    self.MCItemWorldRenderScale = worldScale
    self:SetModelScale(worldScale, 0)
    drawMCItemModel(self, self, position)
    self:SetRenderOrigin()
    self:SetRenderAngles()
end

-- 这里以前负责还原 viewmodel 的材质覆盖。现在藏 vm 走 render.SetBlend，是逐帧
-- 自愈的渲染状态，不再需要、也不该再依赖 Holster 来收尾——客户端 Holster
-- 并不保证被调到（derived SWEP 可以盖掉它，死亡/出 PVS 时也可能直接跳过）。
function SWEP:Holster()
    return true
end

function SWEP:OnRemove()
    self:Holster()
    if IsValid(self.MCItemPreview) then
        self.MCItemPreview:Remove()
        self.MCItemPreview = nil
    end
end
