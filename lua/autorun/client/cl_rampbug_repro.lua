--------------------------------------------------------------------------
-- rampbug deterministic reproducer (standalone, clientside)
--
-- 用法:
--   1. 站在坡缝附近, 瞄准接缝一侧地面, 输入 rampbug_mark  (设 A 点)
--   2. 瞄准接缝另一侧地面, 再输入 rampbug_mark            (设 B 点)
--   3. rampbug_scan [steps=400]
--        沿 A->B 每步做一次向下 hull trace + 向下 ray trace,
--        hull 法线不可行走(z<0.7) 而 ray 法线可行走 => 伪平面, 标红
--   4. rampbug_fly [minspeed=300] [maxspeed=3000] [speedstep=50]
--        以 A 为起点沿 A->B 方向, 逐档速度跑简化版引擎移动模拟
--        (hull sweep + ClipVelocity), 记录每次命中的平面法线;
--        水平入射却被 clip 出显著垂直速度 => 弹射复现, 标红
--   5. rampbug_clear  清除标记与叠加显示
--
-- 输出: 控制台摘要 + data/rampbug/scan.csv / fly.csv
-- 判定完全确定性: 起点量化到 1/32 格, 固定步长, 无随机数
--------------------------------------------------------------------------

local HULL_MINS = Vector(-16, -16, 0)
local HULL_MAXS = Vector(16, 16, 72)
local WALKABLE_Z = 0.7          -- 引擎可行走坡度阈值
local TRACE_MASK = MASK_PLAYERSOLID_BRUSHONLY

local ptA, ptB
local marks = {}   -- 可视化: {pos=, pos2=, color=, cross=}

local function Quantize(v)
	-- 1/32 网格对齐, 保证复现确定性
	return Vector(
		math.Round(v.x * 32) / 32,
		math.Round(v.y * 32) / 32,
		math.Round(v.z * 32) / 32)
end

local function HullDown(pos, dist)
	return util.TraceHull({
		start = pos, endpos = pos - Vector(0, 0, dist),
		mins = HULL_MINS, maxs = HULL_MAXS, mask = TRACE_MASK,
	})
end

local function RayDown(pos, dist)
	return util.TraceLine({
		start = pos, endpos = pos - Vector(0, 0, dist),
		mask = TRACE_MASK,
	})
end

-- 复刻 CGameMovement::ClipVelocity (overbounce = 1)
local function ClipVelocity(vel, normal)
	local backoff = vel:Dot(normal)
	local out = vel - normal * backoff
	local adjust = out:Dot(normal)
	if adjust < 0 then
		out = out - normal * adjust
	end
	return out
end

local function AddMark(pos, color, pos2)
	marks[#marks + 1] = { pos = pos, pos2 = pos2, color = color }
end

local function WriteCSV(name, lines)
	file.CreateDir("rampbug")
	file.Write("rampbug/" .. name, table.concat(lines, "\n"))
	print(("[rampbug] 已写入 data/rampbug/%s (%d 行)"):format(name, #lines - 1))
end

local function FmtVec(v)
	return ("%.4f,%.4f,%.4f"):format(v.x, v.y, v.z)
end

--------------------------------------------------------------------------
-- rampbug_mark
--------------------------------------------------------------------------
concommand.Add("rampbug_mark", function(ply)
	local tr = ply:GetEyeTrace()
	if not tr.Hit then print("[rampbug] 没有瞄准任何表面") return end
	local p = Quantize(tr.HitPos)
	if not ptA or (ptA and ptB) then
		ptA, ptB = p, nil
		print(("[rampbug] A = %s  (再瞄准另一侧输入一次设 B)"):format(tostring(p)))
	else
		ptB = p
		print(("[rampbug] B = %s  线段长度 %.1f, 可以 rampbug_scan / rampbug_fly")
			:format(tostring(p), ptA:Distance(ptB)))
	end
end)

concommand.Add("rampbug_clear", function()
	ptA, ptB, marks = nil, nil, {}
	print("[rampbug] 已清除")
end)

--------------------------------------------------------------------------
-- rampbug_scan: 静态法线扫描
--------------------------------------------------------------------------
concommand.Add("rampbug_scan", function(_, _, args)
	if not (ptA and ptB) then print("[rampbug] 先用 rampbug_mark 设 A/B") return end
	local steps = math.max(2, tonumber(args[1]) or 400)
	marks = {}

	local csv = { "i,x,y,z,hull_nx,hull_ny,hull_nz,ray_nx,ray_ny,ray_nz,angle_deg,hull_frac,anomaly" }
	local anomalies = 0

	for i = 0, steps do
		local t = i / steps
		-- 抬高 64 起测, 保证 hull/ray 都从空中落到地面
		local pos = Quantize(LerpVector(t, ptA, ptB)) + Vector(0, 0, 64)
		local h = HullDown(pos, 256)
		local r = RayDown(pos, 256 + 64)
		if h.Hit and r.Hit and not h.StartSolid then
			local hn, rn = h.HitNormal, r.HitNormal
			local ang = math.deg(math.acos(math.Clamp(hn:Dot(rn), -1, 1)))
			-- 判据: hull 说不可行走 / ray 说可行走, 或法线夹角离谱
			local bad = (hn.z < WALKABLE_Z and rn.z >= WALKABLE_Z) or ang > 20
			if bad then
				anomalies = anomalies + 1
				AddMark(h.HitPos, Color(255, 40, 40), h.HitPos + hn * 24)
				AddMark(r.HitPos, Color(40, 120, 255), r.HitPos + rn * 24)
			else
				AddMark(h.HitPos, Color(40, 255, 40))
			end
			csv[#csv + 1] = ("%d,%s,%s,%s,%.2f,%.4f,%d")
				:format(i, FmtVec(h.HitPos), FmtVec(hn), FmtVec(rn), ang, h.Fraction, bad and 1 or 0)
		end
	end

	print(("[rampbug] scan 完成: %d 步, %d 处伪平面 (红=hull伪法线 蓝=ray真实法线)")
		:format(steps, anomalies))
	WriteCSV("scan.csv", csv)
end)

--------------------------------------------------------------------------
-- rampbug_fly: 移动模拟弹射复现
--------------------------------------------------------------------------
concommand.Add("rampbug_fly", function(_, _, args)
	if not (ptA and ptB) then print("[rampbug] 先用 rampbug_mark 设 A/B") return end
	local minS = tonumber(args[1]) or 300
	local maxS = tonumber(args[2]) or 3000
	local stepS = math.max(1, tonumber(args[3]) or 50)
	marks = {}

	local dt = engine.TickInterval()
	local gravity = GetConVar("sv_gravity") and GetConVar("sv_gravity"):GetFloat() or 600
	local dir = (ptB - ptA):GetNormalized()
	local flatDir = Vector(dir.x, dir.y, 0):GetNormalized()
	local maxTicks = 400

	local csv = { "speed,tick,x,y,z,plane_nx,plane_ny,plane_nz,vz_before,vz_after,launch" }
	local launches = 0

	for speed = minS, maxS, stepS do
		-- 起点: A 点上方 2 单位 (贴地但不 startsolid), 纯水平初速
		local pos = Quantize(ptA) + Vector(0, 0, 2)
		local vel = flatDir * speed
		local worstLaunch = 0

		for tick = 1, maxTicks do
			vel.z = vel.z - gravity * dt
			local dest = pos + vel * dt
			local tr = util.TraceHull({
				start = pos, endpos = dest,
				mins = HULL_MINS, maxs = HULL_MAXS, mask = TRACE_MASK,
			})
			pos = tr.HitPos

			if tr.Hit and not tr.StartSolid then
				local n = tr.HitNormal
				local vzBefore = vel.z
				vel = ClipVelocity(vel, n)
				-- 弹射判据: clip 前几乎贴地飞行, clip 后获得显著垂直速度
				local launched = vzBefore > -80 and vel.z > 100
				if launched then
					launches = launches + 1
					worstLaunch = math.max(worstLaunch, vel.z)
					AddMark(pos, Color(255, 40, 40), pos + n * 32)
				end
				csv[#csv + 1] = ("%d,%d,%s,%s,%.1f,%.1f,%d")
					:format(speed, tick, FmtVec(pos), FmtVec(n), vzBefore, vel.z, launched and 1 or 0)
			end

			-- 越过 B 点或水平速度耗尽则结束该档
			if (pos - ptA):Dot(flatDir) > ptA:Distance(ptB) + 64 then break end
			if vel:Length2D() < 10 then break end
			if pos.z < ptA.z - 512 then break end
		end

		if worstLaunch > 0 then
			print(("[rampbug]   speed=%d -> 弹射! clip 后 vz=%.0f"):format(speed, worstLaunch))
		end
	end

	print(("[rampbug] fly 完成: 速度 %d..%d 步进 %d, 共 %d 次弹射命中")
		:format(minS, maxS, stepS, launches))
	WriteCSV("fly.csv", csv)
end)

--------------------------------------------------------------------------
-- 可视化 (不依赖 developer 1)
--------------------------------------------------------------------------
hook.Add("PostDrawTranslucentRenderables", "rampbug_repro_overlay", function(_, skybox)
	if skybox then return end
	if ptA then render.DrawWireframeSphere(ptA, 3, 8, 8, Color(255, 255, 0), true) end
	if ptB then render.DrawWireframeSphere(ptB, 3, 8, 8, Color(0, 255, 255), true) end
	if ptA and ptB then render.DrawLine(ptA, ptB, Color(255, 255, 0), true) end
	render.SetColorMaterial()
	for i = 1, #marks do
		local m = marks[i]
		if m.pos2 then
			render.DrawLine(m.pos, m.pos2, m.color, true)
		else
			render.DrawLine(m.pos, m.pos + Vector(0, 0, 4), m.color, true)
		end
	end
end)
