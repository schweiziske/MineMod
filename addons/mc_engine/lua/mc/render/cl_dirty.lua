-- Mesh dirty tracking, rebuild queues, and mesh cleanup.
------------------------------------------------------------------- dirty tracking
local RENDER_SECTION_SIZE = MC.RENDER_SECTION_SIZE or 16
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local RENDER_SECTIONS_Z = math.ceil( MC.CH / RENDER_SECTION_SIZE )
local RENDER_SECTION_COUNT = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
local DecodeLocal = MC.DecodeLocal
local sectionIndexForLocal = MC.RenderSectionIndexForLocal
local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache
local clearSectionBlockEmitCache = MC.ClearSectionBlockEmitCache
local markBlockEmitCacheDirty = MC.MarkBlockEmitCacheDirty
local meshDirtyRevision = 0
local Occlusion = MC.RenderOcclusion
-- Tie retries to the dirty-set lifetime, not a reusable numeric chunk key.
-- Unloaded/replaced queues release these entries without an extra world scan.
local buildRetries = setmetatable( {}, { __mode = "k" } )

local function wakeMeshBuilder()
	meshDirtyRevision = meshDirtyRevision + 1
end

MC.WakeLazyMeshBuilder = wakeMeshBuilder

function MC.MarkChunkDirty( key, rateLimited )
	if MC.NativeL2 then MC.NativeL2.Invalidate( key ) end
	Occlusion.Invalidate( key )
	local previous = MC.MeshDirty[key]
	local limited = rateLimited == true and ( not previous
		or MC.MeshDirtyRateLimited and MC.MeshDirtyRateLimited[key] == true )
		and ( not MC.MeshLightDirty[key]
			or MC.MeshLightDirtyRateLimited and MC.MeshLightDirtyRateLimited[key] == true )
	local sections = {}
	local added = 0
	for sectionIndex = 1, RENDER_SECTION_COUNT do
		sections[sectionIndex] = true
		if previous ~= true and ( not previous or not previous[sectionIndex] ) then added = added + 1 end
	end
	MC.MeshDirty[key] = sections
	MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {}
	MC.MeshDirtyRateLimited[key] = limited and true or nil
	MC.MeshLightDirty[key] = nil
	if MC.MeshLightDirtyRateLimited then MC.MeshLightDirtyRateLimited[key] = nil end
	clearChunkBlockEmitCache( key )
	if added > 0 and MC.RenderPipeline and MC.RenderPipeline.NoteDirtyEnqueue then
		MC.RenderPipeline.NoteDirtyEnqueue( added )
	end
	wakeMeshBuilder()
end

local function markChunkSectionDirty( key, sectionIndex, rateLimited )
	if not key or not sectionIndex then return end
	if MC.NativeL2 then MC.NativeL2.Invalidate( key, sectionIndex ) end
	Occlusion.Invalidate( key, sectionIndex )
	MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {}
	if rateLimited ~= true and MC.MeshDirtyRateLimited[key] then
		MC.MeshDirtyRateLimited[key] = nil
		wakeMeshBuilder()
	end
	local sections = MC.MeshDirty[key]
	if sections == true then return end
	if sections then buildRetries[sections] = nil end
	if not sections then
		sections = {}
		MC.MeshDirty[key] = sections
		MC.MeshDirtyRateLimited[key] = rateLimited == true and true or nil
	elseif rateLimited ~= true then
		-- An ordinary edit sharing a chunk with pending explosion work stays
		-- immediate; the low-priority queue must never delay player interaction.
		MC.MeshDirtyRateLimited[key] = nil
	end
	if sections[sectionIndex] then return end
	sections[sectionIndex] = true
	if MC.RenderPipeline and MC.RenderPipeline.NoteDirtyEnqueue then
		MC.RenderPipeline.NoteDirtyEnqueue( 1 )
	end
	wakeMeshBuilder()
end

function MC.RequestRenderSectionGeometry( key, sectionIndex, rateLimited )
	markChunkSectionDirty( key, sectionIndex, rateLimited ~= false )
end

local function markChunkSectionLightDirty( key, sectionIndex, rateLimited )
	if not key or not sectionIndex then return end
	if MC.NativeL2 then MC.NativeL2.InvalidateLighting( key, sectionIndex ) end
	if MC.MarkBlockAnimationLightDirty then MC.MarkBlockAnimationLightDirty( key ) end
	local geometryDirty = MC.MeshDirty[key]
	if geometryDirty == true then return end
	MC.MeshLightDirtyRateLimited = MC.MeshLightDirtyRateLimited or {}
	local sections = MC.MeshLightDirty[key]
	if sections then buildRetries[sections] = nil end
	if not sections then
		sections = {}
		MC.MeshLightDirty[key] = sections
		MC.MeshLightDirtyRateLimited[key] = rateLimited == true and true or nil
	elseif rateLimited ~= true and MC.MeshLightDirtyRateLimited[key] then
		MC.MeshLightDirtyRateLimited[key] = nil
		wakeMeshBuilder()
	end
	if sections[sectionIndex] then return end
	sections[sectionIndex] = true
	wakeMeshBuilder()
end

function MC.MarkLightSectionDirty( key, sectionIndex, rateLimited )
	markChunkSectionLightDirty( key, sectionIndex, rateLimited )
end

function MC.InvalidateNativeLightSection( key, sectionIndex )
	clearSectionBlockEmitCache( key, sectionIndex )
	markChunkSectionLightDirty( key, sectionIndex, true )
end

function MC.MarkAllMeshLightingDirty( rateLimited )
	local count = 0
	-- In-flight sections may not have any published geometry yet.
	if MC.NativeL2 then
		for key, sections in pairs( MC.NativeL2.pending ) do
			for index in pairs( sections ) do
				if index == 0 then MC.MarkChunkDirty( key, rateLimited )
				else
					clearSectionBlockEmitCache( key, index )
					markChunkSectionLightDirty( key, index, rateLimited )
				end
			end
		end
	end
	for key, sections in pairs( MC.MeshSections ) do
		if MC.World[key] then
			for sectionIndex in pairs( sections ) do
				-- Later partial light marks must not reuse corners from before this reset.
				clearSectionBlockEmitCache( key, sectionIndex )
				markChunkSectionLightDirty( key, sectionIndex, rateLimited )
				count = count + 1
			end
		end
	end
	return count
end

function MC.MarkLightCellDirty( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	if not ( MC.World and MC.World[key] ) then return false end
	local lx, ly, lz = DecodeLocal( li )
	local sectionIndex = sectionIndexForLocal( lx, ly, lz )
	markChunkSectionLightDirty( key, sectionIndex )
	return true, key, sectionIndex
end

function MC.MarkRenderSectionsDirtyInBounds( minBX, minBY, minBZ, maxBX, maxBY, maxBZ )
	minBX, minBY, minBZ = math.floor( tonumber( minBX ) or 0 ), math.floor( tonumber( minBY ) or 0 ), math.floor( tonumber( minBZ ) or 0 )
	maxBX, maxBY, maxBZ = math.floor( tonumber( maxBX ) or minBX ), math.floor( tonumber( maxBY ) or minBY ), math.floor( tonumber( maxBZ ) or minBZ )
	if minBX > maxBX then minBX, maxBX = maxBX, minBX end
	if minBY > maxBY then minBY, maxBY = maxBY, minBY end
	if minBZ > maxBZ then minBZ, maxBZ = maxBZ, minBZ end

	local minCX, minCY, minCZ = MC.CellToChunk( minBX, minBY, minBZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxBX, maxBY, maxBZ )
	for cz = minCZ, maxCZ do
		for cy = minCY, maxCY do
			for cx = minCX, maxCX do
				local key = MC.ChunkKey( cx, cy, cz )
				if MC.World and MC.World[key] then
					local chunkMinX, chunkMinY, chunkMinZ = cx * MC.CS, cy * MC.CS, cz * MC.CH
					local lx0 = math.max( 0, minBX - chunkMinX )
					local ly0 = math.max( 0, minBY - chunkMinY )
					local lz0 = math.max( 0, minBZ - chunkMinZ )
					local lx1 = math.min( MC.CS - 1, maxBX - chunkMinX )
					local ly1 = math.min( MC.CS - 1, maxBY - chunkMinY )
					local lz1 = math.min( MC.CH - 1, maxBZ - chunkMinZ )
					local sx0, sy0, sz0 = math.floor( lx0 / RENDER_SECTION_SIZE ), math.floor( ly0 / RENDER_SECTION_SIZE ), math.floor( lz0 / RENDER_SECTION_SIZE )
					local sx1, sy1, sz1 = math.floor( lx1 / RENDER_SECTION_SIZE ), math.floor( ly1 / RENDER_SECTION_SIZE ), math.floor( lz1 / RENDER_SECTION_SIZE )
					for sz = sz0, sz1 do
						for sy = sy0, sy1 do
							for sx = sx0, sx1 do
								local sectionIndex = sx + sy * RENDER_SECTIONS_XY + sz * RENDER_SECTIONS_XY * RENDER_SECTIONS_XY + 1
								clearSectionBlockEmitCache( key, sectionIndex )
								markChunkSectionDirty( key, sectionIndex )
							end
						end
					end
				end
			end
		end
	end
end

local function markBlockGeometryDirty( x, y, z, rateLimited )
	local cx, cy, cz, li = MC.CellToChunk( x, y, z )
	local lx, ly, lz = DecodeLocal( li )
	local key = MC.ChunkKey( cx, cy, cz )
	local sectionIndex = sectionIndexForLocal( lx, ly, lz )
	if MC.ClearBlockConnectionMaskCache then MC.ClearBlockConnectionMaskCache( x, y, z ) end
	markBlockEmitCacheDirty( x, y, z )
	markChunkSectionDirty( key, sectionIndex, rateLimited )
	return key, sectionIndex
end


-- a block changed: its own chunk and any chunk owning a face-neighbour cell
-- may need a rebuild (boundary faces).
function MC.MarkDirty( bx, by, bz, rateLimited )
	markBlockGeometryDirty( bx, by, bz, rateLimited )
	markBlockGeometryDirty( bx + 1, by, bz, rateLimited ) ; markBlockGeometryDirty( bx - 1, by, bz, rateLimited )
	markBlockGeometryDirty( bx, by + 1, bz, rateLimited ) ; markBlockGeometryDirty( bx, by - 1, bz, rateLimited )
	markBlockGeometryDirty( bx, by, bz + 1, rateLimited ) ; markBlockGeometryDirty( bx, by, bz - 1, rateLimited )
end

-- FluidRenderer corner heights sample a horizontal 3x3 neighborhood. Each
-- sampled cell also checks the state directly above it, so a liquid edit can
-- alter cached fluid geometry in the same layer and one layer below. Keep this
-- fanout liquid-only; ordinary block edits retain the cheap six-neighbour path.
function MC.MarkFluidGeometryDirtyForStateChange( bx, by, bz, oldStateId, newStateId )
	if oldStateId == newStateId then return 0 end
	local oldKind = MC.LiquidKindForState and MC.LiquidKindForState( oldStateId ) or nil
	local newKind = MC.LiquidKindForState and MC.LiquidKindForState( newStateId ) or nil
	if not oldKind and not newKind then return 0 end
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local sourceKey = MC.ChunkKey( cx, cy, cz )
	local rateLimited = MC.MeshDirtyRateLimited and MC.MeshDirtyRateLimited[sourceKey] == true
	for dy = -1, 1 do
		for dx = -1, 1 do
			-- MC.MarkDirty already handled the changed cell, its four horizontal
			-- face neighbours and the cell directly below. Only add the corner
			-- dependencies and the remaining lower-layer ring here.
			if dx ~= 0 and dy ~= 0 then markBlockGeometryDirty( bx + dx, by + dy, bz, rateLimited ) end
			if dx ~= 0 or dy ~= 0 then markBlockGeometryDirty( bx + dx, by + dy, bz - 1, rateLimited ) end
		end
	end
	return 12
end

function MC.MarkLightingGeometryDirtyForChange( bx, by, bz )
	local dirtySections, dirtyCount = {}, 0
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				local key, sectionIndex = markBlockGeometryDirty( bx + dx, by + dy, bz + dz )
				local dirtyKey = type( key ) == "number" and key * 16 + sectionIndex or tostring( key ) .. ":" .. tostring( sectionIndex )
				if not dirtySections[dirtyKey] then
					dirtySections[dirtyKey] = true
					dirtyCount = dirtyCount + 1
				end
			end
		end
	end
	return dirtyCount
end

local function playerChunkCoords()
	local lp = LocalPlayer()
	if not IsValid( lp ) then return nil end
	local pos = lp.WorldSpaceCenter and lp:WorldSpaceCenter() or lp:GetPos()
	local coords = MC.API and MC.API.Coords
	local bx, by, bz
	if coords and coords.EngineToCell then
		bx, by, bz = coords.EngineToCell( pos, lp )
	else
		if MC.EngineToWorldPos then pos = MC.EngineToWorldPos( pos, lp ) end
		bx, by, bz = MC.WorldToCell( pos )
	end
	if bx == nil or by == nil or bz == nil then return nil end
	if coords and coords.CellToChunk then return coords.CellToChunk( bx, by, bz ) end
	return MC.CellToChunk( bx, by, bz )
end

local function lazyMeshBuildEnabled()
	return MC.MeshLazyBuild and MC.MeshLazyBuild.GetBool and MC.MeshLazyBuild:GetBool() == true
end

local function lazyMeshBuildDistance()
	if not lazyMeshBuildEnabled() then return 0 end
	local distance = MC.EffectiveMeshDrawDistance and MC.EffectiveMeshDrawDistance() or 0
	return math.max( 0, tonumber( distance ) or 0 )
end

local dirtyKeys, dirtyScores, dirtyPriorities = {}, {}, {}
local dirtyPinnedOnly = {}
-- Min-heap over dirtyKeys' members. A frame usually consumes a few keys, so
-- popping on demand replaces a full comparator sort of every dirty chunk.
local dirtyHeap, dirtyHeapSize = {}, 0

local function clearDirtySelection()
	for i = 1, #dirtyKeys do
		local key = dirtyKeys[i]
		dirtyKeys[i], dirtyScores[key], dirtyPriorities[key] = nil, nil, nil
		dirtyPinnedOnly[key] = nil
	end
	for i = dirtyHeapSize, 1, -1 do dirtyHeap[i] = nil end
	dirtyHeapSize = 0
end

-- Diagnostics/tests: the per-frame scratch arrays, which must be empty
-- between frames and reused rather than reallocated.
function MC.MeshDirtySelectionScratch()
	return dirtyKeys, dirtyHeap
end

local function dirtyKeyLess( a, b )
	local ap, bp = dirtyPriorities[a], dirtyPriorities[b]
	if ap ~= bp then return ap < bp end
	local ad, bd = dirtyScores[a], dirtyScores[b]
	if ad ~= bd then return ad < bd end
	if type( a ) == type( b ) then return a < b end
	return type( a ) == "number"
end

local function siftDirtyKey( i )
	local heap, size = dirtyHeap, dirtyHeapSize
	local key = heap[i]
	while true do
		local child = i * 2
		if child > size then break end
		if child < size and dirtyKeyLess( heap[child + 1], heap[child] ) then child = child + 1 end
		if not dirtyKeyLess( heap[child], key ) then break end
		heap[i] = heap[child]
		i = child
	end
	heap[i] = key
end

-- The sparse maps remain authoritative for network/legacy writers. Only the
-- ordered selection is scratch; it never retains section tables across builds.
local function sortedDirtyKeys( dirty, rateLimited, buildDistance, pcx, pcy, pcz, blockSize, allowPinned )
	clearDirtySelection()
	local chunkW, chunkH
	if pcx then
		chunkW, chunkH = MC.CS * blockSize, MC.CH * blockSize
	end
	local maxDistSq
	if buildDistance and pcx then
		local halfW, halfH = chunkW * 0.5, chunkH * 0.5
		-- Prebuild one storage chunk beyond the draw boundary. The eligibility
		-- scan only needs to wake when the player crosses a chunk boundary, yet
		-- no drawable chunk can enter the exact eye-centered sphere while absent.
		local prefetch = math.max( chunkW, chunkH )
		local radius = buildDistance + prefetch + math.sqrt( halfW * halfW * 2 + halfH * halfH )
		maxDistSq = radius * radius
	end
	local depth = 0
	for key, sections in pairs( dirty ) do
		if sections ~= true and next( sections ) == nil then
			dirty[key] = nil
			if rateLimited then rateLimited[key] = nil end
		else
			depth = depth + 1
			local score, pinnedOnly
			if pcx then
				local cx, cy, cz = MC.ChunkKeyToCoords( key )
				if cx then
					local dx, dy, dz = ( cx - pcx ) * chunkW, ( cy - pcy ) * chunkW, ( cz - pcz ) * chunkH
					local distanceSq = dx * dx + dy * dy + dz * dz
					local visible = true
					if maxDistSq then
						if MC.ChunkDrawDistanceVisible then
							visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistSq )
						else
							visible = distanceSq <= maxDistSq
						end
					end
					if visible then score = distanceSq
					elseif allowPinned then
						local pins = MC.RenderGeometryStore.GetPinnedSections( key )
						if pins then
							for index in pairs( pins ) do
								if sections == true or sections[index] then
									score, pinnedOnly = distanceSq, true
									break
								end
							end
						end
					end
				elseif not maxDistSq then
					score = math.huge
				end
			elseif not buildDistance then
				score = 0
			end
			if score then
				dirtyKeys[#dirtyKeys + 1] = key
				dirtyScores[key] = score
				dirtyPinnedOnly[key] = pinnedOnly
				dirtyPriorities[key] = ( pinnedOnly or rateLimited and rateLimited[key] == true ) and 2 or 1
			end
		end
	end
	-- dirtyKeyLess is a total order, so pops follow exactly the former sort.
	local count = #dirtyKeys
	for i = 1, count do dirtyHeap[i] = dirtyKeys[i] end
	for i = #dirtyHeap, count + 1, -1 do dirtyHeap[i] = nil end
	dirtyHeapSize = count
	for i = math.floor( count / 2 ), 1, -1 do siftDirtyKey( i ) end
	return count, depth
end

local function popDirtyKey()
	local key = dirtyHeap[1]
	dirtyHeap[1] = dirtyHeap[dirtyHeapSize]
	dirtyHeap[dirtyHeapSize] = nil
	dirtyHeapSize = dirtyHeapSize - 1
	if dirtyHeapSize > 1 then siftDirtyKey( 1 ) end
	return key
end

MC.ExplosionMeshFrameMS = MC.ExplosionMeshFrameMS or ( CreateClientConVar and CreateClientConVar(
	"mc_explosion_mesh_frame_ms", "8", true, false,
	"Lua milliseconds per frame for rate-limited geometry work, including explosions and pack changes", 0.5, 20 ) )
MC.ExplosionMeshSectionsPerFrame = MC.ExplosionMeshSectionsPerFrame or ( CreateClientConVar and CreateClientConVar(
	"mc_explosion_mesh_sections_per_frame", "64", true, false,
	"Render sections per frame for rate-limited geometry work", 1, 128 ) )

local function rateLimitedMeshBuildBudget()
	local frameMS = MC.ExplosionMeshFrameMS and MC.ExplosionMeshFrameMS.GetFloat
		and MC.ExplosionMeshFrameMS:GetFloat() or 8
	local sections = MC.ExplosionMeshSectionsPerFrame and MC.ExplosionMeshSectionsPerFrame.GetInt
		and MC.ExplosionMeshSectionsPerFrame:GetInt() or 64
	return math.max( 0.5, tonumber( frameMS ) or 8 ) / 1000,
		math.max( 1, math.floor( tonumber( sections ) or 64 ) )
end

local function bulkCollisionInterval()
	local cvar = GetConVar and GetConVar( "mc_bulk_collision_interval" ) or nil
	local interval = cvar and cvar:GetFloat() or ( MC.Config.BulkCollisionInterval or 0.12 )
	return math.max( 0, tonumber( interval ) or 0.12 )
end

local function bulkCollisionChunksPerInterval()
	local cvar = GetConVar and GetConVar( "mc_bulk_collision_chunks_per_interval" ) or nil
	local count = cvar and cvar:GetInt() or ( MC.Config.BulkCollisionChunksPerInterval or 1 )
	return math.max( 1, math.floor( tonumber( count ) or 1 ) )
end

local function flushBulkCollisionQueue( unlimited )
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local flushStarted = perfEnabled and SysTime() or nil
	local now = CurTime()
	if not unlimited and now < ( MC.NextBulkCollisionRebuildAt or 0 ) then return end
	local order = MC.PhysDirtyBulkOrder or {}
	local head = MC.PhysDirtyBulkOrderHead or 1
	local tail = #order
	local bulk = MC.PhysDirtyBulk or {}
	local limit = unlimited and math.huge or bulkCollisionChunksPerInterval()
	local built, attempted = 0, 0
	local worstMS, worstKey = 0, nil

	while built < limit and head <= tail do
		local key = order[head]
		head = head + 1
		if bulk[key] and MC.PhysDirty[key] then
			local rebuildStarted = perfEnabled and SysTime() or nil
			MC.RebuildChunkPhys( key, MC.ClientCollisionEnabled and MC.ClientCollisionEnabled() or false )
			if perfEnabled then
				local rebuildMS = ( SysTime() - rebuildStarted ) * 1000
				MC.StreamPerformanceAddStage( "collision.chunk_rebuild", rebuildMS, { collisionChunks = 1 } )
				if rebuildMS > worstMS then worstMS, worstKey = rebuildMS, key end
			end
			attempted = attempted + 1
			built = built + 1
		else
			bulk[key] = nil
		end
	end

	if head > tail then
		MC.PhysDirtyBulkOrder = {}
		MC.PhysDirtyBulkOrderHead = 1
	elseif head > 64 and head > tail * 0.5 then
		local n = 0
		for i = head, tail do
			n = n + 1
			order[n] = order[i]
		end
		for i = n + 1, tail do
			order[i] = nil
		end
		MC.PhysDirtyBulkOrderHead = 1
	else
		MC.PhysDirtyBulkOrderHead = head
	end

	if built > 0 then
		MC.NextBulkCollisionRebuildAt = unlimited and now or now + bulkCollisionInterval()
	end
	if perfEnabled then
		MC.StreamPerformanceAddStage( "collision.flush", ( SysTime() - flushStarted ) * 1000, { collisionAttempts = attempted } )
		local state = MC.StreamPerformanceStats
		if worstKey and state and ( not state.worstCollisionChunk or worstMS > state.worstCollisionChunk.ms ) then
			state.worstCollisionChunk = { key = worstKey, ms = worstMS }
		end
	end
end

local function nativeMeshBackendActive()
	local backend = MC.GetMeshBackend and MC.GetMeshBackend() or nil
	return backend and backend.native == true and backend.async ~= false and not backend.sectionAsync
		and ( not backend.IsActive or backend.IsActive() == true )
end

local frameBudget = {}
local pairedAnimationMS = 0
local function admittedLightPair()
	return true
end

local function refreshPairedFluidLighting( key )
	if not MC.PrepareBlockAnimationLighting then return end
	local started = SysTime()
	-- Admission already happened at the atlas tile boundary. Finish its fluid
	-- colours even if that indivisible tile used the remaining frame budget.
	MC.PrepareBlockAnimationLighting( frameBudget, admittedLightPair, key )
	pairedAnimationMS = pairedAnimationMS + ( SysTime() - started ) * 1000
end

local function canBuildMeshSection( budget, rateLimited )
	-- A section upload cannot be preempted. Allow the first attempt even when
	-- selection used the whole budget; otherwise a busy queue can never drain.
	if ( budget.attempts > 0 or ( budget.lightTextureAttempts or 0 ) > 0 )
	and budget.deadline and SysTime() >= budget.deadline then
		budget.frameYield = true
		return false
	end
	if rateLimited and not budget.native
	and ( budget.rateSections <= 0 or budget.rateSeconds <= 0 ) then
		budget.rateYield = true
		return false
	end
	return true
end

local function tryBuildMeshSection( key, sectionIndex, lightOnly, rateLimited, budget, sections, retried )
	local retry = sections and buildRetries[sections]
	if retry and SysTime() < retry.at then return false end
	if MC.NativeL2 and MC.NativeL2.IsPending( key, sectionIndex ) then return "pending" end
	if not canBuildMeshSection( budget, rateLimited ) then return nil end
	local native = MC.NativeL2
	if native and native.IsActive() and not native.CanBuild() then
		local dirty = lightOnly and MC.MeshLightDirty or MC.MeshDirty
		local token = dirty[key]
		-- Ready results own admission slots until publication. Recycle them once
		-- at backpressure, without waiting/spinning for workers that are still busy.
		native.Pump( budget )
		if dirty[key] ~= token or native.IsPending( key, sectionIndex ) then return "pending" end
		if not canBuildMeshSection( budget, rateLimited ) then return nil end
		if not native.CanBuild() then budget.frameYield = true return nil end
	end
	local limited = rateLimited and not budget.native
	local started = limited and SysTime() or nil
	local result
	budget.attempts = budget.attempts + 1
	if lightOnly then
		result = MC.RebuildChunkMeshLighting( key, sectionIndex )
	else
		result = MC.BuildChunkMesh( key, sectionIndex )
	end
	-- A local light dependency is not global worker backpressure. Leave the
	-- token queued and try other sections without spending the bulk quota.
	if result == "blocked" then return result end
	if limited then
		budget.rateSections = budget.rateSections - 1
		budget.rateSeconds = budget.rateSeconds - ( SysTime() - started )
		budget.rateAttempts = budget.rateAttempts + 1
	end
	if result == "pending" then return result end
	if result == "deferred" then
		if not retried and native and native.IsActive() then
			local dirty = lightOnly and MC.MeshLightDirty or MC.MeshDirty
			local token = dirty[key]
			-- CanBuild is a capacity hint, not a reservation for this section.
			-- Publication can change the selected world data, so retry from its build boundary.
			local released = native.Pump( budget )
			if dirty[key] ~= token or native.IsPending( key, sectionIndex ) then return "pending" end
			if not canBuildMeshSection( budget, rateLimited ) then return nil end
			if released > 0 and native.IsActive() and native.CanBuild() then
				return tryBuildMeshSection( key, sectionIndex, lightOnly, rateLimited, budget, sections, true )
			end
		end
		budget.frameYield = true
		return nil
	end
	if result == false and not budget.native then
		budget.failures = budget.failures + 1
		-- The builder has already reported the fault and retained old geometry.
		-- Unlimited mode must not retry the same broken chunk every frame.
		local delay = retry and math.min( retry.delay * 2, 8 ) or 1
		buildRetries[sections] = { delay = delay, at = SysTime() + delay }
		return false
	end
	if sections then buildRetries[sections] = nil end
	return true
end

local function retireLightDirtySection( key, sectionIndex )
	local sections = MC.MeshLightDirty[key]
	if sections and sectionIndex ~= true then sections[sectionIndex] = nil end
	if sectionIndex == true or not sections or next( sections ) == nil then
		MC.MeshLightDirty[key] = nil
		if MC.MeshLightDirtyRateLimited then MC.MeshLightDirtyRateLimited[key] = nil end
	end
end

local function buildDirtyMeshKey( key, sections, rateLimited, budget, pinnedOnly )
	if not sections then return 0 end
	if sections == true then
		sections = {}
		for sectionIndex = 1, RENDER_SECTION_COUNT do sections[sectionIndex] = true end
		MC.MeshDirty[key] = sections
	end
	if budget.native then
		local sectionIndex = next( sections )
		if sectionIndex == nil then
			MC.MeshDirty[key] = nil
			if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
			return 0
		end
		-- Native builds and uploads a complete storage chunk per submission; its
		-- sectionIndex argument is compatibility-only. Submit once and retire the
		-- whole Lua dirty set instead of calling the bridge 32 times.
		local result = tryBuildMeshSection( key, sectionIndex, false, rateLimited, budget, sections )
		if not result or result == "blocked" then return 0 end
		if MC.RenderPipeline and MC.RenderPipeline.NoteDirtyBuild then MC.RenderPipeline.NoteDirtyBuild( 1 ) end
		if MC.MeshDirty[key] == sections then
			retireLightDirtySection( key, true )
			MC.MeshDirty[key] = nil
			if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
		end
		return 1
	end

	local built = 0
	for sectionIndex = 1, RENDER_SECTION_COUNT do
		if sections[sectionIndex] and ( not pinnedOnly or MC.RenderGeometryStore.IsSectionPinned( key, sectionIndex ) ) then
			local result = tryBuildMeshSection( key, sectionIndex, false, rateLimited, budget, sections )
			if not result then break end
			if result ~= "pending" and result ~= "blocked" then
				if MC.RenderPipeline and MC.RenderPipeline.NoteDirtyBuild then MC.RenderPipeline.NoteDirtyBuild( 1 ) end
				built = built + 1
				if MC.MeshDirty[key] ~= sections then break end
				sections[sectionIndex] = nil
				retireLightDirtySection( key, sectionIndex )
			end
			if MC.MeshDirty[key] ~= sections then break end
		end
	end

	if MC.MeshDirty[key] == sections and next( sections ) == nil then
		MC.MeshDirty[key] = nil
		if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	end
	return built
end

local function buildLightDirtyMeshKey( key, sections, rateLimited, budget, pinnedOnly )
	if not sections then return 0 end
	if budget.native then
		-- Native geometry carries stable GPU-light atlas slots; light dirties are
		-- handled by the atlas/native lighting pipeline, not section mesh rebuilds.
		retireLightDirtySection( key, true )
		return 0
	end

	local built = 0
	for sectionIndex = 1, RENDER_SECTION_COUNT do
		local geometryDirty = MC.MeshDirty[key]
		if sections[sectionIndex] and geometryDirty ~= true
		and not ( istable( geometryDirty ) and geometryDirty[sectionIndex] )
		and ( not pinnedOnly or MC.RenderGeometryStore.IsSectionPinned( key, sectionIndex ) ) then
			local result = tryBuildMeshSection( key, sectionIndex, true, rateLimited, budget, sections )
			if not result then break end
			if result ~= "pending" and result ~= "blocked" then
				built = built + 1
				if MC.MeshLightDirty[key] ~= sections then break end
				sections[sectionIndex] = nil
			end
			if MC.MeshLightDirty[key] ~= sections then break end
		end
	end

	if MC.MeshLightDirty[key] == sections and next( sections ) == nil then
		retireLightDirtySection( key, true )
	end
	return built
end

local function buildSelectedDirtyKeys( dirty, rateLimited, lightOnly, buildDistance, pcx, pcy, pcz, blockSize, budget )
	local selectionStart = SysTime()
	local count, depth = sortedDirtyKeys( dirty, rateLimited, buildDistance, pcx, pcy, pcz, blockSize, not budget.native )
	budget.selectionMS = budget.selectionMS + ( SysTime() - selectionStart ) * 1000
	local keyCount, sectionCount = 0, 0
	local eligible = count > 0
	for _ = 1, count do
		local key = popDirtyKey()
		local limited = dirtyPriorities[key] == 2
		local skyPending = false
		if not budget.native and MC.SkyFloodPendingForChunk then
			local chunk = MC.GetChunkByKey( key )
			if chunk then skyPending = MC.SkyFloodPendingForChunk( chunk.cx, chunk.cy, chunk.cz ) end
		end
		if skyPending then budget.skyWaiting = true end
		local built = 0
		-- Keep deferred keys dirty and eligible so lazy mode checks them again.
		-- Existing geometry remains drawable while its lighting dependencies run.
		if not skyPending then
			if lightOnly then
				built = buildLightDirtyMeshKey( key, MC.MeshLightDirty[key], limited, budget, dirtyPinnedOnly[key] )
			else
				built = buildDirtyMeshKey( key, MC.MeshDirty[key], limited, budget, dirtyPinnedOnly[key] )
			end
		end
		if built > 0 then
			keyCount, sectionCount = keyCount + 1, sectionCount + built
		end
		if budget.frameYield or limited and budget.rateYield then break end
	end
	return keyCount, sectionCount, eligible, depth
end

local function prepareLighting( budget, deadline )
	budget.deadline = deadline
	if not deadline or SysTime() < deadline or budget.attempts == 0 then
		if MC.ProcessGpuChunkLightTextureRefresh then
			budget.lightTextureAttempts = MC.ProcessGpuChunkLightTextureRefresh( deadline, refreshPairedFluidLighting ) or 0
		end
	end
	local started = SysTime()
	if MC.PrepareBlockAnimationLighting then MC.PrepareBlockAnimationLighting( budget, canBuildMeshSection ) end
	return pairedAnimationMS + ( SysTime() - started ) * 1000
end

local function meshBuildPerfPrintEnabled()
	return MC.LightPerfPrintEach and MC.LightPerfPrintEach.GetBool and MC.LightPerfPrintEach:GetBool()
end

local function maybePrintMeshBuildFramePerf( totalStart, geometryKeys, geometrySections, lightKeys, lightSections )
	local totalMS = ( SysTime() - totalStart ) * 1000
	if totalMS < 25 and not meshBuildPerfPrintEnabled() then return end
	print( string.format(
		"[MC meshbuild][frame] ms=%.3f geomKeys=%d geomSec=%d lightKeys=%d lightSec=%d dirtyKeys=%d lightDirtyKeys=%d",
		totalMS,
		geometryKeys or 0,
		geometrySections or 0,
		lightKeys or 0,
		lightSections or 0,
		table.Count( MC.MeshDirty or {} ),
		table.Count( MC.MeshLightDirty or {} )
	) )
end

hook.Remove( "Think", "mc_meshbuild" )
local lazyIdleRevision = -1
local lazyIdlePCX, lazyIdlePCY, lazyIdlePCZ
local lazyIdleGeometry, lazyIdleLight, lazyIdleDistance, lazyIdleBlockSize
hook.Add( "Think", "mc_meshbuild", function()
	local unlimited = MC.BuildUnlimited and MC.BuildUnlimited:GetBool() == true
	if unlimited or MC.ProcessSkyFloodQueue then
		-- Think hook order is unspecified. Consume this frame's sky allowance
		-- before selecting meshes; unlimited mode completes the entire queue.
		local processSky = MC.Need( MC.ProcessSkyFloodQueue,
			"mesh_sky_queue_missing", "cl_sky_flood.lua did not load" )
		if not processSky then return end
		processSky()
	end
	-- Sky work reports its own stage; keep mesh timings disjoint from it.
	local frameStart = SysTime()
	local geometryKeys, geometrySections = 0, 0
	local lightKeys, lightSections = 0, 0
	local lazyDistance = unlimited and 0 or lazyMeshBuildDistance()
	local lazy = lazyDistance > 0
	local pcx, pcy, pcz = playerChunkCoords()
	local coords = MC.API and MC.API.Coords
	local blockSize = coords and coords.BlockSize and coords.BlockSize() or MC.BS
	local idle = lazy and lazyIdleRevision == meshDirtyRevision
		and lazyIdlePCX == pcx and lazyIdlePCY == pcy and lazyIdlePCZ == pcz
		and lazyIdleGeometry == MC.MeshDirty and lazyIdleLight == MC.MeshLightDirty
		and lazyIdleDistance == lazyDistance and lazyIdleBlockSize == blockSize
	local budget = frameBudget
	budget.native = nativeMeshBackendActive()
	local budgetMS = MC.MeshBuildFrameMS and MC.MeshBuildFrameMS.GetFloat
		and MC.MeshBuildFrameMS:GetFloat() or 8
	budgetMS = math.max( 0, tonumber( budgetMS ) or 0 )
	budget.deadline = not unlimited and budgetMS > 0 and frameStart + budgetMS / 1000 or nil
	local animationDeadline = budget.deadline
	if budget.native and not lazy then budget.deadline = nil end
	budget.rateSeconds, budget.rateSections = rateLimitedMeshBuildBudget()
	if unlimited then budget.rateSeconds, budget.rateSections = math.huge, math.huge end
	budget.attempts, budget.failures, budget.rateAttempts, budget.selectionMS = 0, 0, 0, 0
	budget.animationAttempts, budget.animationFailures = 0, 0
	budget.frameYield, budget.rateYield = false, false
	budget.skyWaiting = false
	budget.lightTextureAttempts = 0
	pairedAnimationMS = 0
	if MC.RenderPackGeometry then MC.RenderPackGeometry.PumpRetired( budget ) end
	if MC.NativeL2 then MC.NativeL2.Pump( budget ) end
	idle = idle and lazyIdleRevision == meshDirtyRevision
	-- Native L2 owns section-local atlases. Submit edits before unrelated
	-- fluid/light work so workers can run while Lua prepares the latter.
	local geometryFirst = MC.NativeL2 and MC.NativeL2.IsActive()
	local animationMS = 0
	if not geometryFirst then animationMS = prepareLighting( budget, animationDeadline ) end
	if budget.native and not lazy then
		budget.deadline = nil
		-- Native terrain submissions are not stopped by a Lua-only light yield.
		budget.frameYield = false
	end
	local foundEligible, selectionDeferred = false, false
	local geometryDepth = 0
	local buildDistance = lazy and lazyDistance or nil
	if not idle and next( MC.MeshDirty ) then
		if canBuildMeshSection( budget, false ) then
			geometryKeys, geometrySections, foundEligible, geometryDepth = buildSelectedDirtyKeys(
				MC.MeshDirty, MC.MeshDirtyRateLimited, false, buildDistance, pcx, pcy, pcz, blockSize, budget )
		else
			selectionDeferred = true
		end
	end
	if geometryFirst then animationMS = prepareLighting( budget, animationDeadline ) end
	if not idle and next( MC.MeshLightDirty ) then
		if canBuildMeshSection( budget, false ) then
			local lightEligible
			lightKeys, lightSections, lightEligible = buildSelectedDirtyKeys(
				MC.MeshLightDirty, MC.MeshLightDirtyRateLimited, true, buildDistance, pcx, pcy, pcz, blockSize, budget )
			foundEligible = foundEligible or lightEligible
		else
			selectionDeferred = true
		end
	end
	if budget.skyWaiting and budget.attempts == 0 and budget.lightTextureAttempts == 0
		and budget.deadline and SysTime() < budget.deadline then
		MC.ProcessSkyFloodQueue( budget.deadline )
	end
	-- Include jobs completed during submission/lighting, including the final
	-- partial wave that never filled the admission window.
	if geometryFirst then MC.NativeL2.Pump( budget ) end
	clearDirtySelection()
	-- An unexamined queue may contain nearby work. Budget exhaustion is not idle.
	if lazy and not foundEligible and not selectionDeferred then
		lazyIdleRevision = meshDirtyRevision
		lazyIdlePCX, lazyIdlePCY, lazyIdlePCZ = pcx, pcy, pcz
		lazyIdleGeometry, lazyIdleLight, lazyIdleDistance = MC.MeshDirty, MC.MeshLightDirty, lazyDistance
		lazyIdleBlockSize = blockSize
	else
		lazyIdleRevision = -1
		lazyIdleGeometry, lazyIdleLight, lazyIdleDistance = nil, nil, nil
		lazyIdleBlockSize = nil
	end
	-- Native submissions retain their existing policy, but animations always
	-- run in Lua. Terrain sleep must not put animation scans/retries to sleep.
	budget.deadline = animationDeadline
	local animationStarted = SysTime()
	if MC.PrepareBlockAnimations then MC.PrepareBlockAnimations( budget, canBuildMeshSection ) end
	animationMS = animationMS + ( SysTime() - animationStarted ) * 1000
	if MC.RenderPipeline and MC.RenderPipeline.NoteDirtyFrame then
		MC.RenderPipeline.NoteDirtyFrame( budget.attempts, budget.failures, budget.rateAttempts,
			budget.frameYield, budget.rateYield, geometryDepth, budget.selectionMS, ( SysTime() - frameStart ) * 1000,
			budget.animationAttempts, budget.animationFailures, animationMS )
	end
	flushBulkCollisionQueue( unlimited )
	if MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled() then
		local frameMS = ( SysTime() - frameStart ) * 1000
		MC.StreamPerformanceAddStage( "aftermath.frame", frameMS, {
			geometryKeys = geometryKeys, geometrySections = geometrySections,
			lightKeys = lightKeys, lightSections = lightSections,
		} )
		if MC.StreamPerformanceAddFrameStage then
			MC.StreamPerformanceAddFrameStage( "aftermath.frame", frameMS, {
				geometryKeys = geometryKeys, geometrySections = geometrySections,
				lightKeys = lightKeys, lightSections = lightSections,
			} )
		end
		MC.StreamPerformanceRecordAftermathFrame( {
			ms = frameMS, geometryKeys = geometryKeys, geometrySections = geometrySections,
			lightKeys = lightKeys, lightSections = lightSections,
		} )
	end
	-- if geometrySections > 0 or lightSections > 0 then
	-- 	maybePrintMeshBuildFramePerf( frameStart, geometryKeys, geometrySections, lightKeys, lightSections )
	-- end
end )

if cvars and cvars.AddChangeCallback then
	for _, name in ipairs( { "mc_build_unlimited", "mc_mesh_lazy_build", "mc_mesh_lazy_distance", "mc_mesh_draw_distance", "mc_mesh_build_frame_ms",
		"mc_explosion_mesh_frame_ms", "mc_explosion_mesh_sections_per_frame" } ) do
		cvars.AddChangeCallback( name, wakeMeshBuilder, "mc_mesh_lazy_build_" .. name )
	end
end

-- free all meshes (used by mc_clear)
function MC.FreeAllMeshes()
	if MC.NativeL2 then MC.NativeL2.CancelAll() end
	Occlusion.Reset()
	-- Empty sections have no flat draw-list entry but still own cache state.
	for key in pairs( MC.MeshSections ) do MC.FreeChunkMesh( key ) end
	for key in pairs( MC.Meshes ) do MC.FreeChunkMesh( key ) end
	for key in pairs( MC.MeshesTrans ) do MC.FreeChunkMesh( key ) end
	MC.MeshLightDirty = {}
	MC.MeshLightDirtyRateLimited = {}
	MC.MeshBlockEmitCache = {}
	MC.MeshBlockEmitDirty = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end
