-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local meshBeginUploadEnabled = function()
	local cv = MC.MeshBeginUpload
	return not cv or cv:GetBool()
end

local function meshEmitProbeEnabled()
	local cv = MC.MeshEmitProbe
	return cv and cv:GetBool() or false
end

local function newMeshPerfStats()
	return {
		vertices = 0,
		faces = 0,
		meshes = 0,
		opaqueVerts = 0,
		translucentVerts = 0,
		blocksVisited = 0,
		blocksRendered = 0,
		blockCacheHits = 0,
		blockCacheMisses = 0,
		blockCacheRecolors = 0,
		fullCubeBlocks = 0,
		shapeBlocks = 0,
		modelBlocks = 0,
		liquidBlocks = 0,
		crossBlocks = 0,
		prepMS = 0,
		indexMS = 0,
		loopMS = 0,
		emitMS = 0,
		fullCubeMS = 0,
		shapeMS = 0,
		modelMS = 0,
		liquidMS = 0,
		crossMS = 0,
		flushMS = 0,
		meshNewMS = 0,
		buildTriMS = 0,
		meshBeginUploads = 0,
		buildTriangleUploads = 0,
		destroyMS = 0,
		commitMS = 0,
		flatMS = 0,
		recolorMS = 0,
		cacheAppendMS = 0,
		fullVisibleMS = 0,
		fullFaceMS = 0,
		fullColorMS = 0,
		fullVertexMS = 0,
		fullMetaMS = 0,
		fullPushMS = 0,
		fullVisibleFaces = 0,
		fullDirectBlocks = 0,
	}
end

local function meshPerfElapsedMS( startTime )
	return ( SysTime() - startTime ) * 1000
end

local function meshPerfRoundMS( value )
	return math.Round( value or 0, 3 )
end

local function meshPerfMS( startTime )
	return meshPerfRoundMS( meshPerfElapsedMS( startTime ) )
end

local function meshPerfAdd( perf, field, startTime )
	if not perf or not field or not startTime then return end
	perf[field] = ( perf[field] or 0 ) + meshPerfElapsedMS( startTime )
end

local function uploadMeshVertices( meshObj, verts, perf )
	if meshBeginUploadEnabled() and mesh and mesh.Begin and meshObj then
		local vertexCount = #verts
		local triCount = math.floor( vertexCount / 3 )
		local uploadStart = SysTime()
		local meshBegin = mesh.Begin
		local meshPosition = mesh.Position
		local meshNormal = mesh.Normal
		local meshTexCoord = mesh.TexCoord
		local meshColor = mesh.Color
		local meshAdvanceVertex = mesh.AdvanceVertex
		local meshEnd = mesh.End
		meshBegin( meshObj, MATERIAL_TRIANGLES, triCount )
		for i = 1, vertexCount do
			local vert = verts[i]
			local pos = vert.pos
			local normal = vert.normal
			local color = vert.color
			meshPosition( pos )
			if normal then meshNormal( normal ) end
			meshTexCoord( 0, vert.u or 0, vert.v or 0 )
			if color then
				meshColor( color.r or 255, color.g or 255, color.b or 255, color.a or 255 )
			else
				meshColor( 255, 255, 255, 255 )
			end
			meshAdvanceVertex()
		end
		meshEnd()
		meshPerfAdd( perf, "buildTriMS", uploadStart )
		if perf then perf.meshBeginUploads = ( perf.meshBeginUploads or 0 ) + 1 end
		return "begin"
	end

	local uploadStart = SysTime()
	meshObj:BuildFromTriangles( verts )
	meshPerfAdd( perf, "buildTriMS", uploadStart )
	if perf then perf.buildTriangleUploads = ( perf.buildTriangleUploads or 0 ) + 1 end
	return "triangles"
end

local function meshPerfAddBlockKind( perf, kind )
	if kind == "fullCube" then
		perf.fullCubeBlocks = perf.fullCubeBlocks + 1
	elseif kind == "model" then
		perf.modelBlocks = perf.modelBlocks + 1
	elseif kind == "liquid" then
		perf.liquidBlocks = perf.liquidBlocks + 1
	elseif kind == "cross" then
		perf.crossBlocks = perf.crossBlocks + 1
	else
		perf.shapeBlocks = perf.shapeBlocks + 1
	end
end

local function meshPerfAddKindDuration( perf, kind, durationMS )
	if kind == "fullCube" then
		perf.fullCubeMS = perf.fullCubeMS + durationMS
	elseif kind == "model" then
		perf.modelMS = perf.modelMS + durationMS
	elseif kind == "liquid" then
		perf.liquidMS = perf.liquidMS + durationMS
	elseif kind == "cross" then
		perf.crossMS = perf.crossMS + durationMS
	else
		perf.shapeMS = perf.shapeMS + durationMS
	end
end

local function shouldStoreBlockEmissionCache( kind, vertexCount )
	if vertexCount <= 0 then return false end
	if kind == "fullCube" and vertexCount <= 12 then return false end
	return true
end

local function publishMeshPerfStats( perf )
	local stats = MC.LightPerfStats
	if not stats or not perf then return end
	stats.lastMeshVertices = perf.vertices or 0
	stats.lastMeshFaces = perf.faces or 0
	stats.lastMeshMeshes = perf.meshes or 0
	stats.lastMeshOpaqueVerts = perf.opaqueVerts or 0
	stats.lastMeshTranslucentVerts = perf.translucentVerts or 0
	stats.lastMeshBlocksVisited = perf.blocksVisited or 0
	stats.lastMeshBlocksRendered = perf.blocksRendered or 0
	stats.lastMeshBlockCacheHits = perf.blockCacheHits or 0
	stats.lastMeshBlockCacheMisses = perf.blockCacheMisses or 0
	stats.lastMeshBlockCacheRecolors = perf.blockCacheRecolors or 0
	stats.lastMeshFullCubeBlocks = perf.fullCubeBlocks or 0
	stats.lastMeshShapeBlocks = perf.shapeBlocks or 0
	stats.lastMeshModelBlocks = perf.modelBlocks or 0
	stats.lastMeshLiquidBlocks = perf.liquidBlocks or 0
	stats.lastMeshCrossBlocks = perf.crossBlocks or 0
	stats.lastMeshPrepMS = meshPerfRoundMS( perf.prepMS )
	stats.lastMeshIndexMS = meshPerfRoundMS( perf.indexMS )
	stats.lastMeshLoopMS = meshPerfRoundMS( perf.loopMS )
	stats.lastMeshEmitMS = meshPerfRoundMS( perf.emitMS )
	stats.lastMeshFullCubeMS = meshPerfRoundMS( perf.fullCubeMS )
	stats.lastMeshShapeMS = meshPerfRoundMS( perf.shapeMS )
	stats.lastMeshModelMS = meshPerfRoundMS( perf.modelMS )
	stats.lastMeshLiquidMS = meshPerfRoundMS( perf.liquidMS )
	stats.lastMeshCrossMS = meshPerfRoundMS( perf.crossMS )
	stats.lastMeshFlushMS = meshPerfRoundMS( perf.flushMS )
	stats.lastMeshMeshNewMS = meshPerfRoundMS( perf.meshNewMS )
	stats.lastMeshBuildTrianglesMS = meshPerfRoundMS( perf.buildTriMS )
	stats.lastMeshBeginUploads = perf.meshBeginUploads or 0
	stats.lastMeshBuildTriangleUploads = perf.buildTriangleUploads or 0
	stats.lastMeshUploadMode = ( perf.meshBeginUploads or 0 ) > 0 and "begin" or "triangles"
	stats.lastMeshDestroyMS = meshPerfRoundMS( perf.destroyMS )
	stats.lastMeshCommitMS = meshPerfRoundMS( perf.commitMS )
	stats.lastMeshFlatMS = meshPerfRoundMS( perf.flatMS )
	stats.lastMeshRecolorMS = meshPerfRoundMS( perf.recolorMS )
	stats.lastMeshCacheAppendMS = meshPerfRoundMS( perf.cacheAppendMS )
	stats.lastMeshFullVisibleMS = meshPerfRoundMS( perf.fullVisibleMS )
	stats.lastMeshFullFaceMS = meshPerfRoundMS( perf.fullFaceMS )
	stats.lastMeshFullColorMS = meshPerfRoundMS( perf.fullColorMS )
	stats.lastMeshFullVertexMS = meshPerfRoundMS( perf.fullVertexMS )
	stats.lastMeshFullMetaMS = meshPerfRoundMS( perf.fullMetaMS )
	stats.lastMeshFullPushMS = meshPerfRoundMS( perf.fullPushMS )
	stats.lastMeshFullVisibleFaces = perf.fullVisibleFaces or 0
	stats.lastMeshFullDirectBlocks = perf.fullDirectBlocks or 0
end

local function printMeshEmitProbe( key, sectionIndex, meshMS, perf )
	if not meshEmitProbeEnabled() or not perf then return end
	local parts = { "[MC mesh probe]" }
	local function add( name, value )
		if value ~= nil then parts[#parts + 1] = name .. "=" .. tostring( value ) end
	end
	add( "ms", meshMS )
	add( "key", key )
	add( "sec", sectionIndex or "full" )
	add( "verts", perf.vertices or 0 )
	add( "faces", math.floor( ( perf.vertices or 0 ) / 6 ) )
	add( "blocks", perf.blocksVisited or 0 )
	add( "emitted", perf.blocksRendered or 0 )
	add( "cache", tostring( perf.blockCacheHits or 0 ) .. "/" .. tostring( perf.blockCacheMisses or 0 ) )
	add( "cacheAppendMS", meshPerfRoundMS( perf.cacheAppendMS ) )
	add( "emitMS", meshPerfRoundMS( perf.emitMS ) )
	add( "fullMS", meshPerfRoundMS( perf.fullCubeMS ) )
	add( "fullBlocks", perf.fullCubeBlocks or 0 )
	add( "fullFaces", perf.fullVisibleFaces or 0 )
	add( "fullDirect", perf.fullDirectBlocks or 0 )
	add( "fullVisibleMS", meshPerfRoundMS( perf.fullVisibleMS ) )
	add( "fullFaceMS", meshPerfRoundMS( perf.fullFaceMS ) )
	add( "fullColorMS", meshPerfRoundMS( perf.fullColorMS ) )
	add( "fullVertexMS", meshPerfRoundMS( perf.fullVertexMS ) )
	add( "fullMetaMS", meshPerfRoundMS( perf.fullMetaMS ) )
	add( "fullPushMS", meshPerfRoundMS( perf.fullPushMS ) )
	add( "shapeMS", meshPerfRoundMS( perf.shapeMS ) )
	add( "modelMS", meshPerfRoundMS( perf.modelMS ) )
	add( "flushMS", meshPerfRoundMS( perf.flushMS ) )
	add( "buildTriMS", meshPerfRoundMS( perf.buildTriMS ) )
	add( "upload", ( perf.meshBeginUploads or 0 ) > 0 and "begin" or "triangles" )
	add( "beginUploads", perf.meshBeginUploads or 0 )
	add( "triUploads", perf.buildTriangleUploads or 0 )
	print( table.concat( parts, " " ) )
end

RM.meshEmitProbeEnabled = meshEmitProbeEnabled
RM.meshBeginUploadEnabled = meshBeginUploadEnabled
RM.newMeshPerfStats = newMeshPerfStats
RM.meshPerfElapsedMS = meshPerfElapsedMS
RM.meshPerfRoundMS = meshPerfRoundMS
RM.meshPerfMS = meshPerfMS
RM.meshHasSecondaryUV = meshHasSecondaryUV
RM.meshPerfAdd = meshPerfAdd
RM.uploadMeshVertices = uploadMeshVertices
RM.meshPerfAddBlockKind = meshPerfAddBlockKind
RM.meshPerfAddKindDuration = meshPerfAddKindDuration
RM.shouldStoreBlockEmissionCache = shouldStoreBlockEmissionCache
RM.publishMeshPerfStats = publishMeshPerfStats
RM.printMeshEmitProbe = printMeshEmitProbe
