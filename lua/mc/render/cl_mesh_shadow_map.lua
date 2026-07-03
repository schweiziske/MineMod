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
local mcShadowDepthMaterial
local mcShadowNextUpdate = 0
local mcShadowStats = {
	drawnChunks = 0,
	drawnMeshes = 0,
	lastUpdate = 0,
	lastError = nil,
}

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

local function shadowMapSource()
	local cv = MC.MeshShadowMapSource
	local source = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or "mc"
	if source == "combined" or source == "world" or source == "shadowmap" or source == "csm" then return "combined" end
	if source == "screen" or source == "screenspace" then return "screen" end
	return "mc"
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
	return convarInt( MC.MeshShadowMapSize, 2048, 512, 4096 )
end

local function ensureMCShadowTexture()
	if not GetRenderTargetEx then return nil end
	local size = mcShadowSize()
	if mcShadowTexture and mcShadowTextureSize == size then return mcShadowTexture end

	IMAGE_FORMAT_R32F = IMAGE_FORMAT_R32F or 27
	-- Same recipe as the CSM addon's _rt_CSM shadow target:
	-- CLAMPS|CLAMPT|ANISOTROPIC|NOMIP|NOLOD|DEPTHRENDERTARGET|NODEPTHBUFFER
	local flags = bit.bor( 4, 8, 16, 256, 512, 65536, 8388608 )
	mcShadowTexture = GetRenderTargetEx(
		"mc_mesh_shadow_map2_" .. tostring( size ),
		size,
		size,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		IMAGE_FORMAT_R32F
	)
	mcShadowTextureSize = mcShadowTexture and size or 0
	return mcShadowTexture
end

local function ensureMCShadowDummyTexture()
	if not GetRenderTargetEx then return nil end
	local size = mcShadowSize()
	if mcShadowDummyTexture and mcShadowDummyTextureSize == size then return mcShadowDummyTexture end

	IMAGE_FORMAT_A8 = IMAGE_FORMAT_A8 or 8
	IMAGE_FORMAT_RGB565 = IMAGE_FORMAT_RGB565 or 4
	-- Same recipe as the CSM addon's _rt_CSM_dummy MRT slot 0 target.
	local flags = bit.bor( 1, 4, 8, 256, 512, 32768, 262144, 8388608, 33554432, 536870912 )
	local isLinux = system and system.IsLinux and system.IsLinux() == true
	mcShadowDummyTexture = GetRenderTargetEx(
		"mc_mesh_shadow_map2_dummy_" .. tostring( size ),
		size,
		size,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		isLinux and IMAGE_FORMAT_RGB565 or IMAGE_FORMAT_A8
	)
	mcShadowDummyTextureSize = mcShadowDummyTexture and size or 0
	return mcShadowDummyTexture
end

local function ensureMCShadowDepthMaterial()
	if mcShadowDepthMaterial and not mcShadowDepthMaterial:IsError() then return mcShadowDepthMaterial end
	if not Material then return nil end
	mcShadowDepthMaterial = Material( "pp/mc_shadow_depth3" )
	if mcShadowDepthMaterial and not mcShadowDepthMaterial:IsError() then
		-- Bind the block atlas so the depth pixel shader can alpha-test
		-- casters; cutout blocks (torches, leaves, panes) then only shadow
		-- where their texels are opaque.
		local baseTex = MC.Material and MC.Material.GetTexture and MC.Material:GetTexture( "$basetexture" ) or nil
		if baseTex and not ( baseTex.IsError and baseTex:IsError() ) then
			mcShadowDepthMaterial:SetTexture( "$basetexture", baseTex )
		end
		return mcShadowDepthMaterial
	end
	return nil
end

local function usingGpuLightTexture()
	return MC.UsingGpuLightTexture and MC.UsingGpuLightTexture() == true
end

local function mcShadowSourceEnabled()
	return shadowMapEnabled() and shadowMapSource() == "mc" and usingGpuLightTexture()
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
local function shadowLightDirection()
	if MC.DayCycleEnabled and MC.DayCycleEnabled() and MC.DayCycleSunVector then
		local sunDir, elevation = MC.DayCycleSunVector()
		local isMoon = false
		if elevation < 0 then
			isMoon = true
			sunDir = Vector( -sunDir.x, -sunDir.y, -sunDir.z )
			elevation = -elevation
		end
		local tilt = convarFloat( MC.DayCycleSunTilt, 0.2, 0, 1 )
		local dir = Vector( sunDir.x, tilt, sunDir.z )
		dir:Normalize()
		local scale = math.Clamp( elevation / 0.25, 0, 1 )
		if isMoon then
			scale = scale * convarFloat( MC.DayCycleMoonShadow, 0.3, 0, 1 )
		end
		return dir, scale
	end
	return normalizedSunDirection(), 1
end

local function makeMCShadowViewSetup( rtSize )
	if not ( shaderlib and shaderlib.GetViewProjOrthoMatrix ) then return nil end
	local eye = EyePos()
	local sunDir, strengthScale = shadowLightDirection()
	local shadowDistance = convarFloat( MC.MeshShadowMapDistance, 4096, 512, 32768 )
	local lookDir = Vector( -sunDir.x, -sunDir.y, -sunDir.z )
	local angles = lookDir:Angle()
	local zfar = shadowDistance * 3

	-- Snap the ortho window to whole shadow-map texels in light space so the
	-- shadow edges do not crawl/shimmer while the camera moves.
	local texelWorld = ( shadowDistance * 2 ) / math.max( rtSize or 0, 1 )
	local anchor = eye
	if texelWorld > 0 then
		local right = angles:Right()
		local up = angles:Up()
		local r = math.floor( eye:Dot( right ) / texelWorld + 0.5 ) * texelWorld
		local u = math.floor( eye:Dot( up ) / texelWorld + 0.5 ) * texelWorld
		local f = eye:Dot( lookDir )
		anchor = right * r + up * u + lookDir * f
	end
	local origin = anchor + sunDir * shadowDistance

	local viewSetup = {
		origin = origin,
		angles = angles,
		znear = 0.01,
		zfar = zfar,
		ortho = {
			left = -shadowDistance,
			right = shadowDistance,
			bottom = shadowDistance,
			top = -shadowDistance,
		},
		x = 0,
		y = 0,
		w = rtSize,
		h = rtSize,
		drawviewer = false,
		drawviewmodel = false,
		dopostprocess = false,
		bloomtone = false,
		viewid = 6,
	}

	local viewProj = shaderlib.GetViewProjOrthoMatrix( viewSetup )
	return viewSetup, viewProj, lookDir, origin, zfar, strengthScale
end

local function chunkCenter( chunk )
	local origin = MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz )
	return Vector(
		origin.x + ( MC.ChunkWorld or 0 ) * 0.5,
		origin.y + ( MC.ChunkWorld or 0 ) * 0.5,
		origin.z + ( MC.ChunkWorldH or 0 ) * 0.5
	)
end

local function chunkWithinCasterDistance( chunk, eye, maxDistSqr )
	if not maxDistSqr or maxDistSqr <= 0 then return true end
	return chunkCenter( chunk ):DistToSqr( eye ) <= maxDistSqr
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

local function drawMCShadowCasters( material )
	local meshes = MC.Meshes
	if not meshes then return 0, 0 end
	local eye = EyePos()
	local casterDist = convarFloat( MC.MeshShadowMapCasterDistance, 4608, 0, 65536 )
	local maxDistSqr = casterDist > 0 and casterDist * casterDist or nil
	local drawnChunks, drawnMeshes = 0, 0

	render.SetMaterial( material )
	for key, list in pairs( meshes ) do
		if list then
			local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
			if chunk and chunkWithinCasterDistance( chunk, eye, maxDistSqr ) then
				local mat = Matrix()
				mat:SetTranslation( MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz ) )
				cam.PushModelMatrix( mat )
					local count = drawShadowMeshList( list )
				cam.PopModelMatrix()
				if count > 0 then
					drawnChunks = drawnChunks + 1
					drawnMeshes = drawnMeshes + count
				end
			end
		end
	end

	return drawnChunks, drawnMeshes
end

local function renderMCShadowMap()
	if not mcShadowSourceEnabled() then return false end
	local now = CurTime()
	local interval = convarFloat( MC.MeshShadowMapUpdateInterval, 0, 0, 1 )
	if interval > 0 and mcShadowNextUpdate > now then return true end
	mcShadowNextUpdate = now + interval

	local rt = ensureMCShadowTexture()
	local dummyRT = ensureMCShadowDummyTexture()
	local material = ensureMCShadowDepthMaterial()
	if not ( rt and dummyRT and material ) then
		mcShadowStats.lastError = "missing_rt_or_material"
		return false
	end

	local viewSetup, viewProj, lightForward, lightOrigin, lightZFar, strengthScale = makeMCShadowViewSetup( mcShadowTextureSize )
	if not ( viewSetup and viewProj ) then
		mcShadowStats.lastError = "missing_shaderlib_matrix"
		return false
	end
	mcShadowStrengthScale = strengthScale or 1
	if mcShadowStrengthScale <= 0 then
		-- Twilight gap: sun and moon both below the fade threshold. Skip the
		-- depth pass; binds still run and see an effective strength of 0.
		mcShadowStats.drawnChunks = 0
		mcShadowStats.drawnMeshes = 0
		mcShadowStats.lastUpdate = now
		mcShadowStats.lastError = nil
		return true
	end
	local shadowViewProj = viewProj.GetTransposed and viewProj:GetTransposed() or viewProj
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
		cam.Start( viewSetup )
			startedCam = true
			-- Bind the real shadow target at MRT slot 1 inside the camera
			-- block, mirroring the CSM addon's proven ordering.
			render.SetRenderTargetEx( 1, rt )
			local chunks, meshes = drawMCShadowCasters( material )
			mcShadowStats.drawnChunks = chunks
			mcShadowStats.drawnMeshes = meshes
		cam.End()
		startedCam = false
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
	return true
end

local function mcShadowReady()
	return mcShadowTexture ~= nil and mcShadowViewProj ~= nil
		and mcShadowForward ~= nil and mcShadowOrigin ~= nil
end

local function csmCombinedShadowTexture()
	local csm = GShaderCSM
	local csmMat = csm and csm.csm_mat or nil
	if not csmMat and Material then csmMat = Material( "pp/csm_gmod" ) end
	if not ( csmMat and csmMat.GetTexture ) then return nil end
	local tex = csmMat:GetTexture( "$texture2" )
	if not tex or ( tex.IsError and tex:IsError() ) then return nil end
	return tex
end

local function csmScreenShadowTexture()
	local csm = GShaderCSM
	local finalMat = csm and csm.csm_mat_final or nil
	if not finalMat and Material then finalMat = Material( "pp/csm_final" ) end
	if not ( finalMat and finalMat.GetTexture ) then return nil end
	local tex = finalMat:GetTexture( "$texture1" )
	if not tex or ( tex.IsError and tex:IsError() ) then return nil end
	return tex
end

local function csmShadowTexture()
	if shadowMapSource() == "combined" then return csmCombinedShadowTexture(), "combined" end
	local tex = csmScreenShadowTexture()
	if tex then return tex, "screen" end
	return csmCombinedShadowTexture(), "combined"
end

local function csmReady()
	local csm = GShaderCSM
	if not ( csm and csm.CSMViewProj ) then return false end
	local cv = GetConVar and GetConVar( "r_csm" ) or nil
	if cv and cv.GetBool and not cv:GetBool() then return false end
	return csmShadowTexture() ~= nil
end

function MC.UsingMeshShadowMap()
	if not ( shadowMapEnabled() and usingGpuLightTexture() ) then return false end
	if shadowMapSource() == "mc" then return mcShadowReady() end
	return csmReady()
end

local function bindShadowParams( material, enabled, source, isFancy )
	local strength = enabled and convarFloat( MC.MeshShadowMapStrength, 0.45, 0, 1 ) or 0
	if source == "mc" then
		-- Day cycle: shadows fade at the horizon and stay weak under moonlight.
		strength = strength * math.Clamp( mcShadowStrengthScale, 0, 1 )
	end
	local bias = convarFloat( MC.MeshShadowMapBias, 0.0005, 0, 0.05 )
	local screenContrast = convarFloat( MC.MeshShadowMapScreenContrast, 6, 1, 32 )
	local csm = GShaderCSM
	local cascadeCount = csm and tonumber( csm.cascade_count ) or 4
	if not cascadeCount or cascadeCount < 1 then cascadeCount = 4 end
	if cascadeCount > 4 then cascadeCount = 4 end

	-- $c0_*..$c2_* land in pixel shader constants c0..c2 (screenspace_general
	-- uploads $c0..$c3 to c0..c3; $viewprojmat goes to c11..c14).
	material:SetFloat( "$c0_x", strength )
	material:SetFloat( "$c0_y", source == "screen" and screenContrast or bias )
	material:SetFloat( "$c0_z", enabled and 1 or 0 )
	if source == "mc" then
		material:SetFloat( "$c0_w", -2 )
	elseif source == "screen" then
		material:SetFloat( "$c0_w", -1 )
	else
		material:SetFloat( "$c0_w", 1 / cascadeCount )
	end

	if source == "mc" and mcShadowForward and mcShadowOrigin then
		local invZFar = ( mcShadowZFar and mcShadowZFar > 0 ) and 1 / mcShadowZFar or 0
		-- The shader derives its normal-offset shadow bias from this kernel
		-- radius, so it must span at least one shadow-map texel or the bias
		-- collapses and acne returns; clamp softness up instead of allowing a
		-- biasless single-tap mode.
		local softness = convarFloat( MC.MeshShadowMapSoftness, 1, 1, 4 )
		local kernelUV = mcShadowTextureSize > 0 and softness / mcShadowTextureSize or 0
		material:SetFloat( "$c1_x", mcShadowForward.x )
		material:SetFloat( "$c1_y", mcShadowForward.y )
		material:SetFloat( "$c1_z", mcShadowForward.z )
		material:SetFloat( "$c1_w", invZFar )
		material:SetFloat( "$c2_x", mcShadowOrigin.x )
		material:SetFloat( "$c2_y", mcShadowOrigin.y )
		material:SetFloat( "$c2_z", mcShadowOrigin.z )
		material:SetFloat( "$c2_w", kernelUV )
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

function MC.BindMeshShadowMap( material )
	if not material then return false end
	local enabled = MC.UsingMeshShadowMap and MC.UsingMeshShadowMap() == true
	local source = shadowMapSource()
	local tex
	local matrix

	if enabled and source == "mc" then
		tex = mcShadowTexture
		matrix = mcShadowViewProj
	elseif enabled then
		tex, source = csmShadowTexture()
		local csm = GShaderCSM
		matrix = csm and csm.CSMViewProj or nil
	end

	tex = tex or ensureFallbackShadowTexture()
	if material.SetTexture and tex then
		material:SetTexture( "$texture3", tex )
	end

	if material.SetMatrix and matrix then
		material:SetMatrix( "$viewprojmat", matrix )
	end
	-- Never define $invviewprojmat on the chunk material: the engine would
	-- upload it to pixel shader constants c15..c18, where the compiler is
	-- free to place inline literal constants of the chunk shader.
	if material.SetFloat then
		local isFancy = MC.MaterialGpuLightTextureFancy ~= nil and material == MC.MaterialGpuLightTextureFancy
		bindShadowParams( material, enabled and tex ~= nil and matrix ~= nil, source, isFancy )
	end
	return enabled
end

function MC.ClearMeshShadowMapFallback()
	fallbackTexture = nil
	fallbackReady = false
end

function MC.MeshShadowMapStats()
	return mcShadowStats
end

function MC.UpdateMeshShadowMap()
	return renderMCShadowMap()
end

hook.Remove( "PreRender", "mc_mesh_shadow_map_render" )
hook.Add( "PreRender", "mc_mesh_shadow_map_render", function()
	renderMCShadowMap()
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_shadow_map", function()
		if not MC.BindMeshShadowMap then return end
		if MC.MaterialGpuLightTexture then MC.BindMeshShadowMap( MC.MaterialGpuLightTexture ) end
		if MC.MaterialGpuLightTextureFancy then MC.BindMeshShadowMap( MC.MaterialGpuLightTextureFancy ) end
	end, "mc_mesh_shadow_map_refresh" )
	cvars.AddChangeCallback( "mc_mesh_shadow_map_source", function()
		mcShadowNextUpdate = 0
	end, "mc_mesh_shadow_map_source_refresh" )
end
