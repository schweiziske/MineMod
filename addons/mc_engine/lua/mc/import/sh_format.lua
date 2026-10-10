--[[----------------------------------------------------------------------------
	MC Minecraft world import bundle format.

	This shared module validates metadata and canonical block-state palette data.
	It never reads files and never mutates the live world.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Import = MC.Import or {}

local Import = MC.Import

Import.FORMAT = "mc_world_import"
Import.FORMAT_VERSION = 1
Import.UNKNOWN_POLICY_REJECT = "reject"
Import.UNKNOWN_POLICY_PRESERVE = "preserve"
Import.UNKNOWN_POLICY_SUBSTITUTE = "substitute"

local function integer( value )
	value = tonumber( value )
	if not value or value ~= math.floor( value ) then return nil end
	return value
end

local function stateProperties( schema, source )
	if source == nil then source = {} end
	if not istable( source ) then return nil, "invalid_properties" end
	local count = 0
	for name in pairs( source ) do
		count = count + 1
		if not isstring( name ) or not schema.propertyByName[string.lower( name )] then
			return nil, "unknown_property"
		end
	end
	if count ~= #schema.properties then return nil, "incomplete_properties" end

	local out = {}
	for index, property in ipairs( schema.properties ) do
		local value = source[property.name]
		if value == nil then return nil, "incomplete_properties" end
		out[index] = property.name .. "=" .. tostring( value )
	end
	return out
end

function Import.ResolveStateEntry( entry )
	if isstring( entry ) then
		local stateId, parseError = MC.ParseBlockState( entry )
		if not stateId then return nil, parseError or "invalid_state" end
		local canonical, formatError = MC.FormatBlockState( stateId )
		if not canonical then return nil, formatError or "invalid_state" end
		if canonical ~= entry then return nil, "non_canonical_state" end
		return stateId, canonical
	end
	if not istable( entry ) then return nil, "invalid_palette_entry" end

	local name = entry.Name or entry.name
	if not isstring( name ) then return nil, "invalid_block_name" end
	name = string.lower( name )
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[name] or nil
	if not schema then return nil, "unknown_block" end
	local properties, propertyError = stateProperties( schema, entry.Properties or entry.properties )
	if not properties then return nil, propertyError end
	local spec = #properties > 0 and ( name .. "[" .. table.concat( properties, "," ) .. "]" ) or name
	local stateId, parseError = MC.ParseBlockState( spec )
	if not stateId then return nil, parseError or "invalid_state" end
	local canonical = MC.FormatBlockState( stateId )
	if canonical ~= spec then return nil, "state_roundtrip_mismatch" end
	return stateId, canonical
end

function Import.ValidateSourceMetadata( bundle )
	if not istable( bundle ) then return false, "invalid_bundle" end
	if bundle.format ~= Import.FORMAT or integer( bundle.formatVersion ) ~= Import.FORMAT_VERSION then
		return false, "unsupported_import_format"
	end
	local source, target = bundle.source, bundle.target
	if not istable( source ) or not istable( target ) then return false, "missing_import_metadata" end
	local expected = MC.BlockStateRegistryMetadata or MC.GeneratedStateMetadata or {}
	local expectedDataVersion = integer( expected.worldVersion )
	local expectedMinecraftVersion = tostring( expected.minecraftId or "" )
	local compatibility = tostring( source.compatibility or "exact" )
	if compatibility == "exact" then
		if integer( source.dataVersion ) ~= expectedDataVersion then return false, "data_version_mismatch" end
		if tostring( source.minecraftVersion or "" ) ~= expectedMinecraftVersion then
			return false, "minecraft_version_mismatch"
		end
	elseif compatibility == "schema-validated-state-only" then
		if not integer( source.dataVersion ) then return false, "invalid_data_version" end
		if integer( source.targetDataVersion ) ~= expectedDataVersion then
			return false, "target_data_version_mismatch"
		end
		if tostring( source.targetMinecraftVersion or "" ) ~= expectedMinecraftVersion then
			return false, "target_minecraft_version_mismatch"
		end
	else
		return false, "unsupported_source_compatibility"
	end
	if tostring( source.series or "" ) ~= tostring( expected.seriesId or "main" ) then return false, "data_series_mismatch" end
	if tostring( target.schemaHash or "" ) ~= tostring( expected.schemaHash or "" ) then return false, "schema_hash_mismatch" end
	if tostring( target.blockReportSha256 or "" ) ~= tostring( expected.reportSha256 or "" ) then
		return false, "block_report_hash_mismatch"
	end
	if integer( target.chunkSize ) ~= MC.CS or integer( target.chunkHeight ) ~= MC.CH then
		return false, "import_geometry_mismatch"
	end
	return true
end

function Import.ValidatePalette( palette )
	if not istable( palette ) then return nil, "missing_palette" end
	local stateIds, canonical, seen = {}, {}, {}
	for index, entry in ipairs( palette ) do
		local stateId, specOrError = Import.ResolveStateEntry( entry )
		if not stateId then return nil, specOrError, index end
		if stateId == 0 then return nil, "air_in_sparse_palette", index end
		if seen[specOrError] then return nil, "duplicate_palette_state", index end
		seen[specOrError] = true
		stateIds[index] = stateId
		canonical[index] = specOrError
	end
	return { stateIds = stateIds, canonical = canonical, count = #stateIds }
end

function Import.DecodeSparseCells( cells, paletteCount )
	if not isstring( cells ) then return nil, "invalid_cells" end
	local out, seen = {}, {}
	if cells == "" then return out end
	for entry in string.gmatch( cells, "[^;]+" ) do
		local liText, piText = string.match( entry, "^(%d+):(%d+)$" )
		local li, paletteIndex = integer( liText ), integer( piText )
		if not li or not MC.LocalIndexInRange( li ) then return nil, "invalid_local_index" end
		if not paletteIndex or paletteIndex < 0 or paletteIndex >= paletteCount then return nil, "invalid_palette_index" end
		if seen[li] then return nil, "duplicate_cell" end
		seen[li] = true
		out[#out + 1] = { localIndex = li, paletteIndex = paletteIndex + 1 }
	end
	return out
end

function Import.ValidateChunkRecord( record, paletteCount )
	if not istable( record ) then return nil, "invalid_chunk_record" end
	local cx, cy, cz = integer( record[1] ), integer( record[2] ), integer( record[3] )
	if not cx or not cy or not cz then return nil, "invalid_chunk_coords" end
	local cells, cellError = Import.DecodeSparseCells( record[4], paletteCount )
	if not cells then return nil, cellError end
	return {
		cx = cx, cy = cy, cz = cz,
		cells = cells,
		opaqueBlockEntities = record[5],
		opaqueStates = record[6],
	}
end

-- Explicit block-entity NBT omission is supported for scenery exports. Keep
-- rejecting every other kind of loss, including a truncated block selection.
function Import.HasOnlySkippedBlockEntityNBT( bundle )
	local source, loss, stats = bundle.source, bundle.lossReport, bundle.stats
	if not istable( source ) or source.blockEntityNBT ~= "skip"
	or not istable( loss ) or not istable( stats ) or not istable( loss.events ) then return false end
	local skipped = integer( stats.skippedBlockEntityNBT )
	if not skipped or skipped < 1 or integer( stats.opaqueBlockEntities ) ~= 0
	or stats.clippedByMaxBlocks == true then return false end
	if loss.archiveRoundTripLossless ~= false or loss.substitutedOrDropped ~= true
	or integer( loss.lossCount ) ~= skipped or integer( loss.eventCount ) ~= skipped
	or integer( loss.skippedBlockEntityNBT ) ~= skipped
	or integer( loss.opaqueBlockEntities ) ~= 0 or integer( loss.opaqueCount ) ~= 0
	or #loss.events ~= skipped then return false end
	for _, event in ipairs( loss.events ) do
		if not istable( event ) or event.code ~= "block_entity_nbt_skipped"
		or event.action ~= "skip_block_entity_nbt" or event.loss ~= true then return false end
	end
	return true
end

function Import.LossSummary( bundle )
	local report = istable( bundle ) and bundle.lossReport or nil
	if not istable( report ) then return "lossReport=missing" end
	return table.concat( {
		"runtimeComplete=" .. tostring( report.runtimeComplete == true ),
		"archiveRoundTripLossless=" .. tostring( report.archiveRoundTripLossless == true ),
		"events=" .. tostring( integer( report.eventCount ) or 0 ),
		"opaqueBlockEntities=" .. tostring( integer( report.opaqueBlockEntities ) or 0 ),
		"skippedBlockEntityNBT=" .. tostring( integer( report.skippedBlockEntityNBT ) or 0 ),
	}, " " )
end
