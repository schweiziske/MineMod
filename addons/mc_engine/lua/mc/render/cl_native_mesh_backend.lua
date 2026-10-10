MC = MC or {}
if MC.NativeMeshBackendModuleLoaded then return end
MC.NativeMeshBackendModuleLoaded = true

--[[----------------------------------------------------------------------------
	mcswep_native_bridge.lua 鈥斺€?MCSWEP 鍘熺敓寤洪潰鍚庣閫傞厤鍣?鐙珛鎻掍欢, 涓嶆敼鍘熼」鐩?

	瀹夎: 鏈枃浠堕殢 gmcl_mcswep_native_mesh DLL 鍙戝竷, 浣滀负鐙珛 addon:
	    garrysmod/addons/mcswep-native/lua/autorun/client/mcswep_native_bridge.lua
	    garrysmod/lua/bin/gmcl_mcswep_native_mesh_win64.dll (鎴?_win32)
	鍘熼」鐩?MCSWEP)闆舵敼鍔ㄣ€傛病瑁?DLL / 鎻℃墜澶辫触 / 鍘熼」鐩笉瀛樺湪鏃舵湰鏂囦欢涓嶅仛浠讳綍浜嬨€?

	鍘熺悊(杩愯鏃惰ˉ涓?+ 浠ｇ悊 mesh, 濂戠害瑙佸師鐢熶粨搴?INTERFACE.md v1):
	  1. 鍖呬竴灞?MC.BuildChunkMesh / MC.RebuildChunkMeshLighting / MC.FreeChunkMesh銆?
	     婵€娲诲悗 Lua 涓嶅啀鏋勫缓 IMesh; 姣忔閲嶅缓璇锋眰鎶婅 chunk 鎵撳寘鎺ㄧ粰 mcmesh
	     (ApplyChunk 鏄潈濞佸揩鐓? native 鑷 diff 鍑鸿剰 section 骞跺湪宸ヤ綔绾跨▼閲嶅缓)銆?
	  2. 寰€ MC.Meshes / MC.MeshesTrans 濉炰唬鐞嗗璞? 鍏?:Draw() 杞皟
	     mcmesh.DrawChunk(cx,cy,cz,pass)銆俢l_draw 鐨勪富寰幆銆乻hadow map銆?
	     heightfield 閮藉彧瀵规潯鐩皟 :Draw(), 鏉愯川/鐭╅樀/娓叉煋鐘舵€佺敱鍘熺绾胯缃?
	     C++ 渚у彧鐢讳笉缁?鈥斺€?涓夋潯娑堣垂璺緞闆舵敼鍔ㄨ嚜鍔ㄥ娴併€?
	  3. 姣忓抚 mcmesh.Think(棰勭畻) 钀藉湴宸ヤ綔绾跨▼缁撴灉銆?
	  4. 浠讳竴 native 璋冪敤澶辫触 -> 瑙ｉ櫎鍏ㄩ儴琛ヤ竵銆佹竻浠ｇ悊銆佸叏鍥句氦杩?Lua 璺緞閲嶅缓銆?

	ConVar / 鎸囦护:
	  mc_native_mesh        1=鍚敤(榛樿), 0=绂佺敤骞跺洖閫€ Lua
	  mc_native_think_ms    姣忓抚钀藉湴棰勭畻, 榛樿 3.0
	  mc_native_toggle      A/B 鐑垏鎹袱绉嶅悗绔?鍗虫椂, 甯﹁€楁椂鏃ュ織)
	  mc_native_status      鎵撳嵃褰撳墠鍚庣涓庢ā鍧楃粺璁?	  mc_native_pack_profile [reset]  鎵撳嵃/閲嶇疆 Lua 鏁版嵁鎵撳寘 profiling
------------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end



local CONVAR_ENABLED = CreateClientConVar( "mc_native_mesh", "1", true, false,
	"MCSWEP native mesh backend: 1 = use mcswep_native_mesh module when available, 0 = pure Lua" )
local CONVAR_THINK_MS = CreateClientConVar( "mc_native_think_ms", "3", true, false,
	"Per-frame budget (ms) for native mesh finalization" )
local CONVAR_GREEDY = CreateClientConVar( "mc_native_greedy", "0", true, false,
	"Simple native greedy meshing for opaque full cubes" )
local CONVAR_DIRECTIONAL_DRAW = CreateClientConVar( "mc_native_directional_draw", "1", true, false,
	"Draw only native opaque face-direction ranges which can face the camera" )
local CONVAR_OCCLUSION_CULL = CreateClientConVar( "mc_native_occlusion_cull", "1", true, false,
	"Conservative native Section portal occlusion culling" )
local CONVAR_LOD = CreateClientConVar( "mc_native_lod", "0", true, false,
	"Native 2x2x2 far-distance opaque LOD" )
local CONVAR_LOD_START = CreateClientConVar( "mc_native_lod_start", "24", true, false,
	"Native LOD start distance in chunks" )

local PERF_SAMPLE_CAPACITY = 240

local function newPerfRing()
	return { values = {}, next = 1, count = 0 }
end

local function newNativePerf()
	return {
		startedAt = SysTime(),
		draw = { [0] = newPerfRing(), [1] = newPerfRing() },
		think = newPerfRing(),
	}
end

local function nextPerfSample( ring )
	local sample = ring.values[ring.next]
	if not sample then
		sample = {}
		ring.values[ring.next] = sample
	end
	ring.next = ring.next % PERF_SAMPLE_CAPACITY + 1
	ring.count = math.min( ring.count + 1, PERF_SAMPLE_CAPACITY )
	return sample
end

local function percentile( ring, field, fraction )
	local values = {}
	for _, sample in pairs( ring.values ) do
		local value = tonumber( sample[field] )
		if value then values[#values + 1] = value end
	end
	if #values == 0 then return nil end
	table.sort( values )
	return values[math.Clamp( math.ceil( #values * fraction ), 1, #values )]
end

local function newPackProfile()
	return {
		chunkCalls = 0,
		chunkFailures = 0,
		chunkBytes = 0,
		chunkTotalMS = 0,
		chunkLastMS = 0,
		chunkMaxMS = 0,
		defsCalls = 0,
		defsFailures = 0,
		defsCacheHits = 0,
		defsDiskHits = 0,
		defsBundledHits = 0,
		defsDiskWrites = 0,
		defsDiskFailures = 0,
		defsBytes = 0,
		defsTotalMS = 0,
		defsLastMS = 0,
		defsMaxMS = 0,
		nativeBatchCalls = 0,
		nativeBatchCells = 0,
		nativeSetCellCalls = 0,
		skippedChunkPacks = 0,
	}
end

local state = {
	active = false,
	moduleProbeDone = MC.NativeMeshModuleProbeDone == true,
	moduleUnavailable = MC.NativeMeshModuleProbeDone == true and MC.NativeMeshModuleAvailable == false,
	startupFailureReason = nil,
	failed = false,          -- 娓叉煋涓€旂疆浣? Think 閲岀粺涓€澶勭悊鍥為€€
	shuttingDown = false,
	shutdownCalled = false,
	originals = nil,         -- { BuildChunkMesh=, RebuildChunkMeshLighting=, FreeChunkMesh= }
	proxied = {},            -- key -> true (鎴戜滑鎺ョ鐨?chunk)
	pushedFrame = {},        -- key -> FrameNumber (chunk 鎺ㄩ€佸幓閲?
	defCache = nil,          -- immutable registry/catalog MCBD v5 blob for A/B toggles
	packProfile = newPackProfile(),
	epoch = 0,
	nativeMeshBackend = nil,
	lightPending = false,
	lightRunning = false,
	lightDue = 0,
	lightFirstPending = 0,
	lightReady = false,
	lightCache = {},
	skyCache = {},
	lightLastStatus = "idle",
	lightLastMS = 0,
	lightLastChangedChunks = 0,
	lightLastChangedCells = 0,
	lightScheduleCalls = 0,
	lightCoalesced = 0,
	incrementalLightCalls = 0,
	incrementalLightCells = 0,
	incrementalLightLastMS = 0,
	nativeDrawLast = {},
	nativeDrawMeta = {},
	nativePerf = newNativePerf(),
}

local function nativeLightingEnabled()
	local cv = MC.LightEnabled or ( GetConVar and GetConVar( "mc_light_enabled" ) )
	return not cv or not cv.GetBool or cv:GetBool() == true
end

local function applyNativeLightChanges( result )
	if not istable( result ) then return 0 end
	state.lightReady = state.lightReady or result.status == "incremental"
	state.lightCache = {}
	state.skyCache = {}
	state.lightLastStatus = tostring( result.status or "incremental" )
	state.lightLastMS = tonumber( result.ms ) or 0
	state.lightLastChangedChunks = tonumber( result.changedChunkCount ) or 0
	state.lightLastChangedCells = tonumber( result.changedCellCount ) or 0
	if result.status == "incremental" then
		state.incrementalLightCalls = state.incrementalLightCalls + 1
		state.incrementalLightCells = state.incrementalLightCells + state.lightLastChangedCells
		state.incrementalLightLastMS = state.lightLastMS
	end
	-- The current native ABI completes its atlas upload barrier before returning.
	return state.lightLastChangedCells
end

local function log( msg )
	print( "[mcswep-native] " .. tostring( msg ) )
end

local function refreshConfigVisibility()
	if MC.ConfigRefreshVisibility then MC.ConfigRefreshVisibility() end
end

local function lockToLuaBackend( reason )
	state.moduleProbeDone = true
	state.moduleUnavailable = true
	MC.NativeMeshModuleProbeDone = true
	MC.NativeMeshModuleAvailable = false
	MC.NativeMeshModuleFailureReason = reason or MC.NativeMeshModuleFailureReason or "native module unavailable"
	timer.Remove( "mcswep_native_bootstrap" )
	refreshConfigVisibility()
	return false
end

local function probeNativeModule()
	if state.moduleProbeDone then return not state.moduleUnavailable end

	state.moduleProbeDone = true
	local ok = MC.ProbeNativeMeshModule and MC.ProbeNativeMeshModule() or false
	if not ok or not mcmesh then
		return lockToLuaBackend( MC.NativeMeshModuleFailureReason or "module unavailable" )
	end

	state.moduleUnavailable = false
	refreshConfigVisibility()
	return true
end

-- Transitional formal backend surface used by the MC mother addon.  New
-- chunk loaders can feed sparse state pairs directly into the native mirror
-- without rebuilding a dense 32 KiB Lua string.  The epoch prevents a chunk
-- marker surviving a native ClearWorld/Shutdown cycle.
MC.NativeChunkBackend = MC.NativeChunkBackend or {}
MC.NativeChunkBackend.native = true
MC.NativeChunkBackend.incrementalLighting = true
function MC.NativeChunkBackend.IsActive()
	return state.active and not state.failed and mcmesh ~= nil
end
function MC.NativeChunkBackend.Epoch() return state.epoch end

function MC.NativeChunkBackend.GetLightAtlasSlot( key )
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.GetLightAtlasSlot ) then return 0, 0 end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return 0, 0 end
	local ok, slot, generation = pcall( mcmesh.GetLightAtlasSlot, cx, cy, cz )
	if not ok then state.failed = true; return 0, 0 end
	return tonumber( slot ) or 0, tonumber( generation ) or 0
end

function MC.NativeChunkBackend.GetLightAtlasStats()
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.GetLightAtlasStats ) then return nil end
	local ok, result = pcall( mcmesh.GetLightAtlasStats )
	if not ok then state.failed = true; return nil end
	return istable( result ) and result or nil
end

function MC.NativeChunkBackend.BindLightAtlasMaterials()
	if not mcmesh or not isfunction( mcmesh.BindLightAtlasMaterial ) then return false end
	local materials = MC.GetGpuChunkLightTextureMaterials and MC.GetGpuChunkLightTextureMaterials() or nil
	if not istable( materials ) or #materials == 0 then return false end
	for i = 1, #materials do
		local material = materials[i]
		local okName, name = pcall( material.GetName, material )
		if not okName or not isstring( name ) or name == "" then return false end
		local okBind, bound = pcall( mcmesh.BindLightAtlasMaterial, "!" .. name )
		if not okBind or bound ~= true then return false end
	end
	return true
end

local function nativePassMeta( pass )
	local cached = state.nativeDrawMeta[pass]
	local now = RealTime()
	if cached and now < ( cached.nextRefresh or 0 ) then return cached end
	local translucent = pass == 1
	local nativeMaterial = MC.NativeChunkMaterial or MC.CurrentChunkMaterial
	local material = nativeMaterial and nativeMaterial( translucent )
		or ( translucent and MC.MaterialTranslucent or MC.Material )
	local materialName = tostring( material or "unavailable" )
	if material and material.GetName then
		local ok, name = pcall( material.GetName, material )
		if ok and name then materialName = tostring( name ) end
	end
	local lightTexture = MC.IsGpuLightTextureMaterial and MC.IsGpuLightTextureMaterial( material ) == true
		or material == MC.MaterialGpuLightTexture
		or material == MC.MaterialGpuOpaque
	local meta = cached or {}
	meta.material = materialName
	meta.profile = tostring( MC.CurrentMeshLightStyle and MC.CurrentMeshLightStyle() or "unknown" )
	meta.lightTexture = lightTexture == true
	meta.nextRefresh = now + 1
	state.nativeDrawMeta[pass] = meta
	return meta
end

local function recordNativeDrawSample( pass, result )
	local meta = nativePassMeta( pass )
	local sample = nextPerfSample( state.nativePerf.draw[pass] )
	sample.frame = FrameNumber()
	sample.frameMS = FrameTime() * 1000
	sample.testedChunks = tonumber( result.tested ) or 0
	sample.visibleChunks = tonumber( result.visible ) or 0
	sample.drawnChunks = tonumber( result.drawn ) or 0
	sample.testedSections = tonumber( result.sectionsTested ) or 0
	sample.visibleSections = tonumber( result.sectionsVisible ) or 0
	sample.drawnSections = tonumber( result.sectionsDrawn ) or 0
	sample.meshes = tonumber( result.meshesDrawn ) or 0
	sample.verticesCandidate = tonumber( result.verticesCandidate ) or 0
	sample.vertices = tonumber( result.verticesDrawn ) or 0
	sample.verticesFullDetail = tonumber( result.verticesFullDetail ) or sample.verticesCandidate
	sample.verticesLodCulled = tonumber( result.verticesLodCulled ) or 0
	sample.verticesDirectionCulled = tonumber( result.verticesDirectionCulled ) or 0
	sample.lodSections = tonumber( result.lodSectionsDrawn ) or 0
	sample.lodMeshes = tonumber( result.lodMeshesDrawn ) or 0
	sample.lodStartChunks = tonumber( result.lodStartChunks ) or 0
	sample.occlusionTestedSections = tonumber( result.sectionsOcclusionTested ) or 0
	sample.occlusionCulledSections = tonumber( result.sectionsOcclusionCulled ) or 0
	sample.occlusionCulledChunks = tonumber( result.chunksOcclusionCulled ) or 0
	sample.occlusionComponentSections = tonumber( result.occlusionComponentSections ) or 0
	sample.occlusionReachableSections = tonumber( result.occlusionReachableSections ) or 0
	sample.triangles = tonumber( result.trianglesDrawn ) or 0
	sample.directionalDraw = result.directionalDraw == true
	sample.lod = result.lod == true
	sample.lodApplied = result.lodApplied == true
	sample.occlusionCull = result.occlusionCull == true
	sample.occlusionApplied = result.occlusionApplied == true
	sample.drawUs = tonumber( result.nativeUs ) or 0
	sample.cullUs = tonumber( result.cullUs ) or 0
	sample.material = meta.material
	sample.profile = meta.profile
	sample.lightTexture = meta.lightTexture
end

function MC.NativeChunkBackend.DrawVisible( pass, eye, forward, right, up, tanX, tanY,
	offsetX, offsetY, offsetZ, distance, frustum, horizontalDistance )
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.DrawVisible ) then return nil end
	local ok, result = pcall( mcmesh.DrawVisible,
		pass, eye.x, eye.y, eye.z,
		forward.x, forward.y, forward.z,
		right.x, right.y, right.z,
		up.x, up.y, up.z,
		tanX, tanY, offsetX, offsetY, offsetZ, distance,
		frustum == true, horizontalDistance == true, false )
	if not ok or not istable( result ) then state.failed = true; return nil end
	state.nativeDrawLast[pass] = result
	recordNativeDrawSample( pass, result )
	return result
end

function MC.NativeChunkBackend.SetChunkVisible( key, visible )
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.SetChunkVisible ) then return false end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return false end
	local ok, result = pcall( mcmesh.SetChunkVisible, cx, cy, cz, visible == true )
	return ok and result == true
end
function MC.NativeChunkBackend.CreateChunk( chunk )
	if not MC.NativeChunkBackend.IsActive() or not chunk or not isfunction( mcmesh.CreateChunk ) then return false end
	local ok, result = pcall( mcmesh.CreateChunk, chunk.cx, chunk.cy, chunk.cz )
	if not ok or result ~= true then state.failed = true; return false end
	chunk.nativeMeshEpoch = state.epoch
	chunk.nativeStateStorage = true
	if MC.AttachNativeChunkCompatibilityProxy then MC.AttachNativeChunkCompatibilityProxy( chunk ) end
	return true
end
function MC.NativeChunkBackend.ApplyChunkCells( chunk, cells, replace )
	local batchFn = mcmesh and ( mcmesh.SetCellsBatch or mcmesh.ApplyChunkCells )
	if not MC.NativeChunkBackend.IsActive() or not chunk or not isfunction( batchFn ) then return false end
	local ok, result = pcall( batchFn, chunk.cx, chunk.cy, chunk.cz, cells, replace ~= false )
	if not ok or result ~= true then state.failed = true; return false end
	state.packProfile.nativeBatchCalls = state.packProfile.nativeBatchCalls + 1
	state.packProfile.nativeBatchCells = state.packProfile.nativeBatchCells + math.floor( #cells / 2 )
	chunk.nativeMeshEpoch = state.epoch
	if ( MC.LightingBulkLoadDepth or 0 ) <= 0 then MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0.02 ) end
	return true
end
function MC.NativeChunkBackend.SupportsCompressedPatches()
	return MC.NativeChunkBackend.IsActive()
		and mcmesh and isfunction( mcmesh.StartCompressedPatchDecode )
		and isfunction( mcmesh.PollCompressedPatchDecode )
		and isfunction( mcmesh.CommitCompressedPatch )
		and isfunction( mcmesh.CancelCompressedPatchDecode )
end
function MC.NativeChunkBackend.StartCompressedPatchDecode( compressed, generation, revision, chunks, cells )
	if not MC.NativeChunkBackend.SupportsCompressedPatches() or not isstring( compressed ) then return nil end
	local ok, jobId = pcall( mcmesh.StartCompressedPatchDecode,
		compressed, generation, revision, state.epoch, chunks, cells )
	if not ok or not isnumber( jobId ) or jobId <= 0 then return nil end
	return jobId, state.epoch
end
function MC.NativeChunkBackend.PollCompressedPatchDecode( jobId )
	if not MC.NativeChunkBackend.SupportsCompressedPatches() then return nil end
	local ok, result = pcall( mcmesh.PollCompressedPatchDecode, jobId )
	if not ok or not istable( result ) then state.failed = true; return nil end
	return result
end
function MC.NativeChunkBackend.CommitCompressedPatch( jobId, palette, include )
	if not MC.NativeChunkBackend.SupportsCompressedPatches() then return nil end
	local ok, result = pcall( mcmesh.CommitCompressedPatch, jobId, palette, include )
	if not ok or not istable( result ) then state.failed = true; return nil end
	MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0.02 )
	return result
end
function MC.NativeChunkBackend.SupportsBinarySectionPatches()
	return MC.NativeChunkBackend.IsActive()
		and mcmesh and isfunction( mcmesh.StartBinarySectionPatchDecode )
		and isfunction( mcmesh.PollBinarySectionPatchDecode )
		and isfunction( mcmesh.CommitBinarySectionPatch )
		and isfunction( mcmesh.CancelCompressedPatchDecode )
end
function MC.NativeChunkBackend.StartBinarySectionPatchDecode( payload, compression, rawBytes, generation, revision, chunks, cells )
	if not MC.NativeChunkBackend.SupportsBinarySectionPatches() or not isstring( payload ) then return nil end
	local ok, jobId = pcall( mcmesh.StartBinarySectionPatchDecode,
		payload, compression, rawBytes, generation, revision, state.epoch, chunks, cells )
	if not ok or not isnumber( jobId ) or jobId <= 0 then return nil end
	return jobId, state.epoch
end
function MC.NativeChunkBackend.PollBinarySectionPatchDecode( jobId )
	if not MC.NativeChunkBackend.SupportsBinarySectionPatches() then return nil end
	local ok, result = pcall( mcmesh.PollBinarySectionPatchDecode, jobId )
	if not ok or not istable( result ) then state.failed = true; return nil end
	return result
end
function MC.NativeChunkBackend.CommitBinarySectionPatch( jobId, include )
	if not MC.NativeChunkBackend.SupportsBinarySectionPatches() then return nil end
	local ok, result = pcall( mcmesh.CommitBinarySectionPatch, jobId, include )
	if not ok or not istable( result ) then state.failed = true; return nil end
	MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0.02 )
	return result
end
function MC.NativeChunkBackend.CancelCompressedPatchDecode( jobId )
	if not mcmesh or not isfunction( mcmesh.CancelCompressedPatchDecode ) then return false end
	local ok, result = pcall( mcmesh.CancelCompressedPatchDecode, jobId )
	return ok and result == true
end
function MC.NativeChunkBackend.CancelAllCompressedPatchDecodes()
	if not mcmesh or not isfunction( mcmesh.CancelAllCompressedPatchDecodes ) then return false end
	local ok, result = pcall( mcmesh.CancelAllCompressedPatchDecodes, state.epoch )
	return ok and result == true
end
function MC.NativeChunkBackend.ClearWorld()
	if not MC.NativeChunkBackend.IsActive() or not mcmesh or not isfunction( mcmesh.ClearWorld ) then return false end
	MC.NativeChunkBackend.CancelAllCompressedPatchDecodes()
	if isfunction( mcmesh.CancelBlockLightRebuild ) then pcall( mcmesh.CancelBlockLightRebuild ) end
	local ok = pcall( mcmesh.ClearWorld )
	if not ok then state.failed = true return false end
	for key in pairs( state.proxied ) do
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
	end
	state.proxied = {}
	state.pushedFrame = {}
	state.lightPending, state.lightRunning, state.lightReady = false, false, false
	state.lightCache, state.skyCache, state.lightDue, state.lightFirstPending = {}, {}, 0, 0
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
	return true
end
function MC.NativeChunkBackend.SetCell( chunk, li, stateId )
	if not MC.NativeChunkBackend.IsActive() or not chunk or not isfunction( mcmesh.SetCell ) then return false end
	local ok, result, lightResult = pcall( mcmesh.SetCell, chunk.cx, chunk.cy, chunk.cz, li, stateId )
	if not ok or result ~= true then state.failed = true; return false end
	state.packProfile.nativeSetCellCalls = state.packProfile.nativeSetCellCalls + 1
	chunk.nativeMeshEpoch = state.epoch
	applyNativeLightChanges( lightResult )
	return true
end
function MC.NativeChunkBackend.GetCell( chunk, li )
	if not MC.NativeChunkBackend.IsActive() or not chunk or not isfunction( mcmesh.GetCell ) then return nil end
	local ok, result = pcall( mcmesh.GetCell, chunk.cx, chunk.cy, chunk.cz, li )
	if not ok then state.failed = true; return nil end
	return tonumber( result )
end
function MC.NativeChunkBackend.GetChunkCells( chunk )
	if not MC.NativeChunkBackend.IsActive() or not chunk or not isfunction( mcmesh.GetChunkCells ) then return nil end
	local ok, result = pcall( mcmesh.GetChunkCells, chunk.cx, chunk.cy, chunk.cz )
	if not ok then state.failed = true; return nil end
	return istable( result ) and result or nil
end
function MC.NativeChunkBackend.MaterializeLuaStorage( chunk )
	if not chunk or not mcmesh or not isfunction( mcmesh.GetChunkCells ) then return nil, "native_cells_unavailable" end
	local ok, cells = pcall( mcmesh.GetChunkCells, chunk.cx, chunk.cy, chunk.cz )
	if not ok or not istable( cells ) then return nil, "native_cells_read_failed" end
	local sections, blocks, orients = {}, {}, {}
	for i = 1, #cells, 2 do
		local li, stateId = cells[i], cells[i + 1]
		local sectionIndex = math.floor( li / ( ( MC.CS or 16 ) * ( MC.CS or 16 ) * 16 ) ) + 1
		local sectionLocalIndex = li % ( ( MC.CS or 16 ) * ( MC.CS or 16 ) * 16 )
		local section = sections[sectionIndex]
		if not section then section = MC.StateSection.New(); sections[sectionIndex] = section end
		local changed, err = MC.StateSection.Set( section, sectionLocalIndex, stateId )
		if changed == nil then return nil, err or "native_state_materialization_failed" end
		local id, orient = MC.LegacyFromState( stateId )
		if id then blocks[li], orients[li] = id, orient or 0 end
	end
	chunk.stateSections = sections
	chunk.blocks = blocks
	chunk.orients = orients
	chunk.stateStorageMigrated = true
	chunk.nativeStateStorage = false
	chunk.chunkBackend = "lua"
	return true
end
function MC.NativeChunkBackend.RebuildBlockLight()
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.RebuildBlockLight ) then return false end
	local ok, result = pcall( mcmesh.RebuildBlockLight )
	return ok and result or false
end
function MC.NativeChunkBackend.StartBlockLightRebuild()
	if not nativeLightingEnabled() then
		MC.NativeChunkBackend.CancelBlockLightRebuild( "disabled" )
		return false
	end
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.StartBlockLightRebuild ) then return false end
	local ok, result = pcall( mcmesh.StartBlockLightRebuild )
	return ok and result == true
end
function MC.NativeChunkBackend.PollBlockLightRebuild()
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.PollBlockLightRebuild ) then return false end
	local ok, result = pcall( mcmesh.PollBlockLightRebuild )
	return ok and result or false
end
function MC.NativeChunkBackend.CancelBlockLightRebuild( reason )
	local ok, result = false, false
	if mcmesh and isfunction( mcmesh.CancelBlockLightRebuild ) then
		ok, result = pcall( mcmesh.CancelBlockLightRebuild )
	end
	state.lightPending = false
	state.lightRunning = false
	state.lightDue = 0
	state.lightFirstPending = 0
	state.lightReady = false
	state.lightCache = {}
	state.skyCache = {}
	state.lightLastStatus = tostring( reason or "cancelled" )
	return ok and result == true
end
function MC.NativeChunkBackend.GetBlockLightChunk( cx, cy, cz )
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.GetBlockLightChunk ) then return nil end
	local ok, result = pcall( mcmesh.GetBlockLightChunk, cx, cy, cz )
	return ok and result or nil
end
function MC.NativeChunkBackend.GetSkyLightChunk( cx, cy, cz )
	if not MC.NativeChunkBackend.IsActive() or not isfunction( mcmesh.GetSkyLightChunk ) then return nil end
	local ok, result = pcall( mcmesh.GetSkyLightChunk, cx, cy, cz )
	return ok and result or nil
end
function MC.NativeChunkBackend.ScheduleBlockLightRebuild( delay )
	if not MC.NativeChunkBackend.IsActive() then return false end
	if not nativeLightingEnabled() then
		if state.lightPending or state.lightRunning or state.lightReady or state.lightLastStatus ~= "disabled" then
			MC.NativeChunkBackend.CancelBlockLightRebuild( "disabled" )
		end
		return false
	end
	local now = CurTime()
	state.lightScheduleCalls = state.lightScheduleCalls + 1
	if state.lightPending or state.lightRunning then state.lightCoalesced = state.lightCoalesced + 1 end
	if not state.lightPending then state.lightFirstPending = now end
	state.lightPending = true
	-- Keep the last committed light field live while a full snapshot rebuild is
	-- pending. Initial world hydration starts with lightReady=false naturally;
	-- later structural rebuilds no longer flash back to empty Lua caches.
	local wanted = now + math.max( 0, tonumber( delay ) or 0 )
	local deadline = ( state.lightFirstPending or now ) + 0.25
	state.lightDue = math.min( deadline, math.max( state.lightDue or 0, wanted ) )
	return true
end
function MC.NativeChunkBackend.GetSkyLightAt( bx, by, bz )
	if not state.lightReady then return nil end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local key = MC.ChunkKey( cx, cy, cz )
	local blob = state.skyCache[key]
	if blob == nil then
		blob = MC.NativeChunkBackend.GetSkyLightChunk( cx, cy, cz ) or false
		state.skyCache[key] = blob
	end
	if blob == false then
		return MC.SkyExposedAt and MC.SkyExposedAt( bx, by, bz ) and 15 or 0
	end
	return string.byte( blob, li + 1 ) or 0
end
function MC.NativeChunkBackend.GetBlockLightAt( bx, by, bz )
	if not state.lightReady then return nil end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0 end
	local key = MC.ChunkKey( cx, cy, cz )
	local blob = state.lightCache[key]
	if blob == nil then
		blob = MC.NativeChunkBackend.GetBlockLightChunk( cx, cy, cz ) or false
		state.lightCache[key] = blob
	end
	if blob == false then return 0 end
	return string.byte( blob, li + 1 ) or 0
end
function MC.NativeChunkBackend.IsLightReady()
	return MC.NativeChunkBackend.IsActive() and state.lightReady == true
end
function MC.NativeChunkBackend.GetLightingAt( bx, by, bz )
	if not MC.NativeChunkBackend.IsLightReady() then return nil end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return 0, 0 end
	local key = MC.ChunkKey( cx, cy, cz )
	local blockBlob = state.lightCache[key]
	if blockBlob == nil then blockBlob = MC.NativeChunkBackend.GetBlockLightChunk( cx, cy, cz ) or false; state.lightCache[key] = blockBlob end
	local skyBlob = state.skyCache[key]
	if skyBlob == nil then skyBlob = MC.NativeChunkBackend.GetSkyLightChunk( cx, cy, cz ) or false; state.skyCache[key] = skyBlob end
	local sky = skyBlob ~= false and ( string.byte( skyBlob, li + 1 ) or 0 )
		or ( MC.SkyExposedAt and MC.SkyExposedAt( bx, by, bz ) and 15 or 0 )
	return blockBlob ~= false and ( string.byte( blockBlob, li + 1 ) or 0 ) or 0, sky
end
if MC.RegisterChunkBackend then MC.RegisterChunkBackend( "native", MC.NativeChunkBackend ) end

local function packProfileLines()
	local p = state.packProfile
	local chunkAverageMS = p.chunkCalls > 0 and p.chunkTotalMS / p.chunkCalls or 0
	local defsAverageMS = p.defsCalls > 0 and p.defsTotalMS / p.defsCalls or 0
	local chunkMiBPerSecond = p.chunkTotalMS > 0
		and ( p.chunkBytes / 1048576 ) / ( p.chunkTotalMS / 1000 ) or 0
	return {
		string.format( "pack.chunk calls=%d failures=%d bytes=%d", p.chunkCalls, p.chunkFailures, p.chunkBytes ),
		string.format( "pack.chunk ms last=%.3f avg=%.3f max=%.3f total=%.3f throughput=%.2fMiB/s",
			p.chunkLastMS, chunkAverageMS, p.chunkMaxMS, p.chunkTotalMS, chunkMiBPerSecond ),
		string.format( "pack.defs builds=%d failures=%d cacheHits=%d bytes=%d",
			p.defsCalls, p.defsFailures, p.defsCacheHits, p.defsBytes ),
		string.format( "pack.defs bundledHits=%d diskHits=%d writes=%d failures=%d",
			p.defsBundledHits, p.defsDiskHits, p.defsDiskWrites, p.defsDiskFailures ),
		string.format( "pack.defs ms last=%.3f avg=%.3f max=%.3f total=%.3f",
			p.defsLastMS, defsAverageMS, p.defsMaxMS, p.defsTotalMS ),
		string.format( "native.chunk batches=%d cells=%d setCells=%d skippedPacks=%d",
			p.nativeBatchCalls, p.nativeBatchCells, p.nativeSetCellCalls, p.skippedChunkPacks ),
	}
end

local DEFS_DISK_MAGIC = "MCNDC1"
local function packU32( value )
	value = math.floor( tonumber( value ) or 0 )
	return string.char( bit.band( value, 255 ), bit.band( bit.rshift( value, 8 ), 255 ),
		bit.band( bit.rshift( value, 16 ), 255 ), bit.band( bit.rshift( value, 24 ), 255 ) )
end
local function unpackU32( data, offset )
	local a, b, c, d = string.byte( data, offset, offset + 3 )
	if not d then return nil end
	return a + b * 256 + c * 65536 + d * 16777216
end
local function defsDiskPath( cacheKey )
	local crc = util and util.CRC and util.CRC( cacheKey ) or tostring( #cacheKey )
	return "mcswep_native/defs_" .. tostring( crc ) .. ".dat"
end
local function defsBundledPath( cacheKey )
	local crc = util and util.CRC and util.CRC( cacheKey ) or tostring( #cacheKey )
	-- Workshop's GMAD whitelist rejects arbitrary .dat files under lua/.
	-- This is still opaque binary data read through file.Read; the .lua suffix
	-- only gives the bundled cache a packageable path and it is never included.
	return "lua/mc/generated/native_defs_" .. tostring( crc ) .. ".lua"
end
local function parseDefsCacheData( cacheKey, data )
	if not isstring( data ) or string.sub( data, 1, #DEFS_DISK_MAGIC ) ~= DEFS_DISK_MAGIC then return nil end
	local offset = #DEFS_DISK_MAGIC + 1
	local keyLen = unpackU32( data, offset ); if not keyLen then return nil end; offset = offset + 4
	if keyLen < 1 or keyLen > 4096 or offset + keyLen - 1 > #data then return nil end
	if string.sub( data, offset, offset + keyLen - 1 ) ~= cacheKey then return nil end; offset = offset + keyLen
	local blobLen = unpackU32( data, offset ); if not blobLen then return nil end; offset = offset + 4
	if blobLen < 1 or offset + blobLen - 1 > #data then return nil end
	local blob = string.sub( data, offset, offset + blobLen - 1 ); offset = offset + blobLen
	local lightBlob = string.sub( data, offset )
	local expectedLight = math.max( 1, math.floor( tonumber( MC.BlockStateCount ) or 1 ) ) * 2
	if #lightBlob ~= expectedLight then return nil end
	return blob, lightBlob
end
local function readDefsBundledCache( cacheKey )
	if not file or not file.Read then return nil end
	return parseDefsCacheData( cacheKey, file.Read( defsBundledPath( cacheKey ), "GAME" ) )
end
local function readDefsDiskCache( cacheKey )
	if not file or not file.Read then return nil end
	return parseDefsCacheData( cacheKey, file.Read( defsDiskPath( cacheKey ), "DATA" ) )
end
local function writeDefsDiskCache( cacheKey, blob, lightBlob )
	if not file or not file.Write or not isstring( blob ) or not isstring( lightBlob ) then return false end
	local data = DEFS_DISK_MAGIC .. packU32( #cacheKey ) .. cacheKey .. packU32( #blob ) .. blob .. lightBlob
	local ok = pcall( function()
		if file.CreateDir then file.CreateDir( "mcswep_native" ) end
		file.Write( defsDiskPath( cacheKey ), data )
	end )
	if not ok or not file.Read then return false end
	local verify = file.Read( defsDiskPath( cacheKey ), "DATA" )
	return isstring( verify ) and #verify == #data and verify == data
end
local function deleteDefsDiskCache( cacheKey )
	if file and file.Delete then pcall( file.Delete, defsDiskPath( cacheKey ) ) end
end

-- native 椤剁偣鎼哄甫鍥哄畾 GPU payload(R=255/G=faceIndex/B=0/A=255), 鍙 GPU light
-- texture 鍏夌収妗ｆ瀹夊叏銆傛。妗堢殑閲囨牱鍧愭爣鐢卞儚绱?shader 浠?worldPos 鍙嶆帹, 椤剁偣涓嶅甫
-- 鍏夌収 UV 鈥斺€?鍏跺畠鍏夌収椋庢牸(vanilla/fancy 椤剁偣鐑樼剻)浼氬洜姝ら敊鍏夈€傛闂ㄦ鎷︿綇瀹冧滑銆?
local function gpuLightProfileActive()
	local resolver = MC.NativeChunkMaterial
	if not resolver then return false end
	local okOpaque, opaque = pcall( resolver, false )
	local okTranslucent, translucent = pcall( resolver, true )
	return okOpaque and okTranslucent
		and opaque ~= nil and translucent ~= nil
		and ( not opaque.IsError or not opaque:IsError() )
		and ( not translucent.IsError or not translucent:IsError() )
end

local function nativeGreedyMaterialCompatible()
	local resolver = MC.NativeChunkMaterial or MC.CurrentChunkMaterial
	if not resolver then return false end
	local ok, material = pcall( resolver, false )
	if not ok or not material then return false end
	if material == MC.MaterialGpuOpaque or material == MC.MaterialNativeSlotOpaque then return true end
	return MC.IsGpuLightTextureMaterial
		and MC.IsGpuLightTextureMaterial( material ) == true
end

local function effectiveNativeGreedy()
	return CONVAR_GREEDY:GetBool() and nativeGreedyMaterialCompatible()
end

----------------------------------------------------------------- blockdefs 鎵撳寘
-- MCBD v5 adds independent atlas pages while preserving typed emitters,
-- the complete stateId map and the generated visual catalog.
local string_char = string.char
local bit_band, bit_rshift = bit.band, bit.rshift
local HUGE = math.huge

local function finite( n ) return type( n ) == "number" and n == n and n ~= HUGE and n ~= -HUGE end
local function checkedNumber( value, lo, hi, label )
	local n = tonumber( value )
	if not finite( n ) or n < lo or n > hi then error( label .. " out of range", 0 ) end
	return n
end
local function checkedInt( value, lo, hi, label )
	local n = checkedNumber( value, lo, hi, label )
	if n ~= math.floor( n ) then error( label .. " is not integral", 0 ) end
	return n
end
local function u8( n )
	n = checkedInt( n, 0, 255, "u8" )
	return string_char( n )
end
local function u16le( n )
	n = checkedInt( n, 0, 65535, "u16" )
	return string_char( bit_band( n, 0xFF ), bit_band( bit_rshift( n, 8 ), 0xFF ) )
end
local function u32le( n )
	n = checkedInt( n, 0, 4294967295, "u32" )
	return string_char( bit_band( n, 0xFF ), bit_band( bit_rshift( n, 8 ), 0xFF ),
		bit_band( bit_rshift( n, 16 ), 0xFF ), bit_band( bit_rshift( n, 24 ), 0xFF ) )
end

-- IEEE-754 binary32 LE; reject values which would become NaN/Inf/subnormal.
local function f32le( value )
	local x = checkedNumber( value, -16777216, 16777216, "f32" )
	if x == 0 then return string_char( 0, 0, 0, x < 0 and 128 or 0 ) end
	local sign = 0
	if x < 0 then sign = 0x80; x = -x end
	local mant, expo = math.frexp( x )
	expo = expo - 1
	local e = expo + 127
	if e <= 0 or e >= 255 then error( "f32 exponent out of range", 0 ) end
	local m = math.floor( ( mant * 2 - 1 ) * 2 ^ 23 + 0.5 )
	if m >= 2 ^ 23 then m = 0; e = e + 1 end
	if e >= 255 then error( "f32 overflow", 0 ) end
	return string_char( bit_band( m, 0xFF ), bit_band( bit_rshift( m, 8 ), 0xFF ),
		bit_band( bit_rshift( m, 16 ), 0x7F ) + bit_band( e * 128, 0x80 ), sign + math.floor( e / 2 ) )
end

local EMITTER = { fullCube = 1, cross = 2, model = 3, shape = 4, connection = 5, liquid = 6 }
local LIQUID = { water = 1, lava = 2 }
local CONNECTION = { fence = 1, pane = 2, bars = 3, wall = 4, pipe6 = 5 }
local FACE_TOP, FACE_BOTTOM, FACE_XP, FACE_XN, FACE_YP, FACE_YN = 1, 2, 3, 4, 5, 6
local TRI = { 1, 3, 2, 1, 4, 3 }
local MAX_BLOCKS, MAX_ORIENTS = 65535, 64
local MAX_BOXES, MAX_QUADS, MAX_TEMPLATES = 1000000, 4000000, 1000000
local MAX_BLOB_BYTES = 512 * 1024 * 1024

local function resolveAtlasSurface( tile, label )
	local page, physical
	if MC.ResolveAtlasSurface then
		page, physical = MC.ResolveAtlasSurface( tile )
	else
		page, physical = 0, MC.ResolveAtlasTile and MC.ResolveAtlasTile( tile ) or tile
	end
	return checkedInt( page or 0, 0, 63, ( label or "tile" ) .. " page" ),
		checkedInt( physical or 0, 0, 65535, label or "tile" )
end

local function orientsForBlock( b )
	local rule = b.orient and MC.OrientRules and MC.OrientRules[b.orient]
	if not rule or not rule.allowed then return { 0 } end
	local def = checkedInt( ( MC.DefaultOrient and MC.DefaultOrient( b.id ) ) or rule.default or 0, 0, 255, "default orient" )
	local rest, seen = {}, { [def] = true }
	for raw in pairs( rule.allowed ) do
		local o = checkedInt( raw, 0, 255, "orient" )
		if not seen[o] then rest[#rest + 1] = o; seen[o] = true end
	end
	table.sort( rest )
	if #rest + 1 > MAX_ORIENTS then error( "too many orients for block " .. b.id, 0 ) end
	local list = { def }
	for i = 1, #rest do list[#list + 1] = rest[i] end
	return list
end

local function connectionKind( b, id )
	if not b then return nil end
	if CONNECTION[b.connection] then return b.connection end
	if MC.IsFenceBlock and MC.IsFenceBlock( id ) then return "fence" end
	if MC.IsPaneBlock and MC.IsPaneBlock( id ) then return b.connection == "bars" and "bars" or "pane" end
	if MC.IsWallBlock and MC.IsWallBlock( id ) then return "wall" end
end

local function modelUsesConnection( b, id ) return connectionKind( b, id ) ~= nil end

local function capabilitiesFor( b, id, orient )
	local generic = b and ( b.connection == "fence" or b.connection == "fence_gate"
		or b.connection == "wall" or b.connection == "pane" or b.connection == "bars" )
	if not generic and b and b.solid ~= false then
		generic = MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) or not b.shape
	end
	local caps = generic and 0x07 or 0
	if b and ( b.connection == "pipe6" or b.name == "chorus_flower" ) then caps = caps + 0x08 end
	if b and b.name == "end_stone" then caps = caps + 0x10 end
	return caps
end

local function faceCorners( box, face )
	local x0, y0, z0, x1, y1, z1 = unpack( box, 1, 6 )
	if face == FACE_TOP then return { {x0,y0,z1},{x1,y0,z1},{x1,y1,z1},{x0,y1,z1} } end
	if face == FACE_BOTTOM then return { {x0,y1,z0},{x1,y1,z0},{x1,y0,z0},{x0,y0,z0} } end
	if face == FACE_XP then return { {x1,y0,z0},{x1,y1,z0},{x1,y1,z1},{x1,y0,z1} } end
	if face == FACE_XN then return { {x0,y1,z0},{x0,y0,z0},{x0,y0,z1},{x0,y1,z1} } end
	if face == FACE_YP then return { {x1,y1,z0},{x0,y1,z0},{x0,y1,z1},{x1,y1,z1} } end
	return { {x0,y0,z0},{x1,y0,z0},{x1,y0,z1},{x0,y0,z1} }
end
local function projectedUV( face, x, y, z )
	if face == FACE_TOP then return x * 16, ( 1 - y ) * 16 end
	if face == FACE_BOTTOM then return x * 16, y * 16 end
	if face == FACE_XP then return y * 16, ( 1 - z ) * 16 end
	if face == FACE_XN then return ( 1 - y ) * 16, ( 1 - z ) * 16 end
	if face == FACE_YP then return ( 1 - x ) * 16, ( 1 - z ) * 16 end
	return x * 16, ( 1 - z ) * 16
end
local function rotateFlags( u, v, rot, flipU, flipV )
	rot = math.floor( tonumber( rot ) or 0 ) % 4
	if rot == 1 then u, v = v, 1 - u elseif rot == 2 then u, v = 1 - u, 1 - v elseif rot == 3 then u, v = 1 - v, u end
	if flipU then u = 1 - u end
	if flipV then v = 1 - v end
	return u, v
end

-- Quad88: face:u8 flags:u8 boxIndex:u16 tile:u16 page:u8 reserved:u8,
-- then four {x,y,z,u,v}:f32. Quad positions are bounded block-local extension
-- coordinates [-16,16] (models legitimately extend outside the unit cube); UVs 0..16.
local function packQuad( face, flags, boxIndex, tile, verts, context )
	face, flags = checkedInt( face, 1, 6, "quad face" ), checkedInt( flags or 0, 0, 1, "quad flags" )
	boxIndex = checkedInt( boxIndex or 65535, 0, 65535, "box index" )
	local page, physical = resolveAtlasSurface( tile, "tile" )
	if type( verts ) ~= "table" or #verts ~= 4 then error( ( context or "quad" ) .. " needs four vertices", 0 ) end
	local p = { u8( face ), u8( flags ), u16le( boxIndex ), u16le( physical ), u8( page ), u8( 0 ) }
	for i = 1, 4 do
		local v = verts[i]
		local label = ( context or "quad" ) .. " vertex " .. i
		p[#p+1] = f32le( checkedNumber( v[1], -16, 16, label .. " x" ) )
		p[#p+1] = f32le( checkedNumber( v[2], -16, 16, label .. " y" ) )
		p[#p+1] = f32le( checkedNumber( v[3], -16, 16, label .. " z" ) )
		p[#p+1] = f32le( checkedNumber( v[4], 0, 16, label .. " u" ) )
		p[#p+1] = f32le( checkedNumber( v[5], 0, 16, label .. " v" ) )
	end
	return table.concat( p )
end
local function packBox( box )
	if type( box ) ~= "table" then error( "invalid box", 0 ) end
	local p = {}
	for i = 1, 6 do p[i] = f32le( checkedNumber( box[i], 0, 1, "box coordinate" ) ) end
	if box[1] > box[4] or box[2] > box[5] or box[3] > box[6] then error( "inverted box", 0 ) end
	return table.concat( p )
end

-- FaceTex36: tile:u16 page:u8 flags:u8 + four tile-local {u,v}:f32.
local function packFaceTex( tile, uvs, flags )
	local page, physical = resolveAtlasSurface( tile, "tile" )
	local p = { u16le( physical ), u8( page ), u8( flags or 0 ) }
	for i = 1, 4 do
		p[#p+1] = f32le( checkedNumber( uvs[i][1], 0, 16, "face u" ) )
		p[#p+1] = f32le( checkedNumber( uvs[i][2], 0, 16, "face v" ) )
	end
	return table.concat( p )
end
local FACE_UV_FLAGS = { {0,16},{16,16},{16,0},{0,0} }
local function blockModelSurfaceTile( b, data, fallback )
	if data and MC.BlockModelSurface then return MC.BlockModelSurface( b, data ) end
	if data and data.tile ~= nil then return data.tile end
	return fallback or 0
end
local function resolveFaceTex( b, id, orient, face )
	local baked = b.baked and ( b.baked[orient] or b.baked[MC.DefaultOrient( id )] or b.baked[0] )
	baked = baked and baked[face]
	local tile, rot, fu, fv, rect, raw
	if baked then tile, rot, rect, raw = blockModelSurfaceTile( b, baked ), baked.rot or 0, baked.uv, baked.uvs
	else tile, rot, fu, fv = MC.BlockFace( id, face, orient ) end
	local out = {}
	if raw then
		for i = 1, 4 do out[i] = { raw[i][1], raw[i][2] } end
	else
		local u0, v0, u1, v1 = 0, 0, 16, 16
		if rect then u0,v0,u1,v1 = rect[1] or 0,rect[2] or 0,rect[3] or 16,rect[4] or 16 end
		for i = 1, 4 do
			local uf, vf = rotateFlags( FACE_UV_FLAGS[i][1] / 16, FACE_UV_FLAGS[i][2] / 16, rot, fu, fv )
			out[i] = { uf == 1 and u1 or u0, vf == 1 and v1 or v0 }
		end
	end
	return checkedInt( tile or 0, 0, 65535, "face tile" ), out
end

local function shapeQuad( b, id, orient, box, boxIndex, face, fd, explicitUV, flags )
	local tile = fd and blockModelSurfaceTile( b, fd ) or MC.BlockFace( id, face, orient )
	local corners, verts = faceCorners( box, face ), {}
	local rect = explicitUV or ( fd and fd.uv )
	for i = 1, 4 do
		local x,y,z = corners[i][1],corners[i][2],corners[i][3]
		local u,v
		if rect then
			local uf,vf = rotateFlags( FACE_UV_FLAGS[i][1]/16, FACE_UV_FLAGS[i][2]/16, explicitUV and 0 or fd.rot )
			u = uf == 1 and (rect[3] or 16) or (rect[1] or 0); v = vf == 1 and (rect[4] or 16) or (rect[2] or 0)
		else u,v = projectedUV( face, x,y,z ) end
		verts[i] = {x,y,z,u,v}
	end
	return packQuad( face, flags or 0, boxIndex, tile, verts,
		"block " .. tostring( id ) .. " " .. tostring( b and b.name or "?" )
		.. " orient " .. tostring( orient ) .. " shape box " .. tostring( boxIndex ) .. " face " .. tostring( face ) )
end

local function modelQuads( b, orient )
	local RM = MC.RenderMesh
	local quads = RM and RM.rotatedModelQuads and RM.rotatedModelQuads( b, orient )
	if not quads then return nil end
	local out = {}
	for qi, q in ipairs( quads ) do
		if q.verts and q.verts[1] and q.verts[2] and q.verts[3] and q.verts[4] then
			-- Compact/generated block models address their texture through a local
			-- surface slot.  Reading q.tile directly turns every such model into
			-- atlas tile zero (dirt) when the native backend uses the legacy model
			-- emitter.  Keep the packed definition identical to Lua's model path.
			local tile = blockModelSurfaceTile( b, q )
			local rect = q.uv or {0,0,16,16}; local verts = {}
			for i = 1, 4 do
				local x, y, z, rawU, rawV = MC.ModelQuadVertex( q, i )
				if not finite( x ) or not finite( y ) or not finite( z ) or not finite( rawU ) or not finite( rawV ) then
					error( "invalid model quad vertex", 0 )
				end
				local uf,vf = rotateFlags( rawU, rawV, q.rot or 0 )
				if b.orient == "door" then uf = 1 - uf end
				verts[i] = {x,y,z,uf == 1 and rect[3] or rect[1],vf == 1 and rect[4] or rect[2]}
			end
			out[#out+1] = packQuad( q.face or FACE_TOP, 0, 65535, tile, verts,
				"block " .. tostring( b.id ) .. " " .. tostring( b.name or "?")
				.. " orient " .. tostring( orient ) .. " model quad " .. tostring( qi ) )
		end
	end
	return out
end

local function connectionFaceValues( b, face, box, orient )
	local RM = MC.RenderMesh
	if RM and RM.connectionShapeFaceValues then
		local tile, uv, ok = RM.connectionShapeFaceValues( b, face, box )
		if ok then return tile, uv end
	end
	return MC.BlockFace( b.id, face, orient ), nil
end
local function boundaryBit( box, face )
	local e = 0.0001
	if face == FACE_TOP and math.abs(box[6]-1)<=e then return 32 end
	if face == FACE_BOTTOM and math.abs(box[3])<=e then return 16 end
	if face == FACE_XP and math.abs(box[4]-1)<=e then return 8 end
	if face == FACE_XN and math.abs(box[1])<=e then return 4 end
	if face == FACE_YP and math.abs(box[5]-1)<=e then return 2 end
	if face == FACE_YN and math.abs(box[2])<=e then return 1 end
	return 0
end

local function buildConnectionTemplates( b, id, orient, kind )
	local RM, out = MC.RenderMesh, {}
	local maxMask = kind == "pipe6" and 63 or 15
	for mask = 0, maxMask do
		local boxKind = kind == "bars" and "pane" or kind
		local boxes = MC.ConnectionBlockBoxes( boxKind, mask )
		if not boxes then error( "missing connection boxes", 0 ) end
		local bp, qp = {}, {}
		for i, box in ipairs( boxes ) do bp[i] = packBox( box ) end
		for bi, box in ipairs( boxes ) do
			for face = 1, 6 do
				local bitv = boundaryBit( box, face )
				local connected = bitv ~= 0 and bit_band( mask, bitv ) ~= 0
				local selfCovered = RM and RM.coveredByBoxes and #boxes > 1 and RM.coveredByBoxes( box, face, boxes, 0,0,0 )
				if not connected and not selfCovered then
					local tile, uv = connectionFaceValues( b, face, box, orient )
					local raw = shapeQuad( b, id, orient, box, bi - 1, face, {tile=tile}, uv )
					-- bit0 asks worker to run neighbor coverage (only vertical connection faces).
					if bitv == 16 or bitv == 32 then raw = raw:sub(1,1) .. u8(1) .. raw:sub(3) end
					qp[#qp+1] = raw
				end
			end
		end
		out[#out+1] = u8(mask)..u8(0)..u16le(#boxes)..u32le(#qp)..table.concat(bp)..table.concat(qp)
	end
	return out
end

local function staticShapePayload( b, id, orient )
	local boxes = MC.BlockBoxes( id, orient )
	if not boxes then return nil end
	local bp, qp = {}, {}
	for i, box in ipairs( boxes ) do bp[i] = packBox( box ) end
	for bi, box in ipairs( boxes ) do
		local faces = b.boxFaces and b.boxFaces[bi]
		for face = 1, 6 do
			local fd = faces and faces[face]
			if not b.boxFaces or fd then
				local flags = boundaryBit( box, face ) ~= 0 and 1 or 0
				qp[#qp+1] = shapeQuad( b,id,orient,box,bi-1,face,fd,nil,flags )
			end
		end
	end
	return bp, qp
end

local function hexHashBytes( value, label )
	value = tostring( value or "" )
	if #value ~= 64 or value:find( "[^0-9a-fA-F]" ) then error( label .. " must be 64 hex characters", 0 ) end
	local out = {}
	for i = 1, 64, 2 do out[#out + 1] = string_char( tonumber( value:sub( i, i + 1 ), 16 ) ) end
	return table.concat( out )
end

local function stateMapPayload()
	if not MC.BlockStateRegistryFrozen then error( "block state registry is not frozen", 0 ) end
	local count = checkedInt( MC.BlockStateCount or 0, 1, 1048576, "state count" )
	local parts = {}
	for stateId = 0, count - 1 do
		local blockId, orient, stairPlans = 0, 0, {0,0,0,0,0}
		local stateLiquidKind, stateLiquidAmount = 0, 0
		if stateId ~= 0 then
			local legacyBlockId, legacyOrient, exact, projectionError = MC.LegacyFromState( stateId )
			if not legacyBlockId then error( "state " .. stateId .. " projection failed: " .. tostring( projectionError ), 0 ) end
			local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId ) or nil
			-- Legacy projection is still useful for the compatibility/exactness flag,
			-- but it must not choose native render geometry. Compound states such as
			-- facing=south,lit=false used to project to the default north orient here.
			blockId = visual and visual.id or legacyBlockId
			orient = visual and visual.renderOrient or legacyOrient
			if MC.NormalizeOrient then orient = MC.NormalizeOrient( blockId, orient ) end
			local block = MC.Blocks and MC.Blocks[blockId]
			if not block then error( "state " .. stateId .. " visual block is unavailable", 0 ) end
			local stateFlags = exact and 1 or 0
			local rule = block and ( block.stateRule or block.orient ) or nil
			-- Match the Lua emitter selection instead of blindly consuming every
			-- imported visual plan.  Doors, beds and ordinary compact models are
			-- intentionally rendered by the mother plugin's base model path; only
			-- actual visual overrides (plus native dynamic stairs) use the catalog.
			local useGeneratedVisual = ( block and block.shape == "stairs" )
				or ( visual and visual.generatedVisualOverride == true )
			local keepGeneratedFaces = rule == "door"
			local stateFullCube = not keepGeneratedFaces and (
				visual and MC.BlockVisualIsFullCube and MC.BlockVisualIsFullCube( visual ) == true
					or ( not visual and MC.BlockIsFullCube and MC.BlockIsFullCube( blockId, orient ) == true )
			)
			if stateFullCube then stateFlags = stateFlags + 4 end
			if not keepGeneratedFaces and ( not visual or visual.cullGeneratedFaces ~= false ) then
				stateFlags = stateFlags + 8
			end
			if useGeneratedVisual then stateFlags = stateFlags + 16 end
			if block and block.shape == "stairs" and MC.StateWith and MC.StateVisualPlanIdFast then
				stateFlags = stateFlags + 2
				for index, shape in ipairs( { "straight", "inner_left", "inner_right", "outer_left", "outer_right" } ) do
					local shaped = MC.StateWith( stateId, "shape", shape )
					local planId = shaped and MC.StateVisualPlanIdFast( shaped ) or nil
					stairPlans[index] = checkedInt( planId or 0, 1, 65535, "stair plan" )
				end
			end
			if MC.LiquidStateMetrics then
				local kind, ownHeight, _, _, waterlogged = MC.LiquidStateMetrics( stateId )
				if kind and not waterlogged then
					stateLiquidKind = checkedInt( LIQUID[kind] or 0, 1, 2, "state liquid kind" )
					local scaled = checkedNumber( ownHeight, 0, 1, "state liquid height" ) * 9
					stateLiquidAmount = checkedInt( math.floor( scaled + 0.5 ), 1, 8, "state liquid amount" )
					if math.abs( scaled - stateLiquidAmount ) > 0.000001 then
						error( "state liquid height is not quantized", 0 )
					end
				end
			end
			parts[#parts + 1] = u32le( stateId ) .. u16le( checkedInt( blockId, 1, 65535, "state block id" ) )
				.. u8( checkedInt( orient or 0, 0, 255, "state orient" ) ) .. u8( stateFlags )
				.. u8( stateLiquidKind ) .. u8( stateLiquidAmount ) .. u8( 0 )
				.. u16le(stairPlans[1])..u16le(stairPlans[2])..u16le(stairPlans[3])..u16le(stairPlans[4])..u16le(stairPlans[5])
		else
			parts[#parts + 1] = u32le( 0 ) .. u16le( 0 ) .. string.rep( "\0", 15 )
		end
	end
	return table.concat( parts ), count
end

local function visualCatalogPayload( totalStateCount )
	local c = MC.StateVisualCatalog
	if type( c ) ~= "table" then return "", 0 end
	local function count( field, hi ) return checkedInt( c[field] or 0, 0, hi, "visual " .. field ) end
	local cs=count("stateCount",totalStateCount); local gc=count("geometryTemplateCount",65535); local gq=count("geometryQuadCount",4000000)
	local sc=count("surfaceSetCount",65535); local se=count("surfaceEntryCount",4000000); local mc=count("modelInstanceCount",65535)
	local cc=count("choiceGroupCount",65535); local ca=count("choiceAlternativeCount",65535); local pc=count("visualPlanCount",65535); local pg=count("visualPlanGroupCount",65535)
	local fields={{"geometryIndex",gc*6},{"geometryData",gq*32},{"surfaceIndex",sc*6},{"surfaceData",se*2},{"modelMap",mc*4},{"groupIndex",cc*3},{"groupData",ca*3},{"planIndex",pc*3},{"planData",pg*2},{"statePlans",cs*2}}
	local data={u32le(checkedInt(c.coordinateScale or 0,1,1048576,"coordinate scale")),u32le(checkedInt(c.packedQuadBytes or 0,1,256,"packed quad bytes")),u32le(cs),u32le(gc),u32le(gq),u32le(sc),u32le(se),u32le(mc),u32le(cc),u32le(ca),u32le(pc),u32le(pg)}
	for _,f in ipairs(fields) do
		local raw=c[f[1]]
		if type(raw)~="string" or #raw~=f[2] then error("visual "..f[1].." length mismatch",0) end
		if f[1]=="surfaceData" then
			local remapped,pages={},{}
			for offset=1,#raw,2 do
				local lo,hi=raw:byte(offset,offset+1);local packed=(lo or 0)+(hi or 0)*256
				local logical=bit_band(packed,0x0FFF);local emission=packed-logical
				local page,physical=resolveAtlasSurface(logical,"visual surface tile")
				if physical>0x0FFF then error("visual surface tile exceeds 12-bit range",0) end
				remapped[#remapped+1]=u16le(emission+physical)
				pages[#pages+1]=u8(page)
			end
			raw=table.concat(remapped)
			data[#data+1]=raw
			data[#data+1]=table.concat(pages)
		else
			data[#data+1]=raw
		end
	end
	local tintSeen,tintIndexes={},{}
	for offset=1,#c.geometryData,32 do local packed=c.geometryData:byte(offset) or 0;local tv=bit_rshift(packed,3);if tv>0 and not tintSeen[tv-1] then tintSeen[tv-1]=true;tintIndexes[#tintIndexes+1]=tv-1 end end
	table.sort(tintIndexes);if #tintIndexes>31 then error("too many visual tint indexes",0) end
	data[#data+1]=u8(#tintIndexes);for _,ti in ipairs(tintIndexes)do data[#data+1]=u8(ti) end
	for stateId=0,cs-1 do local blockId=MC.BlockTypeForState and MC.BlockTypeForState(stateId) or 0;for _,ti in ipairs(tintIndexes)do local code=MC.BlockStateTintCode and MC.BlockStateTintCode(stateId,blockId,ti) or 0;data[#data+1]=u8(checkedInt(code,0,255,"state tint code")) end end
	-- Runtime model transforms are typed into the native stream. Format v2
	-- supports both uniform rotation and face-specific rotation in catalog face
	-- order (top, bottom, east, west, north, south).
	local transforms = {}
	local function addTransform( modelId, kind, rotations, label )
		modelId = checkedInt( modelId, 1, mc, label .. " model id" )
		local encoded = u8( kind ) .. u8( 0 )
		if kind == 0 then
			encoded = encoded .. u8( checkedInt( rotations[1], 0, 3, label .. " rotation" ) ) .. u8( 0 )
		elseif kind == 1 then
			for face = 1, 6 do encoded = encoded .. u8( checkedInt( rotations[face], 0, 3, label .. " face rotation" ) ) end
		else error( label .. " transform kind invalid", 0 ) end
		local previous = transforms[modelId]
		if previous and previous ~= encoded then error( label .. " model transform conflict", 0 ) end
		transforms[modelId] = encoded
	end
	for _,name in ipairs({"minecraft:piston","minecraft:sticky_piston","minecraft:piston_head"}) do
		local schema=MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[name]
		if not schema or not MC.StateVisualPlanRangeFast or not MC.StateVisualPlanModelAtFast then
			error("piston visual transform registry unavailable",0)
		end
		for stateId=schema.firstStateId,schema.lastStateId do
			local planId,groupOffset,groupCount=MC.StateVisualPlanRangeFast(stateId)
			if not planId or groupCount~=1 then error("piston visual plan invalid for state "..stateId,0) end
			local modelId=MC.StateVisualPlanModelAtFast(planId,groupOffset,0,0,0,0)
			if not modelId then error("piston visual model missing for state "..stateId,0) end
			addTransform(modelId,0,{2},"piston")
		end
	end
	local railSchema=MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:rail"]
	local railCorners={south_east=true,south_west=true,north_west=true,north_east=true}
	if railSchema and MC.GetStateProperty and MC.StateVisualPlanRangeFast and MC.StateVisualPlanModelAtFast then
		for stateId=railSchema.firstStateId,railSchema.lastStateId do
			if railCorners[MC.GetStateProperty(stateId,"shape")] then
				local planId,groupOffset,groupCount=MC.StateVisualPlanRangeFast(stateId)
				if groupCount~=1 then error("rail corner transform requires one model group",0) end
				local modelId=MC.StateVisualPlanModelAtFast(planId,groupOffset,0,0,0,0)
				if not modelId then error("rail corner transform model missing",0) end
				addTransform(modelId,1,{3,1,3,3,3,3},"rail corner")
			end
		end
	end
	local transformed={};for modelId in pairs(transforms)do transformed[#transformed+1]=modelId end
	table.sort(transformed);data[#data+1]=u16le(#transformed)
	for _,modelId in ipairs(transformed)do data[#data+1]=u16le(modelId)..transforms[modelId] end
	local payload=table.concat(data);return payload,#payload
end

local function atlasPagesPayload()
	local pageCount = checkedInt( MC.AtlasPageCount and MC.AtlasPageCount() or 1,
		1, 64, "atlas page count" )
	local layouts, extra, regions, dynamic = {}, {}, {}, false
	for page = 0, pageCount - 1 do
		local A = MC.AtlasPageLayout and MC.AtlasPageLayout( page ) or ( page == 0 and MC.Atlas )
		if type( A ) ~= "table" then error( "atlas page " .. page .. " layout unavailable", 0 ) end
		local layout = {
			COLS = checkedInt( A.COLS or 1, 1, 65535, "atlas cols" ),
			ROWS = checkedInt( A.ROWS or 1, 1, 65535, "atlas rows" ),
			TILE = checkedInt( A.TILE or 64, 1, 65535, "atlas tile" ),
			PAD = checkedInt( A.PAD or 0, 0, 65535, "atlas pad" ),
			STRIDE = checkedInt( A.STRIDE or A.TILE or 64, 1, 65535, "atlas stride" ),
			W = checkedInt( A.W or 4096, 1, 65535, "atlas width" ),
			H = checkedInt( A.H or 4096, 1, 65535, "atlas height" ),
			INSET = checkedNumber( A.INSET or .5, 0, 65535, "atlas inset" ),
		}
		layouts[page] = layout
		local count = 0
		if A.REGIONS then
			dynamic = true
			for _ in pairs(A.REGIONS) do count = count + 1 end
		end
		regions[#regions+1] = u16le(checkedInt(count, 0, 4096, "atlas region count"))
		for index=0,count-1 do
			local rect = A.REGIONS[index]
			if not rect then error("sparse atlas regions", 0) end
			regions[#regions+1] = u16le(rect[1]) .. u16le(rect[2]) .. u16le(rect[3]) .. u16le(rect[4])
		end
		if page > 0 then
			extra[#extra + 1] = u16le( layout.COLS ) .. u16le( layout.ROWS )
				.. u16le( layout.TILE ) .. u16le( layout.PAD ) .. u16le( layout.STRIDE )
				.. u16le( layout.W ) .. u16le( layout.H ) .. f32le( layout.INSET )
		end
	end
	if dynamic then
		if not mcmesh or mcmesh.AtlasRegionVersion ~= 1 then error("native atlas regions unavailable", 0) end
		return layouts[0], pageCount, table.concat(extra) .. table.concat(regions), 6
	end
	return layouts[0], pageCount, table.concat( extra ), 5
end

local function packBlockDefsUnsafe()
	if not ( MC.Blocks and MC.Atlas and MC.BlockFace and MC.BlockIsFullCube and MC.BlockBoxes ) then return nil end
	local ids = {}
	for id, b in pairs( MC.Blocks ) do
		if type(id)=="number" and id==math.floor(id) and id>=1 and id<=65535 and b then ids[#ids+1]=id end
	end
	table.sort(ids)
	if #ids > MAX_BLOCKS then error("too many block definitions",0) end

	local body, counts = {}, { orient=0, box=0, quad=0, template=0 }
	local emitterCensus, passCensus = {}, { [0]=0,[1]=0 }
	for _, id in ipairs(ids) do
		local b, orients = MC.Blocks[id], orientsForBlock(MC.Blocks[id])
		local orientParts, defaultOrient = {}, orients[1]
		local liquidKind = MC.LiquidKind and MC.LiquidKind(id) or nil
		local connKind = connectionKind(b,id)
		for _, orient in ipairs(orients) do
			local emitter, faces, boxes, quads, templates = nil, {}, {}, {}, {}
			if b.shape == "cross" then emitter = "cross"
			elseif b.shape == "model" and not modelUsesConnection(b,id) then
				quads = modelQuads(b,orient) or {}
				if #quads>0 then
					emitter="model"
					-- Models remain unconditional/no-cull emitters. Their resolved boxes
					-- are nevertheless needed when an adjacent shape asks whether this
					-- model covers its boundary face.
					local modelBoxes = MC.BlockBoxes(id,orient) or {}
					for bi, box in ipairs(modelBoxes) do boxes[bi] = packBox(box) end
				end
			end
			if not emitter and liquidKind then emitter="liquid" end
			if not emitter and MC.BlockIsFullCube(id,orient) then emitter="fullCube" end
			if not emitter and connKind then emitter="connection" end
			if not emitter then
				boxes,quads=staticShapePayload(b,id,orient); if boxes then emitter="shape" else error("unsupported block "..id,0) end
			end
			if emitter=="fullCube" or emitter=="liquid" then
				for face=1,6 do local tile,uvs=resolveFaceTex(b,id,orient,face); faces[#faces+1]=packFaceTex(tile,uvs,0) end
			elseif emitter=="cross" then
				local tile=checkedInt(b.side or 0,0,65535,"cross tile"); faces[1]=packFaceTex(tile,FACE_UV_FLAGS,0)
			elseif emitter=="connection" then templates=buildConnectionTemplates(b,id,orient,connKind) end
			local pass = MC.IsTranslucentBlock and MC.IsTranslucentBlock(id) and 1 or 0
			local flags = MC.BlockIsFullCube(id,orient) and 1 or 0
			local cap = capabilitiesFor(b,id,orient)
			local oh = u8(EMITTER[emitter])..u8(pass)..u8(flags)..u8(cap)..u8(#faces)..u8(0)
				..u16le(#boxes)..u32le(#quads)..u16le(#templates)..u16le(0)
			orientParts[#orientParts+1] = u8(orient)..oh..table.concat(faces)..table.concat(boxes)..table.concat(quads)..table.concat(templates)
			counts.orient=counts.orient+1; counts.box=counts.box+#boxes; counts.quad=counts.quad+#quads; counts.template=counts.template+#templates
			-- aggregate boxes/quads inside templates are part of hostile-validation census.
			if emitter=="connection" then
				local maxMask=connKind=="pipe6" and 63 or 15
				for mask=0,maxMask do local bs=MC.ConnectionBlockBoxes(connKind=="bars" and "pane" or connKind,mask); counts.box=counts.box+#bs end
				-- derive quad census from fixed record lengths after template headers/boxes.
				for _,raw in ipairs(templates) do
					local b0,b1,b2,b3=raw:byte(5,8); counts.quad=counts.quad+(b0+b1*256+b2*65536+b3*16777216)
				end
			end
			emitterCensus[emitter]=(emitterCensus[emitter] or 0)+1; passCensus[pass]=passCensus[pass]+1
		end
		local blockFlags=(b.transparent and 1 or 0)+(b.solid~=false and 2 or 0)
		body[#body+1]=u16le(id)..u16le(blockFlags)..u8(defaultOrient)..u8(LIQUID[liquidKind] or 0)
			..u8(CONNECTION[connKind] or 0)..u8(0)..u16le(#orients)..u16le(0)..u32le(0)..table.concat(orientParts)
	end
	if counts.orient>MAX_BLOCKS*MAX_ORIENTS or counts.box>MAX_BOXES or counts.quad>MAX_QUADS or counts.template>MAX_TEMPLATES then error("definition aggregate limit exceeded",0) end
	local blockPayload=table.concat(body)
	local A, atlasPageCount, atlasPagePayload, atlasVersion = atlasPagesPayload()
	local states, stateCount = stateMapPayload()
	local visualPayload, visualBytes = visualCatalogPayload( stateCount )
	local metadata = MC.BlockStateRegistryMetadata or {}
	local catalog = MC.StateVisualCatalog or {}
	local schemaHash = hexHashBytes( metadata.schemaHash, "schema hash" )
	local visualHash = hexHashBytes( catalog.visualPlanSha256 or catalog.blockstateSha256, "visual hash" )
	local header="MCBD"..u32le(atlasVersion)..u32le(128+#atlasPagePayload+#blockPayload+#states+visualBytes)
		..u16le(checkedInt(A.COLS or 1,1,65535,"atlas cols"))..u16le(checkedInt(A.ROWS or 1,1,65535,"atlas rows"))
		..u16le(checkedInt(A.TILE or 64,1,65535,"atlas tile"))..u16le(checkedInt(A.PAD or 0,0,65535,"atlas pad"))
		..u16le(checkedInt(A.STRIDE or A.TILE or 64,1,65535,"atlas stride"))..u16le(checkedInt(A.W or 4096,1,65535,"atlas width"))
		..u16le(checkedInt(A.H or 4096,1,65535,"atlas height"))..u16le(atlasPageCount)..f32le(checkedNumber(A.INSET or .5,0,65535,"atlas inset"))
		..u32le(#ids)..u32le(counts.orient)..u32le(counts.box)..u32le(counts.quad)..u32le(counts.template)
		..u32le(stateCount)..u32le(visualBytes)..u32le(visualBytes>0 and 3 or 0)..schemaHash..visualHash
	local blob=header..atlasPagePayload..blockPayload..states..visualPayload
	if #blob>MAX_BLOB_BYTES then error("definition blob too large",0) end
	return blob, { emitters=emitterCensus, passes=passCensus }, #ids, passCensus[0], passCensus[1]
end

local function packBlockDefs()
	local started = SysTime()
	local ok,a,b,c,d,e=pcall(packBlockDefsUnsafe)
	local elapsedMS = ( SysTime() - started ) * 1000
	local p = state.packProfile
	p.defsCalls = p.defsCalls + 1
	p.defsTotalMS = p.defsTotalMS + elapsedMS
	p.defsLastMS = elapsedMS
	p.defsMaxMS = math.max( p.defsMaxMS, elapsedMS )
	if not ok or type( a ) ~= "string" then
		p.defsFailures = p.defsFailures + 1
		log("MCBD v5 pack failed: "..tostring(a))
		return nil
	end
	p.defsBytes = #a
	return a,b,c,d,e
end

local function packLightDefs()
	local count = math.max( 1, math.floor( tonumber( MC.BlockStateCount ) or 1 ) )
	local parts, args, np, na = {}, {}, 0, 0
	for stateId = 0, count - 1 do
		local emission = MC.BlockLightEmissionForState and MC.BlockLightEmissionForState( stateId, 0, 0, 0 ) or 0
		local opacity = MC.BlockLightOpacityForState and MC.BlockLightOpacityForState( stateId, 0, 0, 0 ) or 15
		args[na + 1] = math.Clamp( math.floor( tonumber( emission ) or 0 ), 0, 15 )
		args[na + 2] = math.Clamp( math.floor( tonumber( opacity ) or 15 ), 0, 15 )
		na = na + 2
		if na >= 192 then np = np + 1; parts[np] = string_char( unpack( args, 1, na ) ); na = 0 end
	end
	if na > 0 then np = np + 1; parts[np] = string_char( unpack( args, 1, na ) ) end
	return table.concat( parts )
end

----------------------------------------------------------------- chunk 鎵撳寘
local table_concat = table.concat

local function packChunkBlobUnsafe( chunk )
	if type( chunk ) ~= "table" then error( "chunk is not a table", 0 ) end
	local migrated, migrationError = MC.MigrateChunkStateStorage( chunk )
	if not migrated then error( "state storage migration failed: " .. tostring( migrationError ), 0 ) end
	local cs = checkedInt( MC.CS or 16, 1, 65535, "chunk size" )
	local ch = checkedInt( MC.CH or 32, 1, 65535, "chunk height" )
	local cells = cs * cs * ch
	if cells > 16777216 then error( "chunk cell count out of range", 0 ) end
	local maxStateId = checkedInt( MC.BlockStateCount or 1, 1, 1048577, "state count" ) - 1
	local parts, np = {}, 0
	local args, na = {}, 0
	for li = 0, cells - 1 do
		local stateId, readError = MC.GetChunkBlockStateByLocalIndex( chunk, li )
		if stateId == nil then error( "state read failed at " .. li .. ": " .. tostring( readError ), 0 ) end
		stateId = checkedInt( stateId, 0, maxStateId, "chunk stateId at " .. li )
		args[na + 1] = bit_band( stateId, 0xFF )
		args[na + 2] = bit_band( bit_rshift( stateId, 8 ), 0xFF )
		args[na + 3] = bit_band( bit_rshift( stateId, 16 ), 0xFF )
		args[na + 4] = bit_band( bit_rshift( stateId, 24 ), 0xFF )
		na = na + 4
		if na >= 192 then
			np = np + 1
			parts[np] = string_char( unpack( args, 1, na ) )
			na = 0
		end
	end
	if na > 0 then np = np + 1; parts[np] = string_char( unpack( args, 1, na ) ) end
	return table_concat( parts )
end

local function packChunkBlob( chunk )
	local started = SysTime()
	local ok, blob = pcall( packChunkBlobUnsafe, chunk )
	local elapsedMS = ( SysTime() - started ) * 1000
	local p = state.packProfile
	p.chunkCalls = p.chunkCalls + 1
	p.chunkTotalMS = p.chunkTotalMS + elapsedMS
	p.chunkLastMS = elapsedMS
	p.chunkMaxMS = math.max( p.chunkMaxMS, elapsedMS )
	if not ok or type( blob ) ~= "string" then
		p.chunkFailures = p.chunkFailures + 1
		return nil, tostring( blob )
	end
	p.chunkBytes = p.chunkBytes + #blob
	return blob
end

----------------------------------------------------------------- 浠ｇ悊 mesh
local function makeProxy( cx, cy, cz, pass )
	local proxy = {}
	function proxy:Draw()
		if state.failed then return end
		local ok = mcmesh.DrawChunk( cx, cy, cz, pass )
		if ok == false then state.failed = true end
	end
	function proxy:Destroy() end          -- 鍘熺绾挎竻鐞嗚矾寰勫彲鑳借皟鐢?
	function proxy:IsValid() return true end
	return proxy
end

local function installProxies( key )
	if state.proxied[key] then return end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return end
	MC.Meshes[key] = { { mesh = makeProxy( cx, cy, cz, 0 ) } }
	MC.MeshesTrans[key] = { { mesh = makeProxy( cx, cy, cz, 1 ) } }
	state.proxied[key] = true
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
end

local function removeProxies( key )
	if not state.proxied[key] then return end
	MC.Meshes[key] = nil
	MC.MeshesTrans[key] = nil
	state.proxied[key] = nil
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
end

----------------------------------------------------------------- native 璋冪敤
local function pushChunk( key, chunk )
	local frame = FrameNumber()
	if state.pushedFrame[key] == frame then return true end
	if chunk.nativeMeshEpoch == state.epoch then
		state.packProfile.skippedChunkPacks = state.packProfile.skippedChunkPacks + 1
		state.pushedFrame[key] = frame
		return true
	end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return false end
	local blob, packError = packChunkBlob( chunk )
	if not blob then
		log( "chunk pack rejected for " .. tostring( key ) .. ": " .. tostring( packError ) )
		state.failed = true
		return false
	end
	local callOk, result = pcall( mcmesh.ApplyChunk, cx, cy, cz, blob )
	if not callOk then
		log( "ApplyChunk error for " .. tostring( key ) .. ": " .. tostring( result ) )
		state.failed = true
		return false
	end
	if result == true then state.pushedFrame[key] = frame; chunk.nativeMeshEpoch = state.epoch end
	return result == true
end

local function adoptNativeChunkStorage( chunk )
	if not chunk or chunk.nativeMeshEpoch ~= state.epoch then return false end
	chunk.nativeStateStorage = true
	chunk.chunkBackend = "native"
	chunk.stateSections = nil
	chunk.stateStorageMigrated = true
	chunk.renderSectionIndexStorage = nil
	chunk.renderSectionBlocks = nil
	chunk.renderSectionBlocksReady = nil
	chunk.renderSectionIndexVersion = nil
	chunk.renderSectionIndexStoresStateId = nil
	if MC.AttachNativeChunkCompatibilityProxy then MC.AttachNativeChunkCompatibilityProxy( chunk ) end
	return true
end

local function materializeNativeWorldForRestart()
	local converted = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.nativeStateStorage then
			local ok, err = MC.NativeChunkBackend.MaterializeLuaStorage( chunk )
			if not ok then
				for _, restored in ipairs( converted ) do adoptNativeChunkStorage( restored ) end
				return nil, err or "native_state_materialization_failed"
			end
			converted[#converted + 1] = chunk
		end
	end
	return converted
end

local function unloadChunkNative( key )
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if cx then
		pcall( mcmesh.UnloadChunk, cx, cy, cz )
		MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0.02 )
	end
	state.pushedFrame[key] = nil
end

----------------------------------------------------------------- 婵€娲?/ 鍥為€€
local deactivate -- 鍓嶇疆澹版槑

local function wrappedBuildChunkMesh( key, sectionIndex )
	if not state.active then return state.originals.BuildChunkMesh( key, sectionIndex ) end
	key = MC.CanonicalChunkKey and MC.CanonicalChunkKey( key ) or key
	local chunk = MC.GetChunkByKey( key )
	if not chunk or ( chunk.count or 0 ) == 0 then
		removeProxies( key )
		unloadChunkNative( key )
		return
	end
	if not pushChunk( key, chunk ) then
		state.failed = true
		return
	end
	installProxies( key )
end

local function wrappedRebuildLighting( key, sectionIndex )
	-- GPU light texture 妯″紡涓嬪厜鐓т笉鏀瑰嚑浣? 鏉冨▉蹇収鎺ㄤ竴娆? native diff 鍚?
	-- 鏃犲彉鍖栧嵆涓?no-op, 鏈夊彉鍖?缂撳瓨澶辨晥鍏滃簳璺緞)鍒欐甯搁噸寤恒€?
	-- GPU-light texture updates do not change native geometry.
	return true
end

local function wrappedFreeChunkMesh( key )
	key = MC.CanonicalChunkKey and MC.CanonicalChunkKey( key ) or key
	removeProxies( key )
	unloadChunkNative( key )
	return state.originals.FreeChunkMesh( key )
end

local function patch()
	local luaBackend = MC.MeshBackends and MC.MeshBackends.lua
	if not luaBackend then state.failed = true; return false end
	state.originals = {
		BuildChunkMesh = luaBackend.BuildChunkMesh,
		RebuildChunkMeshLighting = luaBackend.RebuildChunkMeshLighting,
		FreeChunkMesh = luaBackend.FreeChunkMesh,
	}
	state.nativeMeshBackend = {
		name = "native",
		native = true,
		IsActive = function() return state.active and not state.failed end,
		BuildChunkMesh = wrappedBuildChunkMesh,
		RebuildChunkMeshLighting = wrappedRebuildLighting,
		FreeChunkMesh = wrappedFreeChunkMesh,
	}
	return MC.RegisterMeshBackend and MC.RegisterMeshBackend( "native", state.nativeMeshBackend ) == true
end

local function unpatch()
	if not state.originals then return end
	if MC.MeshBackends and MC.MeshBackends.native == state.nativeMeshBackend then MC.MeshBackends.native = nil end
	state.nativeMeshBackend = nil
	state.originals = nil
end

local function activate()
	timer.Remove( "mcswep_native_fallback_rebuild" )   -- 蹇€熸潵鍥炲垏鏃剁粓姝㈡湭瀹屾垚鐨勫洖閫€閲嶅缓
	if not patch() then return deactivate( "native backend registration failed" ) end
	state.epoch = state.epoch + 1
	state.active = true
	state.failed = false
	local t0 = SysTime()
	local pushed = 0
	-- 鎺ョ宸插姞杞戒笘鐣? 閲婃斁 Lua mesh -> 鎺ㄥ揩鐓?-> 瑁呬唬鐞?
	for key, chunk in pairs( MC.World or {} ) do
		state.originals.FreeChunkMesh( key )
		if chunk and ( chunk.count or 0 ) > 0 then
			if not pushChunk( key, chunk ) then
				state.failed = true
				break
			end
			installProxies( key )
			pushed = pushed + 1
		end
	end
	if state.failed then
		log( "activation failed, falling back to Lua" )
		return deactivate( "activation failure" )
	end
	-- Ownership changes only after every existing Lua chunk was accepted by
	-- C++. A partial upload therefore leaves all Lua storage intact for the
	-- normal fallback path; a successful upload releases the duplicate stores.
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 then adoptNativeChunkStorage( chunk ) end
	end
	for key in pairs( MC.StreamHiddenChunkKeys or {} ) do MC.NativeChunkBackend.SetChunkVisible( key, false ) end
	log( ">>> backend now: NATIVE (" .. pushed .. " chunks pushed in "
		.. math.Round( ( SysTime() - t0 ) * 1000, 1 ) .. "ms)" )
	MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0 )
end

deactivate = function( reason, options )
	options = options or {}
	MC.NativeChunkBackend.CancelAllCompressedPatchDecodes()
	state.active = false
	local materialized = tonumber( options.materialized ) or 0
	local materializeFailed = 0
	if options.alreadyMaterialized ~= true then
		for _, chunk in pairs( MC.World or {} ) do
			if chunk and chunk.nativeStateStorage then
				local ok = MC.NativeChunkBackend.MaterializeLuaStorage( chunk )
				if ok then materialized = materialized + 1 else materializeFailed = materializeFailed + 1 end
			end
		end
	end
	state.epoch = state.epoch + 1
	unpatch()
	for key in pairs( state.proxied ) do
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
	end
	state.proxied = {}
	state.pushedFrame = {}
	state.lightPending, state.lightRunning, state.lightReady = false, false, false
	state.lightCache, state.skyCache, state.lightDue, state.lightFirstPending = {}, {}, 0, 0
	-- ClearWorld keeps the permanent worker alive for an active native session.
	-- A backend deactivation must fully stop workers and clear definitions/promise,
	-- otherwise the next Handshake correctly rejects workerCount != 0.
	if mcmesh and isfunction( mcmesh.Shutdown ) then pcall( mcmesh.Shutdown )
	elseif mcmesh and isfunction( mcmesh.ClearWorld ) then pcall( mcmesh.ClearWorld ) end
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
	if state.shuttingDown then return materializeFailed == 0, materialized, materializeFailed end
	if options.restarting == true then
		log( ">>> backend restart prepared (" .. tostring( reason ) .. "), materialized="
			.. materialized .. " failed=" .. materializeFailed )
		return materializeFailed == 0, materialized, materializeFailed
	end
	-- Sky reflood requests made while Native owned lighting were redirected to
	-- C++. Once ownership returns to Lua those requests no longer exist in the
	-- Lua queue, so rebuild the column cache before fallback meshes are built.
	if MC.ClearSkyColumnCache then
		MC.ClearSkyColumnCache()
	else
		if MC.ClearSkyFlood then MC.ClearSkyFlood() end
		if MC.QueueAllSkyFlood then MC.QueueAllSkyFlood() end
	end
	if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	if MC.BindGpuChunkLightTexture and MC.BindGpuChunkLightTexture() ~= true then
		log( "Lua light atlas material bind failed during native fallback" )
	end
	-- Rebuild the complete Lua fallback synchronously. Tile preparation is an
	-- upload barrier inside BuildChunkMesh; no live mesh can point at a partial tile.
	local keys = {}
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 then keys[#keys + 1] = key end
	end
	for i = 1, #keys do
		if MC.BuildChunkMesh then MC.BuildChunkMesh( keys[i] ) end
	end
	log( ">>> backend now: LUA (" .. tostring( reason ) .. "), "
		.. #keys .. " chunks rebuilt, materialized=" .. materialized .. " failed=" .. materializeFailed )
	return materializeFailed == 0, materialized, materializeFailed
end

----------------------------------------------------------------- 甯у惊鐜?/ 鐪嬫姢
hook.Add( "Think", "mcswep_native_think", function()
	if not state.active then return end
	if state.failed then return deactivate( "native call failed" ) end
	if not CONVAR_ENABLED:GetBool() then return deactivate( "mc_native_mesh 0" ) end
	-- 鍏夌収椋庢牸鍒囪蛋 GPU light texture -> native 鍥哄畾 payload 浼氶敊鍏? 浜よ繕 Lua
	if not gpuLightProfileActive() then return deactivate( "light style changed" ) end
	-- 鍘熼」鐩?autorefresh 浼氶噸瀹氫箟 MC.BuildChunkMesh, 妫€娴嬪埌灏遍噸鏂版墦琛ヤ竵
	if not MC.MeshBackends or MC.MeshBackends.native ~= state.nativeMeshBackend then
		log( "detected backend registry reload, re-registering" )
		if not patch() then return deactivate( "backend registry reload failed" ) end
	end
	if not nativeLightingEnabled() then
		if state.lightPending or state.lightRunning or state.lightReady or state.lightLastStatus ~= "disabled" then
			MC.NativeChunkBackend.CancelBlockLightRebuild( "disabled" )
		end
	elseif state.lightRunning then
		local lightResult = MC.NativeChunkBackend.PollBlockLightRebuild()
		if istable( lightResult ) and lightResult.status ~= "running" then
			state.lightRunning = false
			if lightResult.status == "committed" or lightResult.status == "partial" then
				if lightResult.status == "committed" then state.lightReady = true end
				applyNativeLightChanges( lightResult )
				if lightResult.status == "partial" then
					-- Unchanged columns were committed; only dependency columns touched
					-- during the worker run need another snapshot. Existing/incremental
					-- light remains visible while that completion pass runs.
					state.lightPending = true
					state.lightFirstPending = CurTime()
					state.lightDue = state.lightFirstPending
				end
			elseif lightResult.status == "stale" then
				state.lightLastStatus = "stale"
				state.lightPending = true
				state.lightFirstPending = CurTime()
				state.lightDue = state.lightFirstPending
			end
		end
	elseif state.lightPending and CurTime() >= ( state.lightDue or 0 ) then
		if MC.NativeChunkBackend.StartBlockLightRebuild() then
			state.lightPending = false
			state.lightRunning = true
			state.lightDue = 0
			state.lightFirstPending = 0
		end
	end
	local nativeThinkStarted = SysTime()
	local ok, result = pcall( mcmesh.Think, math.Clamp( CONVAR_THINK_MS:GetFloat(), 0.5, 16 ) )
	local nativeThinkMS = ( SysTime() - nativeThinkStarted ) * 1000
	if MC.StreamPerformanceAddFrameStage then
		MC.StreamPerformanceAddFrameStage( "native.think", nativeThinkMS, {
			nativePending = istable( result ) and ( tonumber( result.pending ) or 0 ) or 0,
			nativeCommitted = istable( result ) and ( tonumber( result.committed ) or 0 ) or 0,
		} )
	end
	if ok and istable( result ) and istable( result.profile ) then
		local visited = tonumber( result.profile.resultsVisited ) or 0
		local queueWaitUs = tonumber( result.profile.queueWaitUs ) or 0
		MC.NativeMeshLastThinkProfile = {
			completedAt = SysTime(), callMS = nativeThinkMS,
			pending = tonumber( result.pending ) or 0,
			committed = tonumber( result.committed ) or 0,
			profile = table.Copy( result.profile ),
		}
		local sample = nextPerfSample( state.nativePerf.think )
		sample.frame = FrameNumber()
		sample.callMS = nativeThinkMS
		sample.uploadUs = tonumber( result.profile.uploadUs ) or 0
		sample.bytesUploaded = tonumber( result.profile.bytesUploaded ) or 0
		sample.verticesUploaded = tonumber( result.profile.verticesUploaded ) or 0
		sample.queueWaitUs = queueWaitUs
		sample.queueWaitAvgUs = visited > 0 and queueWaitUs / visited or 0
		sample.queueSamples = visited
	end
	if not ok then
		log( "Think error: " .. tostring( result ) )
		return deactivate( "Think error" )
	end
	if istable( result ) and result.failed then
		log( "native fault: " .. tostring( result.fault or "unknown" ) )
		return deactivate( "native fault" )
	end
	-- M3 鐨?BuildChunkMesh wrapper 鍙彁浜ゅ揩鐓э紝鐪熸鐨?IMesh 鏇挎崲鍙戠敓鍦?native
	-- Think銆傜ǔ瀹氫唬鐞嗕笉浼氳嚜琛屾敼鍙?ChunkDrawListVersion锛岃€?shadow map / heightfield
	-- 鐢ㄥ畠浣滀负鍑犱綍鍐呭鐗堟湰锛涙瘡甯ф湁浠绘剰 section 鐪熸钀藉湴鍚庣粺涓€ bump 涓€娆°€?
	if istable( result ) and ( tonumber( result.committed ) or 0 ) > 0 then
		if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
	end
end )

----------------------------------------------------------------- 鍚姩寮曞
local function tryStart()
	state.startupFailureReason = nil
	if state.shuttingDown or state.shutdownCalled then state.startupFailureReason = "shutting down"; return false end
	if state.active then return true end
	if not CONVAR_ENABLED:GetBool() then state.startupFailureReason = "mc_native_mesh disabled"; return false end
	if state.moduleUnavailable
	or ( MC.NativeMeshModuleProbeDone == true and MC.NativeMeshModuleAvailable == false ) then
		return lockToLuaBackend( MC.NativeMeshModuleFailureReason )
	end
	if not ( MC and MC.BuildChunkMesh and MC.World and MC.Meshes and MC.MeshesTrans
		and MC.GetChunkByKey and MC.ChunkKeyToCoords ) then state.startupFailureReason = "MC pipeline not ready"; return false end
	if not probeNativeModule() then state.startupFailureReason = MC.NativeMeshModuleFailureReason or "module probe failed"; return false end
	if not ( mcmesh.AbiVersion and mcmesh.AbiVersion() == MC.NativeMeshABI ) then
		log( "ABI mismatch (module " .. tostring( mcmesh.AbiVersion and mcmesh.AbiVersion() )
			.. ", adapter " .. tostring( MC.NativeMeshABI ) .. "), staying on Lua path" )
		return lockToLuaBackend( "ABI mismatch" )
	end
	-- 瀵煎嚭闈㈡鏌? 濂戠害鍑芥暟蹇呴』鍏ㄩ儴瀛樺湪(绌哄３涔熻), 缂轰竴涓氨鐐瑰悕骞剁暀鍦?Lua 璺緞
	for _, fname in ipairs( { "Handshake", "SetAtlasPageMaterial", "SetBlockDefs", "SetLightDefs", "SetSimpleGreedy", "SetDirectionalDraw", "SetOcclusionCull", "SetLod", "CreateChunk", "ApplyChunk", "SetCellsBatch", "SetCell", "GetCell", "GetChunkCells", "RebuildBlockLight", "StartBlockLightRebuild", "PollBlockLightRebuild", "CancelBlockLightRebuild", "GetBlockLightChunk", "GetSkyLightChunk", "BindLightAtlasMaterial", "GetLightAtlasStats", "GetLightAtlasSlot", "DrawVisible", "SetChunkVisible", "UnloadChunk",
		"ClearWorld", "Think", "DrawChunk", "GetStats", "Shutdown" } ) do
		if not isfunction( mcmesh[fname] ) then
			log( "module missing mcmesh." .. fname .. "(), staying on Lua path" )
			return lockToLuaBackend( "missing export " .. fname )
		end
	end
	-- GPU 鍏夌収妗ｆ闂ㄦ: 闈?GPU light texture 椋庢牸涓?native 鐨勫浐瀹?payload 浼氶敊鍏?
	if not gpuLightProfileActive() then
		state.startupFailureReason = "non-GPU light profile"
		return false   -- 闈欓粯: 鐜╁鍙兘鍒囦簡鍏夌収椋庢牸, bootstrap 涓嬬閲嶈瘯
	end
	-- 鏉愯川鍦ㄥ姞杞芥棭鏈熷彲鑳藉皻鏈垱寤? 鏈氨缁垯闈欓粯杩斿洖, bootstrap 瀹氭椂鍣ㄤ笅绉掗噸璇?
	local nativeMaterial = MC.NativeChunkMaterial or MC.CurrentChunkMaterial
	local matOpaque = nativeMaterial and nativeMaterial( false )
	local matTranslucent = nativeMaterial and nativeMaterial( true )
	if not ( matOpaque and matOpaque.GetName and not matOpaque:IsError()
		and matTranslucent and matTranslucent.GetName and not matTranslucent:IsError() ) then
		state.startupFailureReason = "chunk materials not ready"
		return false
	end
	-- 鏉愯川鍚嶅甫 "!" 鍓嶇紑: chunk 鏉愯川鏄繍琛屾椂 CreateMaterial 鐨? C++ 渚?
	-- FindMaterial 瑁稿悕浼氬幓纾佺洏鎵?.vmt 鑰屾嬁鍒?error material(瀹炴祴鏃犵敾闈?,
	-- "!" 寮哄埗鏌ヨ繍琛屾椂鏉愯川琛?鈥斺€?spike 閲?test.cpp 纭紪鐮佺殑鍚嶅瓧鍚屾鍓嶇紑銆?
	local shook = mcmesh.Handshake and mcmesh.Handshake(
		MC.CS or 16, MC.CH or 32, MC.RENDER_SECTION_SIZE or 16, MC.API.Coords.BlockSize(),
		"!" .. matOpaque:GetName(), "!" .. matTranslucent:GetName() )
	if shook ~= true then
		state.startupFailureReason = "handshake rejected"
		log( "handshake rejected, staying on Lua path" )
		timer.Remove( "mcswep_native_bootstrap" )
		return false
	end
	local atlasPageCount = MC.AtlasPageCount and MC.AtlasPageCount() or 1
	for page = 0, atlasPageCount - 1 do
		local matPageOpaque, opaqueError
		local matPageTranslucent, translucentError
		if MC.AtlasPageMaterial then
			matPageOpaque, opaqueError = MC.AtlasPageMaterial( page, false )
			matPageTranslucent, translucentError = MC.AtlasPageMaterial( page, true )
		end
		if not ( matPageOpaque and matPageOpaque.GetName and not matPageOpaque:IsError()
			and matPageTranslucent and matPageTranslucent.GetName and not matPageTranslucent:IsError() ) then
			state.startupFailureReason = "atlas page material unavailable " .. page .. " ("
				.. tostring( opaqueError or translucentError or "unknown" ) .. ")"
			if isfunction( mcmesh.Shutdown ) then pcall( mcmesh.Shutdown ) end
			return false
		end
		local pageOK, pageResult = pcall( mcmesh.SetAtlasPageMaterial, page,
			"!" .. matPageOpaque:GetName(), "!" .. matPageTranslucent:GetName() )
		if not pageOK or pageResult ~= true then
			state.startupFailureReason = "atlas page material rejected " .. page
			if isfunction( mcmesh.Shutdown ) then pcall( mcmesh.Shutdown ) end
			return false
		end
	end
	if MC.NativeChunkBackend.BindLightAtlasMaterials() ~= true then
		state.startupFailureReason = "light atlas material bind failed"
		if isfunction( mcmesh.Shutdown ) then pcall( mcmesh.Shutdown ) end
		if MC.BindGpuChunkLightTexture then MC.BindGpuChunkLightTexture() end
		log( "native light atlas material bind failed, staying on Lua path" )
		return lockToLuaBackend( state.startupFailureReason )
	end
	local greedyOK, greedyResult = pcall( mcmesh.SetSimpleGreedy, effectiveNativeGreedy() )
	if not greedyOK or greedyResult ~= true then
		state.startupFailureReason = "greedy switch rejected"
		return lockToLuaBackend( "greedy switch rejected" )
	end
	local directionalOK, directionalResult = pcall( mcmesh.SetDirectionalDraw, CONVAR_DIRECTIONAL_DRAW:GetBool() )
	if not directionalOK or directionalResult ~= true then
		state.startupFailureReason = "directional draw switch rejected"
		return lockToLuaBackend( "directional draw switch rejected" )
	end
	local occlusionOK, occlusionResult = pcall( mcmesh.SetOcclusionCull, CONVAR_OCCLUSION_CULL:GetBool() )
	if not occlusionOK or occlusionResult ~= true then
		state.startupFailureReason = "occlusion cull switch rejected"
		return lockToLuaBackend( "occlusion cull switch rejected" )
	end
	local lodStart = math.Clamp( CONVAR_LOD_START:GetFloat(), 0, 4096 )
	local lodOK, lodResult = pcall( mcmesh.SetLod, CONVAR_LOD:GetBool(), lodStart )
	if not lodOK or lodResult ~= true then
		state.startupFailureReason = "LOD switch rejected"
		return lockToLuaBackend( "LOD switch rejected" )
	end
	-- 鏂瑰潡闈欐€佹暟鎹? 鎻℃墜鍚庛€侀涓?ApplyChunk 鍓嶄笂浼犱竴娆°€傚け璐ュ繀椤诲厛娓呯悊
	-- handshake 鍒涘缓鐨?native 鐘舵€侊紝鍚﹀垯 bootstrap 鐨勪笅涓€娆￠噸璇曚細缁ф壙鍗婂惎鍔ㄧ姸鎬併€?
	local function clearFailedStartup()
		if mcmesh and isfunction( mcmesh.Shutdown ) then
			pcall( mcmesh.Shutdown )
		elseif mcmesh and isfunction( mcmesh.ClearWorld ) then
			pcall( mcmesh.ClearWorld )
		end
	end
	local packStarted = SysTime()
	local blob, census, defCount, opaqueCount, translucentCount
	local metadata = MC.BlockStateRegistryMetadata or {}
	local catalog = MC.StateVisualCatalog or {}
	local atlasProfileKey = MC.AtlasProfileCacheKey and MC.AtlasProfileCacheKey() or "default"
	local cacheKey = "mcbd5-state-liquid1-visual3-stateflags3-renderroute2-modelsurface2-pistonuv1-atlaspages1:" .. tostring( metadata.schemaHash or "" ) .. ":" .. tostring( catalog.visualPlanSha256 or "" )
		.. ":" .. tostring( MC.BlockStateCount or 0 ) .. ":" .. tostring( atlasProfileKey )
	local builtFresh, loadedFromDisk, loadedFromArtifact = false, false, false
	if state.defCache and state.defCache.key == cacheKey then
		state.packProfile.defsCacheHits = state.packProfile.defsCacheHits + 1
		blob, census, defCount, opaqueCount, translucentCount = state.defCache.blob, state.defCache.census,
			state.defCache.defCount, state.defCache.opaqueCount, state.defCache.translucentCount
	else
		local bundledBlob, bundledLight = readDefsBundledCache( cacheKey )
		local diskBlob, diskLight
		if bundledBlob then
			loadedFromArtifact = true
			blob = bundledBlob
			state.packProfile.defsCacheHits = state.packProfile.defsCacheHits + 1
			state.packProfile.defsBundledHits = state.packProfile.defsBundledHits + 1
			defCount = tonumber( MC.GeneratedBlockDefinitionCount ) or 0
			opaqueCount, translucentCount = 0, 0
			state.defCache = { key=cacheKey,blob=blob,lightBlob=bundledLight,defCount=defCount,opaqueCount=0,translucentCount=0 }
		else
			diskBlob, diskLight = readDefsDiskCache( cacheKey )
		end
		if not blob and diskBlob then
			loadedFromDisk = true
			loadedFromArtifact = true
			blob = diskBlob
			state.packProfile.defsCacheHits = state.packProfile.defsCacheHits + 1
			state.packProfile.defsDiskHits = state.packProfile.defsDiskHits + 1
			defCount = tonumber( MC.GeneratedBlockDefinitionCount ) or 0
			opaqueCount, translucentCount = 0, 0
			state.defCache = { key=cacheKey,blob=blob,lightBlob=diskLight,defCount=defCount,opaqueCount=0,translucentCount=0 }
		elseif not blob then
			blob, census, defCount, opaqueCount, translucentCount = packBlockDefs()
			builtFresh = blob ~= nil
			if blob then state.defCache = { key=cacheKey,blob=blob,census=census,defCount=defCount,opaqueCount=opaqueCount,translucentCount=translucentCount } end
		end
	end
	local packMS = ( SysTime() - packStarted ) * 1000
	if not blob then
		state.startupFailureReason = "MCBD pack/cache unavailable"
		clearFailedStartup()
		return false -- MC.Blocks/Atlas 灏氭湭灏辩华鎴栧畾涔夐潪娉? 涓嬬浠庡共鍑€鐘舵€侀噸璇?
	end
	local lightBlob = state.defCache and state.defCache.lightBlob or nil
	if not lightBlob then
		lightBlob = packLightDefs()
		if state.defCache then state.defCache.lightBlob = lightBlob end
	end
	local parseStarted = SysTime()
	local blockAccepted = mcmesh.SetBlockDefs( blob ) == true
	if not blockAccepted and loadedFromArtifact then
		if loadedFromDisk then deleteDefsDiskCache( cacheKey ) end
		state.packProfile.defsDiskFailures = state.packProfile.defsDiskFailures + 1
		blob, census, defCount, opaqueCount, translucentCount = packBlockDefs()
		lightBlob = blob and packLightDefs() or nil
		builtFresh, loadedFromDisk, loadedFromArtifact = blob ~= nil, false, false
		if blob then
			state.defCache = { key=cacheKey,blob=blob,lightBlob=lightBlob,census=census,
				defCount=defCount,opaqueCount=opaqueCount,translucentCount=translucentCount }
			blockAccepted = mcmesh.SetBlockDefs( blob ) == true
		end
	end
	if not blockAccepted then
		state.startupFailureReason = "SetBlockDefs rejected"
		log( "SetBlockDefs rejected (" .. tostring( blob and #blob or 0 ) .. " bytes), staying on Lua path" )
		clearFailedStartup()
		timer.Remove( "mcswep_native_bootstrap" )
		return false
	end
	local lightAccepted = mcmesh.SetLightDefs( lightBlob ) == true
	if not lightAccepted and loadedFromArtifact then
		if loadedFromDisk then deleteDefsDiskCache( cacheKey ) end
		state.packProfile.defsDiskFailures = state.packProfile.defsDiskFailures + 1
		lightBlob = packLightDefs()
		if state.defCache then state.defCache.lightBlob = lightBlob end
		builtFresh, loadedFromDisk, loadedFromArtifact = true, false, false
		lightAccepted = mcmesh.SetLightDefs( lightBlob ) == true
	end
	if not lightAccepted then
		state.startupFailureReason = "SetLightDefs rejected"
		log( "SetLightDefs rejected (" .. tostring( #lightBlob ) .. " bytes), staying on Lua path" )
		clearFailedStartup()
		return false
	end
	packMS = ( SysTime() - packStarted ) * 1000
	-- Persist only after both native parsers accepted the payload. A corrupt or
	-- stale file therefore never becomes a trusted cache entry.
	if builtFresh then
		if writeDefsDiskCache( cacheKey, blob, lightBlob ) then
			state.packProfile.defsDiskWrites = state.packProfile.defsDiskWrites + 1
		else
			state.packProfile.defsDiskFailures = state.packProfile.defsDiskFailures + 1
		end
	end
	local parseMS = ( SysTime() - parseStarted ) * 1000
	log( "SetBlockDefs v5 ok: " .. tostring( defCount ) .. " ids, "
		.. tostring( opaqueCount ) .. " opaque + " .. tostring( translucentCount )
		.. " translucent orient definitions, " .. #blob .. " bytes, pack/cache="
		.. math.Round( packMS, 1 ) .. "ms parse=" .. math.Round( parseMS, 1 ) .. "ms" )
	if census and census.emitters then
		local c = census.emitters
		log( "emitter census: fullCube="..tostring(c.fullCube or 0).." cross="..tostring(c.cross or 0)
			.." model="..tostring(c.model or 0).." shape="..tostring(c.shape or 0)
			.." connection="..tostring(c.connection or 0).." liquid="..tostring(c.liquid or 0) )
	end
	activate()
	return true
end

local function queueNativeBootstrap()
	if state.shuttingDown or state.shutdownCalled or state.moduleUnavailable
	or not CONVAR_ENABLED:GetBool() then return false end
	timer.Create( "mcswep_native_bootstrap", 1, 0, function()
		if tryStart() then timer.Remove( "mcswep_native_bootstrap" ) end
	end )
	return true
end

local function queueLuaAtlasRebuild()
	local marked = 0
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
			marked = marked + 1
		end
	end
	return marked
end

function MC.NativeChunkBackend.InvalidateDefinitions()
	state.defCache = nil
	return true
end

-- Reload MCBD definitions and atlas metadata without changing mc_native_mesh.
-- Active native-owned chunk state is materialized only for the duration of the
-- same-DLL restart, then uploaded and adopted again by activate().
function MC.NativeChunkBackend.ReconfigureDefinitions( reason )
	reason = tostring( reason or "definition reconfigure" )
	state.defCache = nil
	if state.shuttingDown or state.shutdownCalled then return false, "shutting_down" end
	if not CONVAR_ENABLED:GetBool() then
		return false, "mc_native_mesh_disabled_lua_meshes_queued_" .. queueLuaAtlasRebuild()
	end

	local wasActive = state.active == true
	if wasActive then
		local converted, materializeError = materializeNativeWorldForRestart()
		if not converted then return false, materializeError end
		local stopped = deactivate( reason, {
			restarting = true,
			alreadyMaterialized = true,
			materialized = #converted,
		} )
		if not stopped then
			deactivate( reason .. " materialization failure" )
			queueNativeBootstrap()
			return false, "native_restart_materialization_failed"
		end
	end

	if tryStart() then
		return true, wasActive and "native_restarted" or "native_started"
	end

	local failure = state.startupFailureReason or "native_restart_failed"
	if wasActive then
		deactivate( reason .. " restart failed" )
	else
		queueLuaAtlasRebuild()
	end
	queueNativeBootstrap()
	return false, failure
end

timer.Simple( 0, function()
	if state.shuttingDown or state.shutdownCalled then return end
	probeNativeModule()
end )

if not state.moduleUnavailable and CONVAR_ENABLED:GetBool() then
	queueNativeBootstrap()
end

cvars.AddChangeCallback( "mc_native_mesh", function( _, _, new )
	if new == "1" and not state.active then
		if state.moduleUnavailable
		or ( MC.NativeMeshModuleProbeDone == true and MC.NativeMeshModuleAvailable == false ) then return end
		if tryStart() then return end
		timer.Create( "mcswep_native_bootstrap", 1, 0, function()
			if tryStart() then timer.Remove( "mcswep_native_bootstrap" ) end
		end )
	end
	-- "0" 鐨勫叧闂敱 Think 閲岀殑 convar 妫€鏌ュ鐞?
end, "mcswep_native_bridge" )

cvars.AddChangeCallback( "mc_light_enabled", function( _, _, newValue )
	local value = string.lower( tostring( newValue or "" ) )
	local enabled = value ~= "0" and value ~= "false" and value ~= "off"
	if not enabled then
		MC.NativeChunkBackend.CancelBlockLightRebuild( "disabled" )
		return
	end
	if state.active and MC.NativeChunkBackend.ScheduleBlockLightRebuild( 0 ) then
		state.lightLastStatus = "queued"
	end
end, "mcswep_native_lighting" )

cvars.AddChangeCallback( "mc_native_greedy", function()
	if not state.active or not mcmesh or not isfunction( mcmesh.SetSimpleGreedy ) then return end
	local effective = effectiveNativeGreedy()
	local ok, accepted = pcall( mcmesh.SetSimpleGreedy, effective )
	if not ok or accepted ~= true then return log( "greedy switch failed" ) end
	log( "simple greedy requested=" .. ( CONVAR_GREEDY:GetBool() and "1" or "0" )
		.. " effective=" .. ( effective and "1" or "0" ) .. "; native sections queued for rebuild" )
end, "mcswep_native_greedy" )

cvars.AddChangeCallback( "mc_native_directional_draw", function( _, _, new )
	if not state.active or not mcmesh or not isfunction( mcmesh.SetDirectionalDraw ) then return end
	local ok, accepted = pcall( mcmesh.SetDirectionalDraw, tonumber( new ) == 1 )
	if not ok or accepted ~= true then return log( "directional draw switch failed" ) end
	log( "directional draw=" .. ( tonumber( new ) == 1 and "1" or "0" ) .. "; no mesh rebuild required" )
end, "mcswep_native_directional_draw" )

cvars.AddChangeCallback( "mc_native_occlusion_cull", function( _, _, new )
	if not state.active or not mcmesh or not isfunction( mcmesh.SetOcclusionCull ) then return end
	local ok, accepted = pcall( mcmesh.SetOcclusionCull, tonumber( new ) == 1 )
	if not ok or accepted ~= true then return log( "occlusion cull switch failed" ) end
	log( "occlusion cull=" .. ( tonumber( new ) == 1 and "1" or "0" ) .. "; no mesh rebuild required" )
end, "mcswep_native_occlusion_cull" )

local function applyNativeLod()
	if not state.active or not mcmesh or not isfunction( mcmesh.SetLod ) then return end
	local enabled = CONVAR_LOD:GetBool()
	local startChunks = math.Clamp( CONVAR_LOD_START:GetFloat(), 0, 4096 )
	local ok, accepted = pcall( mcmesh.SetLod, enabled, startChunks )
	if not ok or accepted ~= true then return log( "LOD switch failed" ) end
	log( "LOD=" .. ( enabled and "1" or "0" ) .. " startChunks=" .. math.Round( startChunks, 2 )
		.. ( enabled and "; first activation queues missing LOD meshes" or "; full-detail draw restored immediately" ) )
end

cvars.AddChangeCallback( "mc_native_lod", applyNativeLod, "mcswep_native_lod" )
cvars.AddChangeCallback( "mc_native_lod_start", applyNativeLod, "mcswep_native_lod_start" )

-- Process teardown is not a fallback: stop scheduling, restore Lua functions,
-- discard proxy bookkeeping, and call the native shutdown exactly once.
hook.Add( "ShutDown", "mcswep_native_shutdown", function()
	if state.shutdownCalled then return end
	state.shutdownCalled = true
	state.shuttingDown = true
	timer.Remove( "mcswep_native_bootstrap" )
	timer.Remove( "mcswep_native_fallback_rebuild" )
	hook.Remove( "Think", "mcswep_native_think" )
	cvars.RemoveChangeCallback( "mc_native_mesh", "mcswep_native_bridge" )
	cvars.RemoveChangeCallback( "mc_light_enabled", "mcswep_native_lighting" )
	cvars.RemoveChangeCallback( "mc_native_greedy", "mcswep_native_greedy" )
	cvars.RemoveChangeCallback( "mc_native_directional_draw", "mcswep_native_directional_draw" )
	cvars.RemoveChangeCallback( "mc_native_occlusion_cull", "mcswep_native_occlusion_cull" )
	cvars.RemoveChangeCallback( "mc_native_lod", "mcswep_native_lod" )
	cvars.RemoveChangeCallback( "mc_native_lod_start", "mcswep_native_lod_start" )
	unpatch()
	state.active = false
	state.failed = false
	state.proxied = {}
	state.pushedFrame = {}
	state.defCache = nil
	if mcmesh and isfunction( mcmesh.Shutdown ) then pcall( mcmesh.Shutdown ) end
end )

----------------------------------------------------------------- A/B 鐑垏鎹㈡寚浠?
local function setEnabledConVar( on )
	-- 淇濇寔 convar 涓庡疄闄呯姸鎬佷竴鑷? 鍚﹀垯 Think 鐨勫畧鎶ゆ鏌ヤ細绔嬪埢鍒囧洖鍘?
	local ok = pcall( function() CONVAR_ENABLED:SetBool( on ) end )
	if not ok then RunConsoleCommand( "mc_native_mesh", on and "1" or "0" ) end
end

concommand.Add( "mc_native_toggle", function()
	if state.active then
		setEnabledConVar( false )
		deactivate( "toggle" )
	else
		setEnabledConVar( true )
		if not tryStart() then
			log( "cannot activate: module or MC pipeline not ready (see mc_native_status)" )
		end
	end
end, nil, "Hot-swap MCSWEP mesh backend between native (mcswep_native_mesh) and pure Lua for A/B comparison" )

local function latestPerfSample( ring )
	if ring.count == 0 then return nil end
	local index = ( ring.next - 2 ) % PERF_SAMPLE_CAPACITY + 1
	return ring.values[index]
end

local function perfNumber( value, decimals )
	if value == nil then return "n/a" end
	return tostring( math.Round( tonumber( value ) or 0, decimals or 2 ) )
end

local function nativeProfilingEnabled()
	if not mcmesh or not isfunction( mcmesh.GetStats ) then return false end
	local ok, stats = pcall( mcmesh.GetStats )
	return ok and istable( stats ) and stats.profilingEnabled == true
end

concommand.Add( "mc_native_perf", function( _, _, args )
	local action = string.lower( tostring( args and args[1] or "" ) )
	if action == "on" then
		if not mcmesh or not isfunction( mcmesh.SetProfiling ) then
			return log( "perf profiling unavailable: mcmesh.SetProfiling missing" )
		end
		local ok, enabled = pcall( mcmesh.SetProfiling, true, true )
		if not ok or enabled ~= true then return log( "perf profiling enable failed" ) end
		state.nativePerf = newNativePerf()
		log( "perf profiling enabled; bounded window reset" )
	elseif action == "off" then
		if mcmesh and isfunction( mcmesh.SetProfiling ) then pcall( mcmesh.SetProfiling, false, false ) end
		log( "perf profiling disabled; draw counters remain available" )
	elseif action == "reset" then
		local enabled = nativeProfilingEnabled()
		if mcmesh and isfunction( mcmesh.SetProfiling ) then pcall( mcmesh.SetProfiling, enabled, true ) end
		state.nativePerf = newNativePerf()
		log( "perf window reset" )
	elseif action ~= "" then
		return log( "usage: mc_native_perf [on|off|reset]" )
	end

	log( "perf window = " .. PERF_SAMPLE_CAPACITY .. " samples, age="
		.. perfNumber( SysTime() - state.nativePerf.startedAt, 1 ) .. "s nativeDetail="
		.. tostring( nativeProfilingEnabled() ) )
	local frameRing = state.nativePerf.draw[0]
	local frame = latestPerfSample( frameRing )
	if frame then
		log( "perf.frame frameMS(current/p50/p95)=" .. perfNumber( frame.frameMS ) .. "/"
			.. perfNumber( percentile( frameRing, "frameMS", 0.50 ) ) .. "/"
			.. perfNumber( percentile( frameRing, "frameMS", 0.95 ) ) )
	end
	for pass = 0, 1 do
		local ring = state.nativePerf.draw[pass]
		local sample = latestPerfSample( ring )
		local label = pass == 0 and "opaque" or "translucent"
		if sample then
			log( "perf." .. label .. " samples=" .. ring.count
				.. " chunks(drawn/visible/tested)=" .. sample.drawnChunks .. "/" .. sample.visibleChunks .. "/" .. sample.testedChunks
				.. " sections(drawn/visible/tested)=" .. sample.drawnSections .. "/" .. sample.visibleSections .. "/" .. sample.testedSections
				.. " meshes=" .. sample.meshes .. " vertices(drawn/candidate)=" .. sample.vertices .. "/" .. sample.verticesCandidate
				.. " lodCulled=" .. sample.verticesLodCulled .. " directionCulled=" .. sample.verticesDirectionCulled
				.. " triangles=" .. sample.triangles
				.. " directional=" .. tostring( sample.directionalDraw )
				.. " lod=" .. tostring( sample.lod ) .. "/" .. tostring( sample.lodApplied )
				.. " lodSections/meshes=" .. sample.lodSections .. "/" .. sample.lodMeshes
				.. " lodStart=" .. sample.lodStartChunks
				.. " occlusion=" .. tostring( sample.occlusionCull ) .. "/" .. tostring( sample.occlusionApplied ) )
			log( "perf." .. label .. " occlusion sections(culled/tested/reachable/component)="
				.. sample.occlusionCulledSections .. "/" .. sample.occlusionTestedSections .. "/"
				.. sample.occlusionReachableSections .. "/" .. sample.occlusionComponentSections
				.. " chunksCulled=" .. sample.occlusionCulledChunks )
			log( "perf." .. label .. " drawUs(current/p50/p95)=" .. perfNumber( sample.drawUs ) .. "/"
				.. perfNumber( percentile( ring, "drawUs", 0.50 ) ) .. "/" .. perfNumber( percentile( ring, "drawUs", 0.95 ) )
				.. " cullFrameUs(current/p50/p95)=" .. perfNumber( sample.cullUs ) .. "/"
				.. perfNumber( percentile( ring, "cullUs", 0.50 ) ) .. "/" .. perfNumber( percentile( ring, "cullUs", 0.95 ) ) )
			log( "perf." .. label .. " material=" .. sample.material .. " lightProfile=" .. sample.profile
				.. " lightTexture=" .. tostring( sample.lightTexture ) )
		else
			log( "perf." .. label .. " = no native draw samples" )
		end
	end

	local thinkRing = state.nativePerf.think
	local think = latestPerfSample( thinkRing )
	if think then
		log( "perf.upload samples=" .. thinkRing.count .. " bytes/frame(current/p50/p95)="
			.. perfNumber( think.bytesUploaded, 0 ) .. "/" .. perfNumber( percentile( thinkRing, "bytesUploaded", 0.50 ), 0 )
			.. "/" .. perfNumber( percentile( thinkRing, "bytesUploaded", 0.95 ), 0 )
			.. " uploadUs(current/p50/p95)=" .. perfNumber( think.uploadUs ) .. "/"
			.. perfNumber( percentile( thinkRing, "uploadUs", 0.50 ) ) .. "/" .. perfNumber( percentile( thinkRing, "uploadUs", 0.95 ) ) )
		log( "perf.queue avgPerResultUs(current/p50/p95)=" .. perfNumber( think.queueWaitAvgUs ) .. "/"
			.. perfNumber( percentile( thinkRing, "queueWaitAvgUs", 0.50 ) ) .. "/"
			.. perfNumber( percentile( thinkRing, "queueWaitAvgUs", 0.95 ) )
			.. " currentResults=" .. think.queueSamples )
	else
		log( "perf.upload/queue = unavailable (run mc_native_perf on, then reproduce the load)" )
	end
	log( "perf.alphatest = unavailable: combined in opaque native meshes" )
	log( "perf.shadow = unavailable: shadow caster does not use native DrawVisible" )
	log( "perf.gpu = unavailable: source_api_unavailable" )
end, nil, "Print bounded native render telemetry; on/off controls detailed upload and queue profiling" )

concommand.Add( "mc_native_status", function()
	local lines = {
		"backend        = " .. ( state.active and "NATIVE" or "LUA" ),
		"convar         = mc_native_mesh " .. ( CONVAR_ENABLED:GetBool() and "1" or "0" ),
		"simple greedy  = requested=" .. ( CONVAR_GREEDY:GetBool() and "1" or "0" )
			.. " effective=" .. ( effectiveNativeGreedy() and "1" or "0" ),
		"direction draw = requested=" .. ( CONVAR_DIRECTIONAL_DRAW:GetBool() and "1" or "0" ),
		"occlusion cull = requested=" .. ( CONVAR_OCCLUSION_CULL:GetBool() and "1" or "0" ),
		"native LOD     = requested=" .. ( CONVAR_LOD:GetBool() and "1" or "0" )
			.. " startChunks=" .. math.Round( math.Clamp( CONVAR_LOD_START:GetFloat(), 0, 4096 ), 2 ),
		"module loaded  = " .. tostring( mcmesh ~= nil ),
		"module probe   = done=" .. tostring( state.moduleProbeDone )
			.. " lockedLua=" .. tostring( state.moduleUnavailable ),
		"module reason  = " .. tostring( MC.NativeMeshModuleFailureReason or "" ),
		"startup reason = " .. tostring( state.startupFailureReason or "" ),
		"proxied chunks = " .. table.Count( state.proxied ),
		"block light    = " .. ( state.lightRunning and "running" or ( state.lightPending and "pending" or state.lightLastStatus ) )
			.. " ready=" .. tostring( state.lightReady ) .. " lastMS=" .. math.Round( state.lightLastMS or 0, 3 )
			.. " changedChunks=" .. state.lightLastChangedChunks .. " changedCells=" .. state.lightLastChangedCells,
		"light merge    = schedules=" .. state.lightScheduleCalls .. " coalesced=" .. state.lightCoalesced,
		"light profile  = " .. tostring( MC.CurrentMeshLightStyle and MC.CurrentMeshLightStyle() or "?" )
			.. ( gpuLightProfileActive() and " (gpu, native-ok)" or " (non-gpu, native blocked)" ),
	}
	if mcmesh and mcmesh.GetStats then
		local ok, s = pcall( mcmesh.GetStats )
		if ok and istable( s ) then
			for k, v in SortedPairs( s ) do
				lines[#lines + 1] = "native." .. k .. " = " .. tostring( v )
			end
		end
	end
	for pass = 0, 1 do
		local draw = state.nativeDrawLast[pass]
		if draw then
			local meta = state.nativeDrawMeta[pass] or {}
			lines[#lines + 1] = ( pass == 0 and "draw.opaque" or "draw.trans" )
				.. " = chunks(drawn/visible/tested) " .. tostring( draw.drawn or 0 ) .. "/"
				.. tostring( draw.visible or 0 ) .. "/" .. tostring( draw.tested or 0 )
				.. " sections(drawn/visible/tested)=" .. tostring( draw.sectionsDrawn or 0 ) .. "/"
				.. tostring( draw.sectionsVisible or 0 ) .. "/" .. tostring( draw.sectionsTested or 0 )
				.. " meshes=" .. tostring( draw.meshesDrawn or 0 )
				.. " vertices(drawn/candidate)=" .. tostring( draw.verticesDrawn or 0 ) .. "/"
				.. tostring( draw.verticesCandidate or 0 )
				.. " lodCulled=" .. tostring( draw.verticesLodCulled or 0 )
				.. " directionCulled=" .. tostring( draw.verticesDirectionCulled or 0 )
				.. " directional=" .. tostring( draw.directionalDraw == true )
				.. " lod=" .. tostring( draw.lod == true ) .. "/" .. tostring( draw.lodApplied == true )
				.. " lodSections/meshes=" .. tostring( draw.lodSectionsDrawn or 0 ) .. "/"
				.. tostring( draw.lodMeshesDrawn or 0 )
				.. " occlusion=" .. tostring( draw.occlusionCull == true ) .. "/" .. tostring( draw.occlusionApplied == true )
				.. " occlusionSections=" .. tostring( draw.sectionsOcclusionCulled or 0 ) .. "/"
				.. tostring( draw.sectionsOcclusionTested or 0 )
				.. " triangles=" .. tostring( draw.trianglesDrawn or 0 )
				.. " drawUs=" .. math.Round( tonumber( draw.nativeUs ) or 0, 2 )
				.. " cullUs=" .. math.Round( tonumber( draw.cullUs ) or 0, 2 )
				.. " material=" .. tostring( meta.material or "unknown" )
				.. " lightTexture=" .. tostring( meta.lightTexture == true )
		end
	end
	lines[#lines + 1] = "gpu timing     = unavailable (source_api_unavailable)"
	for _, l in ipairs( packProfileLines() ) do lines[#lines + 1] = l end
	for _, l in ipairs( lines ) do log( l ) end
end, nil, "Print MCSWEP native mesh backend state and module stats" )

concommand.Add( "mc_native_verify", function()
	local failures, waits = {}, {}
	local function fail( text ) failures[#failures + 1] = text end
	local function waitFor( text ) waits[#waits + 1] = text end
	if not state.active or state.failed then fail( "native backend inactive" ) end
	if ( MC.RENDER_SECTION_SIZE or 0 ) ~= 16 then fail( "render section size is not 16" ) end
	local worldChunks, worldMirrors, nativeChunks, duplicatedChunks, firstChunk = 0, 0, 0, 0
	for _, chunk in pairs( MC.World or {} ) do
		if chunk then
			worldMirrors = worldMirrors + 1
		end
		if chunk and ( chunk.count or 0 ) > 0 then
			worldChunks = worldChunks + 1
			firstChunk = firstChunk or chunk
			if chunk.nativeStateStorage then nativeChunks = nativeChunks + 1
			else duplicatedChunks = duplicatedChunks + 1 end
		end
	end
	local stats
	if mcmesh and isfunction( mcmesh.GetStats ) then
		local ok, result = pcall( mcmesh.GetStats )
		if ok and istable( result ) then stats = result else fail( "GetStats failed" ) end
	else fail( "GetStats unavailable" ) end
	if stats and tonumber( stats.mirrorChunks ) ~= worldMirrors then
		fail( "mirrorChunks=" .. tostring( stats.mirrorChunks ) .. " worldMirrors=" .. worldMirrors )
	end
	if duplicatedChunks > 0 then fail( duplicatedChunks .. " chunks still own Lua state storage" ) end
	if firstChunk then
		local blockBlob = MC.NativeChunkBackend.GetBlockLightChunk( firstChunk.cx, firstChunk.cy, firstChunk.cz )
		local skyBlob = MC.NativeChunkBackend.GetSkyLightChunk( firstChunk.cx, firstChunk.cy, firstChunk.cz )
		local expected = ( MC.CS or 16 ) * ( MC.CS or 16 ) * ( MC.CH or 32 )
		if not isstring( blockBlob ) or #blockBlob ~= expected then fail( "invalid block-light blob" ) end
		if not isstring( skyBlob ) or #skyBlob ~= expected then fail( "invalid sky-light blob" ) end
	end
	if state.lightPending or state.lightRunning or not state.lightReady then waitFor( "lighting worker not committed yet" ) end
	local verdict = #failures > 0 and "FAIL" or ( #waits > 0 and "WAIT" or "PASS" )
	log( "verify " .. verdict .. ": world=" .. worldChunks .. " native=" .. nativeChunks
		.. " lua=" .. duplicatedChunks .. " light=" .. ( state.lightReady and "ready" or "pending" ) )
	for _, text in ipairs( failures ) do log( "verify failure: " .. text ) end
	for _, text in ipairs( waits ) do log( "verify wait: " .. text ) end
end, nil, "Read-only verification of native chunk ownership, lighting blobs and backend state" )

concommand.Add( "mc_native_pack_profile", function( _, _, args )
	if args and string.lower( tostring( args[1] or "" ) ) == "reset" then
		state.packProfile = newPackProfile()
		log( "pack profiling reset" )
	end
	for _, l in ipairs( packProfileLines() ) do log( l ) end
end, nil, "Print Lua MCBD/chunk packing profile; pass 'reset' to clear counters" )

-- Intentionally block the render thread and keep the native worker pool fed
-- until every currently submitted dirty section has been committed.  This is
-- useful after a bulk map import when progressive appearance is less desirable
-- than one loading pause followed by a complete world.
concommand.Add( "mc_native_build_all", function()
	if not state.active or state.failed or not mcmesh or not isfunction( mcmesh.Think ) then
		return log( "build-all unavailable: native backend is not active" )
	end

	local started = SysTime()
	local calls, committed, pending = 0, 0, 0
	repeat
		local ok, result = pcall( mcmesh.Think, 100 )
		calls = calls + 1
		if not ok then
			state.failed = true
			log( "build-all Think error: " .. tostring( result ) )
			break
		end
		if not istable( result ) then
			state.failed = true
			log( "build-all rejected by native module" )
			break
		end
		if result.failed then
			state.failed = true
			log( "build-all native fault: " .. tostring( result.fault or "unknown" ) )
			break
		end
		committed = committed + ( tonumber( result.committed ) or 0 )
		pending = tonumber( result.pending ) or 0
	until pending <= 0

	if committed > 0 and MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty() end
	log( "build-all finished: calls=" .. calls .. " committed=" .. committed
		.. " pending=" .. pending .. " elapsed=" .. math.Round( ( SysTime() - started ) * 1000, 1 ) .. "ms" )
end, nil, "Block the current frame until all submitted native mesh sections are built" )

concommand.Add( "mc_native_light_rebuild", function()
	local result = MC.NativeChunkBackend and MC.NativeChunkBackend.RebuildBlockLight
		and MC.NativeChunkBackend.RebuildBlockLight() or false
	if not istable( result ) then return log( "native light rebuild unavailable" ) end
	log( "native light rebuild: " .. math.Round( tonumber( result.ms ) or 0, 3 ) .. "ms sources="
		.. tostring( result.sources or 0 ) .. " processed=" .. tostring( result.processed or 0 )
		.. " written=" .. tostring( result.written or 0 ) )
end, nil, "Rebuild native block light for profiling and A/B validation" )

concommand.Add( "mc_native_light_rebuild_async", function()
	local backend = MC.NativeChunkBackend
	if not backend or not backend.ScheduleBlockLightRebuild or not backend.ScheduleBlockLightRebuild( 0 ) then
		return log( "native async light rebuild unavailable" )
	end
	log( "native async light rebuild queued; use mc_native_status for completion state" )
end, nil, "Rebuild native block light on a snapshot worker and commit only if the world is unchanged" )

concommand.Add( "mc_native_light_compare", function( _, _, args )
	local limit = math.Clamp( math.floor( tonumber( args and args[1] ) or 4096 ), 1, 1000000 )
	local rebuild = MC.NativeChunkBackend and MC.NativeChunkBackend.RebuildBlockLight
		and MC.NativeChunkBackend.RebuildBlockLight() or false
	if not istable( rebuild ) then return log( "native light compare unavailable" ) end
	local sampled, mismatches, maxError = 0, 0, 0
	for _, chunk in pairs( MC.World or {} ) do
		local blob = MC.NativeChunkBackend.GetBlockLightChunk( chunk.cx, chunk.cy, chunk.cz )
		if isstring( blob ) and #blob == ( MC.CS or 16 ) * ( MC.CS or 16 ) * ( MC.CH or 32 ) then
			local cells = #blob
			local stride = math.max( 1, math.floor( cells / math.max( 1, limit - sampled ) ) )
			for li = 0, cells - 1, stride do
				local lx, ly, lz = MC.DecodeLocal( li )
				local bx, by, bz = chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly, chunk.cz * MC.CH + lz
				local luaBlock = select( 3, MC.SampleLighting( bx, by, bz, 0 ) ) or 0
				local nativeBlock = string.byte( blob, li + 1 ) or 0
				local err = math.abs( luaBlock - nativeBlock )
				if err > 0 then mismatches = mismatches + 1; maxError = math.max( maxError, err ) end
				sampled = sampled + 1
				if sampled >= limit then break end
			end
		end
		if sampled >= limit then break end
	end
	log( "native light compare: samples=" .. sampled .. " mismatches=" .. mismatches
		.. " maxError=" .. maxError .. " nativeMS=" .. math.Round( tonumber( rebuild.ms ) or 0, 3 ) )
end, nil, "Compare Lua and native block-light results; optional sample count" )
