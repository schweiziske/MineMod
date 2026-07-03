-- Client-side sky exposure for the GPU light texture path.
-- A cell is sky-exposed iff it sits ABOVE the highest sky-blocking block of
-- its column (cheap per-column cache). This is deliberately NOT a sky light
-- flood — no lateral propagation, no global rebuilds; directional light
-- through openings is the shadow map's job. Day/night modulates the exposed
-- level through MC.DayCycleSkyLevel().
MC = MC or {}

local tops = {}          -- ["bx:by"] -> topZ (number) | false (no blocker in column)
local chunkColumns = nil -- ["cx:cy"] -> { [cz] = true } built lazily from MC.World

local function colKey( bx, by )
	return bx .. ":" .. by
end

local function chunkColKey( cx, cy )
	return cx .. ":" .. cy
end

local function skyFeatureEnabled()
	-- DISABLED: Column-based sky occlusion disabled to prevent fake shadows under light sources
	return false
	-- local cv = MC.MeshGpuSkyLight
	-- if cv and cv.GetBool and not cv:GetBool() then return false end
	-- local le = MC.LightEnabled
	-- if le and le.GetBool and not le:GetBool() then return false end
	-- return true
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

function MC.SkyExposedAt( bx, by, bz )
	local top = MC.SkyColumnTop( bx, by )
	if top == false then return true end
	return bz > top
end

function MC.SkyLightLevelAt( bx, by, bz )
	-- Column occlusion disabled, always return full sky light
	return MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
end

-- Time-independent exposure for global-lightmap mode: nil = feature inactive,
-- otherwise 0 or 1. Never modulated by the day cycle (that lives in the
-- lightmap sky axis), so chunk bytes stay valid around the clock even with
-- mc_daycycle_moon_light 0.
function MC.SkyExposureUnitAt( bx, by, bz )
	-- Column occlusion disabled, always return full exposure
	return 1
end

local function markColumnSpanDirty( bx, by, zFrom, zTo )
	if not MC.MarkGpuChunkLightTextureDirtyCell then return end
	if zFrom > zTo then zFrom, zTo = zTo, zFrom end
	for bz = zFrom, zTo do
		MC.MarkGpuChunkLightTextureDirtyCell( bx, by, bz )
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
		markColumnSpanDirty( bx, by, math.min( oldTop, newTop ) + 1, math.max( oldTop, newTop ) )
	else
		-- Column gained its first blocker or lost its last one: everything
		-- below the blocker (down to the lowest loaded chunk) flips.
		local top = oldTop == false and newTop or oldTop
		local bottom = lowestLoadedZ( bx, by ) or ( top - ch )
		markColumnSpanDirty( bx, by, bottom, top )
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
	if not skyFeatureEnabled() then return end
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
end
