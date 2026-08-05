-- Server-authoritative mode 1 chunk streaming: horizontal interest with complete
-- vertical columns. This module loads after block transactions and relies only
-- on the state transport/reliable queue public surfaces.
MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local N = MC.Net
local C = MC.Config

SV.StreamColumnClients = SV.StreamColumnClients or setmetatable( {}, { __mode = "k" } )

local function columnCoords( key )
	if type( key ) == "number" then
		local x = bit.band( key, 65535 ) - 32768
		local y = bit.band( bit.rshift( key, 16 ), 65535 ) - 32768
		return x, y
	end
	local x, y = string.match( tostring( key or "" ), "^(-?%d+):(-?%d+):0$" )
	return tonumber( x ), tonumber( y )
end

local function verticalBounds()
	local minCZ, maxCZ
	local store = SV.ChunkStore
	if store and store.GetVerticalBounds then minCZ, maxCZ = store.GetVerticalBounds() end
	if minCZ == nil or maxCZ == nil then
		for _, chunk in pairs( MC.World or {} ) do
			if chunk and ( chunk.count or 0 ) > 0 then
				if minCZ == nil or chunk.cz < minCZ then minCZ = chunk.cz end
				if maxCZ == nil or chunk.cz > maxCZ then maxCZ = chunk.cz end
			end
		end
	end
	if minCZ == nil or maxCZ == nil then
		-- Empty worlds still need a finite initial column so building can begin.
		local limit = math.max( 0, math.floor( tonumber( C.WorldLimit and C.WorldLimit:GetInt() ) or 0 ) )
		minCZ = math.floor( -limit / MC.CH )
		maxCZ = math.ceil( limit / MC.CH ) - 1
	end
	local span = maxCZ - minCZ + 1
	if span < 1 or span > ( N.MAX_STREAM_VERTICAL_CHUNKS or 1024 ) then
		return nil, nil, "world_vertical_span_exceeds_stream_protocol:" .. tostring( span )
	end
	return minCZ, maxCZ
end

SV.StreamingVerticalBounds = verticalBounds

local function desiredColumns( ply, radius )
	local pos = MC.EntityWorldPos and MC.EntityWorldPos( ply ) or ply:GetPos()
	local cx = math.floor( pos.x / MC.ChunkWorld )
	local cy = math.floor( pos.y / MC.ChunkWorld )
	local list, set = {}, {}
	for y = cy - radius, cy + radius do
		for x = cx - radius, cx + radius do
			local key = MC.ChunkColumnKey( x, y )
			set[key] = true
			list[#list + 1] = { key = key, cx = x, cy = y, distance = math.max( math.abs( x - cx ), math.abs( y - cy ) ) }
		end
	end
	table.sort( list, function( a, b )
		if a.distance ~= b.distance then return a.distance < b.distance end
		if a.cy ~= b.cy then return a.cy < b.cy end
		return a.cx < b.cx
	end )
	return list, set, cx, cy
end

function SV.ComputeColumnInterestDiff( subscribed, desiredList, centerX, centerY, unloadRadius, loadLimit, unloadLimit )
	local loads, unloads = {}, {}
	for _, item in ipairs( desiredList or {} ) do
		if #loads >= loadLimit then break end
		if not subscribed[item.key] then loads[#loads + 1] = item end
	end
	for key in pairs( subscribed or {} ) do
		if #unloads >= unloadLimit then break end
		local cx, cy = columnCoords( key )
		if not cx or math.max( math.abs( cx - centerX ), math.abs( cy - centerY ) ) > unloadRadius then
			unloads[#unloads + 1] = { key = key, cx = cx or 0, cy = cy or 0 }
		end
	end
	return loads, unloads
end

local function queueColumns( ply, minCZ, maxCZ, loads, unloads )
	if #loads == 0 and #unloads == 0 then return true end
	local generation = SV.WorldGeneration
	local bytes = 40 + ( #loads + #unloads ) * 10
	return SV.EnqueueReliableNet( ply, bytes, function( target )
		if not IsValid( target ) then return false end
		net.Start( "mc_stream_columns" )
			net.WriteUInt( generation, N.GENERATION_BITS )
			net.WriteInt( minCZ, N.COORD_BITS )
			net.WriteInt( maxCZ, N.COORD_BITS )
			net.WriteUInt( #loads, 7 )
			for _, item in ipairs( loads ) do
				net.WriteInt( item.cx, N.COORD_BITS )
				net.WriteInt( item.cy, N.COORD_BITS )
			end
			net.WriteUInt( #unloads, 7 )
			for _, item in ipairs( unloads ) do
				net.WriteInt( item.cx, N.COORD_BITS )
				net.WriteInt( item.cy, N.COORD_BITS )
			end
		net.Send( target )
		return true
	end, false )
end

local function hydrateLazyColumns( loads, minCZ, maxCZ )
	local store = SV.ChunkStore
	if not store or not store.IsLazyWorld or not store.IsLazyWorld() then return loads end
	local profiling = SV.BinaryNetHydrationProfileEnabled and SV.BinaryNetHydrationProfileEnabled() == true
	local batchSample = profiling and {
		startedAt = SysTime(), columns = #loads, ready = 0, cold = 0, warm = 0, failed = 0, hydrateMS = 0,
	} or nil
	local ready = {}
	for _, item in ipairs( loads ) do
		local columnSample = profiling and {
			startedAt = SysTime(), cx = item.cx, cy = item.cy,
			verticalChecks = 0, attempted = 0, cold = 0, warm = 0, failed = 0, hydrateMS = 0,
		} or nil
		local columnOK = true
		for cz = minCZ, maxCZ do
			if columnSample then columnSample.verticalChecks = columnSample.verticalChecks + 1 end
			local key = MC.ChunkKey( item.cx, item.cy, cz )
			local stringKey = tostring( key )
			local needsData = ( store.HasBaseChunk and store.HasBaseChunk( key ) )
				or ( store.HasChunkEdits and store.HasChunkEdits( key ) )
			if needsData then
				if columnSample then columnSample.attempted = columnSample.attempted + 1 end
				if store.LoadedKeys and store.LoadedKeys[stringKey] then
					if columnSample then columnSample.warm = columnSample.warm + 1 end
					if batchSample then batchSample.warm = batchSample.warm + 1 end
				else
					if columnSample then columnSample.cold = columnSample.cold + 1 end
					if batchSample then batchSample.cold = batchSample.cold + 1 end
					store.LastError = nil
					local hydrateStarted = profiling and SysTime() or nil
					store.HydrateChunkNow( key, false )
					if profiling then
						local elapsedMS = ( SysTime() - hydrateStarted ) * 1000
						columnSample.hydrateMS = columnSample.hydrateMS + elapsedMS
						batchSample.hydrateMS = batchSample.hydrateMS + elapsedMS
					end
					if store.LastError or not ( store.LoadedKeys and store.LoadedKeys[stringKey] ) then
						columnOK = false
						if columnSample then columnSample.failed = columnSample.failed + 1 end
						if batchSample then batchSample.failed = batchSample.failed + 1 end
						if ErrorNoHalt then ErrorNoHalt( "[MC] streaming lazy column hydration failed at "
							.. MC.ChunkKeyString( key ) .. ": " .. tostring( store.LastError or "not_loaded" ) .. "\n" ) end
						break
					end
				end
			end
		end
		if columnOK then
			ready[#ready + 1] = item
			if batchSample then batchSample.ready = batchSample.ready + 1 end
		end
		if columnSample then
			columnSample.success = columnOK
			columnSample.totalMS = ( SysTime() - columnSample.startedAt ) * 1000
			columnSample.scanMS = math.max( 0, columnSample.totalMS - columnSample.hydrateMS )
			if SV.RecordColumnHydrationProfile then SV.RecordColumnHydrationProfile( columnSample ) end
		end
	end
	if batchSample then
		batchSample.totalMS = ( SysTime() - batchSample.startedAt ) * 1000
		batchSample.scanMS = math.max( 0, batchSample.totalMS - batchSample.hydrateMS )
		if SV.RecordHydrationBatchProfile then SV.RecordHydrationBatchProfile( batchSample ) end
	end
	return ready
end

local function patchRefsForColumns( loads, minCZ, maxCZ )
	local wanted, refs = {}, {}
	for _, item in ipairs( loads ) do wanted[item.key] = true end
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 and chunk.cz >= minCZ and chunk.cz <= maxCZ
		and wanted[MC.ChunkColumnKey( chunk.cx, chunk.cy )] then
			refs[#refs + 1] = { patchRef = true, cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, chunk = chunk,
				cellCount = math.max( 0, math.floor( tonumber( chunk.count ) or 0 ) ) }
		end
	end
	table.sort( refs, function( a, b )
		if a.cx ~= b.cx then return a.cx < b.cx end
		if a.cy ~= b.cy then return a.cy < b.cy end
		return a.cz < b.cz
	end )
	return refs
end

function SV.SplitStreamingPatchRefs( refs, maxChunks, maxCells )
	maxChunks = math.Clamp( math.floor( tonumber( maxChunks ) or 16 ), 1, 64 )
	maxCells = math.Clamp( math.floor( tonumber( maxCells ) or 32768 ), 1024, 131072 )
	local batches, current, cells = {}, {}, 0
	for _, ref in ipairs( refs or {} ) do
		local count = math.max( 0, math.floor( tonumber( ref.cellCount or ( ref.chunk and ref.chunk.count ) ) or 0 ) )
		if #current > 0 and ( #current >= maxChunks or cells + count > maxCells ) then
			batches[#batches + 1] = current
			current, cells = {}, 0
		end
		current[#current + 1] = ref
		cells = cells + count
	end
	if #current > 0 then batches[#batches + 1] = current end
	return batches
end

local function rotateAtRevisionLimit()
	if ( SV.BlockRevision or 0 ) < N.MAX_REVISION then return false end
	SV.AdvanceWorldGeneration( true )
	for _, target in ipairs( player.GetAll() ) do if SV.BeginSync then SV.BeginSync( target ) end end
	return true
end

local function otherReadyClients( excluded )
	local others = {}
	for _, target in ipairs( player.GetHumans() ) do
		if target ~= excluded and SV.IsStateClientReady( target ) then others[#others + 1] = target end
	end
	return others
end

local function allocateStreamingRevision( owner )
	if rotateAtRevisionLimit() then return nil end
	SV.BlockRevision = ( SV.BlockRevision or 0 ) + 1
	local revision = SV.BlockRevision
	SV.SendStreamPatchPending( owner, revision )
	SV.SendStateRevisionSkip( otherReadyClients( owner ), revision, revision )
	return revision
end

local function streamPlayerImpl( ply, force )
	if not SV.StreamingEnabled() or not SV.IsStateClientReady( ply ) then return end
	local depth, inflight = SV.ReliableNetQueueDepth( ply )
	if not force and ( depth > 24 or inflight > 0 ) then return end
	local state = SV.StreamColumnClients[ply]
	if not state then state = { subscribed = {} }; SV.StreamColumnClients[ply] = state end
	local radius = math.Clamp( C.StreamChunkSpanXY:GetInt(), 0, 32 )
	local margin = math.Clamp( C.StreamUnloadMargin:GetInt(), 0, 16 )
	local batch = math.Clamp( C.StreamColumnsPerBatch:GetInt(), 1, N.MAX_STREAM_COLUMNS or 64 )
	local desired, _, centerX, centerY = desiredColumns( ply, radius )
	local loads, unloads = SV.ComputeColumnInterestDiff( state.subscribed, desired, centerX, centerY,
		radius + margin, batch, N.MAX_STREAM_COLUMNS or 64 )
	if #loads == 0 and #unloads == 0 then return end
	local minCZ, maxCZ, boundsError = verticalBounds()
	if not minCZ then
		if ErrorNoHalt then ErrorNoHalt( "[MC] refusing streaming sync: " .. tostring( boundsError ) .. "\n" ) end
		return
	end
	loads = hydrateLazyColumns( loads, minCZ, maxCZ )
	if #loads == 0 and #unloads == 0 then return end
	local refs = patchRefsForColumns( loads, minCZ, maxCZ )
	local maxPatchChunks = math.Clamp( C.StreamMaxPatchChunks:GetInt(), 1, 64 )
	local maxPatchCells = math.Clamp( C.StreamMaxPatchCells:GetInt(), 1024, 131072 )
	local patchBatches = SV.SplitStreamingPatchRefs( refs, maxPatchChunks, maxPatchCells )
	-- Every split costs begin/parts/end entries. Do not publish membership until
	-- the existing queue has room for the whole column's contiguous revision run.
	if not force and depth + #patchBatches * 3 > 24 then return end
	if #patchBatches > 0 and ( SV.BlockRevision or 0 ) + #patchBatches > N.MAX_REVISION then
		rotateAtRevisionLimit()
		return
	end
	if not queueColumns( ply, minCZ, maxCZ, loads, unloads ) then return end
	-- Membership changes at queue time, matching the ordering of future edits.
	for _, item in ipairs( loads ) do state.subscribed[item.key] = true end
	for _, item in ipairs( unloads ) do state.subscribed[item.key] = nil end
	state.minCZ, state.maxCZ = minCZ, maxCZ
	-- Membership is FIFO-first. Empty columns consume no revision; oversized
	-- non-empty columns follow as deterministic cz-ordered partial patches.
	for _, batchRefs in ipairs( patchBatches ) do
		local revision = allocateStreamingRevision( ply )
		if not revision then return end
		local queued = SV.QueueStateChunkHydration( batchRefs, revision, revision, ply, true )
		if queued ~= true then
			if SV.ReinitializeColumnStreaming then SV.ReinitializeColumnStreaming( ply, "patch_queue_failed" ) end
			return
		end
	end
end

local function streamPlayer( ply, force )
	local profiling = SV.BinaryNetHydrationProfileEnabled and SV.BinaryNetHydrationProfileEnabled() == true
	if not profiling then return streamPlayerImpl( ply, force ) end
	local startedAt = SysTime()
	local result = streamPlayerImpl( ply, force )
	if SV.RecordStreamPlayerProfile then
		SV.RecordStreamPlayerProfile( {
			totalMS = ( SysTime() - startedAt ) * 1000,
			frame = FrameNumber and FrameNumber() or 0,
			force = force == true,
		} )
	end
	return result
end

function SV.AllocateStreamingRevision( ply )
	return allocateStreamingRevision( ply )
end

function SV.InitializeColumnStreaming( ply )
	if not IsValid( ply ) then return false end
	SV.StreamColumnClients[ply] = { subscribed = {} }
	streamPlayer( ply, true )
	return true
end

function SV.ReinitializeColumnStreaming( ply )
	if not IsValid( ply ) then return false end
	if SV.ClearReliableNet then SV.ClearReliableNet( ply ) end
	SV.StreamColumnClients[ply] = nil
	SV.StateNetClients[ply] = nil
	net.Start( "mc_clear" ) net.Send( ply )
	SV.SendStateHello( ply )
	return true
end

function SV.IsPlayerSubscribedToColumn( ply, cx, cy )
	local state = SV.StreamColumnClients[ply]
	return state and state.subscribed[MC.ChunkColumnKey( cx, cy )] == true or false
end

hook.Add( "PlayerDisconnected", "mc_stream_columns_cleanup", function( ply ) SV.StreamColumnClients[ply] = nil end )
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_chunk_streaming", function()
		timer.Simple( 0, function()
			SV.StreamColumnClients = setmetatable( {}, { __mode = "k" } )
			for _, ply in ipairs( player.GetAll() ) do
				if SV.ClearReliableNet then SV.ClearReliableNet( ply ) end
				SV.StateNetClients[ply] = nil
				net.Start( "mc_clear" ) net.Send( ply )
				if SV.BeginSync then SV.BeginSync( ply ) end
			end
		end )
	end, "mc_column_streaming_mode" )
end
local nextStreamAt = 0
timer.Create( "mc_stream_columns", 0.1, 0, function()
	if not SV.StreamingEnabled() then return end
	local now = CurTime()
	if now < nextStreamAt then return end
	nextStreamAt = now + math.max( 0.1, C.StreamInterval:GetFloat() )
	for _, ply in ipairs( player.GetHumans() ) do streamPlayer( ply, false ) end
end )
