MC = MC or {}
local GeometryStore = MC.RenderGeometryStore
local VertexBuffer = MC.RenderVertexBuffer
local LightBuffer = MC.RenderLightBuffer
local geometrySections

local RENDER_SECTION_SIZE = MC.RENDER_SECTION_SIZE or 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local DEFAULT_GEOMETRY_CACHE_SECTIONS = 384
local DEFAULT_BLOCK_EMIT_CACHE_SECTIONS = 1536

MC.Meshes = MC.Meshes or {}
MC.MeshesTrans = MC.MeshesTrans or {}
MC.MeshSections = MC.MeshSections or {}
geometrySections = GeometryStore.sections
MC.MeshSectionGeometryLRU = MC.MeshSectionGeometryLRU or {}
MC.MeshSectionGeometryLRUClock = MC.MeshSectionGeometryLRUClock or 0
MC.MeshSectionGeometryLRUCount = MC.MeshSectionGeometryLRUCount or 0
MC.MeshDirty = MC.MeshDirty or {}
MC.MeshLightDirty = MC.MeshLightDirty or {}
MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {}
MC.ChunkEnts = MC.ChunkEnts or {}
MC.PhysDirty = MC.PhysDirty or {}
MC.PhysDirtyPriority = MC.PhysDirtyPriority or {}
MC.PhysDirtyBulk = MC.PhysDirtyBulk or {}
MC.PhysDirtyBulkOrder = MC.PhysDirtyBulkOrder or {}
MC.PhysDirtyBulkOrderHead = MC.PhysDirtyBulkOrderHead or 1
MC.MeshBlockEmitCache = MC.MeshBlockEmitCache or {} -- key -> sectionIndex -> local block index -> emitted vertices/light
MC.MeshBlockEmitDirty = MC.MeshBlockEmitDirty or {} -- key -> sectionIndex -> local block index -> true
MC.MeshBlockLightDirty = MC.MeshBlockLightDirty or {} -- key -> sectionIndex -> local block index -> true
MC.MeshBlockEmitCacheLRU = MC.MeshBlockEmitCacheLRU or {}
MC.MeshBlockEmitCacheLRUClock = MC.MeshBlockEmitCacheLRUClock or 0
MC.MeshBlockEmitCacheLRUCount = MC.MeshBlockEmitCacheLRUCount or 0

local function tableEntryCount( t )
	local count = 0
	for _ in pairs( t or {} ) do count = count + 1 end
	return count
end

MC.MeshSectionGeometryLRUCount = tableEntryCount( MC.MeshSectionGeometryLRU )
MC.MeshBlockEmitCacheLRUCount = tableEntryCount( MC.MeshBlockEmitCacheLRU )

local function sectionSlotKey( key, sectionIndex )
	if type( key ) == "number" then return key * 64 + sectionIndex end
	return tostring( key ) .. "/" .. tostring( sectionIndex )
end

local function lruRemove( lru, countName, slot )
	if lru[slot] ~= nil then
		lru[slot] = nil
		MC[countName] = math.max( ( MC[countName] or 1 ) - 1, 0 )
	end
end

local function geometryCacheSectionLimit()
	local cv = MC.MeshGeometryCacheSections
	if not cv and CreateClientConVar then
		cv = CreateClientConVar( "mc_mesh_geometry_cache_sections", tostring( DEFAULT_GEOMETRY_CACHE_SECTIONS ), true, false, "Max client render sections that keep Lua vertex/light data for light-only recolor; lower saves RAM" )
		MC.MeshGeometryCacheSections = cv
	end
	local limit = cv and cv.GetInt and cv:GetInt() or DEFAULT_GEOMETRY_CACHE_SECTIONS
	return math.max( 0, tonumber( limit ) or DEFAULT_GEOMETRY_CACHE_SECTIONS )
end

local function blockEmitCacheSectionLimit()
	local cv = MC.MeshBlockEmitCacheSections
	if not cv and CreateClientConVar then
		cv = CreateClientConVar( "mc_mesh_block_emit_cache_sections", tostring( DEFAULT_BLOCK_EMIT_CACHE_SECTIONS ), true, false, "Max client render sections that keep per-block emitted vertex/light caches; lower saves RAM but increases full mesh emit work" )
		MC.MeshBlockEmitCacheSections = cv
	end
	local limit = cv and cv.GetInt and cv:GetInt() or DEFAULT_BLOCK_EMIT_CACHE_SECTIONS
	return math.max( 0, tonumber( limit ) or DEFAULT_BLOCK_EMIT_CACHE_SECTIONS )
end

function MC.ForgetMeshSectionGeometryCacheSlot( key, sectionIndex )
	if not key or not sectionIndex then return end
	lruRemove( MC.MeshSectionGeometryLRU, "MeshSectionGeometryLRUCount", sectionSlotKey( key, sectionIndex ) )
	if GeometryStore then
		GeometryStore.ClearSection( key, sectionIndex )
	else
		local sections = geometrySections[key]
		if sections then
			sections[sectionIndex] = nil
			if next( sections ) == nil then geometrySections[key] = nil end
		end
	end
end
if GeometryStore then GeometryStore.ForgetSection = MC.ForgetMeshSectionGeometryCacheSlot end

function MC.ForgetChunkMeshSectionGeometryCache( key )
	if not key then return end
	for slot, entry in pairs( MC.MeshSectionGeometryLRU ) do
		if entry and entry.key == key then lruRemove( MC.MeshSectionGeometryLRU, "MeshSectionGeometryLRUCount", slot ) end
	end
	if GeometryStore then
		GeometryStore.ClearChunk( key )
	else
		geometrySections[key] = nil
	end
end

function MC.ClearChunkMeshSectionGeometryLRU( key )
	if not key then return end
	for slot, entry in pairs( MC.MeshSectionGeometryLRU ) do
		if entry and entry.key == key then lruRemove( MC.MeshSectionGeometryLRU, "MeshSectionGeometryLRUCount", slot ) end
	end
end

function MC.TouchMeshSectionGeometryCache( key, sectionIndex )
	if not key or not sectionIndex then return end
	MC.MeshSectionGeometryLRUClock = ( MC.MeshSectionGeometryLRUClock or 0 ) + 1
	local slot = sectionSlotKey( key, sectionIndex )
	if MC.MeshSectionGeometryLRU[slot] == nil then
		MC.MeshSectionGeometryLRUCount = ( MC.MeshSectionGeometryLRUCount or 0 ) + 1
	end
	MC.MeshSectionGeometryLRU[slot] = {
		key = key,
		sectionIndex = sectionIndex,
		tick = MC.MeshSectionGeometryLRUClock,
	}
end
if GeometryStore then GeometryStore.TouchSection = MC.TouchMeshSectionGeometryCache end

function MC.PruneMeshSectionGeometryCache()
	local limit = geometryCacheSectionLimit()
	if ( MC.MeshSectionGeometryLRUCount or 0 ) <= limit then return end
	local lru = MC.MeshSectionGeometryLRU
	while true do
		local count, oldestSlot, oldestTick = 0, nil, nil
		for slot, entry in pairs( lru ) do
			local valid
			if GeometryStore then
				valid = entry and GeometryStore.GetSection( entry.key, entry.sectionIndex )
			else
				valid = entry and geometrySections[entry.key] and geometrySections[entry.key][entry.sectionIndex]
			end
			if valid then
				count = count + 1
				if not oldestTick or entry.tick < oldestTick then
					oldestTick = entry.tick
					oldestSlot = slot
				end
			else
				lruRemove( lru, "MeshSectionGeometryLRUCount", slot )
			end
		end
		MC.MeshSectionGeometryLRUCount = count
		if count <= limit or not oldestSlot then return end
		local oldest = lru[oldestSlot]
		if oldest then MC.ForgetMeshSectionGeometryCacheSlot( oldest.key, oldest.sectionIndex ) end
	end
end
if GeometryStore then GeometryStore.Prune = MC.PruneMeshSectionGeometryCache end

function MC.ForgetBlockEmitCacheSlot( key, sectionIndex )
	if not key or not sectionIndex then return end
	lruRemove( MC.MeshBlockEmitCacheLRU, "MeshBlockEmitCacheLRUCount", sectionSlotKey( key, sectionIndex ) )
	local cacheSections = MC.MeshBlockEmitCache[key]
	if cacheSections then
		cacheSections[sectionIndex] = nil
		if next( cacheSections ) == nil then MC.MeshBlockEmitCache[key] = nil end
	end
	local dirtySections = MC.MeshBlockEmitDirty[key]
	if dirtySections then
		dirtySections[sectionIndex] = nil
		if next( dirtySections ) == nil then MC.MeshBlockEmitDirty[key] = nil end
	end
	local lightDirtySections = MC.MeshBlockLightDirty[key]
	if lightDirtySections then
		lightDirtySections[sectionIndex] = nil
		if next( lightDirtySections ) == nil then MC.MeshBlockLightDirty[key] = nil end
	end
end

function MC.TouchBlockEmitCacheSection( key, sectionIndex )
	if not key or not sectionIndex then return end
	MC.MeshBlockEmitCacheLRUClock = ( MC.MeshBlockEmitCacheLRUClock or 0 ) + 1
	local slot = sectionSlotKey( key, sectionIndex )
	if MC.MeshBlockEmitCacheLRU[slot] == nil then
		MC.MeshBlockEmitCacheLRUCount = ( MC.MeshBlockEmitCacheLRUCount or 0 ) + 1
	end
	MC.MeshBlockEmitCacheLRU[slot] = {
		key = key,
		sectionIndex = sectionIndex,
		tick = MC.MeshBlockEmitCacheLRUClock,
	}
end

function MC.PruneBlockEmitCache()
	local limit = blockEmitCacheSectionLimit()
	if ( MC.MeshBlockEmitCacheLRUCount or 0 ) <= limit then return end
	local lru = MC.MeshBlockEmitCacheLRU
	while true do
		local count, oldestSlot, oldestTick = 0, nil, nil
		for slot, entry in pairs( lru ) do
			local valid = entry and MC.MeshBlockEmitCache[entry.key] and MC.MeshBlockEmitCache[entry.key][entry.sectionIndex]
			if valid then
				count = count + 1
				if not oldestTick or entry.tick < oldestTick then
					oldestTick = entry.tick
					oldestSlot = slot
				end
			else
				lruRemove( lru, "MeshBlockEmitCacheLRUCount", slot )
			end
		end
		MC.MeshBlockEmitCacheLRUCount = count
		if count <= limit or not oldestSlot then return end
		local oldest = lru[oldestSlot]
		if oldest then MC.ForgetBlockEmitCacheSlot( oldest.key, oldest.sectionIndex ) end
	end
end

if not MC.MarkChunkDirty then
	function MC.MarkChunkDirty( key )
		if not key then return end
		local size = 8
		local xy = math.ceil( MC.CS / size )
		local count = xy * xy * math.ceil( MC.CH / size )
		local sections = {}
		for sectionIndex = 1, count do sections[sectionIndex] = true end
		MC.MeshDirty[key] = sections
		MC.MeshLightDirty[key] = nil
		MC.MeshDirtyRateLimited[key] = nil
	end
end

if not MC.MarkChunkPhysDirty then
	function MC.MarkChunkPhysDirty( key, priority )
		if not key then return end
		MC.PhysDirty[key] = true
		if priority then
			MC.PhysDirtyPriority[key] = true
		else
			MC.PhysDirtyPriority[key] = nil
		end
	end
end

if not MC.MarkChunkPhysDirtyBulk then
	function MC.MarkChunkPhysDirtyBulk( key )
		if not key then return end
		MC.PhysDirty[key] = true
		MC.PhysDirtyPriority[key] = nil
		MC.PhysDirtyBulk[key] = true
		MC.PhysDirtyBulkOrder[#MC.PhysDirtyBulkOrder + 1] = key
		MC.PhysDirtyBulkOrderHead = MC.PhysDirtyBulkOrderHead or 1
	end
end

function MC.RenderSectionIndexForLocal( lx, ly, lz )
	local sx = math.floor( lx / RENDER_SECTION_SIZE )
	local sy = math.floor( ly / RENDER_SECTION_SIZE )
	local sz = math.floor( lz / RENDER_SECTION_SIZE )
	return sx + sy * RENDER_SECTIONS_XY + sz * RENDER_SECTIONS_XY * RENDER_SECTIONS_XY + 1
end

local function pruneBlockTable( store, key, sectionIndex )
	local sections = store and store[key]
	if not sections then return end
	local section = sections[sectionIndex]
	if section and next( section ) == nil then sections[sectionIndex] = nil end
	if next( sections ) == nil then store[key] = nil end
end

local function clearBlockDirtySlot( store, key, sectionIndex, li )
	local sections = store and store[key]
	local section = sections and sections[sectionIndex]
	if not section then return end
	section[li] = nil
	pruneBlockTable( store, key, sectionIndex )
end

function MC.ClearBlockCacheDirtySlot( key, sectionIndex, li )
	clearBlockDirtySlot( MC.MeshBlockEmitDirty, key, sectionIndex, li )
	clearBlockDirtySlot( MC.MeshBlockLightDirty, key, sectionIndex, li )
end

function MC.ClearSectionBlockEmitCache( key, sectionIndex )
	MC.ForgetBlockEmitCacheSlot( key, sectionIndex )
end

function MC.ClearSectionBlockEmitDirty( key, sectionIndex )
	local dirtySections = MC.MeshBlockEmitDirty[key]
	if dirtySections then
		dirtySections[sectionIndex] = nil
		if next( dirtySections ) == nil then MC.MeshBlockEmitDirty[key] = nil end
	end
end

function MC.ClearSectionBlockLightDirty( key, sectionIndex )
	local lightDirtySections = MC.MeshBlockLightDirty[key]
	if not lightDirtySections then return end
	lightDirtySections[sectionIndex] = nil
	if next( lightDirtySections ) == nil then MC.MeshBlockLightDirty[key] = nil end
end

function MC.ClearChunkBlockEmitCache( key )
	if not key then return end
	for slot, entry in pairs( MC.MeshBlockEmitCacheLRU or {} ) do
		if entry and entry.key == key then lruRemove( MC.MeshBlockEmitCacheLRU, "MeshBlockEmitCacheLRUCount", slot ) end
	end
	MC.MeshBlockEmitCache[key] = nil
	MC.MeshBlockEmitDirty[key] = nil
	MC.MeshBlockLightDirty[key] = nil
end

local function cellToBlockDirtySlot( bx, by, bz )
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	local lx, ly, lz = MC.DecodeLocal( li )
	return key, MC.RenderSectionIndexForLocal( lx, ly, lz ), li
end

function MC.MarkBlockEmitCacheDirty( bx, by, bz )
	local key, sectionIndex, li = cellToBlockDirtySlot( bx, by, bz )
	local cacheSections = MC.MeshBlockEmitCache[key]
	local dirtySections = MC.MeshBlockEmitDirty[key]
	if not cacheSections and not dirtySections and not ( MC.World and MC.World[key] ) then return end

	local cacheSection = cacheSections and cacheSections[sectionIndex]
	if cacheSection then
		cacheSection[li] = nil
		pruneBlockTable( MC.MeshBlockEmitCache, key, sectionIndex )
	end

	dirtySections = MC.MeshBlockEmitDirty[key]
	if not dirtySections then
		dirtySections = {}
		MC.MeshBlockEmitDirty[key] = dirtySections
	end
	local dirtySection = dirtySections[sectionIndex]
	if not dirtySection then
		dirtySection = {}
		dirtySections[sectionIndex] = dirtySection
	end
	dirtySection[li] = true

	local lightDirtySection = MC.MeshBlockLightDirty[key] and MC.MeshBlockLightDirty[key][sectionIndex]
	if lightDirtySection then
		lightDirtySection[li] = nil
		pruneBlockTable( MC.MeshBlockLightDirty, key, sectionIndex )
	end
end

function MC.MarkBlockLightCacheDirty( bx, by, bz )
	local key, sectionIndex, li = cellToBlockDirtySlot( bx, by, bz )
	local cacheSections = MC.MeshBlockEmitCache[key]
	local lightDirtySections = MC.MeshBlockLightDirty[key]
	if not cacheSections and not lightDirtySections and not ( MC.World and MC.World[key] ) then return end

	lightDirtySections = MC.MeshBlockLightDirty[key]
	if not lightDirtySections then
		lightDirtySections = {}
		MC.MeshBlockLightDirty[key] = lightDirtySections
	end
	local lightDirtySection = lightDirtySections[sectionIndex]
	if not lightDirtySection then
		lightDirtySection = {}
		lightDirtySections[sectionIndex] = lightDirtySection
	end
	lightDirtySection[li] = true
end

function MC.MarkLightCellBlockDirty( bx, by, bz )
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				MC.MarkBlockLightCacheDirty( bx + dx, by + dy, bz + dz )
			end
		end
	end
end

function MC.GetBlockLightDirtySection( key, sectionIndex )
	return MC.MeshBlockLightDirty[key] and MC.MeshBlockLightDirty[key][sectionIndex]
end

function MC.GetCachedBlockEmission( key, sectionIndex, li, id, orient, stateId )
	local dirtySection = MC.MeshBlockEmitDirty[key] and MC.MeshBlockEmitDirty[key][sectionIndex]
	if dirtySection and dirtySection[li] then return nil end
	local section = MC.MeshBlockEmitCache[key] and MC.MeshBlockEmitCache[key][sectionIndex]
	local record = section and section[li]
	if not record then return nil end
	if record.id ~= id or record.orient ~= ( orient or 0 ) then return nil end
	if stateId ~= nil and record.stateId ~= stateId then return nil end
	if not record.verts or not record.light then return nil end
	if not LightBuffer.Validate( record.light ) then return nil end
	local vertexCount = record.vertexCount or VertexBuffer.Count( record.verts )
	if vertexCount ~= VertexBuffer.Count( record.verts ) or vertexCount ~= #record.light then return nil end
	MC.TouchBlockEmitCacheSection( key, sectionIndex )
	return record
end

function MC.GetCachedBlockEmissionByLocalIndex( key, sectionIndex, li )
	local section = MC.MeshBlockEmitCache[key] and MC.MeshBlockEmitCache[key][sectionIndex]
	return section and section[li] or nil
end

function MC.DropBlockEmitCacheRecord( key, sectionIndex, li )
	local section = MC.MeshBlockEmitCache[key] and MC.MeshBlockEmitCache[key][sectionIndex]
	if not section then return end
	section[li] = nil
	pruneBlockTable( MC.MeshBlockEmitCache, key, sectionIndex )
end

function MC.StoreBlockEmissionCache( key, sectionIndex, li, id, orient, lightStyle, record, stateId )
	if not record then return nil end
	record.id = id
	record.orient = orient or 0
	record.stateId = stateId
	record.lightStyle = lightStyle
	record.vertexCount = record.vertexCount or VertexBuffer.Count( record.verts )
	record.hasSecondaryUV = record.hasSecondaryUV == true
	if record.vertexCount <= 0 then
		MC.DropBlockEmitCacheRecord( key, sectionIndex, li )
		MC.ClearBlockCacheDirtySlot( key, sectionIndex, li )
		return nil
	end

	local sections = MC.MeshBlockEmitCache[key]
	if not sections then
		sections = {}
		MC.MeshBlockEmitCache[key] = sections
	end
	local section = sections[sectionIndex]
	if not section then
		section = {}
		sections[sectionIndex] = section
	end

	section[li] = record
	MC.TouchBlockEmitCacheSection( key, sectionIndex )

	MC.ClearBlockCacheDirtySlot( key, sectionIndex, li )
	return record
end

function MC.AppendCachedBlockEmission( record, buf, flushFn, meshPerf, vertexLimit )
	if not record or not buf then return 0 end
	local verts = record.verts or {}
	local light = record.light or {}
	local vertexCount = record.vertexCount or VertexBuffer.Count( verts )
	vertexLimit = vertexLimit or 64998
	local outVerts = buf.verts
	local outLight = buf.light
	local nv = buf.nv or 0
	local pushed = 0
	local tableMove = table.move
	if record.hasSecondaryUV then buf.hasSecondaryUV = true end
	if outVerts.vertexBufferVersion then
		local offset = 1
		while offset <= vertexCount do
			if nv >= vertexLimit and flushFn then
				buf.nv = nv
				flushFn( buf )
				outVerts, outLight, nv = buf.verts, buf.light, buf.nv
			end
			local count = vertexCount - offset + 1
			if flushFn then count = math.min( count, vertexLimit - nv ) end
			if count <= 0 then break end
			-- flush resets this flag; reapply it for every split batch.
			if record.hasSecondaryUV then buf.hasSecondaryUV = true end
			VertexBuffer.AppendRange( outVerts, verts, offset, count )
			LightBuffer.AppendRange( outLight, light, offset, count )
			nv, offset, pushed = nv + count, offset + count, pushed + count
			if nv >= vertexLimit and flushFn then
				buf.nv = nv
				flushFn( buf )
				outVerts, outLight, nv = buf.verts, buf.light, buf.nv
			end
		end
	elseif tableMove then
		local offset = 1
		while offset <= vertexCount do
			if nv >= vertexLimit and flushFn then
				buf.nv = nv
				if meshPerf and pushed > 0 then
					meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + pushed
					pushed = 0
				end
				flushFn( buf )
				outVerts = buf.verts
				outLight = buf.light
				nv = buf.nv or 0
			end
			local chunkCount = vertexCount - offset + 1
			if flushFn then
				local room = vertexLimit - nv
				if chunkCount > room then chunkCount = room end
			end
			if chunkCount <= 0 then break end
			tableMove( verts, offset, offset + chunkCount - 1, nv + 1, outVerts )
			LightBuffer.AppendRange( outLight, light, offset, chunkCount )
			nv = nv + chunkCount
			offset = offset + chunkCount
			pushed = pushed + chunkCount
			if nv >= vertexLimit and flushFn then
				buf.nv = nv
				if meshPerf and pushed > 0 then
					meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + pushed
					pushed = 0
				end
				flushFn( buf )
				outVerts = buf.verts
				outLight = buf.light
				nv = buf.nv or 0
			end
		end
	else
		for i = 1, vertexCount do
			nv = nv + 1
			outVerts[nv] = verts[i]
			LightBuffer.AppendRange( outLight, light, i, 1 )
			pushed = pushed + 1
			if nv >= vertexLimit and flushFn then
				buf.nv = nv
				if meshPerf and pushed > 0 then
					meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + pushed
					pushed = 0
				end
				flushFn( buf )
				outVerts = buf.verts
				outLight = buf.light
				nv = buf.nv or 0
			end
		end
	end
	buf.nv = nv
	if meshPerf and pushed > 0 then
		meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + pushed
	end
	return vertexCount
end

local function cachedBlockLightMetaKey( meta )
	if not meta then return nil end
	if meta.recolorKey ~= nil then return meta.recolorKey end
	local RM = MC.RenderMesh
	local meshRecolorKey = RM and RM.meshRecolorKey
	if not meshRecolorKey then return nil end
	local key = meshRecolorKey( meta.shadeIndex, meta.bx, meta.by, meta.bz, meta.faceIndex, meta.cx, meta.cy, meta.cz, meta.selfEmission, meta.tintCode )
	meta.recolorKey = key
	return key
end

function MC.CachedBlockLightMetaKey( meta )
	return cachedBlockLightMetaKey( meta )
end

function MC.CachedBlockLightKey( light, index )
	local RM = MC.RenderMesh
	return LightBuffer.RecolorKey( light, index, RM and RM.meshRecolorKey )
end

function MC.RecolorCachedBlockEmission( record, lightStyle, recolorFn, meshPerf )
	if not record or not recolorFn then return false end
	local verts = record.verts or {}
	local light = record.light or {}
	local vertexCount = record.vertexCount or VertexBuffer.Count( verts )
	if not LightBuffer.IsCompatible( light )
		or vertexCount ~= VertexBuffer.Count( verts ) or vertexCount ~= #light then return false end
	local colorCache = {}
	local metaScratch = {}
	local style = lightStyle
	local recolor = recolorFn
	for i = 1, vertexCount do
		local key
		if light.lightBufferVersion then
			-- Indexed samples already encode identity without the legacy key's
			-- 16-cell coordinate wrap (animation batches span a whole chunk).
			key = light[i]
		else
			key = MC.CachedBlockLightKey( light, i )
		end
		if key == nil then return false end
		local color = colorCache[key]
		if color == nil then
			local meta = LightBuffer.Read( light, i, metaScratch )
			if not meta or meta.shadeIndex == nil then return false end
			color = recolor( meta, style )
			colorCache[key] = color
		end
		VertexBuffer.SetColor( verts, i, color )
	end
	record.lightStyle = lightStyle
	return true, vertexCount
end

local function clearRecordRecolorKeys( record )
	local light = record and record.light
	if light then LightBuffer.ClearRecolorKeys( light ) end
end

function MC.ClearCachedBlockRecolorKeys()
	for _, sections in pairs( geometrySections or {} ) do
		for _, section in pairs( sections or {} ) do
			for _, record in ipairs( section.opaque or {} ) do clearRecordRecolorKeys( record ) end
			for _, record in ipairs( section.translucent or {} ) do clearRecordRecolorKeys( record ) end
		end
	end
	for _, sections in pairs( MC.MeshBlockEmitCache or {} ) do
		for _, section in pairs( sections or {} ) do
			for _, record in pairs( section or {} ) do clearRecordRecolorKeys( record ) end
		end
	end
end

MC.ClearCachedBlockRecolorKeys()

function MC.PruneEmptyBlockEmissionCacheRecords()
	for key, sections in pairs( MC.MeshBlockEmitCache or {} ) do
		for sectionIndex, section in pairs( sections or {} ) do
			for li, record in pairs( section or {} ) do
				if not record or ( record.vertexCount or VertexBuffer.Count( record.verts ) ) <= 0 then
					section[li] = nil
				end
			end
			pruneBlockTable( MC.MeshBlockEmitCache, key, sectionIndex )
		end
	end
end

MC.PruneEmptyBlockEmissionCacheRecords()
