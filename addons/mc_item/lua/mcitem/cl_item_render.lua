-- ItemInHandRenderer 的第一人称变换（MC 26.2 移植）。
--
-- 只放 MC 的纯数学：一般物品仍使用各 SWEP 的 Source 手持锚点；能证明完整模型轴合同
-- 的特殊物品（目前是盾牌）则在这里重建包括 0.56/-0.52/-0.72 在内的完整 PoseStack，
-- 再一次性换算到 Source。另负责 equip、挥动、pivot、走路晃动和转头滞后。
--
-- MC 里这几层的叠加顺序（GameRenderer.renderItemInHand → submitHandsWithItems）：
--   ① bobHurt（受伤翻滚，本库不做）
--   ② bobView             走路晃动，和相机用的是同一个函数
--   ③ xBob/yBob 转头滞后
--   ④ applyItemArmTransform   手持锚点 + equippedProgress 下沉
--   ⑤ swingArm                挥动位移 + 四步攻击旋转
-- 顺序不能换：②③ 是绕相机原点转的，所以必须在加锚点偏移**之前**做。
--
-- 对应 MC 源（26.2）：
--   ItemInHandRenderer.applyItemArmTransform / swingArm / applyItemArmAttackTransform
--   GameRenderer.bobView
--   submitArmWithItem 里按 ItemStack.getSwingAnimation().type() 分派 WHACK / STAB

MCITEM = MCITEM or {}
MCITEM.Render = MCITEM.Render or {}

local Render = MCITEM.Render

local DEFAULT_WEIGHTS = {}
local DEFAULT_DISPLAY = {
    translation = { 1.13, 3.2, 1.13 },
    rotation = { 0, -90, 25 },
    scale = { 0.68, 0.68, 0.68 },
}

Render.DefaultFirstPersonDisplay = DEFAULT_DISPLAY

local function progress(value, startValue, endValue)
    if endValue == startValue then return value >= endValue and 1 or 0 end
    return math.Clamp((value - startValue) / (endValue - startValue), 0, 1)
end

-- net.minecraft.util.Ease（只保留 SpearAnimations 实际调用的曲线）。
local function easeInOutSine(value)
    return -(math.cos(math.pi * value) - 1) / 2
end

local function easeOutBack(value)
    local shifted = value - 1
    return 1 + 2.70158 * shifted * shifted * shifted + 1.70158 * shifted * shifted
end

local function easeInOutExpo(value)
    if value < 0.5 then
        if value == 0 then return 0 end
        return math.pow(2, 20 * value - 10) / 2
    end
    if value == 1 then return 1 end
    return (2 - math.pow(2, -20 * value + 10)) / 2
end

local function easeOutCubic(value)
    return 1 - math.pow(1 - value, 3)
end

local function easeInOutElastic(value)
    if value == 0 or value == 1 then return value end
    local sine = math.sin((20 * value - 11.125) * 1.3962634801864624)
    if value < 0.5 then
        return -(math.pow(2, 20 * value - 10) * sine) / 2
    end
    return math.pow(2, -20 * value + 10) * sine / 2 + 1
end

local function easeOutCirc(value)
    return math.sqrt(math.max(1 - (value - 1) * (value - 1), 0))
end

local function easeInCirc(value)
    return -math.sqrt(math.max(1 - value * value, 0)) + 1
end

local function easeInOutBack(value)
    if value < 0.5 then
        return 4 * value * value * (7.189819 * value - 2.5949094) / 2
    end
    local shifted = 2 * value - 2
    return (shifted * shifted * (3.5949094 * shifted + 2.5949094) + 2) / 2
end

local function easeOutQuart(value)
    local inverse = 1 - value
    return 1 - inverse * inverse * inverse * inverse
end

-- MC 相机空间（+X 右、+Y 上、+Z 朝向观察者）→ Source（Right / Up / -Forward）。
-- unitScale = 一个 MC 单位（= 一格）在这套坐标里的 Source 长度。
function Render.CameraOffset(angles, x, y, z, unitScale)
    return angles:Right() * (x * unitScale)
        + angles:Up() * (y * unitScale)
        + angles:Forward() * (-z * unitScale)
end

-- ItemTransform 的位移是 1/16 单位空间（模型像素），不是格。
function Render.DisplayOffset(angles, x, y, z, unitScale)
    return Render.CameraOffset(angles, x / 16, y / 16, z / 16, unitScale)
end

-- 手部 pivot：ItemTransform 在攻击旋转之后才叠加，单独拿出来物品才会绕手转，
-- 而不是绕生成网格的几何中心自转。
function Render.HandPivotOffset(angles, unitScale, pivotScale)
    return Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, DEFAULT_DISPLAY)
end

function Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
    display = display or DEFAULT_DISPLAY
    pivotScale = pivotScale or 1
    local translation = display.translation or DEFAULT_DISPLAY.translation
    return Render.DisplayOffset(
        angles,
        (translation[1] or DEFAULT_DISPLAY.translation[1]) * pivotScale,
        (translation[2] or DEFAULT_DISPLAY.translation[2]) * pivotScale,
        (translation[3] or DEFAULT_DISPLAY.translation[3]) * pivotScale,
        unitScale
    )
end

-- ItemInHandRenderer.swingArm + applyItemArmAttackTransform（SwingAnimationType.WHACK）。
--   position/angles  已经落在 idle 手持位姿上
--   swing            LivingEntity.getAttackAnim(partialTick) 的结果，[0,1]
--   equip            1 = 刚掏出来（往下沉），0 = 完全举起
--   side             +1 主手在右，-1 在左
--   unitScale        一个 MC 单位的 Source 长度
--   weights          调试用的分量权重（缺省全 1），用来单独关掉某一项看效果
--   extra            可选：`function(translate, rotate, swing)`，在四步旋转之后、
--                    display 偏移之前追加自己的位姿。弩上好弦的静止偏移走这一条
--                    （MC 在 `swingArm(...)` 之后紧跟一句 `if (charged && attack < 0.001)`）。
function Render.ApplyWhackTransform(position, angles, swing, equip, side, unitScale, weights, pivotScale, display, extra)
    weights = weights or DEFAULT_WEIGHTS

    local function weight(key)
        local value = weights[key]
        if value == nil then return 1 end
        return value
    end

    local function translate(x, y, z)
        position = position + Render.CameraOffset(angles, x, y, z, unitScale)
    end

    local function rotate(axis, degrees)
        if axis == "x" then
            angles:RotateAroundAxis(angles:Right(), degrees)
        elseif axis == "y" then
            angles:RotateAroundAxis(angles:Up(), degrees)
        else
            -- MC 的 +Z 朝向观察者，和 Source 的 Forward 反向。
            angles:RotateAroundAxis(angles:Forward(), -degrees)
        end
    end

    -- applyItemArmTransform 的 equippedProgress 分量（ITEM_HEIGHT_SCALE = -0.6）。
    -- 另外三个常量是 MC 的手持锚点，Source 侧由 SWEP 的 convar 提供。
    translate(0, equip * -0.6, 0)

    -- swingArm：位移三分量。注意 x/y 用 sqrt(swing)，z 用 swing 本身，别写混。
    local swingRoot = math.sqrt(math.max(swing, 0))
    local swingSin = math.sin(swingRoot * math.pi)
    local swingSin2 = math.sin(swingRoot * math.pi * 2)
    local swingSinFull = math.sin(swing * math.pi)
    translate(
        side * (-0.4 * swingSin) * weight("posX"),
        0.2 * swingSin2 * weight("posY"),
        -0.2 * swingSinFull * weight("posZ")
    )

    -- applyItemArmAttackTransform：四步旋转，顺序不能换。
    rotate("y", side * (45 - 20 * math.sin(swing * swing * math.pi)) * weight("rotYaw"))
    rotate("z", side * swingSin * -20 * weight("rotRoll"))
    rotate("x", swingSin * -80 * weight("rotPitch"))
    rotate("y", side * -45 * weight("rotYaw"))

    if isfunction(extra) then extra(translate, rotate, swing) end

    position = position + Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)

    return position, angles
end

-- ItemUseAnimation.BLOCK for a real ShieldItem. Java 26.2 first applies the
-- ordinary item-arm transform (only the equippedProgress vertical sink), then
-- deliberately skips the legacy sword-block rotations for ShieldItem itself.
-- The special shield/blocking item model supplies the remaining display pose.
function Render.ApplyShieldBlockTransform(position, angles, equip, unitScale, pivotScale, display)
    position = position + Render.CameraOffset(angles, 0, (tonumber(equip) or 0) * -0.6, 0, unitScale)
    position = position + Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
    return position, angles
end

-- Rebuild the complete Java shield pose in Minecraft camera space, then
-- change basis once for Source:
--   MC camera (x, y, z) -> Source (Right, Up, -Forward)
--   ShieldModel (x, y, z) -> runtime MDL local (z, x, y)
-- The MDL contains the raw ShieldModel geometry. The item definition's
-- special-renderer transform (1, -1, -1) is applied in the final axis bridge.
-- The runtime mapping includes mc2source's root bridge and the idle sequence's
-- +90-degree yaw; using the raw VVD bind axes here leaves the shield 90 degrees
-- out after SetupBones applies that sequence pose.
-- This preserves PoseStack's post-multiply order instead of approximating the
-- display transform with hand-tuned Source Euler offsets.
function Render.ApplyExactShieldTransform(position, angles, swing, equip, blocking, unitScale, display)
    display = display or DEFAULT_DISPLAY

    local origin = Vector(0, 0, 0)
    local basisX = Vector(1, 0, 0)
    local basisY = Vector(0, 1, 0)
    local basisZ = Vector(0, 0, 1)

    local function translate(x, y, z)
        origin = origin + basisX * x + basisY * y + basisZ * z
    end

    local function rotateX(degrees)
        local radians = math.rad(degrees)
        local sine, cosine = math.sin(radians), math.cos(radians)
        local oldY, oldZ = basisY, basisZ
        basisY = oldY * cosine + oldZ * sine
        basisZ = oldY * -sine + oldZ * cosine
    end

    local function rotateY(degrees)
        local radians = math.rad(degrees)
        local sine, cosine = math.sin(radians), math.cos(radians)
        local oldX, oldZ = basisX, basisZ
        basisX = oldX * cosine + oldZ * -sine
        basisZ = oldX * sine + oldZ * cosine
    end

    local function rotateZ(degrees)
        local radians = math.rad(degrees)
        local sine, cosine = math.sin(radians), math.cos(radians)
        local oldX, oldY = basisX, basisY
        basisX = oldX * cosine + oldY * sine
        basisY = oldX * -sine + oldY * cosine
    end

    -- ItemInHandRenderer.applyItemArmTransform, right/main hand.
    translate(0.56, -0.52 + (tonumber(equip) or 0) * -0.6, -0.72)

    if not blocking then
        -- ItemInHandRenderer.swingArm + applyItemArmAttackTransform.
        swing = math.Clamp(tonumber(swing) or 0, 0, 1)
        local swingRoot = math.sqrt(swing)
        local swingPosition = math.sin(swingRoot * math.pi)
        local swingPosition2 = math.sin(swingRoot * math.pi * 2)
        local swingFull = math.sin(swing * math.pi)
        translate(-0.4 * swingPosition, 0.2 * swingPosition2, -0.2 * swingFull)

        rotateY(45 + math.sin(swing * swing * math.pi) * -20)
        rotateZ(swingPosition * -20)
        rotateX(swingPosition * -80)
        rotateY(-45)
    end

    -- ItemTransform.apply: translation is stored in model pixels and decoded
    -- to 1/16 block units before rotationXYZ, scale, and the centre shift.
    local translation = display.translation or DEFAULT_DISPLAY.translation
    translate(
        (tonumber(translation[1]) or DEFAULT_DISPLAY.translation[1]) / 16,
        (tonumber(translation[2]) or DEFAULT_DISPLAY.translation[2]) / 16,
        (tonumber(translation[3]) or DEFAULT_DISPLAY.translation[3]) / 16
    )

    local rotation = display.rotation or DEFAULT_DISPLAY.rotation
    rotateX(tonumber(rotation[1]) or DEFAULT_DISPLAY.rotation[1])
    rotateY(tonumber(rotation[2]) or DEFAULT_DISPLAY.rotation[2])
    rotateZ(tonumber(rotation[3]) or DEFAULT_DISPLAY.rotation[3])

    local scale = display.scale or DEFAULT_DISPLAY.scale
    local scaleX = tonumber(scale[1]) or DEFAULT_DISPLAY.scale[1]
    local scaleY = tonumber(scale[2]) or DEFAULT_DISPLAY.scale[2]
    local scaleZ = tonumber(scale[3]) or DEFAULT_DISPLAY.scale[3]
    basisX = basisX * scaleX
    basisY = basisY * scaleY
    basisZ = basisZ * scaleZ
    translate(-0.5, -0.5, -0.5)

    local function cameraVector(value)
        return angles:Right() * value.x
            + angles:Up() * value.y
            + angles:Forward() * -value.z
    end

    position = position + cameraVector(origin) * unitScale

    -- At draw time ShieldModel G is L = (G.z, G.x, G.y) in MDL-local space.
    -- Vanilla's A = (1, -1, -1) therefore maps those local axes to:
    --   L.x -> -basisZ, L.y -> +basisX, L.z -> -basisY.
    -- Source's entity local +Y is Angle:Left (= -Angle:Right).
    local pose = Matrix()
    pose:SetForward(cameraVector(basisZ):GetNormalized() * -1)
    pose:SetRight(cameraVector(basisX):GetNormalized() * -1)
    pose:SetUp(cameraVector(basisY):GetNormalized() * -1)

    return position, pose:GetAngles(), Vector(scaleZ, scaleX, scaleY)
end

-- ItemUseAnimation.EAT / DRINK: ItemInHandRenderer.applyEatTransform followed by
-- applyItemArmTransform.  Unlike WHACK, the consume transform happens before the
-- hand anchor, so the calibrated Source anchor is supplied separately and added
-- in the already-rotated frame.
function Render.ApplyConsumeTransform(
    position,
    angles,
    timeHeld,
    durationTicks,
    equip,
    side,
    unitScale,
    anchorForward,
    anchorRight,
    anchorUp
)
    durationTicks = math.max(tonumber(durationTicks) or 1, 1)
    timeHeld = math.max(tonumber(timeHeld) or 0, 0)

    local function translate(x, y, z)
        position = position + Render.CameraOffset(angles, x, y, z, unitScale)
    end

    local function rotate(axis, degrees)
        if axis == "x" then
            angles:RotateAroundAxis(angles:Right(), degrees)
        elseif axis == "y" then
            angles:RotateAroundAxis(angles:Up(), degrees)
        else
            angles:RotateAroundAxis(angles:Forward(), -degrees)
        end
    end

    -- f = remainingTicks - partialTick + 1.  Continuous timeHeld is exactly
    -- (duration - remainingTicks + partialTick), so the expressions collapse.
    local remainingWithPartial = durationTicks - timeHeld + 1
    local remainingFraction = remainingWithPartial / durationTicks

    if remainingFraction < 0.8 then
        translate(0, math.abs(math.cos(remainingWithPartial / 4 * math.pi) * 0.1), 0)
    end

    local amount = 1 - math.pow(remainingFraction, 27)
    translate(side * amount * 0.6, amount * -0.5, 0)
    rotate("y", side * amount * 90)
    rotate("x", amount * 10)
    rotate("z", side * amount * 30)

    -- applyItemArmTransform is after applyEatTransform in Mojang's branch.
    position = position
        + angles:Forward() * (tonumber(anchorForward) or 0)
        + angles:Right() * (tonumber(anchorRight) or 0)
        + angles:Up() * (tonumber(anchorUp) or 0)
    translate(0, (tonumber(equip) or 0) * -0.6, 0)

    return position, angles
end

-- SwingAnimationType.STAB：SpearAnimations.firstPersonAttack。
function Render.ApplyStabTransform(position, angles, swing, equip, side, unitScale, pivotScale, display)
    local function translate(x, y, z)
        position = position + Render.CameraOffset(angles, x, y, z, unitScale)
    end

    local function rotateX(degrees)
        angles:RotateAroundAxis(angles:Right(), degrees)
    end

    translate(0, equip * -0.6, 0)

    local startingAmount = easeInOutSine(progress(swing, 0, 0.05))
    local middleAmount = easeOutBack(progress(swing, 0.05, 0.2))
    local endingAmount = easeInOutExpo(progress(swing, 0.4, 1))

    translate(
        side * 0.1 * (startingAmount - middleAmount),
        -0.075 * (startingAmount - endingAmount),
        0.65 * (startingAmount - middleAmount)
    )
    rotateX(-70 * (startingAmount - endingAmount))
    translate(0, 0, -0.25 * (endingAmount - middleAmount))

    position = position + Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
    return position, angles
end

-- ItemInHandRenderer's BOW/CROSSBOW branches. The caller supplies the already calibrated
-- idle anchor, just like ApplyWhackTransform; this function applies the exact MC translations
-- and rotation order around the same hand pivot. `timeHeld` is measured in MC ticks.
--
-- 返回值多两个：`stretch`（= MC 的 `poseStack.scale(1, 1, 1 + power * 0.2)`）和它作用的
-- **世界方向**。那句 scale 是在弓自己那三次旋转之后、`Axis.YN(45)` 和 display 之前
-- 右乘进去的，所以拉伸轴是**当时那一帧的 MC +Z**，不是相机深度轴，也不是模型局部轴 ——
-- 要么在正确的时刻把轴记下来，要么就会拉错方向。调用方拿它去拼 RenderMultiply。
-- `drawScale`   只乘"随蓄力后拉"的那一段位移（MC：弓/弩 0.04 格、三叉戟 0.2 格）。
-- `stretchScale` 只乘 `scale(1, 1, 1 + power * 0.2)` 那个**深度拉伸**。
-- ⚠ 这两个以前是同一个 convar。想把三叉戟的后举调明显一点就得调大 draw，结果连拉伸
-- 一起放大 —— 模型沿深度轴被拽长，看起来就是"三叉戟被拉扁了"。拆开之后
-- `mcitem_use_trident_draw` 只管往后拉多少，`mcitem_use_trident_stretch` 才动形变。
function Render.ApplyRangedUseTransform(position, angles, kind, timeHeld, chargeTicks, equip, side, unitScale, pivotScale, display, drawScale, stretchScale)
    drawScale = tonumber(drawScale) or 1
    stretchScale = tonumber(stretchScale) or 1
    -- MC 的那一下微抖幅度只有 0.004 格（蓄满时约 0.0036），原版几乎看不出来；
    -- `mcitem_draw_shake` 只是个手动倍率，1 = 原版。真正让人觉得"拉弓在抖"的是
    -- FOV 平滑被两套时钟推的那个 bug，已经在 sh_use_effects.lua 里修掉。
    local shakeScale = isfunction(MCITEM.DrawShakeScale) and MCITEM.DrawShakeScale() or 1
    local function translate(x, y, z)
        position = position + Render.CameraOffset(angles, x, y, z, unitScale)
    end

    local function rotate(axis, degrees)
        if axis == "x" then
            angles:RotateAroundAxis(angles:Right(), degrees)
        elseif axis == "y" then
            angles:RotateAroundAxis(angles:Up(), degrees)
        else
            angles:RotateAroundAxis(angles:Forward(), -degrees)
        end
    end

    translate(0, equip * -0.6, 0)

    local power = 0

    if kind == "bow" then
        translate(side * -0.2785682, 0.18344387, 0.15731531)
        rotate("x", -13.935)
        rotate("y", side * 35.3)
        rotate("z", side * -9.785)

        power = math.max(timeHeld, 0) / 20
        power = (power * power + power * 2) / 3
        power = math.min(power, 1)

        if power > 0.1 then
            local shake = math.sin((timeHeld - 0.1) * 1.3) * (power - 0.1)
            translate(0, shake * 0.004 * shakeScale, 0)
        end

        translate(0, 0, power * 0.04 * drawScale)
    elseif kind == "crossbow" then
        translate(side * -0.4785682, -0.094387, 0.05731531)
        rotate("x", -11.935)
        rotate("y", side * 65.3)
        rotate("z", side * -9.785)

        power = math.Clamp(math.max(timeHeld, 0) / math.max(chargeTicks or 25, 1), 0, 1)
        if power > 0.1 then
            local shake = math.sin((timeHeld - 0.1) * 1.3) * (power - 0.1)
            translate(0, shake * 0.004 * shakeScale, 0)
        end

        translate(0, 0, power * 0.04 * drawScale)
    elseif kind == "trident" then
        translate(side * -0.5, 0.7, 0.1)
        rotate("x", -55)
        rotate("y", side * 35.3)
        rotate("z", side * -9.785)

        power = math.Clamp(math.max(timeHeld, 0) / 10, 0, 1)
        if power > 0.1 then
            local shake = math.sin((timeHeld - 0.1) * 1.3) * (power - 0.1)
            translate(0, shake * 0.004 * shakeScale, 0)
        end

        translate(0, 0, power * 0.2 * drawScale)
    else
        position = position + Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
        return position, angles, 1, nil
    end

    -- `poseStack.scale(1, 1, 1 + power * 0.2)`：三支分岔（BOW / CROSSBOW / TRIDENT）都有，
    -- 三支都紧接着 `Axis.YN.rotationDegrees(invert * 45)`。MC 的 +Z 朝向观察者，
    -- 对应 Source 的 -Forward。
    local stretch = 1 + power * 0.2 * stretchScale
    local stretchAxis = -angles:Forward()

    rotate("y", side * -45)

    -- scale 是右乘进去的，所以 display 的位移也在被拉伸的空间里。
    local displayOffset = Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
    position = position + displayOffset
        + stretchAxis * ((stretch - 1) * displayOffset:Dot(stretchAxis))

    return position, angles, stretch, stretchAxis
end

-- 把"沿世界方向 `axis` 拉伸 `factor` 倍"表达成一个**模型局部空间**的矩阵，供
-- `EnableMatrix("RenderMultiply", ...)` 用（RenderMultiply 作用在模型局部坐标上，
-- 而我们要的拉伸定义在世界方向上）。
--
--   世界:  S = I + (factor - 1) * d ⊗ d          d = 单位世界方向
--   局部:  M = R⁻¹ S R = I + (factor - 1) * dl ⊗ dl,  dl = d 在模型局部基下的分量
--
-- Source 的模型局部基是 (x = Forward, y = Left = -Right, z = Up)。
function Render.WorldStretchMatrix(entityAngles, axis, factor)
    local matrix = Matrix()
    if not axis or math.abs(factor - 1) < 1e-6 then return matrix end

    local local_ = Vector(
        axis:Dot(entityAngles:Forward()),
        axis:Dot(-entityAngles:Right()),
        axis:Dot(entityAngles:Up())
    )

    local gain = factor - 1
    for row = 1, 3 do
        for column = 1, 3 do
            local identity = row == column and 1 or 0
            matrix:SetField(row, column, identity + gain * local_[row] * local_[column])
        end
    end
    return matrix
end

-- Source keeps the viewmodel's vertical framing while widening its horizontal
-- projection for widescreen.  Anchors tuned at 4:3 therefore move toward the
-- centre at 16:9/ultrawide.  Scale only the camera-right component by the
-- aspect-ratio change so the same anchor lands at the same normalized screen X.
-- Depth and vertical placement stay untouched, and 4:3 is an exact no-op.
function Render.LockHandAspect(position, eyePos, eyeAngles, viewportWidth, viewportHeight, referenceAspect)
    viewportWidth = tonumber(viewportWidth) or 0
    viewportHeight = tonumber(viewportHeight) or 0
    referenceAspect = tonumber(referenceAspect) or (4 / 3)
    if viewportWidth <= 0 or viewportHeight <= 0 or referenceAspect <= 0 then return position, 1 end

    local ratio = (viewportWidth / viewportHeight) / referenceAspect
    if math.abs(ratio - 1) < 1e-4 then return position, 1 end

    local offset = position - eyePos
    local forward, right, up = eyeAngles:Forward(), eyeAngles:Right(), eyeAngles:Up()
    local corrected = eyePos
        + forward * offset:Dot(forward)
        + right * (offset:Dot(right) * ratio)
        + up * offset:Dot(up)

    return corrected, ratio
end

-- MC 的手是用 **hudFov** 画的，而 `Camera.calculateHudFov` 是写死的 70：
--     private float calculateHudFov(float partialTicks) {
--         return this.modifyFovBasedOnDeathOrFluid(partialTicks, 70.0f);
--     }
-- 也就是说 `fovModifier`（拉弓那 0.85、冲刺、速度效果）**只作用于世界**，手里的弓
-- 一点都不会跟着变大。GMod 这边物品是我们自己按世界坐标摆的模型，世界 FOV 一收它
-- 就跟着放大 1/0.85 ≈ 17.6%；而 modifier 是 `1 - (t/20)² * 0.15` 的**平方**曲线，
-- 所以前半段几乎看不出来、拉满突然变大 —— 这就是"没蓄满对得上、蓄满对不上"。
--
-- 屏幕尺寸 ∝ (size / depth) / tan(fov/2)。把相机空间的**横向**偏移和模型尺寸同乘
-- r = tan(fovModified/2) / tan(fovBase/2)、深度分量保持不变，屏幕位置和大小就都不变。
function Render.LockHandFov(position, eyePos, eyeAngles, fovBase, fovModified)
    if not fovBase or fovBase <= 0 or not fovModified or fovModified <= 0 then return position, 1 end
    if math.abs(fovModified - fovBase) < 1e-4 then return position, 1 end

    local ratio = math.tan(math.rad(fovModified) * 0.5) / math.tan(math.rad(fovBase) * 0.5)

    local offset = position - eyePos
    local forward, right, up = eyeAngles:Forward(), eyeAngles:Right(), eyeAngles:Up()
    local depth = offset:Dot(forward)

    local corrected = eyePos + forward * depth
        + right * (offset:Dot(right) * ratio)
        + up * (offset:Dot(up) * ratio)

    return corrected, ratio
end

-- ItemInHandRenderer 的弩分支，**装填之外**那一半：
--     } else {
--         this.swingArm(attack, poseStack, invert, arm);
--         if (charged && attack < 0.001f && isMainHand) {
--             poseStack.translate(invert * -0.641864f, 0.0f, 0.0f);
--             poseStack.mulPose(Axis.YP.rotationDegrees(invert * 10.0f));
--         }
--     }
-- 注意它是接在 `swingArm(attack)` **后面**的补丁，不是替代品：上好弦的弩照样挥手、
-- 照样挖方块，只是站着不动（attack < 0.001）时把弩往左挪一点、转 10°。
-- 早先把这一段当成一个独立的"use 姿势"返回，等于把挥动整段吞掉了。
function Render.ApplyCrossbowChargedIdle(translate, rotate, side, swing)
    if swing >= 0.001 then return end
    translate(side * -0.641864, 0, 0)
    rotate("y", side * 10)
end

local function spearUseParams(data, timeHeld)
    local finishRaisingTick = math.max(data.delayTicks or 0, 0)
    local finishSwayingTick = math.max(data.dismountDurationTicks or 0, 0) + finishRaisingTick
    local startSwayingTick = finishSwayingTick - 20
    local finishLoweringTick = math.max(data.knockbackDurationTicks or 0, 0) + finishRaisingTick
    local startLoweringTick = finishLoweringTick - 40
    local finishRaisingBackTick = math.max(data.damageDurationTicks or 0, 0) + finishRaisingTick

    local raiseProgress = progress(timeHeld, 0, finishRaisingTick)
    local swayProgress = progress(timeHeld, startSwayingTick, finishSwayingTick)
    local raiseBackProgress = progress(timeHeld, finishRaisingBackTick - 5, finishRaisingBackTick)
    local lowerProgress = easeOutCubic(easeInOutElastic(
        progress(timeHeld - 20, startLoweringTick, finishLoweringTick)
    ))
    local swayIntensity = 2 * easeOutCirc(swayProgress) - 2 * easeInCirc(raiseBackProgress)

    return {
        raiseProgress = raiseProgress,
        raiseProgressStart = progress(raiseProgress, 0, 0.5),
        raiseProgressMiddle = progress(raiseProgress, 0.5, 0.8),
        raiseProgressEnd = progress(raiseProgress, 0.8, 1),
        swayProgress = swayProgress,
        lowerProgress = lowerProgress,
        raiseBackProgress = raiseBackProgress,
        swayIntensity = swayIntensity,
        swayScaleSlow = math.sin(timeHeld * 19 * math.pi / 180) * swayIntensity,
        swayScaleFast = math.sin(timeHeld * 30 * math.pi / 180) * swayIntensity,
    }
end

local function spearHitFeedbackAmount(ticksSinceFeedbackStart)
    return 0.4 * (
        easeOutQuart(progress(ticksSinceFeedbackStart, 1, 3))
        - easeInOutSine(progress(ticksSinceFeedbackStart, 3, 10))
    )
end

-- ItemUseAnimation.SPEAR：SpearAnimations.firstPersonUse。和弓/三叉戟不同，原版
-- 这一支自己写静止手位，不套 equippedProgress；rotateAround 的两个轴心也逐项保留。
function Render.ApplySpearUseTransform(position, angles, timeHeld, side, unitScale, pivotScale, display, data)
    data = data or {}
    local params = spearUseParams(data, math.max(timeHeld or 0, 0))

    local function translate(x, y, z)
        position = position + Render.CameraOffset(angles, x, y, z, unitScale)
    end

    local function rotate(axis, degrees)
        if axis == "x" then
            angles:RotateAroundAxis(angles:Right(), degrees)
        elseif axis == "y" then
            angles:RotateAroundAxis(angles:Up(), degrees)
        else
            angles:RotateAroundAxis(angles:Forward(), -degrees)
        end
    end

    local function rotateAround(axis, degrees, pivotX, pivotY, pivotZ)
        local pivot = position + Render.CameraOffset(angles, pivotX, pivotY, pivotZ, unitScale)
        rotate(axis, degrees)
        position = pivot - Render.CameraOffset(angles, pivotX, pivotY, pivotZ, unitScale)
    end

    translate(
        side * (params.raiseProgress * 0.15 + params.raiseProgressEnd * -0.05
            + params.swayProgress * -0.1 + params.swayScaleSlow * 0.005),
        params.raiseProgress * -0.075 + params.raiseProgressMiddle * 0.075
            + params.swayScaleFast * 0.01,
        params.raiseProgressStart * 0.05 + params.raiseProgressEnd * -0.05
            + params.swayScaleSlow * 0.005
    )

    rotateAround(
        "x",
        -65 * easeInOutBack(params.raiseProgress) - 35 * params.lowerProgress
            + 100 * params.raiseBackProgress - 0.5 * params.swayScaleFast,
        0,
        0.1,
        0
    )

    -- Axis.YN.rotationDegrees(a) 等于绕 +Y 旋转 -a。
    local yNegativeDegrees = side * (
        -90 * progress(params.raiseProgress, 0.5, 0.55)
        + 90 * params.swayProgress
        + 2 * params.swayScaleSlow
    )
    rotateAround("y", -yNegativeDegrees, side * 0.15, 0, 0)

    translate(0, -spearHitFeedbackAmount(data.hitFeedbackTicks or 1000), 0)

    position = position + Render.FirstPersonDisplayOffset(angles, unitScale, pivotScale, display)
    return position, angles
end

--------------------------------------------------------------------------------
-- 走路晃动 / 转头滞后（在锚点之前叠加）
--------------------------------------------------------------------------------

-- GameRenderer.bobView(camera, poseStack)。
-- MC 会把它**同时**应用在相机和手上（renderItemInHand 里再调一次），所以走路时
-- 物品相对屏幕也在晃。这里只做手的那一份，相机交给 GMod 自己的视角摇晃。
--   walkPhase = -(walkDist + (walkDist - walkDistO) * partialTick)   ← 注意取负
--   bobAmount = lerp(partialTick, bobO, bob)
function Render.ApplyViewBob(position, angles, walkPhase, bobAmount, unitScale, scale)
    scale = scale or 1
    if scale <= 0 or bobAmount <= 0 then return position, angles end

    local amount = bobAmount * scale
    local sinPhase = math.sin(walkPhase * math.pi)
    local cosPhase = math.cos(walkPhase * math.pi)

    position = position + Render.CameraOffset(
        angles,
        sinPhase * amount * 0.5,
        -math.abs(cosPhase * amount),
        0,
        unitScale
    )

    -- MC 的 +Z 朝向观察者，和 Source 的 Forward 反向（同 ApplyWhackTransform 的 rotate("z")）。
    angles:RotateAroundAxis(angles:Forward(), -(sinPhase * amount * 3))
    angles:RotateAroundAxis(angles:Right(), math.abs(math.cos(walkPhase * math.pi - 0.2) * amount) * 5)

    return position, angles
end

-- submitHandsWithItems 开头那两下：物品朝向落后于视角，转头时会甩一下。
-- 角度已经由 MCITEM.GetViewSway 算好（度）。
function Render.ApplyViewSway(angles, pitchOffset, yawOffset, scale)
    scale = scale or 1
    if scale <= 0 then return angles end

    angles:RotateAroundAxis(angles:Right(), pitchOffset * scale)
    angles:RotateAroundAxis(angles:Up(), yawOffset * scale)
    return angles
end

return Render
