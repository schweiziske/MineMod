--[[----------------------------------------------------------------------------
	MC : canonical block-state save encoder.

	Runtime stateId values never leave the process. Saves carry canonical state
	specifications and remain wrapped by sv_world's existing util.Compress layer.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

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

function SV.BuildStateSaveData( slotName, options )
	local chunks, palette, paletteIndex = {}, {}, {}
	local specByStateId = {}
	for _, chunk in ipairs( orderedWorldChunks() ) do
		local cells = {}
		local encodeError
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
		end )
		if encodeError then return nil, nil, "state_encode_failed:" .. tostring( encodeError ) end
		local blockEntities, blockEntityError = encodeBlockEntities( chunk, options )
		if blockEntityError then return nil, nil, "block_entity_encode_failed:" .. tostring( blockEntityError ) end
		chunks[#chunks + 1] = { chunk.cx, chunk.cy, chunk.cz, packSparseCells( cells ), blockEntities }
	end

	return {
		v = 9,
		formatVersion = 9,
		schemaHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil,
		map = game.GetMap(),
		slotName = slotName,
		savedAt = os.time(),
		bs = MC.BS,
		cs = MC.CS,
		h = MC.CH,
		p = palette,
		chunks = chunks,
	}, chunks
end
