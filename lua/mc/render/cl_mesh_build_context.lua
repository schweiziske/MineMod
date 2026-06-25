-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local clampLightLevel = RM.clampLightLevel
local lightmapStyleUsesHardware = RM.lightmapStyleUsesHardware
local fallbackLightStyle = RM.fallbackLightStyle
local MC_LIGHT_STYLE_LIGHTMAP = RM.MC_LIGHT_STYLE_LIGHTMAP
local sameLiquidKind = RM.sameLiquidKind
local coveredByBoxes = RM.coveredByBoxes
local facePlane = RM.facePlane
local EPS = RM.EPS
local cornerXYZ = RM.cornerXYZ
local shadeRecolorIndex = RM.shadeRecolorIndex
local uploadMeshVertices = RM.uploadMeshVertices
local meshPerfAdd = RM.meshPerfAdd
local meshPerfMS = RM.meshPerfMS
local smoothCornerLightmapUVFromMeta = RM.smoothCornerLightmapUVFromMeta
local lightmapPacketCornerUV = RM.lightmapPacketCornerUV
local setMeshSampleCacheOrigin = RM.setMeshSampleCacheOrigin
local ensureChunkRenderSectionIndex = RM.ensureChunkRenderSectionIndex

function RM.NewBuildContext( key, sectionIndex, chunk, meshPerf, meshProbe, meshLightStyle, buildStart )
	local sectionNeedsRecolor = sectionIndex and MC.MeshLightDirty[key] and MC.MeshLightDirty[key][sectionIndex]
	local blockLightDirtySection = sectionNeedsRecolor and MC.GetBlockLightDirtySection and MC.GetBlockLightDirtySection( key, sectionIndex ) or nil
	local sectionNeedsFullRecolor = sectionNeedsRecolor and not blockLightDirtySection

	local bxo = chunk.cx * C.CS
	local byo = chunk.cy * C.CS
	local bzo = chunk.cz * C.CH
	setMeshSampleCacheOrigin( bxo, byo, bzo )
	chunk.orients = chunk.orients or {}
	local chunkBlocks = chunk.blocks or {}
	local chunkOrients = chunk.orients
	local normalizeOrient = MC.NormalizeOrient
	local blocksById = MC.Blocks
	local blockIsFullCube = MC.BlockIsFullCube
	local getBlock = MC.GetBlock
	local getBlockOrient = MC.GetBlockOrient
	local isPaneBlock = MC.IsPaneBlock
	local blockBoxes = MC.BlockBoxes

	local sectionBuffers = {}
	local cur
	local meshUsesHardwareLightmap = lightmapStyleUsesHardware( meshLightStyle )

	local function styleForBuffer( buf )
		if meshLightStyle == MC_LIGHT_STYLE_LIGHTMAP and not ( buf and buf.lightmap ) then
			return fallbackLightStyle( meshLightStyle )
		end
		return meshLightStyle
	end

	local function currentEmitLightStyle()
		return styleForBuffer( cur )
	end

	local function localIndex( lx, ly, lz )
		return lx + ly * C.CS + lz * C.CS2
	end

	local function inCurrentChunk( lx, ly, lz )
		return lx >= 0 and lx < C.CS and ly >= 0 and ly < C.CS and lz >= 0 and lz < C.CH
	end

	local function blockAt( lx, ly, lz, bx, by, bz )
		if inCurrentChunk( lx, ly, lz ) then
			return chunkBlocks[localIndex( lx, ly, lz )] or 0
		end
		return getBlock( bx, by, bz )
	end

	local function orientAt( lx, ly, lz, bx, by, bz )
		if inCurrentChunk( lx, ly, lz ) then
			local li = localIndex( lx, ly, lz )
			local id = chunkBlocks[li]
			if not id then return 0 end
			return normalizeOrient and normalizeOrient( id, chunkOrients[li] ) or ( chunkOrients[li] or 0 )
		end
		return getBlockOrient and getBlockOrient( bx, by, bz ) or 0
	end

	local function visibleAt( curId, lx, ly, lz, bx, by, bz )
		local nb = blockAt( lx, ly, lz, bx, by, bz )
		if nb == 0 then return true end
		if sameLiquidKind( curId, nb ) then return false end
		local d = blocksById[nb]
		if d and d.transparent then return nb ~= curId end
		if blockIsFullCube and not blockIsFullCube( nb, orientAt( lx, ly, lz, bx, by, bz ) ) then return true end
		return false
	end

	local function shapeFaceCoveredAt( curId, box, faceIndex, boxes, bx, by, bz, lx, ly, lz )
		if boxes and #boxes > 1 and coveredByBoxes( box, faceIndex, boxes, 0, 0, 0 ) then return true end
		local plane = facePlane( box, faceIndex )
		local off = C.FACES[faceIndex].off
		if ( faceIndex == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.BOTTOM and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.XP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.XN and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.YP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.YN and math.abs( plane ) > EPS ) then
			return false
		end
		local nlx, nly, nlz = lx + off[1], ly + off[2], lz + off[3]
		local nbx, nby, nbz = bx + off[1], by + off[2], bz + off[3]
		local nb = blockAt( nlx, nly, nlz, nbx, nby, nbz )
		if nb == 0 then return false end
		if sameLiquidKind( curId, nb ) then return true end
		local d = blocksById[nb]
		if d and d.transparent and not ( isPaneBlock and isPaneBlock( nb ) ) then return false end
		local nbOrient = orientAt( nlx, nly, nlz, nbx, nby, nbz )
		if blockIsFullCube and blockIsFullCube( nb, nbOrient ) then return true end
		return coveredByBoxes( box, faceIndex, blockBoxes and blockBoxes( nb, nbOrient, nbx, nby, nbz ) or nil, off[1], off[2], off[3] )
	end

	local function newMeshBuffer( material, translucent, lightmap )
		return { list = {}, records = {}, verts = {}, light = {}, nv = 0, material = material, translucent = translucent == true, lightmap = lightmap == true }
	end

	local function newBlockCacheBuffer( targetBuffer )
		return { verts = {}, light = {}, nv = 0, material = targetBuffer.material, translucent = targetBuffer.translucent == true, lightmap = targetBuffer.lightmap == true, cacheOnly = true }
	end

	local function prepareBlockCacheBuffer( targetBuffer )
		cur = newBlockCacheBuffer( targetBuffer )
		return true
	end

	local function buffersForLocal( lx, ly, lz )
		local index = MC.RenderSectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil end
		local buffers = sectionBuffers[index]
		if not buffers then
			buffers = {
				opaque = newMeshBuffer( meshUsesHardwareLightmap and MC.MaterialLightmapped or MC.Material, false, meshUsesHardwareLightmap ),
				translucent = newMeshBuffer( meshUsesHardwareLightmap and MC.MaterialLightmappedTranslucent or MC.MaterialTranslucent, true, meshUsesHardwareLightmap ),
			}
			sectionBuffers[index] = buffers
		end
		return buffers
	end

	local function flush( buf )
		if buf.nv == 0 then return end
		local vertexCount = buf.nv
		local meshNewStart = SysTime()
		local m = Mesh( buf.material )
		meshPerfAdd( meshPerf, "meshNewMS", meshNewStart )
		uploadMeshVertices( m, buf.verts, meshPerf )
		buf.list[#buf.list + 1] = { mesh = m, material = buf.material, lightmap = buf.lightmap == true }
		buf.records[#buf.records + 1] = {
			mesh = m,
			verts = buf.verts,
			light = buf.light,
			material = buf.material,
			lightmap = buf.lightmap == true,
			vertexCount = vertexCount,
		}
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if buf.translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		buf.verts = {}
		buf.light = {}
		buf.nv = 0
	end

	local function push( vert, light )
		if cur and cur.lightmap then
			local u1, v1 = light and light.u1, light and light.v1
			if u1 ~= nil and v1 ~= nil then
				meshPerf.lightmapPacketVertices = ( meshPerf.lightmapPacketVertices or 0 ) + 1
			else
				u1, v1 = smoothCornerLightmapUVFromMeta( light )
				meshPerf.lightmapFallbackUVs = ( meshPerf.lightmapFallbackUVs or 0 ) + 1
			end
			vert.u1 = u1
			vert.v1 = v1
			if light and not light.shared then
				light.u1 = nil
				light.v1 = nil
			end
		end
		local nv = cur.nv + 1
		cur.nv = nv
		cur.verts[nv] = vert
		cur.light[nv] = light
		if not cur.cacheOnly then
			meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + 1
			if nv >= C.VERT_LIMIT then flush( cur ) end
		end
	end

	local function addLightmapPacketUV( meta, lightmapPacket, packetCornerIndex )
		if not lightmapPacket or not packetCornerIndex or not lightmapPacketCornerUV then return meta end
		local u1, v1 = lightmapPacketCornerUV( lightmapPacket, packetCornerIndex )
		if u1 ~= nil and v1 ~= nil then
			meta.u1 = u1
			meta.v1 = v1
			meta.lightmapCornerIndex = packetCornerIndex
		end
		return meta
	end

	local function lightMeta( shade, bx, by, bz, id, faceIndex, corner, selfEmission, weightedLightmapQuad, faceCubic, quadLightEmission, lightmapPacket, packetCornerIndex )
		local cx, cy, cz = cornerXYZ( corner )
		local shadeIndex = shadeRecolorIndex( shade )
		quadLightEmission = clampLightLevel( quadLightEmission )
		if faceCubic == nil then
			faceCubic = not weightedLightmapQuad or weightedLightmapQuad.faceCubic ~= false
		end
		return addLightmapPacketUV( {
			shade = shade,
			shadeIndex = shadeIndex,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
			quadLightEmission = quadLightEmission,
			weightedLightmapQuad = weightedLightmapQuad,
			faceCubic = faceCubic ~= false,
		}, lightmapPacket, packetCornerIndex )
	end

	local function lightMetaValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission, weightedLightmapQuad, faceCubic, quadLightEmission, lightmapPacket, packetCornerIndex )
		local shadeIndex = shadeRecolorIndex( shade )
		quadLightEmission = clampLightLevel( quadLightEmission )
		if faceCubic == nil then
			faceCubic = not weightedLightmapQuad or weightedLightmapQuad.faceCubic ~= false
		end
		return addLightmapPacketUV( {
			shade = shade,
			shadeIndex = shadeIndex,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
			quadLightEmission = quadLightEmission,
			weightedLightmapQuad = weightedLightmapQuad,
			faceCubic = faceCubic ~= false,
		}, lightmapPacket, packetCornerIndex )
	end

	local function appendMeshList( out, list )
		for i = 1, #list do
			out[#out + 1] = list[i]
		end
	end

	local function flushSectionBuffers()
		local opaqueMeshes = {}
		local translucentMeshes = {}
		local opaqueRecords = {}
		local translucentRecords = {}
		local totalSections = C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				flush( buffers.opaque )
				flush( buffers.translucent )
				appendMeshList( opaqueMeshes, buffers.opaque.list )
				appendMeshList( translucentMeshes, buffers.translucent.list )
				appendMeshList( opaqueRecords, buffers.opaque.records )
				appendMeshList( translucentRecords, buffers.translucent.records )
			end
		end
		return opaqueMeshes, translucentMeshes, opaqueRecords, translucentRecords
	end

	local blockIter = chunk.blocks
	if sectionIndex then
		local indexStart = SysTime()
		local bySection = ensureChunkRenderSectionIndex( chunk )
		meshPerfAdd( meshPerf, "indexMS", indexStart )
		blockIter = bySection and bySection[sectionIndex] or {}
	end
	meshPerf.prepMS = meshPerfMS( buildStart )

	local ctx = {
		key = key,
		sectionIndex = sectionIndex,
		chunk = chunk,
		meshPerf = meshPerf,
		meshProbe = meshProbe,
		meshLightStyle = meshLightStyle,
		sectionNeedsRecolor = sectionNeedsRecolor,
		blockLightDirtySection = blockLightDirtySection,
		sectionNeedsFullRecolor = sectionNeedsFullRecolor,
		bxo = bxo,
		byo = byo,
		bzo = bzo,
		chunkBlocks = chunkBlocks,
		chunkOrients = chunkOrients,
		blocksById = blocksById,
		blockIsFullCube = blockIsFullCube,
		blockBoxes = blockBoxes,
		blockIter = blockIter,
		sectionBuffers = sectionBuffers,
		C = C,
	}

	ctx.styleForBuffer = styleForBuffer
	ctx.currentEmitLightStyle = currentEmitLightStyle
	ctx.localIndex = localIndex
	ctx.blockAt = blockAt
	ctx.orientAt = orientAt
	ctx.visibleAt = visibleAt
	ctx.shapeFaceCoveredAt = shapeFaceCoveredAt
	ctx.buffersForLocal = buffersForLocal
	ctx.flush = flush
	ctx.push = push
	ctx.lightMeta = lightMeta
	ctx.lightMetaValues = lightMetaValues
	ctx.flushSectionBuffers = flushSectionBuffers
	function ctx.prepareBlockCacheBuffer( targetBuffer )
		local ok = prepareBlockCacheBuffer( targetBuffer )
		ctx.cur = cur
		return ok
	end
	function ctx.setCur( value )
		cur = value
		ctx.cur = cur
	end
	function ctx.getCur()
		ctx.cur = cur
		return cur
	end
	return ctx
end
