--[[----------------------------------------------------------------------------
	MC : client-side Minecraft-style vertex lighting

	Lighting is derived from the locally loaded voxel store. It does not create
	Source lights; chunk meshes consume the sampled values through vertex colour.
------------------------------------------------------------------------------]]

MC = MC or {}

local LIGHT_RADIUS = 15

MC.LightEnabled = MC.LightEnabled or CreateClientConVar( "mc_light_enabled", "1", true, false,
	"Apply Minecraft-style vertex lighting to MC chunk meshes" )
MC.LightSkyLevel = MC.LightSkyLevel or CreateClientConVar( "mc_light_sky_level", "15", true, false,
	"Client sky light level for MC chunks (0-15)" )
MC.LightAmbientMin = MC.LightAmbientMin or CreateClientConVar( "mc_light_ambient_min", "0.18", true, false,
	"Minimum brightness multiplier for MC vertex lighting" )

MC.LightingCache = MC.LightingCache or {}
MC.LightSourceCells = MC.LightSourceCells or {}
MC.LightChunkSources = MC.LightChunkSources or {}
MC.LightSkyColumns = MC.LightSkyColumns or {}
MC.LightSourceIndexReady = MC.LightSourceIndexReady or false

local function lightEnabled()
	return not MC.LightEnabled or MC.LightEnabled:GetBool()
end

local function skyLevel()
	local cv = MC.LightSkyLevel
	return math.Clamp( cv and cv:GetInt() or 15, 0, 15 )
end

local function ambientMin()
	local cv = MC.LightAmbientMin
	return math.Clamp( cv and cv:GetFloat() or 0.18, 0, 1 )
end

local function cellKey( bx, by, bz )
	return bx .. ":" .. by .. ":" .. bz
end

local function columnKey( bx, by )
	return bx .. ":" .. by
end

local function lightEmission( id )
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

local function lightOpacity( id, orient )
	if id == 0 then return 0 end
	return MC.BlockLightOpacity and MC.BlockLightOpacity( id, orient ) or 15
end

function MC.ClearLightingCache()
	MC.LightingCache = {}
	MC.LightSkyColumns = {}
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	MC.LightSourceIndexReady = false
end

function MC.MarkAllMeshesDirty()
	MC.ClearLightingCache()
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.count and chunk.count > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
		end
	end
end

function MC.ClearChunkLightSources( key )
	MC.LightSourceCells = MC.LightSourceCells or {}
	MC.LightChunkSources = MC.LightChunkSources or {}
	local old = MC.LightChunkSources[key]
	if old then
		for sourceKey in pairs( old ) do
			MC.LightSourceCells[sourceKey] = nil
		end
	end
	MC.LightChunkSources[key] = nil
end

local function addLightSource( bx, by, bz, level )
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if level <= 0 then return end
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local chunkKey = MC.ChunkKey( cx, cy, cz )
	local sourceKey = cellKey( bx, by, bz )
	MC.LightSourceCells[sourceKey] = { bx = bx, by = by, bz = bz, level = level, chunkKey = chunkKey }
	MC.LightChunkSources[chunkKey] = MC.LightChunkSources[chunkKey] or {}
	MC.LightChunkSources[chunkKey][sourceKey] = true
end

function MC.IndexChunkLightSources( chunk )
	if not chunk or not chunk.key then return end
	if MC.LightingCache then MC.LightingCache[chunk.key] = nil end
	MC.LightSkyColumns = {}
	MC.ClearChunkLightSources( chunk.key )
	if not chunk.blocks or not MC.DecodeLocal then return end
	local baseX, baseY, baseZ = chunk.cx * MC.CS, chunk.cy * MC.CS, chunk.cz * MC.CH
	for li, id in pairs( chunk.blocks ) do
		local emission = lightEmission( id )
		if emission > 0 then
			local lx, ly, lz = MC.DecodeLocal( li )
			addLightSource( baseX + lx, baseY + ly, baseZ + lz, emission )
		end
	end
end

function MC.ReindexAllLightingSources()
	MC.LightSourceCells = {}
	MC.LightChunkSources = {}
	for _, chunk in pairs( MC.World or {} ) do
		MC.IndexChunkLightSources( chunk )
	end
	MC.LightSourceIndexReady = true
end

local function ensureLightSourceIndex()
	if MC.LightSourceIndexReady then return end
	MC.ReindexAllLightingSources()
end

local function invalidateSkyColumn( bx, by )
	MC.LightSkyColumns[columnKey( bx, by )] = nil
end

function MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )
	ensureLightSourceIndex()
	local key = cellKey( bx, by, bz )
	local old = MC.LightSourceCells[key]
	if old then
		local chunkSources = MC.LightChunkSources[old.chunkKey]
		if chunkSources then chunkSources[key] = nil end
		MC.LightSourceCells[key] = nil
	end
	addLightSource( bx, by, bz, lightEmission( newId ) )
	if lightOpacity( oldId, oldOrient ) ~= lightOpacity( newId, newOrient ) then
		invalidateSkyColumn( bx, by )
	end
end

local function cacheIndex( cache, bx, by, bz )
	if bx < cache.minX or bx > cache.maxX
	or by < cache.minY or by > cache.maxY
	or bz < cache.minZ or bz > cache.maxZ then
		return nil
	end
	return ( bx - cache.minX )
		+ ( by - cache.minY ) * cache.dimX
		+ ( bz - cache.minZ ) * cache.dimX * cache.dimY
		+ 1
end

local function blockAllowsPropagation( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return true end
	if lightEmission( id ) > 0 then return true end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return MC.BlockAllowsLight and MC.BlockAllowsLight( id, orient ) == true
end

local function pushLight( cache, queue, bx, by, bz, level )
	local idx = cacheIndex( cache, bx, by, bz )
	if not idx then return end
	level = math.Clamp( math.floor( tonumber( level ) or 0 ), 0, 15 )
	if level <= ( cache.block[idx] or 0 ) then return end
	cache.block[idx] = level
	queue[#queue + 1] = { bx, by, bz, level }
end

local function buildBlockLightCache( key, chunk )
	ensureLightSourceIndex()
	local minX = chunk.cx * MC.CS - LIGHT_RADIUS
	local minY = chunk.cy * MC.CS - LIGHT_RADIUS
	local minZ = chunk.cz * MC.CH - LIGHT_RADIUS
	local maxX = chunk.cx * MC.CS + MC.CS - 1 + LIGHT_RADIUS
	local maxY = chunk.cy * MC.CS + MC.CS - 1 + LIGHT_RADIUS
	local maxZ = chunk.cz * MC.CH + MC.CH - 1 + LIGHT_RADIUS
	local cache = {
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
		dimX = maxX - minX + 1,
		dimY = maxY - minY + 1,
		block = {},
		sky = {},
		skyLevel = skyLevel(),
	}
	local queue = {}

	for _, source in pairs( MC.LightSourceCells or {} ) do
		if source.bx >= minX and source.bx <= maxX
		and source.by >= minY and source.by <= maxY
		and source.bz >= minZ and source.bz <= maxZ then
			pushLight( cache, queue, source.bx, source.by, source.bz, source.level )
		end
	end

	local head = 1
	while head <= #queue do
		local item = queue[head]
		head = head + 1
		local bx, by, bz, level = item[1], item[2], item[3], item[4]
		local nextLevel = level - 1
		if nextLevel > 0 then
			local function try( x, y, z )
				if blockAllowsPropagation( x, y, z ) then
					pushLight( cache, queue, x, y, z, nextLevel )
				end
			end
			try( bx + 1, by, bz )
			try( bx - 1, by, bz )
			try( bx, by + 1, bz )
			try( bx, by - 1, bz )
			try( bx, by, bz + 1 )
			try( bx, by, bz - 1 )
		end
	end

	MC.LightingCache[key] = cache
	return cache
end

local function cacheForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	local cache = MC.LightingCache[key]
	if cache and cache.skyLevel == skyLevel() then return cache end
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key )
	if not chunk then return nil end
	return buildBlockLightCache( key, chunk )
end

local function buildSkyColumnTop( bx, by )
	local cx, cy = math.floor( bx / MC.CS ), math.floor( by / MC.CS )
	local lx, ly = bx - cx * MC.CS, by - cy * MC.CS
	local topOpaque = nil
	for _, chunk in pairs( MC.World or {} ) do
		if chunk.cx == cx and chunk.cy == cy and chunk.count and chunk.count > 0 then
			for lz = MC.CH - 1, 0, -1 do
				local li = lx + ly * MC.CS + lz * MC.CS * MC.CS
				local id = chunk.blocks and chunk.blocks[li] or 0
				if id and id ~= 0 then
					local orient = chunk.orients and chunk.orients[li] or 0
					if lightOpacity( id, orient ) >= 15 then
						local z = chunk.cz * MC.CH + lz
						if not topOpaque or z > topOpaque then topOpaque = z end
						break
					end
				end
			end
		end
	end
	MC.LightSkyColumns[columnKey( bx, by )] = topOpaque or false
	return topOpaque
end

local function columnHasSky( bx, by, bz )
	local key = columnKey( bx, by )
	local topOpaque = MC.LightSkyColumns[key]
	if topOpaque == nil then topOpaque = buildSkyColumnTop( bx, by ) or false end
	if topOpaque == false then return true end
	return topOpaque <= bz
end

local function skyForCell( cache, bx, by, bz )
	local idx = cacheIndex( cache, bx, by, bz )
	if not idx then return skyLevel() end
	local cached = cache.sky[idx]
	if cached ~= nil then return cached end
	local current = MC.GetBlock( bx, by, bz )
	if current ~= 0 then
		local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
		if lightOpacity( current, orient ) >= 15 then
			cache.sky[idx] = 0
			return 0
		end
	end
	local value = columnHasSky( bx, by, bz ) and skyLevel() or 0
	cache.sky[idx] = value
	return value
end

function MC.SampleLighting( bx, by, bz, selfEmission )
	if not lightEnabled() then
		return 1, 15, 15, 15
	end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local cache = cacheForCell( bx, by, bz )
	local idx = cache and cacheIndex( cache, bx, by, bz ) or nil
	local block = idx and ( cache.block[idx] or 0 ) or 0
	local sky = cache and skyForCell( cache, bx, by, bz ) or skyLevel()
	local level = math.max( block, sky, math.Clamp( math.floor( tonumber( selfEmission ) or 0 ), 0, 15 ) )
	local brightness = ambientMin() + ( 1 - ambientMin() ) * ( level / 15 )
	return brightness, level, block, sky
end

function MC.SampleAmbientOcclusion( bx, by, bz )
	if not lightEnabled() then return 1 end
	local blocked = 0
	local function test( x, y, z )
		local id = MC.GetBlock( x, y, z )
		if id == 0 then return end
		local orient = MC.GetBlockOrient and MC.GetBlockOrient( x, y, z ) or 0
		if lightOpacity( id, orient ) >= 15 then
			blocked = blocked + 1
		end
	end
	test( bx + 1, by, bz )
	test( bx - 1, by, bz )
	test( bx, by + 1, bz )
	test( bx, by - 1, bz )
	test( bx, by, bz + 1 )
	test( bx, by, bz - 1 )
	return math.Clamp( 1 - blocked * 0.035, 0.72, 1 )
end

local function invalidateCacheBounds( minBX, minBY, minBZ, maxBX, maxBY, maxBZ )
	local minCX, minCY, minCZ = MC.CellToChunk( minBX, minBY, minBZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxBX, maxBY, maxBZ )
	for cz = minCZ, maxCZ do
		for cy = minCY, maxCY do
			for cx = minCX, maxCX do
				MC.LightingCache[MC.ChunkKey( cx, cy, cz )] = nil
			end
		end
	end
end

function MC.MarkLightingDirtyAroundCell( bx, by, bz, radius, rateLimited )
	radius = math.Clamp( math.floor( tonumber( radius ) or LIGHT_RADIUS ), 0, LIGHT_RADIUS )
	local minX, minY, minZ = bx - radius, by - radius, bz - radius
	local maxX, maxY, maxZ = bx + radius, by + radius, bz + radius
	invalidateCacheBounds( minX, minY, minZ, maxX, maxY, maxZ )
	if MC.MarkRenderSectionsDirtyInBounds then
		MC.MarkRenderSectionsDirtyInBounds( minX, minY, minZ, maxX, maxY, maxZ, rateLimited )
	elseif MC.MarkDirty then
		MC.MarkDirty( bx, by, bz, rateLimited )
	end
end

local function loadedColumnBounds( bx, by )
	local cx, cy = math.floor( bx / MC.CS ), math.floor( by / MC.CS )
	local minZ, maxZ
	for _, chunk in pairs( MC.World or {} ) do
		if chunk.cx == cx and chunk.cy == cy and chunk.count and chunk.count > 0 then
			local bottom = chunk.cz * MC.CH
			local top = bottom + MC.CH - 1
			minZ = minZ and math.min( minZ, bottom ) or bottom
			maxZ = maxZ and math.max( maxZ, top ) or top
		end
	end
	return minZ, maxZ
end

local function markLightingDirtyColumn( bx, by, bz, rateLimited )
	invalidateSkyColumn( bx, by )
	local minZ, maxZ = loadedColumnBounds( bx, by )
	if not minZ then return end
	invalidateCacheBounds( bx, by, minZ, bx, by, maxZ )
	if MC.MarkRenderSectionsDirtyInBounds then
		MC.MarkRenderSectionsDirtyInBounds( bx, by, minZ, bx, by, maxZ, rateLimited )
	end
end

local function nearbySourceRadius( bx, by, bz )
	ensureLightSourceIndex()
	local radius = 0
	for _, source in pairs( MC.LightSourceCells or {} ) do
		local dist = math.abs( source.bx - bx ) + math.abs( source.by - by ) + math.abs( source.bz - bz )
		if dist <= source.level then
			radius = math.max( radius, source.level )
			if radius >= LIGHT_RADIUS then return LIGHT_RADIUS end
		end
	end
	return radius
end

function MC.MarkLightingDirtyForChange( bx, by, bz, oldId, oldOrient, newId, newOrient, rateLimited )
	oldId, newId = math.floor( tonumber( oldId ) or 0 ), math.floor( tonumber( newId ) or 0 )
	oldOrient, newOrient = math.floor( tonumber( oldOrient ) or 0 ), math.floor( tonumber( newOrient ) or 0 )
	MC.NoteLightingCellChanged( bx, by, bz, oldId, oldOrient, newId, newOrient )

	local oldEmission, newEmission = lightEmission( oldId ), lightEmission( newId )
	local oldOpacity, newOpacity = lightOpacity( oldId, oldOrient ), lightOpacity( newId, newOrient )
	if oldEmission ~= newEmission then
		MC.MarkLightingDirtyAroundCell( bx, by, bz, math.max( oldEmission, newEmission, 1 ), rateLimited )
	end
	if oldOpacity ~= newOpacity then
		markLightingDirtyColumn( bx, by, bz, rateLimited )
		MC.MarkLightingDirtyAroundCell( bx, by, bz, math.max( nearbySourceRadius( bx, by, bz ), 1 ), rateLimited )
	end
end

cvars.AddChangeCallback( "mc_light_enabled", function()
	MC.MarkAllMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_sky_level", function()
	MC.MarkAllMeshesDirty()
end, "mc" )

cvars.AddChangeCallback( "mc_light_ambient_min", function()
	MC.MarkAllMeshesDirty()
end, "mc" )
