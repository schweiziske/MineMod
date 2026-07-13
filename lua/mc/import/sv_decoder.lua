-- Strict, read-only decoder for Phase 5 Minecraft import bundles.

MC = MC or {}
MC.Import = MC.Import or {}

local Import = MC.Import

local function localCellPosition( chunk, localIndex )
	local lx, ly, lz = MC.DecodeLocal( localIndex )
	return chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly, chunk.cz * MC.CH + lz
end

local function opaqueCount( value )
	return istable( value ) and #value or 0
end

local function validateOpaqueBlockEntities( entries, expectedDataVersion )
	if entries == nil then return {}, 0 end
	if not istable( entries ) then return nil, "invalid_opaque_block_entities" end
	local out, seen, totalBytes = {}, {}, 0
	for index, entry in ipairs( entries ) do
		if not istable( entry ) then return nil, "invalid_opaque_block_entity", index end
		local localIndex = math.floor( tonumber( entry.localIndex ) or -1 )
		if not MC.LocalIndexInRange( localIndex ) or seen[localIndex] then
			return nil, "invalid_opaque_block_entity_index", index
		end
		seen[localIndex] = true
		if not isstring( entry.sourceType ) or entry.sourceType == "" or #entry.sourceType > 160 then
			return nil, "invalid_opaque_block_entity_type", index
		end
		if math.floor( tonumber( entry.sourceDataVersion ) or -1 ) ~= expectedDataVersion then
			return nil, "opaque_block_entity_version_mismatch", index
		end
		if entry.encoding ~= "typed-nbt-json-v1" or not istable( entry.data ) then
			return nil, "invalid_opaque_block_entity_encoding", index
		end
		local json = util.TableToJSON( entry.data, false )
		local bytes = json and #json or 0
		if bytes < 1 or bytes > 1048576 then return nil, "opaque_block_entity_too_large", index end
		totalBytes = totalBytes + bytes
		if totalBytes > 8388608 then return nil, "opaque_chunk_budget_exceeded", index end
		out[#out + 1] = entry
	end
	return out, totalBytes
end

function Import.Preflight( source, options )
	options = istable( options ) and options or {}
	if not istable( source ) or not istable( source.manifest ) then return nil, "invalid_import_source" end
	local bundle = source.manifest
	local metadataOK, metadataError = Import.ValidateSourceMetadata( bundle )
	if not metadataOK then return nil, metadataError end
	local palette, paletteError, paletteIndex = Import.ValidatePalette( bundle.palette or bundle.p )
	if not palette then return nil, paletteError, paletteIndex end

	local loss = bundle.lossReport
	if not istable( loss ) then return nil, "missing_loss_report" end
	local unknownPolicy = tostring( options.unknownPolicy or Import.UNKNOWN_POLICY_REJECT )
	if loss.archiveRoundTripLossless ~= true or loss.substitutedOrDropped == true then
		return nil, "import_contains_actual_loss"
	end
	if unknownPolicy == Import.UNKNOWN_POLICY_REJECT then
		if loss.runtimeComplete ~= true or loss.substitutedOrDropped == true
		or ( tonumber( loss.eventCount ) or 0 ) > 0 then
			return nil, "import_loss_report_not_clean"
		end
	elseif unknownPolicy == Import.UNKNOWN_POLICY_PRESERVE then
		for _, event in ipairs( loss.events or {} ) do
			if not istable( event ) or event.action ~= "preserve_opaque" then
				return nil, "unsupported_preserve_event"
			end
		end
	end

	local plan = {
		bundle = bundle,
		palette = palette,
		chunks = {},
		cellCount = 0,
		opaqueBlockEntityCount = 0,
		opaqueStateCount = 0,
		lossReport = loss,
	}
	local totalOpaqueBytes = 0
	local seenCells = {}
	for chunkIndex, record in ipairs( source.chunks or {} ) do
		local chunk, chunkError = Import.ValidateChunkRecord( record, palette.count )
		if not chunk then return nil, chunkError, chunkIndex end
		local decoded = { cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, cells = {} }
		for _, cell in ipairs( chunk.cells ) do
			local bx, by, bz = localCellPosition( chunk, cell.localIndex )
			if options.worldBoundsOK and options.worldBoundsOK( bx, by, bz ) ~= true then
				return nil, "import_cell_out_of_bounds", chunkIndex
			end
			local key = MC.CellKey( bx, by, bz )
			if seenCells[key] then return nil, "duplicate_world_cell", chunkIndex end
			seenCells[key] = true
			decoded.cells[#decoded.cells + 1] = {
				localIndex = cell.localIndex,
				stateId = palette.stateIds[cell.paletteIndex],
			}
			plan.cellCount = plan.cellCount + 1
		end
		local opaqueBlockEntities, opaqueValue, opaqueIndex = validateOpaqueBlockEntities(
			chunk.opaqueBlockEntities,
			math.floor( tonumber( bundle.source.dataVersion ) or -1 )
		)
		if not opaqueBlockEntities then return nil, opaqueValue, opaqueIndex end
		local chunkOpaqueBytes = opaqueValue or 0
		totalOpaqueBytes = totalOpaqueBytes + chunkOpaqueBytes
		if totalOpaqueBytes > 268435456 then return nil, "opaque_import_budget_exceeded" end
		plan.opaqueBlockEntityCount = plan.opaqueBlockEntityCount + #opaqueBlockEntities
		plan.opaqueStateCount = plan.opaqueStateCount + opaqueCount( chunk.opaqueStates )
		decoded.opaqueBlockEntities = opaqueBlockEntities
		decoded.opaqueStates = chunk.opaqueStates
		plan.chunks[#plan.chunks + 1] = decoded
	end

	if plan.opaqueStateCount > 0 then return nil, "opaque_states_not_supported" end
	if unknownPolicy == Import.UNKNOWN_POLICY_REJECT and plan.opaqueBlockEntityCount > 0 then
		return nil, "opaque_import_data_rejected"
	end
	return plan
end
