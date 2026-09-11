-- Client-side sky exposure for the GPU light texture path.
-- A cell is sky-exposed iff it sits ABOVE the highest sky-blocking block of
-- its column (cheap per-column cache). This module only maintains the column
-- tops; exposed cells are implicit sky level 15 and everything below them is
-- flooded by cl_sky_flood (Minecraft-style BFS, -1 per lateral block). The
-- old soft-exposure ring kernel is gone: it painted a hard vertical light
-- pillar under roof openings that fought the shadow map's directional shadow.
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
				local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
				if blocksSky( stateId, bx, by, bz ) then
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

	local zFrom, zTo
	if oldTop ~= false and newTop ~= false then
		-- Exposure flips for cells strictly above the lower top.
		zFrom, zTo = math.min( oldTop, newTop ) + 1, math.max( oldTop, newTop )
	else
		-- Column gained its first blocker or lost its last one: everything
		-- below the blocker (down to the lowest loaded chunk) flips.
		local top = oldTop == false and newTop or oldTop
		local bottom = lowestLoadedZ( bx, by ) or ( top - ch )
		zFrom, zTo = bottom, top
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

function MC.NoteSkyColumnChunkLoaded( chunk )
	if not ( chunk and chunk.cx ~= nil ) then return end
	noteChunkPresence( chunk.cx, chunk.cy, chunk.cz, true )
	invalidateChunkFootprint( chunk.cx, chunk.cy, chunk.cz )
	-- Column tops over this footprint changed wholesale: re-flood the sky
	-- light of the whole chunk column plus its lateral neighbors (BFS light
	-- reaches at most 14 blocks, less than one chunk).
	if MC.QueueSkyFloodColumn then
		MC.QueueSkyFloodColumn( chunk.cx, chunk.cy )
	end
end

function MC.NoteSkyColumnChunkUnloaded( cx, cy, cz )
	noteChunkPresence( cx, cy, cz, false )
	invalidateChunkFootprint( cx, cy, cz )
	if MC.QueueSkyFloodChunk and MC.ChunkKey then
		MC.QueueSkyFloodChunk( MC.ChunkKey( cx, cy, cz ) )
	end
	if MC.QueueSkyFloodColumn then
		MC.QueueSkyFloodColumn( cx, cy )
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
