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
	"Skip drawing MC chunk meshes outside the view frustum" ) )
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

local function restoreChunkMeshRenderState( setCullMode )
	local cullOK, cullError = true, nil
	if setCullMode then cullOK, cullError = pcall( restoreDefaultCullMode ) end
	local colorOK, colorError = pcall( resetColorWriteOverride )
	local depthOK, depthError = pcall( resetDepthOverride )
	if not cullOK then MC.Fault( "render_l2_restore_cull", "%s", tostring( cullError ) ) end
	if not colorOK then MC.Fault( "render_l2_restore_color", "%s", tostring( colorError ) ) end
	if not depthOK then MC.Fault( "render_l2_restore_depth", "%s", tostring( depthError ) ) end
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
			render.SetMaterial( currentMaterial )
		end
		entry.mesh:Draw()
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
end

-- Monotonic mesh-change counter: bumps whenever chunk mesh lists are built,
-- replaced, or freed. The heightfield shadow module polls it to re-render
-- its cached top-down height map only when geometry actually changed.
function MC.ChunkDrawListVersion()
	return drawListVersion
end

local function updateDrawEntry( e, key, list, c, chunkW, chunkH )
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
	prepareChunkFrame( frame, true )
	e.key, e.list, e.frame, e.matrix = key, list, frame, frame.matrix
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
local planeCount = 0
local cullEyeX, cullEyeY, cullEyeZ = 0, 0, 0
local maxDistSq = 0 -- 0 = unlimited

MC.DrawCullStats = MC.DrawCullStats or {
	tested = 0,
	drawn = 0,
	distanceCulled = 0,
	frustumCulled = 0,
	stale = 0,
	meshes = 0,
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

	local size = MC.API.Coords.BlockSize()
	local hx, hz = MC.CS * size * 0.5, MC.CH * size * 0.5

	local dist = MC.EffectiveMeshDrawDistance and MC.EffectiveMeshDrawDistance()
		or ( MC.MeshDrawDistance and MC.MeshDrawDistance.GetFloat and MC.MeshDrawDistance:GetFloat() or 0 )
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
local function drawPackChunk( key, translucent )
	local runtime = MC.Need( MC.RenderPackRuntime, "render_l2_runtime_missing", "L2 runtime did not load" )
	if not runtime or not runtime.ChunkCurrent( key ) then return end
	local groups = runtime.GetStages( translucent )
	local setCullMode = applyPassState( not translucent )
	if translucent then render.OverrideDepthEnable( true, false ) end
	local ok, err = pcall( function()
		for _, passes in ipairs( groups ) do
			for _, pass in ipairs( passes ) do
				local list = pass.store[key]
				if list then drawMeshListInner( list ) end
			end
		end
	end )
	restoreChunkMeshRenderState( setCullMode )
	if not ok then runtime.DrawFault( "chunk=" .. tostring( key ) .. ": " .. tostring( err ) ) end
	reportL2Faults()
end

function MC.DrawChunk( key )
	drawPackChunk( key, false )
end

function MC.DrawChunkTranslucent( key )
	drawPackChunk( key, true )
end

local function drawVisibleChunks( store, entries, count, chunks )
	local pushMatrix = cam.PushModelMatrix
	local popMatrix = cam.PopModelMatrix
	local getChunk = MC.GetChunkByKey
	local currentMaterial, meshes = nil, 0
	local drawn, distanceCulled, frustumCulled, stale = 0, 0, 0, 0
	for i = 1, count do
		local e = entries[i]
		if store[e.key] ~= e.list or getChunk( e.key ) ~= chunks[e.key] then
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
				passMatrixPushed = true
				currentMaterial = drawMeshListInner( e.list, currentMaterial )
				meshes = meshes + #e.list
				popMatrix()
				passMatrixPushed = false
			end
		end
	end
	return drawn, distanceCulled, frustumCulled, stale, meshes
end

-- One cache per pass, collected with its runtime. Edits patch only dirty keys;
-- removing a chunk swaps the final entry into its slot instead of shifting or
-- rebuilding the world's arrays. The draw loop still rejects stale identities.
local packEntries = setmetatable( {}, { __mode = "k" } )

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

local function drawPackStages( translucent )
	local runtime = MC.RenderPackRuntime
	local groups, version, chunks = runtime.GetStages( translucent )
	updateCullState()
	local totalTested, totalDrawn, totalDistance, totalFrustum, totalStale = 0, 0, 0, 0, 0
	local totalMeshes = 0
	for _, passes in ipairs( groups ) do
		for _, pass in ipairs( passes ) do
			local cached = ensurePackEntries( pass, version )
			local setCullMode = applyPassState( not translucent )
			if translucent then render.OverrideDepthEnable( true, false ) end
			local ok, drawn, distance, frustum, stale, meshes = pcall( drawVisibleChunks,
				pass.store, cached.entries, cached.count, chunks )
			if passMatrixPushed then cam.PopModelMatrix() passMatrixPushed = false end
			restoreChunkMeshRenderState( setCullMode )
			if not ok then
				runtime.DrawFault( "stage=" .. pass.node.stage .. " pass=" .. pass.node.key .. ": " .. tostring( drawn ) )
				reportL2Faults()
				return
			end
			totalTested, totalDrawn = totalTested + cached.count, totalDrawn + drawn
			totalDistance, totalFrustum, totalStale = totalDistance + distance, totalFrustum + frustum, totalStale + stale
			totalMeshes = totalMeshes + meshes
		end
	end
	if not translucent then
		local stats = MC.DrawCullStats
		stats.tested, stats.drawn = totalTested, totalDrawn
		stats.distanceCulled, stats.frustumCulled, stats.stale = totalDistance, totalFrustum, totalStale
		stats.meshes = totalMeshes
	end
	reportL2Faults()
end

local function drawAllChunks( translucent )
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	local runtime = MC.Need( MC.RenderPackRuntime, "render_l2_runtime_missing", "L2 runtime did not load" )
	if runtime then drawPackStages( translucent ) end
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
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( false ) end
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
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime() or nil
	if not bSky3D and meshRenderingEnabled() then drawAllChunks( true ) end
	if perf then MC.StreamPerformanceAddFrameStage( "render.translucent", ( SysTime() - started ) * 1000 ) end
end )
