-- Experimental shadow map binding for GPU light texture chunks.
MC = MC or {}

local fallbackTexture
local fallbackReady = false
local mcShadowTexture
local mcShadowTextureSize = 0
local mcShadowDummyTexture
local mcShadowDummyTextureSize = 0
local mcShadowViewProj
local mcShadowForward
local mcShadowOrigin
local mcShadowZFar
local mcShadowStrengthScale = 1
local mcShadowNextUpdate = 0
local mapBindFrame = {}
local mapBindResult = {}
local mcShadowStats = {
	drawnChunks = 0,
	drawnMeshes = 0,
	lastUpdate = 0,
	lastError = nil,
}
-- Local copy of the tiny GShader matrix helper this shadow pass used to call.
-- Keeping it here makes the MC shadow map independent from the external
-- GShader/CSM addons while preserving the same matrix convention the shaders
-- were validated against.
local t0001 = { 0, 0, 0, 1 }
local function GetViewProjOrthoMatrix(viewSetup)
	local pos, ang = viewSetup.origin, viewSetup.angles
	local D = -ang:Forward()
	local R = ang:Right()
	local U = -ang:Up() -- In Gmod func cam.GetViewMatrix() local U = ang:Up()
	local P = -pos

	local mFirst = Matrix({
		{R.x, 	R.y, 	R.z,	0},
		{U.x, 	U.y, 	U.z,	0},
		{D.x, 	D.y, 	D.z,	0},
		t0001,
	})

	local mSecond = Matrix({
		{1, 	0, 		0, 		P.x},
		{0, 	1, 		0, 		P.y},
		{0, 	0, 		1, 		P.z},
		t0001,
	})

	mFirst:Mul(mSecond)

	local left = viewSetup.ortho.left
	local right = viewSetup.ortho.right
	local bottom = viewSetup.ortho.bottom
	local top = viewSetup.ortho.top
	local znear = viewSetup.znear
	local zfar = viewSetup.zfar
	local mProj = Matrix()

	mProj:SetUnpacked(
		2 / (right - left), 0, 					0, 					 (right + left) / (right - left),
		0, 					2 / (top - bottom), 0, 					 (top + bottom) / (top - bottom),
		0, 					0, 					-1 / (zfar - znear), -(zfar + znear) / (zfar - znear),
		0,		0,		0, 		1
	)

	mProj:InvertTR()

	mProj:Mul(mFirst)

	return mProj
end

local function convarBool( cv )
	return cv and cv.GetBool and cv:GetBool() == true
end

local function convarFloat( cv, fallback, minValue, maxValue )
	local value = cv and cv.GetFloat and cv:GetFloat() or fallback
	value = tonumber( value ) or fallback
	if minValue ~= nil and value < minValue then value = minValue end
	if maxValue ~= nil and value > maxValue then value = maxValue end
	return value
end

local function convarInt( cv, fallback, minValue, maxValue )
	local value = cv and cv.GetInt and cv:GetInt() or fallback
	value = tonumber( value ) or fallback
	value = math.floor( value + 0.5 )
	if minValue ~= nil and value < minValue then value = minValue end
	if maxValue ~= nil and value > maxValue then value = maxValue end
	return value
end

local function shadowMapEnabled()
	return convarBool( MC.MeshShadowMap )
end

-- Shadow technique switch:
--   "map" (default) = Photon-style distorted single shadow map: one depth
--     pass whose clip xy is radially warped so texel density is highest at
--     the camera and falls off CONTINUOUSLY with distance — no cascade seams.
--   "csm" = 3-cascade vertically stacked atlas (discrete quality steps, but
--     texel-snappable and therefore rock-stable under a stepped sun).
--   "height" = cached heightfield ray march; disables this file's depth pass.
local function shadowMapMode()
	local cv = MC.MeshShadowMode
	local mode = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or "map"
	if mode == "height" or mode == "heightfield" or mode == "hf" or mode == "2" then return "height" end
	if mode == "csm" or mode == "cascade" or mode == "cascades" or mode == "3" then return "csm" end
	if mode == "linear" or mode == "single" or mode == "debug" then return "linear" end
	return "distort"
end

function MC.MeshShadowMapMode()
	return shadowMapMode()
end

local function ensureFallbackShadowTexture()
	if fallbackTexture and fallbackReady then return fallbackTexture end
	if not ( GetRenderTarget and render and surface and cam ) then return nil end
	fallbackTexture = fallbackTexture or GetRenderTarget( "mc_mesh_shadow_map_fallback_white", 2, 2 )
	if not fallbackTexture then return nil end
	render.PushRenderTarget( fallbackTexture, 0, 0, 2, 2 )
		render.Clear( 255, 255, 255, 255, true, true )
		cam.Start2D()
			surface.SetDrawColor( 255, 255, 255, 255 )
			surface.DrawRect( 0, 0, 2, 2 )
		cam.End2D()
	render.PopRenderTarget()
	fallbackReady = true
	return fallbackTexture
end

local function mcShadowSize()
	-- Tile size. distort mode uses one size x size map; csm stacks three
	-- tiles into size x (3 * size). 4096 in csm mode means a 4096x12288 R32F
	-- target (~192MB VRAM + the dummy MRT slot) and needs a GPU with max
	-- texture dimension >= 12288 (any modern card; ancient DX10-era GPUs cap
	-- at 8192 and the RT creation will fail -> shadows disable cleanly).
	return convarInt( MC.MeshShadowMapSize, 2048, 512, 4096 )
end

-- Tile rows in the shadow target: 1 for the distorted single map, 3 for the
-- cascade atlas.
local function mcShadowTileRows( mode )
	return ( mode or shadowMapMode() ) == "csm" and 3 or 1
end

local mcShadowTextureRows = 0
local function ensureMCShadowTexture( rows )
	if not GetRenderTargetEx then return nil end
	local size = mcShadowSize()
	if mcShadowTexture and mcShadowTextureSize == size and mcShadowTextureRows == rows then return mcShadowTexture end

	IMAGE_FORMAT_R32F = IMAGE_FORMAT_R32F or 27
	-- Shadow target recipe:
	-- CLAMPS|CLAMPT|ANISOTROPIC|NOMIP|NOLOD|DEPTHRENDERTARGET|NODEPTHBUFFER
	local flags = bit.bor( 4, 8, 16, 256, 512, 65536, 8388608 )
	mcShadowTexture = GetRenderTargetEx(
		"mc_mesh_shadow_map4_" .. tostring( rows ) .. "x_" .. tostring( size ),
		size,
		size * rows,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		IMAGE_FORMAT_R32F
	)
	mcShadowTextureSize = mcShadowTexture and size or 0
	mcShadowTextureRows = mcShadowTexture and rows or 0
	return mcShadowTexture
end

local mcShadowDummyTextureRows = 0
local function ensureMCShadowDummyTexture( rows )
	if not GetRenderTargetEx then return nil end
	local size = mcShadowSize()
	if mcShadowDummyTexture and mcShadowDummyTextureSize == size and mcShadowDummyTextureRows == rows then return mcShadowDummyTexture end

	IMAGE_FORMAT_A8 = IMAGE_FORMAT_A8 or 8
	IMAGE_FORMAT_RGB565 = IMAGE_FORMAT_RGB565 or 4
	-- Dummy MRT slot 0 target (must match the real target's dimensions).
	local flags = bit.bor( 1, 4, 8, 256, 512, 32768, 262144, 8388608, 33554432, 536870912 )
	local isLinux = system and system.IsLinux and system.IsLinux() == true
	mcShadowDummyTexture = GetRenderTargetEx(
		"mc_mesh_shadow_map4_dummy_" .. tostring( rows ) .. "x_" .. tostring( size ),
		size,
		size * rows,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		isLinux and IMAGE_FORMAT_RGB565 or IMAGE_FORMAT_A8
	)
	mcShadowDummyTextureSize = mcShadowDummyTexture and size or 0
	mcShadowDummyTextureRows = mcShadowDummyTexture and rows or 0
	return mcShadowDummyTexture
end

-- Depth writer materials: same pixel shader (linear world-space depth to
-- COLOR1), but distort mode's vertex shader warps the clip position with the
-- Photon distortion formula. Cached per mode.
local mcShadowDepthMaterials = {}
local function ensureMCShadowDepthMaterial( mode )
	local path = mode == "distort" and "pp/mc_shadow_depth5_distort" or "pp/mc_shadow_depth4"
	local cached = mcShadowDepthMaterials[path]
	if cached and not cached:IsError() then return cached end
	if not Material then return nil end
	local material = Material( path )
	if material and not material:IsError() then
		-- Bind the block atlas so the depth pixel shader can alpha-test
		-- casters; cutout blocks (torches, leaves, panes) then only shadow
		-- where their texels are actually opaque.
		local baseTex = MC.Material and MC.Material.GetTexture and MC.Material:GetTexture( "$basetexture" ) or nil
		if baseTex and not ( baseTex.IsError and baseTex:IsError() ) then
			material:SetTexture( "$basetexture", baseTex )
		end
		mcShadowDepthMaterials[path] = material
		return material
	end
	return nil
end

local function usingGpuLightTexture()
	return MC.UsingGpuLightTexture and MC.UsingGpuLightTexture() == true
end

local function mcShadowSourceEnabled()
	-- Vanilla lighting mode has no shadow consumer (its shader never samples
	-- the shadow map), so the per-frame depth pass would be wasted GPU work.
	if MC.UsingVanillaLightMaterial and MC.UsingVanillaLightMaterial() then return false end
	return shadowMapEnabled() and shadowMapMode() ~= "height" and usingGpuLightTexture()
end

local function normalizedSunDirection()
	local info = util and util.GetSunInfo and util.GetSunInfo() or nil
	local dir = info and info.direction or nil
	if not dir or dir:IsZero() then
		dir = Vector( -0.35, -0.45, -0.82 )
	end
	return dir:GetNormalized()
end

-- Direction toward the active light body (sun by day, moon at night) plus a
-- strength scale that fades shadows out around the horizon and keeps moon
-- shadows weak. Falls back to the map sun when the day cycle is off.
--
-- The direction fed into the shadow matrix is QUANTIZED to whole angle steps
-- (mc_shadow_sun_step): a continuously moving sun rotates the light-space
-- texel grid every frame, which makes every shadow edge crawl by up to one
-- texel — invisible at small coverage radii, but the texel's world size grows
-- linearly with mc_shadow_distance and the crawl becomes visible jitter.
-- Holding the direction still between steps lets the ortho-window texel snap
-- and the depth-pass signature keep the map bit-identical, so shadows only
-- move in discrete, infrequent jumps. The strength scale stays continuous so
-- horizon fades don't step.
local function shadowLightDirection()
	if MC.DayCycleEnabled and MC.DayCycleEnabled() and MC.DayCycleSunVector then
		local sunDir, elevation = MC.DayCycleSunVector()
		local strengthElevation = math.abs( elevation )
		local stepDeg = convarFloat( MC.MeshShadowMapSunStep, 1, 0, 30 )
		if stepDeg > 0 and MC.DayCycleCelestialAngle then
			local step = stepDeg / 360
			local angle = math.floor( MC.DayCycleCelestialAngle() / step + 0.5 ) * step * math.pi * 2
			elevation = math.cos( angle )
			sunDir = Vector( -math.sin( angle ), 0, elevation )
		end
		local isMoon = false
		if elevation < 0 then
			isMoon = true
			sunDir = Vector( -sunDir.x, -sunDir.y, -sunDir.z )
		end
		local tilt = convarFloat( MC.DayCycleSunTilt, 0.2, 0, 1 )
		local dir = Vector( sunDir.x, tilt, sunDir.z )
		dir:Normalize()
		local scale = math.Clamp( strengthElevation / 0.25, 0, 1 )
		if isMoon then
			scale = scale * convarFloat( MC.DayCycleMoonShadow, 0.3, 0, 1 )
		end
		return dir, scale
	end
	return normalizedSunDirection(), 1
end

-- Shared with the heightfield shadow module: direction toward the active
-- light body plus the horizon/moon strength scale.
MC.MeshShadowLightDirection = shadowLightDirection

-- Cascade geometry: three sun-space ortho windows rendered into one
-- vertically stacked atlas (tile k on rows [k*S, (k+1)*S) of an S x 3S
-- target). Tile 0 is the finest (radius = distance / ratio^2), tile 1 covers
-- distance / ratio, tile 2 the full mc_shadow_distance. Every tile shares the
-- same camera BASIS (angles) and pull-back, so the normalized linear
-- light-space depth written by the depth shader is valid for all three tiles
-- (a cascade's window center moves orthogonally to the light direction and
-- cancels out of the depth dot product); only the XY window mapping differs,
-- which the chunk shader resolves as an affine clip-space remap uploaded
-- through $invviewprojmat (c15..c18).
local function cascadeRadii()
	local far = convarFloat( MC.MeshShadowMapDistance, 4096, 512, 32768 )
	local ratio = convarFloat( MC.MeshShadowCascadeRatio, 3, 1.5, 8 )
	local mid = far / ratio
	local near = math.max( far / ( ratio * ratio ), 256 )
	return near, mid, far
end

local function makeMCShadowCascades( rtSize, mode )
	local eye = EyePos()
	local sunDir, strengthScale = shadowLightDirection()
	local r0, r1, r2 = cascadeRadii()
	-- distort mode renders ONE full-distance window (the vertex/pixel warp
	-- supplies the near-camera detail); csm renders all three.
	local radii = ( mode == "csm" ) and { r0, r1, r2 } or { r2 }
	local lookDir = Vector( -sunDir.x, -sunDir.y, -sunDir.z )
	local angles = lookDir:Angle()
	local right = angles:Right()
	local up = angles:Up()
	local zfar = r2 * 3
	local f = eye:Dot( lookDir )

	local setups, viewProjs, origins = {}, {}, {}
	for k = 1, #radii do
		local radius = radii[k]
		local anchor = eye
		if mode == "csm" then
			-- Snap each ortho window to whole shadow-map texels in light
			-- space so the shadow edges do not crawl while the camera moves.
			-- The distorted map CANNOT snap (its warp center must follow the
			-- camera continuously, Photon behaviour); its stability comes
			-- from the high texel density near the camera instead.
			local texelWorld = ( radius * 2 ) / math.max( rtSize or 0, 1 )
			if texelWorld > 0 then
				local r = math.floor( eye:Dot( right ) / texelWorld + 0.5 ) * texelWorld
				local u = math.floor( eye:Dot( up ) / texelWorld + 0.5 ) * texelWorld
				anchor = right * r + up * u + lookDir * f
			end
		end
		local origin = anchor + sunDir * r2

		local viewSetup = {
			origin = origin,
			angles = angles,
			znear = 0.01,
			zfar = zfar,
			ortho = {
				left = -radius,
				right = radius,
				bottom = radius,
				top = -radius,
			},
			x = 0,
			y = ( k - 1 ) * rtSize,
			w = rtSize,
			h = rtSize,
			drawviewer = false,
			drawviewmodel = false,
			dopostprocess = false,
			bloomtone = false,
			viewid = 6,
		}
		setups[k] = viewSetup
		viewProjs[k] = GetViewProjOrthoMatrix( viewSetup )
		origins[k] = origin
	end

	return {
		setups = setups,
		viewProjs = viewProjs,
		origins = origins,
		radii = radii,
		lookDir = lookDir,
		-- Canonical depth origin: the last (largest) window's camera. The
		-- depth shader and every tile's compare use this one origin.
		origin = origins[#origins],
		zfar = zfar,
		strengthScale = strengthScale,
	}
end

-- Clip-space XY of a world point under a cascade view-proj (VMatrix
-- convention: clip_i = sum_j M[i][j] * p_j; ortho w row is 0 0 0 1).
local function clipXY( m, p )
	local x = m:GetField( 1, 1 ) * p.x + m:GetField( 1, 2 ) * p.y + m:GetField( 1, 3 ) * p.z + m:GetField( 1, 4 )
	local y = m:GetField( 2, 1 ) * p.x + m:GetField( 2, 2 ) * p.y + m:GetField( 2, 3 ) * p.z + m:GetField( 2, 4 )
	return x, y
end

-- Affine remap rows for the shader's cascade table: clip_k = clip_0 * scale
-- + offset (exact — all cascades share one camera basis). Measured
-- numerically from the actual matrices so no assumption about the ortho
-- builder's sign conventions can drift out of sync.
local mcCsmRow1, mcCsmRow2, mcCsmNearRadius
local function computeCsmRows( cascades )
	if #cascades.viewProjs < 3 then
		-- Distorted single map: no remap rows. c17.x still carries the window
		-- half radius (the shader's distortion path derives its local filter
		-- footprint from it) and c18 the border fade.
		mcCsmRow1 = { 0, 0, 0, 0 }
		mcCsmRow2 = { 0, 0, 0, 0 }
		mcCsmNearRadius = cascades.radii[1]
		return
	end
	local eye = EyePos()
	local probe = eye + cascades.setups[1].angles:Right() * 128
	local m0 = cascades.viewProjs[1]
	local p0x, p0y = clipXY( m0, eye )
	local q0x = clipXY( m0, probe )
	local rows = {}
	for k = 2, 3 do
		local mk = cascades.viewProjs[k]
		local pkx, pky = clipXY( mk, eye )
		local qkx = clipXY( mk, probe )
		local denom = q0x - p0x
		local scale = 0
		if math.abs( denom ) > 1e-9 then scale = ( qkx - pkx ) / denom end
		rows[k - 1] = { scale, pkx - scale * p0x, pky - scale * p0y, cascades.radii[k] }
	end
	mcCsmRow1 = rows[1]
	mcCsmRow2 = rows[2]
	mcCsmNearRadius = cascades.radii[1]
end

-- The c15..c18 table uploaded through $invviewprojmat. Row 4 carries live
-- convar-derived values (selection pad, far-tile border fade), so the matrix
-- is refreshed at bind time rather than only when the depth pass re-renders.
local mcCsmTableMatrix
local function csmTableMatrix( filterKernelUV, biasKernelUV )
	if not mcCsmRow1 then return nil end
	local fade = convarFloat( MC.MeshShadowMapEdgeFade, 0.1, 0, 0.5 )
	-- PCF taps are the only receiver-space footprint in the clean path.
	local pad = filterKernelUV
	mcCsmTableMatrix = mcCsmTableMatrix or Matrix()
	mcCsmTableMatrix:SetUnpacked(
		mcCsmRow1[1], mcCsmRow1[2], mcCsmRow1[3], mcCsmRow1[4],
		mcCsmRow2[1], mcCsmRow2[2], mcCsmRow2[3], mcCsmRow2[4],
		mcCsmNearRadius, 0, 0, 0,
		pad, fade, biasKernelUV, 0
	)
	return mcCsmTableMatrix
end

local function shadowKernelUVs()
	local softness = convarFloat( MC.MeshShadowMapSoftness, 0.5, 0, 32 )
	local texelUV = mcShadowTextureSize > 0 and 1 / mcShadowTextureSize or 0
	return softness * texelUV, texelUV
end

-- Last-rendered depth-pass signature. The atlas content only depends on the
-- light direction, the three texel-snapped cascade windows, the RT size, the
-- caster radius and the chunk geometry version — while all of those hold
-- (static/stepped sun, camera inside one snapped texel of every cascade, no
-- mesh edits) re-rendering would reproduce the exact same texels, so the
-- pass is skipped.
local sigValid = false
local sigOrigins = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local sigOriginCount = 0
local sigMode = ""
local sigDirX, sigDirY, sigDirZ = 0, 0, 0
local sigZFar, sigSize, sigCasterDist = 0, 0, 0
local sigRadius0, sigRadius1 = 0, 0
local sigDrawVersion = -1

local function cascadeOriginsMatchSig( origins )
	if #origins ~= sigOriginCount then return false end
	for k = 1, #origins do
		local o = origins[k]
		local base = ( k - 1 ) * 3
		if sigOrigins[base + 1] ~= o.x or sigOrigins[base + 2] ~= o.y or sigOrigins[base + 3] ~= o.z then
			return false
		end
	end
	return true
end

local function storeCascadeOriginsSig( origins )
	sigOriginCount = #origins
	for k = 1, #origins do
		local o = origins[k]
		local base = ( k - 1 ) * 3
		sigOrigins[base + 1], sigOrigins[base + 2], sigOrigins[base + 3] = o.x, o.y, o.z
	end
end

-- Defined before renderMCShadowMap so the signature skip captures the local
-- (not a nil global) as its upvalue.
local function mcShadowReady()
	return mcShadowTexture ~= nil and mcShadowViewProj ~= nil
		and mcShadowForward ~= nil and mcShadowOrigin ~= nil
end

local function setChunkMeshCullMode()
	if not render.CullMode then return false end
	local mode = MATERIAL_CULLMODE_CCW or 0
	local cv = MC.MeshCullMode
	local value = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or "ccw"
	if value ~= "ccw" and value ~= "counterclockwise" and value ~= "counter-clockwise" then
		mode = MATERIAL_CULLMODE_CW or 1
	end
	render.CullMode( mode )
	return true
end

local function restoreDefaultCullMode()
	if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
end

local function drawShadowMeshList( list )
	local drawn = 0
	for i = 1, #list do
		local entry = list[i]
		local meshObj = entry
		if type( entry ) == "table" then meshObj = entry.mesh end
		if meshObj and meshObj.Draw then
			meshObj:Draw()
			drawn = drawn + 1
		end
	end
	return drawn
end

local function drawMCShadowCasters( material, maxDistSqr )
	local store = MC.Meshes
	if not ( store and MC.OpaqueChunkDrawEntries ) then return 0, 0 end
	local entries, count = MC.OpaqueChunkDrawEntries()
	local eye = EyePos()
	local eyeX, eyeY, eyeZ = eye.x, eye.y, eye.z
	local pushMatrix, popMatrix = cam.PushModelMatrix, cam.PopModelMatrix
	local drawnChunks, drawnMeshes = 0, 0

	render.SetMaterial( material )
	for i = 1, count do
		local e = entries[i]
		if store[e.key] == e.list then
			local within = true
			if maxDistSqr and maxDistSqr > 0 then
				local dx, dy, dz = e.x - eyeX, e.y - eyeY, e.z - eyeZ
				within = dx * dx + dy * dy + dz * dz <= maxDistSqr
			end
			if within then
				pushMatrix( e.matrix )
					local n = drawShadowMeshList( e.list )
				popMatrix()
				if n > 0 then
					drawnChunks = drawnChunks + 1
					drawnMeshes = drawnMeshes + n
				end
			end
		end
	end

	return drawnChunks, drawnMeshes
end

local function renderMCShadowMap( force )
	if not mcShadowSourceEnabled() then return false end
	local now = CurTime()
	local interval = convarFloat( MC.MeshShadowMapUpdateInterval, 0, 0, 1 )
	if not force and interval > 0 and mcShadowNextUpdate > now then return true end
	mcShadowNextUpdate = now + interval

	local mode = shadowMapMode()
	local rows = mcShadowTileRows( mode )
	local rt = ensureMCShadowTexture( rows )
	local dummyRT = ensureMCShadowDummyTexture( rows )
	local material = ensureMCShadowDepthMaterial( mode )
	if not ( rt and dummyRT and material ) then
		mcShadowStats.lastError = "missing_rt_or_material"
		return false
	end

	local cascades = makeMCShadowCascades( mcShadowTextureSize, mode )
	if not ( cascades and #cascades.viewProjs == #cascades.setups and cascades.viewProjs[#cascades.setups] ) then
		mcShadowStats.lastError = "missing_shadow_matrix"
		return false
	end
	local lightForward = cascades.lookDir
	local lightOrigin = cascades.origin
	local lightZFar = cascades.zfar
	mcShadowStrengthScale = cascades.strengthScale or 1
	if mcShadowStrengthScale <= 0 then
		-- Twilight gap: sun and moon both below the fade threshold. Skip the
		-- depth pass; binds still run and see an effective strength of 0.
		mcShadowStats.drawnChunks = 0
		mcShadowStats.drawnMeshes = 0
		mcShadowStats.lastUpdate = now
		mcShadowStats.lastError = nil
		return true
	end

	-- Depth-pass output is fully determined by the signature below; while it
	-- holds (static sun + camera within one snapped texel of every cascade +
	-- unchanged chunk geometry) the previous atlas is still exact, so keep it.
	-- With the sun angle stepped this makes standing still / looking around
	-- free between steps.
	local drawVersion = MC.ChunkDrawListVersion and MC.ChunkDrawListVersion() or -1
	local casterDist = convarFloat( MC.MeshShadowMapCasterDistance, 4608, 0, 65536 )
	if not force and sigValid and mcShadowReady()
		and sigMode == mode
		and sigDrawVersion == drawVersion
		and cascadeOriginsMatchSig( cascades.origins )
		and sigDirX == lightForward.x and sigDirY == lightForward.y and sigDirZ == lightForward.z
		and sigZFar == lightZFar
		and sigSize == mcShadowTextureSize
		and sigRadius0 == cascades.radii[1] and sigRadius1 == ( cascades.radii[2] or 0 )
		and sigCasterDist == casterDist then
		return true
	end
	sigValid = false

	local shadowViewProj = cascades.viewProjs[1].GetTransposed and cascades.viewProjs[1]:GetTransposed() or cascades.viewProjs[1]
	local invZFar = lightZFar > 0 and 1 / lightZFar or 0

	-- The depth pixel shader rebuilds the same normalized linear light-space
	-- depth the chunk shader compares against.
	material:SetFloat( "$c0_x", lightForward.x )
	material:SetFloat( "$c0_y", lightForward.y )
	material:SetFloat( "$c0_z", lightForward.z )
	material:SetFloat( "$c0_w", invZFar )
	material:SetFloat( "$c1_x", lightOrigin.x )
	material:SetFloat( "$c1_y", lightOrigin.y )
	material:SetFloat( "$c1_z", lightOrigin.z )

	local setCullMode = false
	local pushedRT = false
	local startedCam = false
	local setMRT = false
	local ok, err = xpcall( function()
		render.PushRenderTarget( rt )
			pushedRT = true
			render.Clear( 255, 255, 255, 255, true, true )
			render.ClearDepth()
		render.PopRenderTarget()
		pushedRT = false

		render.PushRenderTarget( dummyRT )
			pushedRT = true
			render.Clear( 0, 0, 0, 0, true, true )
			render.ClearDepth()
		render.PopRenderTarget()
		pushedRT = false

		render.SetRenderTargetEx( 0, dummyRT )
		setMRT = true
		render.OverrideDepthEnable( true, true )
		setCullMode = setChunkMeshCullMode()
		local totalChunks, totalMeshes = 0, 0
		for k = 1, #cascades.setups do
			cam.Start( cascades.setups[k] )
				startedCam = true
				-- Bind the real shadow target at MRT slot 1 inside the camera
				-- block so the depth shader can write linear depth to COLOR1.
				render.SetRenderTargetEx( 1, rt )
				-- Inner cascades only need casters close enough to reach their
				-- window: radius + generous slack for long grazing-sun shadows.
				local radius = cascades.radii[k]
				local cullDist = casterDist
				if cullDist <= 0 or radius * 2 + 2048 < cullDist then
					cullDist = radius * 2 + 2048
				end
				local maxDistSqr = cullDist > 0 and cullDist * cullDist or nil
				local chunks, meshes = drawMCShadowCasters( material, maxDistSqr )
				totalChunks = totalChunks + chunks
				totalMeshes = totalMeshes + meshes
			cam.End()
			startedCam = false
		end
		mcShadowStats.drawnChunks = totalChunks
		mcShadowStats.drawnMeshes = totalMeshes
		if setCullMode then restoreDefaultCullMode() end
		setCullMode = false
		render.OverrideDepthEnable( false, false )
		render.SetRenderTargetEx( 1 )
		render.SetRenderTargetEx( 0 )
		setMRT = false
	end, debug and debug.traceback or tostring )

	if not ok then
		if startedCam then pcall( cam.End ) end
		if setCullMode then restoreDefaultCullMode() end
		render.OverrideDepthEnable( false, false )
		if setMRT then
			pcall( render.SetRenderTargetEx, 1 )
			pcall( render.SetRenderTargetEx, 0 )
		end
		if pushedRT then pcall( render.PopRenderTarget ) end
		mcShadowStats.lastError = tostring( err )
		return false
	end

	computeCsmRows( cascades )
	mcShadowViewProj = shadowViewProj
	mcShadowForward = lightForward
	mcShadowOrigin = lightOrigin
	mcShadowZFar = lightZFar
	MC.MCShadowMapTexture = rt
	MC.MCShadowMapViewProj = shadowViewProj
	MC.MCShadowMapForward = lightForward
	MC.MCShadowMapOrigin = lightOrigin
	MC.MCShadowMapZFar = lightZFar
	mcShadowStats.lastUpdate = now
	mcShadowStats.lastError = nil
	-- Only freeze the signature when the pass actually drew casters (or the
	-- world is empty): a zero-caster render (e.g. during a Lua autorefresh
	-- window while cl_draw reloads) must keep re-rendering every frame like
	-- the old path did, otherwise an empty white map gets locked in.
	local worldEmpty = MC.Meshes == nil or next( MC.Meshes ) == nil
	if mcShadowStats.drawnChunks > 0 or worldEmpty then
		sigValid = true
		sigMode = mode
		storeCascadeOriginsSig( cascades.origins )
		sigDirX, sigDirY, sigDirZ = lightForward.x, lightForward.y, lightForward.z
		sigZFar = lightZFar
		sigSize = mcShadowTextureSize
		sigRadius0, sigRadius1 = cascades.radii[1], cascades.radii[2] or 0
		sigCasterDist = casterDist
		sigDrawVersion = drawVersion
	end
	return true
end

function MC.UsingMeshShadowMap()
	if not ( shadowMapEnabled() and usingGpuLightTexture() ) then return false end
	if shadowMapMode() == "height" then
		return MC.UsingHeightfieldShadow and MC.UsingHeightfieldShadow() == true
	end
	return mcShadowReady()
end

local function bindShadowParams( material, enabled, isFancy )
	local strength = enabled and convarFloat( MC.MeshShadowMapStrength, 0.75, 0, 1 ) or 0
	-- Day cycle: shadows fade at the horizon and stay weak under moonlight.
	strength = strength * math.Clamp( mcShadowStrengthScale, 0, 1 )
	local depthOnlyBias = convarFloat( MC.MeshShadowMapBias, 0, 0, 0.05 )

	-- $c0_*..$c2_* land in pixel shader constants c0..c2 (screenspace_general
	-- uploads $c0..$c3 to c0..c3; $viewprojmat goes to c11..c14).
	material:SetFloat( "$c0_x", strength )
	-- Peter-Panning fix: bias changes only the reference depth. Shadow UV is
	-- always projected from the original, unshifted receiver world position.
	material:SetFloat( "$c0_y", depthOnlyBias )
	material:SetFloat( "$c0_z", enabled and 1 or 0 )
	-- Technique flag read by the chunk shaders: -3 = Photon-style distorted
	-- single map, -2 = 3-cascade atlas.
	local mode = shadowMapMode()
	material:SetFloat( "$c0_w", mode == "csm" and -2 or ( mode == "linear" and -4 or -3 ) )

	if mcShadowForward and mcShadowOrigin then
		local invZFar = ( mcShadowZFar and mcShadowZFar > 0 ) and 1 / mcShadowZFar or 0
		local filterKernelUV = shadowKernelUVs()
		material:SetFloat( "$c1_x", mcShadowForward.x )
		material:SetFloat( "$c1_y", mcShadowForward.y )
		material:SetFloat( "$c1_z", mcShadowForward.z )
		material:SetFloat( "$c1_w", invZFar )
		material:SetFloat( "$c2_x", mcShadowOrigin.x )
		material:SetFloat( "$c2_y", mcShadowOrigin.y )
		material:SetFloat( "$c2_z", mcShadowOrigin.z )
		material:SetFloat( "$c2_w", filterKernelUV )
	end

	-- $c3 is reserved for the fancy shader variant. Only that material may
	-- define it: uploading c3 on the plain material would overwrite one of
	-- its compiler-placed inline literal constants.
	if isFancy then
		material:SetFloat( "$c3_x", convarFloat( MC.MeshShadowMapTint, 0.6, 0, 1 ) )
		material:SetFloat( "$c3_y", convarFloat( MC.MeshShadowMapEdgeFade, 0.1, 0, 0.5 ) )
		material:SetFloat( "$c3_z", convarFloat( MC.MeshShadowMapFaceShade, 0.65, 0, 1 ) )
		material:SetFloat( "$c3_w", convarFloat( MC.MeshShadowMapWarmth, 0.35, 0, 1 ) )
	end
end

-- Fast low-sample material: its shader reads only $c0 (day-cycle sky
-- brightness / ambient floor / night blue / tint strength). It must never
-- go through the shadow bind below — that would clobber $c0 with shadow
-- semantics and upload $viewprojmat over its compiler literals.
local function bindFastLightParams( material )
	local frame = FrameNumber and FrameNumber() or 0
	if mapBindFrame[material] == frame then return true end
	mapBindFrame[material] = frame
	if not material.SetFloat then return true end
	local sky, night = 1, 0
	if MC.DayCycleEnabled and MC.DayCycleEnabled() then
		-- In global-lightmap mode the light texture's sky channel is raw
		-- time-independent exposure, so the day/night brightness must come
		-- in through this constant; the fallback writer already bakes the
		-- day-cycle brightness into the channel, so scaling again here
		-- would darken nights twice.
		if MC.DayCycleSkyBrightness and MC.GlobalLightmapActive and MC.GlobalLightmapActive() then
			sky = tonumber( MC.DayCycleSkyBrightness() ) or 1
		end
		if MC.DayCycleNightBlend then
			night = ( tonumber( MC.DayCycleNightBlend() ) or 0 ) * convarFloat( MC.DayCycleNightTint, 0.85, 0, 1 )
		end
	end
	material:SetFloat( "$c0_x", math.Clamp( sky, 0, 1 ) )
	material:SetFloat( "$c0_y", convarFloat( MC.MeshGpuLightmapAmbient, 0.04, 0, 1 ) )
	material:SetFloat( "$c0_z", math.Clamp( night, 0, 1 ) )
	material:SetFloat( "$c0_w", convarFloat( MC.MeshGpuLightmapTorchWarmth, 0.7, 0, 1 ) )
	return true
end

function MC.BindMeshShadowMap( material, force )
	if not material then return false end
	-- The vanilla materials' shaders read NO constant registers: any SetFloat
	-- / SetMatrix here would define those material vars and make the engine
	-- upload c0..c3 / c11..c14 over compiler-placed literal constants (same
	-- hazard the fast/height dispatches below guard against).
	if MC.MaterialGpuLightTextureVanilla and ( material == MC.MaterialGpuLightTextureVanilla
		or material == MC.MaterialGpuLightTextureVanillaTranslucent ) then
		return true
	end
	if MC.MaterialGpuLightTextureFast and material == MC.MaterialGpuLightTextureFast then
		return bindFastLightParams( material )
	end
	-- The heightfield material reads a different constant layout and must
	-- never receive $viewprojmat (the engine would upload c11..c14 over its
	-- compiler literals), so dispatch by material identity: if the height
	-- material failed to create and the selector fell back to plain/fancy,
	-- those still bind safely through the map path below.
	if MC.MaterialGpuLightTextureHeight and material == MC.MaterialGpuLightTextureHeight
		and MC.BindMeshHeightfieldShadow then
		return MC.BindMeshHeightfieldShadow( material )
	end
	-- Shadow constants are identical for every chunk, but this is called from
	-- the per-chunk draw path (478 chunks x 12 SetFloat + SetMatrix +
	-- SetTexture used to dominate the frame). Bind once per frame per
	-- material; repeat calls in the same frame are one table lookup.
	local frame = FrameNumber and FrameNumber() or 0
	if not force and mapBindFrame[material] == frame then
		return mapBindResult[material] == true
	end
	mapBindFrame[material] = frame

	local enabled = MC.UsingMeshShadowMap and MC.UsingMeshShadowMap() == true
	local tex
	local matrix

	if enabled then
		tex = mcShadowTexture
		matrix = mcShadowViewProj
	end

	tex = tex or ensureFallbackShadowTexture()
	if material.SetTexture and tex then
		material:SetTexture( "$texture3", tex )
	end

	if material.SetMatrix and matrix then
		material:SetMatrix( "$viewprojmat", matrix )
		-- Cascade remap table -> c15..c18. The chunk shaders DECLARE and USE
		-- those registers (see the .fxc sources), so the engine upload is safe
		-- there — but it must never land on shaders that leave c15..c18 free
		-- for compiler literals (vanilla/fast/height already returned above).
		local filterKernelUV, biasKernelUV = shadowKernelUVs()
		local csmTable = csmTableMatrix( filterKernelUV, biasKernelUV )
		if csmTable then
			material:SetMatrix( "$invviewprojmat", csmTable )
		end
	end
	if material.SetFloat then
		local isFancy = ( MC.MaterialGpuLightTextureFancy ~= nil and material == MC.MaterialGpuLightTextureFancy )
			or ( MC.MaterialGpuLightTextureFancyLinearDebug ~= nil and material == MC.MaterialGpuLightTextureFancyLinearDebug )
			or ( MC.MaterialGpuLightTextureFancyPpFix ~= nil and material == MC.MaterialGpuLightTextureFancyPpFix )
			or ( MC.MaterialGpuLightTextureTranslucent ~= nil and material == MC.MaterialGpuLightTextureTranslucent )
			or ( MC.MaterialGpuLightTextureTranslucentLinearDebug ~= nil and material == MC.MaterialGpuLightTextureTranslucentLinearDebug )
			or ( MC.MaterialGpuLightTextureTranslucentPpFix ~= nil and material == MC.MaterialGpuLightTextureTranslucentPpFix )
		bindShadowParams( material, enabled and tex ~= nil and matrix ~= nil, isFancy )
	end
	mapBindResult[material] = enabled
	return enabled
end

function MC.ClearMeshShadowMapFallback()
	fallbackTexture = nil
	fallbackReady = false
end

function MC.MeshShadowMapStats()
	return mcShadowStats
end

function MC.UpdateMeshShadowMap( force )
	return renderMCShadowMap( force )
end

hook.Remove( "PreRender", "mc_mesh_shadow_map_render" )
hook.Add( "PreRender", "mc_mesh_shadow_map_render", function()
	renderMCShadowMap()
end )

if cvars and cvars.AddChangeCallback then
	local function rebindAllShadowMaterials()
		if not MC.BindMeshShadowMap then return end
		if MC.MaterialGpuLightTexture then MC.BindMeshShadowMap( MC.MaterialGpuLightTexture, true ) end
		if MC.MaterialGpuLightTextureLinearDebug then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureLinearDebug, true ) end
		if MC.MaterialGpuLightTexturePpFix then MC.BindMeshShadowMap( MC.MaterialGpuLightTexturePpFix, true ) end
		if MC.MaterialGpuLightTextureFancy then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureFancy, true ) end
		if MC.MaterialGpuLightTextureFancyLinearDebug then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureFancyLinearDebug, true ) end
		if MC.MaterialGpuLightTextureFancyPpFix then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureFancyPpFix, true ) end
		if MC.MaterialGpuLightTextureTranslucent then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureTranslucent, true ) end
		if MC.MaterialGpuLightTextureTranslucentLinearDebug then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureTranslucentLinearDebug, true ) end
		if MC.MaterialGpuLightTextureTranslucentPpFix then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureTranslucentPpFix, true ) end
		if MC.MaterialGpuLightTextureHeight and MC.BindMeshHeightfieldShadow then
			MC.BindMeshHeightfieldShadow( MC.MaterialGpuLightTextureHeight )
		end
	end
	cvars.AddChangeCallback( "mc_shadow", function()
		rebindAllShadowMaterials()
	end, "mc_shadow_refresh" )
	cvars.AddChangeCallback( "mc_shadow_mode", function()
		mcShadowNextUpdate = 0
		if MC.MarkHeightfieldShadowDirty then MC.MarkHeightfieldShadowDirty() end
		rebindAllShadowMaterials()
	end, "mc_shadow_mode_refresh" )
	cvars.AddChangeCallback( "mc_shadow_facefix", function()
		rebindAllShadowMaterials()
	end, "mc_shadow_facefix_refresh" )
end
