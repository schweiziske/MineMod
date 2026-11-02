if SERVER then return end

-- Explicit diagnostics only. Never query proxy cells, export Native sections,
-- force GC, or retain world/cache tables in a saved report.
MC = MC or {}
if MC.WorldMemory then MC.WorldMemory.Cancel() end
local M = {}
MC.WorldMemory = M
local active
local timerName = "mc_world_memory_watch"
local serial = 0

local function say( message ) print( "[MC world memory] " .. message ) end

local function entries( value )
	if type( value ) ~= "table" then return 0 end
	local count = 0
	for _ in next, value do count = count + 1 end
	return count
end

local function stringBytes( values )
	local bytes = 0
	if type( values ) == "table" then
		for _, value in next, values do
			if type( value ) == "string" then bytes = bytes + #value end
		end
	end
	return bytes
end

-- Counts reachable raw entries and string payloads, not allocator footprints.
-- Metatables and function closures are deliberately outside this census.
local function graphStats( roots )
	local result = { tables = 0, entries = 0, numberValues = 0, opaqueValues = 0,
		stringReferences = 0, stringReferenceBytes = 0, uniqueStrings = 0, uniqueStringBytes = 0 }
	local seenTables, seenStrings, stack = {}, {}, {}
	local function visit( value )
		local kind = type( value )
		if kind == "table" then
			if not seenTables[value] then
				seenTables[value] = true
				stack[#stack + 1] = value
				result.tables = result.tables + 1
			end
		elseif kind == "string" then
			result.stringReferences = result.stringReferences + 1
			result.stringReferenceBytes = result.stringReferenceBytes + #value
			if not seenStrings[value] then
				seenStrings[value] = true
				result.uniqueStrings = result.uniqueStrings + 1
				result.uniqueStringBytes = result.uniqueStringBytes + #value
			end
		elseif kind ~= "number" and kind ~= "boolean" and kind ~= "nil" then
			result.opaqueValues = result.opaqueValues + 1
		end
	end
	for _, root in ipairs( roots ) do visit( root ) end
	while #stack > 0 do
		local value = stack[#stack]
		stack[#stack] = nil
		for key, item in next, value do
			result.entries = result.entries + 1
			if type( item ) == "number" then result.numberValues = result.numberValues + 1 end
			visit( key )
			visit( item )
		end
	end
	return result
end

local function addRoot( roots, value )
	if type( value ) == "table" or type( value ) == "string" then roots[#roots + 1] = value end
end

local function transportStats( detailed )
	local transport = MC.StateNetworkTransport
	if type( transport ) ~= "table" then return { available = false } end
	local snapshot, patch = transport.snapshot, transport.chunkPatch
	local result = { available = true, snapshotActive = snapshot ~= nil, chunkPatchActive = patch ~= nil,
		awaitingSnapshot = transport.awaitingSnapshot == true, desynced = transport.desynced == true,
		snapshotFragments = 0, snapshotFragmentBytes = 0, batchCount = 0, batchPayloadBytes = 0,
		committedBatchPayloadBytes = 0, chunkPatchFragmentBytes = 0,
		pendingTransactions = entries( transport.pendingTransactions ),
		pendingCorrections = entries( transport.pendingCorrections ), pendingStreams = entries( transport.pendingStreams ),
		pendingChunkPatches = entries( transport.pendingChunkPatches ) }
	if snapshot then
		result.snapshotFragments = entries( snapshot.parts )
		result.snapshotFragmentBytes = stringBytes( snapshot.parts )
		local binary = snapshot.binary
		if binary then
			result.nextBatch = binary.nextBatch
			result.nativeDecodePending = entries( binary.decodes )
			for index, batch in next, binary.batches or {} do
				local bytes = type( batch.payload ) == "string" and #batch.payload or 0
				result.batchCount = result.batchCount + 1
				result.batchPayloadBytes = result.batchPayloadBytes + bytes
				if index < binary.nextBatch then
					result.committedBatchPayloadBytes = result.committedBatchPayloadBytes + bytes
				end
			end
		end
	end
	if patch then result.chunkPatchFragmentBytes = stringBytes( patch.parts ) end
	result.bufferReferenceBytes = result.snapshotFragmentBytes + result.batchPayloadBytes + result.chunkPatchFragmentBytes
	local session = MC.NativeTakeover and MC.NativeTakeover.active
	if session and session.nativeTransport then
		local ok, native, err = MC.Try( "world_memory_native_transport", session.handle.GetTransportStats, session.handle )
		if ok and MC.Check( type( native ) == "table", "world_memory_native_transport_result", "%s", tostring( err ) ) then
			result.nativeTransport = native
		end
	end
	if detailed then
		local roots = {}
		for _, name in ipairs( { "snapshot", "chunkPatch", "pendingTransactions", "pendingCorrections",
			"pendingStreams", "pendingChunkPatches" } ) do addRoot( roots, transport[name] ) end
		local session = MC.NativeTakeover and MC.NativeTakeover.active
		if session then addRoot( roots, session.decodeJobs ) end
		result.retainedGraph = graphStats( roots )
	end
	return result
end

local function newWorldStats()
	return { chunkRecords = 0, blocks = 0, nativeChunks = 0, luaChunks = 0, staleNativeChunks = 0,
		legacyBlockEntries = 0, legacyOrientEntries = 0, stateSections = 0, stateSectionBlocks = 0,
		nativeLegacyBlockEntries = 0, nativeLegacyOrientEntries = 0, nativeStateSections = 0,
		nativeStateSectionBlocks = 0, packedWordEntries = 0, paletteEntries = 0,
		cachedChunks = 0, cachedSections = 0, cachedStateEntries = 0, cachedIndexEntries = 0,
		cachedReverseEntries = 0, nativeCachedSections = 0, nativeCachedStateEntries = 0,
		blockEntities = 0, opaqueBlockEntities = 0, topCachedChunks = {} }
end

local function inspectChunk( chunk, key, result, epoch, roots )
	result.chunkRecords = result.chunkRecords + 1
	result.blocks = result.blocks + chunk.count
	local native = chunk.nativeStateStorage == true
	if native then
		result.nativeChunks = result.nativeChunks + 1
		if chunk.nativeMeshEpoch ~= epoch or epoch == nil then result.staleNativeChunks = result.staleNativeChunks + 1 end
	else result.luaChunks = result.luaChunks + 1 end
	-- next() never invokes the Native blocks/orients compatibility __index.
	local blocks, orients = entries( chunk.blocks ), entries( chunk.orients )
	result.legacyBlockEntries = result.legacyBlockEntries + blocks
	result.legacyOrientEntries = result.legacyOrientEntries + orients
	if native then
		result.nativeLegacyBlockEntries = result.nativeLegacyBlockEntries + blocks
		result.nativeLegacyOrientEntries = result.nativeLegacyOrientEntries + orients
	end
	for _, name in ipairs( { "stateSections", "blocks", "orients" } ) do addRoot( roots.state, chunk[name] ) end
	if chunk.stateSections then
		for _, section in next, chunk.stateSections do
			result.stateSections = result.stateSections + 1
			result.stateSectionBlocks = result.stateSectionBlocks + section.count
			result.packedWordEntries = result.packedWordEntries + entries( section.words )
			result.paletteEntries = result.paletteEntries + entries( section.palette )
			if native then
				result.nativeStateSections = result.nativeStateSections + 1
				result.nativeStateSectionBlocks = result.nativeStateSectionBlocks + section.count
			end
		end
	end
	local cachedStates, cachedSections = 0, 0
	if chunk.renderSectionBlocks then
		addRoot( roots.render, chunk.renderSectionBlocks )
		for _, section in next, chunk.renderSectionBlocks do
			cachedSections = cachedSections + 1
			cachedStates = cachedStates + entries( section.states )
			result.cachedIndexEntries = result.cachedIndexEntries + entries( section.indices )
			result.cachedReverseEntries = result.cachedReverseEntries + entries( section.slots )
		end
	end
	result.cachedSections = result.cachedSections + cachedSections
	result.cachedStateEntries = result.cachedStateEntries + cachedStates
	if native then
		result.nativeCachedSections = result.nativeCachedSections + cachedSections
		result.nativeCachedStateEntries = result.nativeCachedStateEntries + cachedStates
	end
	if cachedSections > 0 then
		result.cachedChunks = result.cachedChunks + 1
		result.topCachedChunks[#result.topCachedChunks + 1] = { key = tostring( key ),
			sections = cachedSections, states = cachedStates, native = native }
	end
	result.blockEntities = result.blockEntities + entries( chunk.blockEntities )
	result.opaqueBlockEntities = result.opaqueBlockEntities + entries( chunk.opaqueBlockEntities )
	addRoot( roots.entities, chunk.blockEntities )
	addRoot( roots.entities, chunk.opaqueBlockEntities )
end

function M.Capture( label )
	if not MC.Check( type( MC.World ) == "table", "world_memory_no_world", "MC.World is unavailable" ) then return nil end
	local heapBefore, started = collectgarbage( "count" ), SysTime()
	local report = { schema = 1, label = label, capturedAt = os.date( "%Y-%m-%d %H:%M:%S" ),
		map = game.GetMap(), luaHeapKB = heapBefore, world = newWorldStats(), detached = newWorldStats(),
		notes = {
			"luaHeapKB is the entire client Lua VM allocation, including uncollected garbage; GC is not forced.",
			"Raw table entries and string payload bytes are measured; table capacities/headers and Native/GPU bytes are not.",
			"Native compatibility proxies are counted with next(), without querying or exporting Native cells.",
			"Cached states on Native-marked chunks are Lua copies; caches can remain from an earlier fallback build.",
			"stateSectionBlocks uses section metadata, not a decoded cell scan. Legacy blocks/orients are separate views.",
			"Graph totals deduplicate tables within each category; categories can share objects and must not be summed.",
			"Buffer byte totals count references. Graph uniqueStringBytes deduplicates equal string contents.",
			"Functions, metatables, userdata and C++ resources are not traversed. Observer allocations/time are reported separately.",
		} }
	local epoch, session = nil, MC.NativeTakeover and MC.NativeTakeover.active
	if session then
		epoch = session.backendEpoch
		local ok, stats, err = MC.Try( "world_memory_native_stats", session.handle.GetStats, session.handle )
		if not ok then return nil end
		if not MC.Check( type( stats ) == "table", "world_memory_native_stats_result", "%s", tostring( err ) ) then return nil end
		report.nativeWorld = stats
	end
	report.nativeActive = session ~= nil
	local roots = { state = {}, render = {}, entities = {} }
	local seen = {}
	for key, chunk in next, MC.World do
		if not seen[chunk] then
			seen[chunk] = true
			inspectChunk( chunk, key, report.world, epoch, roots )
		end
	end
	for _, item in next, MC.StreamCleanupQueue or {} do
		if not item.done and item.chunk and not seen[item.chunk] then
			seen[item.chunk] = true
			inspectChunk( item.chunk, item.key, report.detached, epoch, roots )
		end
	end
	for _, result in ipairs( { report.world, report.detached } ) do
		table.sort( result.topCachedChunks, function( a, b ) return a.states > b.states end )
		for index = #result.topCachedChunks, 11, -1 do result.topCachedChunks[index] = nil end
	end
	if report.world.blocks > 0 then
		report.world.nativeCachedPercentOfWorldBlocks = report.world.nativeCachedStateEntries / report.world.blocks * 100
	end
	report.graphs = { state = graphStats( roots.state ), render = graphStats( roots.render ), entities = graphStats( roots.entities ),
		blockLight = graphStats( { MC.LightBlockChunks } ), skyLight = graphStats( { MC.LightSkyChunks } ),
		blockEmitCache = graphStats( { MC.MeshBlockEmitCache } ) }
	report.transport = transportStats( true )
	report.queues = { geometry = entries( MC.MeshDirty ), light = entries( MC.MeshLightDirty ),
		nativePending = MC.NativeL2 and MC.NativeL2.pendingCount or 0, cleanupPending = MC.StreamCleanupPending or 0 }
	local native = MC.NativeL2
	if native then
		-- Scalar totals only: do not retain the pending build contexts or input.
		report.renderInputs = { mixedTopologyAvailable = native.mixedTopologyAvailable == true,
			filteredSections = native.filteredSections or 0, filteredLuaCells = native.filteredLuaCells or 0,
			filteredWorldCells = native.filteredWorldCells or 0 }
	end
	report.observer = { scanMS = ( SysTime() - started ) * 1000, heapAfterScanKB = collectgarbage( "count" ) }
	report.observer.heapDeltaKB = report.observer.heapAfterScanKB - heapBefore
	return report
end

local function reportText( report )
	local world, transport = report.world, report.transport
	local lines = {
		string.format( "%s Lua heap=%.2f MiB (whole client VM, GC not forced)", report.label, report.luaHeapKB / 1024 ),
		string.format( "World chunks=%d blocks=%d native=%d lua=%d staleNative=%d", world.chunkRecords,
			world.blocks, world.nativeChunks, world.luaChunks, world.staleNativeChunks ),
		string.format( "Native chunk Lua copies: cachedSections=%d stateEntries=%d (%.2f%% of world blocks)",
			world.nativeCachedSections, world.nativeCachedStateEntries, world.nativeCachedPercentOfWorldBlocks or 0 ),
		string.format( "Native chunk legacy/packed storage: blocks=%d orients=%d sectionBlocks=%d",
			world.nativeLegacyBlockEntries, world.nativeLegacyOrientEntries, world.nativeStateSectionBlocks ),
		string.format( "All render caches: sections=%d states=%d indices=%d reverseSlots=%d", world.cachedSections,
			world.cachedStateEntries, world.cachedIndexEntries, world.cachedReverseEntries ),
		string.format( "Lua state: sections=%d nativeChunkSections=%d sectionBlocks=%d packedWords=%d legacyBlocks=%d orients=%d",
			world.stateSections, world.nativeStateSections, world.stateSectionBlocks, world.packedWordEntries,
			world.legacyBlockEntries, world.legacyOrientEntries ),
		string.format( "Block entities=%d opaque=%d; detachedChunks=%d detachedCachedStates=%d", world.blockEntities,
			world.opaqueBlockEntities, report.detached.chunkRecords, report.detached.cachedStateEntries ),
	}
	if report.renderInputs then
		local input = report.renderInputs
		lines[#lines + 1] = string.format( "Filtered build input (cumulative preparations): sections=%d LuaCells=%d worldCells=%d mixedTopology=%s",
			input.filteredSections, input.filteredLuaCells, input.filteredWorldCells, tostring( input.mixedTopologyAvailable ) )
	end
	if transport.available then
		lines[#lines + 1] = string.format( "Transport snapshot=%s fragmentBytes=%d batchBytes=%d committedRetainedBytes=%d patchFragmentBytes=%d",
			tostring( transport.snapshotActive ), transport.snapshotFragmentBytes, transport.batchPayloadBytes,
			transport.committedBatchPayloadBytes, transport.chunkPatchFragmentBytes )
		if transport.nativeTransport then
			local native = transport.nativeTransport
			lines[#lines + 1] = string.format( "Native transport jobs=%d running=%d retainedBytes=%d reservedBytes=%d",
				native.jobs, native.running, native.retainedBytes, native.reservedBytes )
		end
		lines[#lines + 1] = string.format( "Transport pending: transactions=%d corrections=%d streams=%d patches=%d",
			transport.pendingTransactions, transport.pendingCorrections, transport.pendingStreams, transport.pendingChunkPatches )
	else lines[#lines + 1] = "Transport unavailable; buffer counts are unknown" end
	for _, name in ipairs( { "state", "render", "entities", "blockLight", "skyLight", "blockEmitCache" } ) do
		local graph = report.graphs[name]
		lines[#lines + 1] = string.format( "%s: tables=%d entries=%d uniqueStringBytes=%d (table heap bytes unmeasured)",
			name, graph.tables, graph.entries, graph.uniqueStringBytes )
	end
	if report.watch then
		local watch = report.watch
		lines[#lines + 1] = string.format( "Watch %.2fs samples=%d sampledHeapPeak=%.2f MiB observer=%.2fms",
			watch.elapsedSeconds, #watch.samples, watch.peakLuaHeapKB / 1024, watch.observerMS )
		if watch.transportAvailableSamples > 0 then
			lines[#lines + 1] = string.format( "Sampled transport peaks: bufferBytes=%d committedRetainedBytes=%d availableSamples=%d",
				watch.peakBufferReferenceBytes, watch.peakCommittedBatchPayloadBytes, watch.transportAvailableSamples )
			if ( watch.nativeTransportAvailableSamples or 0 ) > 0 then
				lines[#lines + 1] = string.format( "Sampled Native transport peaks: retainedBytes=%d reservedBytes=%d availableSamples=%d",
					watch.peakNativeTransportBytes, watch.peakNativeTransportReservedBytes, watch.nativeTransportAvailableSamples )
			end
		else lines[#lines + 1] = "No transport samples available; buffer peaks are unknown" end
	end
	lines[#lines + 1] = string.format( "Observer scan=%.2fms heapDelta=%.2f KiB; census timing is not a game frame benchmark",
		report.observer.scanMS, report.observer.heapDeltaKB )
	return table.concat( lines, "\n" )
end

local function save( report )
	if not report then return nil end
	local path
	repeat
		serial = serial + 1
		path = string.format( "mc_render_bench/%s_world_memory_%s_%d", os.date( "%Y%m%d_%H%M%S" ), report.label, serial )
	until not file.Exists( path .. ".json", "DATA" ) and not file.Exists( path .. ".txt", "DATA" )
	local text, json = reportText( report ), util.TableToJSON( report, true )
	if not MC.Check( json ~= nil, "world_memory_encode", "Could not encode memory report" ) then return nil end
	file.CreateDir( "mc_render_bench" )
	file.Write( path .. ".json", json )
	file.Write( path .. ".txt", text )
	if not MC.Check( file.Size( path .. ".json", "DATA" ) == #json and file.Size( path .. ".txt", "DATA" ) == #text,
		"world_memory_write", "Could not write %s", path ) then return nil end
	M.lastText, M.lastPath = text, path
	say( text )
	say( "garrysmod/data/" .. path .. ".json" )
	return path
end

local function labelArgument( value )
	local label = value or "world"
	if #label < 1 or #label > 64 or label:find( "[^%w_-]" ) then
		return nil, "Label must contain 1..64 letters, digits, underscores or hyphens"
	end
	return label
end

local function sample( capture )
	local started = SysTime()
	local heap = collectgarbage( "count" )
	local transport = transportStats( false )
	capture.samples[#capture.samples + 1] = { seconds = started - capture.started, luaHeapKB = heap, transport = transport }
	capture.peakLuaHeapKB = math.max( capture.peakLuaHeapKB, heap )
	if transport.available then
		capture.transportAvailableSamples = capture.transportAvailableSamples + 1
		capture.peakBufferReferenceBytes = math.max( capture.peakBufferReferenceBytes, transport.bufferReferenceBytes )
		capture.peakCommittedBatchPayloadBytes = math.max( capture.peakCommittedBatchPayloadBytes, transport.committedBatchPayloadBytes )
		if transport.nativeTransport then
			capture.nativeTransportAvailableSamples = capture.nativeTransportAvailableSamples + 1
			capture.peakNativeTransportBytes = math.max( capture.peakNativeTransportBytes, transport.nativeTransport.retainedBytes )
			capture.peakNativeTransportReservedBytes = math.max( capture.peakNativeTransportReservedBytes, transport.nativeTransport.reservedBytes )
		end
	end
	capture.observerMS = capture.observerMS + ( SysTime() - started ) * 1000
end

function M.Cancel()
	timer.Remove( timerName )
	active = nil
end

function M.Stop()
	local capture = active
	if not capture then return nil, "No memory watch is running" end
	M.Cancel()
	sample( capture )
	capture.elapsedSeconds = SysTime() - capture.started
	local report = M.Capture( capture.label )
	if not report then return nil, "Memory census failed; see mc_faults" end
	report.watch = capture
	return save( report )
end

concommand.Add( "mc_world_memory", function( _, _, args )
	if active then say( "Use mc_world_memory_stop to finish the running watch" ) return end
	local label, err = labelArgument( args[1] )
	if not label then say( err ) return end
	save( M.Capture( label ) )
end, nil, "Report raw client world/cache entries, retained transport bytes and total Lua heap" )

concommand.Add( "mc_world_memory_start", function( _, _, args )
	if active then say( "A memory watch is already running" ) return end
	local label, err = labelArgument( args[1] )
	if not label then say( err ) return end
	local seconds = tonumber( args[2] or "120" )
	if not seconds or seconds < 1 or seconds > 600 then say( "Usage: mc_world_memory_start <label> [seconds 1..600]" ) return end
	active = { label = label, started = SysTime(), samples = {}, peakLuaHeapKB = 0,
		peakBufferReferenceBytes = 0, peakCommittedBatchPayloadBytes = 0, transportAvailableSamples = 0,
		peakNativeTransportBytes = 0, peakNativeTransportReservedBytes = 0,
		nativeTransportAvailableSamples = 0,
		observerMS = 0, intervalSeconds = 0.5 }
	sample( active )
	timer.Create( timerName, active.intervalSeconds, 0, function()
		if SysTime() - active.started >= seconds then
			local path, failure = M.Stop()
			if not path then say( failure or "Memory report failed; see mc_faults" ) end
		else sample( active ) end
	end )
	say( "Watching heap/transport twice per second; load the map yourself. Full world census runs only at stop." )
end, nil, "Observe sampled loading heap/buffer peaks, then write a final world memory census" )

concommand.Add( "mc_world_memory_stop", function()
	local path, err = M.Stop()
	if not path then say( err or "Memory report failed; see mc_faults" ) end
end )

concommand.Add( "mc_world_memory_report", function()
	if M.lastText then say( M.lastText ) say( "garrysmod/data/" .. M.lastPath .. ".json" )
	else say( "No report yet; use mc_world_memory <label>" ) end
end )
