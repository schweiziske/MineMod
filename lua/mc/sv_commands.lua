--[[----------------------------------------------------------------------------
	MC : server command layer.

	Console/chat command parsing lives here; world mutation stays in sv_world.lua.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config
local FILL_BULK_CELLS_PER_MESSAGE = 4096 -- legacy fallback queue, no longer the default /fill path
local FillJobs = {}
local NextFillBatchAt = 0
local NextFillJobId = 0

local function nextFillJobId()
	NextFillJobId = ( NextFillJobId + 1 ) % 4294967296
	if NextFillJobId == 0 then NextFillJobId = 1 end
	return NextFillJobId
end

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local function chat( ply, msg )
	if SV.Chat then
		SV.Chat( ply, msg )
		if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. msg ) end
	elseif IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. msg )
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. msg )
	else
		MsgN( "[MC] " .. msg )
	end
end

local function trimArg( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

local function joinArgs( args, first, last )
	if not args[first] then return nil end
	local out = {}
	for i = first, last or #args do out[#out + 1] = args[i] end
	return table.concat( out, " " )
end

local function copyConsoleArgsWithCommand( command, args )
	local out = { command }
	for i = 1, #args do out[#out + 1] = args[i] end
	return out
end

------------------------------------------------------------------- fill command
local FILL_USAGE = "用法: /fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]> [state]"

local function fillAimText( ply )
	if not IsValid( ply ) or not MC.PlayerBlockAim then return nil end
	local hit = MC.PlayerBlockAim( ply )
	if not hit or not hit.bx then return nil end
	return string.format( "当前瞄准方块坐标: %d %d %d", hit.bx, hit.by, hit.bz )
end

local function sendFillUsage( ply )
	chat( ply, L( ply, "server.fill_usage", FILL_USAGE ) )
	-- local aim = fillAimText( ply )
	-- if aim then chat( ply, aim ) end
end

local function appendFillCoords( job, bx, by, bz )
	local coords = job.coords
	coords[#coords + 1] = bx
	coords[#coords + 1] = by
	coords[#coords + 1] = bz
	job.cellCount = job.cellCount + 1
end

local function fillBatchCells()
	local configured = C.FillBatchCells and C.FillBatchCells:GetInt() or MC.Config.FillBatchCells or 512
	local streamLimit = MC.Net and MC.Net.MAX_STATE_STREAM_CELLS or 4294967295
	return math.min( streamLimit, math.max( 1, configured ) )
end

local function fillBatchChunks()
	if C.FillBatchChunks then return math.max( 1, C.FillBatchChunks:GetInt() ) end
	return math.max( 1, MC.Config.FillBatchChunks or 16 )
end

local function fillBatchInterval()
	if C.FillBatchInterval then return math.max( 0, C.FillBatchInterval:GetFloat() ) end
	return math.max( 0, MC.Config.FillBatchInterval or 0.05 )
end

local function fillCellChunkKey( cell )
	local cx, cy, cz = MC.CellToChunk( cell.bx, cell.by, cell.bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function advanceFillScan( job )
	job.scanX = job.scanX + 1
	if job.scanX <= job.maxx then return end
	job.scanX = job.minx
	job.scanY = job.scanY + 1
	if job.scanY <= job.maxy then return end
	job.scanY = job.miny
	job.scanZ = job.scanZ + 1
end

local function scanFillJob( job )
	local budget = fillBatchCells()
	local processed = 0
	while job.scanZ <= job.maxz and processed < budget do
		local x, y, z = job.scanX, job.scanY, job.scanZ
		local old = MC.GetBlock( x, y, z )
		local changed = old ~= job.blockId
		if not changed and job.blockId ~= 0 then
			changed = MC.GetBlockOrient( x, y, z ) ~= job.orient
		end
		if changed then
			if job.blockId == 0 then
				if old ~= 0 then appendFillCoords( job, x, y, z ) end
			elseif old == 0 then
				if not SV.PlacementWouldTrapPlayer( x, y, z, job.blockId, job.orient ) then
					job.add = job.add + 1
					appendFillCoords( job, x, y, z )
				end
			else
				appendFillCoords( job, x, y, z )
			end
		end
		advanceFillScan( job )
		processed = processed + 1
	end
	if job.scanZ <= job.maxz then return "scanning" end

	local maxBlocks = C.MaxBlocks:GetInt()
	if job.blockId ~= 0 and maxBlocks > 0 and SV.BlockCount + job.add > maxBlocks then return "max_blocks" end
	if job.cellCount <= 0 then return "empty" end
	job.phase = "apply"
	job.index = 1
	chat( job.ply, string.format( "[fill] queued %d changed blocks; batch=%d cells/%d chunks every %.2fs",
		job.cellCount, fillBatchCells(), fillBatchChunks(), fillBatchInterval() ) )
	return "ready"
end

local function nextFillBatch( job )
	local batch = {}
	local chunks = {}
	local chunkCount = 0
	local maxCells = fillBatchCells()
	local maxChunks = fillBatchChunks()

	while job.index <= job.cellCount and #batch < maxCells do
		local offset = ( job.index - 1 ) * 3
		local cell = {
			bx = job.coords[offset + 1],
			by = job.coords[offset + 2],
			bz = job.coords[offset + 3],
			stateId = job.stateId,
		}
		local key = fillCellChunkKey( cell )
		if not chunks[key] then
			if chunkCount >= maxChunks and #batch > 0 then break end
			chunks[key] = true
			chunkCount = chunkCount + 1
		end
		batch[#batch + 1] = cell
		job.index = job.index + 1
	end

	return batch
end

local function enqueueFillJob( ply, spec )
	FillJobs[#FillJobs + 1] = {
		id = nextFillJobId(),
		ply = ply,
		phase = "scan",
		minx = spec.minx, maxx = spec.maxx,
		miny = spec.miny, maxy = spec.maxy,
		minz = spec.minz, maxz = spec.maxz,
		scanX = spec.minx, scanY = spec.miny, scanZ = spec.minz,
		blockId = spec.blockId,
		orient = spec.orient,
		stateId = spec.stateId,
		volume = spec.volume,
		coords = {},
		cellCount = 0,
		add = 0,
		changed = 0,
		startedAt = SysTime(),
		scanMS = 0,
		applyMS = 0,
		batches = 0,
		physKeys = {},
	}
	chat( ply, string.format( "[fill] scanning %d blocks in paced server batches", spec.volume ) )
end

-- Kept only so a hot-reloaded server can still parse old queued-job helpers;
-- no timer is installed and new fills never enter this compatibility branch.
if false then timer.Create( "mc_fill_jobs", 0.05, 0, function()
	if #FillJobs == 0 then return end
	local now = CurTime()
	if now < NextFillBatchAt then return end
	NextFillBatchAt = now + fillBatchInterval()

	local job = FillJobs[1]
	if job.phase == "scan" then
		local scanStarted = SysTime()
		local scanState = scanFillJob( job )
		job.scanMS = job.scanMS + ( SysTime() - scanStarted ) * 1000
		if scanState == "max_blocks" then
			table.remove( FillJobs, 1 )
			chat( job.ply, L( job.ply, "server.fill_max_blocks", "Fill would exceed mc_max_blocks" ) )
		elseif scanState == "empty" then
			table.remove( FillJobs, 1 )
			chat( job.ply, L( job.ply, "server.filled", "Filled {count} blocks", { count = 0 } ) )
		end
		return
	end
	local batch = nextFillBatch( job )
	if #batch > 0 then
		local applyStarted = SysTime()
		local changed = SV.SetBlocksBulk( batch, {
			actor = job.ply,
			fx = false,
			handlers = true,
			priorityPhys = false,
			immediatePhys = false,
			netPaced = true,
			cellsPerMessage = FILL_BULK_CELLS_PER_MESSAGE,
			stateStream = true,
			stateGroupId = job.id,
			physCollector = job.physKeys,
		} )
		job.applyMS = job.applyMS + ( SysTime() - applyStarted ) * 1000
		job.batches = job.batches + 1
		job.changed = ( job.changed or 0 ) + ( changed or 0 )
	end

	if job.index > job.cellCount then
		for key in pairs( job.physKeys or {} ) do
			if SV.MarkPhysDirtyBulk then SV.MarkPhysDirtyBulk( key ) end
		end
		if SV.EndStateBulkGroup then SV.EndStateBulkGroup( job.id, SV.BlockRevision ) end
		table.remove( FillJobs, 1 )
		print( string.format(
			"[MC fill] id=%.0f volume=%d planned=%d changed=%d batches=%d scan=%.3fms apply=%.3fms elapsed=%.3fms",
			job.id, job.volume or 0, job.cellCount or 0, job.changed or 0, job.batches or 0,
			job.scanMS or 0, job.applyMS or 0, ( SysTime() - ( job.startedAt or SysTime() ) ) * 1000
		) )
		chat( job.ply, L( job.ply, "server.filled", "已填充 {count} 个方块", { count = job.changed or 0 } ) )
	end
end ) end

-- Default /fill path: mutate authoritative Chunk storage in one pass, then
-- publish the final touched Chunks as one compressed partial-world snapshot.
-- The legacy paced transaction queue above remains available only as dormant
-- compatibility code for hot reloads; runFill never enqueues into it.
local function hydrateLazyFillChunk( key )
	local store = SV.ChunkStore
	if not store or not store.IsLazyWorld or not store.IsLazyWorld() then return true end
	local stringKey = tostring( key )
	if store.LoadedKeys and store.LoadedKeys[stringKey] then return true end
	local hasBase = store.HasBaseChunk and store.HasBaseChunk( key ) or false
	local hasEdits = store.HasChunkEdits and store.HasChunkEdits( key ) or false
	if not hasBase and not hasEdits then return true end
	if not store.HydrateChunkNow then return false, "lazy_chunk_hydrator_unavailable" end
	store.LastError = nil
	store.HydrateChunkNow( key, true )
	if store.LastError then return false, store.LastError end
	return true
end

local function buildFillChunkPlans( spec )
	local plans = {}
	local changed, added, removed = 0, 0, 0
	local minCX = math.floor( spec.minx / MC.CS )
	local minCY = math.floor( spec.miny / MC.CS )
	local minCZ = math.floor( spec.minz / MC.CH )
	local maxCX = math.floor( spec.maxx / MC.CS )
	local maxCY = math.floor( spec.maxy / MC.CS )
	local maxCZ = math.floor( spec.maxz / MC.CH )
	for cz = minCZ, maxCZ do
		for cy = minCY, maxCY do
			for cx = minCX, maxCX do
				local key = MC.ChunkKey( cx, cy, cz )
				local hydrated, hydrateError = hydrateLazyFillChunk( key )
				if not hydrated then return nil, hydrateError end
				local chunk = MC.GetChunkByKey( key )
				if chunk or spec.stateId ~= 0 then
					local x0 = math.max( spec.minx, cx * MC.CS )
					local x1 = math.min( spec.maxx, cx * MC.CS + MC.CS - 1 )
					local y0 = math.max( spec.miny, cy * MC.CS )
					local y1 = math.min( spec.maxy, cy * MC.CS + MC.CS - 1 )
					local z0 = math.max( spec.minz, cz * MC.CH )
					local z1 = math.min( spec.maxz, cz * MC.CH + MC.CH - 1 )
					local changes = {}
					for bz = z0, z1 do
						local lz = bz - cz * MC.CH
						for by = y0, y1 do
							local ly = by - cy * MC.CS
							local row = ly * MC.CS + lz * MC.CS * MC.CS
							for bx = x0, x1 do
								local li = bx - cx * MC.CS + row
								local oldStateId = chunk and MC.GetChunkBlockStateByLocalIndex( chunk, li ) or 0
								if oldStateId == nil then return nil, "fill_state_read_failed" end
								if oldStateId ~= spec.stateId then
									local blocked = oldStateId == 0 and spec.stateId ~= 0
										and SV.PlacementWouldTrapPlayer
										and SV.PlacementWouldTrapPlayer( bx, by, bz, spec.blockId, spec.orient )
									if not blocked then
										changes[#changes + 1] = li
										changes[#changes + 1] = oldStateId
										changed = changed + 1
										if oldStateId == 0 then added = added + 1 end
										if spec.stateId == 0 then removed = removed + 1 end
									end
								end
							end
						end
					end
					if #changes > 0 then
						plans[#plans + 1] = {
							cx = cx, cy = cy, cz = cz, key = key,
							chunk = chunk, changes = changes,
						}
					end
				end
			end
		end
	end
	return plans, { changed = changed, added = added, removed = removed }
end

local function addFillPhysNeighbours( keys, cx, cy, cz )
	keys[MC.ChunkKey( cx, cy, cz )] = true
	keys[MC.ChunkKey( cx - 1, cy, cz )] = true
	keys[MC.ChunkKey( cx + 1, cy, cz )] = true
	keys[MC.ChunkKey( cx, cy - 1, cz )] = true
	keys[MC.ChunkKey( cx, cy + 1, cz )] = true
end

local function commitFillChunkPlans( plans, stats, spec, jobId )
	local patchRefs = {}
	local physKeys = {}
	for _, plan in ipairs( plans ) do
		local chunk = plan.chunk
		if not chunk then chunk = MC.EnsureChunk( plan.cx, plan.cy, plan.cz ) end
		local oldEnt = chunk and chunk.ent
		for index = 1, #plan.changes, 2 do
			local cellChanged, oldOrError = MC.SetChunkLocalStateRaw(
				chunk, plan.changes[index], spec.stateId, plan.changes[index + 1] )
			if cellChanged ~= true then return nil, oldOrError or "fill_state_write_failed" end
		end
		MC.FinalizeChunkStateStorage( chunk )
		if SV.ChunkStore and SV.ChunkStore.RecordChunkStateEdits then
			SV.ChunkStore.RecordChunkStateEdits( plan.key, plan.changes, spec.stateId )
		end
		if chunk.count and chunk.count > 0 then
			SV.EnsureChunkEnt( chunk )
			plan.chunk = chunk
		else
			MC.World[plan.key] = nil
			if IsValid( oldEnt ) then oldEnt:Remove() end
			plan.chunk = nil
		end
		addFillPhysNeighbours( physKeys, plan.cx, plan.cy, plan.cz )
		patchRefs[#patchRefs + 1] = {
			patchRef = true,
			cx = plan.cx, cy = plan.cy, cz = plan.cz,
			chunk = plan.chunk,
		}
	end

	SV.BlockCount = math.max( 0, ( SV.BlockCount or 0 ) + stats.added - stats.removed )
	for key in pairs( physKeys ) do
		local chunk = MC.GetChunkByKey( key )
		if chunk and chunk.count and chunk.count > 0 then
			SV.EnsureChunkEnt( chunk )
			if SV.MarkPhysDirtyBulk then SV.MarkPhysDirtyBulk( key ) end
		end
	end
	if MC.ClearAllBlockConnectionMaskCaches then MC.ClearAllBlockConnectionMaskCaches() end
	SV.StreamInterestDirty = true
	SV.Dirty = true

	local generationRotated = false
	if MC.Net and ( SV.BlockRevision or 0 ) >= MC.Net.MAX_REVISION and SV.AdvanceWorldGeneration then
		SV.AdvanceWorldGeneration( true )
		generationRotated = true
	end
	SV.BlockRevision = ( SV.BlockRevision or 0 ) + 1
	local revision = SV.BlockRevision
	if generationRotated and SV.BeginSync then
		for _, target in ipairs( player.GetAll() ) do SV.BeginSync( target ) end
		return { revision = revision, parts = 0, bytes = 0, recipients = 0, netMS = 0, resync = true }
	end
	if not SV.QueueStateChunkHydration then
		if SV.BeginSync then for _, target in ipairs( player.GetAll() ) do SV.BeginSync( target ) end end
		return { revision = revision, parts = 0, bytes = 0, recipients = 0, netMS = 0,
			resync = true, fallbackReason = "chunk_hydration_transport_unavailable" }
	end
	local netStarted = SysTime()
	local queued, recipients, parts, bytes = SV.QueueStateChunkHydration( patchRefs, revision, jobId )
	local netMS = ( SysTime() - netStarted ) * 1000
	if queued ~= true then
		if SV.BeginSync then for _, target in ipairs( player.GetAll() ) do SV.BeginSync( target ) end end
		return { revision = revision, parts = 0, bytes = 0, recipients = 0, netMS = netMS,
			resync = true, fallbackReason = recipients or "chunk_hydration_queue_failed" }
	end
	return {
		revision = revision,
		parts = parts or 0,
		bytes = bytes or 0,
		recipients = recipients or 0,
		netMS = netMS,
	}
end

local function runFullSpeedFill( spec )
	local startedAt = SysTime()
	local scanStarted = SysTime()
	local plans, statsOrError = buildFillChunkPlans( spec )
	local scanMS = ( SysTime() - scanStarted ) * 1000
	if not plans then return nil, statsOrError end
	local stats = statsOrError
	local maxBlocks = C.MaxBlocks:GetInt()
	if spec.stateId ~= 0 and maxBlocks > 0 and SV.BlockCount + stats.added > maxBlocks then
		return nil, "max_blocks"
	end
	if stats.changed <= 0 then
		return {
			changed = 0, chunks = 0, scanMS = scanMS,
			applyMS = 0, netMS = 0, elapsedMS = ( SysTime() - startedAt ) * 1000,
			parts = 0, bytes = 0, recipients = 0,
		}
	end

	local applyStarted = SysTime()
	local network, commitError = commitFillChunkPlans( plans, stats, spec, nextFillJobId() )
	local applyMS = ( SysTime() - applyStarted ) * 1000
	if not network then return nil, commitError end
	return {
		changed = stats.changed,
		chunks = #plans,
		added = stats.added,
		removed = stats.removed,
		scanMS = scanMS,
		applyMS = applyMS,
		netMS = network.netMS or 0,
		elapsedMS = ( SysTime() - startedAt ) * 1000,
		revision = network.revision,
		parts = network.parts,
		bytes = network.bytes,
		recipients = network.recipients,
		fallbackReason = network.fallbackReason,
	}
end

-- Public programmatic fill: the /fill engine (raw chunk writes + one
-- compressed hydration publish; block handlers do NOT run for filled cells).
-- Coordinates are inclusive cell bounds in any order. stateId 0 clears.
-- options: actor (attribution + event), ignoreVolumeLimit (skip mc_fill_max).
-- Returns the fill result table { changed, chunks, added, removed, revision,
-- ... } or nil, err ("invalid_state" | "world_limit" | "fill_too_large" |
-- "max_blocks" | commit errors).
function SV.FillVolume( x1, y1, z1, x2, y2, z2, stateId, options )
	options = istable( options ) and options or {}
	x1, y1, z1 = tonumber( x1 ), tonumber( y1 ), tonumber( z1 )
	x2, y2, z2 = tonumber( x2 ), tonumber( y2 ), tonumber( z2 )
	if not x1 or not y1 or not z1 or not x2 or not y2 or not z2 then return nil, "invalid_cell" end
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 0 or ( stateId ~= 0 and ( not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) ) ) then
		return nil, "invalid_state"
	end
	local blockId, orient = 0, 0
	if stateId ~= 0 and MC.LegacyFromState then
		local id, legacyOrient = MC.LegacyFromState( stateId )
		blockId, orient = id or 0, legacyOrient or 0
	end

	local minx, maxx = math.min( math.floor( x1 ), math.floor( x2 ) ), math.max( math.floor( x1 ), math.floor( x2 ) )
	local miny, maxy = math.min( math.floor( y1 ), math.floor( y2 ) ), math.max( math.floor( y1 ), math.floor( y2 ) )
	local minz, maxz = math.min( math.floor( z1 ), math.floor( z2 ) ), math.max( math.floor( z1 ), math.floor( z2 ) )
	if not SV.WorldBoundsOK( minx, miny, minz ) or not SV.WorldBoundsOK( maxx, maxy, maxz ) then
		return nil, "world_limit"
	end

	local volume = ( maxx - minx + 1 ) * ( maxy - miny + 1 ) * ( maxz - minz + 1 )
	if options.ignoreVolumeLimit ~= true then
		local fillMax = C.FillMax and C.FillMax:GetInt() or 32768
		if fillMax > 0 and volume > fillMax then return nil, "fill_too_large" end
	end

	local result, fillError = runFullSpeedFill( {
		minx = minx, maxx = maxx,
		miny = miny, maxy = maxy,
		minz = minz, maxz = maxz,
		blockId = blockId, orient = orient, stateId = stateId,
		volume = volume,
	} )
	if not result then return nil, fillError end

	print( string.format(
		"[MC fill] mode=chunk-hydration volume=%d changed=%d chunks=%d revision=%d scan=%.3fms apply=%.3fms netpack=%.3fms parts=%d bytes=%d recipients=%d elapsed=%.3fms",
		volume, result.changed or 0, result.chunks or 0, result.revision or SV.BlockRevision or 0,
		result.scanMS or 0, result.applyMS or 0, result.netMS or 0,
		result.parts or 0, result.bytes or 0, result.recipients or 0, result.elapsedMS or 0
	) )
	if result.fallbackReason then
		print( "[MC fill] Chunk hydration fell back to full client resync: " .. tostring( result.fallbackReason ) )
	end
	if ( result.changed or 0 ) > 0 and SV.FlushLightingCaches then SV.FlushLightingCaches() end
	if ( result.changed or 0 ) > 0 and MC.RunEvent then
		MC.RunEvent( "MC.WorldFilled", {
			x1 = minx, y1 = miny, z1 = minz,
			x2 = maxx, y2 = maxy, z2 = maxz,
			stateId = stateId,
			changed = result.changed,
		}, options.actor )
	end
	return result
end

local function runFill( ply, args )
	if #args < 8 then sendFillUsage( ply ) return end
	if not SV.CanEdit( ply ) then return end

	local x1, y1, z1 = tonumber( args[2] ), tonumber( args[3] ), tonumber( args[4] )
	local x2, y2, z2 = tonumber( args[5] ), tonumber( args[6] ), tonumber( args[7] )
	local id, orient, blockArg, parseErr = MC.ParseBlockSpec( trimArg( joinArgs( args, 8 ) ) )
	if not x1 or not y1 or not z1 or not x2 or not y2 or not z2 or id == nil or parseErr == "block" then
		sendFillUsage( ply )
		return
	end
	if parseErr == "state" then
		chat( ply, L( ply, "server.invalid_state", "方块状态不合法: {block}", { block = blockArg } ) )
		return
	end
	local stateId, stateExact, stateError = MC.StateFromLegacy( id, id == 0 and 0 or orient )
	if stateId == nil or stateExact ~= true then
		chat( ply, L( ply, "server.invalid_state", "方块状态不合法: {block}", { block = blockArg or stateError or "?" } ) )
		return
	end

	local result, fillError = SV.FillVolume( x1, y1, z1, x2, y2, z2, stateId, { actor = ply } )
	if not result then
		if fillError == "world_limit" then
			chat( ply, L( ply, "server.world_limit", "超出建造范围 (mc_world_limit)" ) )
		elseif fillError == "fill_too_large" then
			local volume = ( math.abs( math.floor( x2 ) - math.floor( x1 ) ) + 1 )
				* ( math.abs( math.floor( y2 ) - math.floor( y1 ) ) + 1 )
				* ( math.abs( math.floor( z2 ) - math.floor( z1 ) ) + 1 )
			local fillMax = C.FillMax and C.FillMax:GetInt() or 32768
			chat( ply, L( ply, "server.fill_too_large", "填充范围太大 ({volume} > mc_fill_max {max})", { volume = volume, max = fillMax } ) )
		elseif fillError == "max_blocks" then
			chat( ply, L( ply, "server.fill_max_blocks", "Fill would exceed mc_max_blocks" ) )
		else
			chat( ply, "Fill failed: " .. tostring( fillError or "unknown_error" ) )
		end
		return
	end
	chat( ply, L( ply, "server.filled", "Filled {count} blocks", { count = result.changed or 0 } ) )
end

hook.Add( "PlayerSay", "mc_fill_command", function( ply, text )
	local args = string.Explode( "%s+", string.Trim( text ), true )
	if not args[1] then return end
	local cmd = string.lower( args[1] )
	if cmd == "/fill" or cmd == "!fill" or cmd == "fill" then
		runFill( ply, args )
		return ""
	end
end )

concommand.Add( "mc_fill", function( ply, _, args )
	runFill( ply, copyConsoleArgsWithCommand( "mc_fill", args ) )
end )
