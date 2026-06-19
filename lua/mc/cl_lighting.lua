--[[----------------------------------------------------------------------------
	MC : client-side Minecraft-style vertex lighting

	Lighting is stored as per-cell 0-15 block/sky values, like Minecraft's light
	arrays. Mesh building only samples those values; propagation happens when
	chunks arrive or blocks change.
------------------------------------------------------------------------------]]

MC = MC or {}

local LIGHT_RADIUS = 15

MC.LightEnabled = MC.LightEnabled or CreateClientConVar( "mc_light_enabled", "1", true, false,
	"Apply Minecraft-style vertex lighting to MC chunk meshes" )
MC.LightSkyLevel = MC.LightSkyLevel or CreateClientConVar( "mc_light_sky_level", "15", true, false,
	"Client sky light level for MC chunks (0-15)" )
MC.LightAmbientMin = MC.LightAmbientMin or CreateClientConVar( "mc_light_ambient_min", "0.18", true, false,
	"Minimum brightness multiplier for MC vertex lighting" )
MC.LightStyle = MC.LightStyle or CreateClientConVar( "mc_light_style", "vanilla", true, false,
	"MC chunk lighting visual style: fast, vanilla, or best" )
MC.LightPerfDebug = MC.LightPerfDebug or CreateClientConVar( "mc_light_perf_debug", "0", true, false,
	"Show and collect detailed MC lighting performance diagnostics" )
MC.LightPerfPrintBreak = MC.LightPerfPrintBreak or CreateClientConVar( "mc_light_perf_print_break", "0", true, false,
	"Print MC lighting performance diagnostics after a block is broken" )

MC.LightBlockChunks = MC.LightBlockChunks or {}
MC.LightSkyChunks = MC.LightSkyChunks or {}
MC.LightSkyColumnTops = MC.LightSkyColumnTops or {}
MC.LightSourceCells = MC.LightSourceCells or {}
MC.LightChunkSources = MC.LightChunkSources or {}
MC.LightColumnChunks = MC.LightColumnChunks or {}
MC.LightCellsReady = MC.LightCellsReady or false
MC.LightSourceIndexReady = MC.LightSourceIndexReady or false
MC.LightCellsSkyLevel = MC.LightCellsSkyLevel or -1
MC.LightPerfStats = MC.LightPerfStats or {}

local function lightEnabled()
	return not MC.LightEnabled or MC.LightEnabled:GetBool()
end

local function skyLevel()
	local cv = MC.LightSkyLevel
	return math.Clamp( cv and cv:GetInt() or 15, 0, 15 )
end

local function ambientMin()
	local cv = MC.LightAmbientMin
	return math.Clamp( cv and cv:GetFloat() or 0.18, 0, 1 )
end

local function lightPerfDebugEnabled()
	return MC.LightPerfDebug and MC.LightPerfDebug:GetBool()
end

local function lightPerfPrintBreakEnabled()
	return MC.LightPerfPrintBreak and MC.LightPerfPrintBreak:GetBool()
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
end

local function cellKey( bx, by, bz )
	return bx .. ":" .. by .. ":" .. bz
end

local function chunkColumnKey( cx, cy )
	return cx .. ":" .. cy
end

local function skyColumnKey( bx, by )
	return bx .. ":" .. by
end

local function invalidateSkyColumnsForChunkCoords( cx, cy )
	if not MC.LightSkyColumnTops then return end
	local baseX, baseY = cx * MC.CS, cy * MC.CS
	for ly = 0, MC.CS - 1 do
		for lx = 0, MC.CS - 1 do
			MC.LightSkyColumnTops[skyColumnKey( baseX + lx, baseY + ly )] = nil
		end
	end
end

local function syncLightColumnForCell( bx, by, bz )
	if not MC.CellToChunk or not MC.ChunkKey then return end
	MC.LightColumnChunks = MC.LightColumnChunks or {}
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local chunkKey = MC.ChunkKey( cx, cy, cz )
	local columnKey = chunkColumnKey( cx, cy )
	local column = MC.LightColumnChunks[columnKey]
	local chunk = MC.World and MC.World[chunkKey]
	if chunk and chunk.count and chunk.count > 0 then
		if not column then
			column = {}
			MC.LightColumnChunks[columnKey] = column
		end
		column[cz] = chunk
	elseif column then
		column[cz] = nil
		if next( column ) == nil then MC.LightColumnChunks[columnKey] = nil end
	end
	if MC.LightSkyColumnTops then MC.LightSkyColumnTops[skyColumnKey( bx, by )] = nil end
end

local function lightEmission( id )
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

local function lightOpacity( id, orient )
	if id == 0 then return 0 end
	return MC.BlockLightOpacity and MC.BlockLightOpacity( id, orient ) or 15
end

local function chunkLoadedForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.World and MC.World[MC.ChunkKey( cx, cy, cz )] ~= nil
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

local function getStoredLightRaw( store, bx, by, bz )
	local chunkStore, li = lightStoreForCell( store, bx, by, bz, false )
	return chunkStore and chunkStore[li] or nil
end

local function setStoredLight( store, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	local chunkStore, li = lightStoreForCell( store, bx, by, bz, level > 0 )
	if not chunkStore then return end
	chunkStore[li] = level > 0 and level or nil
end

local function inBounds( bx, by, bz, minX, minY, minZ, maxX, maxY, maxZ )
	return bx >= minX and bx <= maxX
		and by >= minY and by <= maxY
		and bz >= minZ and bz <= maxZ
end

local function distanceToBounds( bx, by, bz, minX, minY, minZ, maxX, maxY, maxZ )
	local dx = bx < minX and ( minX - bx ) or ( bx > maxX and ( bx - maxX ) or 0 )
	local dy = by < minY and ( minY - by ) or ( by > maxY and ( by - maxY ) or 0 )
	local dz = bz < minZ and ( minZ - bz ) or ( bz > maxZ and ( bz - maxZ ) or 0 )
	return dx + dy + dz
end

local function blockAllowsPropagation( bx, by, bz )
	if not chunkLoadedForCell( bx, by, bz ) then return false end
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return true end
	if lightEmission( id ) > 0 then return true end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return MC.BlockAllowsLight and MC.BlockAllowsLight( id, orient ) == true
end

local function clearStoredLight()
	MC.LightBlockChunks = {}
	MC.LightSkyChunks = {}
	MC.LightSkyColumnTops = {}
	MC.LightCellsReady = false
	MC.LightCellsSkyLevel = -1
end

function MC.ClearLightingCache()
	clearStoredLight()
	MC.LightSkyColumnTops = {}
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	MC.LightColumnChunks = {}
	MC.LightSourceIndexReady = false
end

function MC.MarkAllMeshesDirty()
	MC.ClearLightingCache()
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.count and chunk.count > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
		end
	end
end

local function markLoadedMeshesDirty()
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
	if MC.ChunkKeyToCoords then
		local cx, cy, cz = MC.ChunkKeyToCoords( key )
		if cx then
			invalidateSkyColumnsForChunkCoords( cx, cy )
			local columnKey = chunkColumnKey( cx, cy )
			local column = MC.LightColumnChunks and MC.LightColumnChunks[columnKey]
			if column then
				column[cz] = nil
				if next( column ) == nil then
					MC.LightColumnChunks[columnKey] = nil
				end
			end
		end
	end
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
	if not chunk or not chunk.blocks or not MC.DecodeLocal then return end
	local baseX, baseY, baseZ = chunk.cx * MC.CS, chunk.cy * MC.CS, chunk.cz * MC.CH
	for li, id in pairs( chunk.blocks ) do
		local emission = lightEmission( id )
		if emission > 0 then
			local lx, ly, lz = MC.DecodeLocal( li )
			addLightSource( baseX + lx, baseY + ly, baseZ + lz, emission )
		end
	end
end

local function indexChunkColumn( chunk )
	if not chunk or not chunk.key or not chunk.count or chunk.count <= 0 then return end
	invalidateSkyColumnsForChunkCoords( chunk.cx, chunk.cy )
	local key = chunkColumnKey( chunk.cx, chunk.cy )
	MC.LightColumnChunks[key] = MC.LightColumnChunks[key] or {}
	MC.LightColumnChunks[key][chunk.cz] = chunk
end

function MC.IndexChunkLightSources( chunk )
	if not chunk or not chunk.key then return end
	if not lightEnabled() then
		MC.LightSourceIndexReady = false
		MC.LightCellsReady = false
		return
	end
	MC.ClearChunkLightSources( chunk.key )
	indexChunkColumn( chunk )
	indexChunkSources( chunk )
	MC.LightSourceIndexReady = true
	if MC.UpdateLightingForChunkLoaded then
		MC.UpdateLightingForChunkLoaded( chunk )
	else
		MC.LightCellsReady = false
	end
end

function MC.ReindexAllLightingSources()
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	MC.LightColumnChunks = {}
	for _, chunk in pairs( MC.World or {} ) do
		indexChunkColumn( chunk )
		indexChunkSources( chunk )
	end
	MC.LightSourceIndexReady = true
	MC.LightCellsReady = false
end

local function ensureLightSourceIndex()
	if MC.LightSourceIndexReady then return end
	MC.ReindexAllLightingSources()
end

local function forEachLightSourceInBounds( minX, minY, minZ, maxX, maxY, maxZ, fn )
	local minCX, minCY, minCZ = MC.CellToChunk( minX, minY, minZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxX, maxY, maxZ )
	for cz = minCZ, maxCZ do
		for cy = minCY, maxCY do
			for cx = minCX, maxCX do
				local sources = MC.LightChunkSources and MC.LightChunkSources[MC.ChunkKey( cx, cy, cz )]
				if sources then
					for sourceKey in pairs( sources ) do
						local source = MC.LightSourceCells and MC.LightSourceCells[sourceKey]
						if source then fn( source ) end
					end
				end
			end
		end
	end
end

local NEIGHBORS = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

local LIGHT_DIRTY_MESH_NEIGHBORS = {}
do
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				LIGHT_DIRTY_MESH_NEIGHBORS[#LIGHT_DIRTY_MESH_NEIGHBORS + 1] = { dx, dy, dz }
			end
		end
	end
end

local function newChangedLightCells()
	return { keys = {}, list = {}, count = 0 }
end

local function noteChangedLightCell( changed, bx, by, bz )
	if not changed then return end
	local key = cellKey( bx, by, bz )
	if changed.keys[key] then return end
	changed.keys[key] = true
	changed.count = changed.count + 1
	changed.list[changed.count] = { bx, by, bz }
end

local function setBlockLightChanged( changed, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	local loaded = chunkLoadedForCell( bx, by, bz )
	if level > 0 and not loaded then return false end
	if getStoredLight( MC.LightBlockChunks, bx, by, bz ) == level then return false end
	setStoredLight( MC.LightBlockChunks, bx, by, bz, level )
	if loaded then noteChangedLightCell( changed, bx, by, bz ) end
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
		if bx and chunkLoadedForCell( bx, by, bz ) then
			processed = processed + 1
			local nextLevel = level - 1
			if nextLevel > 0 then
				for i = 1, #NEIGHBORS do
					local off = NEIGHBORS[i]
					local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
					if chunkLoadedForCell( nx, ny, nz )
					and blockAllowsPropagation( nx, ny, nz )
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
	while removeQ.head <= removeQ.tail do
		local bx, by, bz, oldLevel = popLightQueue( removeQ )
		if bx then
			processed = processed + 1
			for i = 1, #NEIGHBORS do
				local off = NEIGHBORS[i]
				local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
				if chunkLoadedForCell( nx, ny, nz ) then
					local neighborLevel = getStoredLight( MC.LightBlockChunks, nx, ny, nz )
					if neighborLevel > 0 and neighborLevel < oldLevel then
						setBlockLightChanged( changed, nx, ny, nz, 0 )
						pushLightQueue( removeQ, nx, ny, nz, neighborLevel )
					elseif neighborLevel >= oldLevel then
						pushLightQueue( addQ, nx, ny, nz, neighborLevel )
					end
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

local function finishChunkLightQueues( perfStart, changed, removeQ, addQ, sourceCount, boundsText )
	local decProcessed = runLightDecreaseQueue( removeQ, addQ, changed )
	local incProcessed = runLightIncreaseQueue( addQ, changed )
	local dirtySections = MC.MarkLightSectionsDirtyForChangedCells and MC.MarkLightSectionsDirtyForChangedCells( changed ) or 0
	MC.LightCellsReady = true
	MC.LightCellsSkyLevel = skyLevel()
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
	return finishChunkLightQueues( perfStart, changed, removeQ, addQ, 0, "remove:" .. tostring( key ) )
end

function MC.UpdateLightingForChunkLoaded( chunk )
	if not chunk or not chunk.key then return 0, 0 end
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
	if chunk.count and chunk.count > 0 and MC.World and MC.World[chunk.key] then
		sourceCount = seedChunkLightSources( addQ, changed, chunk )
		seedChunkBorderLight( addQ, chunk )
	end
	return finishChunkLightQueues( perfStart, changed, removeQ, addQ, sourceCount, tostring( chunk.key ) )
end

function MC.MarkLightSectionsDirtyForChangedCells( changed )
	local dirty = {}
	local dirtyCount = 0
	for _, cell in ipairs( changed and changed.list or {} ) do
		if MC.MarkLightCellDirty then
			for i = 1, #LIGHT_DIRTY_MESH_NEIGHBORS do
				local off = LIGHT_DIRTY_MESH_NEIGHBORS[i]
				local ok, key, sectionIndex = MC.MarkLightCellDirty( cell[1] + off[1], cell[2] + off[2], cell[3] + off[3] )
				if ok and key and sectionIndex then
					local dirtyKey = key .. ":" .. sectionIndex
					if not dirty[dirtyKey] then
						dirty[dirtyKey] = true
						dirtyCount = dirtyCount + 1
					end
				end
			end
		end
	end
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
	return changed
end

local function columnBounds( bx, by )
	local cx, cy = math.floor( bx / MC.CS ), math.floor( by / MC.CS )
	local minZ, maxZ
	local column = MC.LightColumnChunks and MC.LightColumnChunks[chunkColumnKey( cx, cy )]
	for cz, chunk in pairs( column or {} ) do
		if chunk and chunk.count and chunk.count > 0 then
			local bottom = cz * MC.CH
			local top = bottom + MC.CH - 1
			minZ = minZ and math.min( minZ, bottom ) or bottom
			maxZ = maxZ and math.max( maxZ, top ) or top
		end
	end
	return minZ, maxZ
end

local function highestOpaqueInColumn( bx, by )
	local cx, cy = math.floor( bx / MC.CS ), math.floor( by / MC.CS )
	local lx, ly = bx - cx * MC.CS, by - cy * MC.CS
	local topOpaque = nil
	local column = MC.LightColumnChunks and MC.LightColumnChunks[chunkColumnKey( cx, cy )]
	for cz, chunk in pairs( column or {} ) do
		if chunk and chunk.count and chunk.count > 0 then
			for lz = MC.CH - 1, 0, -1 do
				local li = lx + ly * MC.CS + lz * MC.CS * MC.CS
				local id = chunk.blocks and chunk.blocks[li] or 0
				if id and id ~= 0 then
					local orient = chunk.orients and chunk.orients[li] or 0
					if lightOpacity( id, orient ) >= 15 then
						local z = cz * MC.CH + lz
						if not topOpaque or z > topOpaque then topOpaque = z end
						break
					end
				end
			end
		end
	end
	return topOpaque
end

local function skyColumnTopWithOverride( bx, by, overrideBX, overrideBY, overrideBZ, overrideId, overrideOrient )
	local cx, cy = math.floor( bx / MC.CS ), math.floor( by / MC.CS )
	local lx, ly = bx - cx * MC.CS, by - cy * MC.CS
	local topOpaque = nil
	local column = MC.LightColumnChunks and MC.LightColumnChunks[chunkColumnKey( cx, cy )]
	for cz, chunk in pairs( column or {} ) do
		if chunk and chunk.count and chunk.count > 0 then
			for lz = MC.CH - 1, 0, -1 do
				local z = cz * MC.CH + lz
				local id, orient
				if bx == overrideBX and by == overrideBY and z == overrideBZ then
					id, orient = overrideId, overrideOrient
				else
					local li = lx + ly * MC.CS + lz * MC.CS * MC.CS
					id = chunk.blocks and chunk.blocks[li] or 0
					orient = chunk.orients and chunk.orients[li] or 0
				end
				if id and id ~= 0 and lightOpacity( id, orient ) >= 15 then
					if not topOpaque or z > topOpaque then topOpaque = z end
					break
				end
			end
		end
	end
	if bx == overrideBX and by == overrideBY
	and overrideId and overrideId ~= 0
	and lightOpacity( overrideId, overrideOrient ) >= 15 then
		topOpaque = topOpaque and math.max( topOpaque, overrideBZ ) or overrideBZ
	end
	return topOpaque or false
end

local function cachedSkyColumnTop( bx, by )
	MC.LightSkyColumnTops = MC.LightSkyColumnTops or {}
	local key = skyColumnKey( bx, by )
	local topOpaque = MC.LightSkyColumnTops[key]
	if topOpaque == nil then
		topOpaque = highestOpaqueInColumn( bx, by ) or false
		MC.LightSkyColumnTops[key] = topOpaque
	end
	return topOpaque
end

local function rebuildSkyColumn( bx, by )
	local perfStart = perfNow()
	local minZ, maxZ = columnBounds( bx, by )
	if not minZ then return nil, nil, false end
	local topOpaque = highestOpaqueInColumn( bx, by )
	MC.LightSkyColumnTops = MC.LightSkyColumnTops or {}
	MC.LightSkyColumnTops[skyColumnKey( bx, by )] = topOpaque or false
	local ms = perfMS( perfStart )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastSkyColumnMS = ms
	stats.lastSkyColumnCells = 1
	stats.lastSkyColumn = string.format( "%d,%d z=%d..%d", bx, by, minZ, maxZ )
	return minZ, maxZ, topOpaque or false, ms
end

local function rebuildAllSkyCells()
	local perfStart = perfNow()
	MC.LightSkyChunks = {}
	MC.LightSkyColumnTops = {}
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastSkyRebuildMS = perfMS( perfStart )
	stats.lastSkyRebuildColumns = 0
	stats.lastSkyRebuildCells = 0
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
	MC.LightSkyChunks = {}
	local minX, minY, minZ, maxX, maxY, maxZ = loadedWorldBounds()
	rebuildBlockLightCells()
	rebuildAllSkyCells()
	MC.LightCellsSkyLevel = skyLevel()
	MC.LightCellsReady = true
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastRebuildMS = perfMS( perfStart )
	stats.lastRebuildBounds = minX and perfBoundsText( minX, minY, minZ, maxX, maxY, maxZ ) or "empty"
end

local function ensureLightingCells()
	if MC.LightCellsReady and MC.LightCellsSkyLevel == skyLevel() then return end
	MC.RebuildLightingCells()
end

function MC.UpdateLightingCellsAroundCell( bx, by, bz, radius, rateLimited )
	if not lightEnabled() then
		noteLightingDisabledSkip( "around_cell", bx, by, bz )
		return 0, 0
	end
	local perfStart = SysTime()
	ensureLightSourceIndex()
	if MC.LightCellsSkyLevel ~= skyLevel() then
		MC.LightSkyChunks = {}
		MC.LightCellsSkyLevel = skyLevel()
	end
	local changed = newChangedLightCells()
	local addQ = newLightQueue()
	seedNeighborLight( addQ, bx, by, bz )
	runLightIncreaseQueue( addQ, changed )
	MC.LightCellsReady = true
	MC.LightCellsSkyLevel = skyLevel()
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
end

function MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )
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

function MC.MarkLightingDirtyAroundCell( bx, by, bz, radius, rateLimited )
	MC.UpdateLightingCellsAroundCell( bx, by, bz, radius, rateLimited )
end

local function markLightingDirtyColumn( bx, by, bz, oldTop )
	local minZ, maxZ, newTop = rebuildSkyColumn( bx, by )
	if not minZ then return end
	if oldTop == nil then oldTop = false end
	if oldTop == newTop then
		local stats = MC.LightPerfStats or {}
		MC.LightPerfStats = stats
		stats.lastSkyColumnDirtySections = 0
		return
	end
	local z0, z1
	if oldTop == false then
		z0, z1 = minZ, newTop
	elseif newTop == false then
		z0, z1 = minZ, oldTop
	else
		z0, z1 = math.min( oldTop, newTop ), math.max( oldTop, newTop )
	end
	z0 = math.Clamp( math.floor( z0 or minZ ), minZ, maxZ )
	z1 = math.Clamp( math.floor( z1 or maxZ ), minZ, maxZ )
	local dirtySections, dirtyCells = markLightSectionsInBounds( bx, by, z0, bx, by, z1 )
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastSkyColumnDirtySections = dirtySections
	stats.lastSkyColumnCells = dirtyCells
	stats.lastSkyColumn = string.format( "%d,%d z=%d..%d", bx, by, z0, z1 )
end

local function nearbySourceRadius( bx, by, bz )
	ensureLightSourceIndex()
	local radius = 0
	forEachLightSourceInBounds( bx - LIGHT_RADIUS, by - LIGHT_RADIUS, bz - LIGHT_RADIUS, bx + LIGHT_RADIUS, by + LIGHT_RADIUS, bz + LIGHT_RADIUS, function( source )
		local dist = math.abs( source.bx - bx ) + math.abs( source.by - by ) + math.abs( source.bz - bz )
		if dist <= source.level then
			radius = math.max( radius, source.level )
			if radius >= LIGHT_RADIUS then return end
		end
	end )
	return radius
end

function MC.UpdateBlockLightForChange( bx, by, bz, oldEmission, newEmission, oldOpacity, newOpacity )
	if not lightEnabled() then
		noteLightingDisabledSkip( "block_change", bx, by, bz )
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
	MC.LightCellsSkyLevel = skyLevel()

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
	syncLightColumnForCell( bx, by, bz )
	local oldTop = oldOpacity ~= newOpacity and skyColumnTopWithOverride( bx, by, bx, by, bz, oldId, oldOrient ) or nil
	MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )
	if oldOpacity ~= newOpacity then
		markLightingDirtyColumn( bx, by, bz, oldTop )
	end
	if oldEmission ~= newEmission or oldOpacity ~= newOpacity then
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

local function storedSkyLight( bx, by, bz )
	if not chunkLoadedForCell( bx, by, bz ) then return skyLevel() end
	local id = MC.GetBlock( bx, by, bz )
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	if lightOpacity( id, orient ) >= 15 then return 0 end
	local topOpaque = cachedSkyColumnTop( bx, by )
	if topOpaque == false then return skyLevel() end
	return bz >= topOpaque and skyLevel() or 0
end

function MC.SampleLighting( bx, by, bz, selfEmission )
	local sampleStart = lightPerfDebugEnabled() and perfNow() or nil
	if not lightEnabled() then
		noteLightSample( sampleStart )
		return 1, 15, 15, 15
	end
	ensureLightSourceIndex()
	if MC.LightCellsSkyLevel ~= skyLevel() then
		MC.LightSkyChunks = {}
		MC.LightCellsSkyLevel = skyLevel()
	end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local block = chunkLoadedForCell( bx, by, bz ) and getStoredLight( MC.LightBlockChunks, bx, by, bz ) or 0
	local sky = storedSkyLight( bx, by, bz )
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
	local id = MC.GetBlock( bx, by, bz )
	local blocked = false
	if id ~= 0 then
		local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
		blocked = lightOpacity( id, orient ) >= 15
	end
	noteLightAOSample( sampleStart )
	return blocked
end

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
	MC.LightSkyChunks = {}
	MC.LightSkyColumnTops = {}
	local value = string.lower( tostring( newValue or "" ) )
	if value ~= "0" and value ~= "false" and value ~= "off" then
		MC.RebuildLightingCells()
	else
		noteLightingDisabledSkip( "disabled" )
	end
	markLoadedMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_sky_level", function()
	MC.LightSkyChunks = {}
	MC.LightSkyColumnTops = {}
	MC.LightCellsSkyLevel = skyLevel()
	markLoadedMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_ambient_min", function()
	markLoadedMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_style", function()
	markLoadedMeshesDirty()
end, "mc" )
