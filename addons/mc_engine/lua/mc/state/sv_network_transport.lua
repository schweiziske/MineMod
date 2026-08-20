--[[----------------------------------------------------------------------------
	MC authoritative block-state server transport.

	The world and transaction modules call this API; this module never mutates
	voxel storage. Every ordered message carries one world generation and block
	revision so clients can reject stale or skipped data and request a snapshot.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local N = MC.Net
if not N then error( "MC state network protocol is unavailable" ) end
local TRANSPORT_RELOAD = SV.StateNetworkTransportLoaded == true
SV.StateNetworkTransportLoaded = true

local SNAPSHOT_PART_BYTES = N.STATE_SNAPSHOT_PART_BYTES
local STREAM_PART_BYTES = N.STATE_STREAM_PART_BYTES or 30000
local MAX_STREAM_CELLS = N.MAX_STATE_STREAM_CELLS or 4294967295
local CHUNK_PATCH_PART_BYTES = N.CHUNK_PATCH_PART_BYTES or 30000
local CHUNK_PATCH_MAX_BYTES = N.CHUNK_PATCH_MAX_BYTES or 16777216
local BLOCK_ENTITY_PAYLOAD_MAX = N.BLOCK_ENTITY_PAYLOAD_MAX
local TRANSACTION_PAYLOAD_MAX = N.STATE_TRANSACTION_PAYLOAD_MAX
local TRANSACTION_FLAG_CORRECTION = N.TransactionFlag.CORRECTION
local TRANSACTION_FLAG_MESH_RATE_LIMITED = N.TransactionFlag.MESH_RATE_LIMITED
local TRANSACTION_FLAG_COALESCED_BULK = N.TransactionFlag.COALESCED_BULK or 0x04
local BLOCK_ENTITY_NONE = N.BlockEntityOp.NONE
local BLOCK_ENTITY_REMOVE = N.BlockEntityOp.REMOVE
local BLOCK_ENTITY_UPSERT = N.BlockEntityOp.UPSERT
local ALL_CAPABILITIES = bit.bor(
	N.REQUIRED_CAPABILITIES,
	N.Capability.BLOCK_ENTITY_ENVELOPE,
	N.Capability.BINARY_CHUNK_PATCH or 0,
	N.Capability.BINARY_STATE_SNAPSHOT or 0
)

local function reliablePayloadBytes( overheadBytes, protocolMaximum )
	if SV.ReliableNetPayloadBytes then
		return SV.ReliableNetPayloadBytes( overheadBytes, protocolMaximum )
	end
	return math.max( 1, math.min( protocolMaximum, 2048 - overheadBytes ) )
end

local function reliableBudgetBytes()
	if SV.ReliableNetBudgetBytes then return SV.ReliableNetBudgetBytes() end
	return 2048
end

SV.StateNetClients = SV.StateNetClients or setmetatable( {}, { __mode = "k" } )
SV.StateHelloRevisions = SV.StateHelloRevisions or setmetatable( {}, { __mode = "k" } )
SV.StateResyncRequestTimes = TRANSPORT_RELOAD and setmetatable( {}, { __mode = "k" } )
	or SV.StateResyncRequestTimes or setmetatable( {}, { __mode = "k" } )
-- Lua 5.1 math.random cannot portably accept the full unsigned 32-bit range.
SV.WorldGeneration = math.floor( tonumber( SV.WorldGeneration ) or math.random( 1, 2147483647 ) )
SV.BlockRevision = math.floor( tonumber( SV.BlockRevision ) or 0 )
SV.StateSnapshotToken = math.floor( tonumber( SV.StateSnapshotToken ) or 0 )

local function schemaHash()
	-- Numeric state transport is guarded by the network registry hash.  It
	-- includes canonical block-name -> runtime block-id bindings for legacy
	-- paths, while save metadata continues to use the string-scoped hash.
	if MC.GetModRegistryNetworkHash then
		return tostring( MC.GetModRegistryNetworkHash() or "" )
	elseif MC.GetEffectiveBlockStateRegistryHash then
		return tostring( MC.GetEffectiveBlockStateRegistryHash() or "" )
	end
	return MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or ""
end

local function blockEntityRegistryHash()
	if not MC.BlockEntityRegistryFrozen and MC.FinalizeBlockEntityRegistry then
		MC.FinalizeBlockEntityRegistry()
	end
	return tostring( MC.BlockEntityRegistryHash or "" )
end

function SV.GetBlockEntityRegistryHash()
	return blockEntityRegistryHash()
end

local function nextSnapshotToken()
	SV.StateSnapshotToken = ( SV.StateSnapshotToken + 1 ) % 4294967296
	return SV.StateSnapshotToken
end

local function validPlayer( ply )
	return IsValid( ply ) and ply:IsPlayer()
end

local function compatibleClient( ply )
	local state = SV.StateNetClients[ply]
	return state and state.ready == true
end

function SV.IsStateClientReady( ply )
	return compatibleClient( ply )
end

function SV.StreamingEnabled()
	-- The archived ConVar is configuration, not ownership. Only an active
	-- integration may opt the world into interest streaming; otherwise a stale
	-- mc_chunk_streaming 1 from an earlier InfMap session breaks ordinary maps.
	if not ( MC.ChunkStreamingEnabled and MC.ChunkStreamingEnabled() == true ) then return false end
	local minCZ, maxCZ, boundsError
	if SV.StreamingVerticalBounds then minCZ, maxCZ, boundsError = SV.StreamingVerticalBounds() end
	if boundsError then
		if not SV.StreamingVerticalLimitWarned then
			SV.StreamingVerticalLimitWarned = true
			ErrorNoHalt( "[MC] mc_chunk_streaming disabled: " .. tostring( boundsError ) .. "\n" )
		end
		return false
	end
	if minCZ == nil or maxCZ == nil then
		local limit = math.max( 0, math.floor( tonumber( MC.Config.WorldLimit and MC.Config.WorldLimit:GetInt() ) or 0 ) )
		minCZ = math.floor( -limit / ( MC.CH or 32 ) )
		maxCZ = math.ceil( limit / ( MC.CH or 32 ) ) - 1
	end
	local span = maxCZ - minCZ + 1
	if span > ( N.MAX_STREAM_VERTICAL_CHUNKS or 1024 ) then
		if not SV.StreamingVerticalLimitWarned then
			SV.StreamingVerticalLimitWarned = true
			ErrorNoHalt( "[MC] mc_chunk_streaming disabled: vertical range requires " .. tostring( span )
				.. " vertical chunks; maximum is " .. tostring( N.MAX_STREAM_VERTICAL_CHUNKS or 1024 ) .. "\n" )
		end
		return false
	end
	SV.StreamingVerticalLimitWarned = nil
	return true
end

local function writeOrderedHeader( revision )
	net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
	net.WriteUInt( revision, N.REVISION_BITS )
end

local function writeCell( change )
	net.WriteInt( math.floor( change.bx ), N.COORD_BITS )
	net.WriteInt( math.floor( change.by ), N.COORD_BITS )
	net.WriteInt( math.floor( change.bz ), N.COORD_BITS )
	net.WriteUInt( math.floor( change.stateId ), N.STATE_ID_BITS )
end

local function clientVisibleBlockEntity( record )
	if not istable( record ) or not isstring( record.type ) then return nil end
	local definition = MC.BlockEntityTypes and MC.BlockEntityTypes[record.type]
	if not definition or definition.serverOnly then return nil end
	return record, definition
end

-- Encode every envelope before net.Start. A failed codec/JSON/size check can
-- therefore fall back to a snapshot without emitting a partial transaction.
local function prepareBlockEntityEnvelope( change )
	if change.blockEntityChanged == false then return { op = BLOCK_ENTITY_NONE } end
	local oldRecord = change.oldBlockEntity
	local newRecord = change.newBlockEntity
	if newRecord == nil and change.blockEntity ~= nil then newRecord = change.blockEntity end
	local oldVisible = clientVisibleBlockEntity( oldRecord )
	local visible, definition = clientVisibleBlockEntity( newRecord )
	if not visible then
		return { op = ( oldVisible or change.removeBlockEntity == true ) and BLOCK_ENTITY_REMOVE or BLOCK_ENTITY_NONE }
	end
	local wire, wireError = change.blockEntityWire, nil
	if not wire and MC.PrepareBlockEntityWireEnvelope then
		wire, wireError = MC.PrepareBlockEntityWireEnvelope( change.stateId, visible )
	end
	if not wire then return nil, wireError or "block_entity_wire_encode_failed" end
	if not isstring( wire.payload ) or #wire.payload > BLOCK_ENTITY_PAYLOAD_MAX then
		return nil, "block_entity_payload_too_large"
	end
	return {
		op = BLOCK_ENTITY_UPSERT,
		type = wire.type or definition.name,
		codecVersion = wire.codecVersion or definition.codecVersion,
		payload = wire.payload,
	}
end

local function writeBlockEntityEnvelope( envelope )
	net.WriteUInt( envelope.op, 2 )
	if envelope.op ~= BLOCK_ENTITY_UPSERT then return end
	net.WriteString( envelope.type )
	net.WriteUInt( envelope.codecVersion, 16 )
	net.WriteUInt( #envelope.payload, 16 )
	net.WriteData( envelope.payload, #envelope.payload )
end

local function validateChange( change )
	if not istable( change ) then return false, "invalid_change" end
	if not N.ValidateStateId( change.stateId ) then return false, "invalid_state_id" end
	for _, key in ipairs( { "bx", "by", "bz" } ) do
		local value = tonumber( change[key] )
		if not value or value % 1 ~= 0 then return false, "invalid_coordinate" end
		local limit = 2 ^ ( N.COORD_BITS - 1 )
		if value < -limit or value >= limit then return false, "coordinate_out_of_range" end
	end
	return true
end

function SV.AdvanceWorldGeneration( resetRevision )
	SV.WorldGeneration = ( SV.WorldGeneration + 1 ) % 4294967296
	if SV.WorldGeneration == 0 then SV.WorldGeneration = 1 end
	if resetRevision ~= false then SV.BlockRevision = 0 end
	SV.StateNetClients = setmetatable( {}, { __mode = "k" } )
	return SV.WorldGeneration
end

function SV.SendStateHello( ply )
	if not validPlayer( ply ) then return false, "invalid_player" end
	local helloRevision = SV.BlockRevision
	if MC.Workshop and MC.Workshop.StateHelloRevisionForPlayer then
		local override = tonumber( MC.Workshop.StateHelloRevisionForPlayer( ply, helloRevision ) )
		if override and override >= 0 and override <= N.MAX_REVISION and override == math.floor( override ) then
			helloRevision = override
		end
	end
	if MC.Workshop and MC.Workshop.ShouldUseServerBaseForPlayer
	and MC.Workshop.ShouldUseServerBaseForPlayer( ply ) and SV.StateNetClients[ply] then
		SV.StateNetClients[ply].ready = false
	end
	SV.StateHelloRevisions[ply] = helloRevision
	net.Start( "mc_state_hello" )
		net.WriteUInt( N.PROTOCOL_VERSION, 16 )
		net.WriteUInt( ALL_CAPABILITIES, N.CAPABILITY_BITS )
		net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
		net.WriteUInt( helloRevision, N.REVISION_BITS )
		net.WriteUInt( math.min( N.MAX_STATE_ID, math.max( 0, ( MC.BlockStateCount or 1 ) - 1 ) ), N.STATE_ID_BITS )
		net.WriteString( schemaHash() )
		net.WriteString( blockEntityRegistryHash() )
		net.WriteUInt( SV.StreamingEnabled() and 1 or 0, 2 )
	net.Send( ply )
	return true
end

function SV.ValidateStateProtocol( version, capabilities, clientSchemaHash, clientBEHash )
	if version ~= N.PROTOCOL_VERSION then return false, "protocol_version_mismatch" end
	if bit.band( capabilities or 0, N.REQUIRED_CAPABILITIES ) ~= N.REQUIRED_CAPABILITIES then
		return false, "required_capability_missing"
	end
	if clientSchemaHash ~= schemaHash() then return false, "schema_hash_mismatch" end
	if clientBEHash ~= blockEntityRegistryHash() then return false, "block_entity_registry_hash_mismatch" end
	return true
end

local function readyTargets( recipients )
	local targets = {}
	if recipients then
		local candidates = istable( recipients ) and recipients or { recipients }
		for _, ply in ipairs( candidates ) do
			if validPlayer( ply ) and compatibleClient( ply ) then targets[#targets + 1] = ply end
		end
	else
		for _, ply in ipairs( player.GetHumans() ) do
			if compatibleClient( ply ) then targets[#targets + 1] = ply end
		end
	end
	return targets
end

local function binaryChunkPatchEnabled( targets )
	local cv = MC.Config and MC.Config.BinaryChunkPatch
	if not cv or not cv.GetBool or cv:GetBool() ~= true then return false end
	if not MC.BinarySectionPatch or not MC.BinarySectionPatch.EncodeTransportPayload then return false end
	local capability = N.Capability.BINARY_CHUNK_PATCH or 0
	if capability == 0 then return false end
	for _, ply in ipairs( targets ) do
		local state = SV.StateNetClients[ply]
		if not state or bit.band( state.capabilities or 0, capability ) == 0 then return false end
	end
	return #targets > 0
end

local function binaryStateSnapshotEnabled( ply )
	local cv = MC.Config and MC.Config.BinaryChunkPatch
	if not cv or not cv.GetBool or cv:GetBool() ~= true then return false end
	if not MC.BinarySectionPatch or not MC.BinarySectionPatch.EncodeSnapshotPayload then return false end
	local capability = N.Capability.BINARY_STATE_SNAPSHOT or 0
	local state = SV.StateNetClients[ply]
	return capability ~= 0 and state ~= nil
		and bit.band( state.capabilities or 0, capability ) ~= 0
end

SV.BinaryNetProfile = SV.BinaryNetProfile or {
	samples = {}, hydrationSamples = {}, hydrationColumns = {}, hydrationBatches = {}, streamCalls = {},
}
local printBinaryNetReport
local finishBinaryNetAutoTest
local binaryNetCommandOutput

local function binaryNetProfileEnabled()
	local cv = MC.Config and MC.Config.BinaryNetProfile
	return cv and cv.GetBool and cv:GetBool() == true or false
end

function SV.BinaryNetHydrationProfileEnabled()
	return binaryNetProfileEnabled()
end

local function appendBinaryNetProfileSample( field, sample, limit )
	if not binaryNetProfileEnabled() or not istable( sample ) then return end
	local state = SV.BinaryNetProfile
	state[field] = state[field] or {}
	state[field][#state[field] + 1] = sample
	while #state[field] > ( limit or 256 ) do table.remove( state[field], 1 ) end
end

function SV.RecordChunkHydrationProfile( sample )
	appendBinaryNetProfileSample( "hydrationSamples", sample, 4096 )
end

function SV.RecordColumnHydrationProfile( sample )
	appendBinaryNetProfileSample( "hydrationColumns", sample, 4096 )
end

function SV.RecordHydrationBatchProfile( sample )
	appendBinaryNetProfileSample( "hydrationBatches", sample, 512 )
end

function SV.RecordStreamPlayerProfile( sample )
	appendBinaryNetProfileSample( "streamCalls", sample, 512 )
end

local function binaryNetProfileHasColdHydration()
	for _, sample in ipairs( SV.BinaryNetProfile.hydrationSamples or {} ) do
		if sample.warm ~= true then return true end
	end
	return false
end

local function finishBinaryNetProfile( sample )
	if not sample or sample.finished then return end
	sample.finished = true
	sample.queueWallMS = ( ( sample.lastSendAt or SysTime() ) - ( sample.queuedAt or sample.createdAt ) ) * 1000
	local state = SV.BinaryNetProfile
	state.samples = state.samples or {}
	state.samples[#state.samples + 1] = sample
	if #state.samples > 128 then table.remove( state.samples, 1 ) end
	if state.autoTest and not state.autoTest.finishing then
		if binaryNetProfileHasColdHydration() then
			state.autoTest.finishing = true
			timer.Simple( 0, function()
				if finishBinaryNetAutoTest then finishBinaryNetAutoTest( "first cold-hydrated Binary patch completed" ) end
			end )
		elseif not state.autoTest.warmNoticePrinted then
			state.autoTest.warmNoticePrinted = true
			binaryNetCommandOutput( state.autoTest.ply,
				"current patch used warm save data; move into a never-loaded column while the test keeps recording" )
		end
	end
end

local function noteBinaryNetSend( sample, kind, startedAt )
	if not sample then return end
	local endedAt = SysTime()
	local elapsedMS = ( endedAt - startedAt ) * 1000
	if not sample.firstSendAt then
		sample.firstSendAt = startedAt
		sample.firstSendWaitMS = ( startedAt - ( sample.queuedAt or sample.createdAt ) ) * 1000
	end
	sample.lastSendAt = endedAt
	sample.sendCalls = ( sample.sendCalls or 0 ) + 1
	sample.sendCpuMS = ( sample.sendCpuMS or 0 ) + elapsedMS
	sample.sendCallMaxMS = math.max( sample.sendCallMaxMS or 0, elapsedMS )
	local state = SV.BinaryNetProfile
	state.sendFrames, state.sendFrameOrder = state.sendFrames or {}, state.sendFrameOrder or {}
	local frame = FrameNumber and FrameNumber() or 0
	if state.sendFrames[frame] == nil then state.sendFrameOrder[#state.sendFrameOrder + 1] = frame end
	state.sendFrames[frame] = ( state.sendFrames[frame] or 0 ) + elapsedMS
	if #state.sendFrameOrder > 2048 then
		local expired = table.remove( state.sendFrameOrder, 1 )
		state.sendFrames[expired] = nil
	end
	if kind == "end" then
		sample.completedTargets = ( sample.completedTargets or 0 ) + 1
		if sample.completedTargets >= sample.targets then finishBinaryNetProfile( sample ) end
	end
end

binaryNetCommandOutput = function( ply, text )
	local line = "[MC binary net] " .. tostring( text )
	MsgN( line )
	if validPlayer( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, line ) end
end

local function binaryNetPercentile( samples, field, percentile )
	local values = {}
	for _, sample in ipairs( samples ) do
		local value = tonumber( sample[field] )
		if value then values[#values + 1] = value end
	end
	if #values == 0 then return 0 end
	table.sort( values )
	return values[math.Clamp( math.ceil( #values * percentile ), 1, #values )]
end

local function binaryNetSendFramePercentile( percentile )
	local state = SV.BinaryNetProfile
	local values = {}
	for _, frame in ipairs( state.sendFrameOrder or {} ) do
		local value = state.sendFrames and state.sendFrames[frame]
		if value then values[#values + 1] = value end
	end
	if #values == 0 then return 0 end
	table.sort( values )
	return values[math.Clamp( math.ceil( #values * percentile ), 1, #values )]
end

local function noteBinaryNetBuildFrame( sample )
	if not sample then return end
	local state = SV.BinaryNetProfile
	state.buildFrames, state.buildFrameOrder = state.buildFrames or {}, state.buildFrameOrder or {}
	local frame = FrameNumber and FrameNumber() or 0
	local frameSample = state.buildFrames[frame]
	if not frameSample then
		frameSample = {
			totalMS = 0, payloadBuildMS = 0, sectionEncodeMS = 0,
			compressMS = 0, crcMS = 0, queueBuildMS = 0, patches = 0,
		}
		state.buildFrames[frame] = frameSample
		state.buildFrameOrder[#state.buildFrameOrder + 1] = frame
	end
	frameSample.sectionEncodeMS = frameSample.sectionEncodeMS + ( sample.sectionEncodeMS or 0 )
	frameSample.compressMS = frameSample.compressMS + ( sample.compressMS or 0 )
	frameSample.payloadBuildMS = frameSample.payloadBuildMS + ( sample.payloadBuildMS or 0 )
	frameSample.crcMS = frameSample.crcMS + ( sample.crcMS or 0 )
	frameSample.queueBuildMS = frameSample.queueBuildMS + ( sample.queueBuildMS or 0 )
	frameSample.totalMS = frameSample.payloadBuildMS + frameSample.crcMS + frameSample.queueBuildMS
	frameSample.patches = frameSample.patches + 1
	if #state.buildFrameOrder > 2048 then
		local expired = table.remove( state.buildFrameOrder, 1 )
		state.buildFrames[expired] = nil
	end
end

local function binaryNetBuildFramePercentile( field, percentile )
	local state = SV.BinaryNetProfile
	local values = {}
	for _, frame in ipairs( state.buildFrameOrder or {} ) do
		local sample = state.buildFrames and state.buildFrames[frame]
		local value = sample and tonumber( sample[field] )
		if value then values[#values + 1] = value end
	end
	if #values == 0 then return 0 end
	table.sort( values )
	return values[math.Clamp( math.ceil( #values * percentile ), 1, #values )]
end

local function printHydrationReport( ply, hydrationSamples, hydrationColumns, hydrationBatches )
	local coldSamples = {}
	local warmChunks, failedChunks = 0, 0
	local fastFallbackReasons = {}
	local totals = {
		partCacheHits = 0, partCacheMisses = 0, storedBytes = 0, jsonBytes = 0,
		entries = 0, records = 0, cellsVisited = 0, cellsWritten = 0, touchedChunks = 0,
		fastAttempts = 0, fastHits = 0, fastFallbacks = 0, fastBytes = 0,
	}
	for _, sample in ipairs( hydrationSamples ) do
		if sample.warm then
			warmChunks = warmChunks + 1
		else
			coldSamples[#coldSamples + 1] = sample
		end
		if sample.success == false then failedChunks = failedChunks + 1 end
		if sample.fastLastError then
			fastFallbackReasons[sample.fastLastError] = ( fastFallbackReasons[sample.fastLastError] or 0 ) + 1
		end
		for field in pairs( totals ) do totals[field] = totals[field] + ( tonumber( sample[field] ) or 0 ) end
	end

	local columnColdSamples = {}
	local columnAttempted, columnCold, columnWarm, columnFailed = 0, 0, 0, 0
	for _, sample in ipairs( hydrationColumns ) do
		columnAttempted = columnAttempted + ( tonumber( sample.attempted ) or 0 )
		columnCold = columnCold + ( tonumber( sample.cold ) or 0 )
		columnWarm = columnWarm + ( tonumber( sample.warm ) or 0 )
		columnFailed = columnFailed + ( tonumber( sample.failed ) or 0 )
		if ( tonumber( sample.cold ) or 0 ) > 0 then columnColdSamples[#columnColdSamples + 1] = sample end
	end

	binaryNetCommandOutput( ply, string.format(
		"save hydration chunks samples=%d cold=%d warm=%d failed=%d",
		#hydrationSamples, #coldSamples, warmChunks, failedChunks ) )
	if #coldSamples > 0 then
		local fields = {
			{ "fastReadMS", "MCB4 range read" },
			{ "fastDecodeMS", "MCB4 decode" },
			{ "fastInstallMS", "MCB4 install/finalize" },
			{ "fileReadMS", "file.Read" },
			{ "decompressMS", "save decompress" },
			{ "jsonMS", "JSON decode" },
			{ "partLoadMS", "part lookup/load" },
			{ "stateApplyMS", "cell decode/write" },
			{ "overlayFinalizeMS", "overlay/finalize" },
			{ "collisionQueueMS", "collision queue" },
			{ "totalMS", "chunk hydration total" },
		}
		for _, field in ipairs( fields ) do
			binaryNetCommandOutput( ply, string.format( "hydration %s ms p50=%.3f p95=%.3f max=%.3f", field[2],
				binaryNetPercentile( coldSamples, field[1], 0.50 ),
				binaryNetPercentile( coldSamples, field[1], 0.95 ),
				binaryNetPercentile( coldSamples, field[1], 1.00 ) ) )
		end
		binaryNetCommandOutput( ply, string.format(
			"hydration totals entries=%d records=%d cells=%d written=%d touchedChunks=%d partCache=%d hit/%d miss stored=%dB json=%dB",
			totals.entries, totals.records, totals.cellsVisited, totals.cellsWritten, totals.touchedChunks,
			totals.partCacheHits, totals.partCacheMisses, totals.storedBytes, totals.jsonBytes ) )
		binaryNetCommandOutput( ply, string.format(
			"hydration MCB4 attempts=%d hits=%d JSON-fallbacks=%d rangeBytes=%dB",
			totals.fastAttempts, totals.fastHits, totals.fastFallbacks, totals.fastBytes ) )
		if next( fastFallbackReasons ) ~= nil then
			local reasons = {}
			for reason, count in pairs( fastFallbackReasons ) do reasons[#reasons + 1] = tostring( reason ) .. "=" .. count end
			table.sort( reasons )
			binaryNetCommandOutput( ply, "hydration MCB4 fallback reasons: " .. table.concat( reasons, ", " ) )
		end
		local phases = {
			{ "MCB4 range read", binaryNetPercentile( coldSamples, "fastReadMS", 0.95 ) },
			{ "MCB4 decode", binaryNetPercentile( coldSamples, "fastDecodeMS", 0.95 ) },
			{ "MCB4 install/finalize", binaryNetPercentile( coldSamples, "fastInstallMS", 0.95 ) },
			{ "file.Read", binaryNetPercentile( coldSamples, "fileReadMS", 0.95 ) },
			{ "save decompression", binaryNetPercentile( coldSamples, "decompressMS", 0.95 ) },
			{ "JSON decode", binaryNetPercentile( coldSamples, "jsonMS", 0.95 ) },
			{ "cell decode/write", binaryNetPercentile( coldSamples, "stateApplyMS", 0.95 ) },
			{ "overlay/finalize", binaryNetPercentile( coldSamples, "overlayFinalizeMS", 0.95 ) },
			{ "collision queue", binaryNetPercentile( coldSamples, "collisionQueueMS", 0.95 ) },
		}
		table.sort( phases, function( a, b ) return a[2] > b[2] end )
		binaryNetCommandOutput( ply, string.format(
			"hydration CPU verdict: largest measured cold-chunk phase is %s at p95 %.3fms",
			phases[1][1], phases[1][2] ) )
	else
		binaryNetCommandOutput( ply, "warm test: no cold save hydration observed; move into a never-loaded column while profiling is enabled" )
	end

	if #hydrationColumns > 0 then
		binaryNetCommandOutput( ply, string.format(
			"save hydration columns samples=%d attempted=%d cold=%d warm=%d failed=%d",
			#hydrationColumns, columnAttempted, columnCold, columnWarm, columnFailed ) )
		binaryNetCommandOutput( ply, string.format( "column scan wall ms p50=%.3f p95=%.3f max=%.3f",
			binaryNetPercentile( hydrationColumns, "totalMS", 0.50 ),
			binaryNetPercentile( hydrationColumns, "totalMS", 0.95 ),
			binaryNetPercentile( hydrationColumns, "totalMS", 1.00 ) ) )
		binaryNetCommandOutput( ply, string.format( "column index/interest scan excluding hydration ms p50=%.3f p95=%.3f max=%.3f",
			binaryNetPercentile( hydrationColumns, "scanMS", 0.50 ),
			binaryNetPercentile( hydrationColumns, "scanMS", 0.95 ),
			binaryNetPercentile( hydrationColumns, "scanMS", 1.00 ) ) )
		if #columnColdSamples > 0 then
			binaryNetCommandOutput( ply, string.format( "cold column wall ms p50=%.3f p95=%.3f max=%.3f",
				binaryNetPercentile( columnColdSamples, "totalMS", 0.50 ),
				binaryNetPercentile( columnColdSamples, "totalMS", 0.95 ),
				binaryNetPercentile( columnColdSamples, "totalMS", 1.00 ) ) )
		end
	end
	if #hydrationBatches > 0 then
		local batchColumns, batchReady, batchCold, batchFailed = 0, 0, 0, 0
		local coldBatches = {}
		for _, sample in ipairs( hydrationBatches ) do
			batchColumns = batchColumns + ( tonumber( sample.columns ) or 0 )
			batchReady = batchReady + ( tonumber( sample.ready ) or 0 )
			batchCold = batchCold + ( tonumber( sample.cold ) or 0 )
			batchFailed = batchFailed + ( tonumber( sample.failed ) or 0 )
			if ( tonumber( sample.cold ) or 0 ) > 0 then coldBatches[#coldBatches + 1] = sample end
		end
		binaryNetCommandOutput( ply, string.format(
			"save hydration batches samples=%d columns=%d ready=%d coldChunks=%d failedChunks=%d",
			#hydrationBatches, batchColumns, batchReady, batchCold, batchFailed ) )
		binaryNetCommandOutput( ply, string.format( "synchronous hydration batch wall ms p50=%.3f p95=%.3f max=%.3f",
			binaryNetPercentile( hydrationBatches, "totalMS", 0.50 ),
			binaryNetPercentile( hydrationBatches, "totalMS", 0.95 ),
			binaryNetPercentile( hydrationBatches, "totalMS", 1.00 ) ) )
		binaryNetCommandOutput( ply, string.format( "batch index/interest scan excluding hydration ms p50=%.3f p95=%.3f max=%.3f",
			binaryNetPercentile( hydrationBatches, "scanMS", 0.50 ),
			binaryNetPercentile( hydrationBatches, "scanMS", 0.95 ),
			binaryNetPercentile( hydrationBatches, "scanMS", 1.00 ) ) )
		if #coldBatches > 0 then
			binaryNetCommandOutput( ply, string.format( "cold synchronous hydration batch wall ms p50=%.3f p95=%.3f max=%.3f",
				binaryNetPercentile( coldBatches, "totalMS", 0.50 ),
				binaryNetPercentile( coldBatches, "totalMS", 0.95 ),
				binaryNetPercentile( coldBatches, "totalMS", 1.00 ) ) )
		end
		local verdictSamples = #coldBatches > 0 and coldBatches or hydrationBatches
		local batchP95 = binaryNetPercentile( verdictSamples, "totalMS", 0.95 )
		local batchMax = binaryNetPercentile( verdictSamples, "totalMS", 1.00 )
		if batchP95 >= 15 or batchMax >= 15 then
			binaryNetCommandOutput( ply, string.format(
				"server hitch verdict: cold synchronous save hydration consumed %.1fms p95 / %.1fms max inside one server tick",
				batchP95, batchMax ) )
		else
			binaryNetCommandOutput( ply, string.format(
				"server hitch verdict: measured cold synchronous hydration batch is %.1fms p95 / %.1fms max",
				batchP95, batchMax ) )
		end
	end
end

printBinaryNetReport = function( ply )
	local samples = SV.BinaryNetProfile.samples or {}
	local hydrationSamples = SV.BinaryNetProfile.hydrationSamples or {}
	local hydrationColumns = SV.BinaryNetProfile.hydrationColumns or {}
	local hydrationBatches = SV.BinaryNetProfile.hydrationBatches or {}
	local streamCalls = SV.BinaryNetProfile.streamCalls or {}
	if #hydrationSamples > 0 or #hydrationColumns > 0 or #hydrationBatches > 0 then
		printHydrationReport( ply, hydrationSamples, hydrationColumns, hydrationBatches )
	elseif binaryNetProfileEnabled() then
		binaryNetCommandOutput( ply, "save hydration: no samples yet; move into a never-loaded column, then run mc_binary_net_report" )
	end
	if #streamCalls > 0 then
		binaryNetCommandOutput( ply, string.format( "complete streamPlayer CPU ms p50=%.3f p95=%.3f max=%.3f",
			binaryNetPercentile( streamCalls, "totalMS", 0.50 ),
			binaryNetPercentile( streamCalls, "totalMS", 0.95 ),
			binaryNetPercentile( streamCalls, "totalMS", 1.00 ) ) )
	end
	if #samples == 0 then
		local profileEnabled = binaryNetProfileEnabled()
		local binaryCV = MC.Config and MC.Config.BinaryChunkPatch
		local binaryEnabled = binaryCV and binaryCV.GetBool and binaryCV:GetBool() == true or false
		local streamingEnabled = SV.StreamingEnabled and SV.StreamingEnabled() == true or false
		local ready, capable = 0, 0
		local capability = N.Capability.BINARY_CHUNK_PATCH or 0
		for _, target in ipairs( player.GetHumans() ) do
			local client = SV.StateNetClients[target]
			if client and client.ready then
				ready = ready + 1
				if bit.band( client.capabilities or 0, capability ) ~= 0 then capable = capable + 1 end
			end
		end
		binaryNetCommandOutput( ply, string.format(
			"no completed Binary network samples: profile=%s binaryPatch=%s streaming=%s readyClients=%d binaryClients=%d",
			tostring( profileEnabled ), tostring( binaryEnabled ), tostring( streamingEnabled ), ready, capable ) )
		if not binaryEnabled then
			binaryNetCommandOutput( ply, "cause: mc_binary_chunk_patch is 0, so the server is using the old JSON path" )
		elseif not profileEnabled then
			binaryNetCommandOutput( ply, "cause: profiling is disabled" )
		elseif capable == 0 then
			binaryNetCommandOutput( ply, "cause: no ready client advertised Binary Section support" )
		else
			binaryNetCommandOutput( ply, "no Binary patch completed yet" )
		end
		return
	end
	local fields = {
		{ "payloadBuildMS", "payload encode+LZMA total" },
		{ "sectionEncodeMS", "section encode" },
		{ "compressMS", "LZMA" },
		{ "crcMS", "CRC" },
		{ "queueBuildMS", "slice/enqueue" },
		{ "sendCpuMS", "net.Send CPU total/batch" },
		{ "sendCallMaxMS", "net.Send max call/batch" },
		{ "firstSendWaitMS", "first-send wait" },
		{ "queueWallMS", "queue wall" },
	}
	binaryNetCommandOutput( ply, string.format( "samples=%d (last %d retained)", #samples, math.min( #samples, 128 ) ) )
	for _, field in ipairs( fields ) do
		binaryNetCommandOutput( ply, string.format( "%s ms p50=%.3f p95=%.3f max=%.3f", field[2],
			binaryNetPercentile( samples, field[1], 0.50 ),
			binaryNetPercentile( samples, field[1], 0.95 ),
			binaryNetPercentile( samples, field[1], 1.00 ) ) )
	end
	binaryNetCommandOutput( ply, string.format( "net.Send CPU/server-frame ms p50=%.3f p95=%.3f max=%.3f",
		binaryNetSendFramePercentile( 0.50 ), binaryNetSendFramePercentile( 0.95 ),
		binaryNetSendFramePercentile( 1.00 ) ) )
	binaryNetCommandOutput( ply, string.format( "binary build CPU/server-frame ms p50=%.3f p95=%.3f max=%.3f",
		binaryNetBuildFramePercentile( "totalMS", 0.50 ),
		binaryNetBuildFramePercentile( "totalMS", 0.95 ),
		binaryNetBuildFramePercentile( "totalMS", 1.00 ) ) )
	binaryNetCommandOutput( ply, string.format( "binary build/server-frame p95 section=%.3fms LZMA=%.3fms CRC=%.3fms enqueue=%.3fms",
		binaryNetBuildFramePercentile( "sectionEncodeMS", 0.95 ),
		binaryNetBuildFramePercentile( "compressMS", 0.95 ),
		binaryNetBuildFramePercentile( "crcMS", 0.95 ),
		binaryNetBuildFramePercentile( "queueBuildMS", 0.95 ) ) )
	local rawBytes, wireBytes, chunks, cells, parts, targets = 0, 0, 0, 0, 0, 0
	for _, sample in ipairs( samples ) do
		rawBytes = rawBytes + ( sample.rawBytes or 0 )
		wireBytes = wireBytes + ( sample.wireBytes or 0 )
		chunks = chunks + ( sample.chunks or 0 )
		cells = cells + ( sample.cells or 0 )
		parts = parts + ( sample.parts or 0 )
		targets = targets + ( sample.targets or 0 )
	end
	binaryNetCommandOutput( ply, string.format(
		"totals chunks=%d cells=%d parts=%d targets=%d raw=%dB wire=%dB ratio=%.2f%%",
		chunks, cells, parts, targets, rawBytes, wireBytes, rawBytes > 0 and wireBytes * 100 / rawBytes or 0 ) )
	local budget = MC.Config and MC.Config.SyncBudget and MC.Config.SyncBudget:GetInt() or reliableBudgetBytes()
	local messages = MC.Config and MC.Config.SyncMsgs and MC.Config.SyncMsgs:GetInt() or 0
	local window = MC.Config and MC.Config.SyncWindow and MC.Config.SyncWindow:GetInt() or 0
	binaryNetCommandOutput( ply, string.format(
		"queue config budget=%dB/50ms (~%.1fKiB/s/player) messages=%d/50ms inflight=%dB",
		budget, budget * 20 / 1024, messages, window ) )

	local buildFrameP95 = binaryNetBuildFramePercentile( "totalMS", 0.95 )
	local sendP95 = binaryNetSendFramePercentile( 0.95 )
	local wallP95 = binaryNetPercentile( samples, "queueWallMS", 0.95 )
	local phases = {
		{ "Binary build CPU/frame", buildFrameP95 }, { "net.Send CPU/frame", sendP95 },
	}
	table.sort( phases, function( a, b ) return a[2] > b[2] end )
	if phases[1][2] >= 2 then
		binaryNetCommandOutput( ply, string.format( "server CPU verdict: %s is highest at p95 %.3fms", phases[1][1], phases[1][2] ) )
	else
		binaryNetCommandOutput( ply, string.format( "server CPU verdict: binary network hot path is below 2ms p95; highest is %s %.3fms", phases[1][1], phases[1][2] ) )
	end
	if wallP95 >= 100 and sendP95 < 2 then
		binaryNetCommandOutput( ply, string.format( "delivery verdict: %.1fms p95 is queue pacing/ACK wait, not net.Send CPU", wallP95 ) )
	else
		binaryNetCommandOutput( ply, string.format( "delivery verdict: queue wall p95 %.1fms, net.Send CPU p95 %.3fms", wallP95, sendP95 ) )
	end
end

finishBinaryNetAutoTest = function( reason )
	local state = SV.BinaryNetProfile
	local test = state.autoTest
	if not test then return end
	state.autoTest = nil
	timer.Remove( "mc_binary_net_test_timeout" )
	binaryNetCommandOutput( test.ply, "automatic test finished: " .. tostring( reason ) )
	printBinaryNetReport( test.ply )
	local binaryCV = MC.Config and MC.Config.BinaryChunkPatch
	local profileCV = MC.Config and MC.Config.BinaryNetProfile
	if binaryCV and binaryCV.SetBool then binaryCV:SetBool( test.restoreBinary == true ) end
	if profileCV and profileCV.SetBool then profileCV:SetBool( test.restoreProfile == true ) end
	binaryNetCommandOutput( test.ply, "temporary ConVars restored" )
end

function SV.SendStateRevisionSkip( recipients, fromRevision, toRevision )
	local targets = readyTargets( recipients )
	fromRevision = math.floor( tonumber( fromRevision ) or -1 )
	toRevision = math.floor( tonumber( toRevision ) or -1 )
	if #targets == 0 then return true, 0 end
	if fromRevision < 1 or toRevision < fromRevision or toRevision > N.MAX_REVISION then return false, "invalid_skip_range" end
	net.Start( "mc_state_revision_skip" )
		net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
		net.WriteUInt( fromRevision, N.REVISION_BITS )
		net.WriteUInt( toRevision, N.REVISION_BITS )
	net.Send( targets )
	return true, #targets
end

function SV.SendStreamPatchPending( recipients, revision )
	local targets = readyTargets( recipients )
	revision = math.floor( tonumber( revision ) or -1 )
	if #targets == 0 then return true, 0 end
	if revision < 1 or revision > N.MAX_REVISION then return false, "invalid_pending_revision" end
	net.Start( "mc_stream_patch_pending" )
		net.WriteUInt( SV.WorldGeneration, N.GENERATION_BITS )
		net.WriteUInt( revision, N.REVISION_BITS )
	net.Send( targets )
	return true, #targets
end

local function snapshotTargets( targets, reason )
	if SV.StreamingEnabled() then
		for _, ply in ipairs( targets ) do
			if SV.ReinitializeColumnStreaming then SV.ReinitializeColumnStreaming( ply, reason ) end
		end
		return false, reason or "streaming_incremental_failed"
	end
	local binaryTargets, jsonTargets = {}, {}
	for _, ply in ipairs( targets ) do
		local list = binaryStateSnapshotEnabled( ply ) and binaryTargets or jsonTargets
		list[#list + 1] = ply
	end
	if #binaryTargets > 0 then
		local payload = SV.BuildBinaryStateSnapshotPayload()
		if payload then
			for _, ply in ipairs( binaryTargets ) do
				SV.SendStateSnapshot( ply, payload, SV.BlockRevision, true )
			end
		else
			for _, ply in ipairs( binaryTargets ) do jsonTargets[#jsonTargets + 1] = ply end
		end
	end
	if #jsonTargets > 0 then
		local payload, payloadError = SV.BuildStateSnapshotPayload()
		if not payload then return false, payloadError or reason end
		for _, ply in ipairs( jsonTargets ) do
			SV.SendStateSnapshot( ply, payload, SV.BlockRevision, false )
		end
	end
	return true, #targets, reason
end

local function preparedItemBytes( item )
	local bytes = 5 -- localIndex + stateId + Block Entity op
	local envelope = item.envelope
	if envelope.op == BLOCK_ENTITY_UPSERT then
		bytes = bytes + #envelope.type + #envelope.payload + 10
	end
	return bytes
end

-- Large ordered edits are encoded as chunk-local patches. Coordinates are
-- written once per segment and every part stays below the reliable byte budget;
-- this replaces the old full-world snapshot fallback used by /fill.
local function buildStateStreamParts( prepared, cellsPerPart, partByteLimit )
	if #prepared < 1 or #prepared > MAX_STREAM_CELLS then return nil, "state_stream_cell_limit" end
	cellsPerPart = math.Clamp( math.floor( tonumber( cellsPerPart ) or 4096 ), 1, MAX_STREAM_CELLS )
	partByteLimit = math.Clamp( math.floor( tonumber( partByteLimit ) or STREAM_PART_BYTES ), 256, STREAM_PART_BYTES )
	local chunks, order = {}, {}
	for _, item in ipairs( prepared ) do
		local change = item.change
		local cx, cy, cz, li = MC.CellToChunk( change.bx, change.by, change.bz )
		local key = MC.ChunkKey( cx, cy, cz )
		local chunk = chunks[key]
		if not chunk then
			chunk = { cx = cx, cy = cy, cz = cz, items = {} }
			chunks[key] = chunk
			order[#order + 1] = chunk
		end
		item.localIndex = li
		item.streamBytes = preparedItemBytes( item )
		if item.streamBytes + 128 > partByteLimit then return nil, "state_stream_item_too_large" end
		chunk.items[#chunk.items + 1] = item
	end

	local parts = {}
	local part = { segments = {}, cellCount = 0, bytes = 96 }
	local function flushPart()
		if part.cellCount <= 0 then return end
		parts[#parts + 1] = part
		part = { segments = {}, cellCount = 0, bytes = 96 }
	end

	for _, chunk in ipairs( order ) do
		local segment
		for _, item in ipairs( chunk.items ) do
			local segmentBytes = segment and 0 or 12
			if part.cellCount > 0 and ( part.cellCount >= cellsPerPart
			or part.bytes + segmentBytes + item.streamBytes > partByteLimit ) then
				flushPart()
				segment = nil
				segmentBytes = 12
			end
			if not segment then
				segment = { cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, items = {} }
				part.segments[#part.segments + 1] = segment
				part.bytes = part.bytes + segmentBytes
			end
			segment.items[#segment.items + 1] = item
			part.cellCount = part.cellCount + 1
			part.bytes = part.bytes + item.streamBytes
		end
	end
	flushPart()
	if #parts < 1 or #parts > 65535 then return nil, "state_stream_part_limit" end
	return parts
end

local function sendStateStreamPart( target, generation, revision, flags, groupId, partIndex, partCount, totalCells, part, ackBytes )
	if not validPlayer( target ) then return false end
	net.Start( "mc_state_chunk_stream" )
		net.WriteUInt( generation, N.GENERATION_BITS )
		net.WriteUInt( revision, N.REVISION_BITS )
		net.WriteUInt( flags, 8 )
		net.WriteUInt( groupId, 32 )
		net.WriteUInt( partIndex - 1, 16 )
		net.WriteUInt( partCount, 16 )
		net.WriteUInt( totalCells, 32 )
		net.WriteUInt( #part.segments, 16 )
		for _, segment in ipairs( part.segments ) do
			net.WriteInt( segment.cx, N.COORD_BITS )
			net.WriteInt( segment.cy, N.COORD_BITS )
			net.WriteInt( segment.cz, N.COORD_BITS )
			net.WriteUInt( #segment.items, N.COUNT_BITS )
			for _, item in ipairs( segment.items ) do
				net.WriteUInt( item.localIndex, N.LOCAL_BITS )
				net.WriteUInt( math.floor( item.change.stateId ), N.STATE_ID_BITS )
				writeBlockEntityEnvelope( item.envelope )
			end
		end
		net.WriteUInt( ackBytes, 32 )
	net.Send( target )
	return true
end

local function queueStateStream( targets, prepared, revision, options )
	local parts, partError = buildStateStreamParts( prepared, options.cellsPerMessage,
		math.min( STREAM_PART_BYTES, reliableBudgetBytes() ) )
	if not parts then return false, partError end
	local flags = TRANSACTION_FLAG_COALESCED_BULK
	if options.explosionMeshThrottle == true then flags = bit.bor( flags, TRANSACTION_FLAG_MESH_RATE_LIMITED ) end
	local groupId = math.floor( tonumber( options.stateGroupId ) or 0 ) % 4294967296
	local generation = SV.WorldGeneration
	local partCount, totalCells = #parts, #prepared
	for partIndex, streamPart in ipairs( parts ) do
		local queuedIndex, queuedPart = partIndex, streamPart
		local ackBytes = math.max( 1, math.ceil( queuedPart.bytes ) )
		local sendFn = function( ply )
			return sendStateStreamPart( ply, generation, revision, flags, groupId,
				queuedIndex, partCount, totalCells, queuedPart, ackBytes )
		end
		if SV.EnqueueReliableNet then
			SV.EnqueueReliableNet( targets, ackBytes, sendFn, true )
		else
			for _, ply in ipairs( targets ) do sendFn( ply ) end
		end
	end
	return true, #targets, #parts
end

function SV.EndStateBulkGroup( groupId, revision, recipients )
	groupId = math.floor( tonumber( groupId ) or 0 ) % 4294967296
	if groupId == 0 then return false, "invalid_bulk_group" end
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	local generation = SV.WorldGeneration
	local targets = readyTargets( recipients )
	if #targets == 0 then return true, 0 end
	local function sendEnd( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_bulk_group_end" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
		net.Send( ply )
		return true
	end
	if SV.EnqueueReliableNet then SV.EnqueueReliableNet( targets, 32, sendEnd, false )
	else for _, ply in ipairs( targets ) do sendEnd( ply ) end end
	return true, #targets
end

local function queueBinaryStateChunkHydration( refs, revision, groupId, targets )
	local profiling = binaryNetProfileEnabled()
	local payloadStarted = profiling and SysTime() or nil
	local payload, metadataOrError = MC.BinarySectionPatch.EncodeTransportPayload( refs, profiling )
	local payloadBuildMS = profiling and ( SysTime() - payloadStarted ) * 1000 or 0
	if not payload then return false, metadataOrError or "binary_patch_encode_failed" end
	local metadata = metadataOrError
	if #payload < 1 or #payload > CHUNK_PATCH_MAX_BYTES then return false, "binary_patch_size_limit" end
	local partBytes = reliablePayloadBytes( 104, CHUNK_PATCH_PART_BYTES )
	local partCount = math.ceil( #payload / partBytes )
	if partCount < 1 or partCount > 65535 then return false, "binary_patch_part_limit" end

	local generation = SV.WorldGeneration
	local token = nextSnapshotToken()
	local totalBytes = #payload
	local crcStarted = profiling and SysTime() or nil
	local crc = util.CRC( payload )
	local sample = profiling and {
		createdAt = SysTime(), revision = revision, token = token,
		chunks = metadata.chunkCount, cells = metadata.cellCount,
		rawBytes = metadata.rawBytes, wireBytes = totalBytes,
		parts = partCount, targets = #targets,
		sectionEncodeMS = metadata.sectionEncodeMS or 0,
		compressMS = metadata.compressMS or 0,
		payloadBuildMS = payloadBuildMS,
		crcMS = ( SysTime() - crcStarted ) * 1000,
		sendCpuMS = 0, sendCalls = 0, completedTargets = 0,
	} or nil
	local queueStarted = profiling and SysTime() or nil
	if sample then sample.queuedAt = queueStarted end
	local function sendBegin( ply )
		if not validPlayer( ply ) then return false end
		local sendStarted = sample and SysTime() or nil
		net.Start( "mc_state_binary_patch_begin" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteUInt( totalBytes, 32 )
			net.WriteUInt( metadata.rawBytes, 32 )
			net.WriteUInt( metadata.compression, 2 )
			net.WriteUInt( partCount, 16 )
			net.WriteUInt( metadata.chunkCount, 16 )
			net.WriteUInt( metadata.cellCount, 32 )
			net.WriteString( schemaHash() )
			net.WriteString( blockEntityRegistryHash() )
		net.Send( ply )
		if sample then noteBinaryNetSend( sample, "begin", sendStarted ) end
		return true
	end
	SV.EnqueueReliableNet( targets, 136, sendBegin, false )

	for partIndex = 0, partCount - 1 do
		local queuedIndex = partIndex
		local offset = queuedIndex * partBytes + 1
		local queuedBytes = string.sub( payload, offset, offset + partBytes - 1 )
		local ackBytes = #queuedBytes + 104
		SV.EnqueueReliableNet( targets, ackBytes, function( ply )
			if not validPlayer( ply ) then return false end
			local sendStarted = sample and SysTime() or nil
			net.Start( "mc_state_binary_patch_part" )
				net.WriteUInt( generation, N.GENERATION_BITS )
				net.WriteUInt( token, 32 )
				net.WriteUInt( queuedIndex, 16 )
				net.WriteUInt( #queuedBytes, 16 )
				net.WriteData( queuedBytes, #queuedBytes )
				net.WriteUInt( ackBytes, 32 )
			net.Send( ply )
			if sample then noteBinaryNetSend( sample, "part", sendStarted ) end
			return true
		end, true )
	end

	SV.EnqueueReliableNet( targets, 104, function( ply )
		if not validPlayer( ply ) then return false end
		local sendStarted = sample and SysTime() or nil
		net.Start( "mc_state_binary_patch_end" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteString( crc )
		net.Send( ply )
		if sample then noteBinaryNetSend( sample, "end", sendStarted ) end
		return true
	end, false )
	if sample then
		sample.queueBuildMS = ( SysTime() - queueStarted ) * 1000
		noteBinaryNetBuildFrame( sample )
	end
	return true, #targets, partCount, totalBytes
end

local function binaryNetCommandAllowed( ply )
	return not validPlayer( ply ) or ply:IsAdmin()
end

concommand.Add( "mc_binary_net_profile_reset", function( ply )
	if not binaryNetCommandAllowed( ply ) then return end
	SV.BinaryNetProfile.samples = {}
	SV.BinaryNetProfile.sendFrames = {}
	SV.BinaryNetProfile.sendFrameOrder = {}
	SV.BinaryNetProfile.buildFrames = {}
	SV.BinaryNetProfile.buildFrameOrder = {}
	SV.BinaryNetProfile.hydrationSamples = {}
	SV.BinaryNetProfile.hydrationColumns = {}
	SV.BinaryNetProfile.hydrationBatches = {}
	SV.BinaryNetProfile.streamCalls = {}
	binaryNetCommandOutput( ply, "network and save hydration profile samples reset" )
end, nil, "Reset collected Binary Section network and save hydration timings" )

concommand.Add( "mc_binary_net_report", function( ply )
	if not binaryNetCommandAllowed( ply ) then return end
	printBinaryNetReport( ply )
end, nil, "Report save hydration plus Binary Section encode, compression, queue and send timings" )

concommand.Add( "mc_binary_net_test", function( ply )
	if not binaryNetCommandAllowed( ply ) then return end
	if not SV.StreamingEnabled or not SV.StreamingEnabled() then
		binaryNetCommandOutput( ply, "cannot run: chunk streaming is disabled" )
		return
	end
	local target = validPlayer( ply ) and compatibleClient( ply ) and ply or nil
	if not target then
		for _, candidate in ipairs( player.GetHumans() ) do
			if compatibleClient( candidate ) then target = candidate break end
		end
	end
	if not target then
		binaryNetCommandOutput( ply, "cannot run: no protocol-ready human player" )
		return
	end
	local capability = N.Capability.BINARY_CHUNK_PATCH or 0
	local client = SV.StateNetClients[target]
	if capability == 0 or bit.band( client and client.capabilities or 0, capability ) == 0 then
		binaryNetCommandOutput( ply, "cannot run: selected client does not support Binary Section patches" )
		return
	end
	local binaryCV = MC.Config and MC.Config.BinaryChunkPatch
	local profileCV = MC.Config and MC.Config.BinaryNetProfile
	if not binaryCV or not binaryCV.SetBool or not profileCV or not profileCV.SetBool then
		binaryNetCommandOutput( ply, "cannot run: Binary test ConVars are unavailable" )
		return
	end
	SV.BinaryNetProfile.samples = {}
	SV.BinaryNetProfile.sendFrames = {}
	SV.BinaryNetProfile.sendFrameOrder = {}
	SV.BinaryNetProfile.buildFrames = {}
	SV.BinaryNetProfile.buildFrameOrder = {}
	SV.BinaryNetProfile.hydrationSamples = {}
	SV.BinaryNetProfile.hydrationColumns = {}
	SV.BinaryNetProfile.hydrationBatches = {}
	SV.BinaryNetProfile.streamCalls = {}
	SV.BinaryNetProfile.autoTest = {
		ply = validPlayer( ply ) and ply or nil,
		restoreBinary = binaryCV:GetBool(),
		restoreProfile = profileCV:GetBool(),
	}
	binaryCV:SetBool( true )
	profileCV:SetBool( true )
	binaryNetCommandOutput( ply, "armed for 30s; current view is resent, and a warm result keeps waiting until you enter a never-loaded column" )
	timer.Create( "mc_binary_net_test_timeout", 30, 1, function()
		if finishBinaryNetAutoTest then finishBinaryNetAutoTest( "30 second timeout" ) end
	end )
	if not SV.InitializeColumnStreaming or SV.InitializeColumnStreaming( target ) ~= true then
		finishBinaryNetAutoTest( "failed to trigger current-view streaming" )
	end
end, nil, "Automatically profile one real Binary Section patch and print the result" )

concommand.Add( "mc_binary_net_bench", function( ply, _, args )
	if not binaryNetCommandAllowed( ply ) then return end
	if not MC.BinarySectionPatch or not MC.BinarySectionPatch.EncodeTransportPayload then
		binaryNetCommandOutput( ply, "Binary Section encoder unavailable" )
		return
	end
	local wanted = math.Clamp( math.floor( tonumber( args[1] ) or 16 ), 1, 64 )
	local refs = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 then
			refs[#refs + 1] = {
				patchRef = true, cx = chunk.cx, cy = chunk.cy, cz = chunk.cz,
				chunk = chunk, cellCount = chunk.count,
			}
			if #refs >= wanted then break end
		end
	end
	if #refs == 0 then
		binaryNetCommandOutput( ply, "no non-empty server chunks available" )
		return
	end
	local totalStarted = SysTime()
	local payload, metadataOrError = MC.BinarySectionPatch.EncodeTransportPayload( refs, true )
	local totalMS = ( SysTime() - totalStarted ) * 1000
	if not payload then
		binaryNetCommandOutput( ply, "bench failed: " .. tostring( metadataOrError ) )
		return
	end
	local metadata = metadataOrError
	local crcStarted = SysTime()
	util.CRC( payload )
	local crcMS = ( SysTime() - crcStarted ) * 1000
	local partBytes = reliablePayloadBytes( 104, CHUNK_PATCH_PART_BYTES )
	local partCount = math.ceil( #payload / partBytes )
	binaryNetCommandOutput( ply, string.format(
		"isolated bench chunks=%d cells=%d raw=%dB wire=%dB ratio=%.2f%% parts=%d",
		#refs, metadata.cellCount or 0, metadata.rawBytes or 0, #payload,
		(metadata.rawBytes or 0) > 0 and #payload * 100 / metadata.rawBytes or 0, partCount ) )
	binaryNetCommandOutput( ply, string.format(
		"isolated CPU section=%.3fms LZMA=%.3fms CRC=%.3fms total=%.3fms compression=%s",
		metadata.sectionEncodeMS or 0, metadata.compressMS or 0, crcMS, totalMS,
		metadata.compression == MC.BinarySectionPatch.COMPRESSION_LZMA and "LZMA" or "none" ) )
	binaryNetCommandOutput( ply, "this bench sends nothing; use mc_binary_net_profile 1 plus mc_binary_net_report for real queue/send timings" )
end, nil, "Benchmark Binary Section encoding and LZMA without sending; optional chunk count 1..64" )

-- Queue one compressed partial-world snapshot. The payload contains the final
-- authoritative state of only the touched chunks, including empty tombstones.
-- Every part uses the same byte-budgeted, ACK-windowed queue as join snapshots
-- and ordered state streams. Large edits no longer have a bypass lane.
function SV.QueueStateChunkHydration( refs, revision, groupId, recipients, pendingAlreadyAnnounced )
	if revision == nil and SV.StreamingEnabled() and recipients ~= nil and SV.AllocateStreamingRevision then
		revision = SV.AllocateStreamingRevision( istable( recipients ) and recipients[1] or recipients )
		if revision == nil then return false, "revision_rollover" end
		pendingAlreadyAnnounced = true
	end
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	groupId = math.floor( tonumber( groupId ) or 0 ) % 4294967296
	if groupId == 0 then return false, "invalid_chunk_patch_group" end
	local targets = readyTargets( recipients )
	if #targets == 0 then return true, 0, 0, 0 end
	if SV.SendStreamPatchPending and pendingAlreadyAnnounced ~= true then SV.SendStreamPatchPending( targets, revision ) end
	if binaryChunkPatchEnabled( targets ) then
		local ok, targetCountOrError, partCount, totalBytes = queueBinaryStateChunkHydration(
			refs, revision, groupId, targets )
		if ok then return true, targetCountOrError, partCount, totalBytes end
		SV.BinaryPatchFallbackWarnings = SV.BinaryPatchFallbackWarnings or {}
		local warning = tostring( targetCountOrError )
		if not SV.BinaryPatchFallbackWarnings[warning] then
			SV.BinaryPatchFallbackWarnings[warning] = true
			ErrorNoHalt( "[MC] binary chunk patch fallback: " .. warning .. "\n" )
		end
	end
	if not SV.BuildStateChunkPatchData then return false, "chunk_patch_encoder_unavailable" end

	local data, chunks, buildError = SV.BuildStateChunkPatchData( refs, { forClient = true } )
	if not data then return false, buildError or "chunk_patch_encode_failed" end
	local json = util.TableToJSON( data, false )
	local payload = json and util.Compress( json ) or nil
	if not payload or #payload < 1 then return false, "chunk_patch_compress_failed" end
	if #payload > CHUNK_PATCH_MAX_BYTES then return false, "chunk_patch_too_large" end
	local chunkPatchPartBytes = reliablePayloadBytes( 96, CHUNK_PATCH_PART_BYTES )
	local partCount = math.ceil( #payload / chunkPatchPartBytes )
	if partCount < 1 or partCount > 65535 then return false, "chunk_patch_part_limit" end

	local generation = SV.WorldGeneration
	local token = nextSnapshotToken()
	local totalBytes = #payload
	local chunkCount = #chunks
	local cellCount = math.max( 0, math.floor( tonumber( data.blockCount ) or 0 ) )
	local crc = util.CRC( payload )
	local function sendBegin( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_chunk_patch_begin" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteUInt( totalBytes, 32 )
			net.WriteUInt( partCount, 16 )
			net.WriteUInt( chunkCount, 16 )
			net.WriteUInt( cellCount, 32 )
			net.WriteString( schemaHash() )
			net.WriteString( blockEntityRegistryHash() )
		net.Send( ply )
		return true
	end
	SV.EnqueueReliableNet( targets, 128, sendBegin, false )

	for partIndex = 0, partCount - 1 do
		local queuedIndex = partIndex
		local offset = queuedIndex * chunkPatchPartBytes + 1
		local queuedBytes = string.sub( payload, offset, offset + chunkPatchPartBytes - 1 )
		local ackBytes = #queuedBytes + 96
		SV.EnqueueReliableNet( targets, ackBytes, function( ply )
			if not validPlayer( ply ) then return false end
			net.Start( "mc_state_chunk_patch_part" )
				net.WriteUInt( generation, N.GENERATION_BITS )
				net.WriteUInt( token, 32 )
				net.WriteUInt( queuedIndex, 16 )
				net.WriteUInt( #queuedBytes, 16 )
				net.WriteData( queuedBytes, #queuedBytes )
				net.WriteUInt( ackBytes, 32 )
			net.Send( ply )
			return true
		end, true )
	end

	SV.EnqueueReliableNet( targets, 96, function( ply )
		if not validPlayer( ply ) then return false end
		net.Start( "mc_state_chunk_patch_end" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteUInt( revision, N.REVISION_BITS )
			net.WriteUInt( groupId, 32 )
			net.WriteUInt( token, 32 )
			net.WriteString( crc )
		net.Send( ply )
		return true
	end, false )
	return true, #targets, partCount, totalBytes
end

function SV.BroadcastStateTransaction( changes, revision, options )
	options = istable( options ) and options or {}
	if istable( changes ) and changes.changes then
		revision = changes.revision
		changes = changes.changes
	end
	if not istable( changes ) or #changes == 0 then return true, 0 end
	revision = math.floor( tonumber( revision ) or SV.BlockRevision )
	local targets = readyTargets( options.recipients )
	if #targets == 0 then return true, 0 end
	if SV.StreamingEnabled() and options.recipients == nil then
		-- Transactions remain globally ordered for every ready client. The client
		-- consumes the revision but discards cells outside its subscriptions.
	end
	local prepared = {}
	local estimatedBytes = 32
	for i, change in ipairs( changes ) do
		local ok, err = validateChange( change )
		if not ok then return false, err, i end
		local envelope, envelopeError = prepareBlockEntityEnvelope( change )
		if not envelope then
			if options.noSnapshotFallback == true then return false, envelopeError or "block_entity_envelope_failed" end
			return snapshotTargets( targets, envelopeError )
		end
		prepared[i] = { change = change, envelope = envelope }
		estimatedBytes = estimatedBytes + 12
		if envelope.op == BLOCK_ENTITY_UPSERT then
			estimatedBytes = estimatedBytes + #envelope.type + #envelope.payload + 8
		end
	end
	if options.stateStream == true
	or ( options.netPaced == true and ( #changes > N.MAX_STATE_BULK_CELLS or estimatedBytes > TRANSACTION_PAYLOAD_MAX ) ) then
		local streamed, streamResult, partCount = queueStateStream( targets, prepared, revision, options )
		if streamed then return true, streamResult, "streamed", partCount end
		if options.noSnapshotFallback == true then return false, streamResult or "state_stream_failed" end
		return snapshotTargets( targets, streamResult or "state_stream_failed" )
	end
	if #changes > N.MAX_STATE_BULK_CELLS or estimatedBytes > TRANSACTION_PAYLOAD_MAX then
		if options.noSnapshotFallback == true then return false, "too_many_changes_for_incremental_packet" end
		return snapshotTargets( targets, "too_many_changes_for_incremental_packet" )
	end

	if #changes == 1 then
		net.Start( "mc_state_set" )
			writeOrderedHeader( revision )
			net.WriteUInt( options.explosionMeshThrottle == true and TRANSACTION_FLAG_MESH_RATE_LIMITED or 0, 8 )
			writeCell( prepared[1].change )
			writeBlockEntityEnvelope( prepared[1].envelope )
	else
		net.Start( "mc_state_set_bulk" )
			writeOrderedHeader( revision )
			net.WriteUInt( options.explosionMeshThrottle == true and TRANSACTION_FLAG_MESH_RATE_LIMITED or 0, 8 )
			net.WriteUInt( #changes, N.COUNT_BITS )
			for _, item in ipairs( prepared ) do
				writeCell( item.change )
				writeBlockEntityEnvelope( item.envelope )
			end
	end
	net.Send( targets )
	return true, #targets
end

function SV.BroadcastStateChanges( changes, revision, recipients )
	return SV.BroadcastStateTransaction( changes, revision, { recipients = recipients } )
end

function SV.SendStateCorrection( ply, bx, by, bz, stateId, revision )
	if not validPlayer( ply ) then return false, "invalid_player" end
	local change = { bx = bx, by = by, bz = bz, stateId = stateId }
	local ok, err = validateChange( change )
	if not ok then return false, err end
	change.blockEntity = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
	local envelope, envelopeError = prepareBlockEntityEnvelope( change )
	if not envelope then
		if SV.StreamingEnabled() then
			if SV.ReinitializeColumnStreaming then SV.ReinitializeColumnStreaming( ply, envelopeError ) end
			return false, envelopeError or "correction_envelope_failed"
		end
		return SV.SendStateSnapshot( ply )
	end
	net.Start( "mc_state_set" )
		writeOrderedHeader( math.floor( tonumber( revision ) or SV.BlockRevision ) )
		net.WriteUInt( TRANSACTION_FLAG_CORRECTION, 8 )
		writeCell( change )
		writeBlockEntityEnvelope( envelope )
	net.Send( ply )
	return true
end

function SV.BuildStateSnapshotPayload( slotName )
	if not SV.BuildStateSaveData then return nil, "state_save_codec_unavailable" end
	local data, _, buildError = SV.BuildStateSaveData( slotName or "__network_snapshot", { forClient = true } )
	if not data then return nil, buildError or "snapshot_build_failed" end
	local json = util.TableToJSON( data, false )
	if not json then return nil, "snapshot_json_failed" end
	local compressed = util.Compress( json )
	if not compressed then return nil, "snapshot_compress_failed" end
	return compressed
end

function SV.BuildBinaryStateSnapshotPayload()
	if not MC.BinarySectionPatch or not MC.BinarySectionPatch.EncodeSnapshotPayload then
		return nil, "binary_snapshot_encoder_unavailable"
	end
	local refs = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and ( tonumber( chunk.count ) or 0 ) > 0 then refs[#refs + 1] = chunk end
	end
	table.sort( refs, function( a, b )
		if a.cz ~= b.cz then return a.cz < b.cz end
		if a.cy ~= b.cy then return a.cy < b.cy end
		return a.cx < b.cx
	end )
	return MC.BinarySectionPatch.EncodeSnapshotPayload( refs, binaryNetProfileEnabled() )
end

function SV.SendStateSnapshot( ply, payload, baseRevision, binarySnapshot )
	if MC.Workshop and MC.Workshop.ShouldUseServerBaseForPlayer
	and MC.Workshop.ShouldUseServerBaseForPlayer( ply ) then
		MsgN( string.format( "[MC Workshop] blocked full state snapshot for %s; restarting GMA base sync",
			IsValid( ply ) and ply:Nick() or tostring( ply ) ) )
		if SV.ClearReliableNet then SV.ClearReliableNet( ply ) end
		SV.SendStateHello( ply )
		return false, "workshop_base_replaces_snapshot"
	end
	if SV.StreamingEnabled() then
		if SV.ReinitializeColumnStreaming then SV.ReinitializeColumnStreaming( ply, "snapshot_forbidden_in_streaming_mode" ) end
		return false, "snapshot_forbidden_in_streaming_mode"
	end
	if not validPlayer( ply ) then return false, "invalid_player" end
	if not compatibleClient( ply ) then return false, "protocol_not_ready" end
	if payload == nil then
		local err
		binarySnapshot = binaryStateSnapshotEnabled( ply )
		if binarySnapshot then payload, err = SV.BuildBinaryStateSnapshotPayload() end
		if not payload then
			binarySnapshot = false
			payload, err = SV.BuildStateSnapshotPayload()
		end
		if not payload then return false, err end
	end
	if not isstring( payload ) then return false, "invalid_snapshot_payload" end
	if binarySnapshot == nil and MC.BinarySectionPatch and MC.BinarySectionPatch.IsSnapshotPayload then
		binarySnapshot = MC.BinarySectionPatch.IsSnapshotPayload( payload )
	end
	if binarySnapshot == true and not binaryStateSnapshotEnabled( ply ) then
		return false, "binary_snapshot_not_supported"
	end
	baseRevision = math.floor( tonumber( baseRevision ) or SV.BlockRevision )
	local snapshotGeneration = SV.WorldGeneration
	local token = nextSnapshotToken()
	local totalBytes = #payload
	local snapshotPartBytes = reliablePayloadBytes( 64, SNAPSHOT_PART_BYTES )
	local partCount = math.ceil( totalBytes / snapshotPartBytes )
	if partCount > 65535 then return false, "snapshot_too_large" end
	if SV.ClearReliableNet then SV.ClearReliableNet( ply ) end

	net.Start( "mc_state_snapshot_begin" )
		net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
		net.WriteUInt( baseRevision, N.REVISION_BITS )
		net.WriteUInt( token, 32 )
		net.WriteUInt( totalBytes, 32 )
		net.WriteUInt( partCount, 16 )
		net.WriteString( schemaHash() )
		net.WriteString( blockEntityRegistryHash() )
	net.Send( ply )

	local function enqueue( bytes, callback, waitAck )
		if SV.EnqueueReliableNet then return SV.EnqueueReliableNet( ply, bytes, callback, waitAck ) end
		return callback( ply )
	end

	for partIndex = 0, partCount - 1 do
		local offset = partIndex * snapshotPartBytes + 1
		local bytes = string.sub( payload, offset, offset + snapshotPartBytes - 1 )
		local queuedIndex, queuedBytes = partIndex, bytes
		local ackBytes = #queuedBytes + 64
		enqueue( ackBytes, function( target )
			net.Start( "mc_state_snapshot_part" )
				net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
				net.WriteUInt( token, 32 )
				net.WriteUInt( queuedIndex, 16 )
				net.WriteUInt( #queuedBytes, 16 )
				net.WriteData( queuedBytes, #queuedBytes )
				net.WriteUInt( ackBytes, 32 )
			net.Send( target )
		end, true )
	end

	enqueue( 128, function( target )
		net.Start( "mc_state_snapshot_end" )
			net.WriteUInt( snapshotGeneration, N.GENERATION_BITS )
			net.WriteUInt( baseRevision, N.REVISION_BITS )
			net.WriteUInt( token, 32 )
			net.WriteString( tostring( util.CRC( payload ) ) )
		net.Send( target )
	end )
	local client = SV.StateNetClients[ply]
	if client then client.pendingSnapshotToken = token end
	return true, token, totalBytes, partCount
end

net.Receive( "mc_state_hello_ack", function( _, ply )
	local version = net.ReadUInt( 16 )
	local capabilities = net.ReadUInt( N.CAPABILITY_BITS )
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local clientSchemaHash = net.ReadString()
	local clientBEHash = net.ReadString()
	local ok, err = SV.ValidateStateProtocol( version, capabilities, clientSchemaHash, clientBEHash )
	SV.StateNetClients[ply] = {
		ready = ok and generation == SV.WorldGeneration,
		version = version,
		capabilities = capabilities,
		error = not ok and err or generation ~= SV.WorldGeneration and "generation_mismatch" or nil,
	}
	if SV.StateNetClients[ply].ready then
		if MC.Workshop and MC.Workshop.HandleStateHelloAck
		and MC.Workshop.HandleStateHelloAck( ply, SV.StateNetClients[ply] ) == true then
			return
		end
		local helloRevision = math.floor( tonumber( SV.StateHelloRevisions[ply] ) or SV.BlockRevision )
		if helloRevision < SV.BlockRevision then
			SV.SendStateRevisionSkip( ply, helloRevision + 1, SV.BlockRevision )
		end
		if SV.StreamingEnabled() and SV.InitializeColumnStreaming then
			SV.InitializeColumnStreaming( ply )
		else
			SV.SendStateSnapshot( ply )
		end
	else
		SV.SendStateHello( ply )
	end
end )

net.Receive( "mc_state_snapshot_ack", function( _, ply )
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local token = net.ReadUInt( 32 )
	local appliedRevision = net.ReadUInt( N.REVISION_BITS )
	local success = net.ReadBool()
	local client = SV.StateNetClients[ply]
	if not client or generation ~= SV.WorldGeneration or token ~= client.pendingSnapshotToken then return end
	client.pendingSnapshotToken = nil
	client.appliedRevision = success and appliedRevision or nil
	if success and MC.RunEvent then MC.RunEvent( "MC.PlayerWorldSynced", ply, appliedRevision ) end
end )

net.Receive( "mc_state_resync_request", function( _, ply )
	local now = CurTime()
	local last = SV.StateResyncRequestTimes[ply]
	if last and now - last < 4 then return end
	SV.StateResyncRequestTimes[ply] = now
	local generation = net.ReadUInt( N.GENERATION_BITS )
	local revision = net.ReadUInt( N.REVISION_BITS )
	local reason = string.sub( net.ReadString(), 1, 128 )
	local client = SV.StateNetClients[ply]
	if not client or not client.ready then
		SV.SendStateHello( ply )
		return
	end
	client.resyncReason = reason
	client.appliedRevision = revision
	if generation ~= SV.WorldGeneration then
		SV.SendStateHello( ply )
		return
	end
	if SV.StreamingEnabled() and SV.ReinitializeColumnStreaming then
		SV.ReinitializeColumnStreaming( ply, reason )
	else
		SV.SendStateSnapshot( ply )
	end
end )

hook.Add( "PlayerDisconnected", "mc_state_transport_cleanup", function( ply )
	SV.StateHelloRevisions[ply] = nil
	SV.StateResyncRequestTimes[ply] = nil
end )

if TRANSPORT_RELOAD and timer and timer.Simple then
	timer.Simple( 0, function()
		SV.AdvanceWorldGeneration( true )
		if not SV.BeginSync then return end
		for _, ply in ipairs( player.GetAll() ) do SV.BeginSync( ply ) end
	end )
end
