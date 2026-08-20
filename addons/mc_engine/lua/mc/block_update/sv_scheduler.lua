--[[----------------------------------------------------------------------------
	MC : authoritative block update scheduler.

	Transactions enqueue work; callbacks run later and return transaction cells.
	This prevents recursive world writes while supporting neighbor propagation and
	Minecraft-style delayed ticks for fluids, redstone and future block behavior.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local Kind = MC.BlockUpdateKind
if not Kind then error( "MC block update registry is unavailable" ) end

local TICKS_PER_SECOND = 20
local TICK_INTERVAL = 1 / TICKS_PER_SECOND
local DEFAULT_MAX_UPDATES = 4096
local DEFAULT_MAX_CELLS = 16384
local DEFAULT_MAX_DEPTH = 64
local DEFAULT_MAX_QUEUE = 262144
local DEFAULT_RANDOM_TICK_SPEED = 3
local DEFAULT_RANDOM_MAX_SECTIONS = 1024
local DEFAULT_RANDOM_MAX_SAMPLES = 4096
local DEFAULT_RANDOM_MAX_CALLBACKS = 1024
local RANDOM_SECTION_HEIGHT = 16
local RANDOM_SECTION_COUNT = math.max( 1, math.floor( ( MC.CH or 32 ) / RANDOM_SECTION_HEIGHT ) )

local cvEnabled = MC.Config and MC.Config.BlockUpdatesEnabled
	or GetConVar( "mc_block_updates_enabled" )
local cvMaxUpdates = CreateConVar( "mc_block_update_max_per_tick", tostring( DEFAULT_MAX_UPDATES ), FCVAR_ARCHIVE,
	"Maximum block update callbacks processed per 20 TPS logic tick." )
local cvMaxCells = CreateConVar( "mc_block_update_max_cells_per_tick", tostring( DEFAULT_MAX_CELLS ), FCVAR_ARCHIVE,
	"Soft maximum transaction cells produced by block updates per logic tick." )
local cvMaxDepth = CreateConVar( "mc_block_update_max_depth", tostring( DEFAULT_MAX_DEPTH ), FCVAR_ARCHIVE,
	"Maximum asynchronous neighbor-update cascade depth." )
local cvMaxQueue = CreateConVar( "mc_block_update_max_queue", tostring( DEFAULT_MAX_QUEUE ), FCVAR_ARCHIVE,
	"Maximum combined ready and scheduled block updates." )
local cvRandomTickSpeed = CreateConVar( "mc_random_tick_speed", tostring( DEFAULT_RANDOM_TICK_SPEED ), FCVAR_ARCHIVE,
	"Minecraft randomTickSpeed samples per eligible 16x16x16 section each 20 TPS tick.", 0, 4096 )
local cvRandomMaxSections = CreateConVar( "mc_random_tick_max_sections_per_tick",
	tostring( DEFAULT_RANDOM_MAX_SECTIONS ), FCVAR_ARCHIVE,
	"Maximum loaded 16x16x16 sections inspected by the random-tick producer per logic tick.", 0, 65536 )
local cvRandomMaxSamples = CreateConVar( "mc_random_tick_max_samples_per_tick",
	tostring( DEFAULT_RANDOM_MAX_SAMPLES ), FCVAR_ARCHIVE,
	"Maximum block positions sampled by the random-tick producer per logic tick.", 0, 262144 )
local cvRandomMaxCallbacks = CreateConVar( "mc_random_tick_max_callbacks_per_tick",
	tostring( DEFAULT_RANDOM_MAX_CALLBACKS ), FCVAR_ARCHIVE,
	"Maximum sampled random-tick cells dispatched per logic tick; also counts against mc_block_update_max_per_tick.",
	0, 65536 )

local Ready = {}
local ReadyHead = 1
local ReadyTail = 0
local ReadyCount = 0
local ReadyByKind = {}

local ScheduledHeap = {}
local ScheduledByKind = {}
local ScheduledCount = 0
local Sequence = 0
local LogicTick = 0
local Running = false
local RandomChunkCursor = nil
local RandomSectionCursor = RANDOM_SECTION_COUNT
local RandomTickValue = bit.tobit( math.random( 0, 2147483647 ) )
local LastRandom = {
	sectionVisits = 0,
	eligibleSections = 0,
	samples = 0,
	hits = 0,
	callbacks = 0,
	submittedCells = 0,
}

local Stats = {
	enqueued = 0,
	deduplicated = 0,
	scheduled = 0,
	rescheduledEarlier = 0,
	cancelled = 0,
	processed = 0,
	noHandler = 0,
	stale = 0,
	errors = 0,
	transactions = 0,
	transactionFailures = 0,
	changedCells = 0,
	droppedDepth = 0,
	droppedQueue = 0,
	droppedResultCells = 0,
	randomSectionVisits = 0,
	randomEligibleSections = 0,
	randomSamples = 0,
	randomHits = 0,
	randomCallbacks = 0,
	randomBudgetStops = 0,
	randomSectionErrors = 0,
}

local function positiveConVar( convar, fallback )
	local value = convar and convar:GetInt() or fallback
	if value < 1 then return fallback end
	return value
end

local function nonNegativeConVar( convar, fallback )
	local value = convar and convar:GetInt() or fallback
	return math.max( 0, math.floor( tonumber( value ) or fallback ) )
end

local function queueLimit()
	return positiveConVar( cvMaxQueue, DEFAULT_MAX_QUEUE )
end

local function updatesEnabled()
	return not cvEnabled or cvEnabled:GetBool()
end

local function depthLimit()
	return positiveConVar( cvMaxDepth, DEFAULT_MAX_DEPTH )
end

local function pendingMap( root, kind )
	local map = root[kind]
	if not map then
		map = {}
		root[kind] = map
	end
	return map
end

local function combinedQueueCount()
	return ReadyCount + ScheduledCount
end

local function enqueueReady( bx, by, bz, kind, depth, revision, expectedStateId, knownKey, sourceX, sourceY, sourceZ )
	if not updatesEnabled() then return false, "block_updates_disabled" end
	kind = math.floor( tonumber( kind ) or 0 )
	if not MC.IsBlockUpdateKind or not MC.IsBlockUpdateKind( kind ) then return false, "invalid_update_kind" end
	if MC.HasBlockUpdateListeners and not MC.HasBlockUpdateListeners( kind ) then return false, "no_update_handlers" end
	depth = math.max( 0, math.floor( tonumber( depth ) or 0 ) )
	if depth > depthLimit() then
		Stats.droppedDepth = Stats.droppedDepth + 1
		return false, "update_depth_limit"
	end

	local key = knownKey or MC.CellKey( bx, by, bz )
	local byCell = pendingMap( ReadyByKind, kind )
	local existing = byCell[key]
	if existing then
		if depth < existing.depth then existing.depth = depth end
		if revision and ( not existing.revision or revision > existing.revision ) then existing.revision = revision end
		if existing.sourceX == nil then
			existing.sourceX, existing.sourceY, existing.sourceZ = sourceX, sourceY, sourceZ
		elseif existing.sourceX ~= sourceX or existing.sourceY ~= sourceY or existing.sourceZ ~= sourceZ then
			local sources = existing.sources
			if not sources then
				sources = { { existing.sourceX, existing.sourceY, existing.sourceZ } }
				existing.sources = sources
			end
			local duplicate = false
			for index = 1, #sources do
				local source = sources[index]
				if source[1] == sourceX and source[2] == sourceY and source[3] == sourceZ then
					duplicate = true
					break
				end
			end
			if not duplicate and #sources < 32 then sources[#sources + 1] = { sourceX, sourceY, sourceZ } end
			existing.sourceX, existing.sourceY, existing.sourceZ = false, false, false
		end
		Stats.deduplicated = Stats.deduplicated + 1
		return false, "duplicate_update"
	end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
	if not MC.BlockStateHasUpdateListener or not MC.BlockStateHasUpdateListener( stateId, kind ) then
		Stats.noHandler = Stats.noHandler + 1
		return false, "no_update_handler"
	end
	if combinedQueueCount() >= queueLimit() then
		Stats.droppedQueue = Stats.droppedQueue + 1
		return false, "update_queue_limit"
	end

	ReadyTail = ReadyTail + 1
	local entry = {
		bx = bx, by = by, bz = bz,
		key = key,
		kind = kind,
		depth = depth,
		revision = revision,
		expectedStateId = expectedStateId,
		sourceX = sourceX, sourceY = sourceY, sourceZ = sourceZ,
	}
	Ready[ReadyTail] = entry
	byCell[key] = entry
	ReadyCount = ReadyCount + 1
	Stats.enqueued = Stats.enqueued + 1
	return true
end

local function popReady()
	if ReadyCount <= 0 then return nil end
	local entry = Ready[ReadyHead]
	Ready[ReadyHead] = nil
	ReadyHead = ReadyHead + 1
	ReadyCount = ReadyCount - 1
	local byCell = ReadyByKind[entry.kind]
	if byCell and byCell[entry.key] == entry then byCell[entry.key] = nil end
	if ReadyCount == 0 then
		ReadyHead = 1
		ReadyTail = 0
	end
	return entry
end

local function scheduledLess( left, right )
	if left.dueTick ~= right.dueTick then return left.dueTick < right.dueTick end
	return left.sequence < right.sequence
end

local function heapSwap( leftIndex, rightIndex )
	local left = ScheduledHeap[leftIndex]
	local right = ScheduledHeap[rightIndex]
	ScheduledHeap[leftIndex], ScheduledHeap[rightIndex] = right, left
	right.heapIndex = leftIndex
	left.heapIndex = rightIndex
end

local function heapUp( index )
	while index > 1 do
		local parent = math.floor( index / 2 )
		if not scheduledLess( ScheduledHeap[index], ScheduledHeap[parent] ) then break end
		heapSwap( index, parent )
		index = parent
	end
end

local function heapDown( index )
	local count = #ScheduledHeap
	while true do
		local left = index * 2
		if left > count then break end
		local right = left + 1
		local smallest = left
		if right <= count and scheduledLess( ScheduledHeap[right], ScheduledHeap[left] ) then smallest = right end
		if not scheduledLess( ScheduledHeap[smallest], ScheduledHeap[index] ) then break end
		heapSwap( index, smallest )
		index = smallest
	end
end

local function heapPush( entry )
	local index = #ScheduledHeap + 1
	ScheduledHeap[index] = entry
	entry.heapIndex = index
	heapUp( index )
end

local function heapRemoveAt( index )
	local count = #ScheduledHeap
	if index < 1 or index > count then return nil end
	local removed = ScheduledHeap[index]
	local last = ScheduledHeap[count]
	ScheduledHeap[count] = nil
	removed.heapIndex = nil
	if index < count then
		ScheduledHeap[index] = last
		last.heapIndex = index
		local parent = math.floor( index / 2 )
		if index > 1 and scheduledLess( last, ScheduledHeap[parent] ) then heapUp( index )
		else heapDown( index ) end
	end
	return removed
end

local function removeScheduledMapping( entry )
	local byCell = ScheduledByKind[entry.kind]
	if byCell and byCell[entry.key] == entry then
		byCell[entry.key] = nil
		ScheduledCount = ScheduledCount - 1
	end
end

local function promoteDueScheduled()
	while true do
		local entry = ScheduledHeap[1]
		if not entry or entry.dueTick > LogicTick then return end
		heapRemoveAt( 1 )
		removeScheduledMapping( entry )
		enqueueReady( entry.bx, entry.by, entry.bz, entry.kind, 0, entry.revision, entry.expectedStateId )
	end
end

function SV.EnqueueBlockUpdate( bx, by, bz, kind, depth, revision, sourceX, sourceY, sourceZ )
	bx = math.floor( tonumber( bx ) or 0 )
	by = math.floor( tonumber( by ) or 0 )
	bz = math.floor( tonumber( bz ) or 0 )
	return enqueueReady( bx, by, bz, kind or Kind.NEIGHBOR, depth, revision, nil, nil, sourceX, sourceY, sourceZ )
end

function SV.EnqueueTransactionNeighbours( changes, revision, depth )
	if type( changes ) ~= "table" or #changes == 0 then return 0 end
	if not updatesEnabled() then return 0 end
	if MC.HasBlockUpdateListeners and not MC.HasBlockUpdateListeners( Kind.NEIGHBOR ) then return 0 end
	local added, seen = 0, {}
	local function add( bx, by, bz, sourceX, sourceY, sourceZ )
		local key = MC.CellKey( bx, by, bz )
		if seen[key] then
			local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
			local schema = stateId and MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
			if schema and schema.name == "minecraft:observer" then
				enqueueReady( bx, by, bz, Kind.NEIGHBOR, depth, revision, nil, key, sourceX, sourceY, sourceZ )
			end
			return
		end
		seen[key] = true
		local ok = enqueueReady( bx, by, bz, Kind.NEIGHBOR, depth, revision, nil, key, sourceX, sourceY, sourceZ )
		if ok then added = added + 1 end
	end
	for index = 1, #changes do
		local change = changes[index]
		local bx, by, bz = change.bx, change.by, change.bz
		add( bx, by, bz, bx, by, bz )
		add( bx + 1, by, bz, bx, by, bz )
		add( bx - 1, by, bz, bx, by, bz )
		add( bx, by + 1, bz, bx, by, bz )
		add( bx, by - 1, bz, bx, by, bz )
		add( bx, by, bz + 1, bx, by, bz )
		add( bx, by, bz - 1, bx, by, bz )
	end
	if MC.AppendRedstoneConductorFanout then
		MC.AppendRedstoneConductorFanout( changes, add )
	end
	return added
end

function SV.ScheduleBlockTick( bx, by, bz, delayTicks, kind, expectedStateId )
	if not updatesEnabled() then return false, "block_updates_disabled" end
	bx = math.floor( tonumber( bx ) or 0 )
	by = math.floor( tonumber( by ) or 0 )
	bz = math.floor( tonumber( bz ) or 0 )
	kind = math.floor( tonumber( kind ) or Kind.SCHEDULED )
	if not MC.IsBlockUpdateKind or not MC.IsBlockUpdateKind( kind ) then return false, "invalid_update_kind" end
	delayTicks = math.max( 1, math.floor( tonumber( delayTicks ) or 1 ) )
	if expectedStateId ~= nil then
		expectedStateId = math.floor( tonumber( expectedStateId ) or -1 )
		if not MC.IsValidBlockState or not MC.IsValidBlockState( expectedStateId ) then
			return false, "invalid_expected_state"
		end
	end

	local key = MC.CellKey( bx, by, bz )
	local byCell = pendingMap( ScheduledByKind, kind )
	local dueTick = LogicTick + delayTicks
	local existing = byCell[key]
	if existing then
		if dueTick >= existing.dueTick then
			Stats.deduplicated = Stats.deduplicated + 1
			return false, "scheduled_tick_exists"
		end
		existing.dueTick = dueTick
		existing.expectedStateId = expectedStateId
		heapUp( existing.heapIndex )
		Stats.rescheduledEarlier = Stats.rescheduledEarlier + 1
		return true
	end
	if combinedQueueCount() >= queueLimit() then
		Stats.droppedQueue = Stats.droppedQueue + 1
		return false, "update_queue_limit"
	end

	Sequence = Sequence + 1
	local entry = {
		bx = bx, by = by, bz = bz,
		key = key,
		kind = kind,
		dueTick = dueTick,
		sequence = Sequence,
		expectedStateId = expectedStateId,
	}
	byCell[key] = entry
	ScheduledCount = ScheduledCount + 1
	heapPush( entry )
	Stats.scheduled = Stats.scheduled + 1
	return true
end

function SV.CancelBlockTick( bx, by, bz, kind )
	kind = math.floor( tonumber( kind ) or Kind.SCHEDULED )
	local byCell = ScheduledByKind[kind]
	if not byCell then return false end
	local key = MC.CellKey(
		math.floor( tonumber( bx ) or 0 ),
		math.floor( tonumber( by ) or 0 ),
		math.floor( tonumber( bz ) or 0 )
	)
	local entry = byCell[key]
	if not entry then return false end
	heapRemoveAt( entry.heapIndex )
	removeScheduledMapping( entry )
	Stats.cancelled = Stats.cancelled + 1
	return true
end

local function reportHandlerError( message )
	Stats.errors = Stats.errors + 1
	local output = "[MC] block update handler failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function reportSchedulerError( message )
	Stats.errors = Stats.errors + 1
	local output = "[MC] block update scheduler failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function returnedCells( result )
	if type( result ) ~= "table" then return nil end
	if type( result.cells ) == "table" then return result.cells end
	if result[1] ~= nil then return result end
	return nil
end

-- Game-layer integrations sometimes need to inspect the old state before a
-- returned transaction removes it, then publish an opaque side effect only
-- after the commit succeeds. The scheduler owns that two-phase ordering while
-- remaining independent of inventories, loot tables and entity classes.
SV.BlockUpdateResultEffects = SV.BlockUpdateResultEffects or {}
local ResultEffects = SV.BlockUpdateResultEffects

function SV.RegisterBlockUpdateResultEffect( identifier, definition )
	if type( identifier ) ~= "string" or identifier == "" or #identifier > 64 then
		return false, "invalid_result_effect_id"
	end
	if type( definition ) ~= "table" or not isfunction( definition.Prepare )
		or not isfunction( definition.Commit ) then
		return false, "invalid_result_effect"
	end
	ResultEffects[identifier] = definition
	return true
end

function SV.UnregisterBlockUpdateResultEffect( identifier )
	if type( identifier ) ~= "string" or ResultEffects[identifier] == nil then return false end
	ResultEffects[identifier] = nil
	return true
end

local function orderedResultEffectIds()
	local identifiers = {}
	for identifier in pairs( ResultEffects ) do identifiers[#identifiers + 1] = identifier end
	table.sort( identifiers )
	return identifiers
end

local function prepareReturnedEffects( result, cells )
	if type( result ) ~= "table" or type( cells ) ~= "table" then return nil end
	local prepared
	for _, identifier in ipairs( orderedResultEffectIds() ) do
		local definition = ResultEffects[identifier]
		local ok, plan = xpcall( function() return definition.Prepare( result, cells ) end, debug.traceback )
		if not ok then
			reportHandlerError( identifier .. " prepare: " .. tostring( plan ) )
		elseif plan ~= nil then
			prepared = prepared or {}
			prepared[#prepared + 1] = { identifier = identifier, definition = definition, plan = plan }
		end
	end
	return prepared
end

local function commitReturnedEffects( prepared, transaction )
	if not prepared then return end
	for index = 1, #prepared do
		local entry = prepared[index]
		local ok, commitError = xpcall( function()
			entry.definition.Commit( entry.plan, transaction )
		end, debug.traceback )
		if not ok then
			reportHandlerError( entry.identifier .. " commit: " .. tostring( commitError ) )
		end
	end
end

local function applyReturnedSchedules( result, entry )
	if type( result ) ~= "table" or type( result.schedule ) ~= "table" then return end
	for index = 1, #result.schedule do
		local request = result.schedule[index]
		if type( request ) == "table" then
			SV.ScheduleBlockTick(
				request.bx ~= nil and request.bx or entry.bx,
				request.by ~= nil and request.by or entry.by,
				request.bz ~= nil and request.bz or entry.bz,
				request.delayTicks, request.kind, request.expectedStateId
			)
		end
	end
end

local function applyReturnedUpdates( result, entry )
	if type( result ) ~= "table" or type( result.updates ) ~= "table" then return end
	for index = 1, #result.updates do
		local request = result.updates[index]
		if type( request ) == "table" then
			SV.EnqueueBlockUpdate(
				request.bx ~= nil and request.bx or entry.bx,
				request.by ~= nil and request.by or entry.by,
				request.bz ~= nil and request.bz or entry.bz,
				request.kind or Kind.NEIGHBOR,
				entry.depth + 1,
				entry.revision,
				entry.bx, entry.by, entry.bz
			)
		end
	end
end

local function applyAfterTransaction( result, transaction )
	if type( result ) ~= "table" or type( result.afterTransaction ) ~= "function" then return end
	local ok, callbackError = xpcall( function()
		result.afterTransaction( result.afterTransactionData, transaction )
	end, debug.traceback )
	if not ok then reportHandlerError( callbackError ) end
end

-- One listener invocation: run it, then apply whatever it asked for. Returns
-- the number of cells it submitted. Each listener gets its own transaction, so
-- an observer can never corrupt the primary handler's result - and a listener
-- that errors out does not stop the others.
local function runListener( callback, entry, stateId )
	local context = {
		bx = entry.bx, by = entry.by, bz = entry.bz,
		stateId = stateId,
		kind = entry.kind,
		depth = entry.depth,
		revision = entry.revision,
		logicTick = LogicTick,
		sourceX = entry.sourceX, sourceY = entry.sourceY, sourceZ = entry.sourceZ,
		sources = entry.sources,
		GetBlockState = MC.GetBlockState,
	}
	local ok, result = xpcall( function() return callback( context ) end, debug.traceback )
	if not ok then
		reportHandlerError( result )
		return 0
	end

	local cells = returnedCells( result )
	local cellCount = cells and #cells or 0
	if cellCount > positiveConVar( cvMaxCells, DEFAULT_MAX_CELLS ) then
		Stats.droppedResultCells = Stats.droppedResultCells + cellCount
		return 0
	end
	local transaction
	local returnedEffects = prepareReturnedEffects( result, cells )
	if cellCount > 0 then
		transaction = SV.ApplyBlockTransaction( cells, {
			actor = nil,
			fx = false,
			netMode = "bulk",
			updateDepth = entry.depth + 1,
			compareCollision = result.compareCollision == true,
		} )
		Stats.transactions = Stats.transactions + 1
		if not transaction or transaction.ok ~= true then
			Stats.transactionFailures = Stats.transactionFailures + 1
			return 0
		end
		Stats.changedCells = Stats.changedCells + ( transaction.changed or 0 )
	end
	commitReturnedEffects( returnedEffects, transaction )
	applyAfterTransaction( result, transaction )
	applyReturnedUpdates( result, entry )
	applyReturnedSchedules( result, entry )
	return cellCount
end

local function processEntry( entry )
	local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
	if entry.expectedStateId ~= nil and stateId ~= entry.expectedStateId then
		Stats.stale = Stats.stale + 1
		return 0
	end
	local callbackName = MC.BlockUpdateCallbackName and MC.BlockUpdateCallbackName( entry.kind ) or nil
	if not callbackName then
		Stats.noHandler = Stats.noHandler + 1
		return 0
	end
	local handler = MC.BlockUpdateHandlerForState and MC.BlockUpdateHandlerForState( stateId ) or nil
	local callback = handler and handler[callbackName] or nil
	local observers = MC.BlockUpdateObserversForState and MC.BlockUpdateObserversForState( stateId ) or nil
	if not callback and not observers then
		Stats.noHandler = Stats.noHandler + 1
		return 0
	end

	-- The block's own handler defines its canonical behavior and runs first;
	-- observers are additive and see the world the handler left behind. They are
	-- selected from the state as it was when this entry was popped, so an
	-- observer that cares whether the handler already changed the cell must
	-- re-read it through context.GetBlockState.
	local cellCount = 0
	if callback then cellCount = runListener( callback, entry, stateId ) end
	if observers then
		-- Without this the per-tick cell budget could be multiplied by the number
		-- of observers on a single cell.
		local budget = positiveConVar( cvMaxCells, DEFAULT_MAX_CELLS )
		for index = 1, #observers do
			if cellCount >= budget then break end
			local observerCallback = observers[index][callbackName]
			if observerCallback then
				cellCount = cellCount + runListener( observerCallback, entry, stateId )
			end
		end
	end
	return cellCount
end

-- Level.getBlockRandomPos in Java 26.2: randValue = randValue * 3 +
-- 1013904223 (32-bit), then x/y/z are three four-bit fields of randValue >> 2.
-- MCSWEP uses X/Y horizontally and Z vertically, so Java's Z maps to local Y
-- and Java's Y maps to local Z here.
local function nextRandomSectionCell()
	RandomTickValue = bit.tobit( RandomTickValue * 3 + 1013904223 )
	local value = bit.rshift( RandomTickValue, 2 )
	local lx = bit.band( value, 15 )
	local ly = bit.band( bit.rshift( value, 8 ), 15 )
	local lz = bit.band( bit.rshift( value, 16 ), 15 )
	local cs = MC.CS or 16
	return lx + ly * cs + lz * cs * cs, lx, ly, lz
end

-- Iterate only MC.LoadedChunkKeys, never MC.World. The cursor advances at most
-- the configured section budget each tick, so very large maps are handled over
-- multiple ticks instead of reintroducing the old whole-world scan.
local function nextLoadedRandomSection()
	local loaded = MC.LoadedChunkKeys
	if type( loaded ) ~= "table" or next( loaded ) == nil then
		RandomChunkCursor = nil
		RandomSectionCursor = RANDOM_SECTION_COUNT
		return nil
	end
	if RandomChunkCursor ~= nil and loaded[RandomChunkCursor] ~= true then
		RandomChunkCursor = nil
		RandomSectionCursor = RANDOM_SECTION_COUNT
	end
	if RandomChunkCursor ~= nil and RandomSectionCursor < RANDOM_SECTION_COUNT then
		RandomSectionCursor = RandomSectionCursor + 1
		return RandomChunkCursor, RandomSectionCursor
	end
	local key = next( loaded, RandomChunkCursor )
	if key == nil then key = next( loaded ) end
	if key == nil then return nil end
	RandomChunkCursor = key
	RandomSectionCursor = 1
	return key, RandomSectionCursor
end

local function sectionHasRandomListener( section )
	if not section or ( section.count or 0 ) <= 0 or not MC.BlockStateHasUpdateListener then return false end
	local palette = section.palette or {}
	local refCount = section.refCount or {}
	for localIndex = 0, ( section.paletteSize or #palette ) - 1 do
		if ( refCount[localIndex] or 0 ) > 0 then
			local stateId = palette[localIndex + 1] or 0
			if stateId ~= 0 and MC.BlockStateHasUpdateListener( stateId, Kind.RANDOM ) then return true end
		end
	end
	return false
end

local function resetLastRandom()
	for key in pairs( LastRandom ) do LastRandom[key] = 0 end
end

local function produceRandomTicks( callbackBudget, cellBudget )
	resetLastRandom()
	local speed = nonNegativeConVar( cvRandomTickSpeed, DEFAULT_RANDOM_TICK_SPEED )
	local maxSections = nonNegativeConVar( cvRandomMaxSections, DEFAULT_RANDOM_MAX_SECTIONS )
	local maxSamples = nonNegativeConVar( cvRandomMaxSamples, DEFAULT_RANDOM_MAX_SAMPLES )
	callbackBudget = math.max( 0, math.floor( tonumber( callbackBudget ) or 0 ) )
	cellBudget = math.max( 0, math.floor( tonumber( cellBudget ) or 0 ) )
	if speed <= 0 or maxSections <= 0 or maxSamples <= 0 or callbackBudget <= 0 or cellBudget <= 0
	or not MC.HasBlockUpdateListeners or not MC.HasBlockUpdateListeners( Kind.RANDOM ) then return 0, 0 end

	local callbacks, submittedCells = 0, 0
	local cs = MC.CS or 16
	local ch = MC.CH or 32
	local firstChunkKey, firstSectionIndex
	while LastRandom.sectionVisits < maxSections and LastRandom.samples < maxSamples
	and callbacks < callbackBudget and submittedCells < cellBudget do
		local chunkKey, sectionIndex = nextLoadedRandomSection()
		if chunkKey == nil then break end
		-- A generous budget must not make a small world random-tick repeatedly in
		-- one logic tick. Stop before the first duplicate section after a complete
		-- pass; when the budget is smaller, the persistent cursor resumes next tick.
		if firstChunkKey == nil then
			firstChunkKey, firstSectionIndex = chunkKey, sectionIndex
		elseif chunkKey == firstChunkKey and sectionIndex == firstSectionIndex then
			break
		end
		LastRandom.sectionVisits = LastRandom.sectionVisits + 1
		local chunk = MC.GetChunkByKey and MC.GetChunkByKey( chunkKey ) or nil
		if chunk and ( chunk.count or 0 ) > 0 then
			local migrated = MC.MigrateChunkStateStorage and MC.MigrateChunkStateStorage( chunk )
			if migrated then
				local section = chunk.stateSections and chunk.stateSections[sectionIndex] or nil
				if sectionHasRandomListener( section ) then
					LastRandom.eligibleSections = LastRandom.eligibleSections + 1
					local samplesThisSection = math.min( speed, maxSamples - LastRandom.samples )
					for _ = 1, samplesThisSection do
						local sectionLocalIndex, lx, ly, lz = nextRandomSectionCell()
						LastRandom.samples = LastRandom.samples + 1
						local stateId = MC.StateSection.GetFast( section, sectionLocalIndex )
						if stateId ~= 0 and MC.BlockStateHasUpdateListener( stateId, Kind.RANDOM ) then
							LastRandom.hits = LastRandom.hits + 1
							local cx, cy, cz = chunk.cx, chunk.cy, chunk.cz
							if cx == nil and MC.ChunkKeyToCoords then cx, cy, cz = MC.ChunkKeyToCoords( chunkKey ) end
							if cx ~= nil and cy ~= nil and cz ~= nil then
								local entry = {
									bx = cx * cs + lx,
									by = cy * cs + ly,
									bz = cz * ch + ( sectionIndex - 1 ) * RANDOM_SECTION_HEIGHT + lz,
									kind = Kind.RANDOM,
									depth = 0,
								}
								callbacks = callbacks + 1
								submittedCells = submittedCells + processEntry( entry )
							end
						end
						if callbacks >= callbackBudget or submittedCells >= cellBudget then break end
					end
				end
			else
				Stats.randomSectionErrors = Stats.randomSectionErrors + 1
			end
		end
	end

	LastRandom.callbacks = callbacks
	LastRandom.submittedCells = submittedCells
	Stats.randomSectionVisits = Stats.randomSectionVisits + LastRandom.sectionVisits
	Stats.randomEligibleSections = Stats.randomEligibleSections + LastRandom.eligibleSections
	Stats.randomSamples = Stats.randomSamples + LastRandom.samples
	Stats.randomHits = Stats.randomHits + LastRandom.hits
	Stats.randomCallbacks = Stats.randomCallbacks + callbacks
	if LastRandom.sectionVisits >= maxSections or LastRandom.samples >= maxSamples
	or callbacks >= callbackBudget or submittedCells >= cellBudget then
		Stats.randomBudgetStops = Stats.randomBudgetStops + 1
	end
	return callbacks, submittedCells
end

local function processReadyUntil( processed, submittedCells, updateLimit, cellLimit )
	while processed < updateLimit and submittedCells < cellLimit do
		local entry = popReady()
		if not entry then break end
		processed = processed + 1
		submittedCells = submittedCells + processEntry( entry )
	end
	return processed, submittedCells
end

local function runLogicTick()
	LogicTick = LogicTick + 1
	promoteDueScheduled()

	local maxUpdates = positiveConVar( cvMaxUpdates, DEFAULT_MAX_UPDATES )
	local maxCells = positiveConVar( cvMaxCells, DEFAULT_MAX_CELLS )
	local randomCallbackCap = math.min(
		nonNegativeConVar( cvRandomMaxCallbacks, DEFAULT_RANDOM_MAX_CALLBACKS ), maxUpdates )
	local processed, submittedCells = 0, 0
	-- Reserve the configured random share during the first ready pass. Any share
	-- the producer does not use is immediately returned to the ready queue below.
	processed, submittedCells = processReadyUntil(
		processed, submittedCells, maxUpdates - randomCallbackCap, maxCells )
	local randomProcessed, randomCells = produceRandomTicks(
		math.min( randomCallbackCap, maxUpdates - processed ), maxCells - submittedCells )
	processed = processed + randomProcessed
	submittedCells = submittedCells + randomCells
	processed, submittedCells = processReadyUntil( processed, submittedCells, maxUpdates, maxCells )
	Stats.processed = Stats.processed + processed
	return processed, submittedCells
end

function SV.RunBlockUpdateTick()
	if not updatesEnabled() then return false, "block_updates_disabled" end
	if Running then return false, "scheduler_already_running" end
	Running = true
	local ok, processed, submittedCells = xpcall( runLogicTick, debug.traceback )
	Running = false
	if not ok then
		reportSchedulerError( processed )
		return false, "scheduler_error"
	end
	return true, processed, submittedCells
end

function SV.ClearBlockUpdates( resetStats )
	Ready = {}
	ReadyHead = 1
	ReadyTail = 0
	ReadyCount = 0
	ReadyByKind = {}
	ScheduledHeap = {}
	ScheduledByKind = {}
	ScheduledCount = 0
	RandomChunkCursor = nil
	RandomSectionCursor = RANDOM_SECTION_COUNT
	resetLastRandom()
	if MC.ClearRedstoneWireRuntime then MC.ClearRedstoneWireRuntime() end
	if SV.ClearRedstoneRuntime then SV.ClearRedstoneRuntime() end
	if resetStats == true then
		for key in pairs( Stats ) do Stats[key] = 0 end
	end
	return true
end

function SV.BlockUpdateDiagnostics()
	local out = {
		enabled = updatesEnabled(),
		logicTick = LogicTick,
		ticksPerSecond = TICKS_PER_SECOND,
		ready = ReadyCount,
		scheduledPending = ScheduledCount,
		heapSize = #ScheduledHeap,
		running = Running,
		randomTickSpeed = nonNegativeConVar( cvRandomTickSpeed, DEFAULT_RANDOM_TICK_SPEED ),
		randomMaxSectionsPerTick = nonNegativeConVar( cvRandomMaxSections, DEFAULT_RANDOM_MAX_SECTIONS ),
		randomMaxSamplesPerTick = nonNegativeConVar( cvRandomMaxSamples, DEFAULT_RANDOM_MAX_SAMPLES ),
		randomMaxCallbacksPerTick = nonNegativeConVar( cvRandomMaxCallbacks, DEFAULT_RANDOM_MAX_CALLBACKS ),
		randomCursorKey = RandomChunkCursor,
		randomCursorSection = RandomSectionCursor,
		randomLast = {
			sectionVisits = LastRandom.sectionVisits,
			eligibleSections = LastRandom.eligibleSections,
			samples = LastRandom.samples,
			hits = LastRandom.hits,
			callbacks = LastRandom.callbacks,
			submittedCells = LastRandom.submittedCells,
		},
	}
	for key, value in pairs( Stats ) do out[key] = value end
	return out
end

timer.Remove( "mc_block_update_scheduler" )
timer.Create( "mc_block_update_scheduler", TICK_INTERVAL, 0, SV.RunBlockUpdateTick )

cvars.RemoveChangeCallback( "mc_block_updates_enabled", "mc_block_update_scheduler_enabled" )
cvars.AddChangeCallback( "mc_block_updates_enabled", function( _, _, newValue )
	if tonumber( newValue ) == 0 then SV.ClearBlockUpdates() end
end, "mc_block_update_scheduler_enabled" )

if not updatesEnabled() then SV.ClearBlockUpdates() end
