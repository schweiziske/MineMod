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
local chunkMatrices = {} -- key -> Matrix; chunk origins never move for a key

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
			e.key = key
			e.list = list
			e.x = ox + chunkW * 0.5
			e.y = oy + chunkW * 0.5
			e.z = oz + chunkH * 0.5
			local m = chunkMatrices[key]
			if not m then
				m = Matrix()
				m:SetTranslation( Vector( ox, oy, oz ) )
				chunkMatrices[key] = m
			end
			e.matrix = m
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

MC.DrawCullStats = MC.DrawCullStats or { tested = 0, drawn = 0 }

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
	local dx, dy, dz = e.x - cullEyeX, e.y - cullEyeY, e.z - cullEyeZ
	if maxDistSq > 0 and dx * dx + dy * dy + dz * dz > maxDistSq then return false end
	for i = 1, planeCount do
		if planeNX[i] * dx + planeNY[i] * dy + planeNZ[i] * dz < -planeR[i] then return false end
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
		-- Light data lives in one shared atlas bound to $texture1 once, so the
		-- per-chunk work here is pure Lua: LRU-touch the chunk's atlas slot and
		-- queue a budgeted PreRender bake if it is dirty or unassigned. The
		-- per-chunk SetTexture this used to do was the last per-chunk material
		-- state write in the frame.
		if MC.TouchGpuChunkLightTexture then MC.TouchGpuChunkLightTexture( key ) end
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
		-- Same per-frame binds as the opaque GPU path: LRU-touch the chunk's
		-- light atlas slot and upload the shadow constants once per material.
		if MC.TouchGpuChunkLightTexture then MC.TouchGpuChunkLightTexture( key ) end
		if MC.BindMeshShadowMap then MC.BindMeshShadowMap( material ) end
	end
	drawMeshList( MC.MeshesTrans[key], material, isGpuLightTexture and "test" or false, nil, isGpuLightTexture )
end

local function drawVisibleChunks( store, entries, count, drawFn, material, isGpuLightTexture )
	local pushMatrix = cam.PushModelMatrix
	local popMatrix = cam.PopModelMatrix
	local drawn = 0
	for i = 1, count do
		local e = entries[i]
		if store[e.key] == e.list and entryVisible( e ) then
			drawn = drawn + 1
			pushMatrix( e.matrix )
			drawFn( e.key, material, isGpuLightTexture )
			popMatrix()
		end
	end
	return drawn
end

local function drawAllChunks( store, drawFn )
	ensureDrawLists()
	local translucent = store == MC.MeshesTrans
	local entries, count
	if translucent then
		entries, count = transEntries, transCount
	else
		entries, count = opaqueEntries, opaqueCount
	end
	if count == 0 then return end
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
	local ok, drawn = pcall( drawVisibleChunks, store, entries, count, drawFn, material, isGpuLightTexture )
	passActive = false
	restoreChunkMeshRenderState( setCullMode )
	if not ok then error( drawn ) end
	if not translucent then
		local stats = MC.DrawCullStats
		stats.tested = count
		stats.drawn = drawn
	end
end

hook.Remove( "PostDrawOpaqueRenderables", "mc_draw_chunks" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_draw_chunks" )
-- bSky mirrors the engine's DF_DRAWSKYBOX draw flag: it is also true for the
-- MAIN pass whenever the 2D sky is drawn within it (maps without a 3D skybox,
-- or r_3dsky 0) and for water reflection passes, and it is false underwater.
-- Guarding on it blanks the whole world outdoors on 2D-sky maps, so only the
-- real 3D-skybox pass (bSky3D) is skipped.
hook.Add( "PostDrawOpaqueRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	if bSky3D then return end
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.Meshes, MC.DrawChunk )
end )
-- translucent blocks only; the bulk of the world stays in the opaque pass above
hook.Add( "PostDrawTranslucentRenderables", "mc_draw_chunks", function( bDepth, bSky, bSky3D )
	if bSky3D then return end
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.MeshesTrans, MC.DrawChunkTranslucent )
end )
