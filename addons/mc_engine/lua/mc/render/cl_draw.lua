-- Chunk mesh draw hooks.
--
-- Hot-path notes (LuaJIT): the per-frame loops iterate flat arrays with
-- numeric for, allocate nothing per chunk
-- (chunk matrices are cached by key, frustum planes live in reused number
-- slots), and error protection is one pcall on a named function per pack
-- pass. Material bindings are reused across adjacent chunks within a pass.
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
	"Skip drawing 8x8x8 MC render sections outside the view frustum" ) )
MC.MeshDrawDistance = MC.MeshDrawDistance or ( CreateClientConVar and CreateClientConVar( "mc_mesh_draw_distance", "0", true, false,
	"Max distance in units at which MC chunk meshes are drawn; 0 = lazy distance while lazy building is enabled, otherwise unlimited" ) )

function MC.EffectiveMeshDrawDistance()
	local distance = MC.MeshDrawDistance and MC.MeshDrawDistance.GetFloat and MC.MeshDrawDistance:GetFloat() or 0
	distance = math.max( 0, tonumber( distance ) or 0 )
	if distance > 0 then return distance end
	if MC.MeshLazyBuild and MC.MeshLazyBuild.GetBool and MC.MeshLazyBuild:GetBool() then
		local lazyDistance = MC.MeshLazyDistance and MC.MeshLazyDistance.GetFloat and MC.MeshLazyDistance:GetFloat() or 10000
		return math.max( 0, tonumber( lazyDistance ) or 10000 )
	end
	return 0
end

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

local function restoreChunkMeshRenderState( setCullMode, matrixPushed )
	local matrixOK, matrixError = true, nil
	if matrixPushed then matrixOK, matrixError = pcall( cam.PopModelMatrix ) end
	local cullOK, cullError = true, nil
	if setCullMode then cullOK, cullError = pcall( restoreDefaultCullMode ) end
	local colorOK, colorError = pcall( resetColorWriteOverride )
	local depthOK, depthError = pcall( resetDepthOverride )
	if not matrixOK then return { code = "render_l2_restore_matrix", message = tostring( matrixError ) } end
	if not cullOK then return { code = "render_l2_restore_cull", message = tostring( cullError ) } end
	if not colorOK then return { code = "render_l2_restore_color", message = tostring( colorError ) } end
	if not depthOK then return { code = "render_l2_restore_depth", message = tostring( depthError ) } end
end

-- Apply render overrides once per pack pass, with no per-chunk state writes.
local passMatrixPushed = false

local function reportL2Faults()
	local runtime = MC.RenderPackRuntime
	if runtime and #runtime.faults > 0 then runtime.ReportFaults() end
end

local function applyPassState( writeDepth )
	resetDepthOverride()
	resetColorWriteOverride()
	if writeDepth then forceDepthWrite() end
	return setChunkMeshCullMode()
end

local function drawMeshListInner( list, currentMaterial )
	for i = 1, #list do
		local entry = list[i]
		if entry.material ~= currentMaterial then
			currentMaterial = entry.material
			MC.RenderSky.Bind( currentMaterial )
			MC.RenderPBR.Bind( currentMaterial )
			render.SetMaterial( currentMaterial )
		end
		entry.mesh:Draw()
		MC.RenderDynamicLights.Draw( currentMaterial, entry.mesh )
	end
	return currentMaterial
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
local packEntries = setmetatable( {}, { __mode = "k" } )
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
	MC.MarkChunkDrawListDirty( key )
end

function MC.MarkChunkDrawListDirty( key )
	drawListVersion = drawListVersion + 1
	local runtime = MC.RenderPackRuntime
	if runtime and runtime.MarkChunkDirty then runtime.MarkChunkDirty( key ) end
	local shadows = MC.RenderPBRShadows
	if shadows and shadows.GeometryChanged then shadows.GeometryChanged( key, drawListVersion ) end
end

-- Monotonic mesh-change counter: bumps whenever chunk mesh lists are built,
-- replaced, or freed. The heightfield shadow module polls it to re-render
-- its cached top-down height map only when geometry actually changed.
function MC.ChunkDrawListVersion()
	return drawListVersion
end

local function chunkDrawFrame( key, c, chunkW, chunkH )
	local ox, oy, oz = c.cx * chunkW, c.cy * chunkW, c.cz * chunkH
	local frame = chunkFrames[key]
	if not frame then
		frame = { matrix = Matrix(), centerRevision = -1, matrixRevision = -1 }
		chunkFrames[key] = frame
	end
	if frame.originX ~= ox or frame.originY ~= oy or frame.originZ ~= oz
		or frame.chunkW ~= chunkW or frame.chunkH ~= chunkH then
		frame.originX, frame.originY, frame.originZ = ox, oy, oz
		frame.worldX, frame.worldY, frame.worldZ = ox + chunkW * 0.5, oy + chunkW * 0.5, oz + chunkH * 0.5
		frame.chunkW, frame.chunkH = chunkW, chunkH
		frame.centerRevision, frame.matrixRevision = -1, -1
	end
	return prepareChunkFrame( frame, true )
end

local function updateDrawEntry( e, key, list, c, chunkW, chunkH )
	local frame = chunkDrawFrame( key, c, chunkW, chunkH )
	e.key, e.list, e.frame, e.matrix = key, list, frame, frame.matrix
	e.cx, e.cy, e.cz = c.cx, c.cy, c.cz
end

local function rebuildDrawList( store, entries, indices )
	local size = MC.API.Coords.BlockSize()
	local chunkW, chunkH = MC.CS * size, MC.CH * size
	local n = 0
	if indices then for key in pairs( indices ) do indices[key] = nil end end
	for key, list in pairs( store ) do
		local c = MC.GetChunkByKey( key )
		if c and list then
			n = n + 1
			local e = entries[n]
			if not e then
				e = {}
				entries[n] = e
			end
			updateDrawEntry( e, key, list, c, chunkW, chunkH )
			if indices then indices[key] = n end
		end
	end
	for i = #entries, n + 1, -1 do entries[i] = nil end
	return n
end

local builtChunkW, builtChunkH
local function ensureDrawLists()
	local size = MC.API.Coords.BlockSize()
	local chunkW, chunkH = MC.CS * size, MC.CH * size
	if builtVersion == drawListVersion and builtChunkW == chunkW and builtChunkH == chunkH then return end
	builtVersion = drawListVersion
	builtChunkW, builtChunkH = chunkW, chunkH
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
local planeAX, planeAY, planeAZ = {}, {}, {}
local planeCount = 0
local cullEyeX, cullEyeY, cullEyeZ = 0, 0, 0
local maxDistSq = 0 -- 0 = unlimited
local cullDistance, directionMargin, cullDirections = 0, 0, false
local SectionCull, Occlusion = MC.RenderSectionCull, MC.RenderOcclusion

MC.DrawCullStats = MC.DrawCullStats or {
	tested = 0,
	drawn = 0,
	distanceCulled = 0,
	frustumCulled = 0,
	stale = 0,
	meshes = 0,
}
MC.DrawTranslucentCullStats = MC.DrawTranslucentCullStats or {}
MC.DrawSSRDepthCullStats = MC.DrawSSRDepthCullStats or {}
MC.DrawReflectionCullStats = MC.DrawReflectionCullStats or {}
-- Set only inside MC.DrawTerrainOverride: surface material, cutout -> material.
local overrideMaterial

local function addPlane( nx, ny, nz, hx, hz )
	planeCount = planeCount + 1
	local i = planeCount
	planeNX[i], planeNY[i], planeNZ[i] = nx, ny, nz
	planeAX[i], planeAY[i], planeAZ[i] = math_abs( nx ), math_abs( ny ), math_abs( nz )
	planeR[i] = hx * ( planeAX[i] + planeAY[i] ) + hz * planeAZ[i]
end

local function updateCullState( depthOnly )
	local view = render.GetViewSetup and render.GetViewSetup( true )
	local eye = view and view.origin or EyePos()
	if not MC.RenderPBR.PrepareDraw( eye.x, eye.y, eye.z, view, depthOnly ) then return false end
	planeCount = 0
	cullEyeX, cullEyeY, cullEyeZ = eye.x, eye.y, eye.z

	local size = MC.API.Coords.BlockSize()
	local hx, hz = MC.CS * size * 0.5, MC.CH * size * 0.5
	directionMargin = size * 0.0001
	cullDirections = MC.MeshDirectionalCull and MC.MeshDirectionalCull:GetBool()
		and meshCullMode() == ( MATERIAL_CULLMODE_CCW or 0 ) and not ( view and view.ortho )
	if Occlusion then
		local bx, by, bz
		if MC.MeshOcclusionCull:GetBool() and not ( view and view.ortho ) then
			bx, by, bz = MC.API.Coords.EngineToCell( eye, LocalPlayer() )
		end
		Occlusion.PrepareView( bx, by, bz )
	end

	local dist = MC.EffectiveMeshDrawDistance and MC.EffectiveMeshDrawDistance()
		or ( MC.MeshDrawDistance and MC.MeshDrawDistance.GetFloat and MC.MeshDrawDistance:GetFloat() or 0 )
	cullDistance = dist
	if dist > 0 then
		-- Chunk bounding-sphere slack so a chunk whose center sits past the
		-- limit but whose blocks reach inside it does not pop.
		local r = dist + math.sqrt( hx * hx * 2 + hz * hz )
		maxDistSq = r * r
	else
		maxDistSq = 0
	end

	if not ( MC.MeshFrustumCull and MC.MeshFrustumCull.GetBool and MC.MeshFrustumCull:GetBool() )
		or view and ( view.ortho or view.offcenter ) then return true end

	local ang = view and view.angles or EyeAngles()
	local fwd = ang:Forward()
	local right = ang:Right()
	local up = ang:Up()

	local fovDeg, aspect = 100, ScrW() / ScrH()
	if view then
		fovDeg = view.fov or fovDeg
		if view.width and view.height and view.height > 0 then aspect = view.width / view.height end
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
	return true
end

local function entryVisible( e )
	local frame = prepareChunkFrame( e.frame, false )
	local dx, dy, dz = frame.x - cullEyeX, frame.y - cullEyeY, frame.z - cullEyeZ
	local bounds, distanceSq = e.list.bounds, maxDistSq
	if bounds then
		dx = frame.originX + renderFrameX + bounds.x - cullEyeX
		dy = frame.originY + renderFrameY + bounds.y - cullEyeY
		dz = frame.originZ + renderFrameZ + bounds.z - cullEyeZ
		if cullDistance > 0 then distanceSq = ( cullDistance + bounds.radius ) ^ 2 end
	end
	if maxDistSq > 0 then
		local visible
		if MC.ChunkDrawDistanceVisible then
			visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, distanceSq )
		else
			visible = dx * dx + dy * dy + dz * dz <= distanceSq
		end
		if visible == false then return false, "distance" end
	end
	for i = 1, planeCount do
		local radius = planeR[i]
		if bounds then radius = planeAX[i] * bounds.hx + planeAY[i] * bounds.hy + planeAZ[i] * bounds.hz end
		if planeNX[i] * dx + planeNY[i] * dy + planeNZ[i] * dz < -radius then
			return false, "frustum"
		end
	end
	return true
end

local function sectionInFrustum( bounds, x, y, z )
	if not bounds then return true end -- Geometry retained from before Lua refresh.
	local dx, dy, dz = bounds.x + x, bounds.y + y, bounds.z + z
	for i = 1, planeCount do
		local radius = planeAX[i] * bounds.hx + planeAY[i] * bounds.hy + planeAZ[i] * bounds.hz
		if planeNX[i] * dx + planeNY[i] * dy + planeNZ[i] * dz < -radius then return false end
	end
	return true
end

------------------------------------------------------------------- chunk drawing
local function drawPackChunk( key, translucent )
	local runtime = MC.Need( MC.RenderPackRuntime, "render_l2_runtime_missing", "L2 runtime did not load" )
	if not runtime or not runtime.ChunkCurrent( key ) then return end
	if not MC.RenderPBR.PrepareCurrentView() then return end
	local groups = runtime.GetStages( translucent )
	local size = MC.API.Coords.BlockSize()
	local frame = chunkDrawFrame( key, MC.GetChunkByKey( key ), MC.CS * size, MC.CH * size )
	local setCullMode = applyPassState( not translucent )
	if translucent then render.OverrideDepthEnable( true, false ) end
	local matrixPushed = false
	local ok, err = pcall( function()
		-- Vertices are chunk-local in both entry points, including offscreen
		-- direct draws and worlds whose render origin has moved.
		cam.PushModelMatrix( frame.matrix ) matrixPushed = true
		for _, passes in ipairs( groups ) do
			for _, pass in ipairs( passes ) do
				local list = pass.store[key]
				if list then drawMeshListInner( list ) end
			end
		end
	end )
	local restoreError = restoreChunkMeshRenderState( setCullMode, matrixPushed )
	if restoreError then MC.Fault( restoreError.code, "%s", restoreError.message ) end
	if not ok then runtime.DrawFault( "chunk=" .. tostring( key ) .. ": " .. tostring( err ) ) end
	reportL2Faults()
end

function MC.DrawChunk( key )
	drawPackChunk( key, false )
end

function MC.DrawChunkTranslucent( key )
	drawPackChunk( key, true )
end

local function drawVisibleChunks( store, entries, count, chunks, stats, depthStage )
	local pushMatrix = cam.PushModelMatrix
	local popMatrix = cam.PopModelMatrix
	local getChunk = MC.GetChunkByKey
	local currentMaterial, meshes = nil, 0
	local drawn, distanceCulled, frustumCulled, stale = 0, 0, 0, 0
	local sectionsTested, sectionsDrawn, sectionFrustum, sectionOcclusion = 0, 0, 0, 0
	local directionCulled, vertices, verticesCulled = 0, 0, 0
	for i = 1, count do
		local e = entries[i]
		if store[e.key] ~= e.list or getChunk( e.key ) ~= chunks[e.key] then
			stale = stale + 1
		elseif not ( MC.StreamHiddenChunkKeys and MC.StreamHiddenChunkKeys[e.key] ) then
			local visible, reason = entryVisible( e )
			if not visible then
				verticesCulled = verticesCulled + ( e.list.vertexCount or 0 )
				if reason == "distance" then distanceCulled = distanceCulled + 1
				else frustumCulled = frustumCulled + 1 end
			else
				local list, frame = e.list, e.frame
				local sections = list.sections
				local x, y, z = frame.originX + renderFrameX - cullEyeX,
					frame.originY + renderFrameY - cullEyeY, frame.originZ + renderFrameZ - cullEyeZ
				local dynamic = not depthStage and MC.RenderDynamicLights.AffectsBounds( x, y, z, list.bounds )
				local record = Occlusion and Occlusion.ChunkRecord( e.key, chunks[e.key] )
				local chunkDrawn = false
				for s = 1, sections and #sections or 1 do
					local section = sections and sections[s]
					local first, last, bounds = 1, #list, nil
					if section then first, last, bounds = section.first, section.last, section.bounds end
					sectionsTested = sectionsTested + 1
					if not sectionInFrustum( bounds, x, y, z ) then
						sectionFrustum = sectionFrustum + 1
						verticesCulled = verticesCulled + section.vertexCount
					elseif bounds and not bounds.protrudes and record and not Occlusion.SectionVisible( record, section.index ) then
						sectionOcclusion = sectionOcclusion + 1
						verticesCulled = verticesCulled + section.vertexCount
					else
						local sectionDrawn = false
						for j = first, last do
							local entry = list[j]
							if cullDirections and entry.direction
								and not SectionCull.DirectionVisible( entry.direction, entry.bounds, -x, -y, -z, directionMargin ) then
								directionCulled = directionCulled + 1
								verticesCulled = verticesCulled + entry.vertexCount
							else
								if not chunkDrawn then
									prepareChunkFrame( frame, true )
									pushMatrix( e.matrix )
									passMatrixPushed, chunkDrawn = true, true
								end
								if entry.material ~= currentMaterial then
									currentMaterial = entry.material
									if overrideMaterial then
										render.SetMaterial( overrideMaterial( currentMaterial, depthStage == "world_cutout" ) )
									elseif depthStage then
										render.SetMaterial( MC.RenderPBRSSR.DepthMaterial( currentMaterial, depthStage == "world_cutout" ) )
									else
										MC.RenderSky.Bind( currentMaterial )
										MC.RenderPBR.Bind( currentMaterial )
										render.SetMaterial( currentMaterial )
									end
								end
								entry.mesh:Draw()
								if dynamic then MC.RenderDynamicLights.Draw( currentMaterial, entry.mesh ) end
								meshes, vertices = meshes + 1, vertices + ( entry.vertexCount or 0 )
								sectionDrawn = true
							end
						end
						if sectionDrawn then sectionsDrawn = sectionsDrawn + 1 end
					end
				end
				if chunkDrawn then
					drawn = drawn + 1
					popMatrix()
					passMatrixPushed = false
				end
			end
		end
	end
	stats.sectionsTested, stats.sectionsDrawn = stats.sectionsTested + sectionsTested, stats.sectionsDrawn + sectionsDrawn
	stats.sectionFrustumCulled, stats.sectionOcclusionCulled = stats.sectionFrustumCulled + sectionFrustum, stats.sectionOcclusionCulled + sectionOcclusion
	stats.directionCulled = stats.directionCulled + directionCulled
	stats.vertices, stats.verticesCulled = stats.vertices + vertices, stats.verticesCulled + verticesCulled
	return drawn, distanceCulled, frustumCulled, stale, meshes
end

-- One cache per pass, collected with its runtime. Edits patch only dirty keys;
-- removing a chunk swaps the final entry into its slot instead of shifting or
-- rebuilding the world's arrays. The draw loop still rejects stale identities.
local function ensurePackEntries( pass, version )
	local cached = packEntries[pass]
	if not cached then
		cached = { entries = {}, indices = {} }
		packEntries[pass] = cached
	end
	local dirty = pass.dirtyChunks
	if cached.count == nil or not dirty and cached.version ~= version then
		cached.count = rebuildDrawList( pass.store, cached.entries, cached.indices )
		if dirty then for key in pairs( dirty ) do dirty[key] = nil end end
	elseif dirty and next( dirty ) ~= nil then
		local size = MC.API.Coords.BlockSize()
		local chunkW, chunkH = MC.CS * size, MC.CH * size
		local entries, indices, count = cached.entries, cached.indices, cached.count
		for key in pairs( dirty ) do
			local list, index = pass.store[key], indices[key]
			local chunk = list and MC.GetChunkByKey( key )
			if chunk then
				if not index then
					count = count + 1
					index, indices[key], entries[count] = count, count, {}
				end
				updateDrawEntry( entries[index], key, list, chunk, chunkW, chunkH )
			elseif index then
				if index < count then
					local last = entries[count]
					entries[index], indices[last.key] = last, index
				end
				entries[count], indices[key], count = nil, nil, count - 1
			end
			dirty[key] = nil
		end
		cached.count = count
	end
	cached.version = version
	return cached
end

-- Light-space visibility is independent of the player's camera and portals.
-- The caller owns the render transaction and restores a pushed matrix on error.
function MC.DrawPBRShadowCasters( groups, version, chunks, view, shadow )
	local intersects = MC.RenderShadowMath.Intersects
	local stats, token = shadow.stats, shadow.tileToken
	local currentSource, currentDepth, currentRecord, currentStage
	for g = 1, #groups do
		local passes = groups[g]
		for p = 1, #passes do
			local pass = passes[p]
			local cached = ensurePackEntries( pass, version )
			for i = 1, cached.count do
				local e = cached.entries[i]
				stats.testedChunks = stats.testedChunks + 1
				if pass.store[e.key] == e.list and MC.GetChunkByKey( e.key ) == chunks[e.key]
					and not ( MC.StreamHiddenChunkKeys and MC.StreamHiddenChunkKeys[e.key] ) then
					local list, frame = e.list, e.frame
					local x, y, z = frame.originX + renderFrameX, frame.originY + renderFrameY, frame.originZ + renderFrameZ
					if intersects( list.bounds, x, y, z, view ) then
						local sections, chunkDrawn = list.sections, false
						for s = 1, sections and #sections or 1 do
							local section = sections and sections[s]
							local first, last, bounds = 1, #list, nil
							if section then first, last, bounds = section.first, section.last, section.bounds end
							stats.testedSections = stats.testedSections + 1
							if intersects( bounds, x, y, z, view ) then
								for j = first, last do
									local entry = list[j]
									if entry.material ~= currentSource or pass.node.stage ~= currentStage then
										currentSource, currentStage = entry.material, pass.node.stage
										currentRecord = shadow.CasterMaterial( currentSource, currentStage )
									end
									-- Identical silhouettes shared by several surface passes draw once.
									-- Different albedo/cutout maps retain their distinct silhouettes.
									if currentRecord and currentRecord.seen[entry.mesh] ~= token then
										if not chunkDrawn then
											prepareChunkFrame( frame, true )
											cam.PushModelMatrix( e.matrix )
											shadow.modelPushed, chunkDrawn = true, true
										end
										if currentRecord.material ~= currentDepth then
											currentDepth = currentRecord.material
											render.SetMaterial( currentDepth )
										end
										entry.mesh:Draw()
										currentRecord.seen[entry.mesh] = token
										stats.draws = stats.draws + 1
										stats.vertices = stats.vertices + ( entry.vertexCount or 0 )
									elseif currentRecord then stats.duplicates = stats.duplicates + 1 end
								end
							else stats.culledSections = stats.culledSections + 1 end
						end
						if chunkDrawn then
							shadow.casterKeys[e.key] = true
							cam.PopModelMatrix()
							shadow.modelPushed = false
						end
					else stats.culledChunks = stats.culledChunks + 1 end
				end
			end
		end
	end
end

local function drawPackStages( translucent, depthOnly )
	-- The explicitly owned SSR merge uses clip-W materials and MIN blending.
	-- Lit RGB and translucent water must never reach this private depth texture.
	if depthOnly and ( translucent or not overrideMaterial
		and ( not MC.RenderPBRSSR or not MC.RenderPBRSSR.BeginDepth() ) ) then return end
	local started = SysTime()
	local runtime = MC.RenderPackRuntime
	local groups, version, chunks = runtime.GetStages( translucent )
	if not updateCullState( depthOnly ) then return end
	local stats = overrideMaterial and MC.DrawReflectionCullStats or depthOnly and MC.DrawSSRDepthCullStats or translucent and MC.DrawTranslucentCullStats or MC.DrawCullStats
	stats.sectionsTested, stats.sectionsDrawn, stats.sectionFrustumCulled, stats.sectionOcclusionCulled = 0, 0, 0, 0
	stats.directionCulled, stats.vertices, stats.verticesCulled = 0, 0, 0
	local totalTested, totalDrawn, totalDistance, totalFrustum, totalStale = 0, 0, 0, 0, 0
	local totalMeshes = 0
	for _, passes in ipairs( groups ) do
		for _, pass in ipairs( passes ) do
			-- Pack reflection redraws require PBR maps; sky is never a receiver.
			if not overrideMaterial or pass.node.adapter ~= "mc:sky_quad_v1" then
				local cached = ensurePackEntries( pass, version )
				local setCullMode = applyPassState( not translucent and not depthOnly )
				if translucent then render.OverrideDepthEnable( true, false ) end
				local ok, drawn, distance, frustum, stale, meshes = pcall( drawVisibleChunks,
					pass.store, cached.entries, cached.count, chunks, stats, depthOnly and pass.node.stage or nil )
				local matrixPushed = passMatrixPushed
				passMatrixPushed = false
				local restoreError = restoreChunkMeshRenderState( setCullMode, matrixPushed )
				if restoreError then
					if depthOnly then error( restoreError, 0 ) end
					MC.Fault( restoreError.code, "%s", restoreError.message )
				end
				if not ok then
					-- The SSR owner must restore its outer camera/RT before Fault,
					-- including when strict mode is disabled.
					if depthOnly then error( { code = "render_ssr_terrain_depth", message = tostring( drawn ) }, 0 ) end
					runtime.DrawFault( "stage=" .. pass.node.stage .. " pass=" .. pass.node.key .. ": " .. tostring( drawn ) )
					reportL2Faults()
					return
				end
				totalTested, totalDrawn = totalTested + cached.count, totalDrawn + drawn
				totalDistance, totalFrustum, totalStale = totalDistance + distance, totalFrustum + frustum, totalStale + stale
				totalMeshes = totalMeshes + meshes
			end
		end
	end
	stats.tested, stats.drawn = totalTested, totalDrawn
	stats.distanceCulled, stats.frustumCulled, stats.stale = totalDistance, totalFrustum, totalStale
	stats.meshes, stats.cpuMS = totalMeshes, ( SysTime() - started ) * 1000
	if not translucent then
		stats.totalMeshes, stats.totalVertices = stats.meshes, stats.vertices
	else
		MC.DrawCullStats.totalMeshes = ( MC.DrawCullStats.meshes or 0 ) + stats.meshes
		MC.DrawCullStats.totalVertices = ( MC.DrawCullStats.vertices or 0 ) + stats.vertices
	end
	if not depthOnly then reportL2Faults() end
end

concommand.Add( "mc_mesh_cull_stats", function()
	local names = { "opaque", "translucent", "ssr_depth", "reflection" }
	for pass = 1, 4 do
		local stats = pass == 1 and MC.DrawCullStats or pass == 2 and MC.DrawTranslucentCullStats
			or pass == 3 and MC.DrawSSRDepthCullStats or MC.DrawReflectionCullStats
		print( string.format( "[MC cull] %s draws=%d vertices=%d rejectedVertices=%d sections=%d/%d frustum=%d occlusion=%d directions=%d CPU=%.3fms GPU=unmeasured",
			names[pass], stats.meshes or 0, stats.vertices or 0, stats.verticesCulled or 0,
			stats.sectionsDrawn or 0, stats.sectionsTested or 0, stats.sectionFrustumCulled or 0,
			stats.sectionOcclusionCulled or 0, stats.directionCulled or 0, stats.cpuMS or 0 ) )
	end
	if Occlusion then
		local stats = Occlusion.stats
		print( string.format( "[MC portals] nodes=%d visited=%d traversals=%d cacheHits=%d topologyBuilds=%d topologyHits=%d lastTraversal=%.3fms",
			stats.nodes, stats.visited, stats.traversals, stats.cacheHits, stats.builds, stats.topologyHits, stats.lastMS ) )
	end
end )

local function drawAllChunks( translucent, depthOnly )
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	local runtime = MC.Need( MC.RenderPackRuntime, "render_l2_runtime_missing", "L2 runtime did not load" )
	if runtime then drawPackStages( translucent, depthOnly ) end
end

MC.RenderPBRSSR.RegisterDepthRenderer( "terrain", function()
	if meshRenderingEnabled() then drawAllChunks( false, true ) end
end )

-- Redraw opaque/cutout terrain with resolve( surfaceMaterial, cutout ) in place
-- of each surface material, e.g. block reflections. Culling matches the depth
-- pass; the caller owns camera/RT/blend state. Errors propagate.
function MC.DrawTerrainOverride( resolve )
	if not meshRenderingEnabled() then return end
	overrideMaterial = resolve
	local ok, err = pcall( drawAllChunks, false, true )
	overrideMaterial = nil
	if not ok then error( err, 0 ) end
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
	if bDepth then return end
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime() or nil
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( false, bDepth ) end
	if perf then
		MC.StreamPerformanceAddFrameStage( "render.opaque", ( SysTime() - started ) * 1000, {
			renderOpaqueTested = MC.DrawCullStats and MC.DrawCullStats.tested or 0,
			renderOpaqueDrawn = MC.DrawCullStats and MC.DrawCullStats.drawn or 0,
			renderOpaqueMeshes = MC.DrawCullStats and MC.DrawCullStats.meshes or 0,
		} )
	end
end )
-- translucent blocks only; the bulk of the world stays in the opaque pass above
hook.Add( "PostDrawTranslucentRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	if bDepth then return end
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime() or nil
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( true, bDepth ) end
	if perf then MC.StreamPerformanceAddFrameStage( "render.translucent", ( SysTime() - started ) * 1000 ) end
end )
