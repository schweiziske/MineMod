--[[----------------------------------------------------------------------------
	MC : client net receivers (server is authoritative; we only mirror + redraw)
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net
MC.PendingFull = MC.PendingFull or {}
MC.SnapshotBuffers = MC.SnapshotBuffers or {}
MC.SnapshotQueuedDeltas = MC.SnapshotQueuedDeltas or {}
MC.SyncProgress = MC.SyncProgress or { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = 0 }

local PendingFullAckBytes = 0
local NextFullAckAt = 0

local function flushFullAck()
	if PendingFullAckBytes <= 0 then return end
	local bytes = math.min( PendingFullAckBytes, 4294967295 )
	PendingFullAckBytes = 0
	net.Start( "mc_full_ack" )
		net.WriteUInt( bytes, 32 )
	net.SendToServer()
	NextFullAckAt = CurTime() + 0.02
end

local function queueFullAck( bytes, immediate )
	bytes = math.max( 0, math.ceil( tonumber( bytes ) or 0 ) )
	if bytes <= 0 then return end
	PendingFullAckBytes = math.min( PendingFullAckBytes + bytes, 4294967295 )
	if immediate or PendingFullAckBytes >= 65536 or CurTime() >= NextFullAckAt then
		flushFullAck()
	end
end

timer.Create( "mc_full_ack_flush", 0.05, 0, flushFullAck )

local function sendSnapshotAck( token, bytes, complete )
	net.Start( "mc_snapshot_ack" )
		net.WriteString( token or "" )
		net.WriteUInt( math.Clamp( math.ceil( tonumber( bytes ) or 0 ), 0, 4294967295 ), 32 )
		net.WriteBool( complete == true )
	net.SendToServer()
end

local function touchProgress()
	MC.SyncProgress.lastUpdate = CurTime()
end

local function beginProgressChunk( expected )
	local p = MC.SyncProgress
	p.active = true
	p.expected = p.expected + expected
	p.chunks = p.chunks + 1
	touchProgress()
end

local function addProgressCells( count )
	local p = MC.SyncProgress
	p.received = p.received + count
	touchProgress()
end

local function finishProgressChunk( key )
	local p = MC.SyncProgress
	p.doneChunks = p.doneChunks + 1
	touchProgress()
	if key then MC.MarkChunkDirty( key ) end
end

local function markNeighbours( cx, cy, cz )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx + 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx - 1, cy, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy + 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy - 1, cz ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz + 1 ) )
	MC.MarkChunkDirty( MC.ChunkKey( cx, cy, cz - 1 ) )
end

function MC.MarkCellPhysNeighbours( bx, by, bz, priority )
	local seen = {}
	local function mark( x, y, z )
		local cx, cy, cz = MC.CellToChunk( x, y, z )
		local key = MC.ChunkKey( cx, cy, cz )
		if seen[key] then return end
		seen[key] = true
		MC.MarkChunkPhysDirty( key, priority )
	end

	mark( bx, by, bz )
	mark( bx + 1, by, bz )
	mark( bx - 1, by, bz )
	mark( bx, by + 1, bz )
	mark( bx, by - 1, bz )
end

local function queueSnapshotDelta( bx, by, bz, id, orient )
	if not MC.SnapshotLoadingToken then return end
	MC.SnapshotQueuedDeltas = MC.SnapshotQueuedDeltas or {}
	MC.SnapshotQueuedDeltas[#MC.SnapshotQueuedDeltas + 1] = {
		bx = bx,
		by = by,
		bz = bz,
		id = id,
		orient = orient,
	}
end

local function applyNetCell( bx, by, bz, id, orient )
	MC.ConfirmPrediction( bx, by, bz, id, orient )
	local _, _, _, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
	if changed then
		MC.MarkDirty( bx, by, bz )
		MC.MarkCellPhysNeighbours( bx, by, bz )
	end
end

MC.PendingPredictions = MC.PendingPredictions or {}

local function predictionKey( bx, by, bz )
	return bx .. ":" .. by .. ":" .. bz
end

function MC.IsPendingPredictionCell( bx, by, bz )
	return MC.PendingPredictions[predictionKey( bx, by, bz )] ~= nil
end

local function markPredictedCellDirty( bx, by, bz, priority )
	MC.MarkDirty( bx, by, bz )
	MC.MarkCellPhysNeighbours( bx, by, bz, priority )
end

local function predictCells( cells, priorityFn )
	if not istable( cells ) or #cells == 0 then return false end
	for _, cell in ipairs( cells ) do
		if MC.PendingPredictions[predictionKey( cell.bx, cell.by, cell.bz )] then return false end
	end

	local oldStates = {}
	for i, cell in ipairs( cells ) do
		oldStates[i] = {
			id = MC.GetBlock( cell.bx, cell.by, cell.bz ),
			orient = MC.GetBlockOrient( cell.bx, cell.by, cell.bz ),
		}
	end

	for i, cell in ipairs( cells ) do
		local id = math.floor( tonumber( cell.id ) or 0 )
		local orient = id ~= 0 and MC.NormalizeOrient( id, cell.orient ) or 0
		local _, _, _, changed = MC.SetBlockRaw( cell.bx, cell.by, cell.bz, id, orient )
		if changed then
			MC.PendingPredictions[predictionKey( cell.bx, cell.by, cell.bz )] = {
				bx = cell.bx,
				by = cell.by,
				bz = cell.bz,
				id = id,
				orient = orient,
				oldId = oldStates[i].id,
				oldOrient = oldStates[i].orient,
				expire = CurTime() + 2.5,
			}
			markPredictedCellDirty( cell.bx, cell.by, cell.bz, priorityFn and priorityFn( cell ) or false )
		end
	end

	return true
end

function MC.PredictSetBlock( bx, by, bz, id, orient )
	if not MC.IsValidBlock or not MC.IsValidBlock( id ) then return false end
	local plan = MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
	if not plan then return false end
	for _, cell in ipairs( plan.cells ) do
		if MC.GetBlock( cell.bx, cell.by, cell.bz ) ~= 0 then return false end
	end
	return predictCells( plan.cells, function() return true end )
end

function MC.PredictBreakBlock( bx, by, bz, ply )
	if IsValid( ply ) and not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, MC.CurrentReach() ) then return false end
	local oldId = MC.GetBlock( bx, by, bz )
	if oldId == 0 then return false end
	local oldOrient = MC.GetBlockOrient( bx, by, bz )
	local plan = MC.BuildBreakPlan and MC.BuildBreakPlan( bx, by, bz )
	if not plan then return false end
	if not predictCells( plan.cells, function() return true end ) then return false end
	if MC.PlayBlockFx then
		MC.PlayBlockFx( 2, oldId, oldOrient, bx, by, bz, true )
	end
	return true
end

function MC.ConfirmPrediction( bx, by, bz, id, orient )
	local key = predictionKey( bx, by, bz )
	local hadPrediction = MC.PendingPredictions[key] ~= nil
	if MC.PendingPredictions[key] then
		MC.PendingPredictions[key] = nil
	end
	return hadPrediction
end

local function rollbackExpiredPredictions()
	local now = CurTime()
	for key, pending in pairs( MC.PendingPredictions ) do
		if now >= pending.expire then
			local current = MC.GetBlock( pending.bx, pending.by, pending.bz )
			local currentOrient = MC.GetBlockOrient( pending.bx, pending.by, pending.bz )
			if current == pending.id and currentOrient == pending.orient then
				MC.SetBlockRaw( pending.bx, pending.by, pending.bz, pending.oldId, pending.oldOrient )
				markPredictedCellDirty( pending.bx, pending.by, pending.bz )
			end
			MC.PendingPredictions[key] = nil
		end
	end
end

local function resetChunk( cx, cy, cz )
	local c = MC.EnsureChunk( cx, cy, cz )
	c.blocks = {}
	c.orients = {}
	c.count = 0
	return c
end

local function readCellsIntoChunk( c, count )
	for _ = 1, count do
		local li = net.ReadUInt( Net.LOCAL_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )
		if id ~= 0 and MC.LocalIndexInRange( li ) then
			if c.blocks[li] == nil then c.count = c.count + 1 end
			c.blocks[li] = id
			c.orients[li] = MC.NormalizeOrient( id, orient )
		end
	end
end

local function reviveChunkEnt( c )
	MC.ChunkEnts = MC.ChunkEnts or {}
	local e = MC.ChunkEnts[c.key]
	if not IsValid( e ) then
		for _, candidate in ipairs( ents.FindByClass( "mc_chunk" ) ) do
			if candidate:EnsureKey() == c.key then
				e = candidate
				MC.ChunkEnts[c.key] = candidate
				break
			end
		end
	end
	if not IsValid( e ) then return end
	e:SetNoDraw( false )
	e.ChunkKey = c.key
end

local function resetClientWorldForSnapshot( expectedChunks, expectedBlocks )
	if MC.FreeAllMeshes then MC.FreeAllMeshes() end
	for _, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then e:PhysicsDestroy() end
	end
	MC.World = {}
	MC.MeshDirty = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PendingFull = {}
	MC.PendingPredictions = {}
	MC.SyncProgress = {
		expected = math.max( 0, math.floor( tonumber( expectedBlocks ) or 0 ) ),
		received = 0,
		chunks = math.max( 0, math.floor( tonumber( expectedChunks ) or 0 ) ),
		doneChunks = 0,
		active = true,
		lastUpdate = CurTime(),
		snapshot = true,
	}
	PendingFullAckBytes = 0
end

local function snapshotPaletteEntry( cache, palette, index )
	local pi = math.floor( tonumber( index ) or -1 )
	if pi < 0 then return 0, 0 end
	local cached = cache[pi]
	if cached then return cached.id, cached.orient end

	local spec = istable( palette ) and palette[pi + 1] or nil
	if not isstring( spec ) then return 0, 0 end
	local id, orient = MC.ParseBlockSpec( spec )
	id = math.floor( tonumber( id ) or 0 )
	orient = id ~= 0 and MC.NormalizeOrient( id, orient ) or 0
	cache[pi] = { id = id, orient = orient }
	return id, orient
end

local function loadSnapshotChunk( data, cache, palette )
	local cx = math.floor( tonumber( data[1] ) or 0 )
	local cy = math.floor( tonumber( data[2] ) or 0 )
	local cz = math.floor( tonumber( data[3] ) or 0 )
	local cells = data[4]
	local c = MC.EnsureChunk( cx, cy, cz )
	c.blocks = {}
	c.orients = {}
	c.count = 0

	if isstring( cells ) then
		for entry in string.gmatch( cells, "[^;]+" ) do
			local liText, piText = string.match( entry, "^(-?%d+):(-?%d+)$" )
			local li = math.floor( tonumber( liText ) or -1 )
			if MC.LocalIndexInRange( li ) then
				local id, orient = snapshotPaletteEntry( cache, palette, piText )
				if id and id ~= 0 then
					c.blocks[li] = id
					c.orients[li] = orient
					c.count = c.count + 1
				end
			end
		end
	elseif istable( cells ) then
		for i = 1, #cells, 2 do
			local li = math.floor( tonumber( cells[i] ) or -1 )
			if MC.LocalIndexInRange( li ) then
				local id, orient = snapshotPaletteEntry( cache, palette, cells[i + 1] )
				if id and id ~= 0 then
					c.blocks[li] = id
					c.orients[li] = orient
					c.count = c.count + 1
				end
			end
		end
	end

	if c.count > 0 then
		MC.MarkChunkDirty( c.key )
	else
		MC.World[c.key] = nil
	end
	return c.count
end

function MC.LoadSnapshotSaveData( data )
	if not istable( data ) or not istable( data.chunks ) then return false end
	local palette = data.p or data.palette
	resetClientWorldForSnapshot( #data.chunks, 0 )

	local cache = {}
	local blocks = 0
	for _, chunkData in ipairs( data.chunks ) do
		if istable( chunkData ) then
			blocks = blocks + loadSnapshotChunk( chunkData, cache, palette )
		end
	end

	MC.SyncProgress.expected = blocks
	MC.SyncProgress.received = blocks
	MC.SyncProgress.doneChunks = #data.chunks
	MC.SyncProgress.active = false
	MC.SyncProgress.lastUpdate = CurTime()

	if MC.RefreshClientCollisionInterest then
		MC.RefreshClientCollisionInterest( true )
	end

	local queued = MC.SnapshotQueuedDeltas or {}
	MC.SnapshotQueuedDeltas = {}
	MC.SnapshotLoadingToken = nil
	for _, cell in ipairs( queued ) do
		applyNetCell( cell.bx, cell.by, cell.bz, cell.id, cell.orient )
	end

	return true
end

local function cleanHttpDataPath( path )
	path = string.Trim( tostring( path or "" ) )
	path = string.gsub( path, "\\", "/" )
	path = string.gsub( path, "^/+", "" )
	path = string.gsub( path, "%.%.+", "_" )
	return path
end

local function urlEscapePath( path )
	path = cleanHttpDataPath( path )
	return string.gsub( path, "([^%w%-%._~/])", function( c )
		return string.format( "%%%02X", string.byte( c ) )
	end )
end

local function ensureDataDirsForPath( path )
	local dir = string.GetPathFromFilename( cleanHttpDataPath( path ) )
	dir = string.gsub( dir or "", "/+$", "" )
	local built = ""
	for part in string.gmatch( dir, "[^/]+" ) do
		built = built == "" and part or ( built .. "/" .. part )
		file.CreateDir( built )
	end
end

local function parseHttpSaveJSON( raw )
	if not raw or raw == "" then return nil end
	if string.sub( raw, 1, 1 ) == "{" then return util.JSONToTable( raw ) end
	local json = util.Decompress( raw )
	return json and util.JSONToTable( json ) or nil
end

local function httpCachePath( state, relPath )
	return cleanHttpDataPath( ( state.cacheRoot or "mc/http_cache/default" ) .. "/" .. cleanHttpDataPath( relPath ) )
end

local function writeHttpCache( state, relPath, body )
	local path = httpCachePath( state, relPath )
	ensureDataDirsForPath( path )
	file.Write( path, body or "" )
end

local function httpURLForPath( state, relPath )
	return ( state.baseUrl or "" ) .. "/" .. urlEscapePath( relPath )
end

local function failHttpChunkSync( state, label, err )
	if not state or state.failed then return end
	state.failed = true
	if MC.HttpChunkSync == state then MC.HttpChunkSync = nil end

	local reason = string.Trim( tostring( label or "http" ) .. ": " .. tostring( err or "unknown" ) )
	MsgN( "[MC] HTTP chunk sync failed; falling back to server net: " .. reason )
	if MC.SyncProgress then
		MC.SyncProgress.active = false
		MC.SyncProgress.http = false
		MC.SyncProgress.lastUpdate = CurTime()
	end

	net.Start( "mc_http_failed" )
		net.WriteString( string.sub( reason, 1, 180 ) )
	net.SendToServer()
end

local function httpManifestRelativePath( state, relPath )
	relPath = cleanHttpDataPath( relPath )
	if relPath == "" then return nil end
	if string.StartWith( relPath, "mc/" ) then return relPath end
	return cleanHttpDataPath( ( state.baseDir or "" ) .. relPath )
end

local function httpPartEntryPath( entry )
	if istable( entry ) then return entry.path end
	return entry
end

local function httpPaletteEntry( state, cache, index )
	local pi = math.floor( tonumber( index ) or -1 )
	if pi < 0 then return 0, 0 end
	local cached = cache[pi]
	if cached then return cached.id, cached.orient end
	local spec = state.palette and state.palette[pi + 1]
	if not isstring( spec ) then return 0, 0 end
	local id, orient = MC.ParseBlockSpec( spec )
	id = math.floor( tonumber( id ) or 0 )
	orient = id ~= 0 and MC.NormalizeOrient( id, orient ) or 0
	cache[pi] = { id = id, orient = orient }
	return id, orient
end

local function decodeHttpLocalWithHeight( li, height )
	local cs, cs2 = MC.CS, MC.CS * MC.CS
	li = math.floor( tonumber( li ) or -1 )
	height = math.floor( tonumber( height ) or MC.CH )
	if li < 0 or li >= cs2 * height then return nil end
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / cs )
	local lx = rem - ly * cs
	return lx, ly, lz
end

local function httpChunkKeyForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function applyQueuedHttpDeltas( state, key )
	local queued = state.queuedDeltas and state.queuedDeltas[key]
	if not queued then return end
	state.queuedDeltas[key] = nil
	for _, cell in ipairs( queued ) do
		applyNetCell( cell.bx, cell.by, cell.bz, cell.id, cell.orient )
	end
end

local function queueHttpDelta( bx, by, bz, id, orient )
	local state = MC.HttpChunkSync
	if not state or not state.requestedKeys then return false end
	local key = httpChunkKeyForCell( bx, by, bz )
	if state.loadedKeys and state.loadedKeys[key] then return false end
	if not ( state.requestedKeys[key] or state.loadingKeys[key] or state.pendingKeys[key] ) then return false end
	state.queuedDeltas = state.queuedDeltas or {}
	state.queuedDeltas[key] = state.queuedDeltas[key] or {}
	state.queuedDeltas[key][#state.queuedDeltas[key] + 1] = {
		bx = bx,
		by = by,
		bz = bz,
		id = id,
		orient = orient,
	}
	return true
end

function MC.LoadHttpChunkRecord( key, record, partData )
	local state = MC.HttpChunkSync
	if not state or not istable( record ) or #record < 4 then return 0 end
	local srcCX = math.floor( tonumber( record[1] ) or 0 )
	local srcCY = math.floor( tonumber( record[2] ) or 0 )
	local srcCZ = math.floor( tonumber( record[3] ) or 0 )
	local cells = record[4]
	local savedHeight = math.floor( tonumber( partData and partData.h ) or tonumber( state.height ) or MC.CH )
	local cache = {}
	local touched = {}
	local blocks = 0

	local function loadOneCell( li, paletteIndex )
		local lx, ly, lz = decodeHttpLocalWithHeight( li, savedHeight )
		if not lx then return end
		local bx = srcCX * MC.CS + lx
		local by = srcCY * MC.CS + ly
		local bz = srcCZ * savedHeight + lz
		local cx, cy, cz, nli = MC.CellToChunk( bx, by, bz )
		if not MC.LocalIndexInRange( nli ) then return end
		local id, orient = httpPaletteEntry( state, cache, paletteIndex )
		if not id or id == 0 or ( MC.IsValidBlock and not MC.IsValidBlock( id ) ) then return end
		local chunk = MC.EnsureChunk( cx, cy, cz )
		chunk.orients = chunk.orients or {}
		if chunk.blocks[nli] ~= nil then return end
		chunk.blocks[nli] = id
		chunk.orients[nli] = MC.NormalizeOrient( id, orient )
		chunk.count = ( chunk.count or 0 ) + 1
		touched[chunk.key] = chunk
		blocks = blocks + 1
	end

	if isstring( cells ) then
		for liText, piText in string.gmatch( cells, "([^:;]+):([^:;]*):?[^;]*;?" ) do
			loadOneCell( liText, piText )
		end
	elseif istable( cells ) then
		for i = 1, #cells, 2 do
			loadOneCell( cells[i], cells[i + 1] )
		end
	end

	for touchedKey, chunk in pairs( touched ) do
		if chunk.count and chunk.count > 0 then
			reviveChunkEnt( chunk )
			MC.MarkChunkDirty( touchedKey )
			local cx, cy, cz = MC.ChunkKeyToCoords( touchedKey )
			if cx then markNeighbours( cx, cy, cz ) end
			MC.MarkChunkPhysDirty( touchedKey )
		else
			MC.World[touchedKey] = nil
		end
	end
	return blocks
end

local function finishHttpChunkLoad( state, key, record, partData )
	if not state.requestedKeys[key] then return end
	local blocks = MC.LoadHttpChunkRecord( key, record, partData )
	state.loadingKeys[key] = nil
	state.pendingKeys[key] = nil
	state.loadedKeys[key] = true
	beginProgressChunk( blocks )
	addProgressCells( blocks )
	finishProgressChunk( key )
	applyQueuedHttpDeltas( state, key )
end

local function processHttpPartWaiters( state, partNo )
	local waiting = state.pendingByPart[partNo]
	if not waiting then return end
	state.pendingByPart[partNo] = nil
	local partData = state.partCache[partNo]
	if not partData or not istable( partData.chunks ) then return end
	for key in pairs( waiting ) do
		local entry = state.chunkIndex and state.chunkIndex[key]
		local idx = entry and math.floor( tonumber( entry.index ) or 0 )
		local record = idx and partData.chunks[idx]
		if istable( record ) then
			finishHttpChunkLoad( state, key, record, partData )
		else
			state.loadingKeys[key] = nil
			state.pendingKeys[key] = nil
		end
	end
end

local function fetchHttpPart( state, partNo )
	partNo = math.floor( tonumber( partNo ) or 0 )
	if partNo <= 0 or state.partCache[partNo] or state.loadingParts[partNo] then return end
	local partPath = httpManifestRelativePath( state, httpPartEntryPath( state.parts and state.parts[partNo] ) )
	if not partPath then return end
	state.loadingParts[partNo] = true
	http.Fetch( httpURLForPath( state, partPath ), function( body )
		if MC.HttpChunkSync ~= state then return end
		state.loadingParts[partNo] = nil
		writeHttpCache( state, partPath, body )
		local data = parseHttpSaveJSON( body )
		if not istable( data ) or not istable( data.chunks ) then
			failHttpChunkSync( state, "part " .. tostring( partPath ), "invalid payload" )
			return
		end
		data.h = data.h or state.height
		data.p = data.p or state.palette
		state.partCache[partNo] = data
		processHttpPartWaiters( state, partNo )
	end, function( err )
		if MC.HttpChunkSync ~= state then return end
		state.loadingParts[partNo] = nil
		failHttpChunkSync( state, "part " .. tostring( partPath ), err )
	end )
end

function MC.QueueHttpChunk( key )
	local state = MC.HttpChunkSync
	if not state then return false end
	key = tostring( key or "" )
	if key == "" or state.loadedKeys[key] then return true end
	state.requestedKeys[key] = true
	if not state.ready then
		state.pendingKeys[key] = true
		return true
	end
	local entry = state.chunkIndex and state.chunkIndex[key]
	if not istable( entry ) then
		state.requestedKeys[key] = nil
		return false
	end
	local partNo = math.floor( tonumber( entry.part ) or 0 )
	local idx = math.floor( tonumber( entry.index ) or 0 )
	if partNo <= 0 or idx <= 0 then
		state.requestedKeys[key] = nil
		return false
	end
	state.loadingKeys[key] = true
	local partData = state.partCache[partNo]
	if partData and istable( partData.chunks ) and istable( partData.chunks[idx] ) then
		finishHttpChunkLoad( state, key, partData.chunks[idx], partData )
		return true
	end
	state.pendingByPart[partNo] = state.pendingByPart[partNo] or {}
	state.pendingByPart[partNo][key] = true
	fetchHttpPart( state, partNo )
	return true
end

local function finishHttpManifest( state, body )
	local data = parseHttpSaveJSON( body )
	if not istable( data ) or not istable( data.parts ) or not istable( data.chunkIndex ) then
		failHttpChunkSync( state, "manifest", "invalid payload" )
		return
	end
	writeHttpCache( state, state.manifestPath, body )
	state.manifest = data
	state.palette = data.p or data.palette or {}
	state.chunkIndex = data.chunkIndex or {}
	state.parts = data.parts or {}
	state.height = math.floor( tonumber( data.h ) or tonumber( state.height ) or MC.CH )
	state.ready = true
	for key in pairs( state.pendingKeys ) do
		MC.QueueHttpChunk( key )
	end
end

function MC.BeginHttpChunkSync( baseUrl, manifestPath, chunks, blocks, height )
	baseUrl = string.Trim( tostring( baseUrl or "" ) )
	baseUrl = string.gsub( baseUrl, "/+$", "" )
	manifestPath = cleanHttpDataPath( manifestPath )
	if baseUrl == "" or manifestPath == "" then return false end
	local token = util.CRC( baseUrl .. "|" .. manifestPath )
	local state = {
		baseUrl = baseUrl,
		manifestPath = manifestPath,
		baseDir = string.GetPathFromFilename( manifestPath ),
		cacheRoot = "mc/http_cache/" .. token,
		height = math.floor( tonumber( height ) or MC.CH ),
		palette = {},
		chunkIndex = {},
		parts = {},
		partCache = {},
		loadingParts = {},
		pendingByPart = {},
		pendingKeys = {},
		requestedKeys = {},
		loadingKeys = {},
		loadedKeys = {},
		queuedDeltas = {},
		ready = false,
	}
	MC.HttpChunkSync = state
	resetClientWorldForSnapshot( 0, 0 )
	MC.SyncProgress.http = true
	MC.SyncProgress.snapshot = false
	MC.SyncProgress.httpTotalChunks = math.max( 0, math.floor( tonumber( chunks ) or 0 ) )
	MC.SyncProgress.httpTotalBlocks = math.max( 0, math.floor( tonumber( blocks ) or 0 ) )
	http.Fetch( httpURLForPath( state, manifestPath ), function( body )
		if MC.HttpChunkSync == state then finishHttpManifest( state, body ) end
	end, function( err )
		if MC.HttpChunkSync == state then
			failHttpChunkSync( state, "manifest", err )
		end
	end )
	return true
end

net.Receive( "mc_http_manifest", function()
	local baseUrl = net.ReadString()
	local manifestPath = net.ReadString()
	local chunks = net.ReadUInt( 32 )
	local blocks = net.ReadUInt( 32 )
	local height = net.ReadUInt( 16 )
	MC.BeginHttpChunkSync( baseUrl, manifestPath, chunks, blocks, height )
end )

net.Receive( "mc_http_chunk", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	MC.QueueHttpChunk( MC.ChunkKey( cx, cy, cz ) )
end )

net.Receive( "mc_http_chunk_bulk", function()
	local count = net.ReadUInt( Net.COUNT_BITS )
	for _ = 1, count do
		local cx = net.ReadInt( Net.COORD_BITS )
		local cy = net.ReadInt( Net.COORD_BITS )
		local cz = net.ReadInt( Net.COORD_BITS )
		MC.QueueHttpChunk( MC.ChunkKey( cx, cy, cz ) )
	end
end )

net.Receive( "mc_snapshot_begin", function()
	local token = net.ReadString()
	local isError = net.ReadBool()
	local message = net.ReadString()
	local expectedParts = net.ReadUInt( 32 )
	local totalBytes = net.ReadUInt( 32 )
	local chunks = net.ReadUInt( 32 )
	local blocks = net.ReadUInt( 32 )
	if isError or token == "" or expectedParts < 1 or totalBytes < 1 then
		MsgN( "[MC] snapshot sync failed: " .. tostring( message ) )
		return
	end

	MC.SnapshotLoadingToken = token
	MC.SnapshotQueuedDeltas = {}
	MC.SnapshotBuffers[token] = {
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		chunks = chunks,
		blocks = blocks,
		receivedParts = 0,
		receivedBytes = 0,
		parts = {},
	}
	MC.SyncProgress = {
		expected = blocks,
		received = 0,
		chunks = chunks,
		doneChunks = 0,
		active = true,
		lastUpdate = CurTime(),
		snapshot = true,
	}
end )

net.Receive( "mc_snapshot_part", function()
	local token = net.ReadString()
	local index = net.ReadUInt( 32 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	local download = MC.SnapshotBuffers[token]
	if not download or index < 1 or index > download.expectedParts then return end
	if len < 1 or len > 60000 or not chunk or #chunk ~= len or download.parts[index] then return end

	download.parts[index] = chunk
	download.receivedParts = download.receivedParts + 1
	download.receivedBytes = download.receivedBytes + len
	MC.SyncProgress.received = math.min( download.blocks, math.floor( download.blocks * download.receivedBytes / math.max( 1, download.totalBytes ) ) )
	MC.SyncProgress.lastUpdate = CurTime()
	sendSnapshotAck( token, len, false )

	if download.receivedBytes > download.totalBytes then
		MC.SnapshotBuffers[token] = nil
		if MC.SnapshotLoadingToken == token then MC.SnapshotLoadingToken = nil end
		return
	end
	if download.receivedParts < download.expectedParts then return end

	local payload = table.concat( download.parts )
	MC.SnapshotBuffers[token] = nil
	if #payload ~= download.totalBytes then
		if MC.SnapshotLoadingToken == token then MC.SnapshotLoadingToken = nil end
		return
	end

	local json = util.Decompress( payload )
	local data = json and util.JSONToTable( json ) or nil
	if not data or not MC.LoadSnapshotSaveData( data ) then
		if MC.SnapshotLoadingToken == token then MC.SnapshotLoadingToken = nil end
		MsgN( "[MC] snapshot sync failed: invalid payload" )
		return
	end
	sendSnapshotAck( token, 0, true )
end )

net.Receive( "mc_full", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )

	local c = resetChunk( cx, cy, cz )
	beginProgressChunk( count )
	readCellsIntoChunk( c, count )
	addProgressCells( count )
	reviveChunkEnt( c )
	if c.count == 0 then MC.World[c.key] = nil end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( c.key )
	finishProgressChunk( c.key )
end )

net.Receive( "mc_full_begin", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local expected = net.ReadUInt( Net.COUNT_BITS )
	queueFullAck( MC.EstimateSyncBeginBytes() )
	local c = resetChunk( cx, cy, cz )
	MC.PendingFull[c.key] = { expected = expected, received = 0 }
	beginProgressChunk( expected )
	reviveChunkEnt( c )
end )

net.Receive( "mc_full_part", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local count = net.ReadUInt( Net.COUNT_BITS )
	queueFullAck( MC.EstimateSyncPartBytes( count ) )
	local c = MC.EnsureChunk( cx, cy, cz )
	readCellsIntoChunk( c, count )
	addProgressCells( count )
	reviveChunkEnt( c )

	local pending = MC.PendingFull[c.key]
	if pending then pending.received = pending.received + count end
end )

net.Receive( "mc_full_end", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	queueFullAck( MC.EstimateSyncEndBytes(), true )
	local key = MC.ChunkKey( cx, cy, cz )
	local c = MC.GetChunkByKey( key )
	MC.PendingFull[key] = nil
	if c and c.count == 0 then
		MC.World[key] = nil
	end

	markNeighbours( cx, cy, cz )
	MC.MarkChunkPhysDirty( key )
	finishProgressChunk( key )
end )

net.Receive( "mc_set", function()
	local bx = net.ReadInt( Net.COORD_BITS )
	local by = net.ReadInt( Net.COORD_BITS )
	local bz = net.ReadInt( Net.COORD_BITS )
	local id = net.ReadUInt( Net.ID_BITS )
	local orient = net.ReadUInt( Net.ORIENT_BITS )

	queueSnapshotDelta( bx, by, bz, id, orient )
	if queueHttpDelta( bx, by, bz, id, orient ) then return end
	applyNetCell( bx, by, bz, id, orient )
end )

net.Receive( "mc_set_bulk", function()
	local count = net.ReadUInt( Net.COUNT_BITS )
	for _ = 1, count do
		local bx = net.ReadInt( Net.COORD_BITS )
		local by = net.ReadInt( Net.COORD_BITS )
		local bz = net.ReadInt( Net.COORD_BITS )
		local id = net.ReadUInt( Net.ID_BITS )
		local orient = net.ReadUInt( Net.ORIENT_BITS )

		queueSnapshotDelta( bx, by, bz, id, orient )
		if not queueHttpDelta( bx, by, bz, id, orient ) then
			applyNetCell( bx, by, bz, id, orient )
		end
	end
end )

net.Receive( "mc_unload_chunk", function()
	local cx = net.ReadInt( Net.COORD_BITS )
	local cy = net.ReadInt( Net.COORD_BITS )
	local cz = net.ReadInt( Net.COORD_BITS )
	local key = MC.ChunkKey( cx, cy, cz )

	MC.FreeChunkMesh( key )
	local e = MC.ChunkEnts and MC.ChunkEnts[key]
	if IsValid( e ) then e:PhysicsDestroy() end
	if MC.ChunkEnts then MC.ChunkEnts[key] = nil end
	MC.World[key] = nil
	MC.MeshDirty[key] = nil
	MC.PhysDirty[key] = nil
	MC.PhysDirtyPriority[key] = nil
	MC.PendingFull[key] = nil
	local httpState = MC.HttpChunkSync
	if httpState then
		httpState.requestedKeys[key] = nil
		httpState.pendingKeys[key] = nil
		httpState.loadingKeys[key] = nil
		httpState.loadedKeys[key] = nil
		if httpState.queuedDeltas then httpState.queuedDeltas[key] = nil end
		for _, waiting in pairs( httpState.pendingByPart or {} ) do
			waiting[key] = nil
		end
	end

	for predKey, pending in pairs( MC.PendingPredictions or {} ) do
		local pcx, pcy, pcz = MC.CellToChunk( pending.bx, pending.by, pending.bz )
		if pcx == cx and pcy == cy and pcz == cz then
			MC.PendingPredictions[predKey] = nil
		end
	end
end )

net.Receive( "mc_clear", function()
	MC.FreeAllMeshes()
	for key, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then
			e:PhysicsDestroy()
		end
	end
	MC.World = {}
	MC.MeshDirty = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PendingFull = {}
	MC.PendingPredictions = {}
	MC.HttpChunkSync = nil
	MC.SyncProgress = { expected = 0, received = 0, chunks = 0, doneChunks = 0, active = false, lastUpdate = CurTime() }
	PendingFullAckBytes = 0
end )

hook.Add( "Think", "mc_prediction_rollback", rollbackExpiredPredictions )
