-- Mesh dirty tracking, rebuild queues, and mesh cleanup.
------------------------------------------------------------------- dirty tracking
local RENDER_SECTION_SIZE = 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local DecodeLocal = MC.DecodeLocal
local sectionIndexForLocal = MC.RenderSectionIndexForLocal
local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache
local clearSectionBlockEmitCache = MC.ClearSectionBlockEmitCache
local markBlockEmitCacheDirty = MC.MarkBlockEmitCacheDirty
local NextExplosionMeshBuildAt = 0

function MC.MarkChunkDirty( key )
	MC.MeshDirty[key] = true
	MC.MeshLightDirty[key] = nil
	clearChunkBlockEmitCache( key )
	MC.MeshDirtyRateLimited[key] = nil
end

local function markChunkSectionDirty( key, sectionIndex, rateLimited )
	if not key or not sectionIndex then return end
	if MC.MeshDirty[key] == true then
		if not rateLimited then MC.MeshDirtyRateLimited[key] = nil end
		return
	end
	local sections = MC.MeshDirty[key]
	if not sections then
		sections = {}
		MC.MeshDirty[key] = sections
	end
	MC.MeshDirty[key][sectionIndex] = true
	if rateLimited then
		if MC.MeshDirtyRateLimited[key] ~= false then
			MC.MeshDirtyRateLimited[key] = true
		end
	else
		MC.MeshDirtyRateLimited[key] = nil
	end
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

function MC.MarkRenderSectionsDirtyInBounds( minBX, minBY, minBZ, maxBX, maxBY, maxBZ, rateLimited )
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
								markChunkSectionDirty( key, sectionIndex, rateLimited )
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
	markBlockEmitCacheDirty( x, y, z )
	if rateLimited then
		markChunkSectionDirty( key, sectionIndex, true )
	else
		markChunkSectionDirty( key, sectionIndex )
	end
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

function MC.MarkLightingGeometryDirtyForChange( bx, by, bz, rateLimited )
	local dirtySections, dirtyCount = {}, 0
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				local key, sectionIndex = markBlockGeometryDirty( bx + dx, by + dy, bz + dz, rateLimited )
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

local function chunkDistanceScore( key )
	local lp = LocalPlayer()
	if not IsValid( lp ) then return 0 end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return math.huge end
	local pos = lp.WorldSpaceCenter and lp:WorldSpaceCenter() or lp:GetPos()
	local bx, by, bz = MC.WorldToCell( pos )
	local pcx, pcy, pcz = MC.CellToChunk( bx, by, bz )
	local dx, dy, dz = cx - pcx, cy - pcy, cz - pcz
	return dx * dx + dy * dy + dz * dz * 2
end

local function nextDirtyMeshKeys()
	local keys = {}
	for key in pairs( MC.MeshDirty ) do
		keys[#keys + 1] = key
	end
	table.sort( keys, function( a, b )
		return chunkDistanceScore( a ) < chunkDistanceScore( b )
	end )
	return keys
end

local function nextLightDirtyMeshKeys()
	local keys = {}
	for key in pairs( MC.MeshLightDirty ) do
		keys[#keys + 1] = key
	end
	table.sort( keys, function( a, b )
		return chunkDistanceScore( a ) < chunkDistanceScore( b )
	end )
	return keys
end

local function explosionMeshSectionBudget()
	local cvar = GetConVar and GetConVar( "mc_explosion_mesh_sections_per_frame" ) or nil
	local budget = cvar and cvar:GetInt() or ( MC.Config.ExplosionMeshSectionsPerFrame or 4 )
	budget = math.floor( tonumber( budget ) or 0 )
	if budget <= 0 then return math.huge end
	return budget
end

local function explosionMeshInterval()
	local cvar = GetConVar and GetConVar( "mc_explosion_mesh_interval" ) or nil
	local interval = cvar and cvar:GetFloat() or ( MC.Config.ExplosionMeshInterval or 0.12 )
	return math.max( 0, tonumber( interval ) or 0.12 )
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

local function buildDirtyMeshKey( key, sections, rateLimited, budget, rebuiltSections )
	if sections == true then
		if rateLimited and budget <= 0 then return 0 end
		MC.BuildChunkMesh( key )
		noteRebuiltMeshSection( rebuiltSections, key, true )
		MC.MeshDirty[key] = nil
		MC.MeshDirtyRateLimited[key] = nil
		return 1
	end

	local built = 0
	for sectionIndex in pairs( sections ) do
		if rateLimited and built >= budget then break end
		MC.BuildChunkMesh( key, sectionIndex )
		noteRebuiltMeshSection( rebuiltSections, key, sectionIndex )
		sections[sectionIndex] = nil
		built = built + 1
	end

	if next( sections ) == nil then
		MC.MeshDirty[key] = nil
		MC.MeshDirtyRateLimited[key] = nil
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
	local pending
	for sectionIndex in pairs( sections ) do
		if ( istable( geometryDirty ) and geometryDirty[sectionIndex] ) or ( istable( rebuilt ) and rebuilt[sectionIndex] ) then
			pending = pending or {}
			if not ( istable( rebuilt ) and rebuilt[sectionIndex] ) then
				pending[sectionIndex] = true
			end
		else
			MC.RebuildChunkMeshLighting( key, sectionIndex )
			built = built + 1
		end
	end

	MC.MeshLightDirty[key] = pending
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

-- rebuild dirty meshes; explosion-driven edits are section-budgeted on a fixed
-- interval so one blast cannot force every affected mesh to rebuild at once.
hook.Remove( "Think", "mc_meshbuild" )
hook.Add( "Think", "mc_meshbuild", function()
	local frameStart = SysTime()
	local geometryKeys, geometrySections = 0, 0
	local lightKeys, lightSections = 0, 0
	local rebuiltSections
	if next( MC.MeshDirty ) then
		rebuiltSections = {}
		local now = CurTime()
		local allowExplosionMesh = now >= NextExplosionMeshBuildAt
		local explosionBudget = allowExplosionMesh and explosionMeshSectionBudget() or 0
		local builtExplosionMesh = false
		for _, key in ipairs( nextDirtyMeshKeys() ) do
			local sections = MC.MeshDirty[key]
			local rateLimited = MC.MeshDirtyRateLimited[key] == true
			if rateLimited and not allowExplosionMesh then continue end
			local built = buildDirtyMeshKey( key, sections, rateLimited, explosionBudget, rebuiltSections )
			if built > 0 then
				geometryKeys = geometryKeys + 1
				geometrySections = geometrySections + built
			end
			if rateLimited then
				if built > 0 then builtExplosionMesh = true end
				explosionBudget = explosionBudget - built
				if explosionBudget <= 0 then break end
			end
		end
		if builtExplosionMesh then
			NextExplosionMeshBuildAt = now + explosionMeshInterval()
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
	MC.MeshDirtyRateLimited = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end
