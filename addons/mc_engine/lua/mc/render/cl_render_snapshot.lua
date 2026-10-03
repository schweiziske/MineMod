-- Dense, section-scoped block input for the synchronous Lua mesh builder.
-- No lighting profile, material, vertex object or world-space conversion lives
-- here. Arrays are borrowed read-only by a build; do not retain them across a
-- yield or a world mutation.
MC = MC or {}
local Snapshot = MC.RenderSnapshot or {}
MC.RenderSnapshot = Snapshot

Snapshot.VERSION = 1
-- Bumped when the reverse slot map changed from chunk-local cell keys to
-- section-local compact keys. Existing caches must be rebuilt after reload.
Snapshot.INDEX_FORMAT = 4
local floor = math.floor
local CS, CH = MC.CS, MC.CH
local CS2 = CS * CS
local SIZE = MC.RENDER_SECTION_SIZE or 8
local XY = math.ceil( CS / SIZE )
local Z = math.ceil( CH / SIZE )
local TOTAL = XY * XY * Z
local STATE_CELLS = CS2 * 16
Snapshot.SECTION_COUNT = TOTAL

local function sectionForLocalIndex( li )
	local lz = floor( li / CS2 )
	local ly = floor( li / CS ) % CS
	local lx = li % CS
	return floor( lx / SIZE ) + floor( ly / SIZE ) * XY
		+ floor( lz / SIZE ) * XY * XY + 1
end

local function sectionSlotKey( li )
	local lz = floor( li / CS2 )
	local ly = floor( li / CS ) % CS
	local lx = li % CS
	return ( lx % SIZE ) + ( ly % SIZE ) * SIZE
		+ ( lz % SIZE ) * SIZE * SIZE + 1
end

local function resetIndex( chunk )
	chunk.renderSectionBlocks = {}
	chunk.renderSectionBlocksReady = {}
	chunk.renderSectionIndexVersion = chunk.collisionVersion or 0
	chunk.renderSectionIndexStoresStateId = true
	chunk.renderSectionIndexFormat = Snapshot.INDEX_FORMAT
	chunk.renderSectionIndexStorage = chunk.stateSections
	chunk.renderSectionIndexEpoch = chunk.nativeStateStorage and chunk.nativeMeshEpoch or nil
end

local function indexCurrent( chunk )
	return chunk.renderSectionBlocks ~= nil
		and chunk.renderSectionBlocksReady ~= nil
		and chunk.renderSectionIndexFormat == Snapshot.INDEX_FORMAT
		and chunk.renderSectionIndexStorage == chunk.stateSections
		and chunk.renderSectionIndexEpoch == ( chunk.nativeStateStorage and chunk.nativeMeshEpoch or nil )
		and chunk.renderSectionIndexVersion == ( chunk.collisionVersion or 0 )
end

-- Fail without publishing a ready flag. Missing state data is not an air block.
function Snapshot.EnsureSection( chunk, sectionIndex )
	if not chunk then return nil, "missing_chunk" end
	if type( sectionIndex ) ~= "number" or sectionIndex ~= floor( sectionIndex )
		or sectionIndex < 1 or sectionIndex > TOTAL then
		return nil, "invalid_section_index"
	end
	if not indexCurrent( chunk ) then resetIndex( chunk ) end
	if chunk.renderSectionBlocksReady[sectionIndex] then
		return chunk.renderSectionBlocks[sectionIndex]
	end
	if chunk.nativeStateStorage then
		local backend = MC.GetChunkBackend()
		if not backend.native or not backend.GetSectionCells or backend.Epoch() ~= chunk.nativeMeshEpoch then
			return nil, "native_section_storage_unavailable"
		end
		local cells, err = backend.GetSectionCells( chunk, sectionIndex )
		if not cells then return nil, err end
		local section = { indices = {}, states = {}, slots = {}, count = #cells / 2 }
		for i = 1, #cells, 2 do
			local li, slot = cells[i], ( i + 1 ) / 2
			section.indices[slot], section.states[slot], section.slots[sectionSlotKey( li )] = li, cells[i + 1], slot
		end
		chunk.renderSectionBlocks[sectionIndex], chunk.renderSectionBlocksReady[sectionIndex] = section, true
		return section
	end
	local stateSections = chunk.stateSections
	local stateAPI = MC.StateSection
	local getState = stateAPI and ( stateAPI.GetFast or stateAPI.Get )
	if not stateSections or not getState then return nil, "state_storage_unavailable" end

	local zero = sectionIndex - 1
	local minX = ( zero % XY ) * SIZE
	local minY = ( floor( zero / XY ) % XY ) * SIZE
	local minZ = floor( zero / ( XY * XY ) ) * SIZE
	local maxX = math.min( CS - 1, minX + SIZE - 1 )
	local maxY = math.min( CS - 1, minY + SIZE - 1 )
	local maxZ = math.min( CH - 1, minZ + SIZE - 1 )
	local indices, states, slots = {}, {}, {}
	local count = 0
	for lz = minZ, maxZ do
		local stateSection = stateSections[floor( lz / 16 ) + 1]
		-- An absent palette section is valid sparse air; an unavailable store
		-- above, or a failed cell read below, is not.
		if stateSection and ( stateSection.count or 0 ) > 0 then
			for ly = minY, maxY do
				local row = lz * CS2 + ly * CS
				for lx = minX, maxX do
					local li = row + lx
					local state = getState( stateSection, li % STATE_CELLS )
					if state == nil then return nil, "state_read_failed" end
					if state ~= 0 then
						count = count + 1
						indices[count], states[count], slots[sectionSlotKey( li )] = li, state, count
					end
				end
			end
		end
	end
	local section = { indices = indices, states = states, slots = slots, count = count }
	chunk.renderSectionBlocks[sectionIndex] = section
	chunk.renderSectionBlocksReady[sectionIndex] = true
	return section
end

function Snapshot.EnsureChunk( chunk )
	for i = 1, TOTAL do
		local section, err = Snapshot.EnsureSection( chunk, i )
		if not section then return nil, err end
	end
	return chunk.renderSectionBlocks
end

function Snapshot.Prepare( chunk, sectionIndex )
	if not chunk then return nil, "missing_chunk" end
	if not chunk.stateStorageMigrated and not chunk.nativeStateStorage then
		if not MC.MigrateChunkStateStorage then return nil, "state_migration_unavailable" end
		local ok, err = MC.MigrateChunkStateStorage( chunk )
		if not ok then return nil, err or "state_migration_failed" end
	end
	if sectionIndex then
		local section, err = Snapshot.EnsureSection( chunk, sectionIndex )
		if not section then return nil, err end
		return chunk.renderSectionBlocks
	end
	return Snapshot.EnsureChunk( chunk )
end

-- Called after a single-cell write and collision-version publication. A
-- previous-version check prevents one edit from blessing unrelated stale data.
-- Dense removal swaps the tail into the gap: no shifting, sorting or allocation.
function Snapshot.UpdateCell( chunk, li, stateId, previousVersion )
	if not chunk or not chunk.renderSectionBlocks then return end
	if chunk.renderSectionIndexFormat ~= Snapshot.INDEX_FORMAT
		or chunk.renderSectionIndexStorage ~= chunk.stateSections
		or chunk.renderSectionIndexEpoch ~= ( chunk.nativeStateStorage and chunk.nativeMeshEpoch or nil )
		or chunk.renderSectionIndexVersion ~= previousVersion then
		resetIndex( chunk )
		return
	end
	local sectionIndex = sectionForLocalIndex( li )
	local section = chunk.renderSectionBlocks[sectionIndex]
	if chunk.renderSectionBlocksReady[sectionIndex] and section then
		section.occlusion = nil
		local indices, states, slots = section.indices, section.states, section.slots
		local slotKey = sectionSlotKey( li )
		local slot = slots[slotKey]
		local count = section.count
		if stateId == 0 then
			if slot then
				local tail = indices[count]
				indices[slot], states[slot] = tail, states[count]
				slots[sectionSlotKey( tail )] = slot
				indices[count], states[count], slots[slotKey] = nil, nil, nil
				section.count = count - 1
			end
		elseif slot then
			states[slot] = stateId
		else
			count = count + 1
			indices[count], states[count], slots[slotKey] = li, stateId, count
			section.count = count
		end
	end
	chunk.renderSectionIndexVersion = chunk.collisionVersion or 0
end
