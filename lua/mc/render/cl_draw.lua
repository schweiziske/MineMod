-- Chunk mesh draw hooks.
--
-- Hot-path notes (LuaJIT): the per-frame loops iterate flat arrays with
-- numeric for (pairs() is NYI and aborts traces), allocate nothing per chunk
-- (chunk matrices are cached by key, frustum planes live in reused number
-- slots), and error protection is one pcall on a named function per mesh
-- list instead of a fresh closure + xpcall per call.
------------------------------------------------------------------------- drawing
local math_abs = math.abs
local math_tan = math.tan
local math_rad = math.rad

local function meshRenderingEnabled()
	return not MC.MeshRender or MC.MeshRender:GetBool()
end

MC.MeshCullMode = MC.MeshCullMode or ( CreateClientConVar and CreateClientConVar( "mc_mesh_cull_mode", "ccw", true, false,
	"MC chunk mesh cull mode: cw or ccw" ) )
MC.MeshFrustumCull = MC.MeshFrustumCull or ( CreateClientConVar and CreateClientConVar( "mc_mesh_frustum_cull", "1", true, false,
	"Skip drawing MC chunk meshes outside the view frustum" ) )
MC.MeshDrawDistance = MC.MeshDrawDistance or ( CreateClientConVar and CreateClientConVar( "mc_mesh_draw_distance", "0", true, false,
	"Max distance in units at which MC chunk meshes are drawn; 0 = unlimited" ) )
MC.MeshGpuDepthPrepass = MC.MeshGpuDepthPrepass or ( CreateClientConVar and CreateClientConVar( "mc_mesh_depth_prepass", "0", true, false,
	"Draw a CPU-material depth-only prepass before GPU chunk shading (doubles geometry cost; the main pass already force-writes depth)" ) )

local function meshCullMode()
	local cv = MC.MeshCullMode
	local mode = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or "ccw"
	if mode == "ccw" or mode == "counterclockwise" or mode == "counter-clockwise" then
		return MATERIAL_CULLMODE_CCW or 0
	end
	return MATERIAL_CULLMODE_CW or 1
end

local function setChunkMeshCullMode()
	if render.CullMode then
		render.CullMode( meshCullMode() )
		return true
	end
	return false
end

local function restoreDefaultCullMode()
	if render.CullMode then
		render.CullMode( MATERIAL_CULLMODE_CCW or 0 )
	end
end

local function resetDepthOverride()
	if render.OverrideDepthEnable then
		render.OverrideDepthEnable( false, false )
		return true
	end
	return false
end

local function resetColorWriteOverride()
	if render.OverrideColorWriteEnable then
		render.OverrideColorWriteEnable( false, false )
		return true
	end
	return false
end

local function forceDepthWrite()
	if render.OverrideDepthEnable then
		render.OverrideDepthEnable( true, true )
		return true
	end
	return false
end

local function setDepthPrepassColorMask()
	if render.OverrideColorWriteEnable then
		render.OverrideColorWriteEnable( true, false )
		return true
	end
	return false
end

local function restoreChunkMeshRenderState( setCullMode )
	if setCullMode then pcall( restoreDefaultCullMode ) end
	resetColorWriteOverride()
	resetDepthOverride()
end

-- Pass-scoped render state: depth/colorwrite/cull overrides are identical
-- for every chunk in a pass, so drawAllChunks applies them once and flags
-- the pass as active; drawMeshList then skips its per-chunk state dance
-- (5 render.Override*/CullMode calls per chunk per frame add up on
-- hundreds of visible chunks). External MC.DrawChunk callers outside a
-- pass keep the old self-contained behavior.
local passActive = false

local function applyPassState( writeDepth )
	resetDepthOverride()
	resetColorWriteOverride()
	if writeDepth then forceDepthWrite() end
	return setChunkMeshCullMode()
end

local function drawMeshListInner( list, material, forceMaterial )
	local currentMaterial = material
	render.SetMaterial( currentMaterial )
	for i = 1, #list do
		local entry = list[i]
		local meshObj = entry
		local entryMaterial = material
		if type( entry ) == "table" then
			meshObj = entry.mesh
			if not forceMaterial then
				entryMaterial = entry.material or material
			end
		end
		if entryMaterial ~= currentMaterial then
			currentMaterial = entryMaterial
			render.SetMaterial( currentMaterial )
		end
		if meshObj and meshObj.Draw then meshObj:Draw() end
	end
end

local function drawMeshList( list, material, writeDepth, writeColor, forceMaterial )
	if not list then return end
	local ownState = not passActive or writeColor == false
	local setCullMode = false
	if ownState then
		resetDepthOverride()
		resetColorWriteOverride()
		if writeDepth == "test" then
			-- Depth TEST without write: the GPU translucent chunk material
			-- rides screenspace_general, which ignores the depth buffer unless
			-- overridden — without this glass draws on top of everything.
			if render.OverrideDepthEnable then render.OverrideDepthEnable( true, false ) end
		elseif writeDepth then
			forceDepthWrite()
		end
		if writeColor == false then setDepthPrepassColorMask() end
		setCullMode = setChunkMeshCullMode()
	end
	local ok, err = pcall( drawMeshListInner, list, material, forceMaterial )
	if ownState then
		restoreChunkMeshRenderState( setCullMode )
		-- A depth-prepass detour inside an active pass must hand the pass
		-- state back (the opaque pass is the only caller of that detour).
		if passActive then applyPassState( true ) end
	end
	if not ok then error( err ) end
end

-- Optional early-Z helper, OFF by default: the main GPU pass already renders
-- with OverrideDepthEnable(true, true) and the custom vertex shader outputs
-- real clip-space depth, so this prepass is not needed for correctness. It
-- only saves pixel-shader work on self-overdraw within a chunk while paying
-- the whole vertex/draw-call cost a second time — a net loss on large worlds.
local function drawGpuOpaqueDepthPrepass( list )
	if not ( MC.MeshGpuDepthPrepass and MC.MeshGpuDepthPrepass.GetBool and MC.MeshGpuDepthPrepass:GetBool() ) then return end
	if not ( MC.UsingGpuChunkShader and MC.UsingGpuChunkShader() ) then return end
	local cpuMaterial = MC.MaterialOpaqueCPU or MC.Material
	if not cpuMaterial then return end
	drawMeshList( list, cpuMaterial, true, false, true )
end

------------------------------------------------------------------- draw-list cache
-- Flat per-pass chunk arrays so the frame loop never touches pairs(). Mesh
-- upload/free bumps the version to trigger a rebuild; removed or replaced
-- lists are additionally caught per frame by comparing the store slot against
-- the cached list, so a missed bump can never draw a destroyed IMesh.
local drawListVersion = 0
local builtVersion = -1
local opaqueEntries, opaqueCount = {}, 0
local transEntries, transCount = {}, 0
-- Mesh vertices stay chunk-local. Only cached model matrices follow the
-- active logical-world frame, so a floating-origin transition never rebuilds
-- or uploads native geometry again.
local chunkFrames = {}
local renderFrameRevision = 0
local renderFrameX, renderFrameY, renderFrameZ = 0, 0, 0
local matrixOrigin = Vector()

local function readRenderFrameOffset()
	local offset = MC.WorldToRenderPos and MC.WorldToRenderPos( vector_origin ) or vector_origin
	return offset.x, offset.y, offset.z
end

function MC.RefreshChunkRenderFrame()
	local x, y, z = readRenderFrameOffset()
	if x == renderFrameX and y == renderFrameY and z == renderFrameZ then return false end
	renderFrameX, renderFrameY, renderFrameZ = x, y, z
	renderFrameRevision = renderFrameRevision + 1
	return true
end

function MC.ChunkRenderFrameOffset()
	return renderFrameX, renderFrameY, renderFrameZ
end

local function prepareChunkFrame( frame, matrixNeeded )
	if frame.centerRevision ~= renderFrameRevision then
		frame.x = frame.worldX + renderFrameX
		frame.y = frame.worldY + renderFrameY
		frame.z = frame.worldZ + renderFrameZ
		frame.centerRevision = renderFrameRevision
	end
	if matrixNeeded and frame.matrixRevision ~= renderFrameRevision then
		matrixOrigin.x = frame.originX + renderFrameX
		matrixOrigin.y = frame.originY + renderFrameY
		matrixOrigin.z = frame.originZ + renderFrameZ
		frame.matrix:SetTranslation( matrixOrigin )
		frame.matrixRevision = renderFrameRevision
	end
	return frame
end

function MC.PrepareChunkDrawEntry( entry, matrixNeeded )
	local frame = entry and entry.frame
	if not frame then return nil end
	return prepareChunkFrame( frame, matrixNeeded == true )
end

function MC.EvictChunkDrawMatrix( key )
	chunkFrames[key] = nil
	MC.MarkChunkDrawListDirty()
end

function MC.MarkChunkDrawListDirty()
	drawListVersion = drawListVersion + 1
end

-- Monotonic mesh-change counter: bumps whenever chunk mesh lists are built,
-- replaced, or freed. The heightfield shadow module polls it to re-render
-- its cached top-down height map only when geometry actually changed.
function MC.ChunkDrawListVersion()
	return drawListVersion
end

local function rebuildDrawList( store, entries )
	local chunkW = MC.ChunkWorld
	local chunkH = MC.ChunkWorldH
	local halfW = chunkW * 0.5
	local halfH = chunkH * 0.5
	local n = 0
	for key, list in pairs( store ) do
		local c = MC.GetChunkByKey( key )
		if c and list then
			n = n + 1
			local e = entries[n]
			if not e then
				e = {}
				entries[n] = e
			end
			local ox, oy, oz = c.cx * chunkW, c.cy * chunkW, c.cz * chunkH
			local frame = chunkFrames[key]
			if not frame then
				frame = {
					matrix = Matrix(),
					centerRevision = -1,
					matrixRevision = -1,
				}
				chunkFrames[key] = frame
			end
			if frame.originX ~= ox or frame.originY ~= oy or frame.originZ ~= oz then
				frame.originX, frame.originY, frame.originZ = ox, oy, oz
				frame.worldX, frame.worldY, frame.worldZ = ox + halfW, oy + halfW, oz + halfH
				frame.centerRevision = -1
				frame.matrixRevision = -1
			end
			prepareChunkFrame( frame, true )
			e.key = key
			e.list = list
			e.frame = frame
			e.matrix = frame.matrix
		end
	end
	for i = #entries, n + 1, -1 do entries[i] = nil end
	return n
end

local function ensureDrawLists()
	if builtVersion == drawListVersion then return end
	builtVersion = drawListVersion
	opaqueCount = rebuildDrawList( MC.Meshes, opaqueEntries )
	transCount = rebuildDrawList( MC.MeshesTrans, transEntries )
end

-- Flat opaque draw entries shared with the shadow-map / heightfield depth
-- passes, so caster loops reuse the cached per-chunk matrices instead of
-- walking pairs(MC.Meshes) and allocating a Matrix per chunk per frame.
-- Read-only for callers; entries carry key/list/matrix and the chunk center
-- (x/y/z). Callers must re-check MC.Meshes[e.key] == e.list before drawing.
-- NOTE: defined AFTER ensureDrawLists so the local is captured as an upvalue.
function MC.OpaqueChunkDrawEntries()
	ensureDrawLists()
	return opaqueEntries, opaqueCount
end

------------------------------------------------------------------- frustum culling
-- Inward-pointing frustum planes through the eye. Normals stay unnormalized:
-- the AABB p-vertex radius scales by the same factor as the center distance,
-- so the compare is scale-invariant. All slots are plain numbers reused every
-- frame; the per-chunk test is pure scalar math.
local planeNX, planeNY, planeNZ, planeR = {}, {}, {}, {}
local planeCount = 0
local cullEyeX, cullEyeY, cullEyeZ = 0, 0, 0
local maxDistSq = 0 -- 0 = unlimited

MC.DrawCullStats = MC.DrawCullStats or {
	tested = 0,
	drawn = 0,
	distanceCulled = 0,
	frustumCulled = 0,
	stale = 0,
}

local function addPlane( nx, ny, nz, hx, hz )
	planeCount = planeCount + 1
	local i = planeCount
	planeNX[i], planeNY[i], planeNZ[i] = nx, ny, nz
	planeR[i] = hx * ( math_abs( nx ) + math_abs( ny ) ) + hz * math_abs( nz )
end

local function updateCullState()
	planeCount = 0
	local eye = EyePos()
	cullEyeX, cullEyeY, cullEyeZ = eye.x, eye.y, eye.z

	local hx = MC.ChunkWorld * 0.5
	local hz = MC.ChunkWorldH * 0.5

	local dist = MC.MeshDrawDistance and MC.MeshDrawDistance.GetFloat and MC.MeshDrawDistance:GetFloat() or 0
	if dist > 0 then
		-- Chunk bounding-sphere slack so a chunk whose center sits past the
		-- limit but whose blocks reach inside it does not pop.
		local r = dist + math.sqrt( hx * hx * 2 + hz * hz )
		maxDistSq = r * r
	else
		maxDistSq = 0
	end

	if not ( MC.MeshFrustumCull and MC.MeshFrustumCull.GetBool and MC.MeshFrustumCull:GetBool() ) then return end

	local ang = EyeAngles()
	local fwd = ang:Forward()
	local right = ang:Right()
	local up = ang:Up()

	local fovDeg, aspect = 100, ScrW() / ScrH()
	if render.GetViewSetup then
		local vs = render.GetViewSetup()
		if vs then
			fovDeg = vs.fov or fovDeg
			if vs.width and vs.height and vs.height > 0 then aspect = vs.width / vs.height end
		end
	end
	-- Source fov convention: ViewSetup fov is horizontal on a 4:3 basis and
	-- the vertical fov is aspect-invariant. If the engine hands us an already
	-- aspect-corrected fov this over-includes (draws a few extra off-screen
	-- chunks) instead of popping chunks at the screen edges. 1.05 = margin.
	local tanY = math_tan( math_rad( fovDeg ) * 0.5 ) * 0.75 * 1.05
	local tanX = tanY * aspect

	local fx, fy, fz = fwd.x, fwd.y, fwd.z
	local rx, ry, rz = right.x, right.y, right.z
	local ux, uy, uz = up.x, up.y, up.z

	addPlane( fx, fy, fz, hx, hz )                                        -- near
	addPlane( rx + fx * tanX, ry + fy * tanX, rz + fz * tanX, hx, hz )    -- left edge
	addPlane( -rx + fx * tanX, -ry + fy * tanX, -rz + fz * tanX, hx, hz ) -- right edge
	addPlane( ux + fx * tanY, uy + fy * tanY, uz + fz * tanY, hx, hz )    -- bottom edge
	addPlane( -ux + fx * tanY, -uy + fy * tanY, -uz + fz * tanY, hx, hz ) -- top edge
end

local function entryVisible( e )
	local frame = prepareChunkFrame( e.frame, false )
	local dx, dy, dz = frame.x - cullEyeX, frame.y - cullEyeY, frame.z - cullEyeZ
	if maxDistSq > 0 then
		local visible
		if MC.ChunkDrawDistanceVisible then
			visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistSq )
		else
			visible = dx * dx + dy * dy + dz * dz <= maxDistSq
		end
		if visible == false then return false, "distance" end
	end
	for i = 1, planeCount do
		if planeNX[i] * dx + planeNY[i] * dy + planeNZ[i] * dz < -planeR[i] then
			return false, "frustum"
		end
	end
	return true
end

------------------------------------------------------------------- chunk drawing
-- material/isGpuLightTexture are resolved once per pass by the hooks below;
-- both stay optional so external callers keep the old key-only signature.
function MC.DrawChunk( key, material, isGpuLightTexture )
	local list = MC.Meshes[key]
	if not list then return end
	if material == nil then
		material = MC.CurrentChunkMaterial and MC.CurrentChunkMaterial( false ) or MC.Material
	end
	if isGpuLightTexture == nil then
		isGpuLightTexture = MC.IsGpuLightTextureMaterial and MC.IsGpuLightTextureMaterial( material )
			or material == MC.MaterialGpuLightTexture
	end
	if isGpuLightTexture then
		-- The Native mesh payload already names an immutable atlas slot. Drawing
		-- performs no slot touch, allocation, upload or per-chunk material write.
		if MC.BindMeshShadowMap then MC.BindMeshShadowMap( material ) end
	end
	if material == MC.MaterialGpuOpaque or isGpuLightTexture then
		drawGpuOpaqueDepthPrepass( list )
	end
	local forceCurrentMaterial = material == MC.MaterialGpuOpaque or isGpuLightTexture
	drawMeshList( list, material, true, nil, forceCurrentMaterial )
end

function MC.DrawChunkTranslucent( key, material )
	if material == nil then
		material = MC.CurrentChunkMaterial and MC.CurrentChunkMaterial( true ) or MC.MaterialTranslucent
	end
	local isGpuLightTexture = MC.IsGpuLightTextureMaterial and MC.IsGpuLightTextureMaterial( material ) or false
	if isGpuLightTexture then
		-- Shared shadow constants only; chunk-light atlas state is immutable.
		if MC.BindMeshShadowMap then MC.BindMeshShadowMap( material ) end
	end
	drawMeshList( MC.MeshesTrans[key], material, isGpuLightTexture and "test" or false, nil, isGpuLightTexture )
end

local function drawVisibleChunks( store, entries, count, drawFn, material, isGpuLightTexture )
	local pushMatrix = cam.PushModelMatrix
	local popMatrix = cam.PopModelMatrix
	local drawn, distanceCulled, frustumCulled, stale = 0, 0, 0, 0
	for i = 1, count do
		local e = entries[i]
		if store[e.key] ~= e.list then
			stale = stale + 1
		elseif not ( MC.StreamHiddenChunkKeys and MC.StreamHiddenChunkKeys[e.key] ) then
			local visible, reason = entryVisible( e )
			if not visible then
				if reason == "distance" then distanceCulled = distanceCulled + 1
				else frustumCulled = frustumCulled + 1 end
			else
				drawn = drawn + 1
				prepareChunkFrame( e.frame, true )
				pushMatrix( e.matrix )
				drawFn( e.key, material, isGpuLightTexture )
				popMatrix()
			end
		end
	end
	return drawn, distanceCulled, frustumCulled, stale
end

local function drawNativeChunks( translucent )
	local backend = MC.NativeChunkBackend
	if not ( backend and backend.IsActive and backend.IsActive() and backend.DrawVisible ) then return nil end
	-- Keep the old path for the optional diagnostic prepass, which deliberately
	-- draws the opaque geometry twice with two different materials.
	if not translucent and MC.MeshGpuDepthPrepass and MC.MeshGpuDepthPrepass:GetBool() then return nil end

	local eye = EyePos()
	local ang = EyeAngles()
	local forward, right, up = ang:Forward(), ang:Right(), ang:Up()
	local fovDeg, aspect = 100, ScrW() / ScrH()
	if render.GetViewSetup then
		local view = render.GetViewSetup()
		if view then
			fovDeg = view.fov or fovDeg
			if view.width and view.height and view.height > 0 then aspect = view.width / view.height end
		end
	end
	local tanY = math_tan( math_rad( fovDeg ) * 0.5 ) * 0.75 * 1.05
	local tanX = tanY * aspect
	local offsetX, offsetY, offsetZ = 0, 0, 0
	if MC.ChunkRenderFrameOffset then offsetX, offsetY, offsetZ = MC.ChunkRenderFrameOffset() end
	local distance = MC.MeshDrawDistance and MC.MeshDrawDistance:GetFloat() or 0
	local frustum = not MC.MeshFrustumCull or MC.MeshFrustumCull:GetBool()
	local adapter = MC.GetWorldAdapter and MC.GetWorldAdapter() or nil
	local horizontalDistance = adapter and isfunction( adapter.ChunkDrawDistanceVisible ) or false
	local nativeMaterial = MC.NativeChunkMaterial or MC.CurrentChunkMaterial
	local material = nativeMaterial and nativeMaterial( translucent )
		or ( translucent and MC.MaterialTranslucent or MC.Material )
	local isGpuLightTexture = MC.IsGpuLightTextureMaterial and MC.IsGpuLightTextureMaterial( material )
		or material == MC.MaterialGpuLightTexture

	local setCullMode = applyPassState( not translucent )
	if translucent and isGpuLightTexture and render.OverrideDepthEnable then render.OverrideDepthEnable( true, false ) end
	if material then render.SetMaterial( material ) end
	if isGpuLightTexture and MC.BindMeshShadowMap then MC.BindMeshShadowMap( material ) end
	local ok, result = pcall( backend.DrawVisible, translucent and 1 or 0,
		eye, forward, right, up, tanX, tanY,
		offsetX, offsetY, offsetZ, math.max( 0, distance ), frustum, horizontalDistance )
	restoreChunkMeshRenderState( setCullMode )
	if not ok then error( result ) end
	return istable( result ) and result or nil
end

local function drawAllChunks( store, drawFn )
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	local translucent = store == MC.MeshesTrans
	local nativeResult = drawNativeChunks( translucent )
	if nativeResult then
		if not translucent then
			local stats = MC.DrawCullStats
			stats.tested = tonumber( nativeResult.tested ) or 0
			stats.visible = tonumber( nativeResult.visible ) or 0
			stats.drawn = tonumber( nativeResult.drawn ) or 0
			stats.distanceCulled = tonumber( nativeResult.distanceCulled ) or 0
			stats.frustumCulled = tonumber( nativeResult.frustumCulled ) or 0
			stats.stale = 0
			stats.sectionsTested = tonumber( nativeResult.sectionsTested ) or 0
			stats.sectionsVisible = tonumber( nativeResult.sectionsVisible ) or 0
			stats.sectionsDrawn = tonumber( nativeResult.sectionsDrawn ) or 0
			stats.meshesDrawn = tonumber( nativeResult.meshesDrawn ) or 0
			stats.verticesCandidate = tonumber( nativeResult.verticesCandidate ) or 0
			stats.verticesDrawn = tonumber( nativeResult.verticesDrawn ) or 0
			stats.verticesLodCulled = tonumber( nativeResult.verticesLodCulled ) or 0
			stats.verticesDirectionCulled = tonumber( nativeResult.verticesDirectionCulled ) or 0
			stats.lodSectionsDrawn = tonumber( nativeResult.lodSectionsDrawn ) or 0
			stats.lodMeshesDrawn = tonumber( nativeResult.lodMeshesDrawn ) or 0
			stats.lod = nativeResult.lod == true
			stats.lodApplied = nativeResult.lodApplied == true
			stats.sectionsOcclusionTested = tonumber( nativeResult.sectionsOcclusionTested ) or 0
			stats.sectionsOcclusionCulled = tonumber( nativeResult.sectionsOcclusionCulled ) or 0
			stats.chunksOcclusionCulled = tonumber( nativeResult.chunksOcclusionCulled ) or 0
			stats.trianglesDrawn = tonumber( nativeResult.trianglesDrawn ) or 0
			stats.nativeUs = tonumber( nativeResult.nativeUs ) or 0
		end
		return
	end
	ensureDrawLists()
	local entries, count
	if translucent then
		entries, count = transEntries, transCount
	else
		entries, count = opaqueEntries, opaqueCount
	end
	if count == 0 then
		if not translucent then
			local stats = MC.DrawCullStats
			stats.tested, stats.drawn = 0, 0
			stats.distanceCulled, stats.frustumCulled, stats.stale = 0, 0, 0
		end
		return
	end
	updateCullState()
	local material = MC.CurrentChunkMaterial and MC.CurrentChunkMaterial( translucent )
		or ( translucent and MC.MaterialTranslucent or MC.Material )
	local isGpuLightTexture = MC.IsGpuLightTextureMaterial and MC.IsGpuLightTextureMaterial( material )
		or material == MC.MaterialGpuLightTexture
	local setCullMode = applyPassState( not translucent )
	if translucent and isGpuLightTexture and render.OverrideDepthEnable then
		-- Pass-scoped depth TEST (no write): screenspace_general ignores the
		-- depth buffer unless overridden, which made GPU-lit glass draw on
		-- top of the world.
		render.OverrideDepthEnable( true, false )
	end
	passActive = true
	local ok, drawn, distanceCulled, frustumCulled, stale = pcall(
		drawVisibleChunks, store, entries, count, drawFn, material, isGpuLightTexture
	)
	passActive = false
	restoreChunkMeshRenderState( setCullMode )
	if not ok then error( drawn ) end
	if not translucent then
		local stats = MC.DrawCullStats
		stats.tested = count
		stats.drawn = drawn
		stats.distanceCulled = distanceCulled
		stats.frustumCulled = frustumCulled
		stats.stale = stale
	end
end

MC.RefreshChunkRenderFrame()
hook.Add( "MCWorldAdapterChanged", "mc_chunk_render_frame", function()
	MC.RefreshChunkRenderFrame()
end )

hook.Remove( "PostDrawOpaqueRenderables", "mc_draw_chunks" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_draw_chunks" )
-- bSky mirrors the engine's DF_DRAWSKYBOX draw flag: it is also true for the
-- MAIN pass whenever the 2D sky is drawn within it (maps without a 3D skybox,
-- or r_3dsky 0) and for water reflection passes, and it is false underwater.
-- Guarding on it blanks the whole world outdoors on 2D-sky maps, so only the
-- real 3D-skybox pass (bSky3D) is skipped.
hook.Add( "PostDrawOpaqueRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime() or nil
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( MC.Meshes, MC.DrawChunk ) end
	if perf then
		MC.StreamPerformanceAddFrameStage( "render.opaque", ( SysTime() - started ) * 1000, {
			renderOpaqueTested = MC.DrawCullStats and MC.DrawCullStats.tested or 0,
			renderOpaqueDrawn = MC.DrawCullStats and MC.DrawCullStats.drawn or 0,
		} )
	end
end )
-- translucent blocks only; the bulk of the world stays in the opaque pass above
hook.Add( "PostDrawTranslucentRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime() or nil
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( MC.MeshesTrans, MC.DrawChunkTranslucent ) end
	if perf then MC.StreamPerformanceAddFrameStage( "render.translucent", ( SysTime() - started ) * 1000 ) end
end )
