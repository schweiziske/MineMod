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

local function convarFloat( cvar, fallback, minV, maxV )
	local v = cvar and cvar.GetFloat and cvar:GetFloat()
	return math.Clamp( tonumber( v ) or fallback, minV, maxV )
end

local function sunOccluded( pos, sunDir )
	-- Step out of the source cell first so a particle spawned inside the
	-- broken block does not self-shadow on its own (already removed) cell.
	local step = MC.BS * 0.05
	local start = pos + sunDir * step
	local maxDist = SHADOW_TRACE_BLOCKS * MC.BS
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
function MC.SampleSunShadow( pos )
	if not ( MC.UsingMeshShadowMap and MC.UsingMeshShadowMap() ) then return 1 end
	if not ( MC.MeshShadowLightDirection and MC.TraceBlockRay and MC.WorldToCell ) then return 1 end

	local strength = convarFloat( MC.MeshShadowMapStrength, 0.75, 0, 1 )
	local sunDir, scale = MC.MeshShadowLightDirection()
	strength = strength * math.Clamp( tonumber( scale ) or 1, 0, 1 )
	if strength <= 0 or not sunDir then return 1 end

	local frame = FrameNumber and FrameNumber() or 0
	if frame ~= cacheFrame then
		cacheFrame = frame
		cacheFactor = {}
	end
	local key
	local bx, by, bz = MC.WorldToCell( pos )
	if bx ~= nil and MC.CellKey then
		key = MC.CellKey( bx, by, bz )
		local cached = cacheFactor[key]
		if cached then return cached end
	end

	local factor = 1
	if sunOccluded( pos, sunDir ) then
		local tint = convarFloat( MC.MeshShadowMapTint, 0.6, 0, 1 )
		factor = 1 - strength * ( 1 - tint )
	end
	if key ~= nil then cacheFactor[key] = factor end
	return factor
end

-- Applies the directional shadow to a MC.SampleLighting result. Block light
-- and self emission are omnidirectional, so they set a floor the shadow can
-- never darken below — a torch-lit particle stays torch-lit in the shade.
function MC.ApplySunShadowToBrightness( pos, brightness, level, blockLight, emission )
	brightness = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
	local factor = MC.SampleSunShadow( pos )
	if factor >= 1 then return brightness end

	local shadowed = brightness * factor
	local floorLevel = math.max( tonumber( blockLight ) or 0, tonumber( emission ) or 0 )
	level = tonumber( level ) or 0
	if level > 0 and floorLevel > 0 then
		shadowed = math.max( shadowed, brightness * math.Clamp( floorLevel / level, 0, 1 ) )
	end
	return shadowed
end
