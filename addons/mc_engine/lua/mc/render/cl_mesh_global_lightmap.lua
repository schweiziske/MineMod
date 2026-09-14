-- Procedural 16x16 global lightmap: (block light level, sky light level) ->
-- light color, bound to the GPU chunk materials' $texture2. This activates
-- composeGlobalLightmap()'s real lookup path (which previously always fell
-- back to grayscale because $texture2 was never bound).
--
-- Axes: u = block level 0..15 (warm torch ramp, user brightness/gamma curve),
-- v = sky level 0..15 (day/night brightness + hue: sunset orange, moonlight
-- blue). Sky and block terms add, then floor by the ambient
-- minimum — at default settings this reproduces the old fallback's brightness
-- (mc_lightmap_ambient, default 0.04), with the floor carrying hue.
--
-- Time-of-day lives ENTIRELY in this 16x16 texture: a day/night step now
-- redraws 256 texels once a second instead of re-baking every chunk light
-- texture, so transitions are smooth and hitch-free. While active, chunk
-- light textures store RAW linear levels (see cl_mesh_gpu_light_texture) and
-- the r-channel night tint stays zeroed — the shaders need no changes.
MC = MC or {}

local LIGHTMAP_SIZE = 16
local lightmapRT
local lightmapColors, pendingColors = {}, {}
local pendingChanged = false
local lightmapRevision = MC.GlobalLightmapRevision or 0
MC.GlobalLightmapRevision = 0

-- Keep a CPU copy of the exact RGB bytes supplied to the RT. Animated fluids
-- use ordinary vertex-colour materials, so they cannot sample $texture2.
local function drawLightmapTexel( block, sky, r, g, b )
	r = math.floor( math.Clamp( r, 0, 1 ) * 255 + 0.5 )
	g = math.floor( math.Clamp( g, 0, 1 ) * 255 + 0.5 )
	b = math.floor( math.Clamp( b, 0, 1 ) * 255 + 0.5 )
	local index = ( sky * LIGHTMAP_SIZE + block ) * 3 + 1
	if lightmapColors[index] ~= r or lightmapColors[index + 1] ~= g or lightmapColors[index + 2] ~= b then
		pendingChanged = true
	end
	pendingColors[index], pendingColors[index + 1], pendingColors[index + 2] = r, g, b
	surface.SetDrawColor( r, g, b, 255 )
	surface.DrawRect( block, sky, 1, 1 )
end

local function publishLightmapColors()
	lightmapColors, pendingColors = pendingColors, lightmapColors
	if pendingChanged then lightmapRevision = lightmapRevision + 1 end
	MC.GlobalLightmapRevision = lightmapRevision
	pendingChanged = false
end

local function sampleLightmapChannel( i00, i10, i01, i11, fb, fs )
	local c0 = lightmapColors[i00] * ( 1 - fb ) + lightmapColors[i10] * fb
	local c1 = lightmapColors[i01] * ( 1 - fb ) + lightmapColors[i11] * fb
	return ( c0 * ( 1 - fs ) + c1 * fs ) / 255
end

function MC.SampleGlobalLightmapRGB( block, sky )
	if not MC.Check( MC.GlobalLightmapRevision > 0, "global_lightmap_cpu_unready",
		"CPU lightmap sampled before its first successful refresh" ) then return 0, 0, 0 end
	block, sky = math.Clamp( block, 0, 15 ), math.Clamp( sky, 0, 15 )
	local b0, s0 = math.floor( block ), math.floor( sky )
	local b1, s1 = math.min( b0 + 1, 15 ), math.min( s0 + 1, 15 )
	local fb, fs = block - b0, sky - s0
	local i00, i10 = ( s0 * 16 + b0 ) * 3 + 1, ( s0 * 16 + b1 ) * 3 + 1
	local i01, i11 = ( s1 * 16 + b0 ) * 3 + 1, ( s1 * 16 + b1 ) * 3 + 1
	return sampleLightmapChannel( i00, i10, i01, i11, fb, fs ),
		sampleLightmapChannel( i00 + 1, i10 + 1, i01 + 1, i11 + 1, fb, fs ),
		sampleLightmapChannel( i00 + 2, i10 + 2, i01 + 2, i11 + 2, fb, fs )
end

local function convarNumber( cv, fallback, minValue, maxValue )
	local value = cv and cv.GetFloat and cv:GetFloat() or fallback
	value = tonumber( value ) or fallback
	if value < minValue then value = minValue end
	if value > maxValue then value = maxValue end
	return value
end

local function lightmapEnabled()
	local cv = MC.MeshGpuLightmap
	if cv and cv.GetBool then return cv:GetBool() end
	return true
end

local function ensureLightmapRT()
	if lightmapRT then return lightmapRT end
	if not GetRenderTargetEx then return nil end
	-- Point-sampled: the chunk shader does its own bilinear filtering between
	-- light levels, hardware filtering would double-blur the lookup.
	lightmapRT = GetRenderTargetEx(
		"mc_global_lightmap2",
		LIGHTMAP_SIZE,
		LIGHTMAP_SIZE,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_NONE,
		bit.bor( 1, 4, 8, 256, 512 ),
		0,
		IMAGE_FORMAT_RGBA8888
	)
	return lightmapRT
end

function MC.GlobalLightmapActive()
	-- Chunk atlases always contain raw block/sky levels. mc_lightmap changes
	-- only this 16x16 texture's contents; it never changes chunk tile semantics.
	return true
end

-- Same curve family the per-cell bake used before the lightmap took over:
-- gamma shapes the torch falloff, brightness scales it.
local function blockCurveUnit( level )
	local unit = math.Clamp( level / 15, 0, 1 )
	local gamma = convarNumber( MC.MeshGpuLightGamma, 1, 0.25, 4 )
	if gamma ~= 1 then
		unit = unit ^ ( 1 / gamma )
	end
	return math.Clamp( unit * convarNumber( MC.MeshGpuLightBrightness, 1, 0.1, 4 ), 0, 1 )
end

local TORCH_WARM = { 1.0, 0.82, 0.58 }
local NIGHT_BLUE = { 0.28, 0.42, 1.0 }
local SUNSET_ORANGE = { 1.0, 0.62, 0.36 }

-- ==== Vanilla Minecraft base lightmap =====================================
-- 1:1 port of Minecraft 26.2's lightmap pipeline (out/ decompile):
-- assets/minecraft/shaders/core/lightmap.fsh fed by
-- LightmapRenderStateExtractor.extract() with the overworld defaults from
-- EnvironmentAttributes / DimensionTypes and the "day" timeline from Timelines.
-- GMod has no night vision / darkness effect / boss overlay / weather, so
-- those inputs sit at their vanilla no-effect values (0 / black).

-- DimensionTypes overrides AMBIENT_LIGHT_COLOR with 0xFF0A0A0A in the overworld.
local VANILLA_AMBIENT = 10 / 255
-- EnvironmentAttributes.BLOCK_LIGHT_TINT default 0xFFD88C.
local VANILLA_BLOCK_TINT = { 255 / 255, 216 / 255, 140 / 255 }
-- Timelines.NIGHT_SKY_LIGHT_COLOR / NIGHT_SKY_LIGHT_FACTOR.
local VANILLA_NIGHT_SKY_COLOR = { 0.48, 0.48, 1.0 }
local VANILLA_NIGHT_SKY_FACTOR = 0.24

-- Overworld "day" timeline modifier tracks over the 24000-tick day (base
-- attribute values are white / 1.0, so the multiplier IS the value). Linear
-- easing (KeyframeTrack default), cyclic wrap between the last and first key.
local VANILLA_SKY_FACTOR_KEYS = {
	{ 730, 1.0 },
	{ 11270, 1.0 },
	{ 13140, VANILLA_NIGHT_SKY_FACTOR },
	{ 22860, VANILLA_NIGHT_SKY_FACTOR },
}
local VANILLA_SKY_COLOR_KEYS = {
	{ 730, 1.0, 1.0, 1.0 },
	{ 11270, 1.0, 1.0, 1.0 },
	{ 13140, VANILLA_NIGHT_SKY_COLOR[1], VANILLA_NIGHT_SKY_COLOR[2], VANILLA_NIGHT_SKY_COLOR[3] },
	{ 22860, VANILLA_NIGHT_SKY_COLOR[1], VANILLA_NIGHT_SKY_COLOR[2], VANILLA_NIGHT_SKY_COLOR[3] },
}

local function vanillaLightmapActive()
	return lightmapEnabled()
end

-- Cyclic linear keyframe sampling (KeyframeTrackSampler semantics): segment
-- between the surrounding keys, wrapping last -> first across the day border.
-- Returns the interpolated tuple components after the tick column.
local function sampleVanillaTrack( keys, ticks )
	local count = #keys
	local first, last = keys[1], keys[count]
	local a, b, frac
	if ticks < first[1] or ticks >= last[1] then
		a, b = last, first
		local span = ( first[1] + 24000 ) - last[1]
		local into = ticks >= last[1] and ( ticks - last[1] ) or ( ticks + 24000 - last[1] )
		frac = span > 0 and into / span or 0
	else
		for k = 1, count - 1 do
			if ticks < keys[k + 1][1] then
				a, b = keys[k], keys[k + 1]
				local span = b[1] - a[1]
				frac = span > 0 and ( ticks - a[1] ) / span or 0
				break
			end
		end
	end
	local v1 = a[2] + ( b[2] - a[2] ) * frac
	if a[4] == nil then return v1 end
	local v2 = a[3] + ( b[3] - a[3] ) * frac
	local v3 = a[4] + ( b[4] - a[4] ) * frac
	return v1, v2, v3
end

-- LightmapRenderStateExtractor.tick(): random-walk torch flicker decayed
-- toward zero, advanced at Minecraft's 20 Hz tick rate. blockFactor below is
-- flicker + 1.4 (extract()).
local VANILLA_TICK_INTERVAL = 0.05
local vanillaFlicker = 0
local vanillaFlickerLast = 0

local function updateVanillaFlicker()
	local cv = MC.MeshGpuLightmapVanillaFlicker
	if not ( cv and cv.GetBool and cv:GetBool() ) then
		vanillaFlicker = 0
		return
	end
	local now = RealTime and RealTime() or 0
	local steps = math.floor( ( now - vanillaFlickerLast ) / VANILLA_TICK_INTERVAL )
	if steps <= 0 then return end
	-- Cap the catch-up: after a hitch the walk state converges within a few
	-- ticks anyway (x0.9 decay), so replaying a long backlog is pointless.
	if steps > 5 then
		steps = 5
		vanillaFlickerLast = now
	else
		vanillaFlickerLast = vanillaFlickerLast + steps * VANILLA_TICK_INTERVAL
	end
	for _ = 1, steps do
		vanillaFlicker = vanillaFlicker
			+ ( math.random() - math.random() ) * math.random() * math.random() * 0.1
		vanillaFlicker = vanillaFlicker * 0.9
	end
end

-- lightmap.fsh get_brightness(): the classic vanilla light falloff curve.
local function vanillaGetBrightness( level )
	return level / ( 4 - 3 * level )
end

-- lightmap.fsh notGamma(): the "brightness" option's lift curve.
local function vanillaNotGamma( r, g, b )
	local maxComponent = math.max( r, g, b )
	if maxComponent <= 0 then return r, g, b end
	local maxInverted = 1 - maxComponent
	local maxScaled = 1 - maxInverted * maxInverted * maxInverted * maxInverted
	local mul = maxScaled / maxComponent
	return r * mul, g * mul, b * mul
end

local function generateGlobalLightmapVanilla()
	local target = ensureLightmapRT()
	if not ( target and render and render.PushRenderTarget and cam and surface ) then return false end

	-- The addon clock already runs vanilla ticks (24000/day, same epoch), so
	-- the timeline keys apply directly; with the day cycle off it holds the
	-- base tick (default 6000 = noon).
	local ticks = MC.DayCycleTicks and MC.DayCycleTicks() or 6000
	local skyFactor = sampleVanillaTrack( VANILLA_SKY_FACTOR_KEYS, ticks )
	local skyColorR, skyColorG, skyColorB = sampleVanillaTrack( VANILLA_SKY_COLOR_KEYS, ticks )
	local blockFactor = vanillaFlicker + 1.4
	-- options.gamma, vanilla default 0.5. Dimension ambient is added before
	-- sky/block light and this brightness curve, matching lightmap.fsh.
	local brightnessFactor = convarNumber( MC.MeshGpuLightmapVanillaGamma, 0.5, 0, 1 )

	render.PushRenderTarget( target )
		cam.Start2D()
			for s = 0, LIGHTMAP_SIZE - 1 do
				local skyBrightness = vanillaGetBrightness( s / 15 ) * skyFactor
				local skyR = skyColorR * skyBrightness
				local skyG = skyColorG * skyBrightness
				local skyB = skyColorB * skyBrightness
				for b = 0, LIGHTMAP_SIZE - 1 do
					local blockLevel = b / 15
					local blockBrightness = vanillaGetBrightness( blockLevel ) * blockFactor
					-- BlockLightColor = mix(tint, white, 0.9 * (2l-1)^2): full
					-- warm tint at mid levels, near white at 0 and 15.
					local parabolic = ( 2 * blockLevel - 1 ) * ( 2 * blockLevel - 1 )
					local whiteMix = 0.9 * parabolic
					local r = VANILLA_AMBIENT + skyR + ( VANILLA_BLOCK_TINT[1] + ( 1 - VANILLA_BLOCK_TINT[1] ) * whiteMix ) * blockBrightness
					local g = VANILLA_AMBIENT + skyG + ( VANILLA_BLOCK_TINT[2] + ( 1 - VANILLA_BLOCK_TINT[2] ) * whiteMix ) * blockBrightness
					local bl = VANILLA_AMBIENT + skyB + ( VANILLA_BLOCK_TINT[3] + ( 1 - VANILLA_BLOCK_TINT[3] ) * whiteMix ) * blockBrightness
					r = math.Clamp( r, 0, 1 )
					g = math.Clamp( g, 0, 1 )
					bl = math.Clamp( bl, 0, 1 )
					local nr, ng, nb = vanillaNotGamma( r, g, bl )
					r = r + ( nr - r ) * brightnessFactor
					g = g + ( ng - g ) * brightnessFactor
					bl = bl + ( nb - bl ) * brightnessFactor
					drawLightmapTexel( b, s, r, g, bl )
				end
			end
		cam.End2D()
	render.PopRenderTarget()
	publishLightmapColors()
	return true
end
-- ==== end vanilla lightmap =================================================

-- MC-shaderpack "eyeBrightnessSmooth": the sky-ambient axis scales with the
-- CAMERA cell's sky exposure, smoothed like Minecraft's eye brightness. This
-- — not the per-pixel sky value — is what makes enclosed spaces go dark in
-- shader packs; the per-pixel sky axis keeps a healthy ambient floor so the
-- underside of large structures reads as ONE shadow-map shadow instead of a
-- second, vertical black blob.
local eyeFactorSmooth = 1
local eyeFactorApplied = 1
local eyeFactorLastThink = 0

local function updateEyeFactor()
	local now = RealTime and RealTime() or 0
	local dt = math.Clamp( now - eyeFactorLastThink, 0, 0.25 )
	eyeFactorLastThink = now
	local target = 1
	if MC.SkyVoxelLightUnit and MC.WorldToCell and EyePos then
		local ok, bx, by, bz = pcall( MC.WorldToCell, EyePos() )
		if ok and bx then
			target = math.Clamp( MC.SkyVoxelLightUnit( bx, by, bz ) * 2, 0, 1 )
		end
	end
	eyeFactorSmooth = eyeFactorSmooth + ( target - eyeFactorSmooth ) * math.min( dt * 3, 1 )
end

local function generateGlobalLightmap()
	-- Vanilla mode swaps the texture CONTENT only; the RT, bindings and the
	-- chunk-side raw-level semantics are shared with the custom formula.
	if vanillaLightmapActive() then
		return generateGlobalLightmapVanilla()
	end
	local target = ensureLightmapRT()
	if not ( target and render and render.PushRenderTarget and cam and surface ) then return false end

	local grayscale = not lightmapEnabled()
	local dayBrightness = MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
	-- Perceptual night lift: the linear moonlight floor (moon level / 15, 2/15
	-- at the default) is nearly black on screen, so dusk reads as a sudden
	-- blackout and the night-blue tint lands on brightness too low to see.
	-- Gamma < 1 lifts the dark end while leaving full day (1.0) untouched.
	local nightGamma = convarNumber( MC.MeshGpuLightmapNightGamma, 0.6, 0.25, 1 )
	if nightGamma ~= 1 then
		dayBrightness = math.Clamp( dayBrightness, 0, 1 ) ^ nightGamma
	end
	local nightBlend = MC.DayCycleNightBlend and MC.DayCycleNightBlend() or 0
	local horizon = MC.DayCycleHorizonBlend and MC.DayCycleHorizonBlend() or 0
	local sunset = horizon * ( 1 - nightBlend ) * convarNumber( MC.MeshGpuLightmapSunset, 0.5, 0, 1 )
	local nightTint = nightBlend * convarNumber( MC.DayCycleNightTint, 0.85, 0, 1 )
	local torchWarmth = convarNumber( MC.MeshGpuLightmapTorchWarmth, 0.7, 0, 1 )
	local ambient = convarNumber( MC.MeshGpuLightmapAmbient, 0.18, 0, 1 )
	local sunMul = convarNumber( MC.MeshGpuSunBrightness, 1, 0, 4 )
	-- Camera-based cave darkening (see updateEyeFactor above). Default OFF:
	-- the camera cell also loses sky light when merely standing under a large
	-- structure, which darkened the whole world outdoors.
	local eyeDark = convarNumber( MC.MeshGpuLightmapEyeDark, 1, 0, 1 )
	local eyeFactor = eyeDark + ( 1 - eyeDark ) * eyeFactorSmooth
	eyeFactorApplied = eyeFactorSmooth

	-- Sky hue: day white -> sunset orange -> dark moonlight blue.
	local skyR = 1 + ( SUNSET_ORANGE[1] - 1 ) * sunset
	local skyG = 1 + ( SUNSET_ORANGE[2] - 1 ) * sunset
	local skyB = 1 + ( SUNSET_ORANGE[3] - 1 ) * sunset
	skyR = skyR + ( NIGHT_BLUE[1] - skyR ) * nightTint
	skyG = skyG + ( NIGHT_BLUE[2] - skyG ) * nightTint
	skyB = skyB + ( NIGHT_BLUE[3] - skyB ) * nightTint

	local torchR = 1 + ( TORCH_WARM[1] - 1 ) * torchWarmth
	local torchG = 1 + ( TORCH_WARM[2] - 1 ) * torchWarmth
	local torchB = 1 + ( TORCH_WARM[3] - 1 ) * torchWarmth

	-- Sky hue normalized so the floor's strongest channel equals the ambient
	-- setting (the floor darkens perceptually at night but never below spec).
	local hueMax = math.max( skyR, skyG, skyB, 0.001 )
	local floorR = skyR / hueMax
	local floorG = skyG / hueMax
	local floorB = skyB / hueMax

	render.PushRenderTarget( target )
		cam.Start2D()
			-- Sky ambient falloff: floor + curve, AMBIENT ONLY — the shader
			-- adds direct sun from the sky axis top independently, so this
			-- floor no longer needs to carry "sun under structures". The curve
			-- (1-(1-u)^k) keeps mid levels bright so shaded-but-open areas
			-- read as shadow, not void; level 0 (true enclosure) falls to the
			-- small ambient floor.
			local skyCurve = convarNumber( MC.MeshGpuLightmapSkyCurve, 3, 1, 6 )
			local skyFloor = convarNumber( MC.MeshGpuLightmapSkyMin, 0.1, 0, 1 )
			for s = 0, LIGHTMAP_SIZE - 1 do
				local skyShape = 1 - ( 1 - s / 15 ) ^ skyCurve
				skyShape = skyFloor + ( 1 - skyFloor ) * skyShape
				local skyUnit = math.Clamp( skyShape * dayBrightness * sunMul * eyeFactor, 0, 1 )
				local sr, sg, sb = skyUnit * skyR, skyUnit * skyG, skyUnit * skyB
				for b = 0, LIGHTMAP_SIZE - 1 do
					local unit = blockCurveUnit( b )
					-- ADD torch and sky like vanilla MC, then clamp. A
					-- per-channel max() here produces a magenta band where a
					-- warm torch fringe crosses the cool night sky (R from
					-- the torch, B from the sky, G from neither).
					local r = math.min( unit * torchR + sr, 1 )
					local g = math.min( unit * torchG + sg, 1 )
					local bl = math.min( unit * torchB + sb, 1 )
					-- The ambient floor carries the sky hue: with a neutral
					-- gray floor, deep night snaps to gray the moment the sky
					-- term drops below it.
					r = math.max( r, ambient * floorR )
					g = math.max( g, ambient * floorG )
					bl = math.max( bl, ambient * floorB )
					if grayscale then
						local gray = math.max( unit, ( s / 15 ) * dayBrightness * sunMul, ambient )
						r, g, bl = gray, gray, gray
					end
					drawLightmapTexel( b, s, r, g, bl )
				end
			end
		cam.End2D()
	render.PopRenderTarget()
	publishLightmapColors()
	return true
end

local function bindToMaterials()
	local target = ensureLightmapRT()
	if not target then return end
	local function bind( mat )
		if mat and mat.SetTexture and not mat:IsError() then
			mat:SetTexture( "$texture2", target )
		end
	end
	local materials = MC.GetGpuChunkLightTextureMaterials and MC.GetGpuChunkLightTextureMaterials() or nil
	if type( materials ) == "table" and #materials > 0 then
		for _, material in ipairs( materials ) do bind( material ) end
		return
	end
	bind( MC.MaterialGpuLightTexture )
	bind( MC.MaterialGpuLightTextureLinearDebug )
	bind( MC.MaterialGpuLightTexturePpFix )
	bind( MC.MaterialGpuLightTextureFancy )
	bind( MC.MaterialGpuLightTextureFancyLinearDebug )
	bind( MC.MaterialGpuLightTextureFancyPpFix )
	bind( MC.MaterialGpuLightTextureHeight )
	bind( MC.MaterialGpuLightTextureVanilla )
	bind( MC.MaterialGpuLightTextureVanillaTranslucent )
	bind( MC.MaterialGpuLightTextureTranslucent )
	bind( MC.MaterialGpuLightTextureTranslucentLinearDebug )
	bind( MC.MaterialGpuLightTextureTranslucentPpFix )
end

function MC.RefreshGlobalLightmap()
	local ok = generateGlobalLightmap()
	bindToMaterials()
	return ok
end

-- Initial generation is deferred to the first Think: the render context is
-- not reliable at include time. Afterwards regenerate while the day cycle
-- runs or while the camera eye factor is converging (256 texels, effectively
-- free), so both transitions stay smooth.
local needsInitialRefresh = true
local nextTimedRefresh = 0
hook.Remove( "Think", "mc_global_lightmap_refresh" )
hook.Add( "Think", "mc_global_lightmap_refresh", function()
	local vanilla = vanillaLightmapActive()
	-- Camera grading is not an input to the vanilla lightmap.
	if not vanilla then updateEyeFactor() end
	if needsInitialRefresh then
		vanillaFlickerLast = RealTime and RealTime() or 0
		needsInitialRefresh = not MC.RefreshGlobalLightmap()
		return
	end
	if vanilla then
		-- Vanilla redraws every Minecraft tick, exactly like the game: the
		-- torch flicker walks each tick and the timeline moves with the clock.
		-- With flicker off and the clock frozen the texture is static, so only
		-- convar callbacks refresh it.
		updateVanillaFlicker()
		local flickerCv = MC.MeshGpuLightmapVanillaFlicker
		local flickerOn = flickerCv and flickerCv.GetBool and flickerCv:GetBool() or false
		local dayRunning = MC.DayCycleEnabled and MC.DayCycleEnabled() == true
			and not ( MC.DayCyclePaused and MC.DayCyclePaused() == true )
		if not ( flickerOn or dayRunning ) then return end
		local now = CurTime()
		if now < nextTimedRefresh then return end
		nextTimedRefresh = now + VANILLA_TICK_INTERVAL
		generateGlobalLightmap()
		return
	end
	local eyeDark = convarNumber( MC.MeshGpuLightmapEyeDark, 1, 0, 1 )
	local eyeMoved = eyeDark < 1 and math.abs( eyeFactorSmooth - eyeFactorApplied ) > 0.01
	local dayRunning = MC.DayCycleEnabled and MC.DayCycleEnabled() == true
		and not ( MC.DayCyclePaused and MC.DayCyclePaused() == true )
	if not ( eyeMoved or dayRunning ) then return end
	local now = CurTime()
	if now < nextTimedRefresh then return end
	-- Eye transitions refresh faster than the day-cycle tick so walking into
	-- a cave darkens smoothly instead of stepping.
	nextTimedRefresh = now + ( eyeMoved and 0.05 or 0.25 )
	generateGlobalLightmap()
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_lightmap", function()
		MC.RefreshGlobalLightmap()
	end, "mc_global_lightmap_toggle" )
	if cvars.RemoveChangeCallback then
		cvars.RemoveChangeCallback( "mc_light_style", "mc_global_lightmap_refresh_mc_light_style" )
	end
	for _, name in ipairs( { "mc_lightmap_torch_warmth", "mc_lightmap_ambient", "mc_lightmap_sunset", "mc_lightmap_night_gamma", "mc_lightmap_sky_curve", "mc_lightmap_sky_min", "mc_lightmap_eye_dark", "mc_lightmap_vanilla_gamma", "mc_lightmap_vanilla_flicker" } ) do
		cvars.AddChangeCallback( name, function()
			MC.RefreshGlobalLightmap()
		end, "mc_global_lightmap_refresh_" .. name )
	end
end
