-- Heightfield shadow mode ("mc_shadow_mode height").
--
-- Owns a cached TOP-DOWN depth map of the MC world: one ortho render of the
-- opaque chunk meshes looking straight down, stored as normalized linear
-- depth in an R32F target (same MRT recipe as the sun shadow map). The chunk
-- pixel shader ray-marches this height map toward the sun for soft shadows.
--
-- The whole point vs. the per-frame shadow map: the height map is sun- and
-- camera-independent, so it only re-renders when chunk meshes change or the
-- window recenters around the player (both throttled). Day-cycle sun motion
-- and camera movement cost zero redraws; sun direction is just a pixel
-- shader constant.
--
-- Must never appear here: rebuild-the-world CPU light paths (sky floods,
-- lightmap redownloads) — this module only draws existing IMeshes into an RT
-- and sets material constants.
MC = MC or {}

local hfTexture
local hfTextureSize = 0
local hfDummyTexture
local hfDummyTextureSize = 0
local hfDepthMaterial
local fallbackTexture
local fallbackReady = false

local hfReady = false
local hfDirty = true
local hfNextUpdate = 0
local hfLastMeshVersion = -1

-- Window state captured at render time; binds must describe the rendered
-- texture, not current cvar values.
local hfAnchorX, hfAnchorY = 0, 0
local hfTopZ, hfZFar = 0, 1
local hfRange = 0
local hfScaleU, hfScaleV = 0, 0 -- signed uv factors: u <- world y, v <- world x

local hfStats = {
	renders = 0,
	drawnChunks = 0,
	drawnMeshes = 0,
	lastUpdate = 0,
	lastError = nil,
}

local boundFrame = {}

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

local function usingGpuLightTexture()
	return MC.UsingGpuLightTexture and MC.UsingGpuLightTexture() == true
end

local function heightfieldModeEnabled()
	if not convarBool( MC.MeshShadowMap ) then return false end
	if not ( MC.MeshShadowMapMode and MC.MeshShadowMapMode() == "height" ) then return false end
	-- Vanilla lighting mode outranks the height material in the selector, so
	-- its ray-marched heightmap would render with no consumer.
	if MC.UsingVanillaLightMaterial and MC.UsingVanillaLightMaterial() then return false end
	return usingGpuLightTexture()
end

local function hfSize()
	return convarInt( MC.MeshHfShadowSize, 1024, 256, 4096 )
end

local function hfRangeCvar()
	return convarFloat( MC.MeshHfShadowRange, 4096, 1024, 16384 )
end

local function ensureHfTexture()
	if not GetRenderTargetEx then return nil end
	local size = hfSize()
	if hfTexture and hfTextureSize == size then return hfTexture end

	IMAGE_FORMAT_R32F = IMAGE_FORMAT_R32F or 27
	-- Same recipe as the MC sun shadow map / CSM shadow target:
	-- CLAMPS|CLAMPT|ANISOTROPIC|NOMIP|NOLOD|DEPTHRENDERTARGET|NODEPTHBUFFER
	local flags = bit.bor( 4, 8, 16, 256, 512, 65536, 8388608 )
	hfTexture = GetRenderTargetEx(
		"mc_mesh_hf_height1_" .. tostring( size ),
		size,
		size,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		IMAGE_FORMAT_R32F
	)
	hfTextureSize = hfTexture and size or 0
	hfReady = false
	return hfTexture
end

local function ensureHfDummyTexture()
	if not GetRenderTargetEx then return nil end
	local size = hfSize()
	if hfDummyTexture and hfDummyTextureSize == size then return hfDummyTexture end

	IMAGE_FORMAT_A8 = IMAGE_FORMAT_A8 or 8
	IMAGE_FORMAT_RGB565 = IMAGE_FORMAT_RGB565 or 4
	-- Same recipe as the shadow map module's MRT slot-0 dummy target.
	local flags = bit.bor( 1, 4, 8, 256, 512, 32768, 262144, 8388608, 33554432, 536870912 )
	local isLinux = system and system.IsLinux and system.IsLinux() == true
	hfDummyTexture = GetRenderTargetEx(
		"mc_mesh_hf_height1_dummy_" .. tostring( size ),
		size,
		size,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_ONLY,
		flags,
		0,
		isLinux and IMAGE_FORMAT_RGB565 or IMAGE_FORMAT_A8
	)
	hfDummyTextureSize = hfDummyTexture and size or 0
	return hfDummyTexture
end

local function ensureHfDepthMaterial()
	if hfDepthMaterial and not hfDepthMaterial:IsError() then return hfDepthMaterial end
	if not Material then return nil end
	-- Shared with the sun shadow map pass: both passes set $c0/$c1 right
	-- before drawing, so the two modes never fight over the constants.
	hfDepthMaterial = Material( "pp/mc_shadow_depth4" )
	if hfDepthMaterial and not hfDepthMaterial:IsError() then
		local baseTex = MC.Material and MC.Material.GetTexture and MC.Material:GetTexture( "$basetexture" ) or nil
		if baseTex and not ( baseTex.IsError and baseTex:IsError() ) then
			hfDepthMaterial:SetTexture( "$basetexture", baseTex )
		end
		return hfDepthMaterial
	end
	return nil
end

local function ensureFallbackTexture()
	if fallbackTexture and fallbackReady then return fallbackTexture end
	if not ( GetRenderTarget and render and surface and cam ) then return nil end
	-- Depth 1.0 decodes to the window bottom: below every receiver, so the
	-- fallback never darkens anything.
	fallbackTexture = fallbackTexture or GetRenderTarget( "mc_mesh_hf_fallback_white", 2, 2 )
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

------------------------------------------------------------------ dirty tracking

function MC.MarkHeightfieldShadowDirty()
	hfDirty = true
end

local function meshVersion()
	if MC.ChunkDrawListVersion then return MC.ChunkDrawListVersion() end
	return 0
end

local function anchorNeedsRecenter( eye )
	if hfRange <= 0 then return true end
	local limit = hfRange * 0.35
	return math.abs( eye.x - hfAnchorX ) > limit or math.abs( eye.y - hfAnchorY ) > limit
end

local function heightfieldDirty( eye, size, range )
	if hfDirty then return true end
	if not hfReady then return true end
	if hfTextureSize ~= size or hfRange ~= range then return true end
	local version = meshVersion()
	if version ~= hfLastMeshVersion then return true end
	return anchorNeedsRecenter( eye )
end

------------------------------------------------------------------ top-down pass

local function chunkZBounds()
	local meshes = MC.Meshes
	if not meshes then return nil end
	local chunkH = MC.ChunkWorldH or 0
	local minZ, maxZ
	for key in pairs( meshes ) do
		local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
		if chunk then
			local z0 = chunk.cz * chunkH
			local z1 = z0 + chunkH
			if not minZ or z0 < minZ then minZ = z0 end
			if not maxZ or z1 > maxZ then maxZ = z1 end
		end
	end
	if not minZ then return nil end
	return minZ, maxZ
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

local function drawHeightfieldCasters( material, anchorX, anchorY, range )
	local store = MC.Meshes
	if not ( store and MC.OpaqueChunkDrawEntries ) then return 0, 0 end
	local entries, count = MC.OpaqueChunkDrawEntries()
	local chunkW = MC.ChunkWorld or 0
	local halfW = chunkW * 0.5
	local minX, maxX = anchorX - range - chunkW, anchorX + range
	local minY, maxY = anchorY - range - chunkW, anchorY + range
	local pushMatrix, popMatrix = cam.PushModelMatrix, cam.PopModelMatrix
	local drawnChunks, drawnMeshes = 0, 0

	render.SetMaterial( material )
	for i = 1, count do
		local e = entries[i]
		local list = e.list
		if store[e.key] == list then
			-- Entries carry the chunk CENTER; the window filter keeps running
			-- on the chunk origin (min side is already widened by chunkW).
			local ox, oy = e.x - halfW, e.y - halfW
			if ox <= maxX and ox >= minX and oy <= maxY and oy >= minY then
				pushMatrix( e.matrix )
					local drawn = 0
					for j = 1, #list do
						local entry = list[j]
						local meshObj = type( entry ) == "table" and entry.mesh or entry
						if meshObj and meshObj.Draw then
							meshObj:Draw()
							drawn = drawn + 1
						end
					end
				popMatrix()
				if drawn > 0 then
					drawnChunks = drawnChunks + 1
					drawnMeshes = drawnMeshes + drawn
				end
			end
		end
	end

	return drawnChunks, drawnMeshes
end

local function renderHeightfield()
	if not heightfieldModeEnabled() then return false end

	local eye = EyePos()
	local size = hfSize()
	local range = hfRangeCvar()
	if not heightfieldDirty( eye, size, range ) then return true end

	local now = CurTime()
	local interval = convarFloat( MC.MeshHfShadowUpdateInterval, 0.1, 0, 2 )
	if hfNextUpdate > now then return true end
	hfNextUpdate = now + interval

	local rt = ensureHfTexture()
	local dummyRT = ensureHfDummyTexture()
	local material = ensureHfDepthMaterial()
	if not ( rt and dummyRT and material ) then
		hfStats.lastError = "missing_rt_or_material"
		return false
	end

	local minZ, maxZ = chunkZBounds()
	if not minZ then
		-- No chunk meshes: nothing can cast or receive, leave the last map.
		hfLastMeshVersion = meshVersion()
		hfDirty = false
		return true
	end

	-- Snap the window to whole height-map texels so a recenter lands heights
	-- on the same world alignment (no shadow crawl on recenter).
	local texelWorld = ( range * 2 ) / size
	local anchorX = math.floor( eye.x / texelWorld + 0.5 ) * texelWorld
	local anchorY = math.floor( eye.y / texelWorld + 0.5 ) * texelWorld
	local topZ = maxZ + 128
	local zfar = math.max( topZ - ( minZ - 128 ), 512 )

	-- Straight-down ortho camera. Pitch 90 puts the ortho right axis on
	-- world -y and the up axis on world +x; read the actual vectors back so
	-- the shader mapping follows whatever the engine returns.
	local angles = Angle( 90, 0, 0 )
	local right = angles:Right()
	local up = angles:Up()
	if math.abs( right.y ) < 0.5 or math.abs( up.x ) < 0.5 then
		angles = Angle( 90, 90, 0 )
		right = angles:Right()
		up = angles:Up()
	end

	local viewSetup = {
		origin = Vector( anchorX, anchorY, topZ ),
		angles = angles,
		znear = 0.01,
		zfar = zfar,
		ortho = {
			left = -range,
			right = range,
			bottom = range,
			top = -range,
		},
		x = 0,
		y = 0,
		w = size,
		h = size,
		drawviewer = false,
		drawviewmodel = false,
		dopostprocess = false,
		bloomtone = false,
		viewid = 6,
	}

	-- Depth writer constants: straight-down forward, normalized by zfar. The
	-- chunk shader decodes height = topZ - depth * zfar from the same pair.
	material:SetFloat( "$c0_x", 0 )
	material:SetFloat( "$c0_y", 0 )
	material:SetFloat( "$c0_z", -1 )
	material:SetFloat( "$c0_w", 1 / zfar )
	material:SetFloat( "$c1_x", anchorX )
	material:SetFloat( "$c1_y", anchorY )
	material:SetFloat( "$c1_z", topZ )

	local setCullMode = false
	local pushedRT = false
	local startedCam = false
	local setMRT = false
	local drawnChunks, drawnMeshes = 0, 0
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
			-- Real height target at MRT slot 1 inside the camera block, the
			-- same proven ordering as the sun shadow depth pass.
			render.SetRenderTargetEx( 1, rt )
			drawnChunks, drawnMeshes = drawHeightfieldCasters( material, anchorX, anchorY, range )
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
		hfStats.lastError = tostring( err )
		return false
	end

	hfAnchorX, hfAnchorY = anchorX, anchorY
	hfTopZ, hfZFar = topZ, zfar
	hfRange = range
	hfScaleU = right.y / ( range * 2 )
	hfScaleV = up.x / ( range * 2 )
	hfLastMeshVersion = meshVersion()
	hfDirty = false
	hfReady = true
	hfStats.renders = hfStats.renders + 1
	hfStats.drawnChunks = drawnChunks
	hfStats.drawnMeshes = drawnMeshes
	hfStats.lastUpdate = now
	hfStats.lastError = nil
	MC.HeightfieldShadowTexture = rt
	return true
end

------------------------------------------------------------------ material bind

function MC.UsingHeightfieldShadow()
	return heightfieldModeEnabled() and hfReady
end

function MC.BindMeshHeightfieldShadow( material )
	if not material then return false end
	local frame = FrameNumber and FrameNumber() or 0
	if boundFrame[material] == frame then
		return MC.UsingHeightfieldShadow()
	end
	boundFrame[material] = frame

	local enabled = MC.UsingHeightfieldShadow()
	local strength = enabled and convarFloat( MC.MeshShadowMapStrength, 0.75, 0, 1 ) or 0
	local toSunX, toSunY, toSunZ = 0, 0, 1
	if strength > 0 and MC.MeshShadowLightDirection then
		local toSun, scale = MC.MeshShadowLightDirection()
		strength = strength * math.Clamp( scale or 1, 0, 1 )
		toSunX, toSunY, toSunZ = toSun.x, toSun.y, toSun.z
		-- A near-horizontal sun cannot be resolved by a heightfield march;
		-- the day cycle's horizon envelope already fades strength before
		-- this guard matters.
		if toSunZ <= 0.02 then strength = 0 end
	end

	if material.SetFloat then
		material:SetFloat( "$c0_x", strength )
		material:SetFloat( "$c0_y", convarFloat( MC.MeshHfShadowSoftness, 0.05, 0.005, 0.5 ) )
		material:SetFloat( "$c0_z", hfTopZ )
		material:SetFloat( "$c0_w", hfZFar )
		material:SetFloat( "$c1_x", toSunX )
		material:SetFloat( "$c1_y", toSunY )
		material:SetFloat( "$c1_z", toSunZ )
		material:SetFloat( "$c1_w", convarFloat( MC.MeshHfShadowMaxDist, 2400, 256, 8192 ) )
		material:SetFloat( "$c2_x", hfAnchorX )
		material:SetFloat( "$c2_y", hfAnchorY )
		material:SetFloat( "$c2_z", hfScaleV )
		material:SetFloat( "$c2_w", hfScaleU )
		material:SetFloat( "$c3_x", convarFloat( MC.MeshShadowMapTint, 0.6, 0, 1 ) )
		material:SetFloat( "$c3_y", convarFloat( MC.MeshShadowMapEdgeFade, 0.1, 0.001, 0.5 ) )
		material:SetFloat( "$c3_z", convarFloat( MC.MeshShadowMapFaceShade, 0.65, 0, 1 ) )
		material:SetFloat( "$c3_w", convarFloat( MC.MeshShadowMapWarmth, 0.35, 0, 1 ) )
	end

	-- Never SetMatrix($viewprojmat) on this material: the heightfield shader
	-- keeps compiler literals in c11..c18.
	local tex = ( enabled and hfTexture ) or ensureFallbackTexture()
	if material.SetTexture and tex then
		material:SetTexture( "$texture3", tex )
	end
	return enabled
end

function MC.HeightfieldShadowStats()
	return hfStats
end

function MC.UpdateHeightfieldShadow()
	return renderHeightfield()
end

hook.Remove( "PreRender", "mc_mesh_heightfield_render" )
hook.Add( "PreRender", "mc_mesh_heightfield_render", function()
	renderHeightfield()
end )

if cvars and cvars.AddChangeCallback then
	for _, name in ipairs( { "mc_shadow_hf_size", "mc_shadow_hf_range" } ) do
		cvars.AddChangeCallback( name, function()
			hfDirty = true
			hfNextUpdate = 0
		end, "mc_shadow_hf_refresh" )
	end
end
