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
}

local function positiveConVar( convar, fallback )
	local value = convar and convar:GetInt() or fallback
	if value < 1 then return fallback end
	return value
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
	if MC.HasBlockUpdateHandlers and not MC.HasBlockUpdateHandlers( kind ) then return false, "no_update_handlers" end
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
			existing.sourceX, existing.sourceY, existing.sourceZ = false, false, false
		end
		Stats.deduplicated = Stats.deduplicated + 1
		return false, "duplicate_update"
	end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
	local handler = MC.BlockUpdateHandlerForState and MC.BlockUpdateHandlerForState( stateId ) or nil
	local callbackName = MC.BlockUpdateCallbackName and MC.BlockUpdateCallbackName( kind ) or nil
	if not handler or not callbackName or not handler[callbackName] then
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
	if MC.HasBlockUpdateHandlers and not MC.HasBlockUpdateHandlers( Kind.NEIGHBOR ) then return 0 end
	local added, seen = 0, {}
	local function add( bx, by, bz, sourceX, sourceY, sourceZ )
		local key = MC.CellKey( bx, by, bz )
		if seen[key] then return end
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

local function processEntry( entry )
	local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
	if entry.expectedStateId ~= nil and stateId ~= entry.expectedStateId then
		Stats.stale = Stats.stale + 1
		return 0
	end
	local handler = MC.BlockUpdateHandlerForState and MC.BlockUpdateHandlerForState( stateId ) or nil
	local callbackName = MC.BlockUpdateCallbackName and MC.BlockUpdateCallbackName( entry.kind ) or nil
	local callback = handler and callbackName and handler[callbackName] or nil
	if not callback then
		Stats.noHandler = Stats.noHandler + 1
		return 0
	end

	local context = {
		bx = entry.bx, by = entry.by, bz = entry.bz,
		stateId = stateId,
		kind = entry.kind,
		depth = entry.depth,
		revision = entry.revision,
		logicTick = LogicTick,
		sourceX = entry.sourceX, sourceY = entry.sourceY, sourceZ = entry.sourceZ,
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
	applyAfterTransaction( result, transaction )
	applyReturnedUpdates( result, entry )
	applyReturnedSchedules( result, entry )
	return cellCount
end

local function runLogicTick()
	LogicTick = LogicTick + 1
	promoteDueScheduled()

	local maxUpdates = positiveConVar( cvMaxUpdates, DEFAULT_MAX_UPDATES )
	local maxCells = positiveConVar( cvMaxCells, DEFAULT_MAX_CELLS )
	local processed, submittedCells = 0, 0
	while processed < maxUpdates and submittedCells < maxCells do
		local entry = popReady()
		if not entry then break end
		processed = processed + 1
		submittedCells = submittedCells + processEntry( entry )
	end
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
