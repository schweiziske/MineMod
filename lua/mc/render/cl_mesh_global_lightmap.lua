-- Procedural 16x16 global lightmap: (block light level, sky light level) ->
-- light color, bound to the GPU chunk materials' $texture2. This activates
-- composeGlobalLightmap()'s real lookup path (which previously always fell
-- back to grayscale because $texture2 was never bound).
--
-- Axes: u = block level 0..15 (warm torch ramp, user brightness/gamma curve),
-- v = sky level 0..15 (day/night brightness + hue: sunset orange, moonlight
-- blue). Channels combine with per-channel max, floored by the ambient
-- minimum — at default settings this reproduces the old fallback's brightness
-- (max(0.12, max(block, sky))), only adding hue.
--
-- Time-of-day lives ENTIRELY in this 16x16 texture: a day/night step now
-- redraws 256 texels once a second instead of re-baking every chunk light
-- texture, so transitions are smooth and hitch-free. While active, chunk
-- light textures store RAW linear levels (see cl_mesh_gpu_light_texture) and
-- the r-channel night tint stays zeroed — the shaders need no changes.
MC = MC or {}

local LIGHTMAP_SIZE = 16
local lightmapRT
local offRT

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

local function ensureOffRT()
	if offRT then return offRT end
	if not GetRenderTargetEx then return nil end
	-- Black texture: binding it restores composeGlobalLightmap()'s grayscale
	-- fallback path (a bound texture cannot be unbound).
	offRT = GetRenderTargetEx(
		"mc_global_lightmap_off",
		2,
		2,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_NONE,
		bit.bor( 1, 4, 8, 256, 512 ),
		0,
		IMAGE_FORMAT_RGBA8888
	)
	if offRT and render and render.PushRenderTarget then
		render.PushRenderTarget( offRT )
			render.Clear( 0, 0, 0, 255, true, true )
		render.PopRenderTarget()
	end
	return offRT
end

function MC.GlobalLightmapActive()
	return lightmapEnabled() and lightmapRT ~= nil
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
local NIGHT_BLUE = { 0.55, 0.66, 1.0 }
local SUNSET_ORANGE = { 1.0, 0.62, 0.36 }

local function generateGlobalLightmap()
	local target = ensureLightmapRT()
	if not ( target and render and render.PushRenderTarget and cam and surface ) then return false end

	local dayBrightness = MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
	local nightBlend = MC.DayCycleNightBlend and MC.DayCycleNightBlend() or 0
	local horizon = MC.DayCycleHorizonBlend and MC.DayCycleHorizonBlend() or 0
	local sunset = horizon * ( 1 - nightBlend ) * convarNumber( MC.MeshGpuLightmapSunset, 0.5, 0, 1 )
	local nightTint = nightBlend * convarNumber( MC.DayCycleNightTint, 0.6, 0, 1 )
	local torchWarmth = convarNumber( MC.MeshGpuLightmapTorchWarmth, 0.7, 0, 1 )
	local ambient = convarNumber( MC.MeshGpuLightmapAmbient, 0.12, 0, 1 )
	local sunMul = convarNumber( MC.MeshGpuSunBrightness, 1, 0, 4 )

	-- Sky hue: day white -> sunset orange -> moonlight blue.
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
			for s = 0, LIGHTMAP_SIZE - 1 do
				local skyUnit = math.Clamp( ( s / 15 ) * dayBrightness * sunMul, 0, 1 )
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
					-- term drops below it (sudden loss of the blue tint).
					r = math.max( r, ambient * floorR )
					g = math.max( g, ambient * floorG )
					bl = math.max( bl, ambient * floorB )
					surface.SetDrawColor(
						math.floor( math.Clamp( r, 0, 1 ) * 255 + 0.5 ),
						math.floor( math.Clamp( g, 0, 1 ) * 255 + 0.5 ),
						math.floor( math.Clamp( bl, 0, 1 ) * 255 + 0.5 ),
						255
					)
					surface.DrawRect( b, s, 1, 1 )
				end
			end
		cam.End2D()
	render.PopRenderTarget()
	return true
end

local function bindToMaterials()
	local target = lightmapEnabled() and ensureLightmapRT() or ensureOffRT()
	if not target then return end
	local function bind( mat )
		if mat and mat.SetTexture and not mat:IsError() then
			mat:SetTexture( "$texture2", target )
		end
	end
	bind( MC.MaterialGpuLightTexture )
	bind( MC.MaterialGpuLightTextureFancy )
end

function MC.RefreshGlobalLightmap()
	local ok = false
	if lightmapEnabled() then
		ok = generateGlobalLightmap()
	end
	bindToMaterials()
	return ok
end

-- Initial generation is deferred to the first Think: the render context is
-- not reliable at include time. Afterwards regenerate once a second while the
-- day cycle runs (256 texels, effectively free) so transitions stay smooth.
local needsInitialRefresh = true
local nextTimedRefresh = 0
hook.Remove( "Think", "mc_global_lightmap_refresh" )
hook.Add( "Think", "mc_global_lightmap_refresh", function()
	if needsInitialRefresh then
		needsInitialRefresh = false
		MC.RefreshGlobalLightmap()
		return
	end
	if not ( MC.DayCycleEnabled and MC.DayCycleEnabled() ) then return end
	if not lightmapEnabled() then return end
	local now = CurTime()
	if now < nextTimedRefresh then return end
	nextTimedRefresh = now + 1
	generateGlobalLightmap()
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_gpu_lightmap", function()
		-- Chunk light texture byte semantics differ between lightmap and
		-- fallback mode (raw levels vs curved units), so a toggle re-bakes.
		MC.RefreshGlobalLightmap()
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	end, "mc_global_lightmap_toggle" )
	for _, name in ipairs( { "mc_mesh_gpu_lightmap_torch_warmth", "mc_mesh_gpu_lightmap_ambient", "mc_mesh_gpu_lightmap_sunset" } ) do
		cvars.AddChangeCallback( name, function()
			MC.RefreshGlobalLightmap()
		end, "mc_global_lightmap_refresh_" .. name )
	end
end
