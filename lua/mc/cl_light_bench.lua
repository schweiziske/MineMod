-- mc_light_bench: one-command A/B measurement of the lighting/shadow layers.
--
-- Cycles through pipeline configs on a live world, samples real frame rate
-- for each, then prints a per-layer ms/frame cost breakdown and a verdict in
-- the console. Restores every touched cvar afterwards.
--
-- Default run only toggles layers that do NOT force chunk mesh rebuilds
-- (shadow mode/off, render off), so it finishes in ~15 seconds without
-- hitching. "mc_light_bench full" additionally measures the CPU vertex-color
-- path, which forces a full mesh rebuild twice (into and out of the config) —
-- expect a long hitch on large worlds.
MC = MC or {}

local PHASE_SETTLE = 0.9
local PHASE_SAMPLE = 1.6

local state = nil

local function cvarGet( name )
	local cv = GetConVar( name )
	return cv and cv:GetString() or nil
end

local function cvarSet( name, value )
	if value == nil then return end
	local cv = GetConVar( name )
	if cv and cv.SetString then
		local ok = pcall( cv.SetString, cv, tostring( value ) )
		if ok then return end
	end
	RunConsoleCommand( name, tostring( value ) )
end

local TOUCHED = {
	"mc_mesh_render",
	"mc_mesh_gpu_shader",
	"mc_mesh_gpu_light_texture",
	"mc_mesh_gpu_light_fast",
	"mc_mesh_shadow_map",
	"mc_mesh_shadow_mode",
	"fps_max",
}

local function buildConfigs( full )
	-- Ordered to avoid mesh-rebuild-triggering payload switches until the
	-- optional full pass: shadow/mode/render/fast toggles only rebind or
	-- swap materials of the same vertex format.
	local configs = {
		{ name = "current(你现在的设置)", cvars = {} },
		{ name = "fast低采样(旧版观感)", cvars = { mc_mesh_render = "1", mc_mesh_gpu_shader = "1", mc_mesh_gpu_light_texture = "1", mc_mesh_gpu_light_fast = "1", mc_mesh_shadow_map = "0" } },
		{ name = "height模式(新)", cvars = { mc_mesh_render = "1", mc_mesh_gpu_shader = "1", mc_mesh_gpu_light_texture = "1", mc_mesh_gpu_light_fast = "0", mc_mesh_shadow_map = "1", mc_mesh_shadow_mode = "height" } },
		{ name = "map模式(旧shadow map)", cvars = { mc_mesh_render = "1", mc_mesh_gpu_shader = "1", mc_mesh_gpu_light_texture = "1", mc_mesh_gpu_light_fast = "0", mc_mesh_shadow_map = "1", mc_mesh_shadow_mode = "map" } },
		{ name = "无阴影(smooth采样)", cvars = { mc_mesh_render = "1", mc_mesh_gpu_shader = "1", mc_mesh_gpu_light_texture = "1", mc_mesh_gpu_light_fast = "0", mc_mesh_shadow_map = "0" } },
		{ name = "整个MC渲染关闭", cvars = { mc_mesh_render = "0" } },
	}
	if full then
		table.insert( configs, {
			name = "CPU顶点色(最简shader)",
			cvars = { mc_mesh_render = "1", mc_mesh_gpu_shader = "0", mc_mesh_gpu_light_texture = "0", mc_mesh_gpu_light_fast = "0", mc_mesh_shadow_map = "0" },
			waitRebuild = true,
		} )
	end
	return configs
end

local function meshDirtyCount()
	local dirty = MC.MeshDirty
	if not dirty then return 0 end
	local n = 0
	for _ in pairs( dirty ) do n = n + 1 end
	return n
end

local function ms( fps )
	if not fps or fps <= 0 then return 0 end
	return 1000 / fps
end

local function fmt( pattern, ... )
	print( string.format( "[MC bench] " .. pattern, ... ) )
end

local function finishBench()
	local s = state
	state = nil
	hook.Remove( "Think", "mc_light_bench" )
	for _, name in ipairs( TOUCHED ) do
		if s.restore[name] ~= nil then cvarSet( name, s.restore[name] ) end
	end

	fmt( "================ 结果 ================" )
	for _, r in ipairs( s.results ) do
		local note = ""
		if r.unreliable then note = "  (重建未完成,数字偏低)" end
		fmt( "%-28s %6.1f fps  (%5.2f ms/帧)%s", r.name, r.fps, ms( r.fps ), note )
	end

	local byName = {}
	for _, r in ipairs( s.results ) do byName[r.name] = r end
	local fastR = byName["fast低采样(旧版观感)"]
	local heightR = byName["height模式(新)"]
	local mapR = byName["map模式(旧shadow map)"]
	local noShadowR = byName["无阴影(smooth采样)"]
	local offR = byName["整个MC渲染关闭"]
	local vertexR = byName["CPU顶点色(最简shader)"]

	fmt( "---------------- 分层成本 ----------------" )
	if fastR and noShadowR then
		fmt( "smooth采样比fast低采样贵:  %+.2f ms  <- 这里大 = 像素采样是瓶颈,fast模式就是答案", ms( noShadowR.fps ) - ms( fastR.fps ) )
	end
	if mapR and noShadowR then
		fmt( "旧shadow map每帧深度pass: %+.2f ms", ms( mapR.fps ) - ms( noShadowR.fps ) )
	end
	if heightR and noShadowR then
		fmt( "新height模式相对无阴影:   %+.2f ms", ms( heightR.fps ) - ms( noShadowR.fps ) )
	end
	if fastR and offR then
		fmt( "fast模式下MC渲染总成本:   %+.2f ms  <- 这里还大 = 剩的是draw call提交,得合并mesh", ms( fastR.fps ) - ms( offR.fps ) )
	end
	if noShadowR and offR then
		fmt( "smooth下MC渲染总成本:     %+.2f ms", ms( noShadowR.fps ) - ms( offR.fps ) )
	end
	if vertexR and offR then
		fmt( "CPU顶点色路径总成本:      %+.2f ms", ms( vertexR.fps ) - ms( offR.fps ) )
	end

	fmt( "---------------- 状态检查 ----------------" )
	local vcsLoaded = file.Exists( "shaders/fxc/mc_gpu_chunk_lighttex_height3_vface_ps30.vcs", "GAME" )
	fmt( "height模式shader文件: %s", vcsLoaded and "已找到" or "缺失!! 需要重启客户端/检查部署" )
	local fastVcs = file.Exists( "shaders/fxc/mc_gpu_chunk_lighttex_fast3_vface_ps30.vcs", "GAME" )
	fmt( "fast模式shader文件: %s", fastVcs and "已找到" or "缺失!! 需要重启客户端/检查部署" )
	local heightMat = MC.MaterialGpuLightTextureHeight
	fmt( "height材质: %s", heightMat and ( heightMat:IsError() and "ERROR" or "ok" ) or "未创建" )
	local fastMat = MC.MaterialGpuLightTextureFast
	fmt( "fast材质: %s", fastMat and ( fastMat:IsError() and "ERROR" or "ok" ) or "未创建" )
	if s.hfRendersDelta ~= nil then
		fmt( "height阶段高度图重绘次数: %d (应为1左右;每帧涨=有bug)", s.hfRendersDelta )
	end
	if s.mapDrawnMeshes ~= nil then
		fmt( "map阶段每帧shadow pass画了 %d 个mesh", s.mapDrawnMeshes )
	end
	local drawn = MC.DrawCullStats and MC.DrawCullStats.drawn or 0
	local tested = MC.DrawCullStats and MC.DrawCullStats.tested or 0
	fmt( "视野内chunk: %d / %d", drawn, tested )
	if s.restore.fps_max and tonumber( s.restore.fps_max ) and tonumber( s.restore.fps_max ) > 0 then
		fmt( "注意: 你平时 fps_max=%s,测试期间临时解除了上限", s.restore.fps_max )
	end
	fmt( "================ 完 ================" )
	fmt( "把上面整段复制回给我。" )
end

local function startPhase( s )
	local cfg = s.configs[s.index]
	if not cfg then
		finishBench()
		return
	end
	for name, value in pairs( cfg.cvars ) do cvarSet( name, value ) end
	s.phaseStart = RealTime()
	s.sampleStart = nil
	s.frames = 0
	s.waitingRebuild = cfg.waitRebuild == true
	s.rebuildDeadline = RealTime() + 45
	if cfg.name == "height模式(新)" and MC.HeightfieldShadowStats then
		s.hfRendersBefore = MC.HeightfieldShadowStats().renders or 0
	end
	fmt( "测量中 %d/%d: %s ...", s.index, #s.configs, cfg.name )
end

local function onThink()
	local s = state
	if not s then
		hook.Remove( "Think", "mc_light_bench" )
		return
	end
	local now = RealTime()
	local cfg = s.configs[s.index]
	if not cfg then
		finishBench()
		return
	end

	if s.waitingRebuild then
		if meshDirtyCount() == 0 then
			s.waitingRebuild = false
			s.phaseStart = now
		elseif now > s.rebuildDeadline then
			s.waitingRebuild = false
			s.phaseStart = now
			cfg.rebuildTimeout = true
		else
			return
		end
	end

	if now < s.phaseStart + PHASE_SETTLE then return end
	if not s.sampleStart then
		s.sampleStart = now
		s.frames = 0
		return
	end
	s.frames = s.frames + 1
	if now < s.sampleStart + PHASE_SAMPLE then return end

	local duration = now - s.sampleStart
	local fps = duration > 0 and s.frames / duration or 0
	s.results[#s.results + 1] = {
		name = cfg.name,
		fps = fps,
		unreliable = cfg.rebuildTimeout == true,
	}
	if cfg.name == "height模式(新)" then
		if MC.HeightfieldShadowStats and s.hfRendersBefore ~= nil then
			s.hfRendersDelta = ( MC.HeightfieldShadowStats().renders or 0 ) - s.hfRendersBefore
		end
	elseif cfg.name == "map模式(旧shadow map)" then
		if MC.MeshShadowMapStats then
			s.mapDrawnMeshes = MC.MeshShadowMapStats().drawnMeshes or 0
		end
	end
	s.index = s.index + 1
	startPhase( s )
end

concommand.Add( "mc_light_bench", function( _, _, args )
	if state then
		fmt( "已经在跑了" )
		return
	end
	local full = args and args[1] == "full"
	local restore = {}
	for _, name in ipairs( TOUCHED ) do restore[name] = cvarGet( name ) end
	state = {
		configs = buildConfigs( full ),
		index = 1,
		results = {},
		restore = restore,
	}
	cvarSet( "fps_max", "0" )
	fmt( "开始测量,站着别动约 %d 秒%s", math.ceil( #state.configs * ( PHASE_SETTLE + PHASE_SAMPLE ) + 2 ), full and "(full 模式含全量重建,会卡一阵)" or "" )
	startPhase( state )
	hook.Remove( "Think", "mc_light_bench" )
	hook.Add( "Think", "mc_light_bench", onThink )
end )
