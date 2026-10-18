-- MC 准星 + 攻击冷却条（MC 26.2 的 Hud.extractCrosshair 移植）。
--
-- 四张 sprite 都是十几像素的纯色块，这里直接按解包出来的像素表用 DrawRect 画：
-- 不引入新的 .png/.vtf 资源（省掉"新贴图要重启 GMod / 要 resource.AddFile"那一类
-- 坑），任意 GUI 缩放下都是硬边像素，和 MC 的最近邻采样一致。
--
-- 像素数据来源：assets/minecraft/textures/gui/sprites/hud/
--   crosshair.png(15x15) / crosshair_attack_indicator_background.png(16x4)
--   crosshair_attack_indicator_progress.png(16x4) / ..._full.png(16x16)
--
-- 对应 MC 源（26.2）：Hud.extractCrosshair、RenderPipelines.CROSSHAIR
-- （BlendFunction.INVERT = src ONE_MINUS_DST_COLOR / dst ONE_MINUS_SRC_COLOR）

MCITEM = MCITEM or {}
MCITEM.Crosshair = MCITEM.Crosshair or {}

local Crosshair = MCITEM.Crosshair

local cvEnabled = CreateClientConVar("mcitem_crosshair", "1", true, false,
    "Draw the Minecraft crosshair while holding an MCITEM weapon.")
local cvIndicator = CreateClientConVar("mcitem_attack_indicator", "1", true, false,
    "Minecraft AttackIndicatorStatus: 0 = off, 1 = crosshair.")
local cvInvert = CreateClientConVar("mcitem_crosshair_invert", "1", true, false,
    "Use Minecraft's inverted crosshair blend (BlendFunction.INVERT).")
local cvScale = CreateClientConVar("mcitem_hud_scale", "2", true, false,
    "Screen pixels per Minecraft GUI pixel. 0 = auto (Minecraft's Auto rule, which is 4 at 1080p and reads too big here).")

-- 每条 run 是 { x, y, w, h, r, g, b }，坐标在 sprite 自己的像素空间里。
local CROSSHAIR_RUNS = {
    -- 竖杠和横杠共用中心像素，所以拆成三条：INVERT 混合下同一像素画两遍结果会不一样。
    { 7, 3, 1, 9, 255, 255, 255 },
    { 3, 7, 4, 1, 255, 255, 255 },
    { 8, 7, 4, 1, 255, 255, 255 },
}

local INDICATOR_BACKGROUND_RUNS = {
    { 3, 0, 1, 1, 58, 59, 60 },
    { 0, 1, 16, 1, 58, 59, 60 },
    { 0, 2, 14, 1, 58, 59, 60 },
    { 3, 3, 1, 1, 58, 59, 60 },
}

local INDICATOR_PROGRESS_RUNS = {
    { 3, 0, 1, 1, 91, 74, 73 },
    { 0, 1, 1, 1, 130, 109, 108 },
    { 1, 1, 1, 1, 109, 89, 87 },
    { 2, 1, 1, 1, 130, 109, 108 },
    { 3, 1, 1, 1, 109, 89, 87 },
    { 4, 1, 12, 1, 215, 217, 234 },
    { 0, 2, 1, 1, 130, 109, 108 },
    { 1, 2, 1, 1, 109, 89, 87 },
    { 2, 2, 1, 1, 130, 109, 108 },
    { 3, 2, 1, 1, 109, 89, 87 },
    { 4, 2, 2, 1, 234, 236, 242 },
    { 6, 2, 8, 1, 255, 255, 255 },
    { 3, 3, 1, 1, 91, 74, 73 },
}

-- full 是"满条 + 下面一个小十字"，前四行和 progress 几乎相同（只有右端一像素更亮）。
local INDICATOR_FULL_RUNS = {
    { 3, 0, 1, 1, 91, 74, 73 },
    { 0, 1, 1, 1, 130, 109, 108 },
    { 1, 1, 1, 1, 109, 89, 87 },
    { 2, 1, 1, 1, 130, 109, 108 },
    { 3, 1, 1, 1, 109, 89, 87 },
    { 4, 1, 11, 1, 215, 217, 234 },
    { 15, 1, 1, 1, 255, 255, 255 },
    { 0, 2, 1, 1, 130, 109, 108 },
    { 1, 2, 1, 1, 109, 89, 87 },
    { 2, 2, 1, 1, 130, 109, 108 },
    { 3, 2, 1, 1, 109, 89, 87 },
    { 4, 2, 2, 1, 234, 236, 242 },
    { 6, 2, 8, 1, 255, 255, 255 },
    { 3, 3, 1, 1, 91, 74, 73 },
    { 8, 4, 1, 1, 215, 217, 234 },
    { 7, 5, 3, 1, 215, 217, 234 },
    { 8, 6, 1, 1, 215, 217, 234 },
}

-- Window.calculateScale：一路放大到再放大一档就装不下 320x240 为止。
function Crosshair.GuiScale()
    local override = math.floor(cvScale:GetFloat())
    if override > 0 then return override end

    local width, height = ScrW(), ScrH()
    local scale = 1
    while scale < 8
        and width / (scale + 1) >= 320
        and height / (scale + 1) >= 240 do
        scale = scale + 1
    end
    return scale
end

-- clipWidth = nil 表示整张画；否则只画 sprite 左边 clipWidth 列
-- （等价于 MC 的 blitSprite(..., u=0, v=0, width, height) 带 uv 裁剪）。
local function drawRuns(runs, originX, originY, scale, clipWidth)
    for _, run in ipairs(runs) do
        local x, y, w, h = run[1], run[2], run[3], run[4]
        local visible = true

        if clipWidth then
            w = math.min(w, clipWidth - x)
            visible = x < clipWidth and w > 0
        end

        if visible then
            surface.SetDrawColor(run[5], run[6], run[7], 255)
            surface.DrawRect(originX + x * scale, originY + y * scale, w * scale, h * scale)
        end
    end
end

-- 准星每帧都画，所以 blend 相关的东西先在加载时探一次：万一某个 GMod 分支缺了
-- 枚举，退回普通 alpha 混合（准星变成纯白，不再随背景反色），而不是每帧报错。
local INVERT_SUPPORTED = render ~= nil
    and render.OverrideBlend ~= nil
    and BLEND_ONE_MINUS_DST_COLOR ~= nil
    and BLEND_ONE_MINUS_SRC_COLOR ~= nil
    and BLENDFUNC_ADD ~= nil

local function beginBlend()
    if not INVERT_SUPPORTED or not cvInvert:GetBool() then return false end
    render.OverrideBlend(true, BLEND_ONE_MINUS_DST_COLOR, BLEND_ONE_MINUS_SRC_COLOR, BLENDFUNC_ADD)
    return true
end

local function endBlend(active)
    if active then render.OverrideBlend(false) end
end

-- charge     Player.getAttackStrengthScale(0)，冷却条进度
-- showFull   crosshairPickEntity 是活着的生物 + charge >= 1 + 冷却 > 5 tick 时的满格图标
function Crosshair.Draw(charge, showFull)
    if not cvEnabled:GetBool() then return end

    local scale = Crosshair.GuiScale()
    local guiWidth = math.ceil(ScrW() / scale)
    local guiHeight = math.ceil(ScrH() / scale)

    local blending = beginBlend()

    drawRuns(
        CROSSHAIR_RUNS,
        math.floor((guiWidth - 15) / 2) * scale,
        math.floor((guiHeight - 15) / 2) * scale,
        scale
    )

    if cvIndicator:GetInt() == 1 then
        -- Hud：x = guiWidth/2 - 8，y = guiHeight/2 - 7 + 16。
        local x = (math.floor(guiWidth / 2) - 8) * scale
        local y = (math.floor(guiHeight / 2) - 7 + 16) * scale

        if showFull then
            drawRuns(INDICATOR_FULL_RUNS, x, y, scale)
        elseif charge < 1 then
            drawRuns(INDICATOR_BACKGROUND_RUNS, x, y, scale)
            -- MC 用的就是 17 不是 16（满的时候进度条比背景多顶出一格）。
            drawRuns(INDICATOR_PROGRESS_RUNS, x, y, scale, math.floor(charge * 17))
        end
    end

    endBlend(blending)
end

return Crosshair
