--[[----------------------------------------------------------------------------
	MCB4 region save writer.

	Region files use a .json suffix for GMAD compatibility, but contain opaque
	MCB4 binary fragments. The manifest and optional .side.json lane are JSON.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local REGION_CHUNKS = 32
local SECTION_CELLS = 4096
local UINT32 = 4294967296
local unpackValues = unpack

local function newWriter()
	return { parts = {}, bytes = {}, count = 0 }
end

local function flushBytes( writer )
	if writer.count <= 0 then return end
	writer.parts[#writer.parts + 1] = string.char( unpackValues( writer.bytes, 1, writer.count ) )
	writer.bytes, writer.count = {}, 0
end

local function writeU8( writer, value )
	local count = writer.count + 1
	writer.bytes[count] = value % 256
	writer.count = count
	if count >= 192 then flushBytes( writer ) end
end

local function writeU16( writer, value )
	writeU8( writer, value )
	writeU8( writer, math.floor( value / 256 ) )
end

local function writeU32( writer, value )
	value = value % UINT32
	writeU8( writer, value )
	writeU8( writer, math.floor( value / 256 ) )
	writeU8( writer, math.floor( value / 65536 ) )
	writeU8( writer, math.floor( value / 16777216 ) )
end

local function finishWriter( writer )
	flushBytes( writer )
	return table.concat( writer.parts )
end

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local function orderedWorldChunks()
	local chunks = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and ( tonumber( chunk.count ) or 0 ) > 0 then chunks[#chunks + 1] = chunk end
	end
	table.sort( chunks, function( a, b )
		if a.cz ~= b.cz then return a.cz < b.cz end
		if a.cy ~= b.cy then return a.cy < b.cy end
		return a.cx < b.cx
	end )
	return chunks
end

local function regionCoords( cx, cy )
	return math.floor( cx / REGION_CHUNKS ), math.floor( cy / REGION_CHUNKS )
end

local function regionKey( rx, ry ) return tostring( rx ) .. ":" .. tostring( ry ) end
local function regionName( rx, ry ) return "r." .. tostring( rx ) .. "." .. tostring( ry ) end

local function collectPaletteAndRegions( chunks )
	local palette, paletteBySpec, paletteByState = {}, {}, {}
	local regions, blocks = {}, 0
	for _, chunk in ipairs( chunks ) do
		local rx, ry = regionCoords( chunk.cx, chunk.cy )
		local key = regionKey( rx, ry )
		local region = regions[key]
		if not region then
			region = { rx = rx, ry = ry, chunks = {} }
			regions[key] = region
		end
		region.chunks[#region.chunks + 1] = chunk
		local counted, encodeError = 0, nil
		MC.ForEachBlockState( chunk, function( _, _, _, _, _, _, stateId )
			if encodeError then return end
			local paletteIndex = paletteByState[stateId]
			if paletteIndex == nil then
				local spec, err = MC.FormatBlockState( stateId )
				if not spec then encodeError = err or "invalid_state" return end
				paletteIndex = paletteBySpec[spec]
				if paletteIndex == nil then
					paletteIndex = #palette
					palette[#palette + 1] = spec
					paletteBySpec[spec] = paletteIndex
				end
				paletteByState[stateId] = paletteIndex
			end
			counted = counted + 1
		end )
		if encodeError then return nil, encodeError end
		if counted ~= math.floor( tonumber( chunk.count ) or -1 ) then
			return nil, "chunk_count_mismatch:" .. tostring( chunk.key )
		end
		blocks = blocks + counted
	end
	if #palette > 65535 then return nil, "mcb4_global_palette_limit" end
	local orderedRegions = {}
	for _, region in pairs( regions ) do orderedRegions[#orderedRegions + 1] = region end
	table.sort( orderedRegions, function( a, b )
		if a.rx ~= b.rx then return a.rx < b.rx end
		return a.ry < b.ry
	end )
	return {
		palette = palette,
		paletteByState = paletteByState,
		regions = orderedRegions,
		blocks = blocks,
	}
end

local function collectChunkCells( chunk, paletteByState )
	local cells, encodeError = {}, nil
	MC.ForEachBlockState( chunk, function( _, _, _, lx, ly, lz, stateId )
		if encodeError then return end
		local paletteIndex = paletteByState[stateId]
		if paletteIndex == nil then encodeError = "missing_global_palette_state" return end
		cells[#cells + 1] = {
			localIndex = lx + ly * MC.CS + lz * MC.CS * MC.CS,
			paletteIndex = paletteIndex,
		}
	end )
	if encodeError then return nil, encodeError end
	table.sort( cells, function( a, b ) return a.localIndex < b.localIndex end )
	if #cells ~= math.floor( tonumber( chunk.count ) or -1 ) then return nil, "chunk_count_mismatch" end
	return cells
end

local function bitsForPalette( count )
	local bits, capacity = 1, 2
	while capacity < count do bits, capacity = bits + 1, capacity * 2 end
	return bits
end

local function encodeMCB4Fragment( chunk, paletteByState )
	local cells, cellError = collectChunkCells( chunk, paletteByState )
	if not cells then return nil, cellError end
	if #cells > 65535 then return nil, "mcb4_chunk_cell_limit" end
	local sections, sectionOrder = {}, {}
	for _, cell in ipairs( cells ) do
		local sectionY = math.floor( cell.localIndex / SECTION_CELLS )
		local section = sections[sectionY]
		if not section then
			section = { y = sectionY, cells = {} }
			sections[sectionY] = section
			sectionOrder[#sectionOrder + 1] = section
		end
		section.cells[#section.cells + 1] = {
			localIndex = cell.localIndex % SECTION_CELLS,
			paletteIndex = cell.paletteIndex,
		}
	end
	table.sort( sectionOrder, function( a, b ) return a.y < b.y end )

	local writer = newWriter()
	writeU32( writer, chunk.cx ); writeU32( writer, chunk.cy ); writeU32( writer, chunk.cz )
	writeU16( writer, #cells ); writeU16( writer, #sectionOrder )
	for _, section in ipairs( sectionOrder ) do
		local localPalette, localIndex = {}, {}
		for _, cell in ipairs( section.cells ) do
			if localIndex[cell.paletteIndex] == nil then
				localIndex[cell.paletteIndex] = #localPalette
				localPalette[#localPalette + 1] = cell.paletteIndex
			end
		end
		local bits = bitsForPalette( #localPalette )
		writeU16( writer, section.y )
		writeU16( writer, #section.cells )
		writeU16( writer, #localPalette )
		writeU8( writer, bits )
		for _, paletteIndex in ipairs( localPalette ) do writeU16( writer, paletteIndex ) end

		local occupancy = {}
		for index = 1, 512 do occupancy[index] = 0 end
		for _, cell in ipairs( section.cells ) do
			local byteIndex = math.floor( cell.localIndex / 8 ) + 1
			occupancy[byteIndex] = bit.bor( occupancy[byteIndex], bit.lshift( 1, cell.localIndex % 8 ) )
		end
		for index = 1, 512 do writeU8( writer, occupancy[index] ) end

		local streamBytes = math.ceil( #section.cells * bits / 8 )
		local stream = {}
		for index = 1, streamBytes do stream[index] = 0 end
		local bitOffset = 0
		for _, cell in ipairs( section.cells ) do
			local value = localIndex[cell.paletteIndex]
			for bitIndex = 0, bits - 1 do
				if bit.band( value, bit.lshift( 1, bitIndex ) ) ~= 0 then
					local absolute = bitOffset + bitIndex
					local byteIndex = math.floor( absolute / 8 ) + 1
					stream[byteIndex] = bit.bor( stream[byteIndex], bit.lshift( 1, absolute % 8 ) )
				end
			end
			bitOffset = bitOffset + bits
		end
		for index = 1, streamBytes do writeU8( writer, stream[index] ) end
	end
	return finishWriter( writer ), cells
end

local function encodeBlockEntities( chunk )
	if not chunk.blockEntities then return nil end
	local indexes = {}
	for localIndex in pairs( chunk.blockEntities ) do indexes[#indexes + 1] = localIndex end
	table.sort( indexes )
	local out = {}
	for _, localIndex in ipairs( indexes ) do
		if not MC.LocalIndexInRange( localIndex ) then return nil, "invalid_block_entity_index" end
		local lx, ly, lz = MC.DecodeLocal( localIndex )
		local stateId = MC.GetBlockState(
			chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly, chunk.cz * MC.CH + lz )
		local valid, definition = MC.ValidateBlockEntityRecord( stateId, chunk.blockEntities[localIndex] )
		if valid ~= true then return nil, definition or "invalid_block_entity" end
		local envelope, encodeError = MC.EncodeBlockEntityEnvelope( stateId, chunk.blockEntities[localIndex], false )
		if not envelope then return nil, encodeError or "invalid_block_entity" end
		out[#out + 1] = {
			localIndex = localIndex,
			type = envelope.type,
			codecVersion = envelope.codecVersion,
			data = envelope.data,
			revision = envelope.revision,
		}
	end
	return #out > 0 and out or nil
end

local function encodeOpaqueBlockEntities( chunk )
	if not chunk.opaqueBlockEntities then return nil end
	local indexes = {}
	for localIndex in pairs( chunk.opaqueBlockEntities ) do indexes[#indexes + 1] = localIndex end
	table.sort( indexes )
	local out = {}
	for _, localIndex in ipairs( indexes ) do
		if not MC.LocalIndexInRange( localIndex ) then return nil, "invalid_opaque_block_entity_index" end
		local record = copyValue( chunk.opaqueBlockEntities[localIndex] )
		if not istable( record ) then return nil, "invalid_opaque_block_entity" end
		record.localIndex = localIndex
		out[#out + 1] = record
	end
	return #out > 0 and out or nil
end

local function chunkHasSideData( chunk )
	return chunk.blockEntities and next( chunk.blockEntities ) ~= nil
		or chunk.opaqueBlockEntities and next( chunk.opaqueBlockEntities ) ~= nil
end

local function sideChunkRecord( chunk, cells )
	local packed = {}
	for _, cell in ipairs( cells ) do
		packed[#packed + 1] = cell.localIndex
		packed[#packed + 1] = cell.paletteIndex
	end
	local blockEntities, blockEntityError = encodeBlockEntities( chunk )
	if blockEntityError then return nil, blockEntityError end
	local opaque, opaqueError = encodeOpaqueBlockEntities( chunk )
	if opaqueError then return nil, opaqueError end
	return { chunk.cx, chunk.cy, chunk.cz, packed, blockEntities, opaque }
end

local function stageBinaryFile( path, data )
	local handle = file.Open( path, "wb", "DATA" )
	if not handle then return false, "region_open_failed:" .. path end
	handle:Write( data )
	handle:Close()
	if not file.Exists( path, "DATA" ) or file.Size( path, "DATA" ) ~= #data then
		file.Delete( path )
		return false, "region_write_failed:" .. path
	end
	return true
end

local function rollbackCommittedFiles( committed )
	local failed = {}
	for index = #( committed or {} ), 1, -1 do
		local item = committed[index]
		if item.hadOriginal and not file.Exists( item.backup, "DATA" ) then
			failed[#failed + 1] = item.final
		else
			if file.Exists( item.final, "DATA" ) then file.Delete( item.final ) end
			if not file.Exists( item.final, "DATA" ) and item.hadOriginal then
				file.Rename( item.backup, item.final )
			end
			local restored = item.hadOriginal
				and file.Exists( item.final, "DATA" ) and not file.Exists( item.backup, "DATA" )
				or not item.hadOriginal and not file.Exists( item.final, "DATA" )
			if not restored then failed[#failed + 1] = item.final end
		end
	end
	if #failed > 0 then return false, table.concat( failed, "," ) end
	return true
end

local function commitStagedFiles( staged )
	local committed = {}
	local function reject( item, code )
		local restored, restoreError = rollbackCommittedFiles( committed )
		local reason = ( item.kind or "region" ) .. "_" .. code .. ":" .. item.final
		if not restored then reason = reason .. ":rollback_failed:" .. restoreError end
		return nil, reason
	end
	for _, item in ipairs( staged ) do
		if file.Exists( item.backup, "DATA" ) and not file.Exists( item.final, "DATA" ) then
			return reject( item, "backup_recovery_required" )
		end
		if file.Exists( item.backup, "DATA" ) then file.Delete( item.backup ) end
		if file.Exists( item.backup, "DATA" ) then return reject( item, "backup_cleanup_failed" ) end
		item.hadOriginal = file.Exists( item.final, "DATA" )
		if item.hadOriginal then
			file.Rename( item.final, item.backup )
			if file.Exists( item.final, "DATA" ) or not file.Exists( item.backup, "DATA" ) then
				return reject( item, "backup_failed" )
			end
		end
		-- The old file is safely in its backup (or no old file existed). Include
		-- this item in rollback even if installing the replacement fails.
		committed[#committed + 1] = item
		file.Rename( item.temp, item.final )
		if file.Exists( item.temp, "DATA" ) or not file.Exists( item.final, "DATA" ) then
			return reject( item, "commit_failed" )
		end
	end
	return committed
end

local function cleanStagedFiles( staged )
	for _, item in ipairs( staged or {} ) do
		if file.Exists( item.temp, "DATA" ) then file.Delete( item.temp ) end
	end
end

-- Keep the prior edit overlay until its replacement has been written and read
-- back exactly; file.Write alone cannot establish that a save succeeded.
function SV.WriteStateSaveFile( path, data )
	if not isstring( path ) or not isstring( data ) then return false, "invalid_save_file" end
	path = string.gsub( path, "\\", "/" )
	local stem, extension = string.match( path, "^(.*)(%.[^/%.]+)$" )
	if not stem then return false, "invalid_save_file_path" end
	file.CreateDir( string.GetPathFromFilename( path ) )
	local item = { temp = stem .. ".new" .. extension, final = path,
		backup = stem .. ".bak" .. extension, kind = "save_file" }
	local staged = { item }
	local written, writeError = stageBinaryFile( item.temp, data )
	if not written then cleanStagedFiles( staged ) return false, writeError end
	if file.Read( item.temp, "DATA" ) ~= data then
		cleanStagedFiles( staged )
		return false, "save_file_verify_failed:" .. path
	end
	local committed, commitError = commitStagedFiles( staged )
	if not committed then cleanStagedFiles( staged ) return false, commitError end
	if file.Exists( item.backup, "DATA" ) then file.Delete( item.backup ) end
	return true
end

function SV.WriteStateRegionSave( manifestPath, slotName )
	manifestPath = string.gsub( tostring( manifestPath or "" ), "\\", "/" )
	local root = string.GetPathFromFilename( manifestPath )
	if manifestPath == "" or root == "" or not string.EndsWith( manifestPath, "/manifest.json" ) then
		return nil, "invalid_region_manifest_path"
	end
	local regionDir = root .. "regions"
	file.CreateDir( root )
	file.CreateDir( regionDir )

	local chunks = orderedWorldChunks()
	local layout, layoutError = collectPaletteAndRegions( chunks )
	if not layout then return nil, layoutError end
	local parts, chunkIndex, staged, referenced = {}, {}, {}, {}
	local fastChunks, fallbackChunks, fastBytes = 0, 0, 0

	for partNo, region in ipairs( layout.regions ) do
		local baseName = regionName( region.rx, region.ry )
		local fastFinal = regionDir .. "/" .. baseName .. ".json"
		local fastTemp = regionDir .. "/" .. baseName .. ".new.json"
		local fastBackup = regionDir .. "/" .. baseName .. ".bak.json"
		local sideFinal = regionDir .. "/" .. baseName .. ".side.json"
		local sideTemp = regionDir .. "/" .. baseName .. ".side.new.json"
		local sideBackup = regionDir .. "/" .. baseName .. ".side.bak.json"
		local fragments, regionBytes, sideChunks = {}, 0, {}

		for _, chunk in ipairs( region.chunks ) do
			local fragment, cellsOrError = encodeMCB4Fragment( chunk, layout.paletteByState )
			if not fragment then cleanStagedFiles( staged ) return nil, cellsOrError end
			local entry = { part = partNo }
			if chunkHasSideData( chunk ) then
				local record, sideError = sideChunkRecord( chunk, cellsOrError )
				if not record then cleanStagedFiles( staged ) return nil, sideError end
				sideChunks[#sideChunks + 1] = record
				entry.index = #sideChunks
				fallbackChunks = fallbackChunks + 1
			else
				entry.fastOffset = regionBytes
				entry.fastBytes = #fragment
				fragments[#fragments + 1] = fragment
				regionBytes = regionBytes + #fragment
				fastChunks = fastChunks + 1
			end
			chunkIndex[MC.ChunkKeyString( chunk.cx, chunk.cy, chunk.cz )] = entry
		end

		local part = { region = { region.rx, region.ry } }
		if regionBytes > 0 then
			local ok, writeError = stageBinaryFile( fastTemp, table.concat( fragments ) )
			if not ok then cleanStagedFiles( staged ) return nil, writeError end
			staged[#staged + 1] = { temp = fastTemp, final = fastFinal, backup = fastBackup }
			part.fastPath = "regions/" .. baseName .. ".json"
			part.fastFormat = "MCB4"
			part.fastBytes = regionBytes
			fastBytes = fastBytes + regionBytes
			referenced[baseName .. ".json"] = true
		end
		if #sideChunks > 0 then
			local sideJSON = util.TableToJSON( { v = 10, h = MC.CH, chunks = sideChunks } )
			if not sideJSON then cleanStagedFiles( staged ) return nil, "side_json_failed" end
			file.Write( sideTemp, sideJSON )
			if file.Read( sideTemp, "DATA" ) ~= sideJSON then
				file.Delete( sideTemp )
				cleanStagedFiles( staged )
				return nil, "side_write_failed"
			end
			staged[#staged + 1] = { temp = sideTemp, final = sideFinal, backup = sideBackup }
			part.path = "regions/" .. baseName .. ".side.json"
			part.chunks = #sideChunks
			referenced[baseName .. ".side.json"] = true
		end
		parts[#parts + 1] = part
	end

	local savedAt = os.time()
	local registry = MC.BuildModRegistrySnapshot and MC.BuildModRegistrySnapshot( layout.palette ) or nil
	local persistenceHash = registry and MC.ModRegistrySnapshotHash and MC.ModRegistrySnapshotHash( registry )
		or MC.GetEffectiveBlockStateRegistryHash and MC.GetEffectiveBlockStateRegistryHash() or nil
	local manifest = {
		v = 10,
		formatVersion = 10,
		schemaHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil,
		registryHash = persistenceHash,
		sourceDataVersion = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.worldVersion or nil,
		registry = registry,
		map = game.GetMap(),
		slotName = slotName,
		savedAt = savedAt,
		blockCount = layout.blocks,
		bs = MC.BS,
		cs = MC.CS,
		h = MC.CH,
		chunks = {},
		p = layout.palette,
		parts = parts,
		chunkIndex = chunkIndex,
		regionChunks = REGION_CHUNKS,
		fastFormat = fastChunks > 0 and "MCB4" or nil,
		editOverlay = "edits.json",
		stats = {
			parts = #parts,
			regions = #parts,
			chunks = #chunks,
			blocks = layout.blocks,
			fastParts = 0,
			fastChunks = fastChunks,
			fallbackChunks = fallbackChunks,
			fastBytes = fastBytes,
		},
	}
	for _, part in ipairs( parts ) do
		if part.fastFormat == "MCB4" then manifest.stats.fastParts = manifest.stats.fastParts + 1 end
	end
	local manifestJSON = util.TableToJSON( manifest )
	if not manifestJSON then cleanStagedFiles( staged ) return nil, "manifest_json_failed" end
	local manifestTemp = root .. "manifest.new.json"
	local manifestBackup = root .. "manifest.bak.json"
	file.Write( manifestTemp, manifestJSON )
	local verify = file.Read( manifestTemp, "DATA" )
	if verify ~= manifestJSON or not util.JSONToTable( verify ) then
		cleanStagedFiles( staged )
		file.Delete( manifestTemp )
		return nil, "manifest_verify_failed"
	end

	staged[#staged + 1] = { temp = manifestTemp, final = manifestPath,
		backup = manifestBackup, kind = "manifest" }
	local committed, commitError = commitStagedFiles( staged )
	if not committed then cleanStagedFiles( staged ) return nil, commitError end
	for _, item in ipairs( committed ) do if file.Exists( item.backup, "DATA" ) then file.Delete( item.backup ) end end

	local files = file.Find( regionDir .. "/*.json", "DATA" ) or {}
	for _, name in ipairs( files ) do
		if not referenced[name] and not string.EndsWith( name, ".new.json" )
		and not string.EndsWith( name, ".bak.json" ) then file.Delete( regionDir .. "/" .. name ) end
	end
	return manifest, #chunks, layout.blocks
end
