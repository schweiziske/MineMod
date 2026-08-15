--[[----------------------------------------------------------------------------
	MC : server-side voxel light sampling.

	The real lighting engine (block-light propagation, sky flood) lives on the
	client and has no server twin. This module answers the two questions
	server gameplay (mob spawning, sun burn, flee-sun) actually asks:

	  SV.CanSeeSky( bx, by, bz )    heightmap level: no light-blocking cell above
	  SV.SampleLighting( bx, by, bz [, selfEmission] )
	                                -> brightness, level, blockLight, skyLight

	Semantics and cost:
	- skyLight is heightmap level (15 fully open above, else 0). No lateral
	  flood into overhangs. Time-independent: apply the day cycle yourself,
	  same contract as the client sampler.
	- blockLight is EXACT Minecraft-style propagation (opacity-aware shortest
	  path from every emitting block within range), computed on demand:
	  O(1) when no source is within 15 cells (a per-chunk source index makes
	  the common dark/wilderness case a few table lookups), bounded local
	  Dijkstra otherwise. Results are cached per cell.
	- Caches invalidate through DIRECT calls from the write paths, not hook
	  listeners: transactions call SV.InvalidateLightingCells, fills/clears/
	  loads/imports call SV.FlushLightingCaches, chunk hydration calls
	  SV.InvalidateLightingChunk. Direct calls run synchronously inside the
	  commit, so block handlers and event listeners of the same transaction
	  already see fresh light - a hook listener could not guarantee that
	  (no ordering contract) and would force every transaction to build the
	  MC.BlocksChanged event table. This module installs NO hooks.
	- On lazy-loaded worlds only hydrated chunks are visible; pair queries
	  with MC.API.World.IsCellLoaded.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local MAX_LIGHT = 15
local OFFSET_SPAN = 31 -- offsets in [-15..15] pack into a 31^3 cube
local OFFSET_PLANE = OFFSET_SPAN * OFFSET_SPAN
local CELL_CACHE_LIMIT = 16384

local SkyTop = {}         -- [columnKey] = z of highest light-blocking cell | false (open column)
local ChunkSources = {}   -- [chunkKey] = { {bx,by,bz,emission}, ... } | false (chunk exists, no sources)
local ChunkStamp = {}     -- [chunkKey] = invalidation counter
local GlobalStamp = 0
local CellLight = {}      -- [cellKey] = cached blockLight
local CellStamp = {}      -- [cellKey] = neighborhood stamp the cached value was computed at
local cellCacheCount = 0

--------------------------------------------------------------- invalidation
-- All entries below are called DIRECTLY by the core write paths (see the
-- header); they must stay cheap and must never error.
function SV.FlushLightingCaches()
	GlobalStamp = GlobalStamp + 1
	SkyTop = {}
	ChunkSources = {}
	CellLight = {}
	CellStamp = {}
	cellCacheCount = 0
end

local function invalidateChunkKey( key )
	ChunkSources[key] = nil
	ChunkStamp[key] = ( ChunkStamp[key] or 0 ) + 1
end

local function invalidateCell( bx, by, bz )
	SkyTop[MC.CellColumnKey( bx, by )] = nil
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	invalidateChunkKey( MC.ChunkKey( cx, cy, cz ) )
end

-- Called by the transaction commit with its change list (any array of
-- tables carrying bx/by/bz), synchronously before handlers and events.
function SV.InvalidateLightingCells( changes )
	if not istable( changes ) then return end
	for i = 1, #changes do
		local change = changes[i]
		if istable( change ) then invalidateCell( change.bx, change.by, change.bz ) end
	end
end

-- Called by the lazy-world store for every runtime chunk a hydration wrote.
function SV.InvalidateLightingChunk( key )
	local canonical = MC.CanonicalChunkKey and MC.CanonicalChunkKey( key ) or key
	if canonical ~= nil then invalidateChunkKey( canonical ) end
	if key ~= nil and key ~= canonical then invalidateChunkKey( key ) end
	local cx, cy = MC.ChunkKeyToCoords( key )
	if not cx then return end
	local CS = MC.CS or 16
	for ly = 0, CS - 1 do
		for lx = 0, CS - 1 do
			SkyTop[MC.CellColumnKey( cx * CS + lx, cy * CS + ly )] = nil
		end
	end
end

------------------------------------------------------------------ sky light
-- Full buildable chunk-z range. No clamp to the packed-key range: cells at
-- |bz| around mc_world_limit can live in legacy string-keyed chunks and
-- MC.GetChunk resolves those fine (bz = 1024 sits in cz = 32).
local function columnChunkRange()
	local lim = SV.WorldCoordinateLimit and SV.WorldCoordinateLimit() or 4096
	local CH = MC.CH or 32
	return math.floor( -lim / CH ), math.floor( lim / CH )
end

-- z of the highest light-blocking (opacity > 0) cell in the column, or false
-- when the whole column is open. Only hydrated chunks are visible.
local function columnTopBlocking( bx, by )
	local colKey = MC.CellColumnKey( bx, by )
	local cached = SkyTop[colKey]
	if cached ~= nil then return cached end

	local CS, CH = MC.CS or 16, MC.CH or 32
	local cx = math.floor( bx / CS )
	local cy = math.floor( by / CS )
	local lx = bx - cx * CS
	local ly = by - cy * CS
	local row = lx + ly * CS
	local czMin, czMax = columnChunkRange()

	local top = false
	for cz = czMax, czMin, -1 do
		local chunk = MC.GetChunk( cx, cy, cz )
		if chunk then
			for lz = CH - 1, 0, -1 do
				local stateId = MC.GetChunkBlockStateByLocalIndex( chunk, row + lz * CS * CS )
				if stateId and stateId ~= 0 then
					local worldZ = cz * CH + lz
					if MC.BlockLightOpacityForState( stateId, bx, by, worldZ ) > 0 then
						top = worldZ
						break
					end
				end
			end
			if top ~= false then break end
		end
	end
	SkyTop[colKey] = top
	return top
end

-- Heightmap-level sky access: true when no light-blocking cell sits strictly
-- above the queried cell (glass and other opacity-0 blocks do not block).
function SV.CanSeeSky( bx, by, bz )
	bx = math.floor( tonumber( bx ) or 0 )
	by = math.floor( tonumber( by ) or 0 )
	bz = math.floor( tonumber( bz ) or 0 )
	local top = columnTopBlocking( bx, by )
	return top == false or bz > top
end

---------------------------------------------------------------- block light
-- Lazy per-chunk emitter index. false = chunk scanned, nothing emits (the
-- negative cache is what makes dark-terrain queries a few table lookups).
-- Missing chunks are NOT cached; content changes and hydration clear
-- entries through the direct invalidation calls above.
local function chunkSources( key )
	local cached = ChunkSources[key]
	if cached ~= nil then
		if cached == false then return false end
		return cached
	end
	local chunk = MC.GetChunkByKey( key )
	if not chunk then return false end
	local sources = nil
	MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
		local emission = MC.BlockLightEmissionForState( stateId, bx, by, bz )
		if emission and emission > 0 then
			sources = sources or {}
			sources[#sources + 1] = { bx = bx, by = by, bz = bz, emission = emission }
		end
	end )
	ChunkSources[key] = sources or false
	return sources or false
end

local function forEachNeighborhoodChunk( bx, by, bz, cb )
	local CS, CH = MC.CS or 16, MC.CH or 32
	for cz = math.floor( ( bz - MAX_LIGHT ) / CH ), math.floor( ( bz + MAX_LIGHT ) / CH ) do
		for cy = math.floor( ( by - MAX_LIGHT ) / CS ), math.floor( ( by + MAX_LIGHT ) / CS ) do
			for cx = math.floor( ( bx - MAX_LIGHT ) / CS ), math.floor( ( bx + MAX_LIGHT ) / CS ) do
				cb( MC.ChunkKey( cx, cy, cz ) )
			end
		end
	end
end

local function neighborhoodStamp( bx, by, bz )
	local stamp = GlobalStamp
	forEachNeighborhoodChunk( bx, by, bz, function( key )
		stamp = stamp + ( ChunkStamp[key] or 0 )
	end )
	return stamp
end

-- Exact block light: max over nearby emitters of (emission - path cost),
-- path cost = sum of max(1, opacity) per cell stepped into (Minecraft's
-- propagation rule, evaluated as a reverse Dijkstra from the query cell).
local function blockLightUncached( bx, by, bz )
	local best = 0
	local maxEmission = 0
	local srcByOffset = nil
	forEachNeighborhoodChunk( bx, by, bz, function( key )
		local sources = chunkSources( key )
		if not sources then return end
		for i = 1, #sources do
			local src = sources[i]
			local dx, dy, dz = src.bx - bx, src.by - by, src.bz - bz
			if dx == 0 and dy == 0 and dz == 0 then
				if src.emission > best then best = src.emission end
			else
				local manhattan = math.abs( dx ) + math.abs( dy ) + math.abs( dz )
				if math.abs( dx ) <= MAX_LIGHT and math.abs( dy ) <= MAX_LIGHT and math.abs( dz ) <= MAX_LIGHT
				and src.emission - manhattan > 0 then
					srcByOffset = srcByOffset or {}
					local off = ( dx + MAX_LIGHT ) + ( dy + MAX_LIGHT ) * OFFSET_SPAN + ( dz + MAX_LIGHT ) * OFFSET_PLANE
					if not srcByOffset[off] or srcByOffset[off] < src.emission then
						srcByOffset[off] = src.emission
					end
					if src.emission > maxEmission then maxEmission = src.emission end
				end
			end
		end
	end )
	if not srcByOffset or best >= maxEmission then return best end

	-- 16-bucket Dijkstra: step costs are max(1, opacity) in [1..15]; cells
	-- with opacity 15 charge past every budget and act as walls.
	local buckets = { [0] = { MAX_LIGHT + MAX_LIGHT * OFFSET_SPAN + MAX_LIGHT * OFFSET_PLANE } }
	local bestG = { [buckets[0][1]] = 0 }
	local processed = {}
	for g = 0, MAX_LIGHT - 1 do
		if best >= maxEmission - g then break end
		local bucket = buckets[g]
		if bucket then
			for i = 1, #bucket do
				local off = bucket[i]
				if not processed[off] and bestG[off] == g then
					processed[off] = true
					local srcEmission = srcByOffset[off]
					if srcEmission and srcEmission - g > best then best = srcEmission - g end

					local dx = off % OFFSET_SPAN - MAX_LIGHT
					local rest = math.floor( off / OFFSET_SPAN )
					local dy = rest % OFFSET_SPAN - MAX_LIGHT
					local dz = math.floor( rest / OFFSET_SPAN ) - MAX_LIGHT
					local x, y, z = bx + dx, by + dy, bz + dz
					local stateId = MC.GetBlockState( x, y, z ) or 0
					local opacity = stateId == 0 and 0 or MC.BlockLightOpacityForState( stateId, x, y, z )
					local step = opacity > 1 and opacity or 1
					local ng = g + step
					if ng < maxEmission - best then
						if dx > -MAX_LIGHT then
							local noff = off - 1
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
						if dx < MAX_LIGHT then
							local noff = off + 1
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
						if dy > -MAX_LIGHT then
							local noff = off - OFFSET_SPAN
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
						if dy < MAX_LIGHT then
							local noff = off + OFFSET_SPAN
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
						if dz > -MAX_LIGHT then
							local noff = off - OFFSET_PLANE
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
						if dz < MAX_LIGHT then
							local noff = off + OFFSET_PLANE
							if bestG[noff] == nil or bestG[noff] > ng then
								bestG[noff] = ng
								buckets[ng] = buckets[ng] or {}
								buckets[ng][#buckets[ng] + 1] = noff
							end
						end
					end
				end
			end
		end
	end
	return best > MAX_LIGHT and MAX_LIGHT or best
end

local function blockLightAt( bx, by, bz )
	local cellKey = MC.CellKey( bx, by, bz )
	local stamp = neighborhoodStamp( bx, by, bz )
	if CellStamp[cellKey] == stamp then return CellLight[cellKey] end
	local light = blockLightUncached( bx, by, bz )
	if cellCacheCount >= CELL_CACHE_LIMIT then
		CellLight = {}
		CellStamp = {}
		cellCacheCount = 0
	end
	if CellStamp[cellKey] == nil then cellCacheCount = cellCacheCount + 1 end
	CellLight[cellKey] = light
	CellStamp[cellKey] = stamp
	return light
end

--------------------------------------------------------------------- public
-- Server twin of the client MC.SampleLighting contract:
--   brightness 0..1, level 0..15, blockLight 0..15, skyLight 0..15
-- skyLight is time-independent; brightness here is linear level/15 (the
-- client applies tone-profile curves on top - do not expect them to match
-- to the decimal).
function SV.SampleLighting( bx, by, bz, selfEmission )
	bx = math.floor( tonumber( bx ) or 0 )
	by = math.floor( tonumber( by ) or 0 )
	bz = math.floor( tonumber( bz ) or 0 )

	local blockLight = blockLightAt( bx, by, bz )
	selfEmission = math.floor( tonumber( selfEmission ) or 0 )
	if selfEmission > blockLight then
		blockLight = selfEmission > MAX_LIGHT and MAX_LIGHT or selfEmission
	end

	local top = columnTopBlocking( bx, by )
	local skyLight = ( top == false or bz > top ) and MAX_LIGHT or 0

	local level = blockLight > skyLight and blockLight or skyLight
	return level / MAX_LIGHT, level, blockLight, skyLight
end
