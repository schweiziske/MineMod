-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local currentLightStyle = RM.currentLightStyle
local currentLightProfile = RM.CurrentLightProfile
local newMeshPerfStats = RM.newMeshPerfStats
local meshEmitProbeEnabled = RM.meshEmitProbeEnabled
local resetMeshLightingSampleCaches = RM.resetMeshLightingSampleCaches
local resetMeshColorObjectCache = RM.resetMeshColorObjectCache
local meshPerfAdd = RM.meshPerfAdd
local meshPerfMS = RM.meshPerfMS
local publishMeshPerfStats = RM.publishMeshPerfStats
local noteMeshLightingCacheStats = RM.noteMeshLightingCacheStats
local printMeshEmitProbe = RM.printMeshEmitProbe
local destroySectionMeshList = RM.destroySectionMeshList
local rebuildFlatMeshLists = RM.rebuildFlatMeshLists
local recolorCachedBlockEmission = RM.recolorCachedBlockEmission
local recolorLightMeta = RM.recolorLightMeta
local effectiveLightStyleForMaterial = RM.effectiveLightStyleForMaterial
local setMeshSampleCacheOrigin = RM.setMeshSampleCacheOrigin
local uploadMeshVertices = RM.uploadMeshVertices

function MC.BuildChunkMesh( key, sectionIndex )
	local buildStart = SysTime()
	local meshPerf = newMeshPerfStats()
	local meshProbe = meshEmitProbeEnabled()
	resetMeshLightingSampleCaches()
	resetMeshColorObjectCache()
	local meshLightStyle = currentLightStyle()
	local meshLightProfile = currentLightProfile()
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshLightStyle = meshLightStyle
	end
	if MC.LightPerfBeginMeshBuild then
		MC.LightPerfBeginMeshBuild( key, sectionIndex )
	end
	if not sectionIndex then
		local destroyStart = SysTime()
		MC.FreeChunkMesh( key )
		meshPerfAdd( meshPerf, "destroyMS", destroyStart )
	end

	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count == 0 then
		if sectionIndex then
			MC.ClearSectionBlockEmitCache( key, sectionIndex )
			local commitStart = SysTime()
			local sections = MC.MeshSections[key]
			local old = sections and sections[sectionIndex]
			if old then
				local destroyStart = SysTime()
				destroySectionMeshList( old.opaque )
				destroySectionMeshList( old.translucent )
				meshPerfAdd( meshPerf, "destroyMS", destroyStart )
				sections[sectionIndex] = nil
				if MC.ForgetMeshSectionGeometryCacheSlot then
					MC.ForgetMeshSectionGeometryCacheSlot( key, sectionIndex )
				elseif MC.MeshSectionGeometry[key] then
					MC.MeshSectionGeometry[key][sectionIndex] = nil
				end
				local flatStart = SysTime()
				rebuildFlatMeshLists( key )
				meshPerfAdd( meshPerf, "flatMS", flatStart )
			end
			meshPerfAdd( meshPerf, "commitMS", commitStart )
		else
			MC.FreeChunkMesh( key )
		end
		local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
		MC.RenderStats.lastMeshBuildMS = meshMS
		MC.RenderStats.lastMeshKey = key
		MC.RenderStats.lastMeshSection = sectionIndex or "full"
		MC.RenderStats.lastMeshBlocks = 0
		MC.RenderStats.lastMeshVertices = 0
		MC.RenderStats.lastMeshFaces = 0
		MC.RenderStats.lastOpaqueMeshes = 0
		MC.RenderStats.lastTranslucentMeshes = 0
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "full"
			MC.LightPerfStats.lastMeshRecords = nil
			MC.LightPerfStats.lastMeshFallback = nil
		end
		meshPerf.prepMS = meshPerfMS( buildStart )
		publishMeshPerfStats( meshPerf )
		noteMeshLightingCacheStats()
		printMeshEmitProbe( key, sectionIndex, meshMS, meshPerf )
		if MC.LightPerfEndMeshBuild then
			MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
		end
		return
	end
	local ctx = RM.NewBuildContext( key, sectionIndex, chunk, meshPerf, meshProbe, meshLightStyle, buildStart, meshLightProfile )

	local loopStart = SysTime()
	for li, id in pairs( ctx.blockIter ) do
		RM.EmitBlock( ctx, li, id )
	end
	meshPerfAdd( meshPerf, "loopMS", loopStart )

	local flushStart = SysTime()
	local opaqueMeshes, translucentMeshes, opaqueRecords, translucentRecords = ctx.flushSectionBuffers()
	meshPerfAdd( meshPerf, "flushMS", flushStart )

	local commitStart = SysTime()
	if sectionIndex then
		MC.MeshSections[key] = MC.MeshSections[key] or {}
		MC.MeshSectionGeometry[key] = MC.MeshSectionGeometry[key] or {}
		local old = MC.MeshSections[key][sectionIndex]
		if old then
			local destroyStart = SysTime()
			destroySectionMeshList( old.opaque )
			destroySectionMeshList( old.translucent )
			meshPerfAdd( meshPerf, "destroyMS", destroyStart )
		end
		if #opaqueMeshes > 0 or #translucentMeshes > 0 then
			MC.MeshSections[key][sectionIndex] = { opaque = opaqueMeshes, translucent = translucentMeshes }
			MC.MeshSectionGeometry[key][sectionIndex] = { opaque = opaqueRecords, translucent = translucentRecords }
			if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, sectionIndex ) end
		else
			MC.MeshSections[key][sectionIndex] = nil
			MC.ClearSectionBlockEmitCache( key, sectionIndex )
			if MC.ForgetMeshSectionGeometryCacheSlot then
				MC.ForgetMeshSectionGeometryCacheSlot( key, sectionIndex )
			else
				MC.MeshSectionGeometry[key][sectionIndex] = nil
			end
		end
		MC.ClearSectionBlockEmitDirty( key, sectionIndex )
		MC.ClearSectionBlockLightDirty( key, sectionIndex )
		if MC.MeshLightDirty[key] then MC.MeshLightDirty[key][sectionIndex] = nil end
		local flatStart = SysTime()
		rebuildFlatMeshLists( key )
		meshPerfAdd( meshPerf, "flatMS", flatStart )
	else
		MC.MeshSections[key] = {}
		MC.MeshSectionGeometry[key] = {}
		if MC.ClearChunkMeshSectionGeometryLRU then MC.ClearChunkMeshSectionGeometryLRU( key ) end
		local totalSections = C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = ctx.sectionBuffers[i]
			if buffers then
				MC.MeshSections[key][i] = {
					opaque = buffers.opaque.list,
					translucent = buffers.translucent.list,
				}
				MC.MeshSectionGeometry[key][i] = {
					opaque = buffers.opaque.records,
					translucent = buffers.translucent.records,
				}
				if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, i ) end
			end
		end
		MC.MeshLightDirty[key] = nil
		local flatStart = SysTime()
		rebuildFlatMeshLists( key )
		meshPerfAdd( meshPerf, "flatMS", flatStart )
	end
	if MC.PruneMeshSectionGeometryCache then MC.PruneMeshSectionGeometryCache() end
	if MC.PruneBlockEmitCache then MC.PruneBlockEmitCache() end
	meshPerfAdd( meshPerf, "commitMS", commitStart )
	local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.RenderStats.lastMeshBuildMS = meshMS
	MC.RenderStats.lastMeshKey = key
	MC.RenderStats.lastMeshSection = sectionIndex or "full"
	MC.RenderStats.lastMeshBlocks = chunk.count or 0
	MC.RenderStats.lastMeshVertices = meshPerf.vertices
	MC.RenderStats.lastMeshFaces = meshPerf.faces
	MC.RenderStats.lastOpaqueMeshes = #opaqueMeshes
	MC.RenderStats.lastTranslucentMeshes = #translucentMeshes
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshMode = "full"
		MC.LightPerfStats.lastMeshRecords = nil
		MC.LightPerfStats.lastMeshFallback = nil
	end
	publishMeshPerfStats( meshPerf )
	noteMeshLightingCacheStats()
	printMeshEmitProbe( key, sectionIndex, meshMS, meshPerf )
	if MC.LightPerfEndMeshBuild then
		MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
	end
end

------------------------------------------------------------------------- drawing

function MC.RebuildChunkMeshLighting( key, sectionIndex )
	if not sectionIndex then return MC.BuildChunkMesh( key ) end
	local buildStart = SysTime()
	local meshPerf = newMeshPerfStats()
	resetMeshLightingSampleCaches()
	resetMeshColorObjectCache()
	local meshLightStyle = currentLightStyle()
	local meshLightProfile = currentLightProfile()
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshLightStyle = meshLightStyle
	end
	if MC.LightPerfBeginMeshBuild then
		MC.LightPerfBeginMeshBuild( key, sectionIndex )
	end

	local chunk = MC.GetChunkByKey( key )
	local section = MC.MeshSectionGeometry[key] and MC.MeshSectionGeometry[key][sectionIndex]
	if not chunk or chunk.count == 0 or not section then
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "fallback"
			MC.LightPerfStats.lastMeshFallback = "missing_cache"
		end
		return MC.BuildChunkMesh( key, sectionIndex )
	end

	setMeshSampleCacheOrigin( chunk.cx * C.CS, chunk.cy * C.CS, chunk.cz * C.CH )
	meshPerf.prepMS = meshPerfMS( buildStart )

	local scannedRecords, updatedRecords = 0, 0
	local blockLightDirtySection = MC.GetBlockLightDirtySection and MC.GetBlockLightDirtySection( key, sectionIndex ) or nil
	local blockEmitCacheSection = blockLightDirtySection and MC.MeshBlockEmitCache[key] and MC.MeshBlockEmitCache[key][sectionIndex] or nil
	local chunkBaseX, chunkBaseY, chunkBaseZ = chunk.cx * C.CS, chunk.cy * C.CS, chunk.cz * C.CH
	local cachedBlockLightMetaKey = MC.CachedBlockLightMetaKey
	local function metaLocalIndex( meta )
		local li = meta and meta.li
		if li ~= nil then return li end
		if not meta or meta.bx == nil or meta.by == nil or meta.bz == nil then return nil end
		local lx, ly, lz = meta.bx - chunkBaseX, meta.by - chunkBaseY, meta.bz - chunkBaseZ
		if lx < 0 or lx >= C.CS or ly < 0 or ly >= C.CS or lz < 0 or lz >= C.CH then return nil end
		li = lx + ly * C.CS + lz * C.CS2
		meta.li = li
		return li
	end

	local function ensureRecordLightIndexByLi( record, light, vertexCount )
		local byLi = record.lightByLi
		if byLi ~= nil then return byLi end
		byLi = {}
		for i = 1, vertexCount do
			local li = metaLocalIndex( light[i] )
			if li ~= nil then
				local list = byLi[li]
				if not list then
					list = { n = 0 }
					byLi[li] = list
				end
				local n = list.n + 1
				list.n = n
				list[n] = i
			end
		end
		record.lightByLi = byLi
		return byLi
	end

	local function recolorDirtyRecordVertices( record )
		if not blockLightDirtySection then return true, true end
		if not cachedBlockLightMetaKey or not recolorLightMeta then return false, false end
		local verts = record and record.verts
		local light = record and record.light
		local vertexCount = #( verts or {} )
		if not verts or not light or vertexCount ~= #verts or vertexCount ~= #light then return false, false end
		local lightByLi = ensureRecordLightIndexByLi( record, light, vertexCount )
		local colorCache = {}
		local recolored = false
		local style = effectiveLightStyleForMaterial( meshLightStyle, record.material, meshLightProfile )
		for li in pairs( blockLightDirtySection ) do
			local vertexIndexes = lightByLi[li]
			if vertexIndexes then
				for j = 1, vertexIndexes.n do
					local i = vertexIndexes[j]
					local meta = light[i]
					if not meta then return false, false end
					local recolorKey = cachedBlockLightMetaKey( meta )
					if recolorKey == nil then return false, false end
					local color = colorCache[recolorKey]
					if color == nil then
						color = recolorLightMeta( meta, style )
						colorCache[recolorKey] = color
					end
					verts[i].color = color
					recolored = true
				end
			end
		end
		return true, recolored
	end

	local function recolorDirtyBlockRecords()
		if not blockLightDirtySection then return true end
		if not blockEmitCacheSection then return true end
		for li in pairs( blockLightDirtySection ) do
			local blockRecord = blockEmitCacheSection[li]
			if blockRecord then
				local recolorStart = SysTime()
				local recordStyle = effectiveLightStyleForMaterial( meshLightStyle, blockRecord.material, meshLightProfile )
				local ok = recolorCachedBlockEmission( blockRecord, recordStyle, meshPerf )
				meshPerfAdd( meshPerf, "recolorMS", recolorStart )
				if not ok then return false end
				meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
			end
		end
		return true
	end

	local function updateRecord( record, translucent, recolorWholeRecord )
		scannedRecords = scannedRecords + 1
		if not record or not record.mesh or not record.verts or not record.light then return false end
		if #record.verts ~= #record.light then return false end
		local vertexCount = #record.verts
		if recolorWholeRecord then
			local recolorStart = SysTime()
			local recordStyle = effectiveLightStyleForMaterial( meshLightStyle, record.material, meshLightProfile )
			if not recolorCachedBlockEmission( record, recordStyle, meshPerf ) then return false end
			meshPerfAdd( meshPerf, "recolorMS", recolorStart )
		else
			local recolorStart = SysTime()
			local ok, changed = recolorDirtyRecordVertices( record )
			if not ok then return false end
			if not changed then return true, false end
			meshPerfAdd( meshPerf, "recolorMS", recolorStart )
		end
		uploadMeshVertices( record.mesh, record.verts, meshPerf, record.hasSecondaryUV )
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		updatedRecords = updatedRecords + 1
		return true, true
	end

	local function updateList( list, translucent, recolorWholeRecord )
		for i = 1, #( list or {} ) do
			if not updateRecord( list[i], translucent, recolorWholeRecord ) then return false end
		end
		return true
	end

	local loopStart = SysTime()
	local recolorWholeRecord = not blockLightDirtySection
	local updateOK = recolorDirtyBlockRecords()
		and updateList( section.opaque, false, recolorWholeRecord )
		and updateList( section.translucent, true, recolorWholeRecord )
	meshPerfAdd( meshPerf, "loopMS", loopStart )
	if not updateOK then
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "fallback"
			MC.LightPerfStats.lastMeshFallback = "invalid_cache"
			MC.LightPerfStats.lastMeshRecords = tostring( updatedRecords ) .. "/" .. tostring( scannedRecords )
		end
		return MC.BuildChunkMesh( key, sectionIndex )
	end
	MC.ClearSectionBlockLightDirty( key, sectionIndex )
	if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, sectionIndex ) end
	if MC.PruneMeshSectionGeometryCache then MC.PruneMeshSectionGeometryCache() end

	local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.RenderStats.lastMeshBuildMS = meshMS
	MC.RenderStats.lastMeshKey = key
	MC.RenderStats.lastMeshSection = sectionIndex
	MC.RenderStats.lastMeshBlocks = chunk.count or 0
	MC.RenderStats.lastMeshVertices = meshPerf.vertices
	MC.RenderStats.lastMeshFaces = meshPerf.faces
	MC.RenderStats.lastOpaqueMeshes = #( section.opaque or {} )
	MC.RenderStats.lastTranslucentMeshes = #( section.translucent or {} )
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshMode = "light"
		MC.LightPerfStats.lastMeshRecords = tostring( updatedRecords ) .. "/" .. tostring( scannedRecords )
		MC.LightPerfStats.lastMeshFallback = nil
	end
	publishMeshPerfStats( meshPerf )
	noteMeshLightingCacheStats()
	if MC.LightPerfEndMeshBuild then
		MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
	end
end
