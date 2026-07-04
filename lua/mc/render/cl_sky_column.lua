-- Client-side sky exposure for the GPU light texture path.
-- A cell is sky-exposed iff it sits ABOVE the highest sky-blocking block of
-- its column (cheap per-column cache). This is deliberately NOT a sky light
-- flood — no lateral propagation, no global rebuilds; directional light
-- through openings is the shadow map's job. Day/night modulates the exposed
-- level through MC.DayCycleSkyLevel().
--
-- On top of the binary column test sits a SOFT exposure kernel
-- (MC.SkyExposureUnitAt): enclosed cells take the nearest open-sky column
-- within a small Manhattan radius, faded by distance. Skylight through an
-- opening reads as a soft shaft instead of the hard-edged pillar that got
-- binary exposure disabled, and fully enclosed rooms fall to the ambient
-- floor. Still not a flood: it only ever reads the column-top cache.
MC = MC or {}

-- Numeric column keys: |block coord| < 2^20 (net COORD_BITS), so bx * 2^21 +
-- by is exact in a double and unique. Avoids string concat garbage in the
-- per-cell exposure queries during light texture bakes.
local COL_KEY_STRIDE = 2097152
local tops = {}          -- [colKey] -> topZ (number) | false (no blocker in column)
local chunkColumns = nil -- ["cx:cy"] -> { [cz] = true } built lazily from MC.World

local function colKey( bx, by )
	return bx * COL_KEY_STRIDE + by
end

local function chunkColKey( cx, cy )
	return cx .. ":" .. cy
end

local function skyFeatureEnabled()
	-- Hard disabled: column exposure creates visible sky-light pillars in this
	-- renderer. Day/night still uses a uniform sky term through the global
	-- lightmap; directional occlusion belongs to the shadow map, not this cache.
	return false
end

local function ensureChunkColumns()
	if chunkColumns then return chunkColumns end
	chunkColumns = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.cx ~= nil then
			local ck = chunkColKey( chunk.cx, chunk.cy )
			local list = chunkColumns[ck]
			if not list then
				list = {}
				chunkColumns[ck] = list
			end
			list[chunk.cz] = true
		end
	end
	return chunkColumns
end

local function noteChunkPresence( cx, cy, cz, present )
	if not chunkColumns then return end
	local ck = chunkColKey( cx, cy )
	local list = chunkColumns[ck]
	if present then
		if not list then
			list = {}
			chunkColumns[ck] = list
		end
		list[cz] = true
	elseif list then
		list[cz] = nil
		if next( list ) == nil then chunkColumns[ck] = nil end
	end
end

local function blocksSky( id, orient )
	if not id or id == 0 then return false end
	-- Light-emitting blocks (torches, glowstone) never block sky light,
	-- matching MC semantics — otherwise placing a lamp darkens the column
	-- under it.
	if MC.BlockLightEmission and ( MC.BlockLightEmission( id ) or 0 ) > 0 then return false end
	local opacity = MC.BlockLightOpacity and MC.BlockLightOpacity( id, orient ) or 15
	return opacity >= 15
end

local function computeColumnTop( bx, by )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cx, cy = math.floor( bx / cs ), math.floor( by / cs )
	local list = ensureChunkColumns()[chunkColKey( cx, cy )]
	if not list then return false end
	local czs = {}
	for cz in pairs( list ) do czs[#czs + 1] = cz end
	table.sort( czs, function( a, b ) return a > b end )
	local world = MC.World or {}
	for i = 1, #czs do
		local cz = czs[i]
		local chunk = world[MC.ChunkKey( cx, cy, cz )]
		if chunk and chunk.count and chunk.count > 0 then
			for bz = cz * ch + ch - 1, cz * ch, -1 do
				local id = MC.GetBlock( bx, by, bz )
				if id ~= 0 and blocksSky( id, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0 ) then
					return bz
				end
			end
		end
	end
	return false
end

local function lowestLoadedZ( bx, by )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cx, cy = math.floor( bx / cs ), math.floor( by / cs )
	local list = ensureChunkColumns()[chunkColKey( cx, cy )]
	if not list then return nil end
	local minCz
	for cz in pairs( list ) do
		if minCz == nil or cz < minCz then minCz = cz end
	end
	return minCz and minCz * ch or nil
end

function MC.SkyColumnTop( bx, by )
	bx, by = math.floor( bx ), math.floor( by )
	local key = colKey( bx, by )
	local top = tops[key]
	if top == nil then
		top = computeColumnTop( bx, by )
		tops[key] = top
	end
	return top
end

-- Internal fast path: assumes integer coords, shares the tops cache.
local function skyExposedRaw( bx, by, bz )
	local key = colKey( bx, by )
	local top = tops[key]
	if top == nil then
		top = computeColumnTop( bx, by )
		tops[key] = top
	end
	if top == false then return true end
	return bz > top
end

function MC.SkyExposedAt( bx, by, bz )
	local top = MC.SkyColumnTop( bx, by )
	if top == false then return true end
	return bz > top
end

function MC.SkyLightLevelAt( bx, by, bz )
	return MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
end

-- Manhattan rings for the soft-exposure kernel, flattened {dx1,dy1,dx2,dy2,...}
-- and built once per distance.
local softRings = {}
local function ringOffsets( d )
	local ring = softRings[d]
	if ring then return ring end
	ring = {}
	for dx = -d, d do
		local ady = d - math.abs( dx )
		ring[#ring + 1] = dx
		ring[#ring + 1] = ady
		if ady ~= 0 then
			ring[#ring + 1] = dx
			ring[#ring + 1] = -ady
		end
	end
	softRings[d] = ring
	return ring
end

local function softSkyRadius()
	local cv = MC.MeshGpuSkySoft
	local r = cv and cv.GetInt and cv:GetInt() or 2
	if r < 0 then r = 0 elseif r > 8 then r = 8 end
	return r
end

-- Time-independent soft exposure for the chunk light texture sky byte.
-- 1 above open sky; under a roof, the nearest exposed column within the
-- kernel radius wins, faded to 0 at the kernel edge (rings are scanned
-- nearest-first, so the first hit is the maximum). 0 deep inside — the
-- global lightmap then only applies torch light plus the ambient floor.
function MC.SkyExposureUnitAt( bx, by, bz )
	local radius = softSkyRadius()
	if radius <= 0 then return 1 end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	if skyExposedRaw( bx, by, bz ) then return 1 end
	for d = 1, radius do
		local ring = ringOffsets( d )
		for i = 1, #ring, 2 do
			if skyExposedRaw( bx + ring[i], by + ring[i + 1], bz ) then
				return 1 - d / ( radius + 1 )
			end
		end
	end
	return 0
end

local function markColumnSpanDirty( bx, by, zFrom, zTo )
	if not MC.MarkGpuChunkLightTextureDirtyCell then return end
	if zFrom > zTo then zFrom, zTo = zTo, zFrom end
	for bz = zFrom, zTo do
		MC.MarkGpuChunkLightTextureDirtyCell( bx, by, bz )
	end
end

-- A column-top change also shifts the soft exposure of neighbor columns
-- within the kernel radius, so the dirty span fans out over the footprint.
local function markColumnFootprintSpanDirty( bx, by, zFrom, zTo )
	markColumnSpanDirty( bx, by, zFrom, zTo )
	for d = 1, softSkyRadius() do
		local ring = ringOffsets( d )
		for i = 1, #ring, 2 do
			markColumnSpanDirty( bx + ring[i], by + ring[i + 1], zFrom, zTo )
		end
	end
end

-- Called from MC.MarkLightingDirtyForChange for every client block change.
function MC.NoteSkyColumnBlockChange( bx, by, bz, oldOpacity, newOpacity )
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local cs, ch = MC.CS or 16, MC.CH or 32
	if chunkColumns then
		local cx, cy, cz = math.floor( bx / cs ), math.floor( by / cs ), math.floor( bz / ch )
		local present = MC.World and MC.World[MC.ChunkKey( cx, cy, cz )] ~= nil
		noteChunkPresence( cx, cy, cz, present )
	end

	local wasBlocking = ( tonumber( oldOpacity ) or 0 ) >= 15
	local nowBlocking = ( tonumber( newOpacity ) or 0 ) >= 15
	if wasBlocking == nowBlocking then return end

	local key = colKey( bx, by )
	local oldTop = tops[key]
	-- Never queried -> no light texture ever sampled this column; the next
	-- query computes fresh data anyway.
	if oldTop == nil then return end

	tops[key] = nil
	local newTop = MC.SkyColumnTop( bx, by )
	if oldTop == newTop then return end

	if oldTop ~= false and newTop ~= false then
		-- Exposure flips for cells strictly above the lower top.
		markColumnFootprintSpanDirty( bx, by, math.min( oldTop, newTop ) + 1, math.max( oldTop, newTop ) )
	else
		-- Column gained its first blocker or lost its last one: everything
		-- below the blocker (down to the lowest loaded chunk) flips.
		local top = oldTop == false and newTop or oldTop
		local bottom = lowestLoadedZ( bx, by ) or ( top - ch )
		markColumnFootprintSpanDirty( bx, by, bottom, top )
	end
end

local function markChunkColumnDirty( cx, cy, exceptCz )
	if not ( MC.GpuChunkLightDirtyChunks and MC.GpuChunkLightDirtyCells and MC.ChunkKey ) then return end
	local list = chunkColumns and chunkColumns[chunkColKey( cx, cy )] or nil
	if not list then return end
	for cz in pairs( list ) do
		if cz ~= exceptCz then
			local key = MC.ChunkKey( cx, cy, cz )
			MC.GpuChunkLightDirtyChunks[key] = true
			MC.GpuChunkLightDirtyCells[key] = true
		end
	end
end

local function invalidateChunkFootprint( cx, cy, cz )
	local cs = MC.CS or 16
	for lx = 0, cs - 1 do
		local bx = cx * cs + lx
		for ly = 0, cs - 1 do
			tops[colKey( bx, cy * cs + ly )] = nil
		end
	end
	-- Sky exposure in this column (and the lateral neighbors whose light
	-- texture pads sample our edge cells) may have changed wholesale.
	for dcx = -1, 1 do
		for dcy = -1, 1 do
			markChunkColumnDirty( cx + dcx, cy + dcy, ( dcx == 0 and dcy == 0 ) and cz or nil )
		end
	end
end

function MC.NoteSkyColumnChunkLoaded( chunk )
	if not ( chunk and chunk.cx ~= nil ) then return end
	noteChunkPresence( chunk.cx, chunk.cy, chunk.cz, true )
	invalidateChunkFootprint( chunk.cx, chunk.cy, chunk.cz )
end

function MC.NoteSkyColumnChunkUnloaded( cx, cy, cz )
	noteChunkPresence( cx, cy, cz, false )
	invalidateChunkFootprint( cx, cy, cz )
end

function MC.ClearSkyColumnCache()
	tops = {}
	chunkColumns = nil
end

-- Day/night: refresh light textures when the quantized sky level steps
-- (about a dozen refreshes per sunrise/sunset, none while it is stable).
-- Uses the amortized queue so a step never rebuilds every chunk in one frame.
local lastSkyLevel
timer.Create( "mc_sky_column_daystep", 1, 0, function()
	local levelNow = MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
	if lastSkyLevel == nil then
		lastSkyLevel = levelNow
		return
	end
	if levelNow ~= lastSkyLevel then
		lastSkyLevel = levelNow
		-- Global-lightmap mode: chunk bytes are time-independent (exposure
		-- only) and the lightmap module regenerates itself; nothing to do.
		if MC.GlobalLightmapActive and MC.GlobalLightmapActive() then return end
		if MC.QueueAllGpuChunkLightTextureRefresh then
			MC.QueueAllGpuChunkLightTextureRefresh()
		elseif MC.ClearAllGpuChunkLightTextures then
			MC.ClearAllGpuChunkLightTextures()
		end
	end
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_gpu_sky_light", function()
		MC.ClearSkyColumnCache()
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	end, "mc_sky_column_toggle" )
	-- Exposure bytes baked into chunk light textures depend on the kernel
	-- radius, so a radius change re-bakes them (the column-top cache is
	-- radius-independent and stays).
	cvars.AddChangeCallback( "mc_mesh_gpu_sky_soft", function()
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	end, "mc_sky_soft_rebake" )
end
