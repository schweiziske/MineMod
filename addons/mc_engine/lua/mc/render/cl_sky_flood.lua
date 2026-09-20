-- Client-side Minecraft-style voxel SKY light flood.
--
-- This replaces the old column soft-exposure kernel (cl_sky_column's ring
-- fade), which painted a hard-edged vertical pillar under every roof opening
-- that disagreed with the shadow map's directional shadow ("two shadows").
-- Minecraft shader packs (Photon / Complementary / SEUS) all treat the voxel
-- sky light as an AMBIENT term only: 15 above open sky, spreading into
-- interiors with -1 per block like torch light, 0 deep inside. Direct sun and
-- its one true shadow stay the shadow map's job; this value only scales the
-- sky-ambient contribution (and gates direct sun so fully enclosed spaces
-- never receive leaked sunlight).
--
-- Storage mirrors MC.LightBlockChunks: values are stored ONLY for cells that
-- are NOT sky-exposed (exposed cells — above their column top — are implicit
-- level 15 and never stored; the BFS reads them as constant sources). Chunk
-- loads/unloads and exposure flips re-flood through an amortized queue.
MC = MC or {}

MC.LightSkyFlood = MC.LightSkyFlood or CreateClientConVar( "mc_light_sky_flood", "1", true, false,
	"Minecraft-style voxel sky light flood: 15 above open sky, -1 per block into interiors (0 = uniform bright sky)" )
MC.LightSkyFloodPerFrame = MC.LightSkyFloodPerFrame or CreateClientConVar( "mc_light_sky_flood_per_frame", "4", true, false,
	"How many chunk sky-light refloods run per frame from the amortized queue" )
MC.LightSkyFloodFrameMS = MC.LightSkyFloodFrameMS or CreateClientConVar( "mc_light_sky_flood_frame_ms", "2", true, false,
	"Soft sky-light reflood time budget in milliseconds per frame (0 = unlimited)" )

MC.LightSkyChunks = MC.LightSkyChunks or {}

local function skyFloodEnabled()
	local cv = MC.LightSkyFlood
	return not cv or ( cv.GetBool and cv:GetBool() == true )
end

local function nativeSkyBackend()
	local backend = MC.GetChunkBackend and MC.GetChunkBackend() or nil
	if backend and backend.native and backend.IsActive and backend.IsActive()
	and backend.ScheduleBlockLightRebuild and backend.GetSkyLightAt then return backend end
	return nil
end

MC.SkyFloodEnabled = skyFloodEnabled

-- A light path reaches at most 14 cells, and L2 samples a two-cell mesh halo.
-- Air-only chunks carry lighting without being inserted into MC.World.
local xyHalo = math.ceil( 16 / MC.CS )
local zHalo = math.ceil( 16 / MC.CH )
local skyDomain = {}

local function chunkKnown( cx, cy, cz, key )
	if MC.World and MC.World[key] then return true end
	if MC.IsChunkLoaded and MC.IsChunkLoaded( key ) then return true end
	local transport = MC.StateNetworkTransport
	if MC.HttpChunkSync ~= nil then return false end
	if not transport or not transport.streaming then return true end
	return cz < ( transport.streamMinCZ or -math.huge ) or cz > ( transport.streamMaxCZ or math.huge )
end

local function chunkKnownForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	return chunkKnown( cx, cy, cz, key )
end

local function inSkyDomain( cx, cy, cz, key )
	local cached = skyDomain[key]
	if cached ~= nil then return cached end
	local world = MC.World
	for dx = -xyHalo, xyHalo do
		for dy = -xyHalo, xyHalo do
			for dz = -zHalo, zHalo do
				if world[MC.ChunkKey( cx + dx, cy + dy, cz + dz )] then
					skyDomain[key] = true
					return true
				end
			end
		end
	end
	skyDomain[key] = false
	return false
end

local function skyStoreForCell( bx, by, bz, create )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( li ) then return nil, nil end
	local key = MC.ChunkKey( cx, cy, cz )
	local chunkStore = MC.LightSkyChunks[key]
	if not chunkStore and create then
		chunkStore = {}
		MC.LightSkyChunks[key] = chunkStore
	end
	return chunkStore, li, key
end

local function getStoredSky( bx, by, bz )
	local chunkStore, li = skyStoreForCell( bx, by, bz, false )
	return chunkStore and ( chunkStore[li] or 0 ) or 0
end

local function setStoredSky( bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	local chunkStore, li = skyStoreForCell( bx, by, bz, level > 0 )
	if not chunkStore then return end
	chunkStore[li] = level > 0 and level or nil
end

-- Exposure = above the column's highest full-opacity block (cl_sky_column
-- caches the tops). Exposed cells are implicit level 15.
local function skyExposed( bx, by, bz )
	if not chunkKnownForCell( bx, by, bz ) then return false end
	if not MC.SkyExposedAt then return true end
	return MC.SkyExposedAt( bx, by, bz ) == true
end

-- Effective sky level for the BFS: implicit 15 when exposed, stored otherwise.
local function skyLevelAt( bx, by, bz )
	if skyExposed( bx, by, bz ) then return 15 end
	return getStoredSky( bx, by, bz )
end

-- Public query used by MC.SampleLighting and the light texture bake.
function MC.SkyVoxelLight( bx, by, bz )
	if not skyFloodEnabled() then return 15 end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local native = nativeSkyBackend()
	local nativeLevel = native and native.GetSkyLightAt( bx, by, bz ) or nil
	if nativeLevel ~= nil then return nativeLevel end
	if not chunkKnownForCell( bx, by, bz ) then return 0 end
	return skyLevelAt( bx, by, bz )
end

function MC.SkyVoxelLightUnit( bx, by, bz )
	return math.Clamp( MC.SkyVoxelLight( bx, by, bz ) / 15, 0, 1 )
end

local function propagationCost( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	if not chunkKnown( cx, cy, cz, key ) or not inSkyDomain( cx, cy, cz, key ) then return 16 end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local opacity = MC.BlockLightOpacityForState and MC.BlockLightOpacityForState( stateId, bx, by, bz ) or 15
	if opacity >= 15 then return 16 end
	return math.max( 1, opacity )
end

local NEIGHBORS = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

local function newChangedCells()
	return { keys = {}, x = {}, y = {}, z = {}, count = 0 }
end

local function noteChangedCell( changed, bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	if changed.keys[key] then return end
	changed.keys[key] = true
	changed.count = changed.count + 1
	changed.x[changed.count] = bx
	changed.y[changed.count] = by
	changed.z[changed.count] = bz
end

-- Write a stored sky value (never for exposed cells — those are implicit 15).
local function setSkyChanged( changed, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if skyExposed( bx, by, bz ) then return false end
	if getStoredSky( bx, by, bz ) == level then return false end
	setStoredSky( bx, by, bz, level )
	noteChangedCell( changed, bx, by, bz )
	return true
end

local function newQueue()
	return { head = 1, tail = 0, x = {}, y = {}, z = {}, level = {} }
end

local function pushQueue( q, bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if level <= 0 then return end
	local tail = q.tail + 1
	q.tail = tail
	q.x[tail], q.y[tail], q.z[tail], q.level[tail] = bx, by, bz, level
end

local function popQueue( q )
	local head = q.head
	if head > q.tail then return nil end
	q.head = head + 1
	local bx, by, bz, level = q.x[head], q.y[head], q.z[head], q.level[head]
	q.x[head], q.y[head], q.z[head], q.level[head] = nil, nil, nil, nil
	return bx, by, bz, level
end

local function runSkyIncrease( q, changed )
	local processed = 0
	while q.head <= q.tail do
		local bx, by, bz, level = popQueue( q )
		-- Same phantom re-seed guard as the block light wave: only spread from
		-- cells whose current effective level still matches the queued level.
		-- Known sparse air is valid; unknown streamed chunks cannot seed sky.
		if bx and chunkKnownForCell( bx, by, bz )
		and skyLevelAt( bx, by, bz ) >= level then
			processed = processed + 1
			if level > 1 then
				for i = 1, #NEIGHBORS do
					local off = NEIGHBORS[i]
					local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
					local nextLevel = level - propagationCost( nx, ny, nz )
					if nextLevel > 0
					and skyLevelAt( nx, ny, nz ) < nextLevel then
						setSkyChanged( changed, nx, ny, nz, nextLevel )
						pushQueue( q, nx, ny, nz, nextLevel )
					end
				end
			end
		end
	end
	return processed
end

local function runSkyDecrease( removeQ, addQ, changed )
	local processed = 0
	while removeQ.head <= removeQ.tail do
		local bx, by, bz, oldLevel = popQueue( removeQ )
		if bx then
			processed = processed + 1
			for i = 1, #NEIGHBORS do
				local off = NEIGHBORS[i]
				local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
				if skyExposed( nx, ny, nz ) then
					-- Exposed neighbors are permanent sources: re-seed the add wave.
					pushQueue( addQ, nx, ny, nz, 15 )
				else
					-- No loaded-chunk gate: stored sky can outlive its chunk,
					-- the removal wave must chase orphans (same as block light).
					local neighborLevel = getStoredSky( nx, ny, nz )
					if neighborLevel > 0 and neighborLevel < oldLevel then
						setStoredSky( nx, ny, nz, 0 )
						noteChangedCell( changed, nx, ny, nz )
						pushQueue( removeQ, nx, ny, nz, neighborLevel )
					elseif neighborLevel >= oldLevel then
						pushQueue( addQ, nx, ny, nz, neighborLevel )
					end
				end
			end
		end
	end
	return processed
end

local function markDirty( changed )
	if changed.count <= 0 then return end
	if MC.MarkLightSectionsDirtyForChangedCells then
		MC.MarkLightSectionsDirtyForChangedCells( changed )
	end
end

------------------------------------------------------------------ block change

-- Called from MC.MarkLightingDirtyForChange AFTER cl_sky_column updated the
-- column tops (so exposure reads are already current).
function MC.UpdateSkyLightForBlockChange( bx, by, bz, oldOpacity, newOpacity )
	if not skyFloodEnabled() then return end
	if ( tonumber( oldOpacity ) or 0 ) == ( tonumber( newOpacity ) or 0 ) then return end
	local native = nativeSkyBackend()
	-- ABI 5+ SetCell performs the native incremental sky update before this
	-- notification reaches the legacy Lua flood hook.
	if native then return end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	skyDomain = {}

	local changed = newChangedCells()
	local removeQ = newQueue()
	local addQ = newQueue()

	local oldStored = getStoredSky( bx, by, bz )
	if oldStored > 0 then
		setStoredSky( bx, by, bz, 0 )
		noteChangedCell( changed, bx, by, bz )
		pushQueue( removeQ, bx, by, bz, oldStored )
	end
	runSkyDecrease( removeQ, addQ, changed )

	-- Re-seed from the cell itself (if it is exposed it is a 15 source) and
	-- from every neighbor's current effective level.
	if skyExposed( bx, by, bz ) then
		pushQueue( addQ, bx, by, bz, 15 )
	end
	for i = 1, #NEIGHBORS do
		local off = NEIGHBORS[i]
		local nx, ny, nz = bx + off[1], by + off[2], bz + off[3]
		local level = skyLevelAt( nx, ny, nz )
		if level > 0 then pushQueue( addQ, nx, ny, nz, level ) end
	end
	runSkyIncrease( addQ, changed )
	markDirty( changed )
end

------------------------------------------------------------------ exposure flips

-- A column top moved: cells in [zFrom, zTo] flipped between implicit-15
-- (exposed) and interior. Called from cl_sky_column with the flip span.
function MC.NoteSkyExposureSpanChanged( bx, by, zFrom, zTo )
	if not skyFloodEnabled() then return end
	local native = nativeSkyBackend()
	if native then native.ScheduleBlockLightRebuild( 0.05 ); return end
	bx, by = math.floor( bx ), math.floor( by )
	skyDomain = {}
	zFrom, zTo = math.floor( zFrom ), math.floor( zTo )
	if zFrom > zTo then zFrom, zTo = zTo, zFrom end

	local changed = newChangedCells()
	local removeQ = newQueue()
	local addQ = newQueue()

	for bz = zFrom, zTo do
		if skyExposed( bx, by, bz ) then
			-- Became exposed: implicit 15 now; drop any stored value and act
			-- as a fresh sky source.
			if getStoredSky( bx, by, bz ) > 0 then
				setStoredSky( bx, by, bz, 0 )
			end
			noteChangedCell( changed, bx, by, bz )
			pushQueue( addQ, bx, by, bz, 15 )
		else
			-- Became covered: it used to be an implicit 15 source, remove its
			-- influence like a deleted light source of level 15.
			noteChangedCell( changed, bx, by, bz )
			pushQueue( removeQ, bx, by, bz, 15 )
		end
	end

	runSkyDecrease( removeQ, addQ, changed )
	runSkyIncrease( addQ, changed )
	markDirty( changed )
end

------------------------------------------------------------------ chunk reflood

local function clearChunkStoredSkyToQueue( key, changed, removeQ )
	local store = MC.LightSkyChunks[key]
	if not store then return 0 end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then
		MC.LightSkyChunks[key] = nil
		return 0
	end
	local cells = {}
	for li, level in pairs( store ) do
		level = math.floor( tonumber( level ) or 0 )
		if level > 0 and MC.LocalIndexInRange( li ) then
			cells[#cells + 1] = { li, level }
		end
	end
	local baseX, baseY, baseZ = cx * MC.CS, cy * MC.CS, cz * MC.CH
	for i = 1, #cells do
		local li, level = cells[i][1], cells[i][2]
		local lx, ly, lz = MC.DecodeLocal( li )
		local bx, by, bz = baseX + lx, baseY + ly, baseZ + lz
		noteChangedCell( changed, bx, by, bz )
		pushQueue( removeQ, bx, by, bz, level )
	end
	MC.LightSkyChunks[key] = nil
	return #cells
end

-- Seed exposure transitions inside the chunk footprint: wherever a column is
-- covered at height z but a lateral neighbor column is exposed at z, the
-- exposed neighbor cell is a 15-level source feeding sideways into this
-- column. Sky light enters interiors ONLY through these lateral steps (the
-- cell straight under a column top is the opaque blocker itself).
local LATERALS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function seedChunkExposureTransitions( addQ, chunk )
	local cs, ch = MC.CS, MC.CH
	local minZ = chunk.cz * ch
	local maxZ = minZ + ch - 1
	for lx = 0, cs - 1 do
		local bx = chunk.cx * cs + lx
		for ly = 0, cs - 1 do
			local by = chunk.cy * cs + ly
			local top = MC.SkyColumnTop and MC.SkyColumnTop( bx, by ) or false
			if top ~= false then
				for d = 1, 4 do
					local nx = bx + LATERALS[d][1]
					local ny = by + LATERALS[d][2]
					local ntop = MC.SkyColumnTop( nx, ny )
					-- Neighbor exposed strictly above its own top; our column
					-- covered up to `top`: overlap is (ntop, top].
					local lo = ( ntop == false ) and minZ or ( ntop + 1 )
					if lo < minZ then lo = minZ end
					local hi = top
					if hi > maxZ then hi = maxZ end
					for bz = lo, hi do
						pushQueue( addQ, nx, ny, bz, 15 )
					end
				end
			end
		end
	end
end

-- Border ring: pull light in across chunk boundaries from stored values and
-- exposed cells one cell outside the chunk (mirror of seedChunkBorderLight).
-- Keep the helper outside the chunk scan: fresh closures abort its JIT trace.
local function seedChunkBorderCell( addQ, bx, by, bz )
	local level = skyLevelAt( bx, by, bz )
	if level > 1 then pushQueue( addQ, bx, by, bz, level ) end
end

local function seedChunkBorderSky( addQ, chunk )
	local cs, ch = MC.CS, MC.CH
	local minX, minY, minZ = chunk.cx * cs, chunk.cy * cs, chunk.cz * ch
	local maxX, maxY, maxZ = minX + cs - 1, minY + cs - 1, minZ + ch - 1
	for y = minY, maxY do
		for x = minX, maxX do
			seedChunkBorderCell( addQ, x, y, minZ - 1 )
			seedChunkBorderCell( addQ, x, y, maxZ + 1 )
		end
	end
	for z = minZ, maxZ do
		for y = minY, maxY do
			seedChunkBorderCell( addQ, minX - 1, y, z )
			seedChunkBorderCell( addQ, maxX + 1, y, z )
		end
		for x = minX, maxX do
			seedChunkBorderCell( addQ, x, minY - 1, z )
			seedChunkBorderCell( addQ, x, maxY + 1, z )
		end
	end
end

local function refloodChunkSky( key, seedOnly )
	local changed = newChangedCells()
	local addQ = newQueue()
	if not seedOnly then
		local removeQ = newQueue()
		clearChunkStoredSkyToQueue( key, changed, removeQ )
		runSkyDecrease( removeQ, addQ, changed )
	end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if cx and chunkKnown( cx, cy, cz, key ) and inSkyDomain( cx, cy, cz, key ) then
		local chunk = { cx = cx, cy = cy, cz = cz }
		seedChunkExposureTransitions( addQ, chunk )
		seedChunkBorderSky( addQ, chunk )
	end
	runSkyIncrease( addQ, changed )
	markDirty( changed )
end

------------------------------------------------------------------ reflood queue

local SEED_ONLY, REPLACE = 1, 2
local pendingReflood = {}
local pendingCount = 0
local totalRefloods, totalRefloodMS, lastRefloods, lastRefloodMS = 0, 0, 0, 0
local lastRefloodFrame = -1

function MC.SkyFloodStats()
	return { pending = pendingCount, refloods = totalRefloods, workMS = totalRefloodMS,
		lastRefloods = lastRefloods, lastMS = lastRefloodMS }
end

-- Scalar Lua counters for opt-in frame capture; no table allocation or scan.
function MC.SkyFloodWorkCounters()
	return totalRefloods, totalRefloodMS, pendingCount
end

local function queueSkyFloodChunk( key, seedOnly )
	if not pendingReflood[key] then
		pendingReflood[key] = seedOnly and SEED_ONLY or REPLACE
		pendingCount = pendingCount + 1
	elseif not seedOnly then
		-- An edit/load/unload must supersede a pending initial fill.
		pendingReflood[key] = REPLACE
	end
end

function MC.QueueSkyFloodChunk( key )
	if key == nil then return end
	local native = nativeSkyBackend()
	if native then native.ScheduleBlockLightRebuild( 0.02 ); return end
	queueSkyFloodChunk( key, false )
end

local function queueChunkHalo( cx, cy, cz, columnX, columnY, seedOnly )
	for dx = -xyHalo, xyHalo do
		for dy = -xyHalo, xyHalo do
			local x, y = cx + dx, cy + dy
			if columnX == nil or ( math.abs( x - columnX ) <= xyHalo and math.abs( y - columnY ) <= xyHalo ) then
				for dz = -zHalo, zHalo do queueSkyFloodChunk( MC.ChunkKey( x, y, cz + dz ), seedOnly ) end
			end
		end
	end
end

local function queueColumnLoadedChunks( cx, cy, columnX, columnY )
	if MC.SkyColumnChunkCzList then
		local czList = MC.SkyColumnChunkCzList( cx, cy )
		if not czList then return end
		for cz in pairs( czList ) do
			queueChunkHalo( cx, cy, cz, columnX, columnY )
		end
		return
	end
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.cx == cx and chunk.cy == cy then
			queueChunkHalo( cx, cy, chunk.cz, columnX, columnY )
		end
	end
end

-- A top change affects the entire column and neighboring lighting halos,
-- including air-only chunks at other heights. Owners can lie one halo farther.
function MC.QueueSkyFloodColumn( cx, cy, changedCZ )
	if not MC.ChunkKey then return end
	local native = nativeSkyBackend()
	if native then native.ScheduleBlockLightRebuild( 0.02 ); return end
	skyDomain = {}
	for dx = -xyHalo * 2, xyHalo * 2 do
		for dy = -xyHalo * 2, xyHalo * 2 do
			queueColumnLoadedChunks( cx + dx, cy + dy, cx, cy )
		end
	end
	-- An unloaded owner no longer appears in the column index.
	if changedCZ ~= nil then queueChunkHalo( cx, cy, changedCZ ) end
end

function MC.QueueAllSkyFlood()
	local native = nativeSkyBackend()
	if native then native.ScheduleBlockLightRebuild( 0 ); return end
	skyDomain = {}
	-- With an empty field there is no stale light to remove. Propagation from
	-- earlier jobs is already valid for this world; later jobs only add sources.
	local seedOnly = next( MC.LightSkyChunks ) == nil
	for _, chunk in pairs( MC.World or {} ) do
		queueChunkHalo( chunk.cx, chunk.cy, chunk.cz, nil, nil, seedOnly )
	end
	for key in pairs( MC.LightSkyChunks or {} ) do
		MC.QueueSkyFloodChunk( key )
	end
end

local function refloodBudget()
	local cv = MC.LightSkyFloodPerFrame
	local n = cv and cv.GetInt and cv:GetInt() or 4
	n = tonumber( n ) or 4
	if n <= 0 then n = 1 end
	return n
end

-- The unlimited mesh builder calls this before consuming sky values. Keep the
-- standalone hook for budgeted work, and count both callers in the same frame.
function MC.ProcessSkyFloodQueue()
	local frame = FrameNumber()
	if lastRefloodFrame ~= frame then
		lastRefloodFrame = frame
		lastRefloods, lastRefloodMS = 0, 0
	end
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = ( perf or pendingCount > 0 ) and SysTime() or nil
	local processed = 0
	if pendingCount <= 0 or ( MC.LightingBulkLoadDepth or 0 ) > 0 then
		if perf then MC.StreamPerformanceAddFrameStage( "lighting.sky_flood", ( SysTime() - started ) * 1000 ) end
		return
	end
	if not skyFloodEnabled() then
		pendingReflood = {}
		pendingCount = 0
		if perf then MC.StreamPerformanceAddFrameStage( "lighting.sky_flood", ( SysTime() - started ) * 1000 ) end
		return
	end
	local unlimited = MC.BuildUnlimited and MC.BuildUnlimited:GetBool() == true
	local budget = unlimited and pendingCount or refloodBudget()
	local cv = MC.LightSkyFloodFrameMS
	local frameMS = cv and cv.GetFloat and cv:GetFloat() or 2
	local deadline = not unlimited and frameMS > 0 and started + frameMS / 1000 or nil
	for key, mode in pairs( pendingReflood ) do
		-- A flood is atomic, but a slow one must not be followed by three more.
		if processed > 0 and deadline and SysTime() >= deadline then break end
		pendingReflood[key] = nil
		pendingCount = pendingCount - 1
		refloodChunkSky( key, mode == SEED_ONLY )
		processed = processed + 1
		budget = budget - 1
		if budget <= 0 then break end
	end
	local elapsed = ( SysTime() - started ) * 1000
	lastRefloods, lastRefloodMS = lastRefloods + processed, lastRefloodMS + elapsed
	totalRefloods, totalRefloodMS = totalRefloods + processed, totalRefloodMS + elapsed
	if perf then MC.StreamPerformanceAddFrameStage( "lighting.sky_flood", elapsed, { skyFloodChunks = processed } ) end
end

hook.Remove( "Think", "mc_sky_flood_queue" )
hook.Add( "Think", "mc_sky_flood_queue", MC.ProcessSkyFloodQueue )

function MC.ClearSkyFlood()
	MC.LightSkyChunks = {}
	skyDomain = {}
	pendingReflood = {}
	pendingCount = 0
end

-- Lua reload with a live world: re-flood everything once.
if MC.World and next( MC.World ) ~= nil then
	MC.QueueAllSkyFlood()
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_light_sky_flood", function()
		MC.ClearSkyFlood()
		if skyFloodEnabled() then MC.QueueAllSkyFlood() end
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
		local markLight = MC.Need( MC.MarkAllMeshLightingDirty,
			"sky_native_invalidation_missing", "native L2 section invalidation did not load" )
		if markLight then markLight( true ) end
	end, "mc_sky_flood_toggle" )
end
