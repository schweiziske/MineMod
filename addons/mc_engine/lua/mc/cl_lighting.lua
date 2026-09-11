--[[----------------------------------------------------------------------------
	MC : client-side Minecraft-style vertex lighting

	Lighting is stored as per-cell 0-15 block light values. Mesh building samples
	those values; propagation happens when
	chunks arrive or blocks change.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.LightEnabled = MC.LightEnabled or CreateClientConVar( "mc_light_enabled", "1", true, false,
	"Apply Minecraft-style vertex lighting to MC chunk meshes" )
MC.LightSkyLevel = nil
MC.LightAmbientMin = MC.LightAmbientMin or CreateClientConVar( "mc_light_ambient_min", "0", true, false,
	"Minimum brightness multiplier for MC vertex lighting" )
MC.LightPerfDebug = MC.LightPerfDebug or CreateClientConVar( "mc_light_perf_debug", "0", true, false,
	"Show and collect detailed MC lighting performance diagnostics" )
MC.LightPerfPrintBreak = MC.LightPerfPrintBreak or CreateClientConVar( "mc_light_perf_print_break", "0", true, false,
	"Print MC lighting performance diagnostics after a block is broken" )
MC.LightPerfPrintEach = MC.LightPerfPrintEach or CreateClientConVar( "mc_light_perf_print_each", "0", true, false,
	"Print one-line timing diagnostics for each MC lighting calculation" )

MC.LightBlockChunks = MC.LightBlockChunks or {}
-- Sky voxel light store lives in mc/render/cl_sky_flood.lua (MC.LightSkyChunks).
MC.LightSkyColumnTops = nil
MC.LightSourceCells = MC.LightSourceCells or {}
MC.LightChunkSources = MC.LightChunkSources or {}
MC.LightCellsReady = MC.LightCellsReady or false
MC.LightSourceIndexReady = MC.LightSourceIndexReady or false
MC.LightCellsSkyLevel = nil
MC.LightPerfStats = MC.LightPerfStats or {}

local function lightEnabled()
	return not MC.LightEnabled or MC.LightEnabled:GetBool()
end

local function ambientMin()
	local cv = MC.LightAmbientMin
	return math.Clamp( cv and cv:GetFloat() or 0, 0, 1 )
end

local function lightPerfDebugEnabled()
	return MC.LightPerfDebug and MC.LightPerfDebug:GetBool()
end

local function lightPerfPrintBreakEnabled()
	return MC.LightPerfPrintBreak and MC.LightPerfPrintBreak:GetBool()
end

local function lightPerfPrintEachEnabled()
	return MC.LightPerfPrintEach and MC.LightPerfPrintEach:GetBool()
end

local function perfNow()
	return SysTime and SysTime() or 0
end

local function perfMS( startTime )
	return math.Round( ( perfNow() - ( startTime or perfNow() ) ) * 1000, 3 )
end

local function perfBoundsText( minX, minY, minZ, maxX, maxY, maxZ )
	return string.format( "%d,%d,%d -> %d,%d,%d", minX or 0, minY or 0, minZ or 0, maxX or 0, maxY or 0, maxZ or 0 )
end

function MC.LightPerfTrace( kind, fields )
	if not lightPerfPrintEachEnabled() then return end
	fields = fields or {}
	local parts = { "[MC light calc][" .. tostring( kind or "?" ) .. "]" }
	local function add( name, value )
		if value ~= nil then parts[#parts + 1] = name .. "=" .. tostring( value ) end
	end
	add( "ms", fields.ms )
	add( "key", fields.key )
	add( "sec", fields.section )
	add( "changed", fields.changed )
	add( "dirtySec", fields.dirtySections )
	add( "inc", fields.inc )
	add( "dec", fields.dec )
	add( "src", fields.sources )
	add( "queue", fields.queued )
	add( "proc", fields.processed )
	add( "write", fields.written )
	add( "mode", fields.mode )
	add( "records", fields.records )
	add( "fallback", fields.fallback )
	add( "verts", fields.vertices )
	add( "faces", fields.faces )
	add( "meshes", fields.meshes )
	add( "blocks", fields.blocks )
	add( "emitted", fields.emitted )
	add( "blockCache", fields.blockCache )
	add( "blockRecolor", fields.blockRecolor )
	add( "fullBlocks", fields.fullBlocks )
	add( "shapeBlocks", fields.shapeBlocks )
	add( "modelBlocks", fields.modelBlocks )
	add( "liquidBlocks", fields.liquidBlocks )
	add( "crossBlocks", fields.crossBlocks )
	add( "opaqueVerts", fields.opaqueVerts )
	add( "transVerts", fields.translucentVerts )
	add( "prepMS", fields.prepMS )
	add( "indexMS", fields.indexMS )
	add( "loopMS", fields.loopMS )
	add( "emitMS", fields.emitMS )
	add( "fullMS", fields.fullMS )
	add( "shapeMS", fields.shapeMS )
	add( "modelMS", fields.modelMS )
	add( "liquidMS", fields.liquidMS )
	add( "crossMS", fields.crossMS )
	add( "flushMS", fields.flushMS )
	add( "meshNewMS", fields.meshNewMS )
	add( "buildTriMS", fields.buildTriMS )
	add( "destroyMS", fields.destroyMS )
	add( "commitMS", fields.commitMS )
	add( "flatMS", fields.flatMS )
	add( "recolorMS", fields.recolorMS )
	add( "samples", fields.samples )
	add( "sampleMS", fields.sampleMS )
	add( "ao", fields.ao )
	add( "aoMS", fields.aoMS )
	add( "cache", fields.cache )
	add( "aoCache", fields.aoCache )
	add( "bounds", fields.bounds )
	print( table.concat( parts, " " ) )
end

local function noteLightingDisabledSkip( reason, bx, by, bz )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastUpdateMS = 0
	stats.lastPropagateMS = 0
	stats.lastDirtyMarkMS = 0
	stats.lastLightChangedCells = 0
	stats.lastLightDirtySections = 0
	stats.lastPropagateSources = 0
	stats.lastPropagateQueued = 0
	stats.lastPropagateProcessed = 0
	stats.lastPropagateWritten = 0
	stats.lastBlockIncreaseProcessed = 0
	stats.lastBlockDecreaseProcessed = 0
	stats.lastUpdateDisabled = reason or true
	if bx and by and bz then
		stats.lastUpdateCell = string.format( "%d,%d,%d", bx, by, bz )
		stats.lastUpdateBounds = perfBoundsText( bx, by, bz, bx, by, bz )
		stats.lastPropagateBounds = stats.lastUpdateBounds
	end
end

local function noteLightSample( startTime )
	local stats = MC.LightPerfStats
	if not stats then return end
	stats.sampleCalls = ( stats.sampleCalls or 0 ) + 1
	stats.currentMeshSampleCalls = ( stats.currentMeshSampleCalls or 0 ) + 1
	if startTime then
		local ms = perfMS( startTime )
		stats.sampleMS = math.Round( ( stats.sampleMS or 0 ) + ms, 3 )
		stats.currentMeshSampleMS = math.Round( ( stats.currentMeshSampleMS or 0 ) + ms, 3 )
	end
end

local function noteLightAOSample( startTime )
	local stats = MC.LightPerfStats
	if not stats then return end
	stats.aoCalls = ( stats.aoCalls or 0 ) + 1
	stats.currentMeshAOCalls = ( stats.currentMeshAOCalls or 0 ) + 1
	if startTime then
		local ms = perfMS( startTime )
		stats.aoMS = math.Round( ( stats.aoMS or 0 ) + ms, 3 )
		stats.currentMeshAOMS = math.Round( ( stats.currentMeshAOMS or 0 ) + ms, 3 )
	end
end

function MC.LightPerfBeginMeshBuild( key, sectionIndex )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.currentMeshKey = key
	stats.currentMeshSection = sectionIndex or "full"
	stats.currentMeshSampleCalls = 0
	stats.currentMeshSampleMS = 0
	stats.currentMeshAOCalls = 0
	stats.currentMeshAOMS = 0
	stats.currentMeshDebugTimed = lightPerfDebugEnabled()
end

function MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastMeshKey = key
	stats.lastMeshSection = sectionIndex or "full"
	stats.lastMeshBuildMS = meshMS
	stats.lastMeshSampleCalls = stats.currentMeshSampleCalls or 0
	stats.lastMeshSampleMS = stats.currentMeshSampleMS or 0
	stats.lastMeshAOCalls = stats.currentMeshAOCalls or 0
	stats.lastMeshAOMS = stats.currentMeshAOMS or 0
	stats.lastMeshDebugTimed = stats.currentMeshDebugTimed == true
	MC.LightPerfTrace( "mesh", {
		ms = meshMS,
		key = key,
		section = sectionIndex or "full",
		mode = stats.lastMeshMode,
		records = stats.lastMeshRecords,
		fallback = stats.lastMeshFallback,
		vertices = stats.lastMeshVertices,
		faces = stats.lastMeshFaces,
		meshes = stats.lastMeshMeshes,
		blocks = stats.lastMeshBlocksVisited,
		emitted = stats.lastMeshBlocksRendered,
		blockCache = tostring( stats.lastMeshBlockCacheHits ) .. "/" .. tostring( stats.lastMeshBlockCacheMisses ),
		blockRecolor = stats.lastMeshBlockCacheRecolors,
		fullBlocks = stats.lastMeshFullCubeBlocks,
		shapeBlocks = stats.lastMeshShapeBlocks,
		modelBlocks = stats.lastMeshModelBlocks,
		liquidBlocks = stats.lastMeshLiquidBlocks,
		crossBlocks = stats.lastMeshCrossBlocks,
		opaqueVerts = stats.lastMeshOpaqueVerts,
		translucentVerts = stats.lastMeshTranslucentVerts,
		prepMS = stats.lastMeshPrepMS,
		indexMS = stats.lastMeshIndexMS,
		loopMS = stats.lastMeshLoopMS,
		emitMS = stats.lastMeshEmitMS,
		fullMS = stats.lastMeshFullCubeMS,
		shapeMS = stats.lastMeshShapeMS,
		modelMS = stats.lastMeshModelMS,
		liquidMS = stats.lastMeshLiquidMS,
		crossMS = stats.lastMeshCrossMS,
		flushMS = stats.lastMeshFlushMS,
		meshNewMS = stats.lastMeshMeshNewMS,
		buildTriMS = stats.lastMeshBuildTrianglesMS,
		destroyMS = stats.lastMeshDestroyMS,
		commitMS = stats.lastMeshCommitMS,
		flatMS = stats.lastMeshFlatMS,
		recolorMS = stats.lastMeshRecolorMS,
		samples = stats.lastMeshSampleCalls,
		sampleMS = stats.lastMeshSampleMS,
		ao = stats.lastMeshAOCalls,
		aoMS = stats.lastMeshAOMS,
		cache = tostring( stats.lastMeshLightCacheHits ) .. "/" .. tostring( stats.lastMeshLightCacheMisses ),
		aoCache = tostring( stats.lastMeshAOCacheHits ) .. "/" .. tostring( stats.lastMeshAOCacheMisses ),
	} )
end

local function cellKey( bx, by, bz )
	return MC.CellKey( bx, by, bz )
end

local function chunkKeyLoaded( key )
	if key == nil then return false end
	if MC.IsChunkLoaded then return MC.IsChunkLoaded( key ) end
	return MC.World and MC.World[key] ~= nil
end

local function lightChunkAvailable( chunk )
	return chunk and chunk.key and chunkKeyLoaded( chunk.key )
end

local function lightEmission( id )
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

local function lightOpacity( id, orient )
	if id == 0 then return 0 end
	return MC.BlockLightOpacity and MC.BlockLightOpacity( id, orient ) or 15
end

local function nativeBlockLightBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native and backend.IsActive and backend.IsActive()
	and backend.ScheduleBlockLightRebuild and backend.GetBlockLightAt then return backend end
	return nil
end

local function lightEmissionForState( stateId, bx, by, bz )
	return MC.BlockLightEmissionForState and MC.BlockLightEmissionForState( stateId, bx, by, bz ) or 0
end

local function lightOpacityForState( stateId, bx, by, bz )
	return MC.BlockLightOpacityForState and MC.BlockLightOpacityForState( stateId, bx, by, bz ) or 15
end

local function lightingGeometrySolidRenderState( id, orient )
	if id == nil or id == 0 then return false end
	local block = MC.Blocks and MC.Blocks[id]
	if block and ( block.transparent == true or block.solid == false ) then return false end
	if MC.BlockIsFullCube then return MC.BlockIsFullCube( id, orient ) == true end
	if block and block.shape then return false end
	return true
end

local function lightingGeometryDirtyState( id, orient )
	id = math.floor( tonumber( id ) or 0 )
	orient = math.floor( tonumber( orient ) or 0 )
	local block = MC.Blocks and MC.Blocks[id] or nil
	return
		lightEmission( id ),
		lightOpacity( id, orient ),
		lightingGeometrySolidRenderState( id, orient ),
		block and block.transparent == true or false,
		block and block.solid == false or false,
		block and block.shadeBrightness or nil
end

local function lightingGeometryDirtyNeeded( oldId, oldOrient, newId, newOrient )
	local oldEmission, oldOpacity, oldSolidRender, oldTransparent, oldNonSolid, oldShade =
		lightingGeometryDirtyState( oldId, oldOrient )
	local newEmission, newOpacity, newSolidRender, newTransparent, newNonSolid, newShade =
		lightingGeometryDirtyState( newId, newOrient )
	return oldEmission ~= newEmission
		or oldOpacity ~= newOpacity
		or oldSolidRender ~= newSolidRender
		or oldTransparent ~= newTransparent
		or oldNonSolid ~= newNonSolid
		or oldShade ~= newShade
end

local function chunkLoadedForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return chunkKeyLoaded( MC.ChunkKey( cx, cy, cz ) )
end

local function lightStoreForCell( store, bx, by, bz, create )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return nil, nil end
	local key = MC.ChunkKey( cx, cy, cz )
	local chunkStore = store[key]
	if not chunkStore and create then
		chunkStore = {}
		store[key] = chunkStore
	end
	return chunkStore, li, key
end

local function getStoredLight( store, bx, by, bz )
	local chunkStore, li = lightStoreForCell( store, bx, by, bz, false )
	return chunkStore and ( chunkStore[li] or 0 ) or 0
end

local function setStoredLight( store, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	local chunkStore, li = lightStoreForCell( store, bx, by, bz, level > 0 )
	if not chunkStore then return end
	chunkStore[li] = level > 0 and level or nil
end

local function lightOpacityAt( bx, by, bz )
	if not chunkLoadedForCell( bx, by, bz ) then return 15 end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	return lightOpacityForState( stateId, bx, by, bz )
end

local function lightPropagationCost( bx, by, bz )
	local opacity = lightOpacityAt( bx, by, bz )
	if opacity >= 15 then return 16 end
	return math.max( 1, opacity )
end

local function clearStoredLight()
	MC.LightBlockChunks = {}
	MC.LightSkyColumnTops = nil
	MC.LightCellsReady = false
	if MC.ClearSkyFlood then MC.ClearSkyFlood() end
end

local function clearGpuLightTextures()
	if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
end

function MC.ClearLightingCache()
	clearStoredLight()
	clearGpuLightTextures()
	MC.LightSkyColumnTops = nil
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	MC.LightSourceIndexReady = false
	-- Full Workshop/snapshot hydration owns the lighting bulk window. Do not
	-- enqueue work against the old or half-loaded world; EndLightingBulkLoad
	-- performs the single rebuild after every chunk has been committed.
	if ( tonumber( MC.LightingBulkLoadDepth ) or 0 ) <= 0 and MC.QueueAllSkyFlood then
		MC.QueueAllSkyFlood()
	end
end

function MC.MarkAllMeshesDirty()
	MC.ClearLightingCache()
	-- ClearLightingCache wipes the stored block-light field but re-queues only
	-- SKY flood; block light comes back solely through RebuildLightingCells.
	-- Without this every caller (mc_mesh_rebuild, the shader/light-texture
	-- toggles, rail/observer/piston visual reloads) blacked out all torch
	-- light until a manual mc_light_rebuild. Inside a lighting bulk load the
	-- rebuild is deferred: EndLightingBulkLoad performs it once at the end.
	if ( tonumber( MC.LightingBulkLoadDepth ) or 0 ) <= 0 and MC.RebuildLightingCells then
		MC.RebuildLightingCells()
	end
	local marked = 0
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.count and chunk.count > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
			marked = marked + 1
		end
	end
	return marked
end

concommand.Add( "mc_mesh_rebuild", function()
	local marked = MC.MarkAllMeshesDirty()
	print( string.format( "[MC mesh] queued full rebuild for %d chunks", marked or 0 ) )
end )

local function markLoadedMeshesDirty()
	clearGpuLightTextures()
	if MC.MarkAllBlockAnimationLightDirty then MC.MarkAllBlockAnimationLightDirty() end
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.count and chunk.count > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
		end
	end
end

function MC.ClearChunkLightSources( key )
	MC.LightSourceCells = MC.LightSourceCells or {}
	MC.LightChunkSources = MC.LightChunkSources or {}
	local old = MC.LightChunkSources[key]
	if old then
		for sourceKey in pairs( old ) do
			MC.LightSourceCells[sourceKey] = nil
		end
	end
	MC.LightChunkSources[key] = nil
	if MC.RemoveChunkLighting then
		MC.RemoveChunkLighting( key )
	else
		MC.LightCellsReady = false
	end
end

local function addLightSource( bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if level <= 0 then return end
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local chunkKey = MC.ChunkKey( cx, cy, cz )
	local sourceKey = cellKey( bx, by, bz )
	MC.LightSourceCells[sourceKey] = { bx = bx, by = by, bz = bz, level = level, chunkKey = chunkKey }
	MC.LightChunkSources[chunkKey] = MC.LightChunkSources[chunkKey] or {}
	MC.LightChunkSources[chunkKey][sourceKey] = true
end

local function indexChunkSources( chunk )
	if not chunk or not MC.ForEachBlockState then return end
	MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
		local emission = lightEmissionForState( stateId, bx, by, bz )
		if emission > 0 then addLightSource( bx, by, bz, emission ) end
	end )
end

function MC.IndexChunkLightSources( chunk )
	if not chunk or not chunk.key then return end
	if not lightEnabled() then
		MC.LightSourceIndexReady = false
		MC.LightCellsReady = false
		return
	end
	MC.ClearChunkLightSources( chunk.key )
	if nativeBlockLightBackend() then
		MC.LightSourceIndexReady = true
		return
	end
	indexChunkSources( chunk )
	MC.LightSourceIndexReady = true
	if ( MC.LightingBulkLoadDepth or 0 ) > 0 then return end
	if MC.UpdateLightingForChunkLoaded then
		MC.UpdateLightingForChunkLoaded( chunk )
	else
		MC.LightCellsReady = false
	end
end

function MC.ReindexAllLightingSources()
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	if nativeBlockLightBackend() then
		MC.LightSourceIndexReady = true
		MC.LightCellsReady = false
		return
	end
	for _, chunk in pairs( MC.World or {} ) do
		indexChunkSources( chunk )
	end
	MC.LightSourceIndexReady = true
	MC.LightCellsReady = false
end

local function ensureLightSourceIndex()
	if MC.LightSourceIndexReady then return end
	MC.ReindexAllLightingSources()
end

local NEIGHBORS = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

local LIGHT_DIRTY_MESH_NEIGHBOR_X = {}
local LIGHT_DIRTY_MESH_NEIGHBOR_Y = {}
local LIGHT_DIRTY_MESH_NEIGHBOR_Z = {}
local LIGHT_DIRTY_MESH_NEIGHBOR_COUNT = 0
do
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				LIGHT_DIRTY_MESH_NEIGHBOR_COUNT = LIGHT_DIRTY_MESH_NEIGHBOR_COUNT + 1
				LIGHT_DIRTY_MESH_NEIGHBOR_X[LIGHT_DIRTY_MESH_NEIGHBOR_COUNT] = dx
				LIGHT_DIRTY_MESH_NEIGHBOR_Y[LIGHT_DIRTY_MESH_NEIGHBOR_COUNT] = dy
				LIGHT_DIRTY_MESH_NEIGHBOR_Z[LIGHT_DIRTY_MESH_NEIGHBOR_COUNT] = dz
			end
		end
	end
end

local function newChangedLightCells()
	return { keys = {}, x = {}, y = {}, z = {}, count = 0 }
end

local function noteChangedLightCell( changed, bx, by, bz )
	if not changed then return end
	local key = cellKey( bx, by, bz )
	if changed.keys[key] then return end
	changed.keys[key] = true
	changed.count = changed.count + 1
	changed.x[changed.count] = bx
	changed.y[changed.count] = by
	changed.z[changed.count] = bz
end

local function setBlockLightChanged( changed, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	local loaded = chunkLoadedForCell( bx, by, bz )
	if level > 0 and not loaded then return false end
	if getStoredLight( MC.LightBlockChunks, bx, by, bz ) == level then return false end
	setStoredLight( MC.LightBlockChunks, bx, by, bz, level )
	-- Always note changed cells for GPU light texture halo updates, even if this cell's chunk is unloaded
	-- (neighbor chunks may be loaded and need their halo texels refreshed)
	noteChangedLightCell( changed, bx, by, bz )
	return true
end

local function newLightQueue()
	return { head = 1, tail = 0, x = {}, y = {}, z = {}, level = {} }
end

local function pushLightQueue( q, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if level <= 0 then return end
	local tail = q.tail + 1
	q.tail = tail
	q.x[tail], q.y[tail], q.z[tail], q.level[tail] = bx, by, bz, level
end

local function popLightQueue( q )
	local head = q.head
	if head > q.tail then return nil end
	q.head = head + 1
	local bx, by, bz, level = q.x[head], q.y[head], q.z[head], q.level[head]
	q.x[head], q.y[head], q.z[head], q.level[head] = nil, nil, nil, nil
	return bx, by, bz, level
end

local function lightQueueCount( q )
	return q and q.tail or 0
end

local function runLightIncreaseQueue( q, changed )
	local processed = 0
	while q.head <= q.tail do
		local bx, by, bz, level = popLightQueue( q )
		-- The stored-value check drops phantom re-seeds: the decrease wave
		-- queues equal-or-brighter neighbors as "another source's light", but
		-- with two overlapping light fields many equal-level neighbor pairs
		-- belong to the REMOVED source and get zeroed by another wave path
		-- after being queued. Without this check the increase pass would
		-- re-flood light out of a now-dark cell — the classic two-torch
		-- overlap residue.
		if bx and chunkLoadedForCell( bx, by, bz )
		and getStoredLight( MC.LightBlockChunks, bx, by, bz ) >= level then
			processed = processed + 1
			if level > 1 then
				for i = 1, #NEIGHBORS do
					local off = NEIGHBORS[i]
					local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
					local nextLevel = level - lightPropagationCost( nx, ny, nz )
					if nextLevel > 0
					and chunkLoadedForCell( nx, ny, nz )
					and getStoredLight( MC.LightBlockChunks, nx, ny, nz ) < nextLevel then
						setBlockLightChanged( changed, nx, ny, nz, nextLevel )
						pushLightQueue( q, nx, ny, nz, nextLevel )
					end
				end
			end
		end
	end
	return processed
end

local function runLightDecreaseQueue( removeQ, addQ, changed )
	local processed = 0
	ensureLightSourceIndex()
	local sources = MC.LightSourceCells
	while removeQ.head <= removeQ.tail do
		local bx, by, bz, oldLevel = popLightQueue( removeQ )
		if bx then
			processed = processed + 1
			for i = 1, #NEIGHBORS do
				local off = NEIGHBORS[i]
				local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
				-- No chunkLoadedForCell gate here: stored block light can
				-- outlive its chunk (a lone torch creates the chunk, removing
				-- it deletes the chunk BEFORE this flood runs). The removal
				-- wave must chase those orphaned values, otherwise the
				-- surviving frontier re-seeds the region and the glow sticks.
				local neighborLevel = getStoredLight( MC.LightBlockChunks, nx, ny, nz )
				if neighborLevel > 0 and neighborLevel < oldLevel then
					-- A dimmer cell engulfed by the removed field may itself be
					-- an emitter (torch next to broken glowstone). Flattening it
					-- to 0 lost that source forever: nothing later re-seeded it,
					-- because the post-wave re-seed only looks at stored values
					-- (all zero by then) around the CHANGED cell. Keep its own
					-- emission as the floor and re-flood from it in the increase
					-- pass; the removal wave still chases the brighter removed
					-- contribution past it.
					local source = sources and sources[cellKey( nx, ny, nz )]
					local emission = source and source.level or 0
					if emission > 0 and chunkLoadedForCell( nx, ny, nz ) then
						if emission < neighborLevel then
							setBlockLightChanged( changed, nx, ny, nz, emission )
							pushLightQueue( removeQ, nx, ny, nz, neighborLevel )
						end
						pushLightQueue( addQ, nx, ny, nz, emission )
					else
						setBlockLightChanged( changed, nx, ny, nz, 0 )
						pushLightQueue( removeQ, nx, ny, nz, neighborLevel )
					end
				elseif neighborLevel >= oldLevel then
					pushLightQueue( addQ, nx, ny, nz, neighborLevel )
				end
			end
		end
	end
	return processed
end

local function seedNeighborLight( q, bx, by, bz )
	for i = 1, #NEIGHBORS do
		local off = NEIGHBORS[i]
		local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
		local level = getStoredLight( MC.LightBlockChunks, nx, ny, nz )
		if level > 0 then pushLightQueue( q, nx, ny, nz, level ) end
	end
end

local function clearChunkStoredBlockLightToQueue( key, changed, removeQ )
	local store = MC.LightBlockChunks and MC.LightBlockChunks[key]
	if not store then return 0 end
	if not MC.ChunkKeyToCoords or not MC.DecodeLocal then
		MC.LightBlockChunks[key] = nil
		return 0
	end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then
		MC.LightBlockChunks[key] = nil
		return 0
	end
	local cells = {}
	for li, level in pairs( store ) do
		level = math.floor( tonumber( level ) or 0 )
		if level > 0 and MC.LocalIndexInRange( li ) then
			cells[#cells + 1] = { li, level }
		end
	end
	local baseX, baseY, baseZ = cx * MC.CS, cy * MC.CS, cz * MC.CH
	for i = 1, #cells do
		local li, level = cells[i][1], cells[i][2]
		local lx, ly, lz = MC.DecodeLocal( li )
		local bx, by, bz = baseX + lx, baseY + ly, baseZ + lz
		setBlockLightChanged( changed, bx, by, bz, 0 )
		pushLightQueue( removeQ, bx, by, bz, level )
	end
	MC.LightBlockChunks[key] = nil
	return #cells
end

local function seedStoredLight( q, bx, by, bz )
	local level = getStoredLight( MC.LightBlockChunks, bx, by, bz )
	if level > 1 then pushLightQueue( q, bx, by, bz, level ) end
end

local function seedChunkBorderLight( q, chunk )
	if not chunk then return end
	local minX, minY, minZ = chunk.cx * MC.CS, chunk.cy * MC.CS, chunk.cz * MC.CH
	local maxX, maxY, maxZ = minX + MC.CS - 1, minY + MC.CS - 1, minZ + MC.CH - 1
	for y = minY, maxY do
		for x = minX, maxX do
			seedStoredLight( q, x, y, minZ - 1 )
			seedStoredLight( q, x, y, maxZ + 1 )
		end
	end
	for z = minZ, maxZ do
		for y = minY, maxY do
			seedStoredLight( q, minX - 1, y, z )
			seedStoredLight( q, maxX + 1, y, z )
		end
		for x = minX, maxX do
			seedStoredLight( q, x, minY - 1, z )
			seedStoredLight( q, x, maxY + 1, z )
		end
	end
end

local function seedChunkLightSources( q, changed, chunk )
	local sources = MC.LightChunkSources and MC.LightChunkSources[chunk and chunk.key or ""]
	local count = 0
	for sourceKey in pairs( sources or {} ) do
		local source = MC.LightSourceCells and MC.LightSourceCells[sourceKey]
		if source and source.level and source.level > 0 then
			if setBlockLightChanged( changed, source.bx, source.by, source.bz, source.level ) then
				count = count + 1
			end
			pushLightQueue( q, source.bx, source.by, source.bz, source.level )
		end
	end
	return count
end

local function finishChunkLightQueues( perfStart, changed, removeQ, addQ, sourceCount, boundsText, traceKind )
	local decProcessed = runLightDecreaseQueue( removeQ, addQ, changed )
	local incProcessed = runLightIncreaseQueue( addQ, changed )
	local dirtySections = MC.MarkLightSectionsDirtyForChangedCells and MC.MarkLightSectionsDirtyForChangedCells( changed ) or 0
	MC.LightCellsReady = true
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastPropagateMS = perfMS( perfStart )
	stats.lastPropagateSources = sourceCount or 0
	stats.lastPropagateQueued = lightQueueCount( removeQ ) + lightQueueCount( addQ )
	stats.lastPropagateProcessed = decProcessed + incProcessed
	stats.lastPropagateWritten = changed.count
	stats.lastPropagateBounds = boundsText or "chunk"
	stats.lastBlockIncreaseProcessed = incProcessed
	stats.lastBlockDecreaseProcessed = decProcessed
	stats.lastLightChangedCells = changed.count
	stats.lastLightDirtySections = dirtySections
	stats.lastUpdateMS = stats.lastPropagateMS
	stats.lastUpdateRadius = 0
	stats.lastUpdateBounds = stats.lastPropagateBounds
	stats.lastDirtyMarkMS = 0
	MC.LightPerfTrace( traceKind or "chunk_light", {
		ms = stats.lastPropagateMS,
		changed = changed.count,
		dirtySections = dirtySections,
		inc = incProcessed,
		dec = decProcessed,
		sources = sourceCount or 0,
		queued = stats.lastPropagateQueued,
		processed = stats.lastPropagateProcessed,
		written = stats.lastPropagateWritten,
		bounds = stats.lastPropagateBounds,
	} )
	return changed.count, dirtySections
end

function MC.RemoveChunkLighting( key )
	if not lightEnabled() then
		noteLightingDisabledSkip( "remove_chunk" )
		return 0, 0
	end
	local perfStart = perfNow()
	local changed = newChangedLightCells()
	local removeQ = newLightQueue()
	local addQ = newLightQueue()
	clearChunkStoredBlockLightToQueue( key, changed, removeQ )
	return finishChunkLightQueues( perfStart, changed, removeQ, addQ, 0, "remove:" .. tostring( key ), "remove_chunk" )
end

function MC.UpdateLightingForChunkLoaded( chunk )
	if not chunk or not chunk.key then return 0, 0 end
	if MC.NoteSkyColumnChunkLoaded then
		MC.NoteSkyColumnChunkLoaded( chunk )
	end
	if not lightEnabled() then
		noteLightingDisabledSkip( "chunk_loaded" )
		return 0, 0
	end
	local perfStart = perfNow()
	local changed = newChangedLightCells()
	local removeQ = newLightQueue()
	local addQ = newLightQueue()
	clearChunkStoredBlockLightToQueue( chunk.key, changed, removeQ )
	local sourceCount = 0
	if lightChunkAvailable( chunk ) then
		sourceCount = seedChunkLightSources( addQ, changed, chunk )
		seedChunkBorderLight( addQ, chunk )
	end
	local changedCount, dirtySections = finishChunkLightQueues( perfStart, changed, removeQ, addQ, sourceCount, tostring( chunk.key ), "chunk_loaded" )
	return changedCount, dirtySections
end

-- Partial streaming batches preserve the global source index and propagated
-- field. Old touched chunks are removed into one decrease queue, then all new
-- sources and loaded borders seed one combined increase. This is also used by
-- progressive unload frames, avoiding one flood per chunk.
function MC.BeginPartialLightingBatch( oldChunks )
	local batch = { started = perfNow(), changed = newChangedLightCells(), removeQ = newLightQueue(), addQ = newLightQueue(), old = {}, sources = 0 }
	local native = nativeBlockLightBackend()
	batch.native = native
	for _, chunk in ipairs( oldChunks or {} ) do
		local key = chunk and chunk.key
		if key and not batch.old[key] then
			batch.old[key] = true
			if MC.NoteSkyColumnChunkUnloaded then MC.NoteSkyColumnChunkUnloaded( chunk.cx, chunk.cy, chunk.cz ) end
			if not native then clearChunkStoredBlockLightToQueue( key, batch.changed, batch.removeQ ) end
			local sources = MC.LightChunkSources and MC.LightChunkSources[key]
			for sourceKey in pairs( sources or {} ) do MC.LightSourceCells[sourceKey] = nil end
			if MC.LightChunkSources then MC.LightChunkSources[key] = nil end
		end
	end
	return batch
end

function MC.CancelPartialLightingBatch( batch )
	if not batch then return end
	-- The caller resets the client world after an internal commit failure. Keep
	-- this hook explicit so no streaming rate-limit mode can leak into later edits.
	MC.PartialLightingRateLimited = false
end

function MC.EndPartialLightingBatch( batch, newChunks, rateLimited )
	if not batch then return 0, 0 end
	local native = batch.native or nativeBlockLightBackend()
	for _, chunk in ipairs( newChunks or {} ) do
		if chunk and chunk.key then
			if MC.NoteSkyColumnChunkLoaded then MC.NoteSkyColumnChunkLoaded( chunk ) end
			if not native then
				indexChunkSources( chunk )
				batch.sources = batch.sources + seedChunkLightSources( batch.addQ, batch.changed, chunk )
				seedChunkBorderLight( batch.addQ, chunk )
			end
		end
	end
	MC.LightSourceIndexReady = true
	if native then
		native.ScheduleBlockLightRebuild( 0.02 )
		MC.LightBlockChunks = {}
		MC.LightCellsReady = true
		return 0, 0
	end
	MC.PartialLightingRateLimited = rateLimited == true
	local changed, sections = finishChunkLightQueues( batch.started, batch.changed, batch.removeQ, batch.addQ,
		batch.sources, "partial:" .. tostring( table.Count( batch.old ) ), "partial_batch" )
	MC.PartialLightingRateLimited = false
	return changed, sections
end

function MC.MarkLightSectionsDirtyForChangedCells( changed )
	local dirty = {}
	local dirtyCells = {}
	local dirtyCount = 0
	local count = changed and changed.count or 0
	local xs, ys, zs = changed and changed.x or {}, changed and changed.y or {}, changed and changed.z or {}
	if MC.UsingGpuLightTexture and MC.UsingGpuLightTexture()
	and MC.MarkGpuChunkLightTextureDirtyForChangedCells then
		local dirtyChunks = MC.MarkGpuChunkLightTextureDirtyForChangedCells( changed )
		local stats = MC.LightPerfStats or {}
		MC.LightPerfStats = stats
		stats.lastGpuLightTextureDirtyChunks = dirtyChunks
		stats.lastGpuLightTextureDirtyCells = count
		return 0
	end
	local chunkKey = MC.ChunkKey
	local world = MC.World
	local meshDirty = MC.MeshDirty
	local meshLightDirty = MC.MeshLightDirty
	local markLightSectionDirty = MC.MarkLightSectionDirty
	local meshBlockLightDirty = MC.MeshBlockLightDirty
	local cs = MC.CS or 16
	local ch = MC.CH or 32
	local cs2 = cs * cs
	local chunkVolume = cs2 * ch
	local renderSectionSize = 8
	local renderSectionsXY = math.ceil( cs / renderSectionSize )
	local mathFloor = math.floor
	if not chunkKey or not meshLightDirty or not meshBlockLightDirty then return 0 end
	for c = 1, count do
		local bx, by, bz = xs[c], ys[c], zs[c]
		for i = 1, LIGHT_DIRTY_MESH_NEIGHBOR_COUNT do
			local dbx = bx + LIGHT_DIRTY_MESH_NEIGHBOR_X[i]
			local dby = by + LIGHT_DIRTY_MESH_NEIGHBOR_Y[i]
			local dbz = bz + LIGHT_DIRTY_MESH_NEIGHBOR_Z[i]
			local cx = mathFloor( dbx / cs )
			local cy = mathFloor( dby / cs )
			local cz = mathFloor( dbz / ch )
			local lx = dbx - cx * cs
			local ly = dby - cy * cs
			local lz = dbz - cz * ch
			local li = lx + ly * cs + lz * cs2
			local key = chunkKey( cx, cy, cz )
			if world and world[key] then
				local cellKey = key * chunkVolume + li
				if not dirtyCells[cellKey] then
					dirtyCells[cellKey] = true
					local sx = mathFloor( lx / renderSectionSize )
					local sy = mathFloor( ly / renderSectionSize )
					local sz = mathFloor( lz / renderSectionSize )
					local sectionIndex = sx + sy * renderSectionsXY + sz * renderSectionsXY * renderSectionsXY + 1
					local lightDirtySections = meshBlockLightDirty[key]
					if not lightDirtySections then
						lightDirtySections = {}
						meshBlockLightDirty[key] = lightDirtySections
					end
					local lightDirtySection = lightDirtySections[sectionIndex]
					if not lightDirtySection then
						lightDirtySection = {}
						lightDirtySections[sectionIndex] = lightDirtySection
					end
					lightDirtySection[li] = true
					if markLightSectionDirty then
						markLightSectionDirty( key, sectionIndex, MC.PartialLightingRateLimited == true )
					elseif not ( meshDirty and meshDirty[key] == true ) then
						local sections = meshLightDirty[key]
						MC.MeshLightDirtyRateLimited = MC.MeshLightDirtyRateLimited or {}
						if not sections then
							sections = {}
							meshLightDirty[key] = sections
							MC.MeshLightDirtyRateLimited[key] = MC.PartialLightingRateLimited == true and true or nil
						elseif not MC.PartialLightingRateLimited then
							MC.MeshLightDirtyRateLimited[key] = nil
						end
						sections[sectionIndex] = true
					end
					local dirtyKey = key * 32 + sectionIndex
					if not dirty[dirtyKey] then
						dirty[dirtyKey] = true
						dirtyCount = dirtyCount + 1
					end
				end
			end
		end
	end
	if not markLightSectionDirty and dirtyCount > 0 and MC.WakeLazyMeshBuilder then MC.WakeLazyMeshBuilder() end
	return dirtyCount
end

local function markLightSectionsInBounds( minBX, minBY, minBZ, maxBX, maxBY, maxBZ )
	local changed = newChangedLightCells()
	for bz = minBZ, maxBZ do
		for by = minBY, maxBY do
			for bx = minBX, maxBX do
				noteChangedLightCell( changed, bx, by, bz )
			end
		end
	end
	return MC.MarkLightSectionsDirtyForChangedCells( changed ), changed.count
end

local function rebuildBlockLightCells()
	local perfStart = perfNow()
	local changed = newChangedLightCells()
	local addQ = newLightQueue()
	local sources = 0
	MC.LightBlockChunks = {}
	for _, source in pairs( MC.LightSourceCells or {} ) do
		if source.level and source.level > 0 and chunkLoadedForCell( source.bx, source.by, source.bz ) then
			sources = sources + 1
			setBlockLightChanged( changed, source.bx, source.by, source.bz, source.level )
			pushLightQueue( addQ, source.bx, source.by, source.bz, source.level )
		end
	end
	local incProcessed = runLightIncreaseQueue( addQ, changed )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastPropagateMS = perfMS( perfStart )
	stats.lastPropagateSources = sources
	stats.lastPropagateQueued = lightQueueCount( addQ )
	stats.lastPropagateProcessed = incProcessed
	stats.lastPropagateWritten = changed.count
	stats.lastPropagateBounds = "full"
	stats.lastBlockIncreaseProcessed = incProcessed
	stats.lastBlockDecreaseProcessed = 0
	stats.lastLightChangedCells = changed.count
	stats.lastLightDirtySections = 0
	MC.LightPerfTrace( "block_rebuild", {
		ms = stats.lastPropagateMS,
		changed = changed.count,
		inc = incProcessed,
		dec = 0,
		sources = sources,
		queued = stats.lastPropagateQueued,
		processed = stats.lastPropagateProcessed,
		written = stats.lastPropagateWritten,
		bounds = "full",
	} )
	return changed
end

local function loadedWorldBounds()
	local minX, minY, minZ, maxX, maxY, maxZ
	for _, chunk in pairs( MC.World or {} ) do
		if chunk.count and chunk.count > 0 then
			local x0, y0, z0 = chunk.cx * MC.CS, chunk.cy * MC.CS, chunk.cz * MC.CH
			local x1, y1, z1 = x0 + MC.CS - 1, y0 + MC.CS - 1, z0 + MC.CH - 1
			minX = minX and math.min( minX, x0 ) or x0
			minY = minY and math.min( minY, y0 ) or y0
			minZ = minZ and math.min( minZ, z0 ) or z0
			maxX = maxX and math.max( maxX, x1 ) or x1
			maxY = maxY and math.max( maxY, y1 ) or y1
			maxZ = maxZ and math.max( maxZ, z1 ) or z1
		end
	end
	return minX, minY, minZ, maxX, maxY, maxZ
end

function MC.RebuildLightingCells()
	local perfStart = SysTime()
	ensureLightSourceIndex()
	local native = nativeBlockLightBackend()
	-- Meshes can query sky columns while a snapshot is still hydrating. Rebuild
	-- both the column index and tops against the final world, not just the flood.
	if MC.ClearSkyColumnCache then
		MC.ClearSkyColumnCache()
	else
		if MC.ClearSkyFlood then MC.ClearSkyFlood() end
		if not native and MC.QueueAllSkyFlood then MC.QueueAllSkyFlood() end
	end
	local minX, minY, minZ, maxX, maxY, maxZ = loadedWorldBounds()
	if native then
		native.ScheduleBlockLightRebuild( 0 )
		MC.LightBlockChunks = {}
	else
		rebuildBlockLightCells()
	end
	MC.LightCellsReady = true
	-- Implicit sky values (including opaque cells becoming zero) have no stored
	-- change notification. Refresh existing tiles too, under the mesh budget.
	if MC.QueueAllGpuChunkLightTextureRefresh then MC.QueueAllGpuChunkLightTextureRefresh() end
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastRebuildMS = perfMS( perfStart )
	stats.lastRebuildBounds = minX and perfBoundsText( minX, minY, minZ, maxX, maxY, maxZ ) or "empty"
	MC.LightPerfTrace( "rebuild", {
		ms = stats.lastRebuildMS,
		changed = stats.lastLightChangedCells,
		dirtySections = stats.lastLightDirtySections,
		inc = stats.lastBlockIncreaseProcessed,
		dec = stats.lastBlockDecreaseProcessed,
		bounds = stats.lastRebuildBounds,
	} )
end

function MC.UpdateLightingCellsAroundCell( bx, by, bz, radius, rateLimited )
	if not lightEnabled() then
		noteLightingDisabledSkip( "around_cell", bx, by, bz )
		return 0, 0
	end
	local native = nativeBlockLightBackend()
	if native then native.ScheduleBlockLightRebuild( 0.05 ); return 0, 0 end
	local perfStart = SysTime()
	ensureLightSourceIndex()
	local changed = newChangedLightCells()
	local addQ = newLightQueue()
	seedNeighborLight( addQ, bx, by, bz )
	local incProcessed = runLightIncreaseQueue( addQ, changed )
	MC.LightCellsReady = true
	local dirtySections = MC.MarkLightSectionsDirtyForChangedCells( changed )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastUpdateMS = perfMS( perfStart )
	stats.lastUpdateRadius = 0
	stats.lastUpdateCell = string.format( "%d,%d,%d", bx, by, bz )
	stats.lastUpdateBounds = perfBoundsText( bx, by, bz, bx, by, bz )
	stats.lastDirtyMarkMS = 0
	stats.lastLightChangedCells = changed.count
	stats.lastLightDirtySections = dirtySections
	stats.lastBlockIncreaseProcessed = incProcessed
	stats.lastBlockDecreaseProcessed = 0
	MC.LightPerfTrace( "around_cell", {
		ms = stats.lastUpdateMS,
		changed = changed.count,
		dirtySections = dirtySections,
		inc = incProcessed,
		dec = 0,
		bounds = stats.lastUpdateBounds,
	} )
end

function MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )
	if nativeBlockLightBackend() then return end
	ensureLightSourceIndex()
	local key = cellKey( bx, by, bz )
	local old = MC.LightSourceCells[key]
	if old then
		local chunkSources = MC.LightChunkSources[old.chunkKey]
		if chunkSources then chunkSources[key] = nil end
		MC.LightSourceCells[key] = nil
	end
	addLightSource( bx, by, bz, lightEmission( newId ) )
end

function MC.BeginLightingBulkLoad()
	MC.LightingBulkLoadDepth = ( MC.LightingBulkLoadDepth or 0 ) + 1
	if MC.LightingBulkLoadDepth == 1 then
		MC.LightSourceCells = {}
		MC.LightChunkSources = {}
		MC.LightSourceIndexReady = true
		MC.LightCellsReady = false
		-- Snapshot reset replaces MC.World without sending per-chunk unload/load
		-- notifications. Drop the old column index now so the final sky reflood
		-- rebuilds it from the newly hydrated world instead of reusing stale tops.
		if MC.ClearSkyColumnCache then
			MC.ClearSkyColumnCache()
		else
			if MC.ClearSkyFlood then MC.ClearSkyFlood() end
			if MC.QueueAllSkyFlood then MC.QueueAllSkyFlood() end
		end
	end
end

function MC.EndLightingBulkLoad()
	local depth = math.max( 0, ( MC.LightingBulkLoadDepth or 0 ) - 1 )
	MC.LightingBulkLoadDepth = depth
	if depth > 0 then return end
	if MC.RebuildLightingCells then MC.RebuildLightingCells() end
end

function MC.CancelLightingBulkLoad()
	MC.LightingBulkLoadDepth = 0
	MC.LightSourceIndexReady = false
	MC.LightCellsReady = false
end

function MC.NoteLightingStateCellChanged( bx, by, bz, newStateId )
	if nativeBlockLightBackend() then return end
	ensureLightSourceIndex()
	local key = cellKey( bx, by, bz )
	local old = MC.LightSourceCells[key]
	if old then
		local chunkSources = MC.LightChunkSources[old.chunkKey]
		if chunkSources then chunkSources[key] = nil end
		MC.LightSourceCells[key] = nil
	end
	addLightSource( bx, by, bz, lightEmissionForState( newStateId, bx, by, bz ) )
end

function MC.MarkLightingDirtyAroundCell( bx, by, bz, radius, rateLimited )
	MC.UpdateLightingCellsAroundCell( bx, by, bz, radius, rateLimited )
end

function MC.UpdateBlockLightForChange( bx, by, bz, oldEmission, newEmission, oldOpacity, newOpacity )
	if not lightEnabled() then
		noteLightingDisabledSkip( "block_change", bx, by, bz )
		return 0, 0
	end
	local native = nativeBlockLightBackend()
	if native then
		-- ABI 5+ SetCell already updated block + sky fields synchronously in C++
		-- and returned exact dirty masks. Do not enqueue a second full-world job.
		return 0, 0
	end
	local perfStart = perfNow()
	local changed = newChangedLightCells()
	local removeQ = newLightQueue()
	local addQ = newLightQueue()
	local oldStored = getStoredLight( MC.LightBlockChunks, bx, by, bz )

	if oldStored > 0 then
		setBlockLightChanged( changed, bx, by, bz, 0 )
		pushLightQueue( removeQ, bx, by, bz, oldStored )
	end

	local decProcessed = runLightDecreaseQueue( removeQ, addQ, changed )

	if newEmission and newEmission > 0 then
		if setBlockLightChanged( changed, bx, by, bz, newEmission ) then
			pushLightQueue( addQ, bx, by, bz, newEmission )
		else
			pushLightQueue( addQ, bx, by, bz, math.max( newEmission, getStoredLight( MC.LightBlockChunks, bx, by, bz ) ) )
		end
	end

	seedNeighborLight( addQ, bx, by, bz )
	local incProcessed = runLightIncreaseQueue( addQ, changed )
	local dirtySections = MC.MarkLightSectionsDirtyForChangedCells( changed )

	MC.LightCellsReady = true

	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastPropagateMS = perfMS( perfStart )
	stats.lastPropagateSources = ( newEmission and newEmission > 0 ) and 1 or 0
	stats.lastPropagateQueued = lightQueueCount( removeQ ) + lightQueueCount( addQ )
	stats.lastPropagateProcessed = decProcessed + incProcessed
	stats.lastPropagateWritten = changed.count
	stats.lastPropagateBounds = perfBoundsText( bx, by, bz, bx, by, bz )
	stats.lastBlockIncreaseProcessed = incProcessed
	stats.lastBlockDecreaseProcessed = decProcessed
	stats.lastLightChangedCells = changed.count
	stats.lastLightDirtySections = dirtySections
	stats.lastUpdateMS = stats.lastPropagateMS
	stats.lastUpdateRadius = 0
	stats.lastUpdateCell = string.format( "%d,%d,%d", bx, by, bz )
	stats.lastUpdateBounds = stats.lastPropagateBounds
	stats.lastDirtyMarkMS = 0
	MC.LightPerfTrace( "block_change", {
		ms = stats.lastPropagateMS,
		changed = changed.count,
		dirtySections = dirtySections,
		inc = incProcessed,
		dec = decProcessed,
		sources = stats.lastPropagateSources,
		queued = stats.lastPropagateQueued,
		processed = stats.lastPropagateProcessed,
		written = stats.lastPropagateWritten,
		bounds = stats.lastPropagateBounds,
	} )
	return changed.count, dirtySections
end

function MC.MarkLightingDirtyForChange( bx, by, bz, oldId, oldOrient, newId, newOrient, rateLimited )
	if not lightEnabled() then
		noteLightingDisabledSkip( "change_dirty", bx, by, bz )
		return 0, 0
	end
	oldId, newId = math.floor( tonumber( oldId ) or 0 ), math.floor( tonumber( newId ) or 0 )
	oldOrient, newOrient = math.floor( tonumber( oldOrient ) or 0 ), math.floor( tonumber( newOrient ) or 0 )

	local oldEmission, newEmission = lightEmission( oldId ), lightEmission( newId )
	local oldOpacity, newOpacity = lightOpacity( oldId, oldOrient ), lightOpacity( newId, newOrient )
	MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )
	if MC.NoteSkyColumnBlockChange then
		MC.NoteSkyColumnBlockChange( bx, by, bz, oldOpacity, newOpacity )
	end
	-- Sky flood runs after the column tops updated above (exposure reads must
	-- see the new top). Covers opacity changes that never flip a column top
	-- (walls, cave ceilings) — the flipped spans re-flood from the note above.
	if MC.UpdateSkyLightForBlockChange then
		MC.UpdateSkyLightForBlockChange( bx, by, bz, oldOpacity, newOpacity )
	end
	if oldEmission ~= newEmission or oldOpacity ~= newOpacity then
		-- Both emission and opacity changes can alter the propagated field far
		-- beyond the edited cell, so every actually changed light cell must
		-- invalidate its CPU mesh section or GPU light-texture texel.
		MC.UpdateBlockLightForChange( bx, by, bz, oldEmission, newEmission, oldOpacity, newOpacity )
	end
	if oldId ~= 0 and newId == 0 and lightPerfPrintBreakEnabled() and timer and timer.Simple then
		timer.Simple( 0, function()
			if MC.PrintLightPerfStats then
				MC.PrintLightPerfStats( "break", string.format( "cell=%d,%d,%d old=%d new=%d", bx, by, bz, oldId, newId ) )
			end
		end )
	end
end

function MC.MarkLightingDirtyForStateChange( bx, by, bz, oldStateId, newStateId, rateLimited )
	if not lightEnabled() then
		noteLightingDisabledSkip( "state_change_dirty", bx, by, bz )
		return 0, 0
	end
	oldStateId = math.floor( tonumber( oldStateId ) or 0 )
	newStateId = math.floor( tonumber( newStateId ) or 0 )
	local oldEmission = lightEmissionForState( oldStateId, bx, by, bz )
	local newEmission = lightEmissionForState( newStateId, bx, by, bz )
	local oldOpacity = lightOpacityForState( oldStateId, bx, by, bz )
	local newOpacity = lightOpacityForState( newStateId, bx, by, bz )
	MC.NoteLightingStateCellChanged( bx, by, bz, newStateId )
	if MC.NoteSkyColumnBlockChange then MC.NoteSkyColumnBlockChange( bx, by, bz, oldOpacity, newOpacity ) end
	if MC.UpdateSkyLightForBlockChange then MC.UpdateSkyLightForBlockChange( bx, by, bz, oldOpacity, newOpacity ) end
	if oldEmission ~= newEmission or oldOpacity ~= newOpacity then
		return MC.UpdateBlockLightForChange( bx, by, bz, oldEmission, newEmission, oldOpacity, newOpacity )
	end
	return 0, 0
end

function MC.SampleLighting( bx, by, bz, selfEmission )
	local sampleStart = lightPerfDebugEnabled() and perfNow() or nil
	if not lightEnabled() then
		noteLightSample( sampleStart )
		return 1, 15, 15, 15
	end
	ensureLightSourceIndex()
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local native = nativeBlockLightBackend()
	local nativeBlock, nativeSky
	if native and native.GetLightingAt then nativeBlock, nativeSky = native.GetLightingAt( bx, by, bz ) end
	local block = nativeBlock ~= nil and nativeBlock
		or ( chunkLoadedForCell( bx, by, bz ) and getStoredLight( MC.LightBlockChunks, bx, by, bz ) or 0 )
	-- Voxel sky light from the flood fill: 15 above open sky, smooth falloff
	-- into interiors, 0 fully enclosed. This is the AMBIENT sky term only —
	-- directional sun shadow stays the shadow map's job.
	local sky
	if nativeSky ~= nil and ( not MC.SkyFloodEnabled or MC.SkyFloodEnabled() ) then sky = nativeSky
	else sky = MC.SkyVoxelLight and MC.SkyVoxelLight( bx, by, bz ) or 0 end
	local level = math.max( block, sky, math.Clamp( math.floor( tonumber( selfEmission ) or 0 ), 0, 15 ) )
	local brightness = ambientMin() + ( 1 - ambientMin() ) * ( level / 15 )
	noteLightSample( sampleStart )
	return brightness, level, block, sky
end

function MC.SampleAmbientOcclusion( bx, by, bz )
	local sampleStart = lightPerfDebugEnabled() and perfNow() or nil
	if not lightEnabled() then
		noteLightAOSample( sampleStart )
		return false
	end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local blocked = stateId ~= 0 and lightOpacityForState( stateId, bx, by, bz ) >= 15 or false
	noteLightAOSample( sampleStart )
	return blocked
end

concommand.Add( "mc_light_rebuild", function()
	if not MC.RebuildLightingCells then return end
	MC.RebuildLightingCells()
	local stats = MC.LightPerfStats or {}
	print( string.format( "[MC light] full rebuild: stored light wiped and re-flooded from sources (%.1fms). Use this to clean residue left by old bugs.",
		tonumber( stats.lastRebuildMS ) or 0 ) )
end )

concommand.Add( "mc_light_enable", function( _, _, args )
	local value = args and args[1]
	if value == nil or value == "" then
		print( "[MC light] mc_light_enabled = " .. tostring( MC.LightEnabled and MC.LightEnabled:GetString() or "?" ) )
		return
	end
	RunConsoleCommand( "mc_light_enabled", tostring( value ) )
end )

cvars.AddChangeCallback( "mc_light_enabled", function( _, _, newValue )
	MC.LightCellsReady = false
	MC.LightSourceIndexReady = false
	if MC.ClearSkyFlood then MC.ClearSkyFlood() end
	MC.LightSkyColumnTops = nil
	local value = string.lower( tostring( newValue or "" ) )
	if value ~= "0" and value ~= "false" and value ~= "off" then
		MC.RebuildLightingCells()
	else
		noteLightingDisabledSkip( "disabled" )
	end
	markLoadedMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_ambient_min", function()
	markLoadedMeshesDirty()
end, "mc" )

if cvars.RemoveChangeCallback then
	cvars.RemoveChangeCallback( "mc_light_style", "mc" )
end
