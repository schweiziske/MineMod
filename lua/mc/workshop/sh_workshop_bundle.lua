--[[----------------------------------------------------------------------------
	MC Workshop world bundle codec.

	MCWSB is retained as the bounded client/server transfer container. Published
	Workshop GMA files expose the normal directory save layout directly under
	data_static/mc/saves/<package>/ instead of embedding this container.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Workshop = MC.Workshop or {}

local W = MC.Workshop
local UINT32 = 4294967296

W.BUNDLE_MAGIC = "MCWSB001"
W.BUNDLE_VERSION = 1
W.MAX_BUNDLE_BYTES = 128 * 1024 * 1024
W.MAX_RAW_BYTES = 128 * 1024 * 1024
W.MAX_FILE_BYTES = 32 * 1024 * 1024
W.MAX_MANIFEST_BYTES = 8 * 1024 * 1024
W.MAX_COVER_BYTES = 2 * 1024 * 1024
W.MAX_FILES = 4096
W.MAX_CHUNKS = 262144
W.MAX_PATH_BYTES = 160
W.WORKSHOP_GMA_MAGIC = "GMAD"
W.WORKSHOP_GMA_VERSION = 3
W.WORKSHOP_GMA_SAVE_ROOT = "data_static/mc/saves"
W.WORKSHOP_GMA_COVER_ROOT = "materials/mc/save_covers"
W.WORKSHOP_ARCHIVE_CACHE_DIR = "mc/workshop_cache"
W.WORKSHOP_LISTEN_SHARED_DIR = "mc/workshop_shared"
W.MAX_WORKSHOP_ARCHIVE_BYTES = W.MAX_RAW_BYTES + W.MAX_COVER_BYTES + 2 * 1024 * 1024
W.MAX_WORKSHOP_GMA_FILES = W.MAX_FILES + 4
W.EXPORT_PART_BYTES = 30000
W.UPLOAD_PART_BYTES = 16000
W.UPLOAD_PART_INTERVAL = 0.04
W.EXPORT_TIMEOUT_MAX = 1800
W.UPLOAD_TIMEOUT_MAX = 900

local function writeU16( value )
	value = math.floor( tonumber( value ) or 0 ) % 65536
	return string.char( value % 256, math.floor( value / 256 ) % 256 )
end

local function writeU32( value )
	value = math.floor( tonumber( value ) or 0 ) % UINT32
	return string.char(
		value % 256,
		math.floor( value / 256 ) % 256,
		math.floor( value / 65536 ) % 256,
		math.floor( value / 16777216 ) % 256
	)
end

local function newReader( data )
	return { data = data, offset = 1, bytes = #data }
end

local function readBytes( reader, count )
	count = math.floor( tonumber( count ) or -1 )
	if count < 0 or reader.offset + count - 1 > reader.bytes then return nil end
	local value = string.sub( reader.data, reader.offset, reader.offset + count - 1 )
	reader.offset = reader.offset + count
	return value
end

local function readU16( reader )
	local a, b = string.byte( reader.data, reader.offset, reader.offset + 1 )
	if b == nil then return nil end
	reader.offset = reader.offset + 2
	return a + b * 256
end

local function readU32( reader )
	local a, b, c, d = string.byte( reader.data, reader.offset, reader.offset + 3 )
	if d == nil then return nil end
	reader.offset = reader.offset + 4
	return a + b * 256.0 + c * 65536.0 + d * 16777216.0
end

local function readU8( reader )
	local value = string.byte( reader.data, reader.offset )
	if value == nil then return nil end
	reader.offset = reader.offset + 1
	return value
end

local function readCString( reader, maxBytes )
	local stop = string.find( reader.data, "\0", reader.offset, true )
	if not stop or stop - reader.offset > maxBytes then return nil end
	local value = string.sub( reader.data, reader.offset, stop - 1 )
	reader.offset = stop + 1
	return value
end

local function crcNumber( data )
	return math.floor( tonumber( util.CRC( data or "" ) ) or 0 ) % UINT32
end

local function cleanText( value, maxBytes )
	value = string.Trim( tostring( value or "" ) )
	if #value > maxBytes then value = string.sub( value, 1, maxBytes ) end
	return value
end

local function uint32( value )
	return math.floor( math.Clamp( tonumber( value ) or 0, 0, UINT32 - 1 ) )
end

function W.SafeSlotName( name )
	name = string.Trim( tostring( name or "" ) )
	if name == "" then return nil end
	name = string.gsub( name, "[%c/\\:%*%?\"<>|]", "_" )
	name = string.gsub( name, "%.%.+", "_" )
	name = string.gsub( name, "^%.+", "" )
	name = string.Trim( string.sub( name, 1, 64 ) )
	if name == "" then return nil end
	return name
end

function W.NormalizeWorkshopId( value )
	value = string.Trim( tostring( value or "" ) )
	if value == "" or #value > 2048 then return nil end

	local function validId( candidate )
		candidate = tostring( candidate or "" )
		if candidate == "" or #candidate > 20 or not string.match( candidate, "^%d+$" )
			or string.match( candidate, "^0+$" ) then
			return nil
		end
		return candidate
	end

	local direct = string.match( value, "^(%d+)/?$" )
	if direct then return validId( direct ) end

	local lower = string.lower( value )
	if not string.find( lower, "steamcommunity.com/", 1, true )
		and not string.find( lower, "steam://", 1, true ) then
		return nil
	end

	local extracted = string.match( lower, "[?&]id=(%d+)" )
		or string.match( lower, "/communityfilepage/(%d+)" )
		or string.match( lower, "/filedetails/(%d+)" )
	return validId( extracted )
end

function W.ContentHash( data )
	if not isstring( data ) then return nil end
	if util.SHA256 then
		local hash = util.SHA256( data )
		if isstring( hash ) and hash ~= "" then return string.lower( hash ) end
	end
	local value = crcNumber( data )
	return string.format( "%02x%02x%02x%02x",
		math.floor( value / 16777216 ) % 256,
		math.floor( value / 65536 ) % 256,
		math.floor( value / 256 ) % 256,
		value % 256
	)
end

function W.IsContentHash( value )
	value = string.lower( string.Trim( tostring( value or "" ) ) )
	return #value >= 8 and #value <= 64 and string.match( value, "^[0-9a-f]+$" ) ~= nil
end

function W.WorkshopArchiveCachePath( workshopId, contentHash )
	workshopId = W.NormalizeWorkshopId( workshopId )
	contentHash = string.lower( string.Trim( tostring( contentHash or "" ) ) )
	if not workshopId or not W.IsContentHash( contentHash ) then return nil end
	return W.WORKSHOP_ARCHIVE_CACHE_DIR .. "/" .. workshopId .. "_" .. contentHash .. ".gma"
end

function W.ListenSharedArchivePath( steamId64, requestId, contentHash )
	steamId64 = string.Trim( tostring( steamId64 or "" ) )
	requestId = math.floor( tonumber( requestId ) or 0 )
	contentHash = string.lower( string.Trim( tostring( contentHash or "" ) ) )
	if steamId64 == "" or #steamId64 > 24 or not string.match( steamId64, "^%d+$" )
		or requestId < 1 or requestId >= UINT32 or not W.IsContentHash( contentHash ) then
		return nil
	end
	return W.WORKSHOP_LISTEN_SHARED_DIR .. "/" .. steamId64 .. "_" .. requestId .. "_" .. contentHash .. ".gma"
end

function W.NormalizeBundlePath( path )
	path = string.Trim( tostring( path or "" ) )
	path = string.gsub( path, "\\", "/" )
	if path == "" or #path > W.MAX_PATH_BYTES or string.find( path, "..", 1, true ) then return nil end
	if path == "manifest.json" or path == "meta.json" or path == "edits.json" or path == "cover.jpg" then
		return path
	end
	if string.match( path, "^regions/[A-Za-z0-9_%.%-]+%.json$" ) then return path end
	return nil
end

local function normalizeMetadata( metadata )
	if not istable( metadata ) then return nil, "invalid_bundle_metadata" end
	local name = W.SafeSlotName( metadata.name )
	if not name then return nil, "invalid_bundle_name" end
	local kind = cleanText( metadata.kind, 32 )
	if kind ~= "" and kind ~= "mcswep_world" then return nil, "invalid_bundle_kind" end
	local source = cleanText( metadata.source, 16 )
	if source ~= "local" and source ~= "workshop" then source = "local" end
	local workshopId = W.NormalizeWorkshopId( metadata.workshopId )
	local owner = cleanText( metadata.publisherSteamId64 or metadata.workshopOwner, 24 )
	if owner ~= "" and not string.match( owner, "^%d+$" ) then owner = "" end

	return {
		kind = "mcswep_world",
		bundleVersion = W.BUNDLE_VERSION,
		name = name,
		map = cleanText( metadata.map, 64 ),
		savedAt = uint32( metadata.savedAt ),
		savedAtText = cleanText( metadata.savedAtText, 64 ),
		bs = tonumber( metadata.bs ) or 0,
		h = math.floor( tonumber( metadata.h ) or 0 ),
		chunks = uint32( metadata.chunks ),
		blocks = uint32( metadata.blocks ),
		schemaHash = cleanText( metadata.schemaHash, 128 ),
		source = source,
		workshopId = workshopId,
		publisherSteamId64 = owner ~= "" and owner or nil,
	}
end

local function validateManifestReferences( files )
	local raw = files["manifest.json"]
	if not isstring( raw ) or raw == "" or #raw > W.MAX_MANIFEST_BYTES then
		return nil, "invalid_bundle_manifest"
	end
	local manifest = util.JSONToTable( raw )
	if not istable( manifest ) then return nil, "invalid_bundle_manifest_json" end
	local version = math.floor( tonumber( manifest.formatVersion or manifest.v ) or -1 )
	if version ~= 10 then return nil, "unsupported_bundle_save_version" end
	if manifest.map ~= nil and ( not isstring( manifest.map ) or #manifest.map > 64 ) then
		return nil, "invalid_bundle_map"
	end
	if manifest.schemaHash ~= nil and ( not isstring( manifest.schemaHash ) or #manifest.schemaHash > 128 ) then
		return nil, "invalid_bundle_schema_hash"
	end
	local blockCount = tonumber( manifest.blockCount )
	if blockCount ~= nil and ( blockCount < 0 or blockCount > UINT32 - 1 or blockCount % 1 ~= 0 ) then
		return nil, "invalid_bundle_block_count"
	end
	if not istable( manifest.parts ) or #manifest.parts > W.MAX_FILES then
		return nil, "invalid_bundle_parts"
	end
	if not istable( manifest.p ) or #manifest.p > 65535 then return nil, "invalid_bundle_palette" end
	for index, spec in ipairs( manifest.p ) do
		if not isstring( spec ) or spec == "" or #spec > 256 then
			return nil, "invalid_bundle_palette:" .. tostring( index )
		end
	end

	local referenced = {}
	for index, part in ipairs( manifest.parts ) do
		if not istable( part ) then return nil, "invalid_bundle_part:" .. tostring( index ) end
		local hasFile = false
		for _, field in ipairs( { "path", "fastPath" } ) do
			local value = part[field]
			if value ~= nil then
				local clean = W.NormalizeBundlePath( value )
				if clean ~= value or not string.StartWith( clean or "", "regions/" ) or not isstring( files[clean] ) then
					return nil, "invalid_bundle_part_path:" .. tostring( index )
				end
				referenced[clean] = true
				hasFile = true
			end
		end
		if not hasFile then return nil, "invalid_bundle_part:" .. tostring( index ) end
		if part.fastPath ~= nil then
			local declared = math.floor( tonumber( part.fastBytes ) or -1 )
			if declared < 0 or declared ~= #files[part.fastPath] then
				return nil, "invalid_bundle_fast_bytes:" .. tostring( index )
			end
		end
	end
	for path in pairs( files ) do
		if string.StartWith( path, "regions/" ) and not referenced[path] then
			return nil, "unreferenced_bundle_region"
		end
	end

	if manifest.editOverlay ~= nil and manifest.editOverlay ~= "edits.json" then
		return nil, "invalid_bundle_overlay_path"
	end
	if not istable( manifest.chunkIndex ) then return nil, "invalid_bundle_chunk_index" end
	local chunkCount = 0
	for key, entry in pairs( manifest.chunkIndex ) do
		chunkCount = chunkCount + 1
		local sx, sy, sz
		if isstring( key ) then sx, sy, sz = string.match( key, "^(%-?%d+):(%-?%d+):(%-?%d+)$" ) end
		local cx, cy, cz = tonumber( sx ), tonumber( sy ), tonumber( sz )
		if chunkCount > W.MAX_CHUNKS or not istable( entry )
			or not cx or not cy or not cz
			or cx < -2147483648 or cx > 2147483647
			or cy < -2147483648 or cy > 2147483647
			or cz < -2147483648 or cz > 2147483647 then
			return nil, "invalid_bundle_chunk_index"
		end
		local partNo = math.floor( tonumber( entry.part ) or 0 )
		local part = manifest.parts[partNo]
		if not part then return nil, "invalid_bundle_chunk_part" end
		if entry.index ~= nil then
			local sideIndex = math.floor( tonumber( entry.index ) or 0 )
			local sideCount = math.floor( tonumber( part.chunks ) or 0 )
			if not part.path or sideIndex < 1 or sideIndex > sideCount then return nil, "invalid_bundle_chunk_side" end
		else
			local offset = math.floor( tonumber( entry.fastOffset ) or -1 )
			local bytes = math.floor( tonumber( entry.fastBytes ) or -1 )
			local partBytes = math.floor( tonumber( part.fastBytes ) or -1 )
			if not part.fastPath or offset < 0 or bytes < 16 or partBytes < 0 or offset + bytes > partBytes then
				return nil, "invalid_bundle_chunk_fast"
			end
		end
	end
	return manifest
end

function W.ValidateBundleFiles( files )
	if not istable( files ) then return nil, "invalid_bundle_files" end
	local count, total = 0, 0
	for path, data in pairs( files ) do
		local clean = W.NormalizeBundlePath( path )
		if clean ~= path or not isstring( data ) then return nil, "invalid_bundle_file" end
		local maxBytes = path == "cover.jpg" and W.MAX_COVER_BYTES or W.MAX_FILE_BYTES
		if #data > maxBytes then return nil, "bundle_file_too_large:" .. path end
		count = count + 1
		total = total + #data
		if count > W.MAX_FILES or total > W.MAX_RAW_BYTES then return nil, "bundle_raw_too_large" end
	end
	if count < 1 or not files["manifest.json"] then return nil, "bundle_manifest_missing" end
	if files["cover.jpg"] and ( #files["cover.jpg"] < 4
		or string.byte( files["cover.jpg"], 1 ) ~= 255
		or string.byte( files["cover.jpg"], 2 ) ~= 216 ) then
		return nil, "invalid_bundle_cover"
	end
	local manifest, manifestError = validateManifestReferences( files )
	if not manifest then return nil, manifestError end
	return { count = count, bytes = total, manifest = manifest }
end

function W.EncodeBundle( metadata, files )
	local normalized, metadataError = normalizeMetadata( metadata )
	if not normalized then return nil, metadataError end
	local fileInfo, fileError = W.ValidateBundleFiles( files )
	if not fileInfo then return nil, fileError end

	local metadataJSON = util.TableToJSON( normalized )
	if not metadataJSON or #metadataJSON > 16384 then return nil, "bundle_metadata_encode_failed" end
	local paths = {}
	for path in pairs( files ) do paths[#paths + 1] = path end
	table.sort( paths )

	local parts = { writeU32( #metadataJSON ), metadataJSON, writeU16( #paths ) }
	local rawBytes = 6 + #metadataJSON
	for _, path in ipairs( paths ) do
		local data = files[path]
		parts[#parts + 1] = writeU16( #path )
		parts[#parts + 1] = path
		parts[#parts + 1] = writeU32( #data )
		parts[#parts + 1] = writeU32( crcNumber( data ) )
		parts[#parts + 1] = data
		rawBytes = rawBytes + 10 + #path + #data
		if rawBytes > W.MAX_RAW_BYTES then return nil, "bundle_raw_too_large" end
	end

	local raw = table.concat( parts )
	local compressed = util.Compress( raw )
	if not compressed or compressed == "" then return nil, "bundle_compress_failed" end
	local bundle = W.BUNDLE_MAGIC .. writeU32( #raw ) .. writeU32( crcNumber( raw ) ) .. compressed
	if #bundle > W.MAX_BUNDLE_BYTES then return nil, "bundle_too_large" end
	return bundle, {
		metadata = normalized,
		manifest = fileInfo.manifest,
		files = fileInfo.count,
		rawBytes = #raw,
		bytes = #bundle,
		hash = W.ContentHash( bundle ),
	}
end

function W.DecodeBundle( bundle )
	if not isstring( bundle ) or #bundle < 17 or #bundle > W.MAX_BUNDLE_BYTES then
		return nil, "invalid_bundle_size"
	end
	if string.sub( bundle, 1, #W.BUNDLE_MAGIC ) ~= W.BUNDLE_MAGIC then return nil, "invalid_bundle_magic" end
	local header = newReader( string.sub( bundle, #W.BUNDLE_MAGIC + 1, #W.BUNDLE_MAGIC + 8 ) )
	local expectedRawBytes = readU32( header )
	local expectedCRC = readU32( header )
	if not expectedRawBytes or expectedRawBytes < 1 or expectedRawBytes > W.MAX_RAW_BYTES then
		return nil, "invalid_bundle_header"
	end
	local raw = util.Decompress( string.sub( bundle, #W.BUNDLE_MAGIC + 9 ) )
	if not raw or #raw ~= expectedRawBytes then return nil, "bundle_decompress_failed" end
	if crcNumber( raw ) ~= expectedCRC then return nil, "bundle_crc_mismatch" end

	local reader = newReader( raw )
	local metadataBytes = readU32( reader )
	if not metadataBytes or metadataBytes < 2 or metadataBytes > 16384 then return nil, "invalid_bundle_metadata" end
	local metadataJSON = readBytes( reader, metadataBytes )
	local metadataTable = metadataJSON and util.JSONToTable( metadataJSON ) or nil
	local metadata, metadataError = normalizeMetadata( metadataTable )
	if not metadata then return nil, metadataError end
	local fileCount = readU16( reader )
	if not fileCount or fileCount < 1 or fileCount > W.MAX_FILES then return nil, "invalid_bundle_file_count" end

	local files, total = {}, 0
	for index = 1, fileCount do
		local pathBytes = readU16( reader )
		if not pathBytes or pathBytes < 1 or pathBytes > W.MAX_PATH_BYTES then
			return nil, "invalid_bundle_path:" .. tostring( index )
		end
		local path = readBytes( reader, pathBytes )
		local clean = W.NormalizeBundlePath( path )
		if clean ~= path or files[path] ~= nil then return nil, "invalid_bundle_path:" .. tostring( index ) end
		local dataBytes = readU32( reader )
		local expectedFileCRC = readU32( reader )
		local maxBytes = path == "cover.jpg" and W.MAX_COVER_BYTES or W.MAX_FILE_BYTES
		if not dataBytes or dataBytes > maxBytes or expectedFileCRC == nil then
			return nil, "invalid_bundle_file_size:" .. tostring( index )
		end
		local data = readBytes( reader, dataBytes )
		if not data or crcNumber( data ) ~= expectedFileCRC then
			return nil, "bundle_file_crc_mismatch:" .. tostring( index )
		end
		files[path] = data
		total = total + dataBytes
		if total > W.MAX_RAW_BYTES then return nil, "bundle_raw_too_large" end
	end
	if reader.offset ~= reader.bytes + 1 then return nil, "bundle_trailing_data" end

	local fileInfo, fileError = W.ValidateBundleFiles( files )
	if not fileInfo then return nil, fileError end
	return {
		metadata = metadata,
		manifest = fileInfo.manifest,
		files = files,
		bytes = #bundle,
		rawBytes = #raw,
		contentHash = W.ContentHash( bundle ),
	}
end

function W.WorkshopPackageId( name, contentHash )
	local slug = string.lower( string.Trim( tostring( name or "" ) ) )
	slug = string.gsub( slug, "[^a-z0-9_%-]+", "_" )
	slug = string.gsub( slug, "_+", "_" )
	slug = string.gsub( slug, "^[_%-]+", "" )
	slug = string.gsub( slug, "[_%-]+$", "" )
	if slug == "" then slug = "world" end
	slug = string.sub( slug, 1, 40 )
	local suffix = string.lower( tostring( contentHash or "" ) )
	if not W.IsContentHash( suffix ) then suffix = W.ContentHash( tostring( name or "world" ) ) or "00000000" end
	return slug .. "_" .. string.sub( suffix, 1, 12 )
end

function W.WorkshopPackageContentHash( packageId )
	packageId = W.SafeSlotName( packageId )
	if not packageId then return nil end
	local suffix = string.lower( tostring( string.match( packageId, "_([0-9a-fA-F]+)$" ) or "" ) )
	if not W.IsContentHash( suffix ) then return nil end
	return suffix
end

local function encodeGMAFiles( files, title )
	local paths, totalBytes = {}, 0
	for path, data in pairs( files or {} ) do
		if not isstring( path ) or path == "" or #path > 512 or string.find( path, "..", 1, true )
			or string.find( path, "\\", 1, true ) or not isstring( data ) or #data < 1 then
			return nil, "invalid_gma_file_entry"
		end
		paths[#paths + 1] = path
		totalBytes = totalBytes + #data
		if #paths > W.MAX_WORKSHOP_GMA_FILES or totalBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES then
			return nil, "workshop_file_too_large"
		end
	end
	if #paths < 1 then return nil, "gma_world_save_missing" end
	table.sort( paths )

	title = cleanText( title, 128 )
	if title == "" then title = "MC Workshop World" end
	title = string.gsub( title, "%z", "" )
	local description = util.TableToJSON( {
		type = "dupe",
		tags = { "mc_world", "save" },
		description = "MC directory save",
	} ) or "{\"type\":\"dupe\",\"tags\":[\"mc_world\",\"save\"]}"
	description = string.gsub( description, "%z", "" )

	local index, payloads = {}, {}
	for fileNumber, path in ipairs( paths ) do
		local data = files[path]
		index[#index + 1] = writeU32( fileNumber )
		index[#index + 1] = path .. "\0"
		index[#index + 1] = writeU32( #data )
		index[#index + 1] = writeU32( 0 )
		index[#index + 1] = writeU32( crcNumber( data ) )
		payloads[#payloads + 1] = data
	end
	index[#index + 1] = writeU32( 0 )

	local body = table.concat( {
		W.WORKSHOP_GMA_MAGIC,
		string.char( W.WORKSHOP_GMA_VERSION ),
		writeU32( 0 ), writeU32( 0 ),
		writeU32( os.time() ), writeU32( 0 ),
		"\0",
		title, "\0",
		description, "\0",
		"MC Workshop", "\0",
		writeU32( 1 ),
		table.concat( index ),
		table.concat( payloads ),
	} )
	local archive = body .. writeU32( crcNumber( body ) )
	if #archive > W.MAX_WORKSHOP_ARCHIVE_BYTES then return nil, "workshop_file_too_large" end
	return archive, { bytes = #archive, files = #paths }
end

function W.EncodeWorkshopArchive( bundle, title )
	local decoded, decodeError = W.DecodeBundle( bundle )
	if not decoded then return nil, decodeError end
	local packageId = W.WorkshopPackageId( decoded.metadata.name or title, decoded.contentHash )
	local saveRoot = W.WORKSHOP_GMA_SAVE_ROOT .. "/" .. packageId
	local coverPath = W.WORKSHOP_GMA_COVER_ROOT .. "/" .. packageId .. ".jpg"
	local gmaFiles = {}

	for relativePath, data in pairs( decoded.files ) do
		if relativePath ~= "cover.jpg" then
			gmaFiles[saveRoot .. "/" .. relativePath] = data
		end
	end
	local meta = decoded.files["meta.json"] and util.JSONToTable( decoded.files["meta.json"] ) or {}
	if not istable( meta ) then meta = {} end
	meta.v = math.max( 2, math.floor( tonumber( meta.v ) or 0 ) )
	meta.name = decoded.metadata.name
	meta.path = saveRoot .. "/manifest.json"
	meta.source = "workshop"
	meta.packageId = packageId
	meta.map = decoded.metadata.map
	meta.savedAt = decoded.metadata.savedAt
	meta.savedAtText = decoded.metadata.savedAtText
	meta.bs = decoded.metadata.bs
	meta.h = decoded.metadata.h
	meta.chunks = decoded.metadata.chunks
	meta.blocks = decoded.metadata.blocks
	meta.workshopOwner = decoded.metadata.publisherSteamId64
	meta.workshopId = decoded.metadata.workshopId
	meta.cover = decoded.files["cover.jpg"] and coverPath or nil
	local metaJSON = util.TableToJSON( meta, true )
	if not metaJSON or #metaJSON > W.MAX_FILE_BYTES then return nil, "invalid_bundle_metadata" end
	gmaFiles[saveRoot .. "/meta.json"] = metaJSON
	if decoded.files["cover.jpg"] then gmaFiles[coverPath] = decoded.files["cover.jpg"] end

	local archive, infoOrError = encodeGMAFiles( gmaFiles, decoded.metadata.name or title )
	if not archive then return nil, infoOrError end
	infoOrError.packageId = packageId
	infoOrError.saveRoot = saveRoot
	infoOrError.coverPath = decoded.files["cover.jpg"] and coverPath or nil
	infoOrError.contentHash = W.ContentHash( archive )
	return archive, infoOrError
end

function W.DecodeWorkshopArchive( archive )
	if not isstring( archive ) or #archive < 17 or #archive > W.MAX_WORKSHOP_ARCHIVE_BYTES then
		return nil, "invalid_workshop_archive_size"
	end
	if string.sub( archive, 1, #W.BUNDLE_MAGIC ) == W.BUNDLE_MAGIC then
		if #archive > W.MAX_BUNDLE_BYTES then return nil, "invalid_bundle_size" end
		return archive, { container = "raw", bytes = #archive }
	end
	if string.sub( archive, 1, #W.WORKSHOP_GMA_MAGIC ) ~= W.WORKSHOP_GMA_MAGIC then
		return nil, "invalid_bundle_magic"
	end

	local reader = newReader( archive )
	if readBytes( reader, 4 ) ~= W.WORKSHOP_GMA_MAGIC then return nil, "invalid_gma_magic" end
	local version = readU8( reader )
	if not version or version < 1 or version > W.WORKSHOP_GMA_VERSION then return nil, "unsupported_gma_version" end
	if not readBytes( reader, 8 ) or not readBytes( reader, 8 ) then return nil, "invalid_gma_header" end
	if version > 1 then
		local terminated = false
		for _ = 1, 128 do
			local required = readCString( reader, 1024 )
			if required == nil then return nil, "invalid_gma_required_content" end
			if required == "" then terminated = true break end
		end
		if not terminated then return nil, "invalid_gma_required_content" end
	end
	if readCString( reader, 1024 ) == nil
		or readCString( reader, 16384 ) == nil
		or readCString( reader, 1024 ) == nil
		or readU32( reader ) == nil then
		return nil, "invalid_gma_metadata"
	end

	local entries, entryPaths, totalBytes = {}, {}, 0
	local terminated = false
	for index = 1, W.MAX_WORKSHOP_GMA_FILES + 1 do
		local fileNumber = readU32( reader )
		if fileNumber == nil then return nil, "invalid_gma_file_index" end
		if fileNumber == 0 then terminated = true break end
		if index > W.MAX_WORKSHOP_GMA_FILES or fileNumber ~= index then return nil, "invalid_gma_file_index" end
		local path = readCString( reader, 512 )
		local sizeLow = readU32( reader )
		local sizeHigh = readU32( reader )
		local fileCRC = readU32( reader )
		if not path or path == "" or sizeLow == nil or sizeHigh ~= 0 or fileCRC == nil
			or sizeLow < 1 or sizeLow > W.MAX_WORKSHOP_ARCHIVE_BYTES then
			return nil, "invalid_gma_file_entry"
		end
		path = string.lower( string.gsub( path, "\\", "/" ) )
		if entryPaths[path] then return nil, "duplicate_gma_file" end
		local entry = { path = path, bytes = sizeLow, crc = fileCRC, offset = totalBytes }
		entries[#entries + 1] = entry
		entryPaths[path] = entry
		totalBytes = totalBytes + sizeLow
		if totalBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES then return nil, "invalid_gma_payload_size" end
	end
	if not terminated then return nil, "invalid_gma_file_index" end

	local payloadOffset = reader.offset
	local bytesWithoutCRC = payloadOffset - 1 + totalBytes
	if bytesWithoutCRC ~= #archive and bytesWithoutCRC + 4 ~= #archive then
		return nil, "invalid_gma_payload_size"
	end
	if bytesWithoutCRC + 4 == #archive then
		local crcReader = newReader( string.sub( archive, #archive - 3 ) )
		local expectedArchiveCRC = readU32( crcReader )
		if expectedArchiveCRC ~= 0 and crcNumber( string.sub( archive, 1, #archive - 4 ) ) ~= expectedArchiveCRC then
			return nil, "gma_archive_crc_mismatch"
		end
	end


	local packageId, saveRoot
	for _, entry in ipairs( entries ) do
		local found = string.match( entry.path, "^" .. W.WORKSHOP_GMA_SAVE_ROOT .. "/([a-z0-9_%.%-]+)/manifest%.json$" )
		if found then
			if packageId then return nil, "multiple_gma_world_saves" end
			packageId = found
			saveRoot = W.WORKSHOP_GMA_SAVE_ROOT .. "/" .. packageId
		end
	end
	if not packageId then return nil, "gma_world_save_missing" end

	local files = {}
	local coverPath = W.WORKSHOP_GMA_COVER_ROOT .. "/" .. packageId .. ".jpg"
	for _, entry in ipairs( entries ) do
		local first = payloadOffset + entry.offset
		local data = string.sub( archive, first, first + entry.bytes - 1 )
		if #data ~= entry.bytes then return nil, "gma_file_read_failed" end
		if entry.crc ~= 0 and crcNumber( data ) ~= entry.crc then return nil, "gma_file_crc_mismatch" end
		if string.StartWith( entry.path, saveRoot .. "/" ) then
			local relativePath = string.sub( entry.path, #saveRoot + 2 )
			if W.NormalizeBundlePath( relativePath ) ~= relativePath then return nil, "invalid_gma_save_path" end
			files[relativePath] = data
		elseif entry.path == coverPath then
			files["cover.jpg"] = data
		else
			return nil, "unexpected_gma_file"
		end
	end

	local fileInfo, fileError = W.ValidateBundleFiles( files )
	if not fileInfo then return nil, fileError end
	local meta = files["meta.json"] and util.JSONToTable( files["meta.json"] ) or {}
	if not istable( meta ) then meta = {} end
	local manifest = fileInfo.manifest
	local stats = istable( manifest.stats ) and manifest.stats or {}
	local bundle, bundleInfoOrError = W.EncodeBundle( {
		kind = "mcswep_world",
		name = meta.name or manifest.slotName or packageId,
		map = meta.map or manifest.map,
		savedAt = meta.savedAt or manifest.savedAt,
		savedAtText = meta.savedAtText,
		bs = meta.bs or manifest.bs,
		h = meta.h or manifest.h,
		chunks = meta.chunks or stats.chunks,
		blocks = meta.blocks or manifest.blockCount or stats.blocks,
		schemaHash = manifest.schemaHash,
		source = "workshop",
		workshopId = meta.workshopId,
		publisherSteamId64 = meta.workshopOwner,
	}, files )
	if not bundle then return nil, bundleInfoOrError end
	return bundle, {
		container = "gma",
		version = version,
		files = #entries,
		bytes = #archive,
		bundleBytes = #bundle,
		packageId = packageId,
		saveRoot = saveRoot,
		contentHash = W.ContentHash( archive ),
	}
end

function W.ReplaceBundleFile( bundle, path, data )
	local decoded, decodeError = W.DecodeBundle( bundle )
	if not decoded then return nil, decodeError end
	path = W.NormalizeBundlePath( path )
	if not path or not isstring( data ) then return nil, "invalid_bundle_file" end
	decoded.files[path] = data
	return W.EncodeBundle( decoded.metadata, decoded.files )
end
