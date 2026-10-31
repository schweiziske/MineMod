--[[----------------------------------------------------------------------------
	MC : CPU-side directional sun/moon shadow sampling for dynamic objects
	(break particles, held block). The GPU shadow map only shades chunk
	meshes, so dynamic quads approximate it here by raymarching the voxel
	grid toward the active light body. Strength/tint follow the same convars
	as the mesh shadow map so both stay visually in sync.
------------------------------------------------------------------------------]]

MC = MC or {}

-- Occluder search distance in blocks. Beyond this the GPU map's casters are
-- usually out of range too, so a longer march would only cost CPU.
local SHADOW_TRACE_BLOCKS = 48
-- Translucent blocks (glass, water) are not shadow casters in the GPU pass;
-- the march skips through at most this many before giving up as unoccluded.
local SHADOW_MAX_PASSTHROUGH = 4

local cacheFrame = -1
local cacheFactor = {}

local TORCH_WARM = { 1.0, 0.82, 0.58 }
local NIGHT_BLUE = { 0.28, 0.42, 1.0 }
local SUNSET_ORANGE = { 1.0, 0.62, 0.36 }

local function convarFloat( cvar, fallback, minV, maxV )
	local v = cvar and cvar.GetFloat and cvar:GetFloat()
	return math.Clamp( tonumber( v ) or fallback, minV, maxV )
end

local function sunOccluded( pos, sunDir, distance )
	-- Step out of the source cell first so a particle spawned inside the
	-- broken block does not self-shadow on its own (already removed) cell.
	local size = MC.API.Coords.BlockSize()
	local step = size * 0.05
	local start = pos + sunDir * step
	local maxDist = distance or SHADOW_TRACE_BLOCKS * size
	for _ = 1, SHADOW_MAX_PASSTHROUGH do
		local hit = MC.TraceBlockRay( start, sunDir, maxDist )
		if not hit then return false end
		if not ( MC.IsTranslucentBlock and MC.IsTranslucentBlock( hit.Block ) ) then
			return true
		end
		maxDist = maxDist - ( hit.Distance or 0 ) - step
		if maxDist <= 0 then return false end
		start = hit.HitPos + sunDir * step
	end
	return false
end

-- Shadow multiplier in [tint..1] for a world position: 1 when the active
-- light body is visible, lerped toward the shadow tint floor (matching the
-- fancy chunk shader) when a voxel occludes it. Cached per cell per frame
-- because break particles sample in bursts within the same block.
function MC.SampleSunShadow( pos, precise )
	if not ( MC.TraceBlockRay and MC.WorldToCell ) then return 1 end
	local sunDir, strength, distance, tint
	local runtime = MC.RenderPackRuntime
	if runtime and runtime.active then
		local shadows = MC.RenderPBRShadows
		if not shadows or not shadows.EntityLightShadow then return 1 end
		local sx, sy, sz
		sx, sy, sz, strength, distance = shadows.EntityLightShadow()
		if not sx then return 1 end
		sunDir, tint = Vector( sx, sy, sz ), 0
	else
		if not ( MC.UsingMeshShadowMap and MC.UsingMeshShadowMap() and MC.MeshShadowLightDirection ) then return 1 end
		local scale
		sunDir, scale = MC.MeshShadowLightDirection()
		strength = convarFloat( MC.MeshShadowMapStrength, 0.75, 0, 1 ) * math.Clamp( tonumber( scale ) or 1, 0, 1 )
		tint = convarFloat( MC.MeshShadowMapTint, 0.6, 0, 1 )
	end
	if strength <= 0 or not sunDir then return 1 end

	local frame = FrameNumber and FrameNumber() or 0
	if frame ~= cacheFrame then
		cacheFrame = frame
		cacheFactor = {}
	end
	local key
	local bx, by, bz = MC.WorldToCell( pos )
	if not precise and bx ~= nil and MC.CellKey then
		key = MC.CellKey( bx, by, bz )
		local cached = cacheFactor[key]
		if cached then return cached end
	end

	local factor = 1
	if sunOccluded( pos, sunDir, distance ) then
		factor = 1 - strength * ( 1 - tint )
	end
	if key ~= nil then cacheFactor[key] = factor end
	return factor
end

local function lerp( t, a, b )
	return a + ( b - a ) * t
end

local function trilerp( c000, c100, c010, c110, c001, c101, c011, c111, fx, fy, fz )
	local x00 = lerp( fx, c000, c100 )
	local x10 = lerp( fx, c010, c110 )
	local x01 = lerp( fx, c001, c101 )
	local x11 = lerp( fx, c011, c111 )
	return lerp( fz, lerp( fy, x00, x10 ), lerp( fy, x01, x11 ) )
end

-- Light values live at voxel centers. Interpolating around those centers keeps
-- a held item from snapping between two integer cells as the hand bobs across
-- a boundary, while still using the exact propagated block/sky fields.
function MC.SampleDynamicLightLevels( pos, emission )
	if not ( pos and MC.SampleLighting ) then return 15, 15 end
	local size = MC.API.Coords.BlockSize()
	local gx = pos.x / size - 0.5
	local gy = pos.y / size - 0.5
	local gz = pos.z / size - 0.5
	local x0, y0, z0 = math.floor( gx ), math.floor( gy ), math.floor( gz )
	local fx, fy, fz = gx - x0, gy - y0, gz - z0
	local block, sky = {}, {}
	local index = 0
	for dz = 0, 1 do
		for dy = 0, 1 do
			for dx = 0, 1 do
				index = index + 1
				local _, _, b, s = MC.SampleLighting( x0 + dx, y0 + dy, z0 + dz, 0 )
				block[index] = tonumber( b ) or 0
				sky[index] = tonumber( s ) or 0
			end
		end
	end
	local blockLevel = trilerp( block[1], block[2], block[3], block[4], block[5], block[6], block[7], block[8], fx, fy, fz )
	local skyLevel = trilerp( sky[1], sky[2], sky[3], sky[4], sky[5], sky[6], sky[7], sky[8], fx, fy, fz )
	return math.max( blockLevel, math.Clamp( tonumber( emission ) or 0, 0, 15 ) ), skyLevel
end

local function lightmapLinear( value )
	if value <= 0.04045 then return value / 12.92 end
	return ( ( value + 0.055 ) / 1.055 ) ^ 2.4
end

local function entityPBRDiffuse( total, base, sun, direct, exposure )
	-- $texture2 is sampled as sRGB by PBR; the CPU copy contains RGB bytes.
	total, base = lightmapLinear( total ), lightmapLinear( base )
	local linear = ( base + math.max( total - base, 0 ) * 0.4 + sun * direct ) * exposure
	local mapped = math.Clamp( linear * ( 2.51 * linear + 0.03 ) / ( linear * ( 2.43 * linear + 0.59 ) + 0.14 ), 0, 1 )
	return mapped ^ ( 1 / 2.2 )
end

-- Source models receive the active lightmap, including night vision and
-- grayscale settings. Do not reconstruct a second, subtly different map.
-- PBR uses a diffuse-only CPU approximation: the engine's materials cannot
-- sample our shadow atlas or captured IBL. Keep block/ambient light separate
-- from direct sunlight so an occluder removes only the direct term.
function MC.SampleEntityLightingRGB( pos )
	local block, sky = MC.SampleDynamicLightLevels( pos, 0 )
	if not MC.Check( MC.GlobalLightmapRevision and MC.GlobalLightmapRevision > 0,
		"entity_lightmap_unready", "entity lighting requires a published global lightmap" ) then return 0, 0, 0 end
	local r, g, b = MC.SampleGlobalLightmapRGB( block, sky )
	local active = MC.RenderPackRuntime and MC.RenderPackRuntime.active
	local definition = active and active.plan.owners["pack/" .. active.pack].definition
	local adapter = definition and definition.adapter
	if adapter == "mc:pbr_quad_v4" or adapter == "mc:pbr_quad_v5" then
		local br, bg, bb = MC.SampleGlobalLightmapRGB( block, 0 )
		local exposure, sr, sg, sb = MC.RenderPBR.EntityLightParameters()
		local direct = ( math.Clamp( sky / 15, 0, 1 ) ^ 2 ) * MC.SampleSunShadow( pos, true ) / math.pi
		r, g, b = entityPBRDiffuse( r, br, sr, direct, exposure ),
			entityPBRDiffuse( g, bg, sg, direct, exposure ), entityPBRDiffuse( b, bb, sb, direct, exposure )
	end
	local moving = MC.RenderDynamicLights
	if moving then
		local dr, dg, db = moving.SampleRGB( pos )
		r, g, b = r + math.min( dr, 1 ) * ( 1 - r ), g + math.min( dg, 1 ) * ( 1 - g ), b + math.min( db, 1 ) * ( 1 - b )
	end
	return r, g, b
end

local function blockCurveUnit( level )
	local unit = math.Clamp( ( tonumber( level ) or 0 ) / 15, 0, 1 )
	local gamma = convarFloat( MC.MeshGpuLightGamma, 1, 0.25, 4 )
	if gamma ~= 1 then unit = unit ^ ( 1 / gamma ) end
	return math.Clamp( unit * convarFloat( MC.MeshGpuLightBrightness, 1, 0.1, 4 ), 0, 1 )
end

-- Dynamic unlit geometry cannot sample the GPU lightmap texture directly, so
-- reproduce its custom lightmap composition here: warm block light, colored
-- sky light, nonlinear sky falloff and the same ambient floor. Shadowing only
-- attenuates the directional part of sky illumination; cave ambient and block
-- light remain visible instead of the whole result being multiplied darker.
function MC.SampleDynamicLightingRGB( pos, emission )
	local blockLevel, skyLevel = MC.SampleDynamicLightLevels( pos, emission )
	local dayBrightness = MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
	local nightGamma = convarFloat( MC.MeshGpuLightmapNightGamma, 0.6, 0.25, 1 )
	if nightGamma ~= 1 then dayBrightness = math.Clamp( dayBrightness, 0, 1 ) ^ nightGamma end
	local nightBlend = MC.DayCycleNightBlend and MC.DayCycleNightBlend() or 0
	local horizon = MC.DayCycleHorizonBlend and MC.DayCycleHorizonBlend() or 0
	local sunset = horizon * ( 1 - nightBlend ) * convarFloat( MC.MeshGpuLightmapSunset, 0.5, 0, 1 )
	local nightTint = nightBlend * convarFloat( MC.DayCycleNightTint, 0.85, 0, 1 )
	local torchWarmth = convarFloat( MC.MeshGpuLightmapTorchWarmth, 0.7, 0, 1 )
	local ambient = math.max(
		convarFloat( MC.LightAmbientMin, 0, 0, 1 ),
		convarFloat( MC.MeshGpuLightmapAmbient, 0.04, 0, 1 )
	)

	local skyR = lerp( sunset, 1, SUNSET_ORANGE[1] )
	local skyG = lerp( sunset, 1, SUNSET_ORANGE[2] )
	local skyB = lerp( sunset, 1, SUNSET_ORANGE[3] )
	skyR = lerp( nightTint, skyR, NIGHT_BLUE[1] )
	skyG = lerp( nightTint, skyG, NIGHT_BLUE[2] )
	skyB = lerp( nightTint, skyB, NIGHT_BLUE[3] )

	local torchR = lerp( torchWarmth, 1, TORCH_WARM[1] )
	local torchG = lerp( torchWarmth, 1, TORCH_WARM[2] )
	local torchB = lerp( torchWarmth, 1, TORCH_WARM[3] )
	local blockUnit = blockCurveUnit( blockLevel )
	local skyCurve = convarFloat( MC.MeshGpuLightmapSkyCurve, 3, 1, 6 )
	local skyFloor = convarFloat( MC.MeshGpuLightmapSkyMin, 0.1, 0, 1 )
	local skyShape = 1 - ( 1 - math.Clamp( skyLevel / 15, 0, 1 ) ) ^ skyCurve
	skyShape = skyFloor + ( 1 - skyFloor ) * skyShape
	local skyUnit = math.Clamp( skyShape * dayBrightness * convarFloat( MC.MeshGpuSunBrightness, 1, 0, 4 ), 0, 1 )

	-- Treat 65% of sky illumination as ambient and 35% as directional. This
	-- mirrors the chunk shader's separation closely enough without crushing an
	-- item to black whenever the ray sample reports a shadow.
	local shadow = MC.SampleSunShadow( pos )
	local skyShadow = 0.65 + 0.35 * shadow
	local sr, sg, sb = skyUnit * skyR * skyShadow, skyUnit * skyG * skyShadow, skyUnit * skyB * skyShadow
	local hueMax = math.max( skyR, skyG, skyB, 0.001 )
	local r = math.max( math.min( blockUnit * torchR + sr, 1 ), ambient * skyR / hueMax )
	local g = math.max( math.min( blockUnit * torchG + sg, 1 ), ambient * skyG / hueMax )
	local b = math.max( math.min( blockUnit * torchB + sb, 1 ), ambient * skyB / hueMax )
	local moving = MC.RenderDynamicLights
	if moving and pos then
		local dr, dg, db = moving.SampleRGB( pos )
		r = r + math.min( dr, 1 ) * ( 1 - r )
		g = g + math.min( dg, 1 ) * ( 1 - g )
		b = b + math.min( db, 1 ) * ( 1 - b )
	end
	return math.Clamp( r, 0, 1 ), math.Clamp( g, 0, 1 ), math.Clamp( b, 0, 1 ), blockLevel, skyLevel
end

-- Keep every unlit dynamic renderer on the same exposure conversion. The
-- caller still chooses its own headroom (held blocks use 0.48, terrain
-- particles use 0.60), but clamping and RGB scaling must stay identical.
function MC.ScaleDynamicLightingRGB( r, g, b, gain )
	gain = math.max( tonumber( gain ) or 1, 0 )
	local rawR = math.Clamp( tonumber( r ) or 1, 0, 1 )
	local rawG = math.Clamp( tonumber( g ) or rawR, 0, 1 )
	local rawB = math.Clamp( tonumber( b ) or rawR, 0, 1 )
	return math.Clamp( rawR * gain, 0, 1 ), math.Clamp( rawG * gain, 0, 1 ), math.Clamp( rawB * gain, 0, 1 )
end

-- Applies day/night sky intensity and the directional shadow to a
-- MC.SampleLighting result. MC.SampleLighting stores time-independent voxel
-- sky levels, while chunk shaders apply the current day-cycle intensity later;
-- dynamic objects must do the same before drawing their unlit materials.
-- Block light and explicit self emission are omnidirectional, so they set a
-- floor the shadow can never darken below.
function MC.ApplySunShadowToBrightness( pos, brightness, level, blockLight, emission, skyLight )
	if MC.SampleDynamicLightingRGB then
		local r, g, b = MC.SampleDynamicLightingRGB( pos, emission )
		return math.max( r, g, b )
	end
	brightness = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
	blockLight = math.Clamp( tonumber( blockLight ) or 0, 0, 15 )
	emission = math.Clamp( tonumber( emission ) or 0, 0, 15 )
	if skyLight ~= nil then
		skyLight = math.Clamp( tonumber( skyLight ) or 0, 0, 15 )
		local skyBrightness = MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
		local sunBrightness = convarFloat( MC.MeshGpuSunBrightness, 1, 0, 4 )
		local effectiveLevel = math.max( blockLight, emission, skyLight * skyBrightness * sunBrightness )
		local ambient = convarFloat( MC.LightAmbientMin, 0, 0, 1 )
		-- Dynamic models use unlit/vertex-colored materials, so they do not
		-- receive the global lightmap's dark-area floor automatically. Match the
		-- active world pipeline while still honoring a higher CPU ambient clamp.
		if MC.GlobalLightmapActive and MC.GlobalLightmapActive() then
			ambient = math.max( ambient, convarFloat( MC.MeshGpuLightmapAmbient, 0.1, 0, 1 ) )
		end
		brightness = math.Clamp( ambient + ( 1 - ambient ) * ( effectiveLevel / 15 ), 0, 1 )
		level = effectiveLevel
	end
	local factor = MC.SampleSunShadow( pos )
	if factor >= 1 then return brightness end

	local shadowed = brightness * factor
	local floorLevel = math.max( blockLight, emission )
	level = tonumber( level ) or 0
	if level > 0 and floorLevel > 0 then
		shadowed = math.max( shadowed, brightness * math.Clamp( floorLevel / level, 0, 1 ) )
	end
	return shadowed
end
