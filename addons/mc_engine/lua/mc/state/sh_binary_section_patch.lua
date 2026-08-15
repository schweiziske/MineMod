--[[----------------------------------------------------------------------------
	MC binary Section hydration patches.

	Terrain state stays numeric from the authoritative Section store to the wire:
	palette state IDs and packed 32-bit words are copied directly. Block Entity
	payloads retain their existing small JSON envelope because their codecs are
	table-based and they are not part of the terrain hot path.
------------------------------------------------------------------------------]]

MC = MC or {}

local Patch = MC.BinarySectionPatch or {}
MC.BinarySectionPatch = Patch

Patch.MAGIC = "MCB9"
Patch.VERSION = 1
Patch.COMPRESSION_NONE = 0
Patch.COMPRESSION_LZMA = 1
Patch.COMPRESS_THRESHOLD = 256
Patch.MAX_RAW_BYTES = 16777216
Patch.SNAPSHOT_MAGIC = "MCSB"
Patch.SNAPSHOT_VERSION = 1
Patch.SNAPSHOT_MAX_BATCHES = 65535
Patch.SNAPSHOT_BATCH_MAX_CHUNKS = 64
Patch.SNAPSHOT_BATCH_MAX_CELLS = 131072

local SECTION_COUNT = 2
local SECTION_CELLS = 4096
local CHUNK_CELLS = 8192
local MODE_EMPTY = 0
local MODE_UNIFORM = 1
local MODE_PACKED = 2
local UINT32 = 4294967296

local floor = math.floor
local bit_band = bit.band
local bit_rshift = bit.rshift
local string_char = string.char
local table_concat = table.concat
local unpack_values = unpack

local function integer( value, minimum, maximum )
	value = tonumber( value )
	if not value or value ~= floor( value ) or value < minimum or value > maximum then return nil end
	return value
end

local function newWriter()
	return { parts = {}, buffer = {}, buffered = 0, bytes = 0 }
end

local function flushWriter( writer )
	local count = writer.buffered
	if count <= 0 then return end
	writer.parts[#writer.parts + 1] = string_char( unpack_values( writer.buffer, 1, count ) )
	writer.buffer, writer.buffered = {}, 0
end

local function writeRaw( writer, value )
	flushWriter( writer )
	writer.parts[#writer.parts + 1] = value
	writer.bytes = writer.bytes + #value
end

local function writeU8( writer, value )
	local count = writer.buffered + 1
	writer.buffer[count] = value % 256
	writer.buffered = count
	writer.bytes = writer.bytes + 1
	if count >= 192 then flushWriter( writer ) end
end

local function writeU16( writer, value )
	writeU8( writer, value )
	writeU8( writer, floor( value / 256 ) )
end

local function writeU32( writer, value )
	value = value % UINT32
	writeU8( writer, value )
	writeU8( writer, floor( value / 256 ) )
	writeU8( writer, floor( value / 65536 ) )
	writeU8( writer, floor( value / 16777216 ) )
end

local function writeI32( writer, value ) writeU32( writer, value < 0 and value + UINT32 or value ) end

local function finishWriter( writer )
	flushWriter( writer )
	return table_concat( writer.parts ), writer.bytes
end

local function newReader( data )
	return { data = data, position = 1, length = #data }
end

local function readBytes( reader, count )
	if count < 0 or reader.position + count - 1 > reader.length then return nil end
	local value = string.sub( reader.data, reader.position, reader.position + count - 1 )
	reader.position = reader.position + count
	return value
end

local function readU8( reader )
	if reader.position > reader.length then return nil end
	local value = string.byte( reader.data, reader.position )
	reader.position = reader.position + 1
	return value
end

local function readU16( reader )
	if reader.position + 1 > reader.length then return nil end
	local a, b = string.byte( reader.data, reader.position, reader.position + 1 )
	reader.position = reader.position + 2
	return a + b * 256
end

local function readU32( reader )
	if reader.position + 3 > reader.length then return nil end
	local a, b, c, d = string.byte( reader.data, reader.position, reader.position + 3 )
	reader.position = reader.position + 4
	return a + b * 256 + c * 65536 + d * 16777216
end

local function readI32( reader )
	local value = readU32( reader )
	if value == nil then return nil end
	return value >= 2147483648 and value - UINT32 or value
end

local function maskForBits( bits )
	return 2 ^ bits - 1
end

local function packedGet( words, bits, cellIndex, entryMask )
	local bitOffset = cellIndex * bits
	local wordIndex = floor( bitOffset / 32 ) + 1
	local shift = bitOffset % 32
	local word = words[wordIndex] or 0
	if shift + bits <= 32 then
		return bit_band( bit_rshift( word, shift ), entryMask )
	end
	local lowBits = 32 - shift
	local highBits = bits - lowBits
	local low = bit_band( bit_rshift( word, shift ), maskForBits( lowBits ) )
	local high = bit_band( words[wordIndex + 1] or 0, maskForBits( highBits ) )
	return low + bit.lshift( high, lowBits )
end

local function sectionStateAt( sections, localIndex )
	local sectionIndex = floor( localIndex / SECTION_CELLS ) + 1
	local section = sections[sectionIndex]
	if not section then return 0 end
	local cellIndex = localIndex % SECTION_CELLS
	local bits = section.bitsPerEntry or 0
	local paletteIndex = bits == 0 and 0 or packedGet( section.words, bits, cellIndex, section.entryMask )
	return section.palette[paletteIndex + 1] or 0
end

local function collectBlockEntities( chunk, sections )
	if not chunk or not chunk.blockEntities then return {} end
	local indexes = {}
	for localIndex in pairs( chunk.blockEntities ) do indexes[#indexes + 1] = localIndex end
	table.sort( indexes )
	local out = {}
	for _, localIndex in ipairs( indexes ) do
		localIndex = integer( localIndex, 0, CHUNK_CELLS - 1 )
		if not localIndex then return nil, "invalid_block_entity_index" end
		local stateId = sectionStateAt( sections, localIndex )
		local wire, wireError = MC.PrepareBlockEntityWireEnvelope( stateId, chunk.blockEntities[localIndex] )
		if not wire then
			if wireError ~= "server_only" then return nil, wireError or "block_entity_encode_failed" end
		else
			if not isstring( wire.type ) or wire.type == "" or #wire.type > 160
			or not isstring( wire.payload ) or #wire.payload > 32768 then
				return nil, "invalid_block_entity_wire"
			end
			out[#out + 1] = {
				localIndex = localIndex,
				type = wire.type,
				codecVersion = integer( wire.codecVersion, 0, 65535 ),
				payload = wire.payload,
			}
			if out[#out].codecVersion == nil then return nil, "invalid_block_entity_codec" end
		end
	end
	return out
end

local function encodeSection( writer, section )
	if not section or ( section.count or 0 ) <= 0 then
		writeU8( writer, MODE_EMPTY )
		return true, 0
	end
	local count = integer( section.count, 1, SECTION_CELLS )
	local bits = integer( section.bitsPerEntry, 0, 12 )
	local paletteSize = integer( section.paletteSize or #( section.palette or {} ), 1, SECTION_CELLS )
	if not count or bits == nil or not paletteSize or not istable( section.palette ) then
		return nil, "invalid_section_header"
	end
	if bits == 0 then
		local stateId = integer( section.palette[1], 1, MC.Net and MC.Net.MAX_STATE_ID or 1048575 )
		if not stateId or count ~= SECTION_CELLS or not MC.Net.ValidateStateId( stateId )
		or not MC.IsValidBlockState( stateId ) then return nil, "invalid_uniform_section" end
		writeU8( writer, MODE_UNIFORM )
		writeU16( writer, count )
		writeU32( writer, stateId )
		return true, count
	end
	if paletteSize > 2 ^ bits or not istable( section.words ) then return nil, "invalid_packed_section" end
	local expectedWords = math.ceil( SECTION_CELLS * bits / 32 )
	writeU8( writer, MODE_PACKED )
	writeU16( writer, count )
	writeU8( writer, bits )
	writeU16( writer, paletteSize )
	for paletteIndex = 1, paletteSize do
		local stateId = integer( section.palette[paletteIndex], 0, MC.Net and MC.Net.MAX_STATE_ID or 1048575 )
		if stateId == nil or not MC.Net.ValidateStateId( stateId )
		or not MC.IsValidBlockState( stateId ) then return nil, "invalid_section_palette" end
		writeU32( writer, stateId )
	end
	writeU16( writer, expectedWords )
	for wordIndex = 1, expectedWords do
		local word = integer( section.words[wordIndex] or 0, -2147483648, 4294967295 )
		if word == nil then return nil, "invalid_section_word" end
		writeU32( writer, word )
	end
	return true, count
end

function Patch.Encode( refs )
	if not istable( refs ) or #refs < 1 or #refs > 64 then return nil, "invalid_chunk_refs" end
	local writer = newWriter()
	local totalCells = 0
	for refIndex, ref in ipairs( refs ) do
		local chunk = ref
		if istable( ref ) and ref.patchRef == true then chunk = ref.chunk end
		local cx = integer( ref and ( ref.cx or chunk and chunk.cx ), -2147483648, 2147483647 )
		local cy = integer( ref and ( ref.cy or chunk and chunk.cy ), -2147483648, 2147483647 )
		local cz = integer( ref and ( ref.cz or chunk and chunk.cz ), -2147483648, 2147483647 )
		if not cx or not cy or not cz then return nil, "invalid_chunk_coords:" .. tostring( refIndex ) end
		writeI32( writer, cx ); writeI32( writer, cy ); writeI32( writer, cz )
		if not chunk or ( chunk.count or 0 ) <= 0 then
			writeU8( writer, 1 )
			writeU16( writer, 0 )
		else
			local migrated, migrationError = MC.MigrateChunkStateStorage( chunk )
			if not migrated then return nil, migrationError or "section_migration_failed" end
			local sections = chunk.stateSections or {}
			local blockEntities, blockEntityError = collectBlockEntities( chunk, sections )
			if not blockEntities then return nil, blockEntityError end
			writeU8( writer, 0 )
			writeU16( writer, #blockEntities )
			local chunkCells = 0
			for sectionIndex = 1, SECTION_COUNT do
				local ok, countOrError = encodeSection( writer, sections[sectionIndex] )
				if not ok then return nil, tostring( countOrError ) .. ":" .. tostring( refIndex ) .. ":" .. tostring( sectionIndex ) end
				chunkCells = chunkCells + countOrError
			end
			if chunkCells ~= floor( tonumber( chunk.count ) or -1 ) then
				return nil, "chunk_count_mismatch:" .. tostring( refIndex )
			end
			for _, envelope in ipairs( blockEntities ) do
				writeU16( writer, envelope.localIndex )
				writeU16( writer, #envelope.type ); writeRaw( writer, envelope.type )
				writeU16( writer, envelope.codecVersion )
				writeU16( writer, #envelope.payload ); writeRaw( writer, envelope.payload )
			end
			totalCells = totalCells + chunkCells
		end
		if writer.bytes > Patch.MAX_RAW_BYTES then return nil, "binary_patch_too_large" end
	end
	local body = finishWriter( writer )
	local header = newWriter()
	writeRaw( header, Patch.MAGIC )
	writeU8( header, Patch.VERSION )
	writeU8( header, MC.CS or 16 )
	writeU8( header, MC.CH or 32 )
	writeU8( header, SECTION_COUNT )
	writeU16( header, #refs )
	writeU32( header, totalCells )
	local headerData = finishWriter( header )
	local payload = table_concat( { headerData, body } )
	return payload, { chunkCount = #refs, cellCount = totalCells, rawBytes = #payload }
end

local function decodeBlockEntity( reader, seen )
	local localIndex = readU16( reader )
	local typeLength = readU16( reader )
	if localIndex == nil or not typeLength or typeLength < 1 or typeLength > 160
	or localIndex >= CHUNK_CELLS or seen[localIndex] then return nil, "invalid_block_entity_header" end
	local typeName = readBytes( reader, typeLength )
	local codecVersion = readU16( reader )
	local payloadLength = readU16( reader )
	if not typeName or codecVersion == nil or payloadLength == nil or payloadLength > 32768 then
		return nil, "invalid_block_entity_header"
	end
	local payload = readBytes( reader, payloadLength )
	local decoded = payload and util.JSONToTable( payload ) or nil
	if not istable( decoded ) or decoded.hasData == nil
	or ( decoded.hasData == true and decoded.data == nil ) then return nil, "invalid_block_entity_payload" end
	seen[localIndex] = true
	return {
		localIndex = localIndex,
		type = typeName,
		codecVersion = codecVersion,
		data = decoded.hasData == true and decoded.data or nil,
	}
end

local function decodeSection( reader )
	local mode = readU8( reader )
	if mode == MODE_EMPTY then return nil, 0 end
	local count = readU16( reader )
	if count == nil or count < 1 or count > SECTION_CELLS then return false, "invalid_section_count" end
	if mode == MODE_UNIFORM then
		local stateId = readU32( reader )
		if count ~= SECTION_CELLS or not stateId or stateId == 0
		or not MC.Net.ValidateStateId( stateId ) or not MC.IsValidBlockState( stateId ) then
			return false, "invalid_uniform_section"
		end
		return {
			palette = { stateId }, paletteIndex = { [stateId] = 0 }, refCount = { [0] = SECTION_CELLS },
			paletteSize = 1, bitsPerEntry = 0, entryMask = 0, words = {}, count = SECTION_CELLS,
			deadPaletteEntries = 0,
		}, count
	end
	if mode ~= MODE_PACKED then return false, "invalid_section_mode" end
	local bits = readU8( reader )
	local paletteSize = readU16( reader )
	if not bits or bits < 1 or bits > 12 or not paletteSize or paletteSize < 2
	or paletteSize > SECTION_CELLS or paletteSize > 2 ^ bits then return false, "invalid_packed_section" end
	local palette, paletteIndex = {}, {}
	for index = 1, paletteSize do
		local stateId = readU32( reader )
		if stateId == nil or not MC.Net.ValidateStateId( stateId )
		or not MC.IsValidBlockState( stateId ) or paletteIndex[stateId] ~= nil then
			return false, "invalid_section_palette"
		end
		palette[index] = stateId
		paletteIndex[stateId] = index - 1
	end
	local wordCount = readU16( reader )
	local expectedWords = math.ceil( SECTION_CELLS * bits / 32 )
	if wordCount ~= expectedWords then return false, "invalid_section_word_count" end
	local words = {}
	for index = 1, wordCount do
		local word = readU32( reader )
		if word == nil then return false, "truncated_section_words" end
		words[index] = word
	end
	local entryMask = maskForBits( bits )
	local refCount = {}
	for index = 0, paletteSize - 1 do refCount[index] = 0 end
	local counted = 0
	for cellIndex = 0, SECTION_CELLS - 1 do
		local localIndex = packedGet( words, bits, cellIndex, entryMask )
		if localIndex >= paletteSize then return false, "section_palette_index_out_of_range" end
		refCount[localIndex] = refCount[localIndex] + 1
		if palette[localIndex + 1] ~= 0 then counted = counted + 1 end
	end
	if counted ~= count then return false, "section_count_mismatch" end
	local dead = 0
	for index = 0, paletteSize - 1 do if refCount[index] == 0 then dead = dead + 1 end end
	return {
		palette = palette, paletteIndex = paletteIndex, refCount = refCount,
		paletteSize = paletteSize, bitsPerEntry = bits, entryMask = entryMask,
		words = words, count = count, deadPaletteEntries = dead,
	}, count
end

function Patch.Decode( payload, expected )
	if not isstring( payload ) or #payload < 14 or #payload > Patch.MAX_RAW_BYTES then
		return nil, "invalid_binary_patch_payload"
	end
	local reader = newReader( payload )
	if readBytes( reader, 4 ) ~= Patch.MAGIC then return nil, "binary_patch_magic_mismatch" end
	if readU8( reader ) ~= Patch.VERSION then return nil, "binary_patch_version_mismatch" end
	if readU8( reader ) ~= ( MC.CS or 16 ) or readU8( reader ) ~= ( MC.CH or 32 )
	or readU8( reader ) ~= SECTION_COUNT then return nil, "binary_patch_geometry_mismatch" end
	local chunkCount = readU16( reader )
	local declaredCells = readU32( reader )
	if not chunkCount or chunkCount < 1 or chunkCount > 64 or declaredCells == nil then
		return nil, "invalid_binary_patch_header"
	end
	if expected and integer( expected.chunkCount, 1, 64 ) ~= chunkCount then return nil, "binary_patch_chunk_count_mismatch" end
	if expected and integer( expected.cellCount, 0, 131072 ) ~= declaredCells then return nil, "binary_patch_cell_count_mismatch" end
	local chunks, seenChunks, totalCells = {}, {}, 0
	for chunkIndex = 1, chunkCount do
		local cx, cy, cz = readI32( reader ), readI32( reader ), readI32( reader )
		local flags = readU8( reader )
		local blockEntityCount = readU16( reader )
		if cx == nil or cy == nil or cz == nil or flags == nil or flags > 1
		or blockEntityCount == nil or blockEntityCount > CHUNK_CELLS then return nil, "invalid_binary_chunk_header" end
		local key = MC.ChunkKey( cx, cy, cz )
		if seenChunks[key] then return nil, "duplicate_binary_chunk" end
		seenChunks[key] = true
		local item = { cx = cx, cy = cy, cz = cz, key = key, sections = {}, blockEntities = {}, count = 0 }
		if flags == 1 then
			if blockEntityCount ~= 0 then return nil, "tombstone_block_entities" end
		else
			for sectionIndex = 1, SECTION_COUNT do
				local section, countOrError = decodeSection( reader )
				if section == false then return nil, tostring( countOrError ) .. ":" .. tostring( chunkIndex ) .. ":" .. tostring( sectionIndex ) end
				item.sections[sectionIndex] = section
				item.count = item.count + countOrError
			end
			local beSeen = {}
			for blockEntityIndex = 1, blockEntityCount do
				local envelope, envelopeError = decodeBlockEntity( reader, beSeen )
				if not envelope then return nil, tostring( envelopeError ) .. ":" .. tostring( chunkIndex ) .. ":" .. tostring( blockEntityIndex ) end
				local stateId = sectionStateAt( item.sections, envelope.localIndex )
				envelope.revision = expected and expected.revision or nil
				if not MC.DecodeBlockEntityEnvelope or not MC.DecodeBlockEntityEnvelope( stateId, envelope ) then
					return nil, "invalid_binary_block_entity"
				end
				item.blockEntities[#item.blockEntities + 1] = envelope
			end
		end
		chunks[chunkIndex] = item
		totalCells = totalCells + item.count
	end
	if totalCells ~= declaredCells then return nil, "binary_patch_total_count_mismatch" end
	if reader.position ~= reader.length + 1 then return nil, "binary_patch_trailing_data" end
	return { chunks = chunks, blocks = totalCells }
end


function Patch.EncodeTransportPayload( refs, measure )
	local encodeStarted = measure and SysTime() or nil
	local raw, metadataOrError = Patch.Encode( refs )
	if not raw then return nil, metadataOrError end
	if measure then metadataOrError.sectionEncodeMS = ( SysTime() - encodeStarted ) * 1000 end
	local payload, compression = raw, Patch.COMPRESSION_NONE
	local compressStarted = measure and SysTime() or nil
	if #raw >= Patch.COMPRESS_THRESHOLD and util and util.Compress then
		local compressed = util.Compress( raw )
		if isstring( compressed ) and #compressed < #raw then
			payload, compression = compressed, Patch.COMPRESSION_LZMA
		end
	end
	if measure then metadataOrError.compressMS = ( SysTime() - compressStarted ) * 1000 end
	metadataOrError.compression = compression
	metadataOrError.totalBytes = #payload
	return payload, metadataOrError
end

function Patch.DecodeTransportPayload( payload, compression, rawBytes, expected )
	compression = integer( compression, Patch.COMPRESSION_NONE, Patch.COMPRESSION_LZMA )
	rawBytes = integer( rawBytes, 1, Patch.MAX_RAW_BYTES )
	if not compression or not rawBytes or not isstring( payload ) then return nil, "invalid_binary_transport_header" end
	local raw = payload
	if compression == Patch.COMPRESSION_LZMA then raw = util.Decompress( payload ) end
	if not isstring( raw ) or #raw ~= rawBytes then return nil, "binary_patch_decompress_failed" end
	return Patch.Decode( raw, expected )
end

local function snapshotRefCellCount( ref )
	local chunk = ref
	if istable( ref ) and ref.patchRef == true then chunk = ref.chunk end
	if not chunk then return 0 end
	return integer( chunk.count or 0, 0, CHUNK_CELLS )
end

-- A full snapshot is a compact container of ordinary MCB9 payloads. Keeping
-- every batch independently compressed lets the native decoder consume it on
-- its worker without changing the DLL ABI or constructing one enormous job.
function Patch.EncodeSnapshotPayload( refs, measure )
	if not istable( refs ) then return nil, "invalid_snapshot_refs" end
	local batches, batch, batchCells = {}, {}, 0
	local totalChunks, totalCells = 0, 0

	local function flushBatch()
		if #batch == 0 then return true end
		local payload, metadataOrError = Patch.EncodeTransportPayload( batch, measure )
		if not payload then return nil, metadataOrError or "binary_snapshot_batch_encode_failed" end
		local metadata = metadataOrError
		batches[#batches + 1] = {
			payload = payload,
			compression = metadata.compression,
			rawBytes = metadata.rawBytes,
			chunkCount = metadata.chunkCount,
			cellCount = metadata.cellCount,
		}
		totalChunks = totalChunks + metadata.chunkCount
		totalCells = totalCells + metadata.cellCount
		batch, batchCells = {}, 0
		return true
	end

	for index, ref in ipairs( refs ) do
		local cells = snapshotRefCellCount( ref )
		if cells == nil then return nil, "invalid_snapshot_chunk_count:" .. tostring( index ) end
		if #batch >= Patch.SNAPSHOT_BATCH_MAX_CHUNKS
		or ( #batch > 0 and batchCells + cells > Patch.SNAPSHOT_BATCH_MAX_CELLS ) then
			local ok, err = flushBatch()
			if not ok then return nil, err end
		end
		batch[#batch + 1] = ref
		batchCells = batchCells + cells
	end
	local ok, err = flushBatch()
	if not ok then return nil, err end
	if #batches > Patch.SNAPSHOT_MAX_BATCHES or totalChunks > UINT32 - 1
	or totalCells > UINT32 - 1 then
		return nil, "binary_snapshot_limit"
	end

	local writer = newWriter()
	writeRaw( writer, Patch.SNAPSHOT_MAGIC )
	writeU8( writer, Patch.SNAPSHOT_VERSION )
	writeU8( writer, MC.CS or 16 )
	writeU8( writer, MC.CH or 32 )
	writeU8( writer, SECTION_COUNT )
	writeU16( writer, #batches )
	writeU32( writer, totalChunks )
	writeU32( writer, totalCells )
	for _, item in ipairs( batches ) do
		writeU8( writer, item.compression )
		writeU16( writer, item.chunkCount )
		writeU32( writer, item.rawBytes )
		writeU32( writer, item.cellCount )
		writeU32( writer, #item.payload )
		writeRaw( writer, item.payload )
	end
	local payload = finishWriter( writer )
	return payload, {
		binarySnapshot = true,
		batchCount = #batches,
		chunkCount = totalChunks,
		cellCount = totalCells,
		totalBytes = #payload,
	}
end

function Patch.IsSnapshotPayload( payload )
	return isstring( payload ) and #payload >= 4
		and string.sub( payload, 1, 4 ) == Patch.SNAPSHOT_MAGIC
end

function Patch.DecodeSnapshotPayload( payload )
	if not Patch.IsSnapshotPayload( payload ) or #payload < 18 then
		return nil, "invalid_binary_snapshot_payload"
	end
	local reader = newReader( payload )
	if readBytes( reader, 4 ) ~= Patch.SNAPSHOT_MAGIC then return nil, "binary_snapshot_magic_mismatch" end
	if readU8( reader ) ~= Patch.SNAPSHOT_VERSION then return nil, "binary_snapshot_version_mismatch" end
	if readU8( reader ) ~= ( MC.CS or 16 ) or readU8( reader ) ~= ( MC.CH or 32 )
	or readU8( reader ) ~= SECTION_COUNT then return nil, "binary_snapshot_geometry_mismatch" end
	local batchCount = readU16( reader )
	local declaredChunks = readU32( reader )
	local declaredCells = readU32( reader )
	if batchCount == nil or batchCount > Patch.SNAPSHOT_MAX_BATCHES
	or declaredChunks == nil or declaredCells == nil then return nil, "invalid_binary_snapshot_header" end
	if ( batchCount == 0 ) ~= ( declaredChunks == 0 ) then return nil, "invalid_empty_binary_snapshot" end

	local batches, totalChunks, totalCells = {}, 0, 0
	for batchIndex = 1, batchCount do
		local compression = readU8( reader )
		local chunkCount = readU16( reader )
		local rawBytes = readU32( reader )
		local cellCount = readU32( reader )
		local payloadBytes = readU32( reader )
		if compression == nil or compression < Patch.COMPRESSION_NONE or compression > Patch.COMPRESSION_LZMA
		or not chunkCount or chunkCount < 1 or chunkCount > Patch.SNAPSHOT_BATCH_MAX_CHUNKS
		or not rawBytes or rawBytes < 1 or rawBytes > Patch.MAX_RAW_BYTES
		or cellCount == nil or cellCount > Patch.SNAPSHOT_BATCH_MAX_CELLS
		or not payloadBytes or payloadBytes < 1 or payloadBytes > Patch.MAX_RAW_BYTES then
			return nil, "invalid_binary_snapshot_batch_header:" .. tostring( batchIndex )
		end
		local batchPayload = readBytes( reader, payloadBytes )
		if not batchPayload then return nil, "truncated_binary_snapshot_batch:" .. tostring( batchIndex ) end
		batches[batchIndex] = {
			payload = batchPayload,
			compression = compression,
			rawBytes = rawBytes,
			chunkCount = chunkCount,
			cellCount = cellCount,
		}
		totalChunks = totalChunks + chunkCount
		totalCells = totalCells + cellCount
	end
	if reader.position ~= reader.length + 1 then return nil, "binary_snapshot_trailing_data" end
	if totalChunks ~= declaredChunks then return nil, "binary_snapshot_chunk_count_mismatch" end
	if totalCells ~= declaredCells then return nil, "binary_snapshot_cell_count_mismatch" end
	return {
		batches = batches,
		batchCount = batchCount,
		chunkCount = totalChunks,
		cellCount = totalCells,
	}
end
