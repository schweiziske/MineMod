include("shared.lua")
include("mcitem/cl_combat_particles.lua")

--------------------------------------------------------------------------------
-- 满蓄力箭的暴击尾迹（AbstractArrow.tick）
--------------------------------------------------------------------------------
--
-- ⚠ 这一段**必须在客户端发**（2026-08-12 修）。原来是服务端每 tick 用真实位置
-- `net.SendPVS` 一发粒子：粒子在客户端立刻按那个坐标出现，而箭本身是普通的网络实体、
-- 要经过 `cl_interp`（默认 0.1s）的插值缓冲才画出来。于是粒子恒定领先箭约 2 个 tick，
-- 满蓄力箭 3 格/tick 就是**领先 6 格** —— 用户报的"粒子比箭快太多"。
--
-- MC 里 `AbstractArrow.tick()` 在客户端也跑，粒子就是从客户端那个（插值过的）箭身上
-- 发出来的。这里照同样的做法：每 20Hz 取一次箭的**渲染位置**，用这一 tick 真实走过的
-- 那一段当 movement 喂给 `EmitArrowCritical`。粒子和箭从此共用同一条时间轴，
-- 剩下的"粒子比箭略快"就是 MC 自己那 4 个沿段铺开的采样点。
local CRIT_TICK_SECONDS = 1 / 20
local spectralArrowMaterial = Material("models/mcmodelpack/arrow_spectral")

local function emitSpectralParticle(position)
    local potions = MCITEM.Potions
    if not potions or not isfunction(potions.SpawnSpellParticle) then return end
    -- SpectralArrow.tick: ParticleTypes.EFFECT, color -1 (white), power 1,
    -- zero input velocity at the arrow's current client-side position.
    potions.SpawnSpellParticle(position, {
        family = "effect",
        inputX = 0,
        inputY = 0,
        inputZ = 0,
        power = 1,
        r = 1,
        g = 1,
        b = 1,
        alpha = 1,
    })
end

function ENT:Initialize()
    self.MCCritLastPos = self:GetPos()
    self.MCCritNextTick = CurTime() + CRIT_TICK_SECONDS
    self.MCSpectralNextTick = CurTime() + CRIT_TICK_SECONDS
    self:SetNextClientThink(CurTime())
end

function ENT:Think()
    local now = CurTime()

    if self:GetCritical() and not self:GetInGround() then
        local position = self:GetPos()
        if not self.MCCritLastPos then
            self.MCCritLastPos = position
            self.MCCritNextTick = now + CRIT_TICK_SECONDS
        elseif now >= (self.MCCritNextTick or 0) then
            local movement = (position - self.MCCritLastPos) / MCITEM.BlockSize()
            local particles = MCITEM.CombatParticles
            if movement:LengthSqr() > 1e-8 and particles and isfunction(particles.EmitArrowCritical) then
                particles.EmitArrowCritical(self.MCCritLastPos, movement)
            end
            self.MCCritLastPos = position
            -- 掉帧 / 切场景之后不要补发上百 tick 的尾迹。
            self.MCCritNextTick = math.max(self.MCCritNextTick + CRIT_TICK_SECONDS, now)
        end
    else
        self.MCCritLastPos = self:GetPos()
        self.MCCritNextTick = now + CRIT_TICK_SECONDS
    end

    if self:GetSpectralArrow() and not self:GetInGround() then
        if now >= (self.MCSpectralNextTick or 0) then
            emitSpectralParticle(self:GetPos())
            self.MCSpectralNextTick = math.max(
                (self.MCSpectralNextTick or now) + CRIT_TICK_SECONDS,
                now)
        end
    else
        self.MCSpectralNextTick = now + CRIT_TICK_SECONDS
    end

    self:SetNextClientThink(now)
    return true
end

-- 朝向由服务端每 tick 用 `Projectile.lerpRotation`（每 tick 走 20%）算好并同步，
-- 客户端只做插值渲染 —— 和 MC 一样（那边也是 tick 更新 + partialTick 插值）。
-- 早先客户端自己按当前速度硬算朝向，既绕过了平滑，��用了裸 `velocity:Angle()`
-- （只对齐 +X），长轴不在 +X 的三叉戟就会"一路直立着飞"。

-- 插住之后要接管两件事：
--   ① 位置：GMod 会插值实体原点，而插住那一下位置是**跳变**的（沿飞行方向回收一整个
--      尖端距离，三叉戟是 62u）。插值出来就是"先陷进方块里、再被拉出来"。
--      服务端把最终落点单独同步过来，这里直接按它画。
--   ② 采光：trident_3d 老模型的 studiohdr illumposition 被编译成了本地 Z=1040.82u
--      （真实 hull 只有 -7.12..64.15u）。矛头朝下时该点会旋进地底，整把直接变黑。
--      render.SetLightingOrigin 在实体 DrawModel 这条路径上没有可靠覆盖这个缓存点；改为
--      显式采样 MineMod 体素光（无 MineMod 时用 Source lightmap），关掉引擎模型光后乘上去。
local cvLightOffset = CreateClientConVar("mcitem_projectile_light_offset", "0.5", true, false,
    "How far along the surface normal a stuck arrow/trident samples world lighting, in blocks. 0 = geometry center.")

local LIGHT_SAMPLE_INTERVAL = 0.10

local function clamp01(value)
    return math.Clamp(tonumber(value) or 1, 0, 1)
end

-- MC.API.Light.* 是 v1 入口；后一个名字兼容早期 MineMod。
local function mcLightFn(name, fallbackName)
    if not MC then return nil end
    if istable(MC.API) and istable(MC.API.Light) and isfunction(MC.API.Light[name]) then
        return MC.API.Light[name]
    end
    return isfunction(MC[fallbackName]) and MC[fallbackName] or nil
end

local function sampleProjectileLight(position)
    local sampleRGB = mcLightFn("SampleRGB", "SampleDynamicLightingRGB")
    if sampleRGB then
        local ok, r, g, b = pcall(sampleRGB, position, 0)
        if ok and r ~= nil and g ~= nil and b ~= nil then
            local gain = 0.48
            if MC.EntityLightingGain then gain = MC.EntityLightingGain:GetFloat() end
            -- [BMB 2026-11-09] unit gain while the draw runs at tone scale 1
            if isfunction(MC.EntityExposureGain) then gain = MC.EntityExposureGain(gain) end

            local scaleRGB = mcLightFn("ScaleRGB", "ScaleDynamicLightingRGB")
            if scaleRGB then
                local scaled, sr, sg, sb = pcall(scaleRGB, r, g, b, math.max(gain, 0))
                if scaled and sr ~= nil and sg ~= nil and sb ~= nil then
                    return clamp01(sr), clamp01(sg), clamp01(sb)
                end
            end

            return clamp01(r * gain), clamp01(g * gain), clamp01(b * gain)
        end
    end

    -- 独立安装 MCITEM、没有 MineMod 体素世界时，仍然按当前 Source 地图取光。
    if render.GetLightColor then
        local light = render.GetLightColor(position)
        if isvector(light) then return clamp01(light.x), clamp01(light.y), clamp01(light.z) end
    end

    return nil
end

local function projectileGeometryCenter(entity, renderOrigin)
    local mins, maxs = entity:OBBMins(), entity:OBBMaxs()
    local localCenter = (mins + maxs) * 0.5
    -- LocalToWorld 用实体逻辑原点；插地时 Draw 可能用 StickOrigin 绕开网络位置插值，
    -- 所以把同一差值补到采样点上。
    return entity:LocalToWorld(localCenter) + (renderOrigin - entity:GetPos())
end

local function getProjectileLight(entity, samplePosition)
    local now = CurTime()
    local state = entity.MCProjectileLight

    if not state or now >= (state.nextSample or 0) then
        local r, g, b = sampleProjectileLight(samplePosition)
        if r ~= nil then
            if not state then
                state = { r = r, g = g, b = b, lastUpdate = now }
                entity.MCProjectileLight = state
            end
            state.targetR, state.targetG, state.targetB = r, g, b
        end
        if state then state.nextSample = now + LIGHT_SAMPLE_INTERVAL end
    end

    if not state then return nil end

    local dt = math.Clamp(now - (state.lastUpdate or now), 0, 0.1)
    state.lastUpdate = now
    local blend = 1 - math.exp(-dt * 12)
    state.r = Lerp(blend, state.r, state.targetR or state.r)
    state.g = Lerp(blend, state.g, state.targetG or state.g)
    state.b = Lerp(blend, state.b, state.targetB or state.b)
    return state.r, state.g, state.b
end

function ENT:Draw()
    local inGround = self:GetInGround()
    local origin = self:GetPos()
    local normal = nil

    if inGround then
        local rest = self:GetStickOrigin()
        if isvector(rest) and rest:LengthSqr() > 0 then
            origin = rest
            self:SetRenderOrigin(rest)
        end
        normal = self:GetStickNormal()
    end

    local samplePosition = projectileGeometryCenter(self, origin)
    if inGround then
        if not isvector(normal) or normal:LengthSqr() < 1e-6 then normal = Vector(0, 0, 1) end
        samplePosition = samplePosition
            + normal:GetNormalized() * (cvLightOffset:GetFloat() * MCITEM.BlockSize())
    end

    local r, g, b = getProjectileLight(self, samplePosition)
    if r ~= nil then
        render.SuppressEngineLighting(true)
        render.SetColorModulation(r, g, b)
    end

    local materialOverride = self:GetSpectralArrow() and spectralArrowMaterial or nil
    if materialOverride then render.MaterialOverride(materialOverride) end
    if r ~= nil and MC and MC.BeginEntityUnitExposure then MC.BeginEntityUnitExposure() end -- [BMB 2026-11-09]
    local ok, err = pcall(self.DrawModel, self)
    if r ~= nil and MC and MC.EndEntityUnitExposure then MC.EndEntityUnitExposure() end
    if materialOverride then render.MaterialOverride() end

    if r ~= nil then
        render.SetColorModulation(1, 1, 1)
        render.SuppressEngineLighting(false)
    end
    self:SetRenderOrigin()

    if not ok then
        ErrorNoHalt("[MCITEM] projectile draw failed: " .. tostring(err) .. "\n")
    end
end
