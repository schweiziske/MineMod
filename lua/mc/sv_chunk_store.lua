--[[----------------------------------------------------------------------------
	Lazy v8 save chunk store.

	The manifest stays loaded, while imported base chunks remain in part files
	until player/entity interest asks for them. Player edits are recorded in a
	separate overlay so base parts remain read-only.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Store = SV.ChunkStore or {}
SV.ChunkStore = Store

local function resetTables()
	Store.Manifest = nil
	Store.ManifestPath = nil
	Store.BaseDir = nil
	Store.Palette = {}
	Store.ChunkIndex = {}
	Store.Parts = {}
	Store.PartCache = {}
	Store.PartOrder = {}
	Store.LoadedKeys = {}
	Store.QueuedKeys = {}
	Store.LoadQueue = {}
	Store.EditChunks = {}
	Store.EditOverlayPath = nil
	Store.Active = false
end

function Store.Reset()
	resetTables()
end

if Store.Manifest == nil then
	resetTables()
end

local function cfgInt( cv, fallback, minValue, maxValue )
	local v
	if cv and cv.GetInt then
		v = cv:GetInt()
	else
		v = fallback
	end
	v = math.floor( tonumber( v ) or fallback or 0 )
	if minValue then v = math.max( minValue, v ) end
	if maxValue then v = math.min( maxValue, v ) end
	return v
end

local function cfgFloat( cv, fallback, minValue, maxValue )
	local v
	if cv and cv.GetFloat then
		v = cv:GetFloat()
	else
		v = fallback
	end
	v = tonumber( v ) or fallback or 0
	if minValue then v = math.max( minValue, v ) end
	if maxValue then v = math.min( maxValue, v ) end
	return v
end

local function readSaveJSON( path )
	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return nil, "empty_file" end
	if string.sub( raw, 1, 1 ) == "{" then
		return util.JSONToTable( raw ), nil
	end
	local json = util.Decompress( raw )
	if not json then return nil, "decompress_failed" end
	return util.JSONToTable( json ), nil
end

local function stripExtension( path )
	return string.gsub( tostring( path or "" ), "%.[^/%.]*$", "" )
end

local function cleanDataPath( path )
	path = string.Trim( tostring( path or "" ) )
	path = string.gsub( path, "\\", "/" )
	path = string.gsub( path, "^/+", "" )
	path = string.gsub( path, "%.%.+", "_" )
	return path
end

local function manifestRelativePath( path )
	path = cleanDataPath( path )
	if path == "" then return nil end
	if string.StartWith( path, "mc/" ) then return path end
	return ( Store.BaseDir or "" ) .. path
end

local function partEntryPath( entry )
	if istable( entry ) then return entry.path end
	return entry
end

local function overlayPathForManifest( manifest, manifestPath )
	local overlay = manifest and manifest.editOverlay
	if isstring( overlay ) and overlay ~= "" then
		return manifestRelativePath( overlay )
	end
	return stripExtension( manifestPath ) .. "_edits.dat"
end

local function removePartOrderValue( partNo )
	for i = #Store.PartOrder, 1, -1 do
		if Store.PartOrder[i] == partNo then
			table.remove( Store.PartOrder, i )
		end
	end
end

local function touchPart( partNo )
	removePartOrderValue( partNo )
	Store.PartOrder[#Store.PartOrder + 1] = partNo
end

local function evictPartCache()
	local maxParts = cfgInt( MC.Config.ChunkStorePartCache, MC.Config.ChunkStorePartCache or 8, 1, 128 )
	while #Store.PartOrder > maxParts do
		local old = table.remove( Store.PartOrder, 1 )
		if old then Store.PartCache[old] = nil end
	end
end

local function loadPart( partNo )
	partNo = math.floor( tonumber( partNo ) or 0 )
	if partNo <= 0 then return nil, "invalid_part" end
	local cached = Store.PartCache[partNo]
	if cached then
		touchPart( partNo )
		return cached, nil
	end

	local entry = Store.Parts[partNo]
	local partPath = manifestRelativePath( partEntryPath( entry ) )
	if not partPath then return nil, "invalid_part_path" end
	if not file.Exists( partPath, "DATA" ) then return nil, "missing_part: " .. partPath end

	local data, err = readSaveJSON( partPath )
	if err then return nil, err end
	if not istable( data ) or not istable( data.chunks ) then return nil, "invalid_part: " .. partPath end
	data.cs = data.cs or ( Store.Manifest and Store.Manifest.cs ) or MC.CS
	data.h = data.h or ( Store.Manifest and Store.Manifest.h ) or MC.CH
	data.p = data.p or Store.Palette

	Store.PartCache[partNo] = data
	touchPart( partNo )
	evictPartCache()
	return data, nil
end

local function paletteEntry( cache, index )
	index = math.floor( tonumber( index ) or -1 )
	if index < 0 then return 0, 0 end
	local spec = Store.Palette[index + 1]
	if not spec then return 0, 0 end

	local cached = cache[spec]
	if cached then return cached[1], cached[2] end

	local id, orient = MC.ParseBlockSpec( spec )
	id = id or 0
	orient = MC.NormalizeOrient( id, orient )
	cache[spec] = { id, orient }
	return id, orient
end

local function decodeLocalWithGeometry( li, chunkSize, height )
	chunkSize = math.floor( tonumber( chunkSize ) or MC.CS )
	if chunkSize <= 0 then chunkSize = MC.CS end
	li = math.floor( tonumber( li ) or -1 )
	height = math.floor( tonumber( height ) or MC.CH )
	if height <= 0 then height = MC.CH end
	local cs2 = chunkSize * chunkSize
	if li < 0 or li >= cs2 * height then return nil end
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / chunkSize )
	local lx = rem - ly * chunkSize
	return lx, ly, lz
end

local function savedChunkSizeForManifest()
	local savedChunkSize = math.floor( tonumber( Store.Manifest and Store.Manifest.cs ) or MC.CS )
	if savedChunkSize <= 0 then savedChunkSize = MC.CS end
	return savedChunkSize
end

local function savedHeightForManifest()
	local savedHeight = math.floor( tonumber( Store.Manifest and Store.Manifest.h ) or MC.CH )
	if savedHeight <= 0 then savedHeight = MC.CH end
	return savedHeight
end

local function baseChunkEntriesForRuntimeKey( key )
	local rx, ry, rz = MC.ChunkKeyToCoords( key )
	if not rx then return {} end
	local savedChunkSize = savedChunkSizeForManifest()
	local savedHeight = savedHeightForManifest()
	local minBX, maxBX = rx * MC.CS, rx * MC.CS + MC.CS - 1
	local minBY, maxBY = ry * MC.CS, ry * MC.CS + MC.CS - 1
	local minBZ, maxBZ = rz * MC.CH, rz * MC.CH + MC.CH - 1
	local minSX, maxSX = math.floor( minBX / savedChunkSize ), math.floor( maxBX / savedChunkSize )
	local minSY, maxSY = math.floor( minBY / savedChunkSize ), math.floor( maxBY / savedChunkSize )
	local minSZ, maxSZ = math.floor( minBZ / savedHeight ), math.floor( maxBZ / savedHeight )
	local entries = {}

	for sz = minSZ, maxSZ do
		for sy = minSY, maxSY do
			for sx = minSX, maxSX do
				local savedKey = MC.ChunkKey( sx, sy, sz )
				local entry = Store.ChunkIndex and Store.ChunkIndex[savedKey]
				if istable( entry ) then
					entries[#entries + 1] = { key = savedKey, entry = entry }
				end
			end
		end
	end

	return entries
end

local function ensureChunkForKey( key )
	local chunk = MC.GetChunkByKey( key )
	if chunk then return chunk end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return nil end
	return MC.EnsureChunk( cx, cy, cz )
end

function Store.IsLazyWorld()
	return Store.Active == true
end

function Store.HasBaseChunk( key )
	if not Store.IsLazyWorld() then return false end
	key = tostring( key or "" )
	return #baseChunkEntriesForRuntimeKey( key ) > 0
end

function Store.HasChunkEdits( key )
	if not Store.IsLazyWorld() then return false end
	key = tostring( key or "" )
	return Store.EditChunks and Store.EditChunks[key] ~= nil
end

function Store.HttpManifestPayload()
	if not Store.IsLazyWorld() or not Store.Manifest then return nil end
	local chunks = 0
	for _ in pairs( Store.ChunkIndex or {} ) do chunks = chunks + 1 end
	return {
		path = Store.ManifestPath,
		chunks = chunks,
		blocks = math.max( 0, math.floor( tonumber( SV.BlockCount ) or tonumber( Store.Manifest.stats and Store.Manifest.stats.blocks ) or 0 ) ),
		chunkSize = savedChunkSizeForManifest(),
		height = savedHeightForManifest(),
	}
end

function Store.LoadLazyManifest( manifest, manifestPath )
	resetTables()
	Store.Active = true
	Store.Manifest = manifest
	Store.ManifestPath = cleanDataPath( manifestPath )
	Store.BaseDir = string.GetPathFromFilename( Store.ManifestPath or "" )
	Store.Palette = manifest.p or manifest.palette or {}
	Store.ChunkIndex = manifest.chunkIndex or {}
	Store.Parts = manifest.parts or {}
	Store.EditOverlayPath = overlayPathForManifest( manifest, Store.ManifestPath )

	if Store.EditOverlayPath and file.Exists( Store.EditOverlayPath, "DATA" ) then
		local overlay = readSaveJSON( Store.EditOverlayPath )
		if istable( overlay ) and istable( overlay.edits ) then
			Store.EditChunks = overlay.edits
		end
		if istable( overlay ) and tonumber( overlay.blockCount ) then
			SV.BlockCount = math.max( 0, math.floor( tonumber( overlay.blockCount ) or 0 ) )
		end
	end

	if not tonumber( SV.BlockCount ) or SV.BlockCount <= 0 then
		SV.BlockCount = tonumber( manifest.stats and manifest.stats.blocks ) or 0
	end
	SV.StreamInterestDirty = true
	return true
end

local function applyCellToChunk( chunk, li, id, orient )
	li = math.floor( tonumber( li ) or -1 )
	id = math.floor( tonumber( id ) or 0 )
	orient = math.floor( tonumber( orient ) or 0 )
	if not chunk or not MC.LocalIndexInRange( li ) then return end
	if id == 0 then
		if chunk.blocks[li] ~= nil then
			chunk.blocks[li] = nil
			if chunk.orients then chunk.orients[li] = nil end
			chunk.count = math.max( 0, ( chunk.count or 0 ) - 1 )
		end
		return
	end
	if not MC.IsValidBlock( id ) then return end
	if chunk.blocks[li] == nil then chunk.count = ( chunk.count or 0 ) + 1 end
	chunk.blocks[li] = id
	chunk.orients = chunk.orients or {}
	chunk.orients[li] = MC.NormalizeOrient( id, orient )
end

function Store.ApplyOverlayToChunk( chunk )
	if not chunk or not chunk.key then return chunk end
	local edits = Store.EditChunks and Store.EditChunks[chunk.key]
	if not istable( edits ) then return chunk end
	for li, edit in pairs( edits ) do
		if istable( edit ) then
			applyCellToChunk( chunk, li, edit.id, edit.orient )
		end
	end
	return chunk
end

local function loadBaseChunkIntoWorld( key, record )
	if not istable( record ) or #record < 4 then return nil end
	local srcCX = math.floor( tonumber( record[1] ) or 0 )
	local srcCY = math.floor( tonumber( record[2] ) or 0 )
	local srcCZ = math.floor( tonumber( record[3] ) or 0 )
	local cells = record[4]
	local savedChunkSize = savedChunkSizeForManifest()
	local savedHeight = savedHeightForManifest()
	local cache = {}
	local touched = {}

	local function loadOneCell( li, paletteIndex )
		local lx, ly, lz = decodeLocalWithGeometry( li, savedChunkSize, savedHeight )
		if not lx then return end
		local bx = srcCX * savedChunkSize + lx
		local by = srcCY * savedChunkSize + ly
		local bz = srcCZ * savedHeight + lz
		local cx, cy, cz, nli = MC.CellToChunk( bx, by, bz )
		local targetKey = MC.ChunkKey( cx, cy, cz )
		local chunk = MC.EnsureChunk( cx, cy, cz )
		local id, orient = paletteEntry( cache, paletteIndex )
		if MC.LocalIndexInRange( nli ) and MC.IsValidBlock( id ) and chunk.blocks[nli] == nil then
			chunk.blocks[nli] = id
			chunk.orients[nli] = MC.NormalizeOrient( id, orient )
			chunk.count = chunk.count + 1
			touched[targetKey] = chunk
		end
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
		Store.ApplyOverlayToChunk( chunk )
		if chunk.count <= 0 then
			MC.World[touchedKey] = nil
		end
	end

	return MC.GetChunkByKey( key ), touched
end

function Store.HydrateChunkNow( key, priority )
	if not Store.IsLazyWorld() then return MC.GetChunkByKey( key ) end
	key = tostring( key or "" )
	if key == "" then return nil end
	local existing = MC.GetChunkByKey( key )
	if existing and Store.LoadedKeys[key] then
		Store.LoadedKeys[key] = true
		return existing
	end

	local chunk = existing
	local entries = baseChunkEntriesForRuntimeKey( key )
	for _, item in ipairs( entries ) do
		local entry = item.entry
		local partData, err = loadPart( entry.part )
		if not partData then
			Store.LastError = err
			Store.QueuedKeys[key] = nil
			return nil
		end
		local idx = math.floor( tonumber( entry.index ) or 0 )
		local record = partData and partData.chunks and partData.chunks[idx]
		if not istable( record ) then
			Store.LastError = "invalid_chunk_index"
			Store.QueuedKeys[key] = nil
			return nil
		end
		local loadedChunk, touched = loadBaseChunkIntoWorld( key, record )
		chunk = chunk or loadedChunk
		for touchedKey in pairs( touched or {} ) do
			Store.LoadedKeys[touchedKey] = true
		end
	end

	if not chunk and Store.EditChunks and Store.EditChunks[key] then
		chunk = ensureChunkForKey( key )
		Store.ApplyOverlayToChunk( chunk )
		if chunk and chunk.count <= 0 then
			MC.World[key] = nil
			chunk = nil
		end
	end

	Store.LoadedKeys[key] = true
	Store.QueuedKeys[key] = nil
	if chunk and chunk.count and chunk.count > 0 and priority then
		SV.EnsureChunkEnt( chunk )
		SV.MarkPhysDirty( key, true )
	end
	return chunk
end

function Store.QueueChunkLoad( key, priority )
	if not Store.IsLazyWorld() then return end
	key = tostring( key or "" )
	if key == "" or Store.LoadedKeys[key] or Store.QueuedKeys[key] then return end
	if #baseChunkEntriesForRuntimeKey( key ) == 0 and not ( Store.EditChunks and Store.EditChunks[key] ) then return end
	Store.QueuedKeys[key] = true
	Store.LoadQueue[#Store.LoadQueue + 1] = { key = key, priority = priority == true }
end

function Store.TickChunkLoads()
	if not Store.IsLazyWorld() or #Store.LoadQueue == 0 then return end
	table.sort( Store.LoadQueue, function( a, b )
		return ( a.priority and 1 or 0 ) > ( b.priority and 1 or 0 )
	end )
	local maxLoads = cfgInt( MC.Config.ChunkStoreLoadsPerTick, MC.Config.ChunkStoreLoadsPerTick or 8, 1, 128 )
	local frameMS = cfgFloat( MC.Config.ChunkStoreFrame, MC.Config.ChunkStoreFrameMS or 3, 0.1, 20 )
	local deadline = SysTime() + frameMS / 1000
	local loaded = 0
	while #Store.LoadQueue > 0 and loaded < maxLoads and SysTime() < deadline do
		local item = table.remove( Store.LoadQueue, 1 )
		Store.QueuedKeys[item.key] = nil
		Store.HydrateChunkNow( item.key, item.priority )
		loaded = loaded + 1
	end
	if loaded > 0 then SV.StreamInterestDirty = true end
end

function Store.RecordEdit( bx, by, bz, id, orient )
	if not Store.IsLazyWorld() then return end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	local edits = Store.EditChunks[key]
	if not edits then
		edits = {}
		Store.EditChunks[key] = edits
	end
	edits[tostring( li )] = {
		id = math.floor( tonumber( id ) or 0 ),
		orient = math.floor( tonumber( orient ) or 0 ),
	}
end

function Store.SaveOverlay()
	return {
		v = 1,
		base = Store.ManifestPath,
		blockCount = math.max( 0, math.floor( tonumber( SV.BlockCount ) or 0 ) ),
		edits = Store.EditChunks or {},
	}
end

timer.Create( "mc_chunk_store_load", 0.05, 0, function()
	if Store.TickChunkLoads then Store.TickChunkLoads() end
end )
