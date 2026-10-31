-- Client-side sky exposure for the GPU light texture path.
-- A cell is sky-exposed iff it sits ABOVE the highest sky-blocking block of
-- its column (cheap per-column cache). Like Minecraft's sky heightmap, any
-- block with opacity > 0 (water, leaves) ends exposure; the flood then
-- attenuates light below it. This module only maintains the column
-- tops; exposed cells are implicit sky level 15 and everything below them is
-- flooded by cl_sky_flood (Minecraft-style BFS, -1 per lateral block). The
-- old soft-exposure ring kernel is gone: it painted a hard vertical light
-- pillar under roof openings that fought the shadow map's directional shadow.
MC = MC or {}

-- The bias keeps every column key above Lua's array-index range, so LuaJIT
-- never sees a mixed sparse/dense table when exposure scans cross x=0.
-- Signed 21-bit block coordinates still produce unique, exact double integers.
local COL_KEY_STRIDE = 2097152
local COL_KEY_BIAS = 4398046511104 -- 2^42
local tops = {}          -- [colKey] -> topZ (number) | false (no blocker in column)
local chunkColumns = nil -- ["cx:cy"] -> { [cz] = true } built lazily from MC.World

local function colKey( bx, by )
	return bx * COL_KEY_STRIDE + by + COL_KEY_BIAS
end

local function chunkColKey( cx, cy )
	return cx .. ":" .. cy
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

local function blocksSky( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return false end
	local opacity = MC.BlockLightOpacityForState and MC.BlockLightOpacityForState( stateId, bx, by, bz ) or 15
	return opacity > 0
end

local function descendingHeight( a, b ) return a > b end

local function computeColumnTop( bx, by )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cx, cy = math.floor( bx / cs ), math.floor( by / cs )
	local list = ensureChunkColumns()[chunkColKey( cx, cy )]
	if not list then return false end
	local czs = {}
	for cz in pairs( list ) do czs[#czs + 1] = cz end
	table.sort( czs, descendingHeight )
	local world = MC.World or {}
	for i = 1, #czs do
		local cz = czs[i]
		local chunk = world[MC.ChunkKey( cx, cy, cz )]
		if chunk and chunk.count and chunk.count > 0 then
			for bz = cz * ch + ch - 1, cz * ch, -1 do
				local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
				if blocksSky( stateId, bx, by, bz ) then
					return bz
				end
			end
		end
	end
	return false
end

local function lowestSkyDomainZ( bx, by, top )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cx, cy = math.floor( bx / cs ), math.floor( by / cs )
	local columns, world = ensureChunkColumns(), MC.World
	local minCz = math.floor( top / ch )
	-- Neighbor air halos can belong to much lower voxel chunks one halo farther.
	local radius = math.ceil( 16 / cs ) * 2
	for dx = -radius, radius do
		for dy = -radius, radius do
			local list = columns[chunkColKey( cx + dx, cy + dy )]
			if list then
				for cz in pairs( list ) do
					if cz < minCz and world[MC.ChunkKey( cx + dx, cy + dy, cz )] then
						minCz = cz
					end
				end
			end
		end
	end
	return ( minCz - math.ceil( 16 / ch ) ) * ch
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

-- Loaded chunk cz set for a chunk column, for callers that need to walk a
-- column without scanning the whole world (sky flood reflood queue).
function MC.SkyColumnChunkCzList( cx, cy )
	return ensureChunkColumns()[chunkColKey( cx, cy )]
end

function MC.SkyExposedAt( bx, by, bz )
	local top = MC.SkyColumnTop( bx, by )
	if top == false then return true end
	return bz > top
end

function MC.SkyLightLevelAt( bx, by, bz )
	return MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
end

local function markColumnSpanDirty( bx, by, zFrom, zTo )
	if not ( MC.MarkGpuChunkLightTextureDirtyForChangedCells or MC.MarkGpuChunkLightTextureDirtyCell ) then return end
	if zFrom > zTo then zFrom, zTo = zTo, zFrom end
	if MC.MarkGpuChunkLightTextureDirtyForChangedCells then
		local changed = { count = zTo - zFrom + 1, x = {}, y = {}, z = {} }
		for i = 1, changed.count do
			changed.x[i], changed.y[i], changed.z[i] = bx, by, zFrom + i - 1
		end
		MC.MarkGpuChunkLightTextureDirtyForChangedCells( changed )
	else
		for bz = zFrom, zTo do MC.MarkGpuChunkLightTextureDirtyCell( bx, by, bz ) end
	end
end

-- Called from MC.MarkLightingDirtyForChange for every client block change.
function MC.NoteSkyColumnBlockChange( bx, by, bz, oldOpacity, newOpacity )
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local cs, ch = MC.CS or 16, MC.CH or 32
	if chunkColumns then
		local cx, cy, cz = math.floor( bx / cs ), math.floor( by / cs ), math.floor( bz / ch )
		local list = chunkColumns[chunkColKey( cx, cy )]
		local wasPresent = list ~= nil and list[cz] == true
		local present = MC.World[MC.ChunkKey( cx, cy, cz )] ~= nil
		noteChunkPresence( cx, cy, cz, present )
		if wasPresent ~= present then
			if MC.QueueSkyFloodForChunkPresenceChange then
				MC.QueueSkyFloodForChunkPresenceChange( cx, cy, cz, present )
			elseif MC.QueueSkyFloodColumn then
				MC.QueueSkyFloodColumn( cx, cy, cz )
			end
		end
	end

	local wasBlocking = ( tonumber( oldOpacity ) or 0 ) > 0
	local nowBlocking = ( tonumber( newOpacity ) or 0 ) > 0
	if wasBlocking == nowBlocking then return end

	local key = colKey( bx, by )
	local oldTop = tops[key]
	-- Never queried -> no light texture ever sampled this column; the next
	-- query computes fresh data anyway.
	if oldTop == nil then return end

	tops[key] = nil
	local newTop = MC.SkyColumnTop( bx, by )
	if oldTop == newTop then return end

	local zFrom, zTo
	if oldTop ~= false and newTop ~= false then
		-- Exposure flips for cells strictly above the lower top.
		zFrom, zTo = math.min( oldTop, newTop ) + 1, math.max( oldTop, newTop )
	else
		-- Column gained its first blocker or lost its last one: everything
		-- below the blocker, including the air-only lighting halo, flips.
		local top = oldTop == false and newTop or oldTop
		zFrom, zTo = lowestSkyDomainZ( bx, by, top ), top
	end
	-- Exposed cells are implicit values, no stored change marks them: dirty
	-- the flipped span for the light texture bake, then let the sky flood
	-- update the stored light around it (marks its own changed cells).
	markColumnSpanDirty( bx, by, zFrom, zTo )
	if MC.NoteSkyExposureSpanChanged then
		MC.NoteSkyExposureSpanChanged( bx, by, zFrom, zTo )
	end
end

local function markChunkColumnDirty( cx, cy, dirtyKeys )
	if not ( MC.MarkGpuChunkLightTextureDirty and MC.ChunkKey ) then return end
	local list = chunkColumns and chunkColumns[chunkColKey( cx, cy )] or nil
	if not list then return end
	for cz in pairs( list ) do
		local key = MC.ChunkKey( cx, cy, cz )
		if dirtyKeys then dirtyKeys[key] = true
		else MC.MarkGpuChunkLightTextureDirty( key ) end
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
	local dirtyKeys = {}
	for dcx = -1, 1 do
		for dcy = -1, 1 do
			-- A replacement can reuse this chunk's atlas slot too.
			markChunkColumnDirty( cx + dcx, cy + dcy, dirtyKeys )
		end
	end
	if next( dirtyKeys ) then
		if MC.MarkGpuChunkLightTextureDirtyKeys then
			MC.MarkGpuChunkLightTextureDirtyKeys( dirtyKeys )
		else
			for key in pairs( dirtyKeys ) do MC.MarkGpuChunkLightTextureDirty( key ) end
		end
	end
end

-- Column tops over a chunk footprint, in column order. Absent chunks never
-- block, so before the chunk enters chunkColumns this is the previous state.
local function footprintTops( cx, cy )
	local cs, result = MC.CS or 16, {}
	for lx = 0, cs - 1 do
		for ly = 0, cs - 1 do
			result[#result + 1] = MC.SkyColumnTop( cx * cs + lx, cy * cs + ly )
		end
	end
	return result
end

function MC.NoteSkyColumnChunkLoaded( chunk )
	if not ( chunk and chunk.cx ~= nil ) then return end
	local cx, cy, cz = chunk.cx, chunk.cy, chunk.cz
	-- Only a fresh arrival can be compared: a chunk already listed would make
	-- the "before" tops read its replacement data from MC.World.
	local list = chunkColumns and chunkColumns[chunkColKey( cx, cy )]
	local before = chunkColumns and not ( list and list[cz] ) and MC.QueueSkyFloodChunkHalo
		and footprintTops( cx, cy ) or nil
	noteChunkPresence( cx, cy, cz, true )
	invalidateChunkFootprint( cx, cy, cz )
	if before then
		local after, unchanged = footprintTops( cx, cy ), true
		for i = 1, #before do
			if before[i] ~= after[i] then unchanged = false break end
		end
		if unchanged then
			MC.QueueSkyFloodChunkHalo( cx, cy, cz )
			return
		end
	end
	-- Column tops over this footprint changed: re-flood the sky light of the
	-- whole chunk column plus its lateral neighbors (BFS light reaches at most
	-- 14 blocks, less than one chunk).
	if MC.QueueSkyFloodColumn then
		MC.QueueSkyFloodColumn( cx, cy, cz )
	end
end

function MC.NoteSkyColumnChunkUnloaded( cx, cy, cz )
	noteChunkPresence( cx, cy, cz, false )
	invalidateChunkFootprint( cx, cy, cz )
	if MC.QueueSkyFloodChunk and MC.ChunkKey then
		MC.QueueSkyFloodChunk( MC.ChunkKey( cx, cy, cz ) )
	end
	if MC.QueueSkyFloodColumn then
		MC.QueueSkyFloodColumn( cx, cy, cz )
	end
end

function MC.ClearSkyColumnCache()
	tops = {}
	chunkColumns = nil
	if MC.ClearSkyFlood then MC.ClearSkyFlood() end
	if ( tonumber( MC.LightingBulkLoadDepth ) or 0 ) <= 0 and MC.QueueAllSkyFlood then
		MC.QueueAllSkyFlood()
	end
end

-- Day/night never invalidates chunk tiles: they contain raw block/sky levels,
-- and the shared 16x16 global lightmap applies the current time-of-day color.
timer.Remove( "mc_sky_column_daystep" )
