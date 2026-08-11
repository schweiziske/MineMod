-- Mesh dirty tracking, rebuild queues, and mesh cleanup.
------------------------------------------------------------------- dirty tracking
local RENDER_SECTION_SIZE = MC.RENDER_SECTION_SIZE or 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local RENDER_SECTIONS_Z = math.ceil( MC.CH / RENDER_SECTION_SIZE )
local RENDER_SECTION_COUNT = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
local DecodeLocal = MC.DecodeLocal
local sectionIndexForLocal = MC.RenderSectionIndexForLocal
local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache
local clearSectionBlockEmitCache = MC.ClearSectionBlockEmitCache
local markBlockEmitCacheDirty = MC.MarkBlockEmitCacheDirty
local meshDirtyRevision = 0

local function wakeMeshBuilder()
	meshDirtyRevision = meshDirtyRevision + 1
end

MC.WakeLazyMeshBuilder = wakeMeshBuilder

function MC.MarkChunkDirty( key )
	local sections = {}
	for sectionIndex = 1, RENDER_SECTION_COUNT do sections[sectionIndex] = true end
	MC.MeshDirty[key] = sections
	MC.MeshLightDirty[key] = nil
	clearChunkBlockEmitCache( key )
	wakeMeshBuilder()
end

local function markChunkSectionDirty( key, sectionIndex )
	if not key or not sectionIndex then return end
	if MC.MeshDirty[key] == true then return end
	local sections = MC.MeshDirty[key]
	if not sections then
		sections = {}
		MC.MeshDirty[key] = sections
	end
	if MC.MeshDirty[key][sectionIndex] then return end
	MC.MeshDirty[key][sectionIndex] = true
	wakeMeshBuilder()
end

local function markChunkSectionLightDirty( key, sectionIndex )
	if not key or not sectionIndex then return end
	local geometryDirty = MC.MeshDirty[key]
	if geometryDirty == true then return end
	local sections = MC.MeshLightDirty[key]
	if not sections then
		sections = {}
		MC.MeshLightDirty[key] = sections
	end
	if sections[sectionIndex] then return end
	sections[sectionIndex] = true
	wakeMeshBuilder()
end

function MC.MarkLightSectionDirty( key, sectionIndex )
	markChunkSectionLightDirty( key, sectionIndex )
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

local function markBlockGeometryDirty( x, y, z )
	local cx, cy, cz, li = MC.CellToChunk( x, y, z )
	local lx, ly, lz = DecodeLocal( li )
	local key = MC.ChunkKey( cx, cy, cz )
	local sectionIndex = sectionIndexForLocal( lx, ly, lz )
	if MC.ClearBlockConnectionMaskCache then MC.ClearBlockConnectionMaskCache( x, y, z ) end
	markBlockEmitCacheDirty( x, y, z )
	markChunkSectionDirty( key, sectionIndex )
	return key, sectionIndex
end


-- a block changed: its own chunk and any chunk owning a face-neighbour cell
-- may need a rebuild (boundary faces).
function MC.MarkDirty( bx, by, bz )
	markBlockGeometryDirty( bx, by, bz )
	markBlockGeometryDirty( bx + 1, by, bz ) ; markBlockGeometryDirty( bx - 1, by, bz )
	markBlockGeometryDirty( bx, by + 1, bz ) ; markBlockGeometryDirty( bx, by - 1, bz )
	markBlockGeometryDirty( bx, by, bz + 1 ) ; markBlockGeometryDirty( bx, by, bz - 1 )
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
	for dy = -1, 1 do
		for dx = -1, 1 do
			-- MC.MarkDirty already handled the changed cell, its four horizontal
			-- face neighbours and the cell directly below. Only add the corner
			-- dependencies and the remaining lower-layer ring here.
			if dx ~= 0 and dy ~= 0 then markBlockGeometryDirty( bx + dx, by + dy, bz ) end
			if dx ~= 0 or dy ~= 0 then markBlockGeometryDirty( bx + dx, by + dy, bz - 1 ) end
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
	local bx, by, bz = MC.WorldToCell( pos )
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

local function chunkDistanceMetrics( cx, cy, cz, pcx, pcy, pcz )
	local dx = ( cx - pcx ) * ( MC.ChunkWorld or ( MC.CS * MC.BS ) )
	local dy = ( cy - pcy ) * ( MC.ChunkWorld or ( MC.CS * MC.BS ) )
	local dz = ( cz - pcz ) * ( MC.ChunkWorldH or ( MC.CH * MC.BS ) )
	return dx * dx + dy * dy + dz * dz, dx, dy, dz
end

local function sortedDirtyKeys( dirty, buildDistance )
	local keys = {}
	local scores = {}
	local pcx, pcy, pcz = playerChunkCoords()
	if buildDistance and buildDistance > 0 and not pcx then return keys end
	local maxDistSq
	if buildDistance and buildDistance > 0 then
		local halfW = ( MC.ChunkWorld or ( MC.CS * MC.BS ) ) * 0.5
		local halfH = ( MC.ChunkWorldH or ( MC.CH * MC.BS ) ) * 0.5
		-- Prebuild one storage chunk beyond the draw boundary. The eligibility
		-- scan only needs to wake when the player crosses a chunk boundary, yet
		-- no drawable chunk can enter the exact eye-centered sphere while absent.
		local prefetch = math.max( MC.ChunkWorld or 0, MC.ChunkWorldH or 0 )
		local radius = buildDistance + prefetch + math.sqrt( halfW * halfW * 2 + halfH * halfH )
		maxDistSq = radius * radius
	end
	for key in pairs( dirty ) do
		if pcx then
			local cx, cy, cz = MC.ChunkKeyToCoords( key )
			if cx then
				local score, dx, dy, dz = chunkDistanceMetrics( cx, cy, cz, pcx, pcy, pcz )
				local visible = true
				if maxDistSq then
					if MC.ChunkDrawDistanceVisible then
						visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistSq )
					else
						visible = score <= maxDistSq
					end
				end
				if visible then
					keys[#keys + 1] = key
					scores[key] = score
				end
			else
				if not maxDistSq then
					keys[#keys + 1] = key
					scores[key] = math.huge
				end
			end
		else
			keys[#keys + 1] = key
			scores[key] = 0
		end
	end
	table.sort( keys, function( a, b )
		return scores[a] < scores[b]
	end )
	return keys
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

local function flushBulkCollisionQueue()
	local perfEnabled = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local flushStarted = perfEnabled and SysTime() or nil
	local now = CurTime()
	if now < ( MC.NextBulkCollisionRebuildAt or 0 ) then return end
	local order = MC.PhysDirtyBulkOrder or {}
	local head = MC.PhysDirtyBulkOrderHead or 1
	local tail = #order
	local bulk = MC.PhysDirtyBulk or {}
	local limit = bulkCollisionChunksPerInterval()
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
		MC.NextBulkCollisionRebuildAt = now + bulkCollisionInterval()
	end
	if perfEnabled then
		MC.StreamPerformanceAddStage( "collision.flush", ( SysTime() - flushStarted ) * 1000, { collisionAttempts = attempted } )
		local state = MC.StreamPerformanceStats
		if worstKey and state and ( not state.worstCollisionChunk or worstMS > state.worstCollisionChunk.ms ) then
			state.worstCollisionChunk = { key = worstKey, ms = worstMS }
		end
	end
end

local function noteRebuiltMeshSection( rebuiltSections, key, sectionIndex )
	if not rebuiltSections or not key then return end
	if sectionIndex == true then
		rebuiltSections[key] = true
		return
	end
	local sections = rebuiltSections[key]
	if sections == true then return end
	if not sections then
		sections = {}
		rebuiltSections[key] = sections
	end
	sections[sectionIndex] = true
end

local function nativeMeshBackendActive()
	local backend = MC.GetMeshBackend and MC.GetMeshBackend() or nil
	return backend and backend.native == true and ( not backend.IsActive or backend.IsActive() == true )
end

local function buildDirtyMeshKey( key, sections, rebuiltSections, deadline )
	if sections == true then
		sections = {}
		for sectionIndex = 1, RENDER_SECTION_COUNT do sections[sectionIndex] = true end
		MC.MeshDirty[key] = sections
	end
	if nativeMeshBackendActive() then
		local sectionIndex = next( sections )
		if sectionIndex == nil then
			MC.MeshDirty[key] = nil
			return 0
		end
		-- Native builds and uploads a complete storage chunk per submission; its
		-- sectionIndex argument is compatibility-only. Submit once and retire the
		-- whole Lua dirty set instead of calling the bridge 32 times.
		MC.BuildChunkMesh( key, sectionIndex )
		noteRebuiltMeshSection( rebuiltSections, key, true )
		MC.MeshDirty[key] = nil
		if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
		return 1
	end

	local built = 0
	for sectionIndex in pairs( sections ) do
		MC.BuildChunkMesh( key, sectionIndex )
		noteRebuiltMeshSection( rebuiltSections, key, sectionIndex )
		sections[sectionIndex] = nil
		built = built + 1
		if deadline and SysTime() >= deadline then break end
	end

	if next( sections ) == nil then
		MC.MeshDirty[key] = nil
		if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	else
		MC.MeshDirty[key] = sections
	end
	return built
end

local function buildLightDirtyMeshKey( key, sections, rebuiltSections, deadline )
	local geometryDirty = MC.MeshDirty[key]
	if geometryDirty == true then
		MC.MeshLightDirty[key] = nil
		return 0
	end
	local rebuilt = rebuiltSections and rebuiltSections[key]
	if rebuilt == true then
		MC.MeshLightDirty[key] = nil
		return 0
	end
	if nativeMeshBackendActive() then
		-- Native geometry carries stable GPU-light atlas slots; light dirties are
		-- handled by the atlas/native lighting pipeline, not section mesh rebuilds.
		MC.MeshLightDirty[key] = nil
		if MC.MeshLightDirtyRateLimited then MC.MeshLightDirtyRateLimited[key] = nil end
		return 0
	end

	local built = 0
	for sectionIndex in pairs( sections ) do
		if ( istable( geometryDirty ) and geometryDirty[sectionIndex] ) or ( istable( rebuilt ) and rebuilt[sectionIndex] ) then
			if istable( rebuilt ) and rebuilt[sectionIndex] then sections[sectionIndex] = nil end
		else
			MC.RebuildChunkMeshLighting( key, sectionIndex )
			sections[sectionIndex] = nil
			built = built + 1
			if deadline and SysTime() >= deadline then break end
		end
	end

	if next( sections ) then
		MC.MeshLightDirty[key] = sections
	else
		MC.MeshLightDirty[key] = nil
		if MC.MeshLightDirtyRateLimited then MC.MeshLightDirtyRateLimited[key] = nil end
	end
	return built
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
hook.Add( "Think", "mc_meshbuild", function()
	local frameStart = SysTime()
	local geometryKeys, geometrySections = 0, 0
	local lightKeys, lightSections = 0, 0
	local rebuiltSections
	local lazyDistance = lazyMeshBuildDistance()
	local lazy = lazyDistance > 0
	local pcx, pcy, pcz = playerChunkCoords()
	if lazy and lazyIdleRevision == meshDirtyRevision
	and lazyIdlePCX == pcx and lazyIdlePCY == pcy and lazyIdlePCZ == pcz then
		flushBulkCollisionQueue()
		return
	end
	local budgetMS = lazy and ( MC.MeshBuildFrameMS and MC.MeshBuildFrameMS.GetFloat
		and MC.MeshBuildFrameMS:GetFloat() or 3 ) or 0
	budgetMS = math.max( 0, tonumber( budgetMS ) or 0 )
	local deadline = budgetMS > 0 and frameStart + budgetMS / 1000 or nil
	local foundEligible = false
	if next( MC.MeshDirty ) then
		rebuiltSections = {}
		local keys = sortedDirtyKeys( MC.MeshDirty, lazy and lazyDistance or nil )
		foundEligible = #keys > 0
		for _, key in ipairs( keys ) do
			local sections = MC.MeshDirty[key]
			local built = buildDirtyMeshKey( key, sections, rebuiltSections, deadline )
			if built > 0 then
				geometryKeys = geometryKeys + 1
				geometrySections = geometrySections + built
			end
			if deadline and SysTime() >= deadline then break end
		end
	end
	if next( MC.MeshLightDirty ) and ( not deadline or SysTime() < deadline ) then
		local keys = sortedDirtyKeys( MC.MeshLightDirty, lazy and lazyDistance or nil )
		foundEligible = foundEligible or #keys > 0
		for _, key in ipairs( keys ) do
			local built = buildLightDirtyMeshKey( key, MC.MeshLightDirty[key], rebuiltSections, deadline )
			if built > 0 then lightKeys, lightSections = lightKeys + 1, lightSections + built end
			if deadline and SysTime() >= deadline then break end
		end
	end
	if lazy and not foundEligible then
		lazyIdleRevision = meshDirtyRevision
		lazyIdlePCX, lazyIdlePCY, lazyIdlePCZ = pcx, pcy, pcz
	else
		lazyIdleRevision = -1
	end
	flushBulkCollisionQueue()
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
	for _, name in ipairs( { "mc_mesh_lazy_build", "mc_mesh_lazy_distance", "mc_mesh_draw_distance", "mc_mesh_build_frame_ms" } ) do
		cvars.AddChangeCallback( name, wakeMeshBuilder, "mc_mesh_lazy_build_" .. name )
	end
end

-- free all meshes (used by mc_clear)
function MC.FreeAllMeshes()
	for key in pairs( MC.Meshes ) do MC.FreeChunkMesh( key ) end
	for key in pairs( MC.MeshesTrans ) do MC.FreeChunkMesh( key ) end
	MC.MeshLightDirty = {}
	MC.MeshLightDirtyRateLimited = {}
	MC.MeshBlockEmitCache = {}
	MC.MeshBlockEmitDirty = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end
