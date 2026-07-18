--[[----------------------------------------------------------------------------
	MC : canonical block-state save encoder.

	Runtime stateId values never leave the process. Saves carry canonical state
	specifications and remain wrapped by sv_world's existing util.Compress layer.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local function packSparseCells( cells )
	local out = {}
	for i = 1, #cells, 2 do
		out[#out + 1] = tostring( cells[i] ) .. ":" .. tostring( cells[i + 1] )
	end
	return table.concat( out, ";" )
end

local function orderedWorldChunks()
	local chunks = {}
	for _, chunk in pairs( MC.World ) do
		if chunk.count and chunk.count > 0 then chunks[#chunks + 1] = chunk end
	end
	table.sort( chunks, function( a, b )
		if a.cz ~= b.cz then return a.cz < b.cz end
		if a.cy ~= b.cy then return a.cy < b.cy end
		return a.cx < b.cx
	end )
	return chunks
end

local function encodeBlockEntities( chunk, options )
	if not chunk.blockEntities then return nil end
	local indexes = {}
	for localIndex in pairs( chunk.blockEntities ) do indexes[#indexes + 1] = localIndex end
	table.sort( indexes )
	local out = {}
	for _, localIndex in ipairs( indexes ) do
		if not MC.LocalIndexInRange( localIndex ) then return nil, "invalid_block_entity_index" end
		local record = chunk.blockEntities[localIndex]
		local lx, ly, lz = MC.DecodeLocal( localIndex )
		local stateId = MC.GetBlockState(
			chunk.cx * MC.CS + lx,
			chunk.cy * MC.CS + ly,
			chunk.cz * MC.CH + lz
		)
		local valid, definition = MC.ValidateBlockEntityRecord( stateId, record )
		if valid ~= true then return nil, definition or "invalid_block_entity" end
		if not ( options and options.forClient == true and definition.serverOnly ) then
			local envelope, encodeError = MC.EncodeBlockEntityEnvelope( stateId, record, false )
			if not envelope then return nil, encodeError or "invalid_block_entity" end
			out[#out + 1] = {
				localIndex = localIndex,
				type = envelope.type,
				codecVersion = envelope.codecVersion,
				data = envelope.data,
				revision = envelope.revision,
			}
		end
	end
	return #out > 0 and out or nil
end

local function encodeOpaqueBlockEntities( chunk, options )
	if options and options.forClient == true then return nil end
	if not chunk.opaqueBlockEntities then return nil end
	local indexes = {}
	for localIndex in pairs( chunk.opaqueBlockEntities ) do indexes[#indexes + 1] = localIndex end
	table.sort( indexes )
	local out, totalBytes = {}, 0
	for _, localIndex in ipairs( indexes ) do
		if not MC.LocalIndexInRange( localIndex ) then return nil, "invalid_opaque_block_entity_index" end
		local record = copyValue( chunk.opaqueBlockEntities[localIndex] )
		if not istable( record ) then return nil, "invalid_opaque_block_entity" end
		if not isstring( record.sourceType ) or record.sourceType == ""
		or record.encoding ~= "typed-nbt-json-v1" or not istable( record.data ) then
			return nil, "invalid_opaque_block_entity_record"
		end
		local json = util.TableToJSON( record.data, false )
		if not json or #json < 1 or #json > 1048576 then return nil, "opaque_block_entity_too_large" end
		totalBytes = totalBytes + #json
		if totalBytes > 8388608 then return nil, "opaque_chunk_budget_exceeded" end
		record.localIndex = localIndex
		out[#out + 1] = record
	end
	return #out > 0 and out or nil
end

function SV.BuildStateSaveData( slotName, options )
	local chunks, palette, paletteIndex = {}, {}, {}
	local specByStateId = {}
	local blockCount = 0
	for _, chunk in ipairs( orderedWorldChunks() ) do
		local cells = {}
		local encodeError
		local chunkBlockCount = 0
		MC.ForEachBlockState( chunk, function( _, _, _, lx, ly, lz, stateId )
			if encodeError then return end
			local spec = specByStateId[stateId]
			if not spec then
				local err
				spec, err = MC.FormatBlockState( stateId )
				if not spec then
					encodeError = err or "invalid_state"
					return
				end
				specByStateId[stateId] = spec
			end
			local paletteId = paletteIndex[spec]
			if paletteId == nil then
				paletteId = #palette
				palette[#palette + 1] = spec
				paletteIndex[spec] = paletteId
			end
			local li = lx + ly * MC.CS + lz * MC.CS * MC.CS
			cells[#cells + 1] = li
			cells[#cells + 1] = paletteId
			chunkBlockCount = chunkBlockCount + 1
		end )
		if encodeError then return nil, nil, "state_encode_failed:" .. tostring( encodeError ) end
		local storedChunkCount = math.max( 0, math.floor( tonumber( chunk.count ) or 0 ) )
		if chunkBlockCount ~= storedChunkCount then
			return nil, nil, "chunk_count_mismatch:" .. tostring( chunk.key or "?")
				.. ":" .. tostring( storedChunkCount ) .. ":" .. tostring( chunkBlockCount )
		end
		blockCount = blockCount + chunkBlockCount
		local blockEntities, blockEntityError = encodeBlockEntities( chunk, options )
		if blockEntityError then return nil, nil, "block_entity_encode_failed:" .. tostring( blockEntityError ) end
		local opaqueBlockEntities, opaqueError = encodeOpaqueBlockEntities( chunk, options )
		if opaqueError then return nil, nil, "opaque_block_entity_encode_failed:" .. tostring( opaqueError ) end
		chunks[#chunks + 1] = { chunk.cx, chunk.cy, chunk.cz, packSparseCells( cells ), blockEntities, opaqueBlockEntities }
	end

	return {
		v = 10,
		formatVersion = 10,
		schemaHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil,
		sourceDataVersion = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.worldVersion or nil,
		map = game.GetMap(),
		slotName = slotName,
		savedAt = os.time(),
		blockCount = blockCount,
		bs = MC.BS,
		cs = MC.CS,
		h = MC.CH,
		p = palette,
		chunks = chunks,
	}, chunks
end

-- Verify the actual bytes written to disk. Re-counting sparse cells after a
-- JSON round-trip is not a valid integrity check: util.JSONToTable may return
-- numerically keyed tables in a different shape even though the compressed
-- payload is byte-for-byte correct and loadable. The encoded JSON is already
-- canonical for this save operation, so exact decompression equality is the
-- strongest write/truncation check available.
function SV.VerifyStateSavePayload( raw, expectedJSON, expectedBlocks, expectedChunks )
	if not isstring( raw ) or raw == "" then return false, "save_verify_read_failed" end
	local decoded = util.Decompress( raw )
	if not isstring( decoded ) then return false, "save_verify_decompress_failed" end
	if decoded ~= expectedJSON then return false, "save_verify_payload_mismatch" end

	local data = util.JSONToTable( decoded )
	if not istable( data ) then return false, "save_verify_json_failed" end
	local formatVersion = math.floor( tonumber( data.formatVersion or data.v ) or -1 )
	if formatVersion ~= 10 then return false, "save_verify_version_mismatch" end
	if math.floor( tonumber( data.blockCount ) or -1 ) ~= expectedBlocks then
		return false, "save_verify_block_count_mismatch"
	end
	if not istable( data.chunks ) or #data.chunks ~= expectedChunks then
		return false, "save_verify_chunk_count_mismatch"
	end
	return true, data
end
