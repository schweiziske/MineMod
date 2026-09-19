--[[----------------------------------------------------------------------------
	Lazy v8/v10 save chunk store.

	The manifest stays loaded, while imported base chunks remain in part files
	until player/entity interest asks for them. Player edits are recorded in a
	separate overlay so base parts remain read-only.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Store = SV.ChunkStore or {}
SV.ChunkStore = Store

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local function resetTables()
	Store.Manifest = nil
	Store.ManifestPath = nil
	Store.BaseDir = nil
	Store.Realm = "DATA"
	Store.Palette = {}
	Store.ChunkIndex = {}
	Store.Parts = {}
	Store.PartCache = {}
	Store.PartOrder = {}
	Store.NumericPalette = nil
	Store.NumericPaletteSource = nil
	Store.LoadedKeys = {}
	Store.QueuedKeys = {}
	Store.LoadQueue = {}
	Store.EditChunks = {}
	Store.EditOverlayPath = nil
	Store.MinRuntimeCZ = nil
	Store.MaxRuntimeCZ = nil
	Store.LastError = nil
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

local function timingAdd( timing, field, value )
	if timing then timing[field] = ( timing[field] or 0 ) + ( tonumber( value ) or 0 ) end
end

local function readSaveJSON( path, timing, realm )
	local readStarted = timing and SysTime() or nil
	local raw = file.Read( path, realm or Store.Realm or "DATA" )
	if timing then
		timingAdd( timing, "fileReadMS", ( SysTime() - readStarted ) * 1000 )
		timingAdd( timing, "storedBytes", raw and #raw or 0 )
	end
	if not raw or raw == "" then return nil, "empty_file" end
	if string.sub( raw, 1, 1 ) == "{" then
		if timing then timingAdd( timing, "jsonBytes", #raw ) end
		local jsonStarted = timing and SysTime() or nil
		local data = util.JSONToTable( raw )
		if timing then timingAdd( timing, "jsonMS", ( SysTime() - jsonStarted ) * 1000 ) end
		return data, nil
	end
	local decompressStarted = timing and SysTime() or nil
	local json = util.Decompress( raw )
	if timing then
		timingAdd( timing, "decompressMS", ( SysTime() - decompressStarted ) * 1000 )
		timingAdd( timing, "jsonBytes", json and #json or 0 )
	end
	if not json then return nil, "decompress_failed" end
	local jsonStarted = timing and SysTime() or nil
	local data = util.JSONToTable( json )
	if timing then timingAdd( timing, "jsonMS", ( SysTime() - jsonStarted ) * 1000 ) end
	return data, nil
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

-- The MCB4 sidecar ships as .json because GMAD's whitelist rejects .mcb and
-- .dat, but imports made before that switch still spell it .mcb. Accept either
-- spelling for the same part so a manifest stays portable between them.
local FAST_SUFFIXES = { ".json", ".mcb" }

local function resolveFastPath( path, forbidden )
	if not isstring( path ) or path == "" then return nil end
	local realm = Store.Realm or "DATA"
	if file.Exists( path, realm ) then return path end
	for _, suffix in ipairs( FAST_SUFFIXES ) do
		if string.EndsWith( path, suffix ) then
			local stem = string.sub( path, 1, #path - #suffix )
			for _, alt in ipairs( FAST_SUFFIXES ) do
				local candidate = stem .. alt
				-- Never fall through onto the side-data lane: that file is real
				-- JSON and would feed text into the MCB4 decoder.
				if alt ~= suffix and candidate ~= forbidden and file.Exists( candidate, realm ) then
					return candidate
				end
			end
			break
		end
	end
	return nil
end

local function numericPalette()
	if Store.NumericPaletteSource == Store.Palette then return Store.NumericPalette end
	Store.NumericPaletteSource = Store.Palette
	Store.NumericPalette = false
	if not istable( Store.Palette ) then return nil end
	local resolved = {}
	for index = 1, #Store.Palette do
		local value = Store.Palette[index]
		local stateId = isnumber( value ) and math.floor( value )
			or ( isstring( value ) and MC.ParseBlockState and MC.ParseBlockState( value ) or nil )
		if stateId == nil or MC.IsValidBlockState and not MC.IsValidBlockState( stateId ) then return nil end
		resolved[index] = stateId
	end
	Store.NumericPalette = resolved
	return resolved
end

local function readFastFragment( partNo, entry, timing )
	local part = Store.Parts[math.floor( tonumber( partNo ) or 0 )]
	if not istable( part ) or part.fastFormat ~= "MCB4" then return nil, "fast_part_unavailable" end
	local offset = math.floor( tonumber( entry and entry.fastOffset ) or -1 )
	local length = math.floor( tonumber( entry and entry.fastBytes ) or -1 )
	local declaredBytes = math.floor( tonumber( part.fastBytes ) or -1 )
	if offset < 0 or length < 16 or declaredBytes < 0 or offset + length > declaredBytes then
		return nil, "invalid_fast_range"
	end
	local fastPath = resolveFastPath( manifestRelativePath( part.fastPath ), manifestRelativePath( partEntryPath( part ) ) )
	if not fastPath then return nil, "missing_fast_part" end
	local started = timing and SysTime() or nil
	local handle = file.Open( fastPath, "rb", Store.Realm or "DATA" )
	if not handle then return nil, "fast_open_failed" end
	handle:Seek( offset )
	local fragment = handle:Read( length )
	handle:Close()
	if timing then
		timingAdd( timing, "fastReadMS", ( SysTime() - started ) * 1000 )
		timingAdd( timing, "fastBytes", isstring( fragment ) and #fragment or 0 )
	end
	if not isstring( fragment ) or #fragment ~= length then return nil, "fast_short_read" end
	return fragment
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

local function loadPart( partNo, timing )
	local loadStarted = timing and SysTime() or nil
	if timing then timingAdd( timing, "partLoads", 1 ) end
	partNo = math.floor( tonumber( partNo ) or 0 )
	if partNo <= 0 then
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return nil, "invalid_part"
	end
	local cached = Store.PartCache[partNo]
	if cached then
		if timing then timingAdd( timing, "partCacheHits", 1 ) end
		touchPart( partNo )
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return cached, nil
	end
	if timing then timingAdd( timing, "partCacheMisses", 1 ) end

	local entry = Store.Parts[partNo]
	local partPath = manifestRelativePath( partEntryPath( entry ) )
	if not partPath then
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return nil, "invalid_part_path"
	end
	if not file.Exists( partPath, Store.Realm or "DATA" ) then
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return nil, "missing_part: " .. partPath
	end

	local data, err = readSaveJSON( partPath, timing )
	if err then
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return nil, err
	end
	if not istable( data ) or not istable( data.chunks ) then
		if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
		return nil, "invalid_part: " .. partPath
	end
	data.cs = data.cs or ( Store.Manifest and Store.Manifest.cs ) or MC.CS
	data.h = data.h or ( Store.Manifest and Store.Manifest.h ) or MC.CH
	data.p = data.p or Store.Palette

	Store.PartCache[partNo] = data
	touchPart( partNo )
	evictPartCache()
	if timing then timingAdd( timing, "partLoadMS", ( SysTime() - loadStarted ) * 1000 ) end
	return data, nil
end

local function paletteState( cache, index )
	index = math.floor( tonumber( index ) or -1 )
	if index < 0 then return nil end
	local spec = Store.Palette[index + 1]
	if not isstring( spec ) then return nil end
	cache._states = cache._states or {}
	local cached = cache._states[spec]
	if cached ~= nil then return cached ~= false and cached or nil end
	local stateId = MC.ParseBlockState( spec )
	cache._states[spec] = stateId or false
	return stateId
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

local function includeRuntimeCZ( cz )
	cz = tonumber( cz )
	if cz == nil then return end
	cz = math.floor( cz )
	if Store.MinRuntimeCZ == nil or cz < Store.MinRuntimeCZ then Store.MinRuntimeCZ = cz end
	if Store.MaxRuntimeCZ == nil or cz > Store.MaxRuntimeCZ then Store.MaxRuntimeCZ = cz end
end

local function includeRuntimeChunkKey( key )
	local _, _, cz = MC.ChunkKeyToCoords( key )
	includeRuntimeCZ( cz )
end

local function rebuildVerticalBounds()
	Store.MinRuntimeCZ = nil
	Store.MaxRuntimeCZ = nil
	local savedHeight = savedHeightForManifest()
	for savedKey in pairs( Store.ChunkIndex or {} ) do
		local _, _, savedCZ = MC.ChunkKeyToCoords( savedKey )
		if savedCZ ~= nil then
			local minBZ = savedCZ * savedHeight
			local maxBZ = minBZ + savedHeight - 1
			includeRuntimeCZ( math.floor( minBZ / MC.CH ) )
			includeRuntimeCZ( math.floor( maxBZ / MC.CH ) )
		end
	end
	for editKey in pairs( Store.EditChunks or {} ) do includeRuntimeChunkKey( editKey ) end
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
				local savedKey = MC.ChunkKeyString( sx, sy, sz )
				local entry = Store.ChunkIndex and Store.ChunkIndex[savedKey]
				if istable( entry ) then
					entries[#entries + 1] = { key = savedKey, entry = entry }
				end
			end
		end
	end

	return entries
end

local function runtimeKeysForManifest()
	local keys = {}
	local savedChunkSize = savedChunkSizeForManifest()
	local savedHeight = savedHeightForManifest()
	for savedKey in pairs( Store.ChunkIndex or {} ) do
		local sx, sy, sz = MC.ChunkKeyToCoords( savedKey )
		if sx ~= nil and sy ~= nil and sz ~= nil then
			local minBX, maxBX = sx * savedChunkSize, ( sx + 1 ) * savedChunkSize - 1
			local minBY, maxBY = sy * savedChunkSize, ( sy + 1 ) * savedChunkSize - 1
			local minBZ, maxBZ = sz * savedHeight, ( sz + 1 ) * savedHeight - 1
			for cz = math.floor( minBZ / MC.CH ), math.floor( maxBZ / MC.CH ) do
				for cy = math.floor( minBY / MC.CS ), math.floor( maxBY / MC.CS ) do
					for cx = math.floor( minBX / MC.CS ), math.floor( maxBX / MC.CS ) do
						keys[MC.ChunkKeyString( cx, cy, cz )] = true
					end
				end
			end
		end
	end
	for key in pairs( Store.EditChunks or {} ) do keys[tostring( key )] = true end
	return keys
end

local HYDRATED_STORAGE_FIELDS = {
	"blocks", "orients", "stateSections", "blockEntities", "opaqueBlockEntities", "opaqueStates",
}

-- Decode into detached storage. Only chunks reached by this hydration are
-- copied; live collision entities and unrelated chunk caches keep their identity.
local function stagedChunk( staged, cx, cy, cz )
	local key = MC.ChunkKey( cx, cy, cz )
	local chunk = staged[key]
	if chunk then return chunk end
	local existing = MC.GetChunkByKey( key )
	if existing then
		chunk = {}
		for field, value in pairs( existing ) do chunk[field] = value end
		for _, field in ipairs( HYDRATED_STORAGE_FIELDS ) do chunk[field] = copyValue( existing[field] ) end
		chunk.key, chunk.cx, chunk.cy, chunk.cz = key, cx, cy, cz
	else
		chunk = { key = key, cx = cx, cy = cy, cz = cz,
			blocks = {}, orients = {}, count = 0, chunkBackend = "lua" }
	end
	staged[key] = chunk
	return chunk
end

local function publishStagedChunks( staged )
	for key, chunk in pairs( staged ) do
		local existing = MC.GetChunkByKey( key )
		if existing then
			if existing.key ~= key then MC.World[existing.key] = nil end
			for field in pairs( existing ) do existing[field] = nil end
			for field, value in pairs( chunk ) do existing[field] = value end
			chunk = existing
		end
		if chunk.count > 0 then
			MC.World[key] = chunk
		else
			MC.World[key] = nil
		end
	end
end

function Store.IsLazyWorld()
	return Store.Active == true
end

function Store.GetVerticalBounds()
	if not Store.IsLazyWorld() then return nil end
	return Store.MinRuntimeCZ, Store.MaxRuntimeCZ
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

local function validateStoredRegistryMetadata( data )
	if MC.ValidateModRegistrySnapshot then
		local registryOK, registryError = MC.ValidateModRegistrySnapshot( data.registry )
		if registryOK ~= true then return false, registryError or "invalid_registry_snapshot" end
	end
	if data.registryHash == nil then return true end
	if not isstring( data.registryHash ) or data.registryHash == "" then return false, "invalid_registry_hash" end
	local scopedHash = data.registry ~= nil and MC.ModRegistrySnapshotHash
		and MC.ModRegistrySnapshotHash( data.registry ) or nil
	local effectiveHash = MC.GetEffectiveBlockStateRegistryHash and MC.GetEffectiveBlockStateRegistryHash() or nil
	local vanillaHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil
	if data.registryHash ~= scopedHash and data.registryHash ~= effectiveHash and data.registryHash ~= vanillaHash then
		return false, "registry_hash_mismatch"
	end
	return true
end

function Store.LoadLazyManifest( manifest, manifestPath, realm )
	resetTables()
	Store.Active = true
	Store.Realm = realm == "GAME" and "GAME" or "DATA"
	Store.Manifest = manifest
	Store.ManifestPath = cleanDataPath( manifestPath )
	Store.BaseDir = string.GetPathFromFilename( Store.ManifestPath or "" )
	Store.Palette = manifest.p or manifest.palette or {}
	Store.ChunkIndex = manifest.chunkIndex or {}
	Store.Parts = manifest.parts or {}
	Store.EditOverlayPath = overlayPathForManifest( manifest, Store.ManifestPath )
	local blockCount = tonumber( manifest.stats and manifest.stats.blocks ) or 0
	local manifestRegistryOK, manifestRegistryError = validateStoredRegistryMetadata( manifest )
	if not manifestRegistryOK then
		resetTables()
		return false, manifestRegistryError
	end

	local overlayCandidates = {}
	if Store.EditOverlayPath then overlayCandidates[#overlayCandidates + 1] = Store.EditOverlayPath end
	-- Older lazy saves wrote a sibling *_edits.dat even when the manifest later
	-- advertised edits.json. Keep that spelling as a compatibility fallback.
	local legacyOverlayPath = stripExtension( Store.ManifestPath ) .. "_edits.dat"
	if legacyOverlayPath ~= Store.EditOverlayPath then overlayCandidates[#overlayCandidates + 1] = legacyOverlayPath end
	-- Mounted bases remain in GAME, but every save writer stores player edits
	-- in DATA. Prefer either local spelling before a bundled starting overlay.
	local overlayRealms = Store.Realm == "GAME" and { "DATA", "GAME" } or { "DATA" }
	local selectedOverlayPath, selectedOverlayRealm
	for _, overlayRealm in ipairs( overlayRealms ) do
		for _, overlayPath in ipairs( overlayCandidates ) do
			if file.Exists( overlayPath, overlayRealm ) then
				selectedOverlayPath, selectedOverlayRealm = overlayPath, overlayRealm
				break
			end
		end
		if selectedOverlayPath then break end
	end
	if selectedOverlayPath then
		local overlay, overlayError = readSaveJSON( selectedOverlayPath, nil, selectedOverlayRealm )
		if not istable( overlay ) or not istable( overlay.edits ) then
			resetTables()
			return false, "invalid_edit_overlay:" .. tostring( overlayError or "invalid_overlay_data" )
		end
		local registryOK, registryError = validateStoredRegistryMetadata( overlay )
		if not registryOK then
			resetTables()
			return false, registryError or "invalid_overlay_registry_snapshot"
		end
		Store.EditChunks = overlay.edits
		local editedCount = tonumber( overlay.blockCount )
		if editedCount ~= nil then blockCount = math.max( 0, math.floor( editedCount ) ) end
	end

	SV.BlockCount = blockCount
	rebuildVerticalBounds()
	SV.StreamInterestDirty = true
	return true
end

-- Normal GMod maps do not have an InfMap owner and must still be able to open
-- a v10/MCB4 save. Hydrate every indexed runtime chunk once, then discard the
-- manifest/cache so the rest of the server remains on the direct-world path.
function Store.LoadAllChunksEager( deferWorldEffects )
	if not Store.IsLazyWorld() then return true end
	local keys = runtimeKeysForManifest()
	local ordered = {}
	for key in pairs( keys ) do ordered[#ordered + 1] = key end
	table.sort( ordered )
	for _, key in ipairs( ordered ) do
		-- nil is a successful empty chunk when edits removed its last block.
		local _, loadError = Store.HydrateChunkNow( key, deferWorldEffects ~= true, deferWorldEffects )
		if loadError then return false, loadError end
	end
	Store.Reset()
	return true
end

local function applyCellToChunk( chunk, li, stateId )
	li = math.floor( tonumber( li ) or -1 )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if not chunk or not MC.LocalIndexInRange( li ) then return end
	if not MC.IsValidBlockState( stateId ) then return end
	return MC.SetChunkLocalStateRaw( chunk, li, stateId )
end

local function clearBlockEntityAt( chunk, localIndex )
	if chunk.blockEntities then
		chunk.blockEntities[localIndex] = nil
		if next( chunk.blockEntities ) == nil then chunk.blockEntities = nil end
	end
	if chunk.opaqueBlockEntities then
		chunk.opaqueBlockEntities[localIndex] = nil
		if next( chunk.opaqueBlockEntities ) == nil then chunk.opaqueBlockEntities = nil end
	end
end

local function installBlockEntityEnvelope( chunk, localIndex, stateId, envelope )
	if not istable( envelope ) then return false, "invalid_overlay_block_entity" end
	local record, decodeError = MC.DecodeBlockEntityEnvelope( stateId, envelope )
	if not record then return false, decodeError or "invalid_overlay_block_entity" end
	clearBlockEntityAt( chunk, localIndex )
	chunk.blockEntities = chunk.blockEntities or {}
	chunk.blockEntities[localIndex] = record
	return true
end

local function applyOverlayBlockEntity( chunk, localIndex, stateId, edit )
	if edit.blockEntity ~= nil then
		return installBlockEntityEnvelope( chunk, localIndex, stateId, edit.blockEntity )
	end
	if edit.removeBlockEntity == true then clearBlockEntityAt( chunk, localIndex ) end
	return true
end

function Store.ApplyOverlayToChunk( chunk )
	if not chunk or not chunk.key then return chunk end
	local editKey = tostring( chunk.key )
	local edits = Store.EditChunks and ( Store.EditChunks[editKey] or Store.EditChunks[chunk.key] or Store.EditChunks[MC.ChunkKeyString( chunk.key )] )
	if not istable( edits ) then return chunk end
	for li, edit in pairs( edits ) do
		if istable( edit ) then
			local localIndex = math.floor( tonumber( li ) or -1 )
			if not MC.LocalIndexInRange( localIndex ) then return nil, "invalid_overlay_local_index" end
			local stateId
			if isstring( edit.state ) then
				stateId = MC.ParseBlockState( edit.state )
			else
				stateId = MC.StateFromLegacy( edit.id, edit.orient )
			end
			if stateId == nil or not MC.IsValidBlockState( stateId ) then return nil, "invalid_overlay_state" end
			local changed, writeError = applyCellToChunk( chunk, localIndex, stateId )
			if changed == nil then return nil, writeError or "overlay_state_write_failed" end
			local applied, entityError = applyOverlayBlockEntity( chunk, localIndex, stateId, edit )
			if applied ~= true then return nil, entityError end
		end
	end
	return chunk
end

local MCB4_SECTION_CELLS = 4096
local MCB4_OCCUPANCY_BYTES = 512
local MCB4_BITS = {}
for value = 0, 255 do
	local offsets = {}
	for bitIndex = 0, 7 do
		if bit.band( value, bit.lshift( 1, bitIndex ) ) ~= 0 then offsets[#offsets + 1] = bitIndex end
	end
	MCB4_BITS[value] = offsets
end

local function readU16LE( data, offset )
	local a, b = string.byte( data, offset, offset + 1 )
	if b == nil then return nil end
	return a + b * 256
end

local function readI32LE( data, offset )
	local a, b, c, d = string.byte( data, offset, offset + 3 )
	if d == nil then return nil end
	local value = a + b * 256 + c * 65536 + d * 16777216
	return value >= 2147483648 and value - 4294967296 or value
end

local function bitsForPalette( size )
	local bits, capacity = 0, 1
	while capacity < size do bits, capacity = bits + 1, capacity * 2 end
	return bits
end

local function packedWrite( words, bits, cellIndex, value )
	if bits <= 0 then return end
	local bitOffset = cellIndex * bits
	local wordIndex = math.floor( bitOffset / 32 ) + 1
	local shift = bitOffset % 32
	if shift + bits <= 32 then
		words[wordIndex] = bit.bor( words[wordIndex] or 0, bit.lshift( value, shift ) )
		return
	end
	local lowBits = 32 - shift
	local lowMask = 2 ^ lowBits - 1
	words[wordIndex] = bit.bor( words[wordIndex] or 0, bit.lshift( bit.band( value, lowMask ), shift ) )
	words[wordIndex + 1] = bit.bor( words[wordIndex + 1] or 0, bit.rshift( value, lowBits ) )
end

local function packedByteValue( data, offset, bitOffset, bits )
	local byteOffset = math.floor( bitOffset / 8 )
	local shift = bitOffset % 8
	local a, b, c = string.byte( data, offset + byteOffset, offset + byteOffset + 2 )
	local value = ( a or 0 ) + ( b or 0 ) * 256 + ( c or 0 ) * 65536
	return math.floor( value / 2 ^ shift ) % 2 ^ bits
end

local function decodeMCB4Section( data, cursor, numeric, expectedSectionCount )
	local sectionY = readU16LE( data, cursor )
	local cellCount = readU16LE( data, cursor + 2 )
	local paletteCount = readU16LE( data, cursor + 4 )
	local sourceBits = string.byte( data, cursor + 6 )
	if sectionY == nil or sectionY >= expectedSectionCount or cellCount == nil or cellCount < 1
	or cellCount > MCB4_SECTION_CELLS or paletteCount == nil or paletteCount < 1
	or paletteCount > MCB4_SECTION_CELLS or sourceBits == nil or sourceBits < 1 or sourceBits > 12
	or paletteCount > 2 ^ sourceBits then return nil, nil, "invalid_fast_section_header" end
	cursor = cursor + 7
	local sourceStates = {}
	local seenStates = {}
	for index = 1, paletteCount do
		local globalIndex = readU16LE( data, cursor )
		local stateId = globalIndex ~= nil and numeric[globalIndex + 1] or nil
		if stateId == nil or stateId == 0 or seenStates[stateId] then return nil, nil, "invalid_fast_palette" end
		sourceStates[index] = stateId
		seenStates[stateId] = true
		cursor = cursor + 2
	end
	local occupancyOffset = cursor
	local packedOffset = occupancyOffset + MCB4_OCCUPANCY_BYTES
	local packedBytes = math.ceil( cellCount * sourceBits / 8 )
	if packedOffset + packedBytes - 1 > #data then return nil, nil, "truncated_fast_section" end

	-- A completely full section does not need an air palette entry. Keeping it
	-- would make the pathological 4096-state case require 13 bits, while the
	-- authoritative Section format is deliberately capped at 12.
	local hasAir = cellCount < MCB4_SECTION_CELLS
	local palette = hasAir and { 0 } or {}
	local paletteIndex = hasAir and { [0] = 0 } or {}
	local refCount = hasAir and { [0] = MCB4_SECTION_CELLS - cellCount } or {}
	local paletteOffset = hasAir and 1 or 0
	for index, stateId in ipairs( sourceStates ) do
		local runtimeIndex = index - 1 + paletteOffset
		palette[runtimeIndex + 1] = stateId
		paletteIndex[stateId] = runtimeIndex
		refCount[runtimeIndex] = 0
	end
	local runtimeBits = bitsForPalette( #palette )
	local words = {}
	local occupied = 0
	for byteIndex = 0, MCB4_OCCUPANCY_BYTES - 1 do
		local occupancy = string.byte( data, occupancyOffset + byteIndex )
		if occupancy == nil then return nil, nil, "truncated_fast_occupancy" end
		for _, bitIndex in ipairs( MCB4_BITS[occupancy] ) do
			local sourceIndex = packedByteValue( data, packedOffset, occupied * sourceBits, sourceBits )
			if sourceIndex >= paletteCount then return nil, nil, "fast_palette_index_out_of_range" end
			local runtimeIndex = sourceIndex + paletteOffset
			packedWrite( words, runtimeBits, byteIndex * 8 + bitIndex, runtimeIndex )
			refCount[runtimeIndex] = refCount[runtimeIndex] + 1
			occupied = occupied + 1
		end
	end
	if occupied ~= cellCount then return nil, nil, "fast_occupancy_count_mismatch" end
	return {
		palette = palette,
		paletteIndex = paletteIndex,
		refCount = refCount,
		paletteSize = #palette,
		bitsPerEntry = runtimeBits,
		entryMask = 2 ^ runtimeBits - 1,
		words = words,
		count = cellCount,
		deadPaletteEntries = hasAir and refCount[0] == 0 and 1 or 0,
	}, packedOffset + packedBytes, sectionY
end

local function loadFastChunkIntoWorld( key, entry, timing, staged )
	if savedChunkSizeForManifest() ~= MC.CS or savedHeightForManifest() ~= MC.CH then
		return nil, nil, "fast_geometry_mismatch"
	end
	local numeric = numericPalette()
	if not numeric then return nil, nil, "fast_palette_unavailable" end
	local fragment, readError = readFastFragment( entry.part, entry, timing )
	if not fragment then return nil, nil, readError end
	local decodeStarted = timing and SysTime() or nil
	local expectedCX, expectedCY, expectedCZ = MC.ChunkKeyToCoords( key )
	local cx, cy, cz = readI32LE( fragment, 1 ), readI32LE( fragment, 5 ), readI32LE( fragment, 9 )
	local totalCount, sectionCount = readU16LE( fragment, 13 ), readU16LE( fragment, 15 )
	if cx ~= expectedCX or cy ~= expectedCY or cz ~= expectedCZ then return nil, nil, "fast_coordinate_mismatch" end
	local expectedSections = math.floor( MC.CH / 16 )
	if totalCount == nil or totalCount > MC.CS * MC.CS * MC.CH or sectionCount == nil
	or sectionCount > expectedSections then return nil, nil, "invalid_fast_header" end
	local sections, seen, decodedCount = {}, {}, 0
	local cursor = 17
	for _ = 1, sectionCount do
		local section, nextCursor, sectionYOrError = decodeMCB4Section( fragment, cursor, numeric, expectedSections )
		if not section then return nil, nil, sectionYOrError end
		if seen[sectionYOrError] then return nil, nil, "duplicate_fast_section" end
		seen[sectionYOrError] = true
		sections[sectionYOrError + 1] = section
		decodedCount = decodedCount + section.count
		cursor = nextCursor
	end
	if decodedCount ~= totalCount or cursor ~= #fragment + 1 then return nil, nil, "fast_length_or_count_mismatch" end
	if timing then timingAdd( timing, "fastDecodeMS", ( SysTime() - decodeStarted ) * 1000 ) end

	local existing = staged[MC.CanonicalChunkKey( key )] or MC.GetChunkByKey( key )
	if existing and ( existing.count or 0 ) > 0 then return nil, nil, "fast_existing_chunk" end
	local installStarted = timing and SysTime() or nil
	local chunk = stagedChunk( staged, cx, cy, cz )
	chunk.stateSections = sections
	chunk.stateStorageMigrated = true
	chunk.packedStateOnly = true
	chunk.nativeStateStorage = false
	chunk.blocks = {}
	chunk.orients = {}
	chunk.count = decodedCount
	chunk.blockEntities = nil
	chunk.opaqueBlockEntities = nil
	chunk.opaqueStates = nil
	if timing then
		timingAdd( timing, "fastInstallMS", ( SysTime() - installStarted ) * 1000 )
		timingAdd( timing, "fastHits", 1 )
		timingAdd( timing, "records", 1 )
		timingAdd( timing, "cellsVisited", decodedCount )
		timingAdd( timing, "cellsWritten", decodedCount )
	end
	return chunk, { [MC.ChunkKey( cx, cy, cz )] = chunk }
end

local function savedBlockEntityCell( record, localIndex )
	local savedChunkSize = savedChunkSizeForManifest()
	local savedHeight = savedHeightForManifest()
	local lx, ly, lz = decodeLocalWithGeometry( localIndex, savedChunkSize, savedHeight )
	if lx == nil then return nil end
	local sourceCX = math.floor( tonumber( record[1] ) or 0 )
	local sourceCY = math.floor( tonumber( record[2] ) or 0 )
	local sourceCZ = math.floor( tonumber( record[3] ) or 0 )
	return sourceCX * savedChunkSize + lx, sourceCY * savedChunkSize + ly, sourceCZ * savedHeight + lz
end

local function applySavedBlockEntities( record, touched, staged )
	local envelopes = record[5]
	if envelopes == nil then return true end
	if not istable( envelopes ) or not MC.DecodeBlockEntityEnvelope then return false, "invalid_block_entities" end
	local seen = {}
	for _, envelope in ipairs( envelopes ) do
		if not istable( envelope ) then return false, "invalid_block_entity_envelope" end
		local sourceIndex = math.floor( tonumber( envelope.localIndex ) or -1 )
		if seen[sourceIndex] then return false, "duplicate_block_entity_index" end
		local bx, by, bz = savedBlockEntityCell( record, sourceIndex )
		if bx == nil then return false, "invalid_block_entity_index" end
		seen[sourceIndex] = true
		local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
		local chunk = stagedChunk( staged, cx, cy, cz )
		local stateId = MC.GetChunkBlockStateByLocalIndex( chunk, localIndex )
		local blockEntity, decodeError = MC.DecodeBlockEntityEnvelope( stateId, envelope )
		if not blockEntity then return false, decodeError or "invalid_block_entity" end
		clearBlockEntityAt( chunk, localIndex )
		chunk.blockEntities = chunk.blockEntities or {}
		chunk.blockEntities[localIndex] = blockEntity
		touched[MC.ChunkKey( cx, cy, cz )] = chunk
	end
	return true
end

local function applySavedOpaqueBlockEntities( record, touched, staged )
	local records = record[6]
	if records == nil then return true end
	if not istable( records ) then return false, "invalid_opaque_block_entities" end
	local seen, totalBytes = {}, 0
	for _, source in ipairs( records ) do
		if not istable( source ) then return false, "invalid_opaque_block_entity" end
		local sourceIndex = math.floor( tonumber( source.localIndex ) or -1 )
		if seen[sourceIndex] then return false, "duplicate_opaque_block_entity_index" end
		local bx, by, bz = savedBlockEntityCell( record, sourceIndex )
		if bx == nil then return false, "invalid_opaque_block_entity_index" end
		seen[sourceIndex] = true
		if not isstring( source.sourceType ) or source.sourceType == ""
		or source.encoding ~= "typed-nbt-json-v1" or not istable( source.data ) then
			return false, "invalid_opaque_block_entity_record"
		end
		local sourceDataVersion = tonumber( source.sourceDataVersion )
		if not sourceDataVersion or sourceDataVersion < 0 or sourceDataVersion ~= math.floor( sourceDataVersion ) then
			return false, "invalid_opaque_block_entity_version"
		end
		local json = util.TableToJSON( source.data, false )
		local bytes = json and #json or 0
		if bytes < 1 or bytes > 1048576 then return false, "opaque_block_entity_too_large" end
		totalBytes = totalBytes + bytes
		if totalBytes > 8388608 then return false, "opaque_chunk_budget_exceeded" end

		local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
		local chunk = stagedChunk( staged, cx, cy, cz )
		if MC.GetChunkBlockStateByLocalIndex( chunk, localIndex ) == 0 then return false, "opaque_block_entity_without_state" end
		if chunk.blockEntities and chunk.blockEntities[localIndex] then
			return false, "opaque_block_entity_conflicts_active"
		end
		chunk.opaqueBlockEntities = chunk.opaqueBlockEntities or {}
		local stored = copyValue( source )
		stored.localIndex = nil
		chunk.opaqueBlockEntities[localIndex] = stored
		touched[MC.ChunkKey( cx, cy, cz )] = chunk
	end
	return true
end

local function loadBaseChunkIntoWorld( key, record, timing, staged )
	if not istable( record ) or #record < 4 then return nil, nil, "invalid_chunk_record" end
	if timing then timingAdd( timing, "records", 1 ) end
	local srcCX = math.floor( tonumber( record[1] ) or 0 )
	local srcCY = math.floor( tonumber( record[2] ) or 0 )
	local srcCZ = math.floor( tonumber( record[3] ) or 0 )
	local cells = record[4]
	local savedChunkSize = savedChunkSizeForManifest()
	local savedHeight = savedHeightForManifest()
	local cache = {}
	local touched = {}
	local cellsVisited, cellsWritten = 0, 0
	local loadError

	local function loadOneCell( li, paletteIndex )
		if loadError then return end
		if timing then cellsVisited = cellsVisited + 1 end
		local lx, ly, lz = decodeLocalWithGeometry( li, savedChunkSize, savedHeight )
		if not lx then return end
		local bx = srcCX * savedChunkSize + lx
		local by = srcCY * savedChunkSize + ly
		local bz = srcCZ * savedHeight + lz
		local cx, cy, cz, nli = MC.CellToChunk( bx, by, bz )
		local targetKey = MC.ChunkKey( cx, cy, cz )
		local chunk = stagedChunk( staged, cx, cy, cz )
		local stateId = paletteState( cache, paletteIndex )
		local existingState, readError = MC.GetChunkBlockStateByLocalIndex( chunk, nli )
		if existingState == nil then loadError = readError or "state_read_failed" return end
		if MC.LocalIndexInRange( nli ) and stateId and stateId ~= 0 and existingState == 0 then
			local changed, writeError = MC.SetChunkLocalStateRaw( chunk, nli, stateId )
			if changed == nil then loadError = writeError or "state_write_failed" return end
			if changed then
				touched[targetKey] = chunk
				if timing then cellsWritten = cellsWritten + 1 end
			end
		end
	end

	local applyStarted = timing and SysTime() or nil
	if isstring( cells ) then
		for liText, piText in string.gmatch( cells, "([^:;]+):([^:;]*):?[^;]*;?" ) do
			loadOneCell( liText, piText )
		end
	elseif istable( cells ) then
		for i = 1, #cells, 2 do
			loadOneCell( cells[i], cells[i + 1] )
		end
	end
	if loadError then return nil, nil, loadError end
	if timing then
		timingAdd( timing, "cellsVisited", cellsVisited )
		timingAdd( timing, "cellsWritten", cellsWritten )
		timingAdd( timing, "stateApplyMS", ( SysTime() - applyStarted ) * 1000 )
	end
	local activeOK, activeError = applySavedBlockEntities( record, touched, staged )
	if activeOK ~= true then return nil, nil, activeError end
	local opaqueOK, opaqueError = applySavedOpaqueBlockEntities( record, touched, staged )
	if opaqueOK ~= true then return nil, nil, opaqueError end

	return staged[MC.CanonicalChunkKey( key )], touched
end

local function prepareChunkHydration( key, sample )
	local staged = {}
	local entries = baseChunkEntriesForRuntimeKey( key )
	if sample then sample.entries = #entries end
	for _, item in ipairs( entries ) do
		local entry = item.entry
		local loadedChunk
		if tonumber( entry.fastOffset ) ~= nil and tonumber( entry.fastBytes ) ~= nil then
			if sample then timingAdd( sample, "fastAttempts", 1 ) end
			local touched, fastError
			loadedChunk, touched, fastError = loadFastChunkIntoWorld( item.key, entry, sample, staged )
			if not loadedChunk and sample then
				timingAdd( sample, "fastFallbacks", 1 )
				sample.fastLastError = fastError
			end
		elseif sample then
			timingAdd( sample, "fastFallbacks", 1 )
			sample.fastLastError = "fast_metadata_unavailable"
		end
		if not loadedChunk then
			local partData, err = loadPart( entry.part, sample )
			if not partData then return nil, err end
			local idx = math.floor( tonumber( entry.index ) or 0 )
			local record = partData.chunks and partData.chunks[idx]
			if not istable( record ) then return nil, "invalid_chunk_index" end
			local _, _, loadError = loadBaseChunkIntoWorld( key, record, sample, staged )
			if loadError then return nil, loadError end
		end
	end

	local canonical = MC.CanonicalChunkKey( key )
	local edits = Store.EditChunks
	if not staged[canonical] and edits and
		( edits[key] or edits[tostring( canonical )] or edits[MC.ChunkKeyString( key )] ) then
		local cx, cy, cz = MC.ChunkKeyToCoords( key )
		stagedChunk( staged, cx, cy, cz )
	end
	-- A saved record can cover several runtime chunks, or several records can
	-- contribute to one chunk. Apply edits and finalize once, after every record
	-- has decoded successfully, before exposing any of them to the live world.
	local finalizeStarted = sample and SysTime() or nil
	for _, chunk in pairs( staged ) do
		if sample then timingAdd( sample, "touchedChunks", 1 ) end
		local overlaid, overlayError = Store.ApplyOverlayToChunk( chunk )
		if not overlaid then return nil, overlayError or "overlay_apply_failed" end
		local finalized, finalizeError = MC.FinalizeChunkStateStorage( chunk )
		if not finalized then return nil, finalizeError or "chunk_finalize_failed" end
	end
	if sample then timingAdd( sample, "overlayFinalizeMS", ( SysTime() - finalizeStarted ) * 1000 ) end
	return staged
end

function Store.HydrateChunkNow( key, priority, deferWorldEffects )
	if not Store.IsLazyWorld() then return MC.GetChunkByKey( key ) end
	key = tostring( key or "" )
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if cx == nil then return nil, "invalid_chunk_key" end
	local canonical = MC.ChunkKey( cx, cy, cz )
	local profiling = SV.BinaryNetHydrationProfileEnabled and SV.BinaryNetHydrationProfileEnabled() == true
	local sample = profiling and {
		key = key, startedAt = SysTime(), priority = priority == true,
		entries = 0, records = 0, cellsVisited = 0, cellsWritten = 0, touchedChunks = 0,
		partCacheHits = 0, partCacheMisses = 0, storedBytes = 0, jsonBytes = 0,
		fastAttempts = 0, fastHits = 0, fastFallbacks = 0, fastBytes = 0,
	} or nil
	local function finishProfile( success, errorText, warm )
		if not sample then return end
		sample.success = success == true
		sample.error = errorText
		sample.warm = warm == true
		sample.totalMS = ( SysTime() - sample.startedAt ) * 1000
		if SV.RecordChunkHydrationProfile then SV.RecordChunkHydrationProfile( sample ) end
	end
	local existing = MC.GetChunkByKey( key )
	if Store.LoadedKeys[key] or Store.LoadedKeys[tostring( canonical )] then
		finishProfile( true, nil, true )
		return existing
	end

	local called, staged, loadError = pcall( prepareChunkHydration, key, sample )
	if not called or not staged then
		Store.LastError = called and loadError or "chunk_hydration_exception"
		Store.QueuedKeys[key] = nil
		finishProfile( false, Store.LastError, false )
		if not called then MC.Fault( "chunk_hydration_exception", "%s: %s", key, tostring( staged ) ) end
		return nil, Store.LastError
	end

	publishStagedChunks( staged )
	local chunk = MC.GetChunkByKey( key )
	local hydratedKeys = { [canonical] = true }
	for touchedKey in pairs( staged ) do hydratedKeys[touchedKey] = true end
	for hydratedKey in pairs( hydratedKeys ) do
		Store.LoadedKeys[tostring( hydratedKey )] = true
		MC.MarkChunkLoaded( hydratedKey )
	end
	Store.LoadedKeys[key] = true
	Store.QueuedKeys[key] = nil
	Store.LastError = nil
	if not deferWorldEffects and chunk and chunk.count and chunk.count > 0 and priority then
		local collisionStarted = sample and SysTime() or nil
		SV.EnsureChunkEnt( chunk )
		SV.MarkPhysDirty( key, true )
		if sample then timingAdd( sample, "collisionQueueMS", ( SysTime() - collisionStarted ) * 1000 ) end
	end
	if not deferWorldEffects then
		for hydratedKey in pairs( hydratedKeys ) do
			if SV.InvalidateLightingChunk then SV.InvalidateLightingChunk( hydratedKey ) end
			if MC.RunEvent then
				local cx, cy, cz
				if MC.ChunkKeyToCoords then cx, cy, cz = MC.ChunkKeyToCoords( hydratedKey ) end
				MC.RunEvent( "MC.ChunkHydrated", hydratedKey, cx, cy, cz )
			end
		end
	end
	finishProfile( true, nil, false )
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

function Store.RecordEdit( bx, by, bz, id, orient, stateId )
	if not Store.IsLazyWorld() then return end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local key = tostring( MC.ChunkKey( cx, cy, cz ) )
	includeRuntimeCZ( cz )
	local edits = Store.EditChunks[key]
	if not edits then
		edits = {}
		Store.EditChunks[key] = edits
	end
	stateId = stateId or MC.StateFromLegacy( id, orient )
	local spec = stateId and MC.FormatBlockState( stateId ) or nil
	if not spec then return end
	local localKey = tostring( li )
	local edit = istable( edits[localKey] ) and edits[localKey] or {}
	edit.state = spec
	edit.id, edit.orient = nil, nil
	edits[localKey] = edit
end

-- Storage-level bulk edits such as /fill already know their Chunk and local
-- indexes. Record the lazy-save overlay without repeating coordinate decoding
-- and block-state formatting for every cell.
function Store.RecordChunkStateEdits( key, localIndexes, stateId )
	if not Store.IsLazyWorld() then return end
	key = tostring( key or "" )
	if key == "" or not istable( localIndexes ) then return end
	includeRuntimeChunkKey( key )
	local spec = MC.FormatBlockState( stateId )
	if not spec then return end
	local edits = Store.EditChunks[key]
	if not edits then
		edits = {}
		Store.EditChunks[key] = edits
	end
	for index = 1, #localIndexes, 2 do
		local li = math.floor( tonumber( localIndexes[index] ) or -1 )
		if MC.LocalIndexInRange( li ) then
			local localKey = tostring( li )
			local edit = istable( edits[localKey] ) and edits[localKey] or {}
			edit.state = spec
			edit.id, edit.orient = nil, nil
			edits[localKey] = edit
		end
	end
end

-- Heterogeneous storage-level edits use alternating localIndex/stateId pairs.
-- Preset hydration can therefore update the lazy-save overlay once per Chunk
-- without decoding world coordinates or formatting the same state repeatedly.
function Store.RecordChunkStateMap( key, localStatePairs )
	if not Store.IsLazyWorld() then return end
	key = tostring( key or "" )
	if key == "" or not istable( localStatePairs ) then return end
	includeRuntimeChunkKey( key )
	local edits = Store.EditChunks[key]
	if not edits then
		edits = {}
		Store.EditChunks[key] = edits
	end
	local specs = {}
	for index = 1, #localStatePairs, 2 do
		local li = math.floor( tonumber( localStatePairs[index] ) or -1 )
		local stateId = math.floor( tonumber( localStatePairs[index + 1] ) or -1 )
		if MC.LocalIndexInRange( li ) and stateId >= 0 then
				local spec = specs[stateId]
			if spec == nil then
				spec = MC.FormatBlockState( stateId ) or false
				specs[stateId] = spec
			end
			if spec then
				local localKey = tostring( li )
				local edit = istable( edits[localKey] ) and edits[localKey] or {}
				edit.state = spec
				edit.id, edit.orient = nil, nil
				edits[localKey] = edit
			end
		end
	end
end

-- Block Entity mutations share the same per-cell overlay entry as state
-- mutations. This covers signs and inventories that change without replacing
-- their block, while keeping server-only payloads out of the normal net path.
function Store.RecordBlockEntityEdit( bx, by, bz, record, stateId )
	if not Store.IsLazyWorld() then return true end
	local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
	local key = tostring( MC.ChunkKey( cx, cy, cz ) )
	includeRuntimeCZ( cz )
	stateId = math.floor( tonumber( stateId ) or tonumber( MC.GetBlockState( bx, by, bz ) ) or -1 )
	if not MC.IsValidBlockState( stateId ) then return false, "invalid_block_entity_overlay_state" end
	local spec = MC.FormatBlockState( stateId )
	if not spec then return false, "invalid_block_entity_overlay_state" end
	local edits = Store.EditChunks[key]
	if not edits then
		edits = {}
		Store.EditChunks[key] = edits
	end
	local localKey = tostring( localIndex )
	local edit = istable( edits[localKey] ) and edits[localKey] or {}
	edit.state = spec
	edit.id, edit.orient = nil, nil
	if record ~= nil then
		local envelope, encodeError = MC.EncodeBlockEntityEnvelope( stateId, record, false )
		if not envelope then return false, encodeError or "block_entity_overlay_encode_failed" end
		edit.blockEntity = copyValue( envelope )
		edit.removeBlockEntity = nil
	else
		edit.blockEntity = nil
		edit.removeBlockEntity = true
	end
	edits[localKey] = edit
	return true
end

function Store.SaveOverlay()
	local stateSpecs = {}
	for _, edits in pairs( Store.EditChunks or {} ) do
		for _, edit in pairs( istable( edits ) and edits or {} ) do
			if istable( edit ) and isstring( edit.state ) then stateSpecs[#stateSpecs + 1] = edit.state end
		end
	end
	local registry = MC.BuildModRegistrySnapshot and MC.BuildModRegistrySnapshot( stateSpecs ) or nil
	local persistenceHash = registry and MC.ModRegistrySnapshotHash and MC.ModRegistrySnapshotHash( registry )
		or MC.GetEffectiveBlockStateRegistryHash and MC.GetEffectiveBlockStateRegistryHash() or nil
	return {
		v = 3,
		base = Store.ManifestPath,
		blockCount = math.max( 0, math.floor( tonumber( SV.BlockCount ) or 0 ) ),
		registryHash = persistenceHash,
		registry = registry,
		edits = Store.EditChunks or {},
	}
end

timer.Create( "mc_chunk_store_load", 0.05, 0, function()
	if Store.TickChunkLoads then Store.TickChunkLoads() end
end )
