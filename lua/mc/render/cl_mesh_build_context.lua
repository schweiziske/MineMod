-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local clampLightLevel = RM.clampLightLevel
local sameLiquidKind = RM.sameLiquidKind
local coveredByBoxes = RM.coveredByBoxes
local facePlane = RM.facePlane
local EPS = RM.EPS
local cornerXYZ = RM.cornerXYZ
local shadeRecolorIndex = RM.shadeRecolorIndex
local uploadMeshVertices = RM.uploadMeshVertices
local meshPerfAdd = RM.meshPerfAdd
local meshPerfMS = RM.meshPerfMS
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

	local function styleForBuffer( buf )
		return meshLightStyle
	end

	local function currentEmitLightStyle()
		return styleForBuffer( cur )
	end

	local function localIndex( lx, ly, lz )
		return lx + ly * C.CS + lz * C.CS2
	end

	local function localIndexForBlockCoords( bx, by, bz )
		local lx, ly, lz = bx - bxo, by - byo, bz - bzo
		if lx < 0 or lx >= C.CS or ly < 0 or ly >= C.CS or lz < 0 or lz >= C.CH then return nil end
		return localIndex( lx, ly, lz )
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

	local function newMeshBuffer( material, translucent )
		return { list = {}, records = {}, verts = {}, light = {}, nv = 0, material = material, translucent = translucent == true }
	end

	local function newBlockCacheBuffer( targetBuffer )
		return { verts = {}, light = {}, nv = 0, material = targetBuffer.material, translucent = targetBuffer.translucent == true, cacheOnly = true }
	end

	local function prepareBlockCacheBuffer( targetBuffer )
		cur = newBlockCacheBuffer( targetBuffer )
		return true
	end

	local function buildLightIndexByLi( light, vertexCount )
		local byLi = {}
		for i = 1, vertexCount do
			local meta = light[i]
			local li = meta and meta.li
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
		return byLi
	end

	local function buffersForLocal( lx, ly, lz )
		local index = MC.RenderSectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil end
		local buffers = sectionBuffers[index]
		if not buffers then
			buffers = {
				opaque = newMeshBuffer( MC.Material, false ),
				translucent = newMeshBuffer( MC.MaterialTranslucent, true ),
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
		buf.list[#buf.list + 1] = { mesh = m, material = buf.material }
		buf.records[#buf.records + 1] = {
			mesh = m,
			verts = buf.verts,
			light = buf.light,
			lightByLi = buildLightIndexByLi( buf.light, vertexCount ),
			material = buf.material,
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
		local nv = cur.nv + 1
		cur.nv = nv
		cur.verts[nv] = vert
		cur.light[nv] = light
		if not cur.cacheOnly then
			meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + 1
			if nv >= C.VERT_LIMIT then flush( cur ) end
		end
	end

	local function lightMeta( shade, bx, by, bz, id, faceIndex, corner, selfEmission, unusedQuad, faceCubic, quadLightEmission )
		local cx, cy, cz = cornerXYZ( corner )
		local shadeIndex = shadeRecolorIndex( shade )
		quadLightEmission = clampLightLevel( quadLightEmission )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return {
			shade = shade,
			shadeIndex = shadeIndex,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			li = localIndexForBlockCoords( bx, by, bz ),
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
			quadLightEmission = quadLightEmission,
			faceCubic = faceCubic ~= false,
		}
	end

	local function lightMetaValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission, unusedQuad, faceCubic, quadLightEmission )
		local shadeIndex = shadeRecolorIndex( shade )
		quadLightEmission = clampLightLevel( quadLightEmission )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return {
			shade = shade,
			shadeIndex = shadeIndex,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			li = localIndexForBlockCoords( bx, by, bz ),
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
			quadLightEmission = quadLightEmission,
			faceCubic = faceCubic ~= false,
		}
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
