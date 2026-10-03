-- Transactional block-container adapter for gameplay-parity logistics.

MC = MC or {}
MC.SV = MC.SV or {}

local L = MC.LogisticsParity or {}
local SV = MC.SV
local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local output = {}
	seen[value] = output
	for key, entry in pairs( value ) do output[copyValue( key, seen )] = copyValue( entry, seen ) end
	return output
end

local function deepEqual( left, right, seen, keyName )
	if keyName == "dirty" then return true end
	if left == right then return true end
	if type( left ) ~= type( right ) or type( left ) ~= "table" then return false end
	seen = seen or {}
	if seen[left] == right then return true end
	seen[left] = right
	for key, value in pairs( left ) do if not deepEqual( value, right[key], seen, key ) then return false end end
	for key in pairs( right ) do if key ~= "dirty" and left[key] == nil then return false end end
	return true
end

local function copyStorage( storage, size )
	local output = {}
	for slot = 1, math.max( 0, math.floor( tonumber( size ) or 0 ) ) do
		output[slot] = MC.CopyItemStack( type( storage ) == "table" and storage[slot] or nil )
	end
	return output
end

local function recordEnvelope( original, rebuilt )
	local record = copyValue( original or {} )
	record.type, record.codecVersion, record.data = rebuilt.type, rebuilt.codecVersion, rebuilt.data
	record.revision = math.max( 0, math.floor( tonumber( original and original.revision ) or 0 ) ) + 1
	record.dirty = true
	return record
end

local function stateAndRecordAt( bx, by, bz )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	local record = World.GetBlockEntity and World.GetBlockEntity( bx, by, bz ) or nil
	return stateId, record
end

local function revisionStamp( record )
	return type( record ) == "table" and record.revision ~= nil and record.revision or false
end

local function persistedRuntimeRecordAt( runtime, bx, by, bz )
	local record = World.GetBlockEntity and World.GetBlockEntity( bx, by, bz ) or nil
	if type( record ) ~= "table" then return nil, "container_persisted_record_missing" end
	local expected = type( runtime ) == "table" and runtime.persistedRevision or nil
	if expected == nil then expected = revisionStamp( runtime and runtime.record ) end
	if revisionStamp( record ) ~= expected then return nil, "stale_container" end
	return record
end

local function physicalEntry( bx, by, bz, stateId, record )
	return { bx = bx, by = by, bz = bz, stateId = stateId, record = copyValue( record ) }
end

local function ensureLogisticsRecord( bx, by, bz, stateId, create )
	local record = World.GetBlockEntity and World.GetBlockEntity( bx, by, bz ) or nil
	if record or create == false then return record end
	if not Blocks.CreateDefaultBlockEntity or not World.SetBlockEntity then return nil end
	local created = Blocks.CreateDefaultBlockEntity( stateId )
	if type( created ) ~= "table" then return nil end
	local written = World.SetBlockEntity( bx, by, bz, created, { reason = "logistics_default" } )
	if written ~= true then return nil end
	-- The engine commits a private copy and stamps its world revision during
	-- the transaction.  Re-read that authoritative record so the first
	-- container transaction cannot fail its stale check against the unstamped
	-- pre-write value.
	local persisted = World.GetBlockEntity and World.GetBlockEntity( bx, by, bz ) or nil
	return type( persisted ) == "table" and persisted or created
end

local function markChanged( container, slot )
	container.changed = true
	container.changedSlotSet[slot] = true
end

function L.ChangedSlots( container )
	local slots = {}
	for slot in pairs( container and container.changedSlotSet or {} ) do slots[#slots + 1] = slot end
	table.sort( slots )
	return slots
end

local function containerBase( kind, bx, by, bz, size, storage, face )
	return {
		kind = kind, bx = bx, by = by, bz = bz, size = size,
		storage = copyStorage( storage, size ), accessDirection = L.NormalizeDirection( face ),
		changed = false, changedSlotSet = {}, stateChanged = false,
	}
end

local function logisticsContainerAt( bx, by, bz, stateId, definition, face, options )
	local record = ensureLogisticsRecord( bx, by, bz, stateId, options.create ~= false )
	if not record or record.type ~= definition.type then return nil, "logistics_data_missing" end
	local storage, storageError = L.StorageFromRecord( record )
	if not storage then return nil, storageError end
	local container = containerBase( definition.kind, bx, by, bz, definition.slots, storage, face )
	container.adapter, container.type = "logistics", definition.type
	container.state = copyValue( record.data or {} )
	container.physical = { physicalEntry( bx, by, bz, stateId, record ) }
	return container
end

local function chestContainerAt( bx, by, bz, face )
	if not SV.LogisticsChestContainerAt then return nil, "chest_adapter_unavailable" end
	local raw, err = SV.LogisticsChestContainerAt( bx, by, bz )
	if not raw then return nil, err end
	local container = containerBase( "chest", bx, by, bz, raw.size, raw.storage, face )
	container.adapter, container.raw, container.physical = "chest", raw, {}
	for _, entry in ipairs( raw.records or {} ) do
		local position = entry.position
		local stateId = World.GetBlockState and World.GetBlockState( position.bx, position.by, position.bz ) or 0
		container.physical[#container.physical + 1] = physicalEntry(
			position.bx, position.by, position.bz, stateId, entry.record )
	end
	return container
end

local function furnaceContainerAt( bx, by, bz, stateId, face, options )
	if not SV.LogisticsFurnaceRuntimeAt then return nil, "furnace_adapter_unavailable" end
	local runtime = SV.LogisticsFurnaceRuntimeAt( bx, by, bz, options.create ~= false )
	if not runtime then return nil, "furnace_data_missing" end
	local info = MC.FurnaceStateInfo and MC.FurnaceStateInfo( stateId ) or nil
	local kind = info and info.name == "minecraft:blast_furnace" and "blast_furnace" or "furnace"
	local container = containerBase( kind, bx, by, bz, 3, runtime.storage, face )
	container.adapter, container.raw = "furnace", runtime
	container.state = {
		litTimeRemaining = runtime.litTimeRemaining, litTotalTime = runtime.litTotalTime,
		cookingTimeSpent = runtime.cookingTimeSpent, cookingTotalTime = runtime.cookingTotalTime,
		recipeUses = runtime.recipeUses,
	}
	-- Furnace/brewing progress may advance in the live runtime between periodic
	-- overlay writes.  Snapshot the persisted CAS baseline while still rebuilding
	-- the committed payload from live state.
	local persisted, persistedError = persistedRuntimeRecordAt( runtime, bx, by, bz )
	if not persisted then return nil, persistedError end
	container.physical = { physicalEntry( bx, by, bz, stateId, persisted ) }
	return container
end

local function brewingContainerAt( bx, by, bz, stateId, face, options )
	if not SV.LogisticsBrewingRuntimeAt then return nil, "brewing_adapter_unavailable" end
	local runtime = SV.LogisticsBrewingRuntimeAt( bx, by, bz, options.create ~= false )
	if not runtime then return nil, "brewing_data_missing" end
	local container = containerBase( "brewing_stand", bx, by, bz, 5, runtime.storage, face )
	container.adapter, container.raw = "brewing", runtime
	container.state = { brewTime = runtime.brewTime, fuel = runtime.fuel }
	local persisted, persistedError = persistedRuntimeRecordAt( runtime, bx, by, bz )
	if not persisted then return nil, persistedError end
	container.physical = { physicalEntry( bx, by, bz, stateId, persisted ) }
	return container
end

function L.ContainerAt( bx, by, bz, face, options )
	options = type( options ) == "table" and options or {}
	if not options.allowDisabled and not L.Enabled() then return nil, "feature_disabled" end
	bx, by, bz = tonumber( bx ), tonumber( by ), tonumber( bz )
	if not bx or not by or not bz then return nil, "invalid_cell" end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	if stateId == 0 then return nil, "not_container" end
	local definition = L.ContainerDefinitionForState and L.ContainerDefinitionForState( stateId ) or nil
	local container, err
	if definition then container, err = logisticsContainerAt( bx, by, bz, stateId, definition, face, options )
	elseif MC.IsChestState and MC.IsChestState( stateId ) then container, err = chestContainerAt( bx, by, bz, face )
	elseif MC.IsFurnaceState and MC.IsFurnaceState( stateId ) then container, err = furnaceContainerAt( bx, by, bz, stateId, face, options )
	elseif MC.IsBrewingStandState and MC.IsBrewingStandState( stateId ) then container, err = brewingContainerAt( bx, by, bz, stateId, face, options )
	elseif L.IsUnadaptedBlockContainer and L.IsUnadaptedBlockContainer( Blocks.Name and Blocks.Name( stateId ) ) then
		return nil, "container_adapter_unavailable"
	else return nil, "not_container" end
	if not container then return nil, err end
	container.analogBefore = L.ContainerAnalogOutput( container.storage, container.size )
	return container
end

function L.ContainerSlots( container, direction )
	if type( container ) ~= "table" then return {} end
	return L.SlotsForFace( container.kind, direction or container.accessDirection, container.size )
end

function L.ContainerIsEmpty( container )
	for slot = 1, container and container.size or 0 do
		if not MC.IsEmptyItemStack( container.storage[slot] ) then return false end
	end
	return true
end

function L.ContainerIsFull( container, direction )
	for _, slot in ipairs( L.ContainerSlots( container, direction ) ) do
		local stack = container.storage[slot + 1]
		if MC.IsEmptyItemStack( stack ) or stack.count < MC.ItemStackMaxCount( stack ) then return false end
	end
	return true
end

function L.CanPlaceInContainer( container, slot, stack )
	return type( container ) == "table" and slot >= 0 and slot < container.size
		and L.CanPlaceInSlot( container.kind, slot, stack, container.storage[slot + 1] ) == true
end

function L.CanTakeFromContainer( container, slot, direction )
	local stack = type( container ) == "table" and container.storage[slot + 1] or nil
	return not MC.IsEmptyItemStack( stack )
		and L.CanTakeThroughFace( container.kind, slot, stack, direction or container.accessDirection ) == true
end

local function setHopperReceiveCooldown( target, source, wasEmpty )
	if not wasEmpty or target.kind ~= "hopper" then return end
	local cooldown = tonumber( target.state and target.state.transferCooldown ) or -1
	if cooldown > ( L.Constants and L.Constants.hopperTransferCooldown or 8 ) then return end
	local skip = source and source.kind == "hopper"
		and ( tonumber( target.state.tickedGameTime ) or 0 ) >= ( tonumber( source.state and source.state.tickedGameTime ) or 0 ) and 1 or 0
	target.state.transferCooldown = ( L.Constants and L.Constants.hopperTransferCooldown or 8 ) - skip
	target.stateChanged = true
end

function L.InsertStack( container, input, direction, source )
	if type( container ) ~= "table" or MC.IsEmptyItemStack( input ) then return MC.CopyItemStack( input ), 0 end
	local remaining = MC.CopyItemStack( input )
	local movedTotal, wasEmpty = 0, L.ContainerIsEmpty( container )
	for _, slot in ipairs( L.ContainerSlots( container, direction ) ) do
		if MC.IsEmptyItemStack( remaining ) then break end
		local existing = container.storage[slot + 1]
		if L.CanPlaceInContainer( container, slot, remaining ) then
			local maximum = math.max( 1, MC.ItemStackMaxCount( remaining ) )
			local moved = 0
			if MC.IsEmptyItemStack( existing ) then
				moved = math.min( remaining.count, maximum )
				container.storage[slot + 1] = MC.CopyItemStack( remaining, moved )
			elseif MC.ItemStacksCanMerge( existing, remaining ) and existing.count <= maximum then
				moved = math.min( remaining.count, math.max( 0, maximum - existing.count ) )
				if moved > 0 then container.storage[slot + 1] = MC.CopyItemStack( existing, existing.count + moved ) end
			end
			if moved > 0 then
				movedTotal = movedTotal + moved
				remaining = remaining.count > moved and MC.CopyItemStack( remaining, remaining.count - moved ) or nil
				markChanged( container, slot )
				setHopperReceiveCooldown( container, source, wasEmpty )
				wasEmpty = false
			end
		end
	end
	return remaining, movedTotal
end

function L.TransferOne( source, target, sourceDirection, targetDirection )
	if type( source ) ~= "table" or type( target ) ~= "table" then return false end
	for _, slot in ipairs( L.ContainerSlots( source, sourceDirection ) ) do
		local stack = source.storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) and L.CanTakeFromContainer( source, slot, sourceDirection ) then
			local remaining = L.InsertStack( target, MC.CopyItemStack( stack, 1 ), targetDirection, source )
			if MC.IsEmptyItemStack( remaining ) then
				source.storage[slot + 1] = stack.count > 1 and MC.CopyItemStack( stack, stack.count - 1 ) or nil
				markChanged( source, slot )
				return true, slot
			end
		end
	end
	return false
end

local function buildContainerCells( container )
	local cells, records = {}, {}
	if container.adapter == "logistics" then
		local rebuilt, err = L.RecordFromStorage( container.type, container.storage, container.state )
		if not rebuilt then return nil, nil, err end
		records[1] = recordEnvelope( container.physical[1].record, rebuilt )
		cells[1] = { bx = container.bx, by = container.by, bz = container.bz,
			stateId = container.physical[1].stateId, blockEntity = records[1] }
	elseif container.adapter == "chest" then
		for index, entry in ipairs( container.physical ) do
			local storage, base = {}, ( index - 1 ) * 27
			for slot = 1, 27 do storage[slot] = MC.CopyItemStack( container.storage[base + slot] ) end
			local customName = entry.record.data and entry.record.data.customName
			records[index] = recordEnvelope( entry.record, MC.ChestRecordFromStorage( storage, customName ) )
			cells[index] = { bx = entry.bx, by = entry.by, bz = entry.bz,
				stateId = entry.stateId, blockEntity = records[index] }
		end
	elseif container.adapter == "furnace" then
		if container.changedSlotSet[0]
		and not MC.ItemStacksEqual( container.raw.storage[1], container.storage[1], true ) then
			local recipe = MC.FindCookingRecipe and MC.FindCookingRecipe( container.storage[1], container.raw.recipeType ) or nil
			container.state.cookingTimeSpent = 0
			container.state.cookingTotalTime = recipe and recipe.cookingTime or 0
		end
		records[1] = recordEnvelope( container.physical[1].record,
			MC.FurnaceRecordFromStorage( container.storage, container.state ) )
		cells[1] = { bx = container.bx, by = container.by, bz = container.bz,
			stateId = container.physical[1].stateId, blockEntity = records[1] }
	elseif container.adapter == "brewing" then
		local nextState = container.physical[1].stateId
		for slot = 0, 2 do
			if Blocks.WithProperty then nextState = Blocks.WithProperty( nextState, "has_bottle_" .. slot,
				not MC.IsEmptyItemStack( container.storage[slot + 1] ) ) or nextState end
		end
		records[1] = recordEnvelope( container.physical[1].record,
			MC.BrewingRecordFromStorage( container.storage, container.state ) )
		cells[1] = { bx = container.bx, by = container.by, bz = container.bz,
			stateId = nextState, blockEntity = records[1] }
	else return nil, nil, "unknown_container_adapter" end
	return cells, records
end

local function containerStillCurrent( container )
	for _, entry in ipairs( container.physical or {} ) do
		local stateId, record = stateAndRecordAt( entry.bx, entry.by, entry.bz )
		if stateId ~= entry.stateId or not deepEqual( record, entry.record ) then return false end
	end
	return true
end

local function applyCommitted( container, records )
	local changedSlots = L.ChangedSlots( container )
	if container.adapter == "chest" then
		for index, entry in ipairs( container.raw.records or {} ) do entry.record = copyValue( records[index] ) end
		for index = 1, #container.raw.records do
			local storage, base = container.raw.storages[index] or {}, ( index - 1 ) * 27
			for slot = 1, 27 do storage[slot] = MC.CopyItemStack( container.storage[base + slot] ) end
			container.raw.storages[index] = storage
		end
		container.raw.storage = copyStorage( container.storage, container.size )
		return not SV.LogisticsCommitChestContainer or SV.LogisticsCommitChestContainer(
			container.raw, { persisted = true } ) ~= false
	end
	if container.adapter == "furnace" then
		return not SV.LogisticsCommitFurnaceRuntime or SV.LogisticsCommitFurnaceRuntime( container.raw,
			changedSlots, { persisted = true, storage = container.storage, state = container.state, record = records[1] } ) ~= false
	end
	if container.adapter == "brewing" then
		return not SV.LogisticsCommitBrewingRuntime or SV.LogisticsCommitBrewingRuntime( container.raw,
			changedSlots, { persisted = true, storage = container.storage, state = container.state, record = records[1] } ) ~= false
	end
	if container.adapter == "logistics" then
		return not SV.LogisticsCommitBlockContainer
			or SV.LogisticsCommitBlockContainer( container, records[1] ) ~= false
	end
	return true
end

local function readCommittedRecords( container )
	local records = {}
	for index, entry in ipairs( container.physical or {} ) do
		local record = World.GetBlockEntity and World.GetBlockEntity( entry.bx, entry.by, entry.bz ) or nil
		if type( record ) ~= "table" then return nil, "container_persisted_record_missing" end
		records[index] = record
	end
	return records
end

local function notifyAnalogChange( container, reason )
	local output = L.ContainerAnalogOutput( container.storage, container.size )
	if output == container.analogBefore or not MC.RunEvent then return end
	for _, entry in ipairs( container.physical or {} ) do
		MC.RunEvent( "MC.BlockAnalogOutputChanged", entry.bx, entry.by, entry.bz,
			output, container.analogBefore, { reason = reason or "logistics_transfer", kind = container.kind } )
	end
	container.analogBefore = output
end

local function postCommitFault( result, container, phase, detail )
	local message = string.format( "%s at %s,%s,%s after world commit: %s",
		phase, tostring( container.bx ), tostring( container.by ), tostring( container.bz ), tostring( detail ) )
	result.postCommitErrors = result.postCommitErrors or {}
	result.postCommitErrors[#result.postCommitErrors + 1] = message
	-- Even strict faults must wait until the caller has finalized ownership of
	-- item entities / player stacks. A committed write cannot be rejected here.
	timer.Simple( 0, function()
		MC.Fault( "logistics_post_commit_" .. phase, "%s", message )
	end )
end

function L.CommitContainers( containers, reason )
	if not L.Enabled() then return false, "feature_disabled" end
	local active, activeSet, cells, cellOwners, recordsByContainer = {}, {}, {}, {}, {}
	for _, container in ipairs( containers or {} ) do
		if type( container ) == "table" and not activeSet[container]
		and ( container.changed or container.stateChanged ) then
			if not containerStillCurrent( container ) then return false, "stale_container" end
			local builtCells, records, err = buildContainerCells( container )
			if not builtCells then return false, err end
			activeSet[container] = true
			active[#active + 1], recordsByContainer[container] = container, records
			for _, cell in ipairs( builtCells ) do
				local key = tostring( cell.bx ) .. ":" .. tostring( cell.by ) .. ":" .. tostring( cell.bz )
				if cellOwners[key] and cellOwners[key] ~= container then
					-- Two independent snapshots of one physical container (possible
					-- when both halves of a double chest are reached in one Hopper
					-- tick) cannot be safely last-write-wins merged.
					return false, "overlapping_containers"
				end
				cellOwners[key] = container
				cells[#cells + 1] = cell
			end
		end
	end
	if #active == 0 then return true, { changedContainers = 0, changedCells = 0 } end
	if not World.SetBlocks then return false, "world_write_unavailable" end
	local changed, writeError = World.SetBlocks( cells, {
		reason = reason or "logistics_transfer", fx = false, blockUpdates = false, compareCollision = false,
	} )
	if not changed or changed <= 0 then return false, writeError or "container_commit_failed" end
	local result = { changedContainers = #active, changedCells = changed }
	-- SetBlocks validates, copies, and stamps the records with the authoritative
	-- world revision.  Runtime/menu mirrors must receive those persisted copies,
	-- not the pre-transaction envelopes built above.
	for _, container in ipairs( active ) do
		local called, persisted, persistedError = pcall( readCommittedRecords, container )
		if called and persisted then
			recordsByContainer[container] = persisted
		else
			recordsByContainer[container] = nil
			postCommitFault( result, container, "read", called and persistedError or persisted )
		end
	end
	for _, container in ipairs( active ) do
		if recordsByContainer[container] then
			local called, applied = pcall( applyCommitted, container, recordsByContainer[container] )
			if not called or not applied then
				postCommitFault( result, container, "apply", called and "container_apply_failed" or applied )
			end
		end
	end
	for _, container in ipairs( active ) do
		local called, err = pcall( notifyAnalogChange, container, reason )
		if not called then postCommitFault( result, container, "analog", err ) end
	end
	return true, result
end

function L.BlockAnalogOutputAt( bx, by, bz )
	if not L.Enabled() then return nil end
	-- Vanilla analog reads the block entity directly.  A valid container state
	-- without a materialized record is therefore represented by its default
	-- block entity; creation is still strictly feature-gated by L.Enabled().
	local container = L.ContainerAt( bx, by, bz, nil, { create = true } )
	if not container then return nil end
	return L.ContainerAnalogOutput( container.storage, container.size )
end

local ANALOG_BLOCK_ENTITY_TYPES = {
	"minecraft:hopper", "minecraft:dispenser", "minecraft:dropper",
	"minecraft:chest", "minecraft:furnace", "minecraft:brewing_stand",
}

local function refreshLoadedContainerComparators()
	if not World.ForEachBlockEntity or not MC.RunEvent then return end
	local seen = {}
	for _, typeName in ipairs( ANALOG_BLOCK_ENTITY_TYPES ) do
		World.ForEachBlockEntity( typeName, function( bx, by, bz )
			local key = tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
			if seen[key] then return end
			seen[key] = true
			MC.RunEvent( "MC.BlockAnalogOutputChanged", bx, by, bz, nil, nil,
				{ reason = "logistics_toggle" } )
		end )
	end
end

if hook and hook.Add then
	hook.Add( "MC.LogisticsParityEnabled", "mcgame_logistics_enabled", function() return L.Enabled() end )
	hook.Add( "MC.BlockAnalogOutputAt", "mcgame_logistics_block_analog", function( bx, by, bz )
		return L.BlockAnalogOutputAt( bx, by, bz )
	end )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_gameplay_parity_logistics", function()
		if timer and timer.Simple then timer.Simple( 0, refreshLoadedContainerComparators )
		else refreshLoadedContainerComparators() end
	end, "mcgame_logistics_comparator_refresh" )
end
