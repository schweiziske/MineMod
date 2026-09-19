-- DX9 sun shadows: each update clears and redraws both complete light volumes.
-- The atlas and projection are published together; no partial tile reuse.
MC = MC or {}
local S = MC.RenderPBRShadows or { targets = {}, depthMaterials = {}, materialCount = 0 }
MC.RenderPBRShadows = S
local B, M, R, L = MC.RenderPBR, MC.RenderShadowMath, MC.RenderL2Resources, MC.RenderPackRuntime
local requireValue = R.Require
local DEPTH_MATERIAL_VERSION = 2
if S.depthMaterialVersion ~= DEPTH_MATERIAL_VERSION then
	-- Retained caster snapshots must also lose the old ALWAYS comparison.
	for _, record in pairs( S.depthMaterials ) do
		record.material:SetInt( "$depthtest", 1 )
		record.material:SetInt( "$writedepth", 0 )
		record.material:SetInt( "$ignorez", 0 )
		record.material:Recompute()
	end
	S.depthMaterialVersion = DEPTH_MATERIAL_VERSION
end
local floor, sqrt, atan2 = math.floor, math.sqrt, math.atan2
local enabled = CreateClientConVar( "mc_pbr_shadows", "1", true, false, "Cached two-cascade sun shadows for PBR packs", 0, 1 )
local resolution = CreateClientConVar( "mc_pbr_shadow_resolution", "512", true, false, "Per-cascade shadow size: 256, 512 or 1024", 256, 1024 )
local distance = CreateClientConVar( "mc_pbr_shadow_range", "64", true, false, "Far shadow radius in Minecraft blocks; near radius is one quarter", 8, 128 )
local interval = CreateClientConVar( "mc_pbr_shadow_interval", "0.05", true, false, "Minimum seconds between changed shadow renders; 0 = every frame", 0, 1 )
local strength = CreateClientConVar( "mc_pbr_shadow_strength", "1", true, false, "Occlusion of direct sunlight only", 0, 1 )
local bias = CreateClientConVar( "mc_pbr_shadow_bias", "0.03", true, false, "Base receiver depth bias in Minecraft blocks", 0, 0.5 )
local settingsRevision = 1
local settings = {}
local function readSettings()
	local size = resolution:GetInt()
	settings.enabled, settings.size = enabled:GetBool(), size <= 256 and 256 or size <= 512 and 512 or 1024
	settings.range, settings.interval = distance:GetFloat(), interval:GetFloat()
	settings.strength, settings.bias = strength:GetFloat(), bias:GetFloat()
	settingsRevision = settingsRevision + 1
end
for _, name in ipairs( { "mc_pbr_shadows", "mc_pbr_shadow_resolution", "mc_pbr_shadow_range",
	"mc_pbr_shadow_interval", "mc_pbr_shadow_strength", "mc_pbr_shadow_bias" } ) do
	cvars.AddChangeCallback( name, readSettings, "mc_l2_pbr_shadows" )
end
readSettings()
S.stats = { mode = "full", updates = 0, nearUpdates = 0, farUpdates = 0, cascades = 0, cached = 0, throttled = 0, failures = 0, draws = 0, vertices = 0,
	testedChunks = 0, testedSections = 0, culledChunks = 0, culledSections = 0, duplicates = 0,
	testedRegions = 0, culledRegions = 0, regionChunks = 0, coverageUpdates = 0, fullCoverageFallbacks = 0,
	materialWrites = 0, cpuMS = 0, status = "initializing" }
S.surfaceMaterials = setmetatable( {}, { __mode = "k" } )
S.renderRevision, S.tileToken = ( S.renderRevision or 0 ) + 1, ( S.tileToken or 0 ) + 1
S.valid, S.modelPushed, S.current, S.pending = false, false, {}, {}
S.rendering = false
S.nextUpdate, S.retryAt, S.camera = 0, 0, { enabled = false }
S.fullDirty, S.cascadeCasters = false, { {}, {} }
-- Discard metadata retained from the retired partial-update path on refresh.
S.dirtyChunks, S.dirtyCount, S.nearDirty, S.farDirty = nil, nil, nil, nil
local matrix, angles, unitTone = Matrix(), Angle(), Vector( 1, 1, 1 )
local setups = {
	{ type = "3D", origin = Vector(), angles = angles, ortho = {}, y = 0, drawviewmodel = false,
		drawviewer = false, dopostprocess = false, bloomtone = false },
	{ type = "3D", origin = Vector(), angles = angles, ortho = {}, y = 0, drawviewmodel = false,
		drawviewer = false, dopostprocess = false, bloomtone = false },
}
local stageNames = { "world_opaque", "world_cutout", "world_translucent" }
local pushedRT, startedCam, stateActive, toneActive, oldTone = false, false, false, false, nil
local clipActive, oldClip = false, false
local apiValidated = false
B.DisableShadow()

-- Any scene change invalidates the complete atlas. Notifications received
-- during a render remain dirty for the next update.
function S.GeometryChanged()
	S.fullDirty = true
end

function S.VisibilityChanged()
	S.fullDirty = true
end

function S.RuntimeChanged( active )
	if active == S.active then S.fullDirty = true end
end

local function shadowProgram( active )
	if not active then return nil end
	for s = 1, #stageNames do
		local nodes = active.bundle.nodes[stageNames[s]]
		for i = 1, #nodes do if nodes[i].shadowProgram then return nodes[i].shadowProgram end end
	end
end

local function ensureTarget( size )
	if not apiValidated then
		requireValue( GetRenderTargetEx and render.PushRenderTarget and render.PopRenderTarget and render.Clear
			and render.SetStencilEnable
			and render.OverrideBlend and render.OverrideAlphaWriteEnable and render.OverrideColorWriteEnable
			and render.OverrideDepthEnable and render.EnableClipping and render.GetToneMappingScaleLinear
			and render.SetToneMappingScaleLinear and cam.Start and cam.End and cam.PushModelMatrix and cam.PopModelMatrix
			and matrix.SetField and MC.DrawPBRShadowCasters and M and M.Configure and M.Same and M.CoversCamera and atan2
			and MATERIAL_RT_DEPTH_SEPARATE ~= nil and RT_SIZE_LITERAL ~= nil and IMAGE_FORMAT_RGBA8888 ~= nil
			and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil,
			"render_pbr_shadow_api", "PBR shadows require orthographic views, a separate depth buffer and exact RGBA8 writes" )
		apiValidated = true
	end
	local target = S.targets[size]
	if not target then
		target = GetRenderTargetEx( "mc_l2_pbr_shadow_rgba8_1_" .. size, size * 2, size,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		requireValue( target and not target:IsError() and target:Width() == size * 2 and target:Height() == size,
			"render_pbr_shadow_target", "could not create the bounded point-filter shadow atlas" )
		S.targets[size] = target
	end
	return target
end

function S.CasterMaterial( surface, stage )
	local binding = S.surfaceMaterials[surface]
	local record
	if binding and binding.program == S.program and binding.stage == stage then
		record = binding.record
	else
		local source = R.SourceTexture( surface )
		local signature = S.program.vertex .. "/" .. S.program.pixel .. "/" .. stage .. "/" .. source:GetName()
		record = S.depthMaterials[signature]
		if not record then
			requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
			local material = CreateMaterial( "mc_l2_pbr_depth" .. DEPTH_MATERIAL_VERSION .. "_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
				["$vertexshader"] = S.program.vertex, ["$pixshader"] = S.program.pixel,
				["$basetexture"] = source:GetName(), ["$x360appchooser"] = 1, ["$nocull"] = 1,
				-- WRITEDEPTH=1 forces ALWAYS; renderAtlas owns the write override.
				["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
				["$linearread_basetexture"] = 1, ["$linearwrite"] = 1,
				["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "-1", ["$c0_w"] = "1",
				["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "0",
				["$c1_w"] = stage == "world_cutout" and "0.5" or "0",
			} )
			requireValue( material and not material:IsError(), "render_pbr_shadow_material", "could not create depth material" )
			material:SetTexture( "$basetexture", source )
			record = { material = material, source = source, seen = setmetatable( {}, { __mode = "k" } ) }
			S.depthMaterials[signature], S.materialCount = record, S.materialCount + 1
		else
			requireValue( R.SameTexture( source, record.source ), "render_pbr_shadow_texture_identity", "shadow albedo dimensions changed" )
		end
		S.surfaceMaterials[surface] = { program = S.program, stage = stage, record = record }
	end
	if record.revision ~= S.renderRevision then
		-- Both cascades share one depth plane. Constant writes happen once per
		-- material per update, including when adjacent chunks alternate materials.
		local view, material = S.pending.views[1], record.material
		material:SetFloat( "$c0_x", view.fx )
		material:SetFloat( "$c0_y", view.fy )
		material:SetFloat( "$c0_z", view.fz )
		material:SetFloat( "$c0_w", 1 / view.zfar )
		material:SetFloat( "$c1_x", view.x )
		material:SetFloat( "$c1_y", view.y )
		material:SetFloat( "$c1_z", view.z )
		record.revision = S.renderRevision
		S.stats.materialWrites = S.stats.materialWrites + 7
	end
	return record
end

local function renderAtlas( groups, version, chunks )
	local pending = S.pending
	local target = ensureTarget( pending.resolution )
	pending.target = target
	local forward = pending.views[1]
	angles.p = atan2( -forward.fz, sqrt( forward.fx * forward.fx + forward.fy * forward.fy ) ) * ( 180 / math.pi )
	angles.y, angles.r = atan2( forward.fy, forward.fx ) * ( 180 / math.pi ), 0
	for i = 1, 2 do
		local view, setup = pending.views[i], setups[i]
		setup.origin.x, setup.origin.y, setup.origin.z = view.x, view.y, view.z
		setup.ortho.left, setup.ortho.right = -view.radius, view.radius
		setup.ortho.top, setup.ortho.bottom = -view.radius, view.radius
		setup.znear, setup.zfar = view.znear, view.zfar
		setup.x, setup.w, setup.h = ( i - 1 ) * pending.resolution, pending.resolution, pending.resolution
	end
	render.PushRenderTarget( target ) pushedRT = true
	-- Water/portal views can leave a clip plane active. It belongs to the outer
	-- camera and must not cut the light volume.
	oldClip = render.EnableClipping( false ) clipActive = true
	oldTone = render.GetToneMappingScaleLinear()
	toneActive = true
	render.SetToneMappingScaleLinear( unitTone )
	stateActive = true
	render.SetStencilEnable( false )
	render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
	render.OverrideAlphaWriteEnable( true, true )
	render.OverrideColorWriteEnable( true, true )
	render.OverrideDepthEnable( true, true )
	render.Clear( 255, 255, 255, 255, true, true )
	for i = 1, 2 do
		S.casterKeys = S.cascadeCasters[i]
		for key in pairs( S.casterKeys ) do S.casterKeys[key] = nil end
		S.tileToken = S.tileToken + 1
		cam.Start( setups[i] ) startedCam = true
		MC.DrawPBRShadowCasters( groups, version, chunks, pending.views[i], S )
		cam.End() startedCam = false
	end
end

-- Cleanup always attempts every owned state before reporting. Strict faults
-- may throw, so none are reported until matrix/camera/RT cleanup has finished.
local cleanupError
local function restore( fn, ... )
	local ok, err = pcall( fn, ... )
	if not ok and not cleanupError then cleanupError = tostring( err ) end
end
local function cleanup()
	cleanupError = nil
	if S.modelPushed then restore( cam.PopModelMatrix ) S.modelPushed = false end
	if startedCam then restore( cam.End ) startedCam = false end
	if stateActive then
		restore( render.SetStencilEnable, false )
		restore( render.OverrideDepthEnable, false, false )
		restore( render.OverrideColorWriteEnable, false, false )
		restore( render.OverrideAlphaWriteEnable, false, false )
		restore( render.OverrideBlend, false )
		-- Depth materials use $nocull; we never changed the outer winding mode.
		stateActive = false
	end
	if toneActive then restore( render.SetToneMappingScaleLinear, oldTone ) toneActive = false end
	if pushedRT then restore( render.PopRenderTarget ) pushedRT = false end
	if clipActive then restore( render.EnableClipping, oldClip ) clipActive = false end
	return cleanupError
end

local function publish()
	local current = S.current
	B.PublishShadow( current.target, matrix, settings.bias * current.blockSize / current.views[1].zfar, settings.strength )
	S.publishedSettings, S.publishedRevision = settingsRevision, B.shadowRevision
end

local function ensurePublished()
	-- Refreshing only cl_render_pbr resets its material constants, but leaves
	-- this module's rendered pixels intact. Rebind them without a GPU redraw.
	if S.publishedSettings ~= settingsRevision or S.publishedRevision ~= B.shadowRevision then publish() end
end

local function disable( status )
	S.stats.status, S.publishedSettings = status, nil
	B.DisableShadow()
	return false
end

function S.Update( x, y, z, renderView )
	if S.rendering then return false end
	if not settings.enabled or settings.strength == 0 or MC.MeshRender and not MC.MeshRender:GetBool() then return disable( "off" ) end
	local active = L.active
	if active ~= S.active then
		S.active, S.program, S.valid = active, shadowProgram( active ), false
		S.retryAt, S.nextUpdate = 0, 0
		B.DisableShadow()
	end
	if not S.program then return disable( "no_shadow_program" ) end
	local size = MC.API.Coords.BlockSize()
	if active.world ~= MC.World or active.worldGeneration ~= MC.StateWorldGeneration or active.blockSize ~= size
		or active.cs ~= MC.CS or active.ch ~= MC.CH or MC.WorldFrameSettled and not MC.WorldFrameSettled() then
		S.valid = false
		return disable( "world_transition" )
	end
	B.PrepareView( x, y, z )
	local sx, sy, sz, radiance = B.SunComponents()
	if radiance <= 0 then return disable( "night" ) end
	-- Quantize the sun direction, not the receiver/camera position. Small solar
	-- changes then share a map; each cascade still snaps to its own texel grid.
	sx, sy, sz = floor( sx * 2048 + 0.5 ), floor( sy * 2048 + 0.5 ), floor( sz * 2048 + 0.5 )
	local inverse = 1 / sqrt( sx * sx + sy * sy + sz * sz )
	sx, sy, sz = sx * inverse, sy * inverse, sz * inverse
	-- The world adapter refreshes this cache at the re-origin boundary.
	-- Polling WorldToRenderPos here would allocate an engine Vector each frame.
	local frameX, frameY, frameZ = MC.ChunkRenderFrameOffset()
	local current, pending = S.current, S.pending
	if S.valid and ( current.frameX ~= frameX or current.frameY ~= frameY or current.frameZ ~= frameZ ) then
		S.valid = false
		B.DisableShadow()
	end
	M.Configure( pending, x, y, z, sx, sy, sz, size, settings.size, settings.range )
	-- Full light-space coverage is independent of view direction/FOV. Never
	-- carry a camera-derived caster cone from an older cached projection.
	pending.views[1].cull, pending.views[2].cull = nil, nil
	local camera = S.camera
	camera.x, camera.y, camera.z = x, y, z
	local coverageMiss = S.valid and not ( M.CoversCamera( current.views[1], camera )
		and M.CoversCamera( current.views[2], camera ) )
	local groups, version, chunks = L.GetStages( false )
	local geometry, visibility = MC.ChunkDrawListVersion(), MC.StreamVisibilityVersion or 0
	if S.valid and not S.fullDirty and not coverageMiss and current.version == version
		and current.geometry == geometry and current.visibility == visibility and M.Same( current, pending ) then
		ensurePublished()
		S.stats.cached, S.stats.status = S.stats.cached + 1, "cached"
		return true
	end
	local now = SysTime()
	if now < S.retryAt then return disable( "retry_wait" ) end
	-- Retain only a complete previous atlas during the configured interval.
	-- A remote view or changed world frame must still refresh immediately.
	if S.valid and not coverageMiss and now < S.nextUpdate then
		ensurePublished()
		S.stats.throttled, S.stats.status = S.stats.throttled + 1, "throttled"
		return true
	end
	S.nextUpdate = now + settings.interval
	S.fullDirty = false
	S.renderRevision = S.renderRevision + 1
	local stats = S.stats
	stats.draws, stats.vertices, stats.duplicates = 0, 0, 0
	stats.testedChunks, stats.testedSections, stats.culledChunks, stats.culledSections = 0, 0, 0, 0
	stats.testedRegions, stats.culledRegions, stats.regionChunks = 0, 0, 0
	S.rendering = true
	local ok, err = pcall( renderAtlas, groups, version, chunks )
	local restoreError = cleanup()
	S.rendering = false
	if not ok or restoreError then
		S.valid, S.retryAt = false, now + 1
		stats.failures = stats.failures + 1
		disable( "failed" )
		local code, message = "render_pbr_shadow_draw", tostring( err )
		if type( err ) == "table" then code, message = err.code, err.message end
		if restoreError then message = message .. "; cleanup: " .. restoreError end
		stats.lastError = message
		L.QueueFault( code, message )
		L.ReportFaults()
		return false
	end
	pending.version, pending.geometry, pending.visibility, pending.blockSize = version, geometry, visibility, size
	pending.frameX, pending.frameY, pending.frameZ = frameX, frameY, frameZ
	S.current, S.pending, S.valid = pending, current, true
	for row = 1, 4 do for col = 1, 4 do matrix:SetField( row, col, pending.values[( row - 1 ) * 4 + col] ) end end
	publish()
	stats.updates, stats.status, stats.lastError = stats.updates + 1, "ready", nil
	stats.nearUpdates, stats.farUpdates = stats.nearUpdates + 1, stats.farUpdates + 1
	stats.cascades = 2
	if coverageMiss then stats.coverageUpdates = stats.coverageUpdates + 1 end
	stats.cpuMS, stats.lastUpdate = ( SysTime() - now ) * 1000, now
	return true
end

function S.VolumeEnabled()
	return settings.enabled and settings.strength > 0 and B.SunEnabled()
		and ( not MC.MeshRender or MC.MeshRender:GetBool() )
end

local volumeCamera = { enabled = false }
-- Read the published atlas only. This consumer must not change update timing,
-- render another map, or pair a pending projection with the current pixels.
function S.VolumeSnapshot( x, y, z )
	if not S.VolumeEnabled() or not S.valid or S.rendering or S.active ~= L.active
		or S.publishedSettings ~= settingsRevision or S.publishedRevision ~= B.shadowRevision then return nil end
	local active, current = L.active, S.current
	if active.world ~= MC.World or active.worldGeneration ~= MC.StateWorldGeneration
		or current.blockSize ~= MC.API.Coords.BlockSize() or MC.WorldFrameSettled and not MC.WorldFrameSettled() then return nil end
	local fx, fy, fz = MC.ChunkRenderFrameOffset()
	if current.frameX ~= fx or current.frameY ~= fy or current.frameZ ~= fz then return nil end
	volumeCamera.x, volumeCamera.y, volumeCamera.z = x, y, z
	if not M.CoversCamera( current.views[2], volumeCamera ) then return nil end
	return current.target, matrix, settings.bias * current.blockSize / current.views[1].zfar, settings.strength
end

-- Draw preparation owns shadow updates. Remove the old early hook on Lua
-- refresh too: nested views could overwrite its result before terrain draws.
hook.Remove( "PreDrawOpaqueRenderables", "mc_l2_pbr_shadows" )

concommand.Add( "mc_pbr_shadow_stats", function()
	local stats = S.stats
	print( string.format( "[MC PBR shadow] mode=full %s updates=%d near=%d far=%d cached=%d throttled=%d failures=%d size=%dx%d range=%.1f blocks updateCPU=%.3fms GPU=unmeasured",
		stats.status, stats.updates, stats.nearUpdates, stats.farUpdates, stats.cached, stats.throttled, stats.failures,
		settings.size * 2, settings.size, settings.range, stats.cpuMS ) )
	print( string.format( "[MC PBR shadow] lastUpdate draws=%d vertices=%d chunksTested=%d chunksCulled=%d sectionsTested=%d sectionsCulled=%d duplicates=%d materials=%d constantWrites=%d",
		stats.draws, stats.vertices, stats.testedChunks, stats.culledChunks, stats.testedSections, stats.culledSections,
		stats.duplicates, S.materialCount, stats.materialWrites ) )
	local views = S.current.views
	print( string.format( "[MC PBR shadow] regionsTested=%d regionsCulled=%d chunksSkippedByRegions=%d coverageUpdates=%d fullCoverageFallbacks=%d nearViewCulling=%s farViewCulling=%s",
		stats.testedRegions, stats.culledRegions, stats.regionChunks, stats.coverageUpdates, stats.fullCoverageFallbacks,
		tostring( views and views[1].cull and views[1].cull.enabled == true or false ),
		tostring( views and views[2].cull and views[2].cull.enabled == true or false ) ) )
end )
