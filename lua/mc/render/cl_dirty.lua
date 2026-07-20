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

function MC.MarkChunkDirty( key )
	local sections = {}
	for sectionIndex = 1, RENDER_SECTION_COUNT do sections[sectionIndex] = true end
	MC.MeshDirty[key] = sections
	MC.MeshLightDirty[key] = nil
	clearChunkBlockEmitCache( key )
end

local function markChunkSectionDirty( key, sectionIndex )
	if not key or not sectionIndex then return end
	if MC.MeshDirty[key] == true then return end
	local sections = MC.MeshDirty[key]
	if not sections then
		sections = {}
		MC.MeshDirty[key] = sections
	end
	MC.MeshDirty[key][sectionIndex] = true
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
	sections[sectionIndex] = true
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

local function sortedDirtyKeys( dirty )
	local keys = {}
	local scores = {}
	local pcx, pcy, pcz = playerChunkCoords()
	for key in pairs( dirty ) do
		keys[#keys + 1] = key
		if pcx then
			local cx, cy, cz = MC.ChunkKeyToCoords( key )
			if cx then
				local dx, dy, dz = cx - pcx, cy - pcy, cz - pcz
				scores[key] = dx * dx + dy * dy + dz * dz * 2
			else
				scores[key] = math.huge
			end
		else
			scores[key] = 0
		end
	end
	table.sort( keys, function( a, b )
		return scores[a] < scores[b]
	end )
	return keys
end

local function nextDirtyMeshKeys() return sortedDirtyKeys( MC.MeshDirty ) end
local function nextLightDirtyMeshKeys() return sortedDirtyKeys( MC.MeshLightDirty ) end

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
	local now = CurTime()
	if now < ( MC.NextBulkCollisionRebuildAt or 0 ) then return end
	local order = MC.PhysDirtyBulkOrder or {}
	local head = MC.PhysDirtyBulkOrderHead or 1
	local tail = #order
	local bulk = MC.PhysDirtyBulk or {}
	local limit = bulkCollisionChunksPerInterval()
	local built = 0

	while built < limit and head <= tail do
		local key = order[head]
		head = head + 1
		if bulk[key] and MC.PhysDirty[key] then
			MC.RebuildChunkPhys( key, MC.ClientCollisionEnabled and MC.ClientCollisionEnabled() or false )
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

local function buildDirtyMeshKey( key, sections, rebuiltSections )
	if sections == true then
		sections = {}
		for sectionIndex = 1, RENDER_SECTION_COUNT do sections[sectionIndex] = true end
		MC.MeshDirty[key] = sections
	end

	local built = 0
	for sectionIndex in pairs( sections ) do
		MC.BuildChunkMesh( key, sectionIndex )
		noteRebuiltMeshSection( rebuiltSections, key, sectionIndex )
		sections[sectionIndex] = nil
		built = built + 1
	end

	if next( sections ) == nil then
		MC.MeshDirty[key] = nil
	else
		MC.MeshDirty[key] = sections
	end
	return built
end

local function buildLightDirtyMeshKey( key, sections, rebuiltSections )
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

	local built = 0
	for sectionIndex in pairs( sections ) do
		if ( istable( geometryDirty ) and geometryDirty[sectionIndex] ) or ( istable( rebuilt ) and rebuilt[sectionIndex] ) then
			if istable( rebuilt ) and rebuilt[sectionIndex] then sections[sectionIndex] = nil end
		else
			MC.RebuildChunkMeshLighting( key, sectionIndex )
			sections[sectionIndex] = nil
			built = built + 1
		end
	end

	MC.MeshLightDirty[key] = next( sections ) and sections or nil
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

-- Drain every pending geometry and lighting section in this Think. Render
-- sections remain the rebuild unit, but there is deliberately no frame-time,
-- section-count, or explosion-specific mesh throttle.
hook.Remove( "Think", "mc_meshbuild" )
hook.Add( "Think", "mc_meshbuild", function()
	local frameStart = SysTime()
	local geometryKeys, geometrySections = 0, 0
	local lightKeys, lightSections = 0, 0
	local rebuiltSections
	if next( MC.MeshDirty ) then
		rebuiltSections = {}
		for _, key in ipairs( nextDirtyMeshKeys() ) do
			local sections = MC.MeshDirty[key]
			local built = buildDirtyMeshKey( key, sections, rebuiltSections )
			if built > 0 then
				geometryKeys = geometryKeys + 1
				geometrySections = geometrySections + built
			end
		end
	end
	if next( MC.MeshLightDirty ) then
		for _, key in ipairs( nextLightDirtyMeshKeys() ) do
			local built = buildLightDirtyMeshKey( key, MC.MeshLightDirty[key], rebuiltSections )
			if built > 0 then
				lightKeys = lightKeys + 1
				lightSections = lightSections + built
			end
		end
	end
	flushBulkCollisionQueue()
	if geometrySections > 0 or lightSections > 0 then
		maybePrintMeshBuildFramePerf( frameStart, geometryKeys, geometrySections, lightKeys, lightSections )
	end
end )

-- free all meshes (used by mc_clear)
function MC.FreeAllMeshes()
	for key in pairs( MC.Meshes ) do MC.FreeChunkMesh( key ) end
	for key in pairs( MC.MeshesTrans ) do MC.FreeChunkMesh( key ) end
	MC.MeshLightDirty = {}
	MC.MeshBlockEmitCache = {}
	MC.MeshBlockEmitDirty = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end
